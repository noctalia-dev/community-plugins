"""Protocol-specific outbound builders for sing-box.

Each builder returns the outbound dict that goes into the sing-box "outbounds"
list when configuring the transport layer (the layer that actually talks to the
remote VPN server).

SSH is handled outside sing-box (via OpenSSH itself opening a SOCKS5
listener on the local transport port), so it does NOT appear here.
"""

from __future__ import annotations

from typing import Any

from backend.models.server import (
    Server,
    ShadowsocksServer,
    Socks5Server,
    SSHServer,
    VlessServer,
    VmessServer,
)


def build_outbound(server: Server, tag: str = "proxy") -> dict[str, Any]:
    """Return a sing-box outbound dict for the given server.

    Raises ValueError for SSH (not a sing-box outbound) and for unsupported
    protocols.
    """
    if isinstance(server, SSHServer):
        raise ValueError("SSH transport is handled outside sing-box")
    if isinstance(server, VlessServer):
        return _build_vless(server, tag)
    if isinstance(server, VmessServer):
        return _build_vmess(server, tag)
    if isinstance(server, ShadowsocksServer):
        return _build_shadowsocks(server, tag)
    if isinstance(server, Socks5Server):
        return _build_socks5(server, tag)
    raise ValueError(f"Unsupported server type: {type(server).__name__}")


def _build_tls(server: VlessServer | VmessServer) -> dict[str, Any] | None:
    if not getattr(server, "tls", False) and getattr(server, "security", None) not in (
        "tls",
        "reality",
    ):
        return None
    tls: dict[str, Any] = {"enabled": True}
    if server.sni:
        tls["server_name"] = server.sni
    fp = getattr(server, "fp", None)
    if fp:
        tls["utls"] = {"enabled": True, "fingerprint": fp}
    if getattr(server, "security", None) == "reality":
        pbk = getattr(server, "pbk", None) or ""
        sid = getattr(server, "sid", None) or ""
        tls["reality"] = {"enabled": True, "public_key": pbk, "short_id": sid}
    return tls


def _build_transport(server: VlessServer | VmessServer) -> dict[str, Any] | None:
    t = (getattr(server, "transport", "tcp") or "tcp").lower()
    if t in ("tcp", "raw", ""):
        return None
    if t == "ws":
        out: dict[str, Any] = {"type": "ws"}
        if getattr(server, "path", None):
            out["path"] = server.path
        if getattr(server, "host", None):
            out["headers"] = {"Host": server.host}
        return out
    if t == "grpc":
        return {"type": "grpc", "service_name": getattr(server, "serviceName", "") or ""}
    if t == "http":
        out = {"type": "http"}
        if getattr(server, "path", None):
            out["path"] = server.path
        if getattr(server, "host", None):
            out["host"] = [server.host]
        return out
    return None


def _build_vless(s: VlessServer, tag: str) -> dict[str, Any]:
    out: dict[str, Any] = {
        "type": "vless",
        "tag": tag,
        "server": s.address,
        "server_port": s.port,
        "uuid": s.uuid,
    }
    if s.flow:
        out["flow"] = s.flow
    tls = _build_tls(s)
    if tls:
        out["tls"] = tls
    tp = _build_transport(s)
    if tp:
        out["transport"] = tp
    return out


def _build_vmess(s: VmessServer, tag: str) -> dict[str, Any]:
    out: dict[str, Any] = {
        "type": "vmess",
        "tag": tag,
        "server": s.address,
        "server_port": s.port,
        "uuid": s.uuid,
        "alter_id": s.alterId,
        "security": s.security or "auto",
    }
    tls = _build_tls(s)
    if tls:
        out["tls"] = tls
    tp = _build_transport(s)
    if tp:
        out["transport"] = tp
    return out


def _build_shadowsocks(s: ShadowsocksServer, tag: str) -> dict[str, Any]:
    return {
        "type": "shadowsocks",
        "tag": tag,
        "server": s.address,
        "server_port": s.port,
        "method": s.method,
        "password": s.password,
    }


def _build_socks5(s: Socks5Server, tag: str) -> dict[str, Any]:
    out: dict[str, Any] = {
        "type": "socks",
        "tag": tag,
        "server": s.host,
        "server_port": s.port,
        "version": "5",
    }
    if s.username:
        out["username"] = s.username
    if s.password:
        out["password"] = s.password
    return out
