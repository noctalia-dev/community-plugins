"""State paths of Noctalia used by the plugin.

The settings.toml and the overrides live in the Noctalia state directory.
That directory changes if the user moves the state with
NOCTALIA_STATE_HOME or XDG_STATE_HOME: if the plugin does not honor it, it
would read (and write) the settings of another installation.

This module is used by both the script and the helper: the two pieces
have to look in exactly the same place, otherwise one writes where the
other reads.
"""

from __future__ import annotations

import os

PLUGIN_ID = "faminec/lyrics-carousel"


def state_dir() -> str:
    """The Noctalia state directory (the one containing settings.toml).

    Noctalia uses the state root as if it were the HOME: with
    NOCTALIA_STATE_HOME or XDG_STATE_HOME, settings.toml ends up in
    <root>/noctalia/settings.toml.
    """
    # LYRICS_CAROUSEL_STATE takes precedence over everything else: it is
    # the hook the tests use to point at a temporary directory.
    direct = os.environ.get("LYRICS_CAROUSEL_STATE", "").strip()
    if direct:
        return os.path.expanduser(direct)
    base = (
        os.environ.get("NOCTALIA_STATE_HOME", "").strip()
        or os.environ.get("XDG_STATE_HOME", "").strip()
        or os.path.expanduser("~/.local/state")
    )
    return os.path.join(os.path.expanduser(base), "noctalia")


def settings_path() -> str:
    """Path of the Noctalia settings.toml."""
    return os.path.join(state_dir(), "settings.toml")


def data_dir() -> str:
    """Data directory of the plugin (where overrides.json lives)."""
    return os.path.join(state_dir(), "plugins", "data", *PLUGIN_ID.split("/"))


def pid_path() -> str:
    """Path of the file holding the PID of the open window.

    The panel needs to notify the window when it clears the cache. The
    stored PID is signalled and the process is not looked up by its command
    line: SIGUSR1 kills by default, so a `pkill -f lyrics-carousel` could
    reach an editor that has the file open.
    """
    return os.path.join(data_dir(), "window.pid")


def overrides_path() -> str:
    """Path of the overrides file.

    It can be redirected with LYRICS_CAROUSEL_OVERRIDES (the autotest uses
    it so it does not touch the real state). An empty variable is ignored:
    otherwise the path would be "" and nothing could be read.
    """
    fallback = os.environ.get("LYRICS_CAROUSEL_OVERRIDES", "").strip()
    if fallback:
        return os.path.expanduser(fallback)
    return os.path.join(data_dir(), "overrides.json")
