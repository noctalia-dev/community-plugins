"""Format Show Me The Key events for the Input Echo Bar widget.

The helper reads JSON lines from showmethekey-cli. Because that backend does
not currently emit pointer-axis events, the optional mouse mode also opens
wheel-capable /dev/input/event* nodes read-only and emits wheel directions.
It performs no network access and writes no files.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import select
import struct
import sys
import threading
import time
from collections import OrderedDict
from typing import Any

MODIFIER_BASE = {
    "CTRL": "Ctrl",
    "SHIFT": "Shift",
    "ALT": "Alt",
    "META": "Super",
    "SUPER": "Super",
}
SIDE = {"LEFT": "Left", "RIGHT": "Right"}
MOUSE_BUTTONS = {
    "LEFT": "LeftClick",
    "RIGHT": "RightClick",
    "MIDDLE": "MiddleClick",
    "SIDE": "SideButton",
    "EXTRA": "ExtraButton",
    "FORWARD": "ForwardButton",
    "BACK": "BackButton",
    "TASK": "TaskButton",
}
SPECIAL_KEYS = {
    "ESC": "Esc",
    "ENTER": "Enter",
    "TAB": "Tab",
    "SPACE": "Space",
    "BACKSPACE": "Backspace",
    "DELETE": "Delete",
    "INSERT": "Insert",
    "HOME": "Home",
    "END": "End",
    "PAGEUP": "PageUp",
    "PAGEDOWN": "PageDown",
    "LEFT": "Left",
    "RIGHT": "Right",
    "UP": "Up",
    "DOWN": "Down",
    "CAPSLOCK": "CapsLock",
    "NUMLOCK": "NumLock",
    "SCROLLLOCK": "ScrollLock",
    "PRINTSCREEN": "PrintScreen",
    "SYSRQ": "PrintScreen",
    "PAUSE": "Pause",
    "MENU": "Menu",
    "LEFTBRACE": "LeftBrace",
    "RIGHTBRACE": "RightBrace",
    "MINUS": "Minus",
    "EQUAL": "Equal",
    "DOT": "Dot",
    "COMMA": "Comma",
    "SLASH": "Slash",
    "BACKSLASH": "Backslash",
    "SEMICOLON": "Semicolon",
    "APOSTROPHE": "Apostrophe",
    "GRAVE": "Grave",
    "KPENTER": "KeypadEnter",
    "KPSLASH": "KeypadSlash",
    "KPASTERISK": "KeypadAsterisk",
    "KPMINUS": "KeypadMinus",
    "KPPLUS": "KeypadPlus",
    "KPDOT": "KeypadDot",
}

# Linux input_event and EV_REL constants used only for wheel events.
INPUT_EVENT = struct.Struct("@llHHi")
EV_REL = 0x02
REL_HWHEEL = 0x06
REL_WHEEL = 0x08
REL_WHEEL_HI_RES = 0x0B
REL_HWHEEL_HI_RES = 0x0C


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Format input events for Input Echo Bar")
    parser.add_argument("--timeout-ms", type=int, default=2000)
    parser.add_argument("--show-mouse-events", action="store_true")
    args = parser.parse_args()
    if not 250 <= args.timeout_ms <= 10000:
        parser.error("--timeout-ms must be between 250 and 10000")
    return args


class Emitter:
    def __init__(self, timeout_ms: int) -> None:
        self.timeout = timeout_ms / 1000.0
        self.timer: threading.Timer | None = None
        self.lock = threading.Lock()
        self.closed = False

    def emit(self, text: str, kind: str) -> None:
        with self.lock:
            if self.closed:
                return
            if self.timer is not None:
                self.timer.cancel()
            print(json.dumps({"text": text, "kind": kind}, ensure_ascii=False), flush=True)
            self.timer = threading.Timer(self.timeout, self.clear)
            self.timer.daemon = True
            self.timer.start()

    def clear(self) -> None:
        with self.lock:
            if not self.closed:
                print(json.dumps({"text": "", "kind": "hidden"}), flush=True)
                self.timer = None

    def close(self) -> None:
        with self.lock:
            self.closed = True
            if self.timer is not None:
                self.timer.cancel()
                self.timer = None


def is_modifier_key(key_name: str) -> bool:
    if not key_name.startswith("KEY_"):
        return False
    name = key_name[4:]
    if name in MODIFIER_BASE:
        return True
    return any(name == side + base for side in SIDE for base in MODIFIER_BASE)


def pretty_key(key_name: str) -> tuple[str, str]:
    if key_name.startswith("BTN_"):
        button = key_name[4:]
        return MOUSE_BUTTONS.get(button, "Mouse" + button.title()), "mouse"

    name = key_name.removeprefix("KEY_")
    for side, pretty_side in SIDE.items():
        for base, pretty_base in MODIFIER_BASE.items():
            if name == side + base:
                return pretty_side + pretty_base, "keyboard"

    if name in MODIFIER_BASE:
        return MODIFIER_BASE[name], "keyboard"
    if name.startswith("F") and name[1:].isdigit():
        return name, "keyboard"
    if name.isdigit():
        return name, "keyboard"
    if len(name) == 1 and name.isalpha():
        return name.upper(), "keyboard"
    if name in SPECIAL_KEYS:
        return SPECIAL_KEYS[name], "keyboard"
    if name.startswith("KP") and name[2:].isdigit():
        return "Keypad" + name[2:], "keyboard"

    return "".join(part[:1].upper() + part[1:].lower() for part in name.split("_") if part), "keyboard"


def is_pressed(event: dict[str, Any]) -> bool:
    return event.get("state_name") == "PRESSED" or event.get("state_code") == 1


def is_released(event: dict[str, Any]) -> bool:
    return event.get("state_name") == "RELEASED" or event.get("state_code") == 0


def capability_bits(event_path: str, capability: str) -> int:
    event_name = os.path.basename(os.path.realpath(event_path))
    path = f"/sys/class/input/{event_name}/device/capabilities/{capability}"
    try:
        with open(path, "r", encoding="ascii") as handle:
            return int("".join(handle.read().split()), 16)
    except (OSError, ValueError):
        return 0


def wheel_name(code: int, value: int) -> str | None:
    if value == 0:
        return None
    if code in (REL_WHEEL, REL_WHEEL_HI_RES):
        return "WheelUp" if value > 0 else "WheelDown"
    if code in (REL_HWHEEL, REL_HWHEEL_HI_RES):
        return "WheelRight" if value > 0 else "WheelLeft"
    return None


def wheel_from_json(event: dict[str, Any]) -> str | None:
    name = str(event.get("key_name") or event.get("axis_name") or "").upper()
    aliases = {
        "BTN_WHEELUP": "WheelUp",
        "WHEELUP": "WheelUp",
        "BTN_WHEELDOWN": "WheelDown",
        "WHEELDOWN": "WheelDown",
        "BTN_WHEELLEFT": "WheelLeft",
        "WHEELLEFT": "WheelLeft",
        "BTN_WHEELRIGHT": "WheelRight",
        "WHEELRIGHT": "WheelRight",
    }
    if name in aliases:
        return aliases[name]

    values = (event.get("value"), event.get("axis_value"), event.get("scroll_value"))
    value = next((item for item in values if isinstance(item, (int, float)) and item != 0), 0)
    if name in ("REL_WHEEL", "REL_WHEEL_HI_RES"):
        return "WheelUp" if value > 0 else "WheelDown" if value < 0 else None
    if name in ("REL_HWHEEL", "REL_HWHEEL_HI_RES"):
        return "WheelRight" if value > 0 else "WheelLeft" if value < 0 else None
    return None


class InputFormatter:
    def __init__(self, emitter: Emitter, show_mouse_events: bool) -> None:
        self.emitter = emitter
        self.show_mouse_events = show_mouse_events
        self.held_modifiers: OrderedDict[str, bool] = OrderedDict()
        self.modifier_lock = threading.Lock()
        self.stop_event = threading.Event()

    def emit_with_modifiers(self, key: str, kind: str) -> None:
        with self.modifier_lock:
            modifiers = [pretty_key(name)[0] for name in self.held_modifiers]
            for name in self.held_modifiers:
                self.held_modifiers[name] = True
        self.emitter.emit(" + ".join(modifiers + [key]), kind)

    def handle(self, event: dict[str, Any]) -> None:
        wheel = wheel_from_json(event)
        if wheel is not None:
            if self.show_mouse_events:
                self.emit_with_modifiers(wheel, "mouse")
            return

        key_name = event.get("key_name")
        if not isinstance(key_name, str) or not key_name:
            return
        is_mouse = key_name.startswith("BTN_") or event.get("event_name") == "POINTER_BUTTON"
        if is_mouse and not self.show_mouse_events:
            return

        if is_pressed(event):
            if is_modifier_key(key_name):
                with self.modifier_lock:
                    self.held_modifiers.setdefault(key_name, False)
            else:
                key, kind = pretty_key(key_name)
                if key:
                    self.emit_with_modifiers(key, kind)
            return

        if is_released(event) and is_modifier_key(key_name):
            with self.modifier_lock:
                used = self.held_modifiers.pop(key_name, None)
            if used is False:
                key, kind = pretty_key(key_name)
                self.emitter.emit(key, kind)

    def wheel_loop(self) -> None:
        devices: dict[int, tuple[str, int]] = {}
        next_scan = 0.0
        try:
            while not self.stop_event.is_set():
                now = time.monotonic()
                if now >= next_scan:
                    current = set(glob.glob("/dev/input/event*"))
                    known = {path for path, _bits in devices.values()}
                    for path in current - known:
                        bits = capability_bits(path, "rel")
                        wheel_bits = sum(1 << code for code in (REL_HWHEEL, REL_WHEEL, REL_WHEEL_HI_RES, REL_HWHEEL_HI_RES))
                        if bits & wheel_bits:
                            try:
                                fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
                                devices[fd] = (path, bits)
                            except OSError:
                                pass
                    for fd, (path, _bits) in list(devices.items()):
                        if path not in current:
                            os.close(fd)
                            del devices[fd]
                    next_scan = now + 2.0

                if not devices:
                    self.stop_event.wait(0.25)
                    continue

                try:
                    readable, _, _ = select.select(list(devices), [], [], 0.25)
                except (OSError, ValueError):
                    readable = []

                for fd in readable:
                    try:
                        data = os.read(fd, INPUT_EVENT.size * 32)
                    except BlockingIOError:
                        continue
                    except OSError:
                        data = b""
                    if not data:
                        try:
                            os.close(fd)
                        except OSError:
                            pass
                        devices.pop(fd, None)
                        continue

                    bits = devices[fd][1]
                    has_regular_vertical = bool(bits & (1 << REL_WHEEL))
                    has_regular_horizontal = bool(bits & (1 << REL_HWHEEL))
                    usable = len(data) - (len(data) % INPUT_EVENT.size)
                    for _sec, _usec, event_type, code, value in INPUT_EVENT.iter_unpack(data[:usable]):
                        if event_type != EV_REL:
                            continue
                        if code == REL_WHEEL_HI_RES and has_regular_vertical:
                            continue
                        if code == REL_HWHEEL_HI_RES and has_regular_horizontal:
                            continue
                        name = wheel_name(code, value)
                        if name is not None:
                            self.emit_with_modifiers(name, "mouse")
        finally:
            for fd in devices:
                try:
                    os.close(fd)
                except OSError:
                    pass


def main() -> int:
    args = parse_args()
    emitter = Emitter(args.timeout_ms)
    formatter = InputFormatter(emitter, args.show_mouse_events)

    if args.show_mouse_events:
        threading.Thread(target=formatter.wheel_loop, name="input-echo-wheel", daemon=True).start()

    try:
        for line in sys.stdin:
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(event, dict):
                formatter.handle(event)
    except KeyboardInterrupt:
        pass
    finally:
        formatter.stop_event.set()
        emitter.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
