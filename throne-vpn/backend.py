#!/usr/bin/env python3
"""Local, non-UI thronectl adapter for the Throne VPN Noctalia plugin.

The API key is passed by filename. This helper never reads the key, downloads
code, grants privileges, edits profiles/routes, or starts speed tests.
Implementation and documentation were produced with AI assistance; see README.
"""

import argparse
import contextlib
import fcntl
import json
import math
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import time

VERSION = "2.1.2"
MAX_ID = 2**53 - 1  # IDs must remain exact when copied into Luau numbers.
MAX_OUTPUT = 8 * 1024 * 1024


class BackendError(Exception):
    """A user-facing error, safe to show without raw thronectl output."""


def clean(value, limit=240):
    return " ".join(re.sub(r"[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]", " ", str(value)).split())[:limit]


def number(value, default=0):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return default
    try:
        return value if math.isfinite(value) and abs(value) <= 10**24 else default
    except OverflowError:
        return default


def ident(value, default=-1):
    return value if isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= MAX_ID else default


def speed_text(value):
    value = number(value)
    return "failed" if value < 0 else (f"{value / 1_000_000:.2f} Mbps" if value else "—")


def ping_text(value):
    value = number(value)
    return "unavailable" if value == -2 else ("failed" if value < 0 else (f"{value:g} ms" if value else "—"))


def traffic_text(value):
    value = max(0, number(value))
    for unit in ("B", "KiB", "MiB", "GiB", "TiB", "PiB"):
        if value < 1024 or unit == "PiB":
            return f"{value:.1f} {unit}" if unit != "B" else f"{value:.0f} B"
        value /= 1024


def normalize_status(data):
    state = data.get("state")
    if state not in ("idle", "running", "connecting", "stopping", "starting"):
        raise BackendError("Unexpected Throne status. Check compatibility with thronectl.")
    profile = data.get("profile")
    route = data.get("route")
    capabilities = data.get("capabilities")
    tun_capability = capabilities.get("tun") if isinstance(capabilities, dict) else None
    return {
        "state": state,
        "tun": data.get("tun") is True,
        "profile": {"id": ident(profile.get("id")), "name": clean(profile.get("name") or "Throne")}
        if isinstance(profile, dict) else None,
        "route": {"name": clean(route.get("name") or "Default")} if isinstance(route, dict) else None,
        "last_profile_id": ident(data.get("last_profile_id")),
        "capabilities": {"tun": tun_capability if type(tun_capability) is bool else None},
        "degraded": clean(data["degraded"]) if isinstance(data.get("degraded"), str) and data["degraded"] else None,
    }


def profile_rows(data):
    if not isinstance(data.get("profiles"), list):
        raise BackendError("Throne returned no profile list. Check compatibility with thronectl.")
    result, seen = [], set()
    for item in data["profiles"]:
        if not isinstance(item, dict):
            continue
        profile_id = ident(item.get("id"))
        if profile_id < 0 or profile_id in seen:
            continue
        seen.add(profile_id)
        row = {"id": profile_id, "name": clean(item.get("name") or "Unnamed profile"),
               "type": clean(item.get("type") or "", 40), "country": clean(item.get("country") or "—", 8)}
        for key in ("latency_ms", "latency_at", "download_bps", "upload_bps", "traffic_up", "traffic_down"):
            row[key] = number(item.get(key))
        row.update(ping=ping_text(row["latency_ms"]), download=speed_text(row["download_bps"]),
                   upload=speed_text(row["upload_bps"]), traffic_up_text=traffic_text(row["traffic_up"]),
                   traffic_down_text=traffic_text(row["traffic_down"]))
        result.append(row)

    def order(row):
        download, latency = row["download_bps"], row["latency_ms"]
        tier = 0 if download > 0 else (1 if download == 0 else 2)
        return tier, -download, -max(0, row["upload_bps"]), latency if latency > 0 else math.inf, row["id"]
    return sorted(result, key=order)


def classify_error(output):
    text = output.lower()
    if "needs_privileges" in text or "cap_net_admin" in text:
        return "ThroneCore needs TUN privileges. Grant them in Throne; see the permissions guide."
    if any(x in text for x in ("unauthorized", "unauthenticated", "invalid api key", "forbidden")):
        return "Throne rejected authentication. Check the API key file setting."
    if any(x in text for x in ("connection refused", "connect: refused", "core_down", "core_unavailable")):
        return "Throne is unavailable. Start Throne and enable its API."
    if "tun_conflict" in text:
        return "Another application holds TUN. Check Throne before retrying."
    # Never echo raw stderr: upstream tools may include paths, URLs or tokens.
    return "The Throne command failed. Check Throne and run thronectl manually for details."


class Client:
    def __init__(self, address, key_file, binary):
        if any('\0' in value for value in (address, key_file, binary)):
            raise BackendError("A plugin setting contains an invalid character.")
        try:
            expanded = os.path.expanduser(binary)
        except (ValueError, RuntimeError) as exc:
            raise BackendError("Could not resolve the thronectl executable. Check plugin settings.") from exc
        found = shutil.which(expanded)
        if not found and binary == "thronectl":
            candidate = Path.home() / ".local/bin/thronectl"
            found = str(candidate) if candidate.is_file() and os.access(candidate, os.X_OK) else None
        if not found:
            raise BackendError("thronectl was not found. Install it or set its executable path in plugin settings.")
        self.binary, self.address = found, address
        try:
            self.key = Path(key_file).expanduser()
        except (ValueError, RuntimeError) as exc:
            raise BackendError("Could not resolve the API key file. Check plugin settings.") from exc
        if not key_file or not self.key.is_file():
            raise BackendError("Set API key file in plugin settings to Throne's existing key file (not the key itself).")

    def call(self, *command, short=False):
        argv = [self.binary, "--addr", self.address, "--key-file", str(self.key),
                "--timeout", "3s" if short else "15s", "--json", *map(str, command)]
        try:
            result = subprocess.run(argv, capture_output=True, text=True, timeout=5 if short else 19)
        except subprocess.TimeoutExpired as exc:
            raise BackendError("Throne timed out. Check its window and try again.") from exc
        except (OSError, UnicodeError) as exc:
            raise BackendError("Could not run thronectl. Check its executable path and version.") from exc
        if len(result.stdout) > MAX_OUTPUT or len(result.stderr) > MAX_OUTPUT:
            raise BackendError("Throne returned an unexpectedly large response.")
        if result.returncode:
            raise BackendError(classify_error(result.stderr or result.stdout))
        try:
            data = json.loads(result.stdout)
        except (ValueError, TypeError) as exc:
            raise BackendError("thronectl returned invalid JSON. Check its version.") from exc
        if not isinstance(data, dict):
            raise BackendError("thronectl returned an unexpected response.")
        return data

    def status(self, short=False):
        return normalize_status(self.call("status", short=short))


def snapshot(client):
    status = client.status(short=True)
    profiles = profile_rows(client.call("profiles", short=True))
    return {"ok": True, "version": VERSION, "status": status, "profiles": profiles, "updated_at": int(time.time())}


def connect(client, selection):
    status = client.status()
    if status["state"] in ("connecting", "stopping", "starting"):
        raise BackendError("Throne is changing state. Wait and retry.")
    if selection == "last" and status["last_profile_id"] < 0:
        raise BackendError("There is no previous profile. Select a server from the list.")
    if not status["tun"]:
        modes = client.call("tun", "on")
        if modes.get("tun") is not True and not client.status()["tun"]:
            raise BackendError("TUN did not turn on. Check ThroneCore privileges in Throne.")
    result = client.call("connect", selection)
    status = normalize_status(result) if result.get("state") in ("running", "connecting") else client.status()
    if status["state"] not in ("running", "connecting") or not status["tun"]:
        raise BackendError("Throne did not confirm a TUN connection. Check its window and logs.")
    return {"ok": True, "status": status}


def disconnect(client):
    status = normalize_status(client.call("disconnect"))
    if status["state"] not in ("idle", "stopping"):
        raise BackendError("Throne did not confirm disconnection. Check its window.")
    return {"ok": True, "status": status}


@contextlib.contextmanager
def action_lock():
    directory = Path(os.environ.get("XDG_RUNTIME_DIR") or str(Path.home() / ".cache")) / "noctalia-throne-vpn"
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise BackendError("The private action-lock directory is unavailable.")
    directory.chmod(0o700)
    # Refuse symlinks for the lock; another user cannot replace the private directory.
    fd = os.open(directory / "action.lock", os.O_CREAT | os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "a") as lock:
        os.fchmod(lock.fileno(), 0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise BackendError("Another VPN action is still running.") from exc
        yield


def selection(value):
    if value == "last":
        return value
    if value.isascii() and value.isdigit() and len(value) <= 16 and ident(int(value)) >= 0:
        return int(value)
    raise argparse.ArgumentTypeError("expected a non-negative profile ID or last")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--addr", default="127.0.0.1:9095")
    parser.add_argument("--key-file", default="")
    parser.add_argument("--thronectl", default="thronectl")
    parser.add_argument("--version", action="version", version=VERSION)
    commands = parser.add_mutually_exclusive_group(required=True)
    commands.add_argument("--snapshot", action="store_true")
    commands.add_argument("--connect", type=selection, metavar="ID|last")
    commands.add_argument("--disconnect", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.snapshot:
            result = snapshot(Client(args.addr, args.key_file, args.thronectl))
        else:
            with action_lock():
                client = Client(args.addr, args.key_file, args.thronectl)
                result = disconnect(client) if args.disconnect else connect(client, args.connect)
        print(json.dumps(result, ensure_ascii=False, allow_nan=False))
        return 0
    except (BackendError, OSError) as exc:
        message = str(exc) if isinstance(exc, BackendError) else "A local file operation failed. Check plugin settings and permissions."
        print(json.dumps({"ok": False, "error": message}, ensure_ascii=False))
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
