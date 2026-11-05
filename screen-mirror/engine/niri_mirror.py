#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""niri-mirror —— 让后插入的显示器自动只显示「主屏的镜像」，并支持一键开关。

原理
----
niri 本身不支持 output mirroring（26.04 的 output 配置没有 mirror 节点，
mutter DisplayConfig 里也写着 "Mirroring is not yet supported"）。
于是这里用 wl-mirror（wlr-screencopy / ext-image-copy-capture 客户端）把源
output 的画面渲染成一个窗口，并用 --fullscreen-output 让它在目标 output 上
全屏 —— 视觉上就是「镜像」，而全屏窗口会盖住该屏其它窗口。

守护进程做的事
--------------
1. 通过 `niri msg --json outputs` / `focused-output` 选出一个「源 output」；
2. 其余活动 output 全部作为「目标」，各跑一个 wl-mirror 全屏实例；
3. 监听 `niri msg event-stream`（niri 26.04 没有 OutputsChanged 事件，
   热插拔表现为 WorkspacesChanged），另加定时轮询兜底；
4. 新屏插入 → 起镜像；拔掉/关闭 → 杀掉对应 wl-mirror；源屏消失 → 重新选举；
5. 退出时清理所有子进程，并回收上次异常退出遗留的镜像窗口。

开关 / 控制
-----------
守护进程在 $XDG_RUNTIME_DIR/niri-mirror.sock 上开控制口：

    niri-mirror toggle     # Win+U 绑这个：开 ↔ 关，并弹 toast 通知
    niri-mirror on|off
    niri-mirror status
    niri-mirror quit
    kill -USR1 <daemon>    # 等效 toggle（备用绑定方式）

守护进程没在跑时，`toggle`/`on` 会自动把它拉起来（setsid 脱离终端）。
"""

from __future__ import annotations

import argparse
import errno
import fcntl
import json
import os
import pathlib
import select
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field

TITLE_PREFIX = "niri-mirror:"
NOTIFY_ID = 910327  # 固定 id，连续开关时替换同一条 toast 而不是堆一叠
LOG_LEVEL = 1  # 0=只报错 1=常规 2=debug


def log(msg: str, level: int = 1) -> None:
    if LOG_LEVEL >= level:
        stamp = time.strftime("%H:%M:%S")
        print(f"[{stamp}] {msg}", file=sys.stderr, flush=True)


# ─────────────────────────── 通知 / OSD ───────────────────────────
# NIRI_MIRROR_NOTIFY = auto(默认) | osd | notification | never
#   auto: 有 noctalia 就用它的 OSD 弹窗，否则退回 notify-send
#   osd:  强制 OSD 弹窗（noctalia msg osd-show）
#   notification: 走 noctalia 通知中心（noctalia msg notification-show）
#   never: 静音
# NIRI_MIRROR_NO_NOTIFY=1 是 never 的快捷写法。


def _run_quiet(cmd: list[str], timeout: float = 5.0) -> bool:
    try:
        return subprocess.run(cmd, timeout=timeout, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL).returncode == 0
    except (OSError, subprocess.TimeoutExpired) as e:
        log(f"调用 {cmd[0]} 失败: {e}", 2)
        return False


def _noctalia() -> str | None:
    return shutil.which("noctalia")


def osd_show(icon: str, text: str) -> bool:
    """noctalia 的 OSD 弹窗：图标 + 一行字，2 秒左右自动消失。"""
    exe = _noctalia()
    if not exe:
        return False
    return _run_quiet([exe, "msg", "osd-show", icon, text])


def noctalia_notification(summary: str, body: str, icon: str, urgency: str) -> bool:
    """noctalia 通知中心（会进历史、受 DND 影响）。"""
    exe = _noctalia()
    if not exe:
        return False
    payload = {"summary": summary, "body": body, "icon": icon, "urgency": urgency}
    if _run_quiet([exe, "msg", "notification-show", json.dumps(payload, ensure_ascii=False)]):
        return True
    # 老版本只认位置参数
    return _run_quiet([exe, "msg", "notification-show", summary, body])


def notify_send(summary: str, body: str, icon: str, urgency: str, expire_ms: int) -> bool:
    """非 noctalia 环境（dunst/mako 等）的兜底：走 org.freedesktop.Notifications。"""
    tool = shutil.which("notify-send")
    if not tool:
        log("没有可用的通知工具，跳过提示", 2)
        return False
    cmd = [tool, "-a", "niri-mirror", "-i", icon, "-u", urgency,
           "-t", str(expire_ms), "-r", str(NOTIFY_ID),
           "-h", "string:x-canonical-private-synchronous:niri-mirror"]
    cmd += [summary]
    if body:
        cmd.append(body)
    return _run_quiet(cmd)


FEEDBACK_MODE = "auto"  # auto | osd | notification | never


def set_feedback(cfg: dict | None = None) -> None:
    """决定提示渠道：环境变量 > 配置里的 feedback > show_osd 派生。"""
    global FEEDBACK_MODE
    mode = (os.environ.get("NIRI_MIRROR_NOTIFY") or "").lower()
    if mode not in {"auto", "osd", "notification", "never"}:
        cfg = cfg or {}
        mode = str(cfg.get("feedback") or "auto").lower()
        if mode not in {"auto", "osd", "notification", "never"}:
            mode = "auto"
        if cfg.get("show_osd") is False and mode == "auto":
            mode = "never"
    FEEDBACK_MODE = mode


def report(summary: str, body: str = "", *, icon: str = "screen-share",
           urgency: str = "normal", expire_ms: int = 2500,
           osd_text: str | None = None) -> None:
    """统一的用户提示入口。"""
    mode = FEEDBACK_MODE
    if mode == "never" or os.environ.get("NIRI_MIRROR_NO_NOTIFY") == "1":
        return
    if mode in {"auto", "osd"}:
        if osd_show(icon, osd_text or body or summary):
            return
        log("OSD 不可用，改用通知", 2)
    if mode in {"auto", "notification"}:
        if noctalia_notification(summary, body, icon, urgency):
            return
    notify_send(summary, body, icon, urgency, expire_ms)


def toast_text(status: dict) -> tuple[str, str, str, str]:
    """把状态翻译成 (summary, body, icon, osd 一行字)。"""
    if not status.get("enabled"):
        return ("屏幕镜像已关闭", "外接屏将作为独立显示器使用",
                "screen-share-off", "镜像已关闭")
    source = status.get("source") or "?"
    live = status.get("mirroring") or []
    planned = status.get("targets") or []
    if live:
        targets = ", ".join(sorted(live))
        return ("屏幕镜像已开启", f"{source} → {targets}（全屏镜像）",
                "screen-share", f"镜像已开启 · {source} → {targets}")
    if planned:
        targets = ", ".join(planned)
        return ("屏幕镜像已开启", f"准备镜像 {source} → {targets}",
                "screen-share", f"镜像已开启 · 准备 {source} → {targets}")
    return ("屏幕镜像已开启", "等待外接显示器接入",
            "screen-share", "镜像已开启 · 等待外接屏")


# ─────────────────────────── 路径 ───────────────────────────
def runtime_dir() -> pathlib.Path:
    base = os.environ.get("XDG_RUNTIME_DIR") or f"/tmp"
    return pathlib.Path(base)


def socket_path() -> pathlib.Path:
    return pathlib.Path(os.environ.get("NIRI_MIRROR_SOCKET") or (runtime_dir() / "niri-mirror.sock"))


def lock_path() -> pathlib.Path:
    return runtime_dir() / "niri-mirror.lock"


def log_path() -> pathlib.Path:
    base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return pathlib.Path(base) / "niri-mirror" / "daemon.log"


def config_path() -> pathlib.Path:
    override = os.environ.get("NIRI_MIRROR_CONFIG")
    if override:
        return pathlib.Path(override)
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return pathlib.Path(base) / "niri-mirror" / "config.json"


def state_path() -> pathlib.Path:
    return runtime_dir() / "niri-mirror" / "state.json"


# 插件（noctalia screen-mirror）写的就是这个文件；键名保持稳定。
DEFAULT_CONFIG: dict = {
    "enabled_on_start": True,
    "show_osd": True,
    "feedback": "auto",
    "source_output": "auto",
    "targets": [],
    "excluded_outputs": [],
    "scaling": None,
    "hide_cursor": False,
    "poll_interval": 5.0,
}


def load_config(path: pathlib.Path | str | None = None) -> dict:
    """读 JSON 配置；缺失/损坏都退回默认值（损坏会记一条错误日志）。"""
    cfg = dict(DEFAULT_CONFIG)
    target = pathlib.Path(path) if path else config_path()
    try:
        raw = target.read_text()
    except FileNotFoundError:
        return cfg
    except OSError as e:
        log(f"读取配置 {target} 失败: {e}", 0)
        return cfg
    if not raw.strip():
        return cfg
    try:
        data = json.loads(raw)
    except ValueError as e:
        log(f"配置文件 {target} 不是合法 JSON: {e}", 0)
        return cfg
    if isinstance(data, dict):
        for key, value in data.items():
            if key in DEFAULT_CONFIG:
                cfg[key] = value
    return cfg


class InstanceLock:
    """同一 session 只允许一个守护进程。"""

    def __init__(self, path: pathlib.Path):
        self.path = path
        self.fh = None

    def acquire(self) -> bool:
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.fh = open(self.path, "w")
            fcntl.flock(self.fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.fh.write(str(os.getpid()))
            self.fh.flush()
            return True
        except OSError:
            if self.fh:
                self.fh.close()
                self.fh = None
            return False

    def release(self) -> None:
        if self.fh:
            try:
                fcntl.flock(self.fh.fileno(), fcntl.LOCK_UN)
                self.fh.close()
            except OSError:
                pass
            self.fh = None


# ─────────────────────────── niri IPC ───────────────────────────
class NiriError(RuntimeError):
    pass


class Niri:
    """对 `niri msg` 的薄封装。所有状态都从 IPC 实时查询，不缓存。"""

    def __init__(self, binary: str = "niri", timeout: float = 5.0):
        self.binary = binary
        self.timeout = timeout

    def _run(self, *args: str, want_json: bool) -> str:
        cmd = [self.binary, "msg"]
        if want_json:
            cmd.append("--json")
        cmd.extend(args)
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=self.timeout)
        except FileNotFoundError as e:
            raise NiriError(f"找不到可执行文件 {self.binary}") from e
        except subprocess.TimeoutExpired as e:
            raise NiriError(f"`{' '.join(cmd)}` 超时") from e
        if r.returncode != 0:
            detail = (r.stderr or r.stdout).strip()
            raise NiriError(detail or f"`{' '.join(cmd)}` 返回 {r.returncode}")
        return r.stdout

    def _json(self, *args: str, default):
        out = self._run(*args, want_json=True).strip()
        if not out:
            return default
        try:
            return json.loads(out)
        except ValueError as e:
            raise NiriError(f"无法解析 `niri msg {' '.join(args)}` 的 JSON: {e}") from e

    def outputs(self) -> dict[str, dict]:
        return self._json("outputs", default={})

    def workspaces(self) -> list[dict]:
        return self._json("workspaces", default=[])

    def windows(self) -> list[dict]:
        return self._json("windows", default=[])

    def focused_output(self) -> str | None:
        """当前聚焦的 output 名字；niri 不支持时返回 None（不是错误）。"""
        try:
            out = self._run("focused-output", want_json=True).strip()
            return json.loads(out).get("name") if out else None
        except (NiriError, ValueError):
            return None

    def action(self, *args: str) -> None:
        try:
            self._run("action", *args, want_json=False)
        except NiriError as e:
            log(f"niri action {' '.join(args)} 失败: {e}", 0)


class Waker:
    """用 socketpair 唤醒主循环。

    niri 事件由 EventStream 线程 poke()；信号由 signal.set_wakeup_fd 直接写进来。
    用 queue.get(timeout=N) 的话 SIGTERM 要等满 N 秒才会被处理，改用 fd 就能立刻响应。
    """

    def __init__(self) -> None:
        self.r, self.w = socket.socketpair()
        self.r.setblocking(False)
        self.w.setblocking(False)

    def fileno(self) -> int:
        return self.w.fileno()

    def poke(self) -> None:
        try:
            self.w.send(b"e")
        except OSError:
            pass

    def wait(self, timeout: float) -> bool:
        """最多等 timeout 秒；有任何唤醒返回 True。"""
        try:
            ready, _, _ = select.select([self.r], [], [], timeout)
        except (InterruptedError, OSError):
            return True
        return bool(ready)

    def drain(self) -> None:
        while True:
            try:
                if not self.r.recv(65536):
                    return
            except (BlockingIOError, InterruptedError):
                return
            except OSError:
                return


class EventStream(threading.Thread):
    """读 `niri msg event-stream`，把「可能与 output 集合有关」的事件丢进队列。

    niri 26.04 没有 OutputsChanged 事件：插入/拔掉显示器时它表现为
    WorkspacesChanged（新 output 会带一组新 workspace）。所以这里只要收到
    相关事件就触发一次 reconcile，不去解析具体 payload —— 状态永远重新查询。
    """

    INTERESTING = {
        "WorkspacesChanged",
        "WorkspaceActivated",
        "WindowsChanged",
        "WindowOpenedOrChanged",
        "WindowClosed",
        "ConfigLoaded",
    }

    def __init__(self, niri: Niri, waker: "Waker"):
        super().__init__(name="niri-event-stream", daemon=True)
        self.niri = niri
        self.waker = waker
        self._stop = threading.Event()
        self._proc: subprocess.Popen | None = None

    def stop(self) -> None:
        self._stop.set()
        proc = self._proc
        if proc and proc.poll() is None:
            try:
                proc.terminate()
            except OSError:
                pass

    def run(self) -> None:
        while not self._stop.is_set():
            try:
                self._proc = subprocess.Popen(
                    [self.niri.binary, "msg", "event-stream"],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    text=True,
                    bufsize=1,
                )
            except OSError as e:
                log(f"启动 event-stream 失败: {e}", 0)
                self._stop.wait(3.0)
                continue

            proc = self._proc
            assert proc.stdout is not None
            try:
                for line in proc.stdout:
                    if self._stop.is_set():
                        break
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        event = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(event, dict) and self.INTERESTING.intersection(event):
                        self.waker.poke()
            except (OSError, ValueError):
                pass
            finally:
                if proc.poll() is None:
                    try:
                        proc.terminate()
                        proc.wait(timeout=2)
                    except (OSError, subprocess.TimeoutExpired):
                        proc.kill()
            if not self._stop.is_set():
                log("event-stream 断开，1s 后重连", 2)
                self._stop.wait(1.0)


# ─────────────────────────── 镜像管理 ───────────────────────────
@dataclass
class Mirror:
    target: str
    source: str
    proc: subprocess.Popen
    started: float = field(default_factory=time.monotonic)
    verified: bool = False


class MirrorManager:
    def __init__(self, opts: argparse.Namespace, niri: Niri):
        self.opts = opts
        self.niri = niri
        self.mirrors: dict[str, Mirror] = {}
        self.fail_count: dict[str, int] = {}
        self.next_try: dict[str, float] = {}
        self.source: str | None = opts.source if opts.source != "auto" else None
        self.warned_placement: set[str] = set()
        self.warned_unknown: set[str] = set()
        self.enabled = bool(getattr(opts, "enabled_on_start", True))
        self.lock = threading.RLock()  # 主循环 / 控制口 / 信号 共用
        self._last_state_json = ""

    # ── 选择源 output ──────────────────────────────────────────
    def choose_source(self, active: list[str]) -> str | None:
        if not active:
            return None
        if self.opts.source != "auto":
            resolved = self.resolve_output(self.opts.source, active)
            if resolved:
                if resolved != self.opts.source:
                    log(f"源 output \"{self.opts.source}\" 匹配到 {resolved}", 2)
                return resolved
            self.warn_unknown([self.opts.source], active, "镜像源显示器")
            log(f"指定的源 output {self.opts.source} 当前不可用，临时改用自动选择", 0)
        # 源一旦选定就粘住，避免焦点跳动导致镜像来回重开
        if self.source in active:
            return self.source
        if self.source is not None:
            log(f"源 output {self.source} 已消失，重新选举", 0)
        focused = self.niri.focused_output()
        self.source = focused if focused in active else active[0]
        log(f"源 output = {self.source}")
        return self.source

    @staticmethod
    def resolve_output(configured: str, active: list[str]) -> str | None:
        """把配置里写的名字对到真实连接名：精确 → 忽略大小写 → 唯一子串。"""
        name = (configured or "").strip()
        if not name:
            return None
        if name in active:
            return name
        lowered = name.lower()
        for candidate in active:
            if candidate.lower() == lowered:
                return candidate
        partial = [c for c in active if lowered in c.lower()]
        if len(partial) == 1:
            return partial[0]
        return None

    def resolve_names(self, names, active: list[str]) -> tuple[set[str], list[str]]:
        resolved: set[str] = set()
        unknown: list[str] = []
        for name in names:
            match = self.resolve_output(name, active)
            if match:
                resolved.add(match)
            else:
                unknown.append(str(name))
        return resolved, unknown

    def warn_unknown(self, unknown: list[str], active: list[str], kind: str) -> None:
        """有写错/没接的显示器名时，把当前可用的连接名列出来（同一组只提示一次）。"""
        if not unknown or not active:
            return
        key = kind + ":" + ",".join(sorted(unknown))
        if key in self.warned_unknown:
            return
        self.warned_unknown.add(key)
        names = ", ".join(sorted(active))
        log(f"{kind}: 无法匹配 {', '.join(unknown)}；当前可用: {names}", 0)
        report(
            f"{kind}里有无法识别的显示器",
            f"{', '.join(unknown)} 不匹配任何已连接的显示器；可用: {names}",
            icon="alert-triangle",
            osd_text=f"未找到 {'/'.join(unknown)} · 可用 {names}",
        )

    def planned_targets(self, active: list[str], source: str | None) -> list[str]:
        if source is None:
            return []
        excluded, unknown = self.resolve_names(self.opts.exclude, active)
        self.warn_unknown(unknown, active, "排除的显示器")
        allowed, unknown_targets = self.resolve_names(self.opts.targets, active)
        if self.opts.targets:
            self.warn_unknown(unknown_targets, active, "targets")
        return [
            name
            for name in active
            if name != source
            and name not in excluded
            and (not self.opts.targets or name in allowed)
        ]

    # ── 对外：状态 ────────────────────────────────────────────
    def status(self) -> dict:
        with self.lock:
            return self._status_locked()

    def _status_locked(self) -> dict:
        try:
            outputs = self.niri.outputs()
            active = [name for name, info in outputs.items() if info.get("logical")]
            focused = self.niri.focused_output()
        except NiriError as e:
            return {"enabled": self.enabled, "error": str(e),
                    "outputs": [], "targets": [], "mirroring": [],
                    "source": self.source, "focused": None}
        source = self.opts.source if self.opts.source in active else self.source
        planned = self.planned_targets(active, source if source in active else None)
        return {
            "enabled": self.enabled,
            "source": source if source in active else None,
            "focused": focused,
            "outputs": active,
            "targets": planned,
            "mirroring": sorted(self.mirrors),
        }

    # ── 配置 / 状态文件 ───────────────────────────────────────
    def apply_config(self, cfg: dict) -> None:
        """把配置应用到运行中的实例（reload 用）。不改变当前开关状态。"""
        with self.lock:
            source = cfg.get("source_output") or "auto"
            if source != self.opts.source:
                self.opts.source = source
                self.source = None if source == "auto" else source
                log(f"源 output 改为 {source}")
            targets = {str(t).strip() for t in (cfg.get("targets") or []) if str(t).strip()}
            exclude = {str(t).strip() for t in (cfg.get("excluded_outputs") or []) if str(t).strip()}
            if exclude != self.opts.exclude:
                log("排除的显示器: " + (", ".join(sorted(exclude)) or "（无）"))
            self.opts.targets = targets
            self.opts.exclude = exclude
            scaling = cfg.get("scaling")
            self.opts.scaling = scaling if scaling in {"fit", "cover", "exact"} else None
            self.opts.hide_cursor = bool(cfg.get("hide_cursor", False))
            self.reconcile_locked()

    def write_state(self, status: dict | None = None) -> None:
        """把状态落到 $XDG_RUNTIME_DIR/niri-mirror/state.json，给插件 UI 读。"""
        if self.opts.dry_run:
            return
        st = status if status is not None else self._status_locked()
        payload = dict(st)
        payload["updated"] = time.time()
        text = json.dumps(payload, ensure_ascii=False, sort_keys=True)
        if text == self._last_state_json:
            return
        self._last_state_json = text
        try:
            path = state_path()
            path.parent.mkdir(parents=True, exist_ok=True)
            tmp = path.with_name("state.json.tmp")
            tmp.write_text(text)
            os.replace(tmp, path)
            # 同一份状态的 key=value 版本：插件脚本（Luau）解析起来不用 JSON 库
            kv = state_path().with_name("state")
            kv_tmp = kv.with_name("state.tmp")
            kv_tmp.write_text("\n".join([
                f"enabled={1 if payload.get('enabled') else 0}",
                f"source={payload.get('source') or ''}",
                f"focused={payload.get('focused') or ''}",
                f"outputs={','.join(payload.get('outputs') or [])}",
                f"targets={','.join(payload.get('targets') or [])}",
                f"mirroring={','.join(payload.get('mirroring') or [])}",
                f"updated={int(payload.get('updated', 0))}",
                "",
            ]))
            os.replace(kv_tmp, kv)
        except OSError as e:
            log(f"写状态文件失败: {e}", 2)

    # ── 对外：开/关 ───────────────────────────────────────────
    def set_enabled(self, value: bool | None) -> tuple[bool, dict]:
        """value=None 表示切换。返回 (状态是否变化, 最新状态)。"""
        with self.lock:
            before = self.enabled
            self.enabled = (not before) if value is None else bool(value)
            self.reconcile_locked()
            status = self._status_locked()
            self.write_state(status)
            return self.enabled != before, status

    # ── 主流程 ────────────────────────────────────────────────
    def reconcile(self) -> None:
        with self.lock:
            self.reconcile_locked()
            self.write_state()

    def reconcile_locked(self) -> None:
        try:
            self._reconcile_locked()
        finally:
            self.write_state()

    def _reconcile_locked(self) -> None:
        if not self.enabled:
            if self.mirrors:
                log("镜像功能已关闭，清理所有镜像")
                self.stop_all()
            return

        outputs = self.niri.outputs()
        active = [name for name, info in outputs.items() if info.get("logical")]
        source = self.choose_source(active)

        if source is None:
            if self.mirrors:
                log("当前没有任何活动显示器，清理所有镜像", 0)
                self.stop_all()
            return

        targets = self.planned_targets(active, source)

        # 1) 收掉不再需要的 / 源变了的
        for target in list(self.mirrors):
            mirror = self.mirrors[target]
            if target not in targets:
                self.stop(target, "目标 output 已移除或不再需要")
                continue
            if mirror.source != source:
                self.stop(target, f"源已从 {mirror.source} 换成 {source}")

        # 2) 存活检查 + 失败退避
        now = time.monotonic()
        for target in list(self.mirrors):
            mirror = self.mirrors[target]
            code = mirror.proc.poll()
            if code is None:
                if mirror.verified and now - mirror.started > 6.0:
                    self.fail_count.pop(target, None)
                continue
            self.mirrors.pop(target)
            fails = self.fail_count.get(target, 0) + 1
            self.fail_count[target] = fails
            delay = min(self.opts.retry_max, 2 ** min(fails, 5))
            self.next_try[target] = now + delay
            log(f"{target} 上的 wl-mirror 退出 (code={code})，{delay:.0f}s 后重试 ({fails}/∞)", 0)

        # 3) 为新屏起镜像
        for target in targets:
            if target in self.mirrors:
                continue
            if now < self.next_try.get(target, 0.0):
                continue
            self.start(target, source)

    # ── 起/停单个镜像 ─────────────────────────────────────────
    def build_command(self, target: str, source: str) -> list[str]:
        cmd = [
            self.opts.wl_mirror,
            "--fullscreen-output",
            target,
            "--title",
            f"{TITLE_PREFIX}{target}",
        ]
        if self.opts.hide_cursor:
            cmd.append("--no-show-cursor")
        if self.opts.scaling:
            cmd.extend(["--scaling", self.opts.scaling])
        if self.opts.backend:
            cmd.extend(["--backend", self.opts.backend])
        if self.opts.extra_args:
            cmd.extend(shlex.split(self.opts.extra_args))
        cmd.append(source)
        return cmd

    def start(self, target: str, source: str) -> None:
        cmd = self.build_command(target, source)
        printable = " ".join(shlex.quote(c) for c in cmd)
        if self.opts.dry_run:
            log(f"[dry-run] 会执行: {printable}")
            return
        log(f"镜像 {source} → {target}")
        log(printable, 2)
        focus_before = self.niri.focused_output()
        try:
            proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL)
        except OSError as e:
            log(f"启动 wl-mirror 失败: {e}", 0)
            fails = self.fail_count.get(target, 0) + 1
            self.fail_count[target] = fails
            self.next_try[target] = time.monotonic() + min(self.opts.retry_max, 2 ** min(fails, 5))
            return
        mirror = Mirror(target=target, source=source, proc=proc)
        self.mirrors[target] = mirror
        # 空转时 reconcile 不会再来，用定时器做一次落位校验
        threading.Timer(2.0, self._verify_later, args=(mirror,)).start()
        if self.opts.restore_focus and focus_before:
            # 全屏请求可能把键盘焦点顺走，等窗口映射后还回去
            threading.Timer(0.4, self._restore_focus, args=(focus_before,)).start()

    def _verify_later(self, mirror: Mirror) -> None:
        with self.lock:
            if self.mirrors.get(mirror.target) is not mirror or mirror.verified:
                return
            mirror.verified = True
            self.verify_placement(mirror)

    def _restore_focus(self, output: str) -> None:
        try:
            if self.niri.focused_output() != output:
                self.niri.action("focus-monitor", output)
                log(f"焦点已归还给 {output}", 2)
        except NiriError:
            pass

    def stop(self, target: str, reason: str = "") -> None:
        mirror = self.mirrors.pop(target, None)
        if not mirror:
            return
        if self.opts.dry_run:
            log(f"[dry-run] 会结束 {target} 上的镜像")
            return
        log(f"结束 {target} 上的镜像" + (f"（{reason}）" if reason else ""))
        proc = mirror.proc
        if proc.poll() is None:
            try:
                proc.terminate()
                proc.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                log(f"{target}: wl-mirror 不响应 SIGTERM，强杀", 0)
                proc.kill()
                try:
                    proc.wait(timeout=2.0)
                except subprocess.TimeoutExpired:
                    pass
            except OSError:
                pass

    def stop_all(self) -> None:
        for target in list(self.mirrors):
            self.stop(target, "退出")

    # ── 事后校验：镜像窗口是不是真的落在目标屏上 ──────────────
    def verify_placement(self, mirror: Mirror) -> None:
        try:
            windows = self.niri.windows()
            workspaces = {w["id"]: w for w in self.niri.workspaces()}
        except NiriError as e:
            log(f"校验窗口位置失败: {e}", 2)
            return
        for win in windows:
            if (win.get("title") or "") != f"{TITLE_PREFIX}{mirror.target}":
                continue
            ws = workspaces.get(win.get("workspace_id"))
            actual = ws.get("output") if ws else None
            if actual != mirror.target and mirror.target not in self.warned_placement:
                self.warned_placement.add(mirror.target)
                log(
                    f"警告: 镜像窗口没有落在 {mirror.target}（实际 {actual}）。"
                    f"该 niri 版本可能不认 --fullscreen-output。",
                    0,
                )
            return

    # ── 清理上次异常退出的残留 ────────────────────────────────
    def kill_stale(self) -> None:
        if self.opts.dry_run:
            return
        try:
            windows = self.niri.windows()
        except NiriError:
            return
        for win in windows:
            title = win.get("title") or ""
            if not title.startswith(TITLE_PREFIX):
                continue
            pid = win.get("pid")
            if not pid or not self._looks_like_wl_mirror(pid):
                continue
            log(f"清理残留镜像进程 pid={pid} ({title})", 0)
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass

    @staticmethod
    def _looks_like_wl_mirror(pid: int) -> bool:
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as fh:
                return b"wl-mirror" in fh.read()
        except OSError:
            return False


# ─────────────────────────── 控制口（toggle 用） ───────────────────────────
class ControlServer(threading.Thread):
    def __init__(self, manager: MirrorManager, path: pathlib.Path, request_stop,
                 waker: "Waker | None" = None, reload_config=None):
        super().__init__(name="niri-mirror-control", daemon=True)
        self.manager = manager
        self.path = path
        self.request_stop = request_stop
        self.waker = waker
        self.reload_config = reload_config
        self._stop = threading.Event()
        self._srv: socket.socket | None = None

    def run(self) -> None:
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            if self.path.exists():
                self.path.unlink()
            srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            srv.bind(str(self.path))
            os.chmod(self.path, 0o600)
            srv.listen(8)
            srv.settimeout(0.5)
            self._srv = srv
        except OSError as e:
            log(f"无法创建控制 socket {self.path}: {e}（toggle 将不可用）", 0)
            return

        log(f"控制口就绪: {self.path}", 2)
        while not self._stop.is_set():
            try:
                conn, _ = srv.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            threading.Thread(target=self._serve, args=(conn,), daemon=True).start()
        try:
            srv.close()
        except OSError:
            pass
        try:
            self.path.unlink()
        except OSError:
            pass

    def stop(self) -> None:
        self._stop.set()
        srv = self._srv
        if srv:
            try:
                srv.close()
            except OSError:
                pass

    def _serve(self, conn: socket.socket) -> None:
        with conn:
            conn.settimeout(5.0)
            try:
                raw = b""
                while not raw.endswith(b"\n"):
                    chunk = conn.recv(4096)
                    if not chunk:
                        break
                    raw += chunk
                request = json.loads(raw.decode() or "{}")
            except (OSError, ValueError):
                return
            try:
                reply = self._handle(request)
            except Exception as e:  # 控制口不能把守护进程带崩
                log(f"控制命令处理失败: {e}", 0)
                reply = {"ok": False, "error": str(e)}
            try:
                conn.sendall(json.dumps(reply).encode() + b"\n")
            except OSError:
                pass

    def _handle(self, request: dict) -> dict:
        cmd = (request.get("cmd") or "status").lower()
        if cmd == "status":
            return {"ok": True, **self.manager.status()}
        if cmd in {"reload", "ensure"}:
            # `ensure` is implemented by the client as "start me if I am not
            # running"; once we are answering it, the only thing left is a
            # config reconcile. Reporting it as unknown made every `ensure`
            # against a live daemon fail.
            if self.reload_config:
                status = self.reload_config()
            else:
                self.manager.reconcile()
                status = self.manager.status()
            return {"ok": True, **status}
        if cmd == "quit":
            self.request_stop()
            if self.waker:
                self.waker.poke()
            return {"ok": True, "quitting": True}
        if cmd in {"on", "off", "toggle"}:
            changed, status = self.manager.set_enabled(
                None if cmd == "toggle" else cmd == "on"
            )
            if changed:
                summary, body, icon, osd = toast_text(status)
                log(f"提示: {summary} / {body}")
                report(summary, body, icon=icon, osd_text=osd)
            return {"ok": True, "changed": changed, **status}
        return {"ok": False, "error": f"未知命令 {cmd}"}


# ─────────────────────────── 客户端（niri-mirror toggle） ───────────────────────────
def ctl_send(cmd: str, timeout: float = 3.0) -> dict | None:
    path = socket_path()
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect(str(path))
    except OSError:
        return None
    with sock:
        try:
            sock.sendall(json.dumps({"cmd": cmd}).encode() + b"\n")
            raw = b""
            while not raw.endswith(b"\n"):
                chunk = sock.recv(65536)
                if not chunk:
                    break
                raw += chunk
        except OSError:
            return None
    try:
        return json.loads(raw.decode() or "{}")
    except ValueError:
        return None


def spawn_daemon(notify_start: bool) -> bool:
    """把守护进程放到独立 session 里拉起来（不阻塞、不占终端）。"""
    target = log_path()
    target.parent.mkdir(parents=True, exist_ok=True)
    argv = [sys.executable, os.path.abspath(__file__)]
    if notify_start:
        argv.append("--notify-start")
    argv += ["--log-file", str(target)]
    log(f"守护进程未运行，拉起: {' '.join(argv)}", 2)
    try:
        subprocess.Popen(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        return True
    except OSError as e:
        print(f"启动守护进程失败: {e}", file=sys.stderr)
        return False


def wait_for_daemon(timeout: float = 8.0) -> dict | None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        status = ctl_send("status", timeout=1.0)
        if status is not None:
            return status
        time.sleep(0.15)
    return None


def describe_status(status: dict) -> str:
    if not status.get("enabled"):
        return "关闭（外接屏独立显示）"
    source = status.get("source") or "?"
    if status.get("mirroring"):
        return f"开启：{source} → {', '.join(status['mirroring'])}"
    return f"开启：{source} 等待外接屏"


def client_main(cmd: str, cfg: dict | None = None) -> int:
    """niri-mirror toggle/on/off/status/quit/ensure/reload 的实现。"""
    cfg = cfg or {}
    if cmd == "status":
        status = ctl_send("status")
        if status is None:
            print("守护进程未运行（镜像关闭）")
            return 0
        print(describe_status(status))
        return 0

    if cmd in {"ensure", "reload"}:
        reply = ctl_send(cmd)
        if reply is None:
            if not spawn_daemon(notify_start=False):
                return 1
            reply = wait_for_daemon()
            if reply is None:
                print("守护进程启动超时，看一眼 ~/.local/state/niri-mirror/daemon.log",
                      file=sys.stderr)
                return 1
        if not reply.get("ok", False):
            print(f"命令失败: {reply.get('error')}", file=sys.stderr)
            return 1
        print(describe_status(reply))
        return 0

    reply = ctl_send(cmd)
    if reply is None:
        # 守护进程没跑
        if cmd == "quit":
            print("守护进程本来就没在运行")
            return 0
        if cmd == "off":
            print(describe_status({"enabled": False}))
            summary, body, icon, osd = toast_text({"enabled": False})
            report(summary, body, icon=icon, osd_text=osd)
            return 0
        if not shutil.which("wl-mirror"):
            msg = "缺少 wl-mirror，请先运行：sudo pacman -S wl-mirror"
            print(msg, file=sys.stderr)
            report("屏幕镜像无法开启", msg, icon="alert-triangle",
                   urgency="critical", expire_ms=6000, osd_text="缺少 wl-mirror")
            return 127
        if not spawn_daemon(notify_start=True):
            return 1
        status = wait_for_daemon()
        if status is None:
            print("守护进程启动超时，看一眼 ~/.local/state/niri-mirror/daemon.log",
                  file=sys.stderr)
            return 1
        print(describe_status(status))
        return 0

    if not reply.get("ok", False):
        print(f"命令失败: {reply.get('error')}", file=sys.stderr)
        return 1
    if reply.get("quitting"):
        print("守护进程已退出")
        return 0
    print(describe_status(reply))
    return 0


# ─────────────────────────── 参数 ───────────────────────────
def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="niri-mirror",
        description="让后接入的 niri 显示器自动只显示主屏的镜像（基于 wl-mirror）。",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""子命令（不需要常驻运行时也能用）:
  niri-mirror toggle      # 开 ↔ 关（Win+U 绑这个），带 toast 通知
  niri-mirror on|off
  niri-mirror status
  niri-mirror quit

例子:
  niri-mirror                          # 常驻：所有非源屏都镜像源屏
  niri-mirror --source eDP-2           # 固定源为笔记本屏
  niri-mirror --once --dry-run         # 只看它打算做什么，不执行
  niri-mirror --list-outputs           # 列出显示器
  NIRI_MIRROR_NO_NOTIFY=1 niri-mirror toggle   # 不弹通知
""",
    )
    p.add_argument("--config", default=None,
                   help="JSON 配置文件（默认 ~/.config/niri-mirror/config.json）")
    p.add_argument("--source", default=None,
                   help="源 output 名字（默认 auto：启动时聚焦的屏，之后粘住）")
    p.add_argument("--targets", default=None,
                   help="只镜像到这些 output（逗号分隔，默认全部非源屏）")
    p.add_argument("--exclude", default=None,
                   help="永不镜像的 output（逗号分隔；配置键 excluded_outputs）")
    p.add_argument("--feedback", default=None,
                   choices=["auto", "osd", "notification", "never"],
                   help="开关提示渠道（默认 auto：noctalia OSD，其次通知）")
    p.add_argument("--wl-mirror", default="wl-mirror", help="wl-mirror 可执行文件路径")
    p.add_argument("--niri", default="niri", help="niri 可执行文件路径")
    p.add_argument("--scaling", choices=["fit", "cover", "exact"], default=None,
                   help="缩放策略（默认交给 wl-mirror：fit）")
    p.add_argument("--backend", default=None,
                   choices=["auto", "screencopy", "screencopy-dmabuf", "screencopy-shm",
                            "extcopy", "extcopy-dmabuf", "extcopy-shm", "export-dmabuf"],
                   help="捕获后端，默认 auto（niri 上通常走 screencopy/extcopy）")
    p.add_argument("--hide-cursor", action="store_const", const=True, default=None,
                   help="镜像里不画鼠标指针")
    p.add_argument("--extra-args", default="",
                   help="额外传给 wl-mirror 的参数（字符串，按 shell 规则切分）")
    p.add_argument("--no-restore-focus", dest="restore_focus", action="store_false",
                   help="不要在起镜像后把键盘焦点抢回来")
    p.add_argument("--poll-interval", type=float, default=None,
                   help="事件之外的兜底轮询间隔秒数（默认 5，配置键 poll_interval）")
    p.add_argument("--debounce", type=float, default=0.35,
                   help="事件去抖窗口秒数（默认 0.35）")
    p.add_argument("--retry-max", type=float, default=30.0,
                   help="wl-mirror 崩溃重试的最大退避秒数（默认 30）")
    p.add_argument("--once", action="store_true", help="只同步一次就退出（排错用）")
    p.add_argument("--dry-run", action="store_true", help="只打印将执行的命令")
    p.add_argument("--list-outputs", action="store_true", help="列出 output 后退出")
    p.add_argument("--notify-start", action="store_true", help="启动成功后弹一条 toast")
    p.add_argument("--log-file", default=None, help="把日志写到文件（后台运行时用）")
    p.add_argument("-v", "--verbose", action="store_true")
    p.add_argument("-q", "--quiet", action="store_true")

    opts = p.parse_args(argv)
    return finalize_options(opts, load_config(opts.config))


def finalize_options(opts: argparse.Namespace, cfg: dict) -> argparse.Namespace:
    """命令行显式给出的值优先，其余从配置文件补齐。"""

    def pick(attr, key, default):
        value = getattr(opts, attr, None)
        if value is not None:
            return value
        value = cfg.get(key, default)
        return default if value is None else value

    opts.source = str(pick("source", "source_output", "auto")) or "auto"
    raw_targets = pick("targets", "targets", [])
    if isinstance(raw_targets, str):
        raw_targets = raw_targets.split(",")
    opts.targets = {str(t).strip() for t in raw_targets if str(t).strip()}
    raw_exclude = pick("exclude", "excluded_outputs", [])
    if isinstance(raw_exclude, str):
        raw_exclude = raw_exclude.split(",")
    opts.exclude = {str(t).strip() for t in raw_exclude if str(t).strip()}
    opts.scaling = pick("scaling", "scaling", None)
    opts.hide_cursor = bool(pick("hide_cursor", "hide_cursor", False))
    try:
        opts.poll_interval = float(pick("poll_interval", "poll_interval", 5.0))
    except (TypeError, ValueError):
        opts.poll_interval = 5.0
    if opts.poll_interval < 0.2:
        opts.poll_interval = 0.2
    opts.feedback = pick("feedback", "feedback", "auto")
    opts.enabled_on_start = bool(cfg.get("enabled_on_start", True))
    return opts


def main(argv: list[str] | None = None) -> int:
    global LOG_LEVEL
    argv = list(sys.argv[1:] if argv is None else argv)

    # 子命令优先（niri 绑定里就是 `niri-mirror toggle`）
    if argv and argv[0] in {"toggle", "on", "off", "status", "quit", "ensure", "reload"}:
        if "-v" in argv or "--verbose" in argv:
            LOG_LEVEL = 2
        cfg = load_config()
        set_feedback(cfg)
        return client_main(argv[0], cfg)
    if argv and argv[0] in {"help", "-h", "--help"}:
        parse_args(["--help"])
        return 0

    opts = parse_args(argv)
    LOG_LEVEL = 2 if opts.verbose else (0 if opts.quiet else 1)
    set_feedback(load_config(opts.config))

    if opts.log_file:
        path = pathlib.Path(opts.log_file)
        path.parent.mkdir(parents=True, exist_ok=True)
        fh = open(path, "a", buffering=1)
        os.dup2(fh.fileno(), sys.stderr.fileno())
        sys.stderr = fh

    niri = Niri(binary=opts.niri)

    if opts.list_outputs:
        try:
            outputs = niri.outputs()
        except NiriError as e:
            log(f"无法获取 output 列表: {e}", 0)
            return 1
        focused = niri.focused_output()
        for name, info in outputs.items():
            logical = info.get("logical")
            mode = info.get("current_mode")
            modes = info.get("modes") or []
            cur = modes[mode] if isinstance(mode, int) and 0 <= mode < len(modes) else None
            desc = (f"{cur['width']}x{cur['height']}@{cur['refresh_rate'] / 1000:g}Hz"
                    if cur else "关闭/无模式")
            size = f"{logical['width']}x{logical['height']}@{logical['scale']}x" if logical else "-"
            print(f"{'*' if name == focused else ' '} {name:<12} {desc:<22} 逻辑={size}")
        return 0

    if not opts.dry_run and not shutil.which(opts.wl_mirror):
        log(f"找不到 {opts.wl_mirror}。请先安装：sudo pacman -S wl-mirror"
            "（或 --dry-run 只看逻辑）", 0)
        return 127

    instance_lock = InstanceLock(lock_path())
    if not opts.dry_run:   # dry-run 只是打印，不占锁；--once 也要占，免得起第二个镜像
        if not instance_lock.acquire():
            log("已有 niri-mirror 守护进程在运行，本实例退出", 0)
            return 0

    cfg = load_config(opts.config)
    manager = MirrorManager(opts, niri)
    if not opts.dry_run:
        manager.kill_stale()

    def reload_config() -> dict:
        """配置文件的 reload 入口：插件改完配置就调这个。"""
        fresh = load_config(opts.config)
        set_feedback(fresh)
        manager.apply_config(fresh)
        state = manager.status()
        manager.write_state(state)
        return state

    stopping = threading.Event()
    toggle_requested = threading.Event()

    waker = Waker()
    previous_wakeup_fd = signal.set_wakeup_fd(waker.fileno())
    stream = None if opts.once else EventStream(niri, waker)
    if stream:
        stream.start()

    control = None
    if not opts.once:
        control = ControlServer(manager, socket_path(), stopping.set, waker,
                                reload_config=reload_config)
        control.start()

    def handle_signal(signum, _frame):
        if signum == signal.SIGUSR1:
            toggle_requested.set()
            return
        if not stopping.is_set():
            log(f"收到信号 {signum}，退出中…")
        stopping.set()

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGUSR1):
        signal.signal(sig, handle_signal)

    log(f"配置: {opts.config or config_path()}"
        + ("（默认开启）" if manager.enabled else "（默认关闭，等 Win+U）"))
    log("启动：监听 niri 事件，热插拔的显示器会被自动镜像"
        + ("（dry-run）" if opts.dry_run else ""))
    notified_start = False
    try:
        while not stopping.is_set():
            if toggle_requested.is_set():
                toggle_requested.clear()
                changed, status = manager.set_enabled(None)
                if changed:
                    summary, body, icon, osd = toast_text(status)
                    log(f"提示: {summary} / {body}")
                    report(summary, body, icon=icon, osd_text=osd)

            try:
                manager.reconcile()
            except NiriError as e:
                log(f"niri IPC 出错: {e}", 0)

            if opts.notify_start and not notified_start:
                state = manager.status()
                summary, body, icon, osd = toast_text(state)
                log(f"提示: {summary} / {body}")
                report(summary, body, icon=icon, osd_text=osd)
                notified_start = True

            if opts.once:
                break
            if waker.wait(opts.poll_interval):
                waker.drain()
                if waker.wait(opts.debounce):  # 去抖：一次插拔会连发多个事件
                    waker.drain()
    finally:
        if control:
            control.stop()
        manager.stop_all()
        if stream:
            stream.stop()
        signal.set_wakeup_fd(previous_wakeup_fd)
        instance_lock.release()
    log("已退出")
    return 0


if __name__ == "__main__":
    sys.exit(main())
