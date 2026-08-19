"""Poll sing-box clash_api /connections endpoint for traffic stats."""

from __future__ import annotations

import asyncio
import time
from dataclasses import dataclass, field
from typing import Awaitable, Callable, Optional

import aiohttp


@dataclass
class TrafficStats:
    bytes_sent: int = 0
    bytes_received: int = 0
    connection_count: int = 0
    started_at: float = field(default_factory=time.time)

    def uptime(self) -> int:
        return max(0, int(time.time() - self.started_at))

    def to_dict(self) -> dict:
        return {
            "bytes_sent": int(self.bytes_sent),
            "bytes_received": int(self.bytes_received),
            "uptime_seconds": self.uptime(),
            "connection_count": int(self.connection_count),
        }


class TrafficMonitor:
    """Polls /connections every `interval` seconds and tracks running totals.

    Notes on the underlying API:
        sing-box clash_api /connections returns:
            {"downloadTotal": int, "uploadTotal": int, "connections": [...]}
        downloadTotal and uploadTotal are *since-mux-started* counters, so we
        can return them directly as bytes_received / bytes_sent.
    """

    def __init__(
        self,
        api_url: str,
        interval: float = 5.0,
        on_update: Optional[Callable[[dict], Awaitable[None]]] = None,
    ) -> None:
        self.api_url = api_url.rstrip("/")
        self.interval = interval
        self._on_update = on_update
        self.stats = TrafficStats()
        self._task: Optional[asyncio.Task] = None

    def start(self) -> None:
        self.stats = TrafficStats()
        if self._task and not self._task.done():
            return
        self._task = asyncio.create_task(self._loop())

    async def stop(self) -> None:
        if self._task is None:
            return
        self._task.cancel()
        try:
            await self._task
        except asyncio.CancelledError:
            pass
        self._task = None

    async def _poll_once(self) -> None:
        timeout = aiohttp.ClientTimeout(total=2.0)
        try:
            async with aiohttp.ClientSession(timeout=timeout) as session:
                async with session.get(f"{self.api_url}/connections") as resp:
                    if resp.status != 200:
                        return
                    data = await resp.json(content_type=None)
        except (aiohttp.ClientError, asyncio.TimeoutError, OSError):
            return
        self.stats.bytes_sent = int(data.get("uploadTotal") or 0)
        self.stats.bytes_received = int(data.get("downloadTotal") or 0)
        self.stats.connection_count = len(data.get("connections") or [])

    async def _loop(self) -> None:
        try:
            while True:
                await self._poll_once()
                if self._on_update:
                    try:
                        await self._on_update(self.stats.to_dict())
                    except Exception:
                        pass
                await asyncio.sleep(self.interval)
        except asyncio.CancelledError:
            return
