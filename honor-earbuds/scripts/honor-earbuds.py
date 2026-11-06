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
import time

from honor_protocol import build_packet, parse_packets

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
