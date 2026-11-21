"""Read and update XDG user folder paths (user-dirs.dirs)."""

import re
from pathlib import Path

from .backups import replace_checked
from .paths import xdg_config_home

ENTRY = re.compile(r'^\s*XDG_([A-Z]+)_DIR\s*=\s*"(.*)"\s*$')
KEY = re.compile(r"^[A-Z]+$")


def config_path():
    return Path(xdg_config_home()) / "user-dirs.dirs"


def snapshot(text, revision):
    values = {}
    for line in text.splitlines():
        match = ENTRY.fullmatch(line)
        if match:
            values[match.group(1)] = match.group(2)
    return {"values": values, "revision": revision}


def validate_changes(changes):
    if not isinstance(changes, dict):
        raise ValueError("Changes must be an object.")
    for key, value in changes.items():
        if not isinstance(key, str) or not KEY.fullmatch(key) or not isinstance(value, str):
            raise ValueError("Invalid folder name or path.")
        if not value:
            continue
        if not (value == "$HOME" or value.startswith(("/", "$HOME/"))):
            raise ValueError(f"{key}: use an absolute path or $HOME/path.")
        remainder = value[5:] if value.startswith("$HOME") else value
        if any(char in remainder for char in '$`"\\\r\n') or "\0" in value:
            raise ValueError(f"{key}: path contains unsupported shell characters.")


def update_text(text, changes):
    output = []
    seen = set()
    for line in text.splitlines(keepends=True):
        match = ENTRY.fullmatch(line.rstrip("\r\n"))
        if match and match.group(1) in changes:
            key = match.group(1)
            seen.add(key)
            if changes[key]:
                output.append(f'XDG_{key}_DIR="{changes[key]}"\n')
        else:
            output.append(line)
    for key, value in changes.items():
        if key not in seen and value:
            if output and not output[-1].endswith(("\n", "\r")):
                output[-1] += "\n"
            output.append(f'XDG_{key}_DIR="{value}"\n')
    return "".join(output)


def save(path, backup_dir, expected_revision, changes):
    validate_changes(changes)
    return replace_checked(path, backup_dir, expected_revision, lambda text: update_text(text, changes),
                           "User folders")
