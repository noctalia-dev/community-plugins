#!/usr/bin/env python3
"""Cider → Noctalia bridge: track metadata, artwork, lyrics (stdout NDJSON)."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import logging
import math
import os
import re
import select
import shutil
import signal
import subprocess
import sys
import threading
import time
import tomllib
import xml.etree.ElementTree as ET
from contextlib import contextmanager
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Callable, Iterator
from urllib.parse import quote, urlparse

_SCRIPTS_DIR = Path(__file__).resolve().parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))
from lyrics_overlay_cfg import display_track_id, restore_word_spacing  # noqa: E402

log = logging.getLogger("cider-bridge")

TrackCallback = Callable[["TrackEvent"], None]

_STATE_DIR = Path.home() / ".cache" / "noctalia-cider"
_EVENT_SEQ = 0
_CIDER_APP_IDS = {"cider", "org.xcider.cider", "Cider"}
_WINDOW_POLL_SEC = 0.1


@dataclass
class TrackEvent:
    type: str  # track | time | state | lyrics | clear | status | art
    title: str = ""
    artist: str = ""
    album: str = ""
    artwork_path: str = ""
    artwork_url: str = ""
    position_ms: int = 0
    duration_ms: int = 0
    playback_state: str = "stopped"
    song_id: str = ""
    catalog_id: str = ""
    isrc: str = ""
    has_lyrics: bool = False
    has_synced: bool = False
    lyrics_lrc: str = ""
    lyrics_lines: list[dict[str, Any]] | None = None
    message: str = ""
    # When True, update state.json metadata but leave position.json alone so the
    # overlay keeps extrapolating from the last real Cider time sample.
    skip_position: bool = False


# Ownership changes and the sidecar publication they protect share this lock.
_EMIT_LOCK = threading.RLock()


def _atomic_write(path: Path, text: str) -> None:
    """Write via a unique temp file — socket + poll threads must not share *.tmp."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.{threading.get_ident()}.{time.time_ns()}.tmp")
    try:
        tmp.write_text(text, encoding="utf-8")
        tmp.replace(path)
    finally:
        try:
            if tmp.exists():
                tmp.unlink()
        except OSError:
            pass


_POS_LOCK = threading.Lock()
_POS_ANCHOR_MS = 0
_POS_ANCHOR_WALL = 0.0
_POS_PLAYING = False
_POS_DURATION_MS = 0
# Clock hygiene for position.json (overlay extrapolates from these anchors).
# Ignore small backwards corrections from both live ticks and polls: consumers
# may already have crossed a lyric boundary by extrapolating the last anchor.
# Live ticks still accept forward seeks; new tracks explicitly reset the clock.
_AHEAD_REJECT_MS = 400
# ponytail: backwards scrubs <1.5s resemble jitter; use explicit seek events if
# Cider exposes them to distinguish scrubs from routine time ticks.
_SEEK_ACCEPT_MS = 1500


def _set_position_anchor(position_ms: int, playing: bool, duration_ms: int = 0) -> None:
    global _POS_ANCHOR_MS, _POS_ANCHOR_WALL, _POS_PLAYING, _POS_DURATION_MS
    with _POS_LOCK:
        _POS_ANCHOR_MS = max(0, int(position_ms))
        _POS_ANCHOR_WALL = time.time()
        _POS_PLAYING = bool(playing)
        if duration_ms:
            _POS_DURATION_MS = max(0, int(duration_ms))


def _estimated_position_ms() -> int:
    with _POS_LOCK:
        base = _POS_ANCHOR_MS
        wall = _POS_ANCHOR_WALL
        playing = _POS_PLAYING
        dur = _POS_DURATION_MS
    if not playing or wall <= 0:
        return base
    elapsed = int((time.time() - wall) * 1000)
    est = base + max(0, elapsed)
    if dur > 0:
        est = min(est, dur)
    return est


def _write_position(
    position_ms: int,
    playing: bool,
    duration_ms: int = 0,
    *,
    trust: bool = False,
    reset: bool = False,
    provider_rewind: bool = False,
) -> None:
    """Write last-known Cider anchor. HUD/Luau extrapolate between ticks.

    trust=True accepts live forward seeks; polls reject forward spikes.
    Routine ticks ignore small backwards jitter. provider_rewind accepts a
    reported native seek; reset=True lets a new track start at any position.
    """
    global _POS_ANCHOR_MS, _POS_ANCHOR_WALL, _POS_PLAYING, _POS_DURATION_MS
    position_ms = max(0, int(position_ms))
    playing = bool(playing)
    duration_ms = max(0, int(duration_ms or 0))

    with _POS_LOCK:
        now = time.time()
        if duration_ms or reset:
            _POS_DURATION_MS = duration_ms
        dur = _POS_DURATION_MS
        if not reset and _POS_ANCHOR_WALL > 0 and (_POS_PLAYING or playing):
            elapsed = max(0, int((now - _POS_ANCHOR_WALL) * 1000)) if _POS_PLAYING else 0
            est = _POS_ANCHOR_MS + elapsed
            if dur > 0:
                est = min(est, dur)
            delta = position_ms - est  # +ahead of clock, -behind
            if playing:
                if not trust and delta > _AHEAD_REJECT_MS:
                    # Spurious forward spike from a poll. Forward seeks arrive on
                    # trusted playbackTimeDidChange ticks instead.
                    return
                rewind = -delta
                if 0 < rewind < _SEEK_ACCEPT_MS and not provider_rewind:
                    # Keep the original anchor/t so jitter cannot reverse lyrics.
                    if _POS_PLAYING:
                        return
                    # Resume from the frozen position even if its tick is stale.
                    position_ms = est
                # rewind >= SEEK_ACCEPT: treat as scrub/seek backward.
            elif delta < 0 and (not trust or (-delta < _SEEK_ACCEPT_MS and not provider_rewind)):
                # Pause with a stale timestamp: freeze at the live estimate.
                position_ms = est

        _POS_ANCHOR_MS = position_ms
        _POS_ANCHOR_WALL = now
        _POS_PLAYING = playing

    payload = {
        "position_ms": position_ms,
        "playing": playing,
        "duration_ms": dur,
        "remaining_ms": max(0, dur - position_ms) if dur else 0,
        "t": now,
    }
    _atomic_write(_STATE_DIR / "position.json", json.dumps(payload, ensure_ascii=False))


def _normalize_app_id(app_id: str | None) -> str:
    aid = (app_id or "").strip()
    if aid.lower().startswith("[xwayland]"):
        aid = aid.split("]", 1)[1].strip()
    return aid


def _is_cider_window(app_id: str | None, title: str | None = None) -> bool:
    aid = _normalize_app_id(app_id)
    if aid in _CIDER_APP_IDS or aid.lower() == "cider":
        return True
    return (title or "").strip().lower() == "cider"


def _empty_window_probe() -> dict[str, Any]:
    return {
        "present": False,
        "focused": False,
        "on_screen": False,
        "suppress_notify": False,
        "compositor": "none",
        "t": time.time(),
    }


def _loft_path() -> Path:
    return _STATE_DIR / "loft.json"


def _read_loft() -> dict[str, Any]:
    path = _loft_path()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def _write_loft(payload: dict[str, Any]) -> None:
    _STATE_DIR.mkdir(parents=True, exist_ok=True)
    _atomic_write(_loft_path(), json.dumps(payload, ensure_ascii=False))


def _remember_workspace() -> bool:
    try:
        config = json.loads((_STATE_DIR / "lyrics_osd_cfg.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False
    return isinstance(config, dict) and config.get("remember_workspace") is True


def _clear_loft() -> None:
    try:
        _loft_path().unlink(missing_ok=True)
    except OSError:
        pass


def _umbriel_output_from_workspace(workspace: str | None) -> str:
    raw = (workspace or "").strip()
    if ":" in raw:
        return raw.split(":", 1)[0]
    return raw


def _umbriel_in_scratchpad(window: dict[str, Any] | None) -> bool:
    """Pad members stay in `windows --json` with an empty workspace."""
    if window is None:
        return True
    return not _umbriel_output_from_workspace(window.get("workspace"))


def _umbriel_peer_output(windows: list[dict[str, Any]]) -> str:
    focused = next((w for w in windows if w.get("active", w.get("focused")) is True), None)
    if focused is not None:
        output = _umbriel_output_from_workspace(focused.get("workspace"))
        if output:
            return output
    for row in windows:
        output = _umbriel_output_from_workspace(row.get("workspace"))
        if output:
            return output
    return ""


def _lofted_window_payload(loft: dict[str, Any]) -> dict[str, Any]:
    payload = _empty_window_probe()
    payload["compositor"] = "umbriel"
    payload["present"] = True
    payload["focused"] = False
    payload["on_screen"] = False
    payload["suppress_notify"] = False
    wid = str(loft.get("id") or "")
    if wid:
        payload["id"] = wid
    output = str(loft.get("output") or "")
    if output:
        payload["output"] = output
    return payload


def _umbriel_windows_json() -> list[dict[str, Any]] | None:
    """Listed Umbriel windows, or None when the compositor query failed."""
    if not shutil.which("umbriel"):
        return None
    try:
        raw = subprocess.check_output(
            ["umbriel", "windows", "--json"],
            stderr=subprocess.DEVNULL,
            timeout=1.5,
        ).decode("utf-8")
        data = json.loads(raw)
    except Exception as exc:
        log.debug("umbriel windows --json failed: %s", exc)
        return None
    if not isinstance(data, list):
        return None
    return [row for row in data if isinstance(row, dict)]


def _umbriel_workspaces_json() -> list[dict[str, Any]] | None:
    try:
        raw = subprocess.check_output(
            ["umbriel", "workspaces", "--json"], stderr=subprocess.DEVNULL, timeout=1.5,
        )
        data = json.loads(raw)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        log.debug("umbriel workspaces --json failed: %s", exc)
        return None
    return [row for row in data if isinstance(row, dict)] if isinstance(data, list) else None


def _select_restore_workspace(workspace: str, send: Callable[[str], bool]) -> bool:
    output, _, name = workspace.partition(":")
    if not output or not name:
        return False
    rows = _umbriel_workspaces_json()
    target = next((row for row in rows or [] if row.get("id") == workspace), None)
    if target is None:
        return False
    if target.get("focused") is True:
        return True
    if not send(f"workspace-switch:{name}/{output}"):
        return False
    return any(row.get("id") == workspace and row.get("focused") is True
               for row in _umbriel_workspaces_json() or [])


def _parse_umbriel_windows(text: str) -> list[tuple[bool, str, str]]:
    """TSV listing leftover for tests; live probe uses JSON."""
    rows: list[tuple[bool, str, str]] = []
    for line in text.splitlines():
        if not line.strip():
            continue
        focused = line.startswith("*")
        rest = line[1:] if focused else line
        rest = rest.lstrip()
        parts = rest.split("\t")
        if len(parts) < 2:
            continue
        rows.append((focused, parts[0].strip(), parts[1].strip()))
    return rows


def _umbriel_on_screen(cider: dict[str, Any], windows: list[dict[str, Any]]) -> bool:
    if cider.get("active", cider.get("focused")) is True:
        return True
    cider_ws = str(cider.get("workspace") or "")
    focused = next((w for w in windows if w.get("active", w.get("focused")) is True), None)
    if focused is None:
        return False
    return cider_ws != "" and cider_ws == str(focused.get("workspace") or "")


def _select_cider_window(
    windows: list[dict[str, Any]], cached_id: str = ""
) -> dict[str, Any] | None:
    cider_windows = [
        w for w in windows if _is_cider_window(w.get("app_id"), w.get("title"))
    ]
    return min(
        cider_windows,
        key=lambda w: (
            str(w.get("title") or "").strip().lower() != "cider - mini player",
            w.get("active", w.get("focused")) is not True,
            str(w.get("id") or "") != cached_id,
            str(w.get("title") or "").strip().lower() != "cider",
            str(w.get("id") or ""),
        ),
        default=None,
    )


def apply_umbriel_listing(windows: list[dict[str, Any]] | None) -> dict[str, Any] | None:
    """Map an Umbriel window list (or query failure) onto window.json + loft latch."""
    loft = _read_loft()
    cached_id = str(loft.get("id") or "")
    if isinstance(loft.get("x11"), dict):
        current = _x11_cached_owner_current(loft["x11"])
        info = _x11_owned_window(loft["x11"], str(loft.get("title") or ""))
        if current is False:
            _clear_loft()
            loft, cached_id = {}, ""
        elif loft.get("remapping") or info is None or _x11_main_mapped(info) is not True:
            return _lofted_window_payload(loft)
        else:
            _clear_loft()  # A manual map releases ownership of the hidden window.
            loft, cached_id = {}, ""

    if windows is None:
        if loft.get("lofted") is True and cached_id:
            return _lofted_window_payload(loft)
        return None

    cider = _select_cider_window(windows, cached_id)
    if cider is not None:
        wid = str(cider.get("id") or cached_id)
        ws_output = _umbriel_output_from_workspace(cider.get("workspace"))
        lofted = _umbriel_in_scratchpad(cider)
        output = ws_output or str(loft.get("output") or "") or _umbriel_peer_output(windows)
        kept = loft if wid == cached_id else {}
        _write_loft({**kept, "id": wid, "output": output, "lofted": lofted})
        cider_windows = [
            w for w in windows if _is_cider_window(w.get("app_id"), w.get("title"))
        ]
        focused = any(w.get("active", w.get("focused")) is True for w in cider_windows)
        on_screen = any(_umbriel_on_screen(w, windows) for w in cider_windows)
        payload = _empty_window_probe()
        payload["compositor"] = "umbriel"
        payload["present"] = True
        payload["focused"] = focused
        payload["on_screen"] = on_screen
        payload["suppress_notify"] = focused or on_screen
        if wid:
            payload["id"] = wid
        if output:
            payload["output"] = output
        return payload

    if cached_id:
        output = str(loft.get("output") or "")
        _write_loft({**loft, "id": cached_id, "output": output, "lofted": True})
        return _lofted_window_payload(loft)

    if not windows:
        return None

    payload = _empty_window_probe()
    payload["compositor"] = "umbriel"
    return payload


def _probe_umbriel() -> dict[str, Any] | None:
    return apply_umbriel_listing(_umbriel_windows_json())


def _umbriel_msg(action: str) -> bool:
    if not action or not shutil.which("umbriel"):
        return False
    try:
        subprocess.check_call(
            ["umbriel", "msg", action],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=1.5,
        )
        return True
    except Exception as exc:
        log.debug("umbriel msg %s failed: %s", action, exc)
        return False


def _close_umbriel_watch(watch: subprocess.Popen[bytes]) -> None:
    if watch.stdout is not None:
        watch.stdout.close()
    if watch.poll() is None:
        watch.terminate()
    try:
        watch.wait(timeout=1)
    except subprocess.TimeoutExpired:
        watch.kill()
        watch.wait(timeout=1)


def _umbriel_action(name: str, output: str) -> str:
    output = (output or "").strip()
    if not output:
        return ""
    return f"{name}:{output}"


def _window_is_focused(windows: list[dict[str, Any]] | None, wid: str) -> bool:
    if not windows or not wid:
        return False
    return any(
        str(w.get("id") or "") == wid
        and w.get("active", w.get("focused")) is True
        for w in windows
    )


@contextmanager
def _window_transaction() -> Iterator[None]:
    """Serialize the polling bridge and one-shot widget/launcher helpers."""
    _STATE_DIR.mkdir(parents=True, exist_ok=True)
    with (_STATE_DIR / "window.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def _focus_umbriel_window(
    wid: str,
    send: Callable[[str], bool],
    list_windows: Callable[[], list[dict[str, Any]] | None],
    *,
    attempts: int = 3,
) -> bool | None:
    if not send(f"window-focus:{wid}"):
        return None
    for attempt in range(attempts):
        windows = list_windows()
        if windows is None:
            return None
        if _window_is_focused(windows, wid):
            return True
        if attempt + 1 < attempts:
            time.sleep(0.03)
    return False


def _umbriel_fade_seconds() -> float:
    """Wait for the compositor's fade before reattaching the window to its workspace."""
    path = Path(os.environ.get("CIDER_UMBRIEL_CONFIG") or (
        Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "umbriel/config.toml"
    )).expanduser()
    animation: dict[str, Any] = {}
    scratchpad: dict[str, Any] = {}
    seen: set[Path] = set()

    def read(config: Path) -> None:
        config = config.resolve()
        if config in seen:
            return
        seen.add(config)
        with config.open("rb") as file:
            data = tomllib.load(file)
        for name in data.get("include", {}).get("files", []):
            included = Path(name).expanduser()
            read(included if included.is_absolute() else config.parent / included)
        section = data.get("animation", {})
        animation.update({k: v for k, v in section.items() if k != "scratchpad"})
        scratchpad.update(section.get("scratchpad", {}))

    try:
        read(path)
        if animation.get("enabled") is False or scratchpad.get("enabled") is not True:
            return 0.0
        duration = 250
        for value in (animation.get("duration_ms"), scratchpad.get("duration_ms")):
            if type(value) is int and 1 <= value <= 10000:
                duration = value
        return duration / 1000.0
    except (OSError, ValueError, TypeError, AttributeError) as exc:
        log.debug("Umbriel animation config unavailable: %s", exc)
        return 0.25


def _restore_umbriel_window(
    wid: str,
    output: str,
    windows: list[dict[str, Any]],
    send: Callable[[str], bool],
    list_windows: Callable[[], list[dict[str, Any]] | None],
    *,
    workspace: str = "",
) -> bool:
    row = next((w for w in windows if str(w.get("id") or "") == wid), None)
    if row is None or not output:
        return False
    if not _umbriel_in_scratchpad(row):
        return _focus_umbriel_window(wid, send, list_windows) is True
    # 0.1.0 always restores to the saved workspace. Select it before revealing
    # the pad, since moving a scratchpad member to another workspace is inert.
    if workspace and not _select_restore_workspace(workspace, send):
        return False
    # Visibility and activation differ. Focusing a visible but unfocused pad
    # works; toggling it first would hide it. Hidden pads ignore focus on 0.1.0.
    # Focus IPC completes synchronously. A hidden pad cannot gain focus until
    # shown, so retrying this visibility probe only delays the first frame.
    focused = _focus_umbriel_window(wid, send, list_windows, attempts=1)
    if focused is None:
        return False
    opened_pad = not focused
    restored = False
    if opened_pad and not send(_umbriel_action("scratchpad-toggle", output)):
        return False
    try:
        if opened_pad:
            shown_at = time.monotonic()
            if not _focus_umbriel_window(wid, send, list_windows):
                return False
            time.sleep(max(0.0, _umbriel_fade_seconds() - (time.monotonic() - shown_at)))
            if not _focus_umbriel_window(wid, send, list_windows):
                return False
        restored = send(_umbriel_action("window-restore-from-scratchpad", output))
        return restored
    finally:
        # Undo only the visibility change this operation made, including errors.
        if opened_pad and (not restored or any(
            str(w.get("id") or "") != wid and _umbriel_in_scratchpad(w)
            for w in windows
        )):
            send(_umbriel_action("scratchpad-toggle", output))


def _read_miniplayer() -> dict[str, Any]:
    try:
        state = json.loads((_STATE_DIR / "miniplayer.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return state if isinstance(state, dict) else {}


def show_cider_window() -> int:
    """Launcher hook: restore the existing mini/main; 1 lets the launcher start Cider."""
    windows = _umbriel_windows_json()
    if windows is None:
        return 2 if "umbriel" in os.environ.get("XDG_CURRENT_DESKTOP", "").lower() else 1
    loft = _read_loft()
    if isinstance(loft.get("x11"), dict):
        if _x11_cached_owner_current(loft["x11"]) is False:
            _clear_loft()
        else:
            if not _restore_x11_window(loft, windows, _umbriel_msg, _umbriel_windows_json, _loft_path()):
                return 2
            _clear_loft()
            apply_umbriel_listing(_umbriel_windows_json())
            return 0
    row = _select_cider_window(windows)
    if row is None:
        state = _read_miniplayer()
        if not isinstance(state.get("main_x11"), dict) or not state.get("restore_main", True):
            return 1
        if _x11_owner_current(state) is False:
            (_STATE_DIR / "miniplayer.json").unlink(missing_ok=True)
            return 1
        reconcile_miniplayer(windows)
        windows = _umbriel_windows_json()
        row = _select_cider_window(windows or [])
        if row is None:
            return 2  # An owned main is still remapping; never launch a duplicate.
    payload = apply_umbriel_listing(windows)
    output = str((payload or {}).get("output") or "")
    loft = _read_loft()
    if _umbriel_in_scratchpad(row):
        converted = _hide_x11_window(row, loft)
        if converted is not None:
            if not converted or not _restore_x11_window(
                _read_loft(), windows, _umbriel_msg, _umbriel_windows_json, _loft_path()
            ):
                return 2
            _clear_loft()
            apply_umbriel_listing(_umbriel_windows_json())
            return 0
    return 0 if _restore_umbriel_window(
        str(row.get("id") or ""), output, windows, _umbriel_msg, _umbriel_windows_json,
        workspace=str(_read_loft().get("workspace") or ""),
    ) else 2


def _xdotool(*args: str) -> str | None:
    if not shutil.which("xdotool"):
        return None
    try:
        return subprocess.check_output(
            ["xdotool", *args], stderr=subprocess.PIPE, timeout=0.6,
        ).decode("utf-8").strip()
    except subprocess.CalledProcessError as exc:
        if args and args[0] == "search" and exc.returncode == 1 and not exc.output and not exc.stderr:
            return ""
        log.debug("Cider X11 query/action failed: %s", exc)
    except (OSError, UnicodeError, subprocess.TimeoutExpired) as exc:
        log.debug("Cider X11 query/action unavailable: %s", exc)
    return None


def _x11_process_start(pid: int) -> str:
    try:
        return Path(f"/proc/{pid}/stat").read_text().rsplit(") ", 1)[1].split()[19]
    except (OSError, IndexError):
        return ""


def _x11_window_info(xid: str, title: str) -> dict[str, Any] | None:
    if title not in ("Cider", "Cider - Mini Player") or not xid.isdecimal() or int(xid) <= 0:
        return None
    raw = _xdotool("getwindowname", xid, "getwindowclassname", xid,
                   "getwindowpid", xid, "getwindowgeometry", "--shell", xid)
    if raw is None:
        return None
    rows = raw.splitlines()
    try:
        if len(rows) != 9 or rows[0] != title or rows[1].lower() != "cider":
            return None
        geometry = dict(row.split("=", 1) for row in rows[3:])
        pid = int(rows[2])
        start = _x11_process_start(pid) if pid > 0 else ""
        if not start or int(geometry["WINDOW"]) != int(xid):
            return None
        return {"xid": xid, "pid": pid, "start": start,
                "w": int(geometry["WIDTH"]), "h": int(geometry["HEIGHT"])}
    except (KeyError, ValueError):
        return None


def _x11_main_info(xid: str) -> dict[str, Any] | None:
    return _x11_window_info(xid, "Cider")


def _x11_main_for_view(main: dict[str, Any]) -> dict[str, Any] | None:
    if main.get("xwayland") is not True or not all(
        type(main.get(key)) is int and main[key] > 10 for key in ("w", "h")
    ):
        return None
    ids = _xdotool("search", "--onlyvisible", "--class", "^cider$")
    matches = [info for xid in (ids or "").split()
               if (info := _x11_main_info(xid)) is not None
               and (info["w"], info["h"]) == (main["w"], main["h"])]
    return matches[0] if len(matches) == 1 else None


def _x11_window_for_view(window: dict[str, Any]) -> dict[str, Any] | None:
    title = str(window.get("title") or "")
    if title == "Cider":
        return _x11_main_for_view(window)
    if title != "Cider - Mini Player" or window.get("xwayland") is not True or not all(
        type(window.get(key)) is int and window[key] > 10 for key in ("w", "h")
    ):
        return None
    ids = _xdotool("search", "--onlyvisible", "--class", "^cider$")
    matches = [info for xid in (ids or "").split()
               if (info := _x11_window_info(xid, title)) is not None
               and (info["w"], info["h"]) == (window["w"], window["h"])]
    return matches[0] if len(matches) == 1 else None


def _x11_owned_window(cached: Any, title: str) -> dict[str, Any] | None:
    if not isinstance(cached, dict):
        return None
    xid = str(cached.get("xid") or "")
    info = _x11_main_info(xid) if title == "Cider" else _x11_window_info(xid, title)
    return info if info is not None and all(
        info[key] == cached.get(key) for key in ("xid", "pid", "start")
    ) else None


def _x11_owned_main(state: dict[str, Any]) -> dict[str, Any] | None:
    return _x11_owned_window(state.get("main_x11"), "Cider")


def _x11_cached_owner_current(cached: Any) -> bool | None:
    if not isinstance(cached, dict):
        return False
    pid, start, xid = cached.get("pid"), cached.get("start"), str(cached.get("xid") or "")
    if (type(pid) is not int or pid <= 0 or not isinstance(start, str) or not start.isdecimal()
            or not xid.isdecimal() or int(xid) <= 0):
        return False
    current_start = _x11_process_start(pid)
    if current_start:
        if current_start != start:
            return False
    else:
        try:
            os.kill(pid, 0)  # Existence probe only; do not confuse permission failure with exit.
        except ProcessLookupError:
            return False
        except OSError:
            pass
        return None
    ids = _xdotool("search", "--pid", str(pid))
    return xid in ids.split() if ids is not None else None


def _x11_owner_current(state: dict[str, Any]) -> bool | None:
    return _x11_cached_owner_current(state.get("main_x11"))


def _x11_main_mapped(info: dict[str, Any]) -> bool | None:
    ids = _xdotool("search", "--onlyvisible", "--pid", str(info["pid"]))
    return info["xid"] in ids.split() if ids is not None else None


def _hide_x11_window(row: dict[str, Any], loft: dict[str, Any]) -> bool | None:
    if _umbriel_in_scratchpad(row) and _remember_workspace() and not loft.get("workspace"):
        return None  # Only the native scratchpad still knows this legacy destination.
    info = _x11_window_for_view(row)
    if info is None:
        return None
    hidden = {**loft, "x11": info, "title": row["title"], "lofted": True}
    if not _umbriel_in_scratchpad(row):
        hidden["workspace"] = row.get("workspace") or ""
        if type(row.get("floating")) is bool:
            hidden["floating"] = row["floating"]
    _write_loft(hidden)
    if _x11_owned_window(info, row["title"]) is None:
        _write_loft(loft)
        return False
    if _xdotool("windowunmap", info["xid"], "getwindowpid", info["xid"]) is None:
        if _x11_main_mapped(info) is True:
            _write_loft(loft)
        return False
    return True


def _restore_x11_window(
    state: dict[str, Any], windows: list[dict[str, Any]],
    send: Callable[[str], bool], list_windows: Callable[[], list[dict[str, Any]] | None],
    path: Path,
) -> bool:
    title = str(state.get("title") or "Cider")
    info = _x11_owned_window(state.get("x11", state.get("main_x11")), title)
    if info is None:
        return False
    mapped = _x11_main_mapped(info)
    if mapped is None:
        return False
    if mapped and not state.get("remapping"):
        return True  # A manual restore releases ownership without moving/focusing it.
    if not mapped:
        workspace = str(state.get("workspace") or "")
        if _remember_workspace() and workspace and not _select_restore_workspace(workspace, send):
            return False
        state["remapping"] = True
        _atomic_write(path, json.dumps(state))
        if _xdotool("windowmap", info["xid"], "getwindowpid", info["xid"]) is None:
            return False
        windows = list_windows() or []
    candidates = [row for row in windows if _is_cider_window(row.get("app_id"), row.get("title"))
                  and row.get("title") == title and row.get("xwayland") is True]
    if len(candidates) != 1:
        return False
    main = candidates[0]
    visible = _x11_window_for_view(main)
    if visible is None or any(visible[key] != info[key] for key in ("xid", "pid", "start")):
        return False
    wid = str(main.get("id") or "")
    if not wid or not _focus_umbriel_window(wid, send, list_windows):
        return False
    floating = state.get("floating")
    if type(floating) is bool and main.get("floating") is not floating:
        if not send("window-toggle-floating"):
            return False
    return _focus_umbriel_window(wid, send, list_windows) is True


def reconcile_miniplayer(
    windows: list[dict[str, Any]] | None,
    msg: Callable[[str], bool] | None = None,
    listing: Callable[[], list[dict[str, Any]] | None] | None = None,
) -> None:
    """Hide the main only for a new mini, and restore only the main we hid."""
    send = msg or _umbriel_msg
    list_windows = listing or _umbriel_windows_json
    path = _STATE_DIR / "miniplayer.json"
    state = _read_miniplayer()
    if windows is None:
        return
    loft = _read_loft()
    if loft.get("remapping") and isinstance(loft.get("x11"), dict):
        if _restore_x11_window(loft, windows, send, list_windows, _loft_path()):
            _clear_loft()
            windows = list_windows() or windows
    mini = next((w for w in windows if _is_cider_window(w.get("app_id"), w.get("title"))
                 and str(w.get("title") or "").lower() == "cider - mini player"), None)
    if mini is None:
        loft = _read_loft()
        if loft.get("title") == "Cider - Mini Player" and isinstance(loft.get("x11"), dict):
            if _x11_cached_owner_current(loft["x11"]) is not False:
                return  # A user-hidden mini still owns its hidden main.
            _clear_loft()
        if isinstance(state.get("main_x11"), dict):
            if (not state.get("restore_main", True) or _x11_owner_current(state) is False
                    or _restore_x11_window(state, windows, send, list_windows, path)):
                path.unlink(missing_ok=True)
            return
        main_id = str(state.get("main_id") or "")
        main = next((w for w in windows if str(w.get("id") or "") == main_id
                     and _is_cider_window(w.get("app_id"), w.get("title"))), None)
        if main is not None and _umbriel_in_scratchpad(main) and state.get("restore_main", True):
            if not _restore_umbriel_window(main_id, str(state.get("output") or ""),
                                           windows, send, list_windows,
                                           workspace=str(state.get("workspace") or "")):
                return
        path.unlink(missing_ok=True)
        return
    mini_id = str(mini.get("id") or "")
    if not mini_id:
        return
    if state.get("mini_id") != mini_id and mini.get("floating") is False:
        if not _focus_umbriel_window(mini_id, send, list_windows) or not send("window-toggle-floating"):
            return
    main = next((w for w in windows if _is_cider_window(w.get("app_id"), w.get("title"))
                 and str(w.get("title") or "").lower() == "cider"), None)
    previous = state
    if isinstance(previous.get("main_x11"), dict):
        state = {**previous, "mini_id": mini_id}
        info = _x11_owned_main(state)
        if info is not None and _x11_main_mapped(info) is True:
            if state.get("remapping") and state.get("restore_main", True):
                if _xdotool("windowunmap", info["xid"], "getwindowpid", info["xid"]) is None:
                    return
                state.pop("remapping", None)
            else:
                state["restore_main"] = False
        if state != previous:
            _atomic_write(path, json.dumps(state))
        return
    state = {"mini_id": mini_id}
    if main is not None and str(main.get("id") or "") == previous.get("main_id"):
        state.update(main_id=previous["main_id"], output=previous.get("output", ""),
                     restore_main=previous.get("restore_main", True) and _umbriel_in_scratchpad(main))
        state.update({key: previous[key] for key in ("workspace", "floating") if key in previous})
    owns_pad = main is not None and _umbriel_in_scratchpad(main) and state.get("restore_main") is True
    needs_hide = main is not None and not _umbriel_in_scratchpad(main) and (
        previous.get("main_id") != main.get("id") or previous.get("mini_id") != mini_id
    )
    if main is not None and (needs_hide or owns_pad):
        info = _x11_main_for_view(main)
        if info is not None:
            state.update(main_id=str(main.get("id") or ""), main_x11=info, restore_main=True)
            if not owns_pad:
                state["workspace"] = main.get("workspace") or ""
                if type(main.get("floating")) is bool:
                    state["floating"] = main["floating"]
            # Journal ownership before unmapping; an interrupted helper must
            # never leave a hidden main with no way to return it.
            _atomic_write(path, json.dumps(state))
            if _x11_owned_main(state) is None:
                _atomic_write(path, json.dumps(previous))
                return
            # The same-connection property read acknowledges XUnmap before a
            # later event probe can mistake its pending state for a manual map.
            if _xdotool("windowunmap", info["xid"], "getwindowpid", info["xid"]) is None:
                if _x11_main_mapped(info) is True:
                    _atomic_write(path, json.dumps(previous))
                return
            if mini.get("floating") is not False and not _window_is_focused(windows, mini_id):
                _focus_umbriel_window(mini_id, send, list_windows)
            return
    if needs_hide:
        main_id = str(main.get("id") or "")
        output = _umbriel_output_from_workspace(main.get("workspace"))
        if not main_id or not output or not _focus_umbriel_window(main_id, send, list_windows):
            return
        if not send(_umbriel_action("window-move-to-scratchpad", output)):
            return
        state.update(main_id=main_id, output=output, restore_main=True)
        state["workspace"] = main.get("workspace") or ""
        if type(main.get("floating")) is bool:
            state["floating"] = main["floating"]
        _focus_umbriel_window(mini_id, send, list_windows)
    if state != previous:
        _atomic_write(path, json.dumps(state))


def toggle_loft(
    msg: Callable[[str], bool] | None = None,
    listing: Callable[[], list[dict[str, Any]] | None] | None = None,
) -> int:
    """Send or restore Cider on Umbriel. Unaddressable window → no-op."""
    send = msg or _umbriel_msg
    list_windows = listing or _umbriel_windows_json
    windows = list_windows()
    payload = apply_umbriel_listing(windows)
    if payload is None or payload.get("compositor") != "umbriel":
        return 0
    loft = _read_loft()
    wid = str(loft.get("id") or payload.get("id") or "")
    output = str(loft.get("output") or payload.get("output") or "")
    if not wid or not output:
        return 0
    was_lofted = loft.get("lofted") is True
    if isinstance(loft.get("x11"), dict):
        if _restore_x11_window(loft, windows or [], send, list_windows, _loft_path()):
            _clear_loft()
            apply_umbriel_listing(list_windows())
        return 0
    row = next((w for w in windows or [] if str(w.get("id") or "") == wid), None)
    hidden = _hide_x11_window(row, loft) if row is not None else None
    if hidden is not None:
        if was_lofted and hidden and _restore_x11_window(
            _read_loft(), windows or [], send, list_windows, _loft_path()
        ):
            _clear_loft()
            apply_umbriel_listing(list_windows())
        return 0
    if was_lofted:
        _restore_umbriel_window(wid, output, windows or [], send, list_windows,
                                workspace=str(loft.get("workspace") or ""))
        return 0
    if not _focus_umbriel_window(wid, send, list_windows):
        return 0
    pad = _umbriel_action("window-move-to-scratchpad", output)
    if not pad:
        return 0
    hidden = {**loft, "workspace": (row or {}).get("workspace") or ""}
    _write_loft(hidden)
    if not send(pad):
        _write_loft(loft)
    return 0


def _niri_json(cmd: list[str]) -> Any | None:
    try:
        raw = subprocess.check_output(cmd, stderr=subprocess.DEVNULL, timeout=1.5)
        return json.loads(raw.decode("utf-8"))
    except Exception as exc:
        log.debug("niri query failed (%s): %s", " ".join(cmd), exc)
        return None


def _niri_cider_on_screen(
    cider: dict[str, Any],
    windows: list[dict[str, Any]],
    workspaces: list[dict[str, Any]],
    outputs: dict[str, Any],
) -> bool:
    """Estimate whether Cider's tile intersects the active workspace viewport."""
    if cider.get("is_focused"):
        return True
    ws = next((w for w in workspaces if w.get("id") == cider.get("workspace_id")), None)
    if not ws or not ws.get("is_active"):
        return False
    if cider.get("is_floating"):
        return True

    out = outputs.get(str(ws.get("output") or ""), {}) if isinstance(outputs, dict) else {}
    logical = out.get("logical") if isinstance(out, dict) else None
    view_w = float((logical or {}).get("width") or 0)
    if view_w <= 0:
        return False

    tiled = [
        w
        for w in windows
        if w.get("workspace_id") == cider.get("workspace_id") and not w.get("is_floating")
    ]
    col_widths: dict[int, float] = {}
    for w in tiled:
        layout = w.get("layout") or {}
        pos = layout.get("pos_in_scrolling_layout") or [0, 0]
        col = int(pos[0] or 0)
        tw = float((layout.get("tile_size") or [0, 0])[0] or 0)
        col_widths[col] = max(col_widths.get(col, 0.0), tw)
    if not col_widths:
        return False

    ordered = sorted(col_widths)
    col_x: dict[int, float] = {}
    x = 0.0
    for col in ordered:
        col_x[col] = x
        x += col_widths[col]
    total_w = x

    focused = next((w for w in tiled if w.get("is_focused")), None)
    if focused is None:
        aw = ws.get("active_window_id")
        focused = next((w for w in tiled if w.get("id") == aw), None)
    if focused is None:
        return False

    flayout = focused.get("layout") or {}
    fcol = int((flayout.get("pos_in_scrolling_layout") or [0, 0])[0] or 0)
    fw = float((flayout.get("tile_size") or [0, 0])[0] or 0)
    fx = col_x.get(fcol, 0.0)
    if fw >= view_w:
        view_left = fx
    else:
        preferred = fx + fw / 2.0 - view_w / 2.0
        max_left = max(0.0, total_w - view_w)
        view_left = min(max(0.0, preferred), max_left)
    view_right = view_left + view_w

    clayout = cider.get("layout") or {}
    ccol = int((clayout.get("pos_in_scrolling_layout") or [0, 0])[0] or 0)
    cw = float((clayout.get("tile_size") or [0, 0])[0] or 0)
    cx = col_x.get(ccol, 0.0)
    return cx < view_right and (cx + cw) > view_left


def _probe_niri() -> dict[str, Any] | None:
    if not shutil.which("niri"):
        return None
    windows = _niri_json(["niri", "msg", "-j", "windows"])
    workspaces = _niri_json(["niri", "msg", "-j", "workspaces"])
    outputs = _niri_json(["niri", "msg", "-j", "outputs"])
    if not isinstance(windows, list) or not isinstance(workspaces, list):
        return None
    cider = next(
        (
            w
            for w in windows
            if _is_cider_window(w.get("app_id"), w.get("title"))
        ),
        None,
    )
    payload = _empty_window_probe()
    payload["compositor"] = "niri"
    if cider is None:
        return payload
    focused = bool(cider.get("is_focused"))
    on_screen = _niri_cider_on_screen(
        cider,
        windows,
        workspaces,
        outputs if isinstance(outputs, dict) else {},
    )
    payload.update(
        {
            "present": True,
            "focused": focused,
            "on_screen": on_screen,
            "suppress_notify": focused or on_screen,
        }
    )
    return payload


def _probe_hyprland() -> dict[str, Any] | None:
    if not shutil.which("hyprctl"):
        return None
    try:
        clients = json.loads(
            subprocess.check_output(
                ["hyprctl", "clients", "-j"],
                stderr=subprocess.DEVNULL,
                timeout=1.5,
            ).decode("utf-8")
        )
        active = json.loads(
            subprocess.check_output(
                ["hyprctl", "activewindow", "-j"],
                stderr=subprocess.DEVNULL,
                timeout=1.5,
            ).decode("utf-8")
        )
    except Exception as exc:
        log.debug("hyprctl probe failed: %s", exc)
        return None
    payload = _empty_window_probe()
    payload["compositor"] = "hyprland"
    cider = next(
        (
            c
            for c in (clients or [])
            if _is_cider_window(c.get("class"), c.get("title"))
        ),
        None,
    )
    if cider is None:
        return payload
    focused = bool(active) and active.get("address") == cider.get("address")
    on_screen = focused or (
        not cider.get("hidden", False)
        and cider.get("workspace", {}).get("id") == (active or {}).get("workspace", {}).get("id")
    )
    payload.update(
        {
            "present": True,
            "focused": focused,
            "on_screen": bool(on_screen),
            "suppress_notify": focused or bool(on_screen),
        }
    )
    return payload


def probe_cider_window() -> dict[str, Any]:
    """Detect Cider focus / on-screen state for notification suppression."""
    for probe in (_probe_umbriel, _probe_niri, _probe_hyprland):
        payload = probe()
        if payload is not None:
            return payload
    return _empty_window_probe()


def _write_window(payload: dict[str, Any]) -> None:
    _atomic_write(_STATE_DIR / "window.json", json.dumps(payload, ensure_ascii=False))


def _wipe_playback_sidecars() -> None:
    """Drop durable snapshots so Luau cannot rehydrate a dead Cider session."""
    global _POS_ANCHOR_MS, _POS_ANCHOR_WALL, _POS_PLAYING, _POS_DURATION_MS
    with _POS_LOCK:
        _POS_ANCHOR_MS = 0
        _POS_ANCHOR_WALL = 0.0
        _POS_PLAYING = False
        _POS_DURATION_MS = 0
    for name in ("state.json", "position.json", "lyrics.json"):
        path = _STATE_DIR / name
        try:
            path.unlink(missing_ok=True)
        except OSError:
            pass


def emit(event: TrackEvent, *, provider_rewind: bool = False) -> None:
    global _EVENT_SEQ
    payload = asdict(event)
    if payload.get("lyrics_lines") is None:
        payload.pop("lyrics_lines", None)
    skip_position = bool(payload.pop("skip_position", False))
    body = json.dumps(payload, ensure_ascii=False)
    with _EMIT_LOCK:
        _STATE_DIR.mkdir(parents=True, exist_ok=True)
        if event.type == "lyrics":
            # Validate against the same snapshot lock used by track changes.
            try:
                current = json.loads((_STATE_DIR / "state.json").read_text(encoding="utf-8"))
            except (OSError, ValueError):
                return
            if any(payload.get(field) != current.get(field)
                   for field in ("title", "artist", "album", "duration_ms", "catalog_id")):
                return
        # Continuous snapshot for progress polling
        if event.type in {"track", "time", "state", "art"}:
            if event.type == "track":
                # Also covers distinct catalog tracks with the same title/artist.
                (_STATE_DIR / "lyrics.json").unlink(missing_ok=True)
            _atomic_write(_STATE_DIR / "state.json", body)
            if event.type in {"track", "time", "state"} and not skip_position:
                _write_position(
                    int(event.position_ms or 0),
                    str(event.playback_state or "") == "playing",
                    int(event.duration_ms or 0),
                    # Live time ticks accept seeks; tracks bypass jitter filtering.
                    trust=event.type in {"time", "track"},
                    reset=event.type == "track",
                    provider_rewind=provider_rewind,
                )
        elif event.type == "clear":
            _wipe_playback_sidecars()
        # Edge events (track change, lyrics, clear, status, art)
        if event.type in {"track", "lyrics", "clear", "status", "art"}:
            _EVENT_SEQ += 1
            payload["_id"] = f"{int(time.time() * 1000)}-{_EVENT_SEQ}"
            edged = json.dumps(payload, ensure_ascii=False)
            _atomic_write(_STATE_DIR / "event.json", edged)
            # Durable lyrics sidecar so track polls cannot clobber the last push
            if event.type == "lyrics":
                _atomic_write(_STATE_DIR / "lyrics.json", edged)
    if sys.stdout.isatty():
        sys.stdout.write(body + "\n")
        sys.stdout.flush()


def _ms_to_lrc_time(ms: int) -> str:
    total_cs = max(0, ms) // 10
    minutes, cs = divmod(total_cs, 6000)
    seconds, centis = divmod(cs, 100)
    return f"{minutes:02d}:{seconds:02d}.{centis:02d}"


def _parse_ttml_time(value: str | None) -> int | None:
    if not value:
        return None
    value = value.strip()
    if value.endswith("s") and ":" not in value:
        try:
            return int(float(value[:-1]) * 1000)
        except ValueError:
            return None
    # HH:MM:SS.mmm or MM:SS.mmm
    parts = value.split(":")
    try:
        if len(parts) == 3:
            h, m, s = parts
            return int((int(h) * 3600 + int(m) * 60 + float(s)) * 1000)
        if len(parts) == 2:
            m, s = parts
            return int((int(m) * 60 + float(s)) * 1000)
        return int(float(value) * 1000)
    except ValueError:
        return None


# Community lyrics widget only draws its animated intro cue when the first
# timed line is >= 6000ms. Below that it defaults index=1 and shows vocals early.
# Apple often starts just under that (e.g. 5940ms). Keep Apple times exact and
# inject a silence row so the widget shows the cue until the real first line.
#
# ASCII dots only — Luau `string.sub` is byte-based, so U+2022 ••••• becomes
# replacement-character garbage when the OSD lights dots one "char" at a time.
# Community lyrics still accepts any cue_text; ASCII renders everywhere.
_LYRICS_INTRO_MIN_MS = 6000
_CUE_TEXT = "..."


def _p_begin_ms(el: Any) -> int | None:
    """Prefer <p begin>; fall back to earliest timed <span> (syllable TTML)."""
    begin = _parse_ttml_time(el.attrib.get("begin"))
    if begin is not None:
        return begin
    earliest: int | None = None
    for child in el.iter():
        if child is el:
            continue
        tag = child.tag.rsplit("}", 1)[-1]
        if tag != "span":
            continue
        span_begin = _parse_ttml_time(child.attrib.get("begin"))
        if span_begin is None:
            continue
        if earliest is None or span_begin < earliest:
            earliest = span_begin
    return earliest


def with_intro_cue(lines: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Match Cider's pre-vocal `...` without shifting Apple timestamps."""
    if not lines:
        return lines
    first = int(lines[0].get("time") or 0)
    # Native intro cue already covers firstTime >= 6000.
    if first <= 0 or first >= _LYRICS_INTRO_MIN_MS:
        return lines
    silence = {
        "time": 0,
        "duration": first,
        "text": _CUE_TEXT,
        "cue": True,
    }
    return [silence, *lines]


# Gaps this long get an explicit cue row so interludes work even when the
# lyrics widget's built-in interlude threshold (5s) would miss shorter breaks.
_INTERLUDE_INJECT_MS = 2500


def inject_interlude_cues(lines: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Insert the same cue glyph the lyrics plugin uses for instrumental gaps."""
    if len(lines) < 2:
        return lines
    out: list[dict[str, Any]] = []
    for i, line in enumerate(lines):
        out.append(line)
        if i + 1 >= len(lines):
            break
        if line.get("cue") or lines[i + 1].get("cue"):
            continue
        start = int(line.get("time") or 0)
        if start < 0:
            continue
        duration = int(line.get("duration") or 0)
        end = start + max(0, duration)
        nxt = int(lines[i + 1].get("time") or 0)
        gap = nxt - end
        if gap >= _INTERLUDE_INJECT_MS:
            out.append(
                {
                    "time": end,
                    "duration": gap,
                    "text": _CUE_TEXT,
                    "cue": True,
                }
            )
    return out


def finalize_synced_lines(lines: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Preserve real end times, infer only when needed, then add intro/interlude cues."""
    if not lines:
        return lines
    for i in range(len(lines) - 1):
        cur = lines[i]
        nxt_time = int(lines[i + 1]["time"])
        start = int(cur["time"])
        gap = nxt_time - start
        if gap <= 0:
            continue
        if cur.get("duration_inferred"):
            # LRC / missing end: don't stretch a short line across a long break.
            if gap >= 7000:
                est = max(3200, min(6000, max(800, len(str(cur.get("text") or "")) * 55)))
                cur["duration"] = min(gap, est)
            else:
                cur["duration"] = gap
        else:
            # Apple end times: keep them; only clamp if they overrun the next begin.
            dur = int(cur.get("duration") or 0)
            if start + dur > nxt_time:
                cur["duration"] = max(500, gap)
    lines = inject_interlude_cues(lines)
    return with_intro_cue(lines)


def resolve_catalog_id(attrs: dict[str, Any], play_params: dict[str, Any] | None = None) -> str:
    """Prefer Apple catalog ids (digits). Library ids like i.… are useless for amapi."""
    play_params = play_params or {}
    candidates: list[Any] = [
        play_params.get("catalogId"),
        play_params.get("id"),
        attrs.get("catalog_id"),
        attrs.get("catalogId"),
        attrs.get("songId"),
        attrs.get("id"),
    ]
    url = str(attrs.get("url") or attrs.get("appleMusicUrl") or "")
    match = re.search(r"[?&]i=(\d+)", url) or re.search(r"/song/[^/?]+/(\d+)", url)
    if match:
        candidates.append(match.group(1))
    for cand in candidates:
        value = str(cand or "").strip()
        if value.isdigit():
            return value
    return ""


def _span_timings(el: Any) -> tuple[list[dict[str, Any]], list[int]]:
    """Extract word/syllable spans + per-character start times from a TTML <p>.

    Apple syllable-lyrics often nests untimed <span> glyphs inside a timed
    parent word span. Prefer timed leaves; if only timed parents exist, use those.
    """
    candidates: list[tuple[Any, int, int | None]] = []
    for child in el.iter():
        if child is el:
            continue
        tag = child.tag.rsplit("}", 1)[-1]
        if tag != "span":
            continue
        begin = _parse_ttml_time(child.attrib.get("begin"))
        if begin is None:
            continue
        end = _parse_ttml_time(child.attrib.get("end"))
        candidates.append((child, begin, end))

    if not candidates:
        return [], []

    # Prefer spans that do not contain another timed span (true leaves).
    leaves: list[tuple[Any, int, int | None]] = []
    for child, begin, end in candidates:
        has_timed_child = False
        for sub in child.iter():
            if sub is child:
                continue
            if sub.tag.rsplit("}", 1)[-1] != "span":
                continue
            if _parse_ttml_time(sub.attrib.get("begin")) is not None:
                has_timed_child = True
                break
        if not has_timed_child:
            leaves.append((child, begin, end))
    timed_spans = leaves or candidates

    words: list[dict[str, Any]] = []
    chars: list[int] = []
    for child, begin, end in timed_spans:
        text = "".join(child.itertext())
        if not text:
            continue
        if end is None or end < begin:
            end = begin
        words.append({"text": text, "start": begin, "end": end})
        span_dur = max(0, end - begin)
        n = max(1, len(text))
        for i in range(n):
            chars.append(begin + (span_dur * i) // n)
    return words, chars


def ttml_to_lines(ttml: str) -> tuple[list[dict[str, Any]], str]:
    """Return (lines, lrc_or_plain) from Apple Music TTML.

    Timed TTML keeps Apple begin/end (so instrumental gaps become `.....`).
    Word/syllable <span> timings become `words` + `chars` for karaoke OSD.
    Untimed TTML returns plain lines (time=-1) so the widget still updates
    title/album text instead of staying stuck on the previous track.
    """
    root = ET.fromstring(ttml)
    timing_attr = ""
    for key, value in root.attrib.items():
        if key.endswith("timing") or key == "timing":
            timing_attr = str(value).lower()
            break

    paragraphs: list[tuple[Any, str]] = []
    timed = 0
    for el in root.iter():
        tag = el.tag.rsplit("}", 1)[-1]
        if tag != "p":
            continue
        # Skip translation / romanization roles — vocals only for sing-along.
        role = " ".join(
            str(v) for k, v in el.attrib.items() if "role" in k.lower()
        ).lower()
        if "translation" in role or "roman" in role:
            continue
        text = "".join(el.itertext()).strip()
        if not text:
            continue
        paragraphs.append((el, text))
        if _p_begin_ms(el) is not None:
            timed += 1

    # Untimed: plain lyrics (no fake 3s sync). Caller may still try LRCLIB synced.
    if timing_attr == "none" or timed == 0:
        plain_lines = [{"time": -1, "text": text} for _, text in paragraphs]
        plain = "\n".join(text for _, text in paragraphs)
        return plain_lines, plain

    lines: list[dict[str, Any]] = []
    for el, text in paragraphs:
        begin = _p_begin_ms(el)
        if begin is None:
            continue
        end = _parse_ttml_time(el.attrib.get("end"))
        words, chars = _span_timings(el)
        if end is None and words:
            end = max(int(w["end"]) for w in words)
        if end is None:
            for child in el.iter():
                if child is el:
                    continue
                tag = child.tag.rsplit("}", 1)[-1]
                if tag != "span":
                    continue
                span_end = _parse_ttml_time(child.attrib.get("end"))
                if span_end is not None and (end is None or span_end > end):
                    end = span_end
        entry: dict[str, Any]
        if end is not None and end > begin:
            entry = {
                "time": begin,
                "duration": end - begin,
                "text": text,
                "duration_inferred": False,
            }
        else:
            entry = {
                "time": begin,
                "duration": 3000,
                "text": text,
                "duration_inferred": True,
            }
        if words:
            entry["words"] = restore_word_spacing(words, text)
        if chars:
            entry["chars"] = chars
        lines.append(entry)

    lines = finalize_synced_lines(lines)
    # LRC sidecar is vocal lines only (skip cue rows) for debugging / fallbacks.
    lrc_parts = [
        f"[{_ms_to_lrc_time(int(line['time']))}]{line['text']}"
        for line in lines
        if not line.get("cue") and int(line.get("time") or 0) >= 0
    ]
    return lines, "\n".join(lrc_parts)


def _normalize_artwork_url(url: str, size: int = 600) -> str:
    """Expand Apple Music {w}x{h} templates and force a concrete size."""
    if not url:
        return ""
    out = url.replace("{w}", str(size)).replace("{h}", str(size))
    out = re.sub(r"/\d+x\d+([a-z]*)\.(jpg|jpeg|png|webp)", rf"/{size}x{size}\1.\2", out, count=1)
    return out


class CiderBridge:
    def __init__(
        self,
        base_url: str,
        apptoken: str,
        cache_dir: Path,
        poll_interval_sec: float,
    ) -> None:
        # One-shot window controls need only stdlib and compositor IPC.
        import requests
        import socketio

        self.base_url = base_url.rstrip("/")
        self.apptoken = apptoken.strip()
        self.cache_dir = cache_dir
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self.poll_interval_sec = poll_interval_sec
        self._session = requests.Session()
        if self.apptoken:
            # Live Cider (2026) still authenticates `apptoken`. Published docs
            # and cider-api say `apitoken`. Send both so either build accepts us.
            self._session.headers["apptoken"] = self.apptoken
            self._session.headers["apitoken"] = self.apptoken
        self._sio = socketio.Client(reconnection=True, reconnection_delay=2)
        self._stop = threading.Event()
        self._window_thread: threading.Thread | None = None
        self._window_watch: subprocess.Popen[bytes] | None = None
        self._art_lock = threading.Lock()
        self._snapshot_lock = threading.Lock()
        self._track_key = ""
        self._lyrics_key = ""
        self._last: dict[str, Any] = {}
        self._api_fail_streak = 0
        self._provider_clock_active = False
        self._provider_clock_sample: tuple[int, str] | None = None
        self._provider_clock_generation = 0
        self._register()

    def _register(self) -> None:
        @self._sio.on("API:Playback")
        def on_playback(message: dict[str, Any]) -> None:
            try:
                self._handle_event(message.get("type", ""), message.get("data", {}))
            except Exception as exc:
                log.exception("playback handler failed: %s", exc)

        @self._sio.event
        def connect() -> None:
            emit(TrackEvent(type="status", message="connected"))
            self.refresh_snapshot()

        @self._sio.event
        def disconnect() -> None:
            with _EMIT_LOCK:
                # A socket outage must not erase a healthy native snapshot.
                if not getattr(self, "_provider_clock_active", False):
                    self._track_key = ""
                    self._lyrics_key = ""
                    self._last = {}
                    self._provider_clock_sample = None
                    _clear_loft()
                    emit(TrackEvent(type="clear"))
                emit(TrackEvent(type="status", message="disconnected"))

    def start(self) -> None:
        # Drop leftovers from a previous session until a live snapshot arrives.
        # Otherwise Luau can rehydrate a stale playing track after Cider quit.
        _wipe_playback_sidecars()
        threading.Thread(target=self._run_sio, name="cider-sio", daemon=True).start()
        if self.poll_interval_sec > 0:
            threading.Thread(target=self._poll_loop, name="cider-poll", daemon=True).start()
        self._window_thread = threading.Thread(target=self._window_loop, name="cider-window", daemon=True)
        self._window_thread.start()
        while not self._stop.is_set():
            self._stop.wait(1)

    def stop(self) -> None:
        self._stop.set()
        if self._window_watch is not None:
            _close_umbriel_watch(self._window_watch)
        if self._window_thread is not None and self._window_thread.is_alive():
            self._window_thread.join(timeout=2)
        try:
            self._sio.disconnect()
        except Exception:
            pass

    def _window_loop(self) -> None:
        last_body = ""
        watch: subprocess.Popen[bytes] | None = None
        watch_retry_at = 0.0
        try:
            while not self._stop.is_set():
                if watch is None and time.monotonic() >= watch_retry_at:
                    watch_retry_at = time.monotonic() + 5.0
                    if shutil.which("umbriel"):
                        try:
                            watch = subprocess.Popen(
                                ["umbriel", "subscribe", "windows,workspaces"],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            )
                            self._window_watch = watch
                        except OSError as exc:
                            log.debug("Umbriel window subscription unavailable: %s", exc)
                try:
                    with _window_transaction():
                        reconcile_miniplayer(_umbriel_windows_json())
                        payload = probe_cider_window()
                    # Unlist while the session is alive is loft (KTD1). Chip hide
                    # waits for socket/API death, not a missing window row.
                    body = json.dumps(payload, ensure_ascii=False)
                    if body != last_body:
                        _write_window(payload)
                        last_body = body
                except Exception as exc:
                    log.debug("window probe failed: %s", exc)
                if self._stop.is_set():
                    break
                if watch is not None and watch.stdout is not None:
                    try:
                        # Native events wake reconciliation immediately. Drain
                        # each burst once; re-query under the transaction lock.
                        if select.select([watch.stdout], [], [], 1.0)[0]:
                            if not os.read(watch.stdout.fileno(), 65536):
                                _close_umbriel_watch(watch)
                                watch = None
                                self._window_watch = None
                    except (OSError, ValueError) as exc:
                        log.debug("Umbriel window subscription ended: %s", exc)
                        _close_umbriel_watch(watch)
                        watch = None
                        self._window_watch = None
                if watch is None:
                    self._stop.wait(_WINDOW_POLL_SEC)
        finally:
            if watch is not None:
                _close_umbriel_watch(watch)
            self._window_watch = None

    def _run_sio(self) -> None:
        while not self._stop.is_set():
            if self._sio.connected:
                self._stop.wait(1)
                continue
            try:
                self._sio.connect(
                    self.base_url,
                    transports=["websocket", "polling"],
                    wait=True,
                    wait_timeout=10,
                )
            except Exception as exc:
                # Wipe durable snapshots — otherwise Luau rehydrates a stale
                # "playing" track from state.json and fires ghost notifications.
                with _EMIT_LOCK:
                    if not getattr(self, "_provider_clock_active", False):
                        self._track_key = ""
                        self._lyrics_key = ""
                        self._last = {}
                        self._provider_clock_sample = None
                        emit(TrackEvent(type="clear"))
                    emit(TrackEvent(type="status", message=f"connect_failed:{exc}"))
                self._stop.wait(5)

    def _poll_loop(self) -> None:
        while not self._stop.is_set():
            self._stop.wait(self.poll_interval_sec)
            if not self._stop.is_set():
                self.refresh_snapshot()

    def refresh_snapshot(self) -> None:
        # Connect and the poll loop can both request a snapshot. Never let an
        # older response finish after a newer one and resemble a native rewind.
        if not self._snapshot_lock.acquire(blocking=False):
            return
        try:
            resp = self._session.get(
                f"{self.base_url}/api/v2/playback",
                timeout=1,
            )
            legacy = resp.status_code in {403, 404}
            if legacy:
                with _EMIT_LOCK:
                    self._provider_clock_active = False
                resp = self._session.get(
                    f"{self.base_url}/api/v1/playback/now-playing",
                    timeout=5,
                )
            if resp.status_code in {404, 502, 503, 504}:
                with _EMIT_LOCK:
                    self._provider_clock_active = False
                    self._note_api_dead(f"http_{resp.status_code}")
                return
            if resp.status_code != 200:
                with _EMIT_LOCK:
                    self._provider_clock_active = False
                return
            payload = resp.json()
            if not isinstance(payload, dict):
                raise ValueError("invalid snapshot payload")
            reason = "snapshot"
            if legacy:
                if "info" not in payload and "data" not in payload:
                    raise ValueError("missing legacy playback")
                info = payload.get("info") or payload.get("data") or {}
                if not isinstance(info, dict):
                    raise ValueError("invalid legacy playback")
            else:
                snapshot = payload.get("data")
                if not isinstance(snapshot, dict) or "nowPlaying" not in snapshot:
                    raise ValueError("missing provider playback")
                state = snapshot.get("state")
                if not isinstance(state, str) or state not in {"playing", "paused", "stopped"}:
                    raise ValueError("invalid provider playback state")
                timing = snapshot.get("time")
                if not isinstance(timing, dict):
                    raise ValueError("missing provider clock")
                current = timing.get("currentTime")
                duration = timing.get("duration")
                if any(isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) or v < 0
                       for v in (current,) + ((duration,) if duration is not None else ())):
                    raise ValueError("invalid provider clock")
                info = snapshot["nowPlaying"]
                if info is not None:
                    if not isinstance(info, dict) or not any(info.get(k) for k in ("name", "title", "artistName", "artist")):
                        raise ValueError("invalid provider track")
                    # v2 reads the reactive provider clock, updated immediately
                    # on seek; v1 attributes lag behind engine time events.
                    info = dict(info, currentPlaybackTime=current, _playback_state=state)
                    if duration is not None:
                        info["durationInMillis"] = int(duration * 1000)
                    reason = "clock"
            with _EMIT_LOCK:
                active = not legacy and getattr(self, "poll_interval_sec", 0.0) > 0
                if active and not getattr(self, "_provider_clock_active", False):
                    self._provider_clock_generation = getattr(self, "_provider_clock_generation", 0) + 1
                self._provider_clock_active = active
                self._api_fail_streak = 0
                if not info:
                    self._provider_clock_sample = None
                    # Empty payload with a live API usually means nothing loaded.
                    if self._last:
                        self._track_key = ""
                        self._lyrics_key = ""
                        self._last = {}
                        emit(TrackEvent(type="clear"))
                    return
                if not legacy:
                    self._emit_from_attrs(info, reason=reason)
                    return
            self._emit_from_attrs(info, reason=reason)
        except (TypeError, ValueError) as exc:
            with _EMIT_LOCK:
                self._provider_clock_active = False
            log.debug("malformed snapshot: %s", exc)
        except Exception as exc:
            with _EMIT_LOCK:
                self._provider_clock_active = False
                self._note_api_dead(str(exc))
            log.debug("snapshot failed: %s", exc)
        finally:
            self._snapshot_lock.release()

    def _note_api_dead(self, reason: str) -> None:
        self._api_fail_streak = getattr(self, "_api_fail_streak", 0) + 1
        # A few blips are fine; sustained failure means Cider is gone.
        if self._api_fail_streak < 3:
            return
        if not self._last and not self._track_key:
            return
        log.info("cider api dead (%s) — clearing now-playing", reason)
        self._track_key = ""
        self._lyrics_key = ""
        self._last = {}
        self._api_fail_streak = 0
        emit(TrackEvent(type="clear"))
        emit(TrackEvent(type="status", message=f"api_dead:{reason}"))

    def _handle_event(self, event_type: str, data: Any) -> None:
        # Cider can emit a fresh engine timestamp with the pre-seek position
        # while its provider clock already holds the requested seek target.
        with _EMIT_LOCK:
            if getattr(self, "_provider_clock_active", False):
                return
            generation = getattr(self, "_provider_clock_generation", 0)
            if event_type == "playbackStatus.nowPlayingItemDidChange":
                if not isinstance(data, dict):
                    return
                attrs, reason = data, "track"
            elif event_type == "playbackStatus.playbackStateDidChange":
                state_payload = data if isinstance(data, dict) else {}
                state = str(state_payload.get("state", self._last.get("playback_state", "stopped"))).lower()
                source = state_payload.get("attributes") or self._last
                attrs = dict(source) if isinstance(source, dict) else dict(self._last)
                attrs["_playback_state"] = state
                reason = "state"
            elif event_type == "playbackStatus.playbackTimeDidChange":
                self._provider_clock_sample = None
                time_payload = data if isinstance(data, dict) else {}
                current = float(time_payload.get("currentPlaybackTime", 0))
                duration = float(time_payload.get("currentPlaybackDuration", 0))
                playing = bool(time_payload.get("isPlaying"))
                position_ms = int(current * 1000)
                duration_ms = int(duration * 1000) or int(self._last.get("duration_ms", 0))
                playback_state = "playing" if playing else "paused"
                # Keep metadata timestamps synchronized with the socket clock.
                if self._last:
                    self._last["position_ms"] = position_ms
                    self._last["duration_ms"] = duration_ms
                    self._last["playback_state"] = playback_state
                event = TrackEvent(
                    type="time",
                    title=str(self._last.get("title", "")),
                    artist=str(self._last.get("artist", "")),
                    album=str(self._last.get("album", "")),
                    artwork_path=str(self._last.get("artwork_path", "")),
                    song_id=str(self._last.get("song_id", "")),
                    catalog_id=str(self._last.get("catalog_id", "")),
                    position_ms=position_ms,
                    duration_ms=duration_ms,
                    playback_state=playback_state,
                )
                emit(event)
                return
            else:
                return
        self._emit_from_attrs(attrs, reason, source_generation=generation)

    def _emit_from_attrs(self, attrs: dict[str, Any], reason: str, *, source_generation: int | None = None) -> None:
        title = str(attrs.get("name") or attrs.get("title") or "")
        artist = str(attrs.get("artistName") or attrs.get("artist") or "")
        album = str(attrs.get("albumName") or attrs.get("album") or "")
        play_params = attrs.get("playParams") if isinstance(attrs.get("playParams"), dict) else {}
        catalog_id = resolve_catalog_id(attrs, play_params)
        song_id = str(play_params.get("id") or attrs.get("song_id") or catalog_id or "")
        isrc = str(attrs.get("isrc") or "")
        duration_ms = int(attrs.get("durationInMillis") or attrs.get("duration_ms") or 0)
        key = display_track_id({"title": title, "artist": artist})
        fresh_position = False
        if attrs.get("currentPlaybackTime") is not None:
            position_ms = int(float(attrs["currentPlaybackTime"]) * 1000)
            fresh_position = True
        elif attrs.get("remainingTime") is not None and duration_ms:
            position_ms = max(0, duration_ms - int(float(attrs["remainingTime"]) * 1000))
            fresh_position = True
        else:
            # No fresh Cider timestamp — keep the live extrapolated clock in
            # memory, but do not rewrite position.json (that re-anchored `t`
            # and could amplify drift).
            position_ms = 0
            fresh_position = False
        artwork = attrs.get("artwork") or attrs.get("artwork_url") or {}
        artwork_url = ""
        if isinstance(artwork, dict):
            artwork_url = str(artwork.get("url") or "")
        elif isinstance(artwork, str):
            artwork_url = artwork
        artwork_url = _normalize_artwork_url(artwork_url)
        cache_key = catalog_id or song_id or artwork_url
        with _EMIT_LOCK:
            if reason != "clock" and getattr(self, "_provider_clock_active", False):
                return
            if source_generation is None:
                source_generation = getattr(self, "_provider_clock_generation", 0)
        # Native clock polls must never wait for an artwork download. Socket
        # fallback may fetch it, then rechecks ownership before publishing.
        artwork_path = str(attrs.get("artwork_path") or "")
        if reason != "clock" and artwork_url:
            artwork_path = self._cache_artwork(artwork_url, cache_key)
        with _EMIT_LOCK:
            if reason != "clock" and (
                getattr(self, "_provider_clock_active", False)
                or source_generation != getattr(self, "_provider_clock_generation", 0)
            ):
                return
            if not title and not artist:
                emit(TrackEvent(type="clear"))
                self._track_key = ""
                self._provider_clock_sample = None
                return
            catalog_changed = bool(catalog_id) and catalog_id != self._last.get("catalog_id")
            is_new_track = key != self._track_key or (catalog_changed and bool(self._last.get("catalog_id")))
            artwork_changed = artwork_url != self._last.get("artwork_url")
            if not is_new_track:
                catalog_id = catalog_id or str(self._last.get("catalog_id") or "")
                song_id = song_id or str(self._last.get("song_id") or "")
                album = album or str(self._last.get("album") or "")
                duration_ms = duration_ms or int(self._last.get("duration_ms") or 0)
                if not artwork_changed and not artwork_path:
                    artwork_path = str(self._last.get("artwork_path") or "")
            lyrics_changed = (catalog_changed or album != self._last.get("album")
                              or duration_ms != self._last.get("duration_ms"))
            cache_key = catalog_id or song_id or artwork_url
            if not fresh_position:
                position_ms = 0 if is_new_track else _estimated_position_ms()
            # Never default to "playing" — queue-load can leave a track at rest.
            raw_state = (attrs.get("_playback_state") or attrs.get("playbackState")
                         or attrs.get("status") or attrs.get("playerState"))
            state = str(raw_state or self._last.get("playback_state") or "paused").lower()
            if state in {"play", "playing", "true", "1"}:
                state = "playing"
            elif state in {"pause", "paused", "false", "0"}:
                state = "paused"
            elif state in {"stop", "stopped", "idle"}:
                state = "stopped"
            if state not in {"playing", "paused", "stopped"}:
                state = "paused"
            event_type = "track" if is_new_track else ("time" if reason == "clock" else "state")
            # Metadata-only snapshots leave the clock alone, but pause/resume
            # must freeze/restart it even without a fresh timestamp.
            skip_position = (not fresh_position) and event_type != "track" and state == self._last.get("playback_state")
            provider_rewind = False
            if reason == "clock":
                previous = getattr(self, "_provider_clock_sample", None)
                previous_position = previous[0] if previous is not None else _POS_ANCHOR_MS
                provider_rewind = not is_new_track and (
                    position_ms < previous_position or
                    (state == "paused" and previous is not None and previous[1] == "paused"
                     and position_ms != previous_position)
                )
                sample = (position_ms, state)
                skip_position = not is_new_track and sample == previous
                if (not is_new_track and not provider_rewind and state == "playing"
                        and self._last.get("playback_state") == state
                        and position_ms < _estimated_position_ms()):
                    skip_position = True
                self._provider_clock_sample = sample
            else:
                self._provider_clock_sample = None
            event = TrackEvent(
                type=event_type,
                title=title,
                artist=artist,
                album=album,
                artwork_path=artwork_path,
                artwork_url=artwork_url,
                position_ms=max(0, position_ms),
                duration_ms=max(0, duration_ms),
                playback_state=state,
                song_id=song_id,
                catalog_id=catalog_id,
                isrc=isrc,
                has_lyrics=bool(attrs.get("hasLyrics", attrs.get("has_lyrics"))),
                has_synced=bool(attrs.get("hasTimeSyncedLyrics", attrs.get("has_synced"))),
                skip_position=skip_position,
            )
            self._last = asdict(event)
            self._last["playback_state"] = state
            if is_new_track:
                self._lyrics_key = ""
            self._track_key = key
            if provider_rewind:
                emit(event, provider_rewind=True)
            else:
                emit(event)

        if (is_new_track or artwork_changed) and artwork_url and not artwork_path:
            threading.Thread(
                target=self._retry_artwork,
                args=(key, artwork_url, cache_key),
                name="cider-art",
                daemon=True,
            ).start()

        if is_new_track or lyrics_changed:
            threading.Thread(
                target=self._fetch_lyrics,
                args=(event, key),
                name="cider-lyrics",
                daemon=True,
            ).start()

    def _cache_artwork(self, url: str, cache_key: str = "") -> str:
        import requests

        url = _normalize_artwork_url(url)
        if not url:
            return ""
        stem = cache_key or url
        digest = hashlib.sha256(stem.encode()).hexdigest()[:16]
        ext = Path(urlparse(url).path).suffix.lower()
        if ext not in {".jpg", ".jpeg", ".png", ".webp"}:
            ext = ".jpg"
        dest = self.cache_dir / f"{digest}{ext}"
        if dest.exists() and dest.stat().st_size > 0:
            return str(dest)
        with self._art_lock:
            if dest.exists() and dest.stat().st_size > 0:
                return str(dest)
            try:
                # Tokened Session is only for Cider's local API. Artwork URLs are
                # Apple Music CDN (*.mzstatic.com) — same bare get as LRCLIB.
                resp = requests.get(url, timeout=10)
                resp.raise_for_status()
                if not resp.content:
                    return ""
                dest.write_bytes(resp.content)
                return str(dest)
            except Exception as exc:
                log.debug("artwork failed: %s", exc)
                return ""

    def _retry_artwork(self, track_key: str, url: str, cache_key: str) -> None:
        for delay in (0.15, 0.4, 1.0):
            time.sleep(delay)
            with _EMIT_LOCK:
                if (track_key != self._track_key or url != self._last.get("artwork_url")
                        or cache_key != (self._last.get("catalog_id") or self._last.get("song_id") or url)):
                    return
            path = self._cache_artwork(url, cache_key)
            if not path:
                continue
            with _EMIT_LOCK:
                if (track_key != self._track_key or url != self._last.get("artwork_url")
                        or cache_key != (self._last.get("catalog_id") or self._last.get("song_id") or url)):
                    return
                self._last["artwork_path"] = path
                self._last["artwork_url"] = url
                emit(
                    TrackEvent(
                        type="art",
                        title=str(self._last.get("title", "")),
                        artist=str(self._last.get("artist", "")),
                        album=str(self._last.get("album", "")),
                        artwork_path=path,
                        artwork_url=url,
                        position_ms=int(self._last.get("position_ms", 0)),
                        duration_ms=int(self._last.get("duration_ms", 0)),
                        playback_state=str(self._last.get("playback_state", "playing")),
                        song_id=str(self._last.get("song_id", "")),
                        catalog_id=str(self._last.get("catalog_id", "")),
                    )
                )
            return
    def _fetch_lyrics(self, track: TrackEvent, track_key: str) -> None:
        lyrics_key = f"{track_key}|{track.album}|{track.duration_ms}|{track.catalog_id}"
        if self._lyrics_key == lyrics_key:
            return
        lines: list[dict[str, Any]] = []
        lrc = ""
        if track.catalog_id:
            lines, lrc = self._lyrics_amapi(track.catalog_id)
        synced = bool(lines) and int(lines[0].get("time", -1)) >= 0
        # Prefer LRCLIB synced over Apple untimed plain.
        if not synced:
            lr_lines, lr_lrc = self._lyrics_lrclib(track)
            if lr_lines and int(lr_lines[0].get("time", -1)) >= 0:
                lines, lrc = lr_lines, lr_lrc
                synced = True
            elif not lines and lr_lines:
                lines, lrc = lr_lines, lr_lrc
        # A slow fetch for the old song/source must not replace current lyrics.
        if (track_key != self._track_key or track.catalog_id != self._last.get("catalog_id")
                or track.album != self._last.get("album") or track.duration_ms != self._last.get("duration_ms")):
            return
        if not lines and not lrc:
            # Publishing the empty result clears lyrics under emit's track lock.
            emit(
                TrackEvent(
                    type="lyrics",
                    message="none",
                    title=track.title,
                    artist=track.artist,
                    album=track.album,
                    artwork_path=track.artwork_path,
                    artwork_url=track.artwork_url,
                    position_ms=int(self._last.get("position_ms", track.position_ms) or 0),
                    duration_ms=int(self._last.get("duration_ms", track.duration_ms) or 0),
                    playback_state=str(self._last.get("playback_state", track.playback_state)),
                    catalog_id=track.catalog_id,
                    song_id=track.song_id,
                )
            )
            return
        self._lyrics_key = lyrics_key
        # Stamp with live clock so first lyrics.json is not stuck at fetch start.
        position_ms = int(self._last.get("position_ms", track.position_ms) or 0)
        duration_ms = int(self._last.get("duration_ms", track.duration_ms) or 0)
        emit(
            TrackEvent(
                type="lyrics",
                title=track.title,
                artist=track.artist,
                album=track.album,
                artwork_path=track.artwork_path,
                artwork_url=track.artwork_url,
                position_ms=position_ms,
                duration_ms=duration_ms,
                playback_state=str(self._last.get("playback_state", track.playback_state)),
                catalog_id=track.catalog_id,
                song_id=track.song_id,
                lyrics_lrc=lrc,
                lyrics_lines=lines or None,
                has_synced=synced,
                message="synced" if synced else "plain",
            )
        )

    def _lyrics_amapi(self, catalog_id: str) -> tuple[list[dict[str, Any]], str]:
        """Prefer syllable-lyrics (word pacing) then fall back to line lyrics."""
        paths = (
            f"/v1/catalog/{{sf}}/songs/{catalog_id}/syllable-lyrics",
            f"/v1/catalog/{{sf}}/songs/{catalog_id}/lyrics",
        )
        best_line_only: tuple[list[dict[str, Any]], str] | None = None
        for storefront in ("us", "gb", "ca", "au", "de", "jp"):
            for path_tmpl in paths:
                path = path_tmpl.format(sf=storefront)
                try:
                    resp = self._session.post(
                        f"{self.base_url}/api/v1/amapi/run-v3",
                        json={"path": path},
                        timeout=12,
                    )
                    if resp.status_code != 200:
                        continue
                    body = resp.json()
                    data = body.get("data") or body
                    items = data.get("data") if isinstance(data, dict) else None
                    if not items:
                        continue
                    attrs = items[0].get("attributes") or {}
                    ttml = attrs.get("ttml") or attrs.get("ttmlLocalizations")
                    if not ttml:
                        continue
                    lines, lrc = ttml_to_lines(ttml)
                    if not lines:
                        continue
                    has_words = any(isinstance(L.get("words"), list) and L["words"] for L in lines)
                    if has_words or "syllable-lyrics" in path:
                        log.info("amapi lyrics via %s (words=%s)", path, has_words)
                        return lines, lrc
                    # Keep line-timed as fallback; keep searching for syllable.
                    if best_line_only is None:
                        best_line_only = (lines, lrc)
                except Exception as exc:
                    log.debug("amapi lyrics %s failed: %s", path, exc)
        if best_line_only is not None:
            return best_line_only
        return [], ""

    def _lyrics_lrclib(self, track: TrackEvent) -> tuple[list[dict[str, Any]], str]:
        import requests

        params = {
            "track_name": track.title,
            "artist_name": track.artist,
        }
        if track.album:
            params["album_name"] = track.album
        if track.duration_ms:
            params["duration"] = str(max(1, track.duration_ms // 1000))
        try:
            resp = requests.get("https://lrclib.net/api/get", params=params, timeout=10)
            if resp.status_code != 200:
                return [], ""
            data = resp.json()
            synced = data.get("syncedLyrics") or ""
            plain = data.get("plainLyrics") or ""
            if synced:
                lines = []
                for match in re.finditer(
                    r"\[(\d+):(\d+(?:\.\d+)?)\](.*)",
                    synced,
                ):
                    mins, secs, text = match.groups()
                    ms = int(mins) * 60_000 + int(float(secs) * 1000)
                    lines.append(
                        {
                            "time": ms,
                            "duration": 3000,
                            "text": text.strip(),
                            "duration_inferred": True,
                        }
                    )
                return finalize_synced_lines(lines), synced
            if plain:
                lines = [
                    {"time": -1, "text": line.strip()}
                    for line in plain.splitlines()
                    if line.strip()
                ]
                return lines, plain
        except Exception as exc:
            log.debug("lrclib failed: %s", exc)
        return [], ""


def main() -> int:
    parser = argparse.ArgumentParser(description="Cider → Noctalia bridge")
    parser.add_argument("--base-url", default=os.environ.get("CIDER_BASE_URL", "http://127.0.0.1:10767"))
    parser.add_argument("--token", default=os.environ.get("CIDER_APPTOKEN", ""))
    parser.add_argument(
        "--cache-dir",
        default=os.environ.get(
            "CIDER_ART_CACHE",
            str(Path.home() / ".cache" / "noctalia-cider" / "art"),
        ),
    )
    parser.add_argument(
        "--state-dir",
        default=os.environ.get(
            "CIDER_STATE_DIR",
            str(Path.home() / ".cache" / "noctalia-cider"),
        ),
    )
    parser.add_argument("--poll", type=float, default=0.0)
    parser.add_argument("--log-level", default="WARNING")
    parser.add_argument(
        "--toggle-loft",
        action="store_true",
        help="One-shot Umbriel loft send/restore; do not start the bridge.",
    )
    parser.add_argument("--show-window", action="store_true",
                        help="One-shot launcher restore; exit 1 when Cider needs launching.")
    args = parser.parse_args()
    logging.basicConfig(level=getattr(logging, args.log_level.upper(), logging.WARNING))
    global _STATE_DIR
    _STATE_DIR = Path(args.state_dir).expanduser()

    if args.toggle_loft or args.show_window:
        try:
            with _window_transaction():
                return show_cider_window() if args.show_window else toggle_loft()
        except Exception as exc:
            log.error("Cider window action failed: %s", exc)
            return 2

    _STATE_DIR.mkdir(parents=True, exist_ok=True)

    if not args.token:
        token_file = _STATE_DIR / "apptoken"
        if token_file.is_file():
            try:
                args.token = token_file.read_text(encoding="utf-8").strip()
            except OSError:
                pass
    if not args.token:
        # Fall back to legacy kde notifier config
        legacy = Path.home() / ".config" / "cider-kde-notifier" / "config.json"
        if legacy.exists():
            try:
                cfg = json.loads(legacy.read_text(encoding="utf-8"))
                args.token = str((cfg.get("cider") or {}).get("apptoken") or "")
                args.base_url = str((cfg.get("cider") or {}).get("base_url") or args.base_url)
            except Exception:
                pass

    bridge = CiderBridge(args.base_url, args.token, Path(args.cache_dir), args.poll)
    previous_term = signal.signal(signal.SIGTERM, lambda _signal, _frame: bridge._stop.set())
    try:
        bridge.start()
    except KeyboardInterrupt:
        pass
    finally:
        try:
            bridge.stop()
        finally:
            signal.signal(signal.SIGTERM, previous_term)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
