#!/usr/bin/env python3
"""Lyrics overlay HUD config."""

from __future__ import annotations

import unittest
from pathlib import Path

import lyrics_overlay_cfg as cfg


ROOT = Path(__file__).resolve().parent.parent


class BackendSettingTests(unittest.TestCase):
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
        unsung_line = cfg.token_rgba_for_paint(far, 2_000, 2_200, 0, paint)
        self.assertAlmostEqual(unsung_line[0], cfg.NEXT_RGBA[0], places=2)
        later = {"text": "thing", "start": 200, "end": 400}
        live_future = cfg.token_rgba_for_paint(later, 0, 400, 80, paint)
        self.assertAlmostEqual(live_future[1], paint["active"][1], places=2)
        self.assertNotAlmostEqual(live_future[1], paint["sung"][1], places=1)
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

    def test_live_word_is_not_left_upcoming_grey(self) -> None:
        paint = {
            "sung": (1.0, 1.0, 1.0, 1.0),
            "active": (1.0, 0.5, 0.2, 1.0),
            "upcoming": (1.0, 1.0, 1.0, 0.38),
        }
        later = {"text": "thing", "start": 200, "end": 400}
        rgba = cfg.token_rgba_for_paint(later, 0, 400, 80, paint)
        self.assertGreater(rgba[3], 0.85)
        overlay = (ROOT / "scripts" / "lyrics_overlay.py").read_text(encoding="utf-8")
        self.assertIn("token_rgba_for_paint", overlay)
        self.assertNotIn("_draw_syllable_fill", overlay)


if __name__ == "__main__":
    unittest.main()
