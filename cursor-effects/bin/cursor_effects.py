#!/usr/bin/env python3
"""Apply Umbriel cursor theme and shader effect selections.

Edits the Umbriel config in place, validates the result with tomllib and replaces the
file atomically. Requires Python 3.11+.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

HOME = Path.home()
CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME") or HOME / ".config")
CONFIG = CONFIG_DIR / "umbriel" / "config.toml"
SHADERS = CONFIG_DIR / "umbriel" / "shaders" / "community" / "cursor"


def toml_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


HEADER = re.compile(r"^\[\s*([^\[\]]+?)\s*\]\s*(?:#.*)?$")


def header_section(line: str) -> str | None:
    match = HEADER.match(line.strip())
    return match.group(1).strip() if match else None


def section_bounds(lines: list[str], section: str) -> tuple[int, int] | None:
    start = None
    for index, line in enumerate(lines):
        if header_section(line) == section:
            start = index
            break
    if start is None:
        return None
    end = len(lines)
    for index in range(start + 1, len(lines)):
        stripped = lines[index].strip()
        if stripped.startswith("[") and not stripped.startswith("#"):
            end = index
            break
    return start, end


def set_key(text: str, section: str, key: str, literal: str) -> str:
    lines = text.splitlines()
    bounds = section_bounds(lines, section)
    if bounds is None:
        lines.extend(["", f"[{section}]", f"{key} = {literal}"])
        return "\n".join(lines) + "\n"
    start, end = bounds
    for index in range(start + 1, end):
        stripped = lines[index].lstrip()
        if stripped.startswith("#"):
            continue
        if stripped.split("=", 1)[0].strip() == key:
            lines[index] = f"{key} = {literal}"
            return "\n".join(lines) + "\n"
    lines.insert(start + 1, f"{key} = {literal}")
    return "\n".join(lines) + "\n"


def include_entries(data: dict) -> list[str]:
    entries = data.get("include", {}).get("files", [])
    if not isinstance(entries, list):
        return []
    return [entry for entry in entries if isinstance(entry, str)]


def resolve_include(entry: str) -> Path:
    path = Path(os.path.expanduser(entry))
    if not path.is_absolute():
        path = CONFIG.parent / path
    return path.resolve()


def ensure_include(text: str, effect: str) -> str:
    manifest = None
    if SHADERS.is_dir():
        for path in sorted(SHADERS.glob("*/effect.toml")):
            try:
                data = tomllib.loads(path.read_text(encoding="utf-8"))
            except tomllib.TOMLDecodeError:
                continue
            if effect in data.get("effects", {}).get("preset", {}):
                manifest = path
                break
    if manifest is None:
        raise SystemExit(f"effect manifest not found for {effect!r}")
    rel = manifest.relative_to(CONFIG.parent).as_posix()
    entries = include_entries(tomllib.loads(text))
    target = resolve_include(rel)
    if any(resolve_include(entry) == target for entry in entries):
        return text
    entries.append(rel)
    lines = text.splitlines()
    bounds = section_bounds(lines, "include")
    if bounds is None:
        lines.extend(["", "[include]", "files = ["])
        lines.extend(f"    {toml_string(entry)}," for entry in entries)
        lines.append("]")
        return "\n".join(lines) + "\n"
    start, end = bounds
    files_at = None
    for index in range(start + 1, end):
        if lines[index].lstrip().split("=", 1)[0].strip() == "files":
            files_at = index
            break
    if files_at is None:
        lines.insert(start + 1, "files = [")
        for offset, entry in enumerate(entries):
            lines.insert(start + 2 + offset, f"    {toml_string(entry)},")
        lines.insert(start + 2 + len(entries), "]")
        return "\n".join(lines) + "\n"
    array_start = files_at
    while array_start < end and "[" not in lines[array_start]:
        array_start += 1
    array_end = array_start
    while array_end < end and "]" not in lines[array_end]:
        array_end += 1
    replacement = ["files = ["]
    replacement.extend(f"    {toml_string(entry)}," for entry in entries)
    replacement.append("]")
    lines[array_start:array_end + 1] = replacement
    return "\n".join(lines) + "\n"


def run_umbriel(arguments: list[str]) -> bool:
    try:
        result = subprocess.run(["umbriel"] + arguments, capture_output=True, text=True)
    except OSError as error:
        print(f"cannot run umbriel: {error}", file=sys.stderr)
        return False
    if result.returncode != 0:
        message = (result.stderr or result.stdout or f"umbriel exited with {result.returncode}").strip()
        print(message, file=sys.stderr)
        return False
    return True


def write_atomically(text: str) -> None:
    directory = CONFIG.parent
    directory.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(dir=directory, prefix=".config.toml.", text=True)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(text)
        os.replace(temporary, CONFIG)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def apply(kind: str, value: str) -> int:
    candidate = CONFIG.read_text(encoding="utf-8")
    if kind == "theme":
        candidate = set_key(candidate, "input.cursor", "theme", toml_string(value))
    elif kind == "effect":
        if value != "off":
            candidate = ensure_include(candidate, value)
        candidate = set_key(candidate, "effects", "cursor", toml_string("" if value == "off" else value))
    else:
        print(f"unknown option: {kind}", file=sys.stderr)
        return 2
    try:
        tomllib.loads(candidate)
    except tomllib.TOMLDecodeError as error:
        print(f"refusing to write invalid config: {error}", file=sys.stderr)
        return 1
    write_atomically(candidate)
    if not run_umbriel(["msg", "config-reload"]):
        return 1
    if kind == "effect" and not run_umbriel(["msg", "effect-cursor-set", value or "off"]):
        return 1
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        data = tomllib.loads(CONFIG.read_text(encoding="utf-8"))
        print(data.get("input", {}).get("cursor", {}).get("theme", ""))
        print(data.get("effects", {}).get("cursor", ""))
        return 0
    kind = sys.argv[1]
    value = sys.argv[2] if len(sys.argv) > 2 else ""
    return apply(kind, value)


if __name__ == "__main__":
    sys.exit(main())
