#!/usr/bin/env python3
"""Reports held left-button presses from /dev/input as stdout lines.

Output:
  down <device>
  repeat <device>
  up <device>

The panel repeats only the stepper currently under the pointer. Noctalia's
declarative UI does not expose press/release events, so this read-only evdev
helper supplies the missing signal. If /dev/input is not readable it exits;
the panel then keeps its normal one-step clicks.
"""

from __future__ import annotations

import fcntl
import glob
import os
import select
import struct
import sys
import time

EV_KEY = 0x01
BTN_LEFT = 0x110
INITIAL_DELAY = 0.45
REPEAT_DELAY = 0.09

_EVENT = struct.Struct("@llHHi")
_EVIOCGNAME = (2 << 30) | (256 << 16) | (ord("E") << 8) | 0x06


def _eviocgbit(event_type: int, length: int) -> int:
    return (2 << 30) | (length << 16) | (ord("E") << 8) | (0x20 + event_type)


class HoldState:
    """Turns button events into one-shot notifications at a fixed cadence."""

    def __init__(self):
        self.pressed: dict[str, float] = {}

    def feed(
        self, device: str, event_type: int, code: int, value: int, now: float
    ) -> list[str]:
        if event_type != EV_KEY or code != BTN_LEFT:
            return []
        if value == 1:
            self.pressed[device] = now + INITIAL_DELAY
            return [f"down {device}"]
        if value == 0:
            self.pressed.pop(device, None)
            return [f"up {device}"]
        return []

    def due(self, now: float) -> list[str]:
        events = []
        for device, deadline in list(self.pressed.items()):
            if now < deadline:
                continue
            events.append(f"repeat {device}")
            # A suspended process must not emit a burst of stale repeats.
            self.pressed[device] = max(deadline + REPEAT_DELAY, now + REPEAT_DELAY)
        return events

    def next_deadline(self) -> float | None:
        return min(self.pressed.values()) if self.pressed else None


def _device_name(fd: int, fallback: str) -> str:
    try:
        raw = fcntl.ioctl(fd, _EVIOCGNAME, b"\0" * 256)
        name = raw.split(b"\0", 1)[0].decode("utf-8", "replace").strip()
        return name or fallback
    except OSError:
        return fallback


def _open_pointing_devices():
    devices = {}
    bit_length = BTN_LEFT // 8 + 1
    for path in sorted(glob.glob("/dev/input/event*")):
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        except OSError:
            continue
        try:
            bits = bytearray(bit_length)
            fcntl.ioctl(fd, _eviocgbit(EV_KEY, bit_length), bits, True)
            if not bits[BTN_LEFT // 8] & (1 << (BTN_LEFT % 8)):
                os.close(fd)
                continue
        except OSError:
            os.close(fd)
            continue
        devices[fd] = _device_name(fd, os.path.basename(path))
    return devices


def main() -> int:
    devices = _open_pointing_devices()
    if not devices:
        print("hold-repeat: no readable pointing device in /dev/input", file=sys.stderr)
        return 1
    state = HoldState()
    try:
        while True:
            now = time.monotonic()
            deadline = state.next_deadline()
            # Idle: block until a button event arrives (no 10 Hz wakeups).
            timeout = None if deadline is None else max(0.0, deadline - now)
            readable, _, _ = select.select(list(devices), [], [], timeout)
            for fd in readable:
                try:
                    data = os.read(fd, _EVENT.size * 64)
                except OSError:
                    continue
                for offset in range(0, len(data) - _EVENT.size + 1, _EVENT.size):
                    _sec, _usec, event_type, code, value = _EVENT.unpack_from(
                        data, offset
                    )
                    for line in state.feed(
                        devices[fd], event_type, code, value, time.monotonic()
                    ):
                        print(line, flush=True)
            for line in state.due(time.monotonic()):
                print(line, flush=True)
    except KeyboardInterrupt:
        return 0
    finally:
        for fd in devices:
            try:
                os.close(fd)
            except OSError:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
