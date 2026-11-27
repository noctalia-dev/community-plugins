#!/usr/bin/env python3
"""Read and apply Umbriel cursor theme, size, and shader effect settings.

Edits the Umbriel config and the selected effect manifest in place, validates the
candidate with tomllib and `umbriel config validate`, and replaces files atomically.
Requires Python 3.11+.
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

DEFAULT_THEME = "Bibata-Modern-Classic"
DEFAULT_SIZE = 24
DEFAULT_RADIUS = 96
MIN_SIZE, MAX_SIZE = 16, 72
MIN_RADIUS, MAX_RADIUS = 32, 4096


class UserError(Exception):
    pass


def toml_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


HEADER = re.compile(r"^\[\s*([^\[\]]+?)\s*\]\s*(?:#.*)?$")


def header_section(line: str) -> str | None:
    match = HEADER.match(line.strip())
    return match.group(1).strip() if match else None


def split_key(text: str) -> list[str]:
    """Split a TOML dotted key, keeping dots inside quoted parts intact."""
    parts: list[str] = []
    current: list[str] = []
    quote: str | None = None
    escaped = False
    for char in text:
        if quote is not None:
            current.append(char)
            if quote == '"' and escaped:
                escaped = False
            elif quote == '"' and char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            continue
        if char in "\"'":
            quote = char
            current.append(char)
        elif char == ".":
            parts.append("".join(current).strip())
            current = []
        else:
            current.append(char)
    parts.append("".join(current).strip())
    return parts


def unquote_key(part: str) -> str:
    if len(part) >= 2 and part[0] == part[-1] == '"':
        try:
            return json.loads(part)
        except json.JSONDecodeError:
            return part[1:-1]
    if len(part) >= 2 and part[0] == part[-1] == "'":
        return part[1:-1]
    return part


def header_path(line: str) -> tuple[str, ...] | None:
    section = header_section(line)
    if section is None:
        return None
    return tuple(unquote_key(part) for part in split_key(section))


BARE_KEY = re.compile(r"^[A-Za-z0-9_-]+$")


def format_key(parts: tuple[str, ...]) -> str:
    return ".".join(part if BARE_KEY.match(part) else toml_string(part) for part in parts)


def section_bounds(lines: list[str], path: tuple[str, ...]) -> tuple[int, int] | None:
    start = None
    for index, line in enumerate(lines):
        if header_path(line) == path:
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


def set_key(text: str, path: tuple[str, ...], key: str, literal: str) -> str:
    lines = text.splitlines()
    bounds = section_bounds(lines, path)
    if bounds is None:
        if lines and lines[-1].strip():
            lines.append("")
        lines.extend([f"[{format_key(path)}]", f"{key} = {literal}"])
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


def parse_toml(text: str, source: str) -> dict:
    try:
        return tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        raise UserError(f"refusing to write invalid TOML for {source}: {error}") from error


def read_config() -> tuple[str, dict]:
    try:
        text = CONFIG.read_text(encoding="utf-8")
    except OSError as error:
        raise UserError(f"cannot read {CONFIG}: {error}") from error
    return text, parse_toml(text, str(CONFIG))


def include_entries(data: dict) -> list[str]:
    include = data.get("include")
    if not isinstance(include, dict):
        return []
    entries = include.get("files", [])
    if not isinstance(entries, list):
        return []
    return [entry for entry in entries if isinstance(entry, str)]


def resolve_include(entry: str) -> Path:
    path = Path(os.path.expanduser(entry))
    if not path.is_absolute():
        path = CONFIG.parent / path
    return path.resolve()


def find_preset(effect: str) -> tuple[Path, dict] | None:
    if not SHADERS.is_dir():
        return None
    for path in sorted(SHADERS.glob("*/effect.toml")):
        try:
            data = tomllib.loads(path.read_text(encoding="utf-8"))
        except (OSError, tomllib.TOMLDecodeError):
            continue
        effects = data.get("effects")
        if not isinstance(effects, dict):
            continue
        presets = effects.get("preset")
        if not isinstance(presets, dict):
            continue
        preset = presets.get(effect)
        if isinstance(preset, dict) and preset.get("kind") == "cursor":
            return path, preset
    return None


def include_path(manifest: Path) -> str:
    try:
        return manifest.relative_to(CONFIG.parent).as_posix()
    except ValueError:
        return manifest.as_posix()


def ensure_include(text: str, manifest: Path, data: dict) -> str:
    rel = include_path(manifest)
    target = resolve_include(rel)
    entries = include_entries(data)
    if any(resolve_include(entry) == target for entry in entries):
        return text
    entries.append(rel)
    lines = text.splitlines()
    bounds = section_bounds(lines, ("include",))
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
        result = subprocess.run(
            ["umbriel"] + arguments,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except OSError as error:
        print(f"cannot run umbriel: {error}", file=sys.stderr)
        return False
    except subprocess.TimeoutExpired:
        print("umbriel timed out", file=sys.stderr)
        return False
    if result.returncode != 0:
        message = (result.stderr or result.stdout or f"umbriel exited with {result.returncode}").strip()
        print(message, file=sys.stderr)
        return False
    return True


def stage(path: Path, text: str) -> Path:
    directory = path.parent
    directory.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(dir=directory, prefix=f".{path.name}.", text=True)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(text)
        try:
            mode = path.stat().st_mode
        except FileNotFoundError:
            pass
        else:
            os.chmod(temporary, mode)
    except BaseException:
        discard(Path(temporary))
        raise
    return Path(temporary)


def discard(temporary: Path) -> None:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass


def write_target(path: Path) -> Path:
    try:
        return path.resolve(strict=False)
    except (OSError, RuntimeError):
        return path


def write_atomically(path: Path, text: str) -> None:
    target = write_target(path)
    temporary = stage(target, text)
    try:
        os.replace(temporary, target)
    except BaseException:
        discard(temporary)
        raise


def normalize_effect(value: str) -> str:
    effect = value.strip()
    return "off" if effect in ("", "off") else effect


def update_radius(manifest: Path, effect: str, radius: int) -> str | None:
    try:
        original = manifest.read_text(encoding="utf-8")
    except OSError as error:
        raise UserError(f"cannot read {manifest}: {error}") from error
    updated = set_key(original, ("effects", "preset", effect), "radius", str(radius))
    if updated == original:
        return None
    data = parse_toml(updated, str(manifest))
    effects = data.get("effects")
    presets = effects.get("preset") if isinstance(effects, dict) else None
    preset = presets.get(effect) if isinstance(presets, dict) else None
    if not isinstance(preset, dict) or preset.get("radius") != radius:
        raise UserError(f"could not set radius in {manifest} for {effect!r}")
    return updated


def apply(theme: str, size: int, effect: str, radius: int) -> int:
    if not theme.strip():
        raise UserError("cursor theme must not be empty")
    if not MIN_SIZE <= size <= MAX_SIZE:
        raise UserError(f"cursor size must be between {MIN_SIZE} and {MAX_SIZE} px")
    if not MIN_RADIUS <= radius <= MAX_RADIUS:
        raise UserError(f"effect radius must be between {MIN_RADIUS} and {MAX_RADIUS}")

    effect = normalize_effect(effect)
    manifest = None
    if effect != "off":
        found = find_preset(effect)
        if found is None:
            raise UserError(f"cursor effect not found: {effect}")
        manifest = found[0]

    original, data = read_config()
    candidate = set_key(original, ("input", "cursor"), "theme", toml_string(theme.strip()))
    candidate = set_key(candidate, ("input", "cursor"), "size", str(size))
    if manifest is not None:
        candidate = ensure_include(candidate, manifest, data)
    candidate = set_key(
        candidate,
        ("effects",),
        "cursor",
        toml_string("" if effect == "off" else effect),
    )
    candidate_data = parse_toml(candidate, str(CONFIG))

    cursor = candidate_data.get("input", {}).get("cursor", {})
    if cursor.get("theme") != theme.strip() or int(cursor.get("size", -1)) != size:
        raise UserError("failed to update the cursor theme or size")
    if normalize_effect(str(candidate_data.get("effects", {}).get("cursor", ""))) != effect:
        raise UserError("failed to update the cursor effect")

    manifest_write: tuple[Path, str] | None = None
    if manifest is not None:
        updated = update_radius(manifest, effect, radius)
        if updated is not None:
            manifest_write = (manifest, updated)

    temporary = stage(CONFIG, candidate)
    try:
        if not run_umbriel(["config", "validate", "-c", str(temporary)]):
            discard(temporary)
            return 1
        if manifest_write is not None:
            write_atomically(*manifest_write)
        target = write_target(CONFIG)
        if target == CONFIG:
            os.replace(temporary, CONFIG)
        else:
            write_atomically(target, candidate)
            discard(temporary)
    except BaseException:
        discard(temporary)
        raise

    if not run_umbriel(["msg", "config-reload"]):
        return 1
    if not run_umbriel(["msg", "effect-cursor-set", "off" if effect == "off" else effect]):
        return 1
    print(
        f"applied: theme={theme.strip()} size={size} "
        f"effect={effect} radius={radius}"
    )
    return 0


def state() -> int:
    _, data = read_config()
    cursor = data.get("input", {}).get("cursor", {})
    theme = cursor.get("theme", DEFAULT_THEME)
    size = int(cursor.get("size", DEFAULT_SIZE))
    effect = normalize_effect(str(data.get("effects", {}).get("cursor", "")))
    radius = DEFAULT_RADIUS
    if effect != "off":
        found = find_preset(effect)
        if found is not None:
            value = found[1].get("radius")
            if isinstance(value, int):
                radius = value
    print(f"theme={theme}")
    print(f"size={size}")
    print(f"effect={effect}")
    print(f"radius={radius}")
    return 0


def effects() -> int:
    names: set[str] = set()
    if SHADERS.is_dir():
        for path in sorted(SHADERS.glob("*/effect.toml")):
            try:
                data = tomllib.loads(path.read_text(encoding="utf-8"))
            except (OSError, tomllib.TOMLDecodeError):
                continue
            preset = data.get("effects", {}).get("preset", {})
            if not isinstance(preset, dict):
                continue
            for name, value in preset.items():
                if isinstance(value, dict) and value.get("kind") == "cursor":
                    names.add(name)
    for name in sorted(names):
        print(name)
    return 0


def main(argv: list[str]) -> int:
    try:
        if not argv or argv[0] == "state":
            return state()
        if argv[0] == "effects":
            return effects()
        if argv[0] == "set":
            if len(argv) != 5:
                raise UserError("usage: cursor_effects.py set <theme> <size> <effect> <radius>")
            try:
                size = int(argv[2])
                radius = int(argv[4])
            except ValueError as error:
                raise UserError("size and radius must be integers") from error
            return apply(argv[1], size, argv[3], radius)
        raise UserError(
            "usage: cursor_effects.py [state|effects|set <theme> <size> <effect> <radius>]"
        )
    except UserError as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
