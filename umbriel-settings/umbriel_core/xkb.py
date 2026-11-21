"""Keyboard layouts, variants and options known to XKB (from `rules/evdev.lst`), for the layout picker."""

import os
import re

_cache = {}


def rules_file(environ=None):
    """Path of XKB's evdev rule list (`$XKB_CONFIG_ROOT` first)."""
    env = os.environ if environ is None else environ
    root = env.get("XKB_CONFIG_ROOT") or "/usr/share/X11/xkb"
    return os.path.join(root, "rules", "evdev.lst")


def parse(text):
    """{layouts: [{name, desc}], variants: {layout: [{name, desc}]}, options: [{name, desc, items}]}."""
    layouts, variants, options = [], {}, []
    section = None
    for line in text.splitlines():
        if line.startswith("!"):
            section = line[1:].strip()
            continue
        name, _, desc = line.strip().partition(" ")
        desc = desc.strip()
        if not name:
            continue
        if section == "layout":
            layouts.append({"name": name, "desc": desc or name})
        elif section == "variant":
            layout, _, desc = desc.partition(":")
            variants.setdefault(layout.strip(), []).append({"name": name, "desc": desc.strip() or name})
        elif section == "option":
            if ":" in name:
                # an option belongs to the group above it, whatever its prefix (`compat` holds `misc:`, ...)
                if options:
                    options[-1]["items"].append({"name": name, "desc": desc or name})
            else:
                # group names may hold a space ("Compose key"): the columns are two or more spaces apart
                name, desc = (re.split(r"\s{2,}", line.strip(), maxsplit=1) + [""])[:2]
                options.append({"name": name, "desc": desc.strip() or name, "items": []})
    return {"layouts": layouts, "variants": variants, "options": [group for group in options if group["items"]]}


def catalog(path=None):
    """The parsed rule list (cached per file modification time); empty lists when it can't be read."""
    path = path or rules_file()
    try:
        stamp = os.stat(path).st_mtime_ns
    except OSError:
        return {"layouts": [], "variants": {}, "options": []}
    cached = _cache.get(path)
    if cached and cached[0] == stamp:
        return cached[1]
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            result = parse(handle.read())
    except OSError:
        return {"layouts": [], "variants": {}, "options": []}
    _cache[path] = (stamp, result)
    return result
