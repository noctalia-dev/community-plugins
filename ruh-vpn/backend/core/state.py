from __future__ import annotations

import asyncio
from collections import deque
from dataclasses import dataclass, field
from typing import Callable, Optional

from backend.models.server import RoutingRule, Server, Settings, StatusInfo


LogEntry = tuple[float, str, str]  # (timestamp, level, message)


@dataclass
class AppState:
    servers: list[Server] = field(default_factory=list)
    rules: list[RoutingRule] = field(default_factory=list)
    settings: Settings = field(default_factory=Settings)
    status: StatusInfo = field(default_factory=StatusInfo)
    pids: dict[str, int] = field(default_factory=dict)
    logs: deque[LogEntry] = field(default_factory=lambda: deque(maxlen=500))
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    status_listeners: list[Callable[[StatusInfo], None]] = field(default_factory=list)
    server_list_listeners: list[Callable[[], None]] = field(default_factory=list)
    log_listeners: list[Callable[[str, str], None]] = field(default_factory=list)

    def get_server(self, server_id: str) -> Optional[Server]:
        for s in self.servers:
            if s.id == server_id:
                return s
        return None

    def emit_status(self) -> None:
        for cb in list(self.status_listeners):
            try:
                cb(self.status)
            except Exception:
                pass

    def emit_server_list(self) -> None:
        for cb in list(self.server_list_listeners):
            try:
                cb()
            except Exception:
                pass

    def emit_log(self, level: str, message: str) -> None:
        import time
        self.logs.append((time.time(), level, message))
        for cb in list(self.log_listeners):
            try:
                cb(level, message)
            except Exception:
                pass
