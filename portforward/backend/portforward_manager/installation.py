"""Install the bundled source outside Noctalia's replaceable plugin directory."""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

from . import tools

HOME = Path.home()
TARGET = (
    Path(os.environ.get("XDG_DATA_HOME", str(HOME / ".local/share")))
    / "portforward-manager/backend"
)
LAUNCHER = HOME / ".local/bin/portforward"
UNIT = (
    Path(os.environ.get("XDG_CONFIG_HOME", str(HOME / ".config")))
    / "systemd/user/portforward@.service"
)
RECORD = (
    Path(os.environ.get("XDG_STATE_HOME", str(HOME / ".local/state")))
    / "portforward-manager/backend.json"
)


def command(*argv: str) -> str:
    result = subprocess.run(
        [tools.executable("systemctl"), "--user", *argv],
        capture_output=True,
        text=True,
        timeout=15,
        check=False,
    )
    if result.returncode:
        raise ValueError(result.stderr.strip() or "The systemd user command failed.")
    return result.stdout


def write(path: Path, content: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".portforward-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        Path(name).chmod(mode)
        Path(name).replace(path)
    finally:
        Path(name).unlink(missing_ok=True)


def unit_quote(value: str) -> str:
    if any(c in value for c in "\r\n\x00"):
        raise ValueError("Installation paths and PATH must not contain line breaks.")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%") + '"'


def fingerprint(source: Path, commands: dict[str, str]) -> str:
    digest = hashlib.sha256()
    for path in sorted(source.rglob("*")):
        if path.is_file() and (path.suffix in (".py", ".service") or path.name == "LICENSE"):
            digest.update(str(path.relative_to(source)).encode())
            digest.update(path.read_bytes())
    digest.update(json.dumps(commands, sort_keys=True).encode())
    digest.update(str(Path(sys.executable).resolve()).encode())
    return digest.hexdigest()


def ensure(source: Path) -> dict[str, str]:
    commands = tools.require_ready()
    RECORD.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (RECORD.parent / ".backend.lock").open("a") as lock:
        os.fchmod(lock.fileno(), 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        return install_locked(source, commands)


def install_locked(source: Path, commands: dict[str, str]) -> dict[str, str]:
    record: dict[str, Any] = json.loads(RECORD.read_text()) if RECORD.exists() else {}
    if record and record.get("target") != str(TARGET):
        raise ValueError(
            "Backend install location changed. Remove the previous installation first."
        )
    if not record:
        for path in (LAUNCHER, UNIT, TARGET):
            if path.exists() or path.is_symlink():
                raise ValueError(f"{path} already exists. Remove the existing installation first.")
    revision = fingerprint(source, commands)
    if (
        record.get("revision") == revision
        and LAUNCHER.exists()
        and UNIT.exists()
        and TARGET.exists()
    ):
        return {"cli": str(LAUNCHER)}
    active = command(
        "list-units", "portforward@*.service", "--state=active,activating", "--no-legend", "--plain"
    )
    if active.strip():
        if record and LAUNCHER.exists() and UNIT.exists() and TARGET.exists():
            return {
                "cli": str(LAUNCHER),
                "warning": "Disconnect forwarding profiles to apply the backend update.",
            }
        raise ValueError("Disconnect forwarding profiles before installing the backend.")
    launcher = (
        "#!/bin/sh\nexec "
        + shlex.quote(str(Path(sys.executable).resolve()))
        + " -I "
        + shlex.quote(str(TARGET / "entry.py"))
        + ' "$@"\n'
    )
    unit = (
        (source / "portforward@.service")
        .read_text()
        .replace("@LAUNCHER@", unit_quote(str(LAUNCHER)))
    )
    # Preserve the installation session's PATH for SSH ProxyCommand/ProxyJump helpers.
    unit += "Environment=" + unit_quote("PATH=" + os.environ.get("PATH", os.defpath)) + "\n"
    TARGET.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.TemporaryDirectory(prefix=".backend-", dir=TARGET.parent) as directory:
        staging = Path(directory) / "backend"
        shutil.copytree(
            source, staging, ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "*.egg-info")
        )
        for path in staging.rglob("*"):
            path.chmod(0o700 if path.is_dir() else 0o600)
        staging.chmod(0o700)
        write(staging / "tool-paths.json", json.dumps(commands, indent=2) + "\n")
        previous = Path(directory) / "previous"
        original_files = {
            path: (path.read_text(), path.stat().st_mode & 0o777) if path.exists() else None
            for path in (LAUNCHER, UNIT, RECORD)
        }
        if TARGET.exists():
            TARGET.rename(previous)
        try:
            staging.rename(TARGET)
            write(LAUNCHER, launcher, 0o700)
            write(UNIT, unit)
            write(
                RECORD, json.dumps({"target": str(TARGET), "revision": revision}, indent=2) + "\n"
            )
            command("daemon-reload")
        except BaseException:
            shutil.rmtree(TARGET, ignore_errors=True)
            if previous.exists():
                previous.rename(TARGET)
            for path, original in original_files.items():
                if original is None:
                    path.unlink(missing_ok=True)
                else:
                    write(path, *original)
            raise
    return {"cli": str(LAUNCHER)}


def stop_all() -> None:
    units = command("list-units", "portforward@*.service", "--all", "--no-legend", "--plain")
    for line in units.splitlines():
        fields = line.lstrip("● ").split()
        command("stop", fields[0])
        if "failed" in fields[1:4]:
            command("reset-failed", fields[0])


def remove() -> None:
    if not RECORD.exists():
        raise ValueError("No backend installation record; refusing to remove unowned files.")
    with (RECORD.parent / ".backend.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        record = json.loads(RECORD.read_text())
        if record.get("target") != str(TARGET):
            raise ValueError("Backend installation record does not match this installation.")
        remove_locked()


def remove_locked() -> None:
    stop_all()
    UNIT.unlink(missing_ok=True)
    command("daemon-reload")
    LAUNCHER.unlink(missing_ok=True)
    shutil.rmtree(TARGET)
    RECORD.unlink()
