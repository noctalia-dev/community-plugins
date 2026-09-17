#!/usr/bin/env python3
"""
OPPO / OnePlus / realme Earbuds Controller
Reverse-engineered Bluetooth RFCOMM protocol for Linux / Noctalia
Author: osp54
"""

import sys
import os
import json
import time
import socket
import argparse
import subprocess
import shutil
import urllib.request
import hmac
import hashlib
import uuid
import zipfile
import io
import threading

CACHE_DIR = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
STATE_FILE = os.path.join(CACHE_DIR, "oppo_pods_state.json")
CHANNEL_FILE = os.path.join(CACHE_DIR, "oppo_pods_channel.txt")

MEDIA_CACHE_DIR = os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "noctalia", "oppo-pods")
SECRET_HEYMELODY = "&*%earphone-OP6r888s**%$"
RENDER_DOWNLOADS = set()

# Noise modes
MODE_OFF = "off"
MODE_ANC = "anc"
MODE_TRANSPARENCY = "transparency"

CYCLE_MODES = [MODE_ANC, MODE_TRANSPARENCY, MODE_OFF]

# Product ID to model map (sample of most popular)
MODEL_NAMES = {
    "067C10": "OPPO Enco Air4 Pro",
    "069010": "OPPO Enco Air4",
    "064C10": "OPPO Enco Air3",
    "065C10": "OPPO Enco Air3 Pro",
    "063410": "OPPO Enco Air2",
    "063810": "OPPO Enco Air2 Pro",
    "066010": "OPPO Enco Free3",
    "068C10": "OPPO Enco Free4",
    "06C010": "OPPO Enco Free4 Dynaudio",
    "068010": "OPPO Enco Buds2 Pro",
    "06A450": "OPPO Enco Buds3",
    "046410": "OnePlus Buds Pro 2",
    "046810": "OnePlus Buds Pro 3",
    "045010": "OnePlus Buds 3",
    "045410": "OnePlus Buds Pro",
    "044810": "OnePlus Buds Z2",
    "055010": "realme Buds Air 5 Pro",
    "056010": "realme Buds Air 6 Pro",
    "054410": "realme Buds T300",
    "054810": "realme Buds T310",
}

def make_frame(command, seq=0x01, payload=b""):
    total_len = len(payload) + 7
    res = bytearray([
        0xAA,
        total_len & 0xFF,
        0x00, 0x00,
        command & 0xFF, (command >> 8) & 0xFF,
        seq & 0xFF,
        len(payload) & 0xFF, (len(payload) >> 8) & 0xFF
    ])
    res.extend(payload)
    return bytes(res)

def parse_frames(data):
    frames = []
    i = 0
    while i < len(data):
        if data[i] == 0xAA and i + 8 < len(data):
            tot_len = data[i+1]
            cmd = data[i+4] | (data[i+5] << 8)
            seq = data[i+6]
            pay_len = data[i+7] | (data[i+8] << 8)
            end = i + 9 + pay_len
            if end <= len(data):
                payload = data[i+9:end]
                frames.append((cmd, seq, payload))
                i = end
                continue
        i += 1
    return frames

def find_connected_device():
    """Find connected OPPO/OnePlus/realme device MAC via bluetoothctl or DBus"""
    try:
        out = subprocess.check_output(["bluetoothctl", "devices", "Connected"], text=True, stderr=subprocess.DEVNULL)
        lines = [line.strip() for line in out.strip().split("\n") if line.strip()]
        for line in lines:
            parts = line.split(" ", 2)
            if len(parts) >= 3:
                mac = parts[1]
                name = parts[2]
                name_lower = name.lower()
                if any(k in name_lower for k in ("oppo", "enco", "oneplus", "buds", "realme", "dizo")):
                    return mac, name
        # If no specific name matched, check info on all connected devices
        for line in lines:
            parts = line.split(" ", 2)
            if len(parts) >= 2:
                mac = parts[1]
                info = subprocess.check_output(["bluetoothctl", "info", mac], text=True, stderr=subprocess.DEVNULL)
                if UUID_OPPO_SPP in info.lower() or "0000079a" in info.lower():
                    return mac, parts[2] if len(parts) >= 3 else "OPPO Pods"
    except Exception:
        pass
    return None, None

def get_cached_channel():
    if os.path.exists(CHANNEL_FILE):
        try:
            with open(CHANNEL_FILE, "r") as f:
                ch = int(f.read().strip())
                if 1 <= ch <= 30:
                    return ch
        except Exception:
            pass
    return 12  # Default on most OPPO Enco Air4 / Air3

def connect_rfcomm(mac, timeout=1.5):
    # HeyMelody SPP protocol is exclusively on RFCOMM channel 12 (or 13 fallback on older models)
    channels = [12, 13]
    for ch in channels:
        s = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_STREAM, socket.BTPROTO_RFCOMM)
        s.settimeout(timeout)
        try:
            s.connect((mac, ch))
            return s, ch
        except Exception:
            s.close()
    return None, None

def _download_render_worker(product_id, out_file):
    # Try list_theme first (contains high-res popup normal/dark 3D renders).
    # Products may use different colour indexes, so try all supported values.
    for region in ["eu", "sg"]:
      for colour in ["2", "1", "0"]:
        try:
            url = f"https://iot-earbuds-{region}.allawnos.com/v1/earphone/personalize/list_theme"
            payload = {
                "platform": "android",
                "channel": "1",
                "versionCode": "116009000",
                "productId": product_id,
                "color": colour
            }
            body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
            sig = hmac.new(SECRET_HEYMELODY.encode("utf-8"), body, hashlib.sha1).hexdigest()
            headers = {
                "Content-Type": "application/json",
                "appid": "earphone",
                "ts": str(int(time.time() * 1000)),
                "nonce": str(uuid.uuid4()),
                "sv": "v1",
                "sign": sig,
                "User-Agent": "okhttp/4.12.0"
            }
            req = urllib.request.Request(url, data=body, headers=headers)
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                items = data.get("data") or []
                if items:
                    anim_url = items[0].get("animUrl") or items[0].get("darkAnimUrl")
                    if anim_url:
                        with urllib.request.urlopen(anim_url, timeout=10) as zresp:
                            with zipfile.ZipFile(io.BytesIO(zresp.read())) as z:
                                for f in ["res/image/disconnected.png", "res/image/pairing.png", "res/image/connected_box.png"]:
                                    if f in z.namelist():
                                        tmp_out = out_file + ".tmp"
                                        with open(tmp_out, "wb") as f_out:
                                            f_out.write(z.read(f))
                                        os.replace(tmp_out, out_file)
                                        return
        except Exception:
            pass

    # Fallback to firmwareCoverImage
    for region in ["eu", "sg"]:
        try:
            url2 = f"https://iot-earbuds-{region}.allawnos.com/v1/earphone/firmwareCoverImage"
            payload2 = {
                "platform": "android",
                "channel": "1",
                "versionCode": "116009000",
                "productId": product_id
            }
            body2 = json.dumps(payload2, separators=(",", ":")).encode("utf-8")
            sig2 = hmac.new(SECRET_HEYMELODY.encode("utf-8"), body2, hashlib.sha1).hexdigest()
            headers2 = {
                "Content-Type": "application/json",
                "appid": "earphone",
                "ts": str(int(time.time() * 1000)),
                "nonce": str(uuid.uuid4()),
                "sv": "v1",
                "sign": sig2,
                "User-Agent": "okhttp/4.12.0"
            }
            req2 = urllib.request.Request(url2, data=body2, headers=headers2)
            with urllib.request.urlopen(req2, timeout=5) as resp2:
                data2 = json.loads(resp2.read().decode("utf-8"))
                items2 = data2.get("data") or []
                if items2:
                    img_url = items2[0].get("listCoverImage")
                    if img_url:
                        with urllib.request.urlopen(img_url, timeout=10) as iresp:
                            tmp_out = out_file + ".tmp"
                            with open(tmp_out, "wb") as f_out:
                                f_out.write(iresp.read())
                            os.replace(tmp_out, out_file)
                            return
        except Exception:
            pass

def ensure_device_image(product_id):
    """Return a cached official 3D render and fetch it once in the background if missing."""
    if not product_id:
        return None
    try:
        os.makedirs(MEDIA_CACHE_DIR, exist_ok=True)
        out_file = os.path.join(MEDIA_CACHE_DIR, f"{product_id}.png")
        if os.path.exists(out_file) and os.path.getsize(out_file) > 1000:
            return out_file
        # Do not start a new network request on every poll while the first is running.
        if product_id not in RENDER_DOWNLOADS:
            RENDER_DOWNLOADS.add(product_id)
            t = threading.Thread(target=_download_render_worker, args=(product_id, out_file), daemon=True)
            t.start()
    except Exception:
        pass
    return None

def query_device(mac, device_name=None):
    prev_cache = {}
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, "r") as f:
                prev_cache = json.load(f)
        except Exception:
            pass

    s, ch = connect_rfcomm(mac)
    if not s:
        # If RFCOMM socket is temporarily busy, return last-known good cached state
        if prev_cache and prev_cache.get("connected"):
            prev_cache["timestamp"] = int(time.time())
            return prev_cache
        return {"connected": False, "error": "Could not connect to RFCOMM socket"}

    state = {
        "connected": True,
        "mac": mac,
        "device_name": device_name or prev_cache.get("device_name") or "OPPO Earbuds",
        "model_name": device_name or prev_cache.get("model_name") or "OPPO Earbuds",
        "product_id": prev_cache.get("product_id"),
        "noise_mode": prev_cache.get("noise_mode", "unknown"),
        "noise_mode_name": prev_cache.get("noise_mode_name", "Неизвестно"),
        "battery_left": prev_cache.get("battery_left", -1),
        "battery_right": prev_cache.get("battery_right", -1),
        "battery_case": prev_cache.get("battery_case", -1),
        "case_offline": prev_cache.get("case_offline", False),
        "charging_left": prev_cache.get("charging_left", False),
        "charging_right": prev_cache.get("charging_right", False),
        "charging_case": prev_cache.get("charging_case", False),
        "has_anc": True,
        "dual_device": False,
        "game_mode": False,
        "timestamp": int(time.time()),
        "device_image": prev_cache.get("device_image")
    }

    try:
        # Handshake
        s.sendall(make_frame(0x0100, seq=1))
        time.sleep(0.04)

        # Product ID
        s.sendall(make_frame(0x0103, seq=2))
        time.sleep(0.04)

        # Battery
        s.sendall(make_frame(0x0106, seq=3))
        time.sleep(0.04)

        # ANC mode
        s.sendall(make_frame(0x010C, seq=4, payload=bytes([0x01, 0x01])))
        time.sleep(0.04)

        # Read responses
        raw = bytearray()
        s.settimeout(0.6)
        while True:
            try:
                chunk = s.recv(1024)
                if not chunk:
                    break
                raw.extend(chunk)
            except socket.timeout:
                break

        frames = parse_frames(raw)
        for cmd, seq, payload in frames:
            # Product ID (0x8103)
            if cmd == 0x8103 and len(payload) >= 4 and payload[0] == 0:
                pid = f"{payload[3]:02X}{payload[2]:02X}{payload[1]:02X}"
                state["product_id"] = pid
                if pid in MODEL_NAMES:
                    state["model_name"] = MODEL_NAMES[pid]

            # Battery (0x8106 or 0x0204 active report)
            if cmd in (0x8106, 0x0204):
                p = list(payload)
                if len(p) >= 4 and p[0] in (0x00, 0x01):
                    count = p[1]
                    items = p[2:2 + count * 2]
                    for k in range(0, len(items), 2):
                        dev_id = items[k]
                        val = items[k+1]
                        level = val & 0x7F
                        charging = bool(val & 0x80)
                        if dev_id == 1:
                            state["battery_left"] = level
                            state["charging_left"] = charging
                        elif dev_id == 2:
                            state["battery_right"] = level
                            state["charging_right"] = charging
                        elif dev_id == 3:
                            if level > 0 or charging:
                                state["battery_case"] = level
                                state["charging_case"] = charging
                                state["case_offline"] = False
                            else:
                                # When earbuds are in ears and case is closed, earbuds report level 0.
                                # Preserve last-known positive battery if available, otherwise mark unknown (-1).
                                state["case_offline"] = True
                                cached_case = prev_cache.get("battery_case", -1)
                                if cached_case > 0:
                                    state["battery_case"] = cached_case
                                    state["charging_case"] = False
                                else:
                                    state["battery_case"] = -1

            # ANC mode (0x810C or 0x0204 active report)
            if cmd in (0x810C, 0x0204):
                p = list(payload)
                for idx in range(len(p) - 2):
                    if p[idx] == 0x01 and p[idx+1] == 0x01:
                        mode_val = p[idx+2]
                        high_val = p[idx+3] if idx + 3 < len(p) else 0
                        if mode_val in (0x02, 0x10, 0x20, 0x40, 0x80):
                            state["noise_mode"] = MODE_ANC
                            state["noise_mode_name"] = "Шумоподавление"
                        elif mode_val == 0x04 or (mode_val == 0x00 and high_val == 0x01):
                            state["noise_mode"] = MODE_TRANSPARENCY
                            state["noise_mode_name"] = "Прозрачность"
                        elif mode_val in (0x01, 0x08):
                            state["noise_mode"] = MODE_OFF
                            state["noise_mode_name"] = "Выключено"

        # Resolve or fetch official 3D render. Keep the previous path while a
        # first download is still running so the image never disappears.
        image_path = ensure_device_image(state.get("product_id"))
        state["device_image"] = image_path or prev_cache.get("device_image")

        # Save to cache
        try:
            with open(STATE_FILE, "w") as f:
                json.dump(state, f, indent=2, ensure_ascii=False)
        except Exception:
            pass

        return state
    finally:
        s.close()

def set_anc_mode(mac, target_mode):
    target_mode = target_mode.lower()
    if target_mode not in (MODE_ANC, MODE_TRANSPARENCY, MODE_OFF):
        return {"success": False, "error": f"Invalid mode: {target_mode}"}

    s, ch = connect_rfcomm(mac)
    if not s:
        return {"success": False, "error": "Could not connect to RFCOMM"}

    try:
        s.sendall(make_frame(0x0100, seq=1))
        time.sleep(0.04)

        # Mode payloads:
        # Off: [0x01, 0x01, 0x01]
        # ANC: [0x01, 0x01, 0x02]
        # Transparency: [0x01, 0x01, 0x04]
        if target_mode == MODE_ANC:
            payload = bytes([0x01, 0x01, 0x02])
            mode_name = "Шумоподавление"
        elif target_mode == MODE_TRANSPARENCY:
            payload = bytes([0x01, 0x01, 0x04])
            mode_name = "Прозрачность"
        else:
            payload = bytes([0x01, 0x01, 0x01])
            mode_name = "Выключено"

        cmd_frame = make_frame(0x0404, seq=0xF0, payload=payload)
        s.sendall(cmd_frame)
        time.sleep(0.12)

        # Update cache if file exists
        if os.path.exists(STATE_FILE):
            try:
                with open(STATE_FILE, "r") as f:
                    data = json.load(f)
                data["noise_mode"] = target_mode
                data["noise_mode_name"] = mode_name
                data["timestamp"] = int(time.time())
                with open(STATE_FILE, "w") as f:
                    json.dump(data, f, indent=2, ensure_ascii=False)
            except Exception:
                pass

        return {"success": True, "mode": target_mode, "mode_name": mode_name}
    finally:
        s.close()

def cycle_anc(mac):
    current = MODE_OFF
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, "r") as f:
                data = json.load(f)
            current = data.get("noise_mode", MODE_OFF)
        except Exception:
            pass

    try:
        idx = CYCLE_MODES.index(current)
        next_mode = CYCLE_MODES[(idx + 1) % len(CYCLE_MODES)]
    except ValueError:
        next_mode = MODE_ANC

    res = set_anc_mode(mac, next_mode)
    if res.get("success"):
        # Show desktop notification if notify-send exists
        if shutil.which("notify-send"):
            icon = "audio-headphones"
            subprocess.run([
                "notify-send",
                "OPPO Pods",
                f"Режим: {res['mode_name']}",
                "-i", icon,
                "-t", "1200",
                "-h", "string:x-canonical-private-synchronous:oppo-anc"
            ], check=False)
    return res

def read_cache():
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, "r") as f:
                return json.load(f)
        except Exception:
            pass
    return {"connected": False}

def main():
    parser = argparse.ArgumentParser(description="OPPO / OnePlus / realme Earbuds CLI")
    parser.add_argument("command", choices=["status", "cached", "set-anc", "cycle-anc"], help="Action to perform")
    parser.add_argument("value", nargs="?", help="Value for set-anc (anc/transparency/off)")
    parser.add_argument("--mac", help="Earbuds Bluetooth MAC address")

    args = parser.parse_args()

    mac = args.mac
    device_name = None
    if not mac:
        mac = os.environ.get("OPPO_MAC")
    if not mac:
        mac, device_name = find_connected_device()

    if args.command == "cached":
        print(json.dumps(read_cache(), ensure_ascii=False))
        return

    if not mac:
        res = {"connected": False, "error": "No OPPO/OnePlus/realme device connected"}
        print(json.dumps(res, ensure_ascii=False))
        return

    if args.command == "status":
        state = query_device(mac, device_name)
        print(json.dumps(state, ensure_ascii=False))
    elif args.command == "set-anc":
        if not args.value:
            print(json.dumps({"success": False, "error": "Missing mode for set-anc"}))
            sys.exit(1)
        res = set_anc_mode(mac, args.value)
        print(json.dumps(res, ensure_ascii=False))
    elif args.command == "cycle-anc":
        res = cycle_anc(mac)
        print(json.dumps(res, ensure_ascii=False))

if __name__ == "__main__":
    main()
