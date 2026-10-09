"""Deterministic ACP wire fixtures; no harness credentials or network required."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("agentik_acp_client", ROOT / "acp_client.py")
acp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acp)

FIXTURE = r'''
import json, os, subprocess, sys, time
from pathlib import Path
mode, logfile = sys.argv[1:]
log = Path(logfile)
def record(value):
    with log.open('a') as f:
        f.write(json.dumps(value) + '\n')
def send(value):
    record({'sent': value})
    sys.stdout.write(json.dumps(value) + '\n'); sys.stdout.flush()
def receive():
    line = sys.stdin.readline()
    if not line: sys.exit(0)
    value = json.loads(line); record({'received':value}); return value
def reply(request, result):
    send({'jsonrpc':'2.0', 'id':request['id'], 'result':result})
def update(session, value):
    send({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':session,'update':value}})
def ask(identity, method, params):
    send({'jsonrpc':'2.0','id':identity,'method':method,'params':params})
    while True:
        value=receive()
        if 'method' not in value and value.get('id')==identity: return value
schema={'type':'object','properties':{'strategy':{'type':'string','oneOf':[{'const':'safe','title':'Safe'},{'const':'quick','title':'Quick'}]},'choices':{'type':'array','items':{'anyOf':[{'const':'a','title':'A'},{'const':'b','title':'B'}]}},'count':{'type':'integer','minimum':1,'maximum':3}},'required':['strategy']}
session='fixture-session'
authenticated=False
while True:
    request=receive(); method=request.get('method')
    if method=='initialize':
        record({'pid':os.getpid(), 'initialize':request['params']})
        reply(request,{'protocolVersion':1,'authMethods':[{'id':'configured-provider'}], 'agentCapabilities':{'loadSession':mode!='no-load','sessionCapabilities':{'fork':{}} if mode!='no-fork' else {}, 'promptCapabilities':{'image':mode!='no-image','embeddedContext':mode!='links'}}})
    elif method=='authenticate':
        authenticated=True; reply(request,{})
    elif method in ('session/new','session/load','session/fork'):
        if mode=='auth' and not authenticated:
            send({'jsonrpc':'2.0','id':request['id'],'error':{'code':-32000,'message':'Authentication required'}}); continue
        if mode=='partial':
            sys.stdout.write('{"jsonrpc":"2.0"'); sys.stdout.flush(); sys.exit(0)
        if mode=='hang': time.sleep(60)
        if method=='session/load':
            session=request['params']['sessionId']; update(session,{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'old replay text'}})
        elif method=='session/fork': session='forked-session'
        if mode=='legacy':
            result={'models':{'availableModels':[{'modelId':'provider:nested/model','name':'Native Model'}]}}
        else:
            result={'configOptions':[{'id':'model','type':'select','category':'model','currentValue':'provider/model','options':[{'group':'provider','name':'Provider','options':[{'value':'provider/model','name':'Model','description':'x'*150000}]}]}]}
        if method!='session/load':result['sessionId']=session
        reply(request,result)
    elif method in ('session/set_config_option','session/set_model'):reply(request,{})
    elif method=='session/prompt':
        prompt_id=request['id']
        if mode in ('permission','invalid-option','question','callback-error'):
            opts=[{'optionId':'once','name':'Allow this time','kind':'allow_once'},{'optionId':'no','name':'Reject','kind':'reject_once'}]
            wrong={'sessionId':'wrong-session','toolCall':{'toolCallId':'call','title':'Write file'},'options':opts}
            ask('wrong-session-request','session/request_permission',wrong)
            params=dict(wrong,sessionId=session)
            ask(prompt_id,'session/request_permission',params)
        if mode=='question':
            ask('form:opaque','elicitation/create',{'sessionId':session,'toolCallId':'ask','mode':'form','message':'Pick strategy','requestedSchema':schema})
            ask('url','elicitation/create',{'sessionId':session,'mode':'url','message':'Login','url':'https://example.com'})
            ask('nested','elicitation/create',{'sessionId':session,'mode':'form','requestedSchema':{'type':'object','properties':{'secret':{'type':'object'}}}})
        if mode=='disconnect':
            send({'jsonrpc':'2.0','id':'pending','method':'session/request_permission','params':{'sessionId':session,'toolCall':{'toolCallId':'call','title':'Write'},'options':[{'optionId':'once','name':'Allow','kind':'allow_once'}]}})
            time.sleep(.05); sys.exit(0)
        if mode=='stderr':
            sys.stderr.write('diagnostic'*30000); sys.stderr.flush()
        if mode=='descendant':
            child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'])
            record({'descendant':child.pid})
        update('other-session',{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'wrong stream'}})
        update(session,{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'hello '}})
        update(session,{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'world'}})
        update(session,{'sessionUpdate':'agent_thought_chunk','content':{'type':'text','text':'thinking'}})
        update(session,{'sessionUpdate':'tool_call','toolCallId':'tool-1','title':'Read file','kind':'read','status':'pending'})
        update(session,{'sessionUpdate':'tool_call_update','toolCallId':'tool-1','status':'in_progress'})
        update(session,{'sessionUpdate':'tool_call_update','toolCallId':'tool-1','status':'completed','content':[{'type':'content','content':{'type':'text','text':'file contents'}}]})
        update(session,{'sessionUpdate':'tool_call','toolCallId':'tool-2','title':'Fail command','status':'failed','content':[{'type':'content','content':{'type':'text','text':'command failed'}}]})
        reply(request,{'stopReason':'end_turn'})
    elif method=='session/cancel':sys.exit(0)
'''


class AcpFixtureTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.cwd = Path(self.tmp.name)
        self.fixture = self.cwd / "fixture.py"
        self.fixture.write_text(FIXTURE)
        self.log = self.cwd / "protocol.jsonl"
        self.events = []
        self.ready = []
        self.processes = []
        original = subprocess.Popen

        def spawn(*args, **kwargs):
            process = original(*args, **kwargs)
            self.processes.append(process)
            return process

        patch = mock.patch.object(acp.subprocess, "Popen", side_effect=spawn)
        patch.start()
        self.addCleanup(patch.stop)

    def turn(self, fixture_mode="normal", interaction=None, attachments=None, cancel_check=None, **selection):
        return acp.run_turn(
            [sys.executable, str(self.fixture), fixture_mode, str(self.log)],
            {"cwd": str(self.cwd), "harness": "omp", "model": "default", **selection},
            "user message", attachments or [],
            lambda kind, text="", **data: self.events.append({"kind": kind, "text": text, **data}),
            interaction or (lambda *_: self.fail("Unexpected interaction")),
            lambda identity, caps: self.ready.append((identity, caps)),
            cancel_check=cancel_check,
        )

    def records(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def requests(self):
        return [item["received"] for item in self.records() if "received" in item and "method" in item["received"]]

    def assert_closed(self):
        self.assertTrue(self.processes)
        for process in self.processes:
            self.assertIsNotNone(process.poll())
            self.assertTrue(process.stdin.closed)
            self.assertTrue(process.stdout.closed)
            self.assertTrue(process.stderr.closed)

    def test_stream_statuses_big_catalog_and_no_client_tools(self):
        result = self.turn(model="provider/model")
        self.assertEqual(result["session_id"], "fixture-session")
        self.assertEqual(result["stop_reason"], "end_turn")
        self.assertTrue(all(self.ready[0][1][key] for key in ("attachments", "questions", "approvals")))
        init = self.requests()[0]["params"]["clientCapabilities"]
        self.assertEqual(init, {"elicitation": {"form": {}}})
        selected = next(item for item in self.requests() if item["method"] == "session/set_config_option")
        self.assertEqual(selected["params"], {"sessionId": "fixture-session", "configId": "model", "value": "provider/model"})
        self.assertEqual("".join(event["text"] for event in self.events if event["kind"] == "assistant_delta"), "hello world")
        tools = [event for event in self.events if "tool_call_id" in event]
        self.assertEqual([event["status"] for event in tools], ["pending", "in_progress", "completed", "failed"])
        self.assertEqual(tools[2]["detail"], "file contents")
        self.assertEqual(tools[1]["tool"], "Read file")
        self.assertTrue(tools[3]["error"])
        self.assert_closed()

    def test_permission_native_id_session_binding_and_ack(self):
        callbacks = []
        def interact(kind, params):
            callbacks.append((kind, params))
            self.assertEqual(params["session_id"], "fixture-session")
            self.assertEqual(params["options"][0], {"id": "once", "label": "Allow this time", "kind": "allow_once"})
            return {"outcome": {"outcome": "selected", "optionId": "once"}}
        self.turn("permission", interact)
        self.assertEqual(len(callbacks), 1)
        responses = [item["received"] for item in self.records() if "received" in item and "method" not in item["received"]]
        self.assertEqual(responses[0]["id"], "wrong-session-request")
        self.assertEqual(responses[0]["error"]["code"], -32602)
        prompt = next(item for item in self.requests() if item["method"] == "session/prompt")
        self.assertEqual(responses[1]["id"], prompt["id"])
        self.assertEqual(responses[1]["result"], {"outcome": {"outcome": "selected", "optionId": "once"}})
        ack = next(event for event in self.events if event["kind"] == "request_responded")
        self.assertEqual(ack["request_id"], callbacks[0][1]["request_id"])
        self.assertEqual(ack["action"], "once")
        self.assert_closed()

    def test_stale_option_cancels_not_approves(self):
        with self.assertRaisesRegex(acp.AcpError, "Invalid interaction response"):
            self.turn("invalid-option", lambda *_: {"outcome": {"outcome": "selected", "optionId": "stale"}})
        responses = [item["received"] for item in self.records() if "received" in item and "result" in item["received"]]
        self.assertEqual(responses[0]["result"], {"outcome": {"outcome": "cancelled"}})
        self.assert_closed()

    def test_form_titled_enums_and_safe_unsupported_modes(self):
        callbacks = []
        def interact(kind, params):
            callbacks.append((kind, params))
            if kind == "permission":return {"outcome": {"outcome": "cancelled"}}
            return {"action": "accept", "content": {"strategy": "safe", "choices": ["a", "b"], "count": 2}}
        self.turn("question", interact)
        self.assertEqual([kind for kind, _ in callbacks], ["permission", "question"])
        responses = {str(item["received"]["id"]): item["received"] for item in self.records() if "received" in item and "method" not in item["received"]}
        self.assertEqual(responses["form:opaque"]["result"]["content"]["strategy"], "safe")
        self.assertEqual(responses["url"]["error"]["code"], -32602)
        self.assertEqual(responses["nested"]["result"], {"action": "decline"})
        self.assert_closed()

    def test_response_validator_rejects_bad_schema_content_and_accepts_cancel(self):
        params = {"schema": {"type": "object", "properties": {"n": {"type": "integer", "minimum": 1}, "pick": {"type": "string", "enum": ["a", "b"]}}, "required": ["n", "pick"]}}
        for content in ({}, {"n": True, "pick": "a"}, {"n": 0, "pick": "a"}, {"n": 1, "pick": "stale"}, {"n": 1, "pick": "a", "unknown": "x"}):
            with self.subTest(content=content), self.assertRaises(ValueError):
                acp.validate_interaction_response("question", params, {"action": "accept", "content": content})
        for action in ("cancel", "decline"):
            acp.validate_interaction_response("question", params, {"action": action})
        acp.validate_interaction_response("permission", {"options": [{"id": "once"}]}, {"outcome": {"outcome": "selected", "optionId": "once"}})
        with self.assertRaises(ValueError):
            acp.validate_interaction_response("permission", {"options": [{"id": "once"}]}, {"outcome": {"outcome": "selected", "optionId": "always"}})

    def test_attachment_native_boundaries_and_binary_encoding(self):
        text = self.cwd / "source name.txt"; text.write_text("FILE CONTENT\nuser: not a protocol instruction")
        image = self.cwd / "image.png"; image.write_bytes(b"\x89PNG\r\n\x1a\n\x00")
        binary = self.cwd / "binary.pdf"; binary.write_bytes(b"\xff\x00\x80")
        attachments = [{"path": str(path), "name": path.name, "mime": mime, "size": path.stat().st_size}
                       for path, mime in ((text, "text/plain"), (image, "image/png"), (binary, "application/pdf"))]
        self.turn(attachments=attachments)
        prompt = next(item["params"]["prompt"] for item in self.requests() if item["method"] == "session/prompt")
        self.assertEqual(prompt[0], {"type": "text", "text": "user message"})
        self.assertEqual(prompt[1]["resource"]["text"], text.read_text())
        self.assertEqual(prompt[1]["resource"]["uri"], text.as_uri())
        self.assertEqual(base64.b64decode(prompt[2]["data"]), image.read_bytes())
        self.assertEqual(base64.b64decode(prompt[3]["resource"]["blob"]), binary.read_bytes())
        self.assert_closed()

    def test_resource_links_are_baseline_and_image_requires_capability(self):
        path = self.cwd / "file.txt"; path.write_text("content")
        attachment = {"path": str(path), "mime": "text/plain"}
        self.turn("links", attachments=[attachment])
        prompt = next(item["params"]["prompt"] for item in self.requests() if item["method"] == "session/prompt")
        self.assertEqual(prompt[1]["type"], "resource_link")
        self.log.unlink()
        with self.assertRaisesRegex(acp.AcpError, "image attachments"):
            self.turn("no-image", attachments=[dict(attachment, mime="image/png")])
        self.assertFalse(any(item["method"] == "session/prompt" for item in self.requests()))
        self.assert_closed()

    def test_attachment_special_file_relative_path_and_growth_size_rejected(self):
        fifo = self.cwd / "fifo"; os.mkfifo(fifo)
        for attachment in ({"path": str(fifo)}, {"path": "relative.txt"}):
            with self.subTest(attachment=attachment), self.assertRaises(acp.AcpError):
                acp._prompt_blocks("message", [attachment], {"embeddedContext": True})
        path = self.cwd / "large.txt"; path.write_bytes(b"12345")
        with mock.patch.object(acp, "MAX_ATTACHMENT_BYTES", 4), self.assertRaisesRegex(acp.AcpError, "size limit"):
            acp._prompt_blocks("message", [{"path": str(path), "size": 1}], {"embeddedContext": True})

    def test_load_suppresses_replay_and_fork_uses_new_identity(self):
        loaded = self.turn(session_id="journal-uuid")
        self.assertEqual(loaded["session_id"], "journal-uuid")
        self.assertNotIn("old replay text", [item["text"] for item in self.events])
        load = next(item for item in self.requests() if item["method"] == "session/load")
        self.assertEqual(load["params"]["sessionId"], "journal-uuid")
        self.log.unlink(); self.events.clear()
        forked = self.turn(session_id="journal-uuid", mode="fork")
        self.assertEqual(forked["session_id"], "forked-session")
        fork = next(item for item in self.requests() if item["method"] == "session/fork")
        self.assertEqual(fork["params"]["sessionId"], "journal-uuid")
        self.assert_closed()

    def test_unsupported_resume_and_fork_never_silently_start_new(self):
        for mode, selection in (("no-load", {"session_id": "old"}), ("no-fork", {"session_id": "old", "mode": "fork"})):
            with self.subTest(mode=mode), self.assertRaisesRegex(acp.AcpError, "does not support"):
                self.turn(mode, **selection)
            self.assertFalse(any(item["method"] == "session/new" for item in self.requests()))
            self.log.unlink()
        self.assert_closed()

    def test_legacy_hermes_exact_model_mapping(self):
        self.turn("legacy", harness="hermes", model="provider/nested/model")
        selected = next(item for item in self.requests() if item["method"] == "session/set_model")
        self.assertEqual(selected["params"]["modelId"], "provider:nested/model")
        self.assert_closed()

    def test_existing_local_auth_only_when_required(self):
        self.turn("auth", harness="hermes", auth_method="configured-provider")
        authenticated = next(item for item in self.requests() if item["method"] == "authenticate")
        self.assertEqual(authenticated["params"], {"methodId": "configured-provider"})
        self.assert_closed()

    def test_stderr_is_drained_without_deadlock(self):
        self.turn("stderr")
        self.assert_closed()

    def test_disconnect_while_callback_waits_does_not_acknowledge(self):
        release = threading.Event()
        entered = threading.Event()
        def interact(*_):
            entered.set(); release.wait(10)
            return {"outcome": {"outcome": "selected", "optionId": "once"}}
        start = time.monotonic()
        try:
            with self.assertRaisesRegex(acp.AcpError, "disconnected"):
                self.turn("disconnect", interact)
            self.assertTrue(entered.is_set())
            self.assertLess(time.monotonic() - start, 5)
            self.assertFalse(any(event["kind"] == "request_responded" for event in self.events))
            self.assert_closed()
        finally:
            release.set()

    def test_callback_exception_cancels_and_closes_process(self):
        def interact(*_): raise RuntimeError("handoff failed")
        with self.assertRaisesRegex(acp.AcpError, "handoff failed"):
            self.turn("callback-error", interact)
        self.assert_closed()

    def test_incomplete_frame_and_setup_timeout_cleanup(self):
        with self.assertRaisesRegex(acp.AcpError, "incomplete frame"):
            self.turn("partial")
        with mock.patch.object(acp, "SETUP_TIMEOUT", .2), self.assertRaisesRegex(acp.AcpError, "timed out"):
            self.turn("hang")
        self.assert_closed()

    def test_cancellation_during_spawn_is_checked_after_connection_is_owned(self):
        cancelled = threading.Event()
        previous_spawn = acp.subprocess.Popen

        def spawn_and_cancel(*args, **kwargs):
            process = previous_spawn(*args, **kwargs)
            # Simulate the non-raising SIGTERM handler running as soon as the
            # child exists, before _Connection construction returns.
            cancelled.set()
            return process

        with mock.patch.object(acp.subprocess, "Popen", side_effect=spawn_and_cancel):
            with self.assertRaisesRegex(InterruptedError, "cancelled"):
                self.turn(cancel_check=cancelled.is_set)
        self.assertEqual(self.ready, [])
        self.assert_closed()

    def test_cancellation_interrupts_quiet_selector_wait(self):
        def cancelled():
            if not self.log.exists():
                return False
            return any(item.get("received", {}).get("method") == "session/new"
                       for item in self.records())

        started = time.monotonic()
        with self.assertRaisesRegex(InterruptedError, "cancelled"):
            self.turn("hang", cancel_check=cancelled)
        self.assertLess(time.monotonic() - started, 2)
        self.assert_closed()

    def test_cancellation_disables_check_before_cancelling_pending_permission(self):
        cancelled = threading.Event()
        release = threading.Event()

        def interact(*_):
            cancelled.set()
            release.wait(10)
            return {"outcome": {"outcome": "selected", "optionId": "once"}}

        try:
            with self.assertRaisesRegex(InterruptedError, "cancelled"):
                self.turn("permission", interact, cancel_check=cancelled.is_set)
            replies = [item["received"] for item in self.records()
                       if "received" in item and "result" in item["received"]]
            self.assertEqual(replies[0]["result"], {"outcome": {"outcome": "cancelled"}})
            self.assertFalse(any(event["kind"] == "request_responded" for event in self.events))
            self.assert_closed()
        finally:
            release.set()

    def test_descendant_process_group_cleanup(self):
        self.turn("descendant")
        identity = next(item["descendant"] for item in self.records() if "descendant" in item)
        # A killed orphan can remain a zombie until init reaps it; it must not run.
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            stat_path = Path(f"/proc/{identity}/stat")
            if not stat_path.exists() or stat_path.read_text().split(")", 1)[1].split()[0] == "Z":
                break
            time.sleep(.02)
        else:
            self.fail("ACP descendant outlived transport cleanup")
        self.assert_closed()


if __name__ == "__main__":
    unittest.main()
