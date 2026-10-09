#!/usr/bin/env python3
"""Thin client: set listening mode via buds-daemon (instant)."""
import os
import socket
import sys

SOCK = os.path.expanduser("~/.local/state/bt-buds/ctl.sock")


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("anc", "off", "transparency"):
        print("usage: mode.py anc|off|transparency", file=sys.stderr)
        return 2
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    try:
        s.connect(SOCK)
    except Exception as e:
        print("daemon down: %s" % e, file=sys.stderr)
        return 1
    s.sendall(("mode %s\n" % sys.argv[1]).encode())
    try:
        resp = s.recv(64).decode().strip()
    except socket.timeout:
        print("daemon timeout", file=sys.stderr)
        return 1
    finally:
        s.close()
    if resp.startswith("ok "):
        print(resp[3:])
        return 0
    print(resp or "err", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
