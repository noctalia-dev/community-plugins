#!/usr/bin/env python3
"""Unit tests for the consent gate (hooks/consent.py).

The gate sits in the critical path of every mutating tool call, so the property that
actually matters is not "does it approve things" but "does it ALWAYS get out of the
way when anything is wrong". Printing nothing on stdout is Claude Code's "no decision,
proceed normally", so most of this file asserts silence: shell offline, no runtime
dir, a forged nonce, a malformed payload, the mode file missing or corrupt.

Run: python3 tests/consent_spec.py
"""
import importlib.util
import io
import json
import os
import tempfile
import unittest
from unittest import mock

_HERE = os.path.dirname(os.path.abspath(__file__))
_HOOK = os.path.join(_HERE, "..", "hooks", "consent.py")
_spec = importlib.util.spec_from_file_location("consent", _HOOK)
consent = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(consent)


def hook_input(**over):
    data = {
        "hook_event_name": "PreToolUse",
        "tool_name": "Bash",
        "tool_input": {"command": "npm test", "description": "Run the test suite"},
        "tool_use_id": "toolu_01ABC",
        "cwd": "/home/u/proj",
        "session_id": "abcd1234-ef56",
        "permission_mode": "default",
    }
    data.update(over)
    return data


class Harness(unittest.TestCase):
    """Each test gets its own runtime + state roots, so nothing leaks between cases."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.rt = os.path.join(self.tmp.name, "run")
        self.st = os.path.join(self.tmp.name, "state")
        os.makedirs(self.rt, mode=0o700)
        os.makedirs(self.st, mode=0o700)
        self.env = mock.patch.dict(os.environ, {
            "XDG_RUNTIME_DIR": self.rt, "XDG_STATE_HOME": self.st,
        })
        self.env.start()
        self.addCleanup(self.env.stop)
        self.addCleanup(self.tmp.cleanup)

    def set_mode(self, mode):
        d = os.path.join(self.rt, "claude-companion")
        os.makedirs(d, mode=0o700, exist_ok=True)
        with open(os.path.join(d, "mode"), "w") as f:
            f.write(mode)

    def run_gate(self, data, dispatch_ok=True, responder=None, deadline=0.5):
        """Drive main() with stdin/stdout captured. `responder` writes the .res file.

        The real 110s deadline is not what these tests are pinning — the fall-through
        BEHAVIOUR is — so it is shortened here. A responder runs synchronously inside
        the dispatch, so an answered request is already on disk before polling starts
        and the shortened deadline never races it.
        """
        out = io.StringIO()

        def fake_run(argv, **kw):
            if responder is not None and "consent_request" in argv:
                responder(self)
            return mock.Mock(returncode=0 if dispatch_ok else 1, stdout=b"", stderr=b"")

        with mock.patch.object(consent, "DEADLINE", deadline), \
             mock.patch.object(consent.sys, "stdin", io.StringIO(json.dumps(data))), \
             mock.patch.object(consent.sys, "stdout", out), \
             mock.patch.object(consent.subprocess, "run", side_effect=fake_run):
            consent.main()
        return out.getvalue()

    def write_response(self, req_id="toolu_01ABC", decision="allow", nonce=None):
        cdir = os.path.join(self.rt, "claude-companion", "consent")
        with open(os.path.join(cdir, req_id + ".req")) as f:
            req = json.load(f)
        with open(os.path.join(cdir, req_id + ".res"), "w") as f:
            json.dump({"nonce": nonce if nonce is not None else req["nonce"],
                       "decision": decision}, f)

    def allowlist(self):
        path = os.path.join(self.st, "noctalia", "claude-companion", "allow.jsonl")
        if not os.path.exists(path):
            return []
        with open(path) as f:
            return [json.loads(line) for line in f if line.strip()]


class Mode(Harness):
    def test_missing_file_is_off(self):
        self.assertEqual(consent._mode(consent._runtime_dir()), "off")

    def test_unrecognised_value_is_off(self):
        self.set_mode("ENFORCE!!")
        self.assertEqual(consent._mode(consent._runtime_dir()), "off")

    def test_recognised_values(self):
        for mode in ("learn", "enforce"):
            self.set_mode(mode)
            self.assertEqual(consent._mode(consent._runtime_dir()), mode)

    def test_no_runtime_dir_is_off(self):
        self.assertEqual(consent._mode(None), "off")


class Silence(Harness):
    """Every route that must print nothing."""

    def test_mode_off(self):
        self.set_mode("off")
        self.assertEqual(self.run_gate(hook_input()), "")

    def test_no_mode_file_at_all(self):
        self.assertEqual(self.run_gate(hook_input()), "")

    def test_bypass_permissions(self):
        self.set_mode("enforce")
        got = self.run_gate(hook_input(permission_mode="bypassPermissions"))
        self.assertEqual(got, "")

    def test_dont_ask(self):
        self.set_mode("enforce")
        self.assertEqual(self.run_gate(hook_input(permission_mode="dontAsk")), "")

    def test_malformed_tool_input(self):
        self.set_mode("enforce")
        self.assertEqual(self.run_gate(hook_input(tool_input="not-a-dict")), "")

    def test_empty_stdin(self):
        out = io.StringIO()
        with mock.patch.object(consent.sys, "stdin", io.StringIO("")), \
             mock.patch.object(consent.sys, "stdout", out):
            consent.main()
        self.assertEqual(out.getvalue(), "")

    def test_dispatch_failure_falls_through(self):
        # Shell offline: nothing can answer, so the gate must not wait out its deadline.
        self.set_mode("enforce")
        self.assertEqual(self.run_gate(hook_input(), dispatch_ok=False), "")

    def test_no_runtime_dir_disables_gate(self):
        # Refusing to fall back to a world-writable /tmp is the point: there, any local
        # process could drop an "allow" of its own.
        self.set_mode("enforce")
        with mock.patch.dict(os.environ, {}, clear=False):
            del os.environ["XDG_RUNTIME_DIR"]
            self.assertEqual(self.run_gate(hook_input()), "")

    def test_forged_nonce_is_ignored(self):
        self.set_mode("enforce")
        got = self.run_gate(hook_input(),
                            responder=lambda s: s.write_response(nonce="wrong"))
        self.assertEqual(got, "")

    def test_unknown_decision_is_ignored(self):
        self.set_mode("enforce")
        got = self.run_gate(hook_input(),
                            responder=lambda s: s.write_response(decision="maybe"))
        self.assertEqual(got, "")


class Verdicts(Harness):
    def test_allow(self):
        self.set_mode("enforce")
        got = self.run_gate(hook_input(), responder=lambda s: s.write_response("toolu_01ABC", "allow"))
        parsed = json.loads(got)["hookSpecificOutput"]
        self.assertEqual(parsed["hookEventName"], "PreToolUse")
        self.assertEqual(parsed["permissionDecision"], "allow")

    def test_deny(self):
        self.set_mode("enforce")
        got = self.run_gate(hook_input(), responder=lambda s: s.write_response("toolu_01ABC", "deny"))
        self.assertEqual(json.loads(got)["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_request_carries_what_the_panel_renders(self):
        self.set_mode("enforce")
        seen = {}

        def capture(s):
            cdir = os.path.join(s.rt, "claude-companion", "consent")
            with open(os.path.join(cdir, "toolu_01ABC.req")) as f:
                seen.update(json.load(f))
            s.write_response()

        self.run_gate(hook_input(), responder=capture)
        self.assertEqual(seen["tool"], "Bash")
        self.assertEqual(seen["command"], "npm test")
        self.assertEqual(seen["description"], "Run the test suite")
        self.assertEqual(seen["cwd"], "/home/u/proj")
        self.assertEqual(seen["session"], "abcd1234")  # first UUID segment
        self.assertTrue(seen["nonce"])

    def test_request_is_cleaned_up(self):
        self.set_mode("enforce")
        self.run_gate(hook_input(), responder=lambda s: s.write_response())
        cdir = os.path.join(self.rt, "claude-companion", "consent")
        self.assertEqual(sorted(os.listdir(cdir)), [])


class Keys(Harness):
    def test_bash_keys_on_exact_command(self):
        self.assertEqual(consent._key("Bash", {"command": "rm -rf build"}),
                         "Bash:rm -rf build")

    def test_path_tools_key_on_path(self):
        self.assertEqual(consent._key("Write", {"file_path": "/a/b.txt"}), "Write:/a/b.txt")
        self.assertEqual(consent._key("Edit", {"file_path": "/a/b.txt"}), "Edit:/a/b.txt")
        self.assertEqual(consent._key("NotebookEdit", {"notebook_path": "/n.ipynb"}),
                         "NotebookEdit:/n.ipynb")

    def test_unknown_tool_falls_back_to_stable_json(self):
        a = consent._key("Weird", {"b": 1, "a": 2})
        b = consent._key("Weird", {"a": 2, "b": 1})
        self.assertEqual(a, b)  # key order must not change identity

    def test_similar_commands_are_distinct(self):
        # Exact match, never a pattern: `git status` must not authorise `git status && x`.
        self.assertNotEqual(consent._key("Bash", {"command": "git status"}),
                            consent._key("Bash", {"command": "git status && rm -rf ~"}))


class Allowlist(Harness):
    def test_allowlisted_command_is_silent(self):
        self.set_mode("enforce")
        consent._reply  # noqa: B018 — presence check, exercised below
        sd = os.path.join(self.st, "noctalia", "claude-companion")
        os.makedirs(sd, exist_ok=True)
        with open(os.path.join(sd, "allow.jsonl"), "w") as f:
            f.write(json.dumps({"key": "Bash:npm test"}) + "\n")
        # Dispatch would raise if it were reached, proving the gate short-circuits.
        self.assertEqual(self.run_gate(hook_input(), dispatch_ok=False), "")

    def test_corrupt_allowlist_line_is_skipped(self):
        sd = os.path.join(self.st, "noctalia", "claude-companion")
        os.makedirs(sd, exist_ok=True)
        with open(os.path.join(sd, "allow.jsonl"), "w") as f:
            f.write("{not json\n")
            f.write(json.dumps({"key": "Bash:ls"}) + "\n")
        self.assertTrue(consent._allowed("Bash:ls"))
        self.assertFalse(consent._allowed("Bash:nope"))

    def test_always_appends_once(self):
        # Answering "always" twice on the same request must not duplicate the entry —
        # a double-click is the obvious way for a user to produce this.
        cdir = os.path.join(self.rt, "claude-companion", "consent")
        os.makedirs(cdir, mode=0o700, exist_ok=True)
        with open(os.path.join(cdir, "r1.req"), "w") as f:
            json.dump({"id": "r1", "nonce": "n", "key": "Bash:npm test"}, f)
        consent._reply("r1", "always")
        consent._reply("r1", "always")
        keys = [row["key"] for row in self.allowlist()]
        self.assertEqual(keys, ["Bash:npm test"])

    def test_always_writes_an_allow_response(self):
        cdir = os.path.join(self.rt, "claude-companion", "consent")
        os.makedirs(cdir, mode=0o700, exist_ok=True)
        with open(os.path.join(cdir, "r2.req"), "w") as f:
            json.dump({"id": "r2", "nonce": "n2", "key": "Bash:ls"}, f)
        consent._reply("r2", "always")
        with open(os.path.join(cdir, "r2.res")) as f:
            res = json.load(f)
        self.assertEqual(res, {"nonce": "n2", "decision": "allow"})

    def test_reply_rejects_unsanitary_id(self):
        consent._reply("../../etc/passwd", "always")
        self.assertEqual(self.allowlist(), [])


class Learn(Harness):
    def test_learn_records_and_stays_silent(self):
        self.set_mode("learn")
        self.assertEqual(self.run_gate(hook_input(), dispatch_ok=False), "")
        with open(os.path.join(self.rt, "claude-companion", "learn.jsonl")) as f:
            rows = [json.loads(line) for line in f if line.strip()]
        self.assertEqual(rows[0]["key"], "Bash:npm test")
        self.assertEqual(rows[0]["description"], "Run the test suite")

    def test_multiline_commands_are_not_recorded(self):
        # An ad-hoc heredoc never recurs verbatim, so an exact-match key for it could
        # never match again — recording it would only bloat the allowlist.
        self.set_mode("learn")
        self.run_gate(hook_input(tool_input={"command": "echo a\necho b"}), dispatch_ok=False)
        self.assertFalse(os.path.exists(os.path.join(self.rt, "claude-companion", "learn.jsonl")))

    def test_multiline_still_gates_under_enforce(self):
        # Not recording is a learn-mode choice, not an exemption.
        self.set_mode("enforce")
        got = self.run_gate(hook_input(tool_input={"command": "echo a\necho b"}),
                            responder=lambda s: s.write_response("toolu_01ABC", "deny"))
        self.assertEqual(json.loads(got)["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_promote_folds_and_dedupes(self):
        self.set_mode("learn")
        for cmd in ("npm test", "ls", "npm test"):
            self.run_gate(hook_input(tool_input={"command": cmd}), dispatch_ok=False)
        consent._promote()
        keys = sorted(row["key"] for row in self.allowlist())
        self.assertEqual(keys, ["Bash:ls", "Bash:npm test"])

    def test_promote_is_idempotent(self):
        self.set_mode("learn")
        self.run_gate(hook_input(), dispatch_ok=False)
        consent._promote()
        consent._promote()
        self.assertEqual(len(self.allowlist()), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
