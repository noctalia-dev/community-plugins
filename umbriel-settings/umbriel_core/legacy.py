"""Give the single rolling `<name>.bak` backups of releases up to 0.1.0-004 a timestamp, once (a marker file in
the shared data directory)."""

import datetime
import os
import re

from .backups import STAMP

MARKER = ".migrated-v1"
TIMESTAMPED = re.compile(r"\.\d{8}-\d{6}-\d{6}\.bak$")


def migrate_data_dir(data_dir):
    """Give old rolling backups in the shared backup directory (desktop files, Noctalia's config) a timestamp."""
    marker = os.path.join(data_dir, MARKER)
    if os.path.exists(marker):
        return
    try:
        _adopt_single_backups(os.path.join(data_dir, "backups"))
        _write_marker(marker)
    except OSError:
        pass


def _write_marker(marker):
    os.makedirs(os.path.dirname(marker), exist_ok=True)
    with open(marker, "w", encoding="utf-8"):
        pass


def _adopt_single_backups(directory):
    """Name each old `<name>.bak` by its time, so it sorts and is pruned as that file's oldest snapshot."""
    try:
        names = os.listdir(directory)
    except FileNotFoundError:
        return
    for name in names:
        legacy = os.path.join(directory, name)
        if not name.endswith(".bak") or TIMESTAMPED.search(name) or not os.path.isfile(legacy) \
                or os.path.islink(legacy):
            continue
        stamp = datetime.datetime.fromtimestamp(os.path.getmtime(legacy)).strftime(STAMP)
        target = os.path.join(directory, f"{name[:-len('.bak')]}.{stamp}.bak")
        if not os.path.exists(target):
            os.replace(legacy, target)
