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
import tempfile
import time
from pathlib import Path

HOME = Path.home()
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME") or HOME / ".config")
DATA = Path(os.environ.get("XDG_DATA_HOME") or HOME / ".local" / "share")
CACHE = Path(os.environ.get("XDG_CACHE_HOME") or HOME / ".cache")

USER_ICONS = DATA / "icons"
ICON_DIRS = [USER_ICONS, HOME / ".icons", Path("/usr/share/icons")]
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

def _gsettings(key: str) -> str:
    if not shutil.which("gsettings"):
        return ""
    try:
        out = subprocess.run(
            ["gsettings", "get", "org.gnome.desktop.interface", key],
            capture_output=True, text=True, timeout=10,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.strip("'\"")


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
    layers |= {
        "gsettings": _gsettings("cursor-theme"),
        "gtk3": _ini_value(CONFIG / "gtk-3.0" / "settings.ini", "gtk-cursor-theme-name"),
        "gtk4": _ini_value(CONFIG / "gtk-4.0" / "settings.ini", "gtk-cursor-theme-name"),
        "xdg_default": _index_field(HOME / ".icons" / "default" / "index.theme", "Inherits"),
        "environment": env_theme.group(1).strip() if env_theme else "",
    }
    present = [v for v in layers.values() if v]
    return {
        "ok": True,
        "theme": first.get("theme") or layers["gsettings"],
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


def _render_niri(theme: str, size: int, hide_typing: bool, hide_ms: int, config_text: str) -> str:
    lines = ["cursor {", f'    xcursor-theme "{theme}"', f"    xcursor-size {size}"]
    if hide_typing:
        lines.append("    hide-when-typing")
    if hide_ms > 0:
        lines.append(f"    hide-after-inactive-ms {hide_ms}")
    lines.append("}")
    # niri allows only one top-level `environment` node, so leave XCURSOR_* to
    # environment.d when the user already owns that block.
    if not re.search(r"^environment\s*\{", config_text, re.M):
        lines += ["environment {", f'    XCURSOR_THEME "{theme}"',
                  f'    XCURSOR_SIZE "{size}"', "}"]
    return "\n".join(lines) + "\n"


def _render_hyprland(theme: str, size: int, hide_typing: bool, hide_ms: int, config_text: str) -> str:
    # Hyprland has no cursor-theme option: the theme travels as XCURSOR_* env,
    # and `hyprctl setcursor` (see the reload argv) is what moves the pointer
    # now rather than at next login. Both hide keys are always written, because
    # the parser is last-wins and an omitted key would leave an earlier one of
    # the user's standing when the panel turns the toggle off.
    return "\n".join([
        f"env = XCURSOR_THEME,{theme}",
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
        f"seat * xcursor_theme {theme} {size}",
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


# One entry per compositor whose own cursor has to be set separately from the
# four portable layers. Adding a compositor is adding a row here, not a new
# write path: `_apply_compositor` and `_read_compositor` are the only code.
COMPOSITORS = {
    "niri": {
        "config": CONFIG / "niri" / "config.kdl",
        "include_file": CONFIG / "niri" / "cursor.kdl",
        "include_line": 'include "cursor.kdl"',
        "comment": "//",
        "render": _render_niri,
        # A second top-level `cursor` node is a KDL collision, not an override,
        # so niri is the one compositor whose conflicting block must go. The
        # other three are last-wins parsers and the include is appended last.
        "comment_block": "cursor",
        "validate": ["niri", "validate", "-c"],
        "reload": [],  # niri watches config.kdl; the mtime bump below is enough
        "theme_re": r'xcursor-theme\s+"([^"]*)"',
        "size_re": r"xcursor-size\s+(\d+)",
        "typing_re": r"hide-when-typing",
        "ms_re": r"hide-after-inactive-ms\s+(\d+)",
        "ms_scale": 1,
    },
    "hyprland": {
        "config": CONFIG / "hypr" / "hyprland.conf",
        "include_file": CONFIG / "hypr" / "cursor.conf",
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
        "size_re": r"^env\s*=\s*XCURSOR_SIZE,(\d+)$",
        "typing_re": r"hide_on_key_press\s*=\s*true",
        "ms_re": r"inactive_timeout\s*=\s*(\d+)",
        "ms_scale": 1000,
    },
    "sway": {
        "config": CONFIG / "sway" / "config",
        "include_file": CONFIG / "sway" / "cursor.conf",
        "include_line": "include {file}",
        "comment": "#",
        "render": _render_sway,
        "validate": ["sway", "-C", "-c"],
        "reload": [["swaymsg", "reload"]],
        "theme_re": r"^seat\s+\S+\s+xcursor_theme\s+(\S+)",
        "size_re": r"^seat\s+\S+\s+xcursor_theme\s+\S+\s+(\d+)",
        "typing_re": r"hide_cursor\s+when-typing\s+enable",
        "ms_re": r"hide_cursor\s+(\d+)",
        "ms_scale": 1,
    },
    "mango": {
        "config": CONFIG / "mango" / "config.conf",
        "include_file": CONFIG / "mango" / "cursor.conf",
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
        "size_re": r"^cursor_size=(\d+)$",
        "typing_re": r"^cursor_hide_on_keypress=[1-9]",
        "ms_re": r"^cursor_hide_timeout=(\d+)$",
        "ms_scale": 1000,
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
    dest = path.with_name(f"{path.name}.bak-cursor-{time.strftime('%Y%m%d-%H%M%S')}")
    shutil.copy2(path, dest)
    return dest


def _read_compositor(spec: dict) -> dict:
    text = (spec["include_file"].read_text(errors="replace")
            if spec["include_file"].is_file() else "")
    theme = re.search(spec["theme_re"], text, re.M)
    size = re.search(spec["size_re"], text, re.M)
    ms = re.search(spec["ms_re"], text, re.M)
    return {
        "theme": theme.group(1).strip() if theme else "",
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

    include_file.write_text(f"{comment} {MANAGED_TEXT}\n"
                            + spec["render"](theme, size, hide_typing, hide_ms, text))

    if not re.search(rf"^\s*{re.escape(include_line)}\s*$", text, re.M):
        if backup is None:
            backup = _backup(config)
        text = text.rstrip("\n") + f"\n\n{comment} {MANAGED_TEXT}\n{include_line}\n"
        notes.append(f"added {include_line}")

    if text != config.read_text():
        config.write_text(text)

    ok, err = _validate(spec["validate"], config)
    if not ok:
        if backup is not None:
            shutil.copy2(backup, config)
        include_file.unlink(missing_ok=True)
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
            out.append(f"{comment} " + line)
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


def _apply_gsettings(theme: str, size: int) -> dict:
    if not shutil.which("gsettings"):
        return {"ok": False, "reason": "gsettings not installed"}
    for key, value in (("cursor-theme", theme), ("cursor-size", str(size))):
        proc = subprocess.run(["gsettings", "set", "org.gnome.desktop.interface", key, value],
                              capture_output=True, text=True, timeout=10)
        if proc.returncode != 0:
            return {"ok": False, "reason": proc.stderr.strip()}
    return {"ok": True}


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


def _apply_environment(theme: str, size: int) -> dict:
    ENV_CONF.parent.mkdir(parents=True, exist_ok=True)
    ENV_CONF.write_text(f"# {MANAGED_TEXT}\nXCURSOR_THEME={theme}\nXCURSOR_SIZE={size}\n")
    return {"ok": True, "file": str(ENV_CONF), "note": "applies to processes started after next login"}


def apply_theme(theme: str, size: int, hide_typing: bool, hide_ms: int) -> dict:
    find_theme(theme)  # fail fast on a typo before touching any config
    detected = detected_compositors()
    layers = {name: _apply_compositor(name, spec, theme, size, hide_typing, hide_ms)
              for name, spec in detected.items()}
    layers |= {
        "gsettings": _apply_gsettings(theme, size),
        "gtk": _apply_gtk(theme, size),
        "xdg_default": _apply_xdg_default(theme),
        "environment": _apply_environment(theme, size),
    }
    # Under a supported compositor its own cursor is the one the user sees on
    # the desktop, so every detected one has to land. With none configured the
    # four portable layers still change the cursor and decide on their own.
    ok = (all(layers[name]["ok"] for name in detected) if detected
          else any(layer["ok"] for layer in layers.values()))
    return {"ok": ok, "theme": theme, "size": size, "layers": layers}


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
    root = USER_ICONS / name
    USER_ICONS.mkdir(parents=True, exist_ok=True)
    # Belt and braces, as in install_theme: catches a symlink planted in
    # USER_ICONS itself, which a name check cannot see.
    if not _is_under(root, USER_ICONS):
        raise Fail(f"refusing to write outside {USER_ICONS}: {root}")
    cursors = root / "cursors"
    cursors.mkdir(parents=True, exist_ok=True)

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

    (root / "index.theme").write_text(
        f"[Icon Theme]\nName={name}\nComment=Built by the Noctalia cursor plugin\n"
        f"Inherits={inherits}\n"
    )
    (root / "cursor.theme").write_text(f"[Icon Theme]\nName={name}\nInherits={name}\n")
    return {"path": str(root), "cursors": written}


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


def _source_dir(path: Path) -> tuple[Path, tempfile.TemporaryDirectory | None]:
    if path.is_dir():
        return path, None
    if path.suffix.lower() in {".zip", ".tar", ".tgz", ".gz", ".bz2", ".xz"}:
        tmp = tempfile.TemporaryDirectory(prefix="curmgr-")
        # A tar entry named ../.. escapes the extraction directory unless the
        # 'data' filter is on: 3.14 defaults to it, 3.12 and 3.13 need asking.
        # zipfile sanitises member paths itself and rejects the keyword, so this
        # is tar-only.
        # ponytail: 3.11 has no filter argument at all and stays trusting. Drop
        # the version check once 3.11 is not worth supporting.
        extra = {}
        if path.suffix.lower() != ".zip" and sys.version_info >= (3, 12):
            extra["filter"] = "data"
        shutil.unpack_archive(str(path), tmp.name, **extra)
        return Path(tmp.name), tmp
    if path.suffix.lower() in {".cur", ".ani"}:
        raise Fail("a single cursor file is not a pack - pick the folder that holds it")
    raise Fail(f"unsupported import source: {path}")


def import_windows(source: Path, name: str, shadow_opts=None, sizes=NOMINAL_SIZES,
                   filter_name="lanczos", overrides: dict[str, str] | None = None,
                   dry_run: bool = False) -> dict:
    from win2xcur.parser import open_blob
    from win2xcur.parser.inf import parse_inf
    from win2xcur.theme import WIN_CURSORS, XCURSOR_ALIASES

    root, tmp = _source_dir(source)
    try:
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
    finally:
        if tmp is not None:
            tmp.cleanup()


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
            stack.extend((d, depth + 1) for d in current.iterdir() if d.is_dir())
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
    return name


def install_theme(source: Path, name: str = "") -> dict:
    """Copy a finished Xcursor theme into ~/.local/share/icons."""
    if not source.exists():
        raise Fail(f"no such path: {source}")

    root, tmp = _source_dir(source)
    try:
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
            dest = USER_ICONS / dest_name
            # Belt and braces: the name is sanitised above, this catches symlink
            # games in USER_ICONS itself before anything is deleted.
            USER_ICONS.mkdir(parents=True, exist_ok=True)
            if not _is_under(dest.parent / dest.name, USER_ICONS):
                raise Fail(f"refusing to write outside {USER_ICONS}: {dest}")
            if dest.exists() or dest.is_symlink():
                if not _is_under(dest, USER_ICONS):
                    raise Fail(f"refusing to replace a theme outside {USER_ICONS}: {dest}")
                shutil.rmtree(dest) if dest.is_dir() and not dest.is_symlink() else dest.unlink()
                replaced.append(dest_name)
            # symlinks=True is load-bearing: a real theme is roughly half alias
            # symlinks, and dereferencing them bloats it and loses the aliasing.
            shutil.copytree(theme_root, dest, symlinks=True)
            installed.append(dest_name)

        return {"ok": True, "installed": installed, "replaced": replaced,
                "path": str(USER_ICONS)}
    finally:
        if tmp is not None:
            tmp.cleanup()


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
    from wand.color import Color
    from wand.image import Image
    from win2xcur.parser import open_blob

    root = find_theme(theme)
    cursors = root / "cursors"
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    out_path = PREVIEW_DIR / f"{theme}.png"

    newest = max((p.stat().st_mtime for p in cursors.iterdir()), default=0)
    if not force and out_path.is_file() and out_path.stat().st_mtime >= newest:
        return {"ok": True, "preview": str(out_path), "cached": True}

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
    return {"ok": True, "preview": str(out_path), "cached": False, "slots": len(picks)}


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
    p.add_argument("source", type=Path, help="folder or archive")
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

    p = sub.add_parser("install", help="install a finished Xcursor theme (folder or archive)")
    p.add_argument("source", type=Path, help="folder or archive holding a cursors/ directory")
    p.add_argument("--name", default="", help="install under this name instead of the theme's own")

    p = sub.add_parser("remove", help="delete a theme you built (never a system one)")
    p.add_argument("theme")

    args = parser.parse_args(argv)

    try:
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

    json.dump(result, sys.stdout)
    print()
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
