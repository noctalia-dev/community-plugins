"""General-purpose port forwarding controls; no desktop dependency."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
from typing import Any

from .model import RUNTIME, Profile, load, save, transaction, valid_id, validate
from .supervisor import connect, control, resolve, running, state_file, status
from .tools import executable


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(
        description="Named, loopback-only SSH forwards supervised by systemd."
    )
    sub = root.add_subparsers(dest="action", required=True)
    sub.add_parser("doctor", help="Check runtime prerequisites and optional desktop tools")
    sub.add_parser("uninstall", help="Stop forwards and remove the backend; retains saved profiles")
    for action in ("list", "status"):
        sub.add_parser(action, help="Print profiles and connection status as JSON")
    sub.add_parser("resolve", help="Preview settings resolved by OpenSSH").add_argument("host")
    for action in ("connect", "disconnect", "delete", "logs", "_run"):
        sub.add_parser(action).add_argument("id", type=valid_id)
    for action in ("add", "edit"):
        entry = sub.add_parser(action)
        entry.add_argument("id", type=valid_id)
        entry.add_argument("--name")
        entry.add_argument("--host")
        entry.add_argument("--map", action="append", dest="mappings", metavar="LOCAL:HOST:REMOTE")
        entry.add_argument("--scheme", choices=("http", "https"), default="http")
    sub.add_parser("put", help="Create or replace a complete profile from JSON").add_argument(
        "profile"
    )
    for action in ("address", "open", "copy"):
        entry = sub.add_parser(action)
        entry.add_argument("id", type=valid_id)
        entry.add_argument("port", type=int, help="Configured local port")
    return root


def parse_mapping(value: str, scheme: str) -> dict[str, Any]:
    match = re.fullmatch(r"(\d+):(\[[^\]]+\]|[^:]+):(\d+)", value)
    if not match:
        raise ValueError("Use LOCAL:HOST:REMOTE, e.g. 3000:localhost:3000 or 8080:[::1]:80.")
    local, host, remote = match.groups()
    return {
        "local_port": int(local),
        "remote_host": host,
        "remote_port": int(remote),
        "scheme": scheme,
    }


def put(profiles: dict[str, Profile], profile: Profile) -> None:
    profile_id = profile["id"]
    if profile_id not in profiles and len(profiles) >= 64:
        raise ValueError("At most 64 profiles are supported.")
    was_running = profile_id in profiles and running(profile_id)
    if was_running:
        control("stop", profile_id)
    profiles[profile_id] = profile
    save(profiles)
    state_file(profile_id).unlink(missing_ok=True)
    if was_running:
        connect(profile)


def execute(args: argparse.Namespace) -> object:
    action = args.action
    if action == "doctor":
        from .tools import doctor

        report = doctor()
        print(json.dumps(report))
        return 0 if report["ok"] else 1
    if action == "uninstall":
        from .installation import remove

        remove()
        return {"ok": True, "message": "Backend removed. Saved profiles were retained."}
    if action in ("status", "list"):
        return status(load())
    if action == "resolve":
        return resolve(args.host)
    if action == "_run":
        from .runner import run

        return run(args.id)
    if action == "logs":
        from .supervisor import unit

        result = subprocess.run(
            [executable("journalctl"), "--user", "-u", unit(args.id), "-n", "60", "--no-pager"],
            check=False,
        )
        return result.returncode
    with transaction() as profiles:
        if action == "put":
            put(profiles, validate(json.loads(args.profile)))
        elif action in ("add", "edit"):
            old = profiles.get(args.id)
            if (action == "add") == (old is not None):
                raise ValueError(
                    f"Profile {args.id} {'already exists' if old else 'does not exist'}."
                )
            raw: dict[str, Any] = (
                dict(old) if old else {"id": args.id, "name": args.id, "host": "", "mappings": []}
            )
            for key in ("name", "host"):
                if getattr(args, key) is not None:
                    raw[key] = getattr(args, key)
            if args.mappings is not None:
                raw["mappings"] = [parse_mapping(m, args.scheme) for m in args.mappings]
            put(profiles, validate(raw))
        else:
            if args.id not in profiles:
                raise ValueError(f"Unknown profile: {args.id}")
            profile = profiles[args.id]
            if action == "connect":
                connect(profile)
            elif action == "disconnect":
                control("stop", args.id)
                state_file(args.id).unlink(missing_ok=True)
            elif action == "delete":
                control("stop", args.id)
                control("reset-failed", args.id)
                del profiles[args.id]
                save(profiles)
                state_file(args.id).unlink(missing_ok=True)
                (RUNTIME / f"agent-{args.id}.env").unlink(missing_ok=True)
            else:
                mapping = next(
                    (m for m in profile["mappings"] if m["local_port"] == args.port), None
                )
                if mapping is None:
                    raise ValueError(f"Local port {args.port} is not in this profile.")
                address = f"127.0.0.1:{args.port}"
                if action == "address":
                    print(address)
                    return None
                if action == "copy":
                    subprocess.run(
                        [executable("wl-copy"), "--type", "text/plain"],
                        input=address,
                        text=True,
                        check=True,
                    )
                elif action == "open":
                    with tempfile.TemporaryFile(mode="w+") as errors:
                        result = subprocess.run(
                            [executable("xdg-open"), f"{mapping['scheme']}://{address}"],
                            stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL,
                            stderr=errors,
                            start_new_session=True,
                            timeout=15,
                            check=False,
                        )
                        if result.returncode:
                            errors.seek(0)
                            raise ValueError(errors.read().strip() or "Could not open the browser.")
    return {"ok": True}


def main() -> int:
    args = parser().parse_args()
    try:
        result = execute(args)
        if isinstance(result, int):
            return result
        if result is not None:
            print(json.dumps(result, ensure_ascii=False))
        return 0
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        return 78 if args.action == "_run" else 1


if __name__ == "__main__":
    sys.exit(main())
