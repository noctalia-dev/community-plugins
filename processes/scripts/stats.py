# Some code was taken from ps_mem.py, which is licensed under LGPLv2.
# Licence: LGPLv2
# Author:  P@draigBrady.com
# Source:  https://www.pixelbeat.org/scripts/ps_mem.py

import os
import sys
import traceback
import json

# The following exits cleanly on Ctrl-C or EPIPE
# while treating other exceptions as before.
def std_exceptions(etype, value, tb):
    sys.excepthook = sys.__excepthook__
    save_path = os.environ.get("XDG_RUNTIME_DIR", "/dev/shm")
    if os.path.exists(f"{save_path}/noctalia_tordex_procs.json"):
        os.remove(f"{save_path}/noctalia_tordex_procs.json")

    if issubclass(etype, KeyboardInterrupt) or issubclass(etype, IOError) and value.errno == errno.EPIPE:
        print("tordex/procs:done:" + json.dumps({"status": "ok", "message": "Interrupted by user"}))
    else:
        #sys.__excepthook__(etype, value, tb)
        tb_lines = traceback.format_exception(value)
        print("tordex/procs:done:" + json.dumps({"status": "error", "message": "".join(tb_lines)}))


sys.excepthook = std_exceptions


import errno
import json
import time
import subprocess
import gi
import psutil
import pwd
from pathlib import Path
import draw_graph
import proc

gi.require_version('Gio', '2.0')
gi.require_version('GioUnix', '2.0')
gi.require_version('Gtk', '3.0')

from gi.repository import Gio, GioUnix
from gi.repository import Gtk

self_pid = os.getpid()
self_uid = os.getuid()

g_default_icon_path = None
g_default_icon_size = 0

def get_icon_path(icon_name, size=24):
    theme = Gtk.IconTheme.get_default()
    icon_info = theme.lookup_icon(icon_name, size, Gtk.IconLookupFlags.USE_BUILTIN)
    if icon_info:
        return icon_info.get_filename()
    return None

def icon_path(icon_name, size=24):
    global g_default_icon_path, g_default_icon_size

    path = get_icon_path(icon_name, size)
    if path:
        return path

    parts = icon_name.split('-')
    if len(parts) > 1:
        # Try to find a more generic icon by removing the last part
        generic_icon_name = '-'.join(parts[:-1])
        path = get_icon_path(generic_icon_name, size)
        if path:
            return path
    if len(parts) > 2:
        # Try to find a more generic icon by removing the last two parts
        generic_icon_name = '-'.join(parts[:-2])
        path = get_icon_path(generic_icon_name, size)
        if path:
            return path

    # Check if we have a cached default icon for the requested size
    if g_default_icon_path is not None and g_default_icon_size == size:
        return g_default_icon_path

    # Fallback to a default icon if the specific icon is not found
    default_icon_name = "application-x-executable"  # You can change this to any default icon you prefer
    g_default_icon_path = get_icon_path(default_icon_name, size)
    g_default_icon_size = size
    return g_default_icon_path  # Return None if no icon is found


proc = proc.Proc()

proc_disk_io = {}
proc_ticks = {}
num_cpus = os.cpu_count() or 1
cpu_idle_time = 0
cpu_total_time = 0

cpu_idle_time, cpu_total_time = proc.get_cpu_times()

g_order_by = "mem"
g_show_user_processes = True
g_search_query = ""

def get_distro_info():
    distro_name = None
    distro_version = None
    pretty_name = None
    icon_path = None
    try:
        candidates = ["/etc/os-release", "/usr/lib/os-release"]
        for file_path in candidates:
            if os.path.exists(file_path):
                with open(file_path, "r") as f:
                    for line in f:
                        if line.startswith("NAME="):
                            distro_name = line.strip().split("=")[1].strip('"')
                        elif line.startswith("VERSION="):
                            distro_version = line.strip().split("=")[1].strip('"')
                        elif line.startswith("PRETTY_NAME="):
                            pretty_name = line.strip().split("=")[1].strip('"')
                        elif line.startswith("LOGO="):
                            icon_path = line.strip().split("=")[1].strip('"')
                break
    except FileNotFoundError:
        pass
    if icon_path is not None:
        icon_path = get_icon_path(icon_path, 100)

    if pretty_name is None and distro_name is not None:
        pretty_name = distro_name
        if distro_version is not None:
            pretty_name += f" {distro_version}"

    return {
        "distro_name": distro_name,
        "distro_version": distro_version,
        "pretty_name": pretty_name,
        "icon_path": icon_path
    }

kernel_version = None
cpu_name = None
board_name = None
board_vendor = None
g_username = None
g_uid = None

def get_system_stats():
    global cpu_idle_time, cpu_total_time, kernel_version, cpu_name, board_name, board_vendor, g_username, g_uid, self_uid
    # CPU Load
    idle_time, total_time = proc.get_cpu_times()
    idle_delta = idle_time - cpu_idle_time
    total_delta = total_time - cpu_total_time

    if total_delta == 0:
        cpu_percent = 0.0
    else:
        cpu_percent = (1.0 - idle_delta / total_delta) * 100

    cpu_idle_time = idle_time
    cpu_total_time = total_time

    cpu_temp = "N/A"
    try:
        temps = psutil.sensors_temperatures()
        if temps:
            # Look for a CPU sensor among the available ones
            for name in ("coretemp", "k10temp", "cpu_thermal", "cpu-thermal"):
                if name in temps and temps[name]:
                    cpu_temp = f"{int(temps[name][0].current)}°"
                    break
            if cpu_temp == "N/A":
                first_entry = next(iter(temps.values()))[0]
                cpu_temp = f"{int(first_entry.current)}°"
    except (AttributeError, KeyError, IndexError):
        pass

    # Memory
    mem = psutil.virtual_memory()

    # Get system uptime
    try:
        with open("/proc/uptime", "r") as f:
            uptime_seconds = float(f.readline().split()[0])
    except (FileNotFoundError, ValueError):
        uptime_seconds = None

    # Get kernel version
    if kernel_version is None:
        try:
            kernel_version = os.uname().release
        except AttributeError:
            kernel_version = None

    # Get CPU name
    global cpu_name
    if cpu_name is None:
        try:
            with open("/proc/cpuinfo", "r") as f:
                for line in f:
                    if line.startswith("model name"):
                        cpu_name = line.split(":", 1)[1].strip()
                        break
        except FileNotFoundError:
            pass

    # Get board name (if available)
    if board_name is None:
        try:
            with open("/sys/devices/virtual/dmi/id/board_name", "r") as f:
                board_name = f.readline().strip()
        except FileNotFoundError:
            pass

    # Get board vendor (if available)
    if board_vendor is None:
        try:
            with open("/sys/devices/virtual/dmi/id/board_vendor", "r") as f:
                board_vendor = f.readline().strip()
        except FileNotFoundError:
            pass

    board = f"{board_vendor} {board_name}" if board_vendor and board_name else None
    if board is None and board_name is not None:
        board = board_name

    if g_username is None:
        g_uid = self_uid
        try:
            g_username = pwd.getpwuid(g_uid).pw_name
        except KeyError:
            g_username = "<unknown>"

    return {
        "cpu_percent": cpu_percent,
        "cpu_temp": cpu_temp,
        "mem_percent": mem.percent,
        "mem_used": mem.used,
        "mem_free": mem.total - mem.used,
        "uptime": uptime_seconds,
        "kernel_version": kernel_version,
        "cpu_name": cpu_name,
        "board": board,
        "uid": g_uid,
        "username": g_username,
    }


def sort_processes(processes):
    global g_order_by
    if g_order_by.startswith("-"):
        key = g_order_by[1:]
        reverse = False
    else:
        key = g_order_by
        reverse = True

    if key in ["name", "username"]:
        def_val = ""
    else:
        def_val = 0

    keys_to_keep = ["pid", "key", "uid", "ppid", "name", "username", "icon", "cpu", "io_read", "io_write", "io", "mem", "swap", "processes", "shared", "private"]
    out_processes = []
    for process in processes:
        out_process = {k: process[k] for k in keys_to_keep if k in process}
        out_processes.append(out_process)

    return sorted(out_processes, key=lambda p: (
        p.get(key, def_val) if p.get(key, None) is not None else def_val,
        p.get("name", None) if p.get("name", None) is not None else ""
    ), reverse=reverse)

def filter_process(process):
    global g_search_query, g_show_user_processes, self_uid
    if g_search_query == "":
        return True
    g_search_query_lower = g_search_query.lower()

    if g_show_user_processes and process["uid"] != self_uid:
        return False

    if not g_show_user_processes and process["uid"] == self_uid:
        return False

    try:
        num = int(g_search_query_lower)
        if process["pid"] != num and process["ppid"] != num:
            return False
        return True
    except ValueError:
        pass

    search_fields = ["name", "cmdline", "exe", "comm", "username"]

    for field in search_fields:
        value = process.get(field, "")
        if field == "cmdline":
            value = " ".join(value)
        if g_search_query_lower in str(value).lower():
            return True

    return False


g_next_id = 1
g_icons = {}

def reset_icons_cache():
    global g_icons, g_next_id
    g_icons = {}
    g_next_id = 1

def get_icons():
    global g_icons
    return {v: k for k, v in g_icons.items()}

def get_icon_id(path):
    global g_icons, g_next_id

    if path in g_icons:
        return g_icons[path]
    ret = str(g_next_id)
    g_icons[path] = ret
    g_next_id += 1
    return ret

def fetch_processes(interval: float):
    processes = {}
    num_user_processes = 0
    num_system_processes = 0
    for pid in os.listdir(proc.path("")):
        if not pid.isdigit():
            continue
        pid = int(pid)

        if pid == self_pid:
            continue

        exe = proc.get_exe(pid)
        cmdline = proc.get_cmdline(pid)
        comm = proc.get_name(pid)

        if exe is None:
            if len(cmdline) > 0:
                exe = cmdline[0]
        if exe is not None:
            name = os.path.basename(exe)
        else:
            name = comm

        if name is None:
            continue

        cpu_ticks = proc.get_cpu_ticks(pid)
        if cpu_ticks["system_ticks"] is None or cpu_ticks["ticks"] is None:
            continue

        io_bytes = proc.get_io_bytes(pid)

        ppid = proc.get_ppid(pid)
        if ppid is None:
            continue

        # Calculate CPU usage percentage based on the difference in ticks since the last measurement
        if pid in proc_ticks:
            prev_ticks = proc_ticks[pid]["ticks"]
            prev_system_ticks = proc_ticks[pid]["system_ticks"]
            delta_ticks = cpu_ticks["ticks"] - prev_ticks
            delta_system_ticks = cpu_ticks["system_ticks"] - prev_system_ticks
            if delta_system_ticks > 0:
                cpu_usage_percent = (delta_ticks / delta_system_ticks) * 100 #* num_cpus
            else:
                cpu_usage_percent = 0.0
        else:
            cpu_usage_percent = 0.0
        proc_ticks[pid] = {
            "ticks": cpu_ticks["ticks"],
            "system_ticks": cpu_ticks["system_ticks"]
        }

        if pid in proc_disk_io:
            prev_read_b = proc_disk_io[pid]["read_b"]
            prev_write_b = proc_disk_io[pid]["write_b"]
            delta_read_b = io_bytes["read_b"] - prev_read_b
            delta_write_b = io_bytes["write_b"] - prev_write_b
        else:
            delta_read_b = 0
            delta_write_b = 0
        proc_disk_io[pid] = {
            "read_b": io_bytes["read_b"],
            "write_b": io_bytes["write_b"]
        }

        proc_data = proc.get_mem_stats(pid)
        if proc_data["private"] == 0 and proc_data["shared"] == 0 and proc_data["swap"] == 0 and proc_data["mem"] == 0:
            continue

        uid = proc.get_uid(pid)
        if uid == -1:
            continue
        try:
            username = pwd.getpwuid(uid).pw_name
        except KeyError:
            username = "<unknown>"

        if uid == self_uid:
            num_system_processes += 1
        else:
            num_user_processes += 1

        proc_data.update({
            "pid": pid,
            "key": str(pid),
            "ppid": ppid,
            "exe": exe,
            "name": name,
            "comm": comm,
            "uid": uid,
            "username": username,
            "icon": get_icon_id(icon_path(name, 24)),
            "cmdline": cmdline,
            "cpu": round(cpu_usage_percent, 1),
            "io_read": int(delta_read_b / interval),
            "io_write": int(delta_write_b / interval),
            "io": int((delta_read_b + delta_write_b) / interval)
        })
        if filter_process(proc_data):
            processes[pid] = proc_data

    return processes, num_system_processes, num_user_processes

app_name_cache = {}

def get_app_icon(app_info, app_id, icon_size: int = 24):
    icon = app_info.get_icon()
    icon_name = icon.to_string() if icon else app_id
    return icon_path(icon_name, icon_size)

def get_app_name(app_id: str, icon_size: int = 24):
    if app_id in app_name_cache:
        return app_name_cache[app_id]["name"], app_name_cache[app_id]["icon"]

    desktop_file = f"{app_id}.desktop" if not app_id.endswith(".desktop") else app_id

    try:
        app_info = GioUnix.DesktopAppInfo.new(desktop_file)
    except TypeError:
        app_name_cache[app_id] = {
            "name": app_id,
            "icon": icon_path(app_id, icon_size)
        }
        return app_name_cache[app_id]["name"], app_name_cache[app_id]["icon"]

    if app_info:
        app_name_cache[app_id] = {
            "name": app_info.get_name(),
            "icon": get_app_icon(app_info, app_id, icon_size)
        }
        return app_name_cache[app_id]["name"], app_name_cache[app_id]["icon"]
    else:
        for app in Gio.AppInfo.get_all():
            if isinstance(app, GioUnix.DesktopAppInfo):
                wm_class = app.get_startup_wm_class()
                if wm_class and wm_class.lower() == app_id.lower():
                    app_name_cache[app_id] = {
                        "name": app.get_name(),
                        "icon": get_app_icon(app, app_id, icon_size)
                    }
                    return app_name_cache[app_id]["name"], app_name_cache[app_id]["icon"]
    app_name_cache[app_id] = {
        "name": app_id,
        "icon": icon_path(app_id, icon_size)
    }
    return app_name_cache[app_id]["name"], app_name_cache[app_id]["icon"]


def fill_app_processes(pid: int, app_procs: dict, processes: dict):
    if pid in app_procs or pid not in processes:
        return

    app_procs[pid] = processes[pid]

    for proc_pid, proc_data in processes.items():
        if proc_data["ppid"] == pid:
            fill_app_processes(proc_pid, app_procs, processes)


def fetch_niri_applications(processes: dict):
    try:
        p = subprocess.run(["niri", "msg", "--json", "windows"], capture_output=True)
        if p.returncode != 0:
            return []
    except FileNotFoundError:
        return []

    try:
        niri_windows = json.loads(p.stdout.decode())
    except json.JSONDecodeError:
        return []

    windows = []
    for window in niri_windows:
        app_id = window.get("app_id") or window.get("title") or "Unknown"
        windows.append({
            "app_id": app_id,
            "pid": window["pid"]
        })

    return windows


def fetch_umbriel_applications(processes: dict):
    try:
        p = subprocess.run(["umbriel", "windows", "--json"], capture_output=True)
        if p.returncode != 0:
            return []
    except FileNotFoundError:
        return []

    try:
        umbriel_windows = json.loads(p.stdout.decode())
    except json.JSONDecodeError:
        return []

    windows = []
    for window in umbriel_windows:
        app_id = window.get("app_id") or window.get("title") or "Unknown"
        windows.append({
            "app_id": app_id,
            "pid": window["pid"]
        })

    return windows

def fetch_hyprland_applications(processes: dict):
    try:
        p = subprocess.run(["hyprctl", "clients", "-j"], capture_output=True)
        if p.returncode != 0:
            return []
    except FileNotFoundError:
        return []

    try:
        hyprland_windows = json.loads(p.stdout.decode())
    except json.JSONDecodeError:
        return []

    windows = []
    for window in hyprland_windows:
        app_id = window.get("class") or window.get("title") or "Unknown"
        windows.append({
            "app_id": app_id,
            "pid": window["pid"]
        })

    return windows

def fetch_sway_applications(processes: dict):
    try:
        p = subprocess.run("swaymsg -t get_tree | jq '[.. | select(.pid? and .name?) | {app_id: (.app_id // .window_properties.class), pid: .pid}]'", capture_output=True, shell=True)
        if p.returncode != 0:
            return []
    except FileNotFoundError:
        return []

    try:
        sway_windows = json.loads(p.stdout.decode())
    except json.JSONDecodeError:
        return []

    windows = []
    for window in sway_windows:
        app_id = window.get("app_id") or "Unknown"
        windows.append({
            "app_id": app_id,
            "pid": window["pid"]
        })

    return windows

def fetch_scroll_applications(processes: dict):
    try:
        p = subprocess.run("scrollmsg -t get_tree | jq '[.. | select(.pid? and .name?) | {app_id: (.app_id // .window_properties.class), pid: .pid}]'", capture_output=True, shell=True)
        if p.returncode != 0:
            return []
    except FileNotFoundError:
        return []

    try:
        scroll_windows = json.loads(p.stdout.decode())
    except json.JSONDecodeError:
        return []

    windows = []
    for window in scroll_windows:
        app_id = window.get("app_id") or "Unknown"
        windows.append({
            "app_id": app_id,
            "pid": window["pid"]
        })

    return windows


def fetch_mango_applications(processes: dict):
    try:
        p = subprocess.run(["mmsg", "get", "all-clients"], capture_output=True)
        if p.returncode != 0:
            return []
    except FileNotFoundError:
        return []

    try:
        mango_windows = json.loads(p.stdout.decode())
    except json.JSONDecodeError:
        return []

    if mango_windows.get("clients") is None:
        return []

    windows = []
    for window in mango_windows["clients"]:
        app_id = window.get("appid") or "Unknown"
        windows.append({
            "app_id": app_id,
            "pid": window["pid"]
        })

    return windows


def fetch_applications(processes: dict):
    xdg_current_desktop = os.environ.get("XDG_CURRENT_DESKTOP")
    xdg_current_desktop = xdg_current_desktop.lower().split(':')

    windows = []
    if "niri" in xdg_current_desktop:
        windows = fetch_niri_applications(processes)
    elif "umbriel" in xdg_current_desktop:
        windows = fetch_umbriel_applications(processes)
    elif "hyprland" in xdg_current_desktop:
        windows = fetch_hyprland_applications(processes)
    elif "sway" in xdg_current_desktop:
        windows = fetch_sway_applications(processes)
    elif "scroll" in xdg_current_desktop:
        windows = fetch_scroll_applications(processes)
    elif "mango" in xdg_current_desktop:
        windows = fetch_mango_applications(processes)

    if len(windows) == 0:
        return {}

    ret = {}
    for window in windows:
        app_id = window["app_id"]
        if app_id not in ret:
            app_name, app_icon = get_app_name(app_id)
            ret[app_id] = {
                "name": app_name,
                "key": app_id,
                "icon": get_icon_id(app_icon),
                "processes": {}
            }
        fill_app_processes(window["pid"], ret[app_id]["processes"], processes)

    for _, app_data in ret.items():
        app_data["processes"] = sort_processes(app_data["processes"].values())

    return ret


def update_apps_metrics(apps: dict):
    for _, app_data in apps.items():
        total_mem = 0
        total_cpu = 0.0
        total_read_b_sec = 0
        total_write_b_sec = 0
        total_io = 0
        total_swap = 0
        username = None

        for proc_data in app_data["processes"]:
            total_mem += proc_data.get("mem", 0)
            total_cpu += proc_data.get("cpu", 0.0)
            total_read_b_sec += proc_data.get("io_read", 0)
            total_write_b_sec += proc_data.get("io_write", 0)
            total_io += proc_data.get("io", 0)
            total_swap += proc_data.get("swap", 0)
            if username is None:
                username = proc_data.get("username")
            else:
                if username != proc_data.get("username"):
                    username = ""

        if username == "":
            username = None

        app_data["mem"] = total_mem
        app_data["cpu"] = round(total_cpu, 1)
        app_data["io_read"] = total_read_b_sec
        app_data["io_write"] = total_write_b_sec
        app_data["io"] = total_io
        app_data["swap"] = total_swap
        app_data["username"] = username


def update_group_metrics(grouped_processes: dict):
    output_data = []
    for exe, procs in grouped_processes.items():
        if len(procs) == 1:
            output_data.append(procs[0])
            continue
        total_mem = 0
        total_cpu = 0.0
        total_read_b_sec = 0
        total_write_b_sec = 0
        total_io = 0
        total_swap = 0
        username = None

        for proc_data in procs:
            total_mem += proc_data.get("mem", 0)
            total_cpu += proc_data.get("cpu", 0.0)
            total_read_b_sec += proc_data.get("io_read", 0)
            total_write_b_sec += proc_data.get("io_write", 0)
            total_io += proc_data.get("io", 0)
            total_swap += proc_data.get("swap", 0)
            if username is None:
                username = proc_data.get("username")
            else:
                if username != proc_data.get("username"):
                    username = ""

        if username == "":
            username = None

        output_data.append({
            "name": os.path.basename(exe),
            "key": exe,
            "icon": procs[0]["icon"],
            "mem": total_mem,
            "cpu": round(total_cpu, 1),
            "io_read": total_read_b_sec,
            "io_write": total_write_b_sec,
            "io": total_io,
            "swap": total_swap,
            "username": username,
            "processes": sort_processes(procs),
        })
    return output_data


def group_processes(processes: dict):
    global self_uid
    user_processes = {}
    system_processes = {}
    for _, proc_data in processes.items():
        uid = proc_data["uid"]
        exe = proc_data["exe"]
        if uid != self_uid:
            if exe not in system_processes:
                system_processes[exe] = []
            system_processes[exe].append(proc_data)
        else:
            if exe not in user_processes:
                user_processes[exe] = []
            user_processes[exe].append(proc_data)

    return update_group_metrics(user_processes), update_group_metrics(system_processes)


def nofollow_opener(path, flags):
    return os.open(path, flags | os.O_NOFOLLOW)

g_params_file = os.environ.get("XDG_RUNTIME_DIR", "/dev/shm") + "/noctalia_tordex_procs_params"
g_params_file_timestamp = 0

def read_params():
    global g_order_by, g_params_file, g_show_user_processes, g_search_query, g_params_file_timestamp

    try:
        with open(g_params_file, "r") as f:
            g_order_by = f.readline().strip()
            g_show_user_processes = f.readline().strip() == "user"
            g_search_query = f.readline().strip()
        g_params_file_timestamp = os.path.getmtime(g_params_file)
    except FileNotFoundError:
        g_order_by = "mem"
        g_show_user_processes = True
        g_search_query = ""


def wait_for_order_by_file_change(timeout: float = 10.0, poll_interval: float = 0.2) -> bool:
    path = Path(g_params_file)
    start_time = time.monotonic()

    while time.monotonic() - start_time < timeout:
        time.sleep(poll_interval)
        if not path.exists():
            continue
        if g_params_file_timestamp == 0:
            continue
        try:
            current_mtime = path.stat().st_mtime
            if current_mtime != g_params_file_timestamp:
                return True
        except FileNotFoundError:
            continue

    return False


def main():
    global g_params_file, g_order_by, g_show_user_processes, g_search_query

    interval = (int)(sys.argv[1]) if len(sys.argv) > 1 else 1
    skin = sys.argv[2] if len(sys.argv) > 2 else "dark"

    save_path = os.environ.get("XDG_RUNTIME_DIR", "/dev/shm")

    while True:
        read_params()
        reset_icons_cache()
        processes, num_system_processes, num_user_processes = fetch_processes(interval)
        if g_search_query != "" or not g_show_user_processes:
            apps = {}
        else:
            apps = fetch_applications(processes)
            update_apps_metrics(apps)

        if g_search_query != "":
            user_processes, system_processes = [], []
        else:
            user_processes, system_processes = group_processes(processes)

        output_data = {
            "processes": [] if g_search_query == "" else sort_processes(processes.values()),
            "applications": sort_processes(apps.values()),
            "user_processes": [] if not g_show_user_processes else sort_processes(user_processes),
            "system_processes": [] if g_show_user_processes else sort_processes(system_processes),
            "total_processes": num_system_processes + num_user_processes,
            "num_system_processes": num_system_processes,
            "num_user_processes": num_user_processes,
            "icons": get_icons(),
        }
        output_data["system_stats"] = get_system_stats()
        output_data["distro_info"] = get_distro_info()

        user_processes = None
        system_processes = None
        apps = None
        processes = None

        cpu_graph_path = f"{save_path}/noctalia_tordex_procs_cpu_usage.png"
        mem_graph_path = f"{save_path}/noctalia_tordex_procs_mem_usage.png"


        # Draw CPU Usage Graph
        cpu_temp = output_data["system_stats"]["cpu_temp"]
        ret = draw_graph.draw_graph(
            percent=output_data["system_stats"]["cpu_percent"],
            val_text=f"{int(output_data['system_stats']['cpu_percent'])}%",
            label_text="CPU",
            sub_text=f"{cpu_temp}",
            skin=skin,
            filename=cpu_graph_path)
        if not ret:
            cpu_graph_path = None

        ret = draw_graph.draw_graph(
            percent=output_data["system_stats"]["mem_percent"],
            val_text=f"{round(output_data['system_stats']['mem_used'] / (1024 * 1024 * 1024), 1)}G",
            label_text="Memory",
            sub_text=f"+{round(output_data['system_stats']['mem_free'] / (1024 * 1024 * 1024), 1)}G",
            skin=skin,
            filename=mem_graph_path
        )
        if not ret:
            mem_graph_path = None

        if cpu_graph_path is not None:
            output_data["system_stats"]["cpu_graph_path"] = cpu_graph_path
        if mem_graph_path is not None:
            output_data["system_stats"]["mem_graph_path"] = mem_graph_path

        filename = f"{save_path}/noctalia_tordex_procs.json"
        try:
            with open(filename, "w", opener=nofollow_opener) as f:
                json.dump(output_data, f)
            print(f"tordex/procs:ready:{filename}", flush=True)
        except FileNotFoundError as e:
            print(f"tordex/procs:error:" + json.dumps({"message": f"Failed to write JSON file: {e}"}), flush=True)

        output_data = None
        wait_for_order_by_file_change(timeout=interval)

if __name__ == '__main__':
    print(f"tordex/procs:pid:{self_pid}")
    main()
