# Copyright (C) 2026 Zach Wilke
# SPDX-License-Identifier: GPL-2.0-or-later
"""Device-scoped HID++ actions. No Solaar rule-file or Hyprland config edits.

Solaar supplies HID++ transport/control APIs. Independent read handles receive
notifications without consuming replies on mxctl's command handles.
"""
from __future__ import annotations

import json
import os
import queue
import re
import select
import socket
import struct
import threading
import time

DIRECTIONS = ("click", "up", "down", "left", "right")
MODIFIERS = {"CTRL": "CTRL", "CONTROL": "CTRL", "ALT": "ALT", "SHIFT": "SHIFT", "SUPER": "SUPER", "META": "SUPER"}
MAX_BINDINGS = 128


def shortcut(text):
    if not isinstance(text, str) or len(text) > 100:
        raise ValueError("Enter a shortcut such as CTRL+C")
    parts = [p.strip() for p in text.split("+")]
    if not parts or not re.fullmatch(r"[A-Za-z0-9_]{1,40}", parts[-1]):
        raise ValueError("Use a key name such as C, Return, space, or XF86AudioPlay")
    mods = []
    for part in parts[:-1]:
        mod = MODIFIERS.get(part.upper())
        if not mod:
            raise ValueError(f"Unknown modifier: {part}")
        if mod not in mods:
            mods.append(mod)
    key = parts[-1]
    if key.upper() in MODIFIERS:
        raise ValueError("A shortcut needs a key after its modifiers")
    if len(key) == 1:
        key = key.lower()
    return "+".join(mods + [key])


def sequence(value):
    if not isinstance(value, str):
        raise ValueError("Shortcut steps must be text")
    steps = [shortcut(line) for line in value.splitlines() if line.strip()]
    if not 1 <= len(steps) <= 8:
        raise ValueError("Enter between one and eight shortcuts, one per line")
    return "\n".join(steps)


def validate_binding(raw):
    if not isinstance(raw, dict):
        raise ValueError("Invalid action assignment")
    device = str(raw.get("device") or "").strip()
    control = str(raw.get("control") or "")
    if not device or len(device) > 160 or not control.isdigit() or not 0 < int(control) <= 65535:
        raise ValueError("Choose a device and a configurable control")
    app = str(raw.get("app") or "").strip()
    if len(app) > 160 or any(ord(c) < 32 for c in app):
        raise ValueError("Invalid application class")
    mode = raw.get("mode", "shortcut")
    if mode not in ("shortcut", "gesture"):
        raise ValueError("Choose shortcut or gestures")
    gestures = raw.get("gestures") or {}
    if mode == "gesture" and not isinstance(gestures, dict):
        raise ValueError("Invalid gestures")
    return {
        "device": device, "control": str(int(control)), "app": app,
        "mode": mode, "shortcut": sequence(raw.get("shortcut", "")),
        "gestures": {d: sequence(gestures[d]) if gestures.get(d) else "" for d in DIRECTIONS[1:]} if mode == "gesture" else {},
    }


def binding_key(row):
    return row["device"], row["control"], row["app"]


def updated_bindings(rows, raw, delete=False):
    if delete:
        key = (str(raw.get("device", "")), str(raw.get("control", "")), str(raw.get("app", "")))
        # Removing the default restores the hardware control and removes its overrides.
        return [r for r in rows if (r["device"], r["control"]) != key[:2]] if not key[2] else [r for r in rows if binding_key(r) != key]
    row = validate_binding(raw)
    others = [r for r in rows if binding_key(r) != binding_key(row)]
    if row["app"] and not any(r["device"] == row["device"] and r["control"] == row["control"] and not r["app"] for r in others):
        raise ValueError("Save an All apps assignment first, so this control also works outside the selected app")
    if len(others) >= MAX_BINDINGS:
        raise ValueError("Too many action assignments")
    return others + [row]


def resolve_binding(rows, control, app):
    candidates = [r for r in rows if r["control"] == str(control)]
    return next((r for r in candidates if r["app"] and r["app"].casefold() == app.casefold()),
                next((r for r in candidates if not r["app"]), None))


class WakePipe:
    """Pollable, coalescing wakeup; no timers and no blocking writers."""
    def __init__(self):
        self.reader, self.writer = os.pipe2(os.O_CLOEXEC | os.O_NONBLOCK)

    def notify(self):
        try:
            os.write(self.writer, b"x")
        except (BlockingIOError, OSError):
            pass

    def close(self):
        for fd in (self.reader, self.writer):
            if fd is not None:
                os.close(fd)
        self.reader = self.writer = None


class HyprlandIPC:
    """Bounded request/response IPC: no hyprctl processes on the input path."""
    def __init__(self, path=None, timeout=0.35, max_bytes=262144):
        self.path = path
        self.timeout = timeout
        self.max_bytes = max_bytes

    def socket_path(self):
        if self.path is not None:
            return self.path
        signature = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,200}", signature):
            raise RuntimeError("No Hyprland instance is available")
        runtime = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
        return f"{runtime}/hypr/{signature}/.socket.sock"

    def __call__(self, command):
        deadline = time.monotonic() + self.timeout
        chunks = []
        size = 0
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(self.timeout)
            connection.connect(self.socket_path())
            connection.settimeout(max(0.001, deadline - time.monotonic()))
            connection.sendall(command.encode("utf-8"))
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("Hyprland IPC timed out")
                connection.settimeout(remaining)
                chunk = connection.recv(min(65536, self.max_bytes + 1 - size))
                if not chunk:
                    break
                size += len(chunk)
                if size > self.max_bytes:
                    raise RuntimeError("Hyprland IPC reply exceeded the size limit")
                chunks.append(chunk)
        return b"".join(chunks).decode("utf-8")


class HyprlandExecutor:
    def __init__(self, request=None):
        self.request = request or HyprlandIPC()

    def active_window(self):
        data = json.loads(self.request("j/activewindow"))
        address = str(data.get("address") or "")
        if not re.fullmatch(r"0x[0-9a-fA-F]+", address) or int(address, 16) == 0:
            raise RuntimeError("No application window is focused")
        return str(data.get("class") or ""), address

    def execute(self, steps, address, cancel):
        values = steps.splitlines()
        for index, value in enumerate(values):
            if cancel.is_set():
                return
            _, current = self.active_window()
            if current != address:
                raise RuntimeError("Action stopped because the focused window changed")
            tokens = shortcut(value).split("+")
            arg = "hl.dsp.send_shortcut({ mods = %s, key = %s, window = %s })" % (
                json.dumps(" ".join(tokens[:-1])), json.dumps(tokens[-1]), json.dumps("address:" + address))
            # A stop can arrive while the focus query is in progress.
            if cancel.is_set():
                return
            result = self.request("/dispatch " + arg)
            if result.strip().lower() not in ("", "ok"):
                raise RuntimeError("Hyprland could not send the shortcut: " + result.strip()[:160])
            # Spacing is between macro steps, never a per-click rate limit.
            if index + 1 < len(values) and cancel.wait(0.06):
                return


class GestureTracker:
    """REPROG_CONTROLS_V4 packets, modeled after Solaar RawXYProcessing."""
    def __init__(self, controls, threshold=120, ignore_first=False):
        self.controls = set(map(int, controls))
        self.threshold = threshold
        self.ignore_first = ignore_first
        self.down = {}

    def feed(self, address, data):
        events = []
        if address == 0 and len(data) >= 8:
            pressed = set(struct.unpack("!HHHH", data[:8])) & self.controls
            for key in list(self.down):
                if key not in pressed:
                    dx, dy, _ = self.down.pop(key)
                    direction = "click"
                    if max(abs(dx), abs(dy)) >= self.threshold:
                        direction = ("right" if dx > 0 else "left") if abs(dx) >= abs(dy) else ("down" if dy > 0 else "up")
                    events.append((key, direction))
            for key in pressed - self.down.keys():
                self.down[key] = [0, 0, self.ignore_first]
        elif address == 0x10 and len(data) >= 4:
            dx, dy = struct.unpack("!hh", data[:4])
            # Ambiguous chords do not attribute movement to several buttons.
            if len(self.down) == 1:
                value = next(iter(self.down.values()))
                if value[2]:
                    value[2] = False
                else:
                    value[0] += dx
                    value[1] += dy
        return events


class DeviceSession:
    def __init__(self, base, device, rows, report, executor=None):
        from logitech_receiver.hidpp20 import MappingFlag, KeyFlag
        from logitech_receiver.hidpp20_constants import SupportedFeature
        self.base, self.device, self.rows, self.report = base, device, rows, report
        self.executor = executor or HyprlandExecutor()
        self.stop_event = threading.Event()
        self.work = queue.Queue(8)
        self.saved = []
        self.threads = []
        self.fd = None
        self.wakeup = None
        self.feature = device.features[SupportedFeature.REPROG_CONTROLS_V4]
        if self.feature is False or self.feature is None:
            raise ValueError("This device does not support HID++ button actions")
        controls = {int(r["control"]) for r in rows}
        keys = {int(k.key): k for k in device.keys if int(k.key) in controls}
        if set(keys) != controls:
            raise ValueError("An assigned control is unavailable on this device")
        # Validate all controls before the first write. Refuse to take over
        # controls already owned by Solaar's gesture/sliding/rule processing.
        for cid, key in keys.items():
            if KeyFlag.DIVERTABLE not in key.flags or KeyFlag.VIRTUAL in key.flags:
                raise ValueError("This control cannot run software actions")
            gesture = any(r["control"] == str(cid) and r["mode"] == "gesture" for r in rows)
            if gesture and KeyFlag.RAW_XY not in key.flags:
                raise ValueError("This control does not support directional gestures")
            key._getCidReporting()
            flags = key.mapping_flags
            if MappingFlag.DIVERTED in flags or MappingFlag.PERSISTENTLY_DIVERTED in flags or MappingFlag.RAW_XY_DIVERTED in flags:
                raise ValueError("Set this control's Solaar rule handling to Regular before assigning an action")
        path = device.path or getattr(device.receiver, "path", None)
        self.fd = base.open_path(path)
        if self.fd is None:
            raise RuntimeError("Cannot open the device's action listener")
        try:
            os.set_blocking(self.fd, False)
            self.wakeup = WakePipe()
            self.tracker = GestureTracker(controls, ignore_first=device.features.get_feature_version(SupportedFeature.REPROG_CONTROLS_V4) >= 5)
            for cid, key in keys.items():
                gesture = any(r["control"] == str(cid) and r["mode"] == "gesture" for r in rows)
                self.saved.append((key, gesture))  # include a partially written key
                key.set_diverted(True)
                if gesture:
                    key.set_rawXY_reporting(True)
                key._getCidReporting()
                if MappingFlag.DIVERTED not in key.mapping_flags or (gesture and MappingFlag.RAW_XY_DIVERTED not in key.mapping_flags):
                    raise RuntimeError("Device did not enable the requested action mode")
            for fn in (self.listen, self.perform):
                thread = threading.Thread(target=fn, daemon=True, name="mx-actions")
                thread.start()
                self.threads.append(thread)
        except BaseException:
            self.close()
            raise

    def restore(self):
        # Only the helper/main thread may issue HID++ configuration commands.
        # A listener error wakes it; it must not use the shared command handle.
        from logitech_receiver.hidpp20 import MappingFlag
        for key, gesture in self.saved[:]:
            try:
                if gesture:
                    key.set_rawXY_reporting(False)
                key.set_diverted(False)
                key._getCidReporting()
                if MappingFlag.DIVERTED in key.mapping_flags or (gesture and MappingFlag.RAW_XY_DIVERTED in key.mapping_flags):
                    raise RuntimeError("Device did not restore regular input")
                self.saved.remove((key, gesture))
            except Exception as exc:
                self.report("Could not restore input; reconnect the device: " + str(exc))

    def request_stop(self):
        self.stop_event.set()
        if self.wakeup:
            self.wakeup.notify()
        try:
            self.work.put_nowait(None)
        except queue.Full:
            pass  # a busy worker sees stop_event before processing its next item

    def listen(self):
        try:
            while not self.stop_event.is_set():
                ready, _, _ = select.select([self.fd, self.wakeup.reader], [], [])
                if self.stop_event.is_set():
                    return
                if self.fd not in ready:
                    continue
                try:
                    data = os.read(self.fd, 64)
                except BlockingIOError:
                    continue
                if not data:
                    raise OSError("Device disconnected")
                # Read the standard HID++ report ourselves: Solaar base.read
                # closes failed handles internally, which would leave us with
                # a stale fd that could later close an unrelated resource.
                if len(data) < 4 or data[0] not in (0x10, 0x11, 0x21):
                    continue
                if data[1] != self.device.number or data[2] != self.feature:
                    continue
                for cid, direction in self.tracker.feed(data[3], data[4:]):
                    try:
                        self.work.put_nowait((cid, direction, time.monotonic()))
                    except queue.Full:
                        self.report("Action queue is full; repeated input was dropped")
        except Exception as exc:
            self.request_stop()
            self.report("Action listener stopped: " + str(exc))

    def perform(self):
        while not self.stop_event.is_set():
            item = self.work.get()
            if item is None or self.stop_event.is_set():
                return
            cid, direction, created = item
            if time.monotonic() - created > 1:
                continue  # never replay stale input after slow commands
            try:
                app, address = self.executor.active_window()
                row = resolve_binding(self.rows, cid, app)
                if row:
                    steps = row["shortcut"] if direction == "click" or row["mode"] == "shortcut" else row["gestures"].get(direction, "")
                    if steps:
                        self.executor.execute(steps, address, self.stop_event)
                        self.report("")
            except Exception as exc:
                self.report(str(exc))

    def verify(self):
        from logitech_receiver.hidpp20 import MappingFlag
        for key, gesture in self.saved:
            key._getCidReporting()
            if MappingFlag.DIVERTED not in key.mapping_flags or (gesture and MappingFlag.RAW_XY_DIVERTED not in key.mapping_flags):
                self.request_stop()
                return

    def close(self):
        self.request_stop()
        # Reader is interrupted by a pipe; executor requests have a total
        # deadline. Join before releasing descriptors or touching device flags.
        for thread in self.threads:
            thread.join()
        self.restore()
        if self.fd is not None:
            self.base.close(self.fd)
            self.fd = None
        if self.wakeup:
            self.wakeup.close()
            self.wakeup = None


class ActionRuntime:
    def __init__(self, base, identity, factory=DeviceSession, clock=time.monotonic):
        self.base, self.identity, self.factory = base, identity, factory
        self.sessions = {}
        self.error = ""
        self.bindings = []
        self.clock = clock
        self.retries = {}
        self.wakeup = WakePipe()

    def report(self, message):
        message = str(message)[:300]
        if self.error != message or message.startswith("Action listener stopped:"):
            self.error = message
            self.wakeup.notify()

    def retry_later(self, did):
        _, previous = self.retries.get(did, (0, 0.5))
        delay = min(60.0, previous * 2)
        self.retries[did] = (self.clock() + delay, delay)

    def wait_timeout(self, maximum):
        pending = [at - self.clock() for did, (at, _) in self.retries.items()
                   if did not in self.sessions]
        return max(0.0, min([maximum] + pending))

    def sync(self, devices, rows):
        if rows != self.bindings:
            self.retries.clear()
        self.bindings = rows
        desired = {self.identity(d): d for d in devices if getattr(d, "online", False)}
        grouped = {did: [r for r in rows if r["device"] == did] for did in desired}
        self.retries = {did: retry for did, retry in self.retries.items() if grouped.get(did)}
        for did in list(self.sessions):
            old_dev, old_rows, session = self.sessions[did]
            if desired.get(did) is not old_dev or grouped.get(did) != old_rows or session.stop_event.is_set():
                if session.stop_event.is_set() and grouped.get(did):
                    self.retry_later(did)
                session.close()
                del self.sessions[did]
        for did, dev in desired.items():
            if did not in self.sessions and grouped[did]:
                retry_at, _ = self.retries.get(did, (0, 0.5))
                if self.clock() < retry_at:
                    continue
                try:
                    session = self.factory(self.base, dev, grouped[did], self.report)
                    self.sessions[did] = (dev, grouped[did], session)
                except Exception as exc:
                    self.retry_later(did)
                    self.report(str(exc))

    def pause(self, device_id):
        existing = self.sessions.pop(device_id, None)
        if existing:
            existing[2].close()

    def close(self):
        for _, _, session in self.sessions.values():
            session.close()
        self.sessions = {}

    def shutdown(self):
        self.close()
        self.wakeup.close()

    def check(self, devices):
        for did, (_, _, session) in list(self.sessions.items()):
            try:
                if session.stop_event.is_set():
                    continue
                session.verify()
                if not session.stop_event.is_set():
                    self.retries.pop(did, None)
            except Exception as exc:
                self.report(str(exc))
                session.request_stop()
        self.sync(devices, self.bindings)

    def status(self):
        return {"activeDevices": [did for did, (_, _, s) in self.sessions.items() if not s.stop_event.is_set()], "error": self.error, "available": bool(os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"))}
