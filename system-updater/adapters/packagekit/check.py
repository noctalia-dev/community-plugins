import subprocess
import json
import re
import sys
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk

def get_icon_path(icon_name, size=48):
    theme = Gtk.IconTheme.get_default()
    icon_info = theme.lookup_icon(icon_name, size, Gtk.IconLookupFlags.USE_BUILTIN)
    if icon_info:
        return icon_info.get_filename()
    return None

def icon_path(icon_name, size=48):
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
    
    # Fallback to a default icon if the specific icon is not found
    #default_icon_name = "application-x-executable"  # You can change this to any default icon you prefer
    #return get_icon_path(default_icon_name, size)
    return None  # Return None if no icon is found

def refresh_updates():
    proc = subprocess.run(["pkgcli", "refresh", "force"], capture_output=True)
    if proc.returncode != 0:
        print(proc.stderr.decode(), file=sys.stderr)
        exit(1)

def get_updates_list():
    proc = subprocess.run(["pkgcli", "list-updates", "--json"], capture_output=True)
    if proc.returncode != 0:
        print(proc.stderr.decode(), file=sys.stderr)
        exit(1)
    return [json.loads(line) for line in proc.stdout.decode().splitlines() if line.strip()]

def get_package_info(package_name):
    try:
        proc = subprocess.Popen(
            ["pkgcli", "show", package_name, "--json", "--filter=newest;installed"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        stdout, _ = proc.communicate(input="1\n")
        lines = stdout.splitlines()
        if len(lines) == 1:
            return json.loads(lines[0])
        for line in lines[1:]:
            index = line.find("{")
            if index != -1:
                line = line[index:]
                return json.loads(line)
        return {
            "summary": "",
            "version": ""
        }
    except Exception as e:
        return {
            "summary": "",
            "version": ""
        }

def check_offline_update_status():
    proc = subprocess.run(["pkgcli", "-q", "offline-update", "status", "--json"], capture_output=True)
    if proc.returncode != 0:
        print(proc.stderr.decode(), file=sys.stderr)
        exit(1)
    stdout = proc.stdout.decode().strip()
    lines = stdout.splitlines()
    if len(lines) >= 1:
        data = json.loads(lines[0])  # Validate JSON
        if data.get("info", "").find("reboot") != -1:
            return data.get("info", "")
    return ""


def package_kit_updates():

    info = check_offline_update_status()
    if info != "":
        return {
            "info": info,
            "info_key": "info_reboot_required",
            "actions": [
                {
                    "name": "Cancel",
                    "tip": "Cancel the offline update process",
                    "command": "cancel"
                },
                {
                    "name": "Reboot",
                    "tip": "Reboot the system to complete the offline update process",
                    "command": "reboot"
                }
            ],
            "updates": []
        }

    refresh_updates()

    updates = get_updates_list()

    out = []

    for update in updates:
        # Extract relevant information from the update dictionary
        pkg_info = get_package_info(update.get("name"))
        update_info = {
            "id": update.get("name"),
            "name": update.get("name"),
            "icon": icon_path(update.get("name")),
            "description": pkg_info.get("summary", ""),
            "from_version": pkg_info.get("version", ""),
            "to_version": update.get("version", "")
        }
        out.append(update_info)

    out.sort(key=lambda x: x["name"].lower())
    return {
        "info": "",
        "updates": out
    }

if __name__ == "__main__":
    print(json.dumps(package_kit_updates(), indent=2, ensure_ascii=False))
