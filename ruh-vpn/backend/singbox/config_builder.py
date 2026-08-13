"""Build sing-box JSON configs for transport / rules-mux / global-mux / TUN.

Each helper returns a dict that can be JSON-dumped straight into the matching
the plugin data directory as <PREFIX>-{transport,rules,global,tun}.json.

Architecture (as proven by reference noctalia-rules.json / noctalia-global.json):

  Transport layer   → port 11080  (talks to remote VPN server)
  Rules mux         → port 11081  (refilter rules → proxy, rest → direct)
  Global mux        → port 11082  (everything → proxy)
  TUN               → tun device; outbound = socks5 → 11081 or 11082

The TUN config never talks to the remote server directly — it always hops
through one of the mux ports so we never create a routing loop.
"""

from __future__ import annotations

from typing import Any

from backend.models.server import RoutingRule, Server, SSHServer
from backend.routing.rules import (
    preset_domain_tags,
    preset_route_rules,
    preset_rule_sets,
)
from backend.identity import PREFIX
from backend.paths import SINGBOX_DIR
from backend.singbox.transport import build_outbound

CONFIG_DIR = SINGBOX_DIR
RULESET_CACHE_DIR = CONFIG_DIR  # sing-box stores ruleset cache here
RULES_DB = CONFIG_DIR / f"{PREFIX}-rules.db"

DEFAULT_LOG = {"level": "info", "timestamp": True}

PROXY_DNS_ADDR = "8.8.8.8"
DIRECT_DNS_ADDR = "223.5.5.5"
TUN_DNS_SERVER_NAME = "dns.google"


def _dns_rules_from_user(rules: list) -> list[dict]:
    """Translate user routing rules into DNS rules with matching server tags.

    For each enabled rule:
      - extract matcher (domain / domain_suffix / domain_keyword / ip_cidr)
      - force-proxy → server: proxy-dns
      - direct      → server: direct-dns
      - block       → action: reject (no DNS lookup at all)
    """
    out: list[dict] = []
    for r in rules:
        sr = r.to_singbox_rule() if hasattr(r, "to_singbox_rule") else None
        if not sr:
            continue
        dns_rule: dict = {}
        for k in ("domain", "domain_suffix", "domain_keyword", "ip_cidr"):
            if k in sr:
                dns_rule[k] = sr[k]
        if not dns_rule:
            continue
        if sr.get("action") == "reject":
            dns_rule["action"] = "reject"
        elif sr.get("outbound") == "proxy":
            dns_rule["server"] = "proxy-dns"
        else:
            dns_rule["server"] = "direct-dns"
        out.append(dns_rule)
    return out


def _build_dns_rules(
    custom_rules: list,
    active_presets: list[str],
    default_proxy: bool,
) -> dict:
    """Return the dns section for a mux config.

    default_proxy=True → unmatched DNS goes through proxy (global mode).
    default_proxy=False → unmatched DNS goes direct (rules mode).

    For each active preset, domain-style rule_sets are routed via proxy-dns
    so DNS resolution for blocked sites doesn't leak to the direct resolver.
    """
    servers = [
        {
            "type": "udp",
            "tag": "proxy-dns",
            "server": PROXY_DNS_ADDR,
            "server_port": 53,
            "detour": "proxy",
        },
        {
            "type": "udp",
            "tag": "direct-dns",
            "server": DIRECT_DNS_ADDR,
            "server_port": 53,
        },
    ]
    rules = _dns_rules_from_user(custom_rules)
    if not default_proxy:
        dom_tags = preset_domain_tags(active_presets or [])
        if dom_tags:
            rules.append({"rule_set": dom_tags, "server": "proxy-dns"})
    return {
        "servers": servers,
        "rules": rules,
        "final": "proxy-dns" if default_proxy else "direct-dns",
        "strategy": "ipv4_only",
    }


def build_transport_config(server: Server, listen_port: int = 11080) -> dict[str, Any]:
    """Build sing-box config for the transport layer.

    Listens on 127.0.0.1:listen_port (SOCKS5) and forwards through the
    server-specific outbound.

    For SSH, this returns None — SSH is handled outside sing-box.
    """
    if isinstance(server, SSHServer):
        raise ValueError(
            "SSH is handled directly by OpenSSH; do not build a sing-box transport config"
        )
    outbound = build_outbound(server, tag="proxy")
    return {
        "log": DEFAULT_LOG,
        "inbounds": [
            {
                "type": "socks",
                "tag": "in",
                "listen": "127.0.0.1",
                "listen_port": listen_port,
                "users": [],
            }
        ],
        "outbounds": [
            outbound,
            {"type": "direct", "tag": "direct"},
        ],
        "route": {"final": "proxy", "auto_detect_interface": True},
    }


def build_rules_config(
    transport_port: int = 11080,
    listen_port: int = 11081,
    custom_rules: list[RoutingRule] | None = None,
    active_presets: list[str] | None = None,
    clash_api_port: int = 11089,
) -> dict[str, Any]:
    """Build the rules-mux config.

    Listens on 127.0.0.1:listen_port (mixed inbound — accepts both SOCKS5 and
    HTTP), routes traffic per rules to either the upstream proxy (the transport
    listening on `transport_port`) or direct.

    `active_presets` is a list of preset keys (e.g. ["ru"]). Each preset
    contributes its rule_set definitions and one route.rules entry that sends
    matches to the 'proxy' outbound. User custom_rules are placed first so they
    take precedence over preset rules (sing-box matches top-to-bottom).
    """
    rules: list[dict[str, Any]] = []
    custom_rules = custom_rules or []
    active_presets = list(active_presets or [])

    for r in custom_rules:
        if not r.enabled:
            continue
        sr = r.to_singbox_rule()
        if sr is not None:
            rules.append(sr)

    rules.extend(preset_route_rules(active_presets))

    rule_set = preset_rule_sets(active_presets)

    route: dict[str, Any] = {
        "final": "direct",
        "auto_detect_interface": True,
        "default_domain_resolver": "direct-dns",
        "rules": rules,
    }
    if rule_set:
        route["rule_set"] = rule_set

    return {
        "log": DEFAULT_LOG,
        "dns": _build_dns_rules(custom_rules, active_presets, default_proxy=False),
        "experimental": {
            "cache_file": {"enabled": True, "path": str(RULES_DB)},
            "clash_api": {"external_controller": f"127.0.0.1:{clash_api_port}"},
        },
        "inbounds": [
            {
                "type": "mixed",
                "tag": "in",
                "listen": "127.0.0.1",
                "listen_port": listen_port,
            }
        ],
        "outbounds": [
            {"type": "direct", "tag": "direct"},
            {
                "type": "socks",
                "tag": "proxy",
                "server": "127.0.0.1",
                "server_port": transport_port,
                "version": "5",
            },
        ],
        "route": route,
    }


def build_global_config(
    transport_port: int = 11080,
    listen_port: int = 11082,
    clash_api_port: int | None = 11089,
) -> dict[str, Any]:
    """Build the global-mux config: everything → proxy."""
    experimental: dict[str, Any] = {}
    if clash_api_port is not None:
        experimental["clash_api"] = {"external_controller": f"127.0.0.1:{clash_api_port}"}
    return {
        "log": DEFAULT_LOG,
        "dns": _build_dns_rules([], active_presets=[], default_proxy=True),
        **({"experimental": experimental} if experimental else {}),
        "inbounds": [
            {
                "type": "mixed",
                "tag": "in",
                "listen": "127.0.0.1",
                "listen_port": listen_port,
            }
        ],
        "outbounds": [
            {
                "type": "socks",
                "tag": "proxy",
                "server": "127.0.0.1",
                "server_port": transport_port,
                "version": "5",
            },
            {"type": "direct", "tag": "direct"},
        ],
        "route": {
            "final": "proxy",
            "auto_detect_interface": True,
            "default_domain_resolver": "proxy-dns",
        },
    }


def build_tun_config(
    upstream_socks_port: int,
    interface_name: str = "noctalia-tun0",
    inet4_address: str = "172.19.0.1/30",
    route_exclude_addresses: list[str] | None = None,
) -> dict[str, Any]:
    """Build the TUN config.

    The TUN outbound is a SOCKS5 client to 127.0.0.1:upstream_socks_port
    (either the rules mux on 11081 or the global mux on 11082). Private/LAN
    traffic goes direct so we don't black-hole local services.

    sing-box exposes the second address of the TUN subnet (172.19.0.2 by
    default) to systemd-resolved.  DNS must therefore be hijacked before the
    private-address rule, otherwise queries are sent direct to that synthetic
    address and immediately re-enter the TUN in a tight loop.  DoH is used so
    SSH SOCKS transports, which cannot relay UDP, work as well.

    ``route_exclude_addresses`` contains the resolved transport endpoint(s).
    They must stay on the physical interface or an SSH/VPN transport would be
    captured by the TUN and recursively sent through itself.
    """
    tun_inbound: dict[str, Any] = {
        "type": "tun",
        "tag": "tun-in",
        "interface_name": interface_name,
        "address": [inet4_address],
        "auto_route": True,
        "strict_route": True,
        "stack": "system",
    }
    if route_exclude_addresses:
        tun_inbound["route_exclude_address"] = route_exclude_addresses

    return {
        "log": DEFAULT_LOG,
        "dns": {
            "servers": [
                {
                    "type": "https",
                    "tag": "tun-dns",
                    "server": PROXY_DNS_ADDR,
                    "server_port": 443,
                    "path": "/dns-query",
                    "tls": {
                        "enabled": True,
                        "server_name": TUN_DNS_SERVER_NAME,
                    },
                    "detour": "proxy",
                }
            ],
            "final": "tun-dns",
            "strategy": "ipv4_only",
        },
        "inbounds": [tun_inbound],
        "outbounds": [
            {
                "type": "socks",
                "tag": "proxy",
                "server": "127.0.0.1",
                "server_port": upstream_socks_port,
                "version": "5",
            },
            {"type": "direct", "tag": "direct"},
        ],
        "route": {
            "rules": [
                {"action": "sniff"},
                {"protocol": "dns", "action": "hijack-dns"},
                {"ip_is_private": True, "outbound": "direct"},
            ],
            "final": "proxy",
            "auto_detect_interface": True,
        },
    }
