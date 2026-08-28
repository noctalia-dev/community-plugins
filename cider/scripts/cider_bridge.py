#!/usr/bin/env python3
"""Cider → Noctalia bridge: track metadata, artwork, lyrics (stdout NDJSON)."""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import xml.etree.ElementTree as ET
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Callable
from urllib.parse import quote, urlparse

import requests
import socketio

_SCRIPTS_DIR = Path(__file__).resolve().parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))
from lyrics_overlay_cfg import restore_word_spacing  # noqa: E402

log = logging.getLogger("cider-bridge")

TrackCallback = Callable[["TrackEvent"], None]

_STATE_DIR = Path.home() / ".cache" / "noctalia-cider"
_EVENT_SEQ = 0
_CIDER_APP_IDS = {"cider", "org.xcider.cider", "Cider"}
_WINDOW_POLL_SEC = 0.35


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


_EMIT_LOCK = threading.Lock()


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
# Untrusted poll/state samples: reject tiny forward spikes, ignore mild behind
# snaps. Trusted time events (real Cider playbackTimeDidChange / new track)
# always re-anchor so scrubbing seeks track immediately.
_AHEAD_REJECT_MS = 400
_STALE_REWIND_MIN_MS = 350
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
) -> None:
    """Write last-known Cider anchor. HUD/Luau extrapolate between ticks.

    Never store wall-clock-extrapolated values here — that double-counts with
    consumers.

    trust=True  — live playbackTimeDidChange / new track: always re-anchor so
                  scrubbing seeks move lyrics immediately.
    trust=False — poll/state snapshots: reject spurious ahead spikes, ignore
                  mild behind snaps, but accept |delta| >= SEEK as a seek.
    """
    global _POS_ANCHOR_MS, _POS_ANCHOR_WALL, _POS_PLAYING, _POS_DURATION_MS
    position_ms = max(0, int(position_ms))
    playing = bool(playing)
    duration_ms = max(0, int(duration_ms or 0))

    with _POS_LOCK:
        if duration_ms:
            _POS_DURATION_MS = duration_ms
        dur = _POS_DURATION_MS
        if (not trust) and _POS_ANCHOR_WALL > 0 and _POS_PLAYING:
            elapsed = max(0, int((time.time() - _POS_ANCHOR_WALL) * 1000))
            est = _POS_ANCHOR_MS + elapsed
            if dur > 0:
                est = min(est, dur)
            delta = position_ms - est  # +ahead of clock, -behind
            if playing:
                if delta > _AHEAD_REJECT_MS:
                    # Spurious forward spike from a poll. Forward seeks arrive on
                    # trusted playbackTimeDidChange ticks instead.
                    return
                rewind = -delta
                if _STALE_REWIND_MIN_MS <= rewind < _SEEK_ACCEPT_MS:
                    # Mild behind from a stale poll — don't scrub.
                    return
                # rewind >= SEEK_ACCEPT: treat as scrub/seek backward.
            elif (-delta) >= _STALE_REWIND_MIN_MS:
                # Pause with a stale timestamp: freeze at the live estimate.
                position_ms = est

        _POS_ANCHOR_MS = position_ms
        _POS_ANCHOR_WALL = time.time()
        _POS_PLAYING = playing

    payload = {
        "position_ms": position_ms,
        "playing": playing,
        "duration_ms": dur,
        "remaining_ms": max(0, dur - position_ms) if dur else 0,
        "t": time.time(),
    }
    _atomic_write(_STATE_DIR / "position.json", json.dumps(payload, ensure_ascii=False))


def _is_cider_window(app_id: str | None, title: str | None = None) -> bool:
    aid = (app_id or "").strip()
    if aid in _CIDER_APP_IDS or aid.lower() == "cider":
        return True
    return (title or "").strip().lower() == "cider"


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


def probe_cider_window() -> dict[str, Any]:
    """Detect Cider focus / on-screen state for notification suppression."""
    empty = {
        "present": False,
        "focused": False,
        "on_screen": False,
        "suppress_notify": False,
        "compositor": "none",
        "t": time.time(),
    }
    if shutil.which("niri"):
        windows = _niri_json(["niri", "msg", "-j", "windows"])
        workspaces = _niri_json(["niri", "msg", "-j", "workspaces"])
        outputs = _niri_json(["niri", "msg", "-j", "outputs"])
        if not isinstance(windows, list) or not isinstance(workspaces, list):
            empty["compositor"] = "niri"
            return empty
        cider = next(
            (
                w
                for w in windows
                if _is_cider_window(w.get("app_id"), w.get("title"))
            ),
            None,
        )
        if cider is None:
            empty["compositor"] = "niri"
            return empty
        focused = bool(cider.get("is_focused"))
        on_screen = _niri_cider_on_screen(
            cider,
            windows,
            workspaces,
            outputs if isinstance(outputs, dict) else {},
        )
        return {
            "present": True,
            "focused": focused,
            "on_screen": on_screen,
            "suppress_notify": focused or on_screen,
            "compositor": "niri",
            "t": time.time(),
        }

    if shutil.which("hyprctl"):
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
            empty["compositor"] = "hyprland"
            return empty
        cider = next(
            (
                c
                for c in (clients or [])
                if _is_cider_window(c.get("class"), c.get("title"))
            ),
            None,
        )
        if cider is None:
            empty["compositor"] = "hyprland"
            return empty
        focused = bool(active) and active.get("address") == cider.get("address")
        # Without viewport math, treat same-workspace mapped window as on-screen.
        on_screen = focused or (
            not cider.get("hidden", False)
            and cider.get("workspace", {}).get("id") == (active or {}).get("workspace", {}).get("id")
        )
        return {
            "present": True,
            "focused": focused,
            "on_screen": bool(on_screen),
            "suppress_notify": focused or bool(on_screen),
            "compositor": "hyprland",
            "t": time.time(),
        }

    return empty


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


def emit(event: TrackEvent) -> None:
    global _EVENT_SEQ
    payload = asdict(event)
    if payload.get("lyrics_lines") is None:
        payload.pop("lyrics_lines", None)
    skip_position = bool(payload.pop("skip_position", False))
    body = json.dumps(payload, ensure_ascii=False)
    with _EMIT_LOCK:
        _STATE_DIR.mkdir(parents=True, exist_ok=True)
        # Continuous snapshot for progress polling
        if event.type in {"track", "time", "state", "art"}:
            _atomic_write(_STATE_DIR / "state.json", body)
            if event.type in {"track", "time", "state"} and not skip_position:
                _write_position(
                    int(event.position_ms or 0),
                    str(event.playback_state or "") == "playing",
                    int(event.duration_ms or 0),
                    # Live time ticks + new tracks are authoritative (seeks).
                    # Snapshot/state polls stay filtered against sprint/scrub noise.
                    trust=event.type in {"time", "track"},
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
        for sub in child:
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
            end = begin + max(120, len(text) * 80)
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
        self._art_lock = threading.Lock()
        self._track_key = ""
        self._lyrics_key = ""
        self._last: dict[str, Any] = {}
        self._api_fail_streak = 0
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
            # Cider quit / API down — wipe now-playing so the bar chip goes idle.
            self._track_key = ""
            self._lyrics_key = ""
            self._last = {}
            emit(TrackEvent(type="clear"))
            emit(TrackEvent(type="status", message="disconnected"))

    def start(self) -> None:
        # Drop leftovers from a previous session until a live snapshot arrives.
        # Otherwise Luau can rehydrate a stale playing track after Cider quit.
        _wipe_playback_sidecars()
        threading.Thread(target=self._run_sio, name="cider-sio", daemon=True).start()
        if self.poll_interval_sec > 0:
            threading.Thread(target=self._poll_loop, name="cider-poll", daemon=True).start()
        threading.Thread(target=self._window_loop, name="cider-window", daemon=True).start()
        while not self._stop.is_set():
            self._stop.wait(1)

    def stop(self) -> None:
        self._stop.set()
        try:
            self._sio.disconnect()
        except Exception:
            pass

    def _window_loop(self) -> None:
        last_body = ""
        was_present = False
        while not self._stop.is_set():
            try:
                payload = probe_cider_window()
                present = payload.get("present") is True
                # Closing Cider removes its window — clear immediately instead of
                # waiting for socket/API death (that lag left the bar chip stuck).
                if was_present and not present:
                    self._track_key = ""
                    self._lyrics_key = ""
                    self._last = {}
                    emit(TrackEvent(type="clear"))
                    emit(TrackEvent(type="status", message="cider_closed"))
                was_present = present
                body = json.dumps(payload, ensure_ascii=False)
                if body != last_body:
                    _write_window(payload)
                    last_body = body
            except Exception as exc:
                log.debug("window probe failed: %s", exc)
            self._stop.wait(_WINDOW_POLL_SEC)

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
                self._track_key = ""
                self._lyrics_key = ""
                self._last = {}
                emit(TrackEvent(type="clear"))
                emit(TrackEvent(type="status", message=f"connect_failed:{exc}"))
                self._stop.wait(5)

    def _poll_loop(self) -> None:
        while not self._stop.is_set():
            self._stop.wait(self.poll_interval_sec)
            if not self._stop.is_set():
                self.refresh_snapshot()

    def refresh_snapshot(self) -> None:
        try:
            resp = self._session.get(
                f"{self.base_url}/api/v1/playback/now-playing",
                timeout=5,
            )
            if resp.status_code in {404, 502, 503, 504}:
                self._note_api_dead(f"http_{resp.status_code}")
                return
            if resp.status_code != 200:
                return
            self._api_fail_streak = 0
            info = (resp.json().get("info") or resp.json().get("data") or {})
            if not info:
                # Empty payload with a live API usually means nothing loaded.
                if self._last:
                    self._track_key = ""
                    self._lyrics_key = ""
                    self._last = {}
                    emit(TrackEvent(type="clear"))
                return
            # Never mark poll snapshots as "track" — that re-fires OSD and races lyrics events.
            self._emit_from_attrs(info, reason="snapshot")
        except Exception as exc:
            log.debug("snapshot failed: %s", exc)
            self._note_api_dead(str(exc))

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
        if event_type == "playbackStatus.nowPlayingItemDidChange":
            if isinstance(data, dict):
                self._emit_from_attrs(data, reason="track")
            return
        if event_type == "playbackStatus.playbackStateDidChange":
            state_payload = data if isinstance(data, dict) else {}
            state = str(state_payload.get("state", self._last.get("playback_state", "stopped"))).lower()
            attrs = state_payload.get("attributes") or self._last
            merged = dict(attrs) if isinstance(attrs, dict) else dict(self._last)
            merged["_playback_state"] = state
            self._emit_from_attrs(merged, reason="state")
            return
        if event_type == "playbackStatus.playbackTimeDidChange":
            time_payload = data if isinstance(data, dict) else {}
            current = float(time_payload.get("currentPlaybackTime", 0))
            duration = float(time_payload.get("currentPlaybackDuration", 0))
            playing = bool(time_payload.get("isPlaying"))
            position_ms = int(current * 1000)
            duration_ms = int(duration * 1000) or int(self._last.get("duration_ms", 0))
            playback_state = "playing" if playing else "paused"
            # Keep _last in sync — state/snapshot without a timestamp must not
            # re-anchor the karaoke clock to a track-start leftover.
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
                position_ms=position_ms,
                duration_ms=duration_ms,
                playback_state=playback_state,
            )
            emit(event)
            return

    def _emit_from_attrs(self, attrs: dict[str, Any], reason: str) -> None:
        title = str(attrs.get("name") or attrs.get("title") or "")
        artist = str(attrs.get("artistName") or attrs.get("artist") or "")
        album = str(attrs.get("albumName") or attrs.get("album") or "")
        if not title and not artist:
            emit(TrackEvent(type="clear"))
            self._track_key = ""
            return

        play_params = attrs.get("playParams") if isinstance(attrs.get("playParams"), dict) else {}
        catalog_id = resolve_catalog_id(attrs, play_params)
        song_id = str(play_params.get("id") or catalog_id or "")
        isrc = str(attrs.get("isrc") or "")
        duration_ms = int(attrs.get("durationInMillis") or 0)
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
            position_ms = _estimated_position_ms() if self._last else 0
            fresh_position = False

        artwork = attrs.get("artwork") or {}
        artwork_url = ""
        if isinstance(artwork, dict):
            artwork_url = str(artwork.get("url") or "")
        elif isinstance(artwork, str):
            artwork_url = artwork
        artwork_url = _normalize_artwork_url(artwork_url)

        cache_key = catalog_id or song_id or artwork_url
        artwork_path = self._cache_artwork(artwork_url, cache_key) if artwork_url else ""
        # Never default to "playing" — launch / queue-load often has a track at rest.
        raw_state = (
            attrs.get("_playback_state")
            or attrs.get("playbackState")
            or attrs.get("status")
            or attrs.get("playerState")
        )
        if raw_state is not None and str(raw_state).strip() != "":
            state = str(raw_state).lower()
        else:
            state = str(self._last.get("playback_state") or "paused").lower()
        if state in {"play", "playing", "true", "1"}:
            state = "playing"
        elif state in {"pause", "paused", "false", "0"}:
            state = "paused"
        elif state in {"stop", "stopped", "idle"}:
            state = "stopped"
        # Normalize unknown tokens away from "playing".
        if state not in {"playing", "paused", "stopped"}:
            state = "paused"

        key = f"{catalog_id}|{title}|{artist}|{album}|{duration_ms}"
        is_new_track = key != self._track_key
        event_type = "track" if is_new_track else ("state" if reason in {"state", "snapshot"} else "state")
        if reason == "track" and is_new_track:
            event_type = "track"
        elif reason == "track" and not is_new_track:
            event_type = "state"
        # New tracks always need a position anchor; metadata-only snapshots do not.
        skip_position = (not fresh_position) and event_type != "track"
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
            has_lyrics=bool(attrs.get("hasLyrics")),
            has_synced=bool(attrs.get("hasTimeSyncedLyrics")),
            skip_position=skip_position,
        )
        self._last = asdict(event)
        self._last["playback_state"] = state
        emit(event)

        if is_new_track and artwork_url and not artwork_path:
            threading.Thread(
                target=self._retry_artwork,
                args=(key, artwork_url, cache_key),
                name="cider-art",
                daemon=True,
            ).start()

        if key != self._track_key:
            self._track_key = key
            threading.Thread(
                target=self._fetch_lyrics,
                args=(event,),
                name="cider-lyrics",
                daemon=True,
            ).start()

    def _cache_artwork(self, url: str, cache_key: str = "") -> str:
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
            if track_key != self._track_key:
                return
            path = self._cache_artwork(url, cache_key)
            if not path:
                continue
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
    def _fetch_lyrics(self, track: TrackEvent) -> None:
        if self._lyrics_key == self._track_key:
            return
        lines: list[dict[str, Any]] = []
        lrc = ""
        if track.catalog_id:
            lines, lrc = self._lyrics_amapi(track.catalog_id)
        synced = bool(lines) and int(lines[0].get("time") or -1) >= 0
        # Prefer LRCLIB synced over Apple untimed plain.
        if not synced:
            lr_lines, lr_lrc = self._lyrics_lrclib(track)
            if lr_lines and int(lr_lines[0].get("time") or -1) >= 0:
                lines, lrc = lr_lines, lr_lrc
                synced = True
            elif not lines and lr_lines:
                lines, lrc = lr_lines, lr_lrc
        if not lines and not lrc:
            # Drop stale synced lyrics so the widget does not keep the previous song.
            lyrics_path = _STATE_DIR / "lyrics.json"
            try:
                lyrics_path.unlink(missing_ok=True)
            except TypeError:
                if lyrics_path.exists():
                    lyrics_path.unlink()
            except Exception:
                pass
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
        self._lyrics_key = self._track_key
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
    args = parser.parse_args()
    logging.basicConfig(level=getattr(logging, args.log_level.upper(), logging.WARNING))
    global _STATE_DIR
    _STATE_DIR = Path(args.state_dir).expanduser()
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
    try:
        bridge.start()
    except KeyboardInterrupt:
        bridge.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
