"""Read-only, best-effort explanations for failed forwarding connections."""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import TypedDict

from .model import Profile


class Conflict(TypedDict):
    port: int
    processes: list[str]


class Issue(TypedDict):
    kind: str
    conflicts: list[Conflict]


def conflicts(ports: set[int], proc: Path = Path("/proc")) -> list[Conflict]:
    """Identify listeners affecting IPv4 loopback; never expose process arguments."""
    sockets: dict[str, int] = {}
    for table in ("tcp", "tcp6"):
        try:
            rows = (proc / "net" / table).read_text().splitlines()[1:]
        except OSError:
            continue
        for row in rows:
            fields = row.split()
            if len(fields) < 10 or fields[3] != "0A":
                continue
            address, value = fields[1].split(":")
            local_port = int(value, 16)
            # Wildcard IPv6 may be dual-stack; an attempted bind remains authoritative.
            if local_port in ports and address in (
                "0100007F" if sys.byteorder == "little" else "7F000001",
                "00000000",
                "0" * 32,
                "0000000000000000FFFF00000100007F"
                if sys.byteorder == "little"
                else "00000000000000000000FFFF7F000001",
            ):
                sockets[f"socket:[{fields[9]}]"] = local_port
    owners: dict[int, set[str]] = {value: set() for value in sockets.values()}
    if not sockets:
        return []
    try:
        processes = list(proc.iterdir())
    except OSError:
        processes = []
    for process in processes:
        if not process.name.isdigit():
            continue
        try:
            name = process.joinpath("comm").read_text().strip()
            for descriptor in process.joinpath("fd").iterdir():
                try:
                    local_port = sockets.get(str(descriptor.readlink()))
                    if local_port is not None and name:
                        owners[local_port].add(name)
                except OSError:
                    continue  # Processes and descriptors can disappear during inspection.
        except OSError:
            continue  # A listener can belong to another user or a hidden process.
    return [
        Conflict(port=value, processes=sorted(names)) for value, names in sorted(owners.items())
    ]


def describe(profile: Profile, message: str) -> Issue:
    text = message.lower()
    if any(part in text for part in ("address already in use", "cannot listen", "port conflict")):
        occupied = conflicts({mapping["local_port"] for mapping in profile["mappings"]})
        if not occupied:
            match = re.search(r"local port (\d+)", text)
            if match:
                occupied = [Conflict(port=int(match[1]), processes=[])]
        return Issue(kind="port_conflict", conflicts=occupied)
    if any(
        part in text for part in ("permission denied", "authentication failed", "signing failed")
    ):
        return Issue(kind="authentication", conflicts=[])
    if "host-key" in text or "host key" in text or "identification has changed" in text:
        return Issue(kind="host_key", conflicts=[])
    return Issue(kind="connection", conflicts=[])
