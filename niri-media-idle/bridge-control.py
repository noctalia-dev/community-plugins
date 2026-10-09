#!/usr/bin/env python3
"""Control the plugin's transient user unit without passing commands through a shell."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path


UNIT = "noctalia-niri-media-idle.service"
PLUGIN_DIR = Path(__file__).resolve().parent
BRIDGE = PLUGIN_DIR / "media-idle-bridge"
RULES = PLUGIN_DIR / "media-idle-rules.toml"
COMMAND_TIMEOUT_SECONDS = 15
RUNTIME_DIRECTORY = "noctalia-niri-media-idle"
STATUS_FIELDS = {
    "version",
    "pid",
    "media",
    "state",
    "logind_idle_held",
    "screensaver_held",
    "sleep_held",
}
MEDIA_STATES = {"none", "music", "video", "unknown"}
PROTECTION_STATES = {
    "unknown",
    "normal",
    "music_sleep",
    "music_sleep_incomplete",
    "protected",
    "incomplete",
}
STARTUP_GRACE_USEC = 3_000_000


class ControlError(Exception):
    pass


class DuplicateStatusField(ValueError):
    pass


def unique_json_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    record: dict[str, object] = {}
    for key, value in pairs:
        if key in record:
            raise DuplicateStatusField(key)
        record[key] = value
    return record


def run_command(
    command: list[str],
    allowed_returncodes: tuple[int, ...] = (0,),
) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            check=False,
            shell=False,
            text=True,
            timeout=COMMAND_TIMEOUT_SECONDS,
        )
    except FileNotFoundError as err:
        raise ControlError(f"{command[0]} is not installed or not on PATH") from err
    except subprocess.TimeoutExpired as err:
        raise ControlError(f"{command[0]} timed out") from err
    except OSError as err:
        raise ControlError(f"{command[0]} could not be run: {err}") from err

    if result.returncode not in allowed_returncodes:
        detail = (result.stderr or result.stdout).strip()
        if not detail:
            detail = f"exit status {result.returncode}"
        raise ControlError(f"{command[0]} failed: {detail}")
    return result


def unit_state() -> str:
    result = run_command(
        ["systemctl", "--user", "is-active", UNIT],
        allowed_returncodes=(0, 3, 4),
    )
    if result.returncode == 0:
        return "active"
    if result.returncode == 3 and result.stdout.strip() == "failed":
        return "failed"
    return "inactive"


def status_file_path() -> Path | None:
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR")
    if not runtime_dir or not Path(runtime_dir).is_absolute():
        return None
    return Path(runtime_dir) / RUNTIME_DIRECTORY / "status.json"


def valid_status_record(record: object) -> bool:
    if type(record) is not dict or set(record) != STATUS_FIELDS:
        return False
    if type(record["version"]) is not int or record["version"] != 2:
        return False
    if type(record["pid"]) is not int or record["pid"] <= 0:
        return False
    if type(record["media"]) is not str or record["media"] not in MEDIA_STATES:
        return False
    if type(record["state"]) is not str or record["state"] not in PROTECTION_STATES:
        return False
    if any(
        type(record[field]) is not bool
        for field in ("logind_idle_held", "screensaver_held", "sleep_held")
    ):
        return False

    media = record["media"]
    state = record["state"]
    idle_held = record["logind_idle_held"]
    screensaver_held = record["screensaver_held"]
    sleep_held = record["sleep_held"]

    if state == "unknown":
        return media == "unknown" and not idle_held and not screensaver_held and not sleep_held
    if media == "none":
        return state == "normal" and not idle_held and not screensaver_held and not sleep_held
    if media == "music":
        if idle_held or screensaver_held:
            return False
        return (state == "music_sleep" and sleep_held) or (
            state == "music_sleep_incomplete" and not sleep_held
        )
    if media == "video":
        fully_protected = idle_held and screensaver_held and sleep_held
        return (state == "protected" and fully_protected) or (
            state == "incomplete" and not fully_protected
        )
    return False


def unknown_active_state() -> str:
    result = run_command(
        [
            "systemctl",
            "--user",
            "show",
            "--property=ActiveEnterTimestampMonotonic",
            "--value",
            UNIT,
        ]
    )
    entered_text = result.stdout.strip()
    if not entered_text.isascii() or not entered_text.isdigit():
        return "unknown"

    try:
        entered_usec = int(entered_text)
    except ValueError:
        return "unknown"
    age_usec = time.monotonic_ns() // 1000 - entered_usec
    if 0 <= age_usec < STARTUP_GRACE_USEC:
        return "loading"
    return "unknown"


def active_protection_state() -> str:
    status_path = status_file_path()
    if status_path is None:
        return unknown_active_state()

    try:
        record = json.loads(
            status_path.read_text(encoding="utf-8"),
            object_pairs_hook=unique_json_object,
        )
    except (OSError, RecursionError, ValueError):
        return unknown_active_state()
    if not valid_status_record(record):
        return unknown_active_state()

    result = run_command(
        ["systemctl", "--user", "show", "--property=MainPID", "--value", UNIT]
    )
    main_pid_text = result.stdout.strip()
    if not main_pid_text.isascii() or not main_pid_text.isdigit():
        return unknown_active_state()
    try:
        main_pid = int(main_pid_text)
    except ValueError:
        return unknown_active_state()
    if main_pid != record["pid"]:
        return unknown_active_state()
    if record["state"] == "unknown":
        return unknown_active_state()
    return record["state"]


def status_unit() -> tuple[str, str]:
    state = unit_state()
    if state == "active":
        return state, active_protection_state()
    return state, "unknown"


def start_unit() -> tuple[str, str]:
    current_state = unit_state()
    if current_state == "active":
        return current_state, active_protection_state()

    status_path = status_file_path()
    if status_path is None:
        raise ControlError("XDG_RUNTIME_DIR must be set to an absolute path before starting the bridge")

    if current_state == "failed":
        run_command(["systemctl", "--user", "reset-failed", UNIT])
    run_command(
        [
            "systemd-run",
            "--user",
            "--quiet",
            "--collect",
            f"--unit={UNIT}",
            "--description=Noctalia Niri Media Idle Bridge",
            "--property=PartOf=graphical-session.target",
            "--property=After=niri.service",
            "--property=Restart=on-failure",
            "--property=RestartSec=3s",
            f"--property=RuntimeDirectory={RUNTIME_DIRECTORY}",
            "--property=RuntimeDirectoryMode=0700",
            sys.executable,
            str(BRIDGE),
            "--config",
            str(RULES),
            "--status-file",
            str(status_path),
        ]
    )
    if unit_state() != "active":
        raise ControlError("systemd-run succeeded, but the transient unit did not become active")
    return "active", active_protection_state()


def stop_unit() -> tuple[str, str]:
    current_state = unit_state()
    if current_state != "active":
        return current_state, "unknown"

    run_command(["systemctl", "--user", "stop", UNIT])
    final_state = unit_state()
    if final_state == "active":
        raise ControlError("systemctl stop succeeded, but the transient unit is still active")
    return final_state, "unknown"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("status", "start", "stop"))
    args = parser.parse_args(argv)

    try:
        result = {
            "status": status_unit,
            "start": start_unit,
            "stop": stop_unit,
        }[args.action]()
    except ControlError as err:
        print(str(err), file=sys.stderr)
        return 1

    print(*result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
