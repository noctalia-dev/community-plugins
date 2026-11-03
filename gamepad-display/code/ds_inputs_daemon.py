#!/usr/bin/env python3
"""
Live input reader for the Noctalia plugin.

Reads the evdev node the kernel exposes for a gamepad (buttons, D-pad, both
sticks and both triggers) and publishes a compact JSON state. The plugin
service forwards those lines to the "Gamepad Display" desktop widget.

Supported out of the box: DualSense, DualSense Edge, DualShock 4 and 8BitDo
pads (plus any XInput-style pad with a standard evdev mapping). Axis roles are
derived from each device's capabilities, because e.g. the 8BitDo uses
ABS_Z/ABS_RZ for its right stick and ABS_BRAKE/ABS_GAS for its left/right
triggers.

When several pads are connected, the one you touched last is shown; plugging a
pad in also takes over the widget.

Unlike the battery daemon this never opens hidraw, so it runs happily next to
ds4u and the kernel driver at the same time.

Modes:
  (default)   keep the state file fresh
  --stream    also print one compact JSON object per line (used by inputs.luau)
  --demo      ignore hardware and stream an animated fake controller (layout preview)

Only the Python 3 standard library is needed.
"""
import fcntl
import glob
import json
import math
import os
import select
import signal
import struct
import subprocess
import sys
import time
from array import array

EV_KEY = 0x01
EV_ABS = 0x03

# linux/input-event-codes.h
BTN_CODES = {
    0x130: "cross",     # BTN_SOUTH
    0x131: "circle",    # BTN_EAST
    0x133: "triangle",  # BTN_NORTH
    0x134: "square",    # BTN_WEST
    0x136: "l1",        # BTN_TL
    0x137: "r1",        # BTN_TR
    0x138: "l2",        # BTN_TL2
    0x139: "r2",        # BTN_TR2
    0x13A: "create",    # BTN_SELECT
    0x13B: "options",   # BTN_START
    0x13C: "ps",        # BTN_MODE
    0x13D: "l3",        # BTN_THUMBL
    0x13E: "r3",        # BTN_THUMBR
    0x110: "touchpad",  # BTN_LEFT (touchpad click)
    0x248: "mute",      # KEY_MICMUTE
}
BUTTON_ORDER = (
    "cross", "circle", "triangle", "square",
    "l1", "r1", "l2", "r2",
    "create", "options", "ps", "l3", "r3", "touchpad", "mute",
)

ABS_X, ABS_Y, ABS_Z = 0x00, 0x01, 0x02
ABS_RX, ABS_RY, ABS_RZ = 0x03, 0x04, 0x05
ABS_GAS, ABS_BRAKE = 0x09, 0x0A
ABS_HAT0X, ABS_HAT0Y = 0x10, 0x11

DS_PID = 0x0CE6
DSE_PID = 0x0DF2
DS4_PID = 0x05C4
DS4_V2_PID = 0x09CC
DS_PIDS = (DS_PID, DSE_PID)
DS4_PIDS = (DS4_PID, DS4_V2_PID)
SONY_PIDS = DS_PIDS + DS4_PIDS

SONY_VENDOR = 0x054C
EIGHTBITDO_VENDOR = 0x2DC8
MICROSOFT_VENDOR = 0x045E
SONY_VENDOR_NAME = "sony interactive entertainment"
SONY_VENDOR_NAME_ALT = "sony computer entertainment"
DEVICE_NAME = "DualSense"
DS4_DEVICE_NAME = "wireless controller"

# Lower is picked first when several pads are connected and none was touched.
MODEL_PRIORITY = {"dualsense": 0, "edge": 0, "ds4": 0, "8bitdo": 1, "xinput": 2}

# Input nodes that belong to a pad but are not the gamepad itself.
SKIP_HINTS = (
    "motion", "sensor", "touchpad", "touch pad", "consumer control",
    "keyboard", "mouse",
)

# Software pads (Sunshine streaming, uinput helpers) must never take over.
VIRTUAL_HINTS = (
    "sunshine", "libvirtualhid", "uinput", "virtual gamepad",
    "virtual controller", "steam virtual",
)


def model_for_pid(pid):
    """Map a Sony product id to the model name the widget understands."""
    if pid == DSE_PID:
        return "edge"
    if pid in DS4_PIDS:
        return "ds4"
    if pid == DS_PID:
        return "dualsense"
    return ""


def model_for_name(name):
    """Guess the model from an evdev device name when the HID id is unknown."""
    lowered = name.lower()
    # Vendor names win: the 8BitDo USB receiver also calls itself a
    # "Wireless Controller", as does a DualShock 4.
    if "8bitdo" in lowered:
        return "8bitdo"
    if "edge" in lowered:
        return "edge"
    if "dualsense" in lowered:
        return "dualsense"
    if "dualshock" in lowered:
        return "ds4"
    if "xbox" in lowered or "x-box" in lowered or "xinput" in lowered:
        return "xinput"
    if SONY_VENDOR_NAME in lowered or SONY_VENDOR_NAME_ALT in lowered:
        return "ds4" if DS4_DEVICE_NAME in lowered else ""
    if DS4_DEVICE_NAME in lowered:
        return "ds4"
    return ""


def model_for_hid(vendor, pid, name=""):
    """Map a HID vendor/product pair (plus name fallback) to a model."""
    if vendor == SONY_VENDOR and pid in SONY_PIDS:
        return model_for_pid(pid)
    if vendor == EIGHTBITDO_VENDOR:
        return "8bitdo"
    if vendor == MICROSOFT_VENDOR:
        return "xinput"
    return model_for_name(name or "")

EVENT = struct.Struct("@llHHi")
EVENT_SIZE = EVENT.size
EVIOCGABS = 0x80184540  # _IOR('E', 0x40 + axis, struct input_absinfo)

EMIT_INTERVAL = 1.0 / 50.0   # s between streamed frames while input changes
HEARTBEAT = 1.0              # s between idle frames
RESCAN_INTERVAL = 2.0        # s between device scans while disconnected
STATE_WRITE_INTERVAL = 0.5   # s between state-file writes

RUNTIME_DIR = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
STATE_FILE = os.path.join(RUNTIME_DIR, "noctalia-dualsense-inputs.json")
LOCK_FILE = os.path.join(RUNTIME_DIR, "noctalia-dualsense-inputs.lock")
DAEMON_VERSION = "1.2.0"


def event_device_name(node):
    """Read the input device's name from sysfs."""
    try:
        with open(f"/sys/class/input/{os.path.basename(node)}/device/name") as f:
            return f.read().strip()
    except OSError:
        return ""


def _read_hex(path):
    try:
        with open(path) as f:
            return int(f.read().strip(), 16)
    except (OSError, ValueError):
        return 0


def _read_text(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def hid_device_info(node):
    """Collect bus/vendor/product/name/uniq for the device behind a node.

    HID devices (USB or Bluetooth) expose HID_ID in an ancestor uevent. Some
    pads - notably the 8BitDo USB receiver, which is bound by xpad - have no
    HID ancestor at all, so fall back to the USB device ids.
    """
    try:
        current = os.path.realpath(f"/sys/class/input/{os.path.basename(node)}/device")
    except OSError:
        return None
    for _ in range(8):
        current = os.path.dirname(current)
        if not os.path.isdir(current):
            break
        uevent = os.path.join(current, "uevent")
        content = ""
        if os.path.isfile(uevent):
            try:
                with open(uevent) as f:
                    content = f.read()
            except OSError:
                content = ""
        if "HID_ID=" in content:
            info = {"bus": "", "vendor": 0, "product": 0, "name": "", "uniq": "", "path": current}
            for line in content.splitlines():
                key, _, value = line.partition("=")
                if key == "HID_ID":
                    parts = value.split(":")
                    if len(parts) == 3:
                        try:
                            info["bus"] = parts[0].upper()
                            info["vendor"] = int(parts[1], 16)
                            info["product"] = int(parts[2], 16)
                        except ValueError:
                            pass
                elif key == "HID_NAME":
                    info["name"] = value
                elif key == "HID_UNIQ":
                    info["uniq"] = value
            return info
        if os.path.isfile(os.path.join(current, "idVendor")):
            return {
                "bus": "0003",
                "vendor": _read_hex(os.path.join(current, "idVendor")),
                "product": _read_hex(os.path.join(current, "idProduct")),
                "name": _read_text(os.path.join(current, "product")),
                "uniq": _read_text(os.path.join(current, "serial")),
                "path": current,
            }
    return None


def bluez_battery(address):
    """Battery percentage from BlueZ org.bluez.Battery1, or None."""
    if not address or ":" not in address:
        return None
    dev = "dev_" + address.upper().replace(":", "_")
    for hci in ("hci0", "hci1", "hci2"):
        try:
            out = subprocess.run(
                [
                    "busctl", "--system", "get-property", "org.bluez",
                    f"/org/bluez/{hci}/{dev}", "org.bluez.Battery1", "Percentage",
                ],
                capture_output=True, text=True, timeout=2,
            ).stdout.split()
        except (OSError, subprocess.SubprocessError):
            continue
        for token in reversed(out):
            if token.isdigit():
                return max(0, min(100, int(token)))
    return None


_bluez_cache = {}


def cached_bluez_battery(address, ttl=30.0):
    """Cache BlueZ battery reads; read_meta() runs every couple of seconds."""
    if not address:
        return None
    now = time.time()
    hit = _bluez_cache.get(address)
    if hit and now - hit[0] < ttl:
        return hit[1]
    pct = bluez_battery(address)
    _bluez_cache[address] = (now, pct)
    return pct


def battery_state(power_supply_dir=""):
    """Return (capacity, charging) from the kernel power_supply of the pad.

    hid-playstation (DualSense) exposes `ps-controller-battery*`, hid-sony
    (DualShock 4) exposes `sony_controller_battery_*` over Bluetooth.
    """
    candidates = []
    if power_supply_dir and os.path.isdir(power_supply_dir):
        for name in os.listdir(power_supply_dir):
            candidates.append(os.path.join(power_supply_dir, name))
    for pattern in ("/sys/class/power_supply/ps-controller-battery*",
                    "/sys/class/power_supply/sony_controller_battery*"):
        for path in glob.glob(pattern):
            if path not in candidates:
                candidates.append(path)
    for path in candidates:
        try:
            with open(os.path.join(path, "capacity")) as f:
                capacity = int(f.read().strip())
        except (OSError, ValueError):
            continue
        status = ""
        try:
            with open(os.path.join(path, "status")) as f:
                status = f.read().strip()
        except OSError:
            pass
        return max(0, min(100, capacity)), status in ("Charging", "Full")
    return -1, False


def openable_controller(fd):
    """True when the fd looks like a gamepad (has the two left-stick axes)."""
    return abs_range(fd, ABS_X) is not None and abs_range(fd, ABS_Y) is not None


def find_controllers():
    """Return every usable gamepad as dicts, best candidate first.

    Sony pads expose extra input nodes (motion sensors, touchpad) and software
    pads (Sunshine) are always present; both are filtered out. The remaining
    candidates are sorted by model priority so that a DualSense wins over an
    8BitDo when neither has been touched yet.
    """
    found = []
    for node in sorted(glob.glob("/dev/input/event*"), key=lambda p: int(p.rsplit("event", 1)[1])):
        name = event_device_name(node)
        lowered = name.lower()
        if not name or any(hint in lowered for hint in SKIP_HINTS):
            continue
        hid = hid_device_info(node) or {}
        uniq = (hid.get("uniq") or "").lower()
        if any(hint in lowered for hint in VIRTUAL_HINTS) or any(
            hint in uniq for hint in VIRTUAL_HINTS
        ):
            continue
        model = model_for_hid(hid.get("vendor", 0), hid.get("product", 0), name)
        if not model:
            continue
        try:
            fd = os.open(node, os.O_RDONLY | os.O_NONBLOCK)
        except OSError:
            continue
        try:
            if not openable_controller(fd):
                continue
        finally:
            os.close(fd)
        found.append({
            "node": node,
            "name": name,
            "model": model,
            "priority": MODEL_PRIORITY.get(model, 9),
            "vendor": hid.get("vendor", 0),
            "product": hid.get("product", 0),
            "bus": hid.get("bus", ""),
            "uniq": hid.get("uniq", ""),
            "hid_path": hid.get("path", ""),
        })
    found.sort(key=lambda c: (c["priority"], int(c["node"].rsplit("event", 1)[1])))
    return found


def button_codes(fd, maxcode=0x140):
    """Return the set of EV_KEY codes the pad supports."""
    size = (maxcode // 8) + 1
    buf = bytearray(size)
    try:
        fcntl.ioctl(fd, (2 << 30) | (size << 16) | (ord("E") << 8) | (0x20 + EV_KEY), buf, True)
    except OSError:
        return set()
    return {code for code in range(maxcode) if buf[code // 8] & (1 << (code % 8))}


def button_map_for(fd, model):
    """Return the evdev-code -> widget-button map for this pad.

    Linux aliases the Xbox face buttons onto the PlayStation position codes:
    BTN_X (physical left) is BTN_NORTH 0x133 and BTN_Y (physical top) is
    BTN_WEST 0x134. Sony pads use those same codes for triangle (top) and
    square (left), so only Xbox-style pads (8BitDo and XInput) need the swap.
    This applies to both the 8BitDo Bluetooth report and its USB receiver.
    """
    if model in ("8bitdo", "xinput"):
        mapping = dict(BTN_CODES)
        mapping[0x133] = "square"    # BTN_NORTH = physical left (X)
        mapping[0x134] = "triangle"  # BTN_WEST = physical top (Y)
        return mapping
    return BTN_CODES


def abs_range(fd, axis):
    """Return (minimum, maximum) for an evdev axis, or None."""
    buf = array("i", [0] * 6)
    try:
        fcntl.ioctl(fd, EVIOCGABS + axis, buf, True)
    except OSError:
        return None
    vmin, vmax = buf[1], buf[2]
    if vmax <= vmin:
        return None
    return vmin, vmax


def normalize(value, info, signed):
    """Map a raw axis value to -1..1 (sticks) or 0..1 (triggers)."""
    if info is None:
        if signed:
            return max(-1.0, min(1.0, value / 127.5))
        return max(0.0, min(1.0, value / 255.0))
    vmin, vmax = info
    if signed:
        center = (vmin + vmax) / 2.0
        half = (vmax - vmin) / 2.0
        return max(-1.0, min(1.0, (value - center) / half))
    return max(0.0, min(1.0, (value - vmin) / float(vmax - vmin)))


def axis_maps(fd):
    """Return (stick_axes, trigger_axes) for the axes this pad actually has.

    Sony pads report the right stick as ABS_RX/ABS_RY and the triggers as
    ABS_Z/ABS_RZ. 8BitDo (and other D-input style pads) have no ABS_RX/ABS_RY
    at all: their right stick is ABS_Z/ABS_RZ and the triggers are
    ABS_GAS/ABS_BRAKE. For those pedals ABS_BRAKE is the left trigger and
    ABS_GAS the right one; verified on an 8BitDo Ultimate 2C in Bluetooth mode.
    """
    sticks = {}
    triggers = {}
    for axis, name in ((ABS_X, "lx"), (ABS_Y, "ly")):
        if abs_range(fd, axis) is not None:
            sticks[axis] = name

    if abs_range(fd, ABS_RX) is not None and abs_range(fd, ABS_RY) is not None:
        sticks[ABS_RX] = "rx"
        sticks[ABS_RY] = "ry"
        if abs_range(fd, ABS_Z) is not None:
            triggers[ABS_Z] = "l2"
        if abs_range(fd, ABS_RZ) is not None:
            triggers[ABS_RZ] = "r2"
    elif abs_range(fd, ABS_Z) is not None and abs_range(fd, ABS_RZ) is not None:
        sticks[ABS_Z] = "rx"
        sticks[ABS_RZ] = "ry"
        # Brake is the left trigger, gas/accelerator the right one.
        if abs_range(fd, ABS_BRAKE) is not None:
            triggers[ABS_BRAKE] = "l2"
        if abs_range(fd, ABS_GAS) is not None:
            triggers[ABS_GAS] = "r2"

    if not triggers:
        if abs_range(fd, ABS_BRAKE) is not None:
            triggers[ABS_BRAKE] = "l2"
        if abs_range(fd, ABS_GAS) is not None:
            triggers[ABS_GAS] = "r2"

    return sticks, triggers


def read_ranges(fd, *maps):
    """Read ABS min/max for every axis used by the given maps."""
    ranges = {}
    for mapping in maps:
        for axis in mapping:
            info = abs_range(fd, axis)
            if info:
                ranges[axis] = info
    return ranges


class InputState:
    def __init__(self):
        self.reset()

    def reset(self):
        self.buttons = {name: False for name in BUTTON_ORDER}
        self.sticks = {"lx": 0.0, "ly": 0.0, "rx": 0.0, "ry": 0.0}
        self.triggers = {"l2": 0.0, "r2": 0.0}
        self.dpad = {"x": 0, "y": 0}

    def key(self):
        return (
            tuple(self.buttons[name] for name in BUTTON_ORDER),
            tuple(round(self.sticks[a], 3) for a in ("lx", "ly", "rx", "ry")),
            tuple(round(self.triggers[a], 3) for a in ("l2", "r2")),
            (self.dpad["x"], self.dpad["y"]),
        )

    def payload(self, node=None, meta=None):
        connected = node is not None
        meta = meta or {}
        name = meta.get("name") or (event_device_name(node) if connected else "")
        model = meta.get("model") or ""
        if connected and not model:
            model = model_for_name(name)
        return {
            "connected": connected,
            "name": name,
            "model": model or "dualsense",
            "connection": meta.get("connection", ""),
            "battery_pct": meta.get("battery_pct", -1),
            "charging": meta.get("charging", False),
            "buttons": dict(self.buttons),
            "sticks": {axis: round(value, 3) for axis, value in self.sticks.items()},
            "triggers": {axis: round(value, 3) for axis, value in self.triggers.items()},
            "dpad": dict(self.dpad),
            "daemon_version": DAEMON_VERSION,
            "ts": int(time.time()),
        }


def write_state(payload):
    try:
        tmp = STATE_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(payload, f, separators=(",", ":"))
        os.replace(tmp, STATE_FILE)
    except OSError:
        pass


def emit(state, node, stream, meta=None):
    payload = state.payload(node, meta)
    if stream:
        try:
            print(json.dumps(payload, separators=(",", ":")), flush=True)
        except BrokenPipeError:
            sys.exit(0)
    return payload


def read_meta(node):
    """Collect connection, model, name and battery for the given evdev node."""
    name = event_device_name(node)
    hid = hid_device_info(node) or {}
    bus = hid.get("bus", "")
    connection = "bluetooth" if bus == "0005" else ("usb" if bus == "0003" else "")
    model = model_for_hid(hid.get("vendor", 0), hid.get("product", 0), name)
    if not model:
        model = model_for_name(name)

    capacity, charging = -1, False
    if model in ("dualsense", "edge", "ds4"):
        power_supply = os.path.join(hid["path"], "power_supply") if hid.get("path") else ""
        capacity, charging = battery_state(power_supply)
    if capacity < 0 and connection == "bluetooth" and hid.get("uniq"):
        pct = cached_bluez_battery(hid["uniq"])
        if pct is not None:
            capacity = pct

    return {
        "name": name,
        "model": model or "dualsense",
        "connection": connection,
        "battery_pct": capacity,
        "charging": charging,
    }


def monitor_activity(mon):
    """Drain a non-active pad and return True if it looks like it was used."""
    try:
        chunk = os.read(mon["fd"], EVENT_SIZE * 64)
    except BlockingIOError:
        return False
    except OSError:
        return True
    for offset in range(0, len(chunk) - EVENT_SIZE + 1, EVENT_SIZE):
        _sec, _usec, ev_type, code, value = EVENT.unpack_from(chunk, offset)
        if ev_type == EV_KEY:
            if value:
                return True
        elif ev_type == EV_ABS:
            if code in (ABS_HAT0X, ABS_HAT0Y):
                if value:
                    return True
                continue
            info = mon["ranges"].get(code)
            if info is None:
                continue
            if code in mon["triggers"]:
                if normalize(value, info, signed=False) > 0.25:
                    return True
            elif code in mon["sticks"]:
                if abs(normalize(value, info, signed=True)) > 0.35:
                    return True
    return False


def handle_event(state, code, value, ranges, stick_axes, trigger_axes, buttons):
    """Apply one evdev event; return True when the rendered state changed."""
    if code in buttons:
        pressed = value != 0
        name = buttons[code]
        if state.buttons[name] != pressed:
            state.buttons[name] = pressed
            return True
        return False
    if code in stick_axes:
        axis = stick_axes[code]
        normalized = normalize(value, ranges.get(code), signed=True)
        if abs(state.sticks[axis] - normalized) > 0.002:
            state.sticks[axis] = normalized
            return True
        return False
    if code in trigger_axes:
        axis = trigger_axes[code]
        normalized = normalize(value, ranges.get(code), signed=False)
        if abs(state.triggers[axis] - normalized) > 0.002:
            state.triggers[axis] = normalized
            return True
        return False
    if code == ABS_HAT0X:
        if state.dpad["x"] != value:
            state.dpad["x"] = max(-1, min(1, value))
            return True
    elif code == ABS_HAT0Y:
        if state.dpad["y"] != value:
            state.dpad["y"] = max(-1, min(1, value))
            return True
    return False


def close_monitors(monitors):
    for mon in monitors.values():
        try:
            os.close(mon["fd"])
        except OSError:
            pass
    monitors.clear()


def refresh_monitors(monitors, active_node):
    """Keep read-only fds open on the other pads so their input is noticed.

    evdev queues events per open fd, so reading here never steals events from
    the pad that is currently being streamed.
    """
    candidates = find_controllers()
    want = [c for c in candidates if c["node"] != active_node]
    wanted = {c["node"] for c in want}

    for node in list(monitors):
        if node not in wanted:
            try:
                os.close(monitors.pop(node)["fd"])
            except (OSError, KeyError):
                monitors.pop(node, None)

    for candidate in want:
        node = candidate["node"]
        if node in monitors:
            continue
        try:
            fd = os.open(node, os.O_RDONLY | os.O_NONBLOCK)
        except OSError:
            continue
        sticks, triggers = axis_maps(fd)
        monitors[node] = {
            "fd": fd,
            "sticks": sticks,
            "triggers": triggers,
            "ranges": read_ranges(fd, sticks, triggers),
        }
    return candidates


def stream_controller(node, stream=False, seen=None):
    """Read one controller until it disconnects or another pad takes over.

    Returns (last_payload, switch_to). `switch_to` is the evdev node of a pad
    that should take over the widget, or None when the current node vanished.
    """
    state = InputState()
    try:
        fd = os.open(node, os.O_RDONLY | os.O_NONBLOCK)
    except OSError:
        return None, None

    stick_axes, trigger_axes = axis_maps(fd)
    ranges = read_ranges(fd, stick_axes, trigger_axes)

    monitors = {}
    refresh_monitors(monitors, node)

    meta = read_meta(node)
    buttons = button_map_for(fd, meta.get("model", ""))
    last_meta = time.time()
    payload = emit(state, node, stream, meta)
    if stream:
        write_state(payload)

    last_key = state.key()
    last_emit = 0.0
    last_state_write = 0.0
    buffer = b""
    switch_to = None
    try:
        while True:
            timeout = 0.02 if state.key() != last_key else HEARTBEAT
            watch = [fd] + [mon["fd"] for mon in monitors.values()]
            ready, _, _ = select.select(watch, [], [], timeout)
            now = time.time()

            if fd in ready:
                try:
                    chunk = os.read(fd, EVENT_SIZE * 64)
                except BlockingIOError:
                    chunk = b""
                except OSError:
                    break
                if not chunk:
                    break
                buffer += chunk
                while len(buffer) >= EVENT_SIZE:
                    _sec, _usec, ev_type, code, value = EVENT.unpack_from(buffer)
                    buffer = buffer[EVENT_SIZE:]
                    if ev_type in (EV_KEY, EV_ABS):
                        handle_event(state, code, value, ranges, stick_axes, trigger_axes, buttons)
            else:
                for other, mon in list(monitors.items()):
                    if mon["fd"] in ready and monitor_activity(mon):
                        switch_to = other
                        break
                if switch_to:
                    break

            key = state.key()
            if now - last_meta >= RESCAN_INTERVAL:
                last_meta = now
                meta = read_meta(node)
                candidates = refresh_monitors(monitors, node)
                nodes = {c["node"] for c in candidates}
                if seen is not None:
                    fresh = [c for c in candidates if c["node"] not in seen]
                    seen.clear()
                    seen.update(nodes)
                    if fresh:
                        switch_to = fresh[0]["node"]
                        break
                if node not in nodes:
                    break

            if key != last_key:
                if now - last_emit >= EMIT_INTERVAL:
                    last_key = key
                    payload = emit(state, node, stream, meta)
                    last_emit = now
                    if stream and now - last_state_write >= STATE_WRITE_INTERVAL:
                        write_state(payload)
                        last_state_write = now
            elif now - last_emit >= HEARTBEAT:
                last_key = key
                payload = emit(state, node, stream, meta)
                last_emit = now
                if stream:
                    write_state(payload)
                    last_state_write = now
    finally:
        close_monitors(monitors)
        try:
            os.close(fd)
        except OSError:
            pass
    return payload, switch_to


def demo_loop(stream, interval=EMIT_INTERVAL):
    """Stream a synthetic controller so the widget layout can be previewed."""
    state = InputState()
    meta = {
        "name": "DualSense (demo)",
        "model": "dualsense",
        "connection": "usb",
        "battery_pct": 87,
        "charging": False,
    }
    phases = (
        {"cross"}, {"l1", "r1"}, {"triangle", "square", "circle"},
        {"ps", "create", "options", "mute"}, {"l3", "r3"}, {"cross", "r2"},
    )
    started = time.time()
    last_write = 0.0
    while True:
        t = time.time() - started
        state.buttons.update({name: False for name in BUTTON_ORDER})
        for name in phases[int(t / 1.6) % len(phases)]:
            state.buttons[name] = True
        state.sticks = {
            "lx": math.sin(t * 0.9),
            "ly": math.cos(t * 0.7),
            "rx": math.sin(t * 1.3 + 1.0),
            "ry": math.cos(t * 1.1 + 0.5),
        }
        state.triggers = {
            "l2": 0.5 + 0.5 * math.sin(t * 0.6),
            "r2": 0.5 + 0.5 * math.sin(t * 0.6 + 2.0),
        }
        step = int(t / 1.6) % 9
        state.dpad = {"x": (0, 1, 1, 0, -1, -1, -1, 0, 1)[step],
                      "y": (0, 0, 1, 1, 1, 0, -1, -1, -1)[step]}
        payload = emit(state, "/dev/input/demo", stream, meta)
        now = time.time()
        if now - last_write >= STATE_WRITE_INTERVAL:
            write_state(payload)
            last_write = now
        time.sleep(interval)


def write_lock():
    try:
        with open(LOCK_FILE, "w") as f:
            f.write(str(os.getpid()))
    except OSError:
        pass


def clear_lock():
    try:
        os.remove(LOCK_FILE)
    except OSError:
        pass


def main(argv):
    stream = "--stream" in argv
    # Let SIGTERM unwind through the finally blocks so the lock file is removed.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    state = InputState()
    write_lock()
    try:
        if "--demo" in argv:
            demo_loop(stream)
            return 0
        idle = state.payload(None)
        if stream:
            print(json.dumps(idle, separators=(",", ":")), flush=True)
        write_state(idle)

        seen = set()
        active = None
        while True:
            candidates = find_controllers()
            nodes = {c["node"] for c in candidates}
            fresh = [c for c in candidates if c["node"] not in seen]
            seen.clear()
            seen.update(nodes)

            # Keep the current pad unless a new one was just connected, or it
            # went away; otherwise fall back to the highest-priority pad.
            if active in nodes and not fresh:
                target = active
            else:
                pool = fresh or candidates
                target = pool[0]["node"] if pool else None
            active = target

            if target is None:
                state.reset()
                idle = state.payload(None)
                if stream:
                    print(json.dumps(idle, separators=(",", ":")), flush=True)
                write_state(idle)
                time.sleep(RESCAN_INTERVAL)
                continue

            payload, switch_to = stream_controller(target, stream, seen)
            state.reset()
            if switch_to:
                active = switch_to
                continue

            # The active pad went away; report idle, then look for another.
            active = None
            idle = state.payload(None)
            if stream:
                print(json.dumps(idle, separators=(",", ":")), flush=True)
            write_state(idle)
            time.sleep(0.3)
    except KeyboardInterrupt:
        return 0
    finally:
        clear_lock()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
