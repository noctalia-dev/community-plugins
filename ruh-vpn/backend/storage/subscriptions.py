"""Persistence for subscription metadata."""

from __future__ import annotations

import json
import os

import aiofiles

from backend.paths import DATA_DIR, ensure_private_dir, protect_file

SUBS_FILE = DATA_DIR / "subscriptions.json"


def ensure_dirs() -> None:
    ensure_private_dir(DATA_DIR)


async def load_subscriptions() -> list[dict]:
    ensure_dirs()
    if not SUBS_FILE.exists():
        return []
    try:
        async with aiofiles.open(SUBS_FILE, "r") as f:
            raw = await f.read()
        return json.loads(raw or "[]")
    except (json.JSONDecodeError, ValueError):
        return []


async def save_subscriptions(subs: list[dict]) -> None:
    ensure_dirs()
    tmp = SUBS_FILE.with_suffix(".json.tmp")
    async with aiofiles.open(tmp, "w") as f:
        await f.write(json.dumps(subs, indent=2))
    protect_file(tmp)
    os.replace(tmp, SUBS_FILE)
