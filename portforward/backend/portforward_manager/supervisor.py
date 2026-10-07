"""Systemd controls and status shared by the CLI and desktop panel."""

from __future__ import annotations

import json
import os
import socket
import subprocess
from pathlib import Path
from typing import Any

from .diagnostics import describe
from .model import RUNTIME, STATE, Profile, atomic_json, check_ports, private_dir, valid_id
from .tools import executable


def command(argv: list[str], *, timeout: int = 15) -> str:
    result = subprocess.run(
        [executable(argv[0]), *argv[1:]],
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    if result.returncode:
        raise ValueError(
            result.stderr.strip() or result.stdout.strip() or f"Command failed: {argv[0]}"
        )
    return result.stdout


def unit(profile_id: str) -> str:
    return f"portforward@{valid_id(profile_id)}.service"


def control(action: str, profile_id: str, *, asynchronous: bool = False) -> None:
    if (
        action == "reset-failed"
        and properties([profile_id])[unit(profile_id)].get("ActiveState") != "failed"
    ):
        return
    argv = ["systemctl", "--user", action]
    if asynchronous:
        argv.append("--no-block")
    command([*argv, unit(profile_id)])


def properties(ids: list[str]) -> dict[str, dict[str, str]]:
    if not ids:
        return {}
    output = command(
        [
            "systemctl",
            "--user",
            "show",
            "--property=Id,ActiveState,SubState,MainPID,NRestarts,Result",
            *map(unit, ids),
        ]
    )
    result: dict[str, dict[str, str]] = {}
    for block in output.strip().split("\n\n"):
        values = dict(line.split("=", 1) for line in block.splitlines() if "=" in line)
        if "Id" in values:
            result[values["Id"]] = values
    return result


def state_file(profile_id: str) -> Path:
    return STATE / f"{valid_id(profile_id)}.json"


def status(profiles: dict[str, Profile]) -> dict[str, Any]:
    units = properties(list(profiles))
    rows: list[dict[str, Any]] = []
    for profile_id, profile in profiles.items():
        details = units.get(unit(profile_id), {})
        active = details.get("ActiveState", "inactive")
        sub = details.get("SubState", "dead")
        try:
            cached: dict[str, Any] = json.loads(state_file(profile_id).read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            cached = {}
        pid = int(details.get("MainPID", "0"))
        error = cached.get("error", "")
        if active == "active" and cached.get("pid") == pid:
            phase = cached.get("state", "connecting")
        elif active == "active":
            phase = "connecting"
        elif active == "activating":
            phase = (
                "reconnecting"
                if sub == "auto-restart" or int(details.get("NRestarts", "0"))
                else "connecting"
            )
        elif active == "failed":
            phase = "error"
            error = error or f"Service failed: {details.get('Result', 'unknown')}. See Logs."
        else:
            phase = "error" if cached.get("state") == "error" else "disconnected"
        rows.append(
            {
                **profile,
                "state": phase,
                "error": error,
                "issue": describe(profile, error) if error else None,
                "pid": pid,
                "restarts": int(details.get("NRestarts", "0")),
            }
        )
    return {"profiles": rows}


def running(profile_id: str) -> bool:
    return properties([profile_id])[unit(profile_id)].get("ActiveState") in ("active", "activating")


def agent_environment(profile_id: str) -> None:
    """Reuse the caller's live agent without changing the global user environment."""
    private_dir(RUNTIME)
    sock = os.environ.get("SSH_AUTH_SOCK")
    path = RUNTIME / f"agent-{valid_id(profile_id)}.env"
    if not sock:
        path.unlink(missing_ok=True)
        return  # The service can still inherit systemd's agent or SSH IdentityAgent.
    if any(c in sock for c in "\n\r\x00"):
        raise ValueError("Invalid SSH_AUTH_SOCK path.")
    escaped = sock.replace("\\", "\\\\").replace('"', '\\"')
    path.write_text(f'SSH_AUTH_SOCK="{escaped}"\n')
    path.chmod(0o600)


def connect(profile: Profile) -> None:
    from .tools import require_ready

    require_ready()
    profile_id = profile["id"]
    if running(profile_id):
        return
    try:
        check_ports(profile)
    except ValueError as error:
        atomic_json(state_file(profile_id), {"state": "error", "error": str(error), "pid": 0})
        raise
    agent_environment(profile_id)
    control("start", profile_id, asynchronous=True)


def resolve(host: str) -> dict[str, str]:
    from .model import valid_host

    output = command(["ssh", "-G", valid_host(host, destination=True)])
    allowed = {"hostname", "user", "port", "identityfile", "identityagent", "proxyjump"}
    resolved: dict[str, str] = {}
    for line in output.splitlines():
        key, _, value = line.partition(" ")
        if key in allowed:
            resolved[key] = f"{resolved[key]}, {value}" if key in resolved else value
    return resolved


def notify(message: str) -> None:
    address = os.environ.get("NOTIFY_SOCKET")
    if not address:
        return
    if address.startswith("@"):
        address = "\0" + address[1:]
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
        sock.sendto(message.encode(), address)
