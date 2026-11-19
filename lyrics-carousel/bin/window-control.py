#!/usr/bin/env python3
"""Sends lifecycle signals to the running lyrics window.

Usage: window-control.py <theme|reload|stop>

The PID always comes from the file the window writes itself. The process is
verified through /proc before a signal is sent: a stale PID can belong to an
unrelated process after a reboot, and SIGUSR2/SIGTERM would affect it.
"""

from __future__ import annotations

import os
import signal
import sys

# The plugin directory must stay clean: importing the sibling `paths` module
# would leave a bin/__pycache__ inside the deployed copy.
sys.dont_write_bytecode = True

from paths import pid_path

SIGNALS = {
    "theme": signal.SIGUSR2,
    "reload": signal.SIGUSR1,
    "stop": signal.SIGTERM,
}


def read_pid() -> int | None:
    """PID stored by the running window, or None when no window is open."""
    try:
        with open(pid_path(), encoding="utf-8") as handle:
            value = handle.read().strip()
    except OSError:
        return None
    try:
        pid = int(value)
    except ValueError:
        return None
    return pid if pid > 1 else None


def is_lyrics_process(pid: int) -> bool:
    """True only when /proc still identifies the lyrics window process."""
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as handle:
            parts = [
                part.decode("utf-8", "replace")
                for part in handle.read().split(b"\0")
                if part
            ]
    except OSError:
        return False
    if not parts:
        return False
    return any(
        os.path.basename(part) == "lyrics-carousel"
        or part.endswith("/bin/lyrics-carousel")
        for part in parts
    )


def send(command: str) -> int:
    """Sends one supported signal; success without a window is intentional."""
    signal_number = SIGNALS.get(command)
    if signal_number is None:
        print(f"unknown command: {command}", file=sys.stderr)
        return 2
    pid = read_pid()
    if pid is None:
        return 0
    if not is_lyrics_process(pid):
        return 0
    try:
        os.kill(pid, signal_number)
    except ProcessLookupError:
        return 0
    except OSError as error:
        print(f"could not signal {pid}: {error}", file=sys.stderr)
        return 1
    return 0


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: window-control.py <theme|reload|stop>", file=sys.stderr)
        return 2
    return send(argv[1])


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
