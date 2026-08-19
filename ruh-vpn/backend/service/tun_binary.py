"""Private copy of the sing-box binary used only for TUN mode.

CAP_NET_ADMIN is granted to a plugin-private copy under DATA_DIR/bin (a 0700
directory) instead of the shared system binary, so the privilege never
extends to other users or to sing-box invocations outside this plugin.

When the system binary changes, the copy is rewritten from scratch; a fresh
file starts with no capabilities, so a stale copy never keeps the grant
across sing-box upgrades.
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path

from backend.paths import DATA_DIR, ensure_private_dir

BIN_DIR = DATA_DIR / "bin"
TUN_BIN = BIN_DIR / "sing-box-tun"


def source_binary(singbox_bin: str) -> str:
    # setcap/getcap act on the real file, not a symlink (NixOS wraps binaries
    # in store symlinks, and setcap on the link fails).
    return os.path.realpath(singbox_bin)


def ensure_copy(singbox_bin: str) -> tuple[str, bool]:
    """Make sure the private copy exists and matches the system binary.

    Returns (path to the copy, True if the copy was (re)created). Callers must
    treat a recreated copy as having no capabilities.
    """
    src = Path(source_binary(singbox_bin))
    ensure_private_dir(BIN_DIR)
    st_src = src.stat()
    if TUN_BIN.exists():
        st_dst = TUN_BIN.stat()
        if st_dst.st_size == st_src.st_size and st_dst.st_mtime == st_src.st_mtime:
            return str(TUN_BIN), False
    # copy2 preserves mtime, which the staleness check above relies on
    tmp = TUN_BIN.with_name(TUN_BIN.name + ".tmp")
    shutil.copy2(src, tmp)
    tmp.chmod(0o700)
    os.replace(tmp, TUN_BIN)
    return str(TUN_BIN), True
