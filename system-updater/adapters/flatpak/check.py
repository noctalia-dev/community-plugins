import subprocess
import json
import re
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk

def get_icon_path(icon_name, size=48):
    theme = Gtk.IconTheme.get_default()
    icon_info = theme.lookup_icon(icon_name, size, Gtk.IconLookupFlags.USE_BUILTIN)
    if icon_info:
        return icon_info.get_filename()
    return None

def run_process(command, input_text=None):
    try:
        proc = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        stdout, _ = proc.communicate(input=input_text)
        return stdout.splitlines()
    except Exception as e:
        return []

def parse_flatpak_list_output(lines):
    apps = {}
    the_caption_line = True
    for line in lines:
        if the_caption_line:
            the_caption_line = False
            continue

        parts = line.split("\t")
        if len(parts) >= 4:
            app_id = parts[0].strip()
            apps[app_id] = {
                "name": parts[1].strip(),
                "description": parts[2].strip(),
                "version": parts[3].strip()
            }
    return apps

def get_real_flatpak_updates():
    # Run flatpak list --columns 'application,name,description,version'
    list_lines = run_process(["flatpak", "list", "--app", "--columns", "application,name,description,version"])
    # Parse the output of flatpak list to create a mapping of app_id to its details
    apps = parse_flatpak_list_output(list_lines)

    # Run flatpak list --app --columns 'application,name,description,version'
    remote_ls_lines = run_process(["flatpak", "remote-ls", "--updates", "--columns", "application,name,description,version"])
    # Parse the output of flatpak remote-ls to create a mapping of app_id to its details
    remote_ls_apps = parse_flatpak_list_output(remote_ls_lines)

    # Run flatpak update in non-interactive mode with an "n" (no) response
    # This makes flatpak print the exact table and exit immediately
    updates_lines = run_process(["flatpak", "update"], input_text="n\n")

    updates = []

    # Parse the output of flatpak update to extract the list of updates
    # And enrich them with the details from the apps mapping
    for line in updates_lines:
        line_str = line.strip()

        # Parse numbered lines (for example: "1. [i] org.mozilla.firefox stable flathub ...")
        if re.match(r'^\d+\.', line_str):
            # Remove the number and flags like [i], [u]
            cleaned = re.sub(r'^\d+\.\s*(\[\w+\]\s*)?', '', line_str)
            parts = cleaned.split()

            if len(parts) >= 1:
                app_id = parts[0].strip()
                if app_id in apps:
                    updates.append({
                        "id": app_id,
                        "name": apps[app_id]["name"],
                        "description": apps[app_id]["description"],
                        "icon": get_icon_path(app_id),
                        "from_version": apps[app_id]["version"],
                        "to_version": remote_ls_apps[app_id]["version"] if app_id in remote_ls_apps and remote_ls_apps[app_id]["version"] != apps[app_id]["version"] else ""
                    })

    updates.sort(key=lambda x: x["name"].lower())
    return {
        "info": "",
        "updates": updates
    }


if __name__ == "__main__":
    print(json.dumps(get_real_flatpak_updates(), indent=2, ensure_ascii=False))
