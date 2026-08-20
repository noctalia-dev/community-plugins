#!/usr/bin/env python3
"""Regression: _write_position must update module globals without UnboundLocalError."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

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
                "pkill -f matches the runAsync launcher argv and kills the overlay before it starts",
            )

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


if __name__ == "__main__":
    unittest.main()
