"""Release regressions through public selections and the detached ACP worker."""
from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import chat_bridge as bridge
import session_actions as actions
from test_acp_client import FIXTURE


class ReleaseRegressionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.chat = self.root / "chat"
        self.hermes = self.root / "hermes #home"
        self.hermes.mkdir()
        self.fixture = self.root / "fixture-agent"
        self.fixture.write_text(
            f"#!{sys.executable}\nimport sys\n"
            f"sys.argv = [sys.argv[0], 'normal', {str(self.root / 'protocol.jsonl')!r}]\n" + FIXTURE
        )
        self.fixture.chmod(0o700)
        self.environment = patch.dict(os.environ, {
            "AGENTIK_STATE_DIR": str(self.chat),
            "AGENTIK_SESSIONS_DIR": str(self.root / "journals"),
            "HERMES_HOME": str(self.hermes),
            "OMP_BIN": str(self.fixture),
            "AGENTIK_CATALOG_JSON": json.dumps([
                {"id": "omp", "name": "Oh My Pi", "available": True,
                 "models": ["default"], "default_model": "default"},
                {"id": "hermes", "name": "Hermes", "available": True,
                 "models": ["default"], "default_model": "default"},
            ]),
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.addCleanup(self.reap_worker)
        self.worker = None

    def reap_worker(self):
        if self.worker is None:
            return
        try:
            waited, _ = os.waitpid(self.worker, os.WNOHANG)
            if waited == 0:
                bridge.dispatch("cancel")
                os.waitpid(self.worker, 0)
        except ChildProcessError:
            pass

    def create_hermes_history(self):
        with closing(sqlite3.connect(self.hermes / "state.db")) as database:
            database.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, cwd TEXT, model TEXT, title TEXT, source TEXT)")
            database.executemany("INSERT INTO sessions VALUES (?, ?, ?, ?, ?)", [
                ("native-session", str(self.root), "provider/model", "Terminal session", "cli"),
                ("other-source", str(self.root), "provider/model", "Not a terminal session", "api"),
            ])
            database.execute("CREATE TABLE messages (id INTEGER, session_id TEXT, role TEXT, content TEXT, tool_call_id TEXT, tool_calls TEXT, tool_name TEXT, timestamp REAL)")
            database.executemany("INSERT INTO messages VALUES (?, ?, ?, ?, ?, ?, ?, ?)", [
                (1, "native-session", "assistant", "", None,
                 json.dumps([{"id": "read-file", "function": {"name": "read"}}]), None, 1),
                (2, "native-session", "tool", "Recorded tool output", "read-file", None, "read", 2),
                (3, "other-source", "tool", "Unrelated output", "different-call", None, "read", 3),
            ])
            database.commit()

    def test_monitored_hermes_selection_uses_configured_read_only_database(self):
        self.create_hermes_history()
        original = (self.hermes / "state.db").read_bytes()
        result = bridge.dispatch("select-id", "hermes:native-session".encode().hex())
        self.assertTrue(result["ok"])
        self.assertTrue(result["selected"])
        self.assertEqual(result["session_id"], "native-session")
        self.assertEqual(result["harness"], "hermes")
        self.assertEqual(result["cwd"], str(self.root))
        self.assertEqual(result["model"], "provider/model")
        self.assertEqual((self.hermes / "state.db").read_bytes(), original)

    def test_monitored_hermes_activity_correlates_only_selected_history(self):
        self.create_hermes_history()
        result = actions.activity("hermes:native-session")
        self.assertTrue(result["ok"])
        self.assertEqual([event["id"] for event in result["events"]], ["tool:read-file"])
        self.assertEqual(result["events"][0]["detail"], "Recorded tool output")
        self.assertEqual(result["events"][0]["status"], "unknown")

    def test_hermes_non_cli_or_missing_session_cannot_replace_selection(self):
        self.create_hermes_history()
        chosen = bridge.dispatch("select-id", "hermes:native-session".encode().hex())
        self.assertTrue(chosen["ok"])
        for identity in ("hermes:other-source", "hermes:missing"):
            with self.subTest(identity=identity):
                result = bridge.dispatch("select-id", identity.encode().hex())
                self.assertFalse(result["ok"])
                self.assertEqual(result["session_id"], "native-session")

    def test_missing_hermes_database_reports_failure_without_creating_it(self):
        result = bridge.dispatch("select-id", "hermes:missing".encode().hex())
        self.assertFalse(result["ok"])
        self.assertFalse(result["selected"])
        self.assertFalse((self.hermes / "state.db").exists())

    def new_session(self):
        result = bridge.dispatch("new", str(self.root).encode().hex(), "omp".encode().hex(), "default".encode().hex())
        self.assertTrue(result["ok"])

    def test_attachment_only_send_completes_through_detached_native_worker(self):
        self.new_session()
        context = self.root / "context.txt"
        context.write_text("Attachment-only context")
        started = bridge.dispatch("send", "", json.dumps([str(context)]).encode().hex())
        self.assertTrue(started["ok"])
        stored = bridge.read_state(self.chat / "state.json")
        self.worker = stored["stream"]["pid"]
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            stored = bridge.read_state(self.chat / "state.json")
            if stored.get("last_run") and not stored.get("stream"):
                break
            time.sleep(0.02)
        self.assertEqual(stored.get("last_run", {}).get("state"), "completed", stored)
        result = bridge.dispatch("status")
        self.assertFalse(result["busy"])
        self.assertTrue(any(message.get("role") == "assistant" and message.get("text") == "hello world"
                            for message in result["messages"]))
        self.assertEqual(bridge.read_state(self.chat / "state.json")["selection"]["session_id"], "fixture-session")

    def test_empty_send_without_attachments_cannot_start_a_worker(self):
        self.new_session()
        result = bridge.dispatch("send", "")
        self.assertFalse(result["ok"])
        self.assertFalse(result["busy"])
        self.assertIsNone(bridge.read_state(self.chat / "state.json").get("stream"))
