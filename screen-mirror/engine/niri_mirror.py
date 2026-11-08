#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""niri-mirror - mirror the main output onto displays that are plugged in later.

------------
----
niri cannot mirror outputs itself (the 26.04 output config has no mirror node,
and mutter's DisplayConfig still says "Mirroring is not yet supported").
So wl-mirror (a wlr-screencopy / ext-image-copy-capture client) renders the source
output into a window, and --fullscreen-output makes that window fullscreen on the
target output: visually a mirror, covering the other windows on that display.

--------------------
--------------
1. pick a source output from `niri msg --json outputs` / `focused-output`;
2. run one fullscreen wl-mirror instance per remaining active output;
3. watch `niri msg event-stream` (niri 26.04 has no OutputsChanged event, a hotplug
   shows up as WorkspacesChanged), plus a periodic poll as a fallback;
4. new display -> start a mirror; unplug -> stop it; source gone -> elect another;
5. on exit stop every child process and reap mirrors left by a previous crash.

-------------------
-----------
The daemon listens on $XDG_RUNTIME_DIR/niri-mirror.sock:

    niri-mirror toggle     # bind this to Win+U: on <-> off, with a toast
    niri-mirror on|off
    niri-mirror status
    niri-mirror quit
    kill -USR1 <daemon>    # same as toggle (alternative binding)

When the daemon is not running, `toggle`/`on` start it (setsid, detached from the terminal).
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
NOTIFY_ID = 910327  # fixed id: repeated toggles replace one toast instead of stacking them
LOG_LEVEL = 1  # 0=errors only 1=normal 2=debug


def log(msg: str, level: int = 1) -> None:
    if LOG_LEVEL >= level:
        stamp = time.strftime("%H:%M:%S")
        print(f"[{stamp}] {msg}", file=sys.stderr, flush=True)


# ─────────────────────────── notifications / OSD ───────────────────────────
# NIRI_MIRROR_NOTIFY = auto (default) | osd | notification | never
#   auto: use the noctalia OSD when available, otherwise fall back to notify-send
#   osd: force the OSD popup (noctalia msg osd-show)
#   notification: use the noctalia notification center (noctalia msg notification-show)
#   never: stay silent
# NIRI_MIRROR_NO_NOTIFY=1 is shorthand for never.


def _run_quiet(cmd: list[str], timeout: float = 5.0) -> bool:
    try:
        return subprocess.run(cmd, timeout=timeout, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL).returncode == 0
    except (OSError, subprocess.TimeoutExpired) as e:
        log(f"running {cmd[0]} failed: {e}", 2)
        return False


def _noctalia() -> str | None:
    return shutil.which("noctalia")


def osd_show(icon: str, text: str) -> bool:
    """noctalia OSD popup: one glyph plus a line of text, gone after a couple of seconds."""
    exe = _noctalia()
    if not exe:
        return False
    return _run_quiet([exe, "msg", "osd-show", icon, text])


def noctalia_notification(summary: str, body: str, icon: str, urgency: str) -> bool:
    """noctalia notification center (keeps history, respects do-not-disturb)."""
    exe = _noctalia()
    if not exe:
        return False
    payload = {"summary": summary, "body": body, "icon": icon, "urgency": urgency}
    if _run_quiet([exe, "msg", "notification-show", json.dumps(payload, ensure_ascii=False)]):
        return True
    # older versions only accept positional arguments
    return _run_quiet([exe, "msg", "notification-show", summary, body])


def notify_send(summary: str, body: str, icon: str, urgency: str, expire_ms: int) -> bool:
    """Fallback outside noctalia (dunst/mako/...): talk to org.freedesktop.Notifications."""
    tool = shutil.which("notify-send")
    if not tool:
        log("no notification tool available, skipping the hint", 2)
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
    """Pick the feedback channel: environment > configured feedback > show_osd."""
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
    """Single entry point for user-facing feedback."""
    mode = FEEDBACK_MODE
    if mode == "never" or os.environ.get("NIRI_MIRROR_NO_NOTIFY") == "1":
        return
    if mode in {"auto", "osd"}:
        if osd_show(icon, osd_text or body or summary):
            return
        log("OSD unavailable, using a notification", 2)
    if mode in {"auto", "notification"}:
        if noctalia_notification(summary, body, icon, urgency):
            return
    notify_send(summary, body, icon, urgency, expire_ms)


def toast_text(status: dict) -> tuple[str, str, str, str]:
    """Turn the state into (summary, body, icon, one-line OSD text)."""
    if not status.get("enabled"):
        return ("Screen mirror off", "External displays are used as independent monitors",
                "screen-share-off", "mirror off")
    source = status.get("source") or "?"
    live = status.get("mirroring") or []
    planned = status.get("targets") or []
    if live:
        targets = ", ".join(sorted(live))
        return ("Screen mirror on", f"{source} -> {targets} (fullscreen mirror)",
                "screen-share", f"mirror on - {source} -> {targets}")
    if planned:
        targets = ", ".join(planned)
        return ("Screen mirror on", f"preparing {source} -> {targets}",
                "screen-share", f"mirror on - preparing {source} -> {targets}")
    return ("Screen mirror on", "waiting for an external display",
            "screen-share", "mirror on - waiting for a display")


# ─────────────────────────── paths ───────────────────────────
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


# The plugin (noctalia screen-mirror) writes exactly this file; keep the keys stable.
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
    """Read the JSON config; missing or broken values fall back to defaults (breakage is logged)."""
    cfg = dict(DEFAULT_CONFIG)
    target = pathlib.Path(path) if path else config_path()
    try:
        raw = target.read_text()
    except FileNotFoundError:
        return cfg
    except OSError as e:
        log(f"reading config {target} failed: {e}", 0)
        return cfg
    if not raw.strip():
        return cfg
    try:
        data = json.loads(raw)
    except ValueError as e:
        log(f"config file {target} is not valid JSON: {e}", 0)
        return cfg
    if isinstance(data, dict):
        for key, value in data.items():
            if key in DEFAULT_CONFIG:
                cfg[key] = value
    return cfg


class InstanceLock:
    """Only one daemon per session."""

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
    """Thin wrapper around `niri msg`. All state is queried live over IPC, never cached."""

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
            raise NiriError(f"executable {self.binary} not found") from e
        except subprocess.TimeoutExpired as e:
            raise NiriError(f"`{' '.join(cmd)}` timed out") from e
        if r.returncode != 0:
            detail = (r.stderr or r.stdout).strip()
            raise NiriError(detail or f"`{' '.join(cmd)}` returned {r.returncode}")
        return r.stdout

    def _json(self, *args: str, default):
        out = self._run(*args, want_json=True).strip()
        if not out:
            return default
        try:
            return json.loads(out)
        except ValueError as e:
            raise NiriError(f"cannot parse the JSON of `niri msg {' '.join(args)}`: {e}") from e

    def outputs(self) -> dict[str, dict]:
        return self._json("outputs", default={})

    def workspaces(self) -> list[dict]:
        return self._json("workspaces", default=[])

    def windows(self) -> list[dict]:
        return self._json("windows", default=[])

    def focused_output(self) -> str | None:
        """Name of the focused output; None when niri does not support it (not an error)."""
        try:
            out = self._run("focused-output", want_json=True).strip()
            return json.loads(out).get("name") if out else None
        except (NiriError, ValueError):
            return None

    def action(self, *args: str) -> None:
        try:
            self._run("action", *args, want_json=False)
        except NiriError as e:
            log(f"niri action {' '.join(args)} failed: {e}", 0)


class Waker:
    """Wake the main loop through a socketpair.

    The event stream thread pokes it; signals write into it via signal.set_wakeup_fd.
    queue.get(timeout=N) would delay SIGTERM by up to N seconds, a file descriptor reacts at once.
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
        """Wait at most timeout seconds; True when something woke us up."""
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
    """Read `niri msg event-stream` and queue events that may change the output set.

    niri 26.04 has no OutputsChanged event: plugging or unplugging a display shows up as
    WorkspacesChanged (a new output arrives with a fresh group of workspaces). Any relevant
    event triggers a reconcile without parsing the payload - state is always re-queried.
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
                log(f"starting the event stream failed: {e}", 0)
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
                log("event stream closed, reconnecting in 1s", 2)
                self._stop.wait(1.0)


# ─────────────────────────── mirror management ───────────────────────────
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
        self.lock = threading.RLock()  # shared by the main loop, the control socket and signals
        self._last_state_json = ""

    # ── source output selection ──────────────────────────────────────────
    def choose_source(self, active: list[str]) -> str | None:
        if not active:
            return None
        if self.opts.source != "auto":
            resolved = self.resolve_output(self.opts.source, active)
            if resolved:
                if resolved != self.opts.source:
                    log(f"source output \"{self.opts.source}\" matched {resolved}", 2)
                return resolved
            self.warn_unknown([self.opts.source], active, "mirror source display")
            log(f"configured source output {self.opts.source} is not available, using auto selection for now", 0)
        # once chosen, the source sticks so a focus change cannot restart the mirrors
        if self.source in active:
            return self.source
        if self.source is not None:
            log(f"source output {self.source} disappeared, electing a new one", 0)
        focused = self.niri.focused_output()
        self.source = focused if focused in active else active[0]
        log(f"source output = {self.source}")
        return self.source

    @staticmethod
    def resolve_output(configured: str, active: list[str]) -> str | None:
        """Map a configured name to a real connector: exact -> case-insensitive -> unique substring."""
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
        """List the connectors that are actually present when a name matches nothing (once per group)."""
        if not unknown or not active:
            return
        key = kind + ":" + ",".join(sorted(unknown))
        if key in self.warned_unknown:
            return
        self.warned_unknown.add(key)
        names = ", ".join(sorted(active))
        log(f"{kind}: cannot match {', '.join(unknown)}; available: {names}", 0)
        report(
            f"{kind} contains an unknown display",
            f"{', '.join(unknown)} does not match any connected display; available: {names}",
            icon="alert-triangle",
            osd_text=f"no match for {'/'.join(unknown)} - available {names}",
        )

    def planned_targets(self, active: list[str], source: str | None) -> list[str]:
        if source is None:
            return []
        excluded, unknown = self.resolve_names(self.opts.exclude, active)
        self.warn_unknown(unknown, active, "excluded display")
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

    # ── public: state ────────────────────────────────────────────
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

    # ── config / state files ───────────────────────────────────────
    def apply_config(self, cfg: dict) -> None:
        """Apply the config to a running instance (used by reload). Does not change on/off state."""
        with self.lock:
            source = cfg.get("source_output") or "auto"
            if source != self.opts.source:
                self.opts.source = source
                self.source = None if source == "auto" else source
                log(f"source output changed to {source}")
            targets = {str(t).strip() for t in (cfg.get("targets") or []) if str(t).strip()}
            exclude = {str(t).strip() for t in (cfg.get("excluded_outputs") or []) if str(t).strip()}
            if exclude != self.opts.exclude:
                log("excluded displays: " + (", ".join(sorted(exclude)) or "(none)"))
            self.opts.targets = targets
            self.opts.exclude = exclude
            scaling = cfg.get("scaling")
            self.opts.scaling = scaling if scaling in {"fit", "cover", "exact"} else None
            self.opts.hide_cursor = bool(cfg.get("hide_cursor", False))
            self.reconcile_locked()

    def write_state(self, status: dict | None = None) -> None:
        """Write the state to $XDG_RUNTIME_DIR/niri-mirror/state.json for the plugin UI."""
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
            # key=value twin of the same state: the plugin (Luau) parses it without a JSON library
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
            log(f"writing the state file failed: {e}", 2)

    # ── public: on/off ───────────────────────────────────────────
    def set_enabled(self, value: bool | None) -> tuple[bool, dict]:
        """value=None toggles. Returns (whether the state changed, the new state)."""
        with self.lock:
            before = self.enabled
            self.enabled = (not before) if value is None else bool(value)
            self.reconcile_locked()
            status = self._status_locked()
            self.write_state(status)
            return self.enabled != before, status

    # ── main loop ────────────────────────────────────────────────
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
                log("mirroring disabled, stopping every mirror")
                self.stop_all()
            return

        outputs = self.niri.outputs()
        active = [name for name, info in outputs.items() if info.get("logical")]
        source = self.choose_source(active)

        if source is None:
            if self.mirrors:
                log("no active display, stopping every mirror", 0)
                self.stop_all()
            return

        targets = self.planned_targets(active, source)

        # 1) drop the ones we no longer need, or whose source changed
        for target in list(self.mirrors):
            mirror = self.mirrors[target]
            if target not in targets:
                self.stop(target, "target output removed or no longer needed")
                continue
            if mirror.source != source:
                self.stop(target, f"source changed from {mirror.source} to {source}")

        # 2) liveness check with failure backoff
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
            log(f"wl-mirror on {target} exited (code={code}), retrying in {delay:.0f}s ({fails}/inf)", 0)

        # 3) start a mirror for a new display
        for target in targets:
            if target in self.mirrors:
                continue
            if now < self.next_try.get(target, 0.0):
                continue
            self.start(target, source)

    # ── start / stop a single mirror ─────────────────────────────
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
            log(f"[dry-run] would run: {printable}")
            return
        log(f"mirroring {source} -> {target}")
        log(printable, 2)
        focus_before = self.niri.focused_output()
        try:
            proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL)
        except OSError as e:
            log(f"starting wl-mirror failed: {e}", 0)
            fails = self.fail_count.get(target, 0) + 1
            self.fail_count[target] = fails
            self.next_try[target] = time.monotonic() + min(self.opts.retry_max, 2 ** min(fails, 5))
            return
        mirror = Mirror(target=target, source=source, proc=proc)
        self.mirrors[target] = mirror
        # reconcile will not run again while idle, so verify placement with a timer
        threading.Timer(2.0, self._verify_later, args=(mirror,)).start()
        if self.opts.restore_focus and focus_before:
            # the fullscreen request can steal keyboard focus; give it back once the window is mapped
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
                log(f"focus returned to {output}", 2)
        except NiriError:
            pass

    def stop(self, target: str, reason: str = "") -> None:
        mirror = self.mirrors.pop(target, None)
        if not mirror:
            return
        if self.opts.dry_run:
            log(f"[dry-run] would stop the mirror on {target}")
            return
        log(f"stopping the mirror on {target}" + (f" ({reason})" if reason else ""))
        proc = mirror.proc
        if proc.poll() is None:
            try:
                proc.terminate()
                proc.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                log(f"{target}: wl-mirror ignores SIGTERM, killing it", 0)
                proc.kill()
                try:
                    proc.wait(timeout=2.0)
                except subprocess.TimeoutExpired:
                    pass
            except OSError:
                pass

    def stop_all(self) -> None:
        for target in list(self.mirrors):
            self.stop(target, "shutting down")

    # ── post-check: did the mirror window really land on the target display? ──────────
    def verify_placement(self, mirror: Mirror) -> None:
        try:
            windows = self.niri.windows()
            workspaces = {w["id"]: w for w in self.niri.workspaces()}
        except NiriError as e:
            log(f"verifying the window position failed: {e}", 2)
            return
        for win in windows:
            if (win.get("title") or "") != f"{TITLE_PREFIX}{mirror.target}":
                continue
            ws = workspaces.get(win.get("workspace_id"))
            actual = ws.get("output") if ws else None
            if actual != mirror.target and mirror.target not in self.warned_placement:
                self.warned_placement.add(mirror.target)
                log(
                    f"warning: the mirror window is not on {mirror.target} (actual {actual})."
                    f"This niri version may ignore --fullscreen-output.",
                    0,
                )
            return

    # ── reap mirrors left behind by a previous crash ────────────────
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
            log(f"reaping leftover mirror process pid={pid} ({title})", 0)
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


# ─────────────────────────── control socket (for toggle) ───────────────────────────
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
            log(f"cannot create the control socket {self.path}: {e} (toggle will not work)", 0)
            return

        log(f"control socket ready: {self.path}", 2)
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
            except Exception as e:  # the control socket must never take the daemon down
                log(f"handling a control command failed: {e}", 0)
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
                log(f"hint: {summary} / {body}")
                report(summary, body, icon=icon, osd_text=osd)
            return {"ok": True, "changed": changed, **status}
        return {"ok": False, "error": f"unknown command {cmd}"}


# ─────────────────────────── client (niri-mirror toggle) ───────────────────────────
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
    """Start the daemon in its own session (non-blocking, no terminal held)."""
    target = log_path()
    target.parent.mkdir(parents=True, exist_ok=True)
    argv = [sys.executable, os.path.abspath(__file__)]
    if notify_start:
        argv.append("--notify-start")
    argv += ["--log-file", str(target)]
    log(f"daemon not running, starting it: {' '.join(argv)}", 2)
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
        print(f"failed to start the daemon: {e}", file=sys.stderr)
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
        return "off (external displays stay independent)"
    source = status.get("source") or "?"
    if status.get("mirroring"):
        return f"on: {source} -> {', '.join(status['mirroring'])}"
    return f"on: {source} waiting for an external display"


def client_main(cmd: str, cfg: dict | None = None) -> int:
    """Implementation of niri-mirror toggle/on/off/status/quit/ensure/reload."""
    cfg = cfg or {}
    if cmd == "status":
        status = ctl_send("status")
        if status is None:
            print("daemon not running (mirroring off)")
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
                print("daemon startup timed out, check ~/.local/state/niri-mirror/daemon.log",
                      file=sys.stderr)
                return 1
        if not reply.get("ok", False):
            print(f"command failed: {reply.get('error')}", file=sys.stderr)
            return 1
        print(describe_status(reply))
        return 0

    reply = ctl_send(cmd)
    if reply is None:
        # daemon is not running
        if cmd == "quit":
            print("the daemon was not running")
            return 0
        if cmd == "off":
            print(describe_status({"enabled": False}))
            summary, body, icon, osd = toast_text({"enabled": False})
            report(summary, body, icon=icon, osd_text=osd)
            return 0
        if not shutil.which("wl-mirror"):
            msg = "wl-mirror is missing, install it first: sudo pacman -S wl-mirror"
            print(msg, file=sys.stderr)
            report("screen mirroring cannot be enabled", msg, icon="alert-triangle",
                   urgency="critical", expire_ms=6000, osd_text="wl-mirror is missing")
            return 127
        if not spawn_daemon(notify_start=True):
            return 1
        status = wait_for_daemon()
        if status is None:
            print("daemon startup timed out, check ~/.local/state/niri-mirror/daemon.log",
                  file=sys.stderr)
            return 1
        print(describe_status(status))
        return 0

    if not reply.get("ok", False):
        print(f"command failed: {reply.get('error')}", file=sys.stderr)
        return 1
    if reply.get("quitting"):
        print("daemon exited")
        return 0
    print(describe_status(reply))
    return 0


# ─────────────────────────── arguments ───────────────────────────
def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="niri-mirror",
        description="Mirror the main display onto niri outputs that are plugged in later (via wl-mirror).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""Subcommands (they work without a running daemon):
  niri-mirror toggle      # on <-> off (bind this to Win+U), with a toast
  niri-mirror on|off
  niri-mirror status
  niri-mirror quit

Examples:
  niri-mirror                          # daemon: mirror the source onto every other output
  niri-mirror --source eDP-2           # pin the source to the laptop panel
  niri-mirror --once --dry-run         # only print what it would do
  niri-mirror --list-outputs           # list the displays
  NIRI_MIRROR_NO_NOTIFY=1 niri-mirror toggle   # no toast
""",
    )
    p.add_argument("--config", default=None,
                   help="JSON config file (default ~/.config/niri-mirror/config.json)")
    p.add_argument("--source", default=None,
                   help="source output name (default auto: the focused display at startup, then pinned)")
    p.add_argument("--targets", default=None,
                   help="only mirror onto these outputs (comma separated, default every non-source display)")
    p.add_argument("--exclude", default=None,
                   help="outputs that are never mirrored (comma separated; config key excluded_outputs)")
    p.add_argument("--feedback", default=None,
                   choices=["auto", "osd", "notification", "never"],
                   help="feedback channel (default auto: noctalia OSD, then notifications)")
    p.add_argument("--wl-mirror", default="wl-mirror", help="path to the wl-mirror executable")
    p.add_argument("--niri", default="niri", help="path to the niri executable")
    p.add_argument("--scaling", choices=["fit", "cover", "exact"], default=None,
                   help="scaling policy (default: let wl-mirror fit)")
    p.add_argument("--backend", default=None,
                   choices=["auto", "screencopy", "screencopy-dmabuf", "screencopy-shm",
                            "extcopy", "extcopy-dmabuf", "extcopy-shm", "export-dmabuf"],
                   help="capture backend, default auto (usually screencopy/extcopy on niri)")
    p.add_argument("--hide-cursor", action="store_const", const=True, default=None,
                   help="do not draw the cursor in the mirror")
    p.add_argument("--extra-args", default="",
                   help="extra arguments passed to wl-mirror (a string, split like a shell would)")
    p.add_argument("--no-restore-focus", dest="restore_focus", action="store_false",
                   help="do not take keyboard focus back after starting a mirror")
    p.add_argument("--poll-interval", type=float, default=None,
                   help="fallback poll interval in seconds beside events (default 5, config key poll_interval)")
    p.add_argument("--debounce", type=float, default=0.35,
                   help="event debounce window in seconds (default 0.35)")
    p.add_argument("--retry-max", type=float, default=30.0,
                   help="maximum backoff in seconds for a crashed wl-mirror (default 30)")
    p.add_argument("--once", action="store_true", help="sync once and exit (for debugging)")
    p.add_argument("--dry-run", action="store_true", help="only print the commands that would run")
    p.add_argument("--list-outputs", action="store_true", help="list the outputs and exit")
    p.add_argument("--notify-start", action="store_true", help="send a toast after a successful start")
    p.add_argument("--log-file", default=None, help="write the log to a file (for background runs)")
    p.add_argument("-v", "--verbose", action="store_true")
    p.add_argument("-q", "--quiet", action="store_true")

    opts = p.parse_args(argv)
    return finalize_options(opts, load_config(opts.config))


def finalize_options(opts: argparse.Namespace, cfg: dict) -> argparse.Namespace:
    """Values given on the command line win; everything else comes from the config file."""

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

    # subcommands come first (the niri binding is `niri-mirror toggle`)
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
            log(f"cannot read the output list: {e}", 0)
            return 1
        focused = niri.focused_output()
        for name, info in outputs.items():
            logical = info.get("logical")
            mode = info.get("current_mode")
            modes = info.get("modes") or []
            cur = modes[mode] if isinstance(mode, int) and 0 <= mode < len(modes) else None
            desc = (f"{cur['width']}x{cur['height']}@{cur['refresh_rate'] / 1000:g}Hz"
                    if cur else "off/no mode")
            size = f"{logical['width']}x{logical['height']}@{logical['scale']}x" if logical else "-"
            print(f"{'*' if name == focused else ' '} {name:<12} {desc:<22} logical={size}")
        return 0

    if not opts.dry_run and not shutil.which(opts.wl_mirror):
        log(f"{opts.wl_mirror} not found. Install it first: sudo pacman -S wl-mirror"
            "(or use --dry-run to inspect the logic)", 0)
        return 127

    instance_lock = InstanceLock(lock_path())
    if not opts.dry_run:   # dry-run only prints and takes no lock; --once must lock too so no second mirror starts
        if not instance_lock.acquire():
            log("another niri-mirror daemon is already running, this instance exits", 0)
            return 0

    cfg = load_config(opts.config)
    manager = MirrorManager(opts, niri)
    if not opts.dry_run:
        manager.kill_stale()

    def reload_config() -> dict:
        """Reload entry point for the config file: the plugin calls this after writing it."""
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
            log(f"signal {signum} received, exiting...")
        stopping.set()

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGUSR1):
        signal.signal(sig, handle_signal)

    log(f"config: {opts.config or config_path()}"
        + (" (enabled by default)" if manager.enabled else " (off by default, waiting for Win+U)"))
    log("starting: watching niri events, hotplugged displays are mirrored automatically"
        + (" (dry-run)" if opts.dry_run else ""))
    notified_start = False
    try:
        while not stopping.is_set():
            if toggle_requested.is_set():
                toggle_requested.clear()
                changed, status = manager.set_enabled(None)
                if changed:
                    summary, body, icon, osd = toast_text(status)
                    log(f"hint: {summary} / {body}")
                    report(summary, body, icon=icon, osd_text=osd)

            try:
                manager.reconcile()
            except NiriError as e:
                log(f"niri IPC error: {e}", 0)

            if opts.notify_start and not notified_start:
                state = manager.status()
                summary, body, icon, osd = toast_text(state)
                log(f"hint: {summary} / {body}")
                report(summary, body, icon=icon, osd_text=osd)
                notified_start = True

            if opts.once:
                break
            if waker.wait(opts.poll_interval):
                waker.drain()
                if waker.wait(opts.debounce):  # debounce: one hotplug fires several events
                    waker.drain()
    finally:
        if control:
            control.stop()
        manager.stop_all()
        if stream:
            stream.stop()
        signal.set_wakeup_fd(previous_wakeup_fd)
        instance_lock.release()
    log("exited")
    return 0


if __name__ == "__main__":
    sys.exit(main())
