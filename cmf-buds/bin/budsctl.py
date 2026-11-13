#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Control for the CMF Buds Pro 2 (B172) on Linux.

Speaks the RFCOMM 0x55 protocol used by the Nothing X app. The flow is:
  classic Bluetooth connected (A2DP) -> RFCOMM channel -> handshake -> commands.

Modes:
  budsctl.py daemon ...   persistent daemon with a Unix socket + state.json
  budsctl.py rpc '<json>' talks to the daemon
  budsctl.py status       prints the current state
  budsctl.py stop         stops the daemon

The protocol is based on the work of:
  - https://github.com/SoaOaoS/something-x (MIT)
  - https://github.com/maniacx/BudsLink (GPL-3.0)
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import signal
import socket
import socketserver
import struct
import subprocess
import sys
import threading
import time
import traceback

try:
    from local_actions import LocalActionEngine
except Exception as exc:  # pragma: no cover - the shortcut engine is optional
    LocalActionEngine = None
    # The reason is kept: without it the daemon would answer
    # "engine_unavailable" without saying why the engine did not load.
    LOCAL_ACTIONS_IMPORT_ERROR = exc
else:
    LOCAL_ACTIONS_IMPORT_ERROR = None

# ── 0x55 protocol ────────────────────────────────────────────────────────────

SOF = 0x55
CTRL_HOST_CRC = 0x0160

CMD_PROTOCOL_GET = 0xC001
CMD_PROTOCOL_SET = 0xF001
CMD_MODEL_GET = 0xC01C
CMD_FIRMWARE_GET = 0xC042
CMD_SERIAL_GET = 0xC006
CMD_BATTERY_GET = 0xC007
CMD_EARPHONE_GET = 0xC00A
CMD_ANC_GET = 0xC01E
CMD_ANC_SET = 0xF00F
CMD_ANC_CONFIG_GET = 0xC01D
CMD_EQ_GET = 0xC01F
CMD_EQ_SET = 0xF010
CMD_LISTENING_MODE_GET = 0xC050
CMD_LISTENING_MODE_SET = 0xF01D
CMD_CUSTOM_EQ_GET = 0xC044
CMD_CUSTOM_EQ_SET = 0xF041
CMD_BASS_GET = 0xC04E
CMD_BASS_SET = 0xF051
CMD_SPATIAL_GET = 0xC04F
CMD_SPATIAL_SET = 0xF052
CMD_IN_EAR_GET = 0xC00E
CMD_IN_EAR_SET = 0xF004
CMD_LATENCY_GET = 0xC041
CMD_LATENCY_SET = 0xF040
CMD_DUAL_GET = 0xC027
CMD_DUAL_SET = 0xF01A
CMD_GESTURES_GET = 0xC018
CMD_GESTURES_SET = 0xF003
CMD_RING_SET = 0xF002
CMD_FIT_TEST_SET = 0xF014
CMD_FIT_TEST_NTFY = 0xE00D

# Notifications / responses
NTFY_BATTERY = 0xE001
NTFY_ANC = 0xE003
NTFY_STATUS = 0xE002
NTFY_GESTURES = 0x4018

# ANC
ANC_OFF = 5
ANC_STRONG = 1
ANC_MEDIUM = 2
ANC_WEAK = 3
ANC_ADAPTIVE = 4
ANC_TRANSPARENCY = 7

ANC_LEVELS = {
    "high": ANC_STRONG,
    "mid": ANC_MEDIUM,
    "low": ANC_WEAK,
    "adaptive": ANC_ADAPTIVE,
}
ANC_LEVEL_NAMES = {v: k for k, v in ANC_LEVELS.items()}

# Equalizer / listening modes for the B172
LISTENING_MODES = {
    "balanced": 0,
    "rock": 1,
    "electronic": 2,
    "pop": 3,
    "vocal": 4,
    "classical": 5,
    "custom": 6,
}
LISTENING_MODE_NAMES = {v: k for k, v in LISTENING_MODES.items()}

# B172 EQ: 3 fixed parametric bands
CUSTOM_EQ_GAIN_OFFSETS = (6, 19, 32)  # mid, treble, bass
CUSTOM_EQ_TEMPLATE = bytes(
    [
        0x03, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x75, 0x44, 0xC3, 0xF5, 0x28, 0x3F, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xC0, 0x5A, 0x45, 0x00, 0x00, 0x80, 0x3F, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x0C, 0x43, 0xCD, 0xCC, 0x4C, 0x3F, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00,
    ]
)

# Gestures for the CMF Buds Pro 2 (B172), taken from BudsLink.
GESTURE_SLOTS = [
    # group, device, type, label
    ("left", 0x02, 0x02, "double"),
    ("left", 0x02, 0x03, "triple"),
    ("left", 0x02, 0x07, "hold"),
    ("left", 0x02, 0x09, "double_hold"),
    ("right", 0x03, 0x02, "double"),
    ("right", 0x03, 0x03, "triple"),
    ("right", 0x03, 0x07, "hold"),
    ("right", 0x03, 0x09, "double_hold"),
    ("case", 0x04, 0x01, "single"),
    ("case", 0x04, 0x02, "double"),
    ("case", 0x04, 0x03, "triple"),
    ("case", 0x04, 0x07, "hold"),
    ("case", 0x04, 0x09, "double_hold"),
    ("case", 0x04, 0x0A, "rotate"),
]
GESTURE_BY_KEY = {(g, t): (d, ty) for g, d, ty, t in GESTURE_SLOTS}

GESTURE_ACTIONS = {
    "no_action": 0x01,
    "play_pause": 0x02,
    "skip_back": 0x08,
    "skip_forward": 0x09,
    "voice_assistant": 0x0B,
    "volume_up": 0x12,
    "volume_down": 0x13,
    "noise_control": 0x0A,
    "game_mode": 0x11,
    "volume_control": 0x17,
}
GESTURE_ACTION_NAMES = {v: k for k, v in GESTURE_ACTIONS.items()}

GESTURE_ALLOWED = {
    ("left", "double"): ["play_pause", "skip_back", "skip_forward", "voice_assistant", "no_action"],
    ("left", "triple"): ["skip_back", "skip_forward", "voice_assistant", "no_action"],
    ("left", "hold"): ["noise_control", "voice_assistant", "no_action"],
    ("left", "double_hold"): ["volume_up", "volume_down", "voice_assistant", "no_action"],
    ("right", "double"): ["play_pause", "skip_back", "skip_forward", "voice_assistant", "no_action"],
    ("right", "triple"): ["skip_back", "skip_forward", "voice_assistant", "no_action"],
    ("right", "hold"): ["noise_control", "voice_assistant", "no_action"],
    ("right", "double_hold"): ["volume_up", "volume_down", "voice_assistant", "no_action"],
    ("case", "single"): ["play_pause", "skip_back", "skip_forward", "voice_assistant", "game_mode", "no_action"],
    ("case", "double"): ["play_pause", "skip_back", "skip_forward", "voice_assistant", "game_mode", "no_action"],
    ("case", "triple"): ["play_pause", "skip_back", "skip_forward", "voice_assistant", "game_mode", "no_action"],
    ("case", "hold"): ["noise_control", "voice_assistant", "game_mode", "no_action"],
    ("case", "double_hold"): ["volume_up", "volume_down", "voice_assistant", "game_mode", "no_action"],
    ("case", "rotate"): ["volume_control", "no_action"],
}

BATTERY_LEFT = 0x02
BATTERY_RIGHT = 0x03
BATTERY_CASE = 0x04
BATTERY_STEREO = 0x06


def crc16(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b & 0xFF
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc & 0xFFFF


def build_frame(cmd: int, payload: bytes = b"", fsn: int = 1) -> bytes:
    header = struct.pack("<BHHH", SOF, CTRL_HOST_CRC, cmd, len(payload)) + bytes([fsn & 0xFF])
    frame = header + payload
    return frame + struct.pack("<H", crc16(frame))


# If the receive buffer grows past this, it means frame sync has been
# lost (a corrupt length, for example): drop it and search for the start
# of the next frame. Without this the parser would wait forever for data
# that will never arrive, and the buffer would keep growing without any
# limit.
MAX_BUFFER = 8192

# The biggest payload the earbuds send. A frame that claims more than this
# is corrupt: without the check the parser would wait for thousands of bytes
# that never arrive and the valid frames behind it would be lost.
MAX_PAYLOAD = 512


def _clamp_buffer(buf: bytes, limit: int = MAX_BUFFER) -> bytes:
    """Return the buffer, or empty if it is past the limit."""
    if len(buf) > limit:
        return b""
    return buf


def parse_frames(buf: bytes):
    """Return (frames, remainder). Each frame is (normalized cmd, payload)."""
    frames = []
    i = 0
    n = len(buf)
    while i + 8 <= n:
        if buf[i] != SOF:
            i += 1
            continue
        try:
            _, ctrl, cmd, length = struct.unpack_from("<BHHH", buf, i)
        except struct.error:
            break
        if length > MAX_PAYLOAD:
            # The length is corrupt: the frame cannot be trusted. The parser
            # resyncs on the next byte instead of waiting for data that will
            # never arrive (that hid every valid frame behind it).
            i += 1
            continue
        crc_len = 2 if (ctrl & 0x20) else 0
        total = 8 + length + crc_len
        if i + total > n:
            break
        payload = buf[i + 8 : i + 8 + length]
        # Do not drop on CRC: some firmwares send a bad CRC and the
        # payload is still valid. We only check it for the log.
        # The mask sets the direction bit (device to host): the earbuds
        # already set it, but a firmware that forgets it is normalized.
        frames.append((cmd | 0x8000, payload))
        i += total
    return frames, buf[i:]


def eq_float_encode(value: float, preamp: bool = False) -> bytes:
    if preamp and value >= 0:
        return bytes([0x00, 0x00, 0x00, 0x80])
    be = bytearray(struct.pack(">f", float(value)))
    if value != 0.0 and be[0] == 0 and be[1] == 0 and be[2] == 0:
        be[3] |= 0x80
    return bytes(reversed(be))


def eq_float_decode(raw: bytes) -> float:
    try:
        return struct.unpack(">f", bytes(reversed(raw)))[0]
    except Exception:
        return 0.0


MODEL_BY_SKU = {
    "01": "B181", "02": "B181", "03": "B181", "04": "B181", "06": "B181",
    "07": "B181", "08": "B181", "10": "B181",
    "14": "B157", "15": "B157", "16": "B157",
    "17": "B155", "18": "B155", "19": "B155", "27": "B155", "28": "B155", "29": "B155",
    "30": "B163", "31": "B163", "32": "B163", "33": "B163", "34": "B163", "35": "B163",
    "48": "B164", "49": "B164", "50": "B164", "51": "B164", "52": "B164", "53": "B164",
    "54": "B168", "55": "B168", "56": "B168", "57": "B168", "58": "B168", "59": "B168",
    "61": "B171", "62": "B171", "69": "B171", "70": "B171", "74": "B171", "75": "B171",
    "63": "B162", "64": "B162", "65": "B162", "66": "B162", "67": "B162",
    "68": "B162", "71": "B162", "72": "B162", "73": "B162",
    "76": "B172", "77": "B172", "78": "B172", "79": "B172", "80": "B172",
    "81": "B172", "82": "B172", "83": "B172",
}


def model_from_serial(serial: str | None) -> str | None:
    if not serial or len(serial) < 6:
        return None
    return MODEL_BY_SKU.get(serial[4:6])


def model_from_name(name: str | None) -> str | None:
    if not name:
        return None
    n = name.lower()
    if "cmf buds pro 2" in n:
        return "B172"
    if "cmf buds 2 plus" in n or "cmf buds 2+" in n:
        return "B171"
    if "cmf buds 2" in n:
        return "B168"
    if "cmf buds" in n:
        return "B168"
    return None


def run(cmd, timeout=10):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return subprocess.CompletedProcess(cmd, 1, "", str(exc))


# Poll interval limits. The manifest exposes the same range (20-300 s), so
# the daemon and the settings panel always agree on what is valid.
POLL_MIN = 20
POLL_MAX = 300
POLL_DEFAULT = 20

# Timeout of the RPC client, in seconds. There is one single budget for
# the whole chain: the client has to answer before the timeout of the
# panel (60 s) and the slowest operation of the daemon (a reconnection
# with the Bluetooth stack) has to fit inside it.
RPC_TIMEOUT = 55.0


def clamp_poll(value):
    """Poll interval in seconds, clamped to the supported range.

    An invalid value (not a number) falls back to the default instead of
    breaking the daemon: the poll interval is a convenience, not a
    requirement.
    """
    try:
        poll = int(value)
    except (TypeError, ValueError):
        return POLL_DEFAULT
    return max(POLL_MIN, min(POLL_MAX, poll))


def bt_devices():
    res = run(["bluetoothctl", "devices"], 8)
    out = []
    for line in (res.stdout or "").splitlines():
        parts = line.split(" ", 2)
        if len(parts) == 3 and parts[0] == "Device":
            out.append({"mac": parts[1], "name": parts[2].strip()})
    return out


def bt_info(mac: str):
    # The timeout is short: the device list can have a dozen entries and the
    # daemon answers the RPC in less than 20 s.
    res = run(["bluetoothctl", "info", mac], 3)
    info = {"mac": mac, "name": "", "alias": "", "connected": False, "battery": None, "icon": ""}
    for line in (res.stdout or "").splitlines():
        line = line.strip()
        if line.startswith("Name:"):
            info["name"] = line.split(":", 1)[1].strip()
        elif line.startswith("Alias:"):
            info["alias"] = line.split(":", 1)[1].strip()
        elif line.startswith("Connected:"):
            info["connected"] = line.split(":", 1)[1].strip().lower() == "yes"
        elif line.startswith("Icon:"):
            info["icon"] = line.split(":", 1)[1].strip()
        elif line.startswith("Battery Percentage:"):
            try:
                info["battery"] = int(line.split("(")[1].split(")")[0].strip().rstrip("%"))
            except Exception:
                pass
    if not info["name"]:
        info["name"] = info["alias"] or "CMF Buds Pro 2"
    return info


def pick_device(preferred_mac: str = "", preferred_name: str = ""):
    devices = bt_devices()
    if preferred_mac:
        info = bt_info(preferred_mac)
        info["name"] = info["name"] or preferred_name or info["mac"]
        return info
    candidates = []
    for dev in devices:
        name = (dev.get("name") or "").lower()
        # The name decides first: "bluetoothctl info" takes seconds and the
        # paired device list can have a dozen entries.
        if preferred_name and preferred_name.lower() in name:
            candidates.insert(0, dev)
            continue
        if any(key in name for key in ("cmf buds", "nothing ear", "cmf headphone", "nothing headphone", "ear (")):
            candidates.append(dev)
    if not candidates:
        return None
    infos = [bt_info(dev["mac"]) for dev in candidates]
    infos.sort(key=lambda d: (not d.get("connected"), 0 if "cmf buds pro 2" in d.get("name", "").lower() else 1))
    return infos[0]


# ── RFCOMM link ─────────────────────────────────────────────────────────────


# The error codes the daemon can send. The panel translates them with the
# "error.code.<code>" keys of the plugin translations, so the daemon never
# sends a sentence in a fixed language: the code is stable and the technical
# context travels apart in "error_detail".
ERROR_CODES = (
    "not_found",
    "not_paired",
    "connect_failed",
    "disconnect_failed",
    "disconnected",
    "channel_busy",
    "link_lost",
    "not_connected",
    "no_sink",
    "engine_unavailable",
    "invalid_anc",
    "invalid_preset",
    "unknown_setting",
    "invalid_gesture",
    "invalid_action",
    "action_not_available",
    "invalid_side",
    "missing_command",
    "unknown_command",
    "invalid_rule",
    "invalid_json",
    "invalid_request",
    "command_failed",
    "daemon_failed",
    "generic",
)


class UserError(ValueError):
    """Expected error: the action cannot be done right now.

    This is not a daemon failure (for example, pressing a panel button with the
    earbuds disconnected). It is logged as a single line instead of a 14-line
    traceback that buries the log.

    It carries the stable code the panel translates and, when it helps, the
    technical detail (the output of an external command, for example).
    """

    def __init__(self, message, code="generic", detail=""):
        super().__init__(message)
        self.code = code
        self.detail = detail


class BudsLink:
    PROBE_CHANNELS = [15, 17, 16, 18, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1]

    def __init__(self, mac: str, log=None):
        self.mac = mac
        self.sock: socket.socket | None = None
        self.fsn = 0
        self.pending = {}
        self.pending_lock = threading.Lock()
        self.send_lock = threading.Lock()
        # One lock per command: responses are matched by command (the firmware
        # does not return the frame sequence number), so two requests for the
        # same command at once would overwrite each other. Different commands
        # can still travel in parallel.
        self._cmd_locks = {}
        self._cmd_locks_lock = threading.Lock()
        self._disconnect_lock = threading.Lock()
        self._disconnect_notified = False
        self.on_disconnect = None
        self.reader = None
        self.running = False
        self.connected = False
        self.log = log or (lambda *a: None)

    # -- connection ------------------------------------------------------------
    def open(self):
        last_exc = None
        for ch in self.PROBE_CHANNELS:
            # The socket is created inside the try: if the creation itself
            # fails there is nothing to close and the probe of the next
            # channel continues.
            sock = None
            try:
                sock = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_STREAM, socket.BTPROTO_RFCOMM)
                sock.settimeout(3.5)
                sock.connect((self.mac, ch))
            except OSError as exc:
                last_exc = exc
                if sock is not None:
                    try:
                        sock.close()
                    except Exception:
                        pass
                continue
            try:
                sock.sendall(build_frame(CMD_PROTOCOL_GET, b"", 1))
                sock.settimeout(2.0)
                data = b""
                deadline = time.monotonic() + 2.0
                while time.monotonic() < deadline and len(data) < 4:
                    chunk = sock.recv(512)
                    if not chunk:
                        break
                    data += chunk
                if not data or data[:1] != b"\x55":
                    sock.close()
                    continue
                # Handshake: the protocol is activated before anything else.
                sock.sendall(build_frame(CMD_PROTOCOL_SET, b"", 2))
                sock.settimeout(1.2)
                frames, _ = parse_frames(data)
                activated = False
                deadline = time.monotonic() + 2.5
                buf = b""
                while time.monotonic() < deadline:
                    try:
                        chunk = sock.recv(1024)
                    except socket.timeout:
                        break
                    if not chunk:
                        break
                    buf += chunk
                    fs, buf = parse_frames(buf)
                    frames += fs
                    if any(cmd == CMD_PROTOCOL_SET for cmd, _ in frames):
                        activated = True
                        break
                self.fsn = 2
                self.sock = sock
                self.connected = True
                self._disconnect_notified = False
                self.log(f"RFCOMM connected on channel {ch} (activated={activated})")
                sock.settimeout(1.0)
                self.running = True
                self.reader = threading.Thread(target=self._read_loop, name="buds-reader", daemon=True)
                self.reader.start()
                return True
            except OSError as exc:
                last_exc = exc
                try:
                    sock.close()
                except Exception:
                    pass
                continue
        self.connected = False
        raise RuntimeError(f"Could not open the RFCOMM link: {last_exc}")

    def _close_socket(self):
        """Close and release the socket (idempotent)."""
        sock = self.sock
        self.sock = None
        if sock is not None:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                sock.close()
            except OSError:
                pass

    def close(self):
        self.running = False
        self.connected = False
        self._close_socket()

    def _notify_disconnect(self, reason):
        """Notify once that the link has gone down."""
        with self._disconnect_lock:
            if self._disconnect_notified:
                return
            self._disconnect_notified = True
        cb = getattr(self, "on_disconnect", None)
        if cb is None:
            return
        try:
            cb(reason)
        except Exception:
            self.log("Error in the disconnect notification: " + traceback.format_exc())

    def _abort(self, reason):
        """Declare the link dead: close the socket and notify the daemon.

        Without this, a socket that is still open but no longer carries
        anything (Errno 107) left the state at 'connected' forever and the
        daemon never reconnected.
        """
        was_connected = self.connected
        self.connected = False
        self.running = False
        self._close_socket()
        with self.pending_lock:
            for wait in self.pending.values():
                wait["error"] = reason
                wait["event"].set()
        if was_connected:
            self._notify_disconnect(reason)

    # -- send / receive ---------------------------------------------------
    def _read_loop(self):
        buf = b""
        while self.running:
            # The socket is read once per iteration: the disconnect thread
            # can close it (and set it to None) while the reader waits,
            # and reading self.sock again would raise AttributeError.
            sock = self.sock
            if sock is None:
                break
            try:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                buf += chunk
                acotado = _clamp_buffer(buf)
                if not acotado:
                    # Sync has been lost: drop the buffer so we do not get
                    # stuck reading garbage.
                    self.log("RFCOMM buffer overflow: resynchronizing")
                    buf = b""
                    continue
                buf = acotado
                frames, buf = parse_frames(buf)
                for cmd, payload in frames:
                    self._handle(cmd, payload)
            except socket.timeout:
                continue
            except OSError:
                break
            except Exception:
                # An unexpected error leaves the link in an unknown state:
                # log it and close the link, which the monitor will open
                # again. Reading on would repeat the error on every chunk
                # received and flood the log.
                self.log("Unexpected error in the reader: " + traceback.format_exc())
                break
        self.log("RFCOMM disconnected")
        # The socket is closed here: leaving it open leaks its descriptor on
        # every reconnect and the RFCOMM channel can stay busy, which is
        # exactly what prevents reconnecting. The daemon is also notified so
        # it marks the state as disconnected and reconnects.
        self._abort("RFCOMM link lost")

    def _handle(self, cmd, payload):
        with self.pending_lock:
            wait = self.pending.get(cmd)
            if wait is not None:
                wait["payload"] = payload
                wait["event"].set()
        self_on_frame = getattr(self, "on_frame", None)
        if self_on_frame:
            try:
                self_on_frame(cmd, payload)
            except Exception:
                self.log("Error in on_frame: " + traceback.format_exc())

    def _cmd_lock(self, cmd):
        """Exclusive lock for one command."""
        with self._cmd_locks_lock:
            lock = self._cmd_locks.get(cmd)
            if lock is None:
                lock = threading.Lock()
                self._cmd_locks[cmd] = lock
            return lock

    def request(self, cmd, payload=b"", timeout=1.5):
        """Send a command and wait for its response.

        The response is matched by command (the firmware does not return the
        frame sequence number), so two requests for the same command in flight
        would overwrite each other: one of them waits until it expires. That
        is why each command has its own lock.
        """
        with self._cmd_lock(cmd):
            if not self.connected or not self.sock:
                raise RuntimeError("the RFCOMM link is not connected")
            wait = {"event": threading.Event(), "payload": None, "error": None}
            with self.pending_lock:
                self.pending[cmd] = wait
            with self.send_lock:
                self.fsn = (self.fsn + 1) & 0xFF
                frame = build_frame(cmd, payload, self.fsn)
                try:
                    self.sock.sendall(frame)
                except OSError as exc:
                    with self.pending_lock:
                        self.pending.pop(cmd, None)
                    # The socket may still be "open" but without transport
                    # (Errno 107). If we only raise, the link stays marked as
                    # connected and the daemon never reconnects: abort the
                    # link here.
                    self._abort("Error sending the command: %s" % exc)
                    raise RuntimeError(f"Error sending the command: {exc}")
            ok = wait["event"].wait(timeout)
            with self.pending_lock:
                self.pending.pop(cmd, None)
            if wait.get("error"):
                raise RuntimeError(wait["error"])
            if not ok:
                raise TimeoutError(f"No response for 0x{cmd:04X}")
            return wait["payload"] or b""

    def send(self, cmd, payload=b"", timeout=1.0, ignore_timeout=True):
        try:
            return self.request(cmd, payload, timeout)
        except TimeoutError:
            if ignore_timeout:
                return b""
            raise


# ── State ────────────────────────────────────────────────────────────────────


def empty_state():
    return {
        "ok": True,
        "connected": False,
        "audio_connected": False,
        "device": {
            "name": "",
            "alias": "",
            "mac": "",
            "model": "",
            "firmware": "",
            "serial": "",
        },
        "battery": {
            "left": None,
            "right": None,
            "case": None,
            "charging": {"left": False, "right": False, "case": False},
            "bluez": None,
        },
        "anc": {"mode": "unknown", "level": "high"},
        "eq": {"preset": "balanced", "preset_index": 0, "kind": "listening", "custom": {"bass": 0, "mid": 0, "treble": 0}},
        "bass": {"enabled": False, "level": 1},
        "spatial": None,
        "in_ear": None,
        "low_latency": None,
        "dual_connection": None,
        "dual_restart_pending": False,
        "gestures": {},
        "fit_test": {"running": False, "left": None, "right": None, "error": ""},
        "ring": {"left": False, "right": False},
        "volume": {"percent": None, "muted": False, "sink": "", "description": ""},
        "model": "B172",
        "updated_at": 0,
        "error": "",
        "error_detail": "",
        "daemon_pid": 0,
    }


class RpcHandler(socketserver.StreamRequestHandler):
    """Reads one RPC request and answers with one line of JSON.

    The socket has a read timeout: a client that opens the connection and
    never sends anything would keep a thread (and a file descriptor) alive
    forever.
    """

    timeout = 10.0

    def handle(self):
        daemon = getattr(self.server, "daemon", None)
        if daemon is None:
            return
        daemon.last_client = time.time()
        try:
            line = self.rfile.readline(65536)
            if not line:
                return
            try:
                req = json.loads(line.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                resp = daemon._rpc_error(
                    UserError("invalid JSON request", code="invalid_json", detail=str(exc))
                )
            else:
                if not isinstance(req, dict):
                    resp = daemon._rpc_error(
                        UserError(
                            "the request must be an object", code="invalid_request"
                        )
                    )
                else:
                    resp = daemon.handle_rpc(req)
        except Exception as exc:
            resp = daemon._rpc_error(exc)
        try:
            self.wfile.write((json.dumps(resp, ensure_ascii=False) + "\n").encode("utf-8"))
        except Exception:
            pass


class BudsDaemon:
    def __init__(self, args):
        self.args = args
        self.state_path = os.path.abspath(os.path.expanduser(args.state))
        self.socket_path = os.path.abspath(os.path.expanduser(args.socket))
        self.log_path = os.path.abspath(os.path.expanduser(args.log)) if args.log else ""
        self.poll = clamp_poll(args.poll)
        self.idle_timeout = max(60, int(args.idle_timeout))
        self.preferred_mac = (args.device_mac or "").strip()
        self.preferred_name = (args.device_name or "").strip()
        self.state = empty_state()
        self.state["daemon_pid"] = os.getpid()
        # The keys the daemon owns. The rest of state.json belongs to the
        # plugin (noctalia.state) and whatever is in the file always wins: if
        # the daemon saved its own copy it would overwrite the plugin's
        # changes (the remembered tab was lost whenever it changed).
        self._daemon_keys = set(self.state.keys()) | {"local_actions"}
        self.lock = threading.RLock()
        # The RFCOMM link is swapped by the monitor thread and closed by the
        # RPC thread: without a dedicated lock the socket could be closed
        # twice, or leaked when both threads connected at the same time.
        self._link_lock = threading.RLock()
        # The volume is written from several sources at the same time (the
        # wheel of the widget, the panel slider, a dial gesture): the writes
        # are serialized so the last one asked for is the last one applied.
        self._volume_lock = threading.RLock()
        # The connection is made by the monitor thread and by the user (the
        # Connect button): the lock keeps the two from opening the same
        # RFCOMM channel at the same time.
        self._connect_lock = threading.RLock()
        self.stop_event = threading.Event()
        self.link: BudsLink | None = None
        self.last_client = time.time()
        self.last_full = 0.0
        self.last_connect_attempt = 0.0
        self.connect_backoff = 5.0
        self.ring_until = {"left": 0.0, "right": 0.0}
        self.fit_started = 0.0
        self.dirty = True
        self._lock_file = None
        self._server = None
        self._started_at = time.time()
        self._save_lock = threading.Lock()
        self.local = None
        if LocalActionEngine is None:
            if LOCAL_ACTIONS_IMPORT_ERROR is not None:
                # The engine did not load: the reason goes to the log, or the
                # daemon would answer "engine_unavailable" without saying
                # why the shortcuts do not work.
                self.log(
                    "The local action engine could not be loaded: %s"
                    % LOCAL_ACTIONS_IMPORT_ERROR
                )
        else:
            try:
                self.local = LocalActionEngine(
                    os.path.dirname(self.state_path), log=self.log
                )
                # Volume changes made from the phone or with the dial: the
                # daemon publishes them in state.json so the panel sees them
                # live (before, they only refreshed when pressing Refresh).
                self.local.on_volume = self._external_volume
                self.local.on_event = self._on_local_event
            except Exception as exc:
                self.log("Could not create the local action engine: %s" % exc)

    # -- logging -------------------------------------------------------------
    def log(self, msg):
        if not self.log_path:
            # Logging is optional: without a path there is nowhere to write.
            return
        line = time.strftime("%Y-%m-%d %H:%M:%S") + " " + str(msg) + "\n"
        try:
            os.makedirs(os.path.dirname(self.log_path), exist_ok=True)
            if os.path.exists(self.log_path) and os.path.getsize(self.log_path) > 300_000:
                os.replace(self.log_path, self.log_path + ".old")
            with open(self.log_path, "a", encoding="utf-8") as fh:
                fh.write(line)
        except Exception:
            pass

    # -- local action engine -------------------------------------------
    def _on_local_event(self):
        """The shortcut engine reports that something changed.

        The engine calls this notification from its own thread while holding
        its lock. Here we only save the state: we never enter the engine
        while holding the daemon lock (see save()), so the two threads cannot
        deadlock each other.
        """
        try:
            self.save()
        except Exception as exc:
            self.log("Could not save the local state: %s" % exc)

    # -- persistence --------------------------------------------------------
    def save(self):
        # The shortcut engine state is requested BEFORE taking any daemon
        # lock: the engine calls save() from its own thread while holding its
        # lock, and if the daemon took its own lock while waiting for the
        # engine, the two threads would wait for each other (deadlock).
        local_state = None
        if self.local is not None:
            try:
                local_state = self.local.snapshot()
            except Exception:
                local_state = None
        # The save lock is taken BEFORE the state is read: several threads
        # (monitor, RPC, RFCOMM reader) may save at once, and without it one
        # of them could write a snapshot older than the one already on disk.
        # The order is always save lock -> state lock (never the other way
        # around), and no caller takes the state lock before saving.
        with self._save_lock:
            with self.lock:
                self.state["updated_at"] = int(time.time() * 1000)
                self.state["daemon_pid"] = os.getpid()
                if local_state is not None:
                    self.state["local_actions"] = local_state
                # The plugin stores its state (the remembered tab, for example)
                # in the SAME file, under noctalia.state. If the daemon
                # overwrote it whole, those keys would be lost on every save and
                # the plugin would write them again in a loop. Keys the daemon
                # does not own are preserved.
                try:
                    with open(self.state_path, "r", encoding="utf-8") as fh:
                        previous = json.load(fh)
                    if isinstance(previous, dict):
                        # The file wins for the plugin keys, and keys the plugin
                        # deletes are deleted too.
                        for key, value in previous.items():
                            if key not in self._daemon_keys:
                                self.state[key] = value
                        for key in list(self.state):
                            if key not in self._daemon_keys and key not in previous:
                                self.state.pop(key, None)
                except Exception:
                    pass
                data = json.dumps(self.state, ensure_ascii=False, separators=(",", ":"))
            tmp = self.state_path + f".{os.getpid()}.tmp"
            # The temp file has a name of its own: several threads (monitor,
            # RPC, RFCOMM reader) may save at once. Without the lock above,
            # one thread can delete another's temp file with os.replace and
            # the write fails with ENOENT.
            try:
                os.makedirs(os.path.dirname(self.state_path), exist_ok=True)
                with open(tmp, "w", encoding="utf-8") as fh:
                    fh.write(data)
                os.replace(tmp, self.state_path)
            except Exception as exc:
                self.log(f"Could not save state: {exc}")

    # -- device ---------------------------------------------------------
    def _external_volume(self, value, sink):
        try:
            with self.lock:
                vol = self.state.setdefault("volume", {})
                changed = vol.get("percent") != int(value) or vol.get("sink") != sink
                vol["percent"] = int(value)
                vol["sink"] = sink
                vol.setdefault("muted", False)
            if changed:
                # The cached values are stale now: the next refresh has to
                # read the sink again or the old value would be published.
                self._volume_cache = None
                self.save()
        except Exception as exc:
            self.log("Could not publish the external volume: %s" % exc)

    def _is_nothing_device(self, name):
        n = (name or "").lower()
        return any(
            key in n
            for key in ("cmf buds", "cmf headphone", "nothing ear", "nothing headphone", "ear (")
        )

    def list_devices(self):
        """Nothing/CMF devices paired on the PC.
        The Nothing X app shows both dual-connection slots. From Linux only
        the devices the PC knows over Bluetooth can be seen and connected;
        the second slot is managed by the phone. Both states are shown so it
        is clear who holds the connection.
        """
        current_mac = self.state.get("device", {}).get("mac", "")
        result = []
        for dev in bt_devices():
            if not self._is_nothing_device(dev.get("name")):
                continue
            info = bt_info(dev["mac"])
            result.append(
                {
                    "mac": dev["mac"],
                    "name": info.get("name") or dev.get("name") or dev["mac"],
                    "connected": bool(info.get("connected")),
                    "battery": info.get("battery"),
                    "current": dev["mac"] == current_mac,
                }
            )
        result.sort(key=lambda d: (not d["connected"], not d["current"], d["name"]))
        return result

    def device_connect(self, mac):
        if not mac:
            raise UserError("missing device address", code="invalid_request")
        self.log("Connecting device %s" % mac)
        res = run(["bluetoothctl", "connect", mac], 20)
        if res.returncode != 0:
            raise self._bluetooth_error(res, "connect_failed")
        time.sleep(1.0)
        return self.list_devices()

    def device_disconnect(self, mac):
        if not mac:
            raise UserError("missing device address", code="invalid_request")
        self.log("Disconnecting device %s" % mac)
        res = run(["bluetoothctl", "disconnect", mac], 20)
        if res.returncode != 0:
            raise self._bluetooth_error(res, "disconnect_failed")
        time.sleep(0.5)
        return self.list_devices()

    @staticmethod
    def _bluetooth_error(res, default_code):
        """Build the error of a failed bluetoothctl call.

        The message of bluetoothctl is technical and in English, but it is
        not a sentence of the plugin: it travels as the detail of a stable
        code, so the panel can show its own text.
        """
        msg = (res.stderr or res.stdout or "").strip() or "bluetoothctl failed"
        lowered = msg.lower()
        if "not found" in lowered or "no such device" in lowered:
            code = "not_found"
        else:
            code = default_code
        return UserError(msg, code=code, detail=msg)

    @staticmethod
    def _close_previous_link(previous):
        """Close the previous link when replacing it.

        If its socket is left open, the descriptor leaks on every reconnect
        and the RFCOMM channel can stay busy, which is what prevents
        reconnecting.
        """
        if previous is None:
            return
        try:
            previous.close()
        except Exception:
            pass

    def _new_link(self, mac):
        """Create the RFCOMM link with its notifications wired up.

        The disconnect notification is what lets the state stop saying
        'connected' as soon as the link dies, without waiting for the next
        poll.
        """
        link = BudsLink(mac, self.log)
        link.on_frame = self.on_frame
        link.on_disconnect = self._on_link_disconnect
        return link

    def _on_link_disconnect(self, reason):
        """The RFCOMM link has gone down: the state reflects it now."""
        try:
            with self.lock:
                self.state["connected"] = False
            self._set_error("link_lost", str(reason) if reason else "")
            self.save()
        except Exception as exc:
            self.log("Could not update the state after the disconnect: %s" % exc)

    def connect(self, force_bt=False, user=False, reactivate=False):
        """Open the RFCOMM link.

        The monitor thread and the RPC thread can ask for a connection at the
        same time. Without a lock both open the channel and the second one
        fails with "busy", reporting a failure for a link that is already
        working. The lock makes the second one wait and see the link that
        the first one opened.

        With 'reactivate' the Bluetooth link is re-established when the
        serial channel is refused: only an explicit user action asks for
        that, because it interrupts the audio for a moment.
        """
        with self._connect_lock:
            return self._connect(
                force_bt=force_bt, user=user, reactivate=reactivate
            )

    def _reactivate_bluetooth(self, mac):
        """Re-establish the Bluetooth link so BlueZ activates the channel.

        After the serial channel has been closed the earbuds refuse new
        RFCOMM connections ("Connection refused") until the Bluetooth link
        itself is re-established. Only the explicit reconnect uses it.
        """
        self.log("Reactivating the Bluetooth link with %s" % mac)
        run(["bluetoothctl", "disconnect", mac], 20)
        time.sleep(1.0)
        run(["bluetoothctl", "connect", mac], 20)
        deadline = time.time() + 12
        info = bt_info(mac)
        while not info.get("connected") and time.time() < deadline:
            time.sleep(0.5)
            info = bt_info(mac)
        if not info.get("connected"):
            self.log("The device did not come back over Bluetooth")
            return False
        # BlueZ needs a moment to activate the serial channel.
        time.sleep(1.0)
        return True

    def _open_link(self, mac, reactivate=False):
        """Open the serial channel, reactivating Bluetooth when asked."""
        link = self._new_link(mac)
        try:
            link.open()
            return link
        except Exception as exc:
            if not reactivate:
                raise
            self.log("The serial channel was refused (%s)" % exc)
            if not self._reactivate_bluetooth(mac):
                raise
            link = self._new_link(mac)
            link.open()
            return link

    def _connect(self, force_bt=False, user=False, reactivate=False):
        now = time.time()
        if self.link and self.link.connected:
            return True
        if not user and now - self.last_connect_attempt < self.connect_backoff:
            return False
        self.last_connect_attempt = now
        if user:
            # A manual click must not be blocked by the backoff the monitor
            # uses to avoid hammering RFCOMM every 3 s.
            self.connect_backoff = 5.0
        else:
            self.connect_backoff = min(30.0, self.connect_backoff + 5.0)
        try:
            info = pick_device(self.preferred_mac, self.preferred_name)
        except Exception:
            info = None
        if info is None:
            self.log("No paired Nothing/CMF device")
            self._set_error("not_paired")
            with self.lock:
                self.state["connected"] = False
            self.save()
            return False
        mac = info["mac"]
        with self.lock:
            self.state["device"]["mac"] = mac
            self.state["device"]["name"] = info.get("name") or self.state["device"]["name"]
            self.state["device"]["alias"] = info.get("alias") or self.state["device"]["name"]
            self.state["audio_connected"] = bool(info.get("connected"))
            if info.get("battery") is not None:
                self.state["battery"]["bluez"] = info["battery"]
                if self.state["battery"]["left"] is None:
                    self.state["battery"]["left"] = info["battery"]
            model = model_from_name(self.state["device"]["name"]) or self.state.get("model") or "B172"
            self.state["device"]["model"] = model
            self.state["model"] = model
        if not info.get("connected"):
            if force_bt:
                self.log(f"Connecting Bluetooth to {mac}")
                res = run(["bluetoothctl", "connect", mac], 20)
                # bluetoothctl can return before BlueZ marks the device as
                # connected; wait a little and check again.
                deadline = time.time() + 12
                info = bt_info(mac)
                while not info.get("connected") and time.time() < deadline:
                    time.sleep(0.5)
                    info = bt_info(mac)
                if not info.get("connected"):
                    detail = (res.stderr or res.stdout or "").strip()
                    if detail:
                        detail = detail.splitlines()[-1]
                    else:
                        detail = "timed out"
                    self.log(f"Bluetooth connect failed: {detail}")
                    self._set_error("connect_failed", detail)
                    with self.lock:
                        self.state["connected"] = False
                    self.save()
                    return False
                with self.lock:
                    self.state["audio_connected"] = True
            else:
                self._set_error("disconnected")
                with self.lock:
                    self.state["connected"] = False
                self.save()
                return False
        try:
            link = self._open_link(mac, reactivate=reactivate)
            # The swap happens under the lock: the monitor thread and an RPC
            # thread can connect at the same time, and the old socket has to
            # be closed exactly once.
            with self._link_lock:
                previous = self.link
                self.link = link
                self._close_previous_link(previous)
            with self.lock:
                self.state["connected"] = True
            self._clear_error()
            self.log("Link ready")
            self.query_all()
            return True
        except Exception as exc:
            self.log(f"connect: {exc}")
            with self.lock:
                # The link may have been opened by another thread while this
                # one was failing: the state must not say "disconnected" if
                # there is a working link.
                if not (self.link and self.link.connected):
                    self.state["connected"] = False
            msg = str(exc)
            if "busy" in msg.lower() or "device or resource busy" in msg.lower():
                self._set_error("channel_busy")
            else:
                self._set_error("connect_failed", msg)
            self.save()
            return False

    def disconnect(self):
        # The link is taken out of the daemon before closing it: two threads
        # disconnecting at the same time must not close the same socket twice.
        with self._link_lock:
            link = self.link
            self.link = None
            if link:
                link.close()
        with self.lock:
            self.state["connected"] = False
        self.save()

    # -- parsing --------------------------------------------------------------
    def on_frame(self, cmd, payload):
        changed = False
        with self.lock:
            st = self.state
            if cmd in (CMD_BATTERY_GET, NTFY_BATTERY):
                if len(payload) >= 3:
                    count = payload[0]
                    for i in range(1, 1 + count * 2, 2):
                        if i + 1 >= len(payload):
                            break
                        btype, bval = payload[i], payload[i + 1]
                        pct = bval & 0x7F
                        charging = bool(bval & 0x80)
                        key = {BATTERY_LEFT: "left", BATTERY_RIGHT: "right", BATTERY_CASE: "case"}.get(btype)
                        if btype == BATTERY_STEREO:
                            st["battery"]["left"] = pct
                            st["battery"]["right"] = pct
                            changed = True
                        elif key:
                            st["battery"][key] = pct
                            st["battery"]["charging"][key] = charging
                            changed = True
            elif cmd in (CMD_ANC_GET, NTFY_ANC):
                # payload: triplets (type, value, pad)
                for i in range(0, len(payload) - 1, 3):
                    t, val = payload[i], payload[i + 1]
                    if t == 1:
                        if val == ANC_TRANSPARENCY:
                            st["anc"]["mode"] = "transparency"
                        elif val in (ANC_OFF, 0):
                            st["anc"]["mode"] = "off"
                        elif 1 <= val <= 4:
                            st["anc"]["mode"] = "anc"
                            st["anc"]["level"] = ANC_LEVEL_NAMES.get(val, "high")
                        changed = True
                    elif t == 2 and 1 <= val <= 4:
                        st["anc"]["level"] = ANC_LEVEL_NAMES.get(val, st["anc"]["level"])
                        changed = True
            elif cmd == CMD_LISTENING_MODE_GET:
                if payload:
                    idx = payload[0]
                    name = LISTENING_MODE_NAMES.get(idx)
                    if name:
                        st["eq"]["preset"] = name
                        st["eq"]["preset_index"] = idx
                        st["eq"]["kind"] = "listening"
                        changed = True
            elif cmd == CMD_EQ_GET:
                if payload:
                    idx = payload[0]
                    names = {0: "balanced", 1: "more_bass", 2: "more_treble", 3: "voice"}
                    st["eq"]["preset"] = names.get(idx, "balanced")
                    st["eq"]["preset_index"] = idx
                    st["eq"]["kind"] = "classic"
                    changed = True
            elif cmd == CMD_CUSTOM_EQ_GET:
                if len(payload) >= 36:
                    gains = [eq_float_decode(payload[o : o + 4]) for o in CUSTOM_EQ_GAIN_OFFSETS]
                    mid, treble, bass = gains
                    st["eq"]["custom"] = {
                        "bass": max(-6, min(6, round(bass))),
                        "mid": max(-6, min(6, round(mid))),
                        "treble": max(-6, min(6, round(treble))),
                    }
                    changed = True
            elif cmd == CMD_BASS_GET:
                if len(payload) >= 2:
                    st["bass"]["enabled"] = payload[0] == 1
                    st["bass"]["level"] = max(1, min(5, round(payload[1] / 2)))
                    changed = True
            elif cmd == CMD_SPATIAL_GET:
                if payload:
                    st["spatial"] = payload[0] == 1
                    changed = True
            elif cmd == CMD_IN_EAR_GET:
                if len(payload) >= 3:
                    # BudsLink uses payload[2] for the fit setting.
                    st["in_ear"] = payload[2] == 1
                    changed = True
            elif cmd == CMD_LATENCY_GET:
                if payload:
                    st["low_latency"] = payload[0] == 1
                    changed = True
            elif cmd == CMD_DUAL_GET:
                if payload:
                    st["dual_connection"] = payload[0] == 1
                    changed = True
            elif cmd == CMD_GESTURES_GET:
                if payload:
                    count = payload[0]
                    gestures = {}
                    off = 1
                    for _ in range(count):
                        if off + 3 >= len(payload):
                            break
                        dev, btn, typ, action = payload[off : off + 4]
                        # The case sends two groups: 04/01 is the dial
                        # (single, double, triple, hold, rotate) and 04/09 is
                        # an internal button the app does not expose. We skip
                        # the second one so it does not overwrite dial gestures.
                        if dev == 0x04 and btn != 0x01:
                            off += 4
                            continue
                        group = {0x02: "left", 0x03: "right", 0x04: "case"}.get(dev, "case")
                        tname = {
                            0x01: "single", 0x02: "double", 0x03: "triple",
                            0x07: "hold", 0x09: "double_hold", 0x0A: "rotate",
                        }.get(typ)
                        aname = GESTURE_ACTION_NAMES.get(action)
                        if tname and aname:
                            gestures[f"{group}.{tname}"] = aname
                        off += 4
                    st["gestures"] = gestures
                    changed = True
            elif cmd == CMD_FIRMWARE_GET:
                txt = payload.decode("utf-8", "replace").strip("\x00 \n")
                if txt:
                    st["device"]["firmware"] = txt
                    changed = True
            elif cmd == CMD_SERIAL_GET:
                raw = payload.decode("utf-8", "replace").strip("\x00")
                for line in raw.splitlines():
                    parts = line.split(",", 2)
                    if len(parts) == 3 and parts[1] == "4" and parts[2].strip():
                        st["device"]["serial"] = parts[2].strip()
                        # Only use the serial if the name did not already identify the model.
                        if not model_from_name(st["device"].get("name")):
                            model = model_from_serial(parts[2].strip())
                            if model:
                                st["device"]["model"] = model
                                st["model"] = model
                        changed = True
                        break
            elif cmd == CMD_MODEL_GET:
                if len(payload) >= 2:
                    mid = payload[0] | (payload[1] << 8)
                    st["device"]["model"] = f"{mid:04X}" if mid else st["device"]["model"]
                    changed = True
            elif cmd == CMD_FIT_TEST_NTFY:
                if len(payload) >= 2:
                    st["fit_test"]["left"] = payload[0]
                    st["fit_test"]["right"] = payload[1]
                    st["fit_test"]["running"] = False
                    st["fit_test"]["error"] = ""
                    self.fit_started = 0.0
                    changed = True
            elif cmd == CMD_ANC_SET:
                # ACK for the set; the 0xE003 event arrives later
                pass
        if changed:
            self.save()

    # -- commands ------------------------------------------------------------
    def query_all(self):
        if not self.link or not self.link.connected:
            return False
        cmds = [
            (CMD_BATTERY_GET, b""),
            (CMD_ANC_GET, b"\x03"),
            (CMD_LISTENING_MODE_GET, b""),
            (CMD_CUSTOM_EQ_GET, b""),
            (CMD_BASS_GET, b""),
            (CMD_SPATIAL_GET, b""),
            (CMD_IN_EAR_GET, b""),
            (CMD_LATENCY_GET, b""),
            (CMD_DUAL_GET, b""),
            (CMD_GESTURES_GET, b""),
            (CMD_FIRMWARE_GET, b""),
            (CMD_SERIAL_GET, b""),
        ]
        error = ""
        timed_out = 0
        for cmd, payload in cmds:
            try:
                self.link.request(cmd, payload, timeout=1.2)
            except TimeoutError:
                timed_out += 1
                self.log(f"Timeout querying 0x{cmd:04X}")
            except Exception as exc:
                self.log(f"query 0x{cmd:04X}: {exc}")
                error = str(exc)
                break
            time.sleep(0.04)
        with self.lock:
            connected = bool(self.link and self.link.connected)
            self.state["connected"] = connected
        if connected and timed_out == 0:
            self._clear_error()
        elif error:
            # The link is down: keep the error so the panel shows the problem
            # instead of a false "connected" state.
            self._set_error("link_lost", error)
        elif timed_out:
            # The link answered but not to everything: the query did not
            # finish, and the panel has to know about it.
            detail = "%d of %d commands timed out" % (timed_out, len(cmds))
            if timed_out == len(cmds):
                self._set_error("link_lost", detail)
            else:
                self._set_error("daemon_failed", detail)
        self.last_full = time.time()
        self.refresh_volume()
        self.save()
        # A query that did not finish is not a success: the caller (the
        # refresh of the panel) has to report it.
        return connected and timed_out == 0 and not error

    @staticmethod
    def _check_anc(mode: str, level: str | None = None):
        """Validate the ANC mode and level and return the value to send."""
        if mode == "off":
            return ANC_OFF
        if mode == "transparency":
            return ANC_TRANSPARENCY
        if mode == "anc":
            lvl = level or "high"
            if lvl not in ANC_LEVELS:
                # Before, it silently fell back to "strong" and the state
                # kept the invalid level: the panel and the device ended up
                # disagreeing.
                raise UserError("invalid ANC level", code="invalid_anc")
            return ANC_LEVELS[lvl]
        raise UserError("invalid ANC level", code="invalid_anc")

    def set_anc(self, mode: str, level: str | None = None):
        val = self._check_anc(mode, level)
        link = self._require_link()
        link.send(CMD_ANC_SET, bytes([0x01, val, 0x00]), 1.2)
        with self.lock:
            self.state["anc"]["mode"] = mode
            if mode == "anc" and level:
                self.state["anc"]["level"] = level
        # The ANC GET takes a moment to reflect the change; querying it right
        # away returns the previous mode and overwrites the optimistic state.
        # The 0xE003 event arrives on its own and updates the real state.
        self.save()
        return self.snapshot()

    def set_eq(self, preset: str):
        if preset not in LISTENING_MODES:
            raise UserError("invalid preset", code="invalid_preset")
        link = self._require_link()
        idx = LISTENING_MODES[preset]
        link.send(CMD_LISTENING_MODE_SET, bytes([idx, 0x00]), 1.2)
        with self.lock:
            self.state["eq"]["preset"] = preset
            self.state["eq"]["preset_index"] = idx
        time.sleep(0.2)
        try:
            link.request(CMD_CUSTOM_EQ_GET, b"", 1.0)
        except Exception:
            pass
        self.save()
        return self.snapshot()

    def set_custom_eq(self, bass: int, mid: int, treble: int):
        link = self._require_link()
        bass, mid, treble = (max(-6, min(6, int(v))) for v in (bass, mid, treble))
        gains = (mid, treble, bass)
        buf = bytearray(CUSTOM_EQ_TEMPLATE)
        buf[1:5] = eq_float_encode(-max(gains), preamp=True)
        for off, gain in zip(CUSTOM_EQ_GAIN_OFFSETS, gains):
            buf[off : off + 4] = eq_float_encode(float(gain))
        link.send(CMD_CUSTOM_EQ_SET, bytes(buf), 1.4)
        # The app writes the curve and then enables "Custom" mode; otherwise
        # the firmware stores the values but the current preset keeps playing.
        link.send(CMD_LISTENING_MODE_SET, bytes([LISTENING_MODES["custom"], 0x00]), 1.2)
        with self.lock:
            self.state["eq"]["custom"] = {"bass": bass, "mid": mid, "treble": treble}
            self.state["eq"]["preset"] = "custom"
            self.state["eq"]["preset_index"] = LISTENING_MODES["custom"]
        self.save()
        return self.snapshot()

    def set_bass(self, enabled: bool, level: int | None = None):
        link = self._require_link()
        level = max(1, min(5, int(level if level is not None else self.state["bass"]["level"])))
        link.send(CMD_BASS_SET, bytes([1 if enabled else 0, level * 2]), 1.2)
        with self.lock:
            self.state["bass"]["enabled"] = bool(enabled)
            self.state["bass"]["level"] = level
        self.save()
        return self.snapshot()

    def set_toggle(self, key: str, value: bool):
        # The key is checked before the link: otherwise the error would be
        # "the earbuds are not connected" instead of "that setting does not
        # exist", and the user could not tell what was wrong.
        if key not in ("spatial", "in_ear", "low_latency", "dual_connection"):
            raise UserError("unknown setting", code="unknown_setting")
        link = self._require_link()
        if key == "spatial":
            link.send(CMD_SPATIAL_SET, bytes([1 if value else 0]), 1.2)
        elif key == "in_ear":
            link.send(CMD_IN_EAR_SET, bytes([0x01, 0x01, 1 if value else 0]), 1.2)
        elif key == "low_latency":
            link.send(CMD_LATENCY_SET, bytes([0x01 if value else 0x02, 0x00]), 1.2)
        else:
            link.send(CMD_DUAL_SET, bytes([1 if value else 0]), 1.2)
        with self.lock:
            self.state[key] = bool(value)
            if key == "dual_connection":
                # The Nothing X app warns that the change does not apply until
                # the earbuds restart; it is remembered in the state so the
                # panel shows it until the user restarts them.
                self.state["dual_restart_pending"] = True
        time.sleep(0.15)
        self.save()
        return self.snapshot()

    @staticmethod
    def _check_gesture(group: str, gesture_type: str, action: str):
        """Check that the gesture exists and that the action is allowed on it.

        Without this check, an action the gesture does not support was sent
        anyway and the device ignored it silently.
        """
        key = (group, gesture_type)
        if key not in GESTURE_BY_KEY:
            raise UserError("invalid gesture", code="invalid_gesture")
        if action not in GESTURE_ACTIONS:
            raise UserError("invalid action", code="invalid_action")
        allowed_actions = GESTURE_ALLOWED.get(key)
        if allowed_actions is None:
            raise UserError("invalid gesture", code="invalid_gesture")
        if action not in allowed_actions:
            raise UserError(
                "this action is not available for that gesture",
                code="action_not_available",
            )

    def set_gesture(self, group: str, gesture_type: str, action: str):
        # The combination is checked before the link: otherwise the error
        # would be "no link" instead of "that action is not valid for that gesture".
        self._check_gesture(group, gesture_type, action)
        link = self._require_link()
        key = (group, gesture_type)
        device, typ = GESTURE_BY_KEY[key]
        link.send(CMD_GESTURES_SET, bytes([0x01, device, 0x01, typ, GESTURE_ACTIONS[action]]), 1.2)
        with self.lock:
            self.state["gestures"][f"{group}.{gesture_type}"] = action
        self.save()
        return self.snapshot()

    @staticmethod
    def _check_side(side: str):
        """Check the earbud side and return its code.

        Before, any side other than "left" silently became "right" (and it
        also stored a made-up key in the state).
        """
        if side == "left":
            return 0x02
        if side == "right":
            return 0x03
        raise UserError("invalid side", code="invalid_side")

    def ring(self, side: str, enabled: bool):
        device = self._check_side(side)
        link = self._require_link()
        link.send(CMD_RING_SET, bytes([device, 1 if enabled else 0]), 1.2)
        with self.lock:
            self.state["ring"][side] = bool(enabled)
            self.ring_until[side] = time.time() + 15 if enabled else 0
        self.save()
        return self.snapshot()

    def fit_test(self, start: bool):
        link = self._require_link()
        link.send(CMD_FIT_TEST_SET, bytes([1 if start else 0]), 1.2)
        with self.lock:
            self.state["fit_test"]["running"] = bool(start)
            self.state["fit_test"]["error"] = ""
            if start:
                self.state["fit_test"]["left"] = None
                self.state["fit_test"]["right"] = None
        self.fit_started = time.time() if start else 0.0
        self.save()
        return self.snapshot()

    def _stop_rings(self, now):
        """Turn off the rings that have reached their time.

        If one cannot be turned off it is not marked as off: it is retried on
        the next cycle (before, it was marked off anyway and the ring kept
        ringing with nobody trying again).
        """
        for side, until in list(self.ring_until.items()):
            if until and now >= until:
                try:
                    self.ring(side, False)
                except Exception:
                    continue
                self.ring_until[side] = 0

    def _require_link(self):
        """Return the RFCOMM link, or fail if there is none.

        The link is returned so the caller does not read self.link again: a
        disconnect in between would leave the caller with None and the
        command would end with an AttributeError instead of an error the
        user can understand.
        """
        with self._link_lock:
            link = self.link
            if not link or not link.connected:
                raise UserError(
                    "the earbuds are not connected over RFCOMM", code="not_connected"
                )
            return link

    # -- errors ------------------------------------------------------------
    def _set_error(self, code, detail=""):
        """Record an error in the state as a stable code.

        The panel translates the code (the "error.code.<code>" keys of the
        plugin translations) and appends the technical detail, so the daemon
        never sends a sentence in a fixed language.
        """
        if code not in ERROR_CODES:
            raise ValueError("unknown error code: %s" % code)
        with self.lock:
            self.state["error"] = code
            self.state["error_detail"] = detail

    def _clear_error(self):
        with self.lock:
            self.state["error"] = ""
            self.state["error_detail"] = ""

    def _rpc_error(self, exc):
        """Response and log entry for an RPC error.

        Expected errors (an action that cannot be done now, or a request
        with a wrong value) are logged as one line; unexpected ones with
        their traceback, because they hide a real bug.

        The answer carries the stable code the panel translates and, when
        there is one, the technical detail of the failure.
        """
        if isinstance(exc, (UserError, ValueError)):
            self.log("rpc: %s" % exc)
        else:
            self.log("rpc: " + traceback.format_exc())
        code = getattr(exc, "code", "") or ""
        detail = getattr(exc, "detail", "") or ""
        if not code:
            detail = detail or str(exc)
            if isinstance(exc, ValueError):
                # A plain ValueError comes from a request the daemon cannot
                # use (a wrong value, a broken payload): the client has to
                # fix it, not the daemon.
                code = "invalid_request"
            else:
                # An unexpected failure: the panel shows a generic message
                # and the detail (the text of the exception) tells what
                # happened.
                code = "daemon_failed"
        return {
            "ok": False,
            "error": code,
            "error_detail": detail,
            "state": self.snapshot(),
        }

    # -- volume -------------------------------------------------------------
    SINK_CACHE_TTL = 2.0
    VOLUME_CACHE_TTL = 2.0

    def _buds_sink(self):
        """Bluetooth sink of the earbuds, or "" if they are not connected.

        It does not fall back to the default sink: the shortcut engine should
        only watch the earbuds volume, not the system one.
        """
        mac = self.state["device"].get("mac", "").replace(":", "_")
        if not mac:
            return ""
        res = run(["pactl", "list", "sinks", "short"], 6)
        for line in (res.stdout or "").splitlines():
            parts = line.split("\t")
            if len(parts) >= 2 and f"bluez_output.{mac}" in parts[1]:
                return parts[1]
        return ""

    def _sink(self, force=False):
        """Current audio sink.

        With the panel open the state is polled every 500 ms: without a cache
        every poll made four pactl calls (list sinks, get-default-sink,
        get-sink-volume and get-sink-mute). The sink almost never changes, so
        it is cached for a couple of seconds; writes force a refresh so they
        do not target a sink that no longer exists.
        """
        now = time.time()
        cache = getattr(self, "_sink_cache", None)
        if not force and cache is not None and now - cache[0] < self.SINK_CACHE_TTL:
            return cache[1]
        sink = self._buds_sink()
        if not sink:
            res = run(["pactl", "list", "sinks", "short"], 6)
            sinks = []
            for line in (res.stdout or "").splitlines():
                parts = line.split("\t")
                if len(parts) >= 2:
                    sinks.append(parts[1])
            res = run(["pactl", "get-default-sink"], 5)
            sink = (res.stdout or "").strip() or (sinks[0] if sinks else "")
        self._sink_cache = (now, sink)
        return sink

    def refresh_volume(self, force=False):
        """Read the volume, the mute state and the description of the sink.

        The panel asks for the status twice a second: without a cache every
        poll started two pactl processes (and the CPU and the battery paid
        for it). The values are kept for a couple of seconds; the changes of
        the earbuds arrive at once, through the 'pactl subscribe' watcher of
        the shortcut engine, so the cache does not hide them.
        """
        sink = self._sink()
        now = time.time()
        cache = getattr(self, "_volume_cache", None)
        if (
            not force
            and cache is not None
            and cache[0] == sink
            and now - cache[1] < self.VOLUME_CACHE_TTL
        ):
            with self.lock:
                self.state["volume"] = {
                    "percent": cache[2],
                    "muted": cache[3],
                    "sink": sink,
                    "description": cache[4],
                }
                volume = dict(self.state["volume"])
            return volume
        pct = None
        muted = False
        desc = ""
        if sink:
            res = run(["pactl", "get-sink-volume", sink], 6)
            for tok in (res.stdout or "").split():
                if tok.endswith("%"):
                    try:
                        pct = int(tok.rstrip("%"))
                        break
                    except ValueError:
                        pass
            res = run(["pactl", "get-sink-mute", sink], 6)
            muted = "yes" in (res.stdout or "").lower()
            # The sink description does not change: it is only re-read when
            # the sink changes (or when there is none yet).
            desc_cache = getattr(self, "_sink_desc", None)
            if desc_cache is not None and desc_cache[0] == sink:
                desc = desc_cache[1]
            else:
                res = run(["pactl", "list", "sinks"], 6)
                current = None
                for line in (res.stdout or "").splitlines():
                    line = line.strip()
                    if line.startswith("Name:"):
                        current = line.split(":", 1)[1].strip()
                    elif line.startswith("Description:") and current == sink:
                        desc = line.split(":", 1)[1].strip()
                        break
                self._sink_desc = (sink, desc)
        self._volume_cache = (sink, now, pct, muted, desc)
        with self.lock:
            self.state["volume"] = {"percent": pct, "muted": muted, "sink": sink, "description": desc}
            volume = dict(self.state["volume"])
        return volume

    def set_volume(self, percent: int | None = None, mute: str | None = None):
        # The volume writes are serialized: every RPC runs in its own thread
        # and two writes at the same time (the wheel of the widget sends one
        # request per event) would end up in an order the user did not ask
        # for: the last one to reach pactl wins, not the last one asked for.
        with self._volume_lock:
            # force=True: when writing, a cached sink is not good enough (it
            # may have changed just now).
            sink = self._sink(force=True)
            if not sink:
                raise UserError("no audio sink", code="no_sink")
            pct = None
            if percent is not None:
                pct = max(0, min(150, int(percent)))
                res = run(["pactl", "set-sink-volume", sink, f"{pct}%"], 6)
                if res.returncode != 0:
                    # The volume did not change: the engine must not be told
                    # about a change that did not happen.
                    raise UserError(
                        "could not set the volume",
                        code="daemon_failed",
                        detail=(res.stderr or res.stdout or "").strip() or "pactl failed",
                    )
                if self.local is not None:
                    # Mark the value we set (already clamped): the engine uses it
                    # to tell our changes apart from the earbud gestures. If the
                    # unclamped value were marked, it would not match the real
                    # volume and the engine would think the change is a user
                    # gesture.
                    self.local.note_self_change(pct)
            mute_res = None
            if mute == "toggle":
                mute_res = run(["pactl", "set-sink-mute", sink, "toggle"], 6)
            elif mute in ("on", "off"):
                mute_res = run(["pactl", "set-sink-mute", sink, "1" if mute == "on" else "0"], 6)
            if mute_res is not None and mute_res.returncode != 0:
                raise UserError(
                    "could not change the mute state",
                    code="daemon_failed",
                    detail=(mute_res.stderr or mute_res.stdout or "").strip() or "pactl failed",
                )
            self.refresh_volume(force=True)
            self.save()
            return self.snapshot()

    # -- main loop ------------------------------------------------------
    def monitor(self):
        while not self.stop_event.is_set():
            now = time.time()
            try:
                if self.link is None or not self.link.connected:
                    self.connect()
                else:
                    if now - self.last_full >= self.poll:
                        self.query_all()
                    else:
                        # Volume is also refreshed between polls: changes made
                        # from the phone do not always produce an RFCOMM
                        # notification. Every 5 s is enough (pactl is costly)
                        # and the volume watcher already publishes changes
                        # instantly.
                        if not hasattr(self, "_last_volume_check"):
                            self._last_volume_check = 0
                        if now - self._last_volume_check >= 5:
                            self._last_volume_check = now
                            self.refresh_volume()
                # A fit test that never returns a result (earbud badly seated,
                # firmware that does not notify): close it with a warning
                # instead of staying "measuring" forever.
                if self.state["fit_test"].get("running") and self.fit_started:
                    if now - self.fit_started > 30:
                        with self.lock:
                            self.state["fit_test"]["running"] = False
                            self.state["fit_test"]["error"] = "timeout"
                        self.fit_started = 0.0
                        self.log("Fit test without a response: cancelling")
                        self.save()
                # turn the rings off automatically
                self._stop_rings(now)
                if self.link is None or not self.link.connected:
                    self.refresh_volume()
                    self.save()
            except Exception as exc:
                self.log("monitor: " + traceback.format_exc())
                self._set_error("daemon_failed", str(exc))
                self.save()
            if now - self.last_client > self.idle_timeout:
                self.log("No clients; shutting down the daemon")
                # The whole daemon goes down, not only the monitor thread:
                # the RPC server would keep answering with a stale state.
                self.shutdown()
                break
            self.stop_event.wait(1.0 if (self.link and self.link.connected) else 3.0)

    # -- RPC -----------------------------------------------------------------
    def handle_rpc(self, req):
        cmd = (req or {}).get("cmd", "status")
        self.last_client = time.time()
        if cmd == "ping":
            return {"ok": True, "state": self.snapshot()}
        if cmd == "configure":
            # The plugin settings (poll, name and MAC) also reach an already
            # running daemon: before, they were only applied when creating it.
            # The service sends them on every round, so the daemon always runs
            # with the user's configuration (when the plugin reloads, the
            # daemon starts with the default values).
            changes = []
            poll = req.get("poll")
            if poll is not None:
                # clamp_poll() never raises: an invalid value falls back to
                # the default.
                new_poll = clamp_poll(poll)
                if new_poll != self.poll:
                    changes.append("poll every %d s" % new_poll)
                self.poll = new_poll
            if req.get("device_mac") is not None:
                mac = str(req.get("device_mac") or "").strip()
                if mac != self.preferred_mac:
                    changes.append("MAC %s" % (mac or "(none)"))
                self.preferred_mac = mac
            if req.get("device_name") is not None:
                device_name = str(req.get("device_name") or "").strip()
                if device_name != self.preferred_name:
                    changes.append("device %s" % (device_name or "(any)"))
                self.preferred_name = device_name
            if changes:
                self.log("Configuration applied: " + ", ".join(changes))
            return {"ok": True, "state": self.snapshot()}
        if cmd == "devices":
            return {"ok": True, "state": self.snapshot(), "devices": self.list_devices()}
        if cmd == "device_connect":
            devices = self.device_connect(req.get("mac", ""))
            return {"ok": True, "state": self.snapshot(), "devices": devices}
        if cmd == "device_disconnect":
            devices = self.device_disconnect(req.get("mac", ""))
            return {"ok": True, "state": self.snapshot(), "devices": devices}
        if cmd == "dual_ack":
            with self.lock:
                self.state["dual_restart_pending"] = False
            self.save()
            return {"ok": True, "state": self.snapshot()}
        if cmd == "status":
            self.refresh_volume()
            return {"ok": True, "state": self.snapshot()}
        if cmd == "refresh":
            if self.link and self.link.connected:
                ok = self.query_all()
            else:
                # user=True: the refresh is a manual action, it must not be
                # blocked by the backoff of the automatic reconnections.
                ok = self.connect(force_bt=True, user=True)
            # The real result is reported: before, the panel always cleared
            # the error message even when the earbuds were not reachable.
            with self.lock:
                error = "" if ok else self.state.get("error", "")
                error_detail = "" if ok else self.state.get("error_detail", "")
            return {
                "ok": bool(ok),
                "error": error,
                "error_detail": error_detail,
                "state": self.snapshot(),
            }
        if cmd == "connect":
            ok = self.connect(force_bt=True, user=True)
            state = self.snapshot()
            return {
                "ok": ok,
                "error": "" if ok else state.get("error", ""),
                "error_detail": "" if ok else state.get("error_detail", ""),
                "state": state,
            }
        if cmd == "reconnect":
            # The link is closed and opened again: the connect command
            # does nothing when the link is alive, and a half-open link
            # can only be recovered this way. The Bluetooth link is
            # re-established too when the serial channel is refused.
            self.disconnect()
            ok = self.connect(force_bt=True, user=True, reactivate=True)
            state = self.snapshot()
            return {
                "ok": bool(ok),
                "error": "" if ok else state.get("error", ""),
                "error_detail": "" if ok else state.get("error_detail", ""),
                "state": state,
            }
        if cmd == "anc":
            return {"ok": True, "state": self.set_anc(req.get("mode", "anc"), req.get("level"))}
        if cmd == "eq":
            return {"ok": True, "state": self.set_eq(req.get("preset", "balanced"))}
        if cmd == "custom_eq":
            return {"ok": True, "state": self.set_custom_eq(req.get("bass", 0), req.get("mid", 0), req.get("treble", 0))}
        if cmd == "bass":
            return {"ok": True, "state": self.set_bass(bool(req.get("enabled", False)), req.get("level"))}
        if cmd == "toggle":
            return {"ok": True, "state": self.set_toggle(req.get("key", ""), bool(req.get("value", False)))}
        if cmd == "gesture":
            return {"ok": True, "state": self.set_gesture(req.get("group", "left"), req.get("gesture", "double"), req.get("action", "no_action"))}
        if cmd == "ring":
            return {"ok": True, "state": self.ring(req.get("side", "left"), bool(req.get("on", True)))}
        if cmd == "fit_test":
            return {"ok": True, "state": self.fit_test(bool(req.get("start", True)))}
        if cmd == "volume":
            return {"ok": True, "state": self.set_volume(req.get("percent"), req.get("mute"))}
        if cmd == "local_rules":
            return {"ok": True, "state": self.snapshot(), "local_actions": self._local_snapshot()}
        if cmd == "local_rule_set":
            if self.local is None:
                raise UserError(
                    "the local action engine is not available",
                    code="engine_unavailable",
                )
            rule = req.get("rule") or {}
            if not isinstance(rule, dict):
                raise UserError("a rule must be an object", code="invalid_rule")
            try:
                saved = self.local.upsert(dict(rule))
            except ValueError as exc:
                raise UserError(str(exc), code="invalid_rule") from exc
            return {"ok": True, "state": self.snapshot(), "local_actions": self._local_snapshot(), "rule": saved}
        if cmd == "local_rule_delete":
            if self.local is None:
                raise UserError(
                    "the local action engine is not available",
                    code="engine_unavailable",
                )
            self.local.delete(req.get("id", ""))
            return {"ok": True, "state": self.snapshot(), "local_actions": self._local_snapshot()}
        if cmd == "local_test":
            if self.local is None:
                raise UserError(
                    "the local action engine is not available",
                    code="engine_unavailable",
                )
            command = (req.get("command") or "").strip()
            if not command:
                raise UserError("missing command", code="missing_command")
            # The details tell what happened: the panel shows the exit status
            # and the output of the command, so the user knows why it failed.
            details = {}
            ok = self.local.run_command(command, wait=True, details=details)
            response = {
                "ok": bool(ok),
                "state": self.snapshot(),
                "local_actions": self._local_snapshot(),
            }
            if not ok:
                detail = str(details.get("stderr") or details.get("stdout") or "").strip()
                if not detail:
                    detail = str(details.get("error") or "").strip()
                status = details.get("returncode")
                if status is None:
                    message = detail or "the command failed"
                elif detail:
                    message = "exit status %s: %s" % (status, detail)
                else:
                    message = "exit status %s" % status
                response["error"] = "command_failed"
                response["error_detail"] = message
            else:
                response["error"] = ""
                response["error_detail"] = ""
            return response
        if cmd == "shutdown":
            threading.Thread(target=self.shutdown, daemon=True).start()
            return {"ok": True, "state": self.snapshot()}
        raise UserError("unknown command", code="unknown_command")

    def snapshot(self):
        # The panel polls `status` twice a second and re-seeds its rule list from
        # `local_actions`: the cached copy in self.state only refreshes on the
        # monitor tick, so handing it back reverted every toggle the user had
        # just flipped. Take a fresh engine snapshot instead.
        # Lock order is engine -> daemon: the engine snapshot is taken before
        # the daemon lock, the same order the monitor loop uses.
        local_state = self._local_snapshot()
        with self.lock:
            state = json.loads(json.dumps(self.state))
        state["local_actions"] = local_state
        return state

    def _local_snapshot(self):
        # The fallback has the same shape as the engine snapshot: the panel
        # reads 'last_event' and 'last_action', so a different set of keys
        # would leave the panel without its last shortcut information.
        # A fresh dict every time: the panel may modify what it receives and
        # the next snapshot must not inherit those changes.
        if self.local is None:
            return self._empty_local_snapshot()
        try:
            return self.local.snapshot()
        except Exception as exc:
            self.log("local snapshot: %s" % exc)
            return self._empty_local_snapshot()

    @staticmethod
    def _empty_local_snapshot():
        return {
            "rules": [],
            "last_event": {},
            "last_action": {},
            "modifiers": [],
            "modifiers_available": False,
        }

    # -- lifecycle -------------------------------------------------------
    def shutdown(self):
        self.stop_event.set()
        self.disconnect()
        if self._server:
            try:
                self._server.shutdown()
            except Exception:
                pass

    def _load_previous_state(self):
        """Read the state of the previous run.

        The shortcut engine needs the device MAC from the start, so it does
        not wait for the RFCOMM link. A broken file (or a 'device' that is
        not an object) is ignored: the daemon starts with the default state
        instead of failing.
        """
        try:
            if not os.path.exists(self.state_path):
                return
            with open(self.state_path, "r", encoding="utf-8") as fh:
                saved = json.load(fh)
            if not isinstance(saved, dict):
                return
            device = saved.get("device")
            if isinstance(device, dict) and device:
                with self.lock:
                    self.state["device"] = device
        except Exception as exc:
            self.log("Could not read the previous state: %s" % exc)

    def run(self):
        os.makedirs(os.path.dirname(self.state_path), exist_ok=True)
        os.makedirs(os.path.dirname(self.socket_path), exist_ok=True)
        # Load the previous state: this way the shortcut engine knows the
        # device MAC from the start and does not wait for the RFCOMM link.
        self._load_previous_state()
        # exclusive lock
        lock_path = self.socket_path + ".lock"
        self._lock_file = open(lock_path, "a+")
        try:
            fcntl.flock(self._lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print(json.dumps({"ok": True, "already_running": True}))
            return 0
        try:
            if os.path.exists(self.socket_path):
                os.unlink(self.socket_path)
        except OSError:
            pass
        class Server(socketserver.ThreadingUnixStreamServer):
            allow_reuse_address = True
            daemon_threads = True

        self._server = Server(self.socket_path, RpcHandler)
        self._server.daemon = self
        try:
            os.chmod(self.socket_path, 0o600)
        except OSError:
            pass

        def on_sig(_signum, _frame):
            self.stop_event.set()
            threading.Thread(target=self._server.shutdown, daemon=True).start()

        import signal
        signal.signal(signal.SIGTERM, on_sig)
        signal.signal(signal.SIGINT, on_sig)

        self.log(f"Daemon started (pid {os.getpid()}, socket {self.socket_path})")
        threading.Thread(target=self.monitor, name="buds-monitor", daemon=True).start()
        if self.local is not None:
            try:
                self.local.start(self._buds_sink)
            except Exception as exc:
                self.log("Could not start the local action engine: %s" % exc)
        try:
            self._server.serve_forever(poll_interval=0.5)
        finally:
            self.stop_event.set()
            if self.local is not None:
                try:
                    self.local.stop()
                except Exception:
                    pass
            self.disconnect()
            try:
                self._server.server_close()
            except Exception:
                pass
            try:
                os.unlink(self.socket_path)
            except OSError:
                pass
            if self._lock_file:
                try:
                    fcntl.flock(self._lock_file.fileno(), fcntl.LOCK_UN)
                except OSError:
                    pass
            self.log("Daemon stopped")
        return 0


# ── CLI ───────────────────────────────────────────────────────────────────────


# The biggest answer the daemon may send. The state of the earbuds is a few
# kilobytes: a bigger answer means something is broken, and it must not be
# read into memory without a limit.
MAX_RESPONSE = 4 * 1024 * 1024


def default_paths():
    state_home = os.environ.get("NOCTALIA_STATE_HOME") or os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    data = os.path.join(state_home, "noctalia", "plugins", "data", "faminec", "cmf-buds")
    return {
        "state": os.path.join(data, "state.json"),
        "socket": os.path.join(data, "daemon.sock"),
        "log": os.path.join(data, "daemon.log"),
    }


def rpc_call(socket_path, req, timeout=RPC_TIMEOUT):
    """Send one RPC request and return the answer.

    The timeout has to be longer than a full query of the earbuds: the
    daemon answers 'refresh' only after every command has been sent (that
    takes about 15 s) and a reconnection can take a minute.
    """
    socket_path = os.path.abspath(os.path.expanduser(socket_path))
    # The socket is closed in every case: a failed call (the daemon is not
    # running, the answer is not JSON) leaked the file descriptor.
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(timeout)
        sock.connect(socket_path)
        sock.sendall((json.dumps(req, ensure_ascii=False) + "\n").encode("utf-8"))
        data = b""
        while b"\n" not in data:
            chunk = sock.recv(65536)
            if not chunk:
                break
            data += chunk
            if len(data) > MAX_RESPONSE:
                # A daemon that answers with megabytes is broken: the answer
                # is not read into memory without a limit.
                raise RuntimeError("the daemon answer is too large")
    return json.loads(data.decode("utf-8"))


def ensure_daemon(args, paths):
    socket_path = os.path.abspath(os.path.expanduser(args.socket or paths["socket"]))
    try:
        return rpc_call(socket_path, {"cmd": "ping"}, 1.0)
    except Exception:
        pass
    # start in the background
    cmd = [
        sys.executable,
        os.path.abspath(__file__),
        "daemon",
        "--state", os.path.abspath(os.path.expanduser(args.state or paths["state"])),
        "--socket", socket_path,
        "--log", os.path.abspath(os.path.expanduser(args.log or paths["log"])),
        "--poll", str(clamp_poll(getattr(args, "poll", POLL_DEFAULT))),
        "--idle-timeout", str(getattr(args, "idle_timeout", 300)),
        "--device-mac", getattr(args, "device_mac", "") or "",
        "--device-name", getattr(args, "device_name", "") or "",
    ]
    try:
        subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError as exc:
        raise RuntimeError(f"Could not start the daemon: {exc}")
    deadline = time.time() + 4
    last = None
    while time.time() < deadline:
        try:
            return rpc_call(socket_path, {"cmd": "ping"}, 1.0)
        except Exception as exc:
            last = exc
            time.sleep(0.2)
    raise RuntimeError(f"The daemon did not start: {last}")


def _lock_is_free(lock_path):
    """Whether nobody holds the lock of the daemon."""
    try:
        handle = open(lock_path, "a+")
    except OSError:
        return False
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        return True
    except OSError:
        return False
    finally:
        try:
            handle.close()
        except OSError:
            pass


def wait_for_daemon_exit(socket_path, timeout=5.0):
    """Wait until the daemon released the socket and its lock.

    The service starts the daemon again after a configuration change: the
    new daemon would find the lock taken by the old one and quit without
    doing anything, so the stop has to be finished before the start.
    """
    socket_path = os.path.abspath(os.path.expanduser(socket_path))
    lock_path = socket_path + ".lock"
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not os.path.exists(socket_path) and _lock_is_free(lock_path):
            return True
        time.sleep(0.1)
    return False


def rpc_request(args, paths, req):
    """Send one request to the daemon, starting it when it is not there.

    A request that times out is not repeated blindly: the daemon may be
    working on it (a reconnection takes almost a minute) and sending it
    again would do the work twice. The request is only repeated when a
    ping proves that the daemon is not running.

    With 'no_autostart' the daemon is never started: the service uses it so
    a request that is in flight when the plugin is disabled does not bring
    the daemon back.
    """
    socket_path = os.path.abspath(
        os.path.expanduser(args.socket or paths["socket"])
    )
    try:
        return rpc_call(socket_path, req, RPC_TIMEOUT)
    except Exception:
        pass
    try:
        rpc_call(socket_path, {"cmd": "ping"}, 2.0)
    except Exception:
        if getattr(args, "no_autostart", False):
            # The daemon must not be started: it would outlive the plugin.
            return {
                "ok": False,
                "error": "daemon_failed",
                "error_detail": "the daemon is not running",
            }
        # The daemon is not running: it is started and the request is
        # sent again.
        ensure_daemon(args, paths)
        return rpc_call(socket_path, req, RPC_TIMEOUT)
    # The daemon is alive but did not answer in time: the request is not
    # repeated, because it may still be running there.
    return {
        "ok": False,
        "error": "daemon_failed",
        "error_detail": "the daemon did not answer in %d s" % int(RPC_TIMEOUT),
    }


def build_parser(paths=None):
    """Command line parser.

    The poll interval has one single range (20-300 s), the same as the
    manifest: the daemon and the settings panel always agree.
    """
    if paths is None:
        paths = default_paths()
    parser = argparse.ArgumentParser(description="Control the CMF Buds Pro 2")
    sub = parser.add_subparsers(dest="command")

    p_daemon = sub.add_parser("daemon")
    p_daemon.add_argument("--state", default=paths["state"])
    p_daemon.add_argument("--socket", default=paths["socket"])
    p_daemon.add_argument("--log", default=paths["log"])
    p_daemon.add_argument("--poll", type=int, default=POLL_DEFAULT)
    p_daemon.add_argument("--idle-timeout", type=int, default=300)
    p_daemon.add_argument("--device-mac", default="")
    p_daemon.add_argument("--device-name", default="")

    for name in ("status", "stop", "rpc"):
        p = sub.add_parser(name)
        p.add_argument("--state", default=paths["state"])
        p.add_argument("--socket", default=paths["socket"])
        p.add_argument("--log", default=paths["log"])
        p.add_argument("payload", nargs="?")
        p.add_argument("--poll", type=int, default=POLL_DEFAULT)
        p.add_argument("--idle-timeout", type=int, default=300)
        p.add_argument("--device-mac", default="")
        p.add_argument("--device-name", default="")
        # The daemon is not started when it is not running: the service uses
        # it so a request in flight does not bring it back after the plugin
        # was disabled.
        p.add_argument("--no-autostart", action="store_true")

    return parser


def _cli_error(exc):
    """JSON answer of the command line when the daemon cannot be reached.

    The command line speaks the same contract as the RPC: a stable code and
    the technical detail apart.
    """
    code = getattr(exc, "code", "") or "daemon_failed"
    detail = getattr(exc, "detail", "") or str(exc)
    return json.dumps(
        {"ok": False, "error": code, "error_detail": detail, "state": None}
    )


def main(argv=None):
    paths = default_paths()
    parser = build_parser(paths)
    args = parser.parse_args(argv)
    if args.command == "daemon":
        daemon = BudsDaemon(args)
        return daemon.run()

    if args.command == "stop":
        try:
            rpc_call(args.socket, {"cmd": "shutdown"}, 2.0)
            # The stop waits for the daemon to release the socket and its
            # lock: the caller can start it again right away.
            wait_for_daemon_exit(args.socket, timeout=5.0)
            print(json.dumps({"ok": True}))
        except Exception as exc:
            print(_cli_error(exc))
        return 0

    if args.command == "rpc":
        try:
            req = json.loads(args.payload or "{}")
        except json.JSONDecodeError as exc:
            print(
                json.dumps(
                    {
                        "ok": False,
                        "error": "invalid_json",
                        "error_detail": str(exc),
                    }
                )
            )
            return 2
        if not isinstance(req, dict):
            print(
                json.dumps(
                    {
                        "ok": False,
                        "error": "invalid_request",
                        "error_detail": "the request must be an object",
                    }
                )
            )
            return 2
        try:
            res = rpc_request(args, paths, req)
        except Exception as exc:
            print(_cli_error(exc))
            return 1
        print(json.dumps(res, ensure_ascii=False))
        return 0

    # status
    try:
        res = rpc_request(args, paths, {"cmd": "status"})
    except Exception as exc:
        print(_cli_error(exc))
        return 1
    print(json.dumps(res, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
