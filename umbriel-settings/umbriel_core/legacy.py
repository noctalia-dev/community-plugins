"""One-time migrations of the shared data directory, each recorded by a marker file in it:
- `.migrated-v1`: the single rolling `<name>.bak` backups of releases up to 0.1.0-004 get a timestamp;
- `.private-v1`: files written by releases up to 0.2.0 become owner-only (backups and sidecars were 0644, their
  directories 0755), also the title-bar script's `*.titlebar.bak` copies of the config.
"""

import datetime
import os
import re
import stat

from .backups import STAMP
from .paths import DATA_DIR_NAME, xdg_config_home

MARKER = ".migrated-v1"
PRIVATE_MARKER = ".private-v1"
TIMESTAMPED = re.compile(r"\.\d{8}-\d{6}-\d{6}\.bak$")


def migrate_data_dir(data_dir):
    """Run the migrations that have not run yet (call under the write lock)."""
    marker = os.path.join(data_dir, MARKER)
    if not os.path.exists(marker):
        try:
            _adopt_single_backups(os.path.join(data_dir, "backups"))
            _write_marker(marker)
        except OSError:
            pass
    marker = os.path.join(data_dir, PRIVATE_MARKER)
    if not os.path.exists(marker):
        try:
            make_private(data_dir)
            make_private(os.path.join(xdg_config_home(), DATA_DIR_NAME), only=".titlebar.bak")
            _write_marker(marker)
        except OSError:
            pass


def make_private(directory, only=None):
    """chmod our directories under `directory` to 0700 and our regular files to 0600 (only names ending in
    `only` when given, and then the directories stay as they are); symlinks are never followed."""
    uid = os.getuid()
    for root, dirs, files in os.walk(directory):
        for name in (dirs if only is None else []) + files:
            full = os.path.join(root, name)
            try:
                info = os.lstat(full)
            except OSError:
                continue
            if info.st_uid != uid or not info.st_mode & 0o077:
                continue
            if stat.S_ISDIR(info.st_mode):
                os.chmod(full, 0o700)
            elif stat.S_ISREG(info.st_mode) and (only is None or name.endswith(only)):
                os.chmod(full, 0o600)


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
