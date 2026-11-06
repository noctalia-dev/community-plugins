#!/usr/bin/env python3
"""
Honor Earbuds Controller for Noctalia Shell v5
Outputs JSON for consumption by Luau service.
"""

import sys
import socket
import argparse
import subprocess
import json
import re
import time

from honor_protocol import build_packet, parse_packets

ANC_MODES = {0: "off", 1: "anc", 2: "transparency"}
ANC_CODE_MAP = {"off": 0, "normal": 0, "anc": 1, "on": 1, "transparency": 2, "awareness": 2}
EQ_MAP = {"balanced": 0, "bass": 1, "vocal": 2}

def is_device_connected(mac: str) -> bool:
    try:
        out = subprocess.check_output(["bluetoothctl", "devices", "Connected"], text=True, stderr=subprocess.DEVNULL)
        for line in out.strip().splitlines():
            if mac.lower() in line.lower():
                return True
    except Exception:
        pass
    try:
        out = subprocess.check_output(["bluetoothctl", "info", mac], text=True, stderr=subprocess.DEVNULL)
        return "Connected: yes" in out
    except Exception:
        pass
    return False

def find_device():
    # 1. Look for currently connected Honor earbuds
    try:
        out = subprocess.check_output(["bluetoothctl", "devices", "Connected"], text=True, stderr=subprocess.DEVNULL)
        for line in out.strip().splitlines():
            m = re.match(r"^Device\s+([0-9A-Fa-f:]{17})\s+(.+)$", line)
            if m:
                mac, name = m.group(1), m.group(2)
                if "honor choice" in name.lower() or "honor earbuds" in name.lower():
                    return mac, name, True
    except Exception:
        pass

    # 2. Look for any paired Honor earbuds
    try:
        out = subprocess.check_output(["bluetoothctl", "devices"], text=True, stderr=subprocess.DEVNULL)
        for line in out.strip().splitlines():
            m = re.match(r"^Device\s+([0-9A-Fa-f:]{17})\s+(.+)$", line)
            if m:
                mac, name = m.group(1), m.group(2)
                if "honor choice" in name.lower() or "honor earbuds" in name.lower():
                    return mac, name, False
    except Exception:
        pass

    return "10:28:74:10:D1:92", "HONOR CHOICE Earbuds X5", False

class EarbudsClient:
    def __init__(self, mac: str, name: str = "HONOR CHOICE Earbuds X5"):
        self.mac = mac
        self.name = name
        self.sock = None

    def connect(self):
        for ch in (18, 12):
            s = None
            try:
                s = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_STREAM, socket.BTPROTO_RFCOMM)
                s.settimeout(1.2)
                s.connect((self.mac, ch))
                self.sock = s
                return True
            except Exception:
                if s:
                    try:
                        s.close()
                    except Exception:
                        pass
        return False

    def close(self):
        if self.sock:
            try:
                self.sock.close()
            except Exception:
                pass
            self.sock = None

    def exchange(self, cmd_pkt: bytes, wait_cmd: bytes = None):
        if not self.sock and not self.connect():
            raise ConnectionError("Disconnected")
        self.sock.sendall(cmd_pkt)
        received = []
        while True:
            try:
                chunk = self.sock.recv(1024)
                if not chunk:
                    break
                pkts = parse_packets(chunk)
                received.extend(pkts)
                if wait_cmd and any(c == wait_cmd for c, _ in pkts):
                    break
                elif not wait_cmd and len(pkts) > 0:
                    break
            except socket.timeout:
                break
            except Exception:
                break
        return received

    def get_status(self):
        if not self.sock and not self.connect():
            return {
                "connected": False,
                "mac": self.mac,
                "model_name": self.name,
                "noise_mode": "off",
                "noise_mode_code": 0,
                "battery_left": None,
                "battery_right": None,
                "battery_case": None,
                "charging_left": False,
                "charging_right": False,
                "charging_case": False
            }

        # 1. Query ANC
        anc_code = 0
        anc_ok = False
        try:
            anc_pkts = self.exchange(build_packet(b"\x2b\x2a"), wait_cmd=b"\x2b\x2a")
            for cmd, params in anc_pkts:
                if cmd == b"\x2b\x2a" and 1 in params and len(params[1]) > 0:
                    anc_code = params[1][-1]
                    anc_ok = True
        except Exception:
            pass

        # 2. Query Battery
        bat = {"left": None, "right": None, "case": None, "chg_left": False, "chg_right": False, "chg_case": False}
        bat_ok = False
        try:
            bat_pkts = self.exchange(build_packet(b"\x01\x08"), wait_cmd=b"\x01\x08")
            for cmd, params in bat_pkts:
                if cmd == b"\x01\x08":
                    if 2 in params and len(params[2]) >= 3:
                        bat["left"] = params[2][0]
                        bat["right"] = params[2][1]
                        bat["case"] = params[2][2]
                        bat_ok = True
                    if 3 in params and len(params[3]) >= 3:
                        bat["chg_left"] = (params[3][0] == 1)
                        bat["chg_right"] = (params[3][1] == 1)
                        bat["chg_case"] = (params[3][2] == 1)
        except Exception:
            pass

        if not anc_ok and not bat_ok:
            self.close()
            return {
                "connected": False,
                "mac": self.mac,
                "model_name": self.name,
                "noise_mode": "off",
                "noise_mode_code": 0,
                "battery_left": None,
                "battery_right": None,
                "battery_case": None,
                "charging_left": False,
                "charging_right": False,
                "charging_case": False
            }

        return {
            "connected": True,
            "mac": self.mac,
            "model_name": self.name,
            "noise_mode": ANC_MODES.get(anc_code, "off"),
            "noise_mode_code": anc_code,
            "battery_left": bat["left"],
            "battery_right": bat["right"],
            "battery_case": bat["case"],
            "charging_left": bat["chg_left"],
            "charging_right": bat["chg_right"],
            "charging_case": bat["chg_case"]
        }

    def set_anc(self, mode_str: str):
        code = ANC_CODE_MAP.get(mode_str.lower(), 0)
        if not self.sock and not self.connect():
            raise ConnectionError("Disconnected")
        # Use exchange with short timeout: earbuds may need to complete the
        # transaction (send + recv) before applying the mode, but we don't
        # want to block for the default 1.2s and cause audio dropout.
        old_timeout = self.sock.gettimeout()
        self.sock.settimeout(0.2)
        self.exchange(build_packet(b"\x2b\x04", [(1, bytes([code]))]))
        self.sock.settimeout(old_timeout)
        time.sleep(0.3)
        return {
            "connected": True,
            "noise_mode": ANC_MODES.get(code, "off"),
            "noise_mode_code": code,
        }

    def cycle_anc(self):
        curr = self.get_status()
        next_code = (curr["noise_mode_code"] + 1) % 3
        self.close()
        if not self.sock and not self.connect():
            raise ConnectionError("Disconnected")
        pkt = build_packet(b"\x2b\x04", [(1, bytes([next_code]))])
        self.sock.sendall(pkt)
        self.close()
        time.sleep(0.5)
        return {
            "connected": True,
            "noise_mode": ANC_MODES.get(next_code, "off"),
            "noise_mode_code": next_code,
        }

    def set_eq(self, preset_str: str):
        code = EQ_MAP.get(preset_str.lower(), 0)
        self.exchange(build_packet(b"\x27\x01", [(1, bytes([code]))]))
        return {
            "connected": True,
            "eq": preset_str,
        }

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", nargs="?", default="status", choices=["status", "set-anc", "cycle-anc", "set-eq"])
    parser.add_argument("value", nargs="?", default=None)
    parser.add_argument("--mac", default=None)
    args = parser.parse_args()

    if args.mac:
        mac = args.mac
        name = "HONOR CHOICE Earbuds X5"
        is_conn = is_device_connected(mac)
    else:
        mac, name, is_conn = find_device()

    if not is_conn:
        print(json.dumps({
            "connected": False,
            "mac": mac,
            "model_name": name,
            "noise_mode": "off",
            "noise_mode_code": 0,
            "battery_left": None,
            "battery_right": None,
            "battery_case": None,
            "charging_left": False,
            "charging_right": False,
            "charging_case": False
        }, ensure_ascii=False))
        return

    client = EarbudsClient(mac, name)
    try:
        if args.action == "status":
            res = client.get_status()
        elif args.action == "set-anc":
            res = client.set_anc(args.value or "off")
        elif args.action == "cycle-anc":
            res = client.cycle_anc()
        elif args.action == "set-eq":
            res = client.set_eq(args.value or "balanced")
        print(json.dumps(res, ensure_ascii=False))
    except Exception as e:
        print(json.dumps({
            "connected": False,
            "error": str(e),
            "mac": mac,
            "model_name": name,
            "noise_mode": "off",
            "noise_mode_code": 0,
            "battery_left": None,
            "battery_right": None,
            "battery_case": None,
            "charging_left": False,
            "charging_right": False,
            "charging_case": False
        }, ensure_ascii=False))
    finally:
        client.close()

if __name__ == "__main__":
    main()
