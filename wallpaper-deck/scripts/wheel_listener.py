#!/usr/bin/env python3
"""
Lightweight mouse wheel listener for Wallpaper Deck.
Listens to evdev input events and sends native Noctalia IPC messages (prev/next).
Runs only while the Wallpaper Deck picker panel is open.
"""
import fcntl
import glob
import os
import select
import signal
import struct
import subprocess
import sys
import time

def main():
    if len(sys.argv) < 2:
        sys.exit(1)

    pid_file = os.path.abspath(os.path.expanduser(sys.argv[1]))
    os.makedirs(os.path.dirname(pid_file), exist_ok=True)
    try:
        with open(pid_file, "w") as f:
            f.write(str(os.getpid()))
    except Exception:
        pass

    def cleanup(*_args):
        try:
            if os.path.exists(pid_file):
                os.remove(pid_file)
        except Exception:
            pass
        sys.exit(0)

    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)

    EV_REL = 0x02
    REL_WHEEL = 0x08
    REL_HWHEEL = 0x06
    REL_WHEEL_HI_RES = 11

    fds = []
    for p in sorted(glob.glob("/dev/input/event*")):
        try:
            fd = os.open(p, os.O_RDONLY | os.O_NONBLOCK)
            buf = bytearray(8)
            fcntl.ioctl(fd, 0x80084520 + EV_REL, buf)
            mask = int.from_bytes(buf, "little")
            if mask & ((1 << REL_WHEEL) | (1 << REL_HWHEEL)):
                fds.append(fd)
            else:
                os.close(fd)
        except Exception:
            pass

    if not fds:
        return

    last_trigger = 0.0
    COOLDOWN = 0.05

    def step(action: str):
        subprocess.run(
            ["noctalia", "msg", "plugin", "ishan0121/wallpaper-deck:picker", "all", action],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    try:
        while True:
            if not os.path.exists(pid_file):
                break

            r, _, _ = select.select(fds, [], [], 0.4)
            for fd in r:
                try:
                    while True:
                        data = os.read(fd, 24)
                        if len(data) < 24:
                            break
                        _, _, ev_type, ev_code, ev_val = struct.unpack("QQHHi", data)
                        if ev_type == EV_REL:
                            if ev_code in (REL_WHEEL, REL_WHEEL_HI_RES):
                                now = time.time()
                                if now - last_trigger >= COOLDOWN:
                                    last_trigger = now
                                    if ev_val > 0:
                                        step("prev")
                                    elif ev_val < 0:
                                        step("next")
                            elif ev_code == REL_HWHEEL:
                                now = time.time()
                                if now - last_trigger >= COOLDOWN:
                                    last_trigger = now
                                    if ev_val > 0:
                                        step("next")
                                    elif ev_val < 0:
                                        step("prev")
                except Exception:
                    break
    finally:
        for fd in fds:
            try:
                os.close(fd)
            except Exception:
                pass
        cleanup()

if __name__ == "__main__":
    main()
