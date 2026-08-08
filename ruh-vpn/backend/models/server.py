from __future__ import annotations

import uuid
from typing import Annotated, Literal, Optional, Union

from pydantic import BaseModel, ConfigDict, Field


class _Base(BaseModel):
    model_config = ConfigDict(extra="allow", populate_by_name=True)

    id: str = Field(default_factory=lambda: uuid.uuid4().hex[:12])
    name: str
    protocol: str


class SSHServer(_Base):
    protocol: Literal["ssh"] = "ssh"
    host: str
    port: int = 22
    user: str
    password: Optional[str] = None
    keyFile: Optional[str] = None
    localPort: int = 11080


class VlessServer(_Base):
    protocol: Literal["vless"] = "vless"
    address: str
    port: int
    uuid: str
    transport: str = "tcp"
    tls: bool = False
    sni: Optional[str] = None
    security: Optional[Literal["tls", "reality", "none"]] = None
    flow: Optional[str] = None
    fp: Optional[str] = None
    pbk: Optional[str] = None
    sid: Optional[str] = None
    # for ws/grpc/http transports
    path: Optional[str] = None
    host: Optional[str] = None
    serviceName: Optional[str] = None


class VmessServer(_Base):
    protocol: Literal["vmess"] = "vmess"
    address: str
    port: int
    uuid: str
    alterId: int = 0
    security: str = "auto"
    transport: str = "tcp"
    tls: bool = False
    sni: Optional[str] = None
    path: Optional[str] = None
    host: Optional[str] = None


class ShadowsocksServer(_Base):
    protocol: Literal["shadowsocks"] = "shadowsocks"
    address: str
    port: int
    method: str
    password: str


class Socks5Server(_Base):
    protocol: Literal["socks5"] = "socks5"
    host: str
    port: int
    username: Optional[str] = None
    password: Optional[str] = None


Server = Annotated[
    Union[SSHServer, VlessServer, VmessServer, ShadowsocksServer, Socks5Server],
    Field(discriminator="protocol"),
]


def parse_server(data: dict) -> Server:
    """Parse a dict into one of the typed server models based on the protocol field."""
    protocol = (data.get("protocol") or "").lower()
    mapping = {
        "ssh": SSHServer,
        "vless": VlessServer,
        "vmess": VmessServer,
        "shadowsocks": ShadowsocksServer,
        "ss": ShadowsocksServer,
        "socks": Socks5Server,
        "socks5": Socks5Server,
    }
    cls = mapping.get(protocol)
    if cls is None:
        raise ValueError(f"Unsupported protocol: {protocol!r}")
    data = dict(data)
    if protocol == "ss":
        data["protocol"] = "shadowsocks"
    if protocol == "socks":
        data["protocol"] = "socks5"
    return cls.model_validate(data)


def server_to_dict(server: BaseModel) -> dict:
    return server.model_dump(exclude_none=True)


# Connection secrets never leave the backend: list RPCs strip them, and
# UpdateServer treats an empty value as "keep the stored one".
SENSITIVE_FIELDS = ("password", "uuid")


def server_to_public_dict(server: BaseModel) -> dict:
    data = server.model_dump(exclude_none=True)
    for key in SENSITIVE_FIELDS:
        data.pop(key, None)
    return data


class RoutingRule(BaseModel):
    """User-defined routing rule.

    type:    force-proxy → match → proxy outbound
             direct      → match → direct outbound
             block       → match → block outbound
    pattern: one of
             - "example.com"      exact domain
             - "*.example.com"    domain suffix (matches example.com + subdomains)
             - "10.0.0.0/8"       CIDR (v4 or v6)
    """

    model_config = ConfigDict(extra="allow")

    id: str = Field(default_factory=lambda: uuid.uuid4().hex[:12])
    name: Optional[str] = None
    enabled: bool = True
    type: Literal["force-proxy", "direct", "block"] = "force-proxy"
    pattern: str

    def to_singbox_rule(self) -> Optional[dict]:
        if not self.enabled or not self.pattern:
            return None
        rule: dict = {}
        if self.type == "block":
            rule["action"] = "reject"
        else:
            rule["outbound"] = "proxy" if self.type == "force-proxy" else "direct"
        pat = self.pattern.strip()
        if "/" in pat and not pat.startswith("*"):
            rule["ip_cidr"] = [pat]
        elif pat.startswith("*."):
            rule["domain_suffix"] = [pat[2:]]
        elif pat.startswith("*"):
            rule["domain_keyword"] = [pat.lstrip("*")]
        else:
            rule["domain"] = [pat]
        return rule


class Settings(BaseModel):
    model_config = ConfigDict(extra="allow")

    activeServerId: Optional[str] = None
    mode: Literal["rules", "global"] = "rules"
    proxyMode: Literal["system", "tun"] = "system"
    autoStart: bool = False
    rulesPort: int = 11081
    globalPort: int = 11082
    transportPort: int = 11080
    refilterEnabled: bool = True
    healthCheckIntervalSec: int = 30
    killSwitchEnabled: bool = False
    clashApiPort: int = 11089
    showPingInBar: bool = True
    showTrafficInBar: bool = False
    activePresets: list[str] = Field(default_factory=lambda: ["ru"])


class StatusInfo(BaseModel):
    model_config = ConfigDict(extra="allow")

    running: bool = False
    activeServerId: Optional[str] = None
    mode: str = "rules"
    proxyMode: str = "system"
    transportPort: int = 11080
    muxPort: Optional[int] = None
    pids: dict[str, int] = Field(default_factory=dict)
    message: Optional[str] = None
    status: str = "ok"  # ok | degraded | failed | error
    reason: Optional[str] = None
