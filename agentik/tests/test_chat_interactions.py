import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import chat_bridge as bridge


class ChatInteractionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.env = patch.dict(os.environ, {
            "AGENTIK_STATE_DIR": str(self.root),
            "AGENTIK_CATALOG_JSON": json.dumps([{"id": "codex", "available": True,
                                                   "default_model": "default", "models": ["default"]}]),
        })
        self.env.start()
        self.addCleanup(self.env.stop)
        self.addCleanup(self.directory.cleanup)
        self.state = bridge.empty_state()
        self.state["selection"] = {"kind": "managed", "harness": "codex", "session_id": "native-session",
                                   "cwd": str(self.root), "messages": []}
        self.stream = bridge.begin_stream(self.state, self.state["selection"], "Review change")
        self.stream.update(state="waiting_for_input", pid=os.getpid(),
                           process_start_time=bridge.process_start_time(os.getpid()))
        self.request = {"request_id": "request-token", "run_id": self.stream["run_id"],
                        "kind": "permission", "sessionId": "native-session", "title": "Run command",
                        "options": [{"optionId": "once", "id": "once", "name": "Allow once", "kind": "allow_once"}]}
        self.stream["pending_requests"] = [self.request]
        bridge.write_state(self.root / "state.json", self.state)

    def respond(self, **changes):
        value = {"run_id": self.stream["run_id"], "request_id": "request-token",
                 "action": "permission", "option_id": "once", **changes}
        return bridge.dispatch("respond", json.dumps(value).encode().hex())

    def test_response_bound_to_current_run_request_and_exact_option(self):
        for changes in ({"run_id": "previous-run"}, {"request_id": "previous-request"},
                        {"option_id": "always"}, {"action": "accept"}):
            with self.subTest(changes=changes):
                self.assertFalse(self.respond(**changes)["ok"])
                self.assertFalse((self.root / "responses").exists())
        result = self.respond()
        self.assertTrue(result["ok"])
        self.assertTrue(result["pending_requests"][0]["submitted"])
        response_path = self.root / "responses" / f"{self.stream['run_id']}_request-token.json"
        self.assertEqual(json.loads(response_path.read_text()),
                         {"outcome": {"outcome": "selected", "optionId": "once"}})
        self.assertEqual(result["request_history"], [])
        response_path.unlink()  # The runtime consumes the handoff before its transport acknowledgement.
        self.assertFalse(self.respond()["ok"])

    def test_event_persistence_does_not_reenable_submitted_request(self):
        self.assertTrue(self.respond()["ok"])
        bridge.append_live_event(self.stream, "tool_call", "Running", tool="shell")
        bridge.persist_stream(self.root / "state.json", self.state, self.stream)
        self.assertTrue(self.stream["pending_requests"][0]["submitted"])

    def test_invalid_question_can_be_corrected_before_transport_submission(self):
        self.request.update(kind="question", schema={"type": "object", "properties": {
            "target": {"type": "string", "enum": ["local", "remote"]}}, "required": ["target"]})
        bridge.write_state(self.root / "state.json", self.state)
        self.assertFalse(self.respond(action="accept", content={"target": "unknown"})["ok"])
        self.assertFalse(self.respond(action="accept", content={})["ok"])
        self.assertTrue(self.respond(action="accept", content={"target": "local"})["ok"])

    def test_failure_preserves_partial_transcript_and_tool_status_without_pending_controls(self):
        self.stream["messages"].append({"role": "assistant", "text": "Partial answer"})
        bridge.append_live_event(self.stream, "tool_result", "Denied", tool="shell", error=True)
        bridge.write_state(self.root / "state.json", self.state)
        result = bridge.finish_stream(self.root / "state.json", self.state, self.stream["run_id"], error="Disconnected")
        self.assertEqual(result["messages"][-1]["text"], "Partial answer")
        self.assertEqual(result["pending_requests"], [])
        self.assertEqual(result["run"]["state"], "failed")
        self.assertTrue(any(event.get("error") for event in result["feed"]["events"]))

    def test_attachments_reject_special_files_and_enforce_size_boundary(self):
        fifo = self.root / "fifo"
        os.mkfifo(fifo)
        with self.assertRaises(ValueError):
            bridge.attachment_metadata([str(fifo)])
        with self.assertRaises(ValueError):
            bridge.attachment_metadata(["relative.txt"])
        regular = self.root / "file.txt"
        with regular.open("wb") as handle:
            handle.truncate(bridge.MAX_ATTACHMENT_BYTES)
        self.assertEqual(bridge.attachment_metadata([str(regular)])[0]["size"], bridge.MAX_ATTACHMENT_BYTES)
        with regular.open("ab") as handle:
            handle.write(b"x")
        with self.assertRaises(ValueError):
            bridge.attachment_metadata([str(regular)])

    def test_uninstalled_harness_cannot_be_selected(self):
        with patch.dict(os.environ, {"AGENTIK_CATALOG_JSON": json.dumps([
                {"id": "claude", "available": False, "default_model": "default"}])}):
            with self.assertRaises(ValueError):
                bridge.decode_new_selection(str(self.root).encode().hex(), "claude".encode().hex(), None)


if __name__ == "__main__":
    unittest.main()
