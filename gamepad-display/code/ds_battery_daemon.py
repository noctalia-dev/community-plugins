#!/usr/bin/env python3
"""
DualSense / DualSense Edge battery and status daemon for the Noctalia plugin.

Combines direct HID report reading (USB report 0x01, Bluetooth report 0x31),
Linux kernel hid-playstation power_supply / BlueZ Battery1 fallbacks, and live
integration with the ds4u daemon ($XDG_RUNTIME_DIR/ds4u.socket) and ds4u
profile configuration (~/.config/ds4u/).

Modes:
  (default)             keep the state file fresh
  --stream              also print one compact JSON object per line (used by battery.luau)
  --buzz                rumble the controller (via ds4u IPC or direct HID output report)
  --switch-profile P    switch the active ds4u profile to P
  --cycle-profile       cycle to the next saved ds4u profile

Only the Python 3 standard library is needed.
"""
import binascii
import fcntl
import glob
import json
import os
import select
import signal
import socket
import struct
import subprocess
import sys
import time
from datetime import datetime

DS_VID = 0x054C
DS_PID = 0x0CE6
DSE_PID = 0x0DF2
DS4_PID = 0x05C4
DS4_V2_PID = 0x09CC
DS_PIDS = (DS_PID, DSE_PID)
DS4_PIDS = (DS4_PID, DS4_V2_PID)
SONY_PIDS = DS_PIDS + DS4_PIDS


def model_for_pid(pid):
    """Map a Sony product id to the model name the card understands."""
    if pid == DSE_PID:
        return "edge"
    if pid in DS4_PIDS:
        return "ds4"
    if pid == DS_PID:
        return "dualsense"
    return ""

HIDIOCGRAWINFO = 0x80084803

DS_INPUT_REPORT_USB = 0x01
DS_INPUT_REPORT_USB_SIZE = 64
DS_INPUT_REPORT_BT = 0x31
DS_INPUT_REPORT_BT_SIZE = 78
DS_INPUT_REPORT_BT_MIN = 0x01

DS_OUTPUT_REPORT_USB = 0x02
DS_OUTPUT_REPORT_BT = 0x31
DS_OUTPUT_REPORT_BT_SIZE = 78
DS_OUTPUT_TAG = 0x10
OUTPUT_CRC32_SEED = 0xA2

DS_STATUS_BATTERY_CAPACITY = 0x0F
DS_STATUS_CHARGING = 0xF0
DS_STATUS_CHARGING_SHIFT = 4

SILENCE_DISCONNECT = 3.0  # s without reports -> rescan
WRITE_INTERVAL = 5.0      # s between state heartbeats

RUNTIME_DIR = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
try:
    os.makedirs(RUNTIME_DIR, exist_ok=True)
except OSError:
    RUNTIME_DIR = "/tmp"

STATE_FILE = os.path.join(RUNTIME_DIR, "noctalia-dualsense-battery.json")
LOCK_FILE = os.path.join(RUNTIME_DIR, "noctalia-dualsense-battery.lock")
DS4U_SOCKET = os.path.join(RUNTIME_DIR, "ds4u.socket")
CONFIG_HOME = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
DS4U_CONFIG_DIR = os.path.join(CONFIG_HOME, "ds4u")
DAEMON_VERSION = "1.2.0"

PLAYER_LED_PATTERNS = (
    0b00000,
    0b00100,
    0b01010,
    0b10101,
    0b11011,
    0b11111,
    0b10001,
    0b01110,
)

BUZZ_PATTERN = [
    (110, 0.08),
    (200, 0.12),
    (255, 0.35),
    (160, 0.12),
    (80, 0.12),
]


def single_instance():
    """Take a per-user lock; exit quietly when another daemon is already up."""
    fd = os.open(LOCK_FILE, os.O_RDWR | os.O_CREAT, 0o600)
    deadline = time.time() + 2.0
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError:
            if time.time() >= deadline:
                os.close(fd)
                sys.exit(0)
            time.sleep(0.05)
    os.ftruncate(fd, 0)
    os.write(fd, str(os.getpid()).encode())
    return fd


def release_lock(fd):
    try:
        os.ftruncate(fd, 0)
    except OSError:
        pass
    os.close(fd)


def rgb_to_hex(r, g, b):
    r_i = max(0, min(255, int(round(r))))
    g_i = max(0, min(255, int(round(g))))
    b_i = max(0, min(255, int(round(b))))
    return f"#{r_i:02x}{g_i:02x}{b_i:02x}"


def sanitize_profile_filename(name):
    return "".join(c if (c.isalnum() or c in "-_") else "_" for c in name)


def read_ds4u_config(override_profile=None):
    """Read active profile and settings from ~/.config/ds4u/."""
    profile_name = override_profile or ""
    settings_path = os.path.join(DS4U_CONFIG_DIR, "settings.json")
    if not profile_name:
        try:
            with open(settings_path) as f:
                data = json.load(f)
            profile_name = str(data.get("profile") or "").strip()
        except (OSError, ValueError, TypeError):
            pass
    if not profile_name:
        profile_name = "Default"

    profiles_dir = os.path.join(DS4U_CONFIG_DIR, "profiles")
    profiles = []
    if os.path.isdir(profiles_dir):
        for entry in sorted(os.listdir(profiles_dir)):
            if entry.endswith(".json"):
                p_path = os.path.join(profiles_dir, entry)
                try:
                    with open(p_path) as f:
                        pdata = json.load(f)
                    pname = str(pdata.get("name") or entry[:-5]).strip()
                    if pname and pname not in profiles:
                        profiles.append(pname)
                except (OSError, ValueError, TypeError):
                    pass

    profile_file = os.path.join(
        profiles_dir, f"{sanitize_profile_filename(profile_name)}.json"
    )
    lightbar_color = "#0080ff"
    player_leds = 1
    mic_muted = True

    if os.path.isfile(profile_file):
        try:
            with open(profile_file) as f:
                p = json.load(f)
            # ds4u first converts profile RGB (0..1) to bytes, then scales each
            # channel by lightbar_brightness (0..255) before sending it.
            # Mirror the bytes seen by the physical controller, not merely the
            # unscaled colour selected in the profile editor.
            brightness = max(
                0, min(255, int(float(p.get("lightbar_brightness", 255.0))))
            )
            r = (
                max(0, min(255, int(float(p.get("lightbar_r", 0.0)) * 255.0)))
                * brightness
            ) // 255
            g = (
                max(0, min(255, int(float(p.get("lightbar_g", 0.5)) * 255.0)))
                * brightness
            ) // 255
            b = (
                max(0, min(255, int(float(p.get("lightbar_b", 1.0)) * 255.0)))
                * brightness
            ) // 255
            lightbar_color = rgb_to_hex(r, g, b)
            player_leds = max(0, min(7, int(p.get("player_leds", 1))))
            mic_muted = not bool(p.get("mic_enabled", False))
            if not profiles and p.get("name"):
                profiles = [str(p["name"])]
        except (OSError, ValueError, TypeError):
            pass

    if not profiles:
        profiles = [profile_name]

    return {
        "profile": profile_name,
        "profiles": profiles,
        "lightbar_color": lightbar_color,
        "player_leds": player_leds,
        "mic_muted": mic_muted,
    }


def ds4u_ipc_request(cmd_obj, timeout=0.6):
    """Send one command to $XDG_RUNTIME_DIR/ds4u.socket and return parsed JSON."""
    if not os.path.exists(DS4U_SOCKET):
        return None
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect(DS4U_SOCKET)
        line = json.dumps(cmd_obj, separators=(",", ":")) + "\n"
        sock.sendall(line.encode("utf-8"))
        buf = b""
        while b"\n" not in buf:
            chunk = sock.recv(4096)
            if not chunk:
                break
            buf += chunk
        if not buf:
            return None
        return json.loads(buf.decode("utf-8", errors="replace").splitlines()[0])
    except (OSError, ValueError, TypeError):
        return None
    finally:
        try:
            sock.close()
        except OSError:
            pass


def query_ds4u_daemon():
    """Query the running ds4u daemon if its socket is active."""
    ping = ds4u_ipc_request({"cmd": "Ping"}, timeout=0.4)
    if not isinstance(ping, dict) or ping.get("type") != "Pong":
        return None

    info_resp = ds4u_ipc_request({"cmd": "GetControllerInfo"}, timeout=0.5)
    prof_resp = ds4u_ipc_request({"cmd": "GetActiveProfile"}, timeout=0.5)
    list_resp = ds4u_ipc_request({"cmd": "ListProfiles"}, timeout=0.5)

    active_profile = ""
    if isinstance(prof_resp, dict) and prof_resp.get("type") == "ActiveProfile":
        active_profile = str((prof_resp.get("data") or {}).get("name") or "")

    cfg = read_ds4u_config(active_profile or None)
    if isinstance(list_resp, dict) and list_resp.get("type") == "ProfileList":
        plist = (list_resp.get("data") or {}).get("profiles")
        if isinstance(plist, list) and plist:
            cfg["profiles"] = [str(x) for x in plist]

    if not isinstance(info_resp, dict) or info_resp.get("type") != "ControllerInfo":
        return {
            "ds4u_daemon": True,
            "connected": False,
            **cfg,
        }

    cdata = info_resp.get("data") or {}
    pid = int(cdata.get("product_id", DS_PID))
    is_bt = bool(cdata.get("is_bt", False))
    serial = str(cdata.get("serial") or "")

    # ds4u may retain a stale HidDevice after unplugging; GetControllerInfo can
    # then keep returning the old serial even though its fd points at a deleted
    # hidraw node. Trust current sysfs presence for connect/disconnect state.
    present_conn, present_serial, present_pid = find_present_controller()
    if present_pid not in SONY_PIDS:
        return {
            "ds4u_daemon": True,
            "connected": False,
            **cfg,
        }
    pid = present_pid
    is_bt = present_conn == "bluetooth"
    serial = present_serial or serial

    bat_resp = ds4u_ipc_request({"cmd": "GetBattery"}, timeout=1.2)
    battery_pct = -1
    battery_status = "Unknown"
    charging = False
    full = False
    if isinstance(bat_resp, dict) and bat_resp.get("type") == "Battery":
        bdata = bat_resp.get("data") or {}
        battery_pct = int(bdata.get("capacity", -1))
        battery_status = str(bdata.get("status") or "Unknown")
        charging = battery_status in ("Charging", "Full")
        full = battery_status == "Full"

    # A present controller plus an invalid battery response means ds4u is still
    # using its pre-disconnect handle. Yield to the direct HID path so a newly
    # created hidraw node is opened and reconnects are visible immediately.
    if battery_pct < 0:
        return None

    return {
        "ds4u_daemon": True,
        "connected": True,
        "charging": charging,
        "full": full,
        "battery_pct": battery_pct,
        "battery_status": battery_status,
        "connection": "bluetooth" if is_bt else "usb",
        "address": serial if serial != "Unknown" else "",
        "model": model_for_pid(pid) or "dualsense",
        "product_id": pid,
        **cfg,
    }


def hid_info(dev):
    """Return (connection, address/uniq, pid) from sysfs uevent of a hidraw node."""
    bus, pid, uniq = "", 0, ""
    try:
        with open(f"/sys/class/hidraw/{os.path.basename(dev)}/device/uevent") as f:
            for line in f:
                k, _, v = line.strip().partition("=")
                if k == "HID_ID":
                    parts = v.split(":")
                    bus = parts[0].upper()
                    pid = int(parts[2], 16) if len(parts) == 3 else 0
                elif k == "HID_UNIQ":
                    uniq = v.strip()
    except (OSError, ValueError):
        pass
    conn = "bluetooth" if bus == "0005" else "usb"
    return conn, uniq, pid


def find_present_controller():
    """Return (connection, address, pid) from current hidraw sysfs nodes.

    This deliberately does not open or read hidraw, so it can validate ds4u's
    cached controller handle without competing with the daemon for reports.
    """
    for sysfs_path in glob.glob("/sys/class/hidraw/hidraw*"):
        dev = "/dev/" + os.path.basename(sysfs_path)
        conn, uniq, pid = hid_info(dev)
        if pid in SONY_PIDS:
            return conn, uniq, pid
    return "", "", 0


def sysfs_battery(dev=None, uniq=""):
    """Read battery capacity & status from kernel power_supply (hid-playstation)."""
    candidates = []
    if dev:
        base = f"/sys/class/hidraw/{os.path.basename(dev)}/device/power_supply"
        if os.path.isdir(base):
            for name in os.listdir(base):
                candidates.append(os.path.join(base, name))
    for pattern in ("/sys/class/power_supply/ps-controller-battery*",
                    "/sys/class/power_supply/sony_controller_battery*"):
        for path in glob.glob(pattern):
            if path not in candidates:
                if not uniq or uniq.lower() in path.lower():
                    candidates.append(path)

    for ps in candidates:
        try:
            with open(os.path.join(ps, "capacity")) as f:
                cap = int(f.read().strip())
            status = "Discharging"
            status_file = os.path.join(ps, "status")
            if os.path.isfile(status_file):
                with open(status_file) as f:
                    status = f.read().strip()
            return max(0, min(100, cap)), status
        except (OSError, ValueError):
            continue
    return None, None


def bluez_battery(address):
    """Fallback battery % from BlueZ org.bluez.Battery1, or None."""
    if not address or ":" not in address:
        return None
    dev = "dev_" + address.upper().replace(":", "_")
    for hci in ("hci0", "hci1", "hci2"):
        try:
            out = subprocess.run(
                [
                    "busctl",
                    "--system",
                    "get-property",
                    "org.bluez",
                    f"/org/bluez/{hci}/{dev}",
                    "org.bluez.Battery1",
                    "Percentage",
                ],
                capture_output=True,
                text=True,
                timeout=2,
            ).stdout.split()
        except (OSError, subprocess.TimeoutExpired):
            return None
        if len(out) == 2 and out[0] == "y":
            try:
                return max(0, min(100, int(out[1])))
            except ValueError:
                return None
    return None


def find_device():
    """Return (hidraw path or None, connection, uniq, pid) for a Sony pad.

    DualShock 4 report ids are not the DualSense layout, so those pads are only
    reported through their sysfs power_supply (hid-sony) and never parsed here.
    """
    fallback = (None, "", "", 0)
    for i in range(32):
        dev = f"/dev/hidraw{i}"
        conn, uniq, uevent_pid = hid_info(dev)
        if uevent_pid in SONY_PIDS and fallback[0] is None:
            fallback = (None, conn, uniq, uevent_pid)
        if uevent_pid in DS4_PIDS:
            continue
        try:
            fd = os.open(dev, os.O_RDONLY | os.O_NONBLOCK)
        except OSError:
            continue
        try:
            buf = bytearray(8)
            fcntl.ioctl(fd, HIDIOCGRAWINFO, buf, True)
            _, vendor, product = struct.unpack("ihh", bytes(buf))
            vid = vendor & 0xFFFF
            pid = product & 0xFFFF
            if vid != DS_VID or pid not in DS_PIDS:
                continue
            conn, uniq, _ = hid_info(dev)
            fallback = (dev, conn, uniq, pid)
            if select.select([fd], [], [], 0.15)[0]:
                return dev, conn, uniq, pid
        except OSError:
            pass
        finally:
            os.close(fd)
    return fallback


def parse_battery_byte(status_byte):
    """Parse DualSense battery status byte using ds4u's exact formula."""
    bat_data = status_byte & DS_STATUS_BATTERY_CAPACITY
    charging_status = (status_byte & DS_STATUS_CHARGING) >> DS_STATUS_CHARGING_SHIFT
    if charging_status == 0x0:
        return min(bat_data * 10 + 5, 100), "Discharging", False, False
    if charging_status == 0x1:
        return min(bat_data * 10 + 5, 100), "Charging", True, False
    if charging_status == 0x2:
        return min(bat_data * 10 + 5, 100), "Full", True, True
    if charging_status in (0xA, 0xB):
        return 0, "Not charging", False, False
    return 0, "Unknown", False, False


def parse_input_report(data, connection):
    """Extract (capacity, status_str, charging, full) from a DualSense input report."""
    if not data:
        return None
    report_id = data[0]
    if connection == "bluetooth":
        if report_id == DS_INPUT_REPORT_BT and len(data) >= 55:
            return parse_battery_byte(data[54])
    else:
        if report_id == DS_INPUT_REPORT_USB and len(data) >= 54:
            return parse_battery_byte(data[53])
    return None


class State:
    def __init__(self, stream=False):
        self.battery_pct = -1
        self.battery_status = "Disconnected"
        self.connected = False
        self.charging = False
        self.full = False
        self.provisional = True
        self.last_seen = ""
        self.connection = ""
        self.address = ""
        self.model = "dualsense"
        self.product_id = DS_PID
        self.profile = "Default"
        self.profiles = ["Default"]
        self.lightbar_color = "#0080ff"
        self.player_leds = 1
        self.mic_muted = True
        self.ds4u_daemon = False
        self.stream = stream
        self._last_write = 0
        self._last_dump = None
        self.load()

    def load(self):
        """Preserve the last known percentage and model across daemon restarts."""
        try:
            with open(STATE_FILE) as f:
                d = json.load(f)
            self.battery_pct = int(d.get("battery_pct", -1))
            if d.get("model") in ("dualsense", "edge"):
                self.model = d["model"]
        except (OSError, ValueError, TypeError):
            pass

    def apply_config(self, cfg):
        self.profile = cfg.get("profile", self.profile)
        self.profiles = cfg.get("profiles", self.profiles)
        self.lightbar_color = cfg.get("lightbar_color", self.lightbar_color)
        self.player_leds = cfg.get("player_leds", self.player_leds)
        self.mic_muted = cfg.get("mic_muted", self.mic_muted)

    def payload(self):
        return {
            "battery_pct": self.battery_pct,
            "battery_status": self.battery_status,
            "connected": self.connected,
            "charging": self.charging,
            "full": self.full,
            "provisional": self.provisional,
            "last_seen": self.last_seen,
            "connection": self.connection,
            "address": self.address,
            "model": self.model,
            "product_id": self.product_id,
            "profile": self.profile,
            "profiles": self.profiles,
            "lightbar_color": self.lightbar_color,
            "player_leds": self.player_leds,
            "mic_muted": self.mic_muted,
            "ds4u_daemon": self.ds4u_daemon,
            "daemon_version": DAEMON_VERSION,
            "updated_at": datetime.now().isoformat(timespec="seconds"),
            "ts": int(time.time()),
        }

    def write(self, force=False):
        now = time.time()
        d = self.payload()
        key = (
            d["battery_pct"],
            d["battery_status"],
            d["connected"],
            d["charging"],
            d["full"],
            d["provisional"],
            d["connection"],
            d["model"],
            d["profile"],
            tuple(d["profiles"]),
            d["lightbar_color"],
            d["player_leds"],
            d["mic_muted"],
            d["ds4u_daemon"],
        )
        if (
            not force
            and key == self._last_dump
            and now - self._last_write < WRITE_INTERVAL
        ):
            return
        self._last_write = now
        self._last_dump = key

        if self.stream:
            print(json.dumps(d, separators=(",", ":")), flush=True)

        try:
            tmp = STATE_FILE + ".tmp"
            with open(tmp, "w") as f:
                json.dump(d, f)
            os.replace(tmp, STATE_FILE)
        except OSError:
            pass


def run(stream=False):
    st = State(stream=stream)
    st.apply_config(read_ds4u_config())
    st.write(force=True)

    while True:
        # 1. Prefer querying ds4u daemon if it is running so we don't steal HID reports
        ipc_state = query_ds4u_daemon()
        if ipc_state is not None:
            st.ds4u_daemon = True
            st.apply_config(ipc_state)
            if ipc_state.get("connected"):
                st.connected = True
                st.connection = ipc_state["connection"]
                st.address = ipc_state["address"]
                st.model = ipc_state["model"]
                st.product_id = ipc_state["product_id"]
                st.last_seen = datetime.now().strftime("%H:%M")
                pct = ipc_state.get("battery_pct", -1)
                if pct >= 0:
                    st.battery_pct = pct
                    st.battery_status = ipc_state.get("battery_status", "Connected")
                    st.charging = bool(ipc_state.get("charging", False))
                    st.full = bool(ipc_state.get("full", False))
                    st.provisional = False
                else:
                    spct, sstat = sysfs_battery(uniq=st.address)
                    if spct is not None:
                        st.battery_pct = spct
                        st.battery_status = sstat or "Discharging"
                        st.charging = sstat in ("Charging", "Full")
                        st.full = sstat == "Full"
                        st.provisional = False
            else:
                st.connected = False
                st.charging = False
                st.full = False
                st.battery_status = "Disconnected"
                st.connection = ""
                st.address = ""
                st.provisional = True
            st.write()
            time.sleep(1.5)
            continue

        st.ds4u_daemon = False
        st.apply_config(read_ds4u_config())

        # 2. Direct HID / sysfs discovery
        dev, conn, uniq, pid = find_device()
        if not dev:
            # Check sysfs power_supply in case hidraw isn't readable but kernel driver is bound
            spct, sstat = sysfs_battery(uniq=uniq)
            if conn:
                st.connected = True
                st.connection = conn
                st.address = uniq
                st.product_id = pid or DS_PID
                st.model = model_for_pid(pid) or "dualsense"
                if spct is not None:
                    st.battery_pct = spct
                    st.battery_status = sstat or "Discharging"
                    st.charging = sstat in ("Charging", "Full")
                    st.full = sstat == "Full"
                    st.provisional = False
                else:
                    # DualShock 4 over Bluetooth: hid-sony may not expose the
                    # power_supply on every kernel, so ask BlueZ as a fallback.
                    bpct = bluez_battery(uniq)
                    if bpct is not None:
                        st.battery_pct = bpct
                        st.battery_status = "Connected"
                        st.charging = False
                        st.full = False
                        st.provisional = False
                st.last_seen = datetime.now().strftime("%H:%M")
            else:
                st.connected = False
                st.charging = False
                st.full = False
                st.battery_status = "Disconnected"
                st.connection = ""
                st.address = ""
                st.provisional = True
            st.write()
            time.sleep(1.5)
            continue

        try:
            fd = os.open(dev, os.O_RDONLY | os.O_NONBLOCK)
        except OSError:
            time.sleep(1.5)
            continue

        st.connection = conn
        st.address = uniq
        st.product_id = pid or DS_PID
        st.model = model_for_pid(pid) or "dualsense"
        silent_since = None
        last_cfg_poll = 0.0

        try:
            while True:
                # If ds4u daemon starts up while we have hidraw open, yield to it
                if os.path.exists(DS4U_SOCKET) and time.time() - last_cfg_poll >= 2.0:
                    if query_ds4u_daemon() is not None:
                        break

                if time.time() - last_cfg_poll >= 2.0:
                    last_cfg_poll = time.time()
                    st.apply_config(read_ds4u_config())

                r, _, _ = select.select([fd], [], [], 1.0)
                if not r:
                    silent_since = silent_since or time.time()
                    if time.time() - silent_since >= SILENCE_DISCONNECT:
                        break
                    continue

                data = os.read(fd, 128)
                if not data:
                    break
                silent_since = None
                st.connected = True
                st.last_seen = datetime.now().strftime("%H:%M")

                parsed = parse_input_report(data, st.connection)
                if parsed is not None:
                    cap, status_str, is_chg, is_full = parsed
                    if cap > 0 or status_str in ("Discharging", "Charging", "Full"):
                        st.battery_pct = cap
                        st.provisional = False
                    st.battery_status = status_str
                    st.charging = is_chg
                    st.full = is_full
                else:
                    # Bluetooth minimal report 0x01 or non-standard report -> use sysfs or BlueZ
                    spct, sstat = sysfs_battery(dev, st.address)
                    if spct is not None:
                        st.battery_pct = spct
                        st.battery_status = sstat or "Discharging"
                        st.charging = sstat in ("Charging", "Full")
                        st.full = sstat == "Full"
                        st.provisional = False
                    elif st.connection == "bluetooth":
                        bpct = bluez_battery(st.address)
                        if bpct is not None:
                            st.battery_pct = bpct
                            st.battery_status = "Discharging"
                            st.charging = False
                            st.full = False
                            st.provisional = False

                st.write()
        except OSError:
            st.connected = False
            st.charging = False
            st.full = False
            st.battery_status = "Disconnected"
            st.provisional = True
            st.write()
        finally:
            try:
                os.close(fd)
            except OSError:
                pass
        time.sleep(1.0)


def build_output_report(is_bt, seq, rumble_l=0, rumble_r=0, lightbar=None, player_leds=None):
    """Build a DualSense USB (0x02) or Bluetooth (0x31) output report with CRC-32."""
    if is_bt:
        buf = bytearray(DS_OUTPUT_REPORT_BT_SIZE)
        buf[0] = DS_OUTPUT_REPORT_BT
        buf[1] = (seq & 0x0F) << 4
        buf[2] = DS_OUTPUT_TAG
        offset = 3
    else:
        buf = bytearray(DS_INPUT_REPORT_USB_SIZE - 1)
        buf[0] = DS_OUTPUT_REPORT_USB
        offset = 1

    if rumble_l is not None or rumble_r is not None:
        buf[offset] |= 0x01  # COMPATIBLE_VIBRATION
        buf[offset + 2] = max(0, min(255, int(rumble_r or 0)))
        buf[offset + 3] = max(0, min(255, int(rumble_l or 0)))
        buf[offset + 38] |= 0x04  # IMPROVED_RUMBLE_EMULATION

    if lightbar is not None:
        r, g, b, br = lightbar
        buf[offset + 1] |= 0x04  # LIGHTBAR_CONTROL_ENABLE
        buf[offset + 44] = int((br * r) // 255) & 0xFF
        buf[offset + 45] = int((br * g) // 255) & 0xFF
        buf[offset + 46] = int((br * b) // 255) & 0xFF

    if player_leds is not None and 0 <= player_leds < len(PLAYER_LED_PATTERNS):
        buf[offset + 1] |= 0x10  # PLAYER_INDICATOR_CONTROL_ENABLE
        buf[offset + 43] = PLAYER_LED_PATTERNS[player_leds]

    if is_bt:
        crc = binascii.crc32(bytes([OUTPUT_CRC32_SEED]) + bytes(buf[:-4])) & 0xFFFFFFFF
        buf[-4:] = struct.pack("<I", crc)

    return bytes(buf)


def buzz():
    """Rumble the DualSense controller via ds4u daemon or direct HID output report."""
    if query_ds4u_daemon() is not None:
        for amp, secs in BUZZ_PATTERN:
            ds4u_ipc_request({"cmd": "SetRumble", "args": {"left": amp, "right": amp}})
            time.sleep(secs)
        ds4u_ipc_request({"cmd": "SetRumble", "args": {"left": 0, "right": 0}})
        return 0

    dev, conn, _, _ = find_device()
    if not dev:
        return 1
    is_bt = conn == "bluetooth"
    try:
        fd = os.open(dev, os.O_WRONLY)
    except OSError:
        return 1
    seq = 0
    try:
        for amp, secs in BUZZ_PATTERN:
            end = time.time() + secs
            while time.time() < end:
                pkt = build_output_report(is_bt, seq, rumble_l=amp, rumble_r=amp)
                seq = (seq + 1) & 0x0F
                os.write(fd, pkt)
                time.sleep(0.04)
        pkt = build_output_report(is_bt, seq, rumble_l=0, rumble_r=0)
        os.write(fd, pkt)
    except OSError:
        return 1
    finally:
        os.close(fd)
    return 0


def apply_profile_direct(profile_name):
    """Apply lightbar and player LEDs from a saved ds4u profile directly over HID."""
    profiles_dir = os.path.join(DS4U_CONFIG_DIR, "profiles")
    pfile = os.path.join(profiles_dir, f"{sanitize_profile_filename(profile_name)}.json")
    if not os.path.isfile(pfile):
        return
    try:
        with open(pfile) as f:
            p = json.load(f)
        r = int(round(float(p.get("lightbar_r", 0.0)) * 255.0))
        g = int(round(float(p.get("lightbar_g", 0.5)) * 255.0))
        b = int(round(float(p.get("lightbar_b", 1.0)) * 255.0))
        br = int(round(float(p.get("lightbar_brightness", 255.0))))
        leds = int(p.get("player_leds", 1))
    except (OSError, ValueError, TypeError):
        return

    dev, conn, _, _ = find_device()
    if not dev:
        return
    try:
        fd = os.open(dev, os.O_WRONLY)
    except OSError:
        return
    try:
        pkt = build_output_report(
            conn == "bluetooth", 0, rumble_l=None, rumble_r=None,
            lightbar=(r, g, b, br), player_leds=leds
        )
        os.write(fd, pkt)
    except OSError:
        pass
    finally:
        os.close(fd)


def switch_profile(target_name):
    """Switch active ds4u profile via daemon IPC or settings.json fallback."""
    target = (target_name or "").strip()
    if not target:
        return 1

    if query_ds4u_daemon() is not None:
        resp = ds4u_ipc_request({"cmd": "SwitchProfile", "args": {"name": target}})
        if isinstance(resp, dict) and resp.get("type") == "Ok":
            return 0

    settings_path = os.path.join(DS4U_CONFIG_DIR, "settings.json")
    data = {"theme_id": "default", "profile": target}
    try:
        if os.path.isfile(settings_path):
            with open(settings_path) as f:
                existing = json.load(f)
            if isinstance(existing, dict):
                existing["profile"] = target
                data = existing
        os.makedirs(DS4U_CONFIG_DIR, exist_ok=True)
        with open(settings_path, "w") as f:
            json.dump(data, f, indent=2)
    except OSError:
        return 1

    apply_profile_direct(target)
    return 0


def cycle_profile():
    """Cycle to the next profile in ~/.config/ds4u/profiles/."""
    ipc_state = query_ds4u_daemon()
    cfg = ipc_state if ipc_state is not None else read_ds4u_config()
    profiles = cfg.get("profiles") or ["Default"]
    current = cfg.get("profile") or "Default"
    if current in profiles:
        idx = (profiles.index(current) + 1) % len(profiles)
    else:
        idx = 0
    return switch_profile(profiles[idx])


def main():
    args = sys.argv[1:]
    if "--buzz" in args:
        return buzz()
    if "--cycle-profile" in args:
        return cycle_profile()
    if "--switch-profile" in args:
        idx = args.index("--switch-profile")
        if idx + 1 < len(args):
            return switch_profile(args[idx + 1])
        return 1

    stream = "--stream" in args
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
    lock = single_instance()
    try:
        run(stream=stream)
    except (KeyboardInterrupt, BrokenPipeError):
        pass
    finally:
        release_lock(lock)
    return 0


if __name__ == "__main__":
    sys.exit(main())
