#!/usr/bin/env python3
"""Lyrics HUD overlay presentation config."""

from __future__ import annotations

import math
import os
import re
import time
from pathlib import Path
from typing import Any

# Overlay HUD paint constants.
BLEND_MS = 180
KARAOKE_IN_MS = 320
KARAOKE_OUT_MS = 280
SUNG_RGBA = (1.0, 1.0, 1.0, 1.0)
ACTIVE_RGBA = (1.0, 0.82, 0.45, 1.0)
UPCOMING_ALPHA = 0.38
# Next line: muted grey, not dim white — reads as "upcoming" against current.
NEXT_RGBA = (0.70, 0.70, 0.74, 0.55)
NEXT_ALPHA = NEXT_RGBA[3]
CUE_DIM_ALPHA = 0.22
IDLE_ALPHA = 0.35
HUD_HEIGHT = 96
HUD_HEIGHT_MAX = 240
CURRENT_SLOT_PX = 56
NEXT_GAP_PX = 6
LINE_ANIM_MS = 460
CURRENT_FONT_PX = 22
NEXT_FONT_PX = 13
FAR_FONT_PX = 8
FAR_DROP_PX = 22
PAST_FONT_PX = 37
PAST_LIFT_PX = 42


def next_line_y(current_top: float, current_body_h: float, gap: int = NEXT_GAP_PX) -> float:
    """Park next just under the current glyphs.

    Padding next to CURRENT_SLOT_PX leaves a dead band so the far line looks like
    a separate caption, not the same path further back in Z.
    """
    return float(current_top) + max(1.0, float(current_body_h)) + max(0, int(gap))


def line_swap_slide_px(outgoing_h: int, gap: int = NEXT_GAP_PX) -> int:
    """Vertical travel so the outgoing current line vacates the slot."""
    return max(CURRENT_SLOT_PX, int(outgoing_h or 0)) + max(0, int(gap))


def cue_centered_y(slot_top: float, slot_h: float, ink_y: float, ink_h: float) -> float:
    """Layout origin so period ink sits in the middle of the current slot.

    Pango's layout box is taller than the glyph; centering the box leaves the
    dots on the baseline, hugging the next line.
    """
    ink_h = max(1.0, float(ink_h))
    return float(slot_top) + float(slot_h) / 2.0 - (float(ink_y) + ink_h / 2.0)


def promote_scale(
    u: float,
    next_px: float = NEXT_FONT_PX,
    current_px: float = CURRENT_FONT_PX,
) -> float:
    """Uniform scale of a current-size layout. 2D stand-in for moving forward in Z."""
    t = smoothstep(u)
    nxt = max(1.0, float(next_px))
    cur = max(nxt, float(current_px))
    return (nxt + (cur - nxt) * t) / cur


def depth_pose_px(u: float, start_px: float, dest_px: float) -> float:
    """Visual size along a depth step. dest may be larger or smaller than start."""
    t = smoothstep(u)
    return float(start_px) + (float(dest_px) - float(start_px)) * t


def depth_layout_scale(
    u: float,
    start_px: float,
    dest_px: float,
    layout_px: float,
) -> float:
    """Scale a fixed layout so on-screen size lerps start → dest.

    Cue dots are always laid out at CUE_BASE_PX. promote_scale assumes the
    layout is already dest-sized and dest >= start, so outgoing cues (36 → 60)
    would shrink first and never pass the camera.
    """
    layout = max(1.0, float(layout_px))
    return depth_pose_px(u, start_px, dest_px) / layout


def promote_top_y(u: float, current_y: float, next_y: float) -> float:
    """Visual top of the promoting line as it travels next → current."""
    t = smoothstep(u)
    return float(next_y) + (float(current_y) - float(next_y)) * t


def promote_color_u(u: float) -> float:
    """Stay upcoming-grey while small; pick up current color as it arrives."""
    return smoothstep((float(u) - 0.18) / 0.82)


def approach_u(u: float) -> float:
    """Far → next pose. Starts once the promoter has left the next slot."""
    return smoothstep((float(u) - 0.22) / 0.78)


def successor_next_alpha(u: float) -> float:
    """Opacity follow for the approaching next line."""
    t = approach_u(u)
    return 0.4 + 0.6 * t


def exit_alpha(u: float) -> float:
    """Current line stays readable, then fades as it passes the camera."""
    return 1.0 - smoothstep((float(u) - 0.08) / 0.72)


def line_anim_forward(pos_delta_ms: int, slack_ms: int = 180) -> bool:
    """Legacy tick-delta direction. Prefer line_anim_forward_from_index."""
    return int(pos_delta_ms) >= -max(0, int(slack_ms))


def line_anim_forward_from_index(prev_idx: int, next_idx: int) -> bool:
    """Stack direction from lyric line index (stable across seek settle ticks)."""
    return int(next_idx) >= int(prev_idx)


def line_anim_duration_ms(index_delta: int, base_ms: int = LINE_ANIM_MS) -> int:
    """Adjacent flips get full ease; scrub jumps shorten so motion stays snappy."""
    gap = abs(int(index_delta))
    base = max(180, int(base_ms))
    if gap <= 1:
        return base
    if gap == 2:
        return int(base * 0.82)
    return int(base * 0.68)


def line_anim_interrupt_elapsed_ms(prev_u: float, duration_ms: int) -> float:
    """Keep a little continuity when a seek cuts an in-flight transition."""
    u = float(prev_u)
    if u <= 0.02 or u >= 0.98:
        return 0.0
    return 0.12 * max(180.0, float(duration_ms))


TRACK_CROSS_MS = 1200
TRACK_FADE_MS = 800
SURFACE_ANIM_MS = 420
SURFACE_SLIDE_PX = 12
SIDE_PAD_PX = 64
CURRENT_MAX_LINES = 3
NEXT_MAX_LINES = 2
# Apple-style intro/mix cue: three dots that independently breathe.
CUE_TEXT = "..."
CUE_COUNT = 3
CUE_TEXTS = frozenset({CUE_TEXT, ".....", "…", "•••••"})
CUE_BASE_PX = 36
CUE_FAR_PX = 12
CUE_PAST_PX = 72
CUE_PULSE_PERIOD_S = 4.2
CUE_PULSE_AMP = 0.12
CUE_DOT_GAP_PX = 10

DEFAULT_CFG: dict[str, Any] = {
    "enabled": True,
    "backend": "overlay",
    "position": "top_center",
    "show_next": True,
    "animate_cues": True,
    "show_idle": True,
    "karaoke": True,
    "glow": True,
    "karaoke_style": "theme",
    "sung": "",
    "active": "",
    "upcoming": "",
}


def merge_cfg(raw: dict[str, Any] | None) -> dict[str, Any]:
    cfg = dict(DEFAULT_CFG)
    if not isinstance(raw, dict):
        return cfg
    if raw.get("enabled") is False:
        cfg["enabled"] = False
    cfg["backend"] = "overlay"
    position = str(raw.get("position") or cfg["position"])
    cfg["position"] = position
    for key in ("show_next", "animate_cues", "show_idle", "karaoke", "glow"):
        if key in raw:
            cfg[key] = raw[key] is not False
    style = str(raw.get("karaoke_style") or cfg["karaoke_style"]).lower()
    cfg["karaoke_style"] = "custom" if style == "custom" else "theme"
    for key in ("sung", "active", "upcoming"):
        val = raw.get(key)
        if isinstance(val, str) and val.strip():
            cfg[key] = val.strip()
    return cfg


def overlay_should_show(surface_visible: bool, cfg: dict[str, Any]) -> bool:
    return surface_visible is True and cfg.get("enabled") is not False


def content_width_px(window_width: int, pad: int = SIDE_PAD_PX) -> int:
    """Usable text width so lyrics wrap instead of running off the monitor."""
    return max(240, int(window_width) - int(pad))


def hud_height_px(current_h: int, next_h: int, show_next: bool, show_progress: bool) -> int:
    height = 8 + max(0, int(current_h))
    if show_next and next_h > 0:
        height += NEXT_GAP_PX + int(next_h)
    height += 16 if show_progress else 8
    if height < HUD_HEIGHT:
        return HUD_HEIGHT
    if height > HUD_HEIGHT_MAX:
        return HUD_HEIGHT_MAX
    return height


def restore_word_spacing(words: list[dict[str, Any]], line_text: str) -> list[dict[str, Any]]:
    """Re-attach spaces that Apple TTML keeps outside timed <span>s.

    Syllable-lyrics often times 'That's' and 'a' as adjacent spans, with the
    space as an untimed text node. Karaoke then paints That'sa.
    """
    if not words:
        return words
    hay = str(line_text or "")
    if not hay:
        return words
    joined = "".join(str(w.get("text") or "") for w in words)
    if joined == hay:
        return words
    out: list[dict[str, Any]] = []
    cursor = 0
    for raw in words:
        item = dict(raw)
        token = str(item.get("text") or "")
        if not token:
            continue
        idx = hay.find(token, cursor)
        if idx < 0:
            if (
                out
                and not str(out[-1].get("text") or "").endswith((" ", "\n", "\t"))
                and not token[:1].isspace()
            ):
                out[-1]["text"] = str(out[-1]["text"]) + " "
            out.append(item)
            continue
        if idx > cursor:
            gap = hay[cursor:idx]
            if out:
                out[-1]["text"] = str(out[-1].get("text") or "") + gap
            else:
                item["text"] = gap + token
        out.append(item)
        cursor = idx + len(token)
    if cursor < len(hay) and out:
        out[-1]["text"] = str(out[-1].get("text") or "") + hay[cursor:]
    return out


_HEX_RE = re.compile(r"#([0-9a-fA-F]{3,8})\b")


def parse_hex_rgba(
    raw: str | None, fallback: tuple[float, float, float, float]
) -> tuple[float, float, float, float]:
    text = str(raw or "").strip()
    match = _HEX_RE.search(text)
    if not match:
        return fallback
    h = match.group(1)
    if len(h) == 3:
        h = "".join(ch * 2 for ch in h)
        h += "ff"
    elif len(h) == 4:
        h = "".join(ch * 2 for ch in h)
    elif len(h) == 6:
        h += "ff"
    elif len(h) != 8:
        return fallback
    r = int(h[0:2], 16) / 255.0
    g = int(h[2:4], 16) / 255.0
    b = int(h[4:6], 16) / 255.0
    a = int(h[6:8], 16) / 255.0
    return (r, g, b, a)


def load_noctalia_theme_hex() -> dict[str, str]:
    """Resolved palette from Noctalia-generated CSS (updates with wallpaper/theme)."""
    home = Path(os.path.expanduser("~"))
    found: dict[str, str] = {}
    for path in (
        home / ".config/gtk-4.0/noctalia.css",
        home / ".config/gtk-3.0/noctalia.css",
        home / ".config/sh.cider.genten/noctalia.css",
    ):
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        for match in re.finditer(
            r"@define-color\s+(\w+)\s+(#[0-9A-Fa-f]{3,8})", text
        ):
            found[match.group(1)] = match.group(2)
        for match in re.finditer(
            r"--(keyColor|musicKeyColor|q-primary|textDefault|textColor):\s*(#[0-9A-Fa-f]{3,8})",
            text,
        ):
            found[match.group(1)] = match.group(2)
    return found


def resolve_karaoke_paint(cfg: dict[str, Any]) -> dict[str, Any]:
    theme = load_noctalia_theme_hex()
    sung_hex = (
        theme.get("window_fg_color")
        or theme.get("textDefault")
        or theme.get("textColor")
        or "#f2f3f3"
    )
    active_hex = (
        theme.get("accent_color")
        or theme.get("keyColor")
        or theme.get("musicKeyColor")
        or theme.get("q-primary")
        or "#83c2c8"
    )
    upcoming_hex = ""
    if str(cfg.get("karaoke_style") or "theme") == "custom":
        if cfg.get("sung"):
            sung_hex = str(cfg["sung"])
        if cfg.get("active"):
            active_hex = str(cfg["active"])
        if cfg.get("upcoming"):
            upcoming_hex = str(cfg["upcoming"])
    sung = parse_hex_rgba(sung_hex, SUNG_RGBA)
    active = parse_hex_rgba(active_hex, ACTIVE_RGBA)
    # Unsung text is next-line grey. Never dim-white sung — that reads as
    # "already current" before karaoke has highlighted anything.
    if upcoming_hex:
        upcoming = parse_hex_rgba(upcoming_hex, NEXT_RGBA)
    else:
        upcoming = NEXT_RGBA
    return {
        "sung": sung,
        "active": active,
        "upcoming": upcoming,
        "next": upcoming,
        "glow": cfg.get("glow") is not False,
    }


def mix_rgba(
    a: tuple[float, float, float, float],
    b: tuple[float, float, float, float],
    t: float,
) -> tuple[float, float, float, float]:
    """Linear RGBA mix. Pass an already-eased t; does not smoothstep again."""
    if t <= 0:
        return a
    if t >= 1:
        return b
    return (
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
        a[3] + (b[3] - a[3]) * t,
    )


def word_rgba_for_paint(
    start: int,
    end: int,
    pos: int,
    paint: dict[str, Any],
) -> tuple[float, float, float, float]:
    sung = paint.get("sung") or SUNG_RGBA
    active = paint.get("active") or ACTIVE_RGBA
    upcoming = paint.get("upcoming") or NEXT_RGBA
    start_i = int(start)
    end_i = int(end)
    if end_i < start_i:
        end_i = start_i
    pos_f = float(pos)
    dur = max(0, end_i - start_i)

    if pos_f >= start_i:
        t_in = 1.0
    elif KARAOKE_IN_MS <= 0:
        t_in = 0.0
    else:
        t_in = (pos_f - (start_i - KARAOKE_IN_MS)) / float(KARAOKE_IN_MS)

    out_window = float(KARAOKE_OUT_MS)
    if dur > 0:
        out_window = min(out_window, max(80.0, dur * 0.55))
    settle_at = end_i - out_window
    if pos_f <= settle_at:
        t_out = 0.0
    elif out_window <= 0 or pos_f >= end_i:
        t_out = 1.0
    else:
        t_out = (pos_f - settle_at) / out_window

    base = mix_rgba(upcoming, active, smoothstep(t_in))
    return mix_rgba(base, sung, smoothstep(t_out))


def group_karaoke_words(tokens: list[dict[str, Any]]) -> list[list[dict[str, Any]]]:
    """Join timed spans that belong to one whitespace-separated word."""
    groups: list[list[dict[str, Any]]] = []
    current: list[dict[str, Any]] = []
    for tok in tokens:
        if not isinstance(tok, dict):
            continue
        text = str(tok.get("text") or "")
        if not text:
            continue
        if not current:
            current = [tok]
            continue
        prev = str(current[-1].get("text") or "")
        if text.isspace():
            current.append(tok)
            continue
        if prev[-1:].isspace() or text[0].isspace():
            groups.append(current)
            current = [tok]
        else:
            current.append(tok)
    if current:
        groups.append(current)
    return groups


def token_rgba_for_paint(
    token: dict[str, Any],
    word_start: int,
    word_end: int,
    pos: float,
    paint: dict[str, Any],
) -> tuple[float, float, float, float]:
    """Unsung stays upcoming-grey. White (sung) only after a syllable is sung.

    Live word remainder uses active, never the word-level settle-to-sung mix —
    that was painting later syllables white before karaoke reached them.
    """
    sung = paint.get("sung") or SUNG_RGBA
    active = paint.get("active") or ACTIVE_RGBA
    upcoming = paint.get("upcoming") or NEXT_RGBA
    syl_s = int(token.get("start") or 0)
    syl_e = int(token.get("end") or syl_s)
    if syl_e < syl_s:
        syl_e = syl_s
    pos_f = float(pos)
    if pos_f < word_start:
        return word_rgba_for_paint(word_start, word_end, pos_f, paint)
    if pos_f >= word_end:
        return sung

    live = active
    if live[3] < 0.9:
        live = mix_rgba(upcoming, active, 0.65)
        live = (live[0], live[1], live[2], max(live[3], active[3]))

    text = str(token.get("text") or "")
    if text.isspace():
        return live
    if pos_f >= syl_e:
        return sung
    if pos_f >= syl_s:
        hot = word_rgba_for_paint(syl_s, syl_e, pos_f, paint)
        if hot[3] < 0.9:
            hot = mix_rgba(hot, active, 1.0)
        return hot
    return live


def line_only_current_rgba(
    paint: dict[str, Any],
) -> tuple[float, float, float, float]:
    """Whole live line is sung when the source has no syllable timings."""
    sung = paint.get("sung") or SUNG_RGBA
    return sung


def estimated_position_ms(pos: dict[str, Any], now: float | None = None) -> float:
    """Extrapolate from Cider's last anchor while playing.

    Bridge may skip rewriting position.json for slightly-stale snapshots so the
    original `t` stays the clock. Never freeze after a few seconds — clamp only
    to duration (or a long idle cap when duration is missing).
    """
    base = int(pos.get("position_ms") or 0)
    if pos.get("playing") is not True:
        return max(0, base)
    stamped = float(pos.get("t") or 0)
    if stamped <= 0:
        return max(0, base)
    clock = time.time() if now is None else now
    elapsed = (clock - stamped) * 1000.0
    if elapsed < 0:
        return max(0, base)
    est = base + elapsed
    dur = int(pos.get("duration_ms") or 0)
    if dur > 0:
        est = min(est, float(dur))
    else:
        est = min(est, float(base + 30 * 60 * 1000))
    return max(0.0, float(est))


def smoothstep(t: float) -> float:
    if t <= 0:
        return 0.0
    if t >= 1:
        return 1.0
    return t * t * (3.0 - 2.0 * t)


def is_cue_text(text: str) -> bool:
    return str(text or "") in CUE_TEXTS


def display_track_id(bag: dict[str, Any] | None) -> str:
    """Stable song identity for mix animation.

    Title+artist only — catalog_id often arrives on a later snapshot and would
    look like a fake track change (same bug service.luau documents).
    """
    if not isinstance(bag, dict):
        return ""
    title = str(bag.get("title") or "").strip()
    artist = str(bag.get("artist") or "").strip()
    if not title and not artist:
        return ""
    return f"{title}|{artist}"


def remaining_ms(position_ms: int, duration_ms: int) -> int:
    if duration_ms <= 0:
        return 0
    return max(0, int(duration_ms) - max(0, int(position_ms)))


def cue_pulse_scale(index: int, now: float, n: int = CUE_COUNT) -> float:
    """Independent sine breath per dot (Apple Music wave, not sequential fill)."""
    count = max(1, int(n))
    phase = (float(now) / CUE_PULSE_PERIOD_S) - (int(index) / count)
    return 1.0 + CUE_PULSE_AMP * math.sin(2.0 * math.pi * phase)


def outro_lyric_alpha(
    remaining: int,
    playing: bool,
    fade_ms: int = TRACK_FADE_MS,
) -> float:
    """Fade lyrics in the last fade_ms of a playing track (automix/crossfade hint)."""
    if not playing or fade_ms <= 0:
        return 1.0
    if remaining >= fade_ms:
        return 1.0
    if remaining <= 0:
        return 0.0
    return remaining / float(fade_ms)


def track_cross_alphas(
    elapsed_ms: float,
    duration_ms: float = TRACK_CROSS_MS,
) -> tuple[float, float, float]:
    """Hold (outgoing), live (incoming), mix-dots alphas for a track change.

    0–40% fade old + raise dots, 40–55% hold dots, 55–100% fade in new.
    """
    if duration_ms <= 0:
        return 0.0, 1.0, 0.0
    u = elapsed_ms / duration_ms
    if u <= 0:
        return 1.0, 0.0, 0.0
    if u >= 1:
        return 0.0, 1.0, 0.0
    if u < 0.40:
        t = smoothstep(u / 0.40)
        return 1.0 - t, 0.0, t
    if u < 0.55:
        return 0.0, 0.0, 1.0
    t = smoothstep((u - 0.55) / 0.45)
    return 0.0, t, 1.0 - t


def surface_mix_u(
    from_u: float,
    showing: bool,
    elapsed_ms: float,
    duration_ms: float = SURFACE_ANIM_MS,
) -> float:
    """Ease a HUD toggle between from_u and 0 or 1."""
    target = 1.0 if showing else 0.0
    if duration_ms <= 0:
        return target
    if elapsed_ms <= 0:
        return from_u
    if elapsed_ms >= duration_ms:
        return target
    eased = smoothstep(elapsed_ms / duration_ms)
    return from_u + (target - from_u) * eased


def lerp_rgba(
    a: tuple[float, float, float, float],
    b: tuple[float, float, float, float],
    t: float,
) -> tuple[float, float, float, float]:
    u = smoothstep(t)
    return (
        a[0] + (b[0] - a[0]) * u,
        a[1] + (b[1] - a[1]) * u,
        a[2] + (b[2] - a[2]) * u,
        a[3] + (b[3] - a[3]) * u,
    )


def layer_anchors(position: str) -> dict[str, bool]:
    """Which gtk-layer-shell edges to pin. Fill-width strip, matching panel width=fill."""
    pos = (position or "top_center").lower()
    top = pos.startswith("top")
    bottom = pos.startswith("bottom")
    center_v = pos.startswith("center")
    if not top and not bottom and not center_v:
        top = True
    return {
        "top": top,
        "bottom": bottom,
        "left": True,
        "right": True,
    }
