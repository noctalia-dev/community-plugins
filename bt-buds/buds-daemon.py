#!/usr/bin/env python3
"""Persistent Xiaomi buds controller: holds one RFCOMM session (ch29),
answers instant commands over a unix socket. Solves EBUSY + speed.
Socket: ~/.local/state/bt-buds/ctl.sock
Commands: 'mode anc|off|transparency' -> 'ok <mode>' | 'battery' -> 'ok L R C'
"""
import json
import os
import socket
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from buds_proto import encode, extract_messages, parse_battery

MAC = "78:99:87:AD:44:BA"
CH = 29
STATE_DIR = os.path.expanduser("~/.local/state/bt-buds")
SOCK_PATH = os.path.join(STATE_DIR, "ctl.sock")
MODE_FILE = os.path.join(STATE_DIR, "mode.json")
VALUES = {"off": 0x00, "anc": 0x01, "transparency": 0x02}


def log(*a):
    print("[buds-daemon]", *a, flush=True)


class Buds:
    def __init__(self):
        self.s = None
        self.buf = b""
        self.seq = 0

    def connect(self):
        self.close()
        self.s = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_STREAM,
                               socket.BTPROTO_RFCOMM)
        self.s.settimeout(4)
        self.s.connect((MAC, CH))
        self.buf = b""
        self.seq = 0
        return True

    def close(self):
        try:
            if self.s:
                self.s.close()
        except Exception:
            pass
        self.s = None

    def _send_raw(self, data):
        self.s.send(data)

    def send(self, mtype, opcode, payload):
        f = encode(mtype, opcode, self.seq, payload)
        self.s.send(f)
        self.seq = (self.seq + 1) & 0xFF

    def _drain(self, wait):
        self.s.settimeout(wait)
        try:
            while True:
                d = self.s.recv(4096)
                if not d:
                    break
                self.buf += d
        except socket.timeout:
            pass

    def _read_msgs(self, timeout):
        self.s.settimeout(timeout)
        msgs = []
        t0 = time.time()
        while time.time() - t0 < timeout:
            try:
                d = self.s.recv(4096)
            except socket.timeout:
                break
            if not d:
                break
            self.buf += d
            m, self.buf = extract_messages(self.buf)
            msgs.extend(m)
            if m:
                break
        return msgs

    def set_mode(self, mode):
        val = VALUES[mode]
        # phone-style raw frames (proven on wire); spec framing is ignored for SET
        self._send_raw(bytes.fromhex("19fedcbac4080004080204%02x" % val))
        self._drain(0.6)
        self._send_raw(bytes.fromhex("15fedcba04f40002001f"))
        self._drain(0.3)
        return True

    def get_battery(self):
        for attempt in range(3):
            self.send(0xC4, 0x02, [0xFF, 0xFF, 0xFF, 0xFF])
            t0 = time.time()
            while time.time() - t0 < 4:
                for m in self._read_msgs(1.5):
                    if m["opcode"] == 0x02:
                        b = parse_battery(m["payload"])
                        if b:
                            return b
        return None


def save_mode(mode):
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(MODE_FILE, "w") as f:
        json.dump({"mode": mode}, f)


def handle(buds, cmd):
    """Execute one client command. Returns the reply line (no newline)."""
    if cmd[0] == "mode" and len(cmd) == 2 and cmd[1] in VALUES:
        buds.set_mode(cmd[1])
        save_mode(cmd[1])
        return "ok %s" % cmd[1]
    if cmd[0] == "battery":
        b = buds.get_battery()
        if b:
            return "ok %d %d %d" % (b["left"], b["right"], b["case"])
        return "err no-data"
    return "err unknown"


def main():
    os.makedirs(STATE_DIR, exist_ok=True)
    # single instance: if someone already serves the socket, exit quietly
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    probe.settimeout(1)
    try:
        probe.connect(SOCK_PATH)
        probe.sendall(b"battery\n")
        probe.settimeout(3)
        if probe.recv(64):
            log("another instance is alive, exiting")
            return 0
    except (OSError, socket.timeout):
        pass
    finally:
        probe.close()
    try:
        os.unlink(SOCK_PATH)
    except FileNotFoundError:
        pass
    buds = Buds()
    try:
        buds.connect()
    except Exception as e:
        log("initial connect fail:", e)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCK_PATH)
    srv.listen(5)
    log("listening", SOCK_PATH)
    while True:
        conn, _ = srv.accept()
        try:
            conn.settimeout(10)
            data = b""
            while not data.endswith(b"\n"):
                chunk = conn.recv(64)
                if not chunk:
                    break
                data += chunk
            cmd = data.decode().strip().split()
            if not cmd:
                continue
            try:
                conn.sendall((handle(buds, cmd) + "\n").encode())
            except (OSError, socket.timeout) as e:
                log("buds link lost, reconnect + retry:", e)
                try:
                    buds.connect()
                    conn.sendall((handle(buds, cmd) + "\n").encode())
                except Exception as e2:
                    log("retry failed:", e2)
                    try:
                        conn.sendall(b"err retry\n")
                    except Exception:
                        pass
        finally:
            conn.close()


if __name__ == "__main__":
    main()
