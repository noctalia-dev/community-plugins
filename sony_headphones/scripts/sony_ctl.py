#!/usr/bin/env python3
"""
Sony Headphones backend for Noctalia — MDR V2 (WH/WF-1000X series, LinkBuds, …).

Speaks Sony's reverse-engineered MDR V2 binary protocol over Bluetooth RFCOMM
(the same protocol the official Sound Connect app uses), using only the
standard library: `socket.AF_BLUETOOTH` + BlueZ (`bluetoothctl`/`sdptool`).

Frame format (verified against mos9527/libmdr, Keller18306/SonyHeadphonesProtocol,
ibatra/sony-headphones-client, MamaJo3/sony-mx5-desktop-toggle):
    START 0x3E | ESCAPED( TYPE SEQ LEN(4B BE) PAYLOAD CHECKSUM ) | END 0x3C
    TYPE: 0x0C = DATA_MDR, 0x01 = ACK
    SEQ: 1 bit, alternates 0/1 per connection, starts at 0
    CHECKSUM: sum(TYPE + SEQ + LEN + PAYLOAD) mod 256
    Escape: 0x3C->3D 2C, 0x3D->3D 2D, 0x3E->3D 2E
    Rule: ACK every received non-ACK frame with inverted seq; wait for ACK after send.

Control channel: SDP UUID 956c7b26-d49a-4ba8-b03f-b17d393cb6e2 ("Serial HPC").
Channel is resolved via `sdptool browse`, default 9 (usual XM5 value).

CLI (mirrors oppo_ctl.py so service.luau stays simple):
    sony_ctl.py status [--mac XX:..]          # full snapshot as JSON
    sony_ctl.py cached                        # last-known snapshot as JSON
    sony_ctl.py set-anc anc|transparency|off [--mac ..]
    sony_ctl.py set-ambient 0..20 [--mac ..]
    sony_ctl.py cycle-anc [--mac ..]
"""

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import time

# ---------------------------------------------------------------- constants

V2_UUID = "956c7b26-d49a-4ba8-b03f-b17d393cb6e2"
DEFAULT_CHANNEL = 9

TYPE_DATA = 0x0C
TYPE_ACK = 0x01

MODE_OFF = "off"
MODE_ANC = "anc"
MODE_TRANSPARENCY = "transparency"
CYCLE_MODES = [MODE_ANC, MODE_TRANSPARENCY, MODE_OFF]

# Table-1 payloads (see module docstring for sources)
P_CONNECT_INFO = bytes([0x00, 0x00])
P_SUPPORT_FUNCTION = bytes([0x06, 0x00])
P_BATTERY = bytes([0x22, 0x00])       # POWER_GET_STATUS(BATTERY); fallback [0x26, 0x00]
P_BATTERY_ALT = bytes([0x26, 0x00])
P_NC_GET = bytes([0x66, 0x17])        # NCASM_GET_PARAM, subtype 0x17 (XM5); fallback 0x19 (XM6)
P_NC_GET_ALT = bytes([0x66, 0x19])

CACHE_DIR = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
STATE_FILE = os.path.join(CACHE_DIR, "sony_headphones_state.json")

MODEL_NAMES = {
    "WH-1000XM6": "WH-1000XM6",
    "WH-1000XM5": "WH-1000XM5",
    "WH-1000XM4": "WH-1000XM4",
    "WH-1000XM3": "WH-1000XM3",
    "WF-1000XM5": "WF-1000XM5",
    "WF-1000XM4": "WF-1000XM4",
    "WF-1000XM3": "WF-1000XM3",
    "LinkBuds S": "LinkBuds S",
    "WH-CH720N": "WH-CH720N",
    "WH-1000XX": "WH-1000XX",
    "1000X THE COLLEXION": "WH-1000XX",
    "1000X THE COLLECTION": "WH-1000XX",
    "ULT WEAR": "ULT WEAR",
}

# ---------------------------------------------------------------- framing


def _escape(data: bytes) -> bytes:
    out = bytearray()
    for b in data:
        if b == 0x3C:
            out += bytes([0x3D, 0x2C])
        elif b == 0x3D:
            out += bytes([0x3D, 0x2D])
        elif b == 0x3E:
            out += bytes([0x3D, 0x2E])
        else:
            out.append(b)
    return bytes(out)


def _unescape(data: bytes) -> bytes:
    out = bytearray()
    i = 0
    while i < len(data):
        if data[i] == 0x3D and i + 1 < len(data):
            nxt = data[i + 1]
            if nxt == 0x2C:
                out.append(0x3C)
            elif nxt == 0x2D:
                out.append(0x3D)
            elif nxt == 0x2E:
                out.append(0x3E)
            else:
                out.append(nxt)
            i += 2
        else:
            out.append(data[i])
            i += 1
    return bytes(out)


def pack_frame(ftype: int, seq: int, payload: bytes) -> bytes:
    body = bytes([ftype & 0xFF, seq & 0xFF]) + len(payload).to_bytes(4, "big") + payload
    checksum = sum(body) % 256
    return bytes([0x3E]) + _escape(body + bytes([checksum])) + bytes([0x3C])


def split_frames(stream: bytearray):
    """Extract complete 0x3E...0x3C frames from a byte stream. Returns (frames, rest)."""
    frames = []
    while True:
        try:
            start = stream.index(0x3E)
        except ValueError:
            return frames, bytearray()
        try:
            end = stream.index(0x3C, start + 1)
        except ValueError:
            return frames, stream[start:]
        frames.append(bytes(stream[start + 1:end]))
        del stream[:end + 1]


def parse_frame(raw: bytes):
    """Returns (ftype, seq, payload) or None on checksum/length error."""
    try:
        body = _unescape(raw)
    except Exception:
        return None
    if len(body) < 7:
        return None
    ftype, seq = body[0], body[1]
    length = int.from_bytes(body[2:6], "big")
    payload = body[6:-1]
    checksum = body[-1]
    if len(payload) != length:
        return None
    if sum(body[:-1]) % 256 != checksum:
        return None
    return ftype, seq, payload


# ---------------------------------------------------------------- transport


def resolve_channel(mac: str) -> int:
    """Resolve the RFCOMM channel for the Sony HPC UUID via sdptool. Falls back to 9."""
    try:
        out = subprocess.check_output(
            ["sdptool", "browse", mac], text=True, stderr=subprocess.DEVNULL, timeout=10
        )
    except Exception:
        return DEFAULT_CHANNEL
    # Find the service block mentioning our UUID, then its Channel line.
    blocks = re.split(r"Service (?:Name|RecHandle)", out)
    for block in blocks:
        if V2_UUID.lower() in block.lower():
            m = re.search(r"Channel:\s*(\d+)", block)
            if m:
                ch = int(m.group(1))
                if 1 <= ch <= 30:
                    return ch
    return DEFAULT_CHANNEL


def find_connected_device():
    """Find a connected Sony device MAC via bluetoothctl."""
    try:
        out = subprocess.check_output(
            ["bluetoothctl", "devices", "Connected"], text=True, stderr=subprocess.DEVNULL
        )
    except Exception:
        return None, None
    for line in out.strip().split("\n"):
        parts = line.strip().split(" ", 2)
        if len(parts) >= 3:
            mac, name = parts[1], parts[2]
            low = name.lower()
            if any(k in low for k in ("sony", "wh-", "wf-", "linkbuds", "ult wear", "ch7")):
                return mac, name
    return None, None


def bluez_battery(mac: str):
    """Fallback battery % from BlueZ (`bluetoothctl info`), e.g. 0x5a -> 90."""
    try:
        out = subprocess.check_output(
            ["bluetoothctl", "info", mac], text=True, stderr=subprocess.DEVNULL
        )
    except Exception:
        return None
    m = re.search(r"Battery Percentage:\s*0x([0-9a-fA-F]+)", out)
    if m:
        try:
            return int(m.group(1), 16)
        except ValueError:
            return None
    # Some bluetoothctl builds print a plain decimal percentage.
    m = re.search(r"Battery Percentage:\s*(\d+)%?", out)
    if m:
        try:
            return max(0, min(100, int(m.group(1))))
        except ValueError:
            return None
    return None


# ---------------------------------------------------------------- session


class SonySession:
    """One short-lived RFCOMM connection. Handles seq + bidirectional ACK."""

    def __init__(self, mac: str, channel: int, timeout: float = 4.0):
        self.mac = mac
        self.channel = channel
        self.timeout = timeout
        self.sock = None
        self.tx_seq = 0
        self.buf = bytearray()

    def open(self, attempts: int = 3, delay: float = 0.4) -> bool:
        """Connect with a few retries: BlueZ can hold the RFCOMM channel for a
        moment after a previous short-lived session closes."""
        for attempt in range(attempts):
            s = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_STREAM, socket.BTPROTO_RFCOMM)
            s.settimeout(self.timeout)
            try:
                s.connect((self.mac, self.channel))
                self.sock = s
                return True
            except Exception:
                s.close()
                if attempt + 1 < attempts:
                    time.sleep(delay)
        return False

    def close(self):
        try:
            if self.sock:
                self.sock.close()
        except Exception:
            pass
        self.sock = None

    def _send_ack(self, seq: int):
        try:
            self.sock.sendall(pack_frame(TYPE_ACK, seq ^ 1, b""))
        except Exception:
            pass

    def _read_frames(self, want_ack_for_seq=None, collect=(), timeout=2.0):
        """Read until we see ACK for our seq and/or collected payloads.

        Returns a list of (type, payload). `collect` holds payload prefixes;
        when non-empty, waiting continues until at least one collected payload
        arrived (in addition to the ACK for our own frame).
        """
        got = []
        deadline = time.time() + timeout
        self.sock.settimeout(0.3)

        def collected():
            if not collect:
                return True
            return any(p[: len(c)] == c for _, p in got for c in collect)

        while time.time() < deadline:
            try:
                chunk = self.sock.recv(1024)
            except socket.timeout:
                continue
            except Exception:
                break
            if not chunk:
                break
            self.buf += chunk
            frames, rest = split_frames(self.buf)
            self.buf = rest
            for raw in frames:
                parsed = parse_frame(raw)
                if not parsed:
                    continue
                ftype, seq, payload = parsed
                if ftype == TYPE_ACK:
                    if want_ack_for_seq is not None and seq == (want_ack_for_seq ^ 1):
                        want_ack_for_seq = None
                else:
                    self._send_ack(seq)
                    got.append((ftype, payload))
            if want_ack_for_seq is None and collected():
                break
        return got

    def transact(self, payload: bytes, expect_prefixes=(), retries=3):
        """Send a DATA frame, wait for its ACK, return received non-ACK payloads."""
        for _ in range(retries):
            seq = self.tx_seq
            try:
                self.sock.sendall(pack_frame(TYPE_DATA, seq, payload))
            except Exception:
                return []
            got = self._read_frames(want_ack_for_seq=seq, collect=expect_prefixes)
            self.tx_seq ^= 1
            # If device ACKed (seq advanced next loop would reuse otherwise), accept.
            # We cannot directly observe ACK here; treat any reply or timeout-then-retry.
            if got:
                return got
        return got


# ---------------------------------------------------------------- queries


def _load_cache():
    try:
        with open(STATE_FILE, "r") as f:
            return json.load(f)
    except Exception:
        return {}


def _save_cache(state):
    """Write the cache atomically so concurrent CLI runs never see a torn file."""
    tmp = STATE_FILE + ".tmp"
    try:
        with open(tmp, "w") as f:
            json.dump(state, f, indent=2, ensure_ascii=False)
        os.replace(tmp, STATE_FILE)
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass


def _parse_battery(payloads):
    level, charging = None, False
    for ftype, p in payloads:
        # POWER_RET_STATUS [0x23 0x00 level charging] / POWER_NTFY_STATUS [0x25 ...]
        if len(p) >= 4 and p[0] in (0x23, 0x25) and p[1] == 0x00:
            level = p[2]
            charging = bool(p[3])
            break
    return level, charging


def _parse_nc(payloads):
    """Returns (mode, subtype) or (None, None).

    WH-1000XM5 verified layout (7-byte RET 0x67 / NTFY 0x69):
        [cmd, 0x17|0x19, 0x01, on_off, ambient_flag, focus?, x]
        on_off: 0x00 = off, else on; ambient_flag 0x01 = ambient sound.
    The subtype (0x17 for XM5, 0x19 for XM6) is remembered so the matching
    set payload uses the same one the device answered to.
    NOTE: the device does not echo the ambient level (0-20) in this reply,
    so the level is tracked locally (last value we set, persisted in cache).
    """
    for ftype, p in payloads:
        if len(p) >= 6 and p[0] in (0x67, 0x69) and p[1] in (0x17, 0x19):
            on_off = p[3]
            ambient_flag = p[4]
            if on_off == 0x00:
                return MODE_OFF, p[1]
            if ambient_flag == 0x01:
                return MODE_TRANSPARENCY, p[1]
            return MODE_ANC, p[1]
    return None, None


def _canonical_model(name):
    """Map an advertised Bluetooth name to a known model label, or None."""
    low = (name or "").lower()
    for known, canonical in MODEL_NAMES.items():
        if known.lower() in low:
            return canonical
    return None


def query_device(mac: str, device_name=None):
    prev = _load_cache()
    state = {
        "connected": True,
        "mac": mac,
        "device_name": device_name or prev.get("device_name") or "Sony Headphones",
        "model_name": device_name or prev.get("model_name") or "Sony Headphones",
        "noise_mode": prev.get("noise_mode", "unknown"),
        "ambient_level": prev.get("ambient_level", 0),
        "focus_voice": prev.get("focus_voice", False),
        "battery": prev.get("battery", -1),
        "battery_left": prev.get("battery_left", -1),
        "battery_right": prev.get("battery_right", -1),
        "battery_case": prev.get("battery_case", -1),
        "charging": prev.get("charging", False),
        "timestamp": int(time.time()),
    }
    canonical = _canonical_model(state["device_name"])
    if canonical:
        state["model_name"] = canonical

    channel = resolve_channel(mac)
    sess = SonySession(mac, channel)
    if not sess.open():
        # Transport busy/refused: fall back to cache + BlueZ battery.
        bz = bluez_battery(mac)
        if bz is not None:
            state["battery"] = bz
            state["battery_left"] = bz
            state["battery_right"] = bz
        if prev.get("connected"):
            state["timestamp"] = int(time.time())
            return state
        state["connected"] = False
        state["error"] = "Could not connect to Sony RFCOMM (channel %d)" % channel
        return state

    try:
        # Best-effort init (optional on XM5 firmware, harmless).
        sess.transact(P_CONNECT_INFO)
        sess.transact(P_SUPPORT_FUNCTION)

        bat = sess.transact(P_BATTERY, expect_prefixes=(bytes([0x23, 0x00]), bytes([0x25])))
        if not bat:
            bat = sess.transact(P_BATTERY_ALT)
        level, charging = _parse_battery(bat)
        if level is None:
            bz = bluez_battery(mac)
            if bz is not None:
                level, charging = bz, False
        if level is not None:
            state["battery"] = level
            state["battery_left"] = level
            state["battery_right"] = level
            state["charging"] = charging

        nc = sess.transact(P_NC_GET, expect_prefixes=(bytes([0x67]), bytes([0x69])))
        if not nc:
            nc = sess.transact(P_NC_GET_ALT, expect_prefixes=(bytes([0x67]), bytes([0x69])))
        mode, subtype = _parse_nc(nc)
        if mode is not None:
            # Ambient level is not reported by the device; the cached
            # last-set value is kept as-is.
            state["noise_mode"] = mode
            state["nc_subtype"] = subtype

        state["connected"] = True
        state.pop("error", None)
        _save_cache(state)
        return state
    finally:
        sess.close()


def _nc_payload(mode: str, level: int = 0, subtype: int = 0x17) -> bytes:
    """8-byte XM5-verified NC/ASM set payload (MamaJo3 golden bytes).

    `subtype` defaults to 0x17 (XM5) and is 0x19 on XM6; it is taken from the
    cached value the device last answered a GET on.
    """
    if subtype not in (0x17, 0x19):
        subtype = 0x17
    level = max(0, min(20, int(level)))
    if mode == MODE_ANC:
        return bytes([0x68, subtype, 0x01, 0x01, 0x00, 0x02, 0x00, 0x00])
    if mode == MODE_TRANSPARENCY:
        return bytes([0x68, subtype, 0x01, 0x01, 0x01, 0x02, 0x00, level])
    return bytes([0x68, subtype, 0x01, 0x00, 0x00, 0x02, 0x00, 0x00])


def set_nc_mode(mac: str, mode: str, level: int = 0):
    mode = mode.lower()
    if mode not in (MODE_ANC, MODE_TRANSPARENCY, MODE_OFF):
        return {"success": False, "error": "Invalid mode: %s" % mode}
    prev = _load_cache()
    subtype = prev.get("nc_subtype", 0x17)
    sess = SonySession(mac, resolve_channel(mac))
    if not sess.open():
        return {"success": False, "error": "Could not connect to Sony RFCOMM"}
    try:
        sess.transact(_nc_payload(mode, level, subtype))
        prev.update(
            {"noise_mode": mode, "timestamp": int(time.time()), "connected": True, "mac": mac}
        )
        if mode == MODE_TRANSPARENCY:
            prev["ambient_level"] = max(0, min(20, int(level)))
        _save_cache(prev)
        return {"success": True, "mode": mode}
    finally:
        sess.close()


def set_ambient(mac: str, level: int):
    return set_nc_mode(mac, MODE_TRANSPARENCY, level)


def cycle_nc(mac: str):
    cache = _load_cache()
    current = cache.get("noise_mode", MODE_OFF)
    try:
        nxt = CYCLE_MODES[(CYCLE_MODES.index(current) + 1) % len(CYCLE_MODES)]
    except ValueError:
        nxt = MODE_ANC
    level = cache.get("ambient_level", 20) or 20
    # User-facing notifications are the service's job (noctalia.notify); the
    # CLI stays silent so a widget click fires exactly one notification.
    return set_nc_mode(mac, nxt, level)


# ---------------------------------------------------------------- cli


def main():
    parser = argparse.ArgumentParser(description="Sony headphones CLI (MDR V2)")
    parser.add_argument(
        "command", choices=["status", "cached", "set-anc", "set-ambient", "cycle-anc"]
    )
    parser.add_argument("value", nargs="?", help="anc|transparency|off or 0..20")
    parser.add_argument("--mac", help="Headphones Bluetooth MAC address")
    args = parser.parse_args()

    if args.command == "cached":
        print(json.dumps(_load_cache() or {"connected": False}, ensure_ascii=False))
        return

    mac = args.mac or os.environ.get("SONY_MAC")
    device_name = None
    if not mac:
        mac, device_name = find_connected_device()
    if not mac:
        print(json.dumps({"connected": False, "error": "No Sony device connected"}))
        return

    if args.command == "status":
        print(json.dumps(query_device(mac, device_name), ensure_ascii=False))
    elif args.command == "set-anc":
        if not args.value:
            print(json.dumps({"success": False, "error": "Missing mode for set-anc"}))
            sys.exit(1)
        level = _load_cache().get("ambient_level", 20) or 20
        print(json.dumps(set_nc_mode(mac, args.value, level), ensure_ascii=False))
    elif args.command == "set-ambient":
        if args.value is None:
            print(json.dumps({"success": False, "error": "Missing level for set-ambient"}))
            sys.exit(1)
        try:
            level = int(args.value)
        except (TypeError, ValueError):
            print(json.dumps({"success": False, "error": "Invalid level: %s" % args.value}))
            sys.exit(1)
        print(json.dumps(set_ambient(mac, level), ensure_ascii=False))
    elif args.command == "cycle-anc":
        print(json.dumps(cycle_nc(mac), ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as exc:  # never leak a traceback to the service's JSON parser
        print(json.dumps({"connected": False, "error": str(exc)}, ensure_ascii=False))
        sys.exit(1)
