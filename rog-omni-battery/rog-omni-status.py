"""Read pairing and battery reports from an ASUS ROG Omni Receiver on Linux."""

import json
import os
from pathlib import Path
import select
import stat
import time

# Pair-list identifiers and report layouts documented by HaloBattery.
MICE = {
    0x1A68: ("ROG Keris Wireless Aimpoint", 5),
    0x1A6A: ("ROG Keris Wireless Aimpoint", 5),
    0x1A72: ("ROG Gladius III Aimpoint", 5),
    0x1A94: ("ROG Harpe Ace Aim Lab Edition", 5),
    0x1AD7: ("ROG Strix Impact III Wireless", 5),
    0x1B18: ("ROG Keris II Ace", 5),
    0x1B1A: ("ROG Keris II Ace", 5),
    0x1B65: ("ROG Harpe Ace Mini", 5),
    0x1B68: ("ROG Harpe Ace Extreme", 5),
    0x1B69: ("ROG Harpe Ace Extreme", 5),
    0x1C0E: ("ROG Keris II Origin", 5),
    0x1D4E: ("ROG Keris II Origin KJP", 5),
}
KEYBOARDS = {
    0x1A85: ("ROG Azoth", 6),
    0x1AB0: ("ROG Strix Scope II 96 Wireless", 6),
    0x1B06: ("ROG Falchion RX Low Profile", 11),
    0x1B42: ("ROG Azoth Extreme", 6),
    0x1B7A: ("ROG Strix Scope II 96 RX Wireless", 6),
    0x1C25: ("ROG Azoth X", 6),
    0x1CEA: ("ROG Strix Morph 96 Wireless", 6),
    0x1CF1: ("ROG Azoth Extreme SE", 6),
}
HID_ID = "0003:00000B05:00001ACE"
INTERFACE = "02"
REPORT_SIZE = 64


class ReceiverError(Exception):
    """An expected receiver state, reported to the widget as a translation key."""


def find_receiver():
    matches = []
    for node in Path("/sys/class/hidraw").glob("hidraw*"):
        device = (node / "device").resolve()
        try:
            fields = (device / "uevent").read_text().splitlines()
            if (f"HID_ID={HID_ID}" in fields
                    and (device.parent / "bInterfaceNumber").read_text().strip() == INTERFACE):
                matches.append(node)
        except FileNotFoundError:
            continue  # A device can disappear during enumeration.
    if not matches:
        raise ReceiverError("disconnected")
    if len(matches) > 1:
        raise ReceiverError("multiple_receivers")
    return matches[0]


def query(fd, request, header=None):
    for _ in range(16):
        try:
            if not os.read(fd, REPORT_SIZE):
                break
        except BlockingIOError:
            break
    if os.write(fd, request.ljust(REPORT_SIZE, bytes(1))) != REPORT_SIZE:
        raise OSError("Incomplete HID write")

    header = request if header is None else header
    deadline = time.monotonic() + 1
    while (remaining := deadline - time.monotonic()) > 0:
        if not select.select([fd], [], [], remaining)[0]:
            break
        try:
            reply = os.read(fd, REPORT_SIZE)
        except BlockingIOError:
            continue
        if not reply:
            raise OSError("HID device closed")
        if len(reply) == REPORT_SIZE and reply.startswith(header):
            return reply
    return b""


def paired_ids(reply):
    ids = []
    for offset in range(5, len(reply) - 1, 4):
        product_id = int.from_bytes(reply[offset:offset + 2], "little")
        if product_id == 0:
            break
        ids.append(product_id)
    return ids


def read_device(fd, ids, models, request, charging_byte):
    product_id = next((pid for pid in ids if pid in models), None)
    if product_id is None:
        return {}
    model, level_byte = models[product_id]
    device = {"pid": product_id, "name": model}
    reply = query(fd, request)
    if reply:
        level = reply[level_byte]
        charging = reply[charging_byte] != 0
        if level <= 100 and (level > 0 or charging):
            device.update(level=level, charging=charging)
    return device


def read_status():
    node = find_receiver()
    major, minor = map(int, (node / "dev").read_text().strip().split(":"))
    fd = os.open(f"/dev/{node.name}", os.O_RDWR | os.O_NONBLOCK | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if not stat.S_ISCHR(info.st_mode) or info.st_rdev != os.makedev(major, minor):
            raise ReceiverError("disconnected")

        reply = query(fd, bytes.fromhex("01 a0 00 00"), bytes.fromhex("01 a0"))
        if not reply:
            raise ReceiverError("pairing_unavailable")
        ids = paired_ids(reply)
        return {
            "receiver": str(node.resolve()),
            "mouse": read_device(fd, ids, MICE, bytes.fromhex("03 12 07"), 10),
            "keyboard": read_device(fd, ids, KEYBOARDS, bytes.fromhex("02 12 01"), 9),
        }
    finally:
        os.close(fd)


def main():
    try:
        result = read_status()
    except ReceiverError as error:
        result = {"error": str(error)}
    except PermissionError:
        result = {"error": "permission"}
    except FileNotFoundError:
        result = {"error": "disconnected"}
    except OSError:
        result = {"error": "read_failed"}
    print(json.dumps(result))


if __name__ == "__main__":
    main()
