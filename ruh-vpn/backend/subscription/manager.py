"""Fetch subscription URLs, parse, import into VpnService."""

from __future__ import annotations

import asyncio
import time
from typing import TYPE_CHECKING, Optional

import aiohttp

from backend.models.server import parse_server, server_to_dict
from backend.storage.subscriptions import load_subscriptions, save_subscriptions
from backend.subscription.parsers import parse_share_link, parse_subscription_body

if TYPE_CHECKING:
    from backend.service.vpn_service import VpnService

AUTO_UPDATE_INTERVAL_SEC = 24 * 3600
FETCH_TIMEOUT_SEC = 30
USER_AGENT = "ruh-vpn/0.1 (subscription-fetcher)"


class SubscriptionManager:
    def __init__(self, service: "VpnService") -> None:
        self._svc = service
        self._task: Optional[asyncio.Task] = None
        self._subs: list[dict] = []

    async def bootstrap(self) -> None:
        self._subs = await load_subscriptions()

    def start_auto_update(self) -> None:
        if self._task and not self._task.done():
            return
        self._task = asyncio.create_task(self._auto_loop())

    async def stop(self) -> None:
        if self._task is None:
            return
        self._task.cancel()
        try:
            await self._task
        except asyncio.CancelledError:
            pass
        self._task = None

    async def list_subs(self) -> list[dict]:
        return [dict(s) for s in self._subs]

    async def add(self, url: str, name: str = "") -> bool:
        url = url.strip()
        if not url:
            return False
        if any(s["url"] == url for s in self._subs):
            return False
        entry = {
            "url": url,
            "name": name or url,
            "last_updated": 0,
            "server_count": 0,
        }
        self._subs.append(entry)
        await save_subscriptions(self._subs)
        return True

    async def remove(self, url: str) -> bool:
        before = len(self._subs)
        self._subs = [s for s in self._subs if s["url"] != url]
        if len(self._subs) == before:
            return False
        await save_subscriptions(self._subs)
        return True

    async def update(self, url: str) -> int:
        """Fetch a single subscription URL and import its servers. Returns count."""
        for s in self._subs:
            if s["url"] == url:
                return await self._fetch_and_import(s)
        return 0

    async def update_all(self) -> int:
        total = 0
        for s in list(self._subs):
            total += await self._fetch_and_import(s)
        return total

    async def _fetch_and_import(self, sub: dict) -> int:
        try:
            body = await self._fetch(sub["url"])
        except Exception as exc:
            self._svc._log("error", f"subscription fetch failed for {sub['url']}: {exc}")
            return 0
        links = parse_subscription_body(body)
        imported = 0
        existing_keys = {self._server_key(s) for s in self._svc.state.servers}
        for link in links:
            entry = parse_share_link(link)
            if not entry:
                continue
            try:
                server = parse_server(entry)
            except Exception:
                continue
            key = self._server_key(server)
            if key in existing_keys:
                # update existing entry's fields by replacing with new id
                existing = next(
                    (s for s in self._svc.state.servers if self._server_key(s) == key), None
                )
                if existing:
                    entry["id"] = existing.id
                    await self._svc.update_server(entry)
                    continue
            await self._svc.add_server(entry)
            existing_keys.add(key)
            imported += 1
        sub["last_updated"] = int(time.time())
        sub["server_count"] = len(links)
        await save_subscriptions(self._subs)
        return imported

    @staticmethod
    def _server_key(server) -> tuple:
        if isinstance(server, dict):
            proto = server.get("protocol", "")
            addr = server.get("address") or server.get("host") or ""
            port = server.get("port")
            secret = server.get("uuid") or server.get("password") or ""
            return (proto, addr, port, secret)
        proto = getattr(server, "protocol", "")
        addr = getattr(server, "address", None) or getattr(server, "host", None) or ""
        port = getattr(server, "port", None)
        secret = (
            getattr(server, "uuid", None)
            or getattr(server, "password", None)
            or ""
        )
        return (proto, addr, port, secret)

    async def _fetch(self, url: str) -> str:
        timeout = aiohttp.ClientTimeout(total=FETCH_TIMEOUT_SEC)
        headers = {"User-Agent": USER_AGENT}
        async with aiohttp.ClientSession(timeout=timeout, headers=headers) as session:
            async with session.get(url) as resp:
                resp.raise_for_status()
                return await resp.text(errors="replace")

    async def _auto_loop(self) -> None:
        try:
            while True:
                await asyncio.sleep(AUTO_UPDATE_INTERVAL_SEC)
                try:
                    await self.update_all()
                except Exception as exc:
                    self._svc._log("error", f"auto-update failed: {exc}")
        except asyncio.CancelledError:
            return
