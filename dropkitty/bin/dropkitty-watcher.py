# kitty watcher loaded into the dropkitty panel (kitty_override watcher=...).
# Forwards focus, command-finished (code, seconds, command line) and last-window-closed to
# the helper; never blocks kitty.
import os
import subprocess
from typing import Any

HELPER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dropkitty")
_started: dict = {}  # window id -> monotonic start time of its running command


def _send(*args: str) -> None:
    try:
        subprocess.Popen(
            [HELPER, "_event", *args],
            env={**os.environ, "DROPKITTY_PID": str(os.getpid())},
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError:
        pass


def on_focus_change(boss: Any, window: Any, data: dict) -> None:
    focused = bool(data.get("focused"))
    if not focused:
        try:
            settings = os.path.join(os.environ["XDG_RUNTIME_DIR"], "dropkitty", "settings")
            with open(settings) as stream:
                for line in stream:
                    key, sep, value = line.rstrip("\n").partition("=")
                    if key == "hide_on_focus_loss" and sep:
                        if value == "yes":
                            boss.call_remote_control(window, ("resize-os-window", "--action=hide"))
                        break
        except Exception:
            pass
    _send("focus", "1" if focused else "0")


def on_cmd_startstop(boss: Any, window: Any, data: dict) -> None:
    now = data.get("time", 0.0)
    if data.get("is_start"):
        _started[window.id] = now
        return
    secs = max(0, int(now - _started.pop(window.id, now)))
    _send("cmd", str(data.get("exit_status", 0)), str(secs), data.get("cmdline", ""))


def on_close(boss: Any, window: Any, data: dict) -> None:
    _started.pop(window.id, None)
    if not any(w.id != window.id for w in boss.all_windows):
        _send("exit")
