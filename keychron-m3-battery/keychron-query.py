#!/usr/bin/env python3
"""Read the battery of a Keychron mouse through its 2.4 GHz receiver.

Talks to the receiver's vendor HID interface (usage page 0xFF0A) with the
"get power" request the Keychron Launcher uses for 4K/8K Nordic mice
(M3 mini 4K and friends), forwarded to the mouse by setting bit 6 of byte 0.

Prints "<percent> <state>" on success (state: 0 = discharging, else charging),
followed by "receiver=<product>" and "receiver_fw=<version>" lines taken from
the receiver's USB descriptor. Exit codes: 2 = no receiver, 3 = no permission, 4 = mouse did not answer.
"""
import glob
import os
import select
import sys
import time

KEYCHRON_VID = "00003434"
VENDOR_USAGE_PAGE = bytes([0x06, 0x0A, 0xFF])
TIMEOUT_S = 1.5


def find_hidraw():
    for node in sorted(glob.glob("/sys/class/hidraw/hidraw*")):
        try:
            with open(f"{node}/device/uevent") as f:
                if f"HID_ID=0003:{KEYCHRON_VID}:" not in f.read():
                    continue
            with open(f"{node}/device/report_descriptor", "rb") as f:
                if not f.read().startswith(VENDOR_USAGE_PAGE):
                    continue
        except OSError:
            continue
        return "/dev/" + os.path.basename(node), node
    return None, None


def receiver_info(node):
    """Product name and firmware (bcdDevice) of the USB device behind node."""
    usb = os.path.realpath(f"{node}/device/../..")
    info = {}
    for key, attr in (("receiver", "product"), ("receiver_fw", "bcdDevice")):
        try:
            with open(f"{usb}/{attr}") as f:
                info[key] = f.read().strip()
        except OSError:
            pass
    if "receiver_fw" in info:
        bcd = info["receiver_fw"]
        info["receiver_fw"] = f"{int(bcd[:2], 16)}.{bcd[2:]}"
    return info


def power_request():
    buf = bytearray(64)
    buf[0] = 0x41  # 0x01 "get power", | 0x40 = forward to the wireless mouse
    buf[2] = 0x81
    buf[3] = 0x01
    buf[63] = (161 - (sum(buf[:63]) & 0xFF)) & 0xFF
    return bytes(buf)


def main():
    dev, node = find_hidraw()
    if dev is None:
        print("no Keychron receiver found", file=sys.stderr)
        return 2
    try:
        fd = os.open(dev, os.O_RDWR | os.O_NONBLOCK)
    except PermissionError:
        print(f"no permission for {dev} (udev rule missing?)", file=sys.stderr)
        return 3

    # No report IDs on this interface: the leading 0x00 is the report-id placeholder.
    os.write(fd, b"\x00" + power_request())
    deadline = time.monotonic() + TIMEOUT_S
    while (left := deadline - time.monotonic()) > 0:
        if not select.select([fd], [], [], left)[0]:
            break
        rep = os.read(fd, 64)
        if len(rep) >= 7 and rep[0] == 0x41 and rep[2] == 0x8C and rep[3] == 0x01:
            state, level = rep[5], rep[6]
            if 0 < level <= 100:
                print(level, state)
                for key, value in receiver_info(node).items():
                    print(f"{key}={value}")
                return 0
    print("mouse did not answer (off or asleep?)", file=sys.stderr)
    return 4


if __name__ == "__main__":
    sys.exit(main())
