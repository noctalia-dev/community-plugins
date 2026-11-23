"""Installed cursor theme discovery."""

import configparser
import os
import warnings

from .paths import xdg_data_dirs, xdg_data_home


def installed_cursor_themes():
    """Find cursor themes and inheritance-only aliases in cursor search paths."""
    cursor_path = os.environ.get("XCURSOR_PATH")
    if cursor_path is not None:
        roots = cursor_path.split(os.pathsep)
    else:
        roots = [
            os.path.expanduser("~/.icons"),
            os.path.join(xdg_data_home(), "icons"),
            *(os.path.join(directory, "icons") for directory in xdg_data_dirs()),
            "/usr/share/pixmaps",
        ]
    themes = set()
    aliases = {}
    for root in roots:
        if not root:
            continue
        root = os.path.expanduser(root)
        try:
            entries = list(os.scandir(root))
        except FileNotFoundError:
            continue
        except OSError as error:
            warnings.warn(f"Could not scan cursor theme directory {root}: {error}", RuntimeWarning, stacklevel=2)
            continue
        for entry in entries:
            if not entry.is_dir():
                continue
            if os.path.isdir(os.path.join(entry.path, "cursors")):
                themes.add(entry.name)
                continue
            index_path = os.path.join(entry.path, "index.theme")
            try:
                with os.scandir(entry.path) as children:
                    if any(child.is_dir() for child in children):
                        continue
                with open(index_path, encoding="utf-8") as index_file:
                    index = configparser.ConfigParser(interpolation=None, strict=False)
                    index.read_file(index_file)
            except FileNotFoundError:
                continue
            except (OSError, UnicodeError, configparser.Error) as error:
                warnings.warn(f"Could not read cursor theme index {index_path}: {error}", RuntimeWarning, stacklevel=2)
                continue
            inherited = index.get("Icon Theme", "Inherits", fallback="")
            aliases.setdefault(entry.name, set()).update(
                name.strip() for name in inherited.split(",") if name.strip()
            )
    while True:
        inherited_themes = {name for name, parents in aliases.items() if parents & themes}
        new_themes = inherited_themes - themes
        if not new_themes:
            break
        themes.update(new_themes)
    return sorted(themes, key=lambda name: (name.casefold(), name))
