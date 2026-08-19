"""Main orchestrator: ties together state, sing-box, ssh, system-proxy and TUN.

Lifecycle:
  StartProxy(server_id, mode, proxy_mode):
    1. stop_all + pkill_zombies + sleep 1s
    2. start transport layer (sing-box or ssh) → port 11080
    3. wait until 11080 is listening
    4. start mux layer (rules → 11081 or global → 11082)
    5. wait until mux port is listening
    6. apply user-facing entry: gsettings (system) or TUN (sing-box)
    7. start monitor task — any process dying tears down the whole stack
"""

from __future__ import annotations

import asyncio
import ipaddress
import shutil
import socket
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from backend.config.settings import load_settings, save_settings
from backend.core.state import AppState
from backend.geoip import ENABLED as GEOIP_ENABLED
from backend.geoip import lookup_country
from backend.models.server import (
    SENSITIVE_FIELDS,
    RoutingRule,
    Server,
    Settings,
    SSHServer,
    StatusInfo,
    parse_server,
    server_to_dict,
    server_to_public_dict,
)
from backend.monitoring.health import HealthMonitor, tcp_ping
from backend.service import tun_binary
from backend.monitoring.log_streamer import LogStreamer
from backend.monitoring.traffic import TrafficMonitor
from backend.singbox.process_manager import LOG_DIR, LOG_NAMES, SINGBOX_BIN
from backend.singbox import config_builder
from backend.singbox.process_manager import ProcessManager
from backend.storage.persistence import (
    load_rules,
    load_servers,
    save_rules,
    save_servers,
)


# sing-box auto_route default table (iproute2_table_index); every sing-box
# based client (v2rayN, GUI.for.SingBox, …) shares it unless reconfigured.
SINGBOX_ROUTE_TABLE = 2022


def _now_log(level: str, message: str) -> None:
    print(f"[{level}] {message}", flush=True)


class VpnService:
    """Owns AppState + ProcessManager and exposes high-level operations.

    All operations are guarded by state.lock so they serialize cleanly.
    """

    def __init__(self, state: Optional[AppState] = None) -> None:
        self.state = state or AppState()
        self._pm = ProcessManager(logger=self._log)
        self._teardown_in_progress = False
        self._health: Optional[HealthMonitor] = None
        self._log_streamer = LogStreamer(self._on_singbox_log_line)
        self._log_streamer.start()
        self._traffic: Optional[TrafficMonitor] = None
        self._traffic_listeners: list = []
        # Latched once getcap confirms CAP_NET_ADMIN on the plugin-private
        # sing-box copy, so subsequent TUN starts never re-prompt via pkexec.
        # Reset whenever the copy is rewritten (a fresh file has no caps).
        self._tun_caps_granted = False
        # Serializes pkexec invocations so a duplicate caller can't open a
        # second polkit dialog while the first one is still on screen.
        self._tun_caps_lock = asyncio.Lock()
        # Subscription manager (initialized in bootstrap)
        from backend.subscription.manager import SubscriptionManager
        self._subs = SubscriptionManager(self)

    # ----------------------------------------------------------------- bootstrap

    async def bootstrap(self) -> None:
        """Load persisted servers/rules/settings."""
        self.state.servers = await load_servers()
        self.state.rules = await load_rules()
        self.state.settings = await load_settings()
        await self._subs.bootstrap()
        self._subs.start_auto_update()
        self._update_status_basics()
        self._log(
            "info",
            f"loaded {len(self.state.servers)} servers, {len(self.state.rules)} rules, "
            f"{len(await self._subs.list_subs())} subscriptions",
        )
        # Servers stored before geoip existed have no country. Do it off the
        # bootstrap path so a slow or dead lookup service cannot delay startup;
        # each server is only ever looked up once, since the result is saved.
        asyncio.create_task(self.backfill_countries())

    async def shutdown(self) -> None:
        if self._health:
            await self._health.stop()
            self._health = None
        if self._traffic:
            await self._traffic.stop()
            self._traffic = None
        await self._subs.stop()
        await self._log_streamer.stop()
        await self._pm.stop_monitor()
        await self._pm.stop_all()
        await self._unset_system_proxy(silent=True)
        await self._pm.clear_state()

    async def _on_singbox_log_line(self, source: str, level: str, message: str) -> None:
        # forward verbatim into the in-memory ring + LogMessage signal
        self.state.emit_log(level, f"[{source}] {message}")

    # ----------------------------------------------------------------- public API

    async def start_proxy(self, server_id: str, mode: str, proxy_mode: str) -> bool:
        async with self.state.lock:
            return await self._start_locked(server_id, mode, proxy_mode)

    async def stop_proxy(self) -> bool:
        async with self.state.lock:
            return await self._stop_locked(reason="user request")

    async def switch_server(self, server_id: str) -> bool:
        async with self.state.lock:
            was_running = self.state.status.running
            mode = self.state.settings.mode
            proxy_mode = self.state.settings.proxyMode
            if was_running:
                await self._stop_locked(reason="switch server", clear_active=False)
            self.state.settings.activeServerId = server_id
            await save_settings(self.state.settings)
            self._update_status_basics()
            if was_running:
                return await self._start_locked(server_id, mode, proxy_mode)
            return True

    async def set_mode(self, mode: str) -> bool:
        if mode not in ("rules", "global"):
            return False
        async with self.state.lock:
            was_running = self.state.status.running
            current_server = self.state.settings.activeServerId
            proxy_mode = self.state.settings.proxyMode
            self.state.settings.mode = mode  # type: ignore[assignment]
            await save_settings(self.state.settings)
            self._update_status_basics()
            if was_running and current_server:
                await self._stop_locked(reason="set_mode", clear_active=False)
                return await self._start_locked(current_server, mode, proxy_mode)
            return True

    async def set_proxy_mode(self, proxy_mode: str) -> bool:
        if proxy_mode not in ("system", "tun"):
            return False
        async with self.state.lock:
            was_running = self.state.status.running
            current_server = self.state.settings.activeServerId
            mode = self.state.settings.mode
            self.state.settings.proxyMode = proxy_mode  # type: ignore[assignment]
            await save_settings(self.state.settings)
            self._update_status_basics()
            if was_running and current_server:
                await self._stop_locked(reason="set_proxy_mode", clear_active=False)
                return await self._start_locked(current_server, mode, proxy_mode)
            return True

    # --- server CRUD

    async def add_server(self, server_dict: dict) -> str:
        server = parse_server(server_dict)
        await self._fill_country(server)
        async with self.state.lock:
            self.state.servers = [s for s in self.state.servers if s.id != server.id]
            self.state.servers.append(server)
            await save_servers(self.state.servers)
        self.state.emit_server_list()
        return server.id

    async def _fill_country(self, server) -> bool:
        """Look up `server.country` when absent. Best effort; never raises.

        Only the UI reads this (it draws the flag); the models keep it via their
        extra="allow". Off unless the user enables geoip_country — the lookup
        discloses their server's address to a third party.
        """
        if not GEOIP_ENABLED or getattr(server, "country", None):
            return False
        host = getattr(server, "host", None) or getattr(server, "address", None)
        if not host:
            return False
        try:
            cc = await lookup_country(str(host))
        except Exception:
            return False
        if not cc:
            return False
        try:
            setattr(server, "country", cc)
        except (AttributeError, ValueError):
            return False
        return True

    async def backfill_countries(self) -> int:
        """Fill in country for servers added before geoip was available."""
        if not GEOIP_ENABLED:
            return 0
        changed = 0
        for server in list(self.state.servers):
            if await self._fill_country(server):
                changed += 1
        if changed:
            async with self.state.lock:
                await save_servers(self.state.servers)
            self.state.emit_server_list()
            self._log("info", f"geoip: filled in country for {changed} server(s)")
        return changed

    async def add_from_link(self, link: str) -> str:
        """Parse one vless://, vmess://, ss://, socks5:// or sn:// share link."""
        from backend.subscription.parsers import parse_share_link

        data = parse_share_link((link or "").strip())
        if not data:
            raise ValueError("Unsupported or invalid share link")
        return await self.add_server(data)

    async def remove_server(self, server_id: str) -> bool:
        async with self.state.lock:
            before = len(self.state.servers)
            self.state.servers = [s for s in self.state.servers if s.id != server_id]
            if len(self.state.servers) == before:
                return False
            await save_servers(self.state.servers)
            if self.state.settings.activeServerId == server_id:
                if self.state.status.running:
                    await self._stop_locked(reason="active server removed")
                self.state.settings.activeServerId = None
                await save_settings(self.state.settings)
                self._update_status_basics()
        self.state.emit_server_list()
        return True

    async def update_server(self, server_dict: dict) -> bool:
        if "id" not in server_dict:
            return False
        async with self.state.lock:
            idx = next(
                (i for i, s in enumerate(self.state.servers) if s.id == server_dict["id"]),
                None,
            )
            if idx is None:
                return False
            # The editor never sees secrets (list_servers strips them), so an
            # empty or missing secret in an update means "keep the stored one".
            existing = server_to_dict(self.state.servers[idx])
            if existing.get("protocol") == server_dict.get("protocol"):
                for key in SENSITIVE_FIELDS:
                    if not server_dict.get(key) and existing.get(key):
                        server_dict[key] = existing[key]
            self.state.servers[idx] = parse_server(server_dict)
            await save_servers(self.state.servers)
        self.state.emit_server_list()
        return True

    async def list_servers(self) -> list[dict]:
        return [server_to_public_dict(s) for s in self.state.servers]

    async def ping(self, server_id: str) -> int:
        server = self.state.get_server(server_id)
        if server is None:
            return -1
        host, port = self._server_endpoint(server)
        if not host:
            return -1
        latency = await tcp_ping(host, port, timeout=5.0)
        return latency if latency is not None else -1

    # ---------------- routing rules CRUD + hot-reload

    async def list_rules(self) -> list[dict]:
        return [r.model_dump(exclude_none=True) for r in self.state.rules]

    async def add_rule(self, rule_dict: dict) -> str:
        from backend.routing.rules import validate_pattern
        try:
            rule = RoutingRule.model_validate(rule_dict)
        except Exception as exc:
            raise ValueError(f"Invalid routing rule: {exc}") from exc
        try:
            rule.pattern = validate_pattern(rule.pattern)
        except ValueError as exc:
            raise ValueError(f"Invalid routing rule pattern: {exc}") from exc
        async with self.state.lock:
            self.state.rules = [r for r in self.state.rules if r.id != rule.id]
            self.state.rules.append(rule)
            await save_rules(self.state.rules)
        await self._reload_rules_mux()
        return rule.id

    async def remove_rule(self, rule_id: str) -> bool:
        async with self.state.lock:
            before = len(self.state.rules)
            self.state.rules = [r for r in self.state.rules if r.id != rule_id]
            if len(self.state.rules) == before:
                return False
            await save_rules(self.state.rules)
        await self._reload_rules_mux()
        return True

    async def _reload_rules_mux(self) -> None:
        """If the proxy is running in rules mode, regenerate and restart the rules mux."""
        async with self.state.lock:
            if not self.state.status.running:
                return
            if self.state.settings.mode != "rules":
                return
            self._log("info", "hot-reloading rules mux after rule change")
            self._log_streamer.remove_source("rules")
            await self._pm.stop("rules")
            cfg = config_builder.build_rules_config(
                transport_port=self.state.settings.transportPort,
                listen_port=self.state.settings.rulesPort,
                custom_rules=self.state.rules,
                active_presets=list(self.state.settings.activePresets or []),
            )
            await self._pm.write_config("rules", cfg)
            try:
                await self._pm.start_singbox("rules")
                self._log_streamer.add_source("rules", LOG_DIR / LOG_NAMES["rules"])
            except Exception as exc:
                self._log("error", f"failed to restart rules mux: {exc}")
                return
            if not await self._wait_port("127.0.0.1", self.state.settings.rulesPort, 5.0):
                self._log("error", "rules mux did not reopen its port after reload")

    async def get_logs(self) -> list[str]:
        out: list[str] = []
        for ts, lvl, msg in list(self.state.logs):
            iso = datetime.fromtimestamp(ts, tz=timezone.utc).isoformat()
            out.append(f"{iso} [{lvl}] {msg}")
        return out[-100:]

    def get_status(self) -> dict:
        return self.state.status.model_dump(exclude_none=True)

    # ----------------------------------------------------------------- internals

    def _log(self, level: str, message: str) -> None:
        _now_log(level, message)
        self.state.emit_log(level, message)

    def _server_endpoint(self, server: Server) -> tuple[Optional[str], int]:
        if isinstance(server, SSHServer):
            return server.host, server.port
        host = getattr(server, "address", None) or getattr(server, "host", None)
        return host, getattr(server, "port", 0)

    def _update_status_basics(self) -> None:
        s = self.state.status
        s.activeServerId = self.state.settings.activeServerId
        s.mode = self.state.settings.mode
        s.proxyMode = self.state.settings.proxyMode
        s.transportPort = self.state.settings.transportPort
        s.muxPort = (
            self.state.settings.rulesPort
            if self.state.settings.mode == "rules"
            else self.state.settings.globalPort
        )
        s.pids = self._pm.running_pids()
        s.running = bool(s.pids) and any(
            n in s.pids for n in ("transport", "ssh")
        )
        self.state.emit_status()

    # --- start / stop body (assumes lock is held)

    async def _start_locked(self, server_id: str, mode: str, proxy_mode: str) -> bool:
        if mode not in ("rules", "global"):
            self._log("error", f"invalid mode: {mode!r}")
            return False
        if proxy_mode not in ("system", "tun"):
            self._log("error", f"invalid proxy_mode: {proxy_mode!r}")
            return False
        server = self.state.get_server(server_id)
        if server is None:
            self._log("error", f"unknown server id: {server_id!r}")
            self.state.status.message = f"Unknown server: {server_id}"
            self.state.emit_status()
            return False

        # full clean slate
        await self._pm.stop_monitor()
        await self._pm.stop_all()
        await self._unset_system_proxy(silent=True)
        await asyncio.sleep(1.0)

        transport_port = self.state.settings.transportPort
        mux_port = (
            self.state.settings.rulesPort
            if mode == "rules"
            else self.state.settings.globalPort
        )

        # 1. transport layer
        try:
            if isinstance(server, SSHServer):
                await self._pm.start_ssh(
                    host=server.host,
                    port=server.port,
                    user=server.user,
                    local_port=transport_port,
                    password=server.password,
                    key_file=server.keyFile,
                )
                self._log_streamer.add_source("ssh", LOG_DIR / LOG_NAMES["ssh"])
            else:
                cfg = config_builder.build_transport_config(server, listen_port=transport_port)
                await self._pm.write_config("transport", cfg)
                await self._pm.start_singbox("transport")
                self._log_streamer.add_source("transport", LOG_DIR / LOG_NAMES["transport"])
        except Exception as exc:
            self._log("error", f"failed to start transport: {exc}")
            await self._safe_teardown()
            self.state.status.message = f"Transport failed: {exc}"
            self.state.emit_status()
            return False

        if not await self._wait_port("127.0.0.1", transport_port, 12.0):
            tail = await self._pm.read_log_tail(
                "ssh" if isinstance(server, SSHServer) else "transport"
            )
            self._log("error", f"transport port {transport_port} did not open. log tail:\n{tail[-1500:]}")
            await self._safe_teardown()
            self.state.status.message = "Transport port did not open"
            self.state.emit_status()
            return False

        # 2. mux layer
        # Global mux (11082) always starts. In rules mode the rules mux
        # (11081) starts alongside it; the user-facing entry points to 11081.
        # Clash API binds only to the rules mux (or global when alone) to
        # avoid a port conflict when both are running.
        try:
            global_port = self.state.settings.globalPort
            global_cfg = config_builder.build_global_config(
                transport_port=transport_port,
                listen_port=global_port,
                clash_api_port=self.state.settings.clashApiPort if mode == "global" else None,
            )
            await self._pm.write_config("global", global_cfg)
            await self._pm.start_singbox("global")
            self._log_streamer.add_source("global", LOG_DIR / LOG_NAMES["global"])

            if mode == "rules":
                rules_cfg = config_builder.build_rules_config(
                    transport_port=transport_port,
                    listen_port=mux_port,
                    custom_rules=self.state.rules,
                    active_presets=list(self.state.settings.activePresets or []),
                    clash_api_port=self.state.settings.clashApiPort,
                )
                await self._pm.write_config("rules", rules_cfg)
                await self._pm.start_singbox("rules")
                self._log_streamer.add_source("rules", LOG_DIR / LOG_NAMES["rules"])
        except Exception as exc:
            self._log("error", f"failed to start mux ({mode}): {exc}")
            await self._safe_teardown()
            self.state.status.message = f"Mux failed: {exc}"
            self.state.emit_status()
            return False

        if not await self._wait_port("127.0.0.1", mux_port, 8.0):
            tail = await self._pm.read_log_tail("rules" if mode == "rules" else "global")
            self._log("error", f"mux port {mux_port} did not open. log tail:\n{tail[-1500:]}")
            await self._safe_teardown()
            self.state.status.message = f"Mux port {mux_port} did not open"
            self.state.emit_status()
            return False

        # 3. user-facing entry
        if proxy_mode == "system":
            ok = await self._set_system_proxy(mux_port)
            if not ok:
                self._log("error", "failed to set system proxy via gsettings")
                await self._safe_teardown()
                self.state.status.message = "Failed to set system proxy"
                self.state.emit_status()
                return False
        else:  # tun
            ok = await self._start_tun(mux_port, server)
            if not ok:
                await self._safe_teardown()
                return False

        # 4. persist settings and arm monitor
        self.state.settings.activeServerId = server_id
        self.state.settings.mode = mode  # type: ignore[assignment]
        self.state.settings.proxyMode = proxy_mode  # type: ignore[assignment]
        await save_settings(self.state.settings)
        self._update_status_basics()
        self.state.status.message = None
        self.state.emit_status()

        await self._pm.write_state({
            "running": True,
            "activeServerId": server_id,
            "mode": mode,
            "proxyMode": proxy_mode,
            "pids": self._pm.running_pids(),
            "startedAt": time.time(),
        })

        self._pm.start_monitor(self._on_unexpected_exit)

        # arm health monitor
        if self._health:
            await self._health.stop()
        host, port = self._server_endpoint(server)
        if host:
            self._health = HealthMonitor(
                host=host,
                port=port,
                interval=float(self.state.settings.healthCheckIntervalSec),
                on_failed=self._on_health_failed,
            )
            self._health.start()

        # arm traffic monitor
        if self._traffic:
            await self._traffic.stop()
        self._traffic = TrafficMonitor(
            api_url=f"http://127.0.0.1:{self.state.settings.clashApiPort}",
            interval=5.0,
            on_update=self._on_traffic_update,
        )
        self._traffic.start()

        self._log("info", f"proxy started: server={server.name} mode={mode} proxy_mode={proxy_mode}")
        return True

    async def _stop_locked(self, *, reason: str, clear_active: bool = True) -> bool:
        self._log("info", f"stopping proxy ({reason})")
        if self._health:
            await self._health.stop()
            self._health = None
        if self._traffic:
            await self._traffic.stop()
            self._traffic = None
        self._log_streamer.clear()
        await self._pm.stop_monitor()
        if self.state.settings.proxyMode == "system":
            await self._unset_system_proxy(silent=True)
        await self._pm.stop_all()
        await self._pm.clear_state()
        if clear_active:
            self.state.status.message = None
            self.state.status.reason = None
        self.state.status.status = "ok"
        self._update_status_basics()
        self.state.status.running = False
        self.state.emit_status()
        return True

    async def _safe_teardown(self) -> None:
        if self._teardown_in_progress:
            return
        self._teardown_in_progress = True
        try:
            if self._health:
                await self._health.stop()
                self._health = None
            if self._traffic:
                await self._traffic.stop()
                self._traffic = None
            self._log_streamer.clear()
            await self._pm.stop_monitor()
            await self._unset_system_proxy(silent=True)
            await self._pm.stop_all()
            await self._pm.clear_state()
            self._update_status_basics()
            self.state.status.running = False
            self.state.emit_status()
        finally:
            self._teardown_in_progress = False

    async def _on_traffic_update(self, stats: dict) -> None:
        for cb in list(self._traffic_listeners):
            try:
                cb(stats)
            except Exception:
                pass

    def add_traffic_listener(self, cb) -> None:
        self._traffic_listeners.append(cb)

    def get_traffic_stats(self) -> dict:
        if self._traffic is None:
            return {
                "bytes_sent": 0,
                "bytes_received": 0,
                "uptime_seconds": 0,
                "connection_count": 0,
            }
        return self._traffic.stats.to_dict()

    async def _on_health_failed(self) -> None:
        self._log("error", "health check failed 3 times in a row")
        self.state.status.status = "error"
        self.state.status.reason = "health_check_failed"
        self.state.emit_status()

    # ---------------- subscriptions

    async def add_subscription(self, url: str, name: str) -> bool:
        return await self._subs.add(url, name)

    async def remove_subscription(self, url: str) -> bool:
        return await self._subs.remove(url)

    async def update_subscription(self, url: str) -> int:
        return await self._subs.update(url)

    async def list_subscriptions(self) -> list[dict]:
        return await self._subs.list_subs()

    # ---------------- settings

    async def get_settings(self) -> dict:
        return self.state.settings.model_dump(exclude_none=True)

    async def update_settings(self, patch: dict) -> dict:
        """Apply a partial update to user-visible settings.

        Only fields explicitly handled here may be mutated; ports and other
        connection-critical fields are deliberately ignored so the bar widget
        toggles can't accidentally clobber them.
        """
        async with self.state.lock:
            if "showPingInBar" in patch:
                self.state.settings.showPingInBar = bool(patch["showPingInBar"])
            if "showTrafficInBar" in patch:
                self.state.settings.showTrafficInBar = bool(patch["showTrafficInBar"])
            await save_settings(self.state.settings)
            return self.state.settings.model_dump(exclude_none=True)

    # ---------------- routing presets

    async def list_presets(self) -> list[dict]:
        from backend.routing.rules import PRESETS
        active = set(self.state.settings.activePresets or [])
        out: list[dict] = []
        for key, p in PRESETS.items():
            out.append({
                "key": p["key"],
                "name": p["name"],
                "flag": p.get("flag", ""),
                "description": p.get("description", ""),
                "enabled": key in active,
            })
        return out

    async def toggle_preset(self, key: str, enabled: bool) -> bool:
        from backend.routing.rules import PRESETS
        if key not in PRESETS:
            return False
        async with self.state.lock:
            current = list(self.state.settings.activePresets or [])
            has = key in current
            if enabled and not has:
                current.append(key)
            elif (not enabled) and has:
                current = [k for k in current if k != key]
            else:
                return True  # no-op
            self.state.settings.activePresets = current
            await save_settings(self.state.settings)
        await self._reload_rules_mux()
        return True

    # ---------------- kill switch

    async def set_kill_switch(self, enabled: bool) -> bool:
        from backend.service import kill_switch as ks
        async with self.state.lock:
            self.state.settings.killSwitchEnabled = bool(enabled)
            await save_settings(self.state.settings)
            if enabled:
                host, port = self._active_server_endpoint()
                # Only literal, pre-resolved IPs may enter the ruleset: its
                # text is executed by nft with root privileges, and the host
                # can come from an untrusted subscription.
                server_ips = await self._resolve_host_ips(host, port) if host else []
                if host and not server_ips:
                    self._log(
                        "warn",
                        f"kill switch: could not resolve {host!r}; "
                        "applying without a server allowance",
                    )
                ruleset = ks.build_ruleset(
                    server_ips=server_ips,
                    server_port=port,
                    extra_allow_tcp=[
                        self.state.settings.transportPort,
                        self.state.settings.rulesPort,
                        self.state.settings.globalPort,
                        self.state.settings.clashApiPort,
                    ],
                )
                ok, msg = await ks.apply(ruleset)
                self._log("info" if ok else "error", f"kill switch apply: {msg}")
                return ok
            else:
                ok, msg = await ks.remove()
                self._log("info" if ok else "warn", f"kill switch remove: {msg}")
                return ok

    async def get_kill_switch_status(self) -> dict:
        from backend.service import kill_switch as ks
        active = await ks.is_active()
        return {
            "enabled": bool(self.state.settings.killSwitchEnabled),
            "active": bool(active),
        }

    def _active_server_endpoint(self) -> tuple[Optional[str], Optional[int]]:
        sid = self.state.settings.activeServerId
        if not sid:
            return None, None
        server = self.state.get_server(sid)
        if server is None:
            return None, None
        return self._server_endpoint(server)

    def check_dns_leak(self) -> dict:
        from backend.monitoring.health import check_dns_leak as _check
        return _check(
            running=self.state.status.running,
            proxy_mode=self.state.settings.proxyMode,
            mode=self.state.settings.mode,
        )

    def get_health(self) -> dict:
        if self._health is None:
            return {
                "latency_ms": -1,
                "jitter_ms": -1,
                "down_mbps": -1.0,
                "up_mbps": -1.0,
                "speed_taken_at": "",
                "last_check": "",
                "consecutive_failures": 0,
                "status": "ok" if not self.state.status.running else "degraded",
            }
        return self._health.state.to_dict()

    async def run_speed_test(self) -> dict:
        empty = {
            "down_mbps": -1.0,
            "up_mbps": -1.0,
            "ping_ms": -1,
            "jitter_ms": -1,
        }
        if self._health is None:
            return empty
        # Always measure through the transport upstream (11080). The mux port
        # would re-enter the routing engine and send speed-test domains DIRECT
        # in rules mode, which defeats the test and can hang on slow paths.
        transport_port = (
            self.state.status.transportPort
            or self.state.settings.transportPort
            or 11080
        )
        # If the transport isn't listening, fail fast instead of hanging.
        from backend.monitoring.health import tcp_ping
        if not self.state.status.running or await tcp_ping(
            "127.0.0.1", transport_port, timeout=1.0
        ) is None:
            return {**empty, "error": "proxy transport not listening on 127.0.0.1:%d" % transport_port}
        proxy_url = f"socks5://127.0.0.1:{transport_port}"
        try:
            return await asyncio.wait_for(
                self._health.run_speed_test(proxy_url=proxy_url),
                timeout=45.0,
            )
        except asyncio.TimeoutError:
            st = self._health.state
            return {
                "down_mbps": float(st.down_mbps),
                "up_mbps": float(st.up_mbps),
                "ping_ms": int(st.latency_ms),
                "jitter_ms": int(st.jitter_ms),
                "error": "speed test timed out after 45s",
            }

    async def _on_unexpected_exit(self, name: str) -> None:
        self._log("error", f"unexpected exit of '{name}'; tearing down")
        async with self.state.lock:
            await self._safe_teardown()
            self.state.status.message = f"Process '{name}' exited unexpectedly"
            self.state.emit_status()

    # ----------------------------------------------------------------- system proxy / TUN

    async def _set_system_proxy(self, port: int) -> bool:
        if shutil.which("gsettings") is None:
            self._log("warn", "gsettings not found — cannot set system proxy")
            return False
        cmds = [
            ["gsettings", "set", "org.gnome.system.proxy", "mode", "manual"],
            ["gsettings", "set", "org.gnome.system.proxy.socks", "host", "127.0.0.1"],
            ["gsettings", "set", "org.gnome.system.proxy.socks", "port", str(port)],
            ["gsettings", "set", "org.gnome.system.proxy.http", "host", "127.0.0.1"],
            ["gsettings", "set", "org.gnome.system.proxy.http", "port", str(port)],
            ["gsettings", "set", "org.gnome.system.proxy.https", "host", "127.0.0.1"],
            ["gsettings", "set", "org.gnome.system.proxy.https", "port", str(port)],
            [
                "gsettings",
                "set",
                "org.gnome.system.proxy",
                "use-same-proxy",
                "true",
            ],
        ]
        for cmd in cmds:
            rc = await self._run(cmd)
            if rc != 0:
                self._log("error", f"gsettings failed: {' '.join(cmd)} rc={rc}")
                return False
        return True

    async def _unset_system_proxy(self, silent: bool = False) -> None:
        if shutil.which("gsettings") is None:
            return
        await self._run(["gsettings", "set", "org.gnome.system.proxy", "mode", "none"])
        if not silent:
            self._log("info", "system proxy disabled")

    async def _start_tun(self, upstream_port: int, server: Server) -> bool:
        try:
            tun_bin, refreshed = await asyncio.to_thread(
                tun_binary.ensure_copy, SINGBOX_BIN
            )
        except OSError as exc:
            self._log("error", f"failed to prepare private sing-box copy for TUN: {exc}")
            self.state.status.message = "Could not prepare sing-box copy for TUN"
            self.state.emit_status()
            return False
        if refreshed:
            # a rewritten copy starts with no file capabilities
            self._tun_caps_granted = False

        cap_ok = await self._check_tun_caps(tun_bin)
        if not cap_ok:
            self._log(
                "warn",
                "TUN sing-box copy missing CAP_NET_ADMIN; attempting pkexec setcap fallback",
            )
            ok = await self._grant_tun_caps(tun_bin)
            if not ok:
                self.state.status.message = (
                    f"TUN requires CAP_NET_ADMIN on {tun_bin}. "
                    f"Run: sudo setcap cap_net_admin+ep {tun_bin}"
                )
                self.state.emit_status()
                return False

        # Our own leftovers are gone by now (stop_all + pkill ran at the top of
        # _start_locked, and TUN routes die with the process), so anything left
        # in the auto_route table belongs to another sing-box based client
        # (v2rayN etc.).  sing-box would only fail later with a cryptic
        # "add route 0: file exists" (issue #327).
        if await self._tun_route_table_busy():
            self._log(
                "error",
                f"route table {SINGBOX_ROUTE_TABLE} is not empty; "
                "another sing-box based VPN client appears to be connected",
            )
            self.state.status.message = (
                "Another VPN's TUN is active — disconnect it first"
            )
            self.state.emit_status()
            return False

        route_exclusions = await self._resolve_transport_endpoints(server)
        if not route_exclusions:
            host, _ = self._server_endpoint(server)
            self._log("error", f"failed to resolve transport endpoint for TUN: {host}")
            self.state.status.message = "Could not resolve VPN server for TUN routing"
            self.state.emit_status()
            return False

        cfg = config_builder.build_tun_config(
            upstream_socks_port=upstream_port,
            route_exclude_addresses=route_exclusions,
        )
        try:
            await self._pm.write_config("tun", cfg)
            await self._pm.start_singbox("tun", binary=tun_bin)
            self._log_streamer.add_source("tun", LOG_DIR / LOG_NAMES["tun"])
        except Exception as exc:
            self._log("error", f"failed to start tun: {exc}")
            return False

        await asyncio.sleep(0.8)
        if not self._pm.is_running("tun"):
            tail = await self._pm.read_log_tail("tun")
            self._log("error", f"tun process died. log tail:\n{tail[-1500:]}")
            self.state.status.message = "TUN failed to start"
            self.state.emit_status()
            return False
        return True

    async def _tun_route_table_busy(self) -> bool:
        """True when the sing-box auto_route table already holds routes."""
        if shutil.which("ip") is None:
            return False
        for family in ("-4", "-6"):
            rc, out = await self._run_capture(
                ["ip", family, "route", "show", "table", str(SINGBOX_ROUTE_TABLE)]
            )
            # rc != 0 means the table does not exist — that is the clean case
            if rc == 0 and out.strip():
                return True
        return False

    async def _resolve_host_ips(self, host: str, port: Optional[int]) -> list[str]:
        """Resolve a host to canonical literal IPs; a literal IP passes through."""
        try:
            return [str(ipaddress.ip_address(host))]
        except ValueError:
            pass

        loop = asyncio.get_running_loop()
        try:
            info = await loop.getaddrinfo(host, port or 443, type=socket.SOCK_STREAM)
        except (socket.gaierror, OSError):
            return []

        ips: set[str] = set()
        for _, _, _, _, sockaddr in info:
            try:
                ips.add(str(ipaddress.ip_address(sockaddr[0])))
            except ValueError:
                continue
        return sorted(ips)

    async def _resolve_transport_endpoints(self, server: Server) -> list[str]:
        """Resolve the transport host to host-prefixes excluded from TUN.

        The transport is started before TUN, so resolving here uses the normal
        system path and cannot recurse through the new interface.
        """
        host, port = self._server_endpoint(server)
        if not host:
            return []
        prefixes = []
        for ip_str in await self._resolve_host_ips(host, port):
            ip = ipaddress.ip_address(ip_str)
            prefixes.append(f"{ip}/{ip.max_prefixlen}")
        return sorted(prefixes)

    async def _check_tun_caps(self, binary: str) -> bool:
        if self._tun_caps_granted:
            return True
        rc, stdout = await self._run_capture(["getcap", binary])
        if rc != 0:
            return False
        if "cap_net_admin" in stdout.lower():
            self._tun_caps_granted = True
            return True
        return False

    async def _grant_tun_caps(self, binary: str) -> bool:
        # pkexec/setcap is meaningful only for TUN mode — refuse to prompt
        # the user during a system-proxy switch.
        if self.state.settings.proxyMode != "tun":
            return False
        if shutil.which("pkexec") is None:
            return False
        async with self._tun_caps_lock:
            # A concurrent caller may have already granted caps while we were
            # waiting for the lock; re-check before firing pkexec again.
            if await self._check_tun_caps(binary):
                return True
            # One prompt does both: grant the cap to the private copy and drop
            # the grant older plugin versions left on the shared system binary.
            # Paths travel as positional arguments, never spliced into the
            # script text.
            script = 'setcap cap_net_admin+ep "$1" && { setcap -r "$2" 2>/dev/null; true; }'
            rc = await self._run(
                [
                    "pkexec", "sh", "-c", script, "sh",
                    binary,
                    tun_binary.source_binary(SINGBOX_BIN),
                ]
            )
            if rc != 0:
                return False
            return await self._check_tun_caps(binary)

    # ----------------------------------------------------------------- low-level

    @staticmethod
    async def _wait_port(host: str, port: int, timeout: float) -> bool:
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout
        while loop.time() < deadline:
            try:
                _, writer = await asyncio.wait_for(
                    asyncio.open_connection(host, port), timeout=0.5
                )
                writer.close()
                try:
                    await writer.wait_closed()
                except (ConnectionError, OSError):
                    pass
                return True
            except (OSError, asyncio.TimeoutError):
                await asyncio.sleep(0.25)
        return False

    @staticmethod
    async def _run(cmd: list[str]) -> int:
        proc = await asyncio.create_subprocess_exec(
            *cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        return await proc.wait()

    @staticmethod
    async def _run_capture(cmd: list[str]) -> tuple[int, str]:
        proc = await asyncio.create_subprocess_exec(
            *cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
        )
        out, _ = await proc.communicate()
        return proc.returncode or 0, out.decode("utf-8", errors="replace")
