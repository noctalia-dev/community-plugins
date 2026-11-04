# kitty watcher loaded into the dropkitty panel (kitty_override watcher=...).
# Forwards focus, command-finished and last-window-closed to the helper; never blocks kitty.
import os
import subprocess
from typing import Any

HELPER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dropkitty")


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
    _send("focus", "1" if data.get("focused") else "0")


def on_cmd_startstop(boss: Any, window: Any, data: dict) -> None:
    if not data.get("is_start"):
        _send("cmd", str(data.get("exit_status", 0)))


def on_close(boss: Any, window: Any, data: dict) -> None:
    if not any(w.id != window.id for w in boss.all_windows):
        _send("exit")
