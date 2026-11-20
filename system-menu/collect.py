"""Collect a small, privacy-conscious system profile; never sample live usage."""

import json
import os
from pathlib import Path
import platform
import re
import socket
import subprocess


def run(argv, timeout=3):
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False)
        return result.stdout.strip() if result.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def read(path):
    try:
        return Path(path).read_text().strip()
    except (OSError, UnicodeError):
        return ""


def usable(value):
    value = str(value or "").strip()
    placeholders = ("to be filled", "o.e.m.", "default string", "not specified", "unknown", "system product name")
    return "" if any(item in value.lower() for item in placeholders) else value


def json_command(argv, default):
    try:
        return json.loads(run(argv))
    except (ValueError, TypeError):
        return default


def size_label(size, binary=False):
    size = float(size or 0)
    base = 1024 if binary else 1000
    units = ("B", "KiB", "MiB", "GiB", "TiB") if binary else ("B", "kB", "MB", "GB", "TB")
    for unit in units:
        if size < base or unit == units[-1]:
            return f"{size:.1f}".rstrip("0").rstrip(".") + " " + unit
        size /= base


def plural(count, one, many):
    word = one if count == 1 else many
    return f"{count} {word}"


def make_report(profile):
    lines = ["About This System", profile["hostname"], profile["subtitle"], ""]
    for section in [*profile["sections"], profile["details"]]:
        if not section["rows"]:
            continue
        lines.append(section["title"])
        for row in section["rows"]:
            detail = f" ({row['detail']})" if row.get("detail") else ""
            lines.append(f"{row['label']}: {row['value']}{detail}")
        lines.append("")
    return "\n".join(lines).strip()


def collect():
    results = json_command([
        "fastfetch", "--config", "none", "--structure", "OS:Host:CPU:Memory:GPU:Kernel:BIOS", "--format", "json",
    ], [])
    modules = {item["type"]: item["result"] for item in results if isinstance(item, dict) and "result" in item and "type" in item}
    release = platform.freedesktop_os_release()
    distro = modules.get("OS", {}).get("prettyName") or release.get("PRETTY_NAME", "Linux")
    version = modules.get("OS", {}).get("version") or release.get("VERSION_ID") or release.get("BUILD_ID", "")
    hardware = {"title": "Hardware", "icon": "cpu", "rows": []}
    software = {"title": "Software", "icon": "apps", "rows": []}
    disks = {"title": "Storage", "icon": "storage", "rows": []}
    details = {"title": "Technical Details", "icon": "settings", "rows": []}
    profile = {
        "hostname": socket.gethostname(),
        "subtitle": distro + (f" · {version}" if version and version.lower() not in distro.lower() else ""),
        "logo": str(Path(__file__).resolve().parent / "assets/system.svg"),
        "sections": [hardware, disks, software],
        "details": details,
        "warnings": [],
    }

    def add(section, label, value, detail=""):
        if value:
            section["rows"].append({"label": label, "value": str(value), "detail": detail})

    host = modules.get("Host", {})
    host_name = usable(host.get("name"))
    if host_name:
        add(hardware, "Model", host_name)
    board = usable(read("/sys/class/dmi/id/board_name"))
    vendor = usable(read("/sys/class/dmi/id/board_vendor"))
    add(hardware, "Motherboard", board, vendor)

    cpu = modules.get("CPU", {})
    cpu_name = cpu.get("cpu") or cpu.get("name")
    if not cpu_name:
        cpu_name = next((line.split(":", 1)[1].strip() for line in read("/proc/cpuinfo").splitlines() if line.startswith("model name")), "")
    cores = cpu.get("cores", {})
    topology = []
    if cores.get("physical"):
        topology.append(plural(cores["physical"], "core", "cores"))
    if cores.get("logical"):
        topology.append(plural(cores["logical"], "thread", "threads"))
    add(hardware, "Processor", cpu_name, " · ".join(topology))
    memory = modules.get("Memory", {}).get("total", 0)
    if not memory:
        match = re.search(r"^MemTotal:\s+(\d+)", read("/proc/meminfo"), re.MULTILINE)
        memory = int(match.group(1)) * 1024 if match else 0
    add(hardware, "Memory", size_label(memory, True) if memory else "", "Available to the operating system")

    for index, gpu in enumerate(modules.get("GPU", []), 1):
        notes = []
        card = re.search(r"\bcard\d+\b", gpu.get("platformApi", ""))
        if card:
            vram = read(f"/sys/class/drm/{card.group()}/device/mem_info_vram_total")
            if vram.isdigit() and int(vram) > 0:
                notes.append(size_label(int(vram), True) + " VRAM")
        add(hardware, "Graphics" if index == 1 else f"Graphics {index}", gpu.get("name"), " · ".join(notes))
        add(details, f"GPU {index} Driver", gpu.get("driver"))

    devices = json_command(["lsblk", "--json", "--bytes", "--nodeps", "--output", "NAME,MODEL,SIZE,TYPE,TRAN,RM,ROTA"], {}).get("blockdevices", [])
    devices = sorted((device for device in devices if device.get("type") == "disk" and not device["name"].startswith(("zram", "loop", "ram")) and int(device.get("size") or 0) > 0), key=lambda device: device["name"])
    for index, device in enumerate(devices, 1):
        connection = str(device.get("tran") or "").upper()
        kind = "HDD" if device.get("rota") else "SSD" if connection in ("NVME", "SATA", "SAS") else "Drive"
        note = size_label(device["size"]) + " · " + kind
        if connection:
            note += " " + ("NVMe" if connection == "NVME" else connection)
        add(disks, f"Drive {index}", usable(device.get("model")) or device["name"], note)
    if not disks["rows"]:
        profile["sections"].remove(disks)
        profile["warnings"].append("Could not read the list of physical drives.")

    add(software, "Operating System", profile["subtitle"].replace(" · ", " — "))
    add(software, "Linux Kernel", modules.get("Kernel", {}).get("release") or platform.release())
    add(software, "Desktop Session", os.environ.get("XDG_CURRENT_DESKTOP", ""))
    noctalia_version = run(["noctalia", "--version"])
    add(software, "Desktop Shell", noctalia_version.split(" (", 1)[0])
    session = "Wayland" if os.environ.get("WAYLAND_DISPLAY") else os.environ.get("XDG_SESSION_TYPE", "")
    add(software, "Display Protocol", session)
    add(details, "Architecture", modules.get("Kernel", {}).get("architecture") or platform.machine())
    firmware = modules.get("BIOS", {})
    add(details, "Firmware", " ".join(filter(None, [firmware.get("vendor"), firmware.get("version")])), firmware.get("type", ""))
    if not modules:
        profile["warnings"].append("Some hardware information is unavailable. Check that fastfetch is installed.")
    profile["report"] = make_report(profile)
    return profile


if __name__ == "__main__":
    print(json.dumps(collect(), ensure_ascii=False))
