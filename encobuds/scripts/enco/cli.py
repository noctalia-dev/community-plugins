#!/usr/bin/env python3
"""EncoBuds — control OPPO/OnePlus/realme Enco earbuds over Bluetooth RFCOMM.

Speaks the reverse-engineered "OPOv1" protocol (the one the HeyMelody app
uses): frame = AA <varint len> 00 00 <cmd LE16> <seq> <plen LE16> <payload>.

Tested against OPPO Enco Air5 Pro (product id 06C410) on Arch/BlueZ 5.88.

  encobuds                  status (mode, battery, game mode, firmware)
  encobuds off | anc | trans    switch listening mode
  encobuds anc deep|mid|light|smart
  encobuds cycle            off -> smart ANC -> transparency -> off
  encobuds game on|off|toggle   low-latency game mode
  encobuds volume [2-10]    prompt-tone volume 20%-100% (read when no value)
  encobuds find [on|off]    ring the earbuds (on holds the link for 15 s)
  encobuds devices          devices the earbuds remember (0x0112)
  encobuds connect <name|mac>   switch the second link to that device
  encobuds disconnect <name|mac>
  encobuds remove <name|mac> --yes   forget a device
  encobuds menu             zenity picker (desktop friendly)
  encobuds --channel 5 status   force an RFCOMM channel
  encobuds --json status    machine-readable snapshot (Noctalia plugin)
  encobuds --mac AA:BB:.. status  override the address for one call

Config: ~/.config/encobuds/config.json -> {"mac": "AA:BB:CC:DD:EE:FF"}
Env:    ENCOBUDS_MAC, ENCOBUDS_CHANNEL, ENCOBUDS_NO_NOTIFY
"""

from __future__ import annotations

import json
import os
import re
import socket
import struct
import subprocess
import sys
import time
import uuid

CONFIG_PATH = os.path.expanduser("~/.config/encobuds/config.json")

# Set by `--json`: machine-readable output for GUI front ends (the Noctalia
# plugin this CLI is bundled with uses it).
JSON_OUT = False


def emit(payload: dict) -> None:
    print(json.dumps(payload, ensure_ascii=False))


def fail(message: str, code: int = 1) -> int:
    if JSON_OUT:
        emit({"ok": False, "error": message})
    else:
        print(message, file=sys.stderr)
    return code

VENDOR_UUID = uuid.UUID("0000079a-d102-11e1-9b23-00025b00a5a5")
SPP_UUID = uuid.UUID("00001101-0000-1000-8000-00805f9b34fb")

# ---------------------------------------------------------------- protocol ---

CMD_CAPS = 0x0100
CMD_PRODUCT = 0x0103
CMD_FIRMWARE = 0x0105
CMD_BATTERY = 0x0106
CMD_EQ_GET = 0x010F
CMD_ANC_GET = 0x010C
CMD_BATCH = 0x010D
CMD_SET_FEATURE = 0x0403
CMD_ANC_SET = 0x0404
CMD_EQ_SET = 0x0406
CMD_FIND = 0x0400
CMD_PROMPT_SET = 0x0427
CMD_PROMPT_GET = 0x0130
CMD_DEVICES = 0x0112
CMD_DUAL = 0x0429
DUAL_VERB = {"connect": 0x01, "disconnect": 0x02, "remove": 0x03}

RESP = 0x8000
PUSH = 0x0204
PUSH_FEATURE = 0x0500  # 0x05xx status pushes

# Leaf mode ids reported by the earbuds. 0/1/2 are the "parent" buttons: the
# device then picks its remembered level for that family.
MODE_OFF = 3
MODE_ANC = 1
MODE_TRANS = 8
MODE_LABELS = {
    0: "Off (parent)",
    1: "Noise cancellation (parent)",
    2: "Transparency (parent)",
    3: "Off",
    4: "Deep ANC",
    5: "Mid ANC",
    6: "Light ANC",
    7: "Smart ANC",
    8: "Transparency",
    9: "Transparency",
}
# name -> leaf index written as the 2-byte bitmap 1 << index
MODE_WRITE = {
    "off": MODE_OFF,
    "close": MODE_OFF,
    "anc": MODE_ANC,
    "nc": MODE_ANC,
    "deep": 4,
    "mid": 5,
    "medium": 5,
    "light": 6,
    "smart": 7,
    "auto": 7,
    "trans": MODE_TRANS,
    "transparency": MODE_TRANS,
}
FEATURE_GAME = 0x28
FEATURE_LOW_LATENCY = 0x06


def frame(cmd: int, payload: bytes = b"", seq: int = 0) -> bytes:
    body = bytes([cmd & 0xFF, (cmd >> 8) & 0xFF, seq & 0xFF,
                  len(payload) & 0xFF, (len(payload) >> 8) & 0xFF]) + payload
    return bytes([0xAA, len(body) + 2, 0x00, 0x00]) + body


def parse_frames(buf: bytes):
    out, i, n = [], 0, len(buf)
    while i < n:
        if buf[i] != 0xAA:
            i += 1
            continue
        j, shift, length = i + 1, 0, 0
        while j < n:
            b = buf[j]
            length |= (b & 0x7F) << shift
            j += 1
            shift += 7
            if not (b & 0x80):
                break
        else:
            break
        if j + length > n:
            break
        body = buf[j + 2:j + length]
        if len(body) >= 5:
            cmd = body[0] | (body[1] << 8)
            plen = body[3] | (body[4] << 8)
            out.append((cmd, body[2], bytes(body[5:5 + plen])))
        i = j + length
    return out, buf[i:]


# ---------------------------------------------------------------- transport ---

class Link:
    def __init__(self, mac: str, channel: int, timeout: float = 6.0):
        self.mac = mac
        self.sock = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_STREAM,
                                  socket.BTPROTO_RFCOMM)
        self.sock.settimeout(timeout)
        self.sock.connect((mac, channel))
        self.channel = channel
        self.seq = 0
        self.buf = bytearray()
        self.pushes: list[tuple[int, bytes]] = []

    def _pump(self, deadline: float, want: int | None, seq: int | None):
        while time.time() < deadline:
            self.sock.settimeout(max(0.05, deadline - time.time()))
            try:
                data = self.sock.recv(4096)
            except socket.timeout:
                return None
            except OSError:
                return None
            if not data:
                return None
            self.buf.extend(data)
            frames, tail = parse_frames(self.buf)
            self.buf = bytearray(tail)
            for cmd, fseq, payload in frames:
                if cmd == PUSH:
                    self.pushes.append((fseq, payload))
                    continue
                if want is not None and cmd == want and (seq is None or fseq == seq):
                    return payload
        return None

    def request(self, cmd: int, payload: bytes = b"", want: int | None = None,
                timeout: float = 2.0):
        want = cmd | RESP if want is None else want
        self.seq = (self.seq + 1) & 0xFF
        seq = self.seq
        self.sock.sendall(frame(cmd, payload, seq))
        return self._pump(time.time() + timeout, want, seq)

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


# ------------------------------------------------------------------ devices ---

def bluetoothctl(*args: str) -> str:
    try:
        return subprocess.run(["bluetoothctl", *args], capture_output=True,
                              text=True, timeout=6).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def is_connected(mac: str) -> bool:
    return re.search(r"^\s*Connected:\s*yes\s*$", bluetoothctl("info", mac),
                     re.MULTILINE) is not None


def device_names() -> list[tuple[str, str]]:
    out = []
    for line in bluetoothctl("devices").splitlines():
        m = re.match(r"^\s*Device\s+([0-9A-Fa-f:]{17})\s+(.*\S)\s*$", line)
        if m:
            out.append((m.group(1), m.group(2)))
    return out


def find_mac() -> str | None:
    if os.environ.get("ENCOBUDS_MAC"):
        return os.environ["ENCOBUDS_MAC"].strip()
    try:
        with open(CONFIG_PATH) as fh:
            mac = str(json.load(fh).get("mac", "")).strip()
        if re.fullmatch(r"([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}", mac):
            return mac
    except (OSError, ValueError):
        pass
    devices = device_names()
    # "enco"/"oppo" are unambiguous; a paired phone called "OnePlus 8 Pro"
    # must not be mistaken for the buds, hence the stricter fallback.
    for strong in (True, False):
        for mac, name in devices:
            low = name.lower()
            hit = ("enco" in low or "oppo" in low) if strong else \
                ("buds" in low and ("oneplus" in low or "realme" in low))
            if hit:
                return mac
    return None


# --------------------------------------------------------------- sdp channel ---

def _de(buf: bytes, i: int = 0):
    t = buf[i]
    i += 1
    n = t & 7
    if n == 5:
        ln = buf[i]
        i += 1
    elif n == 6:
        ln = struct.unpack(">H", buf[i:i + 2])[0]
        i += 2
    elif n == 7:
        ln = struct.unpack(">I", buf[i:i + 4])[0]
        i += 4
    else:
        ln = 1 << n
    return t, buf[i:i + ln], i + ln


def sdp_rfcomm_channel(mac: str, service_uuid: uuid.UUID) -> int | None:
    """Ask the device's SDP server for the RFCOMM channel of one service."""
    pattern = bytes([0x35, 0x11, 0x1C]) + service_uuid.bytes
    attrs = bytes([0x35, 0x05, 0x0A, 0x00, 0x00, 0xFF, 0xFF])
    params = pattern + struct.pack(">H", 0xFFFF) + attrs + b"\x00"
    pdu = b"\x06" + struct.pack(">HH", 0x0001, len(params)) + params
    sock = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_SEQPACKET, 0)
    sock.settimeout(6)
    try:
        sock.connect((mac, 1))
        sock.send(pdu)
        data = sock.recv(65535)
    except OSError:
        return None
    finally:
        sock.close()
    if len(data) < 5 or data[0] != 0x07:
        return None
    # Walk records for attribute 0x0004 (protocol descriptor list) and pick the
    # RFCOMM (0x0003) entry, whose next byte is the channel.
    body = data[5:5 + struct.unpack(">H", data[3:5])[0]]
    i = 2 if body[:1] == b"\x36" else 0
    while i < len(body):
        t, rec, i = _de(body, i)
        if t >> 3 != 6:
            continue
        j = 0
        while j < len(rec):
            at, av, j = _de(rec, j)
            if at >> 3 != 1:
                continue
            aid = int.from_bytes(av, "big")
            if aid != 0x0004:
                continue
            k = 0
            while k < len(av):
                pt, pv, k = _de(av, k)
                if pt >> 3 != 6:
                    continue
                items, m = [], 0
                while m < len(pv):
                    it, iv, m = _de(pv, m)
                    items.append((it, iv))
                if len(items) >= 2 and items[0][1] == b"\x00\x03":
                    return int.from_bytes(items[1][1], "big")
    return None


def open_link(mac: str, forced: int | None = None) -> Link:
    candidates: list[int] = []
    if forced:
        candidates.append(forced)
    else:
        if os.environ.get("ENCOBUDS_CHANNEL"):
            candidates.append(int(os.environ["ENCOBUDS_CHANNEL"]))
        for svc in (VENDOR_UUID, SPP_UUID):
            ch = sdp_rfcomm_channel(mac, svc)
            if ch and ch not in candidates:
                candidates.append(ch)
        candidates += [c for c in (15, 5, 4, 12, 1) if c not in candidates]
    errors = []
    for ch in candidates:
        try:
            link = Link(mac, ch, timeout=5)
        except OSError as exc:
            errors.append(f"{ch}: {exc}")
            continue
        # channel sanity check: the control port answers a battery query
        if link.request(CMD_BATTERY, timeout=1.5) is not None:
            return link
        link.close()
        errors.append(f"{ch}: no reply")
    raise SystemExit(
        "Could not connect to the earbuds control channel (" + ", ".join(errors) + ")\n"
        "Make sure the earbuds are powered on and connected to this machine; "
        "bluetoothctl info must report Connected: yes.")


# ------------------------------------------------------------------ decoders ---

def decode_battery(payload: bytes) -> dict[str, dict]:
    out: dict[str, dict] = {}
    if len(payload) < 2:
        return out
    count = payload[1]
    for k in range(count):
        i = 2 + 2 * k
        if i + 1 >= len(payload):
            break
        dev, val = payload[i], payload[i + 1]
        out[{1: "left", 2: "right", 3: "case"}.get(dev, f"id{dev}")] = {
            "level": val & 0x7F, "charging": bool(val & 0x80)}
    return out


def decode_anc(payload: bytes) -> int | None:
    if len(payload) < 5:
        return None
    bm = int.from_bytes(payload[3:5], "little")
    return bm.bit_length() - 1 if bm else None


def decode_product(payload: bytes) -> str:
    return payload[1:4][::-1].hex().upper() if len(payload) >= 4 else "?"


DEVICE_STATE = {0: "Disconnected", 1: "Connected", 2: "Connected · active"}
DEVICE_TYPE = {0: "Other", 1: "Phone", 2: "Computer", 3: "Tablet", 4: "Watch", 5: "Band"}


def decode_devices(payload: bytes) -> list[dict]:
    """0x0112 -> [count] then per entry: MAC(6, little endian), entry_len,
    state, flags (bit0 current host / bit1 primary audio / bit2 playing / bit3-5 type),
    name_len, name (UTF-8)."""
    out: list[dict] = []
    if len(payload) < 2:
        return out
    i = 2
    for _ in range(payload[1]):
        if i + 10 > len(payload):
            break
        nlen = payload[i + 9]
        out.append({
            "mac": ":".join(f"{b:02X}" for b in payload[i:i + 6][::-1]),
            "state": payload[i + 7],
            "flags": payload[i + 8],
            "type": (payload[i + 8] >> 3) & 7,
            "name": payload[i + 10:i + 10 + nlen].decode("utf-8", "replace"),
        })
        i += 10 + nlen
    return out


def pick_device(devs: list[dict], target: str) -> str | None:
    t = target.strip()
    if re.fullmatch(r"([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}", t):
        return t.upper()
    low = t.lower()
    exact = [d for d in devs if d["name"].lower() == low]
    if exact:
        return exact[0]["mac"]
    part = [d for d in devs if low in d["name"].lower()]
    return part[0]["mac"] if len(part) == 1 else None


def print_devices(devs: list[dict]) -> None:
    print(f"Remembered devices ({len(devs)})")
    for d in devs:
        tags = "".join(t for bit, t in ((1, " current host"), (2, " primary audio"),
                                        (4, " playing")) if d["flags"] & bit)
        print(f"  {d['name']:<16} {d['mac']}  "
              f"{DEVICE_STATE.get(d['state'], d['state'])}"
              f"  {DEVICE_TYPE.get(d['type'], d['type'])}{tags}")


def dual_action(link: Link, verb: str, mac: str, attempts: int = 3,
                per_try: float = 8.0):
    """0x0429 <verb> <MAC in display order>; success is judged by 0x0112.

    The earbuds drop the other secondary link by themselves when the new one
    connects, so a plain "connect" is enough for a swap. A verb that lands a
    couple of seconds after a previous one is ignored by the firmware until it
    settles, hence the retries (the official client does the same).
    """
    raw = bytes.fromhex(mac.replace(":", ""))
    status = None
    devs: list[dict] = []
    for attempt in range(attempts):
        ack = link.request(CMD_DUAL, bytes([DUAL_VERB[verb]]) + raw, timeout=2.0)
        status = ack[0] if ack else None
        deadline = time.time() + per_try
        while time.time() < deadline:
            time.sleep(1.0)
            p = link.request(CMD_DEVICES, timeout=1.5)
            devs = decode_devices(p) if p else []
            cur = next((d["state"] for d in devs if d["mac"] == mac), None)
            if verb == "connect" and cur in (1, 2):
                return devs, status, True
            if verb == "disconnect" and cur == 0:
                return devs, status, True
            if verb == "remove" and cur is None:
                return devs, status, True
        if attempt + 1 < attempts:
            print(f"No effect yet; retry {attempt + 2}/{attempts}…", file=sys.stderr)
            time.sleep(2.0)
    return devs, status, False


def mode_name(idx: int | None) -> str:
    if idx is None:
        return "Unknown"
    return MODE_LABELS.get(idx, f"Unknown ({idx})")


# ------------------------------------------------------------------- actions ---

def get_state(link: Link) -> dict:
    state: dict = {}
    p = link.request(CMD_ANC_GET, b"\x01\x01")
    state["anc"] = decode_anc(p) if p else None
    p = link.request(CMD_BATTERY)
    state["battery"] = decode_battery(p) if p else {}
    p = link.request(CMD_BATCH, bytes([0x02, FEATURE_GAME, FEATURE_LOW_LATENCY]))
    feats: dict[int, int] = {}
    if p and len(p) >= 2:
        for k in range(p[1]):
            i = 2 + 2 * k
            if i + 1 < len(p):
                feats[p[i]] = p[i + 1]
    state["features"] = feats
    p = link.request(CMD_PRODUCT)
    state["product"] = decode_product(p) if p else "?"
    p = link.request(CMD_FIRMWARE)
    state["firmware"] = p[2:].decode("ascii", "replace").strip("\x00") if p else "?"
    p = link.request(CMD_PROMPT_GET)
    state["volume"] = p[1] if p and len(p) >= 2 else None
    p = link.request(CMD_DEVICES)
    state["devices"] = decode_devices(p) if p else []
    return state


def state_json(state: dict, mac: str | None = None,
               channel: int | None = None) -> dict:
    feats = state.get("features", {})
    game = feats.get(FEATURE_GAME)
    return {
        "ok": True,
        "mac": mac,
        "channel": channel,
        "mode": state.get("anc"),
        "mode_name": mode_name(state.get("anc")),
        "battery": state.get("battery", {}),
        "features": {str(k): v for k, v in feats.items()},
        "game": None if game is None else bool(game),
        "volume": state.get("volume"),
        "devices": devices_json(state.get("devices", [])),
        "product": state.get("product", "?"),
        "firmware": state.get("firmware", "?"),
    }


def devices_json(devs: list[dict]) -> list[dict]:
    out = []
    for d in devs:
        flags = d["flags"]
        out.append({
            "mac": d["mac"],
            "name": d["name"],
            "state": d["state"],
            "state_name": DEVICE_STATE.get(d["state"], str(d["state"])),
            "type": d["type"],
            "type_name": DEVICE_TYPE.get(d["type"], str(d["type"])),
            "flags": flags,
            "current": bool(flags & 1),
            "primary_audio": bool(flags & 2),
            "playing": bool(flags & 4),
            "connected": d["state"] in (1, 2),
        })
    return out


def set_anc(link: Link, index: int) -> int | None:
    ack = link.request(CMD_ANC_SET, b"\x01\x01" + struct.pack("<H", 1 << index))
    if ack is None or ack[:1] != b"\x00":
        return None
    for _ in range(4):
        time.sleep(0.35)
        p = link.request(CMD_ANC_GET, b"\x01\x01", timeout=1.0)
        if p is not None:
            return decode_anc(p)
    return None


def notify(text: str) -> None:
    """Show the result when run from a keybind/launcher instead of a terminal."""
    if JSON_OUT or sys.stdout.isatty() or os.environ.get("ENCOBUDS_NO_NOTIFY"):
        return
    for argv in (["noctalia", "msg", "notification-show", "EncoBuds", text],
                 ["notify-send", "EncoBuds", text]):
        try:
            subprocess.run(argv, capture_output=True, timeout=5)
            return
        except (OSError, subprocess.TimeoutExpired):
            continue


def print_status(state: dict, mac: str | None = None) -> None:
    anc = state.get("anc")
    print(f"Mode      {mode_name(anc)}")
    batt = state.get("battery", {})
    parts = []
    for key, label in (("left", "Left"), ("right", "Right"), ("case", "Case")):
        b = batt.get(key)
        if b:
            parts.append(f"{label} {b['level']}%{'⚡' if b['charging'] else ''}")
    print("Battery   " + ("  ".join(parts) if parts else "not reported"))
    game = state.get("features", {}).get(FEATURE_GAME)
    print("Game mode " + ("On" if game else "Off" if game == 0 else "Unknown"))
    print(f"Firmware  {state.get('firmware', '?')}   model {state.get('product', '?')}")
    if mac:
        print(f"Address   {mac}")


def cmd_menu(mac: str) -> int:
    link = open_link(mac)
    try:
        state = get_state(link)
    finally:
        link.close()
    cur = state.get("anc")
    batt = state.get("battery", {})
    info = "  ".join(
        f"{ {'left':'Left','right':'Right','case':'Case'}[k] } {v['level']}%"
        for k, v in batt.items())
    rows = [
        ("off", "Off"),
        ("smart", "Smart ANC"),
        ("deep", "Deep ANC"),
        ("mid", "Mid ANC"),
        ("light", "Light ANC"),
        ("trans", "Transparency"),
    ]
    args = ["zenity", "--list", "--title=EncoBuds",
            f"--text=<b>{mode_name(cur)}</b>\n{info}",
            "--radiolist", "--column=Mode"]
    chosen_idx = {MODE_OFF: "off", 7: "smart", 4: "deep", 5: "mid",
                  6: "light", MODE_TRANS: "trans"}.get(cur)
    label_to_key = {}
    for key, label in rows:
        label_to_key[label] = key
        args += ["TRUE" if key == chosen_idx else "FALSE", label]
    try:
        res = subprocess.run(args, capture_output=True, text=True)
    except OSError as exc:
        print(f"zenity is unavailable: {exc}", file=sys.stderr)
        return 1
    picked = res.stdout.strip().split("|")[0].strip()
    if res.returncode != 0 or picked not in label_to_key:
        return 0
    key = label_to_key[picked]
    link = open_link(mac)
    try:
        got = set_anc(link, MODE_WRITE[key])
    finally:
        link.close()
    print(f"Switched to {mode_name(got)}" if got is not None else "Switch failed")
    return 0 if got is not None else 1

def usage(code: int = 0) -> int:
    print(__doc__.strip())
    return code


def main(argv: list[str] | None = None) -> int:
    global JSON_OUT
    args = list((sys.argv if argv is None else argv)[1:])
    forced = None
    if "--json" in args:
        JSON_OUT = True
        args.remove("--json")
    if "--channel" in args:
        i = args.index("--channel")
        forced = int(args[i + 1])
        del args[i:i + 2]
    mac_override = None
    if "--mac" in args:
        i = args.index("--mac")
        mac_override = args[i + 1].strip().upper()
        del args[i:i + 2]
    if not args or args[0] in ("-h", "--help", "help"):
        return usage(0 if args else 1)

    mac = mac_override or find_mac()
    if not mac:
        return fail("Could not find the earbuds MAC address: write "
                    '{"mac": "AA:BB:CC:DD:EE:FF"} to ~/.config/encobuds/config.json '
                    "or set ENCOBUDS_MAC.", 2)
    if not is_connected(mac):
        return fail(f"Earbuds {mac} are not connected; connect them in the system Bluetooth settings first.", 2)

    verb = args[0].lower()
    try:
        if verb in ("status", "st", "state"):
            link = open_link(mac, forced)
            try:
                state = get_state(link)
                channel = link.channel
            finally:
                link.close()
            if JSON_OUT:
                emit(state_json(state, mac, channel))
            else:
                print_status(state, mac)
            return 0

        if verb in ("menu", "ui", "gui"):
            return cmd_menu(mac)

        if verb in ("devices", "devs", "list"):
            link = open_link(mac, forced)
            try:
                p = link.request(CMD_DEVICES)
            finally:
                link.close()
            devs = decode_devices(p) if p else []
            if JSON_OUT:
                emit({"ok": True, "devices": devices_json(devs)})
            else:
                print_devices(devs)
            return 0

        if verb in DUAL_VERB:
            if len(args) < 2:
                return fail(f"Usage: encobuds {verb} <device name or MAC>", 2)
            if verb == "remove" and "--yes" not in args:
                return fail("Removing a device is irreversible; add --yes to confirm.", 2)
            link = open_link(mac, forced)
            try:
                p = link.request(CMD_DEVICES)
                devs = decode_devices(p) if p else []
                target = pick_device(devs, args[1])
                if not target:
                    if JSON_OUT:
                        emit({"ok": False, "error": f"Device {args[1]!r} not found (or matches more than one)",
                              "devices": devices_json(devs)})
                    else:
                        print_devices(devs)
                        print(f"Device {args[1]!r} not found (or matches more than one)", file=sys.stderr)
                    return 2
                devs, status, ok = dual_action(link, verb, target)
            finally:
                link.close()
            label = {"connect": "Connect", "disconnect": "Disconnect",
                     "remove": "Remove"}[verb]
            if JSON_OUT:
                emit({"ok": ok, "verb": verb, "target": target, "ack": status,
                      "error": None if ok else f"{label} did not take effect (ack={status})",
                      "devices": devices_json(devs)})
            else:
                print_devices(devs)
                print(f"{label} {target}: "
                      + (" succeeded" if ok else f" did not take effect (ack={status})"))
                notify(f"{label} {target} " + ("succeeded" if ok else "failed"))
            return 0 if ok else 1

        if verb in ("battery", "bat"):
            link = open_link(mac, forced)
            try:
                p = link.request(CMD_BATTERY)
                batt = decode_battery(p) if p else {}
            finally:
                link.close()
            if JSON_OUT:
                emit({"ok": True, "battery": batt})
            else:
                print(json.dumps(batt, ensure_ascii=False))
            return 0

        if verb in ("off", "close", "anc", "nc", "deep", "mid", "medium",
                    "light", "smart", "auto", "trans", "transparency", "on"):
            if verb in ("anc", "nc", "trans", "transparency", "on") and len(args) > 1:
                key = args[1].lower()      # e.g. `encobuds anc deep`
            else:
                key = "anc" if verb == "on" else verb
            if key not in MODE_WRITE:
                return fail(f"Unknown mode {key}; available: {', '.join(sorted(MODE_WRITE))}", 2)
            link = open_link(mac, forced)
            try:
                got = set_anc(link, MODE_WRITE[key])
            finally:
                link.close()
            if JSON_OUT:
                if got is None:
                    return fail("Switch failed (the earbuds did not confirm it)", 1)
                emit({"ok": True, "mode": got, "mode_name": mode_name(got)})
            else:
                if got is None:
                    print("Switch failed (the earbuds did not confirm it)", file=sys.stderr)
                    return 1
                print(mode_name(got))
                notify(mode_name(got))
            return 0

        if verb == "cycle":
            link = open_link(mac, forced)
            try:
                p = link.request(CMD_ANC_GET, b"\x01\x01")
                cur = decode_anc(p) if p else None
                order = [(MODE_OFF, "off"), (7, "smart"), (MODE_TRANS, "trans")]
                idx = next((k for k, (leaf, _) in enumerate(order) if leaf == cur), None)
                if cur in (4, 5, 6, 1):        # any ANC level -> next is transparency
                    nxt = MODE_TRANS
                else:
                    nxt = order[(idx + 1) % len(order)][0] if idx is not None else MODE_OFF
                got = set_anc(link, nxt)
            finally:
                link.close()
            if JSON_OUT:
                if got is None:
                    return fail("Switch failed (the earbuds did not confirm it)", 1)
                emit({"ok": True, "mode": got, "mode_name": mode_name(got)})
            else:
                print(mode_name(got))
                notify(mode_name(got))
            return 0 if got is not None else 1

        if verb == "game":
            want = args[1].lower() if len(args) > 1 else "toggle"
            link = open_link(mac, forced)
            try:
                if want == "toggle":
                    p = link.request(CMD_BATCH, bytes([0x01, FEATURE_GAME]))
                    cur = 0
                    if p and len(p) >= 4:
                        cur = p[3]
                    want = "off" if cur else "on"
                val = 1 if want in ("on", "1", "true", "enable") else 0
                ack = link.request(CMD_SET_FEATURE, bytes([FEATURE_GAME, val]))
                if ack is None or ack[:1] != b"\x00":
                    return fail("Setting failed", 1)
                time.sleep(0.3)
                p = link.request(CMD_BATCH, bytes([0x01, FEATURE_GAME]))
                got = p[3] if p and len(p) >= 4 else None
            finally:
                link.close()
            if JSON_OUT:
                emit({"ok": got == val,
                      "game": None if got is None else bool(got),
                      "error": None if got == val else "Setting failed"})
            else:
                print("Game mode " + ("On" if got else "Off" if got == 0 else "Unknown"))
            return 0 if got == val else 1

        if verb in ("volume", "vol"):
            link = open_link(mac, forced)
            try:
                if len(args) > 1:
                    val = int(args[1])
                    if not 2 <= val <= 10:
                        return fail("Prompt volume range is 2-10 (20%-100%)", 2)
                    link.request(CMD_PROMPT_SET, bytes([val]))
                    time.sleep(0.3)
                p = link.request(CMD_PROMPT_GET)
                volume = p[1] if p and len(p) >= 2 else None
            finally:
                link.close()
            if JSON_OUT:
                emit({"ok": volume is not None, "volume": volume})
            else:
                print(f"{volume * 10}%" if volume is not None else "?")
            return 0

        if verb == "find":
            want = "on"
            hold = 15.0
            stop_file = None
            i = 1
            while i < len(args):
                arg = args[i]
                if arg == "--hold" and i + 1 < len(args):
                    hold = max(0.0, float(args[i + 1]))
                    i += 2
                elif arg == "--stop-file" and i + 1 < len(args):
                    stop_file = args[i + 1]
                    i += 2
                else:
                    want = arg.lower()
                    i += 1
            val = 0 if want in ("off", "stop", "0") else 1
            link = open_link(mac, forced)
            ok = False
            try:
                ack = link.request(CMD_FIND, bytes([val]))
                ok = ack is not None and ack[:1] == b"\x00"
                if JSON_OUT:
                    emit({"ok": ok, "ringing": bool(val) if ok else None,
                          "error": None if ok else "failed"})
                else:
                    print("Ringing" if val and ok else "Stopped ringing" if ok else "Failed")
                # Find is an active session: the tone stops when the RFCOMM
                # link closes, so keep it open for the requested hold time.
                if val and ok and hold > 0:
                    deadline = time.time() + hold
                    try:
                        while time.time() < deadline:
                            if stop_file and os.path.exists(stop_file):
                                break
                            time.sleep(0.2)
                    except KeyboardInterrupt:
                        pass
                    finally:
                        link.request(CMD_FIND, b"\x00", timeout=2.0)
            finally:
                link.close()
            return 0 if ok else 1

        if JSON_OUT:
            return fail(f"Unknown command: {verb}", 2)
        print(f"Unknown command: {verb}", file=sys.stderr)
        return usage(2)
    except SystemExit as exc:
        return fail(str(exc), 2)
    except BrokenPipeError:
        return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
