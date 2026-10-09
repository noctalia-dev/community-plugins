#!/usr/bin/env python3
"""Lyrics overlay HUD config."""

from __future__ import annotations

import tomllib
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import cairo
import lyrics_overlay_cfg as cfg


ROOT = Path(__file__).resolve().parent.parent


class BackendSettingTests(unittest.TestCase):

    def test_internal_notifications_use_supported_ipc_contract(self) -> None:
        manifest = tomllib.loads((ROOT / "plugin.toml").read_text(encoding="utf-8"))
        self.assertNotIn("save_to_history", {field["key"] for field in manifest["setting"]})
        service = (ROOT / "service.luau").read_text(encoding="utf-8")
        self.assertNotIn("save_history", service)
        self.assertIn('local icon = "music"', service)

    def test_plugin_toml_has_no_lyrics_osd_backend(self) -> None:
        text = (ROOT / "plugin.toml").read_text(encoding="utf-8")
        self.assertNotIn("lyrics_display_backend", text)
        self.assertNotIn('id = "lyrics-osd"', text)
        self.assertFalse((ROOT / "lyrics-osd.luau").exists())

    def test_service_does_not_rewrite_plugin_toml(self) -> None:
        text = (ROOT / "service.luau").read_text(encoding="utf-8")
        code = "\n".join(
            line for line in text.splitlines() if not line.lstrip().startswith("--")
        )
        self.assertNotIn("/plugin.toml", code)
        self.assertNotIn("applyLyricsOsdPosition", code)

    def test_service_always_launches_overlay(self) -> None:
        text = (ROOT / "service.luau").read_text(encoding="utf-8")
        self.assertIn("ensureLyricsOverlay", text)
        self.assertIn("applyLyricsSurface", text)
        code = "\n".join(
            line for line in text.splitlines() if not line.lstrip().startswith("--")
        )
        self.assertNotIn("openLyricsPanel", code)
        self.assertNotIn('lyricsDisplayBackend == "osd"', code)


class OverlayCfgTests(unittest.TestCase):
    def test_legacy_osd_cfg_still_shows_overlay(self) -> None:
        merged = cfg.merge_cfg({"backend": "osd", "enabled": True})
        self.assertEqual(merged["backend"], "overlay")
        self.assertTrue(cfg.overlay_should_show(True, merged))

    def test_overlay_backend_shows_when_surface_on(self) -> None:
        merged = cfg.merge_cfg({"backend": "overlay"})
        self.assertTrue(cfg.overlay_should_show(True, merged))
        self.assertFalse(cfg.overlay_should_show(False, merged))

    def test_layer_anchors_bottom_is_fill_width_strip(self) -> None:
        edges = cfg.layer_anchors("bottom_center")
        self.assertTrue(edges["bottom"])
        self.assertFalse(edges["top"])
        self.assertTrue(edges["left"])
        self.assertTrue(edges["right"])

    def test_lyrics_hud_never_paints_a_plate(self) -> None:
        overlay = (ROOT / "scripts" / "lyrics_overlay.py").read_text(encoding="utf-8")
        self.assertNotIn("bg_opacity", overlay)
        self.assertNotIn("bg_opacity", cfg.merge_cfg({"bg_opacity": 40}))


class PlainScrollTests(unittest.TestCase):
    LINES = [
        {"time": -1, "text": "Short"},
        {"time": -1, "text": "This line is much longer than the first"},
        {"time": -1, "text": "End"},
    ]

    def test_is_plain_lyrics(self) -> None:
        self.assertTrue(cfg.is_plain_lyrics(self.LINES))
        self.assertFalse(cfg.is_plain_lyrics([{"time": 0, "text": "synced"}]))

    def test_lyrics_are_plain_prefers_bridge_metadata(self) -> None:
        synced_lines = [{"time": 0, "text": "synced"}]
        self.assertFalse(
            cfg.lyrics_are_plain(synced_lines, {"has_synced": True, "message": "synced"})
        )
        self.assertTrue(
            cfg.lyrics_are_plain(self.LINES, {"has_synced": False, "message": "plain"})
        )
        # Line heuristics alone must not downgrade synced payloads.
        self.assertFalse(
            cfg.lyrics_are_plain(synced_lines, {"has_synced": True, "message": "synced"})
        )

    def test_lyrics_are_plain_suppressed_message(self) -> None:
        self.assertTrue(
            cfg.lyrics_are_plain([], {"message": "plain_suppressed", "has_synced": False})
        )

    def test_plain_scroll_starts_on_first_line(self) -> None:
        idx = cfg.plain_scroll_line_index(self.LINES, 0, 120_000, cfg.DEFAULT_CFG)
        self.assertEqual(idx, 0)

    def test_plain_scroll_reaches_last_line_near_end(self) -> None:
        idx = cfg.plain_scroll_line_index(self.LINES, 115_000, 120_000, cfg.DEFAULT_CFG)
        self.assertEqual(idx, 2)

    def test_plain_scroll_weights_longer_lines(self) -> None:
        lines = [
            {"time": -1, "text": "A"},
            {"time": -1, "text": "BBBBBBBBBBBBBBBBBBBBBBBB"},
            {"time": -1, "text": "C"},
        ]
        early = cfg.plain_scroll_line_index(lines, 2_000, 120_000, cfg.DEFAULT_CFG)
        mid = cfg.plain_scroll_line_index(lines, 60_000, 120_000, cfg.DEFAULT_CFG)
        self.assertEqual(early, 0)
        self.assertEqual(mid, 1)

    def test_plain_scroll_respects_speed(self) -> None:
        slow = cfg.plain_scroll_line_index(
            self.LINES, 60_000, 120_000, {"plain_scroll_speed": 50}
        )
        fast = cfg.plain_scroll_line_index(
            self.LINES, 60_000, 120_000, {"plain_scroll_speed": 200}
        )
        self.assertGreaterEqual(fast, slow)

    def test_resolve_line_uses_plain_scroll(self) -> None:
        from lyrics_overlay import resolve_line

        cur, nxt, cue, _progress, idx = resolve_line(
            self.LINES,
            70_000,
            dur_ms=120_000,
            cfg={"show_untimed": True, "plain_scroll": True},
        )
        self.assertFalse(cue)
        self.assertGreater(idx, 0)
        self.assertTrue(nxt)

    def test_untimed_hidden_by_default(self) -> None:
        from lyrics_overlay import resolve_line

        cur, nxt, cue, _progress, idx = resolve_line(
            self.LINES,
            70_000,
            dur_ms=120_000,
            cfg=cfg.DEFAULT_CFG,
        )
        self.assertIsNone(cur)
        self.assertEqual(nxt, "")
        self.assertFalse(cfg.plain_lyrics_allowed(cfg.DEFAULT_CFG))
        self.assertFalse(cfg.plain_scroll_enabled(cfg.DEFAULT_CFG))

    def test_silence_gate_holds_during_quiet_intro(self) -> None:
        # 30s of silence → active_ms=0 should keep line 0 even though wall is mid-song.
        idx = cfg.plain_scroll_line_index(
            self.LINES,
            40_000,
            120_000,
            {"show_untimed": True, "plain_scroll": True, "plain_scroll_silence": True, "plain_scroll_speed": 100},
            active_ms=0,
        )
        self.assertEqual(idx, 0)

    def test_silence_gate_advances_on_active_audio(self) -> None:
        quiet = cfg.plain_scroll_line_index(
            self.LINES,
            60_000,
            120_000,
            {"plain_scroll_silence": True},
            active_ms=0,
        )
        loud = cfg.plain_scroll_line_index(
            self.LINES,
            60_000,
            120_000,
            {"plain_scroll_silence": True},
            active_ms=45_000,
        )
        self.assertLess(quiet, loud)

    def test_effective_pos_maps_active_over_remaining(self) -> None:
        # After quiet intro: wall=60s, active=30s, dur=180 → ~36s effective.
        pos = cfg.plain_scroll_effective_pos_ms(60_000, 180_000, 30_000, True)
        self.assertAlmostEqual(pos, 36_000, delta=1)


class AudioMeterUnitTests(unittest.TestCase):
    def test_rms_silence_is_near_zero(self) -> None:
        from audio_meter import level_from_rms, rms_s16le

        silent = b"\x00\x00" * 200
        self.assertLess(rms_s16le(silent), 0.001)
        self.assertLess(level_from_rms(0.0), 0.1)

    def test_rms_loud_sample_registers(self) -> None:
        from audio_meter import level_from_rms, rms_s16le
        import struct

        loud = struct.pack("<" + ("h" * 200), *([20000] * 200))
        self.assertGreater(rms_s16le(loud), 0.4)
        self.assertGreater(level_from_rms(rms_s16le(loud)), 20)


class ClockExtrapolationTests(unittest.TestCase):
    def test_playing_clock_advances_past_eight_seconds(self) -> None:
        now = 1_000_000.0
        pos = {"position_ms": 823, "playing": True, "t": now - 20.0, "duration_ms": 180_000}
        est = cfg.estimated_position_ms(pos, now=now)
        self.assertGreater(est, 15_000)
        self.assertNotEqual(est, 823)

    def test_playing_clock_clamps_to_duration(self) -> None:
        pos = {"position_ms": 1_000, "playing": True, "t": 1.0, "duration_ms": 5_000}
        self.assertEqual(cfg.estimated_position_ms(pos, now=50.0), 5_000)

    def test_paused_clock_stays_at_anchor(self) -> None:
        now = 1_000.0
        pos = {"position_ms": 4_000, "playing": False, "t": now - 30.0, "duration_ms": 90_000}
        self.assertEqual(cfg.estimated_position_ms(pos, now=now), 4_000)

    def test_unsung_paint_is_next_grey_not_dim_white(self) -> None:
        paint = cfg.resolve_karaoke_paint({"karaoke_style": "theme"})
        self.assertAlmostEqual(paint["next"][0], cfg.NEXT_RGBA[0], places=2)
        self.assertAlmostEqual(paint["upcoming"][0], cfg.NEXT_RGBA[0], places=2)
        self.assertLess(paint["next"][0], 0.85)
        self.assertLess(paint["upcoming"][0], 0.85)
        far = {"text": "thing", "start": 2_000, "end": 2_200}
        unsung_line = cfg.token_rgba_for_paint(far, 0, paint)
        self.assertAlmostEqual(unsung_line[0], cfg.NEXT_RGBA[0], places=2)
        # Fixed palette so active vs sung stay distinct even when Noctalia
        # theme tokens land on similar greens.
        contrast = {
            "sung": (1.0, 1.0, 1.0, 1.0),
            "active": (1.0, 0.0, 0.0, 1.0),
            "upcoming": cfg.NEXT_RGBA,
            "next": cfg.NEXT_RGBA,
        }
        later = {"text": "thing", "start": 200, "end": 400}
        self.assertEqual(cfg.token_rgba_for_paint(later, 80, contrast), contrast["upcoming"])
        live = cfg.token_rgba_for_paint(later, 280, contrast)
        self.assertAlmostEqual(live[1], contrast["active"][1], places=2)
        self.assertNotAlmostEqual(live[1], contrast["sung"][1], places=1)
        overlay = (ROOT / "scripts" / "lyrics_overlay.py").read_text(encoding="utf-8")
        self.assertNotIn('self._mul_a(self._paint["sung"], alpha)', overlay)
        self.assertIn("line_only_current_rgba", overlay)

    def test_line_only_lyrics_paint_current_as_sung(self) -> None:
        paint = cfg.resolve_karaoke_paint({"karaoke_style": "theme"})
        rgba = cfg.line_only_current_rgba(paint)
        self.assertAlmostEqual(rgba[0], paint["sung"][0], places=3)
        self.assertAlmostEqual(rgba[1], paint["sung"][1], places=3)
        self.assertGreater(rgba[0], 0.9)
        overlay = (ROOT / "scripts" / "lyrics_overlay.py").read_text(encoding="utf-8")
        self.assertIn("line_only_current_rgba(self._paint)", overlay)
        self.assertNotIn(
            'self._mul_a(self._paint["next"], alpha),\n                22,',
            overlay,
        )


class WrapBudgetTests(unittest.TestCase):
    def test_content_width_leaves_side_pad(self) -> None:
        self.assertEqual(cfg.content_width_px(1920), 1920 - cfg.SIDE_PAD_PX)
        self.assertGreaterEqual(cfg.content_width_px(100), 240)
        self.assertLess(cfg.content_width_px(1920), 1920)

    def test_hud_grows_for_wrapped_current_and_next(self) -> None:
        short = cfg.hud_height_px(30, 0, False, False)
        tall = cfg.hud_height_px(90, 40, True, True)
        self.assertEqual(short, cfg.HUD_HEIGHT)
        self.assertGreater(tall, short)
        self.assertLessEqual(tall, cfg.HUD_HEIGHT_MAX)

    def test_overlay_has_no_track_progress_bar(self) -> None:
        overlay = (ROOT / "scripts" / "lyrics_overlay.py").read_text(encoding="utf-8")
        self.assertNotIn("self._hud_h - 10", overlay)
        self.assertNotIn("_track_progress", overlay)

    def test_overlay_applies_pango_wrap(self) -> None:
        text = (ROOT / "scripts" / "lyrics_overlay.py").read_text(encoding="utf-8")
        self.assertIn("set_wrap(Pango.WrapMode.WORD_CHAR)", text)
        self.assertIn("set_height(-max(1, int(max_lines)))", text)

    def test_overlay_uses_drop_shadow_not_blur_glow(self) -> None:
        text = (ROOT / "scripts" / "lyrics_overlay.py").read_text(encoding="utf-8")
        self.assertIn("_draw_drop_shadow", text)
        self.assertIn("SHADOW_OFFSET_X", text)
        self.assertIn("SHADOW_OFFSET_Y", text)
        self.assertNotIn("mask_surface", text)
        self.assertNotIn("_draw_glass_behind", text)
        self.assertNotIn("FILTER_BILINEAR", text)


class WordSpacingTests(unittest.TestCase):
    def test_zero_time_ttml_keeps_syllables_instead_of_line_only_fallback(self) -> None:
        import cider_bridge as bridge

        track = bridge.TrackEvent(type="track", title="song", catalog_id="123")
        client = bridge.CiderBridge.__new__(bridge.CiderBridge)
        client._track_key = "song|"
        client._lyrics_key = ""
        client._last = dict(vars(track))
        lines = [{"time": 0, "text": ".....", "cue": True},
                 {"time": 1000, "text": "Held", "words": [{"text": "Held", "start": 1000, "end": 2000}]}]
        with mock.patch.object(client, "_lyrics_amapi", return_value=(lines, "timed")):
            with mock.patch.object(client, "_lyrics_lrclib") as fallback:
                with mock.patch.object(bridge, "emit") as emit:
                    client._fetch_lyrics(track, "song|")
        fallback.assert_not_called()
        published = emit.call_args.args[0]
        self.assertEqual(published.lyrics_lines, lines)
        self.assertTrue(published.has_synced)
        self.assertEqual(published.message, "synced")

    def test_ttml_nested_syllables_replace_timed_parent_word(self) -> None:
        import xml.etree.ElementTree as ET
        from cider_bridge import _span_timings

        line = ET.fromstring('<p><span begin="0s" end="1s"><span>'
                             '<span begin="0s" end="0.4s">But</span>'
                             '<span begin="0.4s" end="0.7s">ter</span>'
                             '<span begin="0.7s" end="1s">fly</span>'
                             '</span></span></p>')
        words, _chars = _span_timings(line)
        self.assertEqual(words, [{"text": "But", "start": 0, "end": 400},
                                 {"text": "ter", "start": 400, "end": 700},
                                 {"text": "fly", "start": 700, "end": 1000}])

    def test_ttml_missing_or_reversed_end_does_not_invent_pulse_duration(self) -> None:
        import xml.etree.ElementTree as ET
        from cider_bridge import _span_timings

        for ending in ('', ' end="0s"'):
            with self.subTest(ending=ending):
                words, chars = _span_timings(ET.fromstring(f'<p><span begin="1s"{ending}>Held</span></p>'))
                self.assertEqual(words, [{"text": "Held", "start": 1000, "end": 1000}])
                self.assertEqual(chars, [1000] * 4)
                self.assertEqual(cfg.word_pulse_scale(1000, 1000, None, 1100), 1.0)

    def test_restores_spaces_between_ttml_spans(self) -> None:
        line = "That's a pretty big trunk on my Lincoln Town Car, ain't it?"
        words = [
            {"text": part, "start": i * 100, "end": i * 100 + 80}
            for i, part in enumerate(
                ["That's", "a", "pretty", "big", "trunk", "on", "my", "Lincoln", "Town", "Car,", "ain't", "it?"]
            )
        ]
        fixed = cfg.restore_word_spacing(words, line)
        joined = "".join(str(w["text"]) for w in fixed)
        self.assertEqual(joined, line)
        self.assertIn(" ", fixed[0]["text"])

    def test_parse_hex_rgba(self) -> None:
        r, g, b, a = cfg.parse_hex_rgba("#83c2c8", (0, 0, 0, 1))
        self.assertAlmostEqual(r, 131 / 255, places=3)
        self.assertAlmostEqual(a, 1.0)


class WordPulseTests(unittest.TestCase):
    def test_char_timings_keep_zero_start_and_do_not_invent_last_word_end(self) -> None:
        from lyrics_overlay import _real_words

        words = [word for word in _real_words({"time": 0, "text": "A B", "chars": [0, 250, 500]}) if word["text"].strip()]
        self.assertEqual([(word["start"], word["end"]) for word in words], [(0, 250), (500, 500)])
        self.assertAlmostEqual(cfg.word_pulse_scale(words[0]["start"], words[0]["end"], 500, 125), 1.025)
        self.assertEqual(cfg.word_pulse_scale(words[1]["start"], words[1]["end"], None, 1750), 1.0)

    def test_pulse_grows_and_shrinks_over_full_source_duration(self) -> None:
        for start, duration in ((0, 400), (1000, 1200)):
            with self.subTest(start=start, duration=duration):
                end = start + duration
                for progress, expected in ((0, 1.0), (0.25, 1.0125), (0.5, 1.025), (0.75, 1.0125), (1, 1.0)):
                    self.assertAlmostEqual(cfg.word_pulse_scale(start, end, None, start + duration * progress), expected)

    def test_pulse_settles_without_velocity_or_acceleration_jump_and_holds_peak(self) -> None:
        pulse = lambda phase: cfg.word_pulse_scale(0, 1000, None, phase * 1000)
        step = 0.001
        for endpoint, direction in ((0.0, 1.0), (1.0, -1.0)):
            with self.subTest(endpoint=endpoint):
                rest, near, farther = (pulse(endpoint + direction * step * n) for n in range(3))
                self.assertAlmostEqual((near - rest) / step, 0.0, delta=0.00001)
                self.assertAlmostEqual((farther - 2 * near + rest) / step ** 2, 0.0, delta=0.001)
        self.assertGreater(pulse(0.45), 1.02495)
        self.assertAlmostEqual(pulse(0.45), pulse(0.55))

    def test_successor_clips_pulse_without_stretching_source_duration(self) -> None:
        self.assertAlmostEqual(cfg.word_pulse_scale(1000, 2200, 1400, 1100), 1.0125)
        self.assertAlmostEqual(cfg.word_pulse_scale(1000, 2200, 1400, 1200), 1.025)
        self.assertEqual(cfg.word_pulse_scale(1000, 2200, 1400, 1400), 1.0)
        self.assertEqual(cfg.word_pulse_scale(1000, 2200, 1400, 1700), 1.0)
        self.assertAlmostEqual(cfg.word_pulse_scale(1000, 2200, 3000, 1600), 1.025)
        self.assertEqual(cfg.word_pulse_scale(1000, 2200, 3000, 2200), 1.0)

    def test_missing_invalid_and_inactive_timing_stays_at_rest(self) -> None:
        for value in (None, "", float("nan"), float("inf"), float("-inf")):
            for field in range(3):
                timing = [1000, 2200, 1600]
                timing[field] = value
                with self.subTest(value=value, field=field):
                    self.assertEqual(cfg.word_pulse_scale(timing[0], timing[1], None, timing[2]), 1.0)
        for start, end, position in ((0, 0, 0), (2200, 1000, 1600), (1000, 2200, 999), (1000, 2200, 2201)):
            with self.subTest(start=start, end=end, position=position):
                self.assertEqual(cfg.word_pulse_scale(start, end, None, position), 1.0)


class LineTransitionTests(unittest.TestCase):
    def setUp(self) -> None:
        from lyrics_overlay import LyricsHud

        self.methods = LyricsHud
        wall = mock.patch("lyrics_overlay.time.time", return_value=1000.0)
        self.wall = wall.start()
        self.addCleanup(wall.stop)
        clock = mock.patch("lyrics_overlay.time.monotonic", return_value=1000.0)
        self.clock = clock.start()
        self.addCleanup(clock.stop)

    def _hud(self) -> SimpleNamespace:
        hud = SimpleNamespace(
            _current=None, _next="", _is_cue=False, _playing=True, _pos_ms=0.0,
            _line_key=None, _line_idx=0, _line_pos_ms=0.0, _line_tick_at=0.0,
            _anim_t0=0.0, _anim_ms=float(cfg.LINE_ANIM_MS), _anim_forward=True,
            _incoming_current="", _incoming_next="", _outgoing_current="", _outgoing_next="",
            _track_anim_t0=0.0, _track_start_u=0.0, _awaiting_lyrics=False,
            _hold_current="", _hold_next="", _hold_was_cue=False, _remaining_ms=60_000,
            _frame=None, _swap_from=None, _swap_t0=0.0, _swap_through=False,
            _next_slot_y=0.0, _promote_y=0.0,
            _next_line=None, _incoming_line=None, _outgoing_line=None,
            _lyrics_lines=[], _seek_route=[], _seek_frames={}, _seek_target_height=1.0,
        )
        hud._current_text = lambda: self.methods._current_text(hud)
        hud._start_seek_route = lambda previous: self.methods._start_seek_route(hud, previous)
        return hud

    def _note(self, hud: SimpleNamespace, idx: int, pos_ms: int, now: float, *, cue: bool = False) -> None:
        self.wall.return_value = now
        self.clock.return_value = now
        hud._current = {"text": f"Line {idx}"}
        hud._next = f"Line {idx + 1}"
        hud._is_cue = cue
        hud._pos_ms = pos_ms
        self.methods._note_line_change(hud, idx)

    def _assert_settled(self, hud: SimpleNamespace, text: str) -> None:
        self.assertEqual(hud._incoming_current, text)
        self.assertEqual(hud._outgoing_current, "")
        self.assertEqual(hud._outgoing_next, "")
        self.assertEqual(self.methods._anim_u(hud), 1.0)

    def _frame(self, side: int) -> cairo.SurfacePattern:
        surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, 3, 1)
        cr = cairo.Context(surface)
        cr.set_source_rgba(1, 1, 1, 1)
        cr.rectangle(side, 0, 1, 1)
        cr.rectangle(1, 0, 1, 1)
        cr.fill()
        return cairo.SurfacePattern(surface)

    def _pixels(self, frame: cairo.Pattern) -> bytes:
        surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, 3, 1)
        cr = cairo.Context(surface)
        cr.set_source(frame)
        cr.paint()
        surface.flush()
        return bytes(surface.get_data())

    def _blend(self, hud: SimpleNamespace, frame: cairo.Pattern, now: float) -> cairo.Pattern:
        self.clock.return_value = now
        cr = cairo.Context(cairo.ImageSurface(cairo.FORMAT_ARGB32, 3, 1))
        return self.methods._blend_frame(hud, cr, frame)

    def test_natural_adjacent_playback_keeps_depth_after_delayed_tick(self) -> None:
        for elapsed_ms in (33, 500):
            with self.subTest(elapsed_ms=elapsed_ms):
                hud = self._hud()
                self._note(hud, 1, 9980, 1000.0)
                self._note(hud, 2, 9980 + elapsed_ms, 1000.0 + elapsed_ms / 1000)
                self.assertEqual(hud._incoming_current, "Line 2")
                self.assertEqual(hud._outgoing_current, "Line 1")
                self.assertEqual(hud._anim_ms, cfg.LINE_ANIM_MS)
                self.assertTrue(hud._anim_forward)
                self.assertEqual(self.methods._anim_u(hud), 0.0)

    def test_line_animation_exposes_raw_phase_for_single_easing(self) -> None:
        hud = self._hud()
        self._note(hud, 1, 9980, 1000.0)
        self._note(hud, 2, 10_013, 1000.033)
        for phase in (0.25, 0.5, 0.75):
            with self.subTest(phase=phase):
                self.clock.return_value = hud._anim_t0 + hud._anim_ms * phase / 1000
                self.assertAlmostEqual(self.methods._anim_u(hud), phase)

    def test_forward_and_backward_seeks_settle_target_immediately(self) -> None:
        for idx, pos_ms in ((4, 45_000), (8, 90_000), (2, 5000)):
            with self.subTest(idx=idx, pos_ms=pos_ms):
                hud = self._hud()
                self._note(hud, 3, 30_000, 1000.0)
                self._note(hud, idx, pos_ms, 1000.033)
                self._assert_settled(hud, f"Line {idx}")

    def test_skipped_indices_settle_without_promoting_unseen_line(self) -> None:
        hud = self._hud()
        self._note(hud, 1, 9800, 1000.0)
        self._note(hud, 4, 9833, 1000.033)
        self._assert_settled(hud, "Line 4")

    def test_seek_cancels_inflight_motion_even_with_unchanged_line(self) -> None:
        for idx in (2, 3, 8, 1):
            with self.subTest(idx=idx):
                hud = self._hud()
                self._note(hud, 1, 9800, 1000.0)
                self._note(hud, 2, 10_000, 1000.2)
                self.assertEqual(hud._outgoing_current, "Line 1")
                self._note(hud, idx, 45_000 if idx > 1 else 5000, 1000.233)
                self._assert_settled(hud, f"Line {idx}")

    def test_seek_between_lyrics_and_cues_settles_correct_content(self) -> None:
        for from_cue, to_cue in ((False, True), (True, False)):
            with self.subTest(from_cue=from_cue):
                hud = self._hud()
                self._note(hud, 1, 9800, 1000.0, cue=from_cue)
                self._note(hud, 2, 45_000, 1000.033, cue=to_cue)
                self._assert_settled(hud, cfg.CUE_TEXT if to_cue else "Line 2")

    def test_seek_discards_track_hold_and_waits_safely_for_pending_lyrics(self) -> None:
        for awaiting in (False, True):
            with self.subTest(awaiting=awaiting):
                hud = self._hud()
                self._note(hud, 1, 9800, 1000.0)
                hud._track_anim_t0 = 1000.0
                hud._hold_current = "Old track"
                hud._hold_next = "Old next"
                hud._hold_was_cue = True
                hud._awaiting_lyrics = awaiting
                self._note(hud, 2, 45_000, 1000.033)
                self._assert_settled(hud, "Line 2")
                self.assertEqual((hud._hold_current, hud._hold_next, hud._hold_was_cue), ("", "", False))
                self.assertEqual(self.methods._mix_alphas(hud), (0.0, 0.0, 1.0) if awaiting else (0.0, 1.0, 0.0))
                self.assertEqual(hud._track_anim_t0, 1000.0 if awaiting else 0.0)

    def test_natural_playback_preserves_track_crossfade(self) -> None:
        hud = self._hud()
        self._note(hud, 1, 9800, 1000.0)
        hud._track_anim_t0 = 1000.0
        hud._hold_current = "Old track"
        hud._hold_next = "Old next"
        self._note(hud, 2, 9833, 1000.033)
        self.assertEqual(hud._track_anim_t0, 1000.0)
        self.assertEqual((hud._hold_current, hud._hold_next), ("Old track", "Old next"))
        for actual, expected in zip(self.methods._mix_alphas(hud), cfg.track_cross_alphas(33.0)):
            self.assertAlmostEqual(actual, expected)

    def test_tick_new_track_clock_reset_preserves_fade_with_ready_or_pending_lyrics(self) -> None:
        import lyrics_overlay as overlay

        for ready in (False, True):
            with self.subTest(ready=ready):
                hud = self._hud()
                hud._play_id = ""
                hud._width, hud._hud_h = 800, cfg.HUD_HEIGHT
                hud._plain_active_ms = hud._plain_last_tick = 0.0
                hud._drawing = SimpleNamespace(queue_draw=mock.Mock())
                hud._apply_layer_position = hud._note_surface = hud._sync_meter = mock.Mock()
                hud._surface_progress = mock.Mock(return_value=1.0)
                hud._measure_needed_height = mock.Mock(return_value=cfg.HUD_HEIGHT)
                hud.set_size_request = mock.Mock()
                hud._note_line_change = lambda idx: self.methods._note_line_change(hud, idx)
                cache = {
                    overlay.CFG_PATH: {"backend": "overlay"},
                    overlay.HUD_PATH: {"visible": True},
                    overlay.STATE_PATH: {"title": "Old", "artist": "Artist", "playback_state": "playing"},
                    overlay.POSITION_PATH: {"position_ms": 59_000, "playing": True, "t": 1000.0, "duration_ms": 120_000},
                    overlay.LYRICS_PATH: {
                        "title": "Old", "artist": "Artist", "has_synced": True,
                        "lyrics_lines": [{"time": 59_000, "text": "Old last"}, {"time": 90_000, "text": "Old next"}],
                    },
                }
                self.wall.return_value = self.clock.return_value = 1000.0
                with mock.patch.object(overlay, "_read_json", side_effect=cache.get), mock.patch.object(overlay.Gdk.Display, "get_default", return_value=None):
                    self.assertTrue(self.methods._tick(hud))
                    self.assertEqual(hud._pos_ms, 59_000)
                    self.assertEqual(hud._incoming_current, "Old last")
                    self.assertIs(hud._next_line, cache[overlay.LYRICS_PATH]["lyrics_lines"][1])
                    cache[overlay.STATE_PATH] = {"title": "New", "artist": "Artist", "playback_state": "playing"}
                    cache[overlay.POSITION_PATH] = {"position_ms": 0, "playing": True, "t": 1000.033, "duration_ms": 180_000}
                    cache[overlay.LYRICS_PATH] = {
                        "title": "New", "artist": "Artist", "has_synced": True,
                        "lyrics_lines": [{"time": 0, "text": "New start"}, {"time": 12_000, "text": "New next"}],
                    } if ready else {}
                    self.wall.return_value = self.clock.return_value = 1000.033
                    self.assertTrue(self.methods._tick(hud))
                self.assertEqual(hud._pos_ms, 0)
                self.assertEqual((hud._hold_current, hud._hold_next), ("Old last", "Old next"))
                self.assertEqual(hud._track_anim_t0, 1000.033)
                self.assertEqual(hud._track_start_u, 0.0)
                self.assertEqual(hud._awaiting_lyrics, not ready)
                self.assertEqual(hud._incoming_current, "New start" if ready else "")
                if ready:
                    self.assertIs(hud._next_line, cache[overlay.LYRICS_PATH]["lyrics_lines"][1])
                else:
                    self.assertIsNone(hud._next_line)
                self.assertEqual(self.methods._mix_alphas(hud), (1.0, 0.0, 0.0))

    def test_changed_line_seek_keeps_depth_motion_from_actual_pose(self) -> None:
        hud = self._hud()
        old, target = self._frame(0), self._frame(2)
        self._note(hud, 1, 9980, 1000.0)
        hud._frame = old
        started = 1000.033
        self._note(hud, 4, 45_000, started)
        self.assertTrue(hud._swap_through)
        self.assertEqual(cfg.SEEK_TRANSITION_MS, 360)
        self.assertEqual(self._pixels(self._blend(hud, target, started)), self._pixels(old))
        finished = self._blend(hud, target, started + cfg.SEEK_TRANSITION_MS / 1000)
        self.assertEqual(self._pixels(finished), self._pixels(target))
        self.assertIsNone(hud._swap_from)
        self.assertEqual(hud._swap_t0, 0.0)

    def test_seek_depth_planes_never_share_glyph_space_in_either_direction(self) -> None:
        for height in (96, 240):
            for forward in (False, True):
                for elapsed in range(cfg.SEEK_TRANSITION_MS + 1):
                    old_s, old_y, new_s, new_y = cfg.seek_depth_poses(elapsed, height, forward)
                    if forward:
                        self.assertLessEqual(old_y + old_s * height, new_y + 1e-9)
                    else:
                        self.assertLessEqual(new_y + new_s * height, old_y + 1e-9)
                old_s, old_y, new_s, new_y = cfg.seek_depth_poses(0, height, forward)
                self.assertEqual((old_s, old_y), (1.0, 0.0))
                old_s, old_y, new_s, new_y = cfg.seek_depth_poses(cfg.SEEK_TRANSITION_MS, height, forward)
                self.assertEqual((new_s, new_y), (1.0, 0.0))
                self.assertGreater(old_s if forward else new_s, cfg.NEXT_FONT_PX / cfg.CURRENT_FONT_PX)
                if forward:
                    self.assertLess(old_y + old_s * height, 0)
                else:
                    self.assertGreater(old_y, height)

    def test_backward_seek_uses_reverse_depth_travel(self) -> None:
        hud = self._hud()
        self._note(hud, 4, 45_000, 1000.0)
        hud._frame = self._frame(0)
        self._note(hud, 1, 10_000, 1000.033)
        self.assertTrue(hud._swap_through)
        self.assertFalse(hud._anim_forward)

    def test_seek_route_uses_real_rows_and_resolver_intro_in_both_directions(self) -> None:
        lines = [{"time": i * 1000 + 1000, "text": "Repeated" if i in (1, 3) else f"Line {i}"} for i in range(6)]
        lines[2]["cue"] = True
        for outgoing, incoming, expected in ((lines[0], lines[4], lines[:5]),
                                             (lines[4], lines[0], lines[4::-1])):
            route = cfg.seek_line_route(lines, dict(outgoing), incoming)
            self.assertEqual(route, expected)
            self.assertIs(route[2], lines[2])
        intro = {"time": 0, "text": "...", "cue": True}
        self.assertEqual(cfg.seek_line_route(lines, intro, lines[2]), [intro, *lines[:3]])
        self.assertEqual(cfg.seek_line_route(lines, lines[2], intro), [*lines[2::-1], intro])
        duplicate = dict(lines[1])
        same_time = [*lines[:2], duplicate, *lines[2:]]
        self.assertEqual(cfg.seek_line_route(same_time, duplicate, lines[3]), [duplicate, lines[2], lines[3]])

    def test_flight_distance_increases_speed_without_unbounded_duration(self) -> None:
        speeds = []
        for distance in (1, 2, 8, 24, 200):
            duration = cfg.seek_flight_duration_ms(distance)
            self.assertLessEqual(duration, 520)
            self.assertEqual(cfg.seek_flight_u(0, distance), 0)
            self.assertEqual(cfg.seek_flight_u(duration, distance), 1)
            speeds.append(distance / duration)
        self.assertEqual(speeds, sorted(speeds))

    def test_repeated_lyric_text_still_travels_through_distinct_source_rows(self) -> None:
        hud = self._hud()
        hud._lyrics_lines = [{"time": i * 1000, "text": "Repeated"} for i in range(5)]
        hud._current = hud._lyrics_lines[0]
        hud._next = "Repeated"
        self.methods._note_line_change(hud, 1)
        hud._frame = self._frame(0)
        hud._current = hud._lyrics_lines[4]
        hud._pos_ms = 4000
        self.clock.return_value = 1000.033
        self.methods._note_line_change(hud, 5)
        self.assertTrue(hud._swap_through)
        self.assertEqual(hud._seek_route, hud._lyrics_lines)
        self.assertIs(hud._incoming_line, hud._lyrics_lines[4])

    def test_rail_has_continuous_motion_and_separated_neighbor_planes(self) -> None:
        for height in (96, 240):
            for i in range(-100, 101):
                q = i / 100
                scale, y = cfg.seek_flight_pose(q, height)
                prior_scale, prior_y = cfg.seek_flight_pose(q - 1, height)
                self.assertAlmostEqual(y - (prior_y + height * prior_scale), cfg.NEXT_GAP_PX)
                self.assertGreater(scale, 0)
            for forward in (False, True):
                direction = 1 if forward else -1
                self.assertEqual(cfg.seek_arrival_alpha(direction, height, 40, forward), 0)
                self.assertEqual(cfg.seek_arrival_alpha(0, height, 40, forward), 1)
                alphas = [cfg.seek_arrival_alpha(direction * (1 - i / 100), height, 40, forward) for i in range(101)]
                self.assertEqual(alphas, sorted(alphas))

    def test_retarget_direction_follows_visible_route_instead_of_old_destination(self) -> None:
        for origin, old_target, target in ((0, 20, 15), (20, 0, 5)):
            hud = self._hud()
            hud._lyrics_lines = [{"time": i * 1000, "text": f"Line {i}"} for i in range(21)]
            self._note(hud, origin, origin * 1000, 1000.0)
            hud._incoming_line = hud._lyrics_lines[origin]
            hud._frame = self._frame(0)
            hud._current = hud._lyrics_lines[old_target]
            hud._pos_ms = old_target * 1000
            self.clock.return_value = 1000.033
            self.methods._note_line_change(hud, old_target)
            now = 1000.033 + cfg.seek_flight_duration_ms(20) / 2000
            self.clock.return_value = now
            hud._current = hud._lyrics_lines[target]
            hud._pos_ms = target * 1000
            self.methods._note_line_change(hud, target)
            self.assertEqual(hud._seek_route[0]["time"], 10_000)
            self.assertEqual(hud._anim_forward, target > 10)

    def test_same_line_seek_blends_without_shared_glyph_opacity_dip(self) -> None:
        hud = self._hud()
        old, target = self._frame(0), self._frame(2)
        self._note(hud, 1, 9980, 1000.0)
        hud._frame = old
        self._note(hud, 1, 45_000, 1000.033)
        self.assertFalse(hud._swap_through)
        first = self._blend(hud, target, 1000.033)
        self.assertEqual(self._pixels(first), self._pixels(old))
        midpoint = self._blend(hud, target, 1000.033 + cfg.BLEND_MS / 2000)
        self.assertEqual(self._pixels(midpoint)[4:8], self._pixels(old)[4:8])
        self.assertNotEqual(self._pixels(midpoint), self._pixels(old))
        self.assertNotEqual(self._pixels(midpoint), self._pixels(target))
        finished = self._blend(hud, target, 1000.034 + cfg.BLEND_MS / 1000)
        self.assertEqual(self._pixels(finished), self._pixels(target))
        self.assertIs(hud._frame, finished)
        self.assertIsNone(hud._swap_from)
        self.assertEqual(hud._swap_t0, 0.0)

    def test_interrupted_blend_starts_from_last_composited_frame(self) -> None:
        for phase in (0.2, 0.7):
            with self.subTest(phase=phase):
                hud = self._hud()
                old, target = self._frame(0), self._frame(2)
                self._note(hud, 1, 9980, 1000.0)
                hud._frame = old
                self._note(hud, 4, 45_000, 1000.033)
                now = 1000.033 + cfg.SEEK_TRANSITION_MS * phase / 1000
                visible = self._blend(hud, target, now)
                self._note(hud, 8, 90_000, now)
                restarted = self._blend(hud, old, now)
                self.assertEqual(self._pixels(restarted), self._pixels(visible))
                self.assertIs(hud._swap_from, visible)
                self._assert_settled(hud, "Line 8")

    def test_interrupted_adjacent_playback_blends_actual_pose(self) -> None:
        hud = self._hud()
        self._note(hud, 1, 9980, 1000.0)
        self._note(hud, 2, 10_013, 1000.033)
        self.assertEqual(hud._outgoing_current, "Line 1")
        visible = self._frame(0)
        hud._frame = visible
        self._note(hud, 3, 10_046, 1000.066)
        self._assert_settled(hud, "Line 3")
        first = self._blend(hud, self._frame(2), 1000.066)
        self.assertEqual(self._pixels(first), self._pixels(visible))

    def test_wall_clock_jumps_leave_animation_progress_unchanged(self) -> None:
        hud = self._hud()
        self._note(hud, 1, 9980, 1000.0)
        self._note(hud, 2, 10_013, 1000.033)
        hud._track_anim_t0 = 1000.0
        self.clock.return_value = 1000.233
        before = self.methods._anim_u(hud), self.methods._mix_alphas(hud)
        for wall in (-1000.0, 1_000_000.0):
            self.wall.return_value = wall
            self.assertEqual((self.methods._anim_u(hud), self.methods._mix_alphas(hud)), before)

    def test_frame_clock_advances_between_ticks_freezes_pause_and_skips_hidden_redraw(self) -> None:
        hud = self._hud()
        self._note(hud, 1, 10_000, 1000.0)
        hud._surface_progress = mock.Mock(return_value=1.0)
        hud._drawing = SimpleNamespace(queue_draw=mock.Mock())
        self.clock.return_value = 1000.0165
        self.assertTrue(self.methods._on_frame(hud))
        self.assertAlmostEqual(hud._pos_ms, 10_016.5)
        hud._drawing.queue_draw.assert_called_once()
        hud._playing = False
        self.clock.return_value = 1000.033
        self.assertTrue(self.methods._on_frame(hud))
        self.assertAlmostEqual(hud._pos_ms, 10_016.5)
        self.assertEqual(hud._drawing.queue_draw.call_count, 2)
        hud._playing = True
        hud._surface_progress.return_value = 0.0
        self.clock.return_value = 1000.050
        self.assertTrue(self.methods._on_frame(hud))
        self.assertAlmostEqual(hud._pos_ms, 10_016.5)
        self.assertEqual(hud._drawing.queue_draw.call_count, 2)

    def test_depth_growth_keeps_rest_font_wrapping(self) -> None:
        hud = self._hud()
        layout = SimpleNamespace(get_pixel_size=lambda: (50, 10))
        hud._wrap_layout = mock.Mock(return_value=(layout, 50))
        hud._draw_text_shadowed = mock.Mock()
        cr = cairo.Context(cairo.ImageSurface(cairo.FORMAT_ARGB32, 160, 80))
        for start_px, dest_px in ((cfg.CURRENT_FONT_PX, cfg.PAST_FONT_PX), (cfg.PAST_FONT_PX, cfg.CURRENT_FONT_PX)):
            with self.subTest(start_px=start_px, dest_px=dest_px):
                self.methods._draw_depth_line(
                    hud, cr, 160, "A wrapped lyric", 0, 10, dest_px, start_px,
                    0.5, (1, 1, 1, 1), True, cfg.CURRENT_MAX_LINES,
                )
                self.assertEqual(hud._wrap_layout.call_args.args[1], cfg.CURRENT_FONT_PX)


class CueMixTests(unittest.TestCase):
    def test_three_cue_dots(self) -> None:
        self.assertEqual(cfg.CUE_COUNT, 3)
        self.assertEqual(cfg.CUE_TEXT, "...")
        self.assertTrue(cfg.is_cue_text("....."))
        self.assertTrue(cfg.is_cue_text("..."))

    def test_cue_dots_breathe_out_of_phase(self) -> None:
        now = 0.35
        scales = [cfg.cue_pulse_scale(i, now) for i in range(cfg.CUE_COUNT)]
        self.assertGreater(cfg.CUE_BASE_PX, 28)
        self.assertGreaterEqual(cfg.CUE_PULSE_PERIOD_S, 3.5)
        self.assertLessEqual(cfg.CUE_PULSE_AMP, 0.18)
        self.assertNotAlmostEqual(scales[0], scales[1], places=3)
        for scale in scales:
            self.assertGreater(scale, 0.8)
            self.assertLess(scale, 1.2)

    def test_outro_fades_only_in_last_window(self) -> None:
        self.assertEqual(cfg.outro_lyric_alpha(5_000, True), 1.0)
        self.assertEqual(cfg.outro_lyric_alpha(0, True), 0.0)
        self.assertEqual(cfg.outro_lyric_alpha(0, False), 1.0)
        mid = cfg.outro_lyric_alpha(cfg.TRACK_FADE_MS // 2, True)
        self.assertGreater(mid, 0.4)
        self.assertLess(mid, 0.6)

    def test_track_cross_holds_dots_then_fades_in(self) -> None:
        old_a, new_a, dots_a = cfg.track_cross_alphas(0)
        self.assertAlmostEqual(old_a, 1.0)
        self.assertAlmostEqual(new_a, 0.0)
        _old, _new, hold_dots = cfg.track_cross_alphas(cfg.TRACK_CROSS_MS * 0.48)
        self.assertAlmostEqual(_old, 0.0)
        self.assertAlmostEqual(_new, 0.0)
        self.assertAlmostEqual(hold_dots, 1.0)
        old_b, new_b, dots_b = cfg.track_cross_alphas(cfg.TRACK_CROSS_MS)
        self.assertAlmostEqual(old_b, 0.0)
        self.assertAlmostEqual(new_b, 1.0)
        self.assertAlmostEqual(dots_b, 0.0)

    def test_remaining_and_track_id(self) -> None:
        self.assertEqual(cfg.remaining_ms(10_000, 90_000), 80_000)
        self.assertEqual(cfg.display_track_id({"title": "A", "artist": "B"}), "A|B")
        self.assertEqual(cfg.display_track_id({"catalog_id": "x"}), "")

    def test_overlay_uses_three_pulsing_dots(self) -> None:
        text = (ROOT / "scripts" / "lyrics_overlay.py").read_text(encoding="utf-8")
        self.assertIn("cue_pulse_scale", text)
        self.assertIn("track_cross_alphas", text)
        self.assertIn("CUE_COUNT", text)

    def test_surface_toggle_eases_in_and_out(self) -> None:
        self.assertAlmostEqual(cfg.surface_mix_u(0.0, True, 0), 0.0)
        self.assertAlmostEqual(cfg.surface_mix_u(0.0, True, cfg.SURFACE_ANIM_MS), 1.0)
        mid = cfg.surface_mix_u(0.0, True, cfg.SURFACE_ANIM_MS / 2)
        self.assertGreater(mid, 0.4)
        self.assertLess(mid, 0.6)
        self.assertAlmostEqual(cfg.surface_mix_u(1.0, False, cfg.SURFACE_ANIM_MS), 0.0)

    def test_overlay_paints_surface_fade(self) -> None:
        text = (ROOT / "scripts" / "lyrics_overlay.py").read_text(encoding="utf-8")
        self.assertIn("paint_with_alpha", text)
        self.assertIn("SURFACE_SLIDE_PX", text)

    def test_line_swap_slides_outgoing_out_of_slot(self) -> None:
        slide = cfg.line_swap_slide_px(70)
        self.assertGreaterEqual(slide, 70 + cfg.NEXT_GAP_PX)
        overlay = (ROOT / "scripts" / "lyrics_overlay.py").read_text(encoding="utf-8")
        self.assertNotIn("y - 10 * anim_u", overlay)
        self.assertNotIn("10 * (1.0 - anim_u)", overlay)

    def test_next_promotes_by_growing_forward(self) -> None:
        self.assertEqual(cfg.promote_color_u(0), 0)
        self.assertGreater(cfg.promote_color_u(30 / cfg.LINE_ANIM_MS), 0)
        self.assertEqual(cfg.promote_color_u(60 / cfg.LINE_ANIM_MS), 1)
        self.assertEqual(cfg.successor_next_alpha(0.22), 0)
        self.assertLess(cfg.successor_next_alpha(0.23), 0.001)
        self.assertAlmostEqual(cfg.successor_next_alpha(1), 1)
        self.assertAlmostEqual(cfg.promote_scale(0.0), cfg.NEXT_FONT_PX / cfg.CURRENT_FONT_PX)
        self.assertAlmostEqual(cfg.promote_scale(1.0), 1.0)
        mid = cfg.promote_scale(0.5)
        self.assertGreater(mid, cfg.NEXT_FONT_PX / cfg.CURRENT_FONT_PX)
        self.assertLess(mid, 1.0)
        self.assertAlmostEqual(cfg.promote_top_y(0.0, 8.0, 78.0), 78.0)
        self.assertAlmostEqual(cfg.promote_top_y(1.0, 8.0, 78.0), 8.0)
        self.assertAlmostEqual(
            cfg.promote_scale(0.0, cfg.FAR_FONT_PX, cfg.NEXT_FONT_PX),
            cfg.FAR_FONT_PX / cfg.NEXT_FONT_PX,
        )
        self.assertLess(cfg.approach_u(0.1), 0.05)
        self.assertGreater(cfg.approach_u(0.9), 0.8)
        overlay = (ROOT / "scripts" / "lyrics_overlay.py").read_text(encoding="utf-8")
        self.assertIn("_draw_depth_line", overlay)
        self.assertIn("FAR_DROP_PX", overlay)
        self.assertIn("PAST_FONT_PX", overlay)
        self.assertIn("next_line_y", overlay)
        self.assertAlmostEqual(cfg.next_line_y(8.0, 30.0), 8.0 + 30.0 + cfg.NEXT_GAP_PX)
        self.assertLess(cfg.NEXT_GAP_PX, 12)
        self.assertAlmostEqual(
            cfg.promote_scale(0.0, cfg.CURRENT_FONT_PX, cfg.PAST_FONT_PX),
            cfg.CURRENT_FONT_PX / cfg.PAST_FONT_PX,
        )
        self.assertAlmostEqual(cfg.exit_alpha(0.0), 1.0)
        self.assertAlmostEqual(cfg.exit_alpha(1.0), 0.0)
        self.assertNotIn("cr.rectangle(0, y, width, CURRENT_SLOT_PX)", overlay)
        self.assertIn("_draw_cue_depth", overlay)
        self.assertNotIn('mix_rgba(self._paint["next"], self._paint["sung"]', overlay)
        self.assertIn("self._draw_karaoke(cr, width, current_y, alpha)", overlay)

    def test_overlay_python_parses(self) -> None:
        import ast

        src = (ROOT / "scripts" / "lyrics_overlay.py").read_text(encoding="utf-8")
        ast.parse(src)

    def test_line_anim_direction_follows_seek(self) -> None:
        self.assertTrue(cfg.line_anim_forward(0))
        self.assertTrue(cfg.line_anim_forward(40))
        self.assertTrue(cfg.line_anim_forward(-50))  # mild clock catch-up
        self.assertFalse(cfg.line_anim_forward(-500))
        self.assertFalse(cfg.line_anim_forward(-5_000))
        self.assertTrue(cfg.line_anim_forward_from_index(3, 4))
        self.assertTrue(cfg.line_anim_forward_from_index(3, 3))
        self.assertFalse(cfg.line_anim_forward_from_index(5, 2))
        self.assertEqual(cfg.line_anim_duration_ms(1), cfg.LINE_ANIM_MS)
        self.assertLess(cfg.line_anim_duration_ms(4), cfg.LINE_ANIM_MS)
        self.assertGreater(cfg.line_anim_interrupt_elapsed_ms(0.4, 460), 0.0)
        self.assertEqual(cfg.line_anim_interrupt_elapsed_ms(1.0, 460), 0.0)
        # Shrink path past → current must work (promote_scale cannot).
        self.assertAlmostEqual(
            cfg.depth_layout_scale(
                0.0, cfg.PAST_FONT_PX, cfg.CURRENT_FONT_PX, cfg.CURRENT_FONT_PX
            ),
            cfg.PAST_FONT_PX / cfg.CURRENT_FONT_PX,
        )
        self.assertAlmostEqual(
            cfg.depth_layout_scale(
                1.0, cfg.PAST_FONT_PX, cfg.CURRENT_FONT_PX, cfg.CURRENT_FONT_PX
            ),
            1.0,
        )
        overlay = (ROOT / "scripts" / "lyrics_overlay.py").read_text(encoding="utf-8")
        self.assertIn("_draw_arrive_from_past", overlay)
        self.assertIn("line_anim_forward_from_index", overlay)
        self.assertIn("self._anim_forward", overlay)
        self.assertIn("line_anim_duration_ms", overlay)

    def test_cue_dots_grow_forward_not_slide_up(self) -> None:
        # Layout is always CUE_BASE. Incoming visual size is far → base.
        self.assertAlmostEqual(
            cfg.depth_layout_scale(0.0, cfg.CUE_FAR_PX, cfg.CUE_BASE_PX, cfg.CUE_BASE_PX),
            cfg.CUE_FAR_PX / cfg.CUE_BASE_PX,
        )
        self.assertAlmostEqual(
            cfg.depth_layout_scale(1.0, cfg.CUE_FAR_PX, cfg.CUE_BASE_PX, cfg.CUE_BASE_PX),
            1.0,
        )
        # Outgoing must grow past the camera. promote_scale cannot: dest-sized
        # layout + dest>=start makes u=0 shrink a base-sized glyph.
        self.assertAlmostEqual(
            cfg.depth_layout_scale(0.0, cfg.CUE_BASE_PX, cfg.CUE_PAST_PX, cfg.CUE_BASE_PX),
            1.0,
        )
        self.assertAlmostEqual(
            cfg.depth_layout_scale(1.0, cfg.CUE_BASE_PX, cfg.CUE_PAST_PX, cfg.CUE_BASE_PX),
            cfg.CUE_PAST_PX / cfg.CUE_BASE_PX,
        )
        self.assertGreater(cfg.CUE_PAST_PX / cfg.CUE_BASE_PX, 1.6)
        self.assertLess(cfg.CUE_FAR_PX / cfg.CUE_BASE_PX, 0.4)
        self.assertLess(cfg.promote_scale(0.0, cfg.CUE_BASE_PX, cfg.CUE_PAST_PX), 1.0)
        overlay = (ROOT / "scripts" / "lyrics_overlay.py").read_text(encoding="utf-8")
        self.assertIn("depth_layout_scale", overlay)
        self.assertIn("y + FAR_DROP_PX", overlay)
        self.assertNotIn("next_slot_y,\n                            CUE_BASE_PX,\n                            CUE_FAR_PX", overlay)
        y = cfg.cue_centered_y(0, 56, 24, 12)
        ink_center = y + 24 + 6
        self.assertAlmostEqual(ink_center, 28.0)
        self.assertIn("cue_centered_y", overlay)

    def test_karaoke_eases_between_upcoming_active_sung(self) -> None:
        paint = {
            "sung": (1.0, 1.0, 1.0, 1.0),
            "active": (1.0, 0.0, 0.0, 1.0),
            "upcoming": (1.0, 1.0, 1.0, 0.38),
        }
        far = cfg.word_rgba_for_paint(1_000, 1_400, 0, paint)
        self.assertAlmostEqual(far[3], 0.38, places=2)
        at_start = cfg.word_rgba_for_paint(1_000, 1_400, 1_000, paint)
        self.assertGreater(at_start[0], 0.95)
        self.assertLess(at_start[1], 0.08)
        approaching = cfg.word_rgba_for_paint(1_000, 1_400, 860, paint)
        self.assertGreater(approaching[3], 0.38)
        self.assertLess(approaching[1], 0.95)
        at_end = cfg.word_rgba_for_paint(1_000, 1_400, 1_400, paint)
        self.assertAlmostEqual(at_end[1], 1.0, places=2)
        settling = cfg.word_rgba_for_paint(1_000, 1_400, 1_280, paint)
        self.assertGreater(settling[1], 0.05)
        self.assertLess(settling[1], 0.95)

    def test_karaoke_groups_syllables_into_words(self) -> None:
        spans = [
            {"text": "some", "start": 0, "end": 120},
            {"text": "thing", "start": 120, "end": 240},
            {"text": " ", "start": 240, "end": 240},
            {"text": "else", "start": 250, "end": 400},
        ]
        groups = cfg.group_karaoke_words(spans)
        self.assertEqual(len(groups), 2)
        self.assertEqual("".join(t["text"] for t in groups[0]).strip(), "something")
        self.assertEqual(groups[1][0]["text"], "else")
        split = cfg.group_karaoke_words(
            [
                {"text": "That's ", "start": 0, "end": 180},
                {"text": "a", "start": 180, "end": 260},
            ]
        )
        self.assertEqual(len(split), 2)
        self.assertEqual(split[0][0]["text"].strip(), "That's")
        self.assertEqual(split[1][0]["text"], "a")

    def test_live_source_span_is_not_left_upcoming_grey(self) -> None:
        paint = {
            "sung": (1.0, 1.0, 1.0, 1.0),
            "active": (1.0, 0.5, 0.2, 1.0),
            "upcoming": (1.0, 1.0, 1.0, 0.38),
        }
        later = {"text": "thing", "start": 200, "end": 400}
        self.assertEqual(cfg.token_rgba_for_paint(later, 80, paint), paint["upcoming"])
        rgba = cfg.token_rgba_for_paint(later, 280, paint)
        self.assertGreater(rgba[3], 0.85)
        self.assertEqual(cfg.token_rgba_for_paint(later, 400, paint), paint["sung"])
        overlay = (ROOT / "scripts" / "lyrics_overlay.py").read_text(encoding="utf-8")
        self.assertIn("token_rgba_for_paint", overlay)
        self.assertNotIn("_draw_syllable_fill", overlay)

    def test_syllables_color_independently_and_respect_configured_alpha(self) -> None:
        paint = {"sung": (1.0, 1.0, 1.0, 0.8), "active": (1.0, 0.5, 0.2, 0.7),
                 "upcoming": (0.6, 0.6, 0.6, 0.38)}
        spans = [{"text": text, "start": start, "end": start + 200}
                 for text, start in (("some", 0), ("thing", 200), ("else", 400))]
        colors = [cfg.token_rgba_for_paint(span, 280, paint) for span in spans]
        self.assertEqual(colors, [paint["sung"], paint["active"], paint["upcoming"]])
        self.assertEqual(cfg.token_rgba_for_paint(spans[0], 200, paint), paint["sung"])
        self.assertEqual(cfg.token_rgba_for_paint(spans[1], 199, paint), paint["upcoming"])

    def test_zero_or_reversed_span_timing_settles_without_division(self) -> None:
        paint = cfg.resolve_karaoke_paint({"karaoke_style": "theme"})
        for end in (200, 100):
            with self.subTest(end=end):
                span = {"text": "word", "start": 200, "end": end}
                self.assertEqual(cfg.token_rgba_for_paint(span, 199, paint), paint["upcoming"])
                self.assertEqual(cfg.token_rgba_for_paint(span, 200, paint), paint["sung"])


if __name__ == "__main__":
    unittest.main()
