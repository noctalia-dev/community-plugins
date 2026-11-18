"""Localhost HTTP control interface for the VPN backend.

Replaces the old DBus interface (backend/dbus/dbus_server.py) for the Luau
plugin. The Luau [[service]] entry talks to us two ways:

  * commands  →  POST http://127.0.0.1:<port>/rpc   with body
                 {"method": "StartProxy", "args": [...]}
                 reply {"result": ...}  or  {"error": "..."}

  * events    →  we print newline-delimited JSON to *stdout*, which the Luau
                 service consumes via noctalia.runStream():
                    {"event": "StatusChanged",   "data": {...}}
                    {"event": "ServerListChanged"}
                    {"event": "LogMessage",      "data": {"level","message"}}
                    {"event": "TrafficUpdate",   "data": {...}}
                    {"event": "ready",  "data": {"port": <port>}}

Only 127.0.0.1 is bound, and /rpc additionally requires a per-launch bearer
token: loopback alone would let any local user (not just the owner) drive the
VPN and read server credentials. The token is generated at startup and written
to a 0600 file inside the private runtime dir, so only the owning user's
processes — the Luau service among them — can read it. /healthz stays open; it
carries nothing but liveness and the port, and the Luau service probes it
before it knows the token.

The method map mirrors the DBus contract 1:1. Over JSON, dict arguments arrive
as plain Python dicts, so none of the DBus Variant coercion is needed.
"""

from __future__ import annotations

import hmac
import inspect
import json
import os
import sys
from pathlib import Path
from typing import Any, Callable

from aiohttp import web

from backend.service.vpn_service import VpnService

HOST = "127.0.0.1"
DEFAULT_PORT = 11090


def emit(obj: dict) -> None:
    """Write one JSON event line to stdout for the Luau service to stream."""
    try:
        sys.stdout.write(json.dumps(obj, ensure_ascii=False, default=str) + "\n")
        sys.stdout.flush()
    except Exception:
        pass


# ------------------------------------------------------------------ dispatch

# Each handler receives (svc, args) and returns either a value or an awaitable.
# Names and argument order match backend/dbus/dbus_server.py exactly.
def _build_handlers() -> dict[str, Callable[[VpnService, list], Any]]:
    return {
        # ---- lifecycle / status ----
        "StartProxy": lambda s, a: s.start_proxy(a[0], a[1], a[2]),
        "StopProxy": lambda s, a: s.stop_proxy(),
        "GetStatus": lambda s, a: s.get_status(),
        "GetHealth": lambda s, a: s.get_health(),
        "GetTrafficStats": lambda s, a: s.get_traffic_stats(),
        "CheckDnsLeak": lambda s, a: s.check_dns_leak(),
        "RunSpeedTest": lambda s, a: s.run_speed_test(),
        # ---- servers ----
        "GetServers": lambda s, a: s.list_servers(),
        "AddServer": lambda s, a: s.add_server(a[0]),
        "UpdateServer": lambda s, a: s.update_server(a[0]),
        "RemoveServer": lambda s, a: s.remove_server(a[0]),
        "SwitchServer": lambda s, a: s.switch_server(a[0]),
        "PingServer": lambda s, a: s.ping(a[0]),
        "ParseShareLink": lambda s, a: s.add_from_link(a[0]),
        # ---- modes ----
        "SetMode": lambda s, a: s.set_mode(a[0]),
        "SetProxyMode": lambda s, a: s.set_proxy_mode(a[0]),
        # ---- routing rules ----
        "GetRoutingRules": lambda s, a: s.list_rules(),
        "AddRoutingRule": lambda s, a: s.add_rule(a[0]),
        "RemoveRoutingRule": lambda s, a: s.remove_rule(a[0]),
        "GetPresets": lambda s, a: s.list_presets(),
        "TogglePreset": lambda s, a: s.toggle_preset(a[0], a[1]),
        # ---- kill switch ----
        "SetKillSwitch": lambda s, a: s.set_kill_switch(a[0]),
        "GetKillSwitchStatus": lambda s, a: s.get_kill_switch_status(),
        # ---- subscriptions ----
        "AddSubscription": lambda s, a: s.add_subscription(a[0], a[1] if len(a) > 1 else ""),
        "RemoveSubscription": lambda s, a: s.remove_subscription(a[0]),
        "UpdateSubscription": lambda s, a: s.update_subscription(a[0]),
        "GetSubscriptions": lambda s, a: s.list_subscriptions(),
        # ---- logs / settings ----
        "GetLogs": lambda s, a: s.get_logs(),
        "GetSettings": lambda s, a: s.get_settings(),
        "UpdateSettings": lambda s, a: s.update_settings(a[0]),
    }


class ControlServer:
    def __init__(
        self,
        service: VpnService,
        port: int = DEFAULT_PORT,
        token: str = "",
        token_file: Path | None = None,
    ) -> None:
        self._svc = service
        self._port = port
        self._token = token
        self._token_file = token_file
        self._handlers = _build_handlers()
        self._runner: web.AppRunner | None = None
        self._wire_events()

    # ------------------------------------------------------------- events
    def _wire_events(self) -> None:
        svc = self._svc
        svc.state.status_listeners.append(self._on_status)
        svc.state.server_list_listeners.append(self._on_server_list)
        svc.state.log_listeners.append(self._on_log)
        svc.add_traffic_listener(self._on_traffic)

    def _on_status(self, status_obj) -> None:
        try:
            data = status_obj.model_dump(exclude_none=True)
        except Exception:
            return
        emit({"event": "StatusChanged", "data": data})

    def _on_server_list(self) -> None:
        emit({"event": "ServerListChanged"})

    def _on_log(self, level: str, message: str) -> None:
        msg = message if len(message) <= 1024 else message[:1024] + "..."
        emit({"event": "LogMessage", "data": {"level": level, "message": msg}})

    def _on_traffic(self, stats: dict) -> None:
        emit({"event": "TrafficUpdate", "data": stats})

    # ------------------------------------------------------------- http
    def _authorized(self, request: web.Request) -> bool:
        if not self._token:
            return False
        header = request.headers.get("Authorization", "")
        scheme, _, presented = header.partition(" ")
        if scheme.lower() != "bearer":
            return False
        return hmac.compare_digest(presented.strip(), self._token)

    async def _handle_rpc(self, request: web.Request) -> web.Response:
        if not self._authorized(request):
            return web.json_response({"error": "unauthorized"}, status=401)
        try:
            req = await request.json()
        except Exception:
            return web.json_response({"error": "invalid JSON body"}, status=400)

        method = req.get("method", "")
        args = req.get("args") or []
        handler = self._handlers.get(method)
        if handler is None:
            return web.json_response({"error": f"unknown method: {method}"}, status=404)

        try:
            result = handler(self._svc, args)
            if inspect.isawaitable(result):
                result = await result
        except ValueError as exc:
            return web.json_response({"error": str(exc) or "invalid argument"}, status=400)
        except IndexError:
            return web.json_response({"error": f"missing arguments for {method}"}, status=400)
        except Exception as exc:  # noqa: BLE001
            return web.json_response({"error": f"{type(exc).__name__}: {exc}"}, status=500)

        return web.json_response({"result": result}, dumps=lambda o: json.dumps(o, default=str))

    async def _handle_health(self, request: web.Request) -> web.Response:
        return web.json_response({"ok": True, "port": self._port})

    def _publish_token(self) -> None:
        """Write the token file, readable by the owning user only.

        Must run only after the port is bound: a second backend losing the
        EADDRINUSE race exits without ever binding, and writing earlier would
        let that loser clobber the live backend's token on its way out."""
        if self._token_file is None:
            return
        fd = os.open(self._token_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as fh:
            fh.write(self._token + "\n")

    async def start(self) -> None:
        """Bind the control socket. Raises OSError if the port is already taken
        (another backend is running) — the caller must NOT fall through to the
        destructive shutdown path in that case."""
        app = web.Application()
        app.router.add_post("/rpc", self._handle_rpc)
        app.router.add_get("/healthz", self._handle_health)
        self._runner = web.AppRunner(app)
        await self._runner.setup()
        site = web.TCPSite(self._runner, HOST, self._port)
        await site.start()  # OSError (EADDRINUSE) propagates to caller
        self._publish_token()
        emit({"event": "ready", "data": {"port": self._port}})

    async def stop(self) -> None:
        if self._runner is not None:
            await self._runner.cleanup()
            self._runner = None


async def serve(
    service: VpnService,
    port: int = DEFAULT_PORT,
    token: str = "",
    token_file: Path | None = None,
) -> ControlServer:
    server = ControlServer(service, port, token=token, token_file=token_file)
    await server.start()
    return server
