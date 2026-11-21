"""Read a config into plain JSON for a UI and apply a recorded change set with the app's save rules."""

import contextlib
import difflib
import hashlib
import json
import os
import re
import subprocess
import tempfile
import tomllib

import tomlkit

from . import entry_ops, keybinds, values
from .backups import create_backup_snapshot
from .fields import TABS
from .included import included_names
from .layout import (
    BANNER_RE,
    add_entry_name_comments,
    group_diff_by_section,
    inline_window_rule_matches,
    move_new_keybinds,
    rebuild_config,
)
from .paths import (
    config_gui_data_dir,
    decode_utf8,
    file_revision,
    labels_file,
    load_all_entry_labels,
    remove_stale_temp_files,
    write_text_file,
)
from .schema import field_schema_option, run_umbriel
from .tomlops import MISSING, getp, py, same_data, totext


def page_field_index():
    """Return {field id: (page, group title, Field)} for every settings-page field."""
    index = {}
    for page, groups in TABS.items():
        for group, fields in groups:
            for field in fields:
                index[".".join(field.path)] = (page, group, field)
    return index


PAGE_FIELDS = page_field_index()
FIELD_PATH_RE = re.compile(r"\b[a-z_][a-z0-9_]*(?:\.[a-z0-9_*]+)+\b")


def entry_labels(config_dir):
    """The stored entry labels with the shape each editor expects (a list for rules, a name → label object for
    named entries); a hand-edited sidecar's wrong-shape value is left out (and so starts over)."""
    labels_all = load_all_entry_labels(config_dir)
    for _, _, path, mode, _, _ in entry_ops.ENTRY_EDITORS.values():
        if path in labels_all and isinstance(labels_all[path], list) != (mode == "aot"):
            del labels_all[path]
    return labels_all


class ConfigSession:
    """One config file plus its GUI sidecars (labels, keybind locks) under the shared GUI data directory."""

    def __init__(self, config_path, data_dir, schema_options=None):
        """`schema_options` is a dict or a function returning one; a function runs on first use, so reading a
        config never waits for `umbriel config schema`."""
        self.path = os.path.abspath(os.path.expanduser(config_path))
        self.data_dir = data_dir
        self.config_dir = config_gui_data_dir(self.path, data_dir)
        self._options = schema_options

    @property
    def options(self):
        if callable(self._options):
            self._options = self._options()
        return self._options or {}

    # ------------------------------------------------------------------ reading
    def lock_path(self):
        return keybinds.lock_file(self.config_dir)

    def revision(self, text_revision=None):
        return {
            "config": text_revision or file_revision(self.path),
            "locks": file_revision(self.lock_path()),
            "labels": file_revision(labels_file(self.config_dir)),
        }

    def load(self):
        """Return (text, parsed document, revision); raise ValueError with a readable message."""
        if os.path.islink(self.path):
            raise ValueError("The config is a symlink; edit its target directly or choose the target file.")
        try:
            with open(self.path, "rb") as f:
                data = f.read()
        except FileNotFoundError as error:
            raise ValueError(
                f"{self.path} does not exist. Copy /usr/share/umbriel/config.toml there first."
            ) from error
        text = decode_utf8(data, self.path)
        try:
            doc = tomlkit.parse(text)
        except tomlkit.exceptions.TOMLKitError as error:
            raise ValueError(f"{self.path} is not valid TOML: {error}") from error
        return text, doc, self.revision(hashlib.sha256(data).hexdigest())

    def default(self, field, schema_path):
        return values.field_default(field, field_schema_option(self.options, schema_path))

    def read(self):
        """Return the whole config as plain JSON-friendly data."""
        text, doc, revision = self.load()
        fields = {}
        for fid, (_, _, field) in PAGE_FIELDS.items():
            current = getp(doc, field.path)
            fields[fid] = values.to_ui(field, current)
        labels_all = entry_labels(self.config_dir)
        editors = {}
        for eid, (_, _, path, mode, _, _) in entry_ops.ENTRY_EDITORS.items():
            editor_fields = entry_ops.editor_fields(eid)
            labels = labels_all.get(path) or ([] if mode == "aot" else {})
            items = []
            for index, item in enumerate(entry_ops.entries(doc, eid)):
                name, table = (None, item) if mode == "aot" else (str(item[0]), item[1])
                if isinstance(labels, dict):
                    custom = labels.get(str(name), "")
                else:
                    custom = labels[index] if index < len(labels) else ""
                if mode == "aot":
                    title, raw, automatic = entry_ops.entry_label_info(table, index, custom)
                else:
                    title, raw, automatic = name, "", False
                items.append({
                    "name": name, "title": title, "raw": raw, "auto": automatic, "label": custom,
                    "values": {
                        fpath: values.to_ui(field, getp(table, field.path))
                        for fpath, field in editor_fields.items()
                        if getp(table, field.path) is not MISSING
                    },
                })
            editors[eid] = items
        maps = {
            eid: [
                [str(name), str(py(value)) if spec[3] == "string" else totext(value)]
                for name, value in entry_ops.map_rows(doc, eid)
            ]
            for eid, spec in entry_ops.MAP_EDITORS.items()
        }
        groups, assignments = keybinds.parse_keybind_groups(text)
        locked = keybinds.load_locked(self.config_dir)
        bindings = keybinds.read_bindings(doc)
        table = getp(doc, ("keybinds",))
        other = [str(k) for k in table if k not in bindings] if table is not MISSING and hasattr(table, "keys") else []
        return {
            "path": self.path,
            "revision": revision,
            "rebuild_default": any(BANNER_RE.match(line) for line in text.splitlines()),
            "fields": fields,
            "editors": editors,
            "maps": maps,
            "included": included_names(py(doc), os.path.dirname(os.path.abspath(self.path))),
            "keybinds": {
                "rows": [
                    {"key": key, "action": action, "opts": opts, "group": assignments.get(key, ""),
                     "locked": key in locked}
                    for key, (action, opts) in bindings.items()
                ],
                "groups": groups,
                "other": other,
            },
        }

    # ----------------------------------------------------------------- applying
    def apply(self, changes):
        """Apply a change set to a fresh parse; return (old text, new text, labels, locks, summary lines)."""
        if not isinstance(changes, dict):
            raise ValueError("Changes must be an object.")
        text, doc, revision = self.load()
        expected = changes.get("revision")
        if expected != revision:
            raise ValueError("The config or its GUI data changed since it was loaded. Reload before saving.")
        summary = []
        labels_all = entry_labels(self.config_dir)
        self._apply_fields(doc, changes.get("fields") or {}, summary)
        labels_changed = self._apply_entries(doc, changes.get("entries") or [], labels_all, summary)

        for op in changes.get("maps") or []:
            if not isinstance(op, dict) or op.get("editor") not in entry_ops.MAP_EDITORS:
                raise ValueError("Invalid map operation.")
            entry_ops.apply_map_op(doc, op["editor"], op)
            page = entry_ops.MAP_EDITORS[op["editor"]][0]
            summary.append({"page": page, "label": f"{op.get('op')} {op.get('name')}"})

        locks = None
        binds = changes.get("keybinds")
        new_keys = []
        groups_payload = None
        if binds is not None:
            locks, new_keys, groups_payload = self._apply_keybinds(doc, binds, summary)
            if any(group.strip() for group in groups_payload[0]) and getp(doc, ("keybinds",)) is MISSING:
                doc["keybinds"] = tomlkit.table()  # the group comment needs a [keybinds] header to live under

        inline_window_rule_matches(doc)
        aot_labels = {
            spec[2]: labels_all.get(spec[2], [])
            for spec in entry_ops.ENTRY_EDITORS.values() if spec[3] == "aot"
        }
        new_text = add_entry_name_comments(tomlkit.dumps(doc), aot_labels)
        rebuild = changes.get("rebuild")
        if rebuild is None:
            rebuild = any(BANNER_RE.match(line) for line in text.splitlines())
        rebuilt = False
        if rebuild:
            try:
                new_text = rebuild_config(new_text)
                rebuilt = True
            except Exception as error:  # like the app: never block a save on the optional rebuild
                summary.append({"page": "File", "label": f"Structure rebuild skipped ({error})"})
        if not rebuilt:
            new_text = move_new_keybinds(new_text, new_keys)
        if groups_payload is not None:
            new_text = keybinds.write_keybind_groups(new_text, *groups_payload)
            if any(group.strip() for group in groups_payload[0]) and keybinds.KEYBIND_GROUPS_MARKER not in new_text:
                summary.append({"page": "Keybinds",
                                "label": "Groups not stored (the file has no [keybinds] header to keep them under)"})
        # The steps after tomlkit.dumps edit plain text; never hand back a file that lost or changed a setting.
        try:
            written = tomllib.loads(new_text)
        except tomllib.TOMLDecodeError as error:
            raise ValueError(f"The edited config would not be valid TOML ({error}). Nothing was written.") from error
        if not same_data(written, doc.unwrap()):
            raise ValueError("The edited config would not contain the same settings. Nothing was written.")
        return text, new_text, (labels_all if labels_changed else None), locks, summary

    def _apply_fields(self, doc, fields, summary):
        for fid, change in fields.items():
            if fid not in PAGE_FIELDS or not isinstance(change, dict):
                raise ValueError(f"Unknown setting: {fid}")
            page, group, field = PAGE_FIELDS[fid]
            option = field_schema_option(self.options, fid)
            default = values.field_default(field, option)
            if change.get("unset"):
                if not field.opt:
                    raise ValueError(f"{field.label} cannot be unset.")
                new = None
            else:
                new = values.from_ui(field, change.get("value"), option)
            old = getp(doc, field.path)
            values.apply_value(doc, field, new, default)
            summary.append({
                "page": page, "group": group, "label": field.label, "id": fid,
                "old": describe(old), "new": describe(getp(doc, field.path)),
            })

    def _apply_entries(self, doc, ops, labels_all, summary):
        """Apply entry operations; update `labels_all` in place and return whether any label changed."""
        changed = False
        for op in ops:
            if not isinstance(op, dict) or op.get("editor") not in entry_ops.ENTRY_EDITORS:
                raise ValueError("Invalid entry operation.")
            eid = op["editor"]
            page, _, path, mode, _, _ = entry_ops.ENTRY_EDITORS[eid]
            before = labels_all.get(path) or ([] if mode == "aot" else {})
            labels = list(before) if isinstance(before, list) else dict(before)
            if op.get("op") in ("set", "unset"):
                field = entry_ops.editor_fields(eid).get(op.get("field"))
                if field is None:
                    raise ValueError(f"{page}: unknown setting {op.get('field')}")
                schema_path = entry_ops.schema_prefix(eid) + "." + ".".join(field.path)
                option = field_schema_option(self.options, schema_path)
                new = None if op["op"] == "unset" else values.from_ui(field, op.get("value"), option)
                if new is None and not field.opt:
                    raise ValueError(f"{field.label} cannot be unset.")
                table = entry_ops.entry_at(doc, eid, op.get("index"))
                values.apply_value(table, field, new, values.field_default(field, option))
                summary.append({"page": page, "label": f"Entry {op['index'] + 1}: {field.label}",
                                "new": describe(getp(table, field.path))})
            else:
                entry_ops.apply_entry_op(doc, eid, labels, op)
                summary.append({"page": page, "label": describe_entry_op(op)})
            if before != labels and (mode != "aot" or any(before + labels)):
                labels_all[path] = labels
                changed = True
        return changed

    def _apply_keybinds(self, doc, binds, summary):
        if not isinstance(binds, dict) or not isinstance(binds.get("rows"), list):
            raise ValueError("Invalid keybind changes.")
        original = keybinds.read_bindings(doc)
        table = getp(doc, ("keybinds",))
        if table is not MISSING and not hasattr(table, "keys"):
            raise ValueError("keybinds is not a table in the config; fix it in the file first.")
        unparsed = {str(k) for k in table if k not in original} if table is not MISSING else set()
        disk_locks = keybinds.load_locked(self.config_dir)
        rows, assignments = {}, {}
        for row in binds["rows"]:
            if not isinstance(row, dict) or not isinstance(row.get("key"), str) \
                    or not isinstance(row.get("action"), str):
                raise ValueError("Invalid keybind.")
            key, action = row["key"].strip(), row["action"].strip()
            opts = row.get("opts") or {}
            if not key or not action or not isinstance(opts, dict):
                raise ValueError("Every keybind needs a shortcut and an action.")
            for name, value in opts.items():
                if isinstance(value, float) and value.is_integer():
                    opts[name] = int(value)
                elif not isinstance(value, (bool, int, str)):
                    raise ValueError(f'Keybind "{key}": invalid option {name}.')
            if key in rows:
                raise ValueError(f'Keybind "{key}" is listed twice.')
            keybinds.check_action(key, action)
            rows[key] = (action, opts)
            if isinstance(row.get("group"), str) and row["group"].strip():
                assignments[key] = row["group"].strip()
        keybinds.check_shortcut_conflicts(list(rows) + sorted(unparsed))
        new_locks = {k for k in binds.get("locks") or [] if isinstance(k, str)}
        for key in disk_locks & new_locks:
            if key in original and key in rows and rows[key] != original[key]:
                raise ValueError(f'Keybind "{key}" is locked; unlock it before changing it.')
        keep = (disk_locks & new_locks) | unparsed
        for key in keep:
            if key in original and key not in rows:
                rows[key] = original[key]
        keybinds.apply_bindings(doc, rows, original, keep)
        for key, value in rows.items():
            if original.get(key) != value:
                summary.append({"page": "Keybinds", "label": key, "new": value[0],
                                "old": original[key][0] if key in original else None})
        for key in original:
            if key not in rows:
                summary.append({"page": "Keybinds", "label": key, "old": original[key][0], "new": None})
        groups = [g for g in binds.get("groups") or [] if isinstance(g, str)]
        new_keys = [key for key in rows if key not in original]
        return sorted(new_locks), new_keys, (groups, assignments)

    # ---------------------------------------------------------------- preview/save
    def preview(self, changes, validate=True, check=False):
        """Return the diff, readable changes and validation result without writing anything; `check` validates
        the config even when the changes leave it as it is."""
        old, new, _, _, summary = self.apply(changes)
        return self._report(old, new, summary, validate, check)

    def _report(self, old, new, summary, validate, check=False):
        diff = "".join(difflib.unified_diff(
            old.splitlines(keepends=True), new.splitlines(keepends=True),
            fromfile="current", tofile="new", n=2,
        ))
        sections = group_diff_by_section(diff, new) if diff else {}
        return {
            "changed": old != new,
            "summary": summary,
            "sections": [{"title": title, "diff": "".join(lines)} for title, lines in sections.items()],
            "validation": self.validate(new) if validate and (old != new or check) else {"ran": False},
        }

    def validate(self, text):
        """Run `umbriel config validate` on a temporary copy next to the config (so includes resolve).

        A read-only config directory falls back to the GUI data directory; relative includes may then not
        resolve, which is still better than not validating at all."""
        name = None
        try:
            for directory in (os.path.dirname(self.path), self.config_dir):
                try:
                    os.makedirs(directory, exist_ok=True)
                    with tempfile.NamedTemporaryFile(
                        mode="w", encoding="utf-8", dir=directory, prefix=".umbriel-settings-",
                        suffix=".toml", delete=False,
                    ) as handle:
                        name = handle.name
                        handle.write(text)
                    break
                except OSError:  # read-only (EROFS) or not writable (EACCES)
                    if directory == self.config_dir:
                        raise
            try:
                result = run_umbriel(["config", "validate", "-c", name, "--json"], 30, errors="replace")
            except FileNotFoundError:
                return {"ran": False, "reason": "The umbriel command was not found; the config was not validated."}
            except subprocess.TimeoutExpired:
                return {"ran": True, "valid": False,
                        "diagnostics": [{"severity": "error", "message": "Umbriel validation timed out."}]}
        finally:
            if name is not None:
                with contextlib.suppress(OSError):
                    os.unlink(name)
        try:
            report = json.loads(result.stdout)
        except json.JSONDecodeError:
            report = None
        if not isinstance(report, dict) or not isinstance(report.get("valid"), bool) \
                or not isinstance(report.get("diagnostics"), list):
            detail = result.stderr.strip() or result.stdout.strip() or f"exit status {result.returncode}"
            return {"ran": True, "valid": False,
                    "diagnostics": [{"severity": "error", "message": f"Unreadable validation result: {detail}"}]}
        diagnostics = []
        for item in report["diagnostics"]:
            if not isinstance(item, dict):
                continue
            message = str(item.get("message", ""))
            diagnostics.append({
                "severity": str(item.get("severity", "error")),
                "message": message,
                "line": item.get("line") if isinstance(item.get("line"), int) else None,
                "field": next((m for m in FIELD_PATH_RE.findall(message) if m in PAGE_FIELDS), None),
            })
        valid = report["valid"] and result.returncode == 0
        if not valid and not diagnostics:
            diagnostics.append({"severity": "error",
                                "message": result.stderr.strip() or "Umbriel rejected the config."})
        return {"ran": True, "valid": valid, "diagnostics": diagnostics}

    def save(self, changes, validate=True, backup=None):
        """Apply, validate (refusing invalid configs), back up and write atomically; return the report.

        Once the config is written, failures of the GUI's own sidecars (labels, keybind locks) no longer fail
        the save; they are listed in report["warnings"].
        """
        remove_stale_temp_files(os.path.dirname(self.path), os.path.basename(self.path))
        old, new, labels_all, locks, summary = self.apply(changes)
        report = self._report(old, new, summary, validate)
        if validate and report["validation"].get("ran") and not report["validation"].get("valid"):
            report["saved"] = False
            return report
        if self.revision() != changes.get("revision"):
            raise ValueError("The config changed while saving. Reload before retrying.")
        if old != new:
            snapshot = (backup or create_backup_snapshot)(self.path, self.config_dir)
            report["backup"] = snapshot
            if os.path.islink(self.path) or self.revision() != changes.get("revision"):
                raise ValueError("The config changed while saving. Reload before retrying.")
            write_text_file(self.path, new)
        warnings = []
        try:
            if labels_all is not None:
                kept = {key: labels for key, labels in labels_all.items() if any(labels)}
                write_text_file(labels_file(self.config_dir), json.dumps(kept, indent=2))
        except OSError as error:
            warnings.append(f"Rule names could not be saved: {error}.")
        try:
            if locks is not None and sorted(keybinds.load_locked(self.config_dir)) != locks:
                keybinds.save_locked(locks, self.config_dir)
        except OSError as error:
            warnings.append(f"Keybind locks could not be saved: {error}.")
        if warnings:
            report["warnings"] = warnings
        report["saved"] = True
        return report


def describe(value):
    """Short human text for a value in change summaries."""
    if value is MISSING or value is None:
        return None
    plain = py(value)
    if isinstance(plain, bool):
        return "on" if plain else "off"
    if isinstance(plain, (list, dict)):
        return totext(value)
    return str(plain)


ENTRY_OP_TEXT = {
    "remove": "Removed entry {n}",
    "move": "Moved entry {n} to position {to}",
    "duplicate": "Duplicated entry {n}",
}


def describe_entry_op(op):
    kind = op.get("op")
    if kind == "add":
        return "Added entry" + (f" {op['name']}" if op.get("name") else "")
    if kind == "label":
        return f"Renamed entry {op.get('index', 0) + 1} to {op.get('text') or '(automatic)'}"
    if kind in ENTRY_OP_TEXT:
        return ENTRY_OP_TEXT[kind].format(n=op.get("index", 0) + 1, to=op.get("to", 0) + 1)
    return str(kind)
