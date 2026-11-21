"""Convert field values between TOML items and plain JSON for UIs, and write them back like the app does."""

import math

import tomlkit

from .tomlops import MISSING, delp, getp, parse_toml_value, putp, py, totext

TEXT_KINDS = ("str", "choice", "combo", "color")
LIST_KINDS = ("list", "command_list")


def field_default(field, schema_option):
    """Return the schema default when the installed Umbriel declares one, else the field's fallback."""
    if schema_option is not None and "default" in schema_option:
        return schema_option["default"]
    return field.default


def table_keys(field):
    """Return the sub-keys a `table` field edits, e.g. ('x', 'y')."""
    return tuple(field.extra or ())


def to_ui(field, value):
    """Return a JSON-friendly value for one field (None when the key is absent)."""
    if value is MISSING or value is None:
        return None
    plain = py(value)
    kind = field.kind
    if kind == "raw":
        return totext(value) if plain != "" else ""
    if kind == "strorlist":
        return plain if isinstance(plain, str) else totext(value)
    if kind == "table":
        keys = table_keys(field)
        if isinstance(plain, list):
            return {key: plain[i] for i, key in enumerate(keys) if i < len(plain)}
        if isinstance(plain, dict):
            return {key: plain[key] for key in keys if key in plain}
        return None
    if kind in LIST_KINDS:
        return [str(item) for item in plain] if isinstance(plain, list) else None
    return plain


def _number(value, label, integer):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError(f"{label}: enter a number.")
    if integer:
        if value != int(value):
            raise ValueError(f"{label}: enter a whole number.")
        return int(value)
    return float(value)


def _check_range(value, label, schema_option):
    if schema_option is None:
        return value
    low, high = schema_option.get("min"), schema_option.get("max")
    if low is not None and value < low or high is not None and value > high:
        raise ValueError(f"{label}: must be between {low} and {high}.")
    return value


def from_ui(field, value, schema_option=None):
    """Turn a UI value into a TOML-ready value; raise ValueError with a readable message when invalid."""
    kind, label = field.kind, field.label
    # Lua tables encode an empty list and an empty object the same way.
    if kind == "table" and value == []:
        value = {}
    elif kind in LIST_KINDS and value == {}:
        value = []
    if kind == "bool":
        if not isinstance(value, bool):
            raise ValueError(f"{label}: expected on or off.")
        return value
    if kind == "int":
        return _check_range(_number(value, label, True), label, schema_option)
    if kind == "float":
        return _check_range(_number(value, label, False), label, schema_option)
    if kind in TEXT_KINDS:
        if not isinstance(value, str):
            raise ValueError(f"{label}: expected text.")
        if kind == "color":
            text = value.strip()
            digits = text[1:]
            if not (text.startswith("#") and len(digits) in (6, 8)
                    and all(c in "0123456789abcdefABCDEF" for c in digits)):
                raise ValueError(f"{label}: use #RRGGBB or #RRGGBBAA.")
            return text.upper()
        if kind == "choice" and schema_option is not None:
            allowed = schema_option.get("values") or field.extra
            if allowed and value not in allowed:
                raise ValueError(f"{label}: choose one of {', '.join(map(str, allowed))}.")
        return value
    if kind in LIST_KINDS:
        if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
            raise ValueError(f"{label}: expected a list of text values.")
        if kind == "command_list":
            return [item for item in value if item.strip()]
        return [item.strip() for item in value if item.strip()]
    if kind == "raw":
        if not isinstance(value, str):
            raise ValueError(f"{label}: expected TOML text.")
        try:
            return parse_toml_value(value.strip())
        except ValueError as error:
            raise ValueError(f"{label}: invalid TOML value ({error})") from error
    if kind == "strorlist":
        if not isinstance(value, str):
            raise ValueError(f"{label}: expected text.")
        text = value.strip()
        if text.startswith("["):
            try:
                return parse_toml_value(text)
            except ValueError as error:
                raise ValueError(f"{label}: invalid TOML value ({error})") from error
        return text
    if kind == "table":
        if not isinstance(value, dict):
            raise ValueError(f"{label}: expected one value per key.")
        keys = table_keys(field)
        defaults = field.default
        items = []
        for index, key in enumerate(keys):
            fallback = defaults[index] if isinstance(defaults, list) else (defaults or {}).get(key)
            item = value.get(key, fallback)
            if isinstance(item, bool) or not isinstance(item, (int, float, str)):
                raise ValueError(f"{label}: invalid value for {key}.")
            # JSON numbers from Luau are doubles; keep integer keys integers.
            if isinstance(item, float) and item.is_integer() and isinstance(fallback, int):
                item = int(item)
            items.append((key, item))
        if isinstance(defaults, list):
            result = tomlkit.array()
            result.extend(item for _, item in items)
            return result
        result = tomlkit.inline_table()
        for key, item in items:
            result[key] = item
        return result
    raise ValueError(f"{label}: unsupported field kind {kind}.")


def apply_value(container, field, value, default):
    """Write one field like the app's apply_fields: None deletes; new keys are written when optional or non-default."""
    path = field.path
    current = getp(container, path)
    if value is None:
        if current is not MISSING:
            delp(container, path)
    elif current is MISSING:
        if field.opt or py(value) != py(default):
            putp(container, path, value)
    elif py(current) != py(value):
        putp(container, path, value)
