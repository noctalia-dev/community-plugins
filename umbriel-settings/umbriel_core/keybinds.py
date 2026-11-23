"""Keybind groups, locks, option text, validation and comment-preserving [keybinds] writes."""

import json
import os
import re

import tomlkit

from .actions import ACTION_INFO, REQUIRED_ARG_ACTIONS
from .paths import LOCK_FILE_NAME, write_text_file
from .tomlops import MISSING, ensure_table, getp, header_re

# Known per-bind options with their own controls (anything else is preserved untouched).
BIND_BOOL_OPTIONS = [("repeat", "Repeat"), ("allow_when_locked", "When locked"),
                     ("allow_when_inhibited", "When inhibited")]
KEYBIND_GROUPS_MARKER = "# Umbriel Config GUI keybind groups: "


def lock_file(config_dir):
    """Return the keybind-lock file inside a per-config GUI data directory."""
    return os.path.join(config_dir, LOCK_FILE_NAME)


def load_locked(config_dir):
    """Return the set of keybind keys locked in the GUI."""
    try:
        with open(lock_file(config_dir), encoding="utf-8") as f:
            keys = json.load(f)
    except (OSError, ValueError):
        return set()
    return {key for key in keys if isinstance(key, str)} if isinstance(keys, list) else set()


def save_locked(keys, config_dir):
    """Write locked keybind keys to GUI data without touching the Umbriel config; raises OSError."""
    write_text_file(lock_file(config_dir), json.dumps(sorted(keys), indent=1), 0o600)


def parse_keybind_groups(text):
    """Read GUI-only keybind groups from the TOML comment metadata."""
    metadata = {}
    for line in text.splitlines():
        if line.startswith(KEYBIND_GROUPS_MARKER):
            try:
                parsed = json.loads(line[len(KEYBIND_GROUPS_MARKER):])
            except json.JSONDecodeError:
                continue
            if isinstance(parsed, dict):
                metadata = parsed
    names = metadata.get("groups", [])
    groups = []
    if isinstance(names, list):
        groups.extend(
            name.strip() for name in names
            if isinstance(name, str) and name.strip()
        )
    assignments = metadata.get("assignments", {})
    if not isinstance(assignments, dict):
        assignments = {}
    for group in assignments.values():
        if isinstance(group, str) and group.strip() and group.strip() not in groups:
            groups.append(group.strip())
    return groups, {
        key: group.strip()
        for key, group in assignments.items()
        if isinstance(key, str) and isinstance(group, str) and group.strip()
    }


def write_keybind_groups(text, groups, assignments):
    """Persist keybind group labels in an ignored TOML comment inside [keybinds].

    The comment is left out when keybinds exist without a [keybinds] header to put it under.
    """
    newline = "\r\n" if "\r\n" in text else "\n"
    lines = text.splitlines(keepends=True)
    lines = [
        line for line in lines
        if not line.lstrip().startswith(KEYBIND_GROUPS_MARKER)
    ]
    groups = list(dict.fromkeys(group.strip() for group in groups if group.strip()))
    assignments = {
        key: group for key, group in assignments.items()
        if key and group in groups
    }
    if not groups and not assignments:
        return "".join(lines)

    section_header = header_re("keybinds")
    start = next(
        (index for index, line in enumerate(lines) if section_header.match(line)),
        None,
    )
    if start is None:
        if "keybinds" in tomlkit.parse(text):
            # Written as dotted keys or an inline table: a [keybinds] header would declare it twice.
            return "".join(lines)
        if lines and not lines[-1].endswith(("\n", "\r")):
            lines[-1] += newline
        lines.append("[keybinds]" + newline)
        start = len(lines) - 1
    payload = json.dumps(
        {"groups": groups, "assignments": assignments},
        ensure_ascii=False,
        separators=(",", ":"),
    )
    lines.insert(start + 1, KEYBIND_GROUPS_MARKER + payload + newline)
    return "".join(lines)


def normalize_shortcut(key):
    """Compare shortcuts case- and whitespace-insensitively."""
    return " ".join(key.casefold().split())


def check_shortcut_conflicts(keys):
    """Raise ValueError when two shortcuts are the same after normalization."""
    seen = {}
    for key in keys:
        key = key.strip()
        if not key:
            continue
        normalized = normalize_shortcut(key)
        if normalized in seen:
            raise ValueError(f'Keybind conflict: "{key}" duplicates shortcut "{seen[normalized]}".')
        seen[normalized] = key


def check_action(key, action):
    """Raise ValueError when an action is incomplete (bare spawn, leftover <arg>, missing argument)."""
    words = action.split()
    if words and words[0] == "spawn" and (len(words) == 1 or action.strip() == "spawn <cmd...>"):
        raise ValueError(f'Keybind "{key}": write a command after "spawn".')
    if re.search(r"<[^>]+>", action) and words and words[0] != "spawn":
        raise ValueError(f'Keybind "{key}": "{action}" still needs its argument (replace the <...> part).')
    if len(words) == 1 and words[0] in REQUIRED_ARG_ACTIONS:
        raise ValueError(f'Keybind "{key}": "{action}" needs an argument, e.g. "{ACTION_INFO[words[0]][0]}".')


def read_bindings(doc, path=("keybinds",)):
    """Return {key: (action, options)} from a parsed document; non-action values are skipped."""
    table = getp(doc, path)
    out = {}
    if table is MISSING or not hasattr(table, "items"):
        return out
    for key, value in table.items():
        plain = value.unwrap() if hasattr(value, "unwrap") else value
        if isinstance(plain, str):
            out[key] = (plain, {})
        elif isinstance(plain, dict) and isinstance(plain.get("action"), str):
            out[key] = (plain["action"], {k: v for k, v in plain.items() if k != "action"})
    return out


def apply_bindings(doc, rows, original, locked, path=("keybinds",)):
    """Write `rows` ({key: (action, opts)}, in display order) into the table.

    Only changed or added keys are rewritten; removed keys are deleted unless locked; the table is
    reordered to match `rows` while comments stay in place.
    """
    if not rows and getp(doc, path) is MISSING:
        return
    tbl = ensure_table(doc, path)
    for k in list(tbl.keys()):
        if k not in rows and k not in locked:  # locked binds are never deleted
            del tbl[k]
    for k, (a, o) in rows.items():
        if original.get(k) == (a, o) and k in tbl:
            continue
        if o:
            it = tomlkit.inline_table()
            it["action"] = a
            for x, y in o.items():
                it[x] = y
            tbl[k] = it
        else:
            tbl[k] = a
    reorder_table(tbl, list(rows))


def reorder_table(table, order):
    """Reorder key/value slots to match `order` while keeping comments in place."""
    container = table.value
    body = container.body
    entries = {key.key: (key, value) for key, value in body if key is not None}
    positions = [index for index, (key, _) in enumerate(body) if key is not None]
    ordered_keys = [key for key in order if key in entries]
    ordered_keys.extend(key for key in container if key not in ordered_keys)
    if not positions or ordered_keys == [key.key for key, _ in body if key is not None]:
        return
    values = {key: dict.__getitem__(container, key) for key in ordered_keys}
    for position, key_name in zip(positions, ordered_keys, strict=False):
        body[position] = entries[key_name]
    container._map.clear()
    for index, (key, _) in enumerate(body):
        if key is not None:
            container._map[key] = index
    dict.clear(container)
    for key_name in ordered_keys:
        dict.__setitem__(container, key_name, values[key_name])
