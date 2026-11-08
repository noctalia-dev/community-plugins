#!/usr/bin/env python3
"""typing-stats - count printable key presses from the Linux evdev devices.

Output is line based:

    READY <count>   listener is up and reading <count> keyboards
    C               one printable key press (count it as one character)
    PING            heartbeat, every 15 s
    ERR <reason>    no readable keyboard device

Letters, digits, punctuation, space and the keypad keys count. Modifiers,
navigation/function keys and shortcuts (Ctrl/Alt/Super held) do not. A held
key's autorepeat does NOT count: one press, one character, no free inflation.

Reading /dev/input/event* needs permission. ``setup.sh`` installs one udev rule
that tags keyboard event nodes ``uaccess``; systemd-logind then gives the
active local session user an ACL on them.
"""

import glob
import os
import select
import signal
import struct
import sys
import time

EVENT = struct.Struct("qqHHi")
EV_KEY = 0x01
SCAN_INTERVAL = 2.0
PING_INTERVAL = 15.0
ERROR_INTERVAL = 10.0

KEY_A = 30

CTRL = {29, 97}
ALT = {56, 100}
SUPER = {125, 126}

# Linux key codes that produce a character on a normal layout. This is a
# physical-key count: Shift+2 is one character (the '@'), and IME composition
# keys are counted as they are typed.
PRINTABLE = set()
PRINTABLE.update(range(2, 12))    # 1..0
PRINTABLE.update(range(16, 26))   # Q..P
PRINTABLE.update(range(30, 39))   # A..L
PRINTABLE.update(range(44, 51))   # Z..M
PRINTABLE.update({12, 13, 26, 27, 39, 40, 41, 43, 51, 52, 53, 86})
PRINTABLE.add(57)                 # Space
PRINTABLE.update(range(71, 84))   # Keypad 7..0, dot, operators


def _emit(line):
    sys.stdout.write(line)
    sys.stdout.write("\n")
    sys.stdout.flush()


def _capabilities(dev, kind):
    name = os.path.basename(os.path.realpath(dev))
    path = f"/sys/class/input/{name}/device/capabilities/{kind}"
    try:
        with open(path, "r", encoding="ascii") as handle:
            # The key bitmap is a space-separated list of 64-bit words.
            return int("".join(handle.read().split()), 16)
    except (OSError, ValueError):
        return None


def is_keyboard(dev):
    events = _capabilities(dev, "ev")
    keys = _capabilities(dev, "key")
    if events is None or keys is None:
        return False
    if not events & (1 << EV_KEY):
        return False
    return bool(keys & (1 << KEY_A))


def candidates():
    found = []
    seen = set()
    for pattern in ("/dev/input/by-id/*event-kbd", "/dev/input/by-path/*event-kbd"):
        for path in sorted(glob.glob(pattern)):
            real = os.path.realpath(path)
            if real not in seen and is_keyboard(real):
                seen.add(real)
                found.append(real)
    for path in sorted(glob.glob("/dev/input/event*")):
        real = os.path.realpath(path)
        if real not in seen and is_keyboard(real):
            seen.add(real)
            found.append(real)
    return found


def test_devices():
    devices = candidates()
    print(f"keyboards with an EV_KEY + KEY_A capability: {len(devices)}")
    readable = 0
    for dev in devices:
        if os.access(dev, os.R_OK):
            readable += 1
            status = "READABLE"
        else:
            status = "PERMISSION DENIED"
        print(f"  {dev}  {status}")
    if devices and readable == 0:
        print("run 'sudo ./setup.sh' in the plugin directory to install the udev rule")
    return 0 if readable else 1


class Listener:
    def __init__(self):
        self.poll = select.poll()
        self.open = {}
        self.ready = False
        self.last_ping = time.monotonic()
        self.last_error = 0.0
        self.ctrl = 0
        self.alt = 0
        self.super = 0

    def _close(self, fd):
        try:
            self.poll.unregister(fd)
        except (KeyError, ValueError):
            pass
        try:
            os.close(fd)
        except OSError:
            pass
        self.open.pop(fd, None)

    def _rescan(self):
        wanted = candidates()
        wanted_set = set(wanted)
        for fd, dev in list(self.open.items()):
            if dev not in wanted_set:
                self._close(fd)
        for dev in wanted:
            if dev in self.open.values():
                continue
            try:
                fd = os.open(dev, os.O_RDONLY | os.O_NONBLOCK)
            except OSError:
                continue
            self.open[fd] = dev
            self.poll.register(fd, select.POLLIN)
        if self.open and not self.ready:
            self.ready = True
            _emit(f"READY {len(self.open)}")

    def _report_error(self, now):
        if now - self.last_error < ERROR_INTERVAL:
            return
        self.last_error = now
        _emit("ERR no readable keyboard (run typing-stats/setup.sh once)")

    def _modifier(self, code, value):
        # Only the initial press (1) and the release (0) change the state.
        # Autorepeat (2) must not add extra counts, or a held modifier would
        # get stuck above zero and silently block every following key.
        if value == 1:
            delta = 1
        elif value == 0:
            delta = -1
        else:
            return
        if code in CTRL:
            self.ctrl = max(0, self.ctrl + delta)
        elif code in ALT:
            self.alt = max(0, self.alt + delta)
        elif code in SUPER:
            self.super = max(0, self.super + delta)

    def run(self):
        next_scan = 0.0
        while True:
            now = time.monotonic()
            if now >= next_scan:
                self._rescan()
                next_scan = now + SCAN_INTERVAL

            if not self.open:
                self._report_error(now)
                time.sleep(SCAN_INTERVAL)
                continue

            timeout_ms = max(0, int(min(next_scan - time.monotonic(), 1.0) * 1000))
            try:
                events = self.poll.poll(timeout_ms)
            except InterruptedError:
                continue

            chars = 0
            for fd, _flags in events:
                try:
                    data = os.read(fd, EVENT.size * 64)
                except (BlockingIOError, InterruptedError):
                    continue
                except OSError:
                    self._close(fd)
                    continue
                if not data:
                    self._close(fd)
                    continue

                for offset in range(0, len(data) - EVENT.size + 1, EVENT.size):
                    _sec, _usec, etype, code, value = EVENT.unpack_from(data, offset)
                    if etype != EV_KEY:
                        continue
                    if code in CTRL or code in ALT or code in SUPER:
                        self._modifier(code, value)
                        continue
                    # Only the initial press counts. Holding a key (autorepeat,
                    # value 2) must not inflate the statistics.
                    if value == 1 and code in PRINTABLE:
                        if self.ctrl == 0 and self.alt == 0 and self.super == 0:
                            chars += 1

            if chars:
                _emit("\n".join(["C"] * chars))

            now = time.monotonic()
            if now - self.last_ping >= PING_INTERVAL:
                self.last_ping = now
                _emit("PING")


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--test-devices":
        return test_devices()

    def stop(_signum, _frame):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    try:
        Listener().run()
    except (BrokenPipeError, SystemExit):
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
