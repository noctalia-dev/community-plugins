#!/usr/bin/env python3
"""Thin client: read battery via buds-daemon (instant).
Prints: L R CASE. Exit 0 on success.
"""
import os
import socket
import sys

SOCK = os.path.expanduser("~/.local/state/bt-buds/ctl.sock")


def main():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    try:
        s.connect(SOCK)
    except Exception as e:
        print("daemon down: %s" % e, file=sys.stderr)
        return 1
    s.sendall(b"battery\n")
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
