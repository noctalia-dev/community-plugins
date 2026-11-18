"""One managed turn over ACP v1 JSON-lines stdio, with no client tool delegation."""
from __future__ import annotations

import base64
import datetime
import json
import math
import os
from pathlib import Path
import queue
import re
import selectors
import signal
import stat
import subprocess
import threading
import time
import uuid
from urllib.parse import urlsplit

SETUP_TIMEOUT = 60.0
TURN_TIMEOUT = 1800.0
INTERACTION_TIMEOUT = 1800.0
MAX_FRAME_BYTES = 32 * 1024 * 1024
MAX_ATTACHMENT_BYTES = 16 * 1024 * 1024
MAX_ATTACHMENTS_BYTES = 32 * 1024 * 1024
STDERR_BYTES = 16 * 1024


class AcpError(RuntimeError):
    """A protocol, transport, or negotiated capability failure."""


class RpcError(AcpError):
    def __init__(self, method, error):
        self.code = error.get("code")
        self.error = error
        detail = error.get("data")
        detail = detail.get("details") if isinstance(detail, dict) else None
        super().__init__(f"{method}: {error.get('message', 'ACP error')}" + (f": {detail}" if detail else ""))


def _enum_values(schema):
    if "enum" in schema:
        values = schema["enum"]
        if not isinstance(values, list) or not values:
            raise ValueError("invalid enum")
        return values
    choices = schema.get("oneOf", schema.get("anyOf"))
    if choices is not None:
        if not isinstance(choices, list) or not choices or any(
            not isinstance(item, dict) or "const" not in item
            or set(item) - {"const", "title", "description"} for item in choices
        ):
            raise ValueError("unsupported enum alternatives")
        return [item["const"] for item in choices]
    return None


def _validate_property(schema, value=None, *, check_value=False):
    if not isinstance(schema, dict):
        raise ValueError("invalid form field")
    allowed = {"type", "title", "description", "default", "enum", "enumNames", "oneOf", "anyOf",
               "minimum", "maximum", "minLength", "maxLength", "format", "items", "minItems", "maxItems", "uniqueItems"}
    if set(schema) - allowed:
        raise ValueError("unsupported form field constraint")
    values = _enum_values(schema)
    kind = schema.get("type")
    if kind is None and values is not None and all(isinstance(item, str) for item in values):
        kind = "string"
    if kind not in {"string", "boolean", "integer", "number", "array"}:
        raise ValueError("unsupported form field type")
    if kind == "array":
        items = schema.get("items")
        if not isinstance(items, dict) or _enum_values(items) is None:
            raise ValueError("only enum arrays are supported")
        _validate_property(items)
    if kind == "string" and schema.get("format") not in {None, "email", "uri", "date", "date-time"}:
        raise ValueError("unsupported string format")
    if not check_value:
        return
    valid = {"string": isinstance(value, str), "boolean": isinstance(value, bool),
             "integer": isinstance(value, int) and not isinstance(value, bool),
             "number": isinstance(value, (float, int)) and not isinstance(value, bool),
             "array": isinstance(value, list)}[kind]
    if not valid or (kind in {"integer", "number"} and not math.isfinite(value)):
        raise ValueError("form field has wrong type")
    if values is not None and not any(type(value) is type(item) and value == item for item in values):
        raise ValueError("form value is not an offered option")
    if kind in {"integer", "number"}:
        if value < schema.get("minimum", -math.inf) or value > schema.get("maximum", math.inf):
            raise ValueError("form number outside allowed range")
    if kind in {"string", "array"}:
        minimum, maximum = ("minLength", "maxLength") if kind == "string" else ("minItems", "maxItems")
        if len(value) < schema.get(minimum, 0) or len(value) > schema.get(maximum, math.inf):
            raise ValueError("form value outside allowed length")
    if kind == "array":
        for item in value:
            _validate_property(schema["items"], item, check_value=True)
        if schema.get("uniqueItems") and len({json.dumps(item, sort_keys=True) for item in value}) != len(value):
            raise ValueError("duplicate form array items")
    if kind == "string":
        fmt = schema.get("format")
        try:
            if fmt == "date":
                datetime.date.fromisoformat(value)
            elif fmt == "date-time":
                parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
                if parsed.tzinfo is None:
                    raise ValueError("date-time requires timezone")
            elif fmt == "email" and not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", value):
                raise ValueError("invalid email")
            elif fmt == "uri" and not urlsplit(value).scheme:
                raise ValueError("invalid URI")
        except ValueError as exc:
            raise ValueError("form value has invalid format") from exc


def _validate_form(schema, content=None, *, check_value=False):
    if not isinstance(schema, dict) or schema.get("type") != "object":
        raise ValueError("form schema must be a flat object")
    if set(schema) - {"type", "properties", "required", "title", "description", "additionalProperties", "$schema"}:
        raise ValueError("unsupported form schema")
    properties = schema.get("properties", {})
    required = schema.get("required", [])
    if not isinstance(properties, dict) or not isinstance(required, list) or any(key not in properties for key in required):
        raise ValueError("invalid form properties")
    for prop in properties.values():
        _validate_property(prop)
    if check_value:
        if not isinstance(content, dict) or set(content) - set(properties) or any(key not in content for key in required):
            raise ValueError("form response has missing or unknown fields")
        for key, value in content.items():
            _validate_property(properties[key], value, check_value=True)


def validate_interaction_response(kind, params, result):
    """Validate the bridge's native response before it queues a user submission."""
    if not isinstance(result, dict):
        raise ValueError("Interaction response must be an object")
    if kind == "permission":
        outcome = result.get("outcome")
        if not isinstance(outcome, dict):
            raise ValueError("Permission response requires an outcome")
        if outcome.get("outcome") == "cancelled":
            return
        options = params.get("options", [])
        ids = {item.get("optionId", item.get("id")) for item in options if isinstance(item, dict)}
        if outcome.get("outcome") != "selected" or not isinstance(outcome.get("optionId"), str) or outcome["optionId"] not in ids:
            raise ValueError("Permission option is not offered by this request")
    elif kind == "question":
        if result.get("action") not in {"accept", "decline", "cancel"}:
            raise ValueError("Invalid question action")
        if result["action"] == "accept":
            try:
                _validate_form(params.get("requestedSchema", params.get("schema")), result.get("content"), check_value=True)
            except TypeError as exc:
                raise ValueError("Invalid question schema or content") from exc
    else:
        raise ValueError("Unknown interaction kind")


def _prompt_blocks(message, attachments, capabilities):
    """Read only explicitly selected regular files; preserve native content boundaries."""
    blocks = [{"type": "text", "text": message}]
    total = 0
    for item in attachments:
        path = Path(item["path"])
        if not path.is_absolute():
            raise AcpError("Attachment path must be absolute")
        mime = item.get("mime") or "application/octet-stream"
        if mime.startswith("image/") and not capabilities.get("image"):
            raise AcpError("This agent does not support image attachments")
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode):
                raise AcpError("Attachment must be a regular file")
            if info.st_size > MAX_ATTACHMENT_BYTES or total + info.st_size > MAX_ATTACHMENTS_BYTES:
                raise AcpError("Attachment size limit exceeded")
            if not mime.startswith("image/") and not capabilities.get("embeddedContext"):
                total += info.st_size
                blocks.append({"type": "resource_link", "uri": path.as_uri(), "name": item.get("name") or path.name,
                               "mimeType": mime, "size": info.st_size})
                continue
            # Bound the actual read too: files can grow after metadata validation.
            with os.fdopen(fd, "rb", closefd=False) as handle:
                data = handle.read(MAX_ATTACHMENT_BYTES + 1)
            total += len(data)
            if len(data) > MAX_ATTACHMENT_BYTES or total > MAX_ATTACHMENTS_BYTES:
                raise AcpError("Attachment size limit exceeded")
        finally:
            os.close(fd)
        uri = path.as_uri()
        if mime.startswith("image/"):
            blocks.append({"type": "image", "mimeType": mime, "data": base64.b64encode(data).decode("ascii"), "uri": uri})
        elif capabilities.get("embeddedContext"):
            resource = {"uri": uri, "mimeType": mime}
            try:
                resource["text"] = data.decode("utf-8")
            except UnicodeDecodeError:
                resource["blob"] = base64.b64encode(data).decode("ascii")
            blocks.append({"type": "resource", "resource": resource})
    return blocks


def _config_values(options):
    for item in options:
        if not isinstance(item, dict):
            continue
        if "options" in item:
            yield from _config_values(item["options"])
        elif isinstance(item.get("value"), str):
            yield item


def _model_id(requested, available, harness):
    ids = [item["id"] for item in available]
    if requested in ids:
        return requested
    # Hermes' native provider:model IDs differ from the existing provider/model catalog.
    if harness == "hermes" and "/" in requested:
        provider, model = requested.split("/", 1)
        native = provider + ":" + model
        if native in ids:
            return native
    raise AcpError(f"Selected model is not offered by the agent: {requested}")


class _Connection:
    def __init__(self, argv, cwd, emit, interaction, cancel_check=None):
        self.emit = emit
        self.interaction = interaction
        # Cancellation is checked only after run_turn owns this fully constructed
        # connection, so an event set during Popen cannot strand its child.
        self.cancel_check = cancel_check
        self.session_id = None
        self.replaying = False
        self.sequence = 0
        self.buffer = bytearray()
        self.stderr = bytearray()
        self.tools = {}
        self.pending = {}
        self.completed = queue.Queue()
        self.seen_requests = set()
        self.process = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, bufsize=0, start_new_session=True)
        self.selector = selectors.DefaultSelector()
        for pipe, kind in ((self.process.stdout, "stdout"), (self.process.stderr, "stderr")):
            os.set_blocking(pipe.fileno(), False)
            self.selector.register(pipe, selectors.EVENT_READ, kind)
        os.set_blocking(self.process.stdin.fileno(), False)

    def check_cancel(self):
        if self.cancel_check is not None and self.cancel_check():
            raise InterruptedError("ACP turn cancelled")

    def send(self, payload, timeout=None):
        self.check_cancel()
        data = memoryview((json.dumps(payload, ensure_ascii=False, allow_nan=False) + "\n").encode("utf-8"))
        deadline = time.monotonic() + (SETUP_TIMEOUT if timeout is None else timeout)
        while data:
            self.check_cancel()
            try:
                written = os.write(self.process.stdin.fileno(), data)
                data = data[written:]
            except BlockingIOError:
                # stdout/stderr can fill while the agent is still reading a large prompt.
                self.pump(min(0.1, max(0, deadline - time.monotonic())), write_wait=True)
            except BrokenPipeError as exc:
                raise self.disconnected() from exc
            if time.monotonic() >= deadline:
                raise AcpError("ACP write timed out")

    def disconnected(self):
        diagnostic = bytes(self.stderr).decode("utf-8", "replace").strip()
        return AcpError("ACP agent disconnected" + (f": {diagnostic}" if diagnostic else ""))

    def update(self, params):
        if self.replaying or params.get("sessionId") != self.session_id:
            return
        update = params.get("update", {})
        kind = update.get("sessionUpdate")
        content = update.get("content", {})
        if kind in {"agent_message_chunk", "agent_thought_chunk"} and isinstance(content, dict):
            if content.get("type") == "text" and isinstance(content.get("text"), str):
                self.emit("assistant_delta" if kind == "agent_message_chunk" else "thought", content["text"],
                          message_id=update.get("messageId"))
        elif kind in {"tool_call", "tool_call_update"}:
            identity = update.get("toolCallId")
            if not isinstance(identity, str):
                return
            tool = self.tools.setdefault(identity, {})
            tool.update({key: value for key, value in update.items() if value is not None})
            status = tool.get("status", "pending")
            detail = []
            for block in tool.get("content", []):
                if isinstance(block, dict) and block.get("type") == "content":
                    nested = block.get("content", {})
                    if isinstance(nested, dict) and nested.get("type") == "text":
                        detail.append(nested.get("text", ""))
                elif isinstance(block, dict) and block.get("type") == "diff":
                    detail.append(str(block.get("path", "")))
            self.emit("tool_result" if status in {"completed", "failed"} else "tool_call",
                      tool.get("title") or tool.get("kind") or "Tool",
                      tool=tool.get("title") or tool.get("kind") or "Tool", tool_call_id=identity,
                      status=status, detail="\n".join(detail)[:16000], error=status == "failed")
        elif kind == "plan":
            self.emit("plan", "\n".join(str(entry.get("content", "")) for entry in update.get("entries", []) if isinstance(entry, dict)),
                      entries=update.get("entries", []))
        elif kind == "session_info_update":
            self.emit("session_info", "", title=update.get("title"))

    def reply_error(self, rpc_id, message, code=-32602):
        self.send({"jsonrpc": "2.0", "id": rpc_id, "error": {"code": code, "message": message}})

    def request(self, message):
        rpc_id = message.get("id")
        if not isinstance(rpc_id, (str, int)) or isinstance(rpc_id, bool):
            self.reply_error(None, "Invalid JSON-RPC request id", -32600)
            return
        key = (type(rpc_id), rpc_id)
        if key in self.seen_requests:
            raise AcpError("Agent reused a JSON-RPC request id")
        self.seen_requests.add(key)
        method = message.get("method")
        params = message.get("params", {})
        if method not in {"session/request_permission", "elicitation/create"}:
            self.reply_error(rpc_id, "Client method not supported", -32601)
            return
        if not isinstance(params, dict) or not self.session_id or params.get("sessionId") != self.session_id:
            self.reply_error(rpc_id, "Request does not belong to the active session")
            return
        kind = "permission" if method == "session/request_permission" else "question"
        token = uuid.uuid4().hex
        handoff = dict(params, request_id=token, session_id=self.session_id)
        if kind == "permission":
            options = params.get("options")
            valid_kinds = {"allow_once", "allow_always", "reject_once", "reject_always"}
            if not isinstance(options, list) or not options or any(
                not isinstance(option, dict) or not isinstance(option.get("optionId"), str)
                or not isinstance(option.get("name"), str) or option.get("kind") not in valid_kinds for option in options
            ) or len({option["optionId"] for option in options}) != len(options):
                self.reply_error(rpc_id, "Invalid permission options")
                return
            tool = params.get("toolCall")
            if not isinstance(tool, dict) or not isinstance(tool.get("toolCallId"), str):
                self.reply_error(rpc_id, "Invalid permission tool call")
                return
            handoff.update(title=tool.get("title") or "Tool permission", tool=tool.get("title") or tool.get("kind"),
                           options=[{"id": option["optionId"], "label": option["name"], "kind": option["kind"]} for option in options])
        else:
            if params.get("mode") != "form":
                self.reply_error(rpc_id, "Only form elicitation was advertised")
                return
            try:
                _validate_form(params.get("requestedSchema"))
            except (ValueError, TypeError):
                self.send({"jsonrpc": "2.0", "id": rpc_id, "result": {"action": "decline"}})
                self.emit("question_unsupported", "Agent requested an unsupported form schema")
                return
            handoff.update(title=params.get("message") or "Agent question", schema=params["requestedSchema"], options=[])
        self.pending[token] = {"rpc_id": rpc_id, "kind": kind, "params": params, "started": time.monotonic()}

        def interact():
            try:
                result = self.interaction(kind, handoff)
                self.completed.put((token, result, None))
            except BaseException as exc:
                self.completed.put((token, None, exc))

        threading.Thread(target=interact, daemon=True, name="agentik-acp-interaction").start()

    def finish_interactions(self):
        while True:
            try:
                token, result, error = self.completed.get_nowait()
            except queue.Empty:
                break
            pending = self.pending.get(token)
            if pending is None:
                continue
            kind, params = pending["kind"], pending["params"]
            valid = error is None
            if valid:
                try:
                    validate_interaction_response(kind, params, result)
                except ValueError:
                    valid = False
            if not valid:
                result = {"outcome": {"outcome": "cancelled"}} if kind == "permission" else {"action": "cancel"}
            elif kind == "question" and result["action"] != "accept":
                result = {"action": result["action"]}
            self.send({"jsonrpc": "2.0", "id": pending["rpc_id"], "result": result})
            self.pending.pop(token, None)
            self.emit("request_responded", "", request_id=token, request_kind=kind,
                      action=(result["outcome"].get("optionId") or "cancel") if kind == "permission" else result["action"])
            if error is not None:
                raise AcpError(f"Agent interaction failed: {error}") from error
            if not valid:
                raise AcpError("Invalid interaction response; request cancelled safely")
        for pending in self.pending.values():
            if time.monotonic() - pending["started"] >= INTERACTION_TIMEOUT:
                raise AcpError("Agent interaction timed out")

    def pump(self, timeout, *, write_wait=False):
        self.check_cancel()
        if self.cancel_check is not None:
            timeout = min(timeout, 0.1)
        # write_wait drains bytes but leaves frames queued, avoiding recursive writes.
        for key, _ in self.selector.select(timeout):
            self.check_cancel()
            data = os.read(key.fileobj.fileno(), 65536)
            if not data:
                self.selector.unregister(key.fileobj)
                if key.data == "stdout":
                    if self.buffer and not self.buffer.endswith(b"\n"):
                        raise AcpError("ACP agent disconnected with an incomplete frame")
                    if not self.buffer:
                        raise self.disconnected()
                continue
            if key.data == "stderr":
                self.stderr.extend(data)
                del self.stderr[:-STDERR_BYTES]
            else:
                self.buffer.extend(data)
                if len(self.buffer) > MAX_FRAME_BYTES and b"\n" not in self.buffer:
                    raise AcpError("ACP frame exceeds size limit")
        self.check_cancel()
        if not write_wait:
            self.finish_interactions()

    def call(self, method, params, timeout=None):
        self.check_cancel()
        self.sequence += 1
        rpc_id = self.sequence
        self.send({"jsonrpc": "2.0", "id": rpc_id, "method": method, "params": params})
        deadline = time.monotonic() + (SETUP_TIMEOUT if timeout is None else timeout)
        while True:
            while b"\n" in self.buffer:
                self.check_cancel()
                line, _, rest = self.buffer.partition(b"\n")
                self.buffer[:] = rest
                if len(line) > MAX_FRAME_BYTES:
                    raise AcpError("ACP frame exceeds size limit")
                if not line.strip():
                    continue
                try:
                    message = json.loads(line)
                except (ValueError, UnicodeDecodeError) as exc:
                    raise AcpError("Invalid ACP JSON frame") from exc
                if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
                    raise AcpError("Invalid ACP JSON-RPC frame")
                if "method" in message:
                    if "id" in message:
                        self.request(message)
                    elif message["method"] == "session/update":
                        self.update(message.get("params", {}))
                elif type(message.get("id")) is int and message["id"] == rpc_id:
                    if "error" in message:
                        raise RpcError(method, message["error"])
                    if not isinstance(message.get("result"), dict):
                        raise AcpError(f"{method} returned an invalid result")
                    if self.pending:
                        raise AcpError("Agent ended a request with unresolved interactions")
                    return message["result"]
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AcpError(f"{method} timed out")
            self.pump(min(0.1 if self.pending else 1.0, remaining))
            if self.process.poll() is not None and not self.buffer:
                raise self.disconnected()

    def close(self):
        self.cancel_check = None
        # Cancel unanswered prompts explicitly; never send an approval on cleanup.
        cleanup_deadline = time.monotonic() + 0.2
        try:
            for pending in self.pending.values():
                remaining = cleanup_deadline - time.monotonic()
                if remaining <= 0:
                    break
                result = {"outcome": {"outcome": "cancelled"}} if pending["kind"] == "permission" else {"action": "cancel"}
                self.send({"jsonrpc": "2.0", "id": pending["rpc_id"], "result": result}, timeout=remaining)
            if self.session_id:
                self.send({"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": self.session_id}},
                          timeout=max(0.01, cleanup_deadline - time.monotonic()))
        except (OSError, AcpError):
            pass
        self.pending.clear()
        self.process.stdin.close()
        try:
            self.process.wait(timeout=0.3)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(self.process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                self.process.wait(timeout=0.5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(self.process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                self.process.wait()
        finally:
            # Descendants must not outlive the dedicated ACP process group.
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.selector.close()
            self.process.stdout.close()
            self.process.stderr.close()


def run_turn(argv, selection, message, attachments, emit, interaction, session_ready, *, cancel_check=None):
    """Run one turn, returning the native session id and negotiated UI capabilities.

    ``interaction`` returns the actual permission/elicitation result, not a UI action.
    ``request_responded`` is emitted only after writing that result to the agent.
    Optional ``cancel_check`` is polled during transport waits and writes; it must
    return a boolean, not raise from a signal handler. Cleanup disables the check.
    """
    cwd = selection.get("cwd")
    if not isinstance(cwd, str) or not Path(cwd).is_absolute() or not Path(cwd).is_dir():
        raise AcpError("ACP session cwd must be an existing absolute directory")
    if not isinstance(argv, list) or not argv or any(not isinstance(arg, str) for arg in argv):
        raise AcpError("Invalid ACP command")
    connection = _Connection(argv, cwd, emit, interaction, cancel_check=cancel_check)
    try:
        initialized = connection.call("initialize", {
            "protocolVersion": 1, "clientInfo": {"name": "agentik", "version": "1"},
            "clientCapabilities": {"elicitation": {"form": {}}},
        })
        if initialized.get("protocolVersion") != 1:
            raise AcpError("Agent does not support ACP protocol version 1")
        agent = initialized.get("agentCapabilities", {})
        prompt_capabilities = agent.get("promptCapabilities", {})
        capabilities = {"attachments": True, "questions": True, "approvals": True,
                        "images": bool(prompt_capabilities.get("image")),
                        "embedded_context": bool(prompt_capabilities.get("embeddedContext"))}
        prompt = _prompt_blocks(message, attachments, prompt_capabilities)
        session_id = selection.get("session_id")
        params = {"cwd": cwd, "mcpServers": []}
        if session_id:
            if not isinstance(session_id, str):
                raise AcpError("Invalid ACP session id")
            params["sessionId"] = session_id
            connection.session_id = session_id
            if selection.get("mode") == "fork":
                if agent.get("sessionCapabilities", {}).get("fork") is None:
                    raise AcpError("Agent does not support session forks")
                method = "session/fork"
            else:
                if not agent.get("loadSession"):
                    raise AcpError("Agent does not support loading this session")
                method = "session/load"
                connection.replaying = True
        elif selection.get("mode") == "fork":
            raise AcpError("Fork requires the original ACP session id")
        else:
            method = "session/new"
        try:
            session = connection.call(method, params)
        except RpcError as exc:
            if exc.code != -32000:
                raise
            # Only the known installed local-credential flows are eligible. No browser login or keys.
            methods = initialized.get("authMethods", [])
            auth_id = "agent" if selection.get("harness") == "omp" else selection.get("auth_method")
            if not auth_id or not any(item.get("id") == auth_id and item.get("type", "agent") == "agent" for item in methods):
                raise AcpError("Agent requires authentication; configure local credentials in its terminal first") from exc
            connection.call("authenticate", {"methodId": auth_id})
            session = connection.call(method, params)
        connection.replaying = False
        if method != "session/load":
            session_id = session.get("sessionId")
        if not isinstance(session_id, str) or not session_id:
            raise AcpError("Agent did not return a valid session id")
        connection.session_id = session_id
        session_ready(session_id, capabilities)
        config = next((item for item in session.get("configOptions", []) if isinstance(item, dict)
                       and (item.get("category") == "model" or item.get("id") == "model") and item.get("type") == "select"), None)
        available = []
        if config:
            available = [{"id": item["value"], "label": item.get("name", item["value"]), "provider": ""}
                         for item in _config_values(config.get("options", []))]
        else:
            available = [{"id": item["modelId"], "label": item.get("name", item["modelId"]), "provider": ""}
                         for item in session.get("models", {}).get("availableModels", []) if isinstance(item, dict) and isinstance(item.get("modelId"), str)]
        requested = selection.get("model")
        if requested and requested != "default":
            chosen = _model_id(requested, available, selection.get("harness"))
            if config:
                connection.call("session/set_config_option", {"sessionId": session_id, "configId": config["id"], "value": chosen})
            else:
                connection.call("session/set_model", {"sessionId": session_id, "modelId": chosen})
        response = connection.call("session/prompt", {"sessionId": session_id, "prompt": prompt}, timeout=TURN_TIMEOUT)
        stop = response.get("stopReason")
        if stop not in {"end_turn", "max_tokens", "max_turn_requests", "refusal", "cancelled"}:
            raise AcpError("Agent returned an invalid stop reason")
        return {"session_id": session_id, "capabilities": capabilities, "stop_reason": stop, "models": available}
    finally:
        connection.close()
