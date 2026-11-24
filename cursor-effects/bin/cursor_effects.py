#!/usr/bin/env python3
"""Apply Umbriel cursor theme / effect selections and print current state."""
import re
import subprocess
import sys
import tomllib
from pathlib import Path

HOME = Path.home()
CONFIG = HOME / ".config/umbriel/config.toml"
SHADERS = HOME / ".config/umbriel/shaders/community/cursor"


def read() -> str:
    return CONFIG.read_text(encoding="utf-8")


def section_block(text: str, section: str) -> tuple[int, int] | None:
    header = f"[{section}]"
    start = text.find(header)
    if start < 0:
        return None
    end = text.find("\n[", start + len(header))
    return start, (end if end >= 0 else len(text))


def get_key(section: str, key: str) -> str:
    text = read()
    block = section_block(text, section)
    if block is None:
        return ""
    chunk = text[block[0]:block[1]]
    match = re.search(rf"^\s*{re.escape(key)}\s*=\s*\"([^\"]*)\"", chunk, re.M)
    return match.group(1) if match else ""


def set_key(text: str, section: str, key: str, literal: str) -> str:
    block = section_block(text, section)
    if block is None:
        return text.rstrip() + f"\n\n[{section}]\n{key} = {literal}\n"
    start, end = block
    chunk = text[start:end]
    pattern = re.compile(rf"(^\s*{re.escape(key)}\s*=\s*)[^\n]*", re.M)
    if pattern.search(chunk):
        chunk = pattern.sub(lambda m: m.group(1) + literal, chunk, count=1)
    else:
        chunk = chunk.rstrip() + f"\n{key} = {literal}\n"
    return text[:start] + chunk + text[end:]


def ensure_include(text: str, effect: str) -> str:
    manifest = None
    if SHADERS.is_dir():
        for path in sorted(SHADERS.glob("*/effect.toml")):
            try:
                data = tomllib.loads(path.read_text(encoding="utf-8"))
            except Exception:
                continue
            if effect in data.get("effects", {}).get("preset", {}):
                manifest = path
                break
    if manifest is None:
        return text
    rel = manifest.relative_to(CONFIG.parent).as_posix()
    if f'"{rel}"' in text:
        return text
    match = re.search(r"(?ms)^\[include\]\s*\nfiles\s*=\s*\[(.*?)\]", text)
    if match is None:
        return text
    body = match.group(1).rstrip()
    return text[:match.start(1)] + body + f'\n    "{rel}",\n' + text[match.end(1):]




def main() -> int:
    if len(sys.argv) < 2:
        print("theme:", get_key("input.cursor", "theme"))
        print("effect:", get_key("effects", "cursor") or "off")
        return 0
    action = sys.argv[1]
    value = sys.argv[2] if len(sys.argv) > 2 else ""
    text = read()
    if action == "theme":
        text = set_key(text, "input.cursor", "theme", f'"{value}"')
    elif action == "effect":
        if value != "off":
            text = ensure_include(text, value)
        text = set_key(text, "effects", "cursor", '""' if value == "off" else f'"{value}"')
    else:
        return 1
    CONFIG.write_text(text, encoding="utf-8")
    subprocess.run(["umbriel", "msg", "config-reload"], check=False)
    if action == "effect":
        subprocess.run(["umbriel", "msg", "effect-cursor-set", value or "off"], check=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
