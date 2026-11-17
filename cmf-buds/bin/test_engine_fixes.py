#!/usr/bin/env python3
"""Regression tests for the local shortcut engine.

Each test describes a bug that was found in the pre-PR review. They are
written as plain unit tests so they run in a few seconds (the long
behavioural suite lives in ``test_local_actions.py``).
"""

import json
import os
import struct
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import local_actions


class TrackingRLock:
    """An RLock that counts how many times it was entered."""

    def __init__(self):
        self._lock = threading.RLock()
        self.entered = 0

    def __enter__(self):
        self.entered += 1
        self._lock.acquire()
        return self

    def __exit__(self, *exc):
        self._lock.release()
        return False


class EngineTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = self._tmp.name
        self.engine = local_actions.LocalActionEngine(
            self.dir, log=lambda msg: None
        )

    def tearDown(self):
        self._tmp.cleanup()

    def rule(self, **overrides):
        rule = {
            "id": "r1",
            "enabled": True,
            "trigger": "volume_up",
            "presses": 0,
            "require": [],
            "forbid": [],
            "command": "echo hi",
            "notify": False,
        }
        rule.update(overrides)
        return rule

    # -- A13: rule ids must not collide ------------------------------------
    def test_upsert_generates_a_unique_id_for_every_rule(self):
        with mock.patch.object(local_actions.time, "time", lambda: 1000.0):
            self.engine.upsert(self.rule(trigger="volume_up", id=""))
            self.engine.upsert(self.rule(trigger="volume_down", id=""))
        ids = [str(r.get("id")) for r in self.engine.rules]
        self.assertEqual(len(ids), 2, "the second rule overwrote the first one")
        self.assertEqual(len(set(ids)), 2, "two rules share the same id")

    # -- A14: the event size must follow the native layout ------------------
    def test_input_event_size_is_derived_from_the_event_format(self):
        self.assertEqual(
            local_actions.INPUT_EVENT_SIZE,
            struct.calcsize(local_actions.INPUT_EVENT_FORMAT),
        )
        self.assertEqual(
            local_actions._input_event_size(local_actions.INPUT_EVENT_FORMAT),
            struct.calcsize(local_actions.INPUT_EVENT_FORMAT),
        )

    # -- A15: a vanished input device must release the modifiers ------------
    def test_held_modifiers_are_cleared_when_an_input_device_disappears(self):
        tracker = local_actions.ModifierTracker(log=lambda msg: None)
        fd = os.open(__file__, os.O_RDONLY)
        tracker._fds = {fd: "/dev/input/event99"}
        tracker._by_path = {"/dev/input/event99": fd}
        tracker.held.add("super")
        with mock.patch.object(
            local_actions, "_list_event_devices", return_value=[]
        ):
            tracker._refresh_devices()
        self.assertEqual(
            tracker.modifiers(), [], "the modifier is still held after the device vanished"
        )

    # -- A16: only the earbuds may report a case press ----------------------
    def test_media_press_is_ignored_when_the_buds_are_not_the_default_sink(self):
        calls = []
        self.engine.run_command = lambda cmd, **kw: calls.append(cmd) or True
        self.engine.upsert(self.rule(trigger="knob_press"))
        self.engine._sink_provider = lambda: "buds_sink"
        result = types.SimpleNamespace(returncode=0, stdout="laptop_sink\n", stderr="")
        with mock.patch.object(local_actions, "_run", lambda cmd, timeout=6: result):
            self.engine._on_media_press("PlayPause")
        self.assertEqual(calls, [], "a press of another player fired the shortcut")

    def test_media_press_is_registered_when_the_buds_are_the_default_sink(self):
        calls = []
        self.engine.run_command = lambda cmd, **kw: calls.append(cmd) or True
        self.engine.upsert(self.rule(trigger="knob_press"))
        self.engine._sink_provider = lambda: "buds_sink"
        result = types.SimpleNamespace(returncode=0, stdout="buds_sink\n", stderr="")
        with mock.patch.object(local_actions, "_run", lambda cmd, timeout=6: result):
            self.engine._on_media_press("PlayPause")
        self.assertEqual(calls, ["echo hi"], "the case press did not fire the shortcut")

    # -- A17: saving must not drop the rest of the file ---------------------
    def test_save_keeps_the_other_keys_of_the_rules_file(self):
        path = os.path.join(self.dir, "local_actions.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"version": 2, "notes": "keep me", "rules": []}, fh)
        self.engine.load()
        self.engine.upsert(self.rule())
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        self.assertEqual(data.get("version"), 2)
        self.assertEqual(data.get("notes"), "keep me")
        self.assertEqual(len(data.get("rules")), 1)

    # -- A18: the volume bookkeeping is shared between two threads ----------
    def test_note_self_change_updates_the_volume_under_the_lock(self):
        lock = TrackingRLock()
        self.engine._lock = lock
        before = lock.entered
        self.engine.note_self_change(42)
        self.assertGreater(lock.entered, before)

    def test_the_volume_change_reads_the_reference_under_the_lock(self):
        lock = TrackingRLock()
        self.engine._lock = lock
        self.engine._last_volume = 50
        self.engine._read_volume = lambda sink: 50
        before = lock.entered
        self.engine._on_volume_change("sink")
        self.assertGreater(lock.entered, before)

    def test_note_self_change_does_not_wait_for_a_slow_volume_read(self):
        started = threading.Event()
        release = threading.Event()
        self.engine._last_volume = 40

        def slow_read(sink):
            started.set()
            release.wait(3)
            return 50

        self.engine._read_volume = slow_read
        reader = threading.Thread(
            target=self.engine._on_volume_change, args=("sink",)
        )
        reader.start()
        self.assertTrue(started.wait(2), "the volume read did not start")
        done = threading.Event()

        def note():
            self.engine.note_self_change(50)
            done.set()

        notifier = threading.Thread(target=note)
        notifier.start()
        self.assertTrue(
            done.wait(1.0),
            "note_self_change waited for the slow volume read (the lock is too wide)",
        )
        release.set()
        reader.join(3)
        notifier.join(3)
        self.assertEqual(
            self.engine.last_event.get("trigger"),
            None,
            "our own volume change was reported as a gesture",
        )

    # -- A19: a shortcut must report the real result ------------------------
    def test_run_command_wait_reports_the_real_result(self):
        self.assertTrue(self.engine.run_command("true", wait=True))
        self.assertFalse(self.engine.run_command("false", wait=True))

    def test_the_last_action_reports_the_real_result_of_the_command(self):
        rule = self.rule(command="false")
        self.engine._run_rule(rule, "volume_up", 1, [], None)
        deadline = time.time() + 3
        while time.time() < deadline:
            if "ok" in self.engine.last_action:
                break
            time.sleep(0.02)
        self.assertIn("ok", self.engine.last_action, "the result never arrived")
        self.assertFalse(self.engine.last_action["ok"])

    # -- A20: the toast must not leave a zombie -----------------------------
    def test_the_notification_does_not_leave_a_zombie_process(self):
        calls = []

        def fake_run(cmd, **kwargs):
            calls.append(cmd)
            return types.SimpleNamespace(returncode=0, stdout="", stderr="")

        info = {"modifiers": [], "trigger": "volume_up", "presses": 1}
        with mock.patch.object(local_actions.subprocess, "run", fake_run):
            self.engine._notify(info, "echo hi")
        self.assertTrue(
            any("notify-send" in cmd for cmd in calls),
            "the toast was not sent with subprocess.run",
        )

    # -- B2: the watcher must not resolve the sink on every event -----------
    def test_the_watcher_does_not_resolve_the_sink_for_every_unrelated_event(self):
        watcher = local_actions.VolumeWatcher(
            lambda: "sink", lambda sink: None, log=lambda msg: None
        )
        calls = []

        def fake_sink_id(sink):
            calls.append(sink)
            return "1"

        watcher._sink_id = fake_sink_id
        sink_id = watcher._handle_line("Event 'change' on sink #1", "sink", None)
        self.assertEqual(sink_id, "1")
        resolved = len(calls)
        for _ in range(5):
            watcher._handle_line("Event 'change' on sink #2", "sink", sink_id)
        self.assertLessEqual(
            len(calls) - resolved,
            1,
            "the sink was resolved again for every unrelated event",
        )



class FakeTracker:
    """Records the lifecycle calls of the modifier tracker."""

    def __init__(self):
        self.started = False
        self.start_calls = 0
        self.stop_calls = 0
        self.available = False

    @property
    def running(self):
        return self.started

    def start(self):
        self.started = True
        self.start_calls += 1

    def stop(self):
        self.started = False
        self.stop_calls += 1

    def modifiers(self):
        return []


class FakeMedia:
    def start(self):
        pass

    def stop(self):
        pass


class FakeWatcher:
    def __init__(self, *args, **kwargs):
        pass

    def start(self):
        pass

    def stop(self):
        pass


class ModifierTrackerLifecycleTests(unittest.TestCase):
    """The keyboard reader must only run while a rule needs the modifiers.

    Reading /dev/input is a sensitive capability: it has to stop as soon as
    no enabled rule uses require/forbid, instead of running for the whole
    life of the daemon.
    """

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = self._tmp.name
        self.engine = local_actions.LocalActionEngine(self.dir, log=lambda msg: None)
        self.tracker = FakeTracker()
        self.engine.modifiers = self.tracker
        self.engine.media = FakeMedia()
        self._watcher = mock.patch.object(local_actions, "VolumeWatcher", FakeWatcher)
        self._watcher.start()

    def tearDown(self):
        self._watcher.stop()
        self._tmp.cleanup()

    def rule(self, **overrides):
        rule = {
            "id": "r1",
            "enabled": True,
            "trigger": "volume_up",
            "presses": 0,
            "require": ["super"],
            "forbid": [],
            "command": "echo hi",
        }
        rule.update(overrides)
        return rule

    def test_the_tracker_is_not_started_without_rules(self):
        self.engine.start(lambda: "")
        self.assertFalse(
            self.tracker.started,
            "the keyboard reader runs without any rule that needs it",
        )

    def test_the_tracker_starts_when_a_rule_needs_modifiers(self):
        self.engine.start(lambda: "")
        self.engine.upsert(self.rule())
        self.assertTrue(
            self.tracker.started,
            "a rule with require does not start the keyboard reader",
        )

    def test_the_tracker_stops_when_no_rule_needs_modifiers(self):
        self.engine.start(lambda: "")
        self.engine.upsert(self.rule())
        self.engine.delete("r1")
        self.assertFalse(
            self.tracker.started,
            "the keyboard reader keeps running after the last rule is gone",
        )

    def test_a_rule_without_modifiers_does_not_start_the_tracker(self):
        self.engine.start(lambda: "")
        self.engine.upsert(self.rule(require=[], forbid=[]))
        self.assertFalse(
            self.tracker.started,
            "a rule without modifiers starts the keyboard reader",
        )

    def test_a_disabled_rule_does_not_start_the_tracker(self):
        self.engine.start(lambda: "")
        self.engine.upsert(self.rule(enabled=False))
        self.assertFalse(
            self.tracker.started,
            "a disabled rule keeps the keyboard reader running",
        )

    def test_a_forbid_list_also_needs_the_tracker(self):
        self.engine.start(lambda: "")
        self.engine.upsert(self.rule(require=[], forbid=["alt"]))
        self.assertTrue(
            self.tracker.started,
            "a rule with forbid does not start the keyboard reader",
        )

    def test_the_real_tracker_can_be_stopped_and_started_again(self):
        tracker = local_actions.ModifierTracker(log=lambda msg: None)
        with mock.patch.object(
            local_actions, "_list_event_devices", return_value=[]
        ):
            tracker.start()
            self.assertTrue(tracker.running, "the tracker did not start")
            tracker.stop()
            self.assertFalse(tracker.running, "the tracker did not stop")
            try:
                tracker.start()
            except RuntimeError as exc:
                self.fail("the tracker cannot be restarted: %s" % exc)
            self.assertTrue(tracker.running, "the tracker did not restart")
            tracker.stop()
            self.assertFalse(tracker.running, "the tracker did not stop again")

if __name__ == "__main__":
    unittest.main(verbosity=2)
