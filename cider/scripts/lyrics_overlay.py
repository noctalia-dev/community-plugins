#!/usr/bin/env python3
"""Transparent top-of-screen lyrics HUD (GTK3 + gtk-layer-shell).

No panel chrome — only shadowed text. Reads:
  ~/.cache/noctalia-cider/hud.json            { "visible": bool }  # sticky surface
  ~/.cache/noctalia-cider/lyrics_osd_cfg.json # backend + paint flags
  ~/.cache/noctalia-cider/lyrics.json
  ~/.cache/noctalia-cider/position.json
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path
from typing import Any

import cairo
import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Pango", "1.0")
gi.require_version("PangoCairo", "1.0")
gi.require_version("GtkLayerShell", "0.1")

from gi.repository import GLib, Gtk, Gdk, Pango, PangoCairo, GtkLayerShell  # noqa: E402

from lyrics_overlay_cfg import (  # noqa: E402
    CUE_BASE_PX,
    CUE_COUNT,
    CUE_DOT_GAP_PX,
    CUE_FAR_PX,
    CUE_PAST_PX,
    CUE_TEXT,
    CURRENT_FONT_PX,
    CURRENT_MAX_LINES,
    CURRENT_SLOT_PX,
    FAR_DROP_PX,
    FAR_FONT_PX,
    HUD_HEIGHT,
    IDLE_ALPHA,
    LINE_ANIM_MS,
    NEXT_FONT_PX,
    NEXT_GAP_PX,
    NEXT_MAX_LINES,
    PAST_FONT_PX,
    PAST_LIFT_PX,
    SURFACE_ANIM_MS,
    SURFACE_SLIDE_PX,
    TRACK_CROSS_MS,
    content_width_px,
    cue_centered_y,
    cue_pulse_scale,
    depth_layout_scale,
    display_track_id,
    estimated_position_ms,
    exit_alpha,
    hud_height_px,
    is_cue_text,
    layer_anchors,
    merge_cfg,
    next_line_y,
    outro_lyric_alpha,
    overlay_should_show,
    approach_u,
    promote_scale,
    promote_top_y,
    remaining_ms,
    resolve_karaoke_paint,
    restore_word_spacing,
    smoothstep,
    successor_next_alpha,
    surface_mix_u,
    token_rgba_for_paint,
    line_only_current_rgba,
    track_cross_alphas,
    group_karaoke_words,
)

CACHE = Path(os.path.expanduser("~/.cache/noctalia-cider"))
HUD_PATH = CACHE / "hud.json"
CFG_PATH = CACHE / "lyrics_osd_cfg.json"
LYRICS_PATH = CACHE / "lyrics.json"
POSITION_PATH = CACHE / "position.json"
STATE_PATH = CACHE / "state.json"
BAR_GAP_PX = 6
TICK_MS = 33
# Offset dark glyph copy (CSS-style drop-shadow), not a blurred halo.
SHADOW_OFFSET_X = 2.0
SHADOW_OFFSET_Y = 3.0
SHADOW_RGBA = (0.0, 0.0, 0.0, 0.72)


def _read_json(path: Path) -> dict[str, Any] | None:
    try:
        raw = path.read_text(encoding="utf-8")
        if not raw.strip():
            return None
        data = json.loads(raw)
        return data if isinstance(data, dict) else None
    except (OSError, json.JSONDecodeError):
        return None


def _clamp01(v: float) -> float:
    return 0.0 if v < 0 else 1.0 if v > 1 else v


def _is_cue(line: dict[str, Any]) -> bool:
    if line.get("cue") is True:
        return True
    text = str(line.get("text") or "")
    return is_cue_text(text)


def _line_text(line: dict[str, Any] | None) -> str:
    if not isinstance(line, dict):
        return ""
    return str(line.get("text") or "")


def _real_words(line: dict[str, Any]) -> list[dict[str, Any]]:
    """Only Apple/source word timings — never invent even splits (mismatches Cider)."""
    words_raw = line.get("words")
    if isinstance(words_raw, list) and words_raw:
        out = []
        for w in words_raw:
            if not isinstance(w, dict):
                continue
            text = str(w.get("text") or w.get("word") or "")
            if not text:
                continue
            out.append(
                {
                    "text": text,
                    "start": int(w.get("start") or w.get("startTime") or 0),
                    "end": int(w.get("end") or w.get("endTime") or 0),
                }
            )
        if out:
            return restore_word_spacing(out, _line_text(line))

    # Char timings from TTML still count as real source pacing.
    text = _line_text(line)
    chars = line.get("chars") if isinstance(line.get("chars"), list) else None
    if not text or not chars:
        return []
    start = int(line.get("time") or 0)
    dur = int(line.get("duration") or 0) or 3000
    words: list[dict[str, Any]] = []
    buf = ""
    buf_start: int | None = None
    idx = 0
    for ch in text:
        t = int(chars[idx]) if idx < len(chars) else start
        idx += 1
        if ch.isspace():
            if buf:
                words.append({"text": buf, "start": buf_start or t, "end": t})
                buf = ""
                buf_start = None
            words.append({"text": ch, "start": t, "end": t})
        else:
            if not buf:
                buf_start = t
            buf += ch
    if buf:
        words.append({"text": buf, "start": buf_start or start, "end": start + dur})
    return restore_word_spacing(words, text)


def resolve_line(lines: list[dict[str, Any]], pos_ms: int) -> tuple[dict[str, Any] | None, str, bool, float]:
    if not lines:
        return None, "", False, 0.0
    pos_ms = max(0, pos_ms)
    idx = 0
    for i, line in enumerate(lines):
        t = line.get("time")
        if t is None:
            continue
        t = int(t)
        if t >= 0 and t <= pos_ms:
            idx = i + 1
        elif t > pos_ms:
            break
    if idx == 0:
        first = lines[0]
        ft = int(first.get("time") or 0)
        if ft > pos_ms:
            progress = _clamp01(pos_ms / ft) if ft > 0 else 0.0
            return {"text": CUE_TEXT, "cue": True, "time": 0, "duration": ft}, _line_text(first), True, progress
        idx = 1
    cur = lines[idx - 1]
    nxt = ""
    for j in range(idx, len(lines)):
        txt = _line_text(lines[j])
        if txt and not _is_cue(lines[j]):
            nxt = txt
            break
    cue = _is_cue(cur)
    progress = 0.0
    if cue:
        start = int(cur.get("time") or 0)
        dur = int(cur.get("duration") or 0)
        finish = start + dur if dur > 0 else start + 4000
        if idx < len(lines):
            nt = lines[idx].get("time")
            if nt is not None and int(nt) > start:
                finish = int(nt)
        if finish > start:
            progress = _clamp01((pos_ms - start) / (finish - start))
    return cur, nxt, cue, progress


class LyricsHud(Gtk.Window):
    def __init__(self) -> None:
        super().__init__(type=Gtk.WindowType.TOPLEVEL)
        self.set_app_paintable(True)
        self.set_decorated(False)
        self.set_resizable(False)
        self.set_accept_focus(False)
        self.set_can_focus(False)

        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual is not None:
            self.set_visual(visual)

        GtkLayerShell.init_for_window(self)
        try:
            GtkLayerShell.set_layer(self, GtkLayerShell.Layer.OVERLAY)
        except Exception:
            GtkLayerShell.set_layer(self, GtkLayerShell.Layer.TOP)
        try:
            GtkLayerShell.set_keyboard_mode(self, GtkLayerShell.KeyboardMode.NONE)
        except Exception:
            GtkLayerShell.set_keyboard_interactivity(self, False)
        GtkLayerShell.set_namespace(self, "noctalia-cider-lyrics")
        GtkLayerShell.set_exclusive_zone(self, 0)

        self._drawing = Gtk.DrawingArea()
        self._drawing.set_can_focus(False)
        self._drawing.connect("draw", self._on_draw)
        self.add(self._drawing)

        self._visible_hud = False
        self._want_visible = False
        self._surface_u = 0.0
        self._surface_from = 0.0
        self._surface_t0 = 0.0
        self._surface_showing = False
        self._cfg: dict[str, Any] = merge_cfg(None)
        self._paint: dict[str, Any] = resolve_karaoke_paint(self._cfg)
        self._position = ""
        self._current: dict[str, Any] | None = None
        self._next = ""
        self._is_cue = False
        self._cue_progress = 0.0
        self._pos_ms = 0
        self._width = 800
        self._line_key: tuple[str, str, bool] | None = None
        self._anim_t0 = 0.0
        self._outgoing_current = ""
        self._outgoing_next = ""
        self._incoming_current = ""
        self._incoming_next = ""
        self._hud_h = HUD_HEIGHT
        self._playing = False
        self._remaining_ms = 0
        self._play_id = ""
        self._track_anim_t0 = 0.0
        self._track_start_u = 0.0
        self._awaiting_lyrics = False
        self._hold_current = ""
        self._hold_next = ""
        self._hold_was_cue = False
        self.set_size_request(100, HUD_HEIGHT)
        self.connect("realize", self._apply_click_through)
        self.connect("map", self._apply_click_through)
        self.connect("configure-event", self._on_configure)
        self._apply_layer_position(str(self._cfg.get("position") or "top_center"))
        self.hide()

        GLib.timeout_add(TICK_MS, self._tick)

    def _apply_click_through(self, *_args: Any) -> None:
        """Empty input region — clicks pass through to windows underneath."""
        empty = cairo.Region()
        try:
            self.input_shape_combine_region(empty)
        except Exception:
            pass
        try:
            self._drawing.input_shape_combine_region(empty)
        except Exception:
            pass
        gdk_win = self.get_window()
        if gdk_win is None:
            return
        try:
            gdk_win.input_shape_combine_region(empty, 0, 0)
        except Exception:
            pass
        try:
            gdk_win.set_pass_through(True)
        except Exception:
            pass

    def _on_configure(self, *_args: Any) -> bool:
        self._apply_click_through()
        return False

    def _apply_layer_position(self, position: str) -> None:
        if position == self._position:
            return
        self._position = position
        edges = layer_anchors(position)
        GtkLayerShell.set_anchor(self, GtkLayerShell.Edge.TOP, edges["top"])
        GtkLayerShell.set_anchor(self, GtkLayerShell.Edge.BOTTOM, edges["bottom"])
        GtkLayerShell.set_anchor(self, GtkLayerShell.Edge.LEFT, edges["left"])
        GtkLayerShell.set_anchor(self, GtkLayerShell.Edge.RIGHT, edges["right"])
        GtkLayerShell.set_margin(
            self, GtkLayerShell.Edge.TOP, BAR_GAP_PX if edges["top"] else 0
        )
        GtkLayerShell.set_margin(
            self, GtkLayerShell.Edge.BOTTOM, BAR_GAP_PX if edges["bottom"] else 0
        )

    def _note_surface(self, want: bool) -> None:
        if want == self._want_visible:
            return
        self._want_visible = want
        self._surface_from = self._surface_u
        self._surface_t0 = time.time()
        self._surface_showing = want
        if want:
            self._visible_hud = True
            self.show_all()
            self._apply_click_through()

    def _surface_progress(self) -> float:
        if self._surface_t0 <= 0:
            u = 1.0 if self._want_visible else 0.0
            self._surface_u = u
            return u
        elapsed = (time.time() - self._surface_t0) * 1000.0
        u = surface_mix_u(self._surface_from, self._surface_showing, elapsed)
        self._surface_u = u
        if elapsed >= SURFACE_ANIM_MS:
            self._surface_t0 = 0.0
            if u <= 0.001:
                self._visible_hud = False
                self.hide()
        return u

    def _tick(self) -> bool:
        self._cfg = merge_cfg(_read_json(CFG_PATH))
        self._paint = resolve_karaoke_paint(self._cfg)
        self._apply_layer_position(str(self._cfg.get("position") or "top_center"))
        hud = _read_json(HUD_PATH) or {}
        want = overlay_should_show(hud.get("visible") is True, self._cfg)
        self._note_surface(want)
        surface_u = self._surface_progress()
        if surface_u <= 0.001:
            return True

        lyrics = _read_json(LYRICS_PATH) or {}
        lines = lyrics.get("lyrics_lines")
        if not isinstance(lines, list):
            lines = []
        pos = _read_json(POSITION_PATH) or {}
        state = _read_json(STATE_PATH) or {}
        prev_outro = outro_lyric_alpha(self._remaining_ms, self._playing)
        self._pos_ms = estimated_position_ms(pos)
        dur = int(pos.get("duration_ms") or state.get("duration_ms") or 0)
        self._playing = pos.get("playing") is True or str(state.get("playback_state") or "") == "playing"
        self._remaining_ms = remaining_ms(self._pos_ms, dur)

        play_id = display_track_id(state) or display_track_id(lyrics)
        if play_id and self._play_id and play_id != self._play_id:
            self._hold_current = self._incoming_current or self._current_text()
            self._hold_next = self._incoming_next or self._next
            self._hold_was_cue = self._is_cue
            # Dim from the *outgoing* remaining, not the new track's clock.
            self._track_start_u = 0.40 * (1.0 - prev_outro)
            self._track_anim_t0 = time.time()
            self._awaiting_lyrics = True
            self._anim_t0 = 0.0
            self._line_key = None
        if play_id:
            self._play_id = play_id
        lyrics_id = display_track_id(lyrics)
        if self._awaiting_lyrics and lyrics_id == self._play_id:
            elapsed = (time.time() - self._track_anim_t0) * 1000.0
            elapsed += self._track_start_u * TRACK_CROSS_MS
            self._awaiting_lyrics = False
            if elapsed >= 0.50 * TRACK_CROSS_MS:
                self._track_anim_t0 = time.time()
                self._track_start_u = 0.52

        self._current, self._next, self._is_cue, self._cue_progress = resolve_line(lines, self._pos_ms)
        self._note_line_change()

        # Match monitor width for centered layout.
        try:
            display = Gdk.Display.get_default()
            monitor = display.get_primary_monitor() if display is not None else None
            if monitor is None and display is not None and display.get_n_monitors() > 0:
                monitor = display.get_monitor(0)
            if monitor is not None:
                geo = monitor.get_geometry()
                self._width = max(400, int(geo.width))
        except Exception:
            pass
        self._hud_h = self._measure_needed_height(self._width)
        self.set_size_request(self._width, self._hud_h)

        self._drawing.queue_draw()
        return True

    def _draw_drop_shadow(
        self,
        cr: Any,
        layout: Pango.Layout,
        x: float,
        y: float,
        glyph_a: float,
    ) -> None:
        """Offset dark glyph copy so lyrics stay readable on wallpaper."""
        if glyph_a <= 0.05:
            return
        cr.save()
        cr.set_source_rgba(
            SHADOW_RGBA[0],
            SHADOW_RGBA[1],
            SHADOW_RGBA[2],
            SHADOW_RGBA[3] * glyph_a,
        )
        cr.move_to(x + SHADOW_OFFSET_X, y + SHADOW_OFFSET_Y)
        PangoCairo.show_layout(cr, layout)
        cr.restore()

    def _draw_text_shadowed(
        self,
        cr: Any,
        layout: Pango.Layout,
        x: float,
        y: float,
        rgba: tuple[float, float, float, float],
        shadow: bool = True,
    ) -> None:
        # Drop shadow first, then sharp letters.
        if shadow and self._paint.get("glow") is not False and rgba[3] > 0.05:
            self._draw_drop_shadow(cr, layout, x, y, rgba[3])
        cr.set_source_rgba(*rgba)
        cr.move_to(x, y)
        PangoCairo.show_layout(cr, layout)

    def _current_text(self) -> str:
        if self._is_cue:
            return CUE_TEXT
        return _line_text(self._current)

    def _note_line_change(self) -> None:
        incoming = self._current_text()
        key = (incoming, self._next, self._is_cue)
        if key == self._line_key:
            return
        if self._line_key is not None and self._track_anim_t0 <= 0:
            self._outgoing_current = self._incoming_current
            self._outgoing_next = self._incoming_next
            self._anim_t0 = time.time()
        else:
            self._anim_t0 = 0.0
        self._incoming_current = incoming
        self._incoming_next = self._next
        self._line_key = key

    def _mix_alphas(self) -> tuple[float, float, float]:
        """hold (outgoing track), live (current track), mix-dots."""
        if self._track_anim_t0 > 0:
            elapsed = (time.time() - self._track_anim_t0) * 1000.0
            elapsed += self._track_start_u * TRACK_CROSS_MS
            if self._awaiting_lyrics:
                elapsed = min(elapsed, 0.52 * TRACK_CROSS_MS)
            if elapsed >= TRACK_CROSS_MS and not self._awaiting_lyrics:
                self._track_anim_t0 = 0.0
                self._track_start_u = 0.0
                self._hold_current = ""
                self._hold_next = ""
                self._hold_was_cue = False
                return 0.0, 1.0, 0.0
            return track_cross_alphas(elapsed)

        outro_a = outro_lyric_alpha(self._remaining_ms, self._playing)
        if outro_a < 0.999:
            return 0.0, outro_a, 1.0 - outro_a
        return 0.0, 1.0, 0.0

    def _anim_u(self) -> float:
        if self._anim_t0 <= 0:
            return 1.0
        elapsed = (time.time() - self._anim_t0) * 1000.0
        if elapsed >= LINE_ANIM_MS:
            self._anim_t0 = 0.0
            return 1.0
        return smoothstep(elapsed / LINE_ANIM_MS)

    def _wrap_layout(
        self,
        text: str,
        size: int,
        bold: bool,
        window_width: int,
        max_lines: int,
    ) -> tuple[Any, int]:
        weight = "Bold" if bold else "Medium"
        font = Pango.FontDescription(f"Sans {weight} {size}")
        layout = self._drawing.create_pango_layout(text)
        layout.set_font_description(font)
        cw = content_width_px(window_width)
        layout.set_width(cw * Pango.SCALE)
        layout.set_wrap(Pango.WrapMode.WORD_CHAR)
        layout.set_alignment(Pango.Alignment.CENTER)
        layout.set_ellipsize(Pango.EllipsizeMode.END)
        layout.set_height(-max(1, int(max_lines)))
        return layout, cw

    def _current_body_h(self, width: int) -> int:
        """Rest-pose height of the incoming current line (not the 56px slot)."""
        if self._is_cue:
            return CURRENT_SLOT_PX
        body = self._incoming_current or _line_text(self._current)
        if not body:
            return CURRENT_SLOT_PX
        try:
            layout, _cw = self._wrap_layout(
                body, CURRENT_FONT_PX, True, width, CURRENT_MAX_LINES
            )
            return max(24, layout.get_pixel_size()[1])
        except Exception:
            return CURRENT_SLOT_PX

    def _measure_needed_height(self, width: int) -> int:
        show_next = self._cfg.get("show_next") is not False
        nxt = self._incoming_next or self._next
        current_h = self._current_body_h(width)
        next_h = 0
        if show_next and nxt:
            try:
                layout, _cw = self._wrap_layout(
                    nxt, NEXT_FONT_PX, False, width, NEXT_MAX_LINES
                )
                next_h = layout.get_pixel_size()[1]
            except Exception:
                next_h = 18
        return hud_height_px(current_h, next_h, show_next and bool(nxt), False)

    def _draw_plain_line(
        self,
        cr: Any,
        width: int,
        y: float,
        text: str,
        rgba: tuple[float, float, float, float],
        size: int,
        bold: bool,
        max_lines: int = CURRENT_MAX_LINES,
    ) -> int:
        if not text or rgba[3] <= 0.01:
            return 0
        layout, cw = self._wrap_layout(text, size, bold, width, max_lines)
        _tw, th = layout.get_pixel_size()
        self._draw_text_shadowed(cr, layout, (width - cw) / 2, y, rgba)
        return th

    def _draw_depth_line(
        self,
        cr: Any,
        width: int,
        text: str,
        dest_y: float,
        start_y: float,
        dest_px: int,
        start_px: int,
        u: float,
        rgba: tuple[float, float, float, float],
        bold: bool,
        max_lines: int,
    ) -> int:
        """One depth step on the 2D plane: smaller/further → larger/nearer."""
        if not text or rgba[3] <= 0.01:
            return 0
        scale = promote_scale(u, start_px, dest_px)
        layout, cw = self._wrap_layout(text, dest_px, bold, width, max_lines)
        _tw, th = layout.get_pixel_size()
        if th <= 0:
            return 0
        x0 = (width - cw) / 2.0
        vis_h = th * scale
        top = promote_top_y(u, dest_y, start_y)
        cx = width / 2.0
        rest_cy = dest_y + th / 2.0
        pose_cy = top + vis_h / 2.0
        cr.save()
        cr.translate(cx, pose_cy)
        cr.scale(scale, scale)
        cr.translate(-cx, -rest_cy)
        self._draw_text_shadowed(cr, layout, x0, dest_y, rgba)
        cr.restore()
        return int(max(1, vis_h))

    def _draw_promote_line(
        self,
        cr: Any,
        width: int,
        _text: str,
        current_y: float,
        next_y: float,
        u: float,
        alpha: float,
    ) -> int:
        """Next-line pose → current-line pose. Karaoke owns color the whole way."""
        scale = promote_scale(u, NEXT_FONT_PX, CURRENT_FONT_PX)
        body_h = max(1.0, float(self._current_body_h(width)))
        vis_h = body_h * scale
        top = promote_top_y(u, current_y, next_y)
        cx = width / 2.0
        rest_cy = current_y + body_h / 2.0
        pose_cy = top + vis_h / 2.0
        cr.save()
        cr.translate(cx, pose_cy)
        cr.scale(scale, scale)
        cr.translate(-cx, -rest_cy)
        self._draw_karaoke(cr, width, current_y, alpha)
        cr.restore()
        return int(max(1, vis_h))

    def _draw_cue_depth(
        self,
        cr: Any,
        width: int,
        dest_slot_y: float,
        start_slot_y: float,
        dest_px: int,
        start_px: int,
        u: float,
        alpha: float,
    ) -> int:
        """Cue dots on the same far → near → past depth path as lyrics.

        Scale around the slot center while the center takes a short rise.
        Do not lerp a 56px slot top — that turns Z into a long upward slide.
        """
        t = smoothstep(u)
        scale = depth_layout_scale(u, start_px, dest_px, CUE_BASE_PX)
        rest_cy = dest_slot_y + CURRENT_SLOT_PX / 2.0
        start_cy = start_slot_y + CURRENT_SLOT_PX / 2.0
        pose_cy = start_cy + (rest_cy - start_cy) * t
        cx = width / 2.0
        cr.save()
        cr.translate(cx, pose_cy)
        cr.scale(scale, scale)
        cr.translate(-cx, -rest_cy)
        self._draw_cue_dots(cr, width, dest_slot_y, alpha)
        cr.restore()
        return CURRENT_SLOT_PX

    def _draw_cue_dots(self, cr: Any, width: int, slot_y: float, alpha_scale: float) -> int:
        r, g, b, _a = self._paint["sung"]
        animate = self._cfg.get("animate_cues") is not False
        font = Pango.FontDescription(f"Sans Bold {CUE_BASE_PX}")
        layout = self._drawing.create_pango_layout(".")
        layout.set_font_description(font)
        tw, th = layout.get_pixel_size()
        ink, _logical = layout.get_pixel_extents()
        ink_x = float(getattr(ink, "x", 0))
        ink_y = float(getattr(ink, "y", 0))
        ink_w = float(getattr(ink, "width", 0) or tw)
        ink_h = float(getattr(ink, "height", 0) or th)
        y = cue_centered_y(slot_y, CURRENT_SLOT_PX, ink_y, ink_h)
        if not animate:
            layout = self._drawing.create_pango_layout(CUE_TEXT)
            layout.set_font_description(font)
            static_w, static_h = layout.get_pixel_size()
            static_ink, _ = layout.get_pixel_extents()
            y = cue_centered_y(
                slot_y,
                CURRENT_SLOT_PX,
                float(getattr(static_ink, "y", 0)),
                float(getattr(static_ink, "height", 0) or static_h),
            )
            self._draw_text_shadowed(
                cr,
                layout,
                (width - static_w) / 2,
                y,
                (r, g, b, 0.55 * alpha_scale),
            )
            return CURRENT_SLOT_PX
        gap = CUE_DOT_GAP_PX
        total_w = CUE_COUNT * tw + (CUE_COUNT - 1) * gap
        x = (width - total_w) / 2
        now = time.time()
        ink_cx = ink_x + ink_w / 2.0
        ink_cy = ink_y + ink_h / 2.0
        for i in range(CUE_COUNT):
            scale = cue_pulse_scale(i, now)
            cx = x + ink_cx
            cy = y + ink_cy
            cr.save()
            cr.translate(cx, cy)
            cr.scale(scale, scale)
            cr.translate(-ink_cx, -ink_cy)
            self._draw_text_shadowed(cr, layout, 0, 0, (r, g, b, 0.92 * alpha_scale))
            cr.restore()
            x += tw + gap
        return CURRENT_SLOT_PX

    def _mul_a(
        self,
        rgba: tuple[float, float, float, float],
        alpha: float,
    ) -> tuple[float, float, float, float]:
        return (rgba[0], rgba[1], rgba[2], rgba[3] * alpha)

    def _draw_karaoke(self, cr: Any, width: int, y: float, alpha: float = 1.0) -> int:
        if not isinstance(self._current, dict):
            return 0
        words = _real_words(self._current)
        tagged: list[dict[str, Any]] = []
        for group in group_karaoke_words(words):
            word_start = min(int(t["start"]) for t in group)
            word_end = max(int(t["end"]) for t in group)
            for t in group:
                tagged.append({**t, "_ws": word_start, "_we": word_end})
        font = Pango.FontDescription("Sans Bold 22")
        use_karaoke = self._cfg.get("karaoke") is not False and bool(tagged)
        if not use_karaoke:
            return self._draw_plain_line(
                cr,
                width,
                y,
                _line_text(self._current) or "…",
                self._mul_a(line_only_current_rgba(self._paint), alpha),
                22,
                True,
                CURRENT_MAX_LINES,
            )
        max_w = content_width_px(width)
        rows: list[list[dict[str, Any]]] = [[]]
        row_w = [0]
        for w in tagged:
            layout = self._drawing.create_pango_layout(w["text"])
            layout.set_font_description(font)
            tw, _th = layout.get_pixel_size()
            if tw > max_w:
                layout.set_width(max_w * Pango.SCALE)
                layout.set_wrap(Pango.WrapMode.CHAR)
                layout.set_ellipsize(Pango.EllipsizeMode.END)
                layout.set_height(-CURRENT_MAX_LINES)
                tw, _th = layout.get_pixel_size()
                if rows[-1]:
                    rows.append([])
                    row_w.append(0)
                rows[-1].append({**w, "_tw": min(tw, max_w), "_layout": layout, "_span": True})
                row_w[-1] = max_w
                rows.append([])
                row_w.append(0)
                continue
            if rows[-1] and row_w[-1] + tw > max_w:
                rows.append([])
                row_w.append(0)
            rows[-1].append({**w, "_tw": tw, "_layout": layout})
            row_w[-1] += tw
        if rows and not rows[-1]:
            rows.pop()
            row_w.pop()
        used = 0
        for r_i, row in enumerate(rows):
            if not row:
                continue
            span = any(w.get("_span") for w in row)
            x = (width - (max_w if span else row_w[r_i])) / 2
            row_h = 0
            for w in row:
                layout = w["_layout"]
                rgba = self._mul_a(
                    token_rgba_for_paint(
                        w,
                        int(w.get("_ws") or w["start"]),
                        int(w.get("_we") or w["end"]),
                        float(self._pos_ms),
                        self._paint,
                    ),
                    alpha,
                )
                _tw, th = layout.get_pixel_size()
                self._draw_text_shadowed(cr, layout, x, y + used, rgba)
                x += w["_tw"]
                row_h = max(row_h, th)
            used += row_h + 2
        return used

    def _on_draw(self, _widget: Gtk.Widget, cr: Any) -> bool:
        cr.set_operator(cairo.OPERATOR_CLEAR)
        cr.paint()
        cr.set_operator(cairo.OPERATOR_OVER)

        u = self._surface_u
        if u <= 0.001:
            return False

        pos = str(self._cfg.get("position") or "top_center").lower()
        slide = SURFACE_SLIDE_PX * (1.0 - u)
        dy = slide if pos.startswith("bottom") else -slide
        cr.push_group()

        alloc = self._drawing.get_allocation()
        width = alloc.width
        hold_a, live_a, dots_a = self._mix_alphas()
        anim_u = 1.0 if self._track_anim_t0 > 0 else self._anim_u()
        idle = not self._is_cue and not isinstance(self._current, dict)
        y = 8.0
        next_max = NEXT_MAX_LINES
        show_hold = hold_a > 0.01 and bool(self._hold_current or self._hold_was_cue)
        show_live = live_a > 0.01
        show_mix_dots = dots_a > 0.01 and not (
            (self._is_cue and live_a > 0.25) or (self._hold_was_cue and hold_a > 0.25)
        )

        if idle and not show_hold and not show_mix_dots:
            if self._cfg.get("show_idle") is not False:
                self._draw_plain_line(
                    cr,
                    width,
                    y + 16,
                    "No lyrics",
                    (1.0, 1.0, 1.0, IDLE_ALPHA * live_a),
                    13,
                    False,
                    1,
                )
        else:
            current_h = CURRENT_SLOT_PX
            next_slot_y = next_line_y(y, current_h)
            if show_hold:
                if self._hold_was_cue:
                    self._draw_cue_dots(cr, width, y, hold_a)
                else:
                    current_h = self._draw_plain_line(
                        cr,
                        width,
                        y,
                        self._hold_current,
                        (1.0, 1.0, 1.0, hold_a),
                        22,
                        True,
                        CURRENT_MAX_LINES,
                    )
                    next_slot_y = next_line_y(y, current_h)
            if show_live and not idle:
                body_h = self._current_body_h(width)
                next_slot_y = next_line_y(y, body_h)
                if anim_u < 1.0 and self._outgoing_current and not show_hold:
                    out_a = exit_alpha(anim_u) * live_a
                    if is_cue_text(self._outgoing_current):
                        self._draw_cue_depth(
                            cr,
                            width,
                            y - FAR_DROP_PX,
                            y,
                            CUE_PAST_PX,
                            CUE_BASE_PX,
                            anim_u,
                            out_a,
                        )
                    else:
                        sung = self._paint["sung"]
                        self._draw_depth_line(
                            cr,
                            width,
                            self._outgoing_current,
                            y - PAST_LIFT_PX,
                            y,
                            PAST_FONT_PX,
                            CURRENT_FONT_PX,
                            anim_u,
                            (sung[0], sung[1], sung[2], sung[3] * out_a),
                            True,
                            CURRENT_MAX_LINES,
                        )
                if self._is_cue:
                    if anim_u < 1.0:
                        self._draw_cue_depth(
                            cr,
                            width,
                            y,
                            y + FAR_DROP_PX,
                            CUE_BASE_PX,
                            CUE_FAR_PX,
                            anim_u,
                            live_a,
                        )
                    else:
                        self._draw_cue_dots(cr, width, y, live_a)
                    current_h = CURRENT_SLOT_PX
                elif anim_u < 1.0:
                    self._draw_promote_line(
                        cr,
                        width,
                        self._incoming_current,
                        y,
                        next_slot_y,
                        anim_u,
                        live_a,
                    )
                    current_h = body_h
                else:
                    current_h = self._draw_karaoke(cr, width, y, live_a)
                    next_slot_y = next_line_y(y, current_h)
            if show_mix_dots:
                self._draw_cue_dots(cr, width, y, dots_a)
                current_h = max(current_h, CURRENT_SLOT_PX)
                next_slot_y = next_line_y(y, current_h)

            y = next_slot_y
            if self._cfg.get("show_next") is not False:
                if show_hold and self._hold_next:
                    r, g, b, a = self._paint["next"]
                    self._draw_plain_line(
                        cr,
                        width,
                        y,
                        self._hold_next,
                        (r, g, b, a * hold_a),
                        13,
                        False,
                        next_max,
                    )
                if show_live and not idle:
                    growing = anim_u < 1.0 and not self._is_cue
                    if (
                        anim_u < 1.0
                        and self._outgoing_next
                        and not show_hold
                        and not growing
                    ):
                        r, g, b, a = self._paint["next"]
                        self._draw_plain_line(
                            cr,
                            width,
                            y,
                            self._outgoing_next,
                            (r, g, b, a * (1.0 - anim_u) * live_a),
                            13,
                            False,
                            next_max,
                        )
                    if self._incoming_next:
                        r, g, b, a = self._paint["next"]
                        if anim_u < 1.0:
                            au = approach_u(anim_u)
                            if au > 0.01:
                                self._draw_depth_line(
                                    cr,
                                    width,
                                    self._incoming_next,
                                    y,
                                    y + FAR_DROP_PX,
                                    NEXT_FONT_PX,
                                    FAR_FONT_PX,
                                    au,
                                    (r, g, b, a * successor_next_alpha(anim_u) * live_a),
                                    False,
                                    next_max,
                                )
                        else:
                            self._draw_plain_line(
                                cr,
                                width,
                                y,
                                self._incoming_next,
                                (r, g, b, a * live_a),
                                NEXT_FONT_PX,
                                False,
                                next_max,
                            )

        cr.pop_group_to_source()
        cr.translate(0, dy)
        cr.paint_with_alpha(u)
        return False


def main() -> int:
    CACHE.mkdir(parents=True, exist_ok=True)
    # Single instance: pid file. Replace a stale/foreign instance.
    pid_path = CACHE / "lyrics_overlay.pid"
    if pid_path.exists():
        try:
            old = int(pid_path.read_text().strip())
            if old != os.getpid():
                try:
                    os.kill(old, 15)
                    time.sleep(0.15)
                except OSError:
                    pass
                try:
                    os.kill(old, 9)
                except OSError:
                    pass
        except (ValueError, OSError):
            pass
    pid_path.write_text(str(os.getpid()), encoding="utf-8")

    win = LyricsHud()
    win.connect("destroy", Gtk.main_quit)
    try:
        Gtk.main()
    finally:
        try:
            if pid_path.exists() and pid_path.read_text().strip() == str(os.getpid()):
                pid_path.unlink(missing_ok=True)
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
