#!/usr/bin/env python3
"""iconmgr - icon theme engine for the Noctalia icons plugin.

Every subcommand prints exactly one JSON object on stdout, so the Luau side
never has to parse text. Standard library only: the panel shows icon files
itself (the host renders SVG), so nothing here rasterises anything.
"""
from __future__ import annotations

import argparse
import configparser
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.parse
import urllib.request
import zipfile
from functools import lru_cache
from pathlib import Path

HOME = Path.home()
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME") or HOME / ".config")
DATA = Path(os.environ.get("XDG_DATA_HOME") or HOME / ".local" / "share")
CACHE = Path(os.environ.get("XDG_CACHE_HOME") or HOME / ".cache")

# Installed themes go here and nowhere else: it is also the one place a
# Flatpak sandbox sees (as /run/host/user-share/icons) with no override, and
# the only place `remove` and recolouring may write.
USER_ICONS = DATA / "icons"


def _env_dirs(var: str, suffix: str = "") -> list[Path]:
    return [Path(d).expanduser() / suffix for d in os.environ.get(var, "").split(":") if d]


# The icon theme spec's base directories, in its order. XDG_DATA_DIRS is how
# NixOS and Guix expose their profiles' themes.
ICON_DIRS = list(dict.fromkeys([
    USER_ICONS, HOME / ".icons",
    *_env_dirs("ICONMGR_ICON_DIRS"),
    *(_env_dirs("XDG_DATA_DIRS", "icons") if os.environ.get("XDG_DATA_DIRS")
      else [Path("/usr/local/share/icons"), Path("/usr/share/icons")]),
]))

GTK_KEY = "gtk-icon-theme-name"
QT_FILES = {"qt5ct": CONFIG / "qt5ct" / "qt5ct.conf", "qt6ct": CONFIG / "qt6ct" / "qt6ct.conf"}
KDEGLOBALS = CONFIG / "kdeglobals"
OCS_URL = os.environ.get("ICONMGR_OCS_URL", "https://api.gnome-look.org/ocs/v1")
OCS_CATEGORY = "132"  # gnome-look "Full Icon Themes"
USER_AGENT = "noctalia-icons/1.0 (+https://github.com/noctalia-dev/community-plugins)"
HEADERS = {"User-Agent": USER_AGENT, "Accept": "*/*"}
DOWNLOAD_TIMEOUT = float(os.environ.get("ICONMGR_DOWNLOAD_TIMEOUT", "10"))
EXTRACT_DIR = CACHE / "iconmgr" / "extract"
DOWNLOAD_DIR = CACHE / "iconmgr" / "downloads"
ARCHIVES = (".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.bz2", ".tbz2", ".tar.zst", ".tar", ".zip")

# The specimen sheet: real categories, each icon with the names themes ship it
# under. The first name a theme resolves is the one shown.
SPECIMEN = [
    ("folders", [["folder"], ["user-home", "folder-home"], ["folder-download", "folder-downloads"],
                 ["folder-documents"], ["folder-pictures"], ["user-trash", "user-trash-full"]]),
    ("files", [["text-x-generic"], ["application-pdf"], ["image-x-generic"], ["audio-x-generic"],
               ["video-x-generic"], ["package-x-generic", "application-x-archive"]]),
    ("apps", [["web-browser", "firefox", "org.mozilla.firefox"],
              ["system-file-manager", "org.gnome.Nautilus"],
              ["utilities-terminal", "org.gnome.Terminal"],
              ["preferences-system", "org.gnome.Settings"],
              ["accessories-text-editor", "org.gnome.TextEditor"],
              ["multimedia-video-player", "totem"]]),
    ("system", [["network-wireless", "network-wireless-signal-excellent"], ["battery-full", "battery"],
                ["audio-volume-high"], ["bluetooth-active", "bluetooth"], ["computer"],
                ["drive-harddisk"]]),
]
SPECIMEN_SIZE = 48


class Fail(Exception):
    """Anything the user should see as {"ok": false, "error": ...}."""


# --------------------------------------------------------------------------
# theme discovery and icon lookup
# --------------------------------------------------------------------------

@lru_cache(maxsize=None)
def _read_index(root: Path) -> configparser.ConfigParser | None:
    """A theme's index.theme, or None when the dir is not an icon theme.

    A cursor-only theme has [Icon Theme] too, but no Directories: that is
    what tells the two apart. Cached: Papirus's index.theme is large, and the
    inheritance walk asked for it once per icon name - two seconds a specimen."""
    index = root / "index.theme"
    if not index.is_file():
        return None
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    parser.optionxform = str
    try:
        parser.read_string(index.read_text(errors="replace"))
    except configparser.Error:
        return None
    if not parser.has_option("Icon Theme", "Directories"):
        return None
    return parser


def _is_under(path: Path, parent: Path) -> bool:
    try:
        path.resolve().relative_to(parent.resolve())
        return True
    except (ValueError, OSError):
        return False


def _safe_name(name: str) -> bool:
    # Goes into gsettings, ini files and paths: one plain directory name.
    return bool(name) and not name.startswith(".") and not re.search(r"[/\x00-\x1f\x7f]", name)


def list_themes() -> list[dict]:
    themes: dict[str, dict] = {}
    for base in ICON_DIRS:
        if not base.is_dir():
            continue
        for entry in sorted(base.iterdir()):
            # hicolor is every theme's fallback, never a choice; dot-entries
            # are install leftovers.
            if entry.name in themes or entry.name.startswith(".") or entry.name in ("hicolor", "default"):
                continue
            index = _read_index(entry)
            if index is None:
                continue
            removable = _is_under(entry, USER_ICONS)
            themes[entry.name] = {
                "name": entry.name,
                "title": index.get("Icon Theme", "Name", fallback=entry.name),
                "comment": index.get("Icon Theme", "Comment", fallback=""),
                "inherits": index.get("Icon Theme", "Inherits", fallback=""),
                "path": str(entry),
                "removable": removable,
                "folder_color": _folder_color(entry) if removable else "",
                "needs": sorted(_links_into(entry)),
            }
    names = {n.lower(): n for n in themes}
    for theme in themes.values():
        name = theme["name"]
        # A variant names itself after its theme: WhiteSur-light, Papirus-Dark,
        # breeze-dark. The longest such name wins, so Tela-purple-dark goes
        # under Tela-purple when both are there.
        parents = [n for low, n in names.items()
                   if n != name and name.lower().startswith(low + "-")]
        theme["parent"] = max(parents, key=len) if parents else ""
        base = Path(theme["path"]).parent
        theme["missing"] = [n for n in theme["needs"] if not (base / n).is_dir()]
    return sorted(themes.values(), key=lambda t: t["title"].lower())


def _links_into(root: Path) -> set[str]:
    """The sibling themes whose files this one links into.

    WhiteSur-light is little more than links: its apps/, places/ and the rest
    point at ../WhiteSur/, so removing WhiteSur empties it. Links sit at the
    top or one level down; deeper ones are within-theme aliases.
    """
    base, own = root.parent, root.resolve()
    found: set[str] = set()

    def visit(folder: Path, depth: int) -> None:
        try:
            entries = list(os.scandir(folder))
        except OSError:
            return
        for entry in entries:
            if entry.is_symlink():
                target = Path(os.path.normpath(Path(folder) / os.readlink(entry.path)))
                try:
                    rel = target.relative_to(base)
                except ValueError:
                    continue
                if rel.parts and rel.parts[0] != root.name and not str(target).startswith(str(own)):
                    found.add(rel.parts[0])
            elif depth < 2 and entry.is_dir(follow_symlinks=False):
                visit(Path(entry.path), depth + 1)

    visit(root, 1)
    return found


@lru_cache(maxsize=None)
def _theme_roots(name: str) -> tuple[Path, ...]:
    """Every base dir copy of a theme; the spec lets one theme span several."""
    return tuple(base / name for base in ICON_DIRS if (base / name).is_dir())


@lru_cache(maxsize=None)
def _theme_dirs(name: str) -> tuple[tuple[str, dict], ...]:
    for root in _theme_roots(name):
        index = _read_index(root)
        if index is None:
            continue
        dirs = []
        for d in (x.strip() for x in index.get("Icon Theme", "Directories").split(",")):
            if d and index.has_section(d):
                dirs.append((d, {k.lower(): v for k, v in index.items(d)}))
        return tuple(dirs)
    return ()


def _chain(name: str) -> list[str]:
    """The theme, then everything it inherits (breadth first), then hicolor."""
    order, queue = [], [name]
    while queue:
        theme = queue.pop(0)
        if theme in order:
            continue
        order.append(theme)
        for root in _theme_roots(theme):
            index = _read_index(root)
            if index is not None:
                queue += [t.strip() for t in index.get("Icon Theme", "Inherits", fallback="").split(",") if t.strip()]
                break
    if "hicolor" not in order:
        order.append("hicolor")
    return order


def _distance(spec: dict, size: int) -> int:
    """The spec's DirectorySizeDistance, at scale 1."""
    if int(spec.get("scale", "1") or 1) != 1:
        return 10_000  # @2x copies only as a last resort
    nominal = int(spec.get("size", "0") or 0)
    kind = spec.get("type", "Threshold").lower()
    if kind == "fixed":
        return abs(nominal - size)
    if kind == "scalable":
        low = int(spec.get("minsize", nominal) or nominal)
        high = int(spec.get("maxsize", nominal) or nominal)
    else:
        threshold = int(spec.get("threshold", "2") or 2)
        low, high = nominal - threshold, nominal + threshold
    return 0 if low <= size <= high else min(abs(low - size), abs(high - size))


@lru_cache(maxsize=None)
def _dir_files(path: Path) -> frozenset[str]:
    # One listdir per icon dir instead of a stat per name and extension: a
    # Papirus specimen went from over a second to a fraction of one.
    try:
        return frozenset(os.listdir(path))
    except OSError:
        return frozenset()


def find_icon(names: list[str], theme: str, size: int = SPECIMEN_SIZE) -> tuple[str, str] | None:
    """(name, path) for the first of `names` the theme chain has, else None."""
    for name in names:
        for t in _chain(theme):
            best, best_distance = None, None
            for root in _theme_roots(t):
                for d, spec in _theme_dirs(t):
                    files = _dir_files(root / d)
                    for ext in (".svg", ".png"):
                        path = root / d / f"{name}{ext}"
                        if f"{name}{ext}" in files and path.is_file():
                            dist = _distance(spec, size)
                            if best_distance is None or dist < best_distance:
                                best, best_distance = path, dist
            if best is not None:
                return name, str(best)
    return None


def find_theme(name: str) -> Path:
    for root in _theme_roots(name):
        if _read_index(root) is not None:
            return root
    raise Fail(f"icon theme not found: {name}")


def _recolored(path: str, color: str) -> str:
    """The same Papirus folder icon in another colour, read off the link."""
    link = Path(path)
    if not link.is_symlink():
        return path
    m = re.match(r"^(folder|user)-[a-z]+(-.+)?\.svg$", os.readlink(link))
    if not m:
        return path
    other = link.parent / f"{m.group(1)}-{color}{m.group(2) or ''}.svg"
    return str(other) if other.is_file() else path


def specimen(theme: str, folder_color: str | None = None) -> dict:
    """The sample icons. With a folder colour, the folders as they would look
    in it - a preview: nothing on disk changes until `folders` is run."""
    find_theme(theme)
    groups = []
    for group, slots in SPECIMEN:
        icons = []
        for names in slots:
            hit = find_icon(names, theme)
            path = hit[1] if hit else ""
            if path and folder_color and group == "folders":
                path = _recolored(path, folder_color)
            icons.append({"name": hit[0] if hit else names[0], "path": path})
        groups.append({"group": group, "icons": icons})
    return {"ok": True, "theme": theme, "folder_color": folder_color or "", "groups": groups}


# --------------------------------------------------------------------------
# small ini helpers (edit one key, keep everything else byte for byte)
# --------------------------------------------------------------------------

def _ini_get(path: Path, section: str, key: str) -> str:
    if not path.is_file():
        return ""
    current = ""
    for line in path.read_text(errors="replace").splitlines():
        header = re.match(r"^\s*\[(.+?)\]\s*$", line)
        if header:
            current = header.group(1)
            continue
        m = re.match(rf"^\s*{re.escape(key)}\s*=\s*(.*?)\s*$", line)
        if m and current == section:
            return m.group(1)
    return ""


def _ini_set(path: Path, section: str, key: str, value: str | None) -> bool:
    """Set (or with None, drop) one key in one section. True if the file changed."""
    text = path.read_text(errors="replace") if path.is_file() else ""
    lines = text.splitlines()
    out, current, done, in_section, insert_at = [], "", False, False, None
    for line in lines:
        header = re.match(r"^\s*\[(.+?)\]\s*$", line)
        if header:
            if in_section and not done and value is not None and insert_at is None:
                insert_at = len(out)
            current = header.group(1)
            in_section = current == section
            out.append(line)
            continue
        if in_section and re.match(rf"^\s*{re.escape(key)}\s*=", line):
            if not done and value is not None:
                out.append(f"{key}={value}")
            done = True
            continue
        out.append(line)
    if value is not None and not done:
        if insert_at is None and in_section:
            insert_at = len(out)
        if insert_at is not None:
            # After the section's last real line, not after its blank separator.
            while insert_at > 0 and not out[insert_at - 1].strip():
                insert_at -= 1
            out.insert(insert_at, f"{key}={value}")
        else:
            if out and out[-1].strip():
                out.append("")
            out += [f"[{section}]", f"{key}={value}"]
    new = "\n".join(out) + "\n" if out else ""
    if new == text or (not text and value is None):
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(new)
    return True


# --------------------------------------------------------------------------
# reading and applying
# --------------------------------------------------------------------------

def _skipped(reason: str) -> dict:
    """A layer this box simply does not have - never reported as a failure."""
    return {"ok": False, "skipped": True, "reason": reason}


def _gsettings(*args: str) -> dict:
    if not shutil.which("gsettings"):
        return _skipped("gsettings not installed")
    proc = subprocess.run(["gsettings", *args], capture_output=True, text=True, timeout=10)
    if proc.returncode != 0:
        reason = proc.stderr.strip()
        # glib without gsettings-desktop-schemas, or with no schemas at all
        missing = "No such schema" in reason or "No schemas installed" in reason
        return _skipped(reason) if missing else {"ok": False, "reason": reason}
    return {"ok": True, "value": proc.stdout.strip().strip("'\"")}


def _layer(apply, *args) -> dict:
    """One layer's result, never an exception: a read-only settings.ini (Home
    Manager) fails that layer while the others still land."""
    try:
        return apply(*args)
    except (OSError, subprocess.SubprocessError) as exc:
        return {"ok": False, "reason": str(exc)}


def _outcome(ok: bool, layers: dict, **extra) -> dict:
    failed = {name: layer.get("reason", "") for name, layer in layers.items()
              if not layer["ok"] and not layer.get("skipped")}
    result = {"ok": ok, **extra, "layers": layers, "failed": failed}
    if not ok:
        result["error"] = "; ".join(f"{n}: {r}" for n, r in failed.items()) or "no layer could be written"
    return result


def _gtk_files() -> list[Path]:
    return [CONFIG / "gtk-3.0" / "settings.ini", CONFIG / "gtk-4.0" / "settings.ini"]


def _set_gtk(value: str | None) -> dict:
    for path in _gtk_files():
        if value is None and not path.is_file():
            continue
        _ini_set(path, "Settings", GTK_KEY, value)
    return {"ok": True}


def _set_qt(path: Path, section: str, key: str, value: str | None) -> dict:
    # Only a file the user already has: creating qt6ct.conf would not make
    # Qt read it (that takes QT_QPA_PLATFORMTHEME), it would just be litter.
    if not path.is_file():
        return {"ok": True}
    _ini_set(path, section, key, value)
    return {"ok": True}


def read_current() -> dict:
    layers = {}
    gs = _gsettings("get", "org.gnome.desktop.interface", "icon-theme")
    if gs["ok"]:
        layers["gsettings"] = gs["value"]
    for label, path in zip(("gtk3", "gtk4"), _gtk_files()):
        layers[label] = _ini_get(path, "Settings", GTK_KEY)
    for label, path in QT_FILES.items():
        if path.is_file():
            layers[label] = _ini_get(path, "Appearance", "icon_theme")
    if KDEGLOBALS.is_file():
        layers["kdeglobals"] = _ini_get(KDEGLOBALS, "Icons", "Theme")
    # What Noctalia itself shows: gsettings first, then the GTK files.
    theme = layers.get("gsettings") or layers["gtk3"] or layers["gtk4"]
    present = [v for v in layers.values() if v]
    return {"ok": True, "theme": theme, "layers": layers,
            "consistent": len(set(present)) <= 1 and len(present) == len(layers)}


def apply_theme(theme: str) -> dict:
    if not _safe_name(theme):
        raise Fail(f"refusing an unsafe theme name: {theme!r}")
    find_theme(theme)
    info = next((t for t in list_themes() if t["name"] == theme), None)
    if info and info["missing"]:
        gone = ", ".join(info["missing"])
        raise Fail(f"{theme} uses files from {gone}, which is not installed: "
                   f"install {gone} again or remove {theme}")
    layers = {
        "gsettings": _layer(_gsettings, "set", "org.gnome.desktop.interface", "icon-theme", theme),
        "gtk": _layer(_set_gtk, theme),
        **{label: _layer(_set_qt, path, "Appearance", "icon_theme", theme)
           for label, path in QT_FILES.items()},
        "kdeglobals": _layer(_set_qt, KDEGLOBALS, "Icons", "Theme", theme),
    }
    for layer in layers.values():
        layer.pop("value", None)
    return _outcome(any(l["ok"] for l in layers.values()), layers, theme=theme)


def reset() -> dict:
    """Back to the system icons: every key this plugin sets, removed."""
    layers = {
        "gsettings": _layer(_gsettings, "reset", "org.gnome.desktop.interface", "icon-theme"),
        "gtk": _layer(_set_gtk, None),
        **{label: _layer(_set_qt, path, "Appearance", "icon_theme", None)
           for label, path in QT_FILES.items()},
        "kdeglobals": _layer(_set_qt, KDEGLOBALS, "Icons", "Theme", None),
    }
    for layer in layers.values():
        layer.pop("value", None)
    return _outcome(all(l["ok"] or l.get("skipped") for l in layers.values()), layers)


# --------------------------------------------------------------------------
# installing
# --------------------------------------------------------------------------

def _stage(name: str) -> tuple[Path, Path, Path]:
    root, staging, retired = (USER_ICONS / name, USER_ICONS / f".{name}.partial",
                              USER_ICONS / f".{name}.old")
    USER_ICONS.mkdir(parents=True, exist_ok=True)
    for path in (root, staging, retired):
        if not _is_under(path, USER_ICONS):
            raise Fail(f"refusing to write outside {USER_ICONS}: {path}")
    for path in (staging, retired):
        if path.is_symlink() or path.is_file():
            path.unlink()
        elif path.exists():
            shutil.rmtree(path)
    return root, staging, retired


def _swap_in(root: Path, staging: Path, retired: Path) -> None:
    """Rename the finished copy into place; a killed run leaves only dot-dirs."""
    if root.exists() or root.is_symlink():
        root.rename(retired)
    staging.rename(root)
    if retired.exists():
        shutil.rmtree(retired, ignore_errors=True)


def _find_theme_roots(root: Path, max_depth: int = 4) -> list[Path]:
    found = []

    def walk(path: Path, depth: int) -> None:
        if _read_index(path) is not None:
            found.append(path)
            return  # a theme's own subdirs are icon sizes, not more themes
        if depth >= max_depth:
            return
        try:
            children = sorted(p for p in path.iterdir() if p.is_dir() and not p.is_symlink())
        except OSError:
            return
        for child in children:
            walk(child, depth + 1)

    walk(root, 0)
    return found


def _tar_filter(member: tarfile.TarInfo, path: str) -> tarfile.TarInfo | None:
    """tarfile's "data" filter, but a link that points out of the archive is
    dropped rather than failing the whole theme.

    "data" keeps relative links (Papirus is half symlinks) and refuses
    absolute paths, `..` escapes and device files - those still refuse the
    archive. Real themes ship the odd link into the author's own disk
    (Candy Icons: 1 of 2,702, to /usr/share/icons/breeze-dark/...), which
    would only ever dangle here.
    """
    try:
        return tarfile.data_filter(member, path)
    except (tarfile.AbsoluteLinkError, tarfile.LinkOutsideDestinationError):
        return None


def _extract(archive: Path, dest: Path) -> None:
    name = archive.name.lower()
    if name.endswith(".zip"):
        with zipfile.ZipFile(archive) as zf:
            for member in zf.namelist():
                parts = Path(member).parts
                if member.startswith("/") or ".." in parts:
                    raise Fail(f"refusing an archive member outside the archive: {member}")
            zf.extractall(dest)
        return
    if not hasattr(tarfile, "data_filter"):
        raise Fail("extracting archives needs a Python with tarfile's data filter (3.12+)")
    try:
        with tarfile.open(archive) as tf:
            tf.extractall(dest, filter=_tar_filter)
    except tarfile.FilterError as exc:
        raise Fail(f"refusing an unsafe archive: {exc}") from None
    except (tarfile.TarError, EOFError) as exc:
        raise Fail(f"cannot read {archive.name}: {exc}") from None


def install(source: Path, archive_ok: bool = False) -> dict:
    """Install every theme found in a folder.

    From disk it takes folders only: the user extracts an archive themselves.
    Only `fetch` passes archive_ok, since a gnome-look download is always one.
    """
    source = source.expanduser()
    if not source.exists():
        raise Fail(f"not found: {source}")
    if source.is_file() and not archive_ok:
        raise Fail(f"{source.name} is a file: extract it first, then choose the folder")
    workdir = None
    try:
        if source.is_file():
            if not source.name.lower().endswith(ARCHIVES):
                raise Fail(f"not a .tar or .zip archive: {source.name}")
            EXTRACT_DIR.mkdir(parents=True, exist_ok=True)
            workdir = Path(tempfile.mkdtemp(dir=EXTRACT_DIR))
            _extract(source, workdir)
            roots = _find_theme_roots(workdir)
        else:
            roots = _find_theme_roots(source)
        if not roots:
            raise Fail("no icon theme found: a theme is a folder with an index.theme "
                       "that lists Directories")
        installed, replaced = [], []
        for theme_root in roots:
            name = theme_root.name
            if not _safe_name(name) or name in ("hicolor", "default"):
                raise Fail(f"refusing an unsafe theme name: {name!r}")
            root, staging, retired = _stage(name)
            if root.exists():
                replaced.append(name)
            # symlinks=True: themes are full of alias links, and copying their
            # targets would double the size and break recolouring.
            shutil.copytree(theme_root, staging, symlinks=True)
            _swap_in(root, staging, retired)
            installed.append(name)
        for cached in (_read_index, _theme_roots, _theme_dirs, _dir_files):
            cached.cache_clear()
        return {"ok": True, "installed": installed, "replaced": replaced}
    finally:
        if workdir is not None:
            shutil.rmtree(workdir, ignore_errors=True)


def remove(theme: str) -> dict:
    """Remove a theme and every variant built on its files.

    Removing WhiteSur alone left WhiteSur-light as a shell of dangling links,
    and the next apply broke every icon on screen. So the variants go with it,
    and nothing in the family may be the theme in use.
    """
    find_theme(theme)
    themes = {t["name"]: t for t in list_themes()}
    family, queue = [], [theme]
    while queue:
        name = queue.pop(0)
        if name in family:
            continue
        family.append(name)
        queue += [n for n, t in themes.items() if name in t["needs"]]
    # The theme Noctalia shows: gsettings, else GTK's settings.ini.
    in_use = read_current()["theme"]
    if in_use in family:
        raise Fail(f"{in_use} is in use; use another theme before removing {theme}")
    roots = [find_theme(name) for name in family]
    for root in roots:
        if not _is_under(root, USER_ICONS):
            raise Fail(f"only themes in {USER_ICONS} can be removed: {root}")
    for root in reversed(roots):  # variants first, the theme they need last
        shutil.rmtree(root)
    return {"ok": True, "removed": family}


# --------------------------------------------------------------------------
# Papirus folder colours
# --------------------------------------------------------------------------

def _places_dirs(root: Path) -> list[Path]:
    return sorted(p for p in root.glob("*/places") if p.is_dir())


def _folder_color(root: Path) -> str:
    """The colour `folder.svg` points at, for a Papirus-style theme, else ""."""
    for places in _places_dirs(root):
        link = places / "folder.svg"
        if link.is_symlink():
            m = re.match(r"^folder-([a-z]+)\.svg$", os.readlink(link))
            if m:
                return m.group(1)
    return ""


def _folder_colors(root: Path) -> list[dict]:
    """Each colour with its own folder icon, which the panel shows as the swatch."""
    places_dirs = _places_dirs(root)
    # The swatch is the 48px folder when there is one, any size otherwise.
    places_dirs.sort(key=lambda p: p.parent.name != "48x48")
    for places in places_dirs:
        names = {m.group(1) for f in places.glob("folder-*.svg")
                 if not f.is_symlink() and (m := re.match(r"^folder-([a-z]+)\.svg$", f.name))}
        # A real colour comes as a whole set; folder-remote.svg is not one.
        names = sorted(c for c in names if (places / f"folder-{c}-documents.svg").exists())
        if names:
            return [{"name": c, "path": str(places / f"folder-{c}.svg")} for c in names]
    return []


def folders(theme: str, color: str | None) -> dict:
    root = find_theme(theme)
    current = _folder_color(root)
    if not current:
        raise Fail(f"{theme} has no folder colours to choose from")
    colors = _folder_colors(root)
    if color is None or color == current:
        return {"ok": True, "theme": theme, "color": current, "colors": colors, "changed": 0}
    if color not in {c["name"] for c in colors}:
        raise Fail(f"{theme} has no {color} folders")
    if not _is_under(root, USER_ICONS) or not os.access(root, os.W_OK):
        raise Fail(f"{theme} belongs to the system; install it from Get more to recolour it")
    # A size dir or places/ may itself be a link. Into a sibling theme is what a
    # variant is and stays inside USER_ICONS; anywhere else is not ours to
    # rewrite. All checked before the first write, so nothing is half done.
    places_dirs = list(dict.fromkeys(p.resolve() for p in _places_dirs(root)))
    for places in places_dirs:
        if not _is_under(places, USER_ICONS):
            raise Fail(f"refusing to write outside {USER_ICONS}: {places}")
        if not os.access(places, os.W_OK):
            raise Fail(f"{places} is read-only; nothing was changed")
    pattern = re.compile(rf"^(folder|user)-{re.escape(current)}(-.+)?\.svg$")
    changed = 0
    for places in places_dirs:
        for link in places.iterdir():
            if not link.is_symlink():
                continue
            m = pattern.match(os.readlink(link))
            if not m:
                continue
            target = f"{m.group(1)}-{color}{m.group(2) or ''}.svg"
            if not (places / target).exists():
                continue
            tmp = link.with_name(f".{link.name}.tmp")
            tmp.unlink(missing_ok=True)
            tmp.symlink_to(target)
            os.replace(tmp, link)  # atomic: a reader never sees a missing icon
            changed += 1
    # Noctalia watches theme roots; a new mtime makes it reload the icons.
    os.utime(root, None)
    return {"ok": True, "theme": theme, "color": color, "colors": colors, "changed": changed,
            "reloaded": _nudge_icon_theme(theme)}


def _nudge_icon_theme(theme: str) -> bool:
    """Make running apps redraw a theme whose files changed under the same name.

    GTK only notices a changed theme dir the next time it looks an icon up,
    so Files kept the old folder colour until you clicked somewhere else. A
    changed icon-theme setting makes every GTK app - and, through the portal,
    every Flatpak - reload at once, so the setting steps aside and comes back.
    """
    current = _gsettings("get", "org.gnome.desktop.interface", "icon-theme")
    if not current["ok"] or current.get("value") != theme:
        return False  # not in use, nothing on screen to refresh
    # The theme it inherits from, not a bare fallback: if an app does catch the
    # moment between the two writes, it draws near-identical icons.
    fallback = next((t for t in _chain(theme)[1:] if t != theme), "hicolor")
    _gsettings("set", "org.gnome.desktop.interface", "icon-theme", fallback)
    return _gsettings("set", "org.gnome.desktop.interface", "icon-theme", theme)["ok"]


# --------------------------------------------------------------------------
# gnome-look (OCS API)
# --------------------------------------------------------------------------

def _ocs(path: str, params: dict) -> dict:
    url = f"{OCS_URL}/{path}?{urllib.parse.urlencode({**params, 'format': 'json'})}"
    request = urllib.request.Request(url, headers=HEADERS)
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = json.load(response)
    except (OSError, ValueError) as exc:
        raise Fail(f"gnome-look did not answer: {exc}") from None
    if str(payload.get("statuscode")) != "100":
        raise Fail(f"gnome-look said: {payload.get('message') or payload.get('status')}")
    return payload


def _files(item: dict) -> list[dict]:
    files, i = [], 1
    while item.get(f"downloadname{i}") or item.get(f"downloadlink{i}"):
        name = item.get(f"downloadname{i}") or f"file {i}"
        if name.lower().endswith(ARCHIVES):
            files.append({"index": i, "name": name, "kb": int(item.get(f"downloadsize{i}") or 0)})
        i += 1
    return files


def browse(query: str, sort: str, page: int) -> dict:
    params = {"categories": OCS_CATEGORY, "page": page, "pagesize": 20,
              "sortmode": {"new": "new", "rating": "high"}.get(sort, "down")}
    if query:
        params["search"] = query
    payload = _ocs("content/data", params)
    items = []
    for item in payload.get("data") or []:
        # The panel names preview files after the id, so only a plain number passes.
        if not re.fullmatch(r"\d+", str(item.get("id"))):
            continue
        items.append({
            "id": str(item.get("id")), "name": item.get("name", ""),
            "author": item.get("personid", ""), "summary": item.get("summary", ""),
            "downloads": int(item.get("downloads") or 0), "score": int(item.get("score") or 0),
            "preview": item.get("smallpreviewpic1") or item.get("previewpic1") or "",
            "url": item.get("detailpage", ""), "files": _files(item),
        })
    return {"ok": True, "total": int(payload.get("totalitems") or 0), "page": page, "items": items}


def _write_state(path: Path | None, **state) -> None:
    if path is None:
        return
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(state))
    os.replace(tmp, path)  # the panel never reads half a file


def _download(link: str, dest: Path, state: Path | None) -> None:
    # The first request to a freshly signed pling link hangs without an
    # answer (seen every time, header-independent); the same link answers
    # at once on a second try. So: a short wait for the response, a retry.
    for attempt in range(1, 5):
        _write_state(state, state="downloading", done=0, total=0)
        request = urllib.request.Request(link, headers=HEADERS)
        try:
            # The first try is the one that stalls, so it gets a short leash:
            # a healthy server answers in well under a second.
            wait = min(DOWNLOAD_TIMEOUT, 4) if attempt == 1 else DOWNLOAD_TIMEOUT
            with urllib.request.urlopen(request, timeout=wait) as response, \
                    dest.open("wb") as out:
                total = int(response.headers.get("Content-Length") or 0)
                done, last = 0, 0.0
                while chunk := response.read(256 * 1024):
                    out.write(chunk)
                    done += len(chunk)
                    if time.monotonic() - last > 0.3:
                        _write_state(state, state="downloading", done=done, total=total)
                        last = time.monotonic()
            return
        except TimeoutError:
            if attempt == 4:
                raise Fail("download failed: gnome-look did not answer, try again later") from None
        except OSError as exc:
            if "timed out" not in str(exc) or attempt == 4:
                raise Fail(f"download failed: {exc}") from None


def fetch(item_id: str, index: int, state: Path | None) -> dict:
    """Download one file of a gnome-look item and install it.

    Runs detached from the panel (a big theme outlives runAsync's 60s), so
    progress and the final answer also go to `state` for the panel to poll.
    """
    try:
        if not re.fullmatch(r"\d+", item_id):
            raise Fail(f"not a gnome-look id: {item_id}")
        _write_state(state, state="starting")
        data = (_ocs(f"content/data/{item_id}", {}).get("data") or [{}])[0]
        # Links are signed and expire, so they are read fresh, never cached.
        link, name = data.get(f"downloadlink{index}"), data.get(f"downloadname{index}") or ""
        if not link or not name.lower().endswith(ARCHIVES):
            raise Fail("that file is not a .tar or .zip archive")
        parsed = urllib.parse.urlparse(link)
        # https only; plain http just for a test server on this machine.
        if parsed.scheme != "https" and parsed.hostname not in ("127.0.0.1", "localhost"):
            raise Fail("refusing a non-https download link")
        DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
        dest = DOWNLOAD_DIR / re.sub(r"[^\w.+-]", "_", Path(name).name)
        _download(link, dest, state)
        _write_state(state, state="installing")
        try:
            result = install(dest, archive_ok=True)
        finally:
            dest.unlink(missing_ok=True)
        result["source"] = data.get("name", "")
    except Fail as exc:
        result = {"ok": False, "error": str(exc)}
    except Exception as exc:  # noqa: BLE001 - the panel must always get an answer
        result = {"ok": False, "error": f"{type(exc).__name__}: {exc}"}
    _write_state(state, state="done", result=result)
    return result


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="iconmgr")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list", help="list installed icon themes")
    sub.add_parser("current", help="the icon theme each layer holds")
    p = sub.add_parser("specimen", help="the sample icons of a theme")
    p.add_argument("theme")
    p.add_argument("--folder-color", help="preview the folders in this Papirus colour")
    p = sub.add_parser("apply", help="use a theme everywhere")
    p.add_argument("theme")
    sub.add_parser("uninstall", help="back to the system icons")
    p = sub.add_parser("install", help="install the themes in a folder")
    p.add_argument("source", type=Path)
    p = sub.add_parser("remove", help="delete a theme from your home folder")
    p.add_argument("theme")
    p = sub.add_parser("folders", help="show or change a Papirus theme's folder colour")
    p.add_argument("theme")
    p.add_argument("color", nargs="?")
    p = sub.add_parser("browse", help="search gnome-look for icon themes")
    p.add_argument("--query", default="")
    p.add_argument("--sort", choices=("popular", "new", "rating"), default="popular")
    p.add_argument("--page", type=int, default=0)
    p = sub.add_parser("fetch", help="download and install one gnome-look file")
    p.add_argument("item")
    p.add_argument("index", type=int)
    p.add_argument("--state", type=Path)
    args = parser.parse_args(argv)

    try:
        if args.cmd == "list":
            result = {"ok": True, "themes": list_themes()}
        elif args.cmd == "current":
            result = read_current()
        elif args.cmd == "specimen":
            result = specimen(args.theme, args.folder_color)
        elif args.cmd == "apply":
            result = apply_theme(args.theme)
        elif args.cmd == "uninstall":
            result = reset()
        elif args.cmd == "install":
            result = install(args.source)
        elif args.cmd == "remove":
            result = remove(args.theme)
        elif args.cmd == "folders":
            result = folders(args.theme, args.color)
        elif args.cmd == "browse":
            result = browse(args.query, args.sort, args.page)
        else:
            result = fetch(args.item, args.index, args.state)
    except Fail as exc:
        result = {"ok": False, "error": str(exc)}
    except Exception as exc:  # noqa: BLE001 - the one-JSON-object contract
        result = {"ok": False, "error": f"{type(exc).__name__}: {exc}"}

    json.dump(result, sys.stdout)
    print()
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
