"""Entry editors (rules, outputs, devices, effects) and key/value maps, with replayable edit operations.

Operations mirror the app's EntryEditor/KVTable/RawValueMapEditor behavior so a UI can record what the
user did and the helper can replay it on a fresh parse of the config, keeping comments intact.
"""

import copy
import re

import tomlkit

from .fields import ENTRY_EDITORS, MAP_EDITORS, schema_prefix  # noqa: F401 (schema_prefix: entry_ops API)
from .tomlops import ENV_NAME_RE, MISSING, RESERVED_ENV, delp, ensure_table, getp, parse_toml_value, putp, py, totext


def editor_path(editor_id):
    spec = ENTRY_EDITORS.get(editor_id) or MAP_EDITORS.get(editor_id)
    if spec is None:
        raise ValueError(f"Unknown editor: {editor_id}")
    return tuple(spec[2].split("."))


def editor_fields(editor_id):
    """Return {dotted field path: Field} for an entry editor."""
    return {
        ".".join(field.path): field
        for _, fields in ENTRY_EDITORS[editor_id][4]
        for field in fields
    }


def container(doc, editor_id, create=False):
    """Return the array of tables or table of tables holding an editor's entries (None when absent)."""
    mode = ENTRY_EDITORS[editor_id][3]
    path = editor_path(editor_id)
    c = getp(doc, path)
    if c is MISSING and create:
        if mode == "aot":
            c = tomlkit.aot()
            putp(doc, path, c)
        else:
            c = ensure_table(doc, path)
    if c is MISSING:
        return None
    # A hand-written config can use the other shape ([[output]] or a plain value); report it instead of crashing.
    if mode == "aot" and not (isinstance(c, list) and all(isinstance(item, dict) for item in c)):
        raise ValueError(f"{ENTRY_EDITORS[editor_id][0]}: `{'.'.join(path)}` must be written as [[{'.'.join(path)}]] "
                         "tables; fix it in the config file.")
    if mode == "map" and not (isinstance(c, dict) and all(isinstance(item, dict) for item in c.values())):
        raise ValueError(f"{ENTRY_EDITORS[editor_id][0]}: `{'.'.join(path)}` must be a table of named tables, "
                         f"like [{'.'.join(path)}.NAME]; fix it in the config file.")
    return c


def entries(doc, editor_id):
    """List entries as tables ('aot') or (name, table) pairs ('map')."""
    c = container(doc, editor_id)
    if c is None:
        return []
    return list(c) if ENTRY_EDITORS[editor_id][3] == "aot" else list(c.items())


def entry_at(doc, editor_id, index):
    items = entries(doc, editor_id)
    if not isinstance(index, int) or isinstance(index, bool) or not 0 <= index < len(items):
        raise ValueError(f"{ENTRY_EDITORS[editor_id][0]}: entry {index} does not exist.")
    item = items[index]
    return item if ENTRY_EDITORS[editor_id][3] == "aot" else item[1]


def _entry_name(name, existing):
    if not isinstance(name, str) or not name.strip():
        raise ValueError("Enter a name for the entry.")
    name = name.strip()
    if name in existing:
        raise ValueError(f'"{name}" already exists.')
    return name


def apply_entry_op(doc, editor_id, labels, op):
    """Apply one operation; `labels` (GUI-only names: a list by position for 'aot' entries, a name → label dict
    for named ones) is updated in place.

    Operations: add [name], remove index, move index to, duplicate index [name], label index text.
    Field edits go through values.apply_value on entry_at(...).
    """
    mode = ENTRY_EDITORS[editor_id][3]
    kind = op.get("op")
    if mode == "aot":
        count = len(entries(doc, editor_id))
        labels[:] = (labels + [""] * count)[:count]
    if kind == "add":
        if mode == "aot":
            container(doc, editor_id, True).append(tomlkit.table())
            labels.append("")
        else:
            c = container(doc, editor_id, True)
            c[_entry_name(op.get("name"), set(c.keys()))] = tomlkit.table()
    elif kind == "remove":
        index = op.get("index")
        entry_at(doc, editor_id, index)
        c = container(doc, editor_id)
        if mode == "aot":
            del c[index]
            labels.pop(index)
        else:
            name = entries(doc, editor_id)[index][0]
            del c[name]
            labels.pop(str(name), None)
            if len(c) == 0:  # an empty [output] super-table isn't written out; drop it so the save check agrees
                delp(doc, editor_path(editor_id))
    elif kind == "move":
        if mode != "aot":
            raise ValueError("Only rules can be reordered.")
        index, target = op.get("index"), op.get("to")
        entry_at(doc, editor_id, index)
        entry_at(doc, editor_id, target)
        c = container(doc, editor_id)
        c.insert(target, c.pop(index))
        labels.insert(target, labels.pop(index))
    elif kind == "duplicate":
        index = op.get("index")
        clone = copy.deepcopy(entry_at(doc, editor_id, index))
        c = container(doc, editor_id)
        if mode == "aot":
            c.insert(index + 1, clone)
            labels.insert(index + 1, "")
        else:
            c[_entry_name(op.get("name"), set(c.keys()))] = clone
    elif kind == "label":
        index, text = op.get("index"), op.get("text")
        entry_at(doc, editor_id, index)
        if not isinstance(text, str):
            raise ValueError("Display names must be text.")
        text = " ".join(text.split())
        if mode == "aot":
            labels[index] = text
        else:
            name = str(entries(doc, editor_id)[index][0])
            if text:
                labels[name] = text
            else:
                labels.pop(name, None)
    else:
        raise ValueError(f"Unknown entry operation: {kind}")


def map_rows(doc, editor_id):
    """Return [(name, value)] of a map editor, values as TOML items."""
    table = getp(doc, editor_path(editor_id))
    if table is MISSING or not hasattr(table, "items"):
        return []
    return list(table.items())


def map_value_from_ui(editor_id, name, text):
    """Parse and check one map value: plain text for environment, TOML for curves."""
    kind = MAP_EDITORS[editor_id][3]
    if not isinstance(name, str) or not name.strip():
        raise ValueError(f"{MAP_EDITORS[editor_id][1]}: enter a name.")
    name = name.strip()
    if not isinstance(text, str):
        raise ValueError(f"{name}: expected text.")
    if kind == "string":
        if not ENV_NAME_RE.fullmatch(name):
            raise ValueError(f'Environment: "{name}" is not a valid variable name')
        if name in RESERVED_ENV:
            raise ValueError(f"Environment: {name} is owned by Umbriel and cannot be set here")
        return name, text
    try:
        value = parse_toml_value(text.strip())
    except ValueError as error:
        raise ValueError(f"{name}: invalid TOML value ({error})") from error
    if kind == "array":
        if not isinstance(value, tomlkit.items.Array):
            raise ValueError(f"{name}: expected a TOML array")
        points = py(value)
        if (len(points) != 4 or not all(isinstance(p, (int, float)) and not isinstance(p, bool) for p in points)):
            raise ValueError(f"{name}: Bézier curves need exactly four numbers: [x1, y1, x2, y2]")
        if not (0 <= points[0] <= 1 and 0 <= points[2] <= 1):
            raise ValueError(f"{name}: Bézier curves need x1 and x2 between 0 and 1")
    elif not isinstance(value, (tomlkit.items.InlineTable, tomlkit.items.Table)):
        raise ValueError(f"{name}: expected a TOML table")
    return name, value


def apply_map_op(doc, editor_id, op):
    """Apply set (name, value[, from]) or remove (name) to a map editor."""
    path = editor_path(editor_id)
    kind = op.get("op")
    if kind == "remove":
        table = getp(doc, path)
        if table is not MISSING and op.get("name") in table:
            del table[op["name"]]
        return
    if kind != "set":
        raise ValueError(f"Unknown map operation: {kind}")
    name, value = map_value_from_ui(editor_id, op.get("name"), op.get("value"))
    table = ensure_table(doc, path)
    old = op.get("from")
    if old not in (None, name):
        if name in table:
            raise ValueError(f"{name}: duplicate name")
        if old not in table:
            raise ValueError(f"{old}: no longer exists")
        del table[old]  # like the app's table editors: a renamed row is re-added at the end
        table[name] = value
        return
    if name in table and py(table[name]) == py(value):
        return
    table[name] = value


# ------------------------------------------------------------------ readable entry names
def readable_pattern(value):
    """Drop regex anchors and escaped dots so a match pattern reads like a name."""
    text = str(value)
    if text.startswith("^"):
        text = text[1:]
    if text.endswith("$") and not text.endswith("\\$"):
        text = text[:-1]
    return text.replace("\\.", ".")


def readable_match(key, value):
    """Describe one identifying key, e.g. app id "^org.mozilla.firefox$" as "firefox (app id)"."""
    plain = py(value)
    if key in ("app_id", "title", "namespace"):
        names = []
        for pattern in plain if isinstance(plain, list) else [plain]:
            text = readable_pattern(pattern)
            if key == "app_id" and re.fullmatch(r"[\w-]+(\.[\w-]+){2,}", text):
                text = text.rsplit(".", 1)[1]
            names.append(text)
        kind = {"app_id": "app id", "namespace": "layer"}.get(key, key)
        return f"{', '.join(names)} ({kind})"
    word = key.removeprefix("is_").replace("_", " ")
    if isinstance(plain, bool):
        return word if plain else f"not {word}"
    return f"{word}: {totext(value)}"


def entry_label_info(entry, index, custom_label=""):
    """Return (list text, raw TOML keys for a tooltip, whether the name is automatic) for one rule entry."""
    raw_lines = []
    for p in (("name",), ("index",)):
        v = getp(entry, p)
        if v is not MISSING:
            raw_lines.append(f"{'.'.join(p)} = {totext(v)}")
    m = getp(entry, ("match",))
    if m is not MISSING and hasattr(m, "items"):
        raw_lines.extend(f"match.{k} = {totext(v)}" for k, v in m.items())
    raw = "\n".join(raw_lines)
    number = index + 1
    if custom_label and custom_label.strip():
        return f"{number}. {custom_label.strip()}", raw, False
    name = getp(entry, ("name",))
    if name is not MISSING:
        return f"{number}. {py(name)}", raw, False
    for key in ("app_id", "title", "namespace"):
        v = getp(entry, ("match", key))
        if v is not MISSING:
            return f"{number}. {readable_match(key, v)}", raw, True
    workspace = getp(entry, ("index",))
    if workspace is not MISSING:
        return f"{number}. Workspace {py(workspace)}", raw, True
    if m is not MISSING and hasattr(m, "items") and len(m):
        k = next(iter(m))
        return f"{number}. {readable_match(k, m[k])}", raw, True
    return f"{number}. (matches everything)", raw, True
