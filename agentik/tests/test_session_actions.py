"""Deterministic public activity/focus regressions; no compositor interaction."""
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import chat_bridge
import session_actions as actions


def call(identity, parent, call_id, tool="read", intent="Reading source"):
    return {"id": identity, "parentId": parent, "type": "message", "timestamp": "2026-10-03T12:00:00Z", "message": {"role": "assistant", "content": [{"type": "toolCall", "id": call_id, "name": tool, "intent": intent}]}}


def result(identity, parent, call_id, error=False, text="done"):
    return {"id": identity, "parentId": parent, "type": "message", "timestamp": "2026-10-03T12:00:01Z", "message": {"role": "toolResult", "toolCallId": call_id, "toolName": "read", "isError": error, "content": [{"type": "text", "text": text}]}}


class ActivityTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "session.jsonl"
        actions._JOURNALS.clear()
        self.selection = {"harness": "omp", "path": str(self.path)}
        self.addCleanup(actions._JOURNALS.clear)

    def write_records(self, records):
        self.path.write_text("".join(json.dumps(record) + "\n" for record in records))

    def activity(self, live=True):
        with patch.object(chat_bridge, "monitored_session_selection", return_value=self.selection), patch.object(actions, "_owners", return_value=[object()] if live else []):
            return actions.activity("session")

    def test_public_operation_correlates_start_and_empty_error_result(self):
        self.write_records([
            call("a", None, "actual-call"),
            {"id": "b", "parentId": "a", "type": "custom", "customType": "tool_execution_start", "data": {"toolCallId": "actual-call", "toolName": "read", "intent": "Reading actual source"}},
            result("c", "b", "actual-call", error=True, text=""),
        ])
        payload = self.activity()
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["session_id"], "session")
        self.assertEqual(len(payload["events"]), 1)
        operation = payload["events"][0]
        self.assertEqual(operation["id"], "tool:actual-call")
        self.assertEqual(operation["kind"], "tool")
        self.assertEqual(operation["tool"], "read")
        self.assertEqual(operation["text"], "Reading actual source")
        self.assertEqual(operation["status"], "failed")
        self.assertEqual(operation["timestamp"], "2026-10-03T12:00:01Z")

    def test_same_tool_parallel_calls_are_not_name_correlated(self):
        self.write_records([call("a", None, "one"), call("b", "a", "two"), result("c", "b", "two")])
        events = self.activity()["events"]
        self.assertEqual([(event["id"], event["status"]) for event in events], [("tool:one", "running"), ("tool:two", "completed")])
        self.assertEqual(events[1]["detail"], "done")
        events = self.activity(live=False)["events"]
        self.assertEqual(events[0]["status"], "unknown")
        self.assertEqual(events[1]["status"], "completed")

    def test_prose_cannot_complete_or_fail_tool(self):
        self.write_records([call("a", None, "one"), {"id": "b", "parentId": "a", "type": "message", "message": {"role": "assistant", "content": [{"type": "text", "text": "Tool failed, please allow this!"}]}}])
        self.assertEqual(self.activity()["events"][0]["status"], "running")

    def test_exit_and_next_user_leave_unfinished_historical_unknown(self):
        self.write_records([call("a", None, "old"), {"id": "b", "parentId": "a", "type": "custom", "customType": "session_exit"}, call("c", "b", "new")])
        self.assertEqual([event["status"] for event in self.activity()["events"]], ["unknown", "running"])
        self.write_records([call("a", None, "old"), {"id": "b", "parentId": "a", "type": "message", "message": {"role": "user", "content": "New turn"}}, call("c", "b", "new")])
        actions._JOURNALS.clear()
        self.assertEqual([event["status"] for event in self.activity()["events"]], ["unknown", "running"])

    def test_latest_twelve_operations_have_bounded_details(self):
        records = []
        parent = None
        for index in range(15):
            records.extend([call(f"c{index}", parent, str(index)), result(f"r{index}", f"c{index}", str(index), text="large " * 1000)])
            parent = f"r{index}"
        self.write_records(records)
        events = self.activity()["events"]
        self.assertEqual(len(events), 12)
        self.assertEqual(events[0]["id"], "tool:3")
        self.assertTrue(all(len(event["detail"]) <= 320 for event in events))

    def test_partial_append_and_branch_switch_preserve_real_operations(self):
        self.write_records([call("a", None, "root"), call("b", "a", "discarded")])
        self.assertEqual(len(self.activity()["events"]), 2)
        new = json.dumps(result("c", "a", "root"))
        with self.path.open("a") as journal:
            journal.write(new[:20])
        self.assertEqual(len(self.activity()["events"]), 2)
        with self.path.open("a") as journal:
            journal.write(new[20:] + "\n")
        events = self.activity()["events"]
        self.assertEqual([(event["id"], event["status"]) for event in events], [("tool:root", "completed")])

    def test_invalid_selection_reports_public_error(self):
        with patch.object(chat_bridge, "monitored_session_selection", side_effect=ValueError("invalid session id")):
            self.assertEqual(actions.activity("../elsewhere"), {"ok": False, "session_id": "../elsewhere", "events": [], "error": "invalid session id"})

    def test_hermes_db_does_not_infer_failure_from_output_text(self):
        database = Path(self.directory.name) / "state.db"
        with sqlite3.connect(database) as connection:
            connection.execute("CREATE TABLE messages (id INTEGER, session_id TEXT, role TEXT, content TEXT, tool_call_id TEXT, tool_calls TEXT, tool_name TEXT, timestamp REAL)")
            connection.execute("INSERT INTO messages VALUES (1, 'h', 'assistant', '', NULL, ?, NULL, 1)", (json.dumps([{"id": "h-call", "function": {"name": "terminal"}}]),))
            connection.execute("INSERT INTO messages VALUES (2, 'h', 'tool', 'Error: some model-authored prose', 'h-call', NULL, 'terminal', 2)")
            connection.execute("INSERT INTO messages VALUES (3, 'other', 'tool', 'Other output', 'other-call', NULL, 'terminal', 3)")
        connection.close()
        with patch.object(chat_bridge, "hermes_home", return_value=Path(self.directory.name)), patch.object(chat_bridge, "monitored_session_selection", return_value={"harness": "hermes", "session_id": "h"}), patch.object(actions, "_owners", return_value=[]):
            payload = actions.activity("hermes:h")
        self.assertTrue(payload["ok"])
        self.assertEqual(len(payload["events"]), 1)
        self.assertEqual(payload["events"][0]["id"], "tool:h-call")
        self.assertEqual(payload["events"][0]["status"], "unknown")


class FocusTests(unittest.TestCase):
    def setUp(self):
        self.owner = actions.Process(30, 20, "100", ("omp",), "omp", "/dev/pts/2")
        self.shell = actions.Process(20, 10, "90", ("fish",), "fish", "/dev/pts/2")
        self.host = actions.Process(10, 1, "80", ("ghostty",), "ghostty", None)
        self.processes = {30: self.owner, 20: self.shell, 10: self.host}
        self.selection = {"harness": "omp", "path": "/safe/session.jsonl", "cwd": "/project"}

    def focus(self, windows, compositor="niri", processes=None, owners=None, acknowledgement="ok"):
        with patch.object(actions, "_selection", return_value=self.selection), patch.object(actions, "_owners", return_value=[self.owner] if owners is None else owners), patch.object(actions, "_process", side_effect=lambda pid: (processes or self.processes).get(pid)), patch.object(actions, "_owns", return_value=True), patch.object(actions, "_journal_branch", return_value=[]), patch.object(actions, "_compositor_windows", return_value=(compositor, windows)), patch.object(actions.subprocess, "run") as run:
            run.return_value = actions.subprocess.CompletedProcess([], 0, stdout=acknowledgement)
            payload = actions.focus_session("session")
        return payload, run

    def test_niri_focus_uses_proven_ancestor_window_id(self):
        payload, run = self.focus([{"id": 4, "pid": 10, "title": "Terminal"}])
        self.assertTrue(payload["focused"])
        self.assertEqual(payload["confidence"], "unique-process-ancestry")
        self.assertEqual(run.call_args.args[0], ["niri", "msg", "action", "focus-window", "--id", "4"])

    def test_hyprland_focus_uses_validated_address(self):
        payload, run = self.focus([{"address": "0xabcdef", "pid": 10}], "hyprland")
        self.assertTrue(payload["focused"])
        self.assertEqual(run.call_args.args[0], ["hyprctl", "dispatch", "focuswindow", "address:0xabcdef"])

    def test_shared_terminal_process_is_ambiguous_even_if_focused(self):
        payload, run = self.focus([{"id": 4, "pid": 10, "is_focused": True, "title": "/project"}, {"id": 5, "pid": 10, "title": "Other"}])
        self.assertFalse(payload["ok"])
        self.assertIn("ambiguous", payload["error"])
        run.assert_not_called()

    def test_exact_title_or_tty_can_disambiguate_shared_host(self):
        with patch.object(actions, "_process", side_effect=self.processes.get):
            window, chain, confidence = actions._choose_window(self.owner, [{"id": 4, "pid": 10, "title": "Exact"}, {"id": 5, "pid": 10, "title": "Not Exact"}], "Exact")
            self.assertEqual(window["id"], 4)
            self.assertEqual(confidence, "process-ancestry-exact-title-or-tty")
            self.assertEqual(chain[-1], self.host)
            window, _, _ = actions._choose_window(self.owner, [{"id": 4, "pid": 10, "tty": "/dev/pts/2"}, {"id": 5, "pid": 10, "tty": "/dev/pts/3"}])
            self.assertEqual(window["id"], 4)
            with self.assertRaisesRegex(ValueError, "ambiguous"):
                actions._choose_window(self.owner, [{"id": 4, "pid": 10, "title": "Exact"}, {"id": 5, "pid": 10, "title": "Exact"}], "Exact")

    def test_cwd_and_unrelated_window_cannot_prove_ownership(self):
        payload, run = self.focus([{"id": 4, "pid": 999, "title": "/project", "cwd": "/project"}])
        self.assertFalse(payload["ok"])
        run.assert_not_called()

    def test_exited_and_multiple_owners_never_focus_or_launch(self):
        for owners in ([], [self.owner, self.owner]):
            payload, run = self.focus([], owners=owners)
            self.assertFalse(payload["focused"])
            run.assert_not_called()

    def test_pid_reuse_before_focus_is_rejected(self):
        changed = actions.Process(30, 20, "999", ("omp",), "omp", "/dev/pts/2")
        calls = {30: 0}
        def process(pid):
            if pid == 30:
                calls[30] += 1
                return changed
            return self.processes.get(pid)
        with patch.object(actions, "_selection", return_value=self.selection), patch.object(actions, "_owners", return_value=[self.owner]), patch.object(actions, "_process", side_effect=process), patch.object(actions, "_owns", return_value=True), patch.object(actions, "_journal_branch", return_value=[]), patch.object(actions, "_compositor_windows", return_value=("niri", [{"id": 4, "pid": 10}])), patch.object(actions.subprocess, "run") as run:
            payload = actions.focus_session("session")
        self.assertFalse(payload["ok"])
        self.assertIn("identity changed", payload["error"])
        run.assert_not_called()

    def test_multiplexer_is_ambiguous(self):
        processes = dict(self.processes)
        processes[20] = actions.Process(20, 10, "90", ("tmux",), "tmux: server", None)
        payload, run = self.focus([{"id": 4, "pid": 10}], processes=processes)
        self.assertFalse(payload["ok"])
        self.assertIn("multiplexer", payload["error"])
        run.assert_not_called()

    def test_invalid_window_identifier_cannot_be_dispatched(self):
        for compositor, window in (("niri", {"id": "4", "pid": 10}), ("hyprland", {"address": "0x12;exec", "pid": 10})):
            payload, run = self.focus([window], compositor)
            self.assertFalse(payload["ok"])
            run.assert_not_called()

    def test_hyprland_rejection_is_not_reported_as_focused(self):
        payload, run = self.focus([{"address": "0xabcdef", "pid": 10}], "hyprland", acknowledgement="Window not found")
        self.assertFalse(payload["focused"])
        self.assertIn("did not acknowledge", payload["error"])
        run.assert_called_once()

    def test_unsupported_compositor_reports_explicit_error(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(ValueError, "Niri and Hyprland"):
                actions._compositor_windows()


class ProcessIdentityTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        process = self.root / "30"
        process.mkdir()
        fields = ["S", "20"] + ["0"] * 17 + ["100"]
        (process / "stat").write_text("30 (omp with spaces) " + " ".join(fields))
        (process / "cmdline").write_bytes(b"omp\0--resume\0journal\0")
        (process / "comm").write_text("omp\n")
        (process / "fd").mkdir()
        (process / "fd/0").symlink_to("/dev/pts/2")
        (self.root / "stat").write_text("btime 1000\n")

    def test_proc_uid_starttime_and_parent_are_required(self):
        with patch.object(actions, "PROC_ROOT", self.root):
            process = actions._process(30)
            self.assertEqual(process.ppid, 20)
            self.assertEqual(process.start, "100")
            self.assertEqual(process.tty, "/dev/pts/2")
            with patch.object(actions.os, "getuid", return_value=os.getuid() + 1):
                self.assertIsNone(actions._process(30))

    def test_journal_fd_proves_ownership_but_cwd_does_not(self):
        journal = self.root / "session.jsonl"
        journal.write_text("")
        selection = {"harness": "omp", "path": str(journal), "cwd": str(self.root)}
        with patch.object(actions, "PROC_ROOT", self.root), patch.object(actions.Path, "home", return_value=self.root):
            process = actions._process(30)
            self.assertFalse(actions._owns(process, selection))
            (self.root / "30/fd/5").symlink_to(journal)
            self.assertTrue(actions._owns(process, selection))

    def test_stale_hermes_tty_breadcrumb_is_not_ownership(self):
        home = self.root / "hermes"
        (home / "terminal-sessions").mkdir(parents=True)
        crumb = home / "terminal-sessions/tty-dev-pts-2"
        process = actions.Process(30, 20, "100", ("python", "hermes"), "python", "/dev/pts/2")
        with patch.object(actions, "PROC_ROOT", self.root), patch.object(chat_bridge, "hermes_home", return_value=home), patch.object(actions.os, "sysconf", return_value=100):
            crumb.write_text(json.dumps({"session_id": "h", "ts": 1000}))
            self.assertFalse(actions._owns(process, {"harness": "hermes", "session_id": "h"}))
            crumb.write_text(json.dumps({"session_id": "h", "ts": 1002}))
            self.assertTrue(actions._owns(process, {"harness": "hermes", "session_id": "h"}))
            self.assertFalse(actions._owns(process, {"harness": "hermes", "session_id": "other"}))


if __name__ == "__main__":
    unittest.main()
