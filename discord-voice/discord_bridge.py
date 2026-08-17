#!/usr/bin/env python3
"""Discord desktop RPC bridge for the Noctalia Discord Voice plugin.

The daemon connects to Discord's local IPC socket and writes state snapshots as
JSON lines to stdout. Short-lived ``command`` invocations talk to the daemon's
private control socket, which lets Noctalia buttons control the persistent RPC
session without exposing the OAuth token to Luau or process arguments.

Python 3.10+ standard library only.
"""

from __future__ import annotations

import asyncio
import errno
import json
import logging
import math
import os
import signal
import socket
import struct
import sys
import tempfile
import time
import urllib.request
from pathlib import Path
from typing import Any, TypedDict


STREAMKIT_CLIENT_ID = "207646673902501888"
OAUTH_SCOPES = ("rpc", "rpc.voice.read", "rpc.voice.write")
TOKEN_EXCHANGE_URL = "https://streamkit.discord.com/overlay/token"
HTTP_USER_AGENT = "Noctalia-Discord-Voice"

OP_HANDSHAKE = 0
OP_FRAME = 1
OP_CLOSE = 2
OP_PING = 3
OP_PONG = 4

RECONNECT_SECONDS = 3
HEARTBEAT_SECONDS = 5
MAX_AVATAR_BYTES = 2 * 1024 * 1024
MAX_RPC_PAYLOAD_BYTES = 8 * 1024 * 1024
MAX_RECENT_CHANNELS = 5
MAX_FAVORITE_CHANNELS = 5
VOICE_STATE_EVENTS = (
    "VOICE_STATE_CREATE",
    "VOICE_STATE_UPDATE",
    "VOICE_STATE_DELETE",
)
SPEAKING_EVENTS = ("SPEAKING_START", "SPEAKING_STOP")


class VoiceSettings(TypedDict):
    mute: bool
    deaf: bool
    input_volume: int


def normalized_volume(value: Any, default: int, maximum: int) -> int:
    """Return a finite Discord volume value clamped to its documented range."""

    try:
        number = float(value)
    except (TypeError, ValueError, OverflowError):
        return default
    if not math.isfinite(number):
        return default
    return max(0, min(maximum, int(round(number))))


logging.basicConfig(
    level=logging.INFO,
    format="[noctalia-discord-voice] %(levelname)s: %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger("discord-voice")


def _xdg_dir(name: str, fallback: str) -> Path:
    value = os.environ.get(name)
    return Path(value).expanduser() if value else Path(fallback).expanduser()


def control_socket_path() -> Path:
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if runtime:
        return Path(runtime) / "noctalia-discord-voice.sock"
    return Path("/tmp") / f"noctalia-discord-voice-{os.getuid()}.sock"


def state_directory() -> Path:
    root = os.environ.get("NOCTALIA_STATE_HOME")
    base = (
        Path(root).expanduser()
        if root
        else _xdg_dir("XDG_STATE_HOME", "~/.local/state")
    )
    return base / "noctalia" / "discord-voice"


def avatar_directory() -> Path:
    return (
        _xdg_dir("XDG_CACHE_HOME", "~/.cache")
        / "noctalia"
        / "discord-voice"
        / "avatars"
    )


def write_private_json(path: Path, payload: dict[str, Any]) -> None:
    """Atomically write JSON with private directory and file permissions."""

    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        os.chmod(path.parent, 0o700)
    except OSError:
        pass

    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle)
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    finally:
        temporary.unlink(missing_ok=True)


class TokenStore:
    """Small 0600 token store. Tokens are never included in bridge output."""

    def __init__(self) -> None:
        self.path = state_directory() / "token.json"

    def load(self) -> str | None:
        try:
            payload = json.loads(self.path.read_text(encoding="utf-8"))
            token = payload.get("access_token")
            return token if isinstance(token, str) and token else None
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            return None

    def save(self, token: str) -> None:
        write_private_json(self.path, {"access_token": token})

    def clear(self) -> None:
        try:
            self.path.unlink()
        except FileNotFoundError:
            pass
        except OSError as error:
            log.warning("Could not remove expired Discord token: %s", error)


class ChannelStore:
    """Private local history for recent and favorite voice channels."""

    def __init__(self) -> None:
        self.path = state_directory() / "channels.json"

    @staticmethod
    def _channel(value: Any) -> dict[str, Any] | None:
        if not isinstance(value, dict) or not value.get("id"):
            return None
        try:
            last_joined_time = int(value.get("last_joined_time") or 0)
        except (TypeError, ValueError, OverflowError):
            last_joined_time = 0
        return {
            "id": str(value.get("id")),
            "name": str(value.get("name") or "Voice channel"),
            "guild_id": str(value.get("guild_id") or ""),
            "guild_name": str(value.get("guild_name") or ""),
            "last_joined_time": last_joined_time,
        }

    @classmethod
    def _channels(cls, value: Any, limit: int) -> list[dict[str, Any]]:
        # Version 0.1 stored a single object at ``recent``. Accept it so users
        # keep their saved channel when upgrading to the five-item history.
        values = value if isinstance(value, list) else [value]
        channels: list[dict[str, Any]] = []
        seen: set[str] = set()
        for item in values:
            channel = cls._channel(item)
            if channel and channel["id"] not in seen:
                channels.append(channel)
                seen.add(channel["id"])
            if len(channels) == limit:
                break
        return channels

    def load(self) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
        try:
            payload = json.loads(self.path.read_text(encoding="utf-8"))
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            return [], []
        if not isinstance(payload, dict):
            return [], []
        favorites = payload.get("favorites")
        if not isinstance(favorites, list):
            # Migrate the original single pinned channel in place.
            favorites = [payload.get("pinned")]
        recent_channels = self._channels(payload.get("recent"), MAX_RECENT_CHANNELS)
        favorite_channels = self._channels(favorites, MAX_FAVORITE_CHANNELS)

        # Older state has recency encoded only by array position. Backfill a
        # stable timestamp rank so favorites shared with the recent list keep
        # the same last-joined ordering after the new activity sort is applied.
        known_times = [
            channel["last_joined_time"]
            for channel in (*recent_channels, *favorite_channels)
        ]
        try:
            state_mtime = int(self.path.stat().st_mtime)
        except OSError:
            state_mtime = 0
        migration_base = max(state_mtime, *known_times)
        migrated = False
        recent_times: dict[str, int] = {}
        for index, channel in enumerate(recent_channels):
            if channel["last_joined_time"] <= 0:
                channel["last_joined_time"] = migration_base - index
                migrated = True
            recent_times[channel["id"]] = channel["last_joined_time"]
        for index, channel in enumerate(favorite_channels):
            recent_time = recent_times.get(channel["id"])
            if (
                recent_time is not None
                and channel["last_joined_time"] != recent_time
            ):
                channel["last_joined_time"] = recent_time
                migrated = True
            elif channel["last_joined_time"] <= 0:
                channel["last_joined_time"] = (
                    migration_base - len(recent_channels) - index
                )
                migrated = True

        if migrated:
            self.save(recent_channels, favorite_channels)
        return recent_channels, favorite_channels

    def save(
        self, recent: list[dict[str, Any]], favorites: list[dict[str, Any]]
    ) -> None:
        payload = {
            "recent": self._channels(recent, MAX_RECENT_CHANNELS),
            "favorites": self._channels(favorites, MAX_FAVORITE_CHANNELS),
        }
        write_private_json(self.path, payload)


class DiscordIPC:
    """Binary-framed connection to Discord's documented local RPC server."""

    def __init__(self) -> None:
        self.reader: asyncio.StreamReader | None = None
        self.writer: asyncio.StreamWriter | None = None
        self._write_lock = asyncio.Lock()

    @staticmethod
    def candidate_paths() -> list[Path]:
        directories: list[Path] = []
        runtime = os.environ.get("XDG_RUNTIME_DIR")
        if runtime:
            runtime_path = Path(runtime)
            directories.append(runtime_path)
            directories.append(runtime_path / "app" / "com.discordapp.Discord")
            directories.append(runtime_path / "snap.discord")
            directories.extend(sorted(runtime_path.glob("snap.discord_*")))

        snap_data = os.environ.get("SNAP_USER_DATA")
        if snap_data:
            directories.append(Path(snap_data) / ".config")

        for variable in ("TMPDIR", "TMP", "TEMP"):
            value = os.environ.get(variable)
            if value:
                directories.append(Path(value))
        directories.append(Path("/tmp"))

        paths: list[Path] = []
        seen: set[Path] = set()
        for directory in directories:
            for index in range(10):
                path = directory / f"discord-ipc-{index}"
                if path not in seen:
                    seen.add(path)
                    paths.append(path)
        return paths

    @property
    def connected(self) -> bool:
        return self.writer is not None and not self.writer.is_closing()

    @staticmethod
    def _peer_uid(writer: asyncio.StreamWriter) -> int | None:
        """Return the connected Unix peer UID, or None when it cannot be verified."""

        peer_socket = writer.get_extra_info("socket")
        peercred_option = getattr(socket, "SO_PEERCRED", None)
        if peer_socket is None or peercred_option is None:
            return None

        try:
            credentials = peer_socket.getsockopt(
                socket.SOL_SOCKET, peercred_option, struct.calcsize("3i")
            )
            _, uid, _ = struct.unpack("3i", credentials)
        except (AttributeError, OSError, struct.error):
            return None
        return uid

    async def connect(self) -> Path | None:
        expected_uid = os.geteuid()
        for path in self.candidate_paths():
            if not path.exists():
                continue
            try:
                reader, writer = await asyncio.open_unix_connection(path)
            except OSError:
                continue

            peer_uid = self._peer_uid(writer)
            if peer_uid == expected_uid:
                self.reader, self.writer = reader, writer
                return path

            if peer_uid is None:
                reason = "peer credentials could not be verified"
            else:
                reason = f"peer UID {peer_uid} does not match {expected_uid}"
            log.warning("Rejected Discord IPC at %s: %s", path, reason)
            writer.close()
            try:
                await writer.wait_closed()
            except OSError:
                pass
        return None

    async def send(self, opcode: int, payload: dict[str, Any]) -> None:
        if not self.writer:
            raise ConnectionError("Discord IPC is not connected")
        encoded = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        frame = struct.pack("<II", opcode, len(encoded)) + encoded
        async with self._write_lock:
            self.writer.write(frame)
            await self.writer.drain()

    async def receive(self) -> tuple[int, dict[str, Any]]:
        if not self.reader:
            raise ConnectionError("Discord IPC is not connected")
        header = await self.reader.readexactly(8)
        opcode, length = struct.unpack("<II", header)
        if length > MAX_RPC_PAYLOAD_BYTES:
            raise ValueError(f"Discord RPC payload is too large: {length} bytes")
        encoded = await self.reader.readexactly(length)
        payload = json.loads(encoded.decode("utf-8"))
        if not isinstance(payload, dict):
            raise ValueError("Discord returned a non-object payload")
        return opcode, payload

    async def handshake(self) -> dict[str, Any]:
        await self.send(OP_HANDSHAKE, {"v": 1, "client_id": STREAMKIT_CLIENT_ID})
        opcode, payload = await self.receive()
        if opcode == OP_CLOSE:
            raise ConnectionError("Discord rejected the StreamKit handshake")
        if payload.get("evt") != "READY":
            raise ConnectionError("Discord did not return READY")
        return payload

    async def close(self) -> None:
        writer = self.writer
        self.reader = None
        self.writer = None
        if writer:
            writer.close()
            try:
                await writer.wait_closed()
            except OSError:
                pass


def exchange_authorization_code(code: str) -> str:
    body = json.dumps({"code": code}).encode("utf-8")
    request = urllib.request.Request(
        TOKEN_EXCHANGE_URL,
        data=body,
        headers={
            "Content-Type": "application/json",
            "User-Agent": HTTP_USER_AGENT,
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=15) as response:
        payload = json.loads(response.read().decode("utf-8"))
    token = payload.get("access_token")
    if not isinstance(token, str) or not token:
        raise ValueError("StreamKit returned no access token")
    return token


def download_avatar(user_id: str, avatar_hash: str, destination: Path) -> Path:
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        os.chmod(destination.parent, 0o700)
    except OSError:
        pass
    url = f"https://cdn.discordapp.com/avatars/{user_id}/{avatar_hash}.png?size=64"
    request = urllib.request.Request(url, headers={"User-Agent": HTTP_USER_AGENT})
    with urllib.request.urlopen(request, timeout=10) as response:
        content = response.read(MAX_AVATAR_BYTES + 1)
    if len(content) > MAX_AVATAR_BYTES:
        raise ValueError("Discord avatar exceeded the size limit")
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{destination.name}.", suffix=".tmp", dir=destination.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(content)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)
    return destination


class DiscordVoiceBridge:
    def __init__(self) -> None:
        self.ipc = DiscordIPC()
        self.tokens = TokenStore()
        self.channels = ChannelStore()
        self.control_path = control_socket_path()
        self.control_server: asyncio.AbstractServer | None = None
        self.stop_event = asyncio.Event()

        self.status = "starting"
        self.status_message = ""
        self.authenticated = False
        self.current_user: dict[str, Any] = {}
        self.channel: dict[str, Any] | None = None
        self.recent_channels, self.favorite_channels = self.channels.load()
        self.participants: dict[str, dict[str, Any]] = {}
        self.voice_settings: VoiceSettings = {
            "mute": False,
            "deaf": False,
            "input_volume": 100,
        }
        self.connection: dict[str, Any] = {
            "state": "DISCONNECTED",
            "hostname": "",
            "average_ping": 0,
            "last_ping": 0,
        }
        self.connected_since: int | None = None
        self.revision = 0
        self.pending: dict[str, dict[str, Any]] = {}
        self.next_nonce = 0
        self.active_token: str | None = None
        self.avatar_tasks: dict[str, asyncio.Task[None]] = {}
        self.saved_channel_counts: dict[str, int] = {}
        self.channel_event_subscriptions: dict[str, set[str]] = {}

    async def run(self) -> None:
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            try:
                loop.add_signal_handler(sig, self.stop_event.set)
            except NotImplementedError:
                pass

        await self._start_control_server()
        supervisor = asyncio.create_task(self._supervise_discord())
        heartbeat = asyncio.create_task(self._heartbeat())
        self._emit_snapshot()

        await self.stop_event.wait()
        supervisor.cancel()
        heartbeat.cancel()
        await asyncio.gather(supervisor, heartbeat, return_exceptions=True)
        for task in self.avatar_tasks.values():
            task.cancel()
        await asyncio.gather(*self.avatar_tasks.values(), return_exceptions=True)
        await self.ipc.close()
        if self.control_server:
            self.control_server.close()
            await self.control_server.wait_closed()
        try:
            self.control_path.unlink()
        except FileNotFoundError:
            pass

    def _write_event(self, payload: dict[str, Any]) -> None:
        try:
            sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\n")
            sys.stdout.flush()
        except (BrokenPipeError, OSError):
            self.stop_event.set()

    def _emit_snapshot(self) -> None:
        self.revision += 1
        participants: list[dict[str, Any]] = []
        for participant in self.participants.values():
            participants.append(
                {
                    key: value
                    for key, value in participant.items()
                    if key != "avatar_hash"
                }
            )
        participants.sort(
            key=lambda item: (
                item["nick"].casefold(),
                item["id"],
            )
        )

        self._write_event(
            {
                "type": "snapshot",
                "revision": self.revision,
                "status": self.status,
                "status_message": self.status_message,
                "authenticated": self.authenticated,
                "user": self.current_user,
                "channel": self.channel,
                "recent_channels": self._sorted_saved_channels(self.recent_channels),
                "favorite_channels": self._sorted_saved_channels(
                    self.favorite_channels
                ),
                "participants": participants,
                "voice": self.voice_settings,
                "connection": self.connection,
                "connected_since": self.connected_since,
            }
        )

    def _sorted_saved_channels(
        self, channels: list[dict[str, Any]]
    ) -> list[dict[str, Any]]:
        decorated: list[dict[str, Any]] = []
        for channel in channels:
            entry = dict(channel)
            entry["participant_count"] = max(
                0, self.saved_channel_counts.get(channel["id"], 0)
            )
            decorated.append(entry)
        return sorted(
            decorated,
            key=lambda entry: (
                entry["participant_count"] > 0,
                entry["last_joined_time"],
            ),
            reverse=True,
        )

    def _set_status(self, status: str, message: str = "") -> None:
        changed = status != self.status or message != self.status_message
        self.status = status
        self.status_message = message
        if changed:
            self._emit_snapshot()

    async def _heartbeat(self) -> None:
        while not self.stop_event.is_set():
            await asyncio.sleep(HEARTBEAT_SECONDS)
            self._write_event({"type": "heartbeat", "time": int(time.time())})

    async def _start_control_server(self) -> None:
        self.control_path.parent.mkdir(parents=True, exist_ok=True)
        for attempt in range(51):
            if not self.control_path.exists():
                break
            probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            probe.settimeout(0.1)
            occupied = False
            try:
                probe.connect(str(self.control_path))
                occupied = True
            except OSError:
                self.control_path.unlink(missing_ok=True)
                break
            finally:
                probe.close()
            if occupied and attempt < 50:
                # Noctalia can start a replacement service just before the old
                # runStream process has finished cleaning up during hot reload.
                await asyncio.sleep(0.1)
                continue
            raise RuntimeError(f"another bridge owns {self.control_path}")

        self.control_server = await asyncio.start_unix_server(
            self._handle_control_client, path=str(self.control_path)
        )
        os.chmod(self.control_path, 0o600)
        log.info("Control socket ready at %s", self.control_path)

    async def _handle_control_client(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        response: dict[str, Any]
        try:
            encoded = await asyncio.wait_for(reader.readline(), timeout=3)
            request = json.loads(encoded.decode("utf-8"))
            response = await self._handle_control_command(request)
        except Exception as error:
            response = {"ok": False, "error": str(error)}

        writer.write(
            json.dumps(response, separators=(",", ":")).encode("utf-8") + b"\n"
        )
        try:
            await writer.drain()
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except OSError:
                pass

    def _saved_channel(self, channel_id: str) -> dict[str, Any] | None:
        return next(
            (
                channel
                for channel in (*self.favorite_channels, *self.recent_channels)
                if channel["id"] == channel_id
            ),
            None,
        )

    async def _save_channel_lists(self) -> None:
        self.channels.save(self.recent_channels, self.favorite_channels)
        await self._sync_channel_subscriptions()
        self._emit_snapshot()

    async def _favorite_channel(self, channel_id: str) -> dict[str, Any]:
        channel = (
            self.channel
            if self.channel and self.channel["id"] == channel_id
            else self._saved_channel(channel_id)
        )
        if channel is None:
            return {"ok": False, "error": "Channel is no longer available"}

        self.favorite_channels = [
            dict(channel),
            *[
                favorite
                for favorite in self.favorite_channels
                if favorite["id"] != channel_id
            ],
        ][:MAX_FAVORITE_CHANNELS]
        await self._save_channel_lists()
        return {"ok": True}

    async def _unfavorite_channel(self, channel_id: str) -> dict[str, Any]:
        remaining = [
            channel for channel in self.favorite_channels if channel["id"] != channel_id
        ]
        if len(remaining) == len(self.favorite_channels):
            return {"ok": False, "error": "Favorite channel is no longer available"}
        self.favorite_channels = remaining
        await self._save_channel_lists()
        return {"ok": True}

    async def _join_channel(self, channel_id: str) -> dict[str, Any]:
        if self._saved_channel(channel_id) is None:
            return {"ok": False, "error": "Saved channel is no longer available"}
        await self._request(
            "SELECT_VOICE_CHANNEL",
            {"channel_id": channel_id},
            kind="join_channel",
        )
        return {"ok": True}

    async def _handle_control_command(self, request: dict[str, Any]) -> dict[str, Any]:
        command = request["command"]
        if command == "status":
            sorted_favorites = self._sorted_saved_channels(self.favorite_channels)
            sorted_recents = self._sorted_saved_channels(self.recent_channels)
            return {
                "ok": True,
                "status": self.status,
                "authenticated": self.authenticated,
                "in_voice": self.channel is not None,
                "channel": self.channel["name"] if self.channel else "",
                "participant_count": len(self.participants),
                "speaking_count": sum(
                    1
                    for participant in self.participants.values()
                    if participant["speaking"]
                ),
                "connection_state": self.connection["state"],
                "average_ping": self.connection["average_ping"],
                "saved_channel": (sorted_favorites[0] if sorted_favorites else None)
                or (sorted_recents[0] if sorted_recents else None),
            }
        if command == "shutdown":
            self.stop_event.set()
            return {"ok": True}
        if command == "authorize":
            await self._begin_authorization()
            return {"ok": True}
        if command == "refresh":
            self.status_message = ""
            if self.authenticated:
                await self._request(
                    "GET_SELECTED_VOICE_CHANNEL", kind="selected_channel"
                )
                await self._request("GET_VOICE_SETTINGS", kind="voice_settings")
                await self._sync_channel_subscriptions()
            return {"ok": True}
        if not self.authenticated:
            return {"ok": False, "error": "Authorize Discord first"}
        if command in ("favorite_channel", "unfavorite_channel", "join_channel"):
            channel_id = request["value"]
            if command == "favorite_channel":
                return await self._favorite_channel(channel_id)
            if command == "unfavorite_channel":
                return await self._unfavorite_channel(channel_id)
            return await self._join_channel(channel_id)
        if command == "set_mute":
            await self._request(
                "SET_VOICE_SETTINGS",
                {"mute": request["value"]},
                kind="voice_settings",
            )
            return {"ok": True}
        if command == "set_deaf":
            await self._request(
                "SET_VOICE_SETTINGS",
                {"deaf": request["value"]},
                kind="voice_settings",
            )
            return {"ok": True}
        if command == "set_mic_volume":
            volume = request["value"]
            previous_volume = self.voice_settings["input_volume"]
            self.voice_settings["input_volume"] = volume
            self.status_message = ""
            self._emit_snapshot()
            await self._request(
                "SET_VOICE_SETTINGS",
                {"input": {"volume": volume}},
                kind="mic_volume",
                meta={
                    "previous_volume": previous_volume,
                    "target_volume": volume,
                },
            )
            return {"ok": True}
        if command == "set_user_volume":
            user_id = request["user_id"]
            if not self.channel or user_id not in self.participants:
                return {
                    "ok": False,
                    "error": "Participant is no longer in this channel",
                }
            if user_id == self.current_user["id"]:
                return {
                    "ok": False,
                    "error": "Use microphone volume to change your own input level",
                }
            volume = request["value"]
            participant = self.participants[user_id]
            previous_volume = participant["volume"]
            participant["volume"] = volume
            self.status_message = ""
            self._emit_snapshot()
            await self._request(
                "SET_USER_VOICE_SETTINGS",
                {"user_id": user_id, "volume": volume},
                kind="user_voice_settings",
                meta={
                    "user_id": user_id,
                    "previous_volume": previous_volume,
                    "target_volume": volume,
                },
            )
            return {"ok": True}
        if command == "hang_up":
            await self._request(
                "SELECT_VOICE_CHANNEL",
                {"channel_id": None},
                kind="hang_up",
            )
            return {"ok": True}
        return {"ok": False, "error": f"unknown command: {command}"}

    async def _supervise_discord(self) -> None:
        while not self.stop_event.is_set():
            try:
                await self._discord_session()
            except asyncio.CancelledError:
                raise
            except Exception as error:
                log.warning("Discord session ended: %s", error)
                self._set_status("discord_unavailable", str(error))
            finally:
                await self.ipc.close()
                self._reset_session_state()

            if not self.stop_event.is_set():
                await asyncio.sleep(RECONNECT_SECONDS)

    async def _discord_session(self) -> None:
        self._set_status("connecting")
        path = await self.ipc.connect()
        if not path:
            raise ConnectionError("Discord desktop is not running")
        await self.ipc.handshake()
        log.info("Connected to Discord IPC at %s", path)

        token = self.tokens.load()
        if token:
            self.active_token = token
            self._set_status("authenticating")
            await self._request(
                "AUTHENTICATE", {"access_token": token}, kind="authenticate"
            )
        else:
            self._set_status("auth_required")

        while not self.stop_event.is_set():
            opcode, payload = await self.ipc.receive()
            if opcode == OP_CLOSE:
                raise ConnectionError("Discord closed the RPC connection")
            if opcode == OP_PING:
                await self.ipc.send(OP_PONG, payload)
                continue
            if opcode == OP_PONG:
                continue
            await self._handle_discord_payload(payload)

    def _reset_session_state(self) -> None:
        self.pending.clear()
        self.channel_event_subscriptions.clear()
        self.saved_channel_counts.clear()
        self.authenticated = False
        self.current_user = {}
        self.channel = None
        self.participants.clear()
        self.voice_settings = {"mute": False, "deaf": False, "input_volume": 100}
        self.connection = {
            "state": "DISCONNECTED",
            "hostname": "",
            "average_ping": 0,
            "last_ping": 0,
        }
        self.connected_since = None
        if self.status not in ("discord_unavailable", "connecting"):
            self.status = "discord_unavailable"
        self._emit_snapshot()

    async def _request(
        self,
        command: str,
        args: dict[str, Any] | None = None,
        *,
        kind: str,
        meta: dict[str, Any] | None = None,
        event: str | None = None,
    ) -> str:
        if not self.ipc.connected:
            raise ConnectionError("Discord IPC is not connected")
        self.next_nonce += 1
        nonce = str(self.next_nonce)
        payload: dict[str, Any] = {"cmd": command, "nonce": nonce}
        if args is not None:
            payload["args"] = args
        if event is not None:
            payload["evt"] = event
        self.pending[nonce] = {"kind": kind, "meta": meta or {}}
        try:
            await self.ipc.send(OP_FRAME, payload)
        except Exception:
            self.pending.pop(nonce, None)
            raise
        return nonce

    async def _subscribe(
        self,
        event: str,
        args: dict[str, Any] | None = None,
        *,
        meta: dict[str, Any] | None = None,
    ) -> None:
        await self._request("SUBSCRIBE", args, kind="subscribe", meta=meta, event=event)

    async def _unsubscribe(
        self,
        event: str,
        args: dict[str, Any],
        *,
        meta: dict[str, Any] | None = None,
    ) -> None:
        try:
            await self._request(
                "UNSUBSCRIBE",
                args,
                kind="unsubscribe",
                meta=meta,
                event=event,
            )
        except ConnectionError:
            pass

    async def _begin_authorization(self) -> None:
        if not self.ipc.connected:
            raise ConnectionError("Start Discord desktop before authorizing")
        if any(item["kind"] == "authorize" for item in self.pending.values()):
            return
        self._set_status("authorizing")
        await self._request(
            "AUTHORIZE",
            {
                "client_id": STREAMKIT_CLIENT_ID,
                "scopes": list(OAUTH_SCOPES),
                "prompt": "none",
            },
            kind="authorize",
        )

    async def _handle_discord_payload(self, payload: dict[str, Any]) -> None:
        nonce = payload.get("nonce")
        event = payload.get("evt")

        if event == "ERROR":
            pending = self.pending.pop(str(nonce), None) if nonce is not None else None
            message = str(payload.get("data", {}).get("message") or "Discord RPC error")
            kind = pending["kind"] if pending else ""
            if kind == "authenticate":
                self.tokens.clear()
                self.active_token = None
                self.authenticated = False
                self._set_status(
                    "auth_required", "Authorization expired; authorize Discord again"
                )
            elif kind == "authorize":
                self._set_status("auth_required", message)
            elif kind == "saved_channel":
                channel_id = pending["meta"]["channel_id"]
                self.saved_channel_counts[channel_id] = 0
                self._emit_snapshot()
            elif kind in ("subscribe", "unsubscribe"):
                # The pending request has already been removed, so a later
                # synchronization may retry this transition. Do not update the
                # confirmed subscription set for a rejected request.
                self.status_message = message
                self._emit_snapshot()
            elif kind == "mic_volume":
                meta = pending["meta"]
                target = meta["target_volume"]
                if self.voice_settings["input_volume"] == target:
                    self.voice_settings["input_volume"] = meta["previous_volume"]
                self.status_message = message
                self._emit_snapshot()
            elif kind == "user_voice_settings":
                meta = pending["meta"]
                user_id = meta["user_id"]
                participant = self.participants.get(user_id)
                target = meta["target_volume"]
                if participant and participant["volume"] == target:
                    participant["volume"] = meta["previous_volume"]
                self.status_message = message
                self._emit_snapshot()
            else:
                self.status_message = message
                self._emit_snapshot()
            return

        if nonce is not None and str(nonce) in self.pending:
            pending = self.pending.pop(str(nonce))
            await self._handle_response(pending, payload.get("data"))
            return

        if payload.get("cmd") == "DISPATCH" and isinstance(event, str):
            data = payload.get("data")
            await self._handle_dispatch(event, data if isinstance(data, dict) else {})

    async def _handle_response(self, pending: dict[str, Any], data: Any) -> None:
        kind = pending["kind"]
        response = data if isinstance(data, dict) else {}

        if kind in ("subscribe", "unsubscribe"):
            meta = pending["meta"]
            channel_id = meta.get("channel_id")
            event = meta.get("event")
            if isinstance(channel_id, str) and isinstance(event, str):
                subscribed = self.channel_event_subscriptions.setdefault(
                    channel_id, set()
                )
                if kind == "subscribe":
                    subscribed.add(event)
                else:
                    subscribed.discard(event)
                    if not subscribed:
                        self.channel_event_subscriptions.pop(channel_id, None)
                await self._sync_channel_subscriptions()
            return

        if kind == "authorize":
            code = response.get("code")
            if not isinstance(code, str) or not code:
                self._set_status(
                    "auth_required", "Discord authorization was not completed"
                )
                return
            try:
                token = await asyncio.to_thread(exchange_authorization_code, code)
            except Exception as error:
                self._set_status(
                    "auth_required", f"StreamKit token exchange failed: {error}"
                )
                return
            self.active_token = token
            self._set_status("authenticating")
            await self._request(
                "AUTHENTICATE", {"access_token": token}, kind="authenticate"
            )
            return

        if kind == "authenticate":
            user = (
                response.get("user") if isinstance(response.get("user"), dict) else {}
            )
            self.current_user = {
                "id": str(user.get("id") or ""),
                "username": str(user.get("global_name") or user.get("username") or ""),
            }
            self.authenticated = True
            if self.active_token:
                self.tokens.save(self.active_token)
            self._set_status("ready")
            await self._subscribe_global_events()
            await self._request("GET_SELECTED_VOICE_CHANNEL", kind="selected_channel")
            await self._request("GET_VOICE_SETTINGS", kind="voice_settings")
            return

        if kind == "selected_channel":
            if response.get("id"):
                await self._enter_channel(response)
            else:
                await self._leave_channel()
            return

        if kind == "saved_channel":
            channel_id = pending["meta"]["channel_id"]
            voice_states = response.get("voice_states")
            users: set[str] = set()
            if isinstance(voice_states, list):
                for state in voice_states:
                    if not isinstance(state, dict):
                        continue
                    user = state.get("user")
                    user_id = str(
                        (user.get("id") if isinstance(user, dict) else "")
                        or state.get("user_id")
                        or ""
                    )
                    if user_id:
                        users.add(user_id)
            self.saved_channel_counts[channel_id] = len(users)
            self._emit_snapshot()
            return

        if kind == "guild":
            guild_id = pending["meta"]["guild_id"]
            if self.channel and self.channel["guild_id"] == guild_id:
                self.channel["guild_name"] = str(response.get("name") or "")
                self._remember_current_channel()
                self._emit_snapshot()
            return

        if kind in ("voice_settings", "mic_volume"):
            input_settings = (
                response.get("input") if isinstance(response.get("input"), dict) else {}
            )
            self.voice_settings = {
                "mute": bool(
                    response.get("mute", self.voice_settings["mute"])
                ),
                "deaf": bool(
                    response.get("deaf", self.voice_settings["deaf"])
                ),
                "input_volume": normalized_volume(
                    input_settings.get("volume"),
                    self.voice_settings["input_volume"],
                    100,
                ),
            }
            self.status_message = ""
            self._emit_snapshot()
            return

        if kind == "user_voice_settings":
            user_id = response.get("user_id") or pending["meta"]["user_id"]
            participant = self.participants.get(user_id)
            if participant:
                participant["volume"] = normalized_volume(
                    response.get("volume"), participant["volume"], 200
                )
                if "mute" in response:
                    participant["local_mute"] = bool(response["mute"])
                self.status_message = ""
                self._emit_snapshot()
            return

        if kind == "hang_up":
            if not response:
                await self._leave_channel()
            return

        if kind == "join_channel":
            if response.get("id"):
                await self._enter_channel(response)
            else:
                await self._request(
                    "GET_SELECTED_VOICE_CHANNEL", kind="selected_channel"
                )

    async def _subscribe_global_events(self) -> None:
        for event in (
            "VOICE_CHANNEL_SELECT",
            "VOICE_SETTINGS_UPDATE",
            "VOICE_CONNECTION_STATUS",
        ):
            await self._subscribe(event)

    def _saved_channel_ids(self) -> list[str]:
        channel_ids: list[str] = []
        seen: set[str] = set()
        for channel in (*self.favorite_channels, *self.recent_channels):
            channel_id = channel["id"]
            if channel_id not in seen:
                seen.add(channel_id)
                channel_ids.append(channel_id)
        return channel_ids

    async def _subscribe_channel_event(self, channel_id: str, event: str) -> None:
        await self._subscribe(
            event,
            {"channel_id": channel_id},
            meta={"channel_id": channel_id, "event": event},
        )

    async def _unsubscribe_channel_event(self, channel_id: str, event: str) -> None:
        await self._unsubscribe(
            event,
            {"channel_id": channel_id},
            meta={"channel_id": channel_id, "event": event},
        )

    def _pending_channel_events(self, kind: str) -> dict[str, set[str]]:
        pending: dict[str, set[str]] = {}
        for request in self.pending.values():
            if request["kind"] != kind:
                continue
            channel_id = request["meta"].get("channel_id")
            event = request["meta"].get("event")
            if isinstance(channel_id, str) and isinstance(event, str):
                pending.setdefault(channel_id, set()).add(event)
        return pending

    async def _sync_channel_subscriptions(self) -> None:
        if not self.authenticated:
            return
        desired: dict[str, set[str]] = {}
        if self.channel:
            desired[self.channel["id"]] = set((*VOICE_STATE_EVENTS, *SPEAKING_EVENTS))
        else:
            for channel_id in self._saved_channel_ids():
                desired[channel_id] = {"VOICE_STATE_CREATE", "VOICE_STATE_DELETE"}

        pending_subscribes = self._pending_channel_events("subscribe")
        pending_unsubscribes = self._pending_channel_events("unsubscribe")
        for channel_id, events in list(self.channel_event_subscriptions.items()):
            unwanted = events - desired.get(channel_id, set())
            for event in unwanted - pending_unsubscribes.get(channel_id, set()):
                await self._unsubscribe_channel_event(channel_id, event)
        for channel_id, events in desired.items():
            subscribed = self.channel_event_subscriptions.get(channel_id, set())
            missing = events - subscribed
            for event in missing - pending_subscribes.get(channel_id, set()):
                await self._subscribe_channel_event(channel_id, event)

        await self._refresh_saved_channel_counts()

    async def _refresh_saved_channel_counts(self) -> None:
        if not self.authenticated or self.channel is not None:
            return
        pending_ids = {
            item["meta"]["channel_id"]
            for item in self.pending.values()
            if item["kind"] == "saved_channel"
        }
        for channel_id in self._saved_channel_ids():
            if channel_id not in pending_ids:
                await self._request(
                    "GET_CHANNEL",
                    {"channel_id": channel_id},
                    kind="saved_channel",
                    meta={"channel_id": channel_id},
                )

    async def _enter_channel(self, channel_data: dict[str, Any]) -> None:
        channel_id = str(channel_data.get("id") or "")
        if not channel_id:
            return
        previous_id = self.channel["id"] if self.channel else ""
        previous_last_joined = (
            self.channel["last_joined_time"] if self.channel else 0
        )

        guild_id = str(channel_data.get("guild_id") or "")
        known_guild_name = ""
        for known in (self.channel, *self.favorite_channels, *self.recent_channels):
            if known and known["guild_id"] == guild_id:
                known_guild_name = known["guild_name"]
                if known_guild_name:
                    break
        self.channel = {
            "id": channel_id,
            "name": str(channel_data.get("name") or "Voice channel"),
            "guild_id": guild_id,
            "guild_name": str(channel_data.get("guild_name") or known_guild_name),
            "last_joined_time": (
                int(time.time()) if previous_id != channel_id else previous_last_joined
            ),
        }
        if previous_id != channel_id:
            self.connected_since = int(time.time())
        self.participants.clear()
        voice_states = channel_data.get("voice_states")
        if isinstance(voice_states, list):
            for state in voice_states:
                if isinstance(state, dict):
                    self._upsert_participant(state)

        self._remember_current_channel()

        await self._sync_channel_subscriptions()
        if guild_id:
            await self._request(
                "GET_GUILD",
                {"guild_id": guild_id},
                kind="guild",
                meta={"guild_id": guild_id},
            )
        await self._request("GET_VOICE_SETTINGS", kind="voice_settings")
        self._emit_snapshot()

    def _remember_current_channel(self) -> None:
        if not self.channel:
            return
        channel_id = self.channel["id"]
        self.recent_channels = [
            dict(self.channel),
            *[
                channel
                for channel in self.recent_channels
                if channel["id"] != channel_id
            ],
        ][:MAX_RECENT_CHANNELS]
        self.favorite_channels = [
            dict(self.channel) if channel["id"] == channel_id else channel
            for channel in self.favorite_channels
        ]
        self.channels.save(self.recent_channels, self.favorite_channels)

    async def _leave_channel(self) -> None:
        self.channel = None
        self.participants.clear()
        self.connected_since = None
        self.connection = {
            "state": "DISCONNECTED",
            "hostname": "",
            "average_ping": 0,
            "last_ping": 0,
        }
        await self._sync_channel_subscriptions()
        self._emit_snapshot()

    def _upsert_participant(self, data: dict[str, Any]) -> None:
        user = data.get("user") if isinstance(data.get("user"), dict) else {}
        voice = (
            data.get("voice_state") if isinstance(data.get("voice_state"), dict) else {}
        )
        user_id = str(user.get("id") or data.get("user_id") or "")
        if not user_id:
            return

        existing = self.participants.get(user_id, {})
        avatar_hash = str(user.get("avatar") or existing.get("avatar_hash") or "")
        username = str(
            user.get("global_name")
            or user.get("username")
            or existing.get("username")
            or "Unknown"
        )
        participant = {
            "id": user_id,
            "username": username,
            "nick": str(data.get("nick") or existing.get("nick") or username),
            "avatar_hash": avatar_hash,
            "avatar_path": str(existing.get("avatar_path") or ""),
            "mute": bool(voice.get("mute", existing.get("mute", False))),
            "self_mute": bool(voice.get("self_mute", existing.get("self_mute", False))),
            "deaf": bool(voice.get("deaf", existing.get("deaf", False))),
            "self_deaf": bool(voice.get("self_deaf", existing.get("self_deaf", False))),
            "volume": normalized_volume(
                data.get("volume"), int(existing.get("volume", 100)), 200
            ),
            "local_mute": bool(data.get("mute", existing.get("local_mute", False))),
            "speaking": bool(existing.get("speaking", False)),
        }
        self.participants[user_id] = participant
        self._ensure_avatar(user_id, avatar_hash)

    def _ensure_avatar(self, user_id: str, avatar_hash: str) -> None:
        if not avatar_hash:
            return
        destination = avatar_directory() / f"{user_id}-{avatar_hash}.png"
        participant = self.participants[user_id]
        if destination.exists():
            participant["avatar_path"] = str(destination)
            return
        key = f"{user_id}:{avatar_hash}"
        if key in self.avatar_tasks:
            return

        async def hydrate() -> None:
            try:
                path = await asyncio.to_thread(
                    download_avatar, user_id, avatar_hash, destination
                )
                current = self.participants.get(user_id)
                if current and current.get("avatar_hash") == avatar_hash:
                    current["avatar_path"] = str(path)
                    self._emit_snapshot()
            except Exception as error:
                log.info("Could not cache avatar for user %s: %s", user_id, error)
            finally:
                self.avatar_tasks.pop(key, None)

        self.avatar_tasks[key] = asyncio.create_task(hydrate())

    async def _handle_dispatch(self, event: str, data: dict[str, Any]) -> None:
        if event == "VOICE_CHANNEL_SELECT":
            if data.get("channel_id"):
                await self._request(
                    "GET_SELECTED_VOICE_CHANNEL", kind="selected_channel"
                )
            else:
                await self._leave_channel()
            return

        if event == "VOICE_SETTINGS_UPDATE":
            input_settings = (
                data.get("input") if isinstance(data.get("input"), dict) else {}
            )
            self.voice_settings = {
                "mute": bool(data.get("mute", self.voice_settings["mute"])),
                "deaf": bool(data.get("deaf", self.voice_settings["deaf"])),
                "input_volume": normalized_volume(
                    input_settings.get("volume"),
                    self.voice_settings["input_volume"],
                    100,
                ),
            }
            self._emit_snapshot()
            return

        if event == "VOICE_CONNECTION_STATUS":
            self.connection = {
                "state": str(data.get("state") or "DISCONNECTED"),
                "hostname": str(data.get("hostname") or ""),
                "average_ping": int(float(data.get("average_ping") or 0)),
                "last_ping": int(float(data.get("last_ping") or 0)),
            }
            self._emit_snapshot()
            return

        if event in ("VOICE_STATE_CREATE", "VOICE_STATE_UPDATE"):
            if self.channel:
                self._upsert_participant(data)
                self._emit_snapshot()
            else:
                await self._refresh_saved_channel_counts()
            return

        if event == "VOICE_STATE_DELETE":
            if self.channel:
                user = data.get("user") if isinstance(data.get("user"), dict) else {}
                user_id = str(user.get("id") or data.get("user_id") or "")
                if user_id:
                    self.participants.pop(user_id, None)
                    self._emit_snapshot()
            else:
                await self._refresh_saved_channel_counts()
            return

        if event in ("SPEAKING_START", "SPEAKING_STOP"):
            user_id = str(data.get("user_id") or "")
            participant = self.participants.get(user_id)
            if participant:
                participant["speaking"] = event == "SPEAKING_START"
                self._emit_snapshot()


async def send_control_command(
    command: str, value: Any = None, user_id: str | None = None
) -> dict[str, Any]:
    request: dict[str, Any] = {"command": command}
    if value is not None:
        request["value"] = value
    if user_id is not None:
        request["user_id"] = user_id
    writer: asyncio.StreamWriter | None = None
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_unix_connection(str(control_socket_path())), timeout=3
        )
        writer.write(json.dumps(request, separators=(",", ":")).encode("utf-8") + b"\n")
        await writer.drain()
        encoded = await asyncio.wait_for(reader.readline(), timeout=5)
    finally:
        if writer:
            writer.close()
            try:
                await writer.wait_closed()
            except OSError:
                pass
    return json.loads(encoded.decode("utf-8"))


def control_error_state(error: BaseException) -> str:
    """Classify whether a watchdog may safely launch a replacement bridge."""

    if isinstance(error, OSError) and error.errno in (
        errno.ENOENT,
        errno.ECONNREFUSED,
    ):
        return "absent"
    if isinstance(error, (TimeoutError, asyncio.TimeoutError)):
        return "unresponsive"
    return "unavailable"


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] not in ("daemon", "command"):
        print(
            "usage: discord_bridge.py daemon | command <name> [value] [volume]",
            file=sys.stderr,
        )
        return 2

    if sys.argv[1] == "daemon":
        try:
            asyncio.run(DiscordVoiceBridge().run())
            return 0
        except Exception as error:
            log.error("Bridge failed: %s", error)
            return 1

    if len(sys.argv) < 3:
        print(json.dumps({"ok": False, "error": "missing command"}))
        return 2

    command = sys.argv[2].replace("-", "_")

    try:
        user_id: str | None = None
        if command in ("set_mute", "set_deaf"):
            value: Any = sys.argv[3] == "true"
        elif command == "set_mic_volume":
            value = int(sys.argv[3])
        elif command == "set_user_volume":
            user_id = sys.argv[3]
            value = int(sys.argv[4])
        elif command in ("favorite_channel", "unfavorite_channel", "join_channel"):
            value = sys.argv[3]
        else:
            value = None
    except (IndexError, ValueError) as error:
        detail = (
            "missing required value" if isinstance(error, IndexError) else str(error)
        )
        print(
            json.dumps(
                {
                    "ok": False,
                    "error": f"invalid arguments for {sys.argv[2]}: {detail}",
                },
                separators=(",", ":"),
            )
        )
        return 2

    try:
        response = asyncio.run(send_control_command(command, value, user_id))
    except Exception as error:
        response = {
            "ok": False,
            "error": f"Discord voice bridge is unavailable: {error}",
            "bridge_state": control_error_state(error),
        }
    print(json.dumps(response, separators=(",", ":")))
    return 0 if response.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
