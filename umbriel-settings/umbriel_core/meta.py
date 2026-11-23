"""Describe pages, groups, fields, editors and actions as plain JSON for a declarative UI."""

from . import entry_ops
from .actions import (
    ACTION_CATEGORIES,
    ARG_HELP,
    RUN_BLOCKED,
    RUN_BLOCKED_SPAWN,
    SUBMAP_REASON,
)
from .cursor_themes import installed_cursor_themes
from .fields import NAV_SECTIONS, OPACITY_SLIDERS, TABS
from .help import CATEGORY_HELP, choice_label, group_help, setting_help_text, split_label
from .keybinds import BIND_BOOL_OPTIONS
from .schema import field_schema_option
from .values import to_ui

# What this version of Umbriel Settings is made for (READMEs list both; tests/test_core.py checks them).
UMBRIEL_VERSION = "0.1.0"  # fields synced against this Umbriel (sync-umbriel-schema)
NOCTALIA_VERSION = "5.4.0"  # oldest Noctalia the plugin runs on; follows plugin_api in plugin.toml

PAGE_KINDS = {
    "User folders": "userdirs",
    "Default apps": "apps",
    "Keybinds": "keybinds",
    "Environment": "map",
    "Animation curves": "map",
}
PAGE_GLYPHS = {
    "User folders": "folder", "Default apps": "apps", "General": "settings", "Appearance": "palette",
    "Colors": "color-swatch", "Animation": "movie", "Animation curves": "vector-bezier",
    "Effects": "sparkles", "Input": "keyboard", "Layout": "layout-grid", "Workspaces": "layout-board",
    "Keybinds": "command", "Window rules": "app-window", "Layer rules": "stack-2",
    "Workspace rules": "layout-columns", "Outputs": "device-desktop", "Scratchpads": "notes",
    "Input devices": "mouse", "Security rules": "shield-lock", "Environment": "variable",
}


# fields that name an output: the UI offers the config's outputs and the connected ones (`names_from`)
OUTPUT_FIELDS = {"general.xwayland_primary_output", "input.tablet.map_to_output", "input.touch.map_to_output",
                 "window_rule[].default_output", "workspace[].output"}

# path fields with a Browse… button: schema path → file chooser options (`relative`: written relative to the
# config's folder when the file is inside it)
FILE_FIELDS = {
    "effects.preset.<name>.shader": {"title": "Choose a shader file", "relative": True},
    "output.<name>.color_profile": {"title": "Choose an ICC profile", "filter": ["ICC profiles", "*.icc *.icm"],
                                    "start": "/usr/share/color/icc"},
    "include.files": {"title": "Choose a config file to include", "filter": ["TOML files", "*.toml"]},
    "include.optional.files": {"title": "Choose a config file to include", "filter": ["TOML files", "*.toml"]},
    # `command`: Browse… lists the installed apps (their Exec command) and offers files for other programs
    "general.autostart": {"title": "Choose a program to start", "start": "~", "command": True},
}

# output modes the UI offers as Resolution and Refresh rate lists while the output is connected
MODE_FIELDS = {"output.<name>.mode"}

# keyboard keys the XKB picker edits: schema path → which part
XKB_FIELDS = {
    f"{prefix}.{part}": part
    for prefix in ("input.keyboard", "input.device[]") for part in ("layout", "variant", "options")
}


def describe_field(field, category, group, schema_options, schema_path, cursor_themes, entry=False):
    """Describe one field. `default` is what Umbriel uses when the key is absent (None when unknown);
    `initial` is the value a control starts from when the user sets the key."""
    option = field_schema_option(schema_options, schema_path)
    if option is not None and "default" in option:
        default = option["default"]
    elif not entry and not schema_options:
        default = field.default  # no installed schema: the app's fallback is the best guess for page fields
    else:
        default = None  # rule fields have no default: an absent key means "any" or "unchanged"
    kind = field.kind
    label, notes = split_label(field.label)
    info = {
        "label": label,
        "kind": kind,
        "path": ".".join(field.path),
        "opt": bool(field.opt),
        "default": to_ui(field, default) if default is not None else None,
        "initial": to_ui(field, field.default) if field.default not in (None, "") else None,
        "restart": "(restart)" in field.label or "(restart)" in group,
    }
    choices = None
    if kind in ("choice", "combo"):
        choices = list(field.extra or [])
        if option is not None and option.get("values"):
            choices = list(option["values"])
        if field.path == ("input", "cursor", "theme"):
            choices = cursor_themes
        info["choices"] = [str(c) for c in choices]
        if kind == "choice":  # combo values (layouts, theme names) are names: shown as they are
            info["choice_labels"] = [choice_label(c) for c in choices]
    if kind in ("int", "float"):
        low, high = None, None
        if isinstance(field.extra, (list, tuple)) and len(field.extra) == 2:
            low, high = field.extra
        if option is not None and "min" in option and "max" in option:
            low, high = option["min"], option["max"]
        info["min"], info["max"] = low, high
    if kind == "table":
        info["keys"] = list(field.extra or ())
    if kind == "color" and field.path in OPACITY_SLIDERS:
        info["opacity"] = True
    # curve and effect names also come from the config's own [animation.beziers]/[animation.springs] and
    # effect presets/pools: the UI adds them to the choices (`names_from`), keeping "Custom…" for the rest
    name_format = option.get("format") if option is not None and option.get("type") == "string" else None
    if name_format == "curve" and kind == "combo":
        info["names_from"] = "curve"
    elif name_format == "effect" and kind == "str":
        info["kind"], info["choices"], info["names_from"] = "combo", [""], "effect"
    elif schema_path in OUTPUT_FIELDS and kind == "str":
        # "" (none) is a choice only where it is the default; rule fields without a key show "Not set"
        info["kind"], info["names_from"] = "combo", "output"
        info["choices"] = [""] if default == "" else []
    elif option is not None and option.get("format") == "effect":
        info["placeholder"] = "Effect preset name"
    if schema_path in XKB_FIELDS:
        info["picker"], info["xkb"] = "xkb", XKB_FIELDS[schema_path]
    elif schema_path in FILE_FIELDS:
        info["picker"], info["file"] = "file", FILE_FIELDS[schema_path]
    elif schema_path in MODE_FIELDS:
        info["picker"] = "mode"
    info.update(notes)
    # with nothing better to show in an empty box, the hint goes there (and not on the status line too)
    if ("hint" in notes and kind in ("str", "strorlist", "raw", "combo") and not info.get("placeholder")
            and info["default"] is None and info["initial"] is None):
        hint = info.pop("hint")
        info["placeholder"] = hint[5:] if hint.startswith("e.g. ") else hint
    info["help"] = setting_help_text(field, group)
    info["search"] = " ".join([field.label, info["path"], group, category, info["help"]]).casefold()
    return info


def group_info(page, title, ids):
    """A settings group; "(restart)" leaves the title and becomes a flag (shown as a glyph)."""
    info = {"title": title.replace(" (restart)", ""), "help": group_help(page, title), "fields": ids}
    if "(restart)" in title:
        info["restart"] = True
    return info


def build_meta(schema_options, schema_info=None, plugin_version=""):
    """Return the metadata document; `schema_options` maps schema paths to options (may be empty)."""
    themes = installed_cursor_themes()
    fields, pages = {}, {}
    for page, groups in TABS.items():
        page_groups = []
        for title, group_fields in groups:
            ids = []
            for field in group_fields:
                fid = ".".join(field.path)
                fields[fid] = describe_field(field, page, title, schema_options, fid, themes)
                ids.append(fid)
            page_groups.append(group_info(page, title, ids))
        pages[page] = {"kind": "form", "groups": page_groups}
    editors = {}
    for eid, (page, title, path, mode, groups, _) in entry_ops.ENTRY_EDITORS.items():
        prefix = entry_ops.schema_prefix(eid)
        editor_groups = []
        for group_title, group_fields in groups:
            ids = []
            for field in group_fields:
                fpath = ".".join(field.path)
                fields[f"{eid}:{fpath}"] = describe_field(
                    field, page, group_title, schema_options, f"{prefix}.{fpath}", themes, entry=True)
                ids.append(f"{eid}:{fpath}")
            editor_groups.append(group_info(page, group_title, ids))
        editors[eid] = {"page": page, "title": title, "path": path, "mode": mode, "groups": editor_groups}
        pages.setdefault(page, {"kind": "entries", "editors": []})["editors"].append(eid)
    maps = {
        eid: {"page": page, "title": title, "path": path, "value": kind}
        for eid, (page, title, path, kind) in entry_ops.MAP_EDITORS.items()
    }
    for eid, spec in maps.items():
        pages.setdefault(spec["page"], {"kind": "map", "maps": []})["maps"].append(eid)
    for page, kind in PAGE_KINDS.items():
        pages.setdefault(page, {"kind": kind})
    for page, info in pages.items():
        info["help"] = CATEGORY_HELP.get(page, "")
        info["glyph"] = PAGE_GLYPHS.get(page, "settings")
    return {
        "version": plugin_version,
        "targets": {"umbriel": UMBRIEL_VERSION, "noctalia": NOCTALIA_VERSION},
        "schema": schema_info or {"available": False},
        "nav": [
            {"title": title, "pages": names, "help": CATEGORY_HELP.get(title, "")}
            for title, names in NAV_SECTIONS
        ],
        "pages": pages,
        "fields": fields,
        "editors": editors,
        "maps": maps,
        "actions": {
            "categories": [[name, [[a, d] for a, d in items]] for name, items in ACTION_CATEGORIES],
            "args": ARG_HELP,
            "options": [[name, label] for name, label in BIND_BOOL_OPTIONS],
            "blocked": {"heads": RUN_BLOCKED, "spawn": RUN_BLOCKED_SPAWN, "submap": SUBMAP_REASON},
        },
    }
