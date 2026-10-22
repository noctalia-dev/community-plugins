#!/usr/bin/env python3
"""
Honor Choice Earbuds X5 / X5 Pro - Linux Control Tool
Supports ANC (Noise Cancellation / Off / Awareness), Battery Status, EQ Presets.
Uses Bluetooth RFCOMM Serial Port Profile (SPP).
"""

import sys
import socket
import argparse
import subprocess
import json
import re

# CRC16-XMODEM lookup table (polynomial 0x1021)
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

ANC_MODES = {
    0: {"id": "off", "name": "Обычный (Выкл)", "desc": "Шумоподавление выключено", "icon": "audio-volume-medium"},
    1: {"id": "anc", "name": "Шумоподавление", "desc": "Активное шумоподавление включено", "icon": "audio-headset"},
    2: {"id": "awareness", "name": "Прозрачность", "desc": "Режим звукопроницаемости", "icon": "audio-volume-high"}
}

ANC_NAME_MAP = {
    "off": 0, "normal": 0, "disable": 0, "0": 0,
    "anc": 1, "on": 1, "enable": 1, "1": 1,
    "awareness": 2, "transparency": 2, "ambient": 2, "2": 2
}

EQ_PRESETS = {
    0: "balanced",
    1: "bass",
    2: "vocal"
}

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
    
    # 0x5A + len(2B big) + 0x00 + body + crc16(2B)
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
        if data[i] != 0x5A:  # 'Z'
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

def find_honor_earbuds_mac() -> str:
    """Find connected Honor Choice Earbuds MAC address automatically."""
    try:
        out = subprocess.check_output(["bluetoothctl", "devices", "Connected"], text=True, stderr=subprocess.DEVNULL)
        for line in out.strip().splitlines():
            m = re.match(r"^Device\s+([0-9A-Fa-f:]{17})\s+(.+)$", line)
            if m:
                mac, name = m.group(1), m.group(2)
                if "honor choice" in name.lower() or "honor earbuds" in name.lower():
                    return mac
    except Exception:
        pass
    try:
        out = subprocess.check_output(["bluetoothctl", "devices"], text=True, stderr=subprocess.DEVNULL)
        for line in out.strip().splitlines():
            # Format: Device <MAC> <Name>
            m = re.match(r"^Device\s+([0-9A-Fa-f:]{17})\s+(.+)$", line)
            if m:
                mac, name = m.group(1), m.group(2)
                if "honor choice" in name.lower() or "honor earbuds" in name.lower():
                    return mac
    except Exception:
        pass
    # Fallback default known address if available
    return "10:28:74:10:D1:92"

def send_notification(summary: str, body: str, icon: str = "audio-headset"):
    """Send notification via Noctalia IPC if running, or notify-send."""
    try:
        # Check Noctalia first
        proc = subprocess.run(
            ["noctalia", "msg", "notification-show", summary, body],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=1.0
        )
        if proc.returncode == 0:
            return
    except Exception:
        pass

    try:
        # Fallback to notify-send
        subprocess.run(
            ["notify-send", "-a", "Honor Earbuds", "-i", icon, summary, body],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=1.0
        )
    except Exception:
        pass

class HonorEarbuds:
    def __init__(self, mac: str, channels=(18, 12)):
        self.mac = mac
        self.channels = channels
        self.sock = None
        self.active_channel = None

    def connect(self):
        for ch in self.channels:
            try:
                s = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_STREAM, socket.BTPROTO_RFCOMM)
                s.settimeout(2.0)
                s.connect((self.mac, ch))
                self.sock = s
                self.active_channel = ch
                return True
            except Exception:
                if s:
                    s.close()
                continue
        return False

    def close(self):
        if self.sock:
            try:
                self.sock.close()
            except Exception:
                pass
            self.sock = None

    def exchange(self, cmd_pkt: bytes, wait_cmd: bytes = None) -> list:
        if not self.sock:
            if not self.connect():
                raise ConnectionError(f"Не удалось подключиться к наушникам ({self.mac}). Убедитесь, что они подключены по Bluetooth.")
        
        self.sock.sendall(cmd_pkt)
        received_packets = []
        start_time = socket.getdefaulttimeout() or 2.0
        
        while True:
            try:
                chunk = self.sock.recv(1024)
                if not chunk:
                    break
                packets = parse_packets(chunk)
                received_packets.extend(packets)
                if wait_cmd:
                    if any(c == wait_cmd for c, _ in packets):
                        break
                else:
                    if len(packets) > 0:
                        break
            except socket.timeout:
                break
            except Exception:
                break
        return received_packets

    def get_anc_mode(self) -> int:
        """Returns 0 (Off), 1 (ANC), 2 (Awareness)."""
        packets = self.exchange(build_packet(b"\x2b\x2a"), wait_cmd=b"\x2b\x2a")
        for cmd_id, params in packets:
            if cmd_id == b"\x2b\x2a" and 1 in params:
                val = params[1]
                if len(val) >= 1:
                    # In query response, mode is the last byte of param 1
                    return val[-1]
        raise RuntimeError("Не удалось получить текущий режим ANC от наушников.")

    def set_anc_mode(self, mode: int):
        """Sets ANC mode: 0 (Off), 1 (ANC), 2 (Awareness)."""
        if mode not in (0, 1, 2):
            raise ValueError(f"Неверный режим ANC: {mode}")
        pkt = build_packet(b"\x2b\x04", [(1, bytes([mode]))])
        self.exchange(pkt)
        return mode

    def cycle_anc_mode(self) -> int:
        """Cycles Off (0) -> ANC (1) -> Awareness (2) -> Off (0)."""
        current = self.get_anc_mode()
        next_mode = (current + 1) % 3
        self.set_anc_mode(next_mode)
        return next_mode

    def toggle_anc_mode(self) -> int:
        """Toggles Off (0) <-> ANC (1)."""
        current = self.get_anc_mode()
        next_mode = 0 if current == 1 else 1
        self.set_anc_mode(next_mode)
        return next_mode

    def get_battery(self) -> dict:
        """Queries battery levels of Left, Right earbuds and Case."""
        packets = self.exchange(build_packet(b"\x01\x08"), wait_cmd=b"\x01\x08")
        result = {"left": None, "right": None, "case": None, "left_charging": None, "right_charging": None, "case_charging": None}
        for cmd_id, params in packets:
            if cmd_id == b"\x01\x08":
                if 2 in params and len(params[2]) >= 3:
                    result["left"] = params[2][0]
                    result["right"] = params[2][1]
                    result["case"] = params[2][2]
                if 3 in params and len(params[3]) >= 3:
                    result["left_charging"] = params[3][0] == 1
                    result["right_charging"] = params[3][1] == 1
                    result["case_charging"] = params[3][2] == 1
                return result
        return result

    def set_eq_preset(self, preset: int):
        """Sets EQ preset (0: Balanced, 1: Bass Boost, 2: Vocal)."""
        pkt = build_packet(b"\x27\x01", [(1, bytes([preset]))])
        self.exchange(pkt)
        return preset

def main():
    parser = argparse.ArgumentParser(
        description="Управление шумоподавлением и параметрами Honor Choice Earbuds X5 / X5 Pro на Linux",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Примеры использования:
  honor-anc cycle              # Переключить режим по кругу (Выкл -> Шумоподавление -> Прозрачность)
  honor-anc cycle --notify     # Переключить с показом всплывающего уведомления
  honor-anc set anc            # Включить шумоподавление (anc / on)
  honor-anc set off            # Выключить шумоподавление (off)
  honor-anc set awareness      # Включить режим прозрачности (awareness)
  honor-anc toggle             # Переключить между Выкл и ANC
  honor-anc get                # Показать текущий режим
  honor-anc battery            # Показать заряд наушников и кейса
  honor-anc status --json      # Вывести статус в формате JSON (для Waybar/панелей)
"""
    )
    
    parser.add_argument("command", nargs="?", default="status",
                        choices=["status", "get", "set", "cycle", "toggle", "battery", "eq"],
                        help="Команда управления (по умолчанию: status)")
    parser.add_argument("arg", nargs="?", default=None,
                        help="Аргумент команды (для set: off|anc|awareness; для eq: balanced|bass|vocal)")
    parser.add_argument("--mac", "-m", default=None,
                        help="MAC-адрес наушников (по умолчанию определяется автоматически)")
    parser.add_argument("--notify", "-n", action="store_true",
                        help="Отправлять всплывающее системное уведомление")
    parser.add_argument("--json", "-j", action="store_true",
                        help="Вывод результата в формате JSON")
    parser.add_argument("--quiet", "-q", action="store_true",
                        help="Минимальный вывод")

    args = parser.parse_args()

    mac = args.mac or find_honor_earbuds_mac()
    if not mac:
        err = "Наушники HONOR CHOICE Earbuds не найдены. Подключите их по Bluetooth."
        if args.notify:
            send_notification("Honor Earbuds", err, icon="dialog-error")
        if args.json:
            print(json.dumps({"connected": False, "error": err}, ensure_ascii=False))
        else:
            print(f"Ошибка: {err}", file=sys.stderr)
        sys.exit(1)

    device = HonorEarbuds(mac)
    try:
        if args.command in ("get", "status"):
            anc_code = device.get_anc_mode()
            anc_info = ANC_MODES.get(anc_code, {"id": "unknown", "name": f"Режим {anc_code}", "desc": ""})
            bat = device.get_battery()

            if args.json:
                print(json.dumps({
                    "connected": True,
                    "mac": mac,
                    "anc_mode": anc_info["id"],
                    "anc_code": anc_code,
                    "anc_name": anc_info["name"],
                    "battery": bat
                }, ensure_ascii=False))
            elif args.quiet:
                print(anc_info["id"])
            else:
                print(f"Подключено: HONOR CHOICE Earbuds X5 ({mac})")
                print(f"Режим ANC: {anc_info['name']} ({anc_info['desc']})")
                if bat.get("left") is not None:
                    print(f"Заряд: Левый: {bat['left']}% | Правый: {bat['right']}% | Кейс: {bat['case']}%")

        elif args.command == "set":
            if not args.arg:
                print("Укажите режим: off, anc (on), awareness", file=sys.stderr)
                sys.exit(1)
            mode_key = args.arg.lower()
            if mode_key not in ANC_NAME_MAP:
                print(f"Неизвестный режим: {args.arg}. Доступны: off, anc, awareness", file=sys.stderr)
                sys.exit(1)
            target_code = ANC_NAME_MAP[mode_key]
            device.set_anc_mode(target_code)
            anc_info = ANC_MODES[target_code]

            if args.notify:
                send_notification("Honor Earbuds - ANC", f"Режим: {anc_info['name']}", icon=anc_info["icon"])
            if args.json:
                print(json.dumps({"anc_mode": anc_info["id"], "anc_code": target_code, "anc_name": anc_info["name"]}, ensure_ascii=False))
            elif not args.quiet:
                print(f"Режим переключен: {anc_info['name']}")

        elif args.command == "cycle":
            new_code = device.cycle_anc_mode()
            anc_info = ANC_MODES[new_code]
            if args.notify:
                send_notification("Honor Earbuds - ANC", f"Режим: {anc_info['name']}", icon=anc_info["icon"])
            if args.json:
                print(json.dumps({"anc_mode": anc_info["id"], "anc_code": new_code, "anc_name": anc_info["name"]}, ensure_ascii=False))
            elif not args.quiet:
                print(f"Режим переключен: {anc_info['name']}")

        elif args.command == "toggle":
            new_code = device.toggle_anc_mode()
            anc_info = ANC_MODES[new_code]
            if args.notify:
                send_notification("Honor Earbuds - ANC", f"Режим: {anc_info['name']}", icon=anc_info["icon"])
            if args.json:
                print(json.dumps({"anc_mode": anc_info["id"], "anc_code": new_code, "anc_name": anc_info["name"]}, ensure_ascii=False))
            elif not args.quiet:
                print(f"Режим переключен: {anc_info['name']}")

        elif args.command == "battery":
            bat = device.get_battery()
            if args.json:
                print(json.dumps(bat, ensure_ascii=False))
            else:
                left = f"{bat['left']}%" if bat.get('left') is not None else "Н/Д"
                right = f"{bat['right']}%" if bat.get('right') is not None else "Н/Д"
                case = f"{bat['case']}%" if bat.get('case') is not None else "Н/Д"
                print(f"Левый наушник:  {left}")
                print(f"Правый наушник: {right}")
                print(f"Кейс:           {case}")
            if args.notify:
                msg = f"L: {bat.get('left', '?')}% | R: {bat.get('right', '?')}% | Case: {bat.get('case', '?')}%"
                send_notification("Honor Earbuds - Заряд", msg, icon="battery")

        elif args.command == "eq":
            eq_map = {"balanced": 0, "bass": 1, "vocal": 2, "0": 0, "1": 1, "2": 2}
            if not args.arg or args.arg.lower() not in eq_map:
                print("Укажите пресет эквалайзера: balanced, bass, vocal", file=sys.stderr)
                sys.exit(1)
            preset_code = eq_map[args.arg.lower()]
            device.set_eq_preset(preset_code)
            preset_name = EQ_PRESETS[preset_code]
            if args.notify:
                send_notification("Honor Earbuds - EQ", f"Эквалайзер: {preset_name.capitalize()}", icon="audio-speakers")
            if not args.quiet:
                print(f"Пресет эквалайзера установлен: {preset_name}")

    except ConnectionError as e:
        if args.notify:
            send_notification("Honor Earbuds", str(e), icon="dialog-warning")
        if args.json:
            print(json.dumps({"connected": False, "error": str(e)}, ensure_ascii=False))
        else:
            print(f"Ошибка подключения: {e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        if args.notify:
            send_notification("Honor Earbuds", f"Ошибка: {e}", icon="dialog-error")
        if args.json:
            print(json.dumps({"connected": False, "error": str(e)}, ensure_ascii=False))
        else:
            print(f"Ошибка: {e}", file=sys.stderr)
        sys.exit(1)
    finally:
        device.close()

if __name__ == "__main__":
    main()
