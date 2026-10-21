#!/usr/bin/env python3
"""Nothing/CMF earbuds CLI controller for the Noctalia plugin.

Stateless: each invocation opens RFCOMM, does its job, exits. No background
daemon — the Luau service.luau drives polling via Noctalia's own scheduler.
Wire protocol implemented from PROTOCOL.md (own clean-room spec,
hardware-verified against a Nothing Ear (2)), not transliterated from any
AGPL/GPL reference. See models.py for how other models are identified.
"""
from __future__ import annotations

import argparse
import contextlib
import errno
import fcntl
import json
import os
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import models as m
import protocol as p
from sdp import resolve_rfcomm_channel

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
                raise SystemExit(json.dumps({"ok": False, "error": "busy"}))
            time.sleep(0.1)
    try:
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def get_channel(address: str) -> int:
    if os.path.exists(CHANNEL_FILE):
        try:
            with open(CHANNEL_FILE) as f:
                cached_addr, cached_channel = f.read().strip().split(":")
            if cached_addr == address:
                return int(cached_channel)
        except (OSError, ValueError):
            pass
    channel = resolve_rfcomm_channel(address, SPP_UUID)
    with open(CHANNEL_FILE, "w") as f:
        f.write(f"{address}:{channel}")
    return channel


def connect(address: str) -> socket.socket:
    channel = get_channel(address)
    sock = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_STREAM, socket.BTPROTO_RFCOMM)
    sock.settimeout(CONNECT_TIMEOUT)
    try:
        sock.connect((address, channel))
    except OSError:
        # cached channel may be stale (e.g. after a firmware update); re-resolve once
        if os.path.exists(CHANNEL_FILE):
            os.remove(CHANNEL_FILE)
        channel = get_channel(address)
        sock.connect((address, channel))
    sock.settimeout(0.5)
    return sock


def gather(
    sock: socket.socket,
    wait_cmds: set[int],
    timeout: float = READ_TIMEOUT,
    optional: set[int] = frozenset(),
    grace: float = 0.5,
) -> dict[int, p.Frame]:
    """Read until every wait_cmds frame arrived, then up to `grace` seconds
    more for `optional` ones that some models never answer."""
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
        for frame in parser.feed(data):
            found[frame.cmd] = frame
    return found


def read_state(address: str) -> dict:
    # The model doesn't change between polls, so only spend a round-trip on
    # it once per device and carry the result forward from the disk cache.
    cached_model = read_cached().get("model")
    need_serial = not (isinstance(cached_model, dict) and cached_model.get("base") is not None)

    with channel_lock():
        sock = connect(address)
        try:
            sock.send(p.build_frame(p.BATTERY_READ, seq=1))
            sock.send(p.build_frame(p.ANC_READ, seq=2))
            sock.send(p.build_frame(p.EQ_PRESET_READ, seq=3))
            sock.send(p.build_frame(p.FIRMWARE_READ, seq=4))
            sock.send(p.build_frame(p.LATENCY_READ, seq=5))
            sock.send(p.build_frame(p.PERSONAL_ANC_READ, seq=7))
            sock.send(p.build_frame(p.SOUND_PROFILE_READ, seq=8))
            sock.send(p.build_frame(p.SOUND_PROFILE_ID_READ, seq=9))
            wanted = {p.BATTERY_RESP, p.ANC_RESP, p.EQ_PRESET_RESP, p.FIRMWARE_RESP, p.LATENCY_RESP}
            if need_serial:
                sock.send(p.build_frame(p.SERIAL_READ, seq=6))
                wanted.add(p.SERIAL_RESP)
            optional = {p.PERSONAL_ANC_RESP, p.SOUND_PROFILE_RESP, p.SOUND_PROFILE_ID_RESP}
            frames = gather(sock, wanted, optional=optional)
        finally:
            sock.close()

    state: dict = {"connected": True, "updated_at": time.time()}
    if p.BATTERY_RESP in frames:
        state["battery"] = p.parse_battery(frames[p.BATTERY_RESP].payload)
    if p.ANC_RESP in frames:
        state["anc"] = p.parse_anc(frames[p.ANC_RESP].payload)
    if p.EQ_PRESET_RESP in frames:
        state["eq_preset"] = p.parse_eq_preset(frames[p.EQ_PRESET_RESP].payload)
    if p.FIRMWARE_RESP in frames:
        state["firmware"] = p.parse_firmware(frames[p.FIRMWARE_RESP].payload)
    if p.LATENCY_RESP in frames:
        state["latency_mode"] = p.parse_latency(frames[p.LATENCY_RESP].payload)
    # Not waited for: models without these features may never answer, and
    # leaving the key out is what hides the toggle in the panel.
    if p.PERSONAL_ANC_RESP in frames:
        state["personal_anc"] = p.parse_personal_anc(frames[p.PERSONAL_ANC_RESP].payload)
    if p.SOUND_PROFILE_RESP in frames and p.SOUND_PROFILE_ID_RESP in frames:
        # Without a hearing-test profile saved from the app there's nothing to switch on.
        if p.has_sound_profile(frames[p.SOUND_PROFILE_ID_RESP].payload):
            state["sound_profile"] = p.parse_sound_profile(frames[p.SOUND_PROFILE_RESP].payload)

    if need_serial and p.SERIAL_RESP in frames:
        serial = p.parse_serial(frames[p.SERIAL_RESP].payload)
        state["model"] = m.identify(serial)
    elif isinstance(cached_model, dict):
        state["model"] = cached_model

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
                    now = p.parse_anc(current[p.ANC_RESP].payload)
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
    if p.ANC_RESP in frames:
        result["anc"] = p.parse_anc(frames[p.ANC_RESP].payload)
    return result


def write_eq(address: str, preset: int) -> dict:
    with channel_lock(wait=WRITE_LOCK_WAIT):
        sock = connect(address)
        try:
            sock.send(p.build_frame(p.EQ_PRESET_WRITE, p.eq_preset_write_payload(preset), seq=1))
            gather(sock, {p.EQ_PRESET_WRITE & 0x7FFF}, timeout=1.5)
            sock.send(p.build_frame(p.EQ_PRESET_READ, seq=2))
            frames = gather(sock, {p.EQ_PRESET_RESP}, timeout=1.5)
        finally:
            sock.close()
    result = {"ok": True}
    if p.EQ_PRESET_RESP in frames:
        result["eq_preset"] = p.parse_eq_preset(frames[p.EQ_PRESET_RESP].payload)
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
    if p.LATENCY_RESP in frames:
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
    if p.PERSONAL_ANC_RESP in frames:
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
    if p.SOUND_PROFILE_RESP in frames:
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


NEEDS_MAC = {
    "status",
    "set-anc",
    "set-eq",
    "set-latency",
    "set-personal-anc",
    "set-sound-profile",
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
            "cycle-anc",
        ],
    )
    parser.add_argument("value", nargs="?")
    parser.add_argument("--strength", default=None, help="anc strength: high/mid/low/adaptive")
    parser.add_argument("--mac", default=None, help="target device MAC address")
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
        elif args.command == "cycle-anc":
            result = cycle_anc(args.mac)
        else:
            result = {"ok": False, "error": "unknown command"}
    except SystemExit:
        raise
    except Exception as e:  # noqa: BLE001 - always emit JSON, never a traceback to stdout
        result = {"ok": False, "error": str(e)}

    print(json.dumps(result))


if __name__ == "__main__":
    main()
