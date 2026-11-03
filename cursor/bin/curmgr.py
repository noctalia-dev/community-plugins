#!/usr/bin/env python3
"""curmgr - cursor theme engine for the Noctalia cursor plugin.

Every subcommand prints exactly one JSON object on stdout, so the Luau side
never has to parse text. All binary cursor work is delegated to win2xcur,
which is pure Python; nothing here decodes .cur/.ani/Xcursor by hand.

Image-dependent subcommands import wand/win2xcur lazily, so listing and
applying themes keep working on a box where ImageMagick is missing.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

HOME = Path.home()
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME") or HOME / ".config")
DATA = Path(os.environ.get("XDG_DATA_HOME") or HOME / ".local" / "share")
CACHE = Path(os.environ.get("XDG_CACHE_HOME") or HOME / ".cache")


def _env_path(var: str, default: Path) -> Path:
    """A path the panel's settings may override. The panel exports only the
    settings that are set, so an unset var keeps the XDG default - and a
    keybind can export the same names with the shell stopped."""
    value = os.environ.get(var, "").strip()
    return Path(value).expanduser() if value else default


def _env_dirs(var: str, suffix: str = "") -> list[Path]:
    return [Path(d).expanduser() / suffix for d in os.environ.get(var, "").split(":") if d]


# Where themes are installed, and the only place `remove` may delete from;
# main() refuses one that is not inside $HOME. Anywhere but the two standard
# places, apply puts it on XCURSOR_PATH and mounts it for Flatpak, or apps
# would never see the themes listed here.
USER_ICONS = _env_path("CURMGR_INSTALL_DIR", DATA / "icons")
# Xcursor's own lookup order, so the first theme of a name here is the one apps
# load. XDG_DATA_DIRS and XCURSOR_PATH are how NixOS and Guix expose their
# profiles' themes; a fixed /usr/share/icons found none there.
ICON_DIRS = list(dict.fromkeys([
    USER_ICONS, DATA / "icons", HOME / ".icons",
    *_env_dirs("CURMGR_ICON_DIRS"),
    *_env_dirs("XCURSOR_PATH"),
    *(_env_dirs("XDG_DATA_DIRS", "icons") if os.environ.get("XDG_DATA_DIRS")
      else [Path("/usr/local/share/icons"), Path("/usr/share/icons")]),
]))
ENV_CONF = CONFIG / "environment.d" / "90-xcursor.conf"
PREVIEW_DIR = CACHE / "curmgr" / "preview"
# Rendered source files from the last scan, so the panel's mapping grid can
# show every candidate file, not just the ones a role claimed. Cleared on
# every scan, never accumulates.
IMPORT_SOURCE_DIR = CACHE / "curmgr" / "import-sources"
# Rendered role previews from the last scan, so the grid shows what each
# role currently holds (inf-mapped, heuristic-mapped, or user-overridden).
IMPORT_ROLE_DIR = CACHE / "curmgr" / "import-roles"
# Build gets its own pair: the panel can hold an Import grid and a Build grid at
# the same time, and each render wipes its directory, so sharing one would blank
# the other tab's thumbnails the moment you scanned here.
BUILD_SOURCE_DIR = CACHE / "curmgr" / "build-sources"
BUILD_ROLE_DIR = CACHE / "curmgr" / "build-roles"

NOMINAL_SIZES = (24, 32, 48, 64, 96)
MANAGED_TEXT = "Managed by the Noctalia cursor plugin - edits here are overwritten."
# Prefix on every config line the plugin comments out, so `uninstall` restores
# exactly those and never a comment of the user's own.
DISABLED_TAG = "cursor plugin:"

# Slots shown in the preview strip, each with fallbacks across naming eras.
PREVIEW_SLOTS = [
    ["default", "left_ptr", "arrow", "top_left_arrow"],
    ["pointer", "hand2", "hand1", "pointing_hand"],
    ["text", "xterm", "ibeam"],
    ["wait", "watch"],
    ["ns-resize", "sb_v_double_arrow", "size_ver"],
    ["not-allowed", "crossed_circle", "circle", "forbidden"],
]

# Filename tokens -> Windows cursor role. Only used when a pack ships no .inf.
# Ambiguous words ("pointer", "busy", "no") are deliberately absent: a wrong
# confident guess is worse than leaving the role unmapped for the UI to fix.
# "select" is deliberately absent: Windows ends six of its fifteen names with
# it - Normal, Alternate, Help, Text, Precision, Link - so it identifies nothing.
ROLE_HINTS = {
    "arrow": ["arrow", "normal", "default", "standard"],
    "help": ["help", "question"],
    "working": ["working", "appstarting", "starting", "progress", "background"],
    "wait": ["wait", "hourglass", "loading", "busy"],
    "crosshair": ["crosshair", "cross", "precision"],
    "text": ["text", "ibeam", "beam"],
    "pen": ["pen", "handwriting", "pencil", "write"],
    # "unava" rather than the full word: packs misspell it, and differently each
    # time - unavaliable in one, unavailiable in another pack's .inf.
    "unavailable": ["unava", "forbidden", "nodrop", "notallowed", "denied"],
    "size_ns": ["ns", "vert", "vertical", "sizens", "updown"],
    "size_ew": ["ew", "we", "horz", "horizontal", "sizewe", "leftright"],
    # "diagonalresize" unnumbered: some packs number only the second one. It is
    # a substring of "diagonalresize2", so the longest-hint tie-break below is
    # what keeps the numbered sibling on its own role.
    "size_nwse": ["nwse", "dgn1", "diag1", "diagonal1", "fdiag", "diagonalresize",
                  "diagonalresize1"],
    "size_nesw": ["nesw", "dgn2", "diag2", "diagonal2", "bdiag", "diagonalresize2"],
    "move": ["move", "fleur", "sizeall", "pan"],
    "up_arrow": ["up", "uparrow", "alternate", "alternative", "alt"],
    "link": ["link", "hand"],
    # No "location"/"person": win2xcur has the roles but Xcursor has no name to
    # write them under, so a hint would report a mapping that produces nothing.
}

# Xcursor's own names, for sources already named the Linux way - a PNG dump of
# an existing theme is left_ptr.png, xterm.png, sb_h_double_arrow.png. A whole
# filename equal to one is as certain as a file named after its role. Only each
# role's own names: win2xcur's XCURSOR_ALIASES also points dozens of unrelated
# names (copy, top_left_corner, zoom-in...) at the arrow as a fallback, and
# taking those as matches would hand the arrow to copy.png. "pointer" and
# "circle" stay out for the same reason they are not hints: a Windows pack's
# "Pointer.cur" is its arrow, and some themes draw "circle" as a plain ring.
XCURSOR_NAMES = {
    "arrow": ["left_ptr", "default", "top_left_arrow"],
    "help": ["question_arrow", "left_ptr_help", "whats_this"],
    "working": ["left_ptr_watch", "progress", "half-busy"],
    "wait": ["watch"],
    "crosshair": ["crosshair", "cross"],
    "text": ["xterm", "ibeam"],
    "pen": ["pencil"],
    "unavailable": ["crossed_circle", "not-allowed", "forbidden"],
    "size_ns": ["sb_v_double_arrow", "v_double_arrow", "ns-resize", "size_ver"],
    "size_ew": ["sb_h_double_arrow", "h_double_arrow", "ew-resize", "size_hor"],
    "size_nwse": ["bd_double_arrow", "nwse-resize", "size_fdiag"],
    "size_nesw": ["fd_double_arrow", "nesw-resize", "size_bdiag"],
    "move": ["fleur", "size_all", "all-scroll"],
    "up_arrow": ["sb_up_arrow", "up-arrow"],
    "link": ["hand2", "pointing_hand"],
}


class Fail(Exception):
    """Anything the user should see as {"ok": false, "error": ...}."""


# --------------------------------------------------------------------------
# theme discovery
# --------------------------------------------------------------------------

def _index_field(index: Path, field: str) -> str:
    if not index.is_file():
        return ""
    pattern = re.compile(rf"^\s*{field}\s*=\s*(.+?)\s*$", re.I | re.M)
    match = pattern.search(index.read_text(errors="replace"))
    return match.group(1) if match else ""


def list_themes() -> list[dict]:
    themes: dict[str, dict] = {}
    for root in ICON_DIRS:
        if not root.is_dir():
            continue
        for entry in sorted(root.iterdir()):
            # Hidden entries are write_theme()'s staging leftovers, never themes.
            if entry.name.startswith("."):
                continue
            cursors = entry / "cursors"
            if entry.name in themes or not cursors.is_dir():
                continue
            files = [f for f in cursors.iterdir() if f.is_file() or f.is_symlink()]
            if not files:
                continue
            index = entry / "index.theme"
            themes[entry.name] = {
                "name": entry.name,
                "title": _index_field(index, "Name") or entry.name,
                "path": str(entry),
                "count": len(files),
                "inherits": _index_field(index, "Inherits"),
                # Only themes under $HOME may be removed by this tool.
                "removable": _is_under(entry, USER_ICONS),
            }
    return list(themes.values())


def _is_under(path: Path, parent: Path) -> bool:
    try:
        path.resolve().relative_to(parent.resolve())
        return True
    except (ValueError, OSError):
        return False


def find_theme(name: str) -> Path:
    for root in ICON_DIRS:
        candidate = root / name
        if (candidate / "cursors").is_dir():
            return candidate
    raise Fail(f"cursor theme not found: {name}")


# --------------------------------------------------------------------------
# reading current state
# --------------------------------------------------------------------------

def _gsettings(key: str) -> str | None:
    """The key's value, or None when gsettings can't be read at all: not
    installed, or installed without the org.gnome.desktop.interface schema."""
    if not shutil.which("gsettings"):
        return None
    try:
        proc = subprocess.run(
            ["gsettings", "get", "org.gnome.desktop.interface", key],
            capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout.strip().strip("'\"")


def _ini_value(path: Path, key: str) -> str:
    if not path.is_file():
        return ""
    match = re.search(rf"^\s*{key}\s*=\s*(.+?)\s*$", path.read_text(errors="replace"), re.I | re.M)
    return match.group(1) if match else ""


def read_current() -> dict:
    env = ENV_CONF.read_text(errors="replace") if ENV_CONF.is_file() else ""
    env_theme = re.search(r"^XCURSOR_THEME=(.*)$", env, re.M)

    # On a box with several compositor configs the panel shows the first row's
    # state, in COMPOSITORS declaration order; they only disagree if one was
    # hand-edited.
    states = {key: _read_compositor(spec) for key, spec in detected_compositors().items()}
    first = next(iter(states.values()), {})
    layers = {key: state["theme"] for key, state in states.items()}
    # Without a working gsettings (no binary, or no schema) that layer can never
    # be written, so it contributes no key - like an undetected compositor. A key
    # holding "" would make `consistent` permanently false.
    gsettings_theme = _gsettings("cursor-theme")
    if gsettings_theme is not None:
        layers["gsettings"] = gsettings_theme
    if shutil.which("flatpak"):
        layers["flatpak"] = _ini_value(DATA / "flatpak" / "overrides" / "global", "XCURSOR_THEME")
    layers |= {
        "gtk3": _ini_value(CONFIG / "gtk-3.0" / "settings.ini", "gtk-cursor-theme-name"),
        "gtk4": _ini_value(CONFIG / "gtk-4.0" / "settings.ini", "gtk-cursor-theme-name"),
        "xdg_default": _index_field(HOME / ".icons" / "default" / "index.theme", "Inherits"),
        "environment": env_theme.group(1).strip() if env_theme else "",
    }
    present = [v for v in layers.values() if v]
    return {
        "ok": True,
        "theme": first.get("theme") or layers.get("gsettings") or layers["gtk3"],
        "size": first.get("size") or int(_gsettings("cursor-size") or 24),
        "hide_when_typing": bool(first.get("hide_when_typing")),
        "hide_after_inactive_ms": first.get("hide_after_inactive_ms", 0),
        "layers": layers,
        # Layers that disagree are the exact bug this tool exists to fix.
        "consistent": len(set(present)) <= 1 and len(present) == len(layers),
        "session_env": {
            "XCURSOR_THEME": os.environ.get("XCURSOR_THEME", ""),
            "XCURSOR_SIZE": os.environ.get("XCURSOR_SIZE", ""),
        },
    }


# --------------------------------------------------------------------------
# applying
# --------------------------------------------------------------------------

def _ms_to_s(ms: int) -> int:
    """Milliseconds to whole seconds, rounding up.

    Hyprland and mango measure this in seconds and read 0 as "never hide", so
    anything the user asked for must survive as at least 1 - rounding down (or
    to-nearest) turns a 300ms delay into the off switch.
    """
    return -(-ms // 1000)


# Theme names are directory names, and imported or installed ones often have
# spaces ("DIM Violet") or even quotes. niri's KDL and sway's config both take a
# double-quoted string with backslash escapes. Hyprland reads the raw rest of the
# line but starts a comment at any `#`, so it writes `##` (its literal `#`);
# Mango reads the raw rest of the line. Each row's `decode` undoes its encoding.
def _quoted(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] == '"':
        return re.sub(r"\\(.)", r"\1", value[1:-1])
    return value


def _render_niri(theme: str, size: int, hide_typing: bool, hide_ms: int, config_text: str) -> str:
    lines = ["cursor {", f"    xcursor-theme {_quoted(theme)}", f"    xcursor-size {size}"]
    if hide_typing:
        lines.append("    hide-when-typing")
    if hide_ms > 0:
        lines.append(f"    hide-after-inactive-ms {hide_ms}")
    lines.append("}")
    # niri allows only one top-level `environment` node, so leave XCURSOR_* to
    # environment.d when the user already owns that block.
    if not re.search(r"^environment\s*\{", config_text, re.M):
        lines += ["environment {", f"    XCURSOR_THEME {_quoted(theme)}",
                  f'    XCURSOR_SIZE "{size}"', "}"]
    return "\n".join(lines) + "\n"


def _render_hyprland(theme: str, size: int, hide_typing: bool, hide_ms: int, config_text: str) -> str:
    # Hyprland has no cursor-theme option: the theme travels as XCURSOR_* env,
    # and `hyprctl setcursor` (see the reload argv) is what moves the pointer
    # now rather than at next login. Both hide keys are always written, because
    # the parser is last-wins and an omitted key would leave an earlier one of
    # the user's standing when the panel turns the toggle off.
    return "\n".join([
        f"env = XCURSOR_THEME,{theme.replace('#', '##')}",
        f"env = XCURSOR_SIZE,{size}",
        "cursor {",
        f"    hide_on_key_press = {'true' if hide_typing else 'false'}",
        # cursor:inactive_timeout is a float in seconds, capped at 20 upstream.
        f"    inactive_timeout = {min(20, _ms_to_s(hide_ms))}",
        "}",
    ]) + "\n"


def _render_sway(theme: str, size: int, hide_typing: bool, hide_ms: int, config_text: str) -> str:
    # sway's hide_cursor takes milliseconds like niri, but rejects anything
    # between 1 and 99; 0 is the documented "never hide".
    idle = 0 if hide_ms <= 0 else max(100, hide_ms)
    return "\n".join([
        f"seat * xcursor_theme {_quoted(theme)} {size}",
        f"seat * hide_cursor when-typing {'enable' if hide_typing else 'disable'}",
        f"seat * hide_cursor {idle}",
    ]) + "\n"


def _render_mango(theme: str, size: int, hide_typing: bool, hide_ms: int, config_text: str) -> str:
    return "\n".join([
        f"cursor_theme={theme}",
        f"cursor_size={size}",
        f"cursor_hide_on_keypress={1 if hide_typing else 0}",
        f"cursor_hide_timeout={_ms_to_s(hide_ms)}",
    ]) + "\n"


def _append_include(text: str, line: str, comment: str) -> str | None:
    """The config with the include line appended, or None if it has it already."""
    if re.search(rf"^\s*{re.escape(line)}\s*$", text, re.M):
        return None
    return text.rstrip("\n") + f"\n\n{comment} {MANAGED_TEXT}\n{line}\n"


def _toml_add_include(text: str, entry: str, comment: str) -> str | None:
    """Add `entry` last to [include.optional] files, creating what is missing.

    Last, so it beats Noctalia's own include. Keeps the array's style: one
    entry per line stays that way, an inline array stays inline.
    """
    if re.search(rf"^[^#\n]*{re.escape(entry)}", text, re.M):
        return None
    header = re.search(r"^\[include\.optional\][ \t]*$", text, re.M)
    if not header:
        return (text.rstrip("\n") + f"\n\n{comment} {MANAGED_TEXT}\n"
                f"[include.optional]\nfiles = [{entry}]\n")
    end = re.compile(r"^\s*\[", re.M).search(text, header.end())
    section_end = end.start() if end else len(text)
    files = re.compile(r"^(\s*files\s*=\s*\[)([^\]]*)\]", re.M).search(
        text, header.end(), section_end)
    if not files:
        return text[:header.end()] + f"\nfiles = [{entry}]" + text[header.end():]
    body = files.group(2).rstrip()
    if "\n" in files.group(2):
        body = f"{body}{'' if body.endswith(',') or not body.strip() else ','}\n  {entry},\n"
    else:
        body = f"{body}, {entry}" if body.strip() else entry
    return text[:files.start(2)] + body + text[files.end(2):]


def _remove_appended_include(text: str, line: str, comment: str) -> str | None:
    """Undo _append_include() exactly, or None if it was never applied."""
    block = f"\n\n{comment} {MANAGED_TEXT}\n{line}\n"
    return text.replace(block, "\n", 1) if block in text else None


def _toml_remove_include(text: str, entry: str, comment: str) -> str | None:
    """Undo _toml_add_include(), whichever of its three shapes it took."""
    created = f"\n\n{comment} {MANAGED_TEXT}\n[include.optional]\nfiles = [{entry}]\n"
    if created in text:
        out = text.replace(created, "\n", 1)
        return out if out.strip() else ""
    e = re.escape(entry)
    for pattern in (rf"\n[ \t]*{e},", rf",[ \t]*{e}", rf"\nfiles = \[{e}\]", e):
        out, n = re.subn(pattern, "", text, count=1)
        if n:
            return out
    return None


def _restore_commented(text: str, comment: str) -> str:
    return re.sub(rf"^{re.escape(comment)} {re.escape(DISABLED_TAG)} ", "", text, flags=re.M)


# ponytail: line-level, so dotted keys (`cursor.theme =` under [input]) and
# inline tables are not seen, and a user who writes the cursor that way keeps
# winning over the include. Reading the merged config with tomllib would catch it.
def _comment_toml_keys(text: str, sections: dict[str, list[str]], comment: str) -> str:
    """Comment out the listed keys of the listed [section]s, nothing else."""
    out, section, changed = [], "", False
    for line in text.splitlines():
        header = re.match(r"^\s*\[+\s*([^\]]+?)\s*\]+\s*(?:#.*)?$", line)
        if header:
            section = header.group(1)
        else:
            key = re.match(r"^\s*([A-Za-z0-9_-]+)\s*=", line)
            if key and key.group(1) in sections.get(section, ()):
                line, changed = f"{comment} {DISABLED_TAG} {line}", True
        out.append(line)
    return "\n".join(out) + "\n" if changed else text


def _render_umbriel(theme: str, size: int, hide_typing: bool, hide_ms: int, config_text: str) -> str:
    # TOML basic strings take the same \\ and \" escapes as KDL. [environment]
    # needs an Umbriel restart; [input.cursor] reloads on save.
    return "\n".join([
        "[input.cursor]",
        f"theme = {_quoted(theme)}",
        f"size = {size}",
        f"hide_when_typing = {'true' if hide_typing else 'false'}",
        f"hide_timeout_ms = {min(3600000, max(0, hide_ms))}",
        "",
        "[environment]",
        f"XCURSOR_THEME = {_quoted(theme)}",
        f'XCURSOR_SIZE = "{size}"',
    ]) + "\n"


NIRI_CONFIG = _env_path("CURMGR_NIRI_CONFIG", CONFIG / "niri" / "config.kdl")
HYPRLAND_CONFIG = _env_path("CURMGR_HYPRLAND_CONFIG", CONFIG / "hypr" / "hyprland.conf")
SWAY_CONFIG = _env_path("CURMGR_SWAY_CONFIG", CONFIG / "sway" / "config")
MANGO_CONFIG = _env_path("CURMGR_MANGO_CONFIG", CONFIG / "mango" / "config.conf")
UMBRIEL_CONFIG = _env_path("CURMGR_UMBRIEL_CONFIG", CONFIG / "umbriel" / "config.toml")

# One entry per compositor whose own cursor has to be set separately from the
# five portable layers. Adding a compositor is adding a row here, not a new
# write path: `_apply_compositor` and `_read_compositor` are the only code.
COMPOSITORS = {
    "niri": {
        "config": NIRI_CONFIG,
        # Beside the config, wherever the settings put it: niri's include is relative.
        "include_file": NIRI_CONFIG.parent / "cursor.kdl",
        "include_line": 'include "cursor.kdl"',
        "comment": "//",
        "render": _render_niri,
        # A second top-level `cursor` node is a KDL collision, not an override,
        # so niri is the one compositor whose conflicting block must go. The
        # other three are last-wins parsers and the include is appended last.
        "comment_block": "cursor",
        "validate": ["niri", "validate", "-c"],
        "reload": [],  # niri watches config.kdl; the mtime bump below is enough
        "theme_re": r'xcursor-theme\s+("(?:[^"\\]|\\.)*")',
        "decode": _unquote,
        "size_re": r"xcursor-size\s+(\d+)",
        "typing_re": r"hide-when-typing",
        "ms_re": r"hide-after-inactive-ms\s+(\d+)",
        "ms_scale": 1,
    },
    "hyprland": {
        "config": HYPRLAND_CONFIG,
        "include_file": HYPRLAND_CONFIG.parent / "cursor.conf",
        "include_line": "source = {file}",
        "comment": "#",
        "render": _render_hyprland,
        # ponytail: no validation. `Hyprland --verify-config` builds a whole
        # compositor object, which is not something to run inside a live
        # session; the only edit to a file we do not own is one appended
        # `source =` line, and the backup covers it. Wire it up if upstream
        # ever ships a parse-only check.
        "validate": None,
        "reload": [["hyprctl", "reload"], ["hyprctl", "setcursor", "{theme}", "{size}"]],
        "theme_re": r"^env\s*=\s*XCURSOR_THEME,(.*)$",
        "decode": lambda value: value.strip().replace("##", "#"),
        "size_re": r"^env\s*=\s*XCURSOR_SIZE,(\d+)$",
        "typing_re": r"hide_on_key_press\s*=\s*true",
        "ms_re": r"inactive_timeout\s*=\s*(\d+)",
        "ms_scale": 1000,
    },
    "sway": {
        "config": SWAY_CONFIG,
        "include_file": SWAY_CONFIG.parent / "cursor.conf",
        "include_line": "include {file}",
        "comment": "#",
        "render": _render_sway,
        "validate": ["sway", "-C", "-c"],
        "reload": [["swaymsg", "reload"]],
        "theme_re": r'^seat\s+\S+\s+xcursor_theme\s+("(?:[^"\\]|\\.)*"|\S+)',
        "decode": _unquote,
        "size_re": r'^seat\s+\S+\s+xcursor_theme\s+(?:"(?:[^"\\]|\\.)*"|\S+)\s+(\d+)',
        "typing_re": r"hide_cursor\s+when-typing\s+enable",
        "ms_re": r"hide_cursor\s+(\d+)",
        "ms_scale": 1,
    },
    "mango": {
        "config": MANGO_CONFIG,
        "include_file": MANGO_CONFIG.parent / "cursor.conf",
        "include_line": "source={file}",
        "comment": "#",
        "render": _render_mango,
        # ponytail: no validation. `mango -p -c FILE` is documented as a parse
        # check but exits 0 on unknown keys and bad binds alike (checked against
        # mango git, Sep 2026), so it would pass anything. Wire it up once it
        # returns non-zero on errors.
        "validate": None,
        "reload": [["mmsg", "dispatch", "reload_config"]],
        "theme_re": r"^cursor_theme=(.*)$",
        "decode": str.strip,
        "size_re": r"^cursor_size=(\d+)$",
        "typing_re": r"^cursor_hide_on_keypress=[1-9]",
        "ms_re": r"^cursor_hide_timeout=(\d+)$",
        "ms_scale": 1000,
    },
    "umbriel": {
        "config": UMBRIEL_CONFIG,
        "include_file": UMBRIEL_CONFIG.parent / "cursor.toml",
        "include_line": '"cursor.toml"',
        "comment": "#",
        "render": _render_umbriel,
        # Umbriel applies its includes first and the including file last, so
        # the include joins [include.optional] (which Noctalia's own
        # noctalia.toml usually already uses - a second table is a TOML error)
        # and the user's own cursor keys are commented out, as niri's block is.
        "add_include": _toml_add_include,
        "remove_include": _toml_remove_include,
        "comment_keys": {
            "input.cursor": ["theme", "size", "hide_when_typing", "hide_timeout_ms"],
            "environment": ["XCURSOR_THEME", "XCURSOR_SIZE"],
        },
        "validate": ["umbriel", "config", "validate", "-c"],
        "reload": [],  # Umbriel watches the config and its optional includes
        "theme_re": r'^theme\s*=\s*("(?:[^"\\]|\\.)*")',
        "decode": _unquote,
        "size_re": r"^size\s*=\s*(\d+)",
        "typing_re": r"^hide_when_typing\s*=\s*true",
        "ms_re": r"^hide_timeout_ms\s*=\s*(\d+)",
        "ms_scale": 1,
    },
}


def detected_compositors() -> dict:
    """Every compositor with a config on this box, not just the running one.

    Writing all of them is what keeps the theme right after a compositor
    switch; the reload commands are best-effort, so the ones that are not
    running simply do nothing.
    """
    return {k: s for k, s in COMPOSITORS.items() if s["config"].is_file()}


def _backup(path: Path) -> Path:
    # Two edits in one second (apply then Undo) must not share a name, or the
    # second backup overwrites the first - the one holding the original.
    stamp = f"{path.name}.bak-cursor-{time.strftime('%Y%m%d-%H%M%S')}"
    dest, n = path.with_name(stamp), 1
    while dest.exists():
        dest, n = path.with_name(f"{stamp}-{n}"), n + 1
    shutil.copy2(path, dest)
    return dest


def _read_compositor(spec: dict) -> dict:
    text = (spec["include_file"].read_text(errors="replace")
            if spec["include_file"].is_file() else "")
    theme = re.search(spec["theme_re"], text, re.M)
    size = re.search(spec["size_re"], text, re.M)
    ms = re.search(spec["ms_re"], text, re.M)
    return {
        "theme": spec["decode"](theme.group(1)) if theme else "",
        "size": int(size.group(1)) if size else 0,
        "hide_when_typing": bool(re.search(spec["typing_re"], text, re.M)),
        "hide_after_inactive_ms": int(ms.group(1)) * spec["ms_scale"] if ms else 0,
    }


def _apply_compositor(name: str, spec: dict, theme: str, size: int,
                      hide_typing: bool, hide_ms: int) -> dict:
    config, include_file = spec["config"], spec["include_file"]
    comment = spec["comment"]
    include_line = spec["include_line"].format(file=include_file)

    text = config.read_text()
    backup = None
    notes = []

    block = spec.get("comment_block")
    if block and re.search(rf"^{block}\s*\{{", text, re.M):
        backup = _backup(config)
        text = _comment_out_block(text, block, comment)
        notes.append(f"commented out the pre-existing top-level {block} block")

    keys = spec.get("comment_keys")
    if keys:
        commented = _comment_toml_keys(text, keys, comment)
        if commented != text:
            backup = backup or _backup(config)
            text = commented
            notes.append("commented out the config's own cursor keys")

    # Kept for the rollback: after the first apply the config already includes
    # this file, so deleting it on a rejection would leave a dangling include.
    previous = include_file.read_text() if include_file.is_file() else None
    include_file.write_text(f"{comment} {MANAGED_TEXT}\n"
                            + spec["render"](theme, size, hide_typing, hide_ms, text))

    included = spec.get("add_include", _append_include)(text, include_line, comment)
    if included is not None:
        backup = backup or _backup(config)
        text = included
        notes.append(f"added {include_line}")

    if text != config.read_text():
        config.write_text(text)

    ok, err = _validate(spec["validate"], config)
    if not ok:
        if backup is not None:
            shutil.copy2(backup, config)
        if previous is None:
            include_file.unlink(missing_ok=True)
        else:
            include_file.write_text(previous)
        return {"ok": False, "reason": f"{name} rejected the config, rolled back: {err}"}

    # niri watches config.kdl, so an edit to the included file alone would not
    # reload; bumping the mtime is a no-op everywhere else.
    os.utime(config, None)
    notes += _reload(spec, theme, size)
    return {"ok": True, "file": str(include_file), "backup": str(backup) if backup else None,
            "notes": notes}


def _reload(spec: dict, theme: str, size: int) -> list[str]:
    """Ask a running compositor to pick the change up. Never fatal."""
    notes = []
    for argv in spec["reload"]:
        argv = [a.format(theme=theme, size=size) for a in argv]
        if not shutil.which(argv[0]):
            continue
        try:
            proc = subprocess.run(argv, capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.SubprocessError) as exc:
            notes.append(f"{argv[0]}: {exc}")
            continue
        if proc.returncode != 0:
            notes.append(f"{' '.join(argv)}: {(proc.stderr or proc.stdout).strip()[-200:]}")
    return notes


def _comment_out_block(text: str, node: str, comment: str = "//") -> str:
    """Comment out a top-level brace block, tracking brace depth."""
    lines = text.splitlines()
    out, depth, active = [], 0, False
    for line in lines:
        if not active and re.match(rf"^{node}\s*\{{", line):
            active = True
        if active:
            depth += line.count("{") - line.count("}")
            out.append(f"{comment} {DISABLED_TAG} " + line)
            if depth <= 0:
                active = False
                depth = 0
            continue
        out.append(line)
    return "\n".join(out) + "\n"


def _validate(argv: list[str] | None, path: Path) -> tuple[bool, str]:
    if not argv or not shutil.which(argv[0]):
        return True, ""
    try:
        proc = subprocess.run([*argv, str(path)], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as exc:
        return True, str(exc)  # cannot validate is not the same as invalid
    return proc.returncode == 0, (proc.stderr or proc.stdout).strip()[-400:]


def _skipped(reason: str) -> dict:
    """A layer this box simply does not have - never reported as a failure."""
    return {"ok": False, "skipped": True, "reason": reason}


def _gsettings_run(commands: list[list[str]]) -> dict:
    """Each `gsettings` argv in turn; the first failure is the layer's result."""
    if not shutil.which("gsettings"):
        return _skipped("gsettings not installed")
    for args in commands:
        proc = subprocess.run(["gsettings", *args], capture_output=True, text=True, timeout=10)
        if proc.returncode != 0:
            reason = proc.stderr.strip()
            # glib without gsettings-desktop-schemas, as _gsettings() reads it.
            return _skipped(reason) if "No such schema" in reason else {"ok": False, "reason": reason}
    return {"ok": True}


def _apply_gsettings(theme: str, size: int) -> dict:
    return _gsettings_run([["set", "org.gnome.desktop.interface", key, value]
                           for key, value in (("cursor-theme", theme), ("cursor-size", str(size)))])


def _apply_flatpak(theme: str, size: int) -> dict:
    # The sandbox mounts the host's icon dirs under /run/host and leaves
    # XCURSOR_PATH empty, so without this every Flatpak app falls back to the
    # runtime's Adwaita. One global user override; the CLI merges its keyfile.
    if not shutil.which("flatpak"):
        return _skipped("flatpak not installed")
    xcursor_path = f"/run/host/user-share/icons:{HOME / '.icons'}:/run/host/share/icons"
    mounts = ["--filesystem=~/.icons:ro"]
    if _custom_install_dir():
        # Under $HOME (main() insists), so the sandbox sees it at the same path.
        xcursor_path = f"{USER_ICONS}:{xcursor_path}"
        mounts.append(f"--filesystem={USER_ICONS}:ro")
    proc = subprocess.run(["flatpak", "override", "--user", *mounts,
                           f"--env=XCURSOR_PATH={xcursor_path}",
                           f"--env=XCURSOR_THEME={theme}", f"--env=XCURSOR_SIZE={size}"],
                          capture_output=True, text=True, timeout=10)
    if proc.returncode != 0:
        return {"ok": False, "reason": proc.stderr.strip()}
    return {"ok": True, "note": "applies to Flatpak apps started from now on"}


def _apply_gtk(theme: str, size: int) -> dict:
    written = []
    for version in ("3.0", "4.0"):
        path = CONFIG / f"gtk-{version}" / "settings.ini"
        path.parent.mkdir(parents=True, exist_ok=True)
        text = path.read_text(errors="replace") if path.is_file() else ""
        if "[Settings]" not in text:
            text = "[Settings]\n" + text
        for key, value in (("gtk-cursor-theme-name", theme), ("gtk-cursor-theme-size", str(size))):
            line = f"{key}={value}"
            if re.search(rf"^\s*{key}\s*=.*$", text, re.M):
                text = re.sub(rf"^\s*{key}\s*=.*$", line, text, count=1, flags=re.M)
            else:
                text = text.replace("[Settings]", f"[Settings]\n{line}", 1)
        path.write_text(text)
        written.append(str(path))
    return {"ok": True, "files": written}


def _apply_xdg_default(theme: str) -> dict:
    if theme == "default":
        return {"ok": False, "reason": "refusing to make 'default' inherit itself"}
    path = HOME / ".icons" / "default" / "index.theme"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "[Icon Theme]\nName=Default\nComment=Managed by the Noctalia cursor plugin\n"
        f"Inherits={theme}\n"
    )
    return {"ok": True, "file": str(path)}


def _custom_install_dir() -> bool:
    """An install dir Xcursor does not search by default."""
    return USER_ICONS not in (DATA / "icons", HOME / ".icons")


def _apply_environment(theme: str, size: int) -> dict:
    ENV_CONF.parent.mkdir(parents=True, exist_ok=True)
    # XCURSOR_PATH replaces Xcursor's default path rather than adding to it, so
    # it is written only when needed, and then as the whole of ICON_DIRS.
    path = (f"XCURSOR_PATH={':'.join(map(str, ICON_DIRS))}\n"
            if _custom_install_dir() else "")
    ENV_CONF.write_text(f"# {MANAGED_TEXT}\nXCURSOR_THEME={theme}\nXCURSOR_SIZE={size}\n{path}")
    return {"ok": True, "file": str(ENV_CONF), "note": "applies to processes started after next login"}


# Every compositor asks the theme for one pixel size and takes the *nearest*
# image, first one winning a tie. niri and Hyprland ask size * ceil(scale)
# (src/cursor.rs, XCursorManager.cpp), wlroots - Sway and Mango - asks
# int(size * scale) (wlr_xcursor_manager.c), GTK clients drawing their own
# cursor ask size * ceil(scale). A theme shipping only 24/32/48/64/96 therefore
# gives 28 the same image as 24 and 40 the same as 32 at scale 2.
# ponytail: a fixed list of common scales, so an unusual one (1.6) still falls
# to the nearest size; reading each output's real scale per COMPOSITORS row
# would make it exact.
COMMON_SCALES = (1, 1.25, 1.5, 1.75, 2, 3)


def _target_sizes(size: int) -> set[int]:
    import math
    return ({size} | {int(size * s) for s in COMMON_SCALES}
            | {size * math.ceil(s) for s in COMMON_SCALES})


# Sizes every cursor file of a user theme is known to carry, so switching back
# to a theme skips ensure_sizes()' full decode. write_theme() and
# install_theme() build into a fresh staging dir, so a rebuilt theme starts
# without one.
# ponytail: trusts that nobody edits a theme's files by hand; a stale note only
# costs exactness (the nearest size is used). Reinstalling the theme or deleting
# the dotfile resets it.
SIZES_MARKER = ".curmgr-sizes"


def _read_sizes_marker(root: Path) -> set[int]:
    try:
        return {int(s) for s in (root / SIZES_MARKER).read_text().split()}
    except (OSError, ValueError):
        return set()


def _write_sizes_marker(root: Path, sizes: set[int]) -> None:
    try:
        (root / SIZES_MARKER).write_text(" ".join(map(str, sorted(sizes))) + "\n")
    except OSError:
        pass  # only ever a shortcut


def ensure_sizes(root: Path, size: int) -> dict:
    """Give every cursor in a user theme an image at each size a compositor may ask for.

    System themes are left alone (they are not ours to rewrite), and a missing
    ImageMagick only costs the exact sizes, never the apply itself.
    """
    target = _target_sizes(size)
    # Before any parsing: decoding a theme just to learn its sizes costs up to
    # 7s, and a system theme is never rewritten whatever it lacks.
    if not _is_under(root, USER_ICONS):
        return {"added": [], "note": "system theme: the nearest available size is used"}
    recorded = _read_sizes_marker(root)
    if target <= recorded:
        return {"added": []}
    try:
        from win2xcur.parser import open_blob
        from win2xcur.writer import to_x11
    except ImportError as exc:
        return {"added": [], "note": f"exact sizes need win2xcur and ImageMagick: {exc}"}

    def missing_in(path: Path) -> set[int]:
        try:
            frames = open_blob(path.read_bytes()).frames
        except (ValueError, OSError):
            return set()
        return target - {image.nominal for frame in frames for image in frame}

    files = [f for f in sorted((root / "cursors").iterdir()) if f.is_file() and not f.is_symlink()]
    missing = {f.name: m for f in files if (m := missing_in(f))}
    if not missing:
        _write_sizes_marker(root, recorded | target)
        return {"added": []}

    dest, staging, retired = _stage(root.name)
    # symlinks=True keeps the alias symlinks, exactly as install_theme() does.
    shutil.copytree(root, staging, symlinks=True)
    added: set[int] = set()
    for name, lacking in missing.items():
        path = staging / "cursors" / name
        frames = open_blob(path.read_bytes()).frames
        existing = {image.nominal for frame in frames for image in frame}
        # The Xcursor parser hands wand premultiplied bytes and to_x11()
        # premultiplies again, so straight alpha first or edges darken.
        for frame in frames:
            for image in frame:
                # Keep the Image itself: a .sequence[0] of a temporary dies with it.
                image.image = _unpremultiply(image.image)
        frames = _expand_sizes(frames, sorted(existing | target))
        path.write_bytes(to_x11(frames))
        added |= lacking
    # Into staging, so the note lands with the files it describes.
    _write_sizes_marker(staging, recorded | target)
    _swap_in(dest, staging, retired)
    return {"added": sorted(added)}


def _layer(apply, *args) -> dict:
    """One layer's result, never an exception. Home Manager makes settings.ini a
    read-only store symlink: that layer fails on its own while the rest - the
    compositor already written - still land and say so."""
    try:
        return apply(*args)
    except (OSError, subprocess.SubprocessError) as exc:
        return {"ok": False, "reason": str(exc)}


def apply_theme(theme: str, size: int, hide_typing: bool, hide_ms: int) -> dict:
    root = find_theme(theme)  # fail fast on a typo before touching any config
    sizes = ensure_sizes(root, size)
    detected = detected_compositors()
    layers = {name: _layer(_apply_compositor, name, spec, theme, size, hide_typing, hide_ms)
              for name, spec in detected.items()}
    layers |= {
        "gsettings": _layer(_apply_gsettings, theme, size),
        "gtk": _layer(_apply_gtk, theme, size),
        "xdg_default": _layer(_apply_xdg_default, theme),
        "environment": _layer(_apply_environment, theme, size),
        "flatpak": _layer(_apply_flatpak, theme, size),
    }
    # Under a supported compositor its own cursor is the one the user sees on
    # the desktop, so every detected one has to land. With none configured the
    # five portable layers still change the cursor and decide on their own.
    ok = (all(layers[name]["ok"] for name in detected) if detected
          else any(layer["ok"] for layer in layers.values()))
    return _outcome(ok, layers, theme=theme, size=size, sizes=sizes)


def _outcome(ok: bool, layers: dict, **extra) -> dict:
    """Name the layers that failed (a skipped one did not), and say why in
    `error` when the whole run counts as failed - the panel shows that text."""
    failed = {name: layer.get("reason", "") for name, layer in layers.items()
              if not layer["ok"] and not layer.get("skipped")}
    result = {"ok": ok, **extra, "layers": layers, "failed": failed}
    if not ok:
        result["error"] = "; ".join(f"{n}: {r}" for n, r in failed.items()) or "no layer could be written"
    return result


# --------------------------------------------------------------------------
# undoing everything (uninstall)
# --------------------------------------------------------------------------

def _uninstall_compositor(name: str, spec: dict) -> dict:
    config, include_file, comment = spec["config"], spec["include_file"], spec["comment"]
    include_line = spec["include_line"].format(file=include_file)
    text = config.read_text()
    removed = spec.get("remove_include", _remove_appended_include)(text, include_line, comment)
    restored = _restore_commented(text if removed is None else removed, comment)
    backup, notes = None, []
    if restored != text:
        backup = _backup(config)
        config.write_text(restored)
        ok, err = _validate(spec["validate"], config)
        if not ok:
            shutil.copy2(backup, config)
            return {"ok": False, "reason": f"{name} rejected the restored config, rolled back: {err}"}
        notes.append("removed the include and restored the lines it had commented out")
    # Before 1.0.5 a commented-out block carried no tag, so it is not ours to guess at.
    block = spec.get("comment_block")
    if block and re.search(rf"^{re.escape(comment)} {block}\s*\{{", restored, re.M):
        notes.append(f"a {block} block commented out by an older version is left as it is")
    include_file.unlink(missing_ok=True)
    os.utime(config, None)
    # Only the plain reloads: `hyprctl setcursor` needs a theme to set.
    notes += _reload({"reload": [a for a in spec["reload"] if "{" not in "".join(a)]}, "", 0)
    return {"ok": True, "backup": str(backup) if backup else None, "notes": notes}


def _undo_gtk() -> dict:
    changed = []
    for version in ("3.0", "4.0"):
        path = CONFIG / f"gtk-{version}" / "settings.ini"
        if not path.is_file():
            continue
        text = path.read_text(errors="replace")
        kept = re.sub(r"^\s*gtk-cursor-theme-(?:name|size)\s*=.*\n?", "", text, flags=re.M)
        if kept != text:
            path.write_text(kept)
            changed.append(str(path))
    return {"ok": True, "files": changed}


def _undo_managed_file(path: Path, marker: str) -> dict:
    """Delete a file this plugin wrote whole - never one it did not."""
    if path.is_file() and marker in path.read_text(errors="replace"):
        path.unlink()
        return {"ok": True, "removed": str(path)}
    return {"ok": True}


def _undo_flatpak() -> dict:
    # `flatpak override --unset-env` does not delete a key: it adds an "unset"
    # entry, which would also hide an XCURSOR_THEME the user exports some other
    # way. So, unlike apply, this edits the keyfile - only our three keys.
    import configparser
    path = DATA / "flatpak" / "overrides" / "global"
    if not path.is_file():
        return {"ok": True}
    keyfile = configparser.ConfigParser(interpolation=None, strict=False)
    keyfile.optionxform = str  # keys are case-sensitive
    keyfile.read_string(path.read_text())
    if not keyfile.has_section("Environment"):
        return {"ok": True}
    removed = [k for k in ("XCURSOR_PATH", "XCURSOR_THEME", "XCURSOR_SIZE")
               if keyfile.remove_option("Environment", k)]
    if not removed:
        return {"ok": True}
    if not keyfile.items("Environment"):
        keyfile.remove_section("Environment")
    with path.open("w") as out:
        keyfile.write(out, space_around_delimiters=False)
    return {"ok": True, "note": "the read-only icon folder mounts are left in place"}


def uninstall() -> dict:
    """Undo every layer: configs back as they were, our files gone, and the
    cursor settings back to the system default. Themes and backups stay."""
    layers = {name: _layer(_uninstall_compositor, name, spec)
              for name, spec in detected_compositors().items()}
    layers |= {
        "gsettings": _layer(_gsettings_run, [["reset", "org.gnome.desktop.interface", key]
                                              for key in ("cursor-theme", "cursor-size")]),
        "gtk": _layer(_undo_gtk),
        "xdg_default": _layer(_undo_managed_file, HOME / ".icons" / "default" / "index.theme",
                              "Managed by the Noctalia cursor plugin"),
        "environment": _layer(_undo_managed_file, ENV_CONF, MANAGED_TEXT),
        "flatpak": _layer(_undo_flatpak),
    }
    return _outcome(all(l["ok"] or l.get("skipped") for l in layers.values()), layers)


# --------------------------------------------------------------------------
# theme writing (shared by import-win and build)
# --------------------------------------------------------------------------

def _expand_sizes(frames, sizes, filter_name="lanczos"):
    """Give every frame one image per nominal size.

    win2xcur's scale.apply_to_frames rescales in place and leaves `nominal`
    stale, which produces themes that look right but resolve wrong, so the
    resampling is done here instead.
    """
    from win2xcur.cursor import CursorFrame
    from wand.image import Image

    out = []
    for frame in frames:
        source = max(frame.images, key=lambda i: i.image.width)
        by_size = {i.image.width: i for i in frame.images}
        images = []
        for size in sizes:
            exact = by_size.get(size)
            if exact is not None:
                clone = exact.clone()
                clone.nominal = size
                images.append(clone)
                continue
            clone = source.clone()
            ratio = size / source.image.width
            with Image(image=clone.image) as scaled:
                scaled.resize(size, max(1, round(source.image.height * ratio)), filter=filter_name)
                clone.image = scaled.sequence[0].clone()
            hx, hy = source.hotspot
            clone.hotspot = (min(round(hx * ratio), size - 1), min(round(hy * ratio), size - 1))
            clone.nominal = size
            images.append(clone)
        out.append(CursorFrame(images, frame.delay))
    return out


def write_theme(name: str, role_frames: dict, inherits: str = "Adwaita",
                sizes=NOMINAL_SIZES, filter_name="lanczos", shadow_opts=None) -> dict:
    """Write one Xcursor theme from {role: frames} into ~/.local/share/icons."""
    from win2xcur import shadow as shadow_mod
    from win2xcur.theme import XCURSOR_ALIASES
    from win2xcur.writer import to_x11

    if not role_frames:
        raise Fail("nothing to build: no cursors were mapped")

    # The name is not the user's: import-win takes it from a pack's Install.inf
    # and build from spec.json, so a downloaded source names this directory.
    # install_theme() already vets names; this is the sink both builders share,
    # so checking here covers any future source format too.
    name = _safe_theme_name(name)
    root, staging, retired = _stage(name)
    cursors = staging / "cursors"
    cursors.mkdir(parents=True)

    written = []
    for role, frames in role_frames.items():
        aliases = XCURSOR_ALIASES.get(role)
        if not aliases:
            continue
        if shadow_opts:
            shadow_mod.apply_to_frames(frames, **shadow_opts)
        frames = _expand_sizes(frames, sizes, filter_name)
        canonical = aliases[0]
        (cursors / canonical).write_bytes(to_x11(frames))
        written.append(canonical)
        for alias in aliases[1:]:
            link = cursors / alias
            if link.is_symlink() or link.exists():
                link.unlink()
            link.symlink_to(canonical)

    (staging / "index.theme").write_text(
        f"[Icon Theme]\nName={name}\nComment=Built by the Noctalia cursor plugin\n"
        f"Inherits={inherits}\n"
    )
    (staging / "cursor.theme").write_text(f"[Icon Theme]\nName={name}\nInherits={name}\n")

    replaced = root.exists() or root.is_symlink()
    _swap_in(root, staging, retired)
    return {"path": str(root), "cursors": written, "replaced": replaced}


# Both writers build a theme beside its final directory and swap it in only
# once complete. A run killed halfway (the panel's runAsync timeout, say) used
# to leave a half-written theme that still showed up in the list; the hidden
# name keeps a leftover out of list_themes(), and the next write clears it.
# Copying before deleting also means installing a theme onto itself is harmless.
def _stage(name: str) -> tuple[Path, Path, Path]:
    root = USER_ICONS / name
    staging = USER_ICONS / f".{name}.partial"
    retired = USER_ICONS / f".{name}.old"
    USER_ICONS.mkdir(parents=True, exist_ok=True)
    # Belt and braces: the name is sanitised by the caller, this catches a
    # symlink planted in USER_ICONS itself, which a name check cannot see.
    for path in (root, staging, retired):
        if not _is_under(path, USER_ICONS):
            raise Fail(f"refusing to write outside {USER_ICONS}: {path}")
    for path in (staging, retired):
        _remove_path(path)
    return root, staging, retired


def _swap_in(root: Path, staging: Path, retired: Path) -> None:
    # Two renames, so the old theme is only deleted once the new one is in place.
    if root.exists() or root.is_symlink():
        root.rename(retired)
    staging.rename(root)
    _remove_path(retired)


def _remove_path(path: Path) -> None:
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    elif path.exists() or path.is_symlink():
        path.unlink()


# --------------------------------------------------------------------------
# import-win
# --------------------------------------------------------------------------

def _guess_role(stem: str) -> tuple[str, int] | tuple[None, int]:
    # ponytail: token scoring, not real matching. Edit distance is not the
    # upgrade path it looks like - it would reach "unavaliable" and never reach
    # "alt", while inviting the confident wrong guess this design avoids. Add a
    # hint that covers a class instead.
    squashed = re.sub(r"[^a-z0-9]", "", stem.lower())
    # A file named after its role always wins. This is the escape hatch the
    # panel tells users about ("rename those files after their role"), and
    # without it up_arrow.cur loses to `arrow`, whose hint is a whole token
    # inside the name - costing the user the pointer they were fixing.
    for role in ROLE_HINTS:
        if squashed == re.sub(r"[^a-z0-9]", "", role) or stem.lower() in XCURSOR_NAMES[role]:
            return role, 4
    tokens = set(re.split(r"[^a-z0-9]+", stem.lower())) - {""}
    best, score, hint_len = None, 0, 0
    for role, hints in ROLE_HINTS.items():
        for hint in hints:
            if hint in tokens:
                candidate = 3
            elif len(hint) >= 4 and hint in squashed:
                candidate = 2
            else:
                continue
            # A tie goes to the longer hint: "diagonalresize2" is more specific
            # than "diagonalresize", and both match the numbered file.
            if candidate > score or (candidate == score and len(hint) > hint_len):
                best, score, hint_len = role, candidate, len(hint)
    return best, score


def _source_dir(path: Path) -> Path:
    # Folders only. Archives were extracted here once, but tarfile on Python
    # 3.11 has no 'data' filter, so a crafted .tar could write outside the
    # extraction directory. The panel already asks for a folder; the engine
    # now agrees, and that whole class of bug is gone rather than patched.
    if path.is_dir():
        return path
    if path.suffix.lower() in {".zip", ".tar", ".tgz", ".gz", ".bz2", ".xz", ".7z", ".rar"}:
        raise Fail("that is an archive - extract it first and pick the folder")
    if path.suffix.lower() in {".cur", ".ani"}:
        raise Fail("a single cursor file is not a pack - pick the folder that holds it")
    raise Fail(f"unsupported import source: {path}")


def import_windows(source: Path, name: str, shadow_opts=None, sizes=NOMINAL_SIZES,
                   filter_name="lanczos", overrides: dict[str, str] | None = None,
                   dry_run: bool = False) -> dict:
    from win2xcur.parser import open_blob
    from win2xcur.parser.inf import parse_inf
    from win2xcur.theme import WIN_CURSORS, XCURSOR_ALIASES

    root = _source_dir(source)
    candidates = sorted(p for p in root.rglob("*") if p.suffix.lower() in {".cur", ".ani"})
    if not candidates:
        raise Fail(f"no .cur or .ani files found under {root}")

    role_frames: dict = {}
    method = "heuristic"
    inf_error = ""

    for inf in sorted(root.rglob("*.inf")):
        try:
            parsed = parse_inf(inf)
        except (ValueError, OSError) as exc:
            inf_error = f"{inf.name}: {exc}"
            continue
        for role in WIN_CURSORS:
            cursor = getattr(parsed, role, None)
            if cursor is not None:
                role_frames[role] = cursor.frames
        if role_frames:
            method = f"inf:{inf.name}"
            name = name or parsed.name
            break
    # No name from the user or an .inf (heuristic packs, or an .inf without a
    # name): the folder's, as build_from_pngs does, minus any leading dot so an
    # extracted ".mypack" doesn't become a hidden theme.
    name = name or root.name.lstrip(".")

    if not role_frames:
        # Packs ship near-duplicates - "Normal Select" beside "My Melody
        # Normal Select", "Busy" beside "Busy 2" - which score the same.
        # Break the tie on the plainest name rather than on where a space
        # happens to sort, which handed the arrow to "Alternate Select".
        scored: dict[str, tuple[tuple[int, int], Path]] = {}
        for path in candidates:
            role, score = _guess_role(path.stem)
            if not role:
                continue
            key = (score, -len(re.split(r"[^a-z0-9]+", path.stem.strip().lower())))
            if key > scored.get(role, ((0, -99), None))[0]:
                scored[role] = (key, path)
        for role, (_, path) in scored.items():
            role_frames[role] = open_blob(path.read_bytes()).frames

    # The panel's mapping grid: a user-picked file wins over both the .inf
    # and the heuristic guess, and an empty value un-maps a role the
    # heuristic got wrong rather than leaving no way to blank it.
    for role, rel in (overrides or {}).items():
        if role not in WIN_CURSORS or role not in XCURSOR_ALIASES:
            raise Fail(f"not a mappable role: {role}")
        if rel == "":
            role_frames.pop(role, None)
            continue
        path = (root / rel).resolve()
        if not _is_under(path, root):
            raise Fail(f"refusing to read outside {root}: {rel}")
        if not path.is_file():
            raise Fail(f"mapped file not found: {rel}")
        role_frames[role] = open_blob(path.read_bytes()).frames

    mapped = set(role_frames)
    used = {p.name for p in candidates}
    # Only roles the user could actually fill by mapping a file: location
    # and person have no Xcursor name to be written under.
    unmapped = [r for r in WIN_CURSORS if r not in mapped and r in XCURSOR_ALIASES]
    files = _render_sources(root, candidates, IMPORT_SOURCE_DIR)
    role_previews = _render_role_previews(role_frames, IMPORT_ROLE_DIR)

    # Two ways to stop before writing anything, one payload. A dry run is
    # how the panel shows its mapping grid *before* the convert, so the
    # user fixes a bad guess once instead of converting twice; no arrow is
    # not a hard failure either, the grid is what the user needs to act on.
    # Everything above this line ran exactly as a real convert would, so the
    # grid is a promise the convert keeps.
    if dry_run or "arrow" not in role_frames:
        return {
            "ok": True, "written": False, "name": name, "method": method,
            "inf_error": inf_error, "mapped": sorted(mapped),
            "unmapped_roles": unmapped, "files": files, "role_previews": role_previews,
            "source_files": sorted(used),
        }

    result = write_theme(name, role_frames, sizes=sizes, filter_name=filter_name,
                         shadow_opts=shadow_opts)

    return {
        "ok": True, "written": True, "name": name, "method": method, "inf_error": inf_error,
        "mapped": sorted(mapped),
        "unmapped_roles": unmapped,
        "files": files,
        "role_previews": role_previews,
        "source_files": sorted(used),
        **result,
    }


# --------------------------------------------------------------------------
# install an already-built Xcursor theme
# --------------------------------------------------------------------------

def _is_theme_root(path: Path) -> bool:
    """Same test list_themes() uses, so installing implies showing up in the list."""
    cursors = path / "cursors"
    if not cursors.is_dir():
        return False
    return any(f.is_file() or f.is_symlink() for f in cursors.iterdir())


def _find_theme_roots(root: Path, max_depth: int = 3) -> list[Path]:
    # Bounded walk: pointing this at ~/Downloads should not scan the whole disk.
    found, stack = [], [(root, 0)]
    while stack:
        current, depth = stack.pop()
        if _is_theme_root(current):
            found.append(current)
            continue  # a theme's own subdirs are never separate themes
        if depth >= max_depth:
            continue
        try:
            # Dot-directories are write_theme()'s staging, skipped like list_themes().
            stack.extend((d, depth + 1) for d in current.iterdir()
                         if d.is_dir() and not d.name.startswith("."))
        except OSError:
            continue
    return sorted(found)


def _theme_dir_name(root: Path) -> str:
    """Prefer the theme's declared Name; a directory name is the fallback."""
    declared = _index_field(root / "index.theme", "Name")
    name = re.sub(r"\s+", "-", declared.strip()) if declared.strip() else root.name
    return name


def _safe_theme_name(name: str) -> str:
    name = name.strip().strip("/")
    if not name or name in {".", ".."} or "/" in name or "\\" in name or ".." in name:
        raise Fail(f"refusing an unsafe theme name: {name!r}")
    # The name ends up inside compositor configs and environment.d. A newline
    # would add a line of its own (`exec = ...` in Hyprland, which the reload
    # right after runs), so anything non-printable is refused. A leading dot
    # would make the theme hidden: list_themes() skips dot-entries.
    if not name.isprintable() or name.startswith("."):
        raise Fail(f"refusing an unsafe theme name: {name!r}")
    return name


def install_theme(source: Path, name: str = "") -> dict:
    """Copy a finished Xcursor theme into ~/.local/share/icons."""
    if not source.exists():
        raise Fail(f"no such path: {source}")

    root = _source_dir(source)
    # Pointing straight at a theme's cursors/ directory means the parent.
    if root.name == "cursors" and _is_theme_root(root.parent):
        roots = [root.parent]
    else:
        roots = _find_theme_roots(root)

    if not roots:
        if any(p.suffix.lower() in {".cur", ".ani"} for p in root.rglob("*")):
            raise Fail("this looks like a Windows cursor pack - use import-win instead")
        raise Fail(f"no Xcursor theme found under {source}: nothing has a cursors/ directory")
    if name and len(roots) > 1:
        raise Fail(f"--name needs exactly one theme, but {len(roots)} were found")

    installed, replaced = [], []
    for theme_root in roots:
        dest_name = _safe_theme_name(name or _theme_dir_name(theme_root))
        dest, staging, retired = _stage(dest_name)
        if dest.exists() or dest.is_symlink():
            replaced.append(dest_name)
        # symlinks=True is load-bearing: a real theme is roughly half alias
        # symlinks, and dereferencing them bloats it and loses the aliasing.
        shutil.copytree(theme_root, staging, symlinks=True)
        _swap_in(dest, staging, retired)
        installed.append(dest_name)

    return {"ok": True, "installed": installed, "replaced": replaced,
            "path": str(USER_ICONS)}


# --------------------------------------------------------------------------
# build from PNG
# --------------------------------------------------------------------------

CENTERED = {"crosshair", "move", "wait", "working", "size_ns", "size_ew",
            "size_nwse", "size_nesw", "unavailable"}


def _load_pngs(paths: list[Path], hotspot, delay_ms: int):
    """Each PNG becomes one animation frame. `hotspot` of None means centre it."""
    from wand.image import Image
    from win2xcur.cursor import CursorFrame, CursorImage

    frames = []
    for path in paths:
        img = Image(filename=str(path))
        img.alpha_channel = True
        single = img.sequence[0]
        hx, hy = hotspot if hotspot is not None else (single.width // 2, single.height // 2)
        hx = max(0, min(int(hx), single.width - 1))
        hy = max(0, min(int(hy), single.height - 1))
        frames.append(CursorFrame([CursorImage(single, (hx, hy), single.width)], delay_ms / 1000))
    return frames


def _build_hotspot(role: str, entry: dict):
    """Where a build role points from. None means centre it in _load_pngs()."""
    hotspot = entry.get("hotspot")
    if hotspot is not None:
        return tuple(hotspot)
    if role in CENTERED:
        return None
    return (0, 0)  # tip-of-the-arrow roles point from their corner


def _png_image(path: Path, target: int = 32):
    """A source PNG scaled for the grid. Straight alpha, so nothing to undo."""
    return _frames_image(_load_pngs([path], (0, 0), 0), target, premultiplied=False)


def build_from_pngs(source: Path, name: str, sizes=NOMINAL_SIZES,
                    filter_name="lanczos", overrides: dict[str, str] | None = None,
                    dry_run: bool = False) -> dict:
    import fnmatch

    from win2xcur.theme import WIN_CURSORS, XCURSOR_ALIASES

    if not source.is_dir():
        raise Fail(f"not a directory: {source}")

    spec_path = source / "spec.json"
    spec = json.loads(spec_path.read_text()) if spec_path.is_file() else {}
    name = name or spec.get("name") or source.name
    inherits = spec.get("inherits", "Adwaita")

    entries = spec.get("cursors")
    method = "spec.json" if entries else "heuristic"
    if not entries:
        # No spec: filename stem is the role, hotspot guessed from the role.
        # Numbered frames (wait-01.png, wait-02.png) are one animated cursor,
        # guessed by their base name. The glob is exact per base, so left_ptr
        # never swallows left_ptr_watch-*, and each role goes to its best
        # score, plainest name first - the same tie-break import-win uses.
        bases: dict[str, bool] = {}
        for png in sorted(source.glob("*.png")):
            base = re.sub(r"[-_]\d+$", "", png.stem)
            bases[base] = bases.get(base, False) or base != png.stem
        scored: dict[str, tuple[tuple[int, int], str]] = {}
        for base, animated in bases.items():
            role, score = _guess_role(base)
            if not role or score < 2:
                continue
            key = (score, -len(re.split(r"[^a-z0-9]+", base.strip().lower())))
            if role not in scored or key > scored[role][0]:
                pattern = glob.escape(base) + ("[-_][0-9]*.png" if animated else ".png")
                scored[role] = (key, pattern)
        entries = {role: {"png": pattern} for role, (_, pattern) in scored.items()}

    role_frames, report = {}, {}
    for role, entry in entries.items():
        pattern = entry.get("png", f"{role}*.png")
        matches = sorted(p for p in source.iterdir()
                         if p.is_file() and fnmatch.fnmatch(p.name, pattern))
        if not matches:
            report[role] = f"no PNG matched {pattern!r}"
            continue
        role_frames[role] = _load_pngs(matches, _build_hotspot(role, entry),
                                       entry.get("delay_ms", 50 if len(matches) > 1 else 0))

    # The panel's mapping grid, same contract as import-win: a picked file beats
    # the spec and the heuristic, an empty value un-maps the role. The file is
    # loaded directly rather than rewritten into entry["png"], which would need
    # the filename escaped against fnmatch.
    # ponytail: one file, so a dropped tile makes the role a single static
    # frame. spec.json's glob stays the way to build an animated role.
    for role, rel in (overrides or {}).items():
        if role not in WIN_CURSORS or role not in XCURSOR_ALIASES:
            raise Fail(f"not a mappable role: {role}")
        if rel == "":
            role_frames.pop(role, None)
            continue
        path = (source / rel).resolve()
        if not _is_under(path, source):
            raise Fail(f"refusing to read outside {source}: {rel}")
        if not path.is_file():
            raise Fail(f"mapped file not found: {rel}")
        entry = entries.get(role, {})
        role_frames[role] = _load_pngs([path], _build_hotspot(role, entry),
                                       entry.get("delay_ms", 0))
        report.pop(role, None)

    pngs = sorted(p for p in source.iterdir() if p.is_file() and p.suffix.lower() == ".png")
    grid = {
        "mapped": sorted(role_frames),
        # Only roles a file could actually fill: location and person have no
        # Xcursor name to be written under.
        "unmapped_roles": [r for r in WIN_CURSORS
                           if r not in role_frames and r in XCURSOR_ALIASES],
        "files": _render_sources(source, pngs, BUILD_SOURCE_DIR, load=_png_image),
        "role_previews": _render_role_previews(role_frames, BUILD_ROLE_DIR,
                                               premultiplied=False),
    }

    # Same gate import-win uses: a scan never writes, and a theme with no arrow
    # is not worth installing - hand back the grid so the user can assign one.
    if dry_run or "arrow" not in role_frames:
        return {"ok": True, "written": False, "name": name, "method": method,
                "skipped": report, **grid}

    result = write_theme(name, role_frames, inherits=inherits, sizes=sizes,
                         filter_name=filter_name)
    return {"ok": True, "written": True, "name": name, "method": method,
            "skipped": report, **grid, **result}


# --------------------------------------------------------------------------
# preview
# --------------------------------------------------------------------------

def _unpremultiply(single):
    """Xcursor stores premultiplied ARGB, Wand reads channels as straight."""
    import numpy as np
    from wand.image import Image

    raw = np.frombuffer(bytes(single.export_pixels(channel_map="RGBA")), dtype=np.uint8)
    px = raw.reshape(-1, 4).astype(np.float64)
    alpha = px[:, 3:4] / 255.0
    np.divide(px[:, :3], alpha, out=px[:, :3], where=alpha > 0)
    out = Image(width=single.width, height=single.height)
    out.import_pixels(channel_map="RGBA", data=np.clip(px, 0, 255).astype(np.uint8).tobytes())
    return out


def _frames_image(frames, target: int = 32, premultiplied: bool = True):
    """First frame of a decoded cursor, unpremultiplied and scaled. Caller closes.

    `premultiplied` is what the frames came from: Xcursor and .cur store
    premultiplied ARGB, but frames built by _load_pngs() are straight alpha
    exactly as wand read them, and unpremultiplying those washes them out.
    """
    from wand.image import Image

    best = min(frames[0].images, key=lambda i: abs(i.nominal - target))
    img = _unpremultiply(best.image) if premultiplied else Image(image=best.image)
    if img.width != target:
        img.resize(target, max(1, round(img.height * target / img.width)), filter="lanczos")
    return img


def _cursor_image(path: Path, target: int = 32):
    """First frame of a cursor file, unpremultiplied and scaled. Caller closes."""
    from win2xcur.parser import open_blob

    return _frames_image(open_blob(path.read_bytes()).frames, target)


def _render_sources(root: Path, paths: list[Path], dest_dir: Path, target: int = 32,
                    load=None) -> list[dict]:
    """Render every candidate source file, so the panel's mapping grid can offer
    all of them, not just the ones a role failed to claim."""
    load = load or _cursor_image
    if dest_dir.exists():
        shutil.rmtree(dest_dir, ignore_errors=True)
    dest_dir.mkdir(parents=True, exist_ok=True)

    out = []
    # ponytail: 60 is enough for a real Windows pack (15 roles, a handful of
    # near-duplicates) without spending a render on every file in a dump.
    # Paginate in the panel if that ever stops being true.
    for index, src in enumerate(paths[:60]):
        dest = dest_dir / f"{index}.png"
        try:
            with load(src, target) as img:
                img.format = "png"
                dest.write_bytes(img.make_blob())
        except (ValueError, OSError, AssertionError, IndexError):
            continue  # an unreadable stray is not worth failing the import over
        out.append({"file": src.name, "rel": str(src.relative_to(root)), "preview": str(dest)})
    return out


def _render_role_previews(role_frames: dict, dest_dir: Path, target: int = 32,
                          premultiplied: bool = True) -> dict:
    """Render what each mapped role currently holds, for the mapping grid."""
    if dest_dir.exists():
        shutil.rmtree(dest_dir, ignore_errors=True)
    dest_dir.mkdir(parents=True, exist_ok=True)

    out = {}
    for role, frames in role_frames.items():
        dest = dest_dir / f"{role}.png"
        try:
            with _frames_image(frames, target, premultiplied) as img:
                img.format = "png"
                dest.write_bytes(img.make_blob())
        except (ValueError, OSError, AssertionError, IndexError):
            continue
        out[role] = str(dest)
    return out


def render_preview(theme: str, cell: int = 40, target: int = 32, force: bool = False) -> dict:
    root = find_theme(theme)
    cursors = root / "cursors"
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    out_path = PREVIEW_DIR / f"{theme}.png"

    # ctime, not mtime: install's copytree keeps the source mtimes, so a
    # reinstall from older files looked unchanged. ctime can't be copied. lstat
    # so a dangling alias symlink doesn't crash the whole strip. The directory's
    # own ctime covers a cursor being added or removed.
    newest = max([cursors.stat().st_ctime] + [p.lstat().st_ctime for p in cursors.iterdir()])
    if not force and out_path.is_file():
        cached = out_path.stat()
        if cached.st_mtime >= newest:
            return {"ok": True, "preview": str(out_path), "cached": True,
                    "stamp": cached.st_mtime_ns}

    # Imported only when a strip is actually drawn: the panel asks for one per
    # theme on every open, and a cached answer shouldn't pay for ImageMagick.
    from wand.color import Color
    from wand.image import Image

    # ponytail: one process per theme, called serially from the panel. Fine for
    # the dozens of themes a person installs; batch it if that ever becomes hundreds.
    picks = []
    for slot in PREVIEW_SLOTS:
        for candidate in slot:
            path = cursors / candidate
            if path.is_file():
                picks.append(path.resolve())
                break

    if not picks:
        raise Fail(f"no recognisable cursors in {cursors}")

    canvas = Image(width=cell * len(picks), height=cell, background=Color("transparent"))
    for index, path in enumerate(picks):
        try:
            image = _cursor_image(path, target)
        except (ValueError, OSError, AssertionError, IndexError):
            continue
        with image as img:
            canvas.composite(img, left=index * cell + (cell - img.width) // 2,
                             top=max(0, (cell - img.height) // 2))
    canvas.format = "png"
    out_path.write_bytes(canvas.make_blob())
    canvas.close()
    return {"ok": True, "preview": str(out_path), "cached": False, "slots": len(picks),
            # The panel keys the image on this, so a re-rendered strip at the
            # same path isn't hidden behind the host's cached texture.
            "stamp": out_path.stat().st_mtime_ns}


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def _shadow_opts(args) -> dict | None:
    if not getattr(args, "shadow", False):
        return None
    return {"color": args.shadow_color, "radius": args.shadow_radius,
            "sigma": args.shadow_sigma, "xoffset": args.shadow_x, "yoffset": args.shadow_y}


def _overrides(args) -> dict[str, str]:
    """--map ROLE=RELPATH, the panel's mapping grid on the command line."""
    out = {}
    for entry in args.map_roles:
        role, sep, rel = entry.partition("=")
        if not sep:
            raise Fail(f"--map wants ROLE=RELPATH, got: {entry}")
        out[role] = rel
    return out


def _add_mapping_args(parser) -> None:
    """Both builders feed the same grid, so both take the same two flags."""
    parser.add_argument("--map", dest="map_roles", action="append", default=[],
                        metavar="ROLE=RELPATH",
                        help="assign a role to a source file (relative to the source folder); "
                             "ROLE= with nothing after the = un-maps that role; repeatable")
    parser.add_argument("--dry-run", action="store_true",
                        help="map and render previews without writing a theme")


def _add_image_args(parser) -> None:
    parser.add_argument("--sizes", default=",".join(map(str, NOMINAL_SIZES)),
                        help="comma-separated nominal sizes to generate")
    # Resampling is the one knob that genuinely needs tuning: 'point' keeps
    # pixel-art cursors crisp, 'lanczos' suits anti-aliased ones.
    parser.add_argument("--filter", dest="filter_name", default="lanczos",
                        help="ImageMagick resize filter (lanczos, point, mitchell, ...)")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="curmgr", description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list", help="list installed cursor themes")
    sub.add_parser("current", help="report the currently applied cursor across all layers")

    p = sub.add_parser("preview", help="render a preview strip for a theme")
    p.add_argument("theme")
    p.add_argument("--force", action="store_true")

    p = sub.add_parser("apply", help="apply a theme to every layer")
    p.add_argument("theme")
    p.add_argument("--size", type=int, default=24)
    p.add_argument("--hide-when-typing", action="store_true")
    p.add_argument("--hide-after-inactive-ms", type=int, default=0)

    p = sub.add_parser("import-win", help="convert a Windows cursor pack into a theme")
    p.add_argument("source", type=Path, help="folder")
    p.add_argument("--name", default="")
    _add_mapping_args(p)
    p.add_argument("--shadow", action="store_true", help="emulate the Windows drop shadow")
    p.add_argument("--shadow-color", default="#000000")
    p.add_argument("--shadow-radius", type=float, default=0.1)
    p.add_argument("--shadow-sigma", type=float, default=0.1)
    p.add_argument("--shadow-x", type=float, default=0.05)
    p.add_argument("--shadow-y", type=float, default=0.05)
    _add_image_args(p)

    p = sub.add_parser("build", help="build a theme from your own PNGs")
    p.add_argument("source", type=Path)
    p.add_argument("--name", default="")
    _add_mapping_args(p)
    _add_image_args(p)

    p = sub.add_parser("install", help="install a finished Xcursor theme from a folder")
    p.add_argument("source", type=Path, help="folder holding a cursors/ directory")
    p.add_argument("--name", default="", help="install under this name instead of the theme's own")

    sub.add_parser("uninstall", help="undo every change the plugin made, back to the default cursor")

    p = sub.add_parser("remove", help="delete a theme you built (never a system one)")
    p.add_argument("theme")

    args = parser.parse_args(argv)

    try:
        # `remove` rmtree's inside the install dir, so a setting may move it
        # but never out of $HOME, nor onto $HOME itself.
        if os.environ.get("CURMGR_INSTALL_DIR", "").strip() and (
                not _is_under(USER_ICONS, HOME) or USER_ICONS.resolve() == HOME.resolve()):
            raise Fail(f"install folder must be inside your home folder: {USER_ICONS}")
        if args.cmd == "list":
            result = {"ok": True, "themes": list_themes()}
        elif args.cmd == "current":
            result = read_current()
        elif args.cmd == "preview":
            result = render_preview(args.theme, force=args.force)
        elif args.cmd == "apply":
            result = apply_theme(args.theme, args.size, args.hide_when_typing,
                                 args.hide_after_inactive_ms)
        elif args.cmd == "import-win":
            result = import_windows(
                args.source, args.name, _shadow_opts(args),
                tuple(int(s) for s in args.sizes.split(",")), args.filter_name,
                _overrides(args), args.dry_run)
        elif args.cmd == "build":
            result = build_from_pngs(
                args.source, args.name,
                tuple(int(s) for s in args.sizes.split(",")), args.filter_name,
                _overrides(args), args.dry_run)
        elif args.cmd == "install":
            result = install_theme(args.source, args.name)
        elif args.cmd == "uninstall":
            result = uninstall()
        elif args.cmd == "remove":
            root = find_theme(args.theme)
            if not _is_under(root, USER_ICONS):
                raise Fail(f"refusing to delete a theme outside {USER_ICONS}: {root}")
            shutil.rmtree(root)
            result = {"ok": True, "removed": str(root)}
        else:  # pragma: no cover - argparse rejects this first
            raise Fail(f"unknown command {args.cmd}")
    except Fail as exc:
        json.dump({"ok": False, "error": str(exc)}, sys.stdout)
        print()
        return 1
    except ImportError as exc:
        json.dump({"ok": False, "error": f"missing dependency: {exc}. "
                                         "Install win2xcur, python-wand and ImageMagick."},
                  sys.stdout)
        print()
        return 1
    except Exception as exc:  # noqa: BLE001 - the one-JSON-object contract
        # Anything unexpected still answers in JSON: the panel treats empty
        # stdout as "engine missing" and would only show a traceback's first line.
        json.dump({"ok": False, "error": f"{type(exc).__name__}: {exc}"}, sys.stdout)
        print()
        return 1

    json.dump(result, sys.stdout)
    print()
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
