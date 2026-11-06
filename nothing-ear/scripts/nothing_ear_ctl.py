#!/usr/bin/env python3
"""Nothing/CMF earbuds CLI controller for the Noctalia plugin.

Stateless: each invocation opens RFCOMM, does its job, exits. No background
daemon — the Luau service.luau drives polling via Noctalia's own scheduler.
Wire protocol implemented from PROTOCOL.md (own clean-room spec, mostly
hardware-verified against a Nothing Ear (2); protocol.py marks what isn't),
not transliterated from any AGPL/GPL reference. See models.py for how other models are identified.
"""
from __future__ import annotations

import argparse
import contextlib
import errno
import fcntl
import json
import os
import platform
import re
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import models as m
import protocol as p
from sdp import SdpError, ServiceNotFound, resolve_rfcomm_channel

SPP_UUID = "aeac4a03-dff5-498f-843a-34487cf133eb"
# Substrings (lowercased) an advertised device name is checked against to guess
# it's a Nothing/CMF earbuds unit worth auto-selecting. Deliberately loose
# (covers "Nothing Ear", "Nothing Ear (2)", "Nothing Ear (a)", "CMF Buds",
# "CMF Buds Pro" etc.) — scan_devices() only uses this to rank results and to
# decide whether exactly one candidate is unambiguous; the user always sees
# the full paired-device list and picks explicitly otherwise.
NAME_HINTS = ("nothing ear", "cmf buds")

CACHE_DIR = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
STATE_FILE = os.path.join(CACHE_DIR, "nothing_ear_state.json")
CHANNEL_FILE = os.path.join(CACHE_DIR, "nothing_ear_channel.txt")
LOCK_FILE = os.path.join(CACHE_DIR, "nothing_ear.lock")

READ_TIMEOUT = 3.0  # overall budget for gathering read responses
CONNECT_TIMEOUT = 5.0

ANC_CYCLE = ["off", "transparency", "anc"]


# Shorter than the service's CLI timeout (8 s), with room for the write itself.
WRITE_LOCK_WAIT = 4.0

# How much of an unparsed reply to keep for a bug report.
RAW_DUMP_BYTES = 256


class CtlError(Exception):
    """A failure with a stable `code` the panel turns into a short hint, plus
    the step it happened at and any detail worth putting in a bug report."""

    def __init__(self, code: str, stage: str, message: str, **detail):
        super().__init__(message)
        self.code = code
        self.stage = stage
        self.detail = detail

    def to_dict(self) -> dict:
        return {"error": self.code, "stage": self.stage, "message": str(self), **self.detail}


# errno -> code, for failures opening the Bluetooth sockets.
_ERRNO_CODES = {
    errno.ECONNREFUSED: "refused",
    errno.EBUSY: "refused",
    errno.EHOSTDOWN: "unreachable",
    errno.EHOSTUNREACH: "unreachable",
    errno.ENOTCONN: "unreachable",
    errno.ECONNRESET: "unreachable",
    errno.ECONNABORTED: "unreachable",
    errno.ETIMEDOUT: "timeout",
    errno.ENETDOWN: "bt_off",
    errno.ENODEV: "bt_off",
    errno.EACCES: "permission",
    errno.EPERM: "permission",
    errno.EAFNOSUPPORT: "no_bt_support",
    errno.EPROTONOSUPPORT: "no_bt_support",
}


def os_error(e: OSError, stage: str, **detail) -> CtlError:
    if isinstance(e, (socket.timeout, TimeoutError)):
        code = "timeout"
    elif e.errno in _ERRNO_CODES:
        code = _ERRNO_CODES[e.errno]
    elif isinstance(e, ConnectionRefusedError):
        code = "refused"
    elif isinstance(e, ConnectionError):
        code = "unreachable"
    elif isinstance(e, PermissionError):
        code = "permission"
    else:
        code = "os_error"
    if e.errno is not None:
        detail["errno"] = e.errno
        detail["errno_name"] = errno.errorcode.get(e.errno, "")
    return CtlError(code, stage, str(e) or type(e).__name__, exc_type=type(e).__name__, **detail)


@contextlib.contextmanager
def channel_lock(wait: float = 0.0):
    """Advisory lock so overlapping invocations don't fight over the single
    RFCOMM channel the earbuds allow. A poll passes wait=0 and skips if the
    lock is held; a write waits up to `wait` seconds for the poll in flight
    to finish, so a click in the panel isn't silently dropped.
    """
    fd = os.open(LOCK_FILE, os.O_CREAT | os.O_RDWR, 0o600)
    deadline = time.monotonic() + wait
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError as e:
            if e.errno not in (errno.EACCES, errno.EAGAIN):
                os.close(fd)
                raise
            if time.monotonic() >= deadline:
                os.close(fd)
                raise CtlError("busy", "lock", "another command is using the earbuds")
            time.sleep(0.1)
    try:
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def cached_channel(address: str) -> int | None:
    if os.path.exists(CHANNEL_FILE):
        try:
            with open(CHANNEL_FILE) as f:
                cached_addr, channel = f.read().strip().rsplit(":", 1)
            if cached_addr == address and 1 <= int(channel) <= 30:
                return int(channel)
        except (OSError, ValueError):
            pass
    return None


def get_channel(address: str) -> int:
    channel = cached_channel(address)
    if channel is not None:
        return channel
    channel = resolve_rfcomm_channel(address, SPP_UUID)
    with open(CHANNEL_FILE, "w") as f:
        f.write(f"{address}:{channel}")
    return channel


def require_bluetooth() -> None:
    if not hasattr(socket, "AF_BLUETOOTH"):
        raise CtlError(
            "no_bt_support",
            "setup",
            f"{sys.executable} was built without Bluetooth socket support",
        )


def sdp_error(e: Exception) -> CtlError:
    if isinstance(e, SdpError):
        code = "no_service" if isinstance(e, ServiceNotFound) else "sdp_failed"
        return CtlError(code, "sdp", str(e), sdp_reply=e.response[:RAW_DUMP_BYTES].hex(" "))
    if isinstance(e, OSError):
        return os_error(e, "sdp")
    raise e


def discover_channel(address: str) -> int:
    """get_channel, with SDP failures turned into CtlErrors."""
    try:
        return get_channel(address)
    except (SdpError, OSError) as e:
        raise sdp_error(e) from e


def require_link(address: str) -> None:
    """Paging earbuds that aren't connected to this computer blocks for ~8 s
    and ends in "Host is down" anyway. BlueZ already knows, so ask it first;
    if bluetoothctl can't say, just try."""
    if "Connected: no" in _run(["bluetoothctl", "info", address]):
        raise CtlError("not_connected", "precheck", "BlueZ reports the earbuds as not connected")


def bluez_name(address: str) -> str | None:
    match = re.search(r"^\s*Name: (.+)$", _run(["bluetoothctl", "info", address]), re.M)
    return match.group(1).strip() if match else None


def connect(address: str) -> socket.socket:
    require_bluetooth()
    require_link(address)
    source = "cached" if cached_channel(address) is not None else "sdp"
    channel = discover_channel(address)
    first_failure = None
    for attempt in range(2):
        sock = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_STREAM, socket.BTPROTO_RFCOMM)
        sock.settimeout(CONNECT_TIMEOUT)
        try:
            sock.connect((address, channel))
        except OSError as e:
            sock.close()
            err = os_error(e, "connect", channel=channel, channel_source=source, first_failure=first_failure)
            # A stale channel is refused; an unreachable device won't be any
            # more reachable on a second try, and paging it again takes seconds.
            if attempt == 1 or err.code in ("unreachable", "timeout"):
                raise err from e
            first_failure = f"channel {channel} ({source}): {e}"
            # A failed Bluetooth connect can invalidate the socket. Resolve
            # a possibly stale channel and retry with a fresh socket.
            if os.path.exists(CHANNEL_FILE):
                os.remove(CHANNEL_FILE)
            source = "sdp"
            channel = discover_channel(address)
        else:
            sock.settimeout(0.5)
            return sock
    raise AssertionError("unreachable")


def gather(
    sock: socket.socket,
    wait_cmds: set[int],
    timeout: float = READ_TIMEOUT,
    optional: set[int] = frozenset(),
    grace: float = 0.5,
    raw: bytearray | None = None,
) -> dict[int, p.Frame]:
    """Read until every wait_cmds frame arrived, then up to `grace` seconds
    more for `optional` ones that some models never answer. Bytes received
    are also copied into `raw` (first RAW_DUMP_BYTES) when given."""
    parser = p.FrameParser()
    found: dict[int, p.Frame] = {}
    deadline = time.monotonic() + timeout
    grace_deadline = None
    while time.monotonic() < deadline and not (wait_cmds | optional).issubset(found.keys()):
        if grace_deadline is None and wait_cmds.issubset(found.keys()):
            grace_deadline = time.monotonic() + grace
            deadline = min(deadline, grace_deadline)
        try:
            data = sock.recv(4096)
        except socket.timeout:
            continue
        if not data:
            break
        if raw is not None and len(raw) < RAW_DUMP_BYTES:
            raw.extend(data[: RAW_DUMP_BYTES - len(raw)])
        for frame in parser.feed(data):
            found[frame.cmd] = frame
    return found


def cached_model(address: str) -> dict | None:
    """The model found on an earlier poll of this same device, if its
    descriptor is complete and the model was actually recognised."""
    cached = read_cached()
    model = cached.get("model")
    if cached.get("address") != address or not isinstance(model, dict):
        return None
    if model.get("base") is None or "eq" not in model:
        return None
    return model


def identify_model(sock: socket.socket, address: str, raw: bytearray) -> dict:
    # Asked on its own first, because which reads follow depends on the answer.
    sock.send(p.build_frame(p.MODEL_READ, seq=10))
    sock.send(p.build_frame(p.SERIAL_READ, seq=6))
    frames = gather(sock, {p.MODEL_RESP}, timeout=1.5, optional={p.SERIAL_RESP}, raw=raw)
    model_id = p.parse_model(frames[p.MODEL_RESP].payload) if p.MODEL_RESP in frames else None
    serial = p.parse_serial(frames[p.SERIAL_RESP].payload) if p.SERIAL_RESP in frames else None
    model = m.identify(model_id, serial, bluez_name(address))
    if model_id:
        model["model_id"] = model_id
    return model


# reply -> (state key, parser); a parser returning None leaves the key out.
_READS = {
    p.BATTERY_RESP: ("battery", p.parse_battery),
    p.ANC_RESP: ("anc", p.parse_anc),
    p.EQ_PRESET_RESP: ("eq_preset", p.parse_eq_preset),
    p.LISTENING_MODE_RESP: ("eq_preset", p.parse_eq_preset),
    p.FIRMWARE_RESP: ("firmware", p.parse_firmware),
    p.LATENCY_RESP: ("latency_mode", p.parse_latency),
    p.PERSONAL_ANC_RESP: ("personal_anc", p.parse_personal_anc),
    p.SOUND_PROFILE_RESP: ("sound_profile", p.parse_sound_profile),
    p.BASS_RESP: ("bass", p.parse_bass),
}
# Pushes the buds send unprompted carry the same payload as the reply, so
# one arriving during the read stands in for a reply that didn't.
_PUSH_FOR = {p.BATTERY_RESP: p.BATTERY_PUSH, p.ANC_RESP: p.ANC_PUSH}


def read_state(address: str, lock_wait: float = 0.0, identify: bool = False) -> dict:
    # The model doesn't change between polls, so only spend a round-trip on
    # it once per device and carry the result forward from the disk cache.
    model = None if identify else cached_model(address)
    raw = bytearray()

    with channel_lock(wait=lock_wait):
        sock = connect(address)
        try:
            if model is None:
                model = identify_model(sock, address, raw)
            reads = [p.BATTERY_READ, p.ANC_READ, p.FIRMWARE_READ, p.LATENCY_READ]
            wanted = {p.BATTERY_RESP, p.ANC_RESP, p.FIRMWARE_RESP, p.LATENCY_RESP}
            if model["eq"] == "classic":
                reads.append(p.EQ_PRESET_READ)
                wanted.add(p.EQ_PRESET_RESP)
            elif model["eq"] == "listening":
                reads.append(p.LISTENING_MODE_READ)
                wanted.add(p.LISTENING_MODE_RESP)
            # Not waited for: models without these features may never answer,
            # and leaving the key out is what hides the toggle in the panel.
            optional = {p.PERSONAL_ANC_RESP, p.SOUND_PROFILE_RESP, p.SOUND_PROFILE_ID_RESP}
            reads += [p.PERSONAL_ANC_READ, p.SOUND_PROFILE_READ, p.SOUND_PROFILE_ID_READ]
            if model["bass"]:
                reads.append(p.BASS_READ)
                optional.add(p.BASS_RESP)
            for seq, cmd in enumerate(reads, start=1):
                sock.send(p.build_frame(cmd, seq=seq))
            frames = gather(sock, wanted, optional=optional, raw=raw)
        except OSError as e:
            raise os_error(e, "read", reply=raw.hex(" ")) from e
        finally:
            sock.close()

    for resp, push in _PUSH_FOR.items():
        if resp not in frames and push in frames:
            frames[resp] = frames[push]

    if not (wanted | optional) & frames.keys():
        # Connected, but nothing we asked for came back: most likely a model
        # that frames or numbers its commands differently. The raw bytes are
        # what's needed to add support for it.
        raise CtlError(
            "no_response",
            "read",
            f"no recognised reply ({len(raw)} bytes received)",
            reply=raw.hex(" "),
            frames_seen=[f"{cmd:04x}" for cmd in frames],
        )

    state: dict = {"connected": True, "updated_at": time.time(), "address": address, "model": model}
    # Replies whose payload didn't parse, kept for a bug report instead of
    # failing the whole read over one setting.
    unparsed: dict[str, str] = {}
    for resp, (key, parse) in _READS.items():
        if resp not in frames:
            continue
        if resp == p.SOUND_PROFILE_RESP:
            # Without a hearing-test profile saved from the app there's nothing to switch on.
            profile_id = frames.get(p.SOUND_PROFILE_ID_RESP)
            if profile_id is None or not p.has_sound_profile(profile_id.payload):
                continue
        payload = frames[resp].payload
        try:
            value = parse(payload)
        except (IndexError, ValueError):
            value = None
        if value is None:
            unparsed[f"{resp:04x}"] = payload.hex(" ")
        else:
            state[key] = value
    if unparsed:
        state["unparsed"] = unparsed

    with open(STATE_FILE + ".tmp", "w") as f:
        json.dump(state, f)
    os.replace(STATE_FILE + ".tmp", STATE_FILE)
    return state


def read_cached() -> dict:
    if not os.path.exists(STATE_FILE):
        return {"connected": False}
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {"connected": False}


def write_anc(address: str, mode: str, strength: str | None) -> dict:
    # Validate before connecting; a missing anc strength is filled in below.
    p.anc_mode_to_byte(mode, strength or ("adaptive" if mode == "anc" else None))
    with channel_lock(wait=WRITE_LOCK_WAIT):
        sock = connect(address)
        try:
            if mode == "anc" and strength is None:
                # Keep the buds' current strength if ANC is already on, else adaptive.
                sock.send(p.build_frame(p.ANC_READ, seq=3))
                current = gather(sock, {p.ANC_RESP}, timeout=1.5)
                strength = "adaptive"
                if p.ANC_RESP in current:
                    now = p.parse_anc(current[p.ANC_RESP].payload) or {}
                    if now.get("mode") == "anc" and now.get("strength"):
                        strength = now["strength"]
            mode_byte = p.anc_mode_to_byte(mode, strength)
            sock.send(p.build_frame(p.ANC_WRITE, p.anc_write_payload(mode_byte), seq=1))
            gather(sock, {p.ANC_WRITE & 0x7FFF}, timeout=1.5)
            sock.send(p.build_frame(p.ANC_READ, seq=2))
            frames = gather(sock, {p.ANC_RESP}, timeout=1.5)
        finally:
            sock.close()
    result = {"ok": True}
    if p.ANC_RESP in frames and p.parse_anc(frames[p.ANC_RESP].payload) is not None:
        result["anc"] = p.parse_anc(frames[p.ANC_RESP].payload)
    return result


def write_eq(address: str, preset: int) -> dict:
    model = cached_model(address) or m.describe(None)
    if preset not in (entry["index"] for entry in model["eq_presets"]):
        raise CtlError("bad_value", "set-eq", f"preset {preset} isn't one this model has")
    if model["eq"] == "listening":
        write_cmd, read_cmd, resp = p.LISTENING_MODE_WRITE, p.LISTENING_MODE_READ, p.LISTENING_MODE_RESP
    else:
        write_cmd, read_cmd, resp = p.EQ_PRESET_WRITE, p.EQ_PRESET_READ, p.EQ_PRESET_RESP
    with channel_lock(wait=WRITE_LOCK_WAIT):
        sock = connect(address)
        try:
            sock.send(p.build_frame(write_cmd, p.eq_preset_write_payload(preset), seq=1))
            gather(sock, {write_cmd & 0x7FFF}, timeout=1.5)
            sock.send(p.build_frame(read_cmd, seq=2))
            frames = gather(sock, {resp}, timeout=1.5)
        finally:
            sock.close()
    result = {"ok": True}
    if resp in frames and p.parse_eq_preset(frames[resp].payload) is not None:
        result["eq_preset"] = p.parse_eq_preset(frames[resp].payload)
    return result


def write_bass(address: str, level: int) -> dict:
    """level 0 turns bass boost off (keeping the last level), 1-5 turns it on."""
    if not 0 <= level <= 5:
        raise CtlError("bad_value", "set-bass", f"level {level} is outside 0-5")
    if not (cached_model(address) or {}).get("bass"):
        raise CtlError("bad_value", "set-bass", "this model has no bass boost")
    current = read_cached().get("bass") or {}
    enabled = level > 0
    wire_level = level if enabled else max(1, min(5, current.get("level") or 1))
    with channel_lock(wait=WRITE_LOCK_WAIT):
        sock = connect(address)
        try:
            sock.send(p.build_frame(p.BASS_WRITE, p.bass_write_payload(enabled, wire_level), seq=1))
            gather(sock, {p.BASS_WRITE & 0x7FFF}, timeout=1.5)
            sock.send(p.build_frame(p.BASS_READ, seq=2))
            frames = gather(sock, {p.BASS_RESP}, timeout=1.5)
        finally:
            sock.close()
    result = {"ok": True}
    if p.BASS_RESP in frames and p.parse_bass(frames[p.BASS_RESP].payload) is not None:
        result["bass"] = p.parse_bass(frames[p.BASS_RESP].payload)
    return result


def write_latency(address: str, enabled: bool) -> dict:
    with channel_lock(wait=WRITE_LOCK_WAIT):
        sock = connect(address)
        try:
            sock.send(p.build_frame(p.LATENCY_WRITE, p.latency_write_payload(enabled), seq=1))
            gather(sock, {p.LATENCY_WRITE & 0x7FFF}, timeout=1.5)
            sock.send(p.build_frame(p.LATENCY_READ, seq=2))
            frames = gather(sock, {p.LATENCY_RESP}, timeout=1.5)
        finally:
            sock.close()
    result = {"ok": True}
    if p.LATENCY_RESP in frames and p.parse_latency(frames[p.LATENCY_RESP].payload) is not None:
        result["latency_mode"] = p.parse_latency(frames[p.LATENCY_RESP].payload)
    return result


def write_personal_anc(address: str, enabled: bool) -> dict:
    with channel_lock(wait=WRITE_LOCK_WAIT):
        sock = connect(address)
        try:
            sock.send(p.build_frame(p.PERSONAL_ANC_WRITE, p.personal_anc_write_payload(enabled), seq=1))
            gather(sock, {p.PERSONAL_ANC_WRITE & 0x7FFF}, timeout=1.5)
            sock.send(p.build_frame(p.PERSONAL_ANC_READ, seq=2))
            frames = gather(sock, {p.PERSONAL_ANC_RESP}, timeout=1.5)
        finally:
            sock.close()
    result = {"ok": True}
    if p.PERSONAL_ANC_RESP in frames and p.parse_personal_anc(frames[p.PERSONAL_ANC_RESP].payload) is not None:
        result["personal_anc"] = p.parse_personal_anc(frames[p.PERSONAL_ANC_RESP].payload)
    return result


def write_sound_profile(address: str, enabled: bool) -> dict:
    with channel_lock(wait=WRITE_LOCK_WAIT):
        sock = connect(address)
        try:
            sock.send(p.build_frame(p.SOUND_PROFILE_WRITE, p.sound_profile_write_payload(enabled), seq=1))
            gather(sock, {p.SOUND_PROFILE_WRITE & 0x7FFF}, timeout=1.5)
            sock.send(p.build_frame(p.SOUND_PROFILE_READ, seq=2))
            frames = gather(sock, {p.SOUND_PROFILE_RESP}, timeout=1.5)
        finally:
            sock.close()
    result = {"ok": True}
    if p.SOUND_PROFILE_RESP in frames and p.parse_sound_profile(frames[p.SOUND_PROFILE_RESP].payload) is not None:
        result["sound_profile"] = p.parse_sound_profile(frames[p.SOUND_PROFILE_RESP].payload)
    return result


def scan_devices() -> dict:
    """List already-paired Bluetooth devices via bluetoothctl, so the panel can
    offer a pick list instead of making the user copy a MAC address out of
    system Bluetooth settings. This only reads BlueZ's paired-device list; it
    does not pair, connect, or probe anything.
    """
    try:
        proc = subprocess.run(
            ["bluetoothctl", "devices", "Paired"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        return {"ok": False, "error": str(e)}
    if proc.returncode != 0:
        return {"ok": False, "error": proc.stderr.strip() or "bluetoothctl failed"}

    devices = []
    for line in proc.stdout.splitlines():
        parts = line.strip().split(" ", 2)
        if len(parts) == 3 and parts[0] == "Device":
            mac, name = parts[1], parts[2]
            name_l = name.lower()
            likely = any(hint in name_l for hint in NAME_HINTS)
            devices.append({"mac": mac, "name": name, "likely": likely})
    devices.sort(key=lambda d: (not d["likely"], d["name"].lower()))
    return {"ok": True, "devices": devices}


def cycle_anc(address: str) -> dict:
    cached = read_cached()
    current_mode = cached.get("anc", {}).get("mode", "off")
    try:
        idx = ANC_CYCLE.index(current_mode)
    except ValueError:
        idx = 0
    next_mode = ANC_CYCLE[(idx + 1) % len(ANC_CYCLE)]
    strength = "high" if next_mode == "anc" else None
    return write_anc(address, next_mode, strength)


def _run(argv: list[str]) -> str:
    try:
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired) as e:
        return f"<{e}>"
    return (proc.stdout or proc.stderr).strip()


def plugin_version() -> str:
    path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "plugin.toml")
    try:
        with open(path) as f:
            match = re.search(r'^version\s*=\s*"([^"]+)"', f.read(), re.M)
    except OSError:
        return "unknown"
    return match.group(1) if match else "unknown"


def mask_mac(address: str) -> str:
    # Reports end up in public issues; the first half (the vendor) is enough.
    parts = address.split(":")
    if len(parts) != 6:
        return address
    return ":".join(parts[:3] + ["xx"] * 3)


def guess_device() -> str | None:
    """The connected Nothing/CMF device, else the only one paired; failing
    that (names like "Ear (2)" match no hint), the only device connected."""
    likely = [d["mac"] for d in scan_devices().get("devices", []) if d["likely"]]
    connected = _run(["bluetoothctl", "devices", "Connected"])
    for mac in likely:
        if mac in connected:
            return mac
    if len(likely) == 1:
        return likely[0]
    connected_macs = [line.split()[1] for line in connected.splitlines() if line.startswith("Device ")]
    return connected_macs[0] if len(connected_macs) == 1 else None


def describe_error(err: dict) -> list[tuple[str, str]]:
    summary = f"{err.get('error')} at {err.get('stage')}: {err.get('message')}"
    extras = [
        f"{key}={err[key]}"
        for key in ("errno_name", "channel", "channel_source", "first_failure", "frames_seen", "exit_code")
        if err.get(key) not in (None, "", [])
    ]
    if extras:
        summary += " (" + ", ".join(str(x) for x in extras) + ")"
    lines = [("", summary)]
    for key in ("reply", "sdp_reply"):
        if err.get(key):
            lines.append((key, err[key]))
    return lines


def refine(e: CtlError, address: str | None) -> CtlError:
    """"Can't reach it" covers both Bluetooth being off and the buds not being
    connected to this computer; BlueZ can tell those apart, and the hint the
    panel shows for each is different."""
    if e.code not in ("unreachable", "timeout") or not address:
        return e
    if "Powered: no" in _run(["bluetoothctl", "show"]):
        e.code = "bt_off"
    elif "Connected: no" in _run(["bluetoothctl", "info", address]):
        e.code = "not_connected"
    return e


def diagnose(address: str | None, last_error: str | None) -> dict:
    """Everything useful for a bug report, as text ready to paste into an
    issue: environment, what BlueZ knows, the last poll's error and a fresh
    step-by-step attempt (SDP without the cache, then a full read)."""
    rows: list[tuple[str, str]] = [
        ("plugin", plugin_version()),
        ("time", time.strftime("%Y-%m-%d %H:%M:%S %z")),
        ("system", f"{platform.system()} {platform.release()}"),
        (
            "python",
            f"{platform.python_version()} {sys.executable} "
            f"(bluetooth sockets: {'yes' if hasattr(socket, 'AF_BLUETOOTH') else 'no'})",
        ),
        ("bluez", _run(["bluetoothctl", "--version"])),
        (
            "adapter",
            next(
                (line.strip() for line in _run(["bluetoothctl", "show"]).splitlines() if "Powered:" in line),
                "no adapter found",
            ),
        ),
    ]

    if not address:
        address = guess_device()
        if address:
            rows.append(("device", f"{mask_mac(address)} (not configured, guessed)"))
    else:
        rows.append(("device", mask_mac(address)))

    if last_error:
        try:
            err = json.loads(last_error)
            rows += [("last poll" + (" " + k if k else ""), v) for k, v in describe_error(err)]
        except (ValueError, AttributeError):
            rows.append(("last poll", last_error))

    if not address:
        rows.append(("device", "none configured, connected or paired"))
    else:
        info = _run(["bluetoothctl", "info", address])
        wanted = ("Name:", "Alias:", "Paired:", "Bonded:", "Trusted:", "Connected:", "UUID:", "Modalias:")
        kept = [line.strip() for line in info.splitlines() if line.strip().startswith(wanted)]
        rows += [("bluez info", line) for line in (kept or [info or "no output"])]
        rows.append(("control uuid", "listed" if SPP_UUID in info.lower() else "not listed by BlueZ"))

        # Fresh SDP, bypassing the cache, so a stale channel can't hide a
        # discovery problem.
        try:
            require_bluetooth()
            rows.append(("sdp", f"ok, channel {resolve_rfcomm_channel(address, SPP_UUID)}"))
        except CtlError as e:
            rows += [("sdp" + (" " + k if k else ""), v) for k, v in describe_error(e.to_dict())]
        except (SdpError, OSError) as e:
            rows += [("sdp" + (" " + k if k else ""), v) for k, v in describe_error(sdp_error(e).to_dict())]
        rows.append(("cached channel", str(cached_channel(address))))

        try:
            # Identify the model afresh, so a wrong cached one shows up here.
            state = read_state(address, lock_wait=WRITE_LOCK_WAIT, identify=True)
            got = sorted(k for k in state if k not in ("connected", "updated_at"))
            rows.append(("read", "ok: " + ", ".join(got)))
            model = state.get("model") or {}
            rows.append(("model", f"{model.get('name')} ({model.get('base')}, id {model.get('model_id')})"))
            rows.append(("firmware", str(state.get("firmware"))))
            for cmd, payload in (state.get("unparsed") or {}).items():
                rows.append(("unparsed " + cmd, payload or "(empty)"))
        except CtlError as e:
            rows += [("read" + (" " + k if k else ""), v) for k, v in describe_error(e.to_dict())]
        except Exception as e:  # noqa: BLE001 - a report should never fail to produce
            rows.append(("read", f"{type(e).__name__}: {e}"))

    body = "\n".join(f"{k:<16}{v}" for k, v in rows)
    if address:
        body = body.replace(address, mask_mac(address))
    return {"ok": True, "text": "Nothing Ear diagnostics\n```text\n" + body + "\n```\n"}


NEEDS_MAC = {
    "status",
    "set-anc",
    "set-eq",
    "set-latency",
    "set-personal-anc",
    "set-sound-profile",
    "set-bass",
    "cycle-anc",
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=[
            "status",
            "cached",
            "scan",
            "set-anc",
            "set-eq",
            "set-latency",
            "set-personal-anc",
            "set-sound-profile",
            "set-bass",
            "cycle-anc",
            "diag",
        ],
    )
    parser.add_argument("value", nargs="?")
    parser.add_argument("--strength", default=None, help="anc strength: high/mid/low/adaptive")
    parser.add_argument("--mac", default=None, help="target device MAC address")
    parser.add_argument("--last-error", default=None, help="diag: the service's last poll error, as JSON")
    args = parser.parse_args()

    try:
        if args.command in NEEDS_MAC and not args.mac:
            result = {"ok": False, "error": "no_device"}
        elif args.command == "status":
            result = read_state(args.mac)
        elif args.command == "cached":
            result = read_cached()
        elif args.command == "scan":
            result = scan_devices()
        elif args.command == "set-anc":
            result = write_anc(args.mac, args.value, args.strength)
        elif args.command == "set-eq":
            result = write_eq(args.mac, int(args.value))
        elif args.command == "set-latency":
            result = write_latency(args.mac, args.value in ("1", "true", "on", "yes"))
        elif args.command == "set-personal-anc":
            result = write_personal_anc(args.mac, args.value in ("1", "true", "on", "yes"))
        elif args.command == "set-sound-profile":
            result = write_sound_profile(args.mac, args.value in ("1", "true", "on", "yes"))
        elif args.command == "set-bass":
            result = write_bass(args.mac, int(args.value))
        elif args.command == "cycle-anc":
            result = cycle_anc(args.mac)
        elif args.command == "diag":
            result = diagnose(args.mac, args.last_error)
            if sys.stdout.isatty():
                # run by hand from a terminal: print the report, not JSON
                print(result["text"])
                return
        else:
            result = {"ok": False, "error": "unknown command"}
    except SystemExit:
        raise
    except CtlError as e:
        result = {"ok": False, "connected": False, **refine(e, args.mac).to_dict()}
    except OSError as e:
        result = {"ok": False, "connected": False, **refine(os_error(e, args.command), args.mac).to_dict()}
    except Exception as e:  # noqa: BLE001 - always emit JSON, never a traceback to stdout
        result = {
            "ok": False,
            "connected": False,
            "error": "unknown",
            "stage": args.command,
            "message": str(e),
            "exc_type": type(e).__name__,
        }

    print(json.dumps(result))


if __name__ == "__main__":
    main()
