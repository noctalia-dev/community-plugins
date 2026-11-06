#!/usr/bin/env python3
"""
Lightweight mouse wheel listener for Wallpaper Deck.
Listens to evdev input events and sends native Noctalia IPC messages (prev/next).
Runs only while the Wallpaper Deck picker panel is open.
"""
import array
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
                with open(pid_file, "r") as pf:
                    recorded = pf.read().strip()
                if recorded == str(os.getpid()):
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

    EVENT_FORMAT = "llHHi"
    EVENT_SIZE = struct.calcsize(EVENT_FORMAT)

    fds = []
    has_standard_wheel = {}
    for p in sorted(glob.glob("/dev/input/event*")):
        try:
            fd = os.open(p, os.O_RDONLY | os.O_NONBLOCK)
            buf = bytearray(8)
            fcntl.ioctl(fd, 0x80084520 + EV_REL, buf)
            mask = int.from_bytes(buf, sys.byteorder)
            if mask & ((1 << REL_WHEEL) | (1 << REL_HWHEEL) | (1 << REL_WHEEL_HI_RES)):
                fds.append(fd)
                has_standard_wheel[fd] = bool(mask & (1 << REL_WHEEL))
            else:
                os.close(fd)
        except Exception:
            pass

    if not fds:
        cleanup()
        return

    last_trigger = 0.0
    COOLDOWN = 0.055
    hi_res_accum = 0
    active_proc = None

    def step(action: str):
        nonlocal active_proc
        try:
            if active_proc is not None and active_proc.poll() is None:
                return
            active_proc = subprocess.Popen(
                ["noctalia", "msg", "plugin", "ishan0121/wallpaper-deck:picker", "all", action],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except Exception:
            pass

    try:
        while True:
            if not os.path.exists(pid_file):
                break

            r, _, _ = select.select(fds, [], [], 0.35)
            for fd in r:
                try:
                    while True:
                        data = os.read(fd, EVENT_SIZE * 16)
                        if not data or len(data) < EVENT_SIZE:
                            break
                        offset = 0
                        while offset + EVENT_SIZE <= len(data):
                            _, _, ev_type, ev_code, ev_val = struct.unpack_from(EVENT_FORMAT, data, offset)
                            offset += EVENT_SIZE
                            if ev_type != EV_REL or ev_val == 0:
                                continue

                            now = time.monotonic()
                            if ev_code == REL_WHEEL:
                                hi_res_accum = 0
                                if now - last_trigger >= COOLDOWN:
                                    last_trigger = now
                                    step("prev" if ev_val > 0 else "next")
                            elif ev_code == REL_WHEEL_HI_RES and not has_standard_wheel.get(fd, False):
                                hi_res_accum += ev_val
                                if abs(hi_res_accum) >= 120:
                                    direction = "prev" if hi_res_accum > 0 else "next"
                                    hi_res_accum = 0
                                    if now - last_trigger >= COOLDOWN:
                                        last_trigger = now
                                        step(direction)
                            elif ev_code == REL_HWHEEL:
                                if now - last_trigger >= COOLDOWN:
                                    last_trigger = now
                                    step("next" if ev_val > 0 else "prev")
                except BlockingIOError:
                    continue
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
