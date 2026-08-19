import subprocess
import json
import re
import sys

def get_updates_list():
    proc = subprocess.run(["bash", "-c", "cargo install-update --list 2>/dev/null | awk '$NF==\"Yes\"{print $1\"\t\"$2\"\t\"$3}'"], capture_output=True)
    if proc.returncode != 0:
        print(proc.stderr.decode(), file=sys.stderr)
        exit(1)
    stdout = proc.stdout.decode().strip()
    for line in stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 3:
            yield {
                "name": parts[0].strip(),
                "from_version": parts[1].strip(),
                "to_version": parts[2].strip()
            }

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

def get_package_description(package_name):
    proc = subprocess.run(["cargo", "-q", "info", package_name], capture_output=True)
    if proc.returncode != 0:
        print(proc.stderr.decode(), file=sys.stderr)
        exit(1)
    stdout = proc.stdout.decode().strip()
    lines = stdout.splitlines()
    if len(lines) >= 2:
        return lines[1].strip()  # The second line usually contains the description
    return ""


def package_kit_updates():

    out = []

    for update in get_updates_list():
        # Extract relevant information from the update dictionary
        pkg_info = get_package_info(update.get("name"))
        update_info = {
            "id": update.get("name"),
            "name": update.get("name"),
            "icon": "",  # Placeholder for icon path, as Cargo doesn't provide icons
            "glyph": "brand-rust",  # Placeholder glyph for Cargo packages
            "description": get_package_description(update.get("name")),
            "from_version": update.get("from_version", ""),
            "to_version": update.get("to_version", "")
        }
        out.append(update_info)

    out.sort(key=lambda x: x["name"].lower())
    return {
        "info": "",
        "updates": out
    }

if __name__ == "__main__":
    print(json.dumps(package_kit_updates(), indent=2, ensure_ascii=False))
