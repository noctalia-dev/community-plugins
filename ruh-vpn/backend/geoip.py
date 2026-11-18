"""Resolve a server's country code, so the UI can show a flag.

Nothing else in the backend knows a server's country: the models simply accept
the extra key. The lookup is best-effort and always optional — a server with no
country just shows no flag, exactly as before.

Privacy: this asks a third party (api.country.is) "which country is this IP in",
which discloses the address of the user's own VPN server to that service. Hence
the `geoip_country` plugin setting, which service.luau forwards as
RUH_VPN_GEOIP so it can be turned off. The endpoint is HTTPS and returns
only {"ip": ..., "country": ...}; an offline answer isn't possible here — no
GeoIP database is installed (no *.mmdb) and sing-box's .srs rulesets only cover
specific countries (cn/ir).
"""

from __future__ import annotations

import asyncio
import ipaddress
import os
import re

# Forwarded by service.luau from the geoip_country setting.
ENABLED = os.environ.get("RUH_VPN_GEOIP", "1").lower() not in ("0", "false", "no")

try:
    import aiohttp
except ImportError:  # pragma: no cover - matches monitoring/health.py's guard
    aiohttp = None  # type: ignore

LOOKUP_URL = "https://api.country.is/{ip}"
TIMEOUT_SEC = 6

_CC_RE = re.compile(r"^[A-Za-z]{2}$")


async def _resolve_ip(host: str) -> str | None:
    """Return `host` if it is already an IP, else its first A/AAAA record."""
    try:
        ipaddress.ip_address(host)
        return host
    except ValueError:
        pass
    try:
        loop = asyncio.get_running_loop()
        infos = await asyncio.wait_for(
            loop.getaddrinfo(host, None), timeout=TIMEOUT_SEC
        )
    except (OSError, asyncio.TimeoutError):
        return None
    return infos[0][4][0] if infos else None


async def lookup_country(host: str) -> str | None:
    """Best-effort ISO-3166 alpha-2 (lowercase) for `host`. None on any failure.

    Never raises: a missing flag must not be able to fail an AddServer.
    """
    if not host or aiohttp is None:
        return None
    ip = await _resolve_ip(host.strip())
    if not ip:
        return None
    # A private address has no country, and asking would leak nothing useful.
    try:
        if not ipaddress.ip_address(ip).is_global:
            return None
    except ValueError:
        return None
    try:
        timeout = aiohttp.ClientTimeout(total=TIMEOUT_SEC)
        async with aiohttp.ClientSession(timeout=timeout) as session:
            async with session.get(LOOKUP_URL.format(ip=ip)) as resp:
                if resp.status != 200:
                    return None
                data = await resp.json(content_type=None)
    except Exception:
        return None
    cc = (data or {}).get("country") if isinstance(data, dict) else None
    if isinstance(cc, str) and _CC_RE.match(cc):
        return cc.lower()
    return None
