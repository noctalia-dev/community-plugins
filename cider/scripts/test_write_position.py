#!/usr/bin/env python3
"""Regression: _write_position must update module globals without UnboundLocalError."""

from __future__ import annotations

import json
import subprocess
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

    def _snapshot_bridge(self) -> tuple[cider_bridge.CiderBridge, dict]:
        bridge = cider_bridge.CiderBridge("http://localhost", "", cider_bridge._STATE_DIR, 0.1)
        attrs = {"name": "song", "artistName": "artist", "durationInMillis": 180_000,
                 "currentPlaybackTime": 10, "_playback_state": "playing", "playParams": {"id": "123"}}
        with mock.patch.object(cider_bridge.time, "time", return_value=1000.0):
            with mock.patch.object(cider_bridge.threading.Thread, "start"):
                bridge._emit_from_attrs(attrs, reason="track")
        return bridge, attrs

    def _snapshot_response(self, attrs: dict | None, *, current: float = 45, state: str = "playing") -> mock.Mock:
        return mock.Mock(status_code=200, json=mock.Mock(return_value={"data": {
            "state": state, "nowPlaying": attrs,
            "time": {"currentTime": current, "duration": 180, "remaining": 180 - current},
        }}))

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

    def test_v2_provider_clock_accepts_seek_before_socket_tick_and_preserves_lyrics(self) -> None:
        bridge, attrs = self._snapshot_bridge()
        cider_bridge.emit(cider_bridge.TrackEvent(**dict(
            bridge._last, type="lyrics", lyrics_lines=[{"time": 0, "text": "line"}],
        )))
        lyrics_path = cider_bridge._STATE_DIR / "lyrics.json"
        event_path = cider_bridge._STATE_DIR / "event.json"
        before = lyrics_path.read_bytes(), event_path.read_bytes()
        with mock.patch.object(cider_bridge.time, "time", return_value=1000.05):
            with mock.patch.object(bridge._session, "get", return_value=self._snapshot_response(attrs)) as get:
                with mock.patch.object(cider_bridge.threading.Thread, "start") as start:
                    bridge.refresh_snapshot()
        get.assert_called_once_with("http://localhost/api/v2/playback", timeout=1)
        start.assert_not_called()
        self.assertEqual(cider_bridge._POS_ANCHOR_MS, 45_000)
        state = json.loads((cider_bridge._STATE_DIR / "state.json").read_text())
        self.assertEqual((state["type"], state["position_ms"], state["catalog_id"]), ("time", 45_000, "123"))
        self.assertEqual((lyrics_path.read_bytes(), event_path.read_bytes()), before)

    def test_v2_clock_owns_socket_time_state_and_track_even_with_newer_timestamp(self) -> None:
        bridge, attrs = self._snapshot_bridge()
        with mock.patch.object(cider_bridge.time, "time", return_value=1000.01) as clock:
            with mock.patch.object(bridge._session, "get", return_value=self._snapshot_response(attrs)):
                bridge.refresh_snapshot()
            self.assertTrue(bridge._provider_clock_active)
            paths = [cider_bridge._STATE_DIR / name for name in ("state.json", "position.json", "event.json")]
            before = [path.read_bytes() for path in paths], dict(bridge._last)
            clock.return_value = 1000.02
            stale = [
                ("playbackStatus.playbackTimeDidChange", {"currentPlaybackTime": 10.02,
                 "currentPlaybackDuration": 180, "isPlaying": True, "anchor": {"timestamp": 1000020}}),
                ("playbackStatus.playbackStateDidChange", {"state": "playing", "attributes": attrs}),
                ("playbackStatus.nowPlayingItemDidChange", dict(attrs, name="old queued track", playParams={"id": "456"})),
            ]
            with mock.patch.object(cider_bridge.threading.Thread, "start") as start:
                for event_type, payload in stale:
                    with self.subTest(event_type=event_type):
                        bridge._handle_event(event_type, payload)
                        self.assertEqual(cider_bridge._POS_ANCHOR_MS, 45_000)
                        self.assertEqual(([path.read_bytes() for path in paths], bridge._last), before)
                start.assert_not_called()

    def test_socket_artwork_completion_cannot_publish_after_native_claim_or_recovery(self) -> None:
        for recovering, release_native in ((False, False), (True, False), (False, True)):
            with self.subTest(recovering=recovering, release_native=release_native):
                bridge, attrs = self._snapshot_bridge()
                bridge._lyrics_key = "current lyrics"
                cider_bridge.emit(cider_bridge.TrackEvent(**dict(
                    bridge._last, type="lyrics", lyrics_lines=[{"time": 0, "text": "current"}],
                )))
                entered, release = cider_bridge.threading.Event(), cider_bridge.threading.Event()
                errors, fetches = [], []
                original_start = cider_bridge.threading.Thread.start

                def start(thread):
                    if thread.name in {"cider-lyrics", "cider-art"}:
                        fetches.append(thread.name)
                    else:
                        original_start(thread)

                def delayed_art(*_args):
                    entered.set()
                    if not release.wait(2):
                        raise TimeoutError("test artwork release missing")
                    return ""

                def old_socket():
                    try:
                        bridge._handle_event("playbackStatus.nowPlayingItemDidChange", dict(
                            attrs, name="old queued track", playParams={"id": "456"},
                            artwork={"url": "https://example.invalid/old.jpg"},
                        ))
                    except Exception as exc:
                        errors.append(exc)

                with mock.patch.object(cider_bridge.time, "time", return_value=1000.05):
                    with mock.patch.object(bridge._session, "get", return_value=self._snapshot_response(attrs)) as get:
                        with mock.patch.object(bridge, "_cache_artwork", side_effect=delayed_art):
                            with mock.patch.object(cider_bridge.threading.Thread, "start", new=start):
                                if recovering:
                                    bridge.refresh_snapshot()
                                    get.return_value = mock.Mock(status_code=503)
                                    bridge.refresh_snapshot()
                                    get.return_value = self._snapshot_response(attrs)
                                worker = cider_bridge.threading.Thread(target=old_socket, name="test-old-socket")
                                worker.start()
                                try:
                                    self.assertTrue(entered.wait(1), "socket should wait outside publication lock")
                                    bridge.refresh_snapshot()
                                    self.assertTrue(bridge._provider_clock_active)
                                    self.assertEqual(cider_bridge._POS_ANCHOR_MS, 45_000)
                                    paths = [cider_bridge._STATE_DIR / name for name in (
                                        "state.json", "position.json", "event.json", "lyrics.json",
                                    )]
                                    before = ([path.read_bytes() for path in paths], dict(bridge._last),
                                              bridge._track_key, bridge._lyrics_key)
                                    if release_native:
                                        get.return_value = mock.Mock(status_code=503)
                                        bridge.refresh_snapshot()
                                        self.assertFalse(bridge._provider_clock_active)
                                finally:
                                    release.set()
                                    worker.join(2)
                                self.assertFalse(worker.is_alive())
                                self.assertEqual(errors, [])
                                self.assertEqual(fetches, [])
                                self.assertEqual(([path.read_bytes() for path in paths], bridge._last,
                                                  bridge._track_key, bridge._lyrics_key), before)

    def test_socket_time_publication_and_native_claim_are_serialized(self) -> None:
        bridge, attrs = self._snapshot_bridge()
        entered, release = cider_bridge.threading.Event(), cider_bridge.threading.Event()
        requested, finished = cider_bridge.threading.Event(), cider_bridge.threading.Event()
        original_emit = cider_bridge.emit
        errors = []

        def delayed_emit(event, **kwargs):
            if event.type == "time" and event.position_ms == 10_000:
                entered.set()
                if not release.wait(2):
                    raise TimeoutError("test time release missing")
            original_emit(event, **kwargs)

        def native_response(*_args, **_kwargs):
            requested.set()
            return self._snapshot_response(attrs)

        def publish_socket():
            try:
                bridge._handle_event("playbackStatus.playbackTimeDidChange", {
                    "currentPlaybackTime": 10, "currentPlaybackDuration": 180, "isPlaying": True,
                })
            except Exception as exc:
                errors.append(exc)

        def publish_native():
            try:
                bridge.refresh_snapshot()
            except Exception as exc:
                errors.append(exc)
            finally:
                finished.set()

        socket = cider_bridge.threading.Thread(target=publish_socket, name="test-time-socket")
        native = cider_bridge.threading.Thread(target=publish_native, name="test-time-native")
        with mock.patch.object(cider_bridge.time, "time", return_value=1000.05):
            with mock.patch.object(cider_bridge, "emit", side_effect=delayed_emit):
                with mock.patch.object(bridge._session, "get", side_effect=native_response):
                    socket.start()
                    try:
                        self.assertTrue(entered.wait(1))
                        native.start()
                        self.assertTrue(requested.wait(1))
                        self.assertFalse(finished.wait(0.05), "native claim must wait for current socket publication")
                    finally:
                        release.set()
                        socket.join(2)
                        if native.ident is not None:
                            native.join(2)
        self.assertEqual(errors, [])
        self.assertFalse(socket.is_alive())
        self.assertFalse(native.is_alive())
        self.assertTrue(bridge._provider_clock_active)
        self.assertEqual((cider_bridge._POS_ANCHOR_MS, bridge._last["position_ms"]), (45_000, 45_000))

    def test_overlapping_snapshot_requests_cannot_finish_out_of_order(self) -> None:
        bridge, attrs = self._snapshot_bridge()
        entered, release = cider_bridge.threading.Event(), cider_bridge.threading.Event()
        errors = []

        def delayed_response(*_args, **_kwargs):
            entered.set()
            if not release.wait(2):
                raise TimeoutError("test snapshot release missing")
            return self._snapshot_response(attrs)

        def poll():
            try:
                bridge.refresh_snapshot()
            except Exception as exc:
                errors.append(exc)

        worker = cider_bridge.threading.Thread(target=poll, name="test-native-poll")
        with mock.patch.object(cider_bridge.time, "time", return_value=1000.05):
            with mock.patch.object(bridge._session, "get", side_effect=delayed_response) as get:
                worker.start()
                try:
                    self.assertTrue(entered.wait(1))
                    bridge.refresh_snapshot()
                    self.assertEqual(get.call_count, 1)
                finally:
                    release.set()
                    worker.join(2)
            self.assertFalse(worker.is_alive())
            self.assertEqual(errors, [])
            self.assertEqual(cider_bridge._POS_ANCHOR_MS, 45_000)
            with mock.patch.object(bridge._session, "get", return_value=self._snapshot_response(attrs, current=60)):
                bridge.refresh_snapshot()
            self.assertEqual(cider_bridge._POS_ANCHOR_MS, 60_000)

    def test_socket_disconnect_and_connect_failure_preserve_healthy_native_clock(self) -> None:
        bridge, attrs = self._snapshot_bridge()
        callbacks = {}
        with mock.patch.object(bridge._sio, "event", side_effect=lambda f: callbacks.setdefault(f.__name__, f)):
            bridge._register()
        paths = [cider_bridge._STATE_DIR / name for name in ("state.json", "position.json")]
        with mock.patch.object(cider_bridge.time, "time", return_value=1000.05):
            with mock.patch.object(bridge._session, "get", return_value=self._snapshot_response(attrs)) as get:
                bridge.refresh_snapshot()
                before = [path.read_bytes() for path in paths], dict(bridge._last), bridge._track_key
                with mock.patch.object(cider_bridge, "_clear_loft") as clear_loft:
                    callbacks["disconnect"]()
                    clear_loft.assert_not_called()
                self.assertEqual(([path.read_bytes() for path in paths], bridge._last, bridge._track_key), before)
                bridge._sio.connected = False
                with mock.patch.object(bridge._sio, "connect", side_effect=RuntimeError("socket unavailable")):
                    with mock.patch.object(bridge._stop, "is_set", side_effect=[False, True]):
                        with mock.patch.object(bridge._stop, "wait"):
                            bridge._run_sio()
                self.assertEqual(([path.read_bytes() for path in paths], bridge._last, bridge._track_key), before)
                get.return_value = mock.Mock(status_code=503)
                bridge.refresh_snapshot()
                callbacks["disconnect"]()
                self.assertEqual(bridge._last, {})
                self.assertFalse(any(path.exists() for path in paths))

    def test_native_artwork_fetch_cannot_replace_later_catalog_track(self) -> None:
        bridge, attrs = self._snapshot_bridge()
        art_attrs = dict(attrs, artwork={"url": "https://example.invalid/cover.jpg"})
        with mock.patch.object(cider_bridge.time, "time", return_value=1000.05):
            with mock.patch.object(cider_bridge.threading.Thread, "start"):
                with mock.patch.object(bridge._session, "get", return_value=self._snapshot_response(art_attrs)):
                    with mock.patch.object(bridge, "_cache_artwork") as cache:
                        bridge.refresh_snapshot()
                        cache.assert_not_called()
                old_key = bridge._track_key

                def switched_during_download(*_args):
                    response = self._snapshot_response(dict(art_attrs, playParams={"id": "456"}), current=0)
                    with mock.patch.object(bridge._session, "get", return_value=response):
                        bridge.refresh_snapshot()
                    return "/old-cover.jpg"

                with mock.patch.object(cider_bridge.time, "sleep"):
                    with mock.patch.object(bridge, "_cache_artwork", side_effect=switched_during_download):
                        bridge._retry_artwork(old_key, "https://example.invalid/cover.jpg", "123")
        self.assertEqual(bridge._last["catalog_id"], "456")
        self.assertEqual(bridge._last["artwork_path"], "")
        state = json.loads((cider_bridge._STATE_DIR / "state.json").read_text())
        self.assertEqual((state["type"], state["catalog_id"], state["artwork_path"]), ("track", "456", ""))

    def test_v2_failure_releases_socket_clock_and_recovery_reclaims_it(self) -> None:
        for failure in ("http", "unauthorized", "unsupported", "unscoped", "body", "state", "time", "json", "timeout"):
            with self.subTest(failure=failure):
                bridge, attrs = self._snapshot_bridge()
                valid = self._snapshot_response(attrs)
                bad = {
                    "http": [mock.Mock(status_code=503)],
                    "unauthorized": [mock.Mock(status_code=401)],
                    "unsupported": [mock.Mock(status_code=404), mock.Mock(status_code=200, json=mock.Mock(return_value={"info": attrs}))],
                    "unscoped": [mock.Mock(status_code=403), mock.Mock(status_code=200, json=mock.Mock(return_value={"info": attrs}))],
                    "body": [mock.Mock(status_code=200, json=mock.Mock(return_value={}))],
                    "state": [self._snapshot_response(attrs, state="seeking")],
                    "time": [self._snapshot_response(attrs, current=float("nan"))],
                    "json": [mock.Mock(status_code=200, json=mock.Mock(side_effect=ValueError("invalid JSON")))],
                    "timeout": [TimeoutError("local playback request timed out")],
                }[failure]
                with mock.patch.object(cider_bridge.time, "time", return_value=1000.01) as clock:
                    with mock.patch.object(bridge._session, "get", return_value=valid):
                        bridge.refresh_snapshot()
                    self.assertTrue(bridge._provider_clock_active)
                    clock.return_value = 1000.02
                    with mock.patch.object(bridge._session, "get", side_effect=bad):
                        bridge.refresh_snapshot()
                    self.assertFalse(bridge._provider_clock_active)
                    bridge._handle_event("playbackStatus.playbackTimeDidChange", {
                        "currentPlaybackTime": 60, "currentPlaybackDuration": 180, "isPlaying": True,
                    })
                    self.assertEqual(cider_bridge._POS_ANCHOR_MS, 60_000)
                    clock.return_value = 1000.03
                    with mock.patch.object(bridge._session, "get", return_value=self._snapshot_response(attrs, current=70)):
                        bridge.refresh_snapshot()
                    self.assertTrue(bridge._provider_clock_active)
                    bridge._handle_event("playbackStatus.playbackTimeDidChange", {
                        "currentPlaybackTime": 60, "currentPlaybackDuration": 180, "isPlaying": True,
                    })
                    self.assertEqual(cider_bridge._POS_ANCHOR_MS, 70_000)

    def test_v2_clock_stays_owned_during_next_request(self) -> None:
        bridge, attrs = self._snapshot_bridge()
        response = self._snapshot_response(attrs)
        with mock.patch.object(cider_bridge.time, "time", return_value=1000.01):
            with mock.patch.object(bridge._session, "get", return_value=response):
                bridge.refresh_snapshot()

            def pending_request(*_args, **_kwargs):
                self.assertTrue(bridge._provider_clock_active)
                bridge._handle_event("playbackStatus.playbackTimeDidChange", {
                    "currentPlaybackTime": 10.02, "currentPlaybackDuration": 180, "isPlaying": True,
                })
                self.assertEqual(cider_bridge._POS_ANCHOR_MS, 45_000)
                return response

            with mock.patch.object(bridge._session, "get", side_effect=pending_request) as get:
                bridge.refresh_snapshot()
            get.assert_called_once_with("http://localhost/api/v2/playback", timeout=1)

    def test_poll_disabled_keeps_socket_clock_after_initial_v2_snapshot(self) -> None:
        bridge, attrs = self._snapshot_bridge()
        bridge.poll_interval_sec = 0
        with mock.patch.object(cider_bridge.time, "time", return_value=1000.01):
            with mock.patch.object(bridge._session, "get", return_value=self._snapshot_response(attrs)):
                bridge.refresh_snapshot()
            self.assertFalse(bridge._provider_clock_active)
            bridge._handle_event("playbackStatus.playbackTimeDidChange", {
                "currentPlaybackTime": 60, "currentPlaybackDuration": 180, "isPlaying": True,
            })
            self.assertEqual(cider_bridge._POS_ANCHOR_MS, 60_000)

    def test_v2_provider_clock_accepts_backward_seek_and_freezes_paused_seek(self) -> None:
        for current, state in ((5, "playing"), (45, "paused")):
            with self.subTest(current=current, state=state):
                bridge, attrs = self._snapshot_bridge()
                with mock.patch.object(cider_bridge.time, "time", return_value=1000.05) as clock:
                    response = self._snapshot_response(attrs, current=current, state=state)
                    with mock.patch.object(bridge._session, "get", return_value=response):
                        bridge.refresh_snapshot()
                    self.assertEqual(cider_bridge._POS_ANCHOR_MS, current * 1000)
                    self.assertEqual(cider_bridge._POS_PLAYING, state == "playing")
                    clock.return_value = 1001.05
                    self.assertEqual(cider_bridge._estimated_position_ms(), (current + (state == "playing")) * 1000)

    def test_v2_short_backward_seek_crosses_boundary_without_repeating_rewind(self) -> None:
        from lyrics_overlay import resolve_line
        from lyrics_overlay_cfg import estimated_position_ms

        bridge, attrs = self._snapshot_bridge()
        lines = [{"time": 0, "text": "before"}, {"time": 9800, "text": "after"}]
        path = cider_bridge._STATE_DIR / "position.json"
        with mock.patch.object(cider_bridge.time, "time", return_value=1000.0) as clock:
            with mock.patch.object(bridge._session, "get", return_value=self._snapshot_response(attrs, current=10)) as get:
                bridge.refresh_snapshot()
                clock.return_value = 1000.05
                get.return_value = self._snapshot_response(attrs, current=9.5)
                bridge.refresh_snapshot()
                sought = json.loads(path.read_text())
                self.assertEqual(sought["position_ms"], 9500)
                shown = estimated_position_ms(sought, now=clock.return_value)
                self.assertEqual(resolve_line(lines, int(shown))[0]["text"], "before")
                for now in (1000.15, 1000.4, 1001.65):
                    clock.return_value = now
                    bridge._handle_event("playerStatus.volumeDidChange", {"volume": 0.5})
                    bridge.refresh_snapshot()
                    self.assertEqual(json.loads(path.read_text()), sought)
                    self.assertAlmostEqual(estimated_position_ms(sought, now=now), 9500 + (now - 1000.05) * 1000)
                    if now >= 1000.4:
                        self.assertEqual(resolve_line(lines, int(estimated_position_ms(sought, now=now)))[0]["text"], "after")
                clock.return_value = 1001.75
                get.return_value = self._snapshot_response(attrs, current=9.6)
                bridge.refresh_snapshot()
                self.assertEqual(json.loads(path.read_text()), sought, "an increasing cached source sample must not reverse interpolation")
                self.assertEqual(resolve_line(lines, int(cider_bridge._estimated_position_ms()))[0]["text"], "after")

    def test_v2_natural_forward_samples_preserve_interpolation_between_updates(self) -> None:
        bridge, attrs = self._snapshot_bridge()
        path = cider_bridge._STATE_DIR / "position.json"
        with mock.patch.object(cider_bridge.time, "time", return_value=1000.0) as clock:
            with mock.patch.object(bridge._session, "get", return_value=self._snapshot_response(attrs, current=10)) as get:
                bridge.refresh_snapshot()
                before = path.read_bytes()
                for now in (1000.1, 1000.4):
                    clock.return_value = now
                    bridge.refresh_snapshot()
                    self.assertEqual(path.read_bytes(), before)
                    self.assertAlmostEqual(cider_bridge._estimated_position_ms(), 10_000 + (now - 1000.0) * 1000, delta=1)
                clock.return_value = 1000.5
                get.return_value = self._snapshot_response(attrs, current=10.5)
                bridge.refresh_snapshot()
                self.assertEqual(cider_bridge._POS_ANCHOR_MS, 10_500)
                before = path.read_bytes()
                clock.return_value = 1000.6
                bridge.refresh_snapshot()
                self.assertEqual(path.read_bytes(), before)
                self.assertAlmostEqual(cider_bridge._estimated_position_ms(), 10_600, delta=1)
                clock.return_value = 1001.0
                get.return_value = self._snapshot_response(attrs, current=11)
                bridge.refresh_snapshot()
                self.assertEqual(cider_bridge._POS_ANCHOR_MS, 11_000)

    def test_v2_pause_resume_and_paused_scrubs_preserve_source_state(self) -> None:
        bridge, attrs = self._snapshot_bridge()
        path = cider_bridge._STATE_DIR / "position.json"
        with mock.patch.object(cider_bridge.time, "time", return_value=1000.0) as clock:
            with mock.patch.object(bridge._session, "get", return_value=self._snapshot_response(attrs, current=10)) as get:
                bridge.refresh_snapshot()
                clock.return_value = 1000.2
                get.return_value = self._snapshot_response(attrs, current=10, state="paused")
                bridge.refresh_snapshot()
                self.assertFalse(cider_bridge._POS_PLAYING)
                self.assertAlmostEqual(cider_bridge._POS_ANCHOR_MS, 10_200, delta=1)
                paused = path.read_bytes()
                clock.return_value = 1000.4
                bridge.refresh_snapshot()
                self.assertEqual(path.read_bytes(), paused)
                for now, current in ((1000.5, 10.1), (1000.6, 9.9)):
                    clock.return_value = now
                    get.return_value = self._snapshot_response(attrs, current=current, state="paused")
                    bridge.refresh_snapshot()
                    self.assertEqual(cider_bridge._POS_ANCHOR_MS, int(current * 1000))
                    self.assertFalse(cider_bridge._POS_PLAYING)
                paused = path.read_bytes()
                clock.return_value = 1001.6
                bridge.refresh_snapshot()
                self.assertEqual(path.read_bytes(), paused)
                clock.return_value = 1001.7
                get.return_value = self._snapshot_response(attrs, current=9.9)
                bridge.refresh_snapshot()
                self.assertTrue(cider_bridge._POS_PLAYING)
                self.assertEqual(cider_bridge._POS_ANCHOR_MS, 9900)
                clock.return_value = 1001.8
                self.assertAlmostEqual(cider_bridge._estimated_position_ms(), 10_000, delta=1)

    def test_provider_clock_history_uses_accepted_anchor_after_fallback_and_resets_for_track(self) -> None:
        bridge, attrs = self._snapshot_bridge()
        with mock.patch.object(cider_bridge.time, "time", return_value=1000.0) as clock:
            with mock.patch.object(bridge._session, "get", return_value=self._snapshot_response(attrs, current=10)) as get:
                with mock.patch.object(cider_bridge.threading.Thread, "start"):
                    bridge.refresh_snapshot()
                    get.return_value = mock.Mock(status_code=503)
                    bridge.refresh_snapshot()
                    bridge._handle_event("playbackStatus.playbackTimeDidChange", {
                        "currentPlaybackTime": 12, "currentPlaybackDuration": 180, "isPlaying": True,
                    })
                    self.assertIsNone(bridge._provider_clock_sample)
                    clock.return_value = 1000.05
                    get.return_value = self._snapshot_response(attrs, current=11.5)
                    bridge.refresh_snapshot()
                    self.assertEqual(cider_bridge._POS_ANCHOR_MS, 11_500)
                    new_attrs = dict(attrs, playParams={"id": "456"})
                    clock.return_value = 1000.1
                    get.return_value = self._snapshot_response(new_attrs, current=0)
                    bridge.refresh_snapshot()
                    self.assertEqual(cider_bridge._POS_ANCHOR_MS, 0)
                    self.assertEqual(bridge._provider_clock_sample, (0, "playing"))
                    clock.return_value = 1000.2
                    bridge.refresh_snapshot()
                    self.assertAlmostEqual(cider_bridge._estimated_position_ms(), 100, delta=1)

    def test_v2_new_catalog_track_resets_clock_and_retires_old_lyrics(self) -> None:
        bridge, attrs = self._snapshot_bridge()
        cider_bridge.emit(cider_bridge.TrackEvent(**dict(
            bridge._last, type="lyrics", lyrics_lines=[{"time": 0, "text": "old"}],
        )))
        response = self._snapshot_response(dict(attrs, currentPlaybackTime=59, playParams={"id": "456"}), current=0)
        with mock.patch.object(cider_bridge.time, "time", return_value=1000.05):
            with mock.patch.object(bridge._session, "get", return_value=response):
                with mock.patch.object(cider_bridge.threading.Thread, "start") as start:
                    bridge.refresh_snapshot()
        self.assertEqual(cider_bridge._POS_ANCHOR_MS, 0)
        self.assertEqual(bridge._last["catalog_id"], "456")
        self.assertEqual(bridge._last["type"], "track")
        self.assertFalse((cider_bridge._STATE_DIR / "lyrics.json").exists())
        start.assert_called_once()

    def test_unsupported_or_unscoped_v2_falls_back_without_trusting_legacy_spikes(self) -> None:
        for status in (403, 404):
            with self.subTest(status=status):
                bridge, attrs = self._snapshot_bridge()
                responses = [mock.Mock(status_code=status), mock.Mock(status_code=200, json=mock.Mock(
                    return_value={"info": dict(attrs, currentPlaybackTime=45)},
                ))]
                with mock.patch.object(cider_bridge.time, "time", return_value=1000.05):
                    with mock.patch.object(bridge._session, "get", side_effect=responses) as get:
                        with mock.patch.object(bridge, "_note_api_dead") as dead:
                            bridge.refresh_snapshot()
                self.assertEqual(get.call_args_list, [
                    mock.call("http://localhost/api/v2/playback", timeout=1),
                    mock.call("http://localhost/api/v1/playback/now-playing", timeout=5),
                ])
                dead.assert_not_called()
                self.assertEqual(cider_bridge._POS_ANCHOR_MS, 10_000)
                self.assertEqual(bridge._last["title"], "song")

    def test_malformed_v2_does_not_publish_or_clear_playback(self) -> None:
        bridge, attrs = self._snapshot_bridge()
        snapshot = {"state": "playing", "nowPlaying": attrs, "time": {"currentTime": 45, "duration": 180}}
        malformed = [None, [], {}, {"data": []}, {"data": {"nowPlaying": None}},
                     {"data": dict(snapshot, state="seeking")}, {"data": dict(snapshot, nowPlaying={})},
                     {"data": dict(snapshot, time={})},
                     {"data": dict(snapshot, nowPlaying=None, time={"currentTime": float("nan")})}]
        for field in ("currentTime", "duration"):
            for value in (True, -1, "45", float("nan"), float("inf")):
                malformed.append({"data": dict(snapshot, time=dict(snapshot["time"], **{field: value}))})
        paths = [cider_bridge._STATE_DIR / name for name in ("state.json", "position.json", "event.json")]
        before = [path.read_bytes() for path in paths]
        bridge._api_fail_streak = 2
        for payload in malformed:
            with self.subTest(payload=payload):
                response = mock.Mock(status_code=200, json=mock.Mock(return_value=payload))
                with mock.patch.object(bridge._session, "get", return_value=response):
                    bridge.refresh_snapshot()
                self.assertEqual([path.read_bytes() for path in paths], before)
                self.assertEqual(bridge._api_fail_streak, 2)
        response = mock.Mock(status_code=200, json=mock.Mock(side_effect=ValueError("invalid JSON")))
        with mock.patch.object(bridge._session, "get", return_value=response):
            bridge.refresh_snapshot()
        self.assertEqual([path.read_bytes() for path in paths], before)
        self.assertEqual(bridge._api_fail_streak, 2)

    def test_empty_v2_playback_and_sustained_api_failure_still_clear_sidecars(self) -> None:
        for empty in (True, False):
            with self.subTest(empty=empty):
                bridge, _attrs = self._snapshot_bridge()
                response = self._snapshot_response(None, current=0, state="stopped") if empty else mock.Mock(status_code=503)
                with mock.patch.object(bridge._session, "get", return_value=response):
                    if not empty:
                        for _ in range(2):
                            bridge.refresh_snapshot()
                            self.assertTrue((cider_bridge._STATE_DIR / "position.json").exists())
                    bridge.refresh_snapshot()
                self.assertFalse((cider_bridge._STATE_DIR / "position.json").exists())
                self.assertFalse((cider_bridge._STATE_DIR / "state.json").exists())
                self.assertEqual(bridge._last, {})
                self.assertEqual(bridge._provider_clock_active, empty)
                if empty:
                    bridge._handle_event("playbackStatus.playbackTimeDidChange", {
                        "currentPlaybackTime": 60, "currentPlaybackDuration": 180, "isPlaying": True,
                    })
                    self.assertFalse((cider_bridge._STATE_DIR / "position.json").exists())

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
        self._real_x11_main_for_view = cider_bridge._x11_main_for_view
        x11 = mock.patch.object(cider_bridge, "_x11_main_for_view", return_value=None)
        x11.start()
        self.addCleanup(x11.stop)
        window = mock.patch.object(cider_bridge, "_x11_window_for_view", return_value=None)
        window.start()
        self.addCleanup(window.stop)
        workspaces = mock.patch.object(cider_bridge, "_umbriel_workspaces_json", return_value=[
            {"id": "DP-1:1", "output": "DP-1", "name": "1", "active": True, "focused": True},
        ])
        workspaces.start()
        self.addCleanup(workspaces.stop)

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

    def test_window_helpers_do_not_import_playback_network_dependencies(self) -> None:
        source = Path(__file__).resolve().parent / "cider_bridge.py"
        check = """
import builtins, importlib.util, sys, tempfile
original_import = builtins.__import__
def without_playback(name, *args, **kwargs):
    if name in {"requests", "socketio"}:
        raise AssertionError("window helper imported playback dependencies")
    return original_import(name, *args, **kwargs)
builtins.__import__ = without_playback
spec = importlib.util.spec_from_file_location("cider_bridge_latency_check", sys.argv[1])
bridge = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = bridge
spec.loader.exec_module(bridge)
bridge._umbriel_windows_json = lambda: []
with tempfile.TemporaryDirectory() as state:
    for flag, status in (("--toggle-loft", 0), ("--show-window", 1)):
        sys.argv = [str(spec.origin), flag, "--state-dir", state]
        assert bridge.main() == status
"""
        subprocess.run([sys.executable, "-c", check, str(source)], check=True)


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

    def test_hidden_pad_starts_show_without_focus_retry_delay(self) -> None:
        pad = [{**self.JSON_SAMPLE[1], "workspace": "", "floating": True}]
        _, calls, send, listing = _umbriel_desktop(pad)
        events = []

        def recording_send(action):
            events.append(action)
            return send(action)

        with mock.patch.object(cider_bridge.time, "sleep", side_effect=lambda delay: events.append(delay)):
            self.assertTrue(cider_bridge._restore_umbriel_window(
                "cider-id", "DP-1", pad, recording_send, listing
            ))
        self.assertEqual(events[:2], ["window-focus:cider-id", "scratchpad-toggle:DP-1"])
        self.assertEqual(calls[-1], "window-restore-from-scratchpad:DP-1")

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


class CiderX11MiniplayerTests(unittest.TestCase):
    setUp = UmbrielWindowProbeTests.setUp
    tearDown = UmbrielWindowProbeTests.tearDown

    def _desktop(self, *, legacy=False, floating=False, restored_workspace="DP-1:1"):
        main = {**UmbrielWindowProbeTests.JSON_SAMPLE[1], "w": 1694, "h": 1372,
                "floating": floating, "active": False}
        if legacy:
            main.update(workspace="", floating=True)
        mini = {**main, "id": "mini-id", "title": "Cider - Mini Player",
                "workspace": "DP-1:1", "floating": True, "active": True}
        rows, calls, send, listing = _umbriel_desktop([main, mini])
        info = {"xid": "9001", "pid": 200, "start": "42", "w": 1694, "h": 1372}
        x11 = {"mapped": True, "info": info, "failure": "", "queries": True}
        actions = []
        path = cider_bridge._STATE_DIR / "miniplayer.json"
        current = {"workspace": restored_workspace}
        path.unlink(missing_ok=True)
        if legacy:
            path.write_text(json.dumps({"mini_id": "mini-id", "main_id": "cider-id",
                                        "output": "DP-1", "restore_main": True}))

        def command(*args):
            actions.append(args)
            self.assertEqual(json.loads(path.read_text())["main_x11"]["xid"], "9001")
            if args[0] == x11["failure"]:
                return None
            if args[0] == "windowunmap":
                x11["mapped"] = False
                rows[:] = [row for row in rows if row["title"] != "Cider"]
            elif args[0] == "windowmap":
                x11["mapped"] = True
                rows.append({**main, "id": "remapped-main-id", "workspace": current["workspace"],
                             "floating": not floating, "active": False})
            return "200"

        def compositor(action):
            if action.startswith("workspace-switch:"):
                calls.append(action)
                workspace, output = action.split(":", 1)[1].split("/", 1)
                current["workspace"] = f"{output}:{workspace}"
                return True
            if action.startswith("window-move-to-workspace:"):
                calls.append(action)
                workspace, output = action.split(":", 1)[1].split("/", 1)
                focused = next(row for row in rows if row.get("active"))
                focused["workspace"] = f"{output}:{workspace}"
                return True
            return send(action)

        patches = (
            mock.patch.object(cider_bridge, "_x11_main_for_view", return_value=info),
            mock.patch.object(cider_bridge, "_x11_window_for_view", return_value=info),
            mock.patch.object(cider_bridge, "_x11_main_info", side_effect=lambda xid: x11["info"] if x11["queries"] else None),
            mock.patch.object(cider_bridge, "_x11_main_mapped", side_effect=lambda value: x11["mapped"]),
            mock.patch.object(cider_bridge, "_x11_owner_current", return_value=True),
            mock.patch.object(cider_bridge, "_xdotool", side_effect=command),
            mock.patch.object(cider_bridge, "_umbriel_workspaces_json", side_effect=lambda: [
                {"id": f"DP-1:{name}", "focused": current["workspace"] == f"DP-1:{name}",
                 "active": current["workspace"] == f"DP-1:{name}", "output": "DP-1", "name": name}
                for name in ("1", "2")
            ]),
        )
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        return rows, calls, actions, compositor, listing, x11, path

    def test_main_is_unmapped_without_focus_or_shared_pad_then_restored_by_owned_xid(self) -> None:
        for floating in (False, True):
            with self.subTest(floating=floating):
                rows, calls, actions, send, listing, x11, path = self._desktop(
                    floating=floating, restored_workspace="DP-1:2"
                )
                cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
                self.assertEqual(calls, [])
                self.assertEqual(actions, [("windowunmap", "9001", "getwindowpid", "9001")])
                self.assertEqual([row["title"] for row in rows], ["Cider - Mini Player"])
                cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
                self.assertEqual(len(actions), 1)
                rows.clear()
                cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
                self.assertTrue(x11["mapped"])
                self.assertEqual(rows[0]["id"], "remapped-main-id")
                self.assertEqual(rows[0]["workspace"], "DP-1:2")
                self.assertEqual(rows[0]["floating"], floating)
                self.assertFalse(path.exists())
                self.assertNotIn("scratchpad-toggle:DP-1", calls)

    def test_manual_map_releases_ownership_without_hiding_focusing_or_moving_main(self) -> None:
        rows, calls, actions, send, listing, x11, path = self._desktop()
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        x11["mapped"] = True
        rows.append({**UmbrielWindowProbeTests.JSON_SAMPLE[1], "id": "manual-main-id",
                     "workspace": "DP-1:3", "active": True})
        before = list(calls)
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        self.assertFalse(json.loads(path.read_text())["restore_main"])
        rows[:] = [row for row in rows if row["title"] != "Cider - Mini Player"]
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        self.assertEqual(calls, before)
        self.assertEqual(len(actions), 1)
        self.assertEqual(rows[0]["workspace"], "DP-1:3")
        self.assertFalse(path.exists())

    def test_legacy_owned_pad_migrates_without_inventing_floating_or_workspace(self) -> None:
        rows, calls, actions, send, listing, _, path = self._desktop(legacy=True)
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        state = json.loads(path.read_text())
        self.assertIn("main_x11", state)
        self.assertNotIn("floating", state)
        self.assertNotIn("workspace", state)
        self.assertEqual(calls, [])
        self.assertEqual(len(actions), 1)
        self.assertEqual([row["title"] for row in rows], ["Cider - Mini Player"])

    def test_query_failure_and_reopened_mini_preserve_pending_owned_main(self) -> None:
        rows, calls, actions, send, listing, x11, path = self._desktop()
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        x11["queries"] = False
        rows[0]["id"] = "new-mini-id"
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        state = json.loads(path.read_text())
        self.assertEqual(state["mini_id"], "new-mini-id")
        self.assertTrue(state["restore_main"])
        self.assertEqual(state["main_x11"]["xid"], "9001")
        rows.clear()
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        self.assertTrue(path.exists())
        self.assertEqual(len(actions), 1)
        x11["queries"] = True
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        self.assertFalse(path.exists())
        self.assertEqual(actions[-1][0], "windowmap")

    def test_reused_xid_pid_or_process_start_never_restores_replacement(self) -> None:
        for changed in ({"pid": 201}, {"start": "43"}, {"xid": "9002"}):
            with self.subTest(changed=changed):
                rows, calls, actions, send, listing, x11, path = self._desktop()
                cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
                rows.clear()
                x11["info"] = {**x11["info"], **changed}
                cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
                self.assertEqual(len(actions), 1)
                self.assertEqual(calls, [])
                self.assertTrue(path.exists())

    def test_unmap_failure_retries_and_map_failure_keeps_owned_state(self) -> None:
        rows, calls, actions, send, listing, x11, path = self._desktop()
        x11["failure"] = "windowunmap"
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        self.assertTrue(x11["mapped"])
        self.assertNotIn("main_x11", json.loads(path.read_text()))
        self.assertEqual(calls, [])
        x11["failure"] = ""
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        rows.clear()
        x11["failure"] = "windowmap"
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        self.assertFalse(x11["mapped"])
        self.assertTrue(json.loads(path.read_text())["remapping"])
        x11["failure"] = ""
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        self.assertTrue(x11["mapped"])
        self.assertFalse(path.exists())

    def test_x11_search_matches_exact_main_geometry_and_excludes_helper(self) -> None:
        main = {"xwayland": True, "w": 1694, "h": 1372}
        records = {
            "1": {"xid": "1", "w": 10, "h": 10},
            "2": {"xid": "2", "w": 1694, "h": 1372},
        }
        with mock.patch.object(cider_bridge, "_xdotool", return_value="1\n2"), mock.patch.object(
            cider_bridge, "_x11_main_info", side_effect=records.get
        ):
            self.assertEqual(self._real_x11_main_for_view(main), records["2"])
            self.assertIsNone(self._real_x11_main_for_view({**main, "xwayland": False}))
            records["1"] = {"xid": "1", "w": 1694, "h": 1372}
            self.assertIsNone(self._real_x11_main_for_view(main))

    def test_x11_identity_uses_exact_title_class_pid_start_and_window_id(self) -> None:
        raw = "Cider\ncider\n200\nWINDOW=9001\nX=0\nY=0\nWIDTH=1694\nHEIGHT=1372\nSCREEN=0"
        with mock.patch.object(cider_bridge, "_xdotool", return_value=raw) as query, mock.patch.object(
            cider_bridge, "_x11_process_start", return_value="42"
        ) as start:
            self.assertEqual(cider_bridge._x11_main_info("9001"), {
                "xid": "9001", "pid": 200, "start": "42", "w": 1694, "h": 1372,
            })
            start.assert_called_once_with(200)
            for malformed in (raw.replace("Cider\n", "Other\n", 1),
                              raw.replace("cider\n", "other\n", 1),
                              raw.replace("WINDOW=9001", "WINDOW=9002"),
                              raw.replace("200\n", "0\n", 1), raw + "\nEXTRA=0"):
                with self.subTest(malformed=malformed):
                    query.return_value = malformed
                    self.assertIsNone(cider_bridge._x11_main_info("9001"))
            query.return_value = raw
            start.return_value = ""
            self.assertIsNone(cider_bridge._x11_main_info("9001"))
            query.reset_mock()
            self.assertIsNone(cider_bridge._x11_main_info("not-a-window"))
            query.assert_not_called()

    def test_pending_native_remap_survives_absence_and_is_hidden_again_on_mini_reopen(self) -> None:
        rows, calls, actions, send, listing, x11, path = self._desktop()
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        rows.clear()
        cider_bridge.reconcile_miniplayer([], msg=send, listing=lambda: [])
        self.assertTrue(json.loads(path.read_text())["remapping"])
        self.assertTrue(x11["mapped"])
        rows.append({"id": "new-mini-id", "app_id": "cider", "title": "Cider - Mini Player",
                     "workspace": "DP-1:1", "floating": True, "active": True})
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        state = json.loads(path.read_text())
        self.assertEqual(state["mini_id"], "new-mini-id")
        self.assertNotIn("remapping", state)
        self.assertTrue(state["restore_main"])
        self.assertFalse(x11["mapped"])
        self.assertEqual([action[0] for action in actions], ["windowunmap", "windowmap", "windowunmap"])
        self.assertEqual(calls, [])
        rows.clear()
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        self.assertFalse(path.exists())

    def test_identity_change_before_initial_unmap_rolls_back_without_action(self) -> None:
        _, calls, actions, send, listing, x11, path = self._desktop()
        x11["info"] = {**x11["info"], "pid": 201}
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        self.assertEqual(actions, [])
        self.assertEqual(calls, [])
        self.assertNotIn("main_x11", json.loads(path.read_text()))

    def test_launcher_remaps_pending_main_instead_of_authorizing_duplicate_launch(self) -> None:
        rows, _, actions, send, listing, _, path = self._desktop()
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        rows.clear()
        with mock.patch.object(cider_bridge, "_x11_owner_current", return_value=True), mock.patch.object(
            cider_bridge, "_umbriel_windows_json", side_effect=listing
        ), mock.patch.object(cider_bridge, "_umbriel_msg", side_effect=send):
            self.assertEqual(cider_bridge.show_cider_window(), 0)
        self.assertEqual(actions[-1][0], "windowmap")
        self.assertFalse(path.exists())

    def test_launcher_blocks_duplicate_on_failed_or_still_pending_remap(self) -> None:
        for failure in ("windowmap", "native-view-pending"):
            with self.subTest(failure=failure):
                rows, _, actions, send, listing, x11, path = self._desktop()
                cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
                rows.clear()
                x11["failure"] = failure
                query = (lambda: []) if failure == "native-view-pending" else listing
                with mock.patch.object(cider_bridge, "_x11_owner_current", return_value=None), mock.patch.object(
                    cider_bridge, "_umbriel_windows_json", side_effect=query
                ), mock.patch.object(cider_bridge, "_umbriel_msg", side_effect=send):
                    self.assertEqual(cider_bridge.show_cider_window(), 2)
                    before = len(actions)
                    self.assertEqual(cider_bridge.show_cider_window(), 2)
                    if failure == "native-view-pending":
                        self.assertEqual(len(actions), before)
                self.assertTrue(path.exists())
                self.assertTrue(json.loads(path.read_text())["restore_main"])

    def test_launcher_clears_proven_stale_owner_but_ignores_unrelated_journal(self) -> None:
        rows, calls, actions, send, listing, _, path = self._desktop()
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        rows.clear()
        with mock.patch.object(cider_bridge, "_x11_owner_current", return_value=False), mock.patch.object(
            cider_bridge, "_umbriel_windows_json", side_effect=listing
        ), mock.patch.object(cider_bridge, "_umbriel_msg", side_effect=send):
            self.assertEqual(cider_bridge.show_cider_window(), 1)
        self.assertFalse(path.exists())
        self.assertEqual(len(actions), 1)
        self.assertEqual(calls, [])
        path.write_text(json.dumps({"main_id": "stale-native-id", "restore_main": True}))
        with mock.patch.object(cider_bridge, "_umbriel_windows_json", return_value=[]), mock.patch.object(
            cider_bridge, "_x11_owner_current"
        ) as current:
            self.assertEqual(cider_bridge.show_cider_window(), 1)
            current.assert_not_called()

    def test_unrelated_native_main_during_remap_is_never_focused_or_moved(self) -> None:
        rows, calls, actions, send, listing, _, path = self._desktop()
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        rows.clear()
        with mock.patch.object(cider_bridge, "_x11_window_for_view", return_value={
            "xid": "9002", "pid": 201, "start": "43", "w": 1694, "h": 1372,
        }):
            cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        self.assertEqual(calls, [])
        self.assertEqual([action[0] for action in actions], ["windowunmap", "windowmap"])
        self.assertTrue(json.loads(path.read_text())["remapping"])
        cider_bridge.reconcile_miniplayer(listing(), msg=send, listing=listing)
        self.assertFalse(path.exists())

    def test_owner_probe_distinguishes_process_exit_reuse_and_query_failure(self) -> None:
        state = {"main_x11": {"xid": "9001", "pid": 200, "start": "42"}}
        with mock.patch.object(cider_bridge, "_x11_process_start", return_value="42") as start, mock.patch.object(
            cider_bridge, "_xdotool", return_value="9001\n9002"
        ) as query, mock.patch.object(cider_bridge.os, "kill") as probe:
            self.assertTrue(cider_bridge._x11_owner_current(state))
            query.assert_called_once_with("search", "--pid", "200")
            query.return_value = ""
            self.assertFalse(cider_bridge._x11_owner_current(state))
            query.return_value = None
            self.assertIsNone(cider_bridge._x11_owner_current(state))
            start.return_value = "43"
            self.assertFalse(cider_bridge._x11_owner_current(state))
            probe.assert_not_called()
            start.return_value = ""
            probe.side_effect = ProcessLookupError()
            self.assertFalse(cider_bridge._x11_owner_current(state))
            probe.assert_called_once_with(200, 0)
            probe.side_effect = PermissionError()
            self.assertIsNone(cider_bridge._x11_owner_current(state))
            probe.side_effect = None
            self.assertIsNone(cider_bridge._x11_owner_current(state))
            self.assertFalse(cider_bridge._x11_owner_current({"main_x11": {"pid": True}}))


class CiderWorkspaceRestoreTests(unittest.TestCase):
    setUp = UmbrielWindowProbeTests.setUp
    tearDown = UmbrielWindowProbeTests.tearDown

    def _config(self, remember):
        (cider_bridge._STATE_DIR / "lyrics_osd_cfg.json").write_text(
            json.dumps({"remember_workspace": remember})
        )

    def _desktop(self, title="Cider", *, delayed=False):
        target = {**UmbrielWindowProbeTests.JSON_SAMPLE[1], "id": "target-id", "title": title,
                  "w": 900, "h": 600, "floating": title != "Cider", "active": True}
        peer = {**UmbrielWindowProbeTests.JSON_SAMPLE[0], "active": False}
        rows, calls, native, listing = _umbriel_desktop([peer, target])
        info = {"xid": "100", "pid": 300, "start": "42", "w": 900, "h": 600}
        background = {**info, "xid": "200"}
        x11 = {"mapped": {"100": True, "200": False}, "exists": True,
               "current": "DP-1:1", "failure": "", "pending": None}
        actions = []
        if title == "Cider - Mini Player":
            (cider_bridge._STATE_DIR / "miniplayer.json").write_text(json.dumps({
                "mini_id": "target-id", "main_id": "old-main-id", "main_x11": background,
                "restore_main": True, "workspace": "DP-1:1", "floating": False,
            }))

        def command(*args):
            actions.append((args[0], x11["current"]))
            if args[0] == x11["failure"]:
                return None
            xid = args[1]
            if args[0] == "windowunmap":
                self.assertEqual(cider_bridge._read_loft()["x11"]["xid"], xid)
                x11["mapped"][xid] = False
                rows[:] = [row for row in rows if row["id"] != "target-id"]
            elif args[0] == "windowmap":
                x11["mapped"][xid] = True
                mapped = {**target, "id": "mapped-target", "workspace": x11["current"], "active": False}
                if xid == "200":
                    mapped.update(id="mapped-main", title="Cider", floating=False)
                if delayed:
                    x11["pending"] = mapped
                else:
                    rows.append(mapped)
            return "300"

        def send(action):
            if action.startswith("workspace-switch:"):
                calls.append(action)
                name, output = action.split(":", 1)[1].split("/", 1)
                x11["current"] = f"{output}:{name}"
                actions.append(("workspace-switch", x11["current"]))
                return True
            return native(action)

        def window_info(xid, expected="Cider"):
            if xid == "200":
                return background if expected == "Cider" else None
            return info if x11["exists"] and expected == title else None

        patches = (
            mock.patch.object(cider_bridge, "_x11_window_for_view", side_effect=lambda row: (
                background if row["title"] == "Cider" and title != "Cider" else info
            )),
            mock.patch.object(cider_bridge, "_x11_main_info", side_effect=lambda xid: window_info(xid)),
            mock.patch.object(cider_bridge, "_x11_window_info", side_effect=window_info),
            mock.patch.object(cider_bridge, "_x11_main_mapped", side_effect=lambda value: x11["mapped"][value["xid"]]),
            mock.patch.object(cider_bridge, "_x11_cached_owner_current", side_effect=lambda value: (
                True if value["xid"] == "200" else x11["exists"]
            )),
            mock.patch.object(cider_bridge, "_xdotool", side_effect=command),
            mock.patch.object(cider_bridge, "_umbriel_windows_json", side_effect=listing),
            mock.patch.object(cider_bridge, "_umbriel_msg", side_effect=send),
            mock.patch.object(cider_bridge, "_umbriel_workspaces_json", side_effect=lambda: [
                {"id": f"DP-1:{name}", "output": "DP-1", "name": name,
                 "focused": x11["current"] == f"DP-1:{name}", "active": x11["current"] == f"DP-1:{name}"}
                for name in ("1", "2")
            ]),
        )
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        return rows, calls, actions, send, listing, x11

    def test_remember_setting_requires_literal_boolean_true(self) -> None:
        self.assertFalse(cider_bridge._remember_workspace())
        for value in (False, 1, "true", None, {}, []):
            with self.subTest(value=value):
                self._config(value)
                self.assertFalse(cider_bridge._remember_workspace())
        self._config(True)
        self.assertTrue(cider_bridge._remember_workspace())

    def test_main_and_mini_default_reveal_directly_on_current_workspace(self) -> None:
        for title in ("Cider", "Cider - Mini Player"):
            with self.subTest(title=title):
                cider_bridge._clear_loft()
                rows, calls, actions, send, listing, x11 = self._desktop(title)
                cider_bridge.toggle_loft(send, listing)
                self.assertEqual(actions, [("windowunmap", "DP-1:1")])
                self.assertEqual(calls, [])
                saved = cider_bridge._read_loft()
                self.assertEqual(saved["workspace"], "DP-1:1")
                self.assertEqual(saved["title"], title)
                x11["current"] = "DP-1:2"
                peer = rows[0]
                peer.update(workspace="DP-1:2", active=True)
                payload = cider_bridge.apply_umbriel_listing(listing())
                self.assertTrue(payload["present"])
                self.assertEqual(cider_bridge._read_loft(), saved)
                cider_bridge.reconcile_miniplayer(listing(), send, listing)
                self.assertEqual(actions, [("windowunmap", "DP-1:1")])
                self.assertEqual(cider_bridge.show_cider_window(), 0)
                self.assertEqual(actions, [("windowunmap", "DP-1:1"), ("windowmap", "DP-1:2")])
                self.assertEqual(rows[-1]["workspace"], "DP-1:2")
                self.assertEqual(rows[-1]["floating"], title != "Cider")
                self.assertTrue(all(not call.startswith("window-move-to-workspace:") for call in calls))
                self.assertNotIn("x11", cider_bridge._read_loft())

    def test_remember_selects_original_before_first_map_for_main_and_mini(self) -> None:
        self._config(True)
        for title in ("Cider", "Cider - Mini Player"):
            with self.subTest(title=title):
                cider_bridge._clear_loft()
                rows, calls, actions, send, listing, x11 = self._desktop(title)
                cider_bridge.toggle_loft(send, listing)
                x11["current"] = "DP-1:2"
                rows[0].update(workspace="DP-1:2", active=True)
                cider_bridge.toggle_loft(send, listing)
                self.assertEqual(actions, [("windowunmap", "DP-1:1"),
                                           ("workspace-switch", "DP-1:1"), ("windowmap", "DP-1:1")])
                self.assertEqual(rows[-1]["workspace"], "DP-1:1")
                self.assertTrue(all(not call.startswith("window-move-to-workspace:") for call in calls))

    def test_hidden_and_pending_mini_keeps_background_main_owned_until_rebound(self) -> None:
        rows, _, actions, send, listing, x11 = self._desktop("Cider - Mini Player", delayed=True)
        cider_bridge.toggle_loft(send, listing)
        path = cider_bridge._STATE_DIR / "miniplayer.json"
        owned_main = json.loads(path.read_text())["main_x11"]
        cider_bridge.reconcile_miniplayer(listing(), send, listing)
        self.assertFalse(x11["mapped"]["200"])
        self.assertEqual(actions, [("windowunmap", "DP-1:1")])
        self.assertEqual(cider_bridge.show_cider_window(), 2)
        self.assertTrue(cider_bridge._read_loft()["remapping"])
        cider_bridge.apply_umbriel_listing(None)
        self.assertEqual(cider_bridge._read_loft()["x11"]["xid"], "100")
        cider_bridge.reconcile_miniplayer(listing(), send, listing)
        self.assertFalse(x11["mapped"]["200"])
        rows.append(x11["pending"])
        cider_bridge.reconcile_miniplayer(listing(), send, listing)
        self.assertNotIn("x11", cider_bridge._read_loft())
        self.assertEqual(json.loads(path.read_text())["main_x11"], owned_main)
        self.assertEqual(json.loads(path.read_text())["mini_id"], "mapped-target")
        self.assertFalse(x11["mapped"]["200"])

    def test_actual_hidden_mini_close_releases_latch_and_restores_main_current(self) -> None:
        rows, _, actions, send, listing, x11 = self._desktop("Cider - Mini Player")
        cider_bridge.toggle_loft(send, listing)
        x11.update(exists=False, current="DP-1:2")
        rows[0].update(workspace="DP-1:2", active=True)
        cider_bridge.reconcile_miniplayer(listing(), send, listing)
        self.assertTrue(x11["mapped"]["200"])
        self.assertEqual(actions[-1], ("windowmap", "DP-1:2"))
        self.assertFalse((cider_bridge._STATE_DIR / "miniplayer.json").exists())
        self.assertNotIn("x11", cider_bridge._read_loft())

    def test_miniplayer_main_remember_selects_original_before_remap(self) -> None:
        self._config(True)
        rows, _, actions, send, listing, x11 = self._desktop("Cider - Mini Player")
        cider_bridge.toggle_loft(send, listing)
        x11.update(exists=False, current="DP-1:2")
        rows[0].update(workspace="DP-1:2", active=True)
        cider_bridge.reconcile_miniplayer(listing(), send, listing)
        self.assertEqual(actions[-2:], [("workspace-switch", "DP-1:1"), ("windowmap", "DP-1:1")])
        self.assertEqual(rows[-1]["workspace"], "DP-1:1")

    def test_current_empty_workspace_and_other_output_need_no_window_to_choose_target(self) -> None:
        for workspace in ("DP-1:2", "HDMI-A-1:3"):
            with self.subTest(workspace=workspace):
                cider_bridge._clear_loft()
                rows, _, actions, send, listing, x11 = self._desktop()
                cider_bridge.toggle_loft(send, listing)
                rows.clear()
                x11["current"] = workspace
                with mock.patch.object(cider_bridge, "_umbriel_workspaces_json") as query:
                    self.assertEqual(cider_bridge.show_cider_window(), 0)
                    query.assert_not_called()
                self.assertEqual(actions[-1], ("windowmap", workspace))
                self.assertEqual(rows[-1]["workspace"], workspace)

    def test_proven_app_exit_releases_both_owned_journals_without_mapping(self) -> None:
        rows, _, actions, send, listing, x11 = self._desktop("Cider - Mini Player")
        cider_bridge.toggle_loft(send, listing)
        x11["exists"] = False
        with mock.patch.object(cider_bridge, "_x11_owner_current", return_value=False):
            cider_bridge.reconcile_miniplayer(listing(), send, listing)
        self.assertFalse((cider_bridge._STATE_DIR / "miniplayer.json").exists())
        self.assertNotIn("x11", cider_bridge._read_loft())
        self.assertEqual(actions, [("windowunmap", "DP-1:1")])

    def test_hide_failure_rolls_back_only_confirmed_unchanged_map(self) -> None:
        _, calls, _, send, listing, x11 = self._desktop()
        x11["failure"] = "windowunmap"
        cider_bridge.toggle_loft(send, listing)
        self.assertTrue(x11["mapped"]["100"])
        self.assertNotIn("x11", cider_bridge._read_loft())
        self.assertEqual(calls, [])

    def test_failed_map_retains_owned_loft_for_launcher_retry(self) -> None:
        _, _, actions, send, listing, x11 = self._desktop()
        cider_bridge.toggle_loft(send, listing)
        x11["failure"] = "windowmap"
        self.assertEqual(cider_bridge.show_cider_window(), 2)
        self.assertTrue(cider_bridge._read_loft()["remapping"])
        x11["failure"] = ""
        self.assertEqual(cider_bridge.show_cider_window(), 0)
        self.assertEqual([action[0] for action in actions], ["windowunmap", "windowmap", "windowmap"])
        self.assertNotIn("x11", cider_bridge._read_loft())

    def test_failed_workspace_selection_never_maps_on_wrong_workspace(self) -> None:
        self._config(True)
        _, _, actions, send, listing, x11 = self._desktop()
        cider_bridge.toggle_loft(send, listing)
        x11["current"] = "DP-1:2"
        with mock.patch.object(cider_bridge, "_umbriel_msg", return_value=False):
            self.assertEqual(cider_bridge.show_cider_window(), 2)
        self.assertEqual(actions, [("windowunmap", "DP-1:1")])
        self.assertFalse(x11["mapped"]["100"])

    def test_legacy_hidden_pad_migrates_current_without_inventing_original_floating(self) -> None:
        rows, _, actions, _, _, x11 = self._desktop()
        rows[1].update(workspace="", floating=True, active=False)
        rows[0].update(workspace="DP-1:2", active=True)
        x11["current"] = "DP-1:2"
        cider_bridge._write_loft({"id": "target-id", "output": "DP-1", "lofted": True})
        with mock.patch.object(cider_bridge, "_restore_x11_window", return_value=False):
            self.assertEqual(cider_bridge.show_cider_window(), 2)
        saved = cider_bridge._read_loft()
        self.assertNotIn("floating", saved)
        self.assertNotIn("workspace", saved)
        self.assertEqual(actions, [("windowunmap", "DP-1:2")])
        self.assertEqual(cider_bridge.show_cider_window(), 0)
        self.assertEqual(actions[-1], ("windowmap", "DP-1:2"))
        self.assertFalse(rows[-1]["floating"])

    def test_manual_map_releases_loft_ownership_without_remap_or_workspace_switch(self) -> None:
        self._config(True)
        rows, calls, actions, send, listing, x11 = self._desktop()
        cider_bridge.toggle_loft(send, listing)
        x11["mapped"]["100"] = True
        rows.append({"id": "manual-id", "app_id": "cider", "title": "Cider", "xwayland": True,
                     "w": 900, "h": 600, "workspace": "DP-1:2", "floating": True, "active": True})
        cider_bridge.apply_umbriel_listing(listing())
        self.assertNotIn("x11", cider_bridge._read_loft())
        self.assertEqual(cider_bridge.show_cider_window(), 0)
        self.assertEqual(actions, [("windowunmap", "DP-1:1")])
        self.assertEqual(calls, ["window-focus:manual-id"])
        self.assertEqual(rows[-1]["workspace"], "DP-1:2")
        self.assertTrue(rows[-1]["floating"])

    def test_hide_revalidates_identity_before_x_action(self) -> None:
        _, calls, actions, send, listing, _ = self._desktop()
        with mock.patch.object(cider_bridge, "_x11_main_info", return_value={
            "xid": "100", "pid": 301, "start": "43", "w": 900, "h": 600,
        }):
            cider_bridge.toggle_loft(send, listing)
        self.assertEqual(actions, [])
        self.assertEqual(calls, [])
        self.assertNotIn("x11", cider_bridge._read_loft())

    def test_exact_mini_identity_rejects_wrong_or_unrequested_titles(self) -> None:
        raw = "Cider - Mini Player\ncider\n300\nWINDOW=100\nX=0\nY=0\nWIDTH=900\nHEIGHT=600\nSCREEN=0"
        with mock.patch.object(cider_bridge, "_xdotool", return_value=raw) as query, mock.patch.object(
            cider_bridge, "_x11_process_start", return_value="42"
        ):
            self.assertEqual(cider_bridge._x11_window_info("100", "Cider - Mini Player"), {
                "xid": "100", "pid": 300, "start": "42", "w": 900, "h": 600,
            })
            self.assertIsNone(cider_bridge._x11_window_info("100", "Cider"))
            query.reset_mock()
            self.assertIsNone(cider_bridge._x11_window_info("100", "Other"))
            query.assert_not_called()

    def test_native_pad_fallback_selects_saved_workspace_before_any_reveal(self) -> None:
        pad = [UmbrielWindowProbeTests.JSON_SAMPLE[0],
               {**UmbrielWindowProbeTests.JSON_SAMPLE[1], "workspace": "", "floating": True}]
        rows, calls, native, listing = _umbriel_desktop(pad)
        current = {"id": "DP-1:2"}

        def send(action):
            if action.startswith("workspace-switch:"):
                calls.append(action)
                current["id"] = "DP-1:1"
                return True
            if action.startswith("scratchpad-toggle:"):
                self.assertEqual(current["id"], "DP-1:1")
            return native(action)

        with mock.patch.object(cider_bridge, "_umbriel_workspaces_json", side_effect=lambda: [
            {"id": f"DP-1:{name}", "focused": current["id"] == f"DP-1:{name}"}
            for name in ("1", "2")
        ]):
            self.assertTrue(cider_bridge._restore_umbriel_window(
                "cider-id", "DP-1", listing(), send, listing, workspace="DP-1:1"
            ))
        self.assertEqual(calls[0], "workspace-switch:1/DP-1")
        self.assertLess(calls.index("workspace-switch:1/DP-1"), calls.index("scratchpad-toggle:DP-1"))
        self.assertEqual(rows[1]["workspace"], "DP-1:1")


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


class UmbrielWindowSubscriptionTests(unittest.TestCase):
    setUp = UmbrielWindowProbeTests.setUp
    tearDown = UmbrielWindowProbeTests.tearDown

    def _bridge(self):
        bridge = object.__new__(cider_bridge.CiderBridge)
        bridge._stop = mock.Mock()
        bridge._stop.is_set.return_value = False
        return bridge

    def test_native_event_hides_main_and_floats_mini_without_poll_wait(self) -> None:
        main = {**UmbrielWindowProbeTests.JSON_SAMPLE[1], "active": True}
        rows, calls, send, listing = _umbriel_desktop([main])
        mini = {**main, "id": "mini-id", "title": "Cider - Mini Player", "floating": False}
        watch = subprocess.Popen(
            [sys.executable, "-u", "-c", 'import time; print("{\\"event\\":\\"windows\\",\\"data\\":[]}"); time.sleep(60)'],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
        self.addCleanup(cider_bridge._close_umbriel_watch, watch)
        bridge = self._bridge()
        writes = []
        read = cider_bridge.os.read

        def mapped_event(fd, count):
            data = read(fd, count)
            rows.append(mini)
            return data

        def record(payload):
            writes.append(payload)
            if len(writes) == 2:
                bridge._stop.is_set.return_value = True

        with mock.patch.object(cider_bridge.shutil, "which", return_value="/usr/bin/umbriel"), mock.patch.object(
            cider_bridge.subprocess, "Popen", return_value=watch
        ) as spawn, mock.patch.object(cider_bridge, "_umbriel_windows_json", side_effect=listing), mock.patch.object(
            cider_bridge, "_umbriel_msg", side_effect=send
        ), mock.patch.object(cider_bridge, "probe_cider_window", side_effect=lambda: {"tick": len(writes) + 1}), mock.patch.object(
            cider_bridge, "_write_window", side_effect=record
        ), mock.patch.object(cider_bridge.os, "read", side_effect=mapped_event):
            bridge._window_loop()
        spawn.assert_called_once_with(
            ["umbriel", "subscribe", "windows,workspaces"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
        bridge._stop.wait.assert_not_called()
        self.assertEqual(len(writes), 2)
        self.assertEqual(rows[0]["workspace"], "")
        self.assertTrue(rows[1]["floating"])
        self.assertTrue(rows[1]["active"])
        self.assertEqual(calls.count("window-move-to-scratchpad:DP-1"), 1)
        self.assertIsNotNone(watch.poll())
        self.assertTrue(watch.stdout.closed)

    def test_stream_unavailable_or_eof_uses_fast_polling_fallback(self) -> None:
        for failure in ("spawn", "eof", "missing"):
            with self.subTest(failure=failure):
                bridge = self._bridge()
                bridge._stop.wait.side_effect = lambda delay: setattr(bridge._stop.is_set, "return_value", True)
                read_fd, write_fd = cider_bridge.os.pipe()
                cider_bridge.os.close(write_fd)
                stream = cider_bridge.os.fdopen(read_fd, "rb")
                watch = mock.Mock(stdout=stream)
                watch.poll.return_value = 0
                with mock.patch.object(cider_bridge.shutil, "which", return_value=None if failure == "missing" else "/usr/bin/umbriel"), mock.patch.object(
                    cider_bridge.subprocess, "Popen", side_effect=OSError("unavailable") if failure == "spawn" else None, return_value=watch
                ) as spawn, mock.patch.object(cider_bridge, "_umbriel_windows_json", return_value=[]), mock.patch.object(
                    cider_bridge, "probe_cider_window", return_value={"present": False}
                ), mock.patch.object(cider_bridge, "_write_window"):
                    bridge._window_loop()
                bridge._stop.wait.assert_called_once_with(0.1)
                if failure == "missing":
                    spawn.assert_not_called()
                elif failure == "eof":
                    self.assertTrue(stream.closed)
                    watch.wait.assert_called_once_with(timeout=1)
                stream.close()

    def test_eof_reconnects_after_backoff_and_cleans_up_next_stream(self) -> None:
        streams = []
        watches = []
        for payload in (b"", b'{"event":"windows","data":[]}\n'):
            read_fd, write_fd = cider_bridge.os.pipe()
            if payload:
                cider_bridge.os.write(write_fd, payload)
            cider_bridge.os.close(write_fd)
            stream = cider_bridge.os.fdopen(read_fd, "rb")
            streams.append(stream)
            watches.append(mock.Mock(stdout=stream))
            watches[-1].poll.return_value = 0
            self.addCleanup(stream.close)
        bridge = self._bridge()
        clock = [0.0]
        bridge._stop.wait.side_effect = lambda delay: clock.__setitem__(0, 5.0)
        writes = []

        def record(payload):
            writes.append(payload)
            if len(writes) == 3:
                bridge._stop.is_set.return_value = True

        with mock.patch.object(cider_bridge.shutil, "which", return_value="/usr/bin/umbriel"), mock.patch.object(
            cider_bridge.subprocess, "Popen", side_effect=watches
        ) as spawn, mock.patch.object(cider_bridge.time, "monotonic", side_effect=lambda: clock[0]), mock.patch.object(
            cider_bridge, "_umbriel_windows_json", return_value=[]
        ), mock.patch.object(cider_bridge, "probe_cider_window", side_effect=lambda: {"tick": len(writes) + 1}), mock.patch.object(
            cider_bridge, "_write_window", side_effect=record
        ):
            bridge._window_loop()
        self.assertEqual(spawn.call_count, 2)
        bridge._stop.wait.assert_called_once_with(0.1)
        self.assertTrue(all(stream.closed for stream in streams))
        for watch in watches:
            watch.wait.assert_called_once_with(timeout=1)

    def test_slow_subscription_process_is_killed_and_reaped(self) -> None:
        watch = mock.Mock()
        watch.poll.return_value = None
        watch.wait.side_effect = [subprocess.TimeoutExpired("umbriel", 1), 0]
        cider_bridge._close_umbriel_watch(watch)
        watch.stdout.close.assert_called_once()
        watch.terminate.assert_called_once()
        watch.kill.assert_called_once()
        self.assertEqual(watch.wait.call_count, 2)

    def test_bridge_stop_reaps_subscription_before_returning(self) -> None:
        bridge = self._bridge()
        bridge._window_watch = mock.Mock()
        bridge._window_watch.poll.return_value = None
        bridge._window_thread = mock.Mock()
        bridge._window_thread.is_alive.return_value = True
        bridge._sio = mock.Mock()
        events = []
        bridge._stop.set.side_effect = lambda: events.append("stop")
        bridge._window_watch.wait.side_effect = lambda timeout: events.append("reaped")
        bridge._window_thread.join.side_effect = lambda timeout: events.append("joined")
        bridge._sio.disconnect.side_effect = lambda: events.append("disconnected")
        bridge.stop()
        self.assertEqual(events, ["stop", "reaped", "joined", "disconnected"])
        bridge._window_watch.terminate.assert_called_once()
        bridge._window_thread.join.assert_called_once_with(timeout=2)

    def test_sigterm_runs_bridge_cleanup_and_restores_handler(self) -> None:
        bridge = mock.Mock()
        previous_handler = object()
        handlers = []

        def register(signum, handler):
            self.assertEqual(signum, cider_bridge.signal.SIGTERM)
            handlers.append(handler)
            return previous_handler

        bridge.start.side_effect = lambda: handlers[0](cider_bridge.signal.SIGTERM, None)
        with mock.patch.object(cider_bridge, "CiderBridge", return_value=bridge), mock.patch.object(
            cider_bridge.signal, "signal", side_effect=register
        ), mock.patch.object(sys, "argv", ["cider_bridge.py", "--state-dir", self._tmp.name]):
            self.assertEqual(cider_bridge.main(), 0)
        bridge._stop.set.assert_called_once()
        bridge.stop.assert_called_once()
        self.assertEqual(handlers[-1], previous_handler)


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
