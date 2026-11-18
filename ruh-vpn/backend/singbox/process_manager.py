"""Async start/stop/monitor of sing-box and ssh transport processes.

All managed processes are tagged via either:
- ssh: <TAG>=1 environment variable
- sing-box: filename pattern <PREFIX>-*.json passed as -c argument

This is intentionally narrow so pkill_zombies can use very specific patterns
and never affect unrelated proxy processes.
"""

from __future__ import annotations

import asyncio
import json
import os
import shutil
import signal
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Awaitable, Callable, Optional

import aiofiles

from backend.identity import PREFIX, TAG
from backend.paths import DATA_DIR, RUNTIME_DIR, SINGBOX_DIR, ensure_private_dir, protect_file

# PATH first so NixOS and other non-FHS layouts work; /usr/bin only as a
# last-resort guess when the backend env has a stripped PATH.
SINGBOX_BIN = shutil.which("sing-box") or "/usr/bin/sing-box"
SSHPASS_BIN = shutil.which("sshpass") or "/usr/bin/sshpass"
SSH_BIN = shutil.which("ssh") or "/usr/bin/ssh"

SINGBOX_CONFIG_DIR = SINGBOX_DIR
LOG_DIR = RUNTIME_DIR
STATE_FILE = LOG_DIR / f"{PREFIX}.state.json"

# Plugin-owned known-hosts: accept-new records a server's key on first connect
# and every later connect verifies it, so a changed key fails loudly instead of
# being silently ignored (the old UserKnownHostsFile=/dev/null behavior).
KNOWN_HOSTS_FILE = DATA_DIR / "known_hosts"

CONFIG_NAMES = {
    "transport": f"{PREFIX}-transport.json",
    "rules": f"{PREFIX}-rules.json",
    "global": f"{PREFIX}-global.json",
    "tun": f"{PREFIX}-tun.json",
}

LOG_NAMES = {
    "transport": f"{PREFIX}-transport.log",
    "rules": f"{PREFIX}-rules.log",
    "global": f"{PREFIX}-global.log",
    "tun": f"{PREFIX}-tun.log",
    "ssh": f"{PREFIX}-ssh.log",
}

# Must only ever match processes started with this plugin's identity.
PKILL_PATTERNS = [
    f"ssh.*{TAG}=1",
    f"sing-box.*{PREFIX}-",
]


@dataclass
class ManagedProc:
    name: str  # one of: transport, rules, global, tun, ssh
    proc: asyncio.subprocess.Process
    cmd: list[str]
    log_path: Path
    started_at: float = field(default_factory=time.time)

    @property
    def pid(self) -> int:
        return self.proc.pid

    def is_running(self) -> bool:
        return self.proc.returncode is None


class ProcessManager:
    def __init__(self, logger: Optional[Callable[[str, str], None]] = None) -> None:
        self._procs: dict[str, ManagedProc] = {}
        self._monitor_task: Optional[asyncio.Task] = None
        self._monitor_cb: Optional[Callable[[str], Awaitable[None]]] = None
        self._log = logger or (lambda level, msg: None)
        ensure_private_dir(SINGBOX_CONFIG_DIR)
        ensure_private_dir(LOG_DIR)

    # ----------------------------------------------------------------- config IO

    async def write_config(self, name: str, config: dict[str, Any]) -> Path:
        if name not in CONFIG_NAMES:
            raise ValueError(f"Unknown sing-box config name: {name}")
        path = SINGBOX_CONFIG_DIR / CONFIG_NAMES[name]
        async with aiofiles.open(path, "w") as f:
            await f.write(json.dumps(config, indent=2))
        protect_file(path)
        return path

    def config_path(self, name: str) -> Path:
        return SINGBOX_CONFIG_DIR / CONFIG_NAMES[name]

    # ----------------------------------------------------------------- launch

    async def start_singbox(self, name: str, binary: Optional[str] = None) -> ManagedProc:
        if name not in CONFIG_NAMES:
            raise ValueError(f"Unknown sing-box config name: {name}")
        if name in self._procs and self._procs[name].is_running():
            raise RuntimeError(f"sing-box '{name}' already running")
        config_path = self.config_path(name)
        if not config_path.exists():
            raise FileNotFoundError(f"Missing config file: {config_path}")
        log_path = LOG_DIR / LOG_NAMES[name]
        log_fh = open(log_path, "ab")  # binary, append; sing-box writes structured text
        protect_file(log_path)
        cmd = [binary or SINGBOX_BIN, "run", "-c", str(config_path), "-D", str(SINGBOX_CONFIG_DIR)]
        self._log("info", f"start sing-box ({name}): {' '.join(cmd)}")
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=log_fh,
            stderr=log_fh,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
        log_fh.close()
        managed = ManagedProc(name=name, proc=proc, cmd=cmd, log_path=log_path)
        self._procs[name] = managed
        return managed

    async def start_ssh(
        self,
        host: str,
        port: int,
        user: str,
        local_port: int,
        password: Optional[str] = None,
        key_file: Optional[str] = None,
    ) -> ManagedProc:
        if "ssh" in self._procs and self._procs["ssh"].is_running():
            raise RuntimeError("ssh transport already running")

        log_path = LOG_DIR / LOG_NAMES["ssh"]
        log_fh = open(log_path, "ab")
        protect_file(log_path)

        KNOWN_HOSTS_FILE.touch(mode=0o600, exist_ok=True)
        protect_file(KNOWN_HOSTS_FILE)

        env = dict(os.environ)
        env[TAG] = "1"

        common_ssh_opts = [
            "-N",
            "-D",
            f"127.0.0.1:{local_port}",
            "-o",
            "ExitOnForwardFailure=yes",
            "-o",
            "ServerAliveInterval=30",
            "-o",
            "ServerAliveCountMax=3",
            "-o",
            "StrictHostKeyChecking=accept-new",
            "-o",
            f"UserKnownHostsFile={KNOWN_HOSTS_FILE}",
            "-o",
            f"SetEnv={TAG}=1",
            "-o",
            f"SendEnv={TAG}",
            "-p",
            str(port),
        ]

        if password:
            cmd = [SSHPASS_BIN, "-e", SSH_BIN, *common_ssh_opts, f"{user}@{host}"]
            env["SSHPASS"] = password
        elif key_file:
            cmd = [SSH_BIN, *common_ssh_opts, "-i", key_file, f"{user}@{host}"]
        else:
            cmd = [SSH_BIN, *common_ssh_opts, f"{user}@{host}"]

        self._log("info", f"start ssh transport to {user}@{host}:{port} -D {local_port}")
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=log_fh,
            stderr=log_fh,
            stdin=subprocess.DEVNULL,
            env=env,
            start_new_session=True,
        )
        log_fh.close()
        managed = ManagedProc(name="ssh", proc=proc, cmd=cmd, log_path=log_path)
        self._procs["ssh"] = managed
        return managed

    # ----------------------------------------------------------------- stop / monitor

    async def stop(self, name: str, timeout: float = 3.0) -> None:
        managed = self._procs.get(name)
        if managed is None:
            return
        if managed.is_running():
            try:
                managed.proc.terminate()
            except ProcessLookupError:
                pass
            try:
                await asyncio.wait_for(managed.proc.wait(), timeout=timeout)
            except asyncio.TimeoutError:
                try:
                    managed.proc.kill()
                    await managed.proc.wait()
                except ProcessLookupError:
                    pass
        self._procs.pop(name, None)

    async def stop_all(self) -> None:
        await asyncio.gather(*(self.stop(n) for n in list(self._procs.keys())))
        await self.pkill_zombies()

    async def pkill_zombies(self) -> None:
        """Kill any leftover processes matching our narrow patterns."""
        for pattern in PKILL_PATTERNS:
            try:
                proc = await asyncio.create_subprocess_exec(
                    "pkill", "-f", pattern,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                await proc.wait()
            except FileNotFoundError:
                return

    # ----------------------------------------------------------------- introspection

    def running_pids(self) -> dict[str, int]:
        return {n: m.pid for n, m in self._procs.items() if m.is_running()}

    def running_names(self) -> list[str]:
        return [n for n, m in self._procs.items() if m.is_running()]

    def is_running(self, name: str) -> bool:
        m = self._procs.get(name)
        return bool(m and m.is_running())

    async def read_log_tail(self, name: str, max_bytes: int = 8192) -> str:
        log_path = LOG_DIR / LOG_NAMES.get(name, "")
        if not log_path.exists():
            return ""
        size = log_path.stat().st_size
        offset = max(0, size - max_bytes)
        async with aiofiles.open(log_path, "rb") as f:
            await f.seek(offset)
            data = await f.read()
        try:
            return data.decode("utf-8", errors="replace")
        except UnicodeDecodeError:
            return data.decode("latin-1", errors="replace")

    # ----------------------------------------------------------------- monitor loop

    def start_monitor(self, on_unexpected_exit: Callable[[str], Awaitable[None]]) -> None:
        self._monitor_cb = on_unexpected_exit
        if self._monitor_task and not self._monitor_task.done():
            return
        self._monitor_task = asyncio.create_task(self._monitor_loop())

    async def stop_monitor(self) -> None:
        if self._monitor_task and not self._monitor_task.done():
            self._monitor_task.cancel()
            try:
                await self._monitor_task
            except asyncio.CancelledError:
                pass
        self._monitor_task = None

    async def _monitor_loop(self) -> None:
        try:
            while True:
                await asyncio.sleep(1.0)
                for name, m in list(self._procs.items()):
                    if not m.is_running():
                        rc = m.proc.returncode
                        self._log("error", f"managed process '{name}' exited rc={rc}")
                        self._procs.pop(name, None)
                        if self._monitor_cb:
                            try:
                                await self._monitor_cb(name)
                            except Exception as exc:
                                self._log("error", f"monitor callback failed: {exc}")
        except asyncio.CancelledError:
            return

    # ----------------------------------------------------------------- state file

    async def write_state(self, state: dict[str, Any]) -> None:
        tmp = STATE_FILE.with_suffix(".json.tmp")
        async with aiofiles.open(tmp, "w") as f:
            await f.write(json.dumps(state, indent=2))
        protect_file(tmp)
        os.replace(tmp, STATE_FILE)

    async def clear_state(self) -> None:
        try:
            STATE_FILE.unlink()
        except FileNotFoundError:
            pass
