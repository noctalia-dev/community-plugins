"""Native-messaging bridge between Thunderbird and Noctalia.

Thunderbird owns stdin/stdout using the native-messaging framing protocol.
Noctalia exchanges JSON through a private state directory:

  snapshot.json      latest unread-message metadata from Thunderbird
  commands/*.json    atomic commands queued by the Noctalia service
  action-result.json latest command result returned by the extension

Nothing is written to stdout except framed native-messaging responses.
"""

from __future__ import annotations

import json
import os
import secrets
import struct
import sys
import time
from pathlib import Path
from typing import Any

HOST_NAME = "dev.noctalia.thunderbird_companion"
MAX_NATIVE_MESSAGE_BYTES = 4 * 1024 * 1024
ALLOWED_COMMANDS = {
    "open_message",
    "mark_read",
    "mark_all_read",
    "archive",
    "compose",
    "reply",
    "refresh",
}

STATE_HOME = Path(
    os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state"
).expanduser()
BRIDGE_DIR = STATE_HOME / "noctalia" / "thunderbird-companion"
SNAPSHOT_PATH = BRIDGE_DIR / "snapshot.json"
COMMAND_DIR = BRIDGE_DIR / "commands"
ACTION_RESULT_PATH = BRIDGE_DIR / "action-result.json"
BRIDGE_ERROR_PATH = BRIDGE_DIR / "bridge-error.json"
CONNECTION_PATH = BRIDGE_DIR / "connection.json"
HEARTBEAT_INTERVAL_SECONDS = 2.0


def ensure_bridge_dir() -> None:
    os.umask(0o077)
    BRIDGE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    COMMAND_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        BRIDGE_DIR.chmod(0o700)
        COMMAND_DIR.chmod(0o700)
    except OSError:
        pass


def atomic_write_json(path: Path, payload: Any) -> None:
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    data = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    temporary.write_text(data, encoding="utf-8")
    try:
        temporary.chmod(0o600)
    except OSError:
        pass
    os.replace(temporary, path)


def write_connection_status(session: str, connected_at: int) -> None:
    atomic_write_json(
        CONNECTION_PATH,
        {
            "schemaVersion": 1,
            "session": session,
            "pid": os.getpid(),
            "connectedAt": connected_at,
            "heartbeatAt": int(time.time() * 1000),
        },
    )


def remove_connection_status(session: str) -> None:
    try:
        payload = json.loads(CONNECTION_PATH.read_text(encoding="utf-8"))
        if isinstance(payload, dict) and payload.get("session") == session:
            CONNECTION_PATH.unlink()
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        pass


def read_exact(length: int) -> bytes | None:
    chunks: list[bytes] = []
    remaining = length
    while remaining > 0:
        chunk = sys.stdin.buffer.read(remaining)
        if not chunk:
            return None
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def read_native_message() -> dict[str, Any] | None:
    raw_length = read_exact(4)
    if raw_length is None:
        return None
    (length,) = struct.unpack("@I", raw_length)
    if length <= 0 or length > MAX_NATIVE_MESSAGE_BYTES:
        raise ValueError(f"invalid native message length: {length}")
    encoded = read_exact(length)
    if encoded is None:
        return None
    payload = json.loads(encoded.decode("utf-8"))
    if not isinstance(payload, dict):
        raise TypeError("native message must be an object")
    return payload


def send_native_message(payload: dict[str, Any]) -> None:
    encoded = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode(
        "utf-8"
    )
    sys.stdout.buffer.write(struct.pack("@I", len(encoded)))
    sys.stdout.buffer.write(encoded)
    sys.stdout.buffer.flush()


def valid_command(payload: Any) -> dict[str, Any] | None:
    if not isinstance(payload, dict) or payload.get("op") not in ALLOWED_COMMANDS:
        return None
    command = {
        "op": payload["op"],
        "seq": payload.get("seq"),
    }
    if payload["op"] in {"open_message", "mark_read", "archive", "reply"}:
        message_id = payload.get("id")
        if not isinstance(message_id, int) or isinstance(message_id, bool) or message_id < 0:
            return None
        command["id"] = message_id
    return command


def take_commands() -> list[dict[str, Any]]:
    processing = sorted(COMMAND_DIR.glob("processing-command-*.json"))
    for command_path in sorted(COMMAND_DIR.glob("command-*.json")):
        claimed = command_path.with_name(f"processing-{command_path.name}")
        try:
            os.replace(command_path, claimed)
            processing.append(claimed)
        except FileNotFoundError:
            pass

    commands: list[dict[str, Any]] = []
    for path in processing:
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
            command = valid_command(payload)
            if command:
                commands.append(command)
        except (OSError, json.JSONDecodeError) as error:
            print(f"{HOST_NAME}: invalid command {path.name}: {error}", file=sys.stderr)
        finally:
            try:
                path.unlink()
            except FileNotFoundError:
                pass
    return commands


def handle_message(message: dict[str, Any]) -> dict[str, Any]:
    message_type = message.get("type")

    if message_type == "hello":
        return {
            "type": "hello_ack",
            "host": HOST_NAME,
            "hostTime": int(time.time() * 1000),
        }

    if message_type == "snapshot":
        snapshot = message.get("data")
        if not isinstance(snapshot, dict) or snapshot.get("schemaVersion") != 1:
            return {"type": "error", "error": "invalid snapshot"}
        snapshot["receivedAt"] = int(time.time() * 1000)
        atomic_write_json(SNAPSHOT_PATH, snapshot)
        try:
            BRIDGE_ERROR_PATH.unlink()
        except FileNotFoundError:
            pass
        return {"type": "ack", "for": "snapshot"}

    if message_type == "snapshot_error":
        atomic_write_json(
            BRIDGE_ERROR_PATH,
            {
                "at": int(time.time() * 1000),
                "error": str(message.get("error") or "snapshot failed"),
            },
        )
        return {"type": "ack", "for": "snapshot_error"}

    if message_type == "action_result":
        result = {
            "at": int(time.time() * 1000),
            "seq": message.get("seq"),
            "op": str(message.get("op") or ""),
            "ok": message.get("ok") is True,
            "error": str(message.get("error") or ""),
        }
        atomic_write_json(ACTION_RESULT_PATH, result)
        return {"type": "ack", "for": "action_result"}

    if message_type == "poll":
        return {"type": "commands", "commands": take_commands()}

    return {"type": "error", "error": "unsupported message type"}


def main() -> int:
    ensure_bridge_dir()
    session = secrets.token_hex(16)
    connected_at = int(time.time() * 1000)
    last_heartbeat = time.monotonic()
    write_connection_status(session, connected_at)
    try:
        while True:
            try:
                message = read_native_message()
                if message is None:
                    return 0
                now = time.monotonic()
                if now - last_heartbeat >= HEARTBEAT_INTERVAL_SECONDS:
                    write_connection_status(session, connected_at)
                    last_heartbeat = now
                send_native_message(handle_message(message))
            except (BrokenPipeError, EOFError):
                return 0
            except Exception as error:  # Keep the host alive for recoverable input errors.
                print(f"{HOST_NAME}: {error}", file=sys.stderr)
                try:
                    send_native_message({"type": "error", "error": str(error)})
                except BrokenPipeError:
                    return 0
    finally:
        remove_connection_status(session)


if __name__ == "__main__":
    raise SystemExit(main())
