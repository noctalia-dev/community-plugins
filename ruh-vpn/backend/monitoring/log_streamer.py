"""Tail sing-box log files and forward each new line to a callback.

Each source is polled at a small interval; new bytes are split into complete
lines (partial trailing data is buffered). ANSI escape codes are stripped and
the line's log level is extracted when present (INFO/WARN/WARNING/ERROR/FATAL/
DEBUG/TRACE), defaulting to "info".
"""

from __future__ import annotations

import asyncio
import os
import re
from pathlib import Path
from typing import Awaitable, Callable, Optional

ANSI_RE = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]")
LEVEL_RE = re.compile(
    r"\b(TRACE|DEBUG|INFO|WARN(?:ING)?|ERROR|FATAL|PANIC)\b",
    re.IGNORECASE,
)

LineCallback = Callable[[str, str, str], Awaitable[None]]
# (source_tag, level, message)


class _Source:
    def __init__(self, tag: str, path: Path) -> None:
        self.tag = tag
        self.path = path
        self.fd: Optional[int] = None
        self.buf = b""

    def open(self) -> None:
        if self.fd is not None:
            return
        try:
            fd = os.open(str(self.path), os.O_RDONLY | os.O_NONBLOCK)
        except FileNotFoundError:
            return
        # seek to end so we don't emit historical content
        try:
            os.lseek(fd, 0, os.SEEK_END)
        except OSError:
            pass
        self.fd = fd

    def close(self) -> None:
        if self.fd is not None:
            try:
                os.close(self.fd)
            except OSError:
                pass
            self.fd = None
        self.buf = b""

    def read_lines(self) -> list[bytes]:
        if self.fd is None:
            self.open()
        if self.fd is None:
            return []
        try:
            chunk = os.read(self.fd, 65536)
        except BlockingIOError:
            return []
        except OSError:
            return []
        if not chunk:
            return []
        self.buf += chunk
        out: list[bytes] = []
        while True:
            nl = self.buf.find(b"\n")
            if nl < 0:
                break
            out.append(self.buf[:nl])
            self.buf = self.buf[nl + 1:]
        return out


def parse_level(line: str) -> str:
    m = LEVEL_RE.search(line)
    if not m:
        return "info"
    lvl = m.group(1).lower()
    if lvl == "warning":
        return "warn"
    return lvl


class LogStreamer:
    def __init__(self, callback: LineCallback, poll_interval: float = 0.5) -> None:
        self._cb = callback
        self._interval = poll_interval
        self._sources: dict[str, _Source] = {}
        self._task: Optional[asyncio.Task] = None

    def add_source(self, tag: str, path: Path | str) -> None:
        p = Path(path)
        if tag in self._sources:
            return
        self._sources[tag] = _Source(tag, p)

    def remove_source(self, tag: str) -> None:
        src = self._sources.pop(tag, None)
        if src:
            src.close()

    def clear(self) -> None:
        for src in list(self._sources.values()):
            src.close()
        self._sources.clear()

    def start(self) -> None:
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
        self.clear()

    async def _loop(self) -> None:
        try:
            while True:
                await asyncio.sleep(self._interval)
                for src in list(self._sources.values()):
                    for raw in src.read_lines():
                        clean = ANSI_RE.sub(b"", raw).decode("utf-8", errors="replace").rstrip()
                        if not clean:
                            continue
                        lvl = parse_level(clean)
                        try:
                            await self._cb(src.tag, lvl, clean)
                        except Exception:
                            pass
        except asyncio.CancelledError:
            return
