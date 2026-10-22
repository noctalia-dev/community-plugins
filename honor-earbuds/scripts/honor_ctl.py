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

CRC16_TAB = [
    0, 4129, 8258, 12387, 16516, 20645, 24774, 28903, -32504, -28375, -24246, -20117, -15988, -11859,
    -7730, -3601, 4657, 528, 12915, 8786, 21173, 17044, 29431, 25302, -27847, -31976, -19589, -23718, -11331,
    -15460, -3073, -7202, 9314, 13379, 1056, 5121, 25830, 29895, 17572, 21637, -23190, -19125, -31448,
    -27383, -6674, -2609, -14932, -10867, 13907, 9842, 5649, 1584, 30423, 26358, 22165, 18100, -18597,
    -22662, -26855, -30920, -2081, -6146, -10339, -14404, 18628, 22757, 26758, 30887, 2112, 6241, 10242,
    14371, -13876, -9747, -5746, -1617, -30392, -26263, -22262, -18133, 23285, 19156, 31415, 27286, 6769,
    2640, 14899, 10770, -9219, -13348, -1089, -5218, -25735, -29864, -17605, -21734, 27814, 31879, 19684,
    23749, 11298, 15363, 3168, 7233, -4690, -625, -12820, -8755, -21206, -17141, -29336, -25271, 32407,
    28342, 24277, 20212, 15891, 11826, 7761, 3696, -97, -4162, -8227, -12292, -16613, -20678, -24743,
    -28808, -28280, -32343, -20022, -24085, -12020, -16083, -3762, -7825, 4224, 161, 12482, 8419, 20484,
    16421, 28742, 24679, -31815, -27752, -23557, -19494, -15555, -11492, -7297, -3234, 689, 4752, 8947,
    13010, 16949, 21012, 25207, 29270, -18966, -23093, -27224, -31351, -2706, -6833, -10964, -15091, 13538,
    9411, 5280, 1153, 29798, 25671, 21540, 17413, -22565, -18438, -30823, -26696, -6305, -2178, -14563,
    -10436, 9939, 14066, 1681, 5808, 26199, 30326, 17941, 22068, -9908, -13971, -1778, -5841, -26168,
    -30231, -18038, -22101, 22596, 18533, 30726, 26663, 6336, 2273, 14466, 10403, -13443, -9380, -5313,
    -1250, -29703, -25640, -21573, -17510, 19061, 23124, 27191, 31254, 2801, 6864, 10931, 14994, -722,
    -4849, -8852, -12979, -16982, -21109, -25112, -29239, 31782, 27655, 23652, 19525, 15522, 11395, 7392,
    3265, -4321, -194, -12451, -8324, -20581, -16454, -28711, -24584, 28183, 32310, 20053, 24180, 11923,
    16050, 3793, 7920
]

ANC_MODES = {0: "off", 1: "anc", 2: "transparency"}
ANC_CODE_MAP = {"off": 0, "normal": 0, "anc": 1, "on": 1, "transparency": 2, "awareness": 2}
EQ_MAP = {"balanced": 0, "bass": 1, "vocal": 2}

def crc16(data: bytes) -> bytes:
    s = 0
    for byte in data:
        s = CRC16_TAB[((s >> 8) ^ byte) & 0xFF] ^ (s << 8)
        s = s & 0xFFFF
    return s.to_bytes(2, "big")

def build_packet(cmd: bytes, parameters=None) -> bytes:
    if parameters is None:
        parameters = []
    body = bytearray(cmd)
    for p_type, p_value in parameters:
        body.append(p_type)
        body.append(len(p_value))
        body.extend(p_value)
    header = bytearray(b"Z")
    header.extend((len(body) + 1).to_bytes(2, "big"))
    header.append(0x00)
    header.extend(body)
    header.extend(crc16(header))
    return bytes(header)

def parse_packets(data: bytes):
    packets = []
    i = 0
    while i < len(data):
        if data[i] != 0x5A:
            i += 1
            continue
        if i + 3 >= len(data):
            break
        length = int.from_bytes(data[i+1:i+3], "big")
        packet_end = i + length + 5
        if packet_end > len(data):
            break
        packet_data = data[i:packet_end]
        cmd_id = packet_data[4:6]
        pos = 6
        params = {}
        while pos < length + 3:
            if pos + 1 >= len(packet_data):
                break
            p_type = packet_data[pos]
            p_len = packet_data[pos + 1]
            if pos + 2 + p_len > len(packet_data):
                break
            p_val = packet_data[pos + 2:pos + 2 + p_len]
            params[p_type] = p_val
            pos += 2 + p_len
        packets.append((cmd_id, params))
        i = packet_end
    return packets

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
        self.exchange(build_packet(b"\x2b\x04", [(1, bytes([code]))]))
        return self.get_status()

    def cycle_anc(self):
        curr = self.get_status()
        next_code = (curr["noise_mode_code"] + 1) % 3
        self.exchange(build_packet(b"\x2b\x04", [(1, bytes([next_code]))]))
        return self.get_status()

    def set_eq(self, preset_str: str):
        code = EQ_MAP.get(preset_str.lower(), 0)
        self.exchange(build_packet(b"\x27\x01", [(1, bytes([code]))]))
        status = self.get_status()
        status["eq"] = preset_str
        return status

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
