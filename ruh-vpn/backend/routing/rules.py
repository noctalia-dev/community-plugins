"""Helpers for translating user routing rules into sing-box rule entries."""

from __future__ import annotations

import ipaddress
import re
from typing import Any

from backend.models.server import RoutingRule


# Country / region routing presets. Each one adds a pair of rule_set entries
# (domains + IPs) and a single route rule that sends matches to the proxy.
# Tags must be unique across active presets so sing-box doesn't reject the
# config — the keys below were picked to avoid collisions.
PRESETS: dict[str, dict[str, Any]] = {
    "ru": {
        "key": "ru",
        "name": "Russia",
        "flag": "🇷🇺",
        "description": "Re-filter list — sites and IPs blocked in Russia",
        "rule_sets": [
            {
                "tag": "refilter_domains",
                "type": "remote",
                "format": "binary",
                "url": "https://github.com/1andrevich/Re-filter-lists/releases/latest/download/ruleset-domain-refilter_domains.srs",
                "download_detour": "direct",
            },
            {
                "tag": "refilter_ipsum",
                "type": "remote",
                "format": "binary",
                "url": "https://github.com/1andrevich/Re-filter-lists/releases/latest/download/ruleset-ip-refilter_ipsum.srs",
                "download_detour": "direct",
            },
        ],
    },
    # There is no "blocked in China" list: the GFW blocks foreign services, so
    # the standard bypass is the inverse — proxy everything geolocated OUTSIDE
    # China and let domestic traffic go direct. sing-geosite publishes its .srs
    # files on the `rule-set` branch, not as release assets.
    "cn": {
        "key": "cn",
        "name": "China",
        "flag": "🇨🇳",
        "description": "GFW bypass — foreign (non-Chinese) sites via VPN",
        "rule_sets": [
            {
                "tag": "geosite_noncn",
                "type": "remote",
                "format": "binary",
                "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-!cn.srs",
                "download_detour": "direct",
            },
        ],
    },
    # geosite-sanctioned covers sites unavailable from Iran (state blocks and
    # foreign sanctions). geosite-ir would be the opposite — Iranian domestic
    # sites, which need no proxy. Same .srs-on-branch layout as sing-geosite.
    "ir": {
        "key": "ir",
        "name": "Iran",
        "flag": "🇮🇷",
        "description": "Sites unavailable from Iran (blocks and sanctions) via VPN",
        "rule_sets": [
            {
                "tag": "geosite_sanctioned",
                "type": "remote",
                "format": "binary",
                "url": "https://raw.githubusercontent.com/Chocolate4U/Iran-sing-box-rules/rule-set/geosite-sanctioned.srs",
                "download_detour": "direct",
            },
        ],
    },
}


def preset_rule_sets(active: list[str]) -> list[dict]:
    """Return rule_set entries for the given active preset keys, deduped by tag."""
    seen: set[str] = set()
    out: list[dict] = []
    for key in active:
        preset = PRESETS.get(key)
        if not preset:
            continue
        for rs in preset["rule_sets"]:
            if rs["tag"] in seen:
                continue
            seen.add(rs["tag"])
            out.append(dict(rs))
    return out


def preset_route_rules(active: list[str]) -> list[dict]:
    """One route.rules entry per active preset routing its tags to 'proxy'."""
    out: list[dict] = []
    for key in active:
        preset = PRESETS.get(key)
        if not preset:
            continue
        tags = [rs["tag"] for rs in preset["rule_sets"]]
        if tags:
            out.append({"rule_set": tags, "outbound": "proxy"})
    return out


def preset_domain_tags(active: list[str]) -> list[str]:
    """Tags of rule_sets that match domains (used for proxy-DNS rule).

    Heuristic: any tag containing 'domain' or 'site' is treated as domain-only.
    IPs don't help the DNS layer, so we skip them here.
    """
    tags: list[str] = []
    for key in active:
        preset = PRESETS.get(key)
        if not preset:
            continue
        for rs in preset["rule_sets"]:
            t = rs["tag"]
            tl = t.lower()
            if "domain" in tl or "site" in tl:
                tags.append(t)
    return tags

# A hostname label: 1–63 chars, alphanumerics + hyphens (not at edges).
# `*` is allowed as the leftmost label so wildcards like *.example.com work.
_LABEL_RE = re.compile(r"^(?:\*|[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)$")


def normalize_pattern(pattern: str) -> str:
    """Clean a user-supplied pattern.

    - Strips http:// and https:// prefixes (extracts hostname).
    - Strips any path / query / fragment from a URL-like input.
    - Strips trailing slashes and surrounding whitespace.
    Domain and CIDR forms pass through unchanged (case-folded for domains).
    """
    p = (pattern or "").strip()
    if not p:
        return ""
    low = p.lower()
    if low.startswith("http://"):
        p = p[len("http://"):]
    elif low.startswith("https://"):
        p = p[len("https://"):]
    # Cut anything after the host: path, query, fragment.
    for sep in ("/", "?", "#"):
        # Don't cut the slash in CIDRs (digits on the right of '/').
        if sep == "/" and "/" in p:
            host, _, tail = p.partition("/")
            if tail and tail[0].isdigit() and host and (host[0].isdigit() or ":" in host):
                # Looks like a CIDR — keep as-is.
                continue
            p = host
        elif sep in p:
            p = p.split(sep, 1)[0]
    # Strip credentials and port (e.g. user:pass@host:443).
    if "@" in p:
        p = p.split("@", 1)[1]
    # Port: only strip when it's not part of an IPv6 literal.
    if p.count(":") == 1 and not p.startswith("["):
        p = p.split(":", 1)[0]
    return p.rstrip(".").lower()


def validate_pattern(pattern: str) -> str:
    """Validate and return the normalized pattern.

    Raises ValueError when the pattern is not a recognized
    domain / wildcard domain / CIDR form.
    """
    p = normalize_pattern(pattern)
    if not p:
        raise ValueError("pattern is empty")

    # CIDR
    if "/" in p and not p.startswith("*"):
        try:
            ipaddress.ip_network(p, strict=False)
        except ValueError as exc:
            raise ValueError(f"invalid CIDR: {p!r} ({exc})") from exc
        return p

    # Bare IP without prefix is not allowed here (CIDR only)
    try:
        ipaddress.ip_address(p)
        raise ValueError(f"{p!r} is a bare IP; use CIDR (e.g. {p}/32)")
    except ValueError:
        pass

    # Wildcard or domain
    labels = p.split(".")
    if not labels or any(not _LABEL_RE.match(label) for label in labels):
        raise ValueError(f"invalid domain pattern: {p!r}")
    # `*` may only appear as the leftmost label.
    if any(label == "*" for label in labels[1:]):
        raise ValueError(f"wildcard '*' only allowed as leftmost label: {p!r}")
    return p


def classify_pattern(pattern: str) -> str:
    """Return one of: 'cidr', 'wildcard', 'keyword', 'domain'."""
    p = pattern.strip()
    if not p:
        return "domain"
    if "/" in p and not p.startswith("*"):
        return "cidr"
    if p.startswith("*."):
        return "wildcard"
    if p.startswith("*") or p.endswith("*"):
        return "keyword"
    return "domain"


def rules_to_singbox(rules: list[RoutingRule]) -> list[dict]:
    """Convert a list of user rules into sing-box route.rules entries.

    Skips disabled rules and rules with no pattern.
    Result preserves input order (first match wins in sing-box).
    """
    out: list[dict] = []
    for r in rules:
        sr = r.to_singbox_rule()
        if sr is not None:
            out.append(sr)
    return out
