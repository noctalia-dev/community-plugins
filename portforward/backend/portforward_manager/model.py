"""Validated profiles and atomic, private local storage."""

from __future__ import annotations

import contextlib
import fcntl
import ipaddress
import json
import os
import re
import socket
import tempfile
from collections.abc import Generator
from pathlib import Path
from typing import TypedDict, cast


class Mapping(TypedDict):
    local_port: int
    remote_host: str
    remote_port: int
    scheme: str


class Profile(TypedDict):
    id: str
    name: str
    host: str
    mappings: list[Mapping]


CONFIG = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "portforward"
STATE = (
    Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state")))
    / "portforward-manager"
)
RUNTIME = (
    Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")) / "portforward-manager"
)
PROFILES = CONFIG / "profiles.json"


def private_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.chmod(0o700)


def atomic_json(path: Path, value: object) -> None:
    private_dir(path.parent)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".write-")
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, indent=2, ensure_ascii=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def valid_id(value: object) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,47}", value):
        raise ValueError("Profile ID must use 1–48 lowercase letters, numbers or hyphens.")
    return value


def valid_host(value: object, *, destination: bool = False) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError("An SSH destination or remote host is required.")
    host = value
    if destination and "@" in host:
        user, host = host.rsplit("@", 1)
        if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]*", user):
            raise ValueError("Invalid SSH username.")
    if len(value) > 255:
        raise ValueError("Host is too long.")
    if host.startswith("[") != host.endswith("]"):
        raise ValueError("IPv6 brackets must be balanced.")
    candidate = host.removeprefix("[").removesuffix("]")
    if ":" in candidate:
        if "%" in candidate:
            zone = candidate.split("%", 1)[1]
            if not re.fullmatch(r"[A-Za-z0-9_.-]{1,64}", zone):
                raise ValueError("Invalid IPv6 scope identifier.")
        try:
            ipaddress.IPv6Address(candidate)
        except ValueError as error:
            raise ValueError("Invalid IPv6 host.") from error
    elif not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]*", host):
        raise ValueError(
            "Use an SSH alias, hostname, IP address or user@host; no options or spaces."
        )
    return value


def port(value: object) -> int:
    if type(value) is not int or not 1 <= value <= 65535:
        raise ValueError("Ports must be integers from 1 to 65535.")
    return value


def fields(raw: object, keys: set[str], message: str) -> dict[str, object]:
    if not isinstance(raw, dict):
        raise ValueError(message)
    value = cast(dict[str, object], raw)
    if set(value) != keys:
        raise ValueError(message)
    return value


def validate(raw: object) -> Profile:
    raw = fields(
        raw,
        {"id", "name", "host", "mappings"},
        "A profile requires id, name, host and mappings only.",
    )
    name = raw["name"]
    if (
        not isinstance(name, str)
        or not name.strip()
        or len(name) > 128
        or any(ord(c) < 32 for c in name)
    ):
        raise ValueError("Profile name must contain 1–128 printable characters.")
    mappings = raw["mappings"]
    if not isinstance(mappings, list):
        raise ValueError("Add between 1 and 32 port mappings.")
    mappings = cast(list[object], mappings)
    if not 1 <= len(mappings) <= 32:
        raise ValueError("Add between 1 and 32 port mappings.")
    checked: list[Mapping] = []
    for mapping in mappings:
        mapping = fields(
            mapping,
            {
                "local_port",
                "remote_host",
                "remote_port",
                "scheme",
            },
            "Each mapping requires local_port, remote_host, remote_port and scheme.",
        )
        scheme = mapping["scheme"]
        if not isinstance(scheme, str) or scheme not in ("http", "https"):
            raise ValueError("Browser scheme must be http or https.")
        checked.append(
            Mapping(
                local_port=port(mapping["local_port"]),
                remote_host=valid_host(mapping["remote_host"]),
                remote_port=port(mapping["remote_port"]),
                scheme=scheme,
            )
        )
    if len({m["local_port"] for m in checked}) != len(checked):
        raise ValueError("Local ports must be unique within a profile.")
    return Profile(
        id=valid_id(raw["id"]),
        name=name.strip(),
        host=valid_host(raw["host"], destination=True),
        mappings=checked,
    )


def load() -> dict[str, Profile]:
    if not PROFILES.exists():
        return {}
    raw = fields(
        json.loads(PROFILES.read_text()),
        {"version", "profiles"},
        f"Invalid profile file: {PROFILES}. Expected version 1.",
    )
    if raw["version"] != 1:
        raise ValueError(f"Invalid profile file: {PROFILES}. Expected version 1.")
    entries = raw["profiles"]
    if not isinstance(entries, list):
        raise ValueError("Profile file must contain an array of at most 64 profiles.")
    entries = cast(list[object], entries)
    if len(entries) > 64:
        raise ValueError("Profile file must contain an array of at most 64 profiles.")
    profiles = [validate(p) for p in entries]
    if len({p["id"] for p in profiles}) != len(profiles):
        raise ValueError("Duplicate profile IDs in profile file.")
    return {p["id"]: p for p in profiles}


def save(profiles: dict[str, Profile]) -> None:
    atomic_json(PROFILES, {"version": 1, "profiles": list(profiles.values())})


@contextlib.contextmanager
def transaction() -> Generator[dict[str, Profile]]:
    private_dir(CONFIG)
    with (CONFIG / ".lock").open("a") as lock:
        os.fchmod(lock.fileno(), 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield load()


def check_ports(profile: Profile) -> None:
    """Preflight every requested listener; SSH remains authoritative for races."""
    with contextlib.ExitStack() as stack:
        for mapping in profile["mappings"]:
            listener = stack.enter_context(socket.socket())
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            local_port = mapping["local_port"]
            try:
                listener.bind(("127.0.0.1", local_port))
                listener.listen(1)
            except OSError as error:
                raise ValueError(
                    f"Cannot listen on local port {local_port}: {error.strerror}. "
                    "Stop its owner or edit this mapping; the port will not be changed."
                ) from error


def forward_spec(mapping: Mapping) -> str:
    host = mapping["remote_host"]
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    return f"127.0.0.1:{mapping['local_port']}:{host}:{mapping['remote_port']}"
