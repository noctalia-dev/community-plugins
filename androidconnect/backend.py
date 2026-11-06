#!/usr/bin/env python3
"""AndroidConnect v5 companion: device IO, owned scrcpy session, and frame producer.

The Luau service receives JSON status on stdout and submits atomic JSON files in
a private, per-process runtime directory. Pairing codes never enter argv or disk
preferences. No user-supplied shell command is executed.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import queue
import re
import secrets
import select
import shlex
import shutil
import signal
import stat
import subprocess
import tempfile
import threading
import time

from video import Child, FrameServer, artwork_paths, phone_filter, phone_geometry, preview_size


class OperationError(Exception):
    pass


def run(argv, *, timeout=5, input=None):
    try:
        result = subprocess.run(argv, input=input, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise OperationError(str(error)) from error
    if result.returncode:
        raise OperationError((result.stderr or result.stdout or f"Exit {result.returncode}").strip()[-1500:])
    return result.stdout.strip()


def adb(serial, *args, **options):
    if not serial or "\0" in serial or len(serial) > 256:
        raise OperationError("Select an authorized ADB target first")
    return run(["adb", "-s", serial, *map(str, args)], **options)


def parse_adb(text):
    devices = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 2 or parts[0] in {"List", "*", "adb:"}:
            continue
        if parts[1] not in {"device", "offline", "unauthorized", "no"}:
            continue
        attributes = dict(part.split(":", 1) for part in parts[2:] if ":" in part)
        devices.append({
            "serial": parts[0], "state": parts[1],
            "name": attributes.get("model", parts[0]).replace("_", " "),
            "usb": "usb" in attributes,
        })
    return devices[:32]


def display_size(text):
    # wm reports physical first and override last; input uses the override.
    sizes = re.findall(r"(?:Physical|Override) size:\s*(\d+)x(\d+)", text)
    if not sizes:
        raise OperationError("Could not read the Android display size")
    width, height = map(int, sizes[-1])
    if not (16 <= width <= 20000 and 16 <= height <= 20000):
        raise OperationError("Invalid Android display size")
    return width, height


def natural_orientation(text):
    match = re.search(r"SurfaceOrientation:\s*([0-3])", text)
    if match:
        return match[1] == "0"
    # Current Android releases describe the default display's input viewport.
    for viewport in re.findall(r"(?:Viewport|viewport)[^\n]+", text):
        if re.search(r"displayId\s*[=:]\s*0\b", viewport):
            match = re.search(r"orientation\s*[=:]\s*(?:ROTATION_)?(0|1|2|3|90|180|270)\b", viewport)
            if match:
                return match[1] == "0"
    raise OperationError("Could not verify the default display orientation; touch input is disabled")


def battery_info(text):
    values = dict(re.findall(r"^\s*(level|scale|status):\s*([0-9]+)\s*$", text, re.MULTILINE))
    level, scale = int(values.get("level", "0")), int(values.get("scale", "0"))
    return {"battery": min(100, round(level * 100 / scale)) if scale > 0 and "level" in values else -1,
            "charging": values.get("status") in {"2", "5"}}


def endpoint(host, port):
    host, port = str(host).strip(), str(port).strip()
    if not port.isascii() or not port.isdigit() or not 1 <= int(port) <= 65535:
        raise OperationError("Port must be 1..65535")
    try:
        address = ipaddress.ip_address(host.strip("[]"))
        host = f"[{address}]" if address.version == 6 else str(address)
    except ValueError:
        if len(host) > 253 or not all(re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label)
                                      for label in host.rstrip(".").split(".")):
            raise OperationError("Enter an IP address or hostname") from None
    return f"{host}:{int(port)}"


def mdns_services(text):
    services = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 3 or parts[1].rstrip(".") not in {"_adb-tls-connect._tcp", "_adb-tls-pairing._tcp"}:
            continue
        host, separator, port = parts[2].rpartition(":")
        if separator:
            try:
                address = endpoint(host, port)
                services.append({"name": parts[0], "type": parts[1].rstrip("."), "host": host.strip("[]"),
                                 "port": port, "endpoint": address})
            except OperationError:
                pass
    return services[:64]


def normalized_host(host):
    host = str(host).strip().strip("[]")
    try:
        return str(ipaddress.ip_address(host))
    except ValueError:
        return host.rstrip(".").lower()


def transport_host(serial, services=()):
    serial = str(serial).rstrip(".")
    suffix = "._adb-tls-connect._tcp"
    if serial.endswith(suffix):
        name = serial.removesuffix(suffix)
        hosts = {normalized_host(item["host"]) for item in services
                 if item["type"] == "_adb-tls-connect._tcp"
                 and item["name"].rstrip(".").removesuffix(suffix) == name}
        return next(iter(hosts)) if len(hosts) == 1 else ""
    host, separator, port = serial.rpartition(":")
    return normalized_host(host) if separator and port.isascii() and port.isdigit() else ""


def discover_services():
    services = []
    try:
        services = mdns_services(run(["adb", "mdns", "services"], timeout=3))
    except OperationError:
        pass
    # Same optional Avahi fallback as v4; only this service, never a port scan.
    if shutil.which("avahi-browse"):
        try:
            output = run(["avahi-browse", "-rtkp", "_adb-tls-connect._tcp"], timeout=3)
            for line in output.splitlines():
                parts = line.split(";")
                if len(parts) >= 9 and parts[0] == "=" and parts[4] == "_adb-tls-connect._tcp":
                    address = endpoint(parts[7], parts[8])
                    item = {"name": parts[3], "type": parts[4], "host": normalized_host(parts[7]),
                            "port": parts[8], "endpoint": address}
                    if item not in services:
                        services.append(item)
        except (OperationError, ValueError):
            pass
    return services[:64]


def connect_wireless(hosts, cancelled, timeout):
    """Bounded discovery for one selected phone; run off the command/input thread."""
    wanted = {normalized_host(host) for host in hosts}
    deadline = time.monotonic() + timeout
    detail = "No Wireless ADB connect service was advertised. Enable Wireless debugging on the selected phone."
    while not cancelled.is_set() and time.monotonic() < deadline:
        services = discover_services()
        matches = sorted({item["endpoint"] for item in services
                          if item["type"] == "_adb-tls-connect._tcp" and normalized_host(item["host"]) in wanted})
        for address in matches:
            remaining = deadline - time.monotonic()
            if cancelled.is_set():
                return None
            if remaining <= 0:
                break
            try:
                output = run(["adb", "connect", address], timeout=min(3, remaining))
                if "connected to" in output:
                    return address
                detail = output or "ADB did not confirm connection"
            except OperationError as error:
                detail = str(error)
        cancelled.wait(min(1, max(0, deadline - time.monotonic())))
    if cancelled.is_set():
        return None
    raise OperationError("Wireless ADB discovery timed out. " + detail)


def unwrap(value):
    if isinstance(value, dict):
        if "type" in value and "data" in value:
            return unwrap(value["data"])
        return {key: unwrap(item) for key, item in value.items()}
    if isinstance(value, list):
        return [unwrap(item) for item in value]
    return value


def bus(path, interface, method, *args):
    text = run(["busctl", "--user", "--timeout=1", "--json=short", "call", "org.kde.kdeconnect",
                path, interface, method, *map(str, args)], timeout=2)
    data = json.loads(text).get("data", [])
    return unwrap(data[0]) if data else None


def properties(path, interface):
    try:
        value = bus(path, "org.freedesktop.DBus.Properties", "GetAll", "s", interface)
        return value if isinstance(value, dict) else {}
    except (OperationError, ValueError):
        return {}


def kde_path(device_id):
    if not re.fullmatch(r"[A-Za-z0-9_]{1,256}", device_id):
        raise OperationError("Invalid KDE Connect device ID")
    return "/modules/kdeconnect/devices/" + device_id


def probe(selected, discover=False, serial=""):
    result = {"adb": [], "kde": [], "services": [], "adbError": "", "kdeAvailable": False,
              "phone": {}, "phoneSerial": serial, "probeSelection": selected}
    if shutil.which("adb"):
        try:
            result["adb"] = parse_adb(run(["adb", "devices", "-l"]))
            if serial and any(item["serial"] == serial and item["state"] == "device" for item in result["adb"]):
                try:
                    result["phone"] = battery_info(adb(serial, "shell", "dumpsys", "battery"))
                except OperationError:
                    pass
        except OperationError as error:
            result["adbError"] = str(error)
        if discover:
            result["services"] = discover_services()
    if shutil.which("busctl"):
        try:
            ids = bus("/modules/kdeconnect", "org.kde.kdeconnect.daemon", "devices", "bb", "false", "false")
            result["kdeAvailable"] = True
            for device_id in (ids if isinstance(ids, list) else [])[:32]:
                path = kde_path(device_id)
                device = properties(path, "org.kde.kdeconnect.device")
                entry = {"id": device_id, "name": device.get("name", device_id),
                         "paired": device.get("isPaired", False), "reachable": device.get("isReachable", False),
                         "pairRequested": device.get("isPairRequested", False),
                         "addresses": device.get("reachableAddresses", []), "battery": -1}
                if device_id == selected and entry["paired"] and entry["reachable"]:
                    battery = properties(path + "/battery", "org.kde.kdeconnect.device.battery")
                    network = properties(path + "/connectivity_report", "org.kde.kdeconnect.device.connectivity_report")
                    entry.update(battery=battery.get("charge", -1), charging=battery.get("isCharging", False),
                                 network=network.get("cellularNetworkType", ""),
                                 signal=network.get("cellularNetworkStrength", -1))
                    try:
                        notifications = bus(path + "/notifications", "org.kde.kdeconnect.device.notifications", "activeNotifications")
                        entry["notifications"] = len(notifications) if isinstance(notifications, list) else 0
                    except OperationError:
                        entry["notifications"] = None
                result["kde"].append(entry)
        except (OperationError, ValueError):
            pass
    return result


def resolve_serial(devices, selected_kde, saved, services=()):
    authorized = [device["serial"] for device in devices if device["state"] == "device"]
    if selected_kde is not None:
        addresses = {normalized_host(host) for host in selected_kde.get("addresses", []) if normalized_host(host)}
        matching = [serial for serial in authorized if transport_host(serial, services) in addresses]
        if matching:
            # IP and mDNS transports can both refer to this same phone.
            return saved if saved in matching else sorted(matching, key=lambda value: ("._adb-tls-" in value, value))[0]
        # Preserve explicit USB/mDNS identity associations, but never follow a
        # stale IP to a different phone after a DHCP/port change.
        if saved in authorized and not transport_host(saved, services):
            return saved
        return ""
    if saved:
        return saved if saved in authorized else ""
    return authorized[0] if len(authorized) == 1 else ""


def save_json(path, value):
    temporary = path.with_suffix(".pending")
    with temporary.open("w", encoding="utf-8") as output:
        json.dump(value, output)
    temporary.replace(path)


class Bridge:
    def __init__(self, runtime, data):
        self.runtime, self.data = runtime, data
        self.stopped = False
        self.events = queue.Queue(maxsize=16)
        self.scrcpy = None
        self.window = None
        self.frames = None
        self.recorder = None
        self.qr = None
        self.panel_open = False
        self.auto_suppressed = False
        self.refresh_requested = True
        self.reconnect = None
        self.reconnect_attempts = set()
        self.config = {"video_device": "/dev/video10", "preview_height": 720, "fps": 60, "auto_mirror": True}
        self.artwork = artwork_paths()
        try:
            self.preferences = json.loads((data / "devices.json").read_text(encoding="utf-8"))
            if not isinstance(self.preferences, dict):
                self.preferences = {}
        except (OSError, ValueError):
            self.preferences = {}
        profiles = self.preferences.get("profiles", {})
        self.preferences["profiles"] = {
            key: value for key, value in (profiles.items() if isinstance(profiles, dict) else [])
            if isinstance(key, str) and isinstance(value, str) and len(value) <= 256
        }
        wireless = self.preferences.get("wireless", {})
        self.preferences["wireless"] = {
            key: {"host": normalized_host(value["host"])}
            for key, value in (wireless.items() if isinstance(wireless, dict) else [])
            if isinstance(key, str) and isinstance(value, dict) and isinstance(value.get("host"), str)
            and 0 < len(value["host"]) <= 253
        }
        names = self.preferences.get("names", {})
        self.preferences["names"] = {
            key: value.strip() for key, value in (names.items() if isinstance(names, dict) else [])
            if isinstance(key, str) and key.startswith(("kde:", "adb:")) and len(key) <= 300
            and isinstance(value, str) and 0 < len(value) <= 80 and value.isprintable() and value.strip()
        }
        size = self.preferences.get("phoneSize", 3)
        size = size if type(size) is int and 1 <= size <= 3 else 3
        direction = self.preferences.get("phoneSizeDirection", -1 if size == 3 else 1)
        self.model = {
            "runtime": str(runtime), "socket": str(runtime / "frames.sock"),
            "adb": [], "kde": [], "selectedKde": str(self.preferences.get("selectedKde", "")), "serial": "",
            "phase": "idle", "error": "", **phone_geometry(538, 1190), "sourceWidth": 0, "sourceHeight": 0,
            "audio": True, "keepAwake": False, "dim": False, "recording": False, "busy": False,
            "phoneSize": size,
            "phoneSizeDirection": direction if type(direction) is int and direction in (-1, 1) else (-1 if size == 3 else 1),
            "names": self.preferences["names"],
            "qrPath": "", "qrActive": False, "configured": False, "idleArtwork": self.artwork["idle"],
            "wirelessHost": "", "wirelessPort": "", "wirelessState": "idle", "wirelessError": "",
            "tools": {name: bool(shutil.which(name)) for name in ("adb", "scrcpy", "ffmpeg", "fuser", "busctl", "qrencode")},
        }

    def publish(self):
        print(json.dumps({"kind": "status", "value": self.model}, ensure_ascii=True), flush=True)

    def notice(self, key, detail="", *, error=False):
        print(json.dumps({"kind": "notice", "key": key, "detail": str(detail)[-1500:], "error": error}), flush=True)

    def selected_kde(self):
        return next((item for item in self.model["kde"] if item["id"] == self.model["selectedKde"]), None)

    def saved_serial(self):
        profiles = self.preferences.get("profiles", {})
        return profiles.get(self.model["selectedKde"] or "adb-only", "") if isinstance(profiles, dict) else ""

    def selection_key(self):
        return self.model["selectedKde"] or "adb-only"

    def wireless_hosts(self):
        device = self.selected_kde()
        hosts = device.get("addresses", []) if device else []
        if not hosts:
            hosts = [self.preferences["wireless"].get(self.selection_key(), {}).get("host", "")
                     or transport_host(self.saved_serial(), self.model.get("services", []))]
        result = []
        for host in hosts:
            host = normalized_host(host)
            try:
                endpoint(host, "1")
            except OperationError:
                continue
            if host not in result:
                result.append(host)
        return result[:8]

    def resolved_serial(self):
        # Match against the same live-or-saved hosts used for reconnection, even
        # when KDE lists the phone without reachable addresses. A selected phone
        # must still never fall back to an unrelated authorized ADB target.
        hosts = self.wireless_hosts()
        device = {"addresses": hosts} if self.model["selectedKde"] or hosts else None
        return resolve_serial(self.model["adb"], device, self.saved_serial(), self.model.get("services", []))

    def remember_wireless(self, address):
        host = transport_host(address)
        if not host:
            return
        key = self.selection_key()
        saved = self.preferences["profiles"].get(key, "")
        # Keep explicit USB/mDNS identities stable when an IP alias also appears.
        target = saved if saved and ":" not in saved else address
        if saved != target or self.preferences["wireless"].get(key) != {"host": host}:
            self.preferences["profiles"][key] = target
            self.preferences["wireless"][key] = {"host": host}
            save_json(self.data / "devices.json", self.preferences)
        self.model.update(wirelessHost=host, wirelessPort=address.rpartition(":")[2], wirelessError="")

    def cancel_reconnect(self):
        if self.reconnect is not None:
            self.reconnect["cancel"].set()
            self.reconnect = None
        self.model["wirelessState"] = "idle"

    def request_reconnect(self, timeout=12, host=""):
        hosts = self.wireless_hosts()
        if host:
            host = normalized_host(host)
            endpoint(host, "1")
            device = self.selected_kde()
            if device and device.get("addresses") and host not in hosts:
                raise OperationError("That host does not belong to the selected KDE Connect phone")
            hosts = [host]
        if not hosts or not self.model["tools"]["adb"]:
            return
        serial = self.model["serial"]
        if any(item["serial"] == serial and item["state"] == "device" for item in self.model["adb"]):
            address = transport_host(serial, self.model.get("services", []))
            if address in hosts:
                self.model.update(wirelessState="connected", wirelessError="")
                return
        self.cancel_reconnect()
        self.reconnect_attempts.add((self.selection_key(), tuple(hosts)))
        self.reconnect = {"key": self.selection_key(), "hosts": hosts, "timeout": timeout, "cancel": threading.Event()}
        self.model.update(wirelessHost=hosts[0], wirelessPort="", wirelessState="scanning", wirelessError="")

    def poll_reconnect(self):
        job = self.reconnect
        if job is None or "future" not in job or not job["future"].done():
            return
        self.reconnect = None
        if job["cancel"].is_set() or job["key"] != self.selection_key() or not self.panel_open:
            return
        try:
            address = job["future"].result()
            device = self.selected_kde()
            allowed = {normalized_host(host) for host in device.get("addresses", [])} if device else set()
            if address and transport_host(address) in job["hosts"] and (not allowed or transport_host(address) in allowed):
                self.remember_wireless(address)
                self.model["wirelessState"] = "connected"
                self.auto_suppressed = False
                self.refresh_requested = True
            else:
                self.model["wirelessState"] = "idle"
        except (OperationError, OSError, ValueError) as error:
            self.model.update(wirelessState="timeout", wirelessError=str(error))
        self.publish()

    def name_key(self):
        device = self.selected_kde()
        if device is not None:
            return "kde:" + device["id"]
        serial = self.model["serial"]
        return "adb:" + serial if serial and any(item["serial"] == serial for item in self.model["adb"]) else ""

    def rename_device(self, request):
        key, name = request.get("nameKey"), request.get("name")
        if not key or key != self.name_key():
            raise OperationError("The selected device changed; reopen Rename device")
        if not isinstance(name, str) or len(name) > 80 or any(not char.isprintable() for char in name):
            raise OperationError("Use a device name of up to 80 printable characters")
        names = dict(self.preferences["names"])
        if name.strip():
            names[key] = name.strip()
        else:
            names.pop(key, None)
        preferences = dict(self.preferences, names=names)
        save_json(self.data / "devices.json", preferences)
        self.preferences, self.model["names"] = preferences, names

    def serial(self):
        serial = self.model["serial"]
        if not any(item["serial"] == serial and item["state"] == "device" for item in self.model["adb"]):
            raise OperationError("The selected ADB device is not authorized or is disconnected")
        return serial

    def stop_mirror(self):
        self.model["phase"] = "idle"
        if self.frames is not None:
            self.frames.stop()
            self.frames = None
        if self.scrcpy is not None:
            self.scrcpy.stop()
            self.scrcpy = None
        self.model["keepAwake"] = False
        self.model["dim"] = False

    def stop_window(self):
        if self.window is not None:
            self.window.stop()
            self.window = None

    def start_window(self, token):
        serial = self.serial()
        if not isinstance(token, str) or not 1 <= len(token) <= 64:
            raise OperationError("Invalid window request")
        for name in ("adb", "scrcpy"):
            if not shutil.which(name):
                raise OperationError(f"Install {name} to open the phone in a window")
        command = ["scrcpy", "--serial=" + serial, "--no-clipboard-autosync", "--max-size=1920",
                   "--max-fps=60", "--video-bit-rate=12M", "--video-codec=h264"]
        if not self.model["audio"]:
            command.append("--no-audio")
        if self.model["keepAwake"]:
            command += ["--stay-awake", "--screen-off-timeout=2147483"]
        if self.model["dim"]:
            command.append("--turn-screen-off")
        self.finish_recording()
        self.stop_mirror()
        self.stop_window()
        self.auto_suppressed = True
        self.window = Child(command)
        # Acknowledge this panel's request only after spawning succeeds. Ordinary
        # panel close stops the embedded session, not this owned desktop window.
        self.model["windowRequest"] = token

    def start_mirror(self):
        serial = self.serial()
        for name in ("adb", "scrcpy", "ffmpeg", "fuser"):
            if not shutil.which(name):
                raise OperationError(f"Install {name} to enable mirroring")
        device = Path(self.config["video_device"])
        if not device.is_char_device() or not os.access(device, os.R_OK | os.W_OK):
            raise OperationError("The configured V4L2 loopback device is missing or not readable/writable")
        width, height = display_size(adb(serial, "shell", "wm", "size"))
        if not natural_orientation(adb(serial, "shell", "dumpsys", "input")):
            raise OperationError("Rotate the phone to its natural orientation before starting the preview")
        awake, dim = self.model["keepAwake"], self.model["dim"]
        self.stop_mirror()
        users = subprocess.run(["fuser", "--", str(device)], capture_output=True, timeout=3)
        if users.returncode != 1:
            raise OperationError("The loopback device is in use or its ownership could not be checked; reserve a free device for AndroidConnect")
        self.model.update(phase="starting", error="", sourceWidth=width, sourceHeight=height,
                          keepAwake=awake, dim=dim)
        # Keep the overall phone height unchanged, including the fitted bezel.
        preview_width, preview_height = preview_size(width, height, self.config["preview_height"] * 1190 / 1241)
        phone = phone_geometry(preview_width, preview_height)
        self.model.update(phone)
        self.publish()
        command = ["scrcpy", "--serial=" + serial, "--v4l2-sink=" + str(device), "--no-window",
                   "--no-clipboard-autosync", "--capture-orientation=@0", "--max-size=960", "--verbosity=info",
                   "--max-fps=" + str(self.config["fps"]), "--video-bit-rate=8M", "--v4l2-buffer=0"]
        if not self.model["audio"]:
            command.append("--no-audio")
        if awake:
            command += ["--stay-awake", "--screen-off-timeout=2147483"]
        if dim:
            command.append("--turn-screen-off")
        try:
            self.scrcpy = Child(command)
            # FrameServer retries until the loopback is available and reports
            # readiness from actual pixels, not scrcpy's buffered stdout logs.
            video = ["ffmpeg", "-nostdin", "-loglevel", "error", "-threads", "1", "-filter_complex_threads", "1",
                     "-f", "v4l2", "-framerate", str(self.config["fps"]), "-i", str(device),
                     "-threads", "1", "-i", self.artwork["frame"],
                     "-filter_complex", phone_filter(preview_width, preview_height), "-map", "[phone]", "-an",
                     "-threads", "1", "-fps_mode", "passthrough", "-f", "rawvideo", "pipe:1"]
            self.frames = FrameServer(self.runtime / "frames.sock", video, phone["width"], phone["height"], self.events)
        except Exception:
            self.stop_mirror()
            raise

    def set_selection(self, request):
        self.cancel_reconnect()
        self.cancel_qr()
        if self.recorder is not None:
            self.finish_recording()
        self.stop_mirror()
        self.auto_suppressed = False
        if "kde" in request:
            device_id = str(request["kde"])
            if device_id and not any(item["id"] == device_id for item in self.model["kde"]):
                raise OperationError("Unknown KDE Connect device")
            self.model["selectedKde"] = device_id
            self.preferences["selectedKde"] = device_id
            self.model["serial"] = self.resolved_serial()
        if "serial" in request:
            serial = str(request["serial"])
            if serial and not any(item["serial"] == serial and item["state"] == "device" for item in self.model["adb"]):
                raise OperationError("Choose an authorized ADB device")
            self.preferences.setdefault("profiles", {})[self.model["selectedKde"] or "adb-only"] = serial
            self.model["serial"] = serial
        save_json(self.data / "devices.json", self.preferences)
        hosts = self.wireless_hosts()
        self.model.update(wirelessHost=hosts[0] if hosts else "", wirelessPort="", wirelessError="")

    def kde_action(self, action, request):
        device = self.selected_kde()
        if device is None:
            raise OperationError("Select a KDE Connect device first")
        path = kde_path(device["id"])
        interface = "org.kde.kdeconnect.device"
        if action == "pair":
            bus(path, interface, "requestPairing")
        elif action == "unpair":
            bus(path, interface, "unpair")
        elif not device["paired"] or not device["reachable"]:
            raise OperationError("This KDE Connect device is not paired and reachable")
        elif action == "ring":
            bus(path + "/findmyphone", interface + ".findmyphone", "ring")
        elif action == "browse":
            bus(path + "/sftp", interface + ".sftp", "mountAndWait")
            directories = bus(path + "/sftp", interface + ".sftp", "getDirectories")
            if isinstance(directories, list) and directories:
                directories = directories[0]
            if not isinstance(directories, dict) or not directories:
                raise OperationError("KDE Connect returned no mounted directories")
            directory = Path(next(iter(directories)))
            if not directory.is_absolute() or not directory.is_dir():
                raise OperationError("KDE Connect returned an invalid mount path")
            subprocess.Popen(["xdg-open", str(directory)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        elif action == "share":
            file = Path(str(request.get("path", ""))).expanduser().resolve()
            if not file.is_file():
                raise OperationError("Choose a local regular file to send")
            bus(path + "/share", interface + ".share", "shareUrls", "as", "1", file.as_uri())

    def output_path(self, kind, extension):
        base = Path.home() / ("Pictures" if kind == "screenshot" else "Videos")
        if shutil.which("xdg-user-dir"):
            try:
                configured = run(["xdg-user-dir", "PICTURES" if kind == "screenshot" else "VIDEOS"])
                if Path(configured).is_absolute():
                    base = Path(configured)
            except OperationError:
                pass
        directory = base / "AndroidConnect"
        directory.mkdir(parents=True, exist_ok=True)
        return directory / (time.strftime("%Y-%m-%d_%H-%M-%S") + "-" + secrets.token_hex(3) + extension)

    def screenshot(self):
        path = self.output_path("screenshot", ".png")
        try:
            with path.open("xb") as output:
                result = subprocess.run(["adb", "-s", self.serial(), "exec-out", "screencap", "-p"],
                                        stdout=output, stderr=subprocess.PIPE, timeout=10)
            if result.returncode or path.stat().st_size < 8:
                raise OperationError(result.stderr.decode("utf-8", "replace") or "Screenshot failed")
        except Exception:
            path.unlink(missing_ok=True)
            raise
        self.notice("notice.screenshot", str(path))

    def start_recording(self):
        serial = self.serial()
        remote = "/sdcard/AndroidConnect-" + secrets.token_hex(8) + ".mp4"
        local = self.output_path("recording", ".mp4")
        # This fixed script reports its own PID before exec; stopping never uses
        # pkill or touches another screenrecord/ADB session.
        script = "echo $$; exec screenrecord " + remote
        process = subprocess.Popen(["adb", "-s", serial, "shell", "sh", "-c", shlex.quote(script)],
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        ready, _, _ = select.select([process.stdout], [], [], 5)
        pid = process.stdout.readline().strip() if ready else ""
        if not pid.isascii() or not pid.isdigit() or not 1 < int(pid) <= 4194304:
            process.terminate()
            process.wait(timeout=3)
            process.stdout.close()
            raise OperationError("Could not start the Android screen recorder")
        self.recorder = {"process": process, "pid": pid, "serial": serial, "remote": remote, "local": local}
        self.model["recording"] = True

    def finish_recording(self):
        recording, self.recorder = self.recorder, None
        self.model["recording"] = False
        if recording is None:
            return
        process = recording["process"]
        try:
            if process.poll() is None:
                adb(recording["serial"], "shell", "kill", "-INT", recording["pid"])
            process.wait(timeout=5)
            adb(recording["serial"], "pull", recording["remote"], str(recording["local"]), timeout=30)
            adb(recording["serial"], "shell", "rm", "--", recording["remote"])
            self.notice("notice.recording", str(recording["local"]))
        except (OperationError, subprocess.TimeoutExpired) as error:
            self.notice("errors.recording", f"{error}\n{recording['remote']}", error=True)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            process.stdout.close()

    def cancel_qr(self):
        if self.qr is not None:
            Path(self.qr["path"]).unlink(missing_ok=True)
        self.qr = None
        self.model.update(qrActive=False, qrPath="")

    def discover(self):
        return discover_services()

    def wireless(self, request):
        action = request["action"]
        if action == "qr":
            if not shutil.which("qrencode"):
                raise OperationError("Install qrencode for QR pairing")
            self.cancel_qr()
            self.cancel_reconnect()
            name, secret = "ANDROIDCONNECT-" + secrets.token_hex(6), secrets.token_hex(12)
            path = str(self.runtime / ("pairing-" + secrets.token_hex(6) + ".png"))
            run(["qrencode", "-o", path, "-s", "5"],
                input=f"WIFI:T:ADB;S:{name};P:{secret};;")
            self.qr = {"name": name, "secret": secret, "deadline": time.monotonic() + 90, "host": "", "path": path}
            self.model.update(qrActive=True, qrPath=path)
        elif action == "pairAdb":
            self.cancel_reconnect()
            code = str(request.get("code", ""))
            if not re.fullmatch(r"[0-9]{6}", code):
                raise OperationError("Enter the six-digit pairing code displayed by Android")
            address = endpoint(request.get("host", ""), request.get("port", ""))
            output = run(["adb", "pair", address], input=code + "\n", timeout=15)
            if "Successfully paired" not in output:
                raise OperationError("ADB did not confirm pairing")
            host = transport_host(address)
            self.preferences["wireless"][self.selection_key()] = {"host": host}
            save_json(self.data / "devices.json", self.preferences)
            self.request_reconnect(18, host)
            self.notice("notice.paired")
        elif action == "connectAdb":
            self.cancel_reconnect()
            address = endpoint(request.get("host", ""), request.get("port", ""))
            output = run(["adb", "connect", address], timeout=10)
            if "connected to" not in output:
                raise OperationError(output or "ADB did not confirm connection")
            self.remember_wireless(address)
            self.auto_suppressed = False
            self.model["wirelessState"] = "connected"
            self.notice("notice.connected")
        elif action == "autoConnect":
            self.request_reconnect(18, str(request.get("host", "")))

    def handle(self, request):
        action = request.get("action")
        if action in {"refresh", "select", "pairAdb", "connectAdb", "pair", "unpair", "autoConnect"}:
            self.refresh_requested = True
        if action == "configure":
            options = request.get("options", {})
            artwork = artwork_paths(options.get("artwork_directory", ""))
            device = str(options.get("video_device", "/dev/video10"))
            if not re.fullmatch(r"/dev/video[0-9]+", device):
                raise OperationError("Configure an absolute /dev/videoN loopback device")
            self.config = {"video_device": device, "auto_mirror": options.get("auto_mirror", True) is True,
                           "preview_height": max(240, min(720, int(options.get("preview_height", 720)))),
                           "fps": max(1, min(60, int(options.get("fps", 60))))}
            restart = artwork != self.artwork and self.scrcpy is not None
            self.artwork = artwork
            self.model["idleArtwork"] = artwork["idle"]
            self.model["configured"] = True
            if restart:
                self.start_mirror()
        elif action == "size":
            size, direction = request.get("preset"), request.get("direction")
            if type(size) is not int or not 1 <= size <= 3 or type(direction) is not int or direction not in (-1, 1):
                raise OperationError("Invalid phone size preset")
            self.preferences.update(phoneSize=size, phoneSizeDirection=direction)
            save_json(self.data / "devices.json", self.preferences)
            self.model.update(phoneSize=size, phoneSizeDirection=direction)
        elif action == "open":
            self.stop_window()
            self.panel_open = True
            self.auto_suppressed = False
            self.cancel_reconnect()
            self.reconnect_attempts.clear()
            self.refresh_requested = True
            hosts = self.wireless_hosts()
            self.model.update(wirelessHost=hosts[0] if hosts else "", wirelessError="")
        elif action == "close":
            self.panel_open = False
            self.cancel_reconnect()
            self.cancel_qr()
            self.finish_recording()
            self.stop_mirror()
        elif action == "select":
            self.set_selection(request)
        elif action == "wirelessOpen":
            self.request_reconnect(18)
        elif action == "rename":
            self.rename_device(request)
        elif action == "window":
            self.start_window(request.get("token"))
        elif action == "start":
            self.auto_suppressed = True
            self.start_mirror()
            self.auto_suppressed = False
        elif action == "stop":
            self.auto_suppressed = True
            self.stop_mirror()
        elif action in {"audio", "keepAwake", "dim"}:
            self.model[action] = not self.model[action]
            if self.scrcpy is not None:
                self.start_mirror()
        elif action == "unlock":
            serial = self.serial()
            adb(serial, "shell", "input", "keyevent", 224)
            # Android prompts for authentication when the keyguard is secure.
            adb(serial, "shell", "wm", "dismiss-keyguard")
        elif action == "key":
            key = int(request.get("key", -1))
            if key not in {3, 4, 19, 20, 21, 22, 24, 25, 26, 61, 66, 67, 82, 92, 93, 112, 122, 123, 187, 224}:
                raise OperationError("Unsupported Android key")
            adb(self.serial(), "shell", "input", "keyevent", key)
        elif action == "gesture":
            if self.scrcpy is None or self.model["phase"] != "streaming":
                raise OperationError("Start the mirror before controlling the phone")
            if not natural_orientation(adb(self.serial(), "shell", "dumpsys", "input")):
                self.stop_mirror()
                self.auto_suppressed = True
                raise OperationError("Phone rotation changed; return to its natural orientation and restart the preview")
            width, height = self.model["sourceWidth"], self.model["sourceHeight"]
            values = request.get("points", [])
            if not isinstance(values, list) or len(values) != 4:
                raise OperationError("Invalid gesture")
            points = []
            for index, value in enumerate(values):
                if not isinstance(value, (int, float)) or not 0 <= value <= 1:
                    raise OperationError("Invalid gesture coordinates")
                size = width if index % 2 == 0 else height
                points.append(min(size - 1, int(value * size)))
            duration = max(50, min(3000, int(request.get("duration", 100))))
            if abs(points[0] - points[2]) < 8 and abs(points[1] - points[3]) < 8 and duration < 400:
                adb(self.serial(), "shell", "input", "tap", *points[:2])
            else:
                adb(self.serial(), "shell", "input", "swipe", *points, duration)
        elif action == "text":
            text = str(request.get("text", ""))
            if not text or len(text) > 1024 or any(ord(character) < 32 or ord(character) > 126 for character in text):
                raise OperationError("ADB input text supports 1..1024 printable ASCII characters")
            # ADB joins shell arguments remotely; quote the complete text word.
            if "%s" in text:
                raise OperationError("ADB cannot type a literal %s sequence; use the phone keyboard for this text")
            adb(self.serial(), "shell", "input", "text", shlex.quote(text.replace(" ", "%s")))
        elif action == "screenshot":
            self.screenshot()
        elif action == "record":
            self.finish_recording() if self.recorder is not None else self.start_recording()
        elif action in {"pair", "unpair", "ring", "browse", "share"}:
            self.kde_action(action, request)
        elif action in {"pairAdb", "connectAdb", "autoConnect", "qr"}:
            self.wireless(request)
        elif action == "cancelQr":
            self.cancel_qr()
        elif action != "refresh":
            raise OperationError("Unknown AndroidConnect action")

    def receive(self):
        requests = sorted(self.runtime.glob("*.json"))
        for path in requests[:1]:
            try:
                info = path.lstat()
                if not re.fullmatch(r"[0-9]+-[0-9]+\.json", path.name) or not stat.S_ISREG(info.st_mode) or info.st_size > 16384:
                    continue
                with path.open(encoding="utf-8") as source:
                    request = json.load(source)
                path.unlink()
                if not isinstance(request, dict):
                    raise OperationError("Invalid command")
                # Input carries the target it was generated for. A late release
                # must never control a different phone after device switching.
                if "target" in request and request["target"] != self.model["serial"]:
                    continue
                if "kdeTarget" in request and request["kdeTarget"] != self.model["selectedKde"]:
                    continue
                if request.get("action") in {"key", "gesture", "text", "unlock", "screenshot", "record", "start", "audio", "keepAwake", "dim", "window", "rename", "wirelessOpen", "autoConnect", "pairAdb", "connectAdb", "qr"}:
                    if not self.panel_open:
                        continue
                self.model["busy"] = True
                self.publish()
                self.handle(request)
                self.model["error"] = ""
            except (OperationError, OSError, ValueError, TypeError, subprocess.TimeoutExpired) as error:
                path.unlink(missing_ok=True)
                self.model["error"] = str(error)
                self.notice("errors.action", str(error), error=True)
                if self.model["phase"] == "starting":
                    self.stop_mirror()
                if path.exists():
                    path.unlink(missing_ok=True)
            finally:
                self.model["busy"] = False
                self.publish()

    def update_probe(self, result):
        if result.get("probeSelection", self.model["selectedKde"]) != self.model["selectedKde"]:
            return
        self.model.update(result)
        serial = self.resolved_serial()
        if serial != self.model["serial"]:
            self.finish_recording()
            self.stop_mirror()
            self.model["serial"] = serial
            self.auto_suppressed = False
        hosts = self.wireless_hosts()
        if hosts:
            self.model["wirelessHost"] = hosts[0]
        host = transport_host(serial, self.model.get("services", []))
        if serial and host and (not hosts or host in hosts):
            self.cancel_reconnect()
            address = serial if "._adb-tls-" not in serial else next(
                (item["endpoint"] for item in self.model.get("services", [])
                 if transport_host(serial, [item]) == host), "")
            if address:
                self.remember_wireless(address)
            self.model.update(wirelessState="connected", wirelessError="")
        elif (self.panel_open and self.model["configured"] and not serial and hosts and self.qr is None
              and self.reconnect is None and (self.selection_key(), tuple(hosts)) not in self.reconnect_attempts):
            self.request_reconnect()
        if self.model.get("phoneSerial") != serial:
            self.model["phone"] = {}
        if self.qr is not None:
            try:
                if not self.qr["host"]:
                    matches = [item for item in result["services"]
                               if item["name"] == self.qr["name"] and item["type"] == "_adb-tls-pairing._tcp"]
                    if len(matches) == 1:
                        output = run(["adb", "pair", matches[0]["endpoint"]], input=self.qr["secret"] + "\n", timeout=15)
                        if "Successfully paired" not in output:
                            raise OperationError("QR pairing was not confirmed by ADB")
                        self.qr["host"] = matches[0]["host"]
                matches = [item for item in result["services"] if item["host"] == self.qr["host"]
                           and item["type"] == "_adb-tls-connect._tcp"]
                if len(matches) == 1:
                    output = run(["adb", "connect", matches[0]["endpoint"]], timeout=10)
                    if "connected to" not in output:
                        raise OperationError(output or "ADB did not confirm connection")
                    self.remember_wireless(matches[0]["endpoint"])
                    self.auto_suppressed = False
                    self.cancel_qr()
                    self.notice("notice.connected")
            except OperationError as error:
                self.cancel_qr()
                self.notice("errors.action", str(error), error=True)
        self.publish()

    def tick(self):
        self.poll_reconnect()
        if self.window is not None and self.window.process.poll() is not None:
            if self.window.process.returncode:
                detail = self.window.error() or "scrcpy stopped"
                self.model["error"] = detail
                self.notice("errors.action", detail, error=True)
            self.stop_window()
            self.publish()
        if self.qr is not None and time.monotonic() >= self.qr["deadline"]:
            self.cancel_qr()
            self.notice("notice.qr_expired")
            self.publish()
        while not self.events.empty():
            kind, detail, frames = self.events.get_nowait()
            if frames is not self.frames:
                continue
            if kind == "ready":
                self.model["phase"] = "streaming"
            else:
                self.stop_mirror()
                self.model.update(phase="error", error=detail)
                self.auto_suppressed = True
                self.notice("errors.video", detail, error=True)
            self.publish()
        if self.scrcpy is not None and self.scrcpy.process.poll() is not None:
            detail = self.scrcpy.error()
            self.stop_mirror()
            self.model.update(phase="error", error=detail or "scrcpy stopped")
            self.auto_suppressed = True
            self.publish()
        if self.recorder is not None and self.recorder["process"].poll() is not None:
            self.finish_recording()
            self.publish()
        if self.frames is not None and self.frames.ever_connected and self.frames.client is None:
            if time.monotonic() - self.frames.last_client > 3:
                self.panel_open = False
                self.cancel_reconnect()
                self.stop_mirror()
                self.publish()
        if (self.panel_open and self.model["configured"] and self.config["auto_mirror"] and not self.auto_suppressed
                and self.model["serial"] and self.scrcpy is None):
            try:
                self.start_mirror()
            except (OperationError, OSError, subprocess.TimeoutExpired) as error:
                self.model.update(phase="error", error=str(error))
                self.auto_suppressed = True
                self.publish()

    def loop(self):
        self.publish()
        # Slow device/DBus probes cannot block incoming pointer commands.
        with ThreadPoolExecutor(max_workers=2) as pool:
            future = None
            next_probe = 0
            while not self.stopped:
                self.receive()
                self.tick()
                if self.reconnect is not None and "future" not in self.reconnect:
                    job = self.reconnect
                    job["future"] = pool.submit(connect_wireless, job["hosts"], job["cancel"], job["timeout"])
                now = time.monotonic()
                if future is not None and future.done():
                    try:
                        self.update_probe(future.result())
                    except Exception as error:
                        self.notice("errors.probe", str(error), error=True)
                    future = None
                if future is None and (now >= next_probe or self.refresh_requested):
                    self.refresh_requested = False
                    future = pool.submit(probe, self.model["selectedKde"], self.panel_open or self.qr is not None, self.model["serial"])
                    next_probe = now + 5
                time.sleep(0.05)
            self.cancel_reconnect()

    def close(self):
        self.stopped = True
        self.cancel_reconnect()
        self.cancel_qr()
        self.finish_recording()
        self.stop_mirror()
        self.stop_window()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", required=True, type=Path)
    args = parser.parse_args()
    runtime = os.environ.get("XDG_RUNTIME_DIR", "")
    if not runtime or not Path(runtime).is_absolute():
        parser.error("XDG_RUNTIME_DIR must identify a private runtime directory")
    info = Path(runtime).stat()
    if info.st_uid != os.geteuid() or info.st_mode & 0o077:
        parser.error("XDG_RUNTIME_DIR must be user-owned and inaccessible to other users")
    os.umask(0o077)
    args.data.mkdir(parents=True, exist_ok=True)
    with (args.data / "companion.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error("AndroidConnect is already running")
        with tempfile.TemporaryDirectory(prefix="androidconnect-", dir=runtime) as directory:
            bridge = Bridge(Path(directory), args.data)
            # Signal handlers only set a flag; they must not acquire a lock.
            signal.signal(signal.SIGINT, lambda *_: setattr(bridge, "stopped", True))
            signal.signal(signal.SIGTERM, lambda *_: setattr(bridge, "stopped", True))
            try:
                bridge.loop()
            finally:
                bridge.close()


if __name__ == "__main__":
    main()
