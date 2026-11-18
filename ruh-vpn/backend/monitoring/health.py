"""Health monitoring: periodic TCP ping + traffic stats helpers."""

from __future__ import annotations

import asyncio
import socket
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Awaitable, Callable, Optional

try:
    import aiohttp
except ImportError:  # pragma: no cover
    aiohttp = None  # type: ignore[assignment]

try:
    from aiohttp_socks import ProxyConnector
except ImportError:  # pragma: no cover
    ProxyConnector = None  # type: ignore[assignment]

SPEED_DOWN_URL = "https://speed.cloudflare.com/__down?bytes=10000000"
SPEED_UP_URL = "https://speed.cloudflare.com/__up"
SPEED_UP_BYTES = 4_000_000
SPEED_TIMEOUT = 20.0


def _connector_for(proxy_url: Optional[str]):
    """Return an aiohttp connector. SOCKS5 proxy if given, else default."""
    if not proxy_url:
        return None
    if ProxyConnector is None:
        return None
    try:
        return ProxyConnector.from_url(proxy_url)
    except Exception:
        return None


async def tcp_ping(host: str, port: int, timeout: float = 5.0) -> Optional[int]:
    """Open a TCP connection and return latency in ms, or None on failure."""
    loop = asyncio.get_running_loop()
    start = loop.time()
    try:
        fut = asyncio.open_connection(host, port)
        _, writer = await asyncio.wait_for(fut, timeout=timeout)
        latency_ms = int((loop.time() - start) * 1000)
        writer.close()
        try:
            await writer.wait_closed()
        except (ConnectionError, OSError):
            pass
        return latency_ms
    except (OSError, asyncio.TimeoutError):
        return None


async def tcp_ping_samples(
    host: str,
    port: int,
    count: int = 4,
    timeout: float = 3.0,
    gap: float = 0.15,
) -> list[int]:
    samples: list[int] = []
    for i in range(count):
        ms = await tcp_ping(host, port, timeout=timeout)
        if ms is not None:
            samples.append(ms)
        if i < count - 1:
            await asyncio.sleep(gap)
    return samples


def compute_jitter(samples: list[int]) -> int:
    if len(samples) < 2:
        return 0
    diffs = [abs(samples[i] - samples[i - 1]) for i in range(1, len(samples))]
    return int(round(sum(diffs) / len(diffs)))


async def measure_download_mbps(
    url: str = SPEED_DOWN_URL,
    timeout: float = SPEED_TIMEOUT,
    proxy_url: Optional[str] = None,
) -> Optional[float]:
    """Fetch URL and return throughput in Mbps (megabits/second).

    If `proxy_url` is given (e.g. "socks5://127.0.0.1:11081"), traffic is
    routed through that SOCKS proxy so the measurement reflects the tunnel.
    """
    if aiohttp is None:
        return None
    timeout_cfg = aiohttp.ClientTimeout(total=timeout, sock_connect=5.0)
    loop = asyncio.get_running_loop()
    connector = _connector_for(proxy_url)
    try:
        async with aiohttp.ClientSession(
            timeout=timeout_cfg, connector=connector
        ) as session:
            async with session.get(url) as resp:
                if resp.status != 200:
                    return None
                start = loop.time()
                total = 0
                async for chunk in resp.content.iter_chunked(65536):
                    total += len(chunk)
                elapsed = max(loop.time() - start, 1e-6)
        if total <= 0:
            return None
        return round((total * 8.0) / elapsed / 1_000_000.0, 1)
    except (aiohttp.ClientError, asyncio.TimeoutError, OSError):
        return None


async def measure_upload_mbps(
    url: str = SPEED_UP_URL,
    size_bytes: int = SPEED_UP_BYTES,
    timeout: float = SPEED_TIMEOUT,
    proxy_url: Optional[str] = None,
) -> Optional[float]:
    if aiohttp is None:
        return None
    payload = b"\0" * size_bytes
    timeout_cfg = aiohttp.ClientTimeout(total=timeout, sock_connect=5.0)
    loop = asyncio.get_running_loop()
    connector = _connector_for(proxy_url)
    try:
        async with aiohttp.ClientSession(
            timeout=timeout_cfg, connector=connector
        ) as session:
            start = loop.time()
            async with session.post(url, data=payload) as resp:
                # Read body to ensure full round-trip
                await resp.read()
                if resp.status >= 400:
                    return None
            elapsed = max(loop.time() - start, 1e-6)
        return round((size_bytes * 8.0) / elapsed / 1_000_000.0, 1)
    except (aiohttp.ClientError, asyncio.TimeoutError, OSError):
        return None


async def resolve_host(host: str) -> Optional[str]:
    loop = asyncio.get_running_loop()
    try:
        info = await loop.getaddrinfo(host, None, type=socket.SOCK_STREAM)
        for _, _, _, _, sockaddr in info:
            return sockaddr[0]
    except (socket.gaierror, OSError):
        return None
    return None


def read_resolv_conf_nameservers(path: str = "/etc/resolv.conf") -> list[str]:
    out: list[str] = []
    try:
        with open(path, "r") as f:
            for line in f:
                line = line.strip()
                if line.startswith("nameserver"):
                    parts = line.split()
                    if len(parts) >= 2:
                        out.append(parts[1])
    except OSError:
        pass
    return out


def check_dns_leak(running: bool, proxy_mode: str, mode: str) -> dict:
    """Best-effort DNS leak check.

    'leaking' is True when the proxy is up but system DNS is going to a
    nameserver that won't be routed through the proxy.

    Heuristic:
      - TUN mode → all UDP/53 hits sing-box → NOT leaking (regardless of resolv.conf).
      - System+global → only HTTP/SOCKS goes through proxy; DNS to /etc/resolv.conf
        servers goes direct over the system → leaking.
      - System+rules → same as global from a DNS-leak standpoint → leaking.
      - Proxy not running → not running, "leaking" reported as N/A (false).
    """
    nameservers = read_resolv_conf_nameservers()
    if not running:
        return {"leaking": False, "dns_servers": nameservers, "reason": "proxy not running"}
    if proxy_mode == "tun":
        return {"leaking": False, "dns_servers": nameservers, "reason": "TUN intercepts all DNS"}
    leaking = any(not (ns.startswith("127.") or ns == "::1") for ns in nameservers)
    return {
        "leaking": bool(leaking),
        "dns_servers": nameservers,
        "reason": (
            "system DNS bypasses the SOCKS proxy in system-proxy mode"
            if leaking
            else "all configured nameservers are local"
        ),
    }


@dataclass
class HealthState:
    latency_ms: int = -1
    jitter_ms: int = -1
    down_mbps: float = -1.0
    up_mbps: float = -1.0
    speed_taken_at: float = 0.0  # epoch seconds; 0 = never
    last_check: float = 0.0  # epoch seconds; 0 = never
    consecutive_failures: int = 0
    status: str = "ok"  # ok | degraded | failed

    def to_dict(self) -> dict:
        if self.last_check:
            last_iso = datetime.fromtimestamp(self.last_check, tz=timezone.utc).isoformat()
        else:
            last_iso = ""
        if self.speed_taken_at:
            speed_iso = datetime.fromtimestamp(
                self.speed_taken_at, tz=timezone.utc
            ).isoformat()
        else:
            speed_iso = ""
        return {
            "latency_ms": int(self.latency_ms),
            "jitter_ms": int(self.jitter_ms),
            "down_mbps": float(self.down_mbps),
            "up_mbps": float(self.up_mbps),
            "speed_taken_at": speed_iso,
            "last_check": last_iso,
            "consecutive_failures": int(self.consecutive_failures),
            "status": self.status,
        }


class HealthMonitor:
    """Periodic TCP ping to the transport server.

    - One ping every `interval` seconds (default 30).
    - 1 failure → degraded; 3 consecutive → failed + on_failed callback fires once.
    - First successful ping after failure resets status to ok.
    """

    FAIL_THRESHOLD = 3

    def __init__(
        self,
        host: str,
        port: int,
        interval: float = 30.0,
        timeout: float = 5.0,
        on_failed: Optional[Callable[[], Awaitable[None]]] = None,
    ) -> None:
        self.host = host
        self.port = port
        self.interval = interval
        self.timeout = timeout
        self._on_failed = on_failed
        self._task: Optional[asyncio.Task] = None
        self.state = HealthState()
        self._failed_emitted = False
        self._speed_task: Optional[asyncio.Task] = None

    def start(self) -> None:
        if self._task and not self._task.done():
            return
        self._failed_emitted = False
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

    async def check_now(self) -> int:
        samples = await tcp_ping_samples(
            self.host, self.port, count=4, timeout=self.timeout, gap=0.1
        )
        self.state.last_check = time.time()
        if not samples:
            self.state.latency_ms = -1
            self.state.jitter_ms = -1
            self.state.consecutive_failures += 1
            if self.state.consecutive_failures >= self.FAIL_THRESHOLD:
                self.state.status = "failed"
                if not self._failed_emitted and self._on_failed:
                    self._failed_emitted = True
                    try:
                        await self._on_failed()
                    except Exception:
                        pass
            else:
                self.state.status = "degraded"
            return -1
        latency = int(round(sum(samples) / len(samples)))
        self.state.latency_ms = latency
        self.state.jitter_ms = compute_jitter(samples)
        self.state.consecutive_failures = 0
        self.state.status = "ok"
        self._failed_emitted = False
        return latency

    async def run_speed_test(self, proxy_url: Optional[str] = None) -> dict:
        """Measure download + upload throughput. Updates state in-place.

        When `proxy_url` is provided, traffic is routed through that proxy.
        """
        down = await measure_download_mbps(proxy_url=proxy_url)
        up = await measure_upload_mbps(proxy_url=proxy_url)
        self.state.down_mbps = down if down is not None else -1.0
        self.state.up_mbps = up if up is not None else -1.0
        self.state.speed_taken_at = time.time()
        return {
            "down_mbps": self.state.down_mbps,
            "up_mbps": self.state.up_mbps,
            "ping_ms": int(self.state.latency_ms),
            "jitter_ms": int(self.state.jitter_ms),
        }

    async def _loop(self) -> None:
        try:
            # First check immediately so GetHealth has real data quickly.
            await self.check_now()
            while True:
                await asyncio.sleep(self.interval)
                await self.check_now()
        except asyncio.CancelledError:
            return
