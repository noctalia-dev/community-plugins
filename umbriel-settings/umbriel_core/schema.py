"""Installed Umbriel schema loading and GUI coverage comparison."""

import fnmatch
import json
import re
import shutil
import subprocess

from .fields import ENTRY_EDITORS, TABS, schema_prefix
from .launch import child_env


def umbriel_executable():
    """The `umbriel` CLI's path; FileNotFoundError when it is not on PATH."""
    executable = shutil.which("umbriel")
    if not executable:
        raise FileNotFoundError("Umbriel CLI was not found on PATH.")
    return executable


def run_umbriel(args, timeout, errors=None):
    """Run `umbriel <args>` (no input, output captured as UTF-8 text; `errors` as in `open`). Raises
    FileNotFoundError when umbriel is not on PATH and subprocess.TimeoutExpired."""
    return subprocess.run([umbriel_executable(), *args], stdin=subprocess.DEVNULL, capture_output=True,
                          encoding="utf-8", errors=errors, timeout=timeout, check=False, env=child_env())


def run_umbriel_json(args, timeout):
    """Run `umbriel <args>` and parse its JSON output.

    Raises FileNotFoundError (no umbriel on PATH), subprocess.TimeoutExpired, RuntimeError (non-zero exit)
    or ValueError (invalid JSON).
    """
    command = "umbriel " + " ".join(args)
    result = run_umbriel(args, timeout)
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit status {result.returncode}"
        raise RuntimeError(f"`{command}` failed: {detail}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ValueError(f"`{command}` returned invalid JSON: {error}") from error


def load_umbriel_schema(timeout=5):
    """Load option metadata from the installed Umbriel CLI."""
    schema = run_umbriel_json(["config", "schema", "--json"], timeout)
    if not isinstance(schema, dict) or not isinstance(schema.get("options"), list):
        raise ValueError("`umbriel config schema --json` returned an unexpected schema document.")
    return schema


def schema_options_by_path(schema):
    """Index a schema document's options by their path."""
    return {
        option["path"]: option
        for option in schema.get("options", [])
        if isinstance(option, dict) and isinstance(option.get("path"), str)
    }


def field_schema_option(options, path):
    """Find an installed-schema entry for a field's fully qualified TOML path in `options` (path -> option)."""
    path = str(path)
    return options.get(path) or options.get(path.replace("<name>", "*"))


def schema_field_catalog():
    """Return canonical config paths represented by Field widgets and custom editors."""
    catalog = []

    def add_fields(groups, prefix=""):
        for _, fields in groups:
            for field in fields:
                path = ".".join(part for part in (prefix, ".".join(field.path)) if part)
                catalog.append((path, field.kind))

    for groups in TABS.values():
        add_fields(groups)
    for editor_id, spec in ENTRY_EDITORS.items():
        add_fields(spec[4], schema_prefix(editor_id))

    catalog.extend([
        ("keybinds.<name>", "custom"),
        ("environment.<name>", "custom"),
        ("animation.beziers.<name>", "custom"),
        ("animation.springs.<name>.stiffness", "custom"),
        ("animation.springs.<name>.damping", "custom"),
    ])
    return catalog


def _segment(part):
    """A path segment as a literal string, or a compiled pattern when it holds a wildcard (`<name>` → `*`)."""
    normalized = _value(part)
    if any(char in normalized for char in "*?["):
        return re.compile(fnmatch.translate(normalized)).match
    return normalized


def _value(part):
    return part.replace("[]", "__array__").replace("<name>", "*")


def _prefix_matches(patterns, values):
    """Every pattern segment matches the value segment at its position (values may be longer)."""
    for pattern, value in zip(patterns, values, strict=False):
        if not (pattern == value if isinstance(pattern, str) else pattern(value)):
            return False
    return True


def check_schema_coverage(schema):
    """Compare supported schema options with the GUI's field and custom-editor catalog.

    Segments are compared with shell wildcards (`<name>` matches any one segment). Both sides are bucketed by
    their first segment, so each option is only compared with catalog entries that can match it.
    """
    catalog = []
    by_first, wild_first = {}, []
    for field_path, kind in schema_field_catalog():
        patterns = [_segment(part) for part in field_path.split(".")]
        entry = (field_path, patterns, kind in ("raw", "table", "custom"))
        catalog.append(entry)
        if isinstance(patterns[0], str):
            by_first.setdefault(patterns[0], []).append(entry)
        else:
            wild_first.append(entry)

    options = [option for option in schema.get("options", []) if isinstance(option, dict)]
    paths_by_first = {}
    for path in {option.get("path") for option in options}:
        if isinstance(path, str):
            values = [_value(part) for part in path.split(".")]
            paths_by_first.setdefault(values[0], []).append(values)

    missing = []
    for option in options:
        if option.get("type") in ("table", "map", "array_of_tables"):
            continue
        path = str(option.get("path", ""))
        values = [_value(part) for part in path.split(".")]
        if not any(
            len(patterns) <= len(values) and (covers_children or len(patterns) == len(values))
            and _prefix_matches(patterns, values)
            for _, patterns, covers_children in by_first.get(values[0], []) + wild_first
        ):
            missing.append(path)

    stale = []
    for field_path, patterns, _ in catalog:
        if isinstance(patterns[0], str):
            candidates = paths_by_first.get(patterns[0], [])
        else:
            candidates = [values for group in paths_by_first.values() for values in group]
        if not any(len(values) >= len(patterns) and _prefix_matches(patterns, values) for values in candidates):
            stale.append(field_path)
    return sorted(set(missing)), sorted(set(stale))
