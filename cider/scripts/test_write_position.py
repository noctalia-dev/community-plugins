#!/usr/bin/env python3
"""Regression: _write_position must update module globals without UnboundLocalError."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import cider_bridge


class WritePositionTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        self._prev_state = cider_bridge._STATE_DIR
        cider_bridge._STATE_DIR = Path(self._tmpdir.name)
        cider_bridge._POS_ANCHOR_MS = 0
        cider_bridge._POS_ANCHOR_WALL = 0.0
        cider_bridge._POS_PLAYING = False
        cider_bridge._POS_DURATION_MS = 0

    def tearDown(self) -> None:
        cider_bridge._STATE_DIR = self._prev_state
        self._tmpdir.cleanup()

    def test_write_position_persists_anchor(self) -> None:
        cider_bridge._write_position(12_000, True, 180_000)
        path = cider_bridge._STATE_DIR / "position.json"
        self.assertTrue(path.is_file(), "position.json must be written")
        payload = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(payload["position_ms"], 12_000)
        self.assertTrue(payload["playing"])
        self.assertEqual(payload["duration_ms"], 180_000)
    def test_write_position_includes_remaining(self) -> None:
        cider_bridge._write_position(12_000, True, 180_000)
        payload = json.loads(
            (cider_bridge._STATE_DIR / "position.json").read_text(encoding="utf-8")
        )
        self.assertEqual(payload["remaining_ms"], 168_000)

    def test_second_write_does_not_unbound_local(self) -> None:
        cider_bridge._write_position(1_000, True, 90_000)
        cider_bridge._write_position(2_000, True, 90_000)
        payload = json.loads(
            (cider_bridge._STATE_DIR / "position.json").read_text(encoding="utf-8")
        )
        self.assertGreaterEqual(payload["position_ms"], 1_000)

    def test_rejects_spurious_ahead_jump_that_caused_lyrics_sprint(self) -> None:
        # Untrusted poll spike +2.5s must not stick the HUD ahead.
        cider_bridge._write_position(10_000, True, 180_000)
        cider_bridge._POS_ANCHOR_WALL -= 1.0
        cider_bridge._write_position(13_500, True, 180_000, trust=False)
        payload = json.loads(
            (cider_bridge._STATE_DIR / "position.json").read_text(encoding="utf-8")
        )
        self.assertEqual(payload["position_ms"], 10_000)
        self.assertEqual(cider_bridge._POS_ANCHOR_MS, 10_000)

    def test_trusted_time_event_accepts_seek_forward(self) -> None:
        # Scrubbing fires playbackTimeDidChange — must re-anchor immediately.
        cider_bridge._write_position(10_000, True, 180_000)
        cider_bridge._POS_ANCHOR_WALL -= 0.5
        cider_bridge._write_position(45_000, True, 180_000, trust=True)
        self.assertEqual(cider_bridge._POS_ANCHOR_MS, 45_000)

    def test_trusted_time_event_accepts_seek_backward(self) -> None:
        cider_bridge._write_position(40_000, True, 180_000)
        cider_bridge._POS_ANCHOR_WALL -= 0.5
        cider_bridge._write_position(12_000, True, 180_000, trust=True)
        self.assertEqual(cider_bridge._POS_ANCHOR_MS, 12_000)

    def test_untrusted_large_jump_still_counts_as_seek(self) -> None:
        cider_bridge._write_position(10_000, True, 180_000)
        cider_bridge._POS_ANCHOR_WALL -= 0.2
        # Forward from polls stays filtered; backward seek still accepted.
        cider_bridge._write_position(40_000, True, 180_000, trust=False)
        self.assertEqual(cider_bridge._POS_ANCHOR_MS, 10_000)
        cider_bridge._write_position(1_000, True, 180_000, trust=False)
        self.assertEqual(cider_bridge._POS_ANCHOR_MS, 1_000)

    def test_still_ignores_mild_stale_rewind(self) -> None:
        cider_bridge._write_position(20_000, True, 180_000)
        cider_bridge._POS_ANCHOR_WALL -= 1.0
        # est ≈ 21000; sample 20500 is ~500ms behind → stale poll, ignore.
        cider_bridge._write_position(20_500, True, 180_000, trust=False)
        self.assertEqual(cider_bridge._POS_ANCHOR_MS, 20_000)

    def test_accepts_large_seek_backward(self) -> None:
        cider_bridge._write_position(40_000, True, 180_000)
        cider_bridge._POS_ANCHOR_WALL -= 0.2
        cider_bridge._write_position(5_000, True, 180_000, trust=False)
        self.assertEqual(cider_bridge._POS_ANCHOR_MS, 5_000)

    def test_time_events_pass_trust_to_write_position(self) -> None:
        source = Path(__file__).resolve().parent / "cider_bridge.py"
        text = source.read_text(encoding="utf-8")
        self.assertIn('trust=event.type in {"time", "track"}', text)

    def test_lyric_boundary_does_not_bounce_on_routine_clock_updates(self) -> None:
        from lyrics_overlay import resolve_line
        from lyrics_overlay_cfg import estimated_position_ms

        lines = [{"time": 0, "text": "old"}, {"time": 10_000, "text": "next"}]
        for event_type in ("time", "state"):
            for rewind_ms in (1, 100, 349, 500, 1499):
                with self.subTest(event_type=event_type, rewind_ms=rewind_ms):
                    with mock.patch.object(cider_bridge.time, "time", return_value=1000.0) as clock:
                        cider_bridge.emit(cider_bridge.TrackEvent(
                            type="track", position_ms=9800, duration_ms=180_000,
                            playback_state="playing",
                        ))
                        clock.return_value = 1000.32
                        path = cider_bridge._STATE_DIR / "position.json"
                        before = json.loads(path.read_text(encoding="utf-8"))
                        position = estimated_position_ms(before, now=clock.return_value)
                        self.assertEqual(resolve_line(lines, int(position))[0]["text"], "next")
                        cider_bridge.emit(cider_bridge.TrackEvent(
                            type=event_type, position_ms=int(position) - rewind_ms,
                            duration_ms=180_000, playback_state="playing",
                        ))
                        after = json.loads(path.read_text(encoding="utf-8"))
                        self.assertEqual(after, before, "jitter must preserve the original anchor")
                        for now in (1000.32, 1000.44):
                            shown = estimated_position_ms(after, now=now)
                            self.assertEqual(resolve_line(lines, int(shown))[0]["text"], "next")

    def test_pause_with_small_stale_tick_freezes_current_lyric(self) -> None:
        from lyrics_overlay_cfg import estimated_position_ms

        with mock.patch.object(cider_bridge.time, "time", return_value=1000.0) as clock:
            cider_bridge._write_position(9800, True, 180_000)
            clock.return_value = 1000.32
            cider_bridge.emit(cider_bridge.TrackEvent(
                type="time", position_ms=9900, duration_ms=180_000,
                playback_state="paused",
            ))
            paused = json.loads((cider_bridge._STATE_DIR / "position.json").read_text())
            self.assertFalse(paused["playing"])
            self.assertAlmostEqual(estimated_position_ms(paused, now=1001.0), 10_120, delta=1)
            clock.return_value = 1001.0
            cider_bridge.emit(cider_bridge.TrackEvent(
                type="time", position_ms=9900, duration_ms=180_000,
                playback_state="playing",
            ))
            resumed = json.loads((cider_bridge._STATE_DIR / "position.json").read_text())
            self.assertTrue(resumed["playing"])
            self.assertEqual(resumed["position_ms"], paused["position_ms"])
            self.assertAlmostEqual(estimated_position_ms(resumed, now=1001.1), 10_220, delta=2)

    def test_track_change_can_reset_by_less_than_jitter_threshold(self) -> None:
        with mock.patch.object(cider_bridge.time, "time", return_value=1000.0):
            cider_bridge.emit(cider_bridge.TrackEvent(
                type="track", position_ms=1000, duration_ms=180_000,
                playback_state="playing",
            ))
            cider_bridge.emit(cider_bridge.TrackEvent(
                type="track", position_ms=0, duration_ms=180_000,
                playback_state="playing",
            ))
            self.assertEqual(cider_bridge._POS_ANCHOR_MS, 0)

    def test_paused_seek_and_resume_accept_position(self) -> None:
        with mock.patch.object(cider_bridge.time, "time", return_value=1000.0) as clock:
            cider_bridge._write_position(10_000, False, 180_000)
            cider_bridge._write_position(9900, False, 180_000, trust=True)
            cider_bridge._write_position(9900, True, 180_000, trust=True)
            clock.return_value = 1000.1
            self.assertAlmostEqual(cider_bridge._estimated_position_ms(), 10_000, delta=1)

    def test_new_track_without_timestamp_starts_at_zero(self) -> None:
        bridge = cider_bridge.CiderBridge("http://localhost", "", cider_bridge._STATE_DIR, 1)
        attrs = {"name": "old", "artistName": "artist", "durationInMillis": 180_000,
                 "currentPlaybackTime": 40, "_playback_state": "playing"}
        with mock.patch.object(cider_bridge.threading.Thread, "start"):
            bridge._emit_from_attrs(attrs, reason="track")
            bridge._emit_from_attrs({"name": "new", "artistName": "artist",
                                     "_playback_state": "playing"}, reason="track")
        self.assertEqual(cider_bridge._POS_ANCHOR_MS, 0)
        self.assertEqual(cider_bridge._POS_DURATION_MS, 0)

    def test_state_without_timestamp_pauses_and_resumes_clock(self) -> None:
        bridge = cider_bridge.CiderBridge("http://localhost", "", cider_bridge._STATE_DIR, 1)
        attrs = {"name": "song", "durationInMillis": 180_000, "_playback_state": "playing",
                 "playParams": {"id": "123"}}
        with mock.patch.object(cider_bridge.threading.Thread, "start"):
            with mock.patch.object(cider_bridge.time, "time", return_value=1000.0) as clock:
                bridge._emit_from_attrs(dict(attrs, currentPlaybackTime=10), reason="track")
                clock.return_value = 1000.1
                track_key = bridge._track_key
                bridge._handle_event("playbackStatus.playbackStateDidChange", {"state": "paused"})
                self.assertFalse(cider_bridge._POS_PLAYING)
                self.assertEqual(bridge._track_key, track_key)
                clock.return_value = 1001.0
                self.assertAlmostEqual(cider_bridge._estimated_position_ms(), 10_100, delta=1)
                bridge._handle_event("playbackStatus.playbackStateDidChange", {"state": "playing"})
                clock.return_value = 1001.1
                self.assertAlmostEqual(cider_bridge._estimated_position_ms(), 10_200, delta=2)

    def test_late_metadata_does_not_reset_lyric_clock(self) -> None:
        from lyrics_overlay import resolve_line
        from lyrics_overlay_cfg import estimated_position_ms

        lines = [{"time": 0, "text": "old"}, {"time": 10_000, "text": "next"}]
        for metadata in ({"playParams": {"id": "123"}}, {"durationInMillis": 180_000},
                         {"albumName": "album"}):
            with self.subTest(metadata=metadata):
                bridge = cider_bridge.CiderBridge("http://localhost", "", cider_bridge._STATE_DIR, 1)
                attrs = {"name": "song", "artistName": "artist",
                         "currentPlaybackTime": 9.8, "_playback_state": "playing"}
                with mock.patch.object(cider_bridge.threading.Thread, "start") as start:
                    with mock.patch.object(cider_bridge.time, "time", return_value=1000.0) as clock:
                        bridge._emit_from_attrs(attrs, reason="track")
                        track_key = bridge._track_key
                        cider_bridge.emit(cider_bridge.TrackEvent(type="lyrics", title="song",
                                                                   artist="artist", lyrics_lines=lines))
                        clock.return_value = 1000.32
                        bridge._emit_from_attrs(dict(attrs, currentPlaybackTime=9.9, **metadata), reason="snapshot")
                        self.assertEqual(bridge._track_key, track_key)
                        payload = json.loads((cider_bridge._STATE_DIR / "position.json").read_text())
                        shown = estimated_position_ms(payload, now=clock.return_value)
                        self.assertEqual(resolve_line(lines, int(shown))[0]["text"], "next")
                        self.assertTrue((cider_bridge._STATE_DIR / "lyrics.json").exists())
                        self.assertEqual(start.call_count, 2, "late metadata must refresh lyrics")

    def test_distinct_catalog_track_with_same_title_resets_clock(self) -> None:
        bridge = cider_bridge.CiderBridge("http://localhost", "", cider_bridge._STATE_DIR, 1)
        attrs = {"name": "song", "artistName": "artist", "currentPlaybackTime": 1,
                 "playParams": {"id": "123"}, "_playback_state": "playing"}
        with mock.patch.object(cider_bridge.threading.Thread, "start"):
            bridge._emit_from_attrs(attrs, reason="track")
            cider_bridge.emit(cider_bridge.TrackEvent(type="lyrics", title="song", artist="artist",
                                                       catalog_id="123", lyrics_lines=[{"time": 0, "text": "old"}]))
            bridge._emit_from_attrs(dict(attrs, currentPlaybackTime=0,
                                         playParams={"id": "456"}), reason="track")
        self.assertEqual(cider_bridge._POS_ANCHOR_MS, 0)
        self.assertFalse((cider_bridge._STATE_DIR / "lyrics.json").exists())
        bridge._handle_event("playbackStatus.playbackTimeDidChange", {
            "currentPlaybackTime": 0.1, "isPlaying": True,
        })
        state = json.loads((cider_bridge._STATE_DIR / "state.json").read_text())
        self.assertEqual(state["catalog_id"], "456")

    def test_lyrics_refresh_after_metadata_and_discards_old_fetch(self) -> None:
        bridge = cider_bridge.CiderBridge("http://localhost", "", cider_bridge._STATE_DIR, 1)
        old = cider_bridge.TrackEvent(type="track", title="song", artist="artist")
        new = cider_bridge.TrackEvent(type="state", title="song", artist="artist", catalog_id="123")
        key = "song|artist"
        bridge._track_key = key
        bridge._last = dict(vars(new))
        bridge._lyrics_key = f"{key}||0|"
        cider_bridge.emit(new)
        lines = [{"time": 1, "text": "new lyrics"}]
        with mock.patch.object(bridge, "_lyrics_amapi", return_value=(lines, "")) as amapi:
            bridge._fetch_lyrics(new, key)
            amapi.assert_called_once_with("123")
        path = cider_bridge._STATE_DIR / "lyrics.json"
        fresh = path.read_text()
        with mock.patch.object(bridge, "_lyrics_lrclib", return_value=([], "")):
            bridge._fetch_lyrics(old, key)
        self.assertEqual(path.read_text(), fresh, "stale fetch must not clear current lyrics")

    def test_track_change_between_fetch_validation_and_emit_rejects_old_lyrics(self) -> None:
        for lines in ([{"time": 1, "text": "old lyrics"}], []):
            with self.subTest(lines=lines):
                bridge = cider_bridge.CiderBridge("http://localhost", "", cider_bridge._STATE_DIR, 1)
                old = cider_bridge.TrackEvent(type="track", title="old", catalog_id="123")
                bridge._track_key = "old|"
                bridge._last = dict(vars(old))
                cider_bridge.emit(old)
                emit = cider_bridge.emit

                def switch_before_publication(event: cider_bridge.TrackEvent) -> None:
                    if event.type == "lyrics":
                        bridge._emit_from_attrs({"name": "new", "playParams": {"id": "456"}}, reason="track")
                        emit(cider_bridge.TrackEvent(type="lyrics", title="new", catalog_id="456",
                                                    lyrics_lines=[{"time": 1, "text": "new lyrics"}]))
                    emit(event)

                with mock.patch.object(cider_bridge.threading.Thread, "start"):
                    with mock.patch.object(bridge, "_lyrics_amapi", return_value=(lines, "")):
                        with mock.patch.object(bridge, "_lyrics_lrclib", return_value=([], "")):
                            with mock.patch.object(cider_bridge, "emit", side_effect=switch_before_publication):
                                bridge._fetch_lyrics(old, "old|")
                lyrics = json.loads((cider_bridge._STATE_DIR / "lyrics.json").read_text())
                self.assertEqual(lyrics["title"], "new")
                self.assertEqual(lyrics["lyrics_lines"][0]["text"], "new lyrics")

    def test_replay_after_song_without_lyrics_fetches_again(self) -> None:
        bridge = cider_bridge.CiderBridge("http://localhost", "", cider_bridge._STATE_DIR, 1)
        lines = [{"time": 1, "text": "A lyrics"}]
        with mock.patch.object(cider_bridge.threading.Thread, "start"):
            with mock.patch.object(bridge, "_lyrics_amapi", side_effect=[(lines, ""), ([], ""), (lines, "")]) as amapi:
                with mock.patch.object(bridge, "_lyrics_lrclib", return_value=([], "")):
                    for name, catalog in (("A", "123"), ("B", "456"), ("A", "123")):
                        bridge._emit_from_attrs({"name": name, "playParams": {"id": catalog}}, reason="track")
                        bridge._fetch_lyrics(cider_bridge.TrackEvent(**bridge._last), bridge._track_key)
        self.assertEqual(amapi.call_count, 3)
        lyrics = json.loads((cider_bridge._STATE_DIR / "lyrics.json").read_text())
        self.assertEqual(lyrics["title"], "A")
        self.assertEqual(lyrics["lyrics_lines"], lines)


class UmbrielWindowProbeTests(unittest.TestCase):
    SAMPLE = "\n".join(
        [
            "*cursor\tCursor Agents\t[tile 1743x1372+17+51]",
            " [Xwayland] cider\tCider\t[tile 1694x1372+1778+51]",
            " zen\tZen Browser\t[tile 1694x1372+3490+51]",
        ]
    )
    JSON_SAMPLE = [
        {
            "id": "cursor-id",
            "app_id": "cursor",
            "title": "Cursor Agents",
            "focused": True,
            "workspace": "DP-1:1",
            "active": True,
        },
        {
            "id": "cider-id",
            "app_id": "cider",
            "title": "Cider",
            "focused": False,
            "workspace": "DP-1:1",
            "active": False,
            "xwayland": True,
        },
        {
            "id": "zen-id",
            "app_id": "zen",
            "title": "Zen Browser",
            "focused": False,
            "workspace": "DP-1:1",
            "active": False,
        },
    ]

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self._prev_state = cider_bridge._STATE_DIR
        cider_bridge._STATE_DIR = Path(self._tmp.name)

    def tearDown(self) -> None:
        cider_bridge._STATE_DIR = self._prev_state
        self._tmp.cleanup()

    def test_parse_umbriel_windows(self) -> None:
        rows = cider_bridge._parse_umbriel_windows(self.SAMPLE)
        self.assertEqual(len(rows), 3)
        self.assertEqual(rows[0][0], True)
        self.assertEqual(rows[1][1], "[Xwayland] cider")
        self.assertEqual(rows[1][2], "Cider")

    def test_normalize_xwayland_app_id(self) -> None:
        self.assertEqual(cider_bridge._normalize_app_id("[Xwayland] cider"), "cider")
        self.assertTrue(cider_bridge._is_cider_window("[Xwayland] cider", "Cider"))

    def test_probe_umbriel_from_json_sample(self) -> None:
        payload = cider_bridge.apply_umbriel_listing(self.JSON_SAMPLE)
        self.assertIsNotNone(payload)
        assert payload is not None
        self.assertEqual(payload["compositor"], "umbriel")
        self.assertTrue(payload["present"])
        self.assertFalse(payload["focused"])
        self.assertTrue(payload["on_screen"])
        self.assertTrue(payload["suppress_notify"])
        self.assertEqual(payload["id"], "cider-id")
        loft = cider_bridge._read_loft()
        self.assertEqual(loft.get("id"), "cider-id")
        self.assertFalse(loft.get("lofted"))

    def test_visible_pad_uses_activation_without_workspace_focus(self) -> None:
        pad = [
            {**self.JSON_SAMPLE[0], "active": False},
            {
                **self.JSON_SAMPLE[1],
                "workspace": "",
                "floating": True,
                "focused": False,
                "active": True,
            },
            self.JSON_SAMPLE[2],
        ]
        payload = cider_bridge.apply_umbriel_listing(pad)
        assert payload is not None
        self.assertTrue(payload["focused"])
        self.assertTrue(payload["on_screen"])
        self.assertTrue(payload["suppress_notify"])
        self.assertTrue(cider_bridge._read_loft().get("lofted"))

    def test_inactive_workspace_remembered_focus_is_not_visible(self) -> None:
        listed = [
            self.JSON_SAMPLE[0],
            {**self.JSON_SAMPLE[1], "workspace": "DP-1:2", "focused": True},
            self.JSON_SAMPLE[2],
        ]
        payload = cider_bridge.apply_umbriel_listing(listed)
        assert payload is not None
        self.assertFalse(payload["focused"])
        self.assertFalse(payload["on_screen"])
        self.assertFalse(payload["suppress_notify"])

    def test_pad_output_prefers_active_peer_over_remembered_focus(self) -> None:
        pad = [
            {**self.JSON_SAMPLE[0], "workspace": "HDMI-A-1:1", "active": False},
            {**self.JSON_SAMPLE[1], "workspace": "", "floating": True},
            {**self.JSON_SAMPLE[2], "focused": True, "active": True},
        ]
        payload = cider_bridge.apply_umbriel_listing(pad)
        assert payload is not None
        self.assertEqual(payload["output"], "DP-1")

    def test_miniplayer_selection_and_visibility_ignore_listing_order(self) -> None:
        main = {**self.JSON_SAMPLE[1], "focused": True, "active": True}
        mini = {
            **self.JSON_SAMPLE[1],
            "id": "mini-id",
            "title": "Cider - Mini Player",
            "workspace": "",
            "floating": True,
        }
        for main_visible in (True, False):
            main_row = {
                **main,
                "workspace": "DP-1:1" if main_visible else "",
                "focused": main_visible,
                "active": main_visible,
            }
            mini_row = {
                **mini,
                "workspace": "" if main_visible else "DP-1:1",
                "active": not main_visible,
            }
            for rows in ([main_row, mini_row], [mini_row, main_row]):
                with self.subTest(main_visible=main_visible, order=[row["id"] for row in rows]):
                    payload = cider_bridge.apply_umbriel_listing(rows)
                    assert payload is not None
                    self.assertEqual(payload["id"], "mini-id")
                    self.assertTrue(payload["focused"])
                    self.assertTrue(payload["on_screen"])
                    self.assertTrue(payload["suppress_notify"])

    def test_selection_prefers_active_then_cached_then_main(self) -> None:
        main = self.JSON_SAMPLE[1]
        other = {**main, "id": "other-id", "title": "Cider Settings", "active": True}
        payload = cider_bridge.apply_umbriel_listing([main, other])
        assert payload is not None
        self.assertEqual(payload["id"], "other-id")
        payload = cider_bridge.apply_umbriel_listing([main, {**other, "active": False}])
        assert payload is not None
        self.assertEqual(payload["id"], "other-id")
        cider_bridge._clear_loft()
        for rows in ([other, main], [main, other]):
            inactive = [{**row, "active": False} for row in rows]
            payload = cider_bridge.apply_umbriel_listing(inactive)
            assert payload is not None
            self.assertEqual(payload["id"], "cider-id")

    def test_unlist_while_session_alive_is_loft_not_quit(self) -> None:
        cider_bridge.apply_umbriel_listing(self.JSON_SAMPLE)
        others = [row for row in self.JSON_SAMPLE if row["app_id"] != "cider"]
        payload = cider_bridge.apply_umbriel_listing(others)
        assert payload is not None
        self.assertEqual(payload["compositor"], "umbriel")
        self.assertTrue(payload["present"])
        self.assertFalse(payload["on_screen"])
        self.assertFalse(payload["suppress_notify"])
        self.assertEqual(payload["id"], "cider-id")
        self.assertTrue(cider_bridge._read_loft().get("lofted"))
        lyrics = cider_bridge._STATE_DIR / "lyrics.json"
        lyrics.write_text("{}", encoding="utf-8")
        self.assertTrue(lyrics.is_file())

    def test_listed_empty_workspace_is_loft_and_keeps_output(self) -> None:
        cider_bridge.apply_umbriel_listing(self.JSON_SAMPLE)
        pad = [
            self.JSON_SAMPLE[0],
            {**self.JSON_SAMPLE[1], "workspace": "", "floating": True, "focused": False},
            self.JSON_SAMPLE[2],
        ]
        payload = cider_bridge.apply_umbriel_listing(pad)
        assert payload is not None
        self.assertTrue(payload["present"])
        self.assertFalse(payload["on_screen"])
        self.assertFalse(payload["suppress_notify"])
        loft = cider_bridge._read_loft()
        self.assertTrue(loft.get("lofted"))
        self.assertEqual(loft.get("output"), "DP-1")
        self.assertEqual(loft.get("id"), "cider-id")

    def test_empty_workspace_infers_output_from_peer(self) -> None:
        pad = [
            self.JSON_SAMPLE[0],
            {**self.JSON_SAMPLE[1], "workspace": "", "floating": True, "focused": False},
            self.JSON_SAMPLE[2],
        ]
        payload = cider_bridge.apply_umbriel_listing(pad)
        assert payload is not None
        loft = cider_bridge._read_loft()
        self.assertTrue(loft.get("lofted"))
        self.assertEqual(loft.get("output"), "DP-1")

    def test_empty_listing_falls_through_without_latch(self) -> None:
        self.assertIsNone(cider_bridge.apply_umbriel_listing([]))

    def test_empty_listing_keeps_umbriel_when_lofted(self) -> None:
        cider_bridge.apply_umbriel_listing(self.JSON_SAMPLE)
        cider_bridge.apply_umbriel_listing(
            [row for row in self.JSON_SAMPLE if row["app_id"] != "cider"]
        )
        payload = cider_bridge.apply_umbriel_listing([])
        assert payload is not None
        self.assertEqual(payload["compositor"], "umbriel")
        self.assertTrue(payload["present"])
        self.assertFalse(payload["on_screen"])

    def test_query_failure_falls_through_without_latch(self) -> None:
        self.assertIsNone(cider_bridge.apply_umbriel_listing(None))

    def test_probe_prefers_umbriel_over_niri(self) -> None:
        with mock.patch.object(
            cider_bridge, "_probe_umbriel", return_value={"compositor": "umbriel", "present": True}
        ) as umbriel_mock, mock.patch.object(
            cider_bridge, "_probe_niri", return_value={"compositor": "niri", "present": False}
        ) as niri_mock:
            payload = cider_bridge.probe_cider_window()
        umbriel_mock.assert_called_once()
        niri_mock.assert_not_called()
        self.assertEqual(payload["compositor"], "umbriel")

    def test_probe_falls_through_when_niri_ipc_dead(self) -> None:
        with mock.patch.object(
            cider_bridge, "_probe_umbriel", return_value=None
        ), mock.patch.object(cider_bridge, "_probe_niri", return_value=None), mock.patch.object(
            cider_bridge,
            "_probe_hyprland",
            return_value={"compositor": "hyprland", "present": False},
        ):
            payload = cider_bridge.probe_cider_window()
        self.assertEqual(payload["compositor"], "hyprland")

    def test_empty_umbriel_plus_niri_listing_is_niri(self) -> None:
        with mock.patch.object(
            cider_bridge, "_umbriel_windows_json", return_value=[]
        ), mock.patch.object(
            cider_bridge,
            "_probe_niri",
            return_value={"compositor": "niri", "present": True, "on_screen": True},
        ):
            payload = cider_bridge.probe_cider_window()
        self.assertEqual(payload["compositor"], "niri")


def _umbriel_desktop(windows: list[dict], pad_visible: bool | None = None):
    rows = [dict(row) for row in windows]
    calls: list[str] = []
    if pad_visible is None:
        pad_visible = any(not row.get("workspace") and row.get("active") for row in rows)
    homes = {row["id"]: row.get("workspace") or "DP-1:1" for row in rows}

    def listing():
        return [dict(row) for row in rows]

    def send(action: str) -> bool:
        nonlocal pad_visible
        calls.append(action)
        name, _, arg = action.partition(":")
        if name == "scratchpad-toggle":
            pad_visible = not pad_visible
            if not pad_visible:
                for row in rows:
                    if not row.get("workspace"):
                        row.update(active=False, focused=False)
        elif name == "window-focus":
            target = next((row for row in rows if row["id"] == arg), None)
            if target is None:
                return False
            if not target.get("workspace") and not pad_visible:
                return True
            for row in rows:
                row["active"] = row is target
                row["focused"] = row is target and bool(row.get("workspace"))
        else:
            target = next((row for row in rows if row.get("active")), None)
            if target is None:
                return False
            if name == "window-toggle-floating":
                target["floating"] = not target.get("floating", False)
            elif name == "window-move-to-scratchpad":
                homes[target["id"]] = target["workspace"]
                target.update(workspace="", floating=True, focused=False, active=False)
            elif name == "window-restore-from-scratchpad":
                target.update(workspace=homes[target["id"]], focused=True)
                if not any(not row.get("workspace") for row in rows):
                    pad_visible = False
        return True

    return rows, calls, send, listing


class UmbrielLoftActuationTests(UmbrielWindowProbeTests):
    def setUp(self) -> None:
        super().setUp()
        fade = mock.patch.object(cider_bridge, "_umbriel_fade_seconds", return_value=0.0)
        fade.start()
        self.addCleanup(fade.stop)

    def _listing(self, *frames: list) -> mock.Mock:
        queued = list(frames)

        def listing() -> list | None:
            if queued:
                return queued.pop(0)
            return frames[-1]

        return listing

    @staticmethod
    def _group_toggle(action: str) -> bool:
        return action == "scratchpad-toggle" or action.startswith("scratchpad-toggle:")

    def test_send_focuses_cider_id_not_foreign_focus(self) -> None:
        listed = self.JSON_SAMPLE
        cider_focused = [
            {**row, "focused": row["id"] == "cider-id", "active": row["id"] == "cider-id"}
            for row in listed
        ]
        calls: list[str] = []

        def msg(action: str) -> bool:
            calls.append(action)
            return True

        cider_bridge.toggle_loft(msg=msg, listing=self._listing(listed, cider_focused))
        self.assertEqual(calls[0], "window-focus:cider-id")
        self.assertEqual(calls[1], "window-move-to-scratchpad:DP-1")
        self.assertFalse(any(self._group_toggle(action) for action in calls))

    def test_send_succeeds_when_another_output_also_has_focus(self) -> None:
        listed = self.JSON_SAMPLE
        cider_and_steam = [
            {**row, "focused": row["id"] in {"cider-id", "cursor-id"}}
            for row in listed
        ]
        cider_and_steam[0] = {**listed[0], "focused": True, "workspace": "DP-1:2", "active": False}
        cider_and_steam[1] = {**listed[1], "focused": True, "active": True}
        calls: list[str] = []

        def msg(action: str) -> bool:
            calls.append(action)
            return True

        cider_bridge.toggle_loft(msg=msg, listing=self._listing(listed, cider_and_steam))
        self.assertEqual(calls[1], "window-move-to-scratchpad:DP-1")

    def test_restore_shows_pad_then_restores_window(self) -> None:
        cider_bridge.apply_umbriel_listing(self.JSON_SAMPLE)
        pad = [
            self.JSON_SAMPLE[0],
            {**self.JSON_SAMPLE[1], "workspace": "", "floating": True, "focused": False},
            self.JSON_SAMPLE[2],
        ]
        _, calls, msg, listing = _umbriel_desktop(pad)
        cider_bridge.toggle_loft(msg=msg, listing=listing)
        self.assertEqual(
            calls,
            [
                "window-focus:cider-id",
                "scratchpad-toggle:DP-1",
                "window-focus:cider-id",
                "window-focus:cider-id",
                "window-restore-from-scratchpad:DP-1",
            ],
        )

    def test_visible_pad_restores_without_group_toggle(self) -> None:
        pad = [
            {**self.JSON_SAMPLE[0], "active": False},
            {**self.JSON_SAMPLE[1], "workspace": "", "floating": True, "focused": False, "active": True},
            {**self.JSON_SAMPLE[2], "focused": False},
        ]
        _, calls, msg, listing = _umbriel_desktop(pad)
        cider_bridge.toggle_loft(msg=msg, listing=listing)
        self.assertEqual(
            calls,
            ["window-focus:cider-id", "window-restore-from-scratchpad:DP-1"],
        )
        self.assertFalse(any(self._group_toggle(action) for action in calls))

    def test_unlisted_cached_window_never_restores_foreign_pad(self) -> None:
        cider_bridge.apply_umbriel_listing(self.JSON_SAMPLE)
        others = [row for row in self.JSON_SAMPLE if row["app_id"] != "cider"]
        others[1] = {**others[1], "workspace": "", "floating": True}
        cider_bridge.apply_umbriel_listing(others)
        _, calls, msg, listing = _umbriel_desktop(others)
        cider_bridge.toggle_loft(msg=msg, listing=listing)
        self.assertEqual(calls, [])

    def test_focus_fail_never_runs_pad_action(self) -> None:
        calls: list[str] = []

        def msg(action: str) -> bool:
            calls.append(action)
            return False

        cider_bridge.toggle_loft(msg=msg, listing=lambda: self.JSON_SAMPLE)
        self.assertEqual(calls, ["window-focus:cider-id"])

    def test_no_cider_id_is_noop(self) -> None:
        calls: list[str] = []
        others = [row for row in self.JSON_SAMPLE if row["app_id"] != "cider"]
        cider_bridge.toggle_loft(
            msg=lambda action: calls.append(action) or True,
            listing=lambda: others,
        )
        self.assertEqual(calls, [])

    def test_missing_output_is_noop(self) -> None:
        listed = [{**self.JSON_SAMPLE[1], "workspace": "", "focused": True}]
        calls: list[str] = []
        cider_bridge.toggle_loft(
            msg=lambda action: calls.append(action) or True,
            listing=lambda: listed,
        )
        self.assertEqual(calls, [])

    def test_cli_does_not_start_bridge(self) -> None:
        with mock.patch.object(cider_bridge, "toggle_loft", return_value=0) as loft_mock, mock.patch.object(
            cider_bridge, "CiderBridge"
        ) as bridge_mock, mock.patch.object(
            sys,
            "argv",
            ["cider_bridge.py", "--toggle-loft", "--state-dir", self._tmp.name],
        ):
            self.assertEqual(cider_bridge.main(), 0)
        loft_mock.assert_called_once()
        bridge_mock.assert_not_called()


class UmbrielWindowLifecycleTests(unittest.TestCase):
    JSON_SAMPLE = UmbrielWindowProbeTests.JSON_SAMPLE
    tearDown = UmbrielWindowProbeTests.tearDown

    def setUp(self) -> None:
        UmbrielWindowProbeTests.setUp(self)
        fade = mock.patch.object(cider_bridge, "_umbriel_fade_seconds", return_value=0.0)
        fade.start()
        self.addCleanup(fade.stop)

    def _mini(self, **changes):
        return {
            **self.JSON_SAMPLE[1],
            "id": "mini-id",
            "title": "Cider - Mini Player",
            "floating": False,
            **changes,
        }

    def test_focus_check_uses_actual_activation_and_legacy_fallback(self) -> None:
        row = {**self.JSON_SAMPLE[1], "focused": True, "active": False}
        self.assertFalse(cider_bridge._window_is_focused([row], "cider-id"))
        row.update(focused=False, active=True)
        self.assertTrue(cider_bridge._window_is_focused([row], "cider-id"))
        row.pop("active")
        row["focused"] = True
        self.assertTrue(cider_bridge._window_is_focused([row], "cider-id"))

    def test_restore_focus_failure_never_restores_foreign_pad(self) -> None:
        pad = [
            {**self.JSON_SAMPLE[1], "workspace": "", "floating": True},
            {**self.JSON_SAMPLE[2], "workspace": "", "floating": True, "active": True},
        ]
        for accepted in (False, True):
            with self.subTest(focus_command_accepted=accepted):
                calls = []

                def send(action):
                    calls.append(action)
                    return accepted if action.startswith("window-focus:") else True

                restored = cider_bridge._restore_umbriel_window(
                    "cider-id", "DP-1", pad, send, lambda: pad
                )
                self.assertFalse(restored)
                self.assertNotIn("window-restore-from-scratchpad:DP-1", calls)
                if not accepted:
                    self.assertEqual(calls, ["window-focus:cider-id"])

    def test_visible_unfocused_pad_restores_without_toggling_visibility(self) -> None:
        pad = [
            self.JSON_SAMPLE[0],
            {**self.JSON_SAMPLE[1], "workspace": "", "floating": True},
        ]
        rows, calls, send, listing = _umbriel_desktop(pad, pad_visible=True)
        self.assertTrue(cider_bridge._restore_umbriel_window(
            "cider-id", "DP-1", listing(), send, listing
        ))
        self.assertEqual(rows[1]["workspace"], "DP-1:1")
        self.assertNotIn("scratchpad-toggle:DP-1", calls)

    def test_restore_failed_focus_query_never_toggles_scratchpad(self) -> None:
        pad = [{**self.JSON_SAMPLE[1], "workspace": "", "floating": True}]
        calls = []

        def send(action):
            calls.append(action)
            return True

        self.assertFalse(cider_bridge._restore_umbriel_window(
            "cider-id", "DP-1", pad, send, lambda: None
        ))
        self.assertEqual(calls, ["window-focus:cider-id"])

    def test_restore_failure_rolls_back_only_pad_opened_by_operation(self) -> None:
        for failure in ("focus", "final-focus", "restore"):
            with self.subTest(failure=failure):
                pad = [self.JSON_SAMPLE[0], {**self.JSON_SAMPLE[1], "workspace": "", "floating": True}]
                rows, calls, send, listing = _umbriel_desktop(pad)

                def failing_send(action):
                    opened = "scratchpad-toggle:DP-1" in calls
                    if (failure == "focus" and opened and action == "window-focus:cider-id") or (
                        failure == "final-focus" and action == "window-focus:cider-id"
                        and calls.count("window-focus:cider-id") == 2
                    ) or (
                        failure == "restore" and action == "window-restore-from-scratchpad:DP-1"
                    ):
                        calls.append(action)
                        return False
                    return send(action)

                self.assertFalse(cider_bridge._restore_umbriel_window(
                    "cider-id", "DP-1", listing(), failing_send, listing
                ))
                self.assertEqual(calls.count("scratchpad-toggle:DP-1"), 2)
                self.assertEqual(calls[-1], "scratchpad-toggle:DP-1")
                self.assertEqual(rows[1]["workspace"], "")
                self.assertFalse(rows[1]["active"])
                if failure != "restore":
                    self.assertNotIn("window-restore-from-scratchpad:DP-1", calls)
                before_hidden_focus = listing()
                send("window-focus:cider-id")
                self.assertEqual(listing(), before_hidden_focus)

    def test_show_existing_window_prefers_mini_in_both_orders(self) -> None:
        for rows in ([self.JSON_SAMPLE[1], self._mini()], [self._mini(), self.JSON_SAMPLE[1]]):
            with self.subTest(order=[row["id"] for row in rows]):
                _, calls, send, listing = _umbriel_desktop(rows)
                with mock.patch.object(cider_bridge, "_umbriel_windows_json", side_effect=listing), mock.patch.object(
                    cider_bridge, "_umbriel_msg", side_effect=send
                ):
                    self.assertEqual(cider_bridge.show_cider_window(), 0)
                self.assertEqual(calls, ["window-focus:mini-id"])

    def test_show_hidden_existing_window_restores_it(self) -> None:
        cider_bridge.apply_umbriel_listing(self.JSON_SAMPLE)
        pad = [self.JSON_SAMPLE[0], {**self.JSON_SAMPLE[1], "workspace": "", "floating": True}]
        rows, calls, send, listing = _umbriel_desktop(pad)
        with mock.patch.object(cider_bridge, "_umbriel_windows_json", side_effect=listing), mock.patch.object(
            cider_bridge, "_umbriel_msg", side_effect=send
        ):
            self.assertEqual(cider_bridge.show_cider_window(), 0)
        self.assertEqual(rows[1]["workspace"], "DP-1:1")
        self.assertIn("window-restore-from-scratchpad:DP-1", calls)

    def test_show_without_existing_window_does_not_use_stale_loft_id(self) -> None:
        cider_bridge.apply_umbriel_listing(self.JSON_SAMPLE)
        for windows in ([], [self.JSON_SAMPLE[0]]):
            with self.subTest(windows=windows), mock.patch.object(
                cider_bridge, "_umbriel_windows_json", return_value=windows
            ), mock.patch.object(cider_bridge, "_umbriel_msg") as send:
                self.assertEqual(cider_bridge.show_cider_window(), 1)
                send.assert_not_called()

    def test_show_ipc_failure_does_not_authorize_relaunch_on_umbriel(self) -> None:
        with mock.patch.object(cider_bridge, "_umbriel_windows_json", return_value=None):
            for desktop, status in (("umbriel", 2), ("niri", 1)):
                with self.subTest(desktop=desktop), mock.patch.dict("os.environ", {"XDG_CURRENT_DESKTOP": desktop}):
                    self.assertEqual(cider_bridge.show_cider_window(), status)

    def test_show_failed_restore_does_not_authorize_duplicate_launch(self) -> None:
        with mock.patch.object(cider_bridge, "_umbriel_windows_json", return_value=self.JSON_SAMPLE), mock.patch.object(
            cider_bridge, "_umbriel_msg", return_value=False
        ):
            self.assertEqual(cider_bridge.show_cider_window(), 2)

    def test_show_cli_exits_without_starting_bridge(self) -> None:
        with mock.patch.object(cider_bridge, "show_cider_window", return_value=1) as show, mock.patch.object(
            cider_bridge, "CiderBridge"
        ) as bridge, mock.patch.object(
            sys, "argv", ["cider_bridge.py", "--show-window", "--state-dir", self._tmp.name]
        ):
            self.assertEqual(cider_bridge.main(), 1)
        show.assert_called_once()
        bridge.assert_not_called()

    def test_show_cli_helper_or_transaction_failure_returns_error_without_bridge(self) -> None:
        for failure in ("helper", "transaction"):
            with self.subTest(failure=failure), mock.patch.object(
                cider_bridge, "_window_transaction"
            ) as transaction, mock.patch.object(cider_bridge, "show_cider_window") as show, mock.patch.object(
                cider_bridge, "CiderBridge"
            ) as bridge, mock.patch.object(cider_bridge.log, "error") as error, mock.patch.object(
                sys, "argv", ["cider_bridge.py", "--show-window", "--state-dir", self._tmp.name]
            ):
                if failure == "helper":
                    show.side_effect = RuntimeError("helper failed")
                else:
                    transaction.return_value.__enter__.side_effect = PermissionError("lock denied")
                self.assertEqual(cider_bridge.main(), 2)
                bridge.assert_not_called()
                error.assert_called_once()
                if failure == "helper":
                    show.assert_called_once()
                else:
                    show.assert_not_called()

    def test_miniplayer_lifecycle_hides_once_and_restores_owned_main(self) -> None:
        for mini_first in (False, True):
            for floating in (False, True):
                with self.subTest(mini_first=mini_first, floating=floating):
                    main = {**self.JSON_SAMPLE[1], "active": True, "focused": True}
                    mini = self._mini(floating=floating)
                    windows = [mini, main] if mini_first else [main, mini]
                    rows, calls, send, listing = _umbriel_desktop([self.JSON_SAMPLE[2], *windows])
                    cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
                    self.assertTrue(next(row for row in rows if row["id"] == "mini-id")["floating"])
                    self.assertEqual(next(row for row in rows if row["id"] == "cider-id")["workspace"], "")
                    self.assertTrue(next(row for row in rows if row["id"] == "mini-id")["active"])
                    self.assertEqual(calls.count("window-toggle-floating"), int(not floating))
                    self.assertEqual(calls.count("window-move-to-scratchpad:DP-1"), 1)
                    self.assertTrue((cider_bridge._STATE_DIR / "miniplayer.json").is_file())
                    first_tick = list(calls)
                    cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
                    self.assertEqual(calls, first_tick)
                    rows[:] = [row for row in rows if row["id"] != "mini-id"]
                    cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
                    self.assertEqual(next(row for row in rows if row["id"] == "cider-id")["workspace"], "DP-1:1")
                    self.assertEqual(rows[0]["id"], "zen-id")
                    self.assertEqual(rows[0]["workspace"], "DP-1:1")
                    self.assertEqual(calls.count("window-restore-from-scratchpad:DP-1"), 1)
                    last_tick = list(calls)
                    cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
                    self.assertEqual(calls, last_tick)

    def test_miniplayer_never_restores_manually_hidden_main(self) -> None:
        main = {**self.JSON_SAMPLE[1], "workspace": "", "floating": True}
        rows, calls, send, listing = _umbriel_desktop([self.JSON_SAMPLE[0], main, self._mini()])
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        rows[:] = [row for row in rows if row["id"] != "mini-id"]
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        self.assertEqual(rows[1]["workspace"], "")
        self.assertNotIn("window-move-to-scratchpad:DP-1", calls)
        self.assertNotIn("window-restore-from-scratchpad:DP-1", calls)

    def test_miniplayer_query_failure_and_closed_main_touch_no_other_window(self) -> None:
        rows, calls, send, listing = _umbriel_desktop([self.JSON_SAMPLE[0], self.JSON_SAMPLE[1], self._mini()])
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        before_failure = list(calls)
        cider_bridge.reconcile_miniplayer(None, msg=send, listing=listing)
        self.assertEqual(calls, before_failure)
        self.assertTrue((cider_bridge._STATE_DIR / "miniplayer.json").is_file())
        rows[:] = [row for row in rows if row["app_id"] != "cider"]
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        self.assertEqual(calls, before_failure)

    def test_miniplayer_close_never_restores_replacement_main_id(self) -> None:
        rows, calls, send, listing = _umbriel_desktop([self.JSON_SAMPLE[0], self.JSON_SAMPLE[1], self._mini()])
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        before_close = list(calls)
        rows[:] = [row for row in rows if row["id"] != "mini-id"]
        rows[1]["id"] = "replacement-main-id"
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        self.assertEqual(calls, before_close)
        self.assertEqual(rows[1]["workspace"], "")

    def test_recreated_miniplayer_keeps_owned_main_until_final_close(self) -> None:
        rows, calls, send, listing = _umbriel_desktop([self.JSON_SAMPLE[1], self._mini()])
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        rows[1].update(id="replacement-mini-id", floating=False)
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        self.assertEqual(rows[0]["workspace"], "")
        self.assertTrue(rows[1]["floating"])
        self.assertEqual(calls.count("window-move-to-scratchpad:DP-1"), 1)
        self.assertNotIn("window-restore-from-scratchpad:DP-1", calls)
        rows.pop()
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        self.assertEqual(rows[0]["workspace"], "DP-1:1")
        self.assertEqual(calls.count("window-restore-from-scratchpad:DP-1"), 1)

    def test_rejected_main_focus_leaves_miniplayer_alive_and_retries_hide(self) -> None:
        rows, calls, send, listing = _umbriel_desktop([self.JSON_SAMPLE[1], self._mini()])
        reject_main_focus = True

        def guarded_send(action):
            if action == "window-focus:cider-id" and reject_main_focus:
                calls.append(action)
                return False
            return send(action)

        cider_bridge.reconcile_miniplayer(listing(), msg=guarded_send, listing=listing)
        self.assertEqual(rows[0]["workspace"], "DP-1:1")
        self.assertEqual(rows[1]["id"], "mini-id")
        self.assertTrue(rows[1]["floating"])
        self.assertTrue(rows[1]["active"])
        self.assertFalse((cider_bridge._STATE_DIR / "miniplayer.json").exists())
        reject_main_focus = False
        cider_bridge.reconcile_miniplayer(listing(), msg=guarded_send, listing=listing)
        self.assertEqual(rows[0]["workspace"], "")
        self.assertTrue(rows[1]["active"])
        self.assertEqual(calls.count("window-move-to-scratchpad:DP-1"), 1)
        self.assertTrue((cider_bridge._STATE_DIR / "miniplayer.json").is_file())

    def test_main_mapping_after_miniplayer_is_hidden_and_owned(self) -> None:
        rows, calls, send, listing = _umbriel_desktop([self._mini(active=True)])
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        rows[0]["active"] = False
        rows.append({**self.JSON_SAMPLE[1], "active": True, "focused": True})
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        self.assertEqual(rows[1]["workspace"], "")
        self.assertTrue(rows[0]["active"])
        self.assertEqual(calls.count("window-toggle-floating"), 1)
        self.assertEqual(calls.count("window-move-to-scratchpad:DP-1"), 1)
        rows.pop(0)
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        self.assertEqual(rows[0]["workspace"], "DP-1:1")
        self.assertEqual(calls.count("window-restore-from-scratchpad:DP-1"), 1)

    def test_observed_manual_restore_releases_ownership_before_manual_hide(self) -> None:
        rows, calls, send, listing = _umbriel_desktop([self.JSON_SAMPLE[1], self._mini()])
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        send("scratchpad-toggle:DP-1")
        send("window-focus:cider-id")
        send("window-restore-from-scratchpad:DP-1")
        self.assertEqual(rows[0]["workspace"], "DP-1:1")
        before_observation = list(calls)
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        self.assertEqual(calls, before_observation)
        send("window-focus:cider-id")
        send("window-move-to-scratchpad:DP-1")
        before_close = list(calls)
        rows.pop()
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        self.assertEqual(calls, before_close)
        self.assertEqual(rows[0]["workspace"], "")


class UmbrielFadeConfigTests(unittest.TestCase):
    INVALID_DURATIONS = ("inf", "nan", "350.0", "10001", "-1", "0", "true", "false", '"350"')
    setUp = UmbrielWindowProbeTests.setUp
    tearDown = UmbrielWindowProbeTests.tearDown

    def _config(self, content: str) -> float:
        config = Path(self._tmp.name) / "config.toml"
        config.write_text(content, encoding="utf-8")
        with mock.patch.dict("os.environ", {"CIDER_UMBRIEL_CONFIG": str(config)}):
            return cider_bridge._umbriel_fade_seconds()

    def test_fade_uses_native_default_and_scratchpad_override(self) -> None:
        self.assertEqual(self._config(
            "[animation]\nenabled=true\nduration_ms=350\n[animation.scratchpad]\nenabled=true\n"
        ), 0.35)
        self.assertEqual(self._config(
            "[animation]\nenabled=true\nduration_ms=350\n[animation.scratchpad]\nenabled=true\nduration_ms=175\n"
        ), 0.175)

    def test_either_animation_disable_makes_fade_instant(self) -> None:
        for master_enabled, pad_enabled in (("false", "true"), ("true", "false")):
            with self.subTest(master=master_enabled, pad=pad_enabled):
                self.assertEqual(self._config(
                    f"[animation]\nenabled={master_enabled}\n[animation.scratchpad]\nenabled={pad_enabled}\nduration_ms=350\n"
                ), 0.0)

    def test_invalid_event_duration_inherits_valid_global(self) -> None:
        for value in self.INVALID_DURATIONS:
            with self.subTest(duration=value):
                self.assertEqual(self._config(
                    f"[animation]\nduration_ms=350\n[animation.scratchpad]\nenabled=true\nduration_ms={value}\n"
                ), 0.35)

    def test_invalid_global_duration_uses_native_default(self) -> None:
        for value in self.INVALID_DURATIONS:
            with self.subTest(duration=value):
                self.assertEqual(self._config(
                    f"[animation]\nduration_ms={value}\n[animation.scratchpad]\nenabled=true\n"
                ), 0.25)

    def test_native_duration_boundaries_are_valid_for_global_and_event(self) -> None:
        for duration in (1, 10000):
            for section in ("animation", "animation.scratchpad"):
                with self.subTest(duration=duration, section=section):
                    content = f"[{section}]\nduration_ms={duration}\n"
                    content += "enabled=true\n" if section == "animation.scratchpad" else "[animation.scratchpad]\nenabled=true\n"
                    self.assertEqual(self._config(content), duration / 1000)

    def test_malformed_enabled_values_follow_native_defaults(self) -> None:
        for value in ("0", "1", '"false"', '"true"'):
            with self.subTest(master_enabled=value):
                self.assertEqual(self._config(
                    f"[animation]\nenabled={value}\nduration_ms=350\n[animation.scratchpad]\nenabled=true\n"
                ), 0.35)
            with self.subTest(pad_enabled=value):
                self.assertEqual(self._config(
                    f"[animation]\nduration_ms=350\n[animation.scratchpad]\nenabled={value}\n"
                ), 0.0)

    def test_includes_merge_in_order_and_root_overrides_included_duration(self) -> None:
        first = Path(self._tmp.name) / "first.toml"
        second = Path(self._tmp.name) / "second.toml"
        first.write_text("[animation.scratchpad]\nenabled=true\nduration_ms=150\n", encoding="utf-8")
        second.write_text("[animation.scratchpad]\nduration_ms=275\n", encoding="utf-8")
        includes = '[include]\nfiles=["first.toml", "second.toml"]\n[animation]\nenabled=true\n'
        self.assertEqual(self._config(includes), 0.275)
        self.assertEqual(self._config(includes + "[animation.scratchpad]\nduration_ms=350\n"), 0.35)

    def test_unavailable_or_invalid_config_uses_fallback(self) -> None:
        for invalid in ("[animation", "[animation]\nscratchpad=7\n", '[animation.scratchpad]\nenabled=true\nduration_ms="bad"\n'):
            with self.subTest(config=invalid):
                self.assertEqual(self._config(invalid), 0.25)
        missing = Path(self._tmp.name) / "missing.toml"
        with mock.patch.dict("os.environ", {"CIDER_UMBRIEL_CONFIG": str(missing)}):
            self.assertEqual(cider_bridge._umbriel_fade_seconds(), 0.25)

    def test_restore_waits_remaining_configured_fade_before_workspace_reattach(self) -> None:
        config = Path(self._tmp.name) / "config.toml"
        config.write_text("[animation.scratchpad]\nenabled=true\nduration_ms=350\n", encoding="utf-8")
        pad = [{**UmbrielWindowProbeTests.JSON_SAMPLE[1], "workspace": "", "floating": True}]
        _, calls, send, listing = _umbriel_desktop(pad)
        events = []

        def recording_send(action):
            events.append(action)
            return send(action)

        with mock.patch.dict("os.environ", {"CIDER_UMBRIEL_CONFIG": str(config)}), mock.patch.object(
            cider_bridge.time, "monotonic", side_effect=[10.0, 10.075]
        ), mock.patch.object(cider_bridge.time, "sleep", side_effect=lambda delay: events.append(delay)):
            self.assertTrue(cider_bridge._restore_umbriel_window(
                "cider-id", "DP-1", listing(), recording_send, listing
            ))
        self.assertAlmostEqual(events[-3], 0.275)
        self.assertEqual(events[-2:], ["window-focus:cider-id", "window-restore-from-scratchpad:DP-1"])
        self.assertEqual(calls.count("scratchpad-toggle:DP-1"), 1)


class OverlayLauncherContractTests(unittest.TestCase):
    def test_service_does_not_pkill_overlay_by_cmdline_pattern(self) -> None:
        service = Path(__file__).resolve().parent.parent / "service.luau"
        text = service.read_text(encoding="utf-8")
        for line in text.splitlines():
            stripped = line.lstrip()
            if stripped.startswith("--"):
                continue
            self.assertNotIn(
                "pkill -f lyrics_overlay.py",
                line,
                "pkill -f matches a shell launcher cmdline and kills the overlay before it starts",
            )

    def test_service_uses_runasync_argv_for_process_launches(self) -> None:
        service = Path(__file__).resolve().parent.parent / "service.luau"
        text = service.read_text(encoding="utf-8")
        self.assertIn("plugin_api = 24", (Path(__file__).resolve().parent.parent / "plugin.toml").read_text(encoding="utf-8"))
        self.assertIn('runArgv({ "python3", script })', text)
        self.assertIn('runArgv({ "python3", script, "--toggle-loft" })', text)
        self.assertIn('runArgv({ "bash", launcher, baseUrl })', text)
        self.assertIn("noctaliaMsg(", text)
        # No shell-string noctalia msg / nohup launches left.
        code = "\n".join(
            line
            for line in text.splitlines()
            if not line.lstrip().startswith("--")
        )
        self.assertNotIn('noctalia.runAsync("noctalia msg', code)
        self.assertNotIn("nohup python3", code)
        self.assertIn('event == "chip-left"', text)
        self.assertIn('event == "toggle-loft"', text)
        self.assertIn('compositor or "") == "umbriel"', text)
        self.assertNotIn("umbriel msg", code)

    def test_service_does_not_push_external_lyrics_plugin(self) -> None:
        service = Path(__file__).resolve().parent.parent / "service.luau"
        text = service.read_text(encoding="utf-8")
        self.assertNotIn("push-state", text)
        self.assertNotIn("h465855hgg", text)
        self.assertNotIn("lyrics_plugin_id", text)
        self.assertNotIn("push_lyrics", text)

    def test_on_exit_kills_overlay_via_pidfile(self) -> None:
        service = Path(__file__).resolve().parent.parent / "service.luau"
        text = service.read_text(encoding="utf-8")
        self.assertIn("function onExit", text)
        self.assertIn("lyrics_overlay.pid", text)
        self.assertIn("function onEnable", text)

    def test_service_does_not_chmod_plugin_dir(self) -> None:
        service = Path(__file__).resolve().parent.parent / "service.luau"
        code = "\n".join(
            line
            for line in service.read_text(encoding="utf-8").splitlines()
            if not line.lstrip().startswith("--")
        )
        self.assertNotIn("chmod +x", code)

    def test_start_bridge_does_not_pass_token_argv(self) -> None:
        launcher = Path(__file__).resolve().parent / "start-bridge.sh"
        text = launcher.read_text(encoding="utf-8")
        self.assertNotIn("--token", text)
        self.assertIn("CIDER_APPTOKEN", text)


class DualTokenHeaderTests(unittest.TestCase):
    def test_bridge_sends_apptoken_and_apitoken(self) -> None:
        source = Path(__file__).resolve().parent / "cider_bridge.py"
        text = source.read_text(encoding="utf-8")
        self.assertIn('self._session.headers["apptoken"]', text)
        self.assertIn('self._session.headers["apitoken"]', text)

    def test_artwork_cdn_fetch_is_tokenless(self) -> None:
        source = Path(__file__).resolve().parent / "cider_bridge.py"
        text = source.read_text(encoding="utf-8")
        # Remote CDN must not reuse the Cider-token Session (ItsLemmy review).
        self.assertIn("resp = requests.get(url, timeout=10)", text)
        self.assertNotIn("self._session.get(url, timeout=10)", text)

    def test_connect_failed_emits_clear_before_status(self) -> None:
        source = Path(__file__).resolve().parent / "cider_bridge.py"
        text = source.read_text(encoding="utf-8")
        failed = text.find('message=f"connect_failed:{exc}"')
        self.assertGreater(failed, 0)
        window = text[max(0, failed - 400) : failed]
        self.assertIn('TrackEvent(type="clear")', window)
        self.assertIn("_wipe_playback_sidecars()", text)
        self.assertIn("_wipe_playback_sidecars()", text[text.find("def start(self)") :][:500])


class ClearWipesSidecarTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        self._prev_state = cider_bridge._STATE_DIR
        cider_bridge._STATE_DIR = Path(self._tmpdir.name)

    def tearDown(self) -> None:
        cider_bridge._STATE_DIR = self._prev_state
        self._tmpdir.cleanup()

    def test_clear_removes_stale_playing_state(self) -> None:
        state = cider_bridge._STATE_DIR / "state.json"
        pos = cider_bridge._STATE_DIR / "position.json"
        state.write_text(
            json.dumps(
                {
                    "type": "state",
                    "title": "Ghost",
                    "artist": "Track",
                    "playback_state": "playing",
                }
            ),
            encoding="utf-8",
        )
        pos.write_text(
            json.dumps({"position_ms": 1, "playing": True, "duration_ms": 10}),
            encoding="utf-8",
        )
        cider_bridge.emit(cider_bridge.TrackEvent(type="clear"))
        self.assertFalse(state.exists())
        self.assertFalse(pos.exists())


class GhostNotifyGuardTests(unittest.TestCase):
    def test_service_gates_state_rehydrate_while_offline(self) -> None:
        service = Path(__file__).resolve().parent.parent / "service.luau"
        text = service.read_text(encoding="utf-8")
        self.assertIn("local ciderOnline = false", text)
        self.assertIn("if not ciderOnline then", text)
        self.assertIn("markCiderOffline()", text)
        # Kickoff must start at EVENT (clear before any state rehydrate).
        self.assertIn(
            "-- Event before state: clear/connect_failed must land before any state rehydrate.",
            text,
        )
        kickoff = text.find(
            "-- Event before state: clear/connect_failed must land before any state rehydrate."
        )
        tail = text[kickoff:]
        self.assertIn("readFileAsync(EVENT_PATH, applyEvent)", tail)
        self.assertLess(
            tail.find("readFileAsync(EVENT_PATH, applyEvent)"),
            tail.find("readFileAsync(STATE_PATH, applyState)")
            if "readFileAsync(STATE_PATH, applyState)" in tail
            else 10**9,
        )

    def test_service_skips_absent_hide_without_compositor_probe(self) -> None:
        service = Path(__file__).resolve().parent.parent / "service.luau"
        text = service.read_text(encoding="utf-8")
        self.assertIn("compositorProbeUsable", text)
        self.assertIn('compositor ~= "none"', text)

    def test_widget_hides_when_no_track(self) -> None:
        widget = Path(__file__).resolve().parent.parent / "widget.luau"
        text = widget.read_text(encoding="utf-8")
        self.assertIn("barWidget.setVisible", text)
        self.assertIn("setChipVisible(false)", text)
        self.assertIn("function hasTrack()", text)
        self.assertNotIn("function onClick", text)
        toml = (Path(__file__).resolve().parent.parent / "plugin.toml").read_text(encoding="utf-8")
        self.assertIn("[widget.actions]", toml)
        self.assertIn('left = "plugin dragged/cider:bridge all toggle-lyrics-hud"', toml)
        self.assertIn('middle = "plugin dragged/cider:bridge all chip-left"', toml)
        self.assertIn('right = "plugin dragged/cider:bridge all show-osd"', toml)
        self.assertIn("toggle-lyrics-hud", toml)
        self.assertIn('type = "color"', toml)
        self.assertIn("advanced = true", toml)
        self.assertIn('type = "glyph"', toml)

    def test_service_gates_plain_lyrics_and_reapplies_on_config(self) -> None:
        service = Path(__file__).resolve().parent.parent / "service.luau"
        text = service.read_text(encoding="utf-8")
        self.assertIn("function lyricsArePlain", text)
        self.assertIn("suppressPlainLyricsSidecar", text)
        self.assertIn("plain_suppressed", text)
        self.assertIn("lastLyricsEvent", text)
        self.assertIn("applyLocalLyrics(lastLyricsEvent)", text)

    def test_unlist_does_not_emit_cider_closed(self) -> None:
        bridge = Path(__file__).resolve().parent / "cider_bridge.py"
        text = bridge.read_text(encoding="utf-8")
        self.assertNotIn("was_present and not present", text)
        self.assertNotIn('message="cider_closed"', text)
        self.assertIn("_clear_loft()", text)
        self.assertIn('message="disconnected"', text)
        service = Path(__file__).resolve().parent.parent / "service.luau"
        svc = service.read_text(encoding="utf-8")
        self.assertIn("maybeHideWhenCiderClosed", svc)
        self.assertIn("cider_closed", svc)
        self.assertIn('noctalia.state.set("now_playing", {', svc)


if __name__ == "__main__":
    unittest.main()
