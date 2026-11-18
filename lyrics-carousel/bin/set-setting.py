#!/usr/bin/env python3
"""Writes the plugin settings into Noctalia's settings.toml.

Usage:  set-setting.py <key> <value> [type] [<key> <value> [type] ...]
        set-setting.py override <key> <value> <type>
        set-setting.py persist <key> <value> <type>
        set-setting.py merge
        set-setting.py read

Types: bool | int | float | string

It keeps the file format (quoted sections, keys sorted the way Noctalia
leaves them) and writes atomically so the configuration is not corrupted.

"override" leaves the value only in the temporary layer (overrides.json),
which the panel dumps when it closes. "persist" writes it to settings.toml
as well: that is what the window shortcuts need, since they have no panel
to dump anything. "merge" folds the overrides layer into settings.toml.
"read" writes nothing: it prints the stored values as JSON, which is how
the panel sees the settings the manifest no longer declares.
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import sys
import tempfile

try:
    import tomllib
except ImportError:  # pragma: no cover - python < 3.11
    tomllib = None

# The state paths are shared by the script: if the helper looked for
# settings.toml in one place and the script in another, one would write
# where the other reads.
from paths import overrides_path, settings_path

PLUGIN_ID = "faminec/lyrics-carousel"
SECTION = f'[plugin_settings."{PLUGIN_ID}"]'

ALLOWED = {
    "font_family", "font_size", "direction", "marker",
    "karaoke", "footer", "hints", "header", "spacing",
    "ghost", "offset_ms", "width", "height", "anchor",
    "custom_x", "custom_y", "accent", "custom_color", "active_scale",
    "visible_above", "visible_below", "glyph",
}

BOOL_KEYS = {
    "marker", "karaoke", "footer", "hints", "header", "ghost",
}
INT_KEYS = {
    "font_size", "spacing", "offset_ms", "width", "height",
    "custom_x", "custom_y", "visible_above", "visible_below",
}
FLOAT_KEYS = {"active_scale"}

# The same patterns as lib/settings.luau (PATTERNS). The panel and the
# widget IPC already apply them; the helper is another write path and
# without this it could store a nonexistent glyph or an invalid color.
PATTERNS = {
    "glyph": r"^[a-z0-9-]+$",
    "custom_color": r"^#[0-9a-fA-F]{6}$",
    # Same pattern as in lib/settings.luau: the font cannot be empty nor
    # contain line breaks (it is passed to the kitty command).
    "font_family": r"^[^\n]+$",
}

# The limits (min/max) are not hardcoded here: they are read from the
# manifest, which is the source of truth. If they were hardcoded, a change
# in plugin.toml would leave the plugin writing values that its own
# settings page does not allow.
_MANIFEST_LIMITS = None


def manifest_limits() -> dict:
    """The ranges (min, max) declared by the plugin manifest.

    Without tomllib (Python < 3.11) the manifest is read with a regular
    expression: otherwise the clamping would silently disappear and the
    helper would write values that the settings page does not allow.
    """
    global _MANIFEST_LIMITS
    if _MANIFEST_LIMITS is not None:
        return _MANIFEST_LIMITS
    manifest = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "plugin.toml"
    )
    limits = {}
    if tomllib is not None:
        try:
            with open(manifest, "rb") as handle:
                data = tomllib.load(handle)
        except (OSError, tomllib.TOMLDecodeError):
            data = {}
        for field in data.get("setting", []):
            key = field.get("key")
            if not key:
                continue
            low = field.get("min")
            high = field.get("max")
            if low is None and high is None:
                continue
            limits[key] = (low, high)
    else:
        limits = manifest_limits_without_tomllib(manifest)
    _MANIFEST_LIMITS = limits
    return limits


def _toml_number(setting_text: str):
    """Converts a TOML number (with +, exponent or _) to int/float."""
    setting_value = float(setting_text.replace("_", ""))
    return int(setting_value) if setting_value.is_integer() else setting_value


def manifest_limits_without_tomllib(manifest: str) -> dict:
    """Reads min/max from the manifest with a regular expression.

    It is only used when there is no tomllib. The manifest format is
    simple ([[setting]] blocks with key/min/max), but the fallback cannot
    assume it is the only valid format: it accepts single quotes and
    numbers with a + sign, an exponent or separators, and it closes the
    setting at any table header (a min/max from [[panel]] does not belong
    to the last setting).
    """
    limits = {}
    try:
        with open(manifest, encoding="utf-8") as handle:
            setting_text = handle.read()
    except OSError:
        return limits

    def add(setting_key, minimum, maximum):
        if setting_key is not None and (minimum is not None or maximum is not None):
            limits[setting_key] = (minimum, maximum)

    number = r"[-+]?(?:\d[\d_]*(?:\.\d[\d_]*)?|\.\d[\d_]*)(?:[eE][-+]?\d[\d_]*)?"
    setting_key = None
    minimum = None
    maximum = None
    for lyric_line in setting_text.splitlines():
        cleans = lyric_line.strip()
        if not cleans or cleans.startswith("#"):
            continue
        if re.match(r"^\[\[.*\]\]\s*(?:#.*)?$", cleans) or re.match(
            r"^\[[^\[].*\]\s*(?:#.*)?$", cleans
        ):
            add(setting_key, minimum, maximum)
            setting_key, minimum, maximum = None, None, None
            continue
        found = re.match(r"""^key\s*=\s*(?:"([^"]+)"|'([^']+)')""", cleans)
        if found:
            setting_key = found.group(1) or found.group(2)
            continue
        found = re.match(rf"^min\s*=\s*({number})", cleans)
        if found:
            minimum = _toml_number(found.group(1))
            continue
        found = re.match(rf"^max\s*=\s*({number})", cleans)
        if found:
            maximum = _toml_number(found.group(1))
    add(setting_key, minimum, maximum)
    return limits


def clamp_value(key: str, value):
    """Clamps a numeric value to the manifest limits."""
    bounds = manifest_limits().get(key)
    if bounds is None:
        return value
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return value
    low, high = bounds
    if low is not None and value < low:
        return low
    if high is not None and value > high:
        return high
    return value


def prepare(key: str, value, kind: str):
    """Converts the value to its type, clamps it and validates its format."""
    prepared = clamp_value(key, parse_value(value, kind))
    # visualizer_position: manual validation (no alternation | in the regex)
    if key == "visualizer_position":
        if not isinstance(prepared, str) or prepared not in ("top", "bottom", "left", "right"):
            raise ValueError(f"invalid format for {key}: {value!r}")
        return prepared
    pattern = PATTERNS.get(key)
    if pattern is not None and (
        not isinstance(prepared, str) or re.fullmatch(pattern, prepared) is None
    ):
        raise ValueError(f"invalid format for {key}: {value!r}")
    return prepared


def format_value(value: str, kind: str) -> str:
    if kind == "bool":
        return "true" if str(value).lower() in ("1", "true", "yes", "on") else "false"
    if kind == "int":
        return str(int(float(value)))
    if kind == "float":
        return str(float(value))
    escaped = str(value).replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def patch(text: str, key: str, raw_value: str) -> str:
    """Inserts or replaces a key inside the plugin section."""
    lines = text.split("\n")
    start = None
    end = len(lines)
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped == SECTION:
            start = index
            continue
        if start is not None and stripped.startswith("[") and stripped.endswith("]"):
            end = index
            break
    if start is None:
        block = [SECTION, f"{key} = {raw_value}"]
        prefix = text if text.endswith("\n") else text + "\n"
        if not prefix.strip():
            return "\n".join(block) + "\n"
        return prefix + "\n".join(block) + "\n"

    body = lines[start + 1 : end]
    # TOML does not allow duplicate keys: if there are any, the whole file
    # becomes invalid and Noctalia discards the entire section. Only the
    # first occurrence of each key is kept.
    seen = set()
    clean = []
    for line in body:
        name = line.split("=", 1)[0].strip()
        if name and not name.startswith("["):
            if name in seen:
                continue
            seen.add(name)
        clean.append(line)
    body = clean
    replaced = False
    for index, line in enumerate(body):
        if line.strip().startswith(key + " "):
            if not replaced:
                body[index] = f"{key} = {raw_value}"
                replaced = True
            else:
                # Duplicate key: the TOML would be invalid and Noctalia
                # would discard the whole section. The duplicate is removed.
                body[index] = None
    body = [line for line in body if line is not None]
    if not replaced:
        insert_at = len(body)
        while insert_at > 0 and body[insert_at - 1].strip() == "":
            insert_at -= 1
        for index in range(insert_at):
            name = body[index].split("=", 1)[0].strip()
            if name and name > key:
                insert_at = index
                break
        body.insert(insert_at, f"{key} = {raw_value}")
    return "\n".join(lines[: start + 1] + body + lines[end:])


def parse_args(argv):
    pairs = []
    index = 0
    while index < len(argv):
        key = argv[index]
        if index + 1 >= len(argv):
            raise ValueError(f"missing value for {key}")
        value = argv[index + 1]
        kind = "string"
        if index + 2 < len(argv) and argv[index + 2] in ("bool", "int", "float", "string"):
            kind = argv[index + 2]
            index += 1
        pairs.append((key, value, kind))
        index += 2
    return pairs


def ensure_dir(path: str) -> bool:
    """Makes sure the directory exists.

    Noctalia creates the plugin data directory, but it may not exist (if it
    was deleted by hand or if the plugin has never saved anything) and then
    neither the lock nor the write could be created.
    """
    directory = os.path.dirname(path)
    if not directory:
        return True
    try:
        os.makedirs(directory, exist_ok=True)
        return True
    except OSError as error:
        print(f"could not create {directory}: {error}", file=sys.stderr)
        return False


def overrides_path_now() -> str:
    """Current path of the overrides file (read every time)."""
    return overrides_path()


def read_overrides():
    try:
        with open(overrides_path_now(), encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def write_overrides(data) -> bool:
    path = overrides_path_now()
    if not ensure_dir(path):
        return False
    directory = os.path.dirname(path)
    try:
        temporary = ""
        handle = tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=directory, delete=False, suffix=".tmp"
        )
        temporary = handle.name
        with handle:
            json.dump(data, handle, ensure_ascii=False, indent=1, sort_keys=True)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        temporary = ""
    except OSError as error:
        print(f"could not write the overrides: {error}", file=sys.stderr)
        return False
    return True


def set_override(key: str, value: str, kind: str) -> int:
    """Stores a setting in the overrides file (Noctalia does not watch it).

    Several writes can overlap (the panel writes without waiting), so the
    read-modify-write cycle takes a lock: otherwise the second one
    overwrites the first.
    """
    path = overrides_path_now()
    lock_path = path + ".lock"
    if not ensure_dir(lock_path):
        return 1
    try:
        lock = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o644)
    except OSError as error:
        print(f"could not open the lock: {error}", file=sys.stderr)
        return 1
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        data = read_overrides()
        data[key] = prepare(key, value, kind)
        if not write_overrides(data):
            return 1
        return 0
    finally:
        try:
            fcntl.flock(lock, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(lock)


def remove_override(key: str, value) -> bool:
    """Removes a key from the overrides if it still holds that value.

    The value is checked: if the panel changed that key in the meantime,
    its change is respected and left alone (the panel dumps its own values
    when it closes).
    """
    path = overrides_path_now()
    lock_path = path + ".lock"
    if not ensure_dir(lock_path):
        return False
    try:
        lock = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o644)
    except OSError:
        return False
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        data = read_overrides()
        if key not in data or data[key] != value:
            return False
        del data[key]
        return write_overrides(data)
    finally:
        try:
            fcntl.flock(lock, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(lock)


def parse_value(value: str, kind: str):
    if kind == "bool":
        return str(value).lower() in ("1", "true", "yes", "on")
    if kind == "int":
        return int(float(value))
    if kind == "float":
        return float(value)
    return value


def merge_overrides() -> int:
    """Dumps the overrides into settings.toml and deletes the file."""
    data = read_overrides()
    if not data:
        return 0
    pairs = []
    for key, value in data.items():
        if key not in ALLOWED:
            continue
        if isinstance(value, bool):
            kind = "bool"
            raw = "true" if value else "false"
        elif isinstance(value, int):
            kind = "int"
            raw = str(value)
        elif isinstance(value, float):
            kind = "float"
            raw = str(value)
        else:
            kind = "string"
            raw = str(value)
        try:
            # An old override with an invalid format (for example, a glyph
            # with an underscore stored before validation) cannot be
            # dumped: it is discarded when the panel closes instead of
            # breaking the dump.
            prepare(key, raw, kind)
        except ValueError as error:
            print(f"discarded {key}: {error}", file=sys.stderr)
            continue
        pairs.append((key, raw, kind))
    if not pairs:
        try:
            os.remove(overrides_path_now())
        except OSError:
            pass
        return 0
    code = write_settings(pairs)
    if code == 0:
        try:
            os.remove(overrides_path_now())
        except OSError:
            pass
    return code


def _toml_value(setting_text: str):
    """Converts a TOML scalar (true, 12, 1.5 or "text") to its type."""
    setting_text = setting_text.strip()
    if setting_text == "true":
        return True
    if setting_text == "false":
        return False
    if len(setting_text) >= 2 and setting_text[0] == setting_text[-1] and setting_text[0] in "\"'":
        return setting_text[1:-1]
    number = re.match(
        r"^[-+]?(?:\d[\d_]*(?:\.\d[\d_]*)?|\.\d[\d_]*)(?:[eE][-+]?\d+)?$", setting_text
    )
    if number is not None:
        return _toml_number(number.group(0))
    return setting_text


def read_settings() -> dict:
    """The plugin settings stored in settings.toml (read only).

    The manifest only declares the toolbar icon: the panel manages the
    rest of the settings. Noctalia keeps stored keys even when they are
    not declared, but `noctalia.getConfig` only returns the ones it knows,
    so the panel has to read the file to see the real value. It is the
    same source the script uses: if the panel showed something else, the
    user would see a value that is not applied.
    """
    try:
        with open(settings_path(), encoding="utf-8") as handle:
            text = handle.read()
    except OSError:
        return {}
    if tomllib is not None:
        try:
            data = tomllib.loads(text)
        except (tomllib.TOMLDecodeError, ValueError):
            return {}
        section = (data.get("plugin_settings") or {}).get(PLUGIN_ID) or {}
        return {key: section[key] for key in ALLOWED if key in section}
    return read_settings_without_tomllib(text)


def read_settings_without_tomllib(text: str) -> dict:
    """Reads the plugin section with a regular expression (Python < 3.11).

    It is only used when there is no tomllib. The file format is written
    by Noctalia (a `[plugin_settings."faminec/lyrics-carousel"]` section
    with scalar keys), but the fallback limits itself to what the panel
    needs and discards any line it does not understand.
    """
    values = {}
    inside = False
    for lyric_line in text.splitlines():
        cleans = lyric_line.strip()
        if not cleans or cleans.startswith("#"):
            continue
        if cleans.startswith("["):
            inside = cleans == SECTION
            continue
        if not inside or "=" not in cleans:
            continue
        name, _, remainder = cleans.partition("=")
        name = name.strip()
        if name not in ALLOWED:
            continue
        values[name] = _toml_value(remainder)
    return values


def persist_override(key: str, value: str, kind: str) -> int:
    """Stores the setting and leaves it written in settings.toml.

    The overrides layer is temporary (the panel dumps it when it closes). A
    window shortcut has no panel to dump it, so the value is written to
    settings.toml as well: otherwise it would be lost when the session
    restarts.

    The overrides are written first: if writing settings.toml fails, the
    value stays in effect during the session and the panel dumps it when
    it closes. If the write succeeds, the key is removed from the overrides
    so it does not mask a later change made on the settings page.
    """
    if set_override(key, value, kind) != 0:
        return 1
    code = write_settings([(key, value, kind)])
    if code != 0:
        return code
    remove_override(key, prepare(key, value, kind))
    return 0


def main(argv):
    if len(argv) >= 2 and argv[1] == "override":
        if len(argv) < 5:
            print("usage: set-setting.py override <key> <value> <type>", file=sys.stderr)
            return 2
        if argv[2] not in ALLOWED:
            print(f"unknown key: {argv[2]}", file=sys.stderr)
            return 2
        try:
            return set_override(argv[2], argv[3], argv[4])
        except ValueError as error:
            print(str(error), file=sys.stderr)
            return 2
    if len(argv) >= 2 and argv[1] == "persist":
        if len(argv) < 5:
            print("usage: set-setting.py persist <key> <value> <type>", file=sys.stderr)
            return 2
        if argv[2] not in ALLOWED:
            print(f"unknown key: {argv[2]}", file=sys.stderr)
            return 2
        try:
            return persist_override(argv[2], argv[3], argv[4])
        except ValueError as error:
            print(str(error), file=sys.stderr)
            return 2
    if len(argv) >= 2 and argv[1] == "merge":
        return merge_overrides()
    if len(argv) >= 2 and argv[1] == "read":
        # Read only: the panel uses it to see the real value of a setting
        # that the manifest no longer declares. It does not write anything.
        print(json.dumps(read_settings(), ensure_ascii=False, sort_keys=True))
        return 0
    if len(argv) < 3:
        print("usage: set-setting.py <key> <value> [type] ...", file=sys.stderr)
        return 2
    try:
        pairs = parse_args(argv[1:])
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 2

    for key, _, _ in pairs:
        if key not in ALLOWED:
            print(f"unknown key: {key}", file=sys.stderr)
            return 2

    try:
        return write_settings(pairs)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 2


def write_settings(pairs) -> int:
    """Writes the settings into settings.toml (with a lock).

    The script and the panel can write at the same time: with a lock file
    the read-modify-write cycle is serialized and they do not overwrite
    each other.
    """
    settings = settings_path()
    lock_path = settings + ".lock"
    if not ensure_dir(lock_path):
        return 1
    try:
        lock = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o644)
    except OSError as error:
        print(f"could not open the lock: {error}", file=sys.stderr)
        return 1
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            with open(settings, encoding="utf-8") as handle:
                text = handle.read()
        except OSError as error:
            print(f"could not read: {error}", file=sys.stderr)
            return 1
        return _write(text, pairs)
    finally:
        try:
            fcntl.flock(lock, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(lock)


def _write(text, pairs):
    updated = text
    for key, value, kind in pairs:
        updated = patch(updated, key, format_value(prepare(key, value, kind), kind))
    if updated == text:
        return 0

    settings = settings_path()
    if not ensure_dir(settings):
        return 1
    directory = os.path.dirname(settings)
    temporary = ""
    try:
        handle = tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=directory, delete=False, suffix=".tmp"
        )
        temporary = handle.name
        with handle:
            handle.write(updated)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, settings)
        temporary = ""
    except OSError as error:
        if temporary:
            try:
                os.unlink(temporary)
            except OSError:
                pass
        print(f"could not write: {error}", file=sys.stderr)
        return 1

    # Check: the file must still be valid TOML and hold the written values.
    # If anything fails, it is reported with an error code.
    if tomllib is None:
        return 0
    try:
        with open(settings, "rb") as handle:
            check = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as error:
        print(f"the file became unreadable: {error}", file=sys.stderr)
        return 1
    section = (check.get("plugin_settings") or {}).get(PLUGIN_ID) or {}
    for key, value, _ in pairs:
        if key not in section:
            print(f"could not save {key}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
