from __future__ import annotations

import json
import os

import aiofiles

from backend.models.server import RoutingRule, Server, parse_server, server_to_dict
from backend.paths import DATA_DIR, ensure_private_dir, protect_file

SERVERS_FILE = DATA_DIR / "servers.json"
RULES_FILE = DATA_DIR / "rules.json"


def ensure_dirs() -> None:
    ensure_private_dir(DATA_DIR)


async def load_servers() -> list[Server]:
    ensure_dirs()
    if not SERVERS_FILE.exists():
        return []
    try:
        async with aiofiles.open(SERVERS_FILE, "r") as f:
            raw = await f.read()
        data = json.loads(raw or "[]")
    except (json.JSONDecodeError, ValueError):
        return []
    servers: list[Server] = []
    for entry in data:
        try:
            servers.append(parse_server(entry))
        except (ValueError, KeyError):
            continue
    return servers


async def save_servers(servers: list) -> None:
    ensure_dirs()
    data = [server_to_dict(s) for s in servers]
    tmp = SERVERS_FILE.with_suffix(".json.tmp")
    async with aiofiles.open(tmp, "w") as f:
        await f.write(json.dumps(data, indent=2))
    protect_file(tmp)
    os.replace(tmp, SERVERS_FILE)


async def load_rules() -> list[RoutingRule]:
    ensure_dirs()
    if not RULES_FILE.exists():
        return []
    try:
        async with aiofiles.open(RULES_FILE, "r") as f:
            raw = await f.read()
        data = json.loads(raw or "[]")
    except (json.JSONDecodeError, ValueError):
        return []
    rules: list[RoutingRule] = []
    for entry in data:
        try:
            rules.append(RoutingRule.model_validate(entry))
        except ValueError:
            continue
    return rules


async def save_rules(rules: list[RoutingRule]) -> None:
    ensure_dirs()
    data = [r.model_dump(exclude_none=True) for r in rules]
    tmp = RULES_FILE.with_suffix(".json.tmp")
    async with aiofiles.open(tmp, "w") as f:
        await f.write(json.dumps(data, indent=2))
    protect_file(tmp)
    os.replace(tmp, RULES_FILE)
