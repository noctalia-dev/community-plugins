#!/usr/bin/env python3
"""One-shot battery query for LAMZU-protocol wireless mice.

Prints one JSON object on stdout and exits:

    {"devices": [{"name": ..., "vid": "373E", "pid": "0047", "node": "/dev/hidraw6",
                  "status": "ok" | "asleep" | "no_permission" | "error",
                  "percent": 81, "charging": false}]}

Matches every hidraw device on LAMZU's USB vendor ids (373E, 37B0) - 2.4G
receivers and cable-connected mice alike - whose report descriptor declares an
unnumbered 64-byte vendor-page feature report, then sends the battery query:

    SET_FEATURE  00 | 00 00 02 02 00 83 00 ...       (report id 0 + 64 bytes)
    GET_FEATURE  00 | ST 00 02 02 00 83 CH PP ...

    ST = 0xA1 reply ready, 0xA0 receiver still waiting on the mouse
    CH = 1 while charging
    PP = battery percent; 0 when the mouse is off or out of range

The query only reads the battery; it changes no mouse settings. Protocol as
documented by github.com/raeAllen17/Wireless-Device-Battery-Monitor
(src/drivers/lamzu.cpp) and confirmed on an Attack Shark R5 Ultra (373e:0047).
"""
import errno
import fcntl
import glob
import json
import os
import time

VENDORS = {"373E", "37B0"}
REPLY_TIMEOUT = 1.5  # seconds; an idle mouse can take a few hundred ms


def _ioc(nr, size):
    return (3 << 30) | (size << 16) | (ord("H") << 8) | nr


HIDIOCSFEATURE = _ioc(0x06, 65)
HIDIOCGFEATURE = _ioc(0x07, 65)


def has_battery_report(desc):
    """True if the descriptor has an unnumbered 64-byte vendor-page feature report."""
    i, page, rid, size, count = 0, 0, 0, 0, 0
    while i < len(desc):
        b = desc[i]
        if b == 0xFE:  # long item
            i += 3 + (desc[i + 1] if i + 1 < len(desc) else 0)
            continue
        n = (0, 1, 2, 4)[b & 3]
        val = int.from_bytes(desc[i + 1:i + 1 + n], "little")
        tag = b & 0xFC
        if tag == 0x04:
            page = val
        elif tag == 0x84:
            rid = val
        elif tag == 0x74:
            size = val
        elif tag == 0x94:
            count = val
        elif tag == 0xB0 and rid == 0 and size * count == 512 and page >= 0xFF00:
            return True
        i += 1 + n
    return False


def find_devices():
    found = {}
    for d in sorted(glob.glob("/sys/class/hidraw/hidraw*")):
        try:
            with open(os.path.join(d, "device/uevent")) as f:
                ev = dict(l.strip().split("=", 1) for l in f if "=" in l)
            with open(os.path.join(d, "device/report_descriptor"), "rb") as f:
                desc = f.read()
        except OSError:
            continue
        hid_id = ev.get("HID_ID", "").upper().split(":")
        if len(hid_id) != 3:
            continue
        vid, pid = hid_id[1][-4:], hid_id[2][-4:]
        if vid not in VENDORS or not has_battery_report(desc):
            continue
        root = ev.get("HID_PHYS", "").rsplit("/", 1)[0]  # one entry per USB device
        found.setdefault(root, {
            "name": ev.get("HID_NAME", "").strip() or f"{vid}:{pid}",
            "vid": vid,
            "pid": pid,
            "node": "/dev/" + os.path.basename(d),
        })
    return list(found.values())


def query(dev):
    try:
        fd = os.open(dev["node"], os.O_RDWR)
    except OSError as e:
        dev["status"] = "no_permission" if e.errno in (errno.EACCES, errno.EPERM) else "error"
        return
    try:
        req = bytearray(65)
        req[3], req[4], req[6] = 0x02, 0x02, 0x83
        fcntl.ioctl(fd, HIDIOCSFEATURE, bytes(req))
        deadline = time.monotonic() + REPLY_TIMEOUT
        while True:
            time.sleep(0.1)
            r = bytearray(65)
            fcntl.ioctl(fd, HIDIOCGFEATURE, r)
            if 0xA0 not in (r[0], r[1]) or time.monotonic() > deadline:
                break
    except OSError:
        dev["status"] = "error"
        return
    finally:
        os.close(fd)

    if r[1] == 0xA1 and r[4] == 0x02 and r[6] == 0x83:
        chg, pct = r[7], r[8]
    elif r[0] == 0xA1 and r[3] == 0x02 and r[5] == 0x83:
        chg, pct = r[6], r[7]
    elif 0xA0 in (r[0], r[1]):
        dev["status"] = "asleep"
        return
    else:
        dev["status"] = "error"
        return
    if pct == 0:
        dev["status"] = "asleep"
    elif pct <= 100:
        dev.update(status="ok", percent=pct, charging=chg == 1)
    else:
        dev["status"] = "error"


def main():
    devices = find_devices()
    for dev in devices:
        query(dev)
    print(json.dumps({"devices": devices}))


if __name__ == "__main__":
    main()
