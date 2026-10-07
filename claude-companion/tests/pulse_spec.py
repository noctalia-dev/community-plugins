#!/usr/bin/env python3
"""Unit tests for the pulse dispatcher's Claude-pid lookup (hooks/pulse.py).

The pid feeds pulse-svc's liveness sweep, which RETIRES a session when that process
is gone. A wrong pid therefore hides a live session, so the property that matters is
that only an exact ~/.claude/sessions/<pid>.json match on the walk up from the hook
yields a pid, and anything less yields none (the 6-field payload, no sweeping).

Run: python3 tests/pulse_spec.py
"""
import importlib.util
import json
import os
import tempfile
import unittest
from unittest import mock

_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location("pulse", os.path.join(_ROOT, "hooks", "pulse.py"))
pulse = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pulse)

SID = "d63ac083-c016-4db1-82e2-e0e5aae68b33"
OUTER = "0d2548f2-8770-44da-affe-be269bc467ee"


class Harness(unittest.TestCase):
    """A fake /proc + Claude config dir; the hook's parent is pid 50."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.proc = os.path.join(self.tmp.name, "proc")
        self.conf = os.path.join(self.tmp.name, "claude")
        os.makedirs(os.path.join(self.conf, "sessions"))
        for p in (mock.patch.object(pulse, "PROC", self.proc),
                  mock.patch.object(pulse.os, "getppid", return_value=50),
                  mock.patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": self.conf})):
            p.start()
            self.addCleanup(p.stop)
        self.addCleanup(self.tmp.cleanup)
        # the captured chain: pulse.py -> sh(50) -> claude(40) -> bash(30) -> outer claude(20)
        for pid, comm, ppid in ((50, "sh", 40), (40, ".claude-wrapped", 30),
                                (30, "bash", 20), (20, ".claude-wrapped", 1)):
            self.proc_entry(pid, comm, ppid)

    def proc_entry(self, pid, comm, ppid):
        os.makedirs(os.path.join(self.proc, str(pid)), exist_ok=True)
        with open(os.path.join(self.proc, str(pid), "stat"), "w") as f:
            f.write(f"{pid} ({comm}) S {ppid} 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 12345 0 0\n")

    def session_file(self, pid, sid):
        with open(os.path.join(self.conf, "sessions", f"{pid}.json"), "w") as f:
            f.write(json.dumps({"pid": pid, "sessionId": sid}) if sid is not None else "{not json")


class Walk(Harness):
    def test_nearest_matching_claude_wins(self):
        self.session_file(40, SID)
        self.session_file(20, OUTER)
        self.assertEqual(pulse._claude_pid(SID), 40)

    def test_outer_claude_is_found_for_its_own_session(self):
        self.session_file(40, SID)
        self.session_file(20, OUTER)
        self.assertEqual(pulse._claude_pid(OUTER), 20)

    def test_no_match_means_no_pid(self):
        self.session_file(20, OUTER)  # a Claude on the chain, but not this session's
        self.assertIsNone(pulse._claude_pid(SID))

    def test_no_session_files_means_no_pid(self):
        self.assertIsNone(pulse._claude_pid(SID))

    def test_corrupt_session_file_is_skipped(self):
        self.session_file(40, None)
        self.session_file(20, SID)
        self.assertEqual(pulse._claude_pid(SID), 20)

    def test_comm_with_spaces_and_parens_parses(self):
        self.proc_entry(50, "tmux: (x) y", 40)
        self.session_file(40, SID)
        self.assertEqual(pulse._claude_pid(SID), 40)

    def test_unreadable_ancestor_stops_the_walk(self):
        os.remove(os.path.join(self.proc, "30", "stat"))
        self.session_file(20, SID)
        self.assertIsNone(pulse._claude_pid(SID))

    def test_walk_is_bounded(self):
        for pid in range(100, 120):  # a 20-deep chain with the match at the top
            self.proc_entry(pid, "sh", pid + 1)
        self.session_file(119, SID)
        with mock.patch.object(pulse.os, "getppid", return_value=100):
            self.assertIsNone(pulse._claude_pid(SID))


class Payload(Harness):
    def test_pid_is_the_seventh_field(self):
        self.session_file(40, SID)
        self.assertEqual(pulse._payload({"session_id": SID}, "turn_start"), "?,0,0,0,0,d63ac083,40")

    def test_no_pid_keeps_the_six_field_form(self):
        self.assertEqual(pulse._payload({"session_id": SID}, "turn_start"), "?,0,0,0,0,d63ac083")

    def test_session_end_skips_the_walk(self):
        self.session_file(40, SID)
        self.assertEqual(pulse._payload({"session_id": SID}, "session_end"), "?,0,0,0,0,d63ac083")


if __name__ == "__main__":
    unittest.main(verbosity=2)
