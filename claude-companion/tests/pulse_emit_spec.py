#!/usr/bin/env python3
"""Tests for the generic emitter (hooks/pulse-emit), run in dry-run mode.

Other agents' hooks call it with whatever they have: a session id from an env macro,
hook JSON on stdin, a pid for liveness. Every one of those reaches pulse-svc as a
single space-free CSV token, so the properties that matter are the exact payload and
that nothing a caller passes can add a field or a word to it.

Run: python3 tests/pulse_emit_spec.py
"""
import os
import subprocess
import unittest

_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EMIT = os.path.join(_ROOT, "hooks", "pulse-emit")
PREFIX = "noctalia msg plugin lowcache/claude-companion:pulse-svc all "


def emit(*args, stdin="", **env):
    full = {k: v for k, v in os.environ.items() if k != "PULSE_PID"}
    full.update(PULSE_DRYRUN="1", **env)
    out = subprocess.run(["sh", EMIT, *args], input=stdin, capture_output=True, text=True, env=full)
    return out.returncode, out.stdout.strip().removeprefix(PREFIX)


class Emit(unittest.TestCase):
    def test_bare_event_without_a_session(self):
        self.assertEqual(emit("needs_attention"), (0, "needs_attention"))

    def test_full_payload(self):
        self.assertEqual(emit("turn_end", "s1", "gpt-5", "12", "8"), (0, "turn_end gpt-5,12,8,0,0,s1"))

    def test_underscores_survive(self):  # opencode ids look like ses_f46b...
        self.assertEqual(emit("idle", "ses_ab12_CD")[1], "idle ?,0,0,0,0,ses_ab12_CD")

    def test_separators_are_stripped(self):
        self.assertEqual(emit("idle", "a b,c;d")[1], "idle ?,0,0,0,0,abcd")

    def test_session_from_stdin_takes_the_first_session_id(self):
        hook = '{"session_id": "019a-7", "tool_input": {"session_id": "nested", "x": "\\"session_id\\":\\"s\\""}}'
        self.assertEqual(emit("tool_start", "-", stdin=hook)[1], "tool_start ?,0,0,0,0,019a-7")

    def test_session_from_multiline_stdin(self):
        hook = '{\n  "cwd": "/x",\n  "session_id":\n    "multi"\n}\n'
        self.assertEqual(emit("idle", "-", stdin=hook)[1], "idle ?,0,0,0,0,multi")

    def test_stdin_without_a_session_id_is_a_bare_event(self):
        self.assertEqual(emit("idle", "-", stdin="{}")[1], "idle")

    def test_pid_becomes_field_seven(self):
        self.assertEqual(emit("turn_end", "aider-42", PULSE_PID="42")[1], "turn_end ?,0,0,0,0,aider-42,42")

    def test_non_numeric_pid_is_dropped(self):
        self.assertEqual(emit("turn_end", "s1", PULSE_PID="12;rm")[1], "turn_end ?,0,0,0,0,s1")

    def test_pid_needs_a_session(self):
        self.assertEqual(emit("idle", PULSE_PID="42")[1], "idle")


if __name__ == "__main__":
    unittest.main(verbosity=2)
