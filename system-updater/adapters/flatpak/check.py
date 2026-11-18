import subprocess
import json
import re
import os
import pty
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

def parse_flatpak_list_output(lines, remove_fist_slash):
    out = {}
    for line in lines:
        parts = line.split("\t")
        app_id = parts[0].strip()

        if remove_fist_slash:
            slash_index = app_id.find('/')
            if slash_index != -1:
                app_id = app_id[slash_index + 1:]

        out[app_id] = {
            "name": parts[1].strip() if len(parts) >= 2 else app_id,
            "description": parts[2].strip() if len(parts) >= 3 else app_id,
            "version": parts[3].strip() if len(parts) >= 4 else ""
        }
    return out

def get_app_ref(app_id, branch, apps):
    for key in apps.keys():
        parts = key.split('/')
        if len(parts) >= 3 and app_id == parts[0] and branch == parts[2]:
            return key
    return ""

def run_flatpak_update_interactive():
    # flatpak only reads stdin prompts when stdin is a tty, so use a pty instead of pipes
    master_fd, slave_fd = pty.openpty()
    env = os.environ.copy()
    # Force English language for consistent output
    env["LC_ALL"] = "C"
    env["LANG"] = "en_US.UTF-8"
    try:
        proc = subprocess.Popen(
            ["flatpak", "update"],
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            env=env,
            close_fds=True
        )
    except Exception:
        os.close(master_fd)
        os.close(slave_fd)
        return []
    os.close(slave_fd)

    output_chars = []
    buffer = ""

    while True:
        try:
            data = os.read(master_fd, 1)
        except OSError:
            # Reading from the master fd raises EIO once the slave side is closed
            break
        if not data:
            break

        char = data.decode(errors="replace")
        output_chars.append(char)
        buffer += char

        if buffer.endswith("Do you want to install it? [Y/n]:"):
            os.write(master_fd, b"y\n")
            buffer = ""
        elif re.search(r"Proceed with these changes to the .* \[Y/n\]:$", buffer):
            os.write(master_fd, b"n\n")
            buffer = ""

    os.close(master_fd)
    proc.wait()
    return "".join(output_chars).splitlines()


def get_real_flatpak_updates():
    # Update the appstream data to ensure we have the latest metadata before listing apps
    run_process(["flatpak", "update", "--appstream", "--noninteractive"])
    # Run flatpak list --columns 'application,name,description,version'
    list_lines = run_process(["flatpak", "list", "--columns", "ref,name,description,version"])
    # Parse the output of flatpak list to create a mapping of app_id to its details
    apps = parse_flatpak_list_output(list_lines, False)

    # Run flatpak list --app --columns 'application,name,description,version'
    remote_ls_lines = run_process(["flatpak", "remote-ls", "--updates", "--columns", "ref,name,description,version"])
    # Parse the output of flatpak remote-ls to create a mapping of app_id to its details
    remote_ls_apps = parse_flatpak_list_output(remote_ls_lines, True)

    # Run flatpak update in non-interactive mode with an "n" (no) response
    # This makes flatpak print the exact table and exit immediately
    updates_lines = run_flatpak_update_interactive()

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
                branch = parts[1].strip()
                app_ref = get_app_ref(app_id, branch, apps)
                if app_ref:
                    updates.append({
                        "id": app_ref,
                        "name": apps[app_ref]["name"],
                        "description": apps[app_ref]["description"],
                        "icon": get_icon_path(app_id),
                        "from_version": apps[app_ref]["version"],
                        "to_version": remote_ls_apps[app_ref]["version"] if app_ref in remote_ls_apps and remote_ls_apps[app_ref]["version"] != apps[app_ref]["version"] else ""
                    })

    updates.sort(key=lambda x: x["name"].lower())
    return {
        "info": "",
        "updates": updates
    }


if __name__ == "__main__":
    print(json.dumps(get_real_flatpak_updates(), indent=2, ensure_ascii=False))
