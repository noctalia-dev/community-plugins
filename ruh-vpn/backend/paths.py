"""Filesystem locations supplied by the Noctalia service entry."""

from __future__ import annotations

import os
from pathlib import Path


def _env_path(name: str, fallback: str) -> Path:
    return Path(os.path.expanduser(os.environ.get(name, fallback)))


DATA_DIR = _env_path("RUH_VPN_DATA_DIR", "~/.local/share/ruh-vpn")
RUNTIME_DIR = _env_path("RUH_VPN_RUNTIME_DIR", str(DATA_DIR / "runtime"))
SINGBOX_DIR = DATA_DIR / "sing-box"


def ensure_private_dir(path: Path) -> None:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.chmod(0o700)


def protect_file(path: Path) -> None:
    path.chmod(0o600)

