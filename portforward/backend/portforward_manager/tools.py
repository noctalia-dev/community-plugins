"""Discover native commands and explain unsupported runtime environments."""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import TypedDict

REGISTRY = Path(__file__).resolve().parents[1] / "tool-paths.json"
OPTIONAL = {
    "xdg-open": "browser opening",
    "wl-copy": "CLI clipboard copying",
    "journalctl": "service logs",
}


class Report(TypedDict):
    ok: bool
    python: str
    ssh_version: str
    commands: dict[str, str]
    agent_available: bool
    errors: list[str]
    warnings: list[str]


def executable(name: str) -> str:
    if REGISTRY.exists():
        saved = json.loads(REGISTRY.read_text())
        path = saved.get(name)
        if isinstance(path, str):
            if os.access(path, os.X_OK):
                return path
            raise ValueError(f"Installed command unavailable: {name}. Run backend setup again.")
    found = shutil.which(name)
    if found:
        return found
    feature = OPTIONAL.get(name)
    hint = f" Install it to enable {feature}." if feature else " Install it before connecting."
    raise ValueError(f"Required command missing: {name}.{hint}")


def doctor() -> Report:
    report = Report(
        ok=True,
        python=".".join(map(str, sys.version_info[:3])),
        ssh_version="",
        commands={},
        agent_available=False,
        errors=[],
        warnings=[],
    )
    if sys.platform != "linux":
        report["errors"].append("Linux with systemd user services is required.")
    if sys.version_info < (3, 11):  # noqa: UP036 -- report prerequisites on direct execution.
        report["errors"].append("Python 3.11 or newer is required.")
    for name in ("ssh", "systemctl", *OPTIONAL):
        try:
            report["commands"][name] = executable(name)
        except (ValueError, OSError) as error:
            report["warnings" if name in OPTIONAL else "errors"].append(str(error))
    if "ssh" in report["commands"]:
        try:
            result = subprocess.run(
                [report["commands"]["ssh"], "-V"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            match = re.search(r"OpenSSH_(\d+)\.(\d+)", result.stderr + result.stdout)
            if result.returncode or not match or tuple(map(int, match.groups())) < (8, 7):
                report["errors"].append("OpenSSH 8.7 or newer is required; upgrade the SSH client.")
            elif match:
                report["ssh_version"] = match.group(0)
        except (OSError, subprocess.SubprocessError):
            report["errors"].append("Could not check the OpenSSH client version.")
    if "systemctl" in report["commands"]:
        try:
            result = subprocess.run(
                [report["commands"]["systemctl"], "--user", "show", "--property=Version"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if result.returncode:
                report["errors"].append(
                    "Cannot reach the systemd user manager. Run setup from your logged-in "
                    "user session on a systemd distribution."
                )
        except (OSError, subprocess.SubprocessError):
            report["errors"].append("Could not contact the systemd user manager.")
    try:
        Path("/proc/net/tcp").read_text()
        next(Path("/proc/self/fd").iterdir()).readlink()
    except OSError:
        report["errors"].append(
            "Readable Linux /proc socket and own-process information is required."
        )
    sock = os.environ.get("SSH_AUTH_SOCK")
    report["agent_available"] = bool(sock and Path(sock).is_socket())
    if not report["agent_available"]:
        report["warnings"].append(
            "No accessible SSH agent socket in this process. SSH can still use IdentityAgent "
            "from its config or an unencrypted key. Unlock encrypted keys with your SSH agent."
        )
    report["ok"] = not report["errors"]
    return report


def require_ready() -> dict[str, str]:
    report = doctor()
    if not report["ok"]:
        raise ValueError("\n".join(report["errors"]))
    return report["commands"]
