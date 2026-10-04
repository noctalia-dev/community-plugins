#!/usr/bin/env python3
"""Regression coverage for the bundled media-idle-bridge inhibitor reasons.

Inhibitor reasons are published in systemd-inhibit --why, /proc argv, logind's
ListInhibitors metadata, and the ScreenSaver.Inhibit call - every one of them readable
by any local user - so they must stay coarse constants.  Player identities, titles, and
URLs must never appear there or in the journal.  Run display-free:

    python3 -m unittest discover -s tests -p 'test_media_bridge.py' -v
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from dataclasses import replace
from importlib.machinery import SourceFileLoader
from pathlib import Path

PLUGIN_DIR = Path(__file__).resolve().parents[1]

spec = importlib.util.spec_from_loader(
    "niri_media_idle_bridge",
    SourceFileLoader("niri_media_idle_bridge", str(PLUGIN_DIR / "media-idle-bridge")),
)
assert spec and spec.loader
bridge = importlib.util.module_from_spec(spec)
sys.modules["niri_media_idle_bridge"] = bridge
spec.loader.exec_module(bridge)


class FakeSource:
    def __init__(self, state: bridge.MediaState) -> None:
        self.state = state

    def snapshot(self) -> bridge.MediaState:
        return self.state


class FakeInhibitors:
    def __init__(self) -> None:
        self.held = set()
        self.reasons = []          # (lease, reason) as handed to the adapter

    def acquire_sleep(self, reason):
        self.reasons.append(("sleep", reason))
        self.held.add("sleep")
        return True

    def acquire_logind(self, reason):
        self.reasons.append(("logind", reason))
        self.held.add("logind")
        return True

    def acquire_screensaver(self, reason):
        self.reasons.append(("screensaver", reason))
        self.held.add("screensaver")
        return True

    def release_logind(self):
        self.held.discard("logind")

    def release_screensaver(self):
        self.held.discard("screensaver")

    def release_sleep(self):
        self.held.discard("sleep")


class FakeRetryScheduler:
    def __init__(self) -> None:
        self.delays = []
        self.pending = {}
        self.cancelled = []

    def schedule(self, delay, callback):
        handle = len(self.delays) + 1
        self.delays.append(delay)
        self.pending[handle] = callback
        return handle

    def cancel(self, handle):
        self.cancelled.append(handle)
        self.pending.pop(handle, None)


def player(identity="", status="Playing", url="", title=""):
    return bridge.Player(bus_name="org.mpris.MediaPlayer2.fake", identity=identity,
                         status=status, url=url, title=title)


class InhibitorReasonPrivacyTests(unittest.TestCase):
    def _bridge(self, state, **rule_overrides):
        return bridge.Bridge(
            replace(bridge.default_rules(), **rule_overrides),
            FakeSource(state),
            inhibitors=FakeInhibitors(),
            retry_scheduler=FakeRetryScheduler(),
        )

    def test_video_reasons_are_coarse_and_leak_no_media_metadata(self):
        victim = player(identity="private-player", title="private-title",
                        url="https://private.invalid/watch?token=SECRET")
        subject = self._bridge(
            bridge.MediaState(players=[victim], streams=[]),
            video_players=("private-player",),
        )

        with self.assertLogs("media-idle-bridge", level="INFO") as captured:
            subject.evaluate("test")

        self.assertEqual({reason for _, reason in subject.inhibitors.reasons},
                         {"video playback"})
        self.assertEqual({lease for lease, _ in subject.inhibitors.reasons},
                         {"logind", "screensaver", "sleep"})
        journal = "\n".join(captured.output)
        for leak in ("SECRET", "private.invalid", "private-title", "private-player"):
            self.assertNotIn(leak, journal)

        with self.assertLogs("media-idle-bridge", level="DEBUG") as captured:
            subject.evaluate("test")
        journal = "\n".join(captured.output)
        for leak in ("SECRET", "private.invalid", "private-title", "private-player"):
            self.assertNotIn(leak, journal)

    def test_music_reason_is_the_coarse_music_constant(self):
        subject = self._bridge(
            bridge.MediaState(players=[player(identity="private-music")], streams=[]),
            music_players=("private-music",),
        )

        with self.assertLogs("media-idle-bridge", level="INFO") as captured:
            result = subject.evaluate("test")

        self.assertFalse(result.decision)
        self.assertEqual({reason for _, reason in subject.inhibitors.reasons},
                         {"music playback"})
        self.assertNotIn("private-music", "\n".join(captured.output))

    def test_pipewire_backstop_reason_is_coarse(self):
        subject = self._bridge(
            bridge.MediaState(players=[], streams=[
                bridge.Stream(node_id=1, binary="private-player", state="running",
                              role="video")]),
            video_binaries=("private-player",),
        )

        with self.assertLogs("media-idle-bridge", level="INFO") as captured:
            result = subject.evaluate("test")

        self.assertTrue(result.decision)
        self.assertEqual({reason for _, reason in subject.inhibitors.reasons},
                         {"video playback"})
        self.assertNotIn("private-player", "\n".join(captured.output))


if __name__ == "__main__":
    unittest.main()
