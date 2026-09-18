#!/usr/bin/env python3
"""Run full coding-agent sessions from the Agentik panel."""

from __future__ import annotations

import argparse
import hashlib
import fcntl
import json
import os
import platform
import shutil
import signal
import sqlite3
import re
import subprocess
import sys
import time
import uuid
from pathlib import Path

MAX_MESSAGE_CHARS = 4_000
MAX_TRANSCRIPT_MESSAGES = 30
MAX_TARGETS = 200
MAX_MODEL_CHARS = 256
CATALOG_TTL_SECONDS = 300
STREAM_WRITE_INTERVAL_SECONDS = 0.1
STARTUP_GRACE_SECONDS = 5
CANCEL_GRACE_SECONDS = 2
ACTIVE_RUN_STATES = frozenset({"starting", "running", "waiting_for_input", "cancelling"})


def state_root() -> Path:
    override = os.environ.get("AGENTIK_STATE_DIR")
    if override:
        return Path(override).expanduser()
    base = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
    return base / "agentik/chat"


def sessions_root() -> Path:
    override = os.environ.get("AGENTIK_SESSIONS_DIR")
    if override:
        return Path(override).expanduser()
    return Path.home() / ".omp/agent/sessions"


def hermes_home() -> Path:
    return Path(os.environ.get("HERMES_HOME", Path.home() / ".hermes")).expanduser()


def session_path(value: str) -> Path:
    """Resolve a selected journal without permitting paths outside OMP storage."""
    root = sessions_root().resolve()
    path = Path(value).expanduser().resolve()
    try:
        path.relative_to(root)
    except ValueError as error:
        raise ValueError("selected journal is outside the OMP sessions directory") from error
    return path


def empty_state() -> dict:
    return {"version": 4, "selection": None, "stream": None, "last_run": None}


def read_state(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return empty_state()
    if not isinstance(value, dict) or value.get("version") not in (2, 3, 4):
        return empty_state()
    if value.get("version") in (2, 3):
        value["version"] = 4
        if isinstance(value.get("selection"), dict):
            value["selection"].setdefault("harness", "omp")
        legacy_stream = value.get("stream")
        if isinstance(legacy_stream, dict):
            legacy_stream.setdefault("run_id", f"legacy-{uuid.uuid4()}")
            legacy_stream.setdefault("state", "orphaned")
            legacy_stream.setdefault("updated", legacy_stream.get("started", time.time()))
    value.setdefault("stream", None)
    value.setdefault("last_run", None)
    selection = value.get("selection")
    if selection is not None and not isinstance(selection, dict):
        value["selection"] = None
    return value


def write_state(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    path.parent.chmod(0o700)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
    temporary.chmod(0o600)
    temporary.replace(path)


def decode_value(value: str) -> str:
    try:
        decoded = bytes.fromhex(value).decode("utf-8")
    except (ValueError, UnicodeDecodeError) as error:
        raise ValueError("invalid value encoding") from error
    return decoded.strip()


def decode_message(value: str) -> str:
    message = decode_value(value)
    if not message:
        raise ValueError("message is empty")
    if len(message) > MAX_MESSAGE_CHARS:
        raise ValueError(f"message exceeds {MAX_MESSAGE_CHARS} characters")
    return message


def parse_record(line: str) -> dict | None:
    try:
        value = json.loads(line)
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, dict) else None


def text_of_message(record: dict) -> tuple[str, str] | None:
    if record.get("type") != "message":
        return None
    message = record.get("message")
    if not isinstance(message, dict):
        return None
    role = message.get("role")
    if role not in ("user", "assistant"):
        return None
    content = message.get("content")
    if isinstance(content, str):
        text = content.strip()
    elif isinstance(content, list):
        text = "\n".join(
            item["text"] for item in content
            if isinstance(item, dict)
            and item.get("type") == "text"
            and isinstance(item.get("text"), str)
        ).strip()
    else:
        text = ""
    return (role, text) if text else None


def bounded_records(path: Path) -> list[dict]:
    with path.open("rb") as journal:
        prefix = journal.read(8_192)
        journal.seek(0, 2)
        size = journal.tell()
        journal.seek(max(0, size - 65_536))
        suffix = journal.read()
    lines = (prefix + b"\n" + suffix).decode("utf-8", errors="replace").splitlines()
    records = []
    seen = set()
    for line in lines:
        record = parse_record(line)
        if record is None:
            continue
        identity = record.get("id")
        marker = identity if isinstance(identity, str) else line
        if marker in seen:
            continue
        seen.add(marker)
        records.append(record)
    return records


def active_terminal_session_paths() -> set[str]:
    """Return journals owned by currently running interactive OMP clients."""
    active = set()
    process_root = Path("/proc")
    terminal_root = Path.home() / ".omp/agent/terminal-sessions"
    try:
        processes = process_root.iterdir()
    except OSError:
        return active
    for process in processes:
        if not process.name.isdigit():
            continue
        try:
            command = (process / "comm").read_text(encoding="utf-8").strip()
            arguments = (process / "cmdline").read_bytes().split(b"\0")
            executable = Path(os.fsdecode(arguments[0])).name if arguments and arguments[0] else ""
            if command != "omp" and executable != "omp":
                continue
            decoded_args = [os.fsdecode(argument) for argument in arguments if argument]
            if "--resume" in decoded_args:
                index = decoded_args.index("--resume") + 1
                if index < len(decoded_args) and ("/" in decoded_args[index] or decoded_args[index].endswith(".jsonl")):
                    active.add(str(Path(decoded_args[index]).expanduser().resolve()))
            terminal = os.readlink(process / "fd/0")
            if not terminal.startswith("/dev/pts/"):
                continue
            breadcrumb = terminal_root / ("pts-" + terminal.rsplit("/", 1)[-1])
            lines = breadcrumb.read_text(encoding="utf-8").splitlines()
            if len(lines) >= 2 and lines[1]:
                active.add(str(Path(lines[1]).expanduser().resolve()))
        except (OSError, UnicodeError):
            continue
    return active


def session_descriptor(path: Path, active_paths: set[str] | None = None) -> dict | None:
    try:
        stat = path.stat()
        records = bounded_records(path)
    except OSError:
        return None
    header = next((record for record in records if record.get("type") == "session"), None)
    if not isinstance(header, dict) or not isinstance(header.get("id"), str):
        return None

    title = None
    cwd = header.get("cwd") if isinstance(header.get("cwd"), str) else None
    model = None
    first_message = None
    entries = []
    for record in records:
        record_type = record.get("type")
        if record_type in ("title", "title_change"):
            candidate = record.get("title")
            if isinstance(candidate, str) and candidate.strip():
                title = candidate.strip()
        elif record_type == "model_change":
            candidate = record.get("model")
            if isinstance(candidate, str) and candidate:
                model = candidate
        message = text_of_message(record)
        if message is not None and message[0] == "user" and first_message is None:
            first_message = message[1].splitlines()[0]
        if isinstance(record.get("id"), str):
            entries.append(record)

    last = entries[-1] if entries else None
    if active_paths is None:
        active_paths = active_terminal_session_paths()
    is_active = str(path.resolve()) in active_paths
    resumable = (
        isinstance(last, dict)
        and last.get("type") == "custom"
        and last.get("customType") == "session_exit"
        and not is_active
    )
    project = Path(cwd).name if cwd else "unknown"
    display = title or first_message or f"Session {header['id'][:8]}"
    return {
        "id": header["id"],
        "path": str(path),
        "cwd": cwd,
        "project": project or cwd or "unknown",
        "title": display[:80],
        "model": model,
        "active": is_active,
        # A fork never writes this journal, so it is safe even when an earlier
        # OMP client ended without recording its terminal session_exit marker.
        "forkable": not resumable,
        "resumable": resumable,
        "modified": int(stat.st_mtime),
        "signature": f"{stat.st_mtime_ns}:{stat.st_size}",
    }


def list_targets() -> list[dict]:
    root = sessions_root()
    if not root.exists():
        return []
    targets = []
    active_paths = active_terminal_session_paths()
    for path in root.rglob("*.jsonl"):
        descriptor = session_descriptor(path, active_paths)
        if descriptor is not None:
            targets.append(descriptor)
    targets.sort(key=lambda target: target["modified"], reverse=True)
    return targets[:MAX_TARGETS]


def session_transcript(path: Path) -> list[dict]:
    try:
        records = [
            record for line in path.read_text(encoding="utf-8", errors="replace").splitlines()
            if (record := parse_record(line)) is not None
        ]
    except OSError:
        return []
    entries = {
        record["id"]: record for record in records
        if isinstance(record.get("id"), str)
    }
    leaf = next(
        (record for record in reversed(records) if isinstance(record.get("id"), str)),
        None,
    )
    branch = []
    visited = set()
    while isinstance(leaf, dict) and leaf.get("id") not in visited:
        identity = leaf["id"]
        visited.add(identity)
        branch.append(leaf)
        parent = leaf.get("parentId")
        leaf = entries.get(parent) if isinstance(parent, str) else None
    branch.reverse()
    messages = []
    for record in branch:
        message = text_of_message(record)
        if message is not None:
            messages.append({"role": message[0], "text": message[1]})
    return messages[-MAX_TRANSCRIPT_MESSAGES:]

MAX_FEED_EVENTS = 160


def journal_signature(path: Path) -> dict:
    stat = path.stat()
    with path.open("rb") as journal:
        head = journal.read(64)
    return {
        "device": stat.st_dev,
        "inode": stat.st_ino,
        "size": stat.st_size,
        "mtime_ns": stat.st_mtime_ns,
        "head": hashlib.sha256(head).hexdigest(),
    }


def event_text(content: object) -> str:
    if not isinstance(content, list):
        return ""
    return "\n".join(
        item["text"] for item in content
        if isinstance(item, dict) and item.get("type") == "text" and isinstance(item.get("text"), str)
    ).strip()

_TODO_PROGRESS = re.compile(r"Overall:\s*(\d+)\s*/\s*(\d+)\s+done\b")
_TODO_ACTIVE = re.compile(r"^\s*-\s+(.+?)\s+\[in_progress\]", re.MULTILINE)


def todo_update_event(event_base: dict, message: dict, text: str) -> dict | None:
    """Turn a completed todo tool call into a compact, terminal-owned snapshot."""
    if message.get("toolName") != "todo":
        return None
    progress = _TODO_PROGRESS.search(text)
    active = _TODO_ACTIVE.search(text)
    complete = "Remaining items: none." in text
    if progress is None and active is None and not complete:
        return None
    return {
        **event_base,
        "kind": "todo_update",
        "text": active.group(1) if active is not None else "",
        "completed": int(progress.group(1)) if progress is not None else None,
        "total": int(progress.group(2)) if progress is not None else None,
        "complete": complete,
    }


def choice_events(event_base: dict, identity: str, item: dict, index: int) -> list[dict]:
    """Expose harness-owned explicit prompts without submitting an answer."""
    arguments = item.get("arguments")
    questions = arguments.get("questions") if isinstance(arguments, dict) else None
    if not isinstance(questions, list):
        return []
    events = []
    for question_index, question in enumerate(questions):
        if not isinstance(question, dict) or not isinstance(question.get("question"), str):
            continue
        options = question.get("options")
        if not isinstance(options, list):
            continue
        choices = []
        for option in options:
            if isinstance(option, str) and option.strip():
                choices.append({"value": option.strip(), "label": option.strip()})
            elif isinstance(option, dict):
                value = option.get("value")
                label = option.get("label")
                if isinstance(value, str) and value and isinstance(label, str) and label:
                    choices.append({"value": value, "label": label})
                elif isinstance(label, str) and label:
                    choices.append({"value": label, "label": label})
        if choices:
            events.append({
                **event_base,
                "id": f"{identity}:choice:{index}:{question_index}",
                "kind": "choice",
                "tool": "ask",
                "text": question["question"],
                "choices": choices,
            })
    return events

def journal_events(record: dict) -> list[dict]:
    identity = record.get("id")
    if not isinstance(identity, str):
        return []
    timestamp = record.get("timestamp")
    event_base = {"id": identity, "timestamp": timestamp}
    if record.get("type") == "message":
        message = record.get("message")
        if not isinstance(message, dict):
            return []
        role = message.get("role")
        content = message.get("content")
        if role == "toolResult":
            text = event_text(content)
            todo_update = todo_update_event(event_base, message, text)
            if todo_update is not None:
                return [todo_update]
            return [{
                **event_base,
                "kind": "tool_output",
                "tool": message.get("toolName"),
                "text": text,
                "error": message.get("isError") is True,
            }] if text else []
        events = []
        text = event_text(content)
        if role in ("user", "assistant") and text:
            events.append({**event_base, "kind": role, "text": text})
        if role == "assistant" and isinstance(content, list):
            for index, item in enumerate(content):
                if not isinstance(item, dict):
                    continue
                if item.get("type") == "thinking" and isinstance(item.get("thinking"), str):
                    events.append({
                        **event_base,
                        "id": f"{identity}:thinking:{index}",
                        "kind": "thinking",
                        "text": item["thinking"],
                    })
                elif item.get("type") == "toolCall":
                    tool = item.get("name")
                    choices = choice_events(event_base, identity, item, index) if tool == "ask" else []
                    if choices:
                        events.extend(choices)
                    else:
                        events.append({
                            **event_base,
                            "id": f"{identity}:tool:{index}",
                            "kind": "todo" if tool == "todo" else "tool_call",
                            "tool": tool,
                            "text": item.get("intent") or tool or "tool",
                        })
        return events
    if record.get("type") == "custom":
        custom_type = record.get("customType")
        if custom_type == "tool_execution_start":
            data = record.get("data")
            if isinstance(data, dict):
                tool = data.get("toolName")
                return [{
                    **event_base,
                    "kind": "todo" if tool == "todo" else "tool_start",
                    "tool": tool,
                    "text": data.get("intent") or tool or "tool",
                }]
        if custom_type == "session_exit":
            data = record.get("data")
            detail = data.get("kind") if isinstance(data, dict) else None
            return [{**event_base, "kind": "session_exit", "text": detail or "completed"}]
    return []


def build_event_feed(path: Path, epoch: int = 1) -> dict:
    records = []
    offset = 0
    with path.open("rb") as journal:
        while True:
            start = journal.tell()
            line = journal.readline()
            if not line:
                break
            if not line.endswith(b"\n"):
                offset = start
                break
            offset = journal.tell()
            record = parse_record(line.decode("utf-8", errors="replace"))
            if record is not None:
                records.append(record)
    entries = {record["id"]: record for record in records if isinstance(record.get("id"), str)}
    leaf = next((record for record in reversed(records) if isinstance(record.get("id"), str)), None)
    branch_ids = set()
    while isinstance(leaf, dict) and isinstance(leaf.get("id"), str) and leaf["id"] not in branch_ids:
        branch_ids.add(leaf["id"])
        parent = leaf.get("parentId")
        leaf = entries.get(parent) if isinstance(parent, str) else None
    events = []
    revision = 0
    for record in records:
        if record.get("id") not in branch_ids:
            continue
        for event in journal_events(record):
            revision += 1
            event["sequence"] = revision
            events.append(event)
    signature = journal_signature(path)
    last_id = next((record["id"] for record in reversed(records) if isinstance(record.get("id"), str)), None)
    return {
        "path": str(path),
        "signature": signature,
        "offset": offset,
        "epoch": epoch,
        "revision": revision,
        "last_id": last_id,
        "events": events[-MAX_FEED_EVENTS:],
    }


def cached_event_feed(state: dict, path: Path) -> dict:
    try:
        signature = journal_signature(path)
    except OSError:
        return {"epoch": 0, "revision": 0, "events": []}
    feed = state.get("feed")
    if not isinstance(feed, dict) or feed.get("path") != str(path):
        feed = build_event_feed(path)
    elif feed.get("signature") == signature:
        return feed
    else:
        previous = feed.get("signature")
        offset = feed.get("offset")
        compatible = (
            isinstance(previous, dict) and isinstance(offset, int)
            and previous.get("device") == signature["device"] and previous.get("inode") == signature["inode"]
            and previous.get("head") == signature["head"] and 0 <= offset <= signature["size"]
        )
        if not compatible:
            feed = build_event_feed(path, int(feed.get("epoch", 0)) + 1)
        else:
            events = list(feed.get("events") or [])
            revision = int(feed.get("revision", 0))
            last_id = feed.get("last_id")
            complete_offset = offset
            branch_changed = False
            with path.open("rb") as journal:
                journal.seek(offset)
                while True:
                    start = journal.tell()
                    line = journal.readline()
                    if not line:
                        break
                    if not line.endswith(b"\n"):
                        complete_offset = start
                        break
                    complete_offset = journal.tell()
                    record = parse_record(line.decode("utf-8", errors="replace"))
                    if record is None:
                        continue
                    identity = record.get("id")
                    parent = record.get("parentId")
                    if (
                        isinstance(identity, str)
                        and isinstance(last_id, str)
                        and isinstance(parent, str)
                        and parent != last_id
                    ):
                        branch_changed = True
                        break
                    if isinstance(identity, str):
                        last_id = identity
                    for event in journal_events(record):
                        revision += 1
                        event["sequence"] = revision
                        events.append(event)
            if branch_changed:
                feed = build_event_feed(path, int(feed.get("epoch", 0)) + 1)
            else:
                feed = {
                    **feed,
                    "signature": signature,
                    "offset": complete_offset,
                    "revision": revision,
                    "last_id": last_id,
                    "events": events[-MAX_FEED_EVENTS:],
                }
    state["feed"] = feed
    return feed


def event_feed_payload(feed: dict, since: str | None = None) -> dict:
    epoch = int(feed.get("epoch", 0))
    revision = int(feed.get("revision", 0))
    token = f"{epoch}:{revision}"
    events = feed.get("events") if isinstance(feed.get("events"), list) else []
    if since == token:
        return {"revision": token, "unchanged": True}
    if isinstance(since, str):
        epoch_text, separator, revision_text = since.partition(":")
        try:
            known_epoch = int(epoch_text)
            known_revision = int(revision_text)
        except ValueError:
            known_epoch = -1
            known_revision = -1
        if separator and known_epoch == epoch and 0 <= known_revision <= revision:
            missing = [event for event in events if event.get("sequence", 0) > known_revision]
            if missing and missing[0].get("sequence") == known_revision + 1:
                return {"revision": token, "events": missing}
    return {"revision": token, "reset": True, "events": events}


def executable(name: str, override: str) -> str | None:
    configured = os.environ.get(override)
    if configured:
        return configured if Path(configured).exists() else shutil.which(configured)
    return shutil.which(name)


def run_json(command: list[str], timeout: int = 30) -> dict | None:
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, dict) else None


def omp_catalog(command: str) -> dict:
    default_model = None
    configured = run_json([command, "config", "get", "modelRoles", "--json"])
    if configured is not None:
        roles = configured.get("value")
        if isinstance(roles, dict) and isinstance(roles.get("default"), str):
            default_model = roles["default"]
    listed = run_json([command, "models", "--json"], timeout=60)
    models = []
    if listed is not None and isinstance(listed.get("models"), list):
        models = sorted({
            model["selector"] for model in listed["models"]
            if isinstance(model, dict) and isinstance(model.get("selector"), str)
        })
    if default_model and default_model not in models:
        models.insert(0, default_model)
    return {
        "id": "omp",
        "name": "Oh My Pi",
        "models": models,
        "default_model": default_model or (models[0] if models else None),
        "capabilities": {"new": True, "resume": True, "fork": True, "stream": True, "terminal": True},
    }


def hermes_default_model(command: str) -> str | None:
    try:
        result = subprocess.run(
            [command, "config", "get", "model"],
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    values = {}
    for line in result.stdout.splitlines():
        key, separator, value = line.partition(":")
        if separator:
            values[key.strip()] = value.strip().strip("'\"")
    provider = values.get("provider")
    model = values.get("default")
    if provider and model:
        return f"{provider}/{model}"
    return model or None


def hermes_catalog(command: str) -> dict:
    default_model = hermes_default_model(command)
    models = []
    try:
        value = json.loads((hermes_home() / "provider_models_cache.json").read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        value = {}
    if isinstance(value, dict):
        for provider, details in value.items():
            if not isinstance(provider, str) or not isinstance(details, dict):
                continue
            provider_models = details.get("models")
            if not isinstance(provider_models, list):
                continue
            models.extend(
                f"{provider}/{model}" for model in provider_models
                if isinstance(model, str) and model
            )
    models = sorted(set(models))
    if default_model and default_model not in models:
        models.insert(0, default_model)
    return {
        "id": "hermes",
        "name": "Hermes Agent",
        "models": models,
        "default_model": default_model or (models[0] if models else None),
        "capabilities": {"new": True, "resume": True, "fork": False, "stream": True, "terminal": True},
    }


def available_harnesses(*, refresh: bool = False) -> list[dict]:
    injected = os.environ.get("AGENTIK_CATALOG_JSON")
    if injected:
        try:
            value = json.loads(injected)
        except json.JSONDecodeError:
            return []
        return value if isinstance(value, list) else []

    cache_path = state_root() / "catalog.json"
    if not refresh:
        try:
            cached = json.loads(cache_path.read_text(encoding="utf-8"))
            if (
                isinstance(cached, dict)
                and time.time() - float(cached.get("created", 0)) < CATALOG_TTL_SECONDS
                and isinstance(cached.get("harnesses"), list)
            ):
                return cached["harnesses"]
        except (FileNotFoundError, json.JSONDecodeError, OSError, TypeError, ValueError):
            pass

    harnesses = []
    omp = executable("omp", "OMP_BIN")
    if omp:
        harnesses.append(omp_catalog(omp))
    hermes = executable("hermes", "HERMES_BIN")
    if hermes:
        harnesses.append(hermes_catalog(hermes))
    try:
        write_state(cache_path, {"created": time.time(), "harnesses": harnesses})
    except OSError:
        pass
    return harnesses


def harness_by_id(harness_id: str, harnesses: list[dict]) -> dict | None:
    return next((item for item in harnesses if item.get("id") == harness_id), None)
def live_stream(state: dict) -> dict | None:
    stream = state.get("stream")
    if not isinstance(stream, dict) or stream.get("state") not in ACTIVE_RUN_STATES:
        return None
    return stream


def stream_feed_payload(stream: dict, since: str | None = None) -> dict:
    sequence = int(stream.get("sequence", 0))
    token = f"run:{stream.get('run_id', '')}:{sequence}"
    events = stream.get("events") if isinstance(stream.get("events"), list) else []
    if since == token:
        return {"revision": token, "unchanged": True}
    if isinstance(since, str):
        prefix = f"run:{stream.get('run_id', '')}:"
        if since.startswith(prefix):
            try:
                known = int(since[len(prefix):])
            except ValueError:
                known = -1
            missing = [event for event in events if int(event.get("sequence", 0)) > known]
            if not missing or int(missing[0].get("sequence", 0)) == known + 1:
                return {"revision": token, "events": missing}
    return {"revision": token, "reset": True, "events": events}


def run_payload(state: dict) -> dict | None:
    stream = state.get("stream")
    if isinstance(stream, dict):
        return {
            key: stream.get(key)
            for key in ("run_id", "state", "started", "updated", "cancel_requested", "error")
        }
    last_run = state.get("last_run")
    return last_run if isinstance(last_run, dict) else None


def health_payload(harnesses: list[dict]) -> dict:
    root = state_root()
    available = [str(item.get("name") or item.get("id")) for item in harnesses]
    state_writable = root.exists() and os.access(root, os.W_OK)
    issues = []
    if not available:
        issues.append("Install Oh My Pi or Hermes Agent and ensure its executable is on PATH.")
    if not state_writable:
        issues.append(f"State directory is not writable: {root}")
    return {
        "ready": bool(available) and state_writable,
        "python": platform.python_version(),
        "state_dir": str(root),
        "state_writable": state_writable,
        "harnesses": available,
        "issues": issues,
    }


def public_result(
    state: dict,
    *,
    error: str | None = None,
    include_catalog: bool = True,
    since: str | None = None,
) -> dict:
    stream = live_stream(state)
    last_run = state.get("last_run")
    if error is None and isinstance(last_run, dict) and last_run.get("state") in ("failed", "orphaned"):
        last_error = last_run.get("error")
        if isinstance(last_error, str) and last_error:
            error = last_error
    harnesses = available_harnesses() if include_catalog else []

    def merged(result: dict) -> dict:
        result["run"] = run_payload(state)
        if stream is not None:
            result["busy"] = True
            result["messages"] = stream.get("messages") or result.get("messages") or []
            result["feed"] = stream_feed_payload(stream, since)
        return result

    selection = state.get("selection")
    result = {
        "ok": error is None,
        "error": error,
        "busy": False,
        "selected": False,
        "messages": [],
        "feed": None,
        "run": run_payload(state),
        "session_id": None,
        "session_path": None,
        "cwd": None,
        "title": None,
        "harness": None,
        "model": None,
        "mode": None,
        "active": False,
        "targets": list_targets() if include_catalog else [],
        "harnesses": harnesses,
        "health": health_payload(harnesses) if include_catalog else None,
    }
    if not isinstance(selection, dict):
        return merged(result)
    kind = selection.get("kind")
    harness = selection.get("harness", "omp")
    if kind == "new" and isinstance(selection.get("cwd"), str):
        harness_info = harness_by_id(harness, harnesses) if include_catalog else None
        result.update({
            "selected": True,
            "cwd": selection["cwd"],
            "title": f"New {(harness_info or {}).get('name', harness)} session",
            "harness": harness,
            "model": selection.get("model"),
            "messages": selection.get("messages", []),
        })
        return merged(result)
    if kind == "managed" and harness == "hermes":
        result.update({
            "selected": True,
            "messages": selection.get("messages", [])[-MAX_TRANSCRIPT_MESSAGES:],
            "session_id": selection.get("session_id"),
            "cwd": selection.get("cwd"),
            "title": selection.get("title") or "Hermes Agent session",
            "harness": harness,
            "model": selection.get("model"),
        })
        return merged(result)
    if kind != "existing" or not isinstance(selection.get("path"), str):
        return merged(result)
    path = Path(selection["path"])
    descriptor = session_descriptor(path)
    if descriptor is None:
        result["error"] = error or "selected session no longer exists"
        result["ok"] = False
        return merged(result)
    selection.update({
        "session_id": descriptor["id"],
        "title": descriptor["title"],
        "model": descriptor["model"],
        "active": descriptor["active"],
    })
    feed = cached_event_feed(state, path)
    result.update({
        "selected": True,
        "feed": event_feed_payload(feed),
        "session_id": descriptor["id"],
        "session_path": descriptor["path"],
        "cwd": descriptor["cwd"],
        "title": descriptor["title"],
        "harness": "omp",
        "model": descriptor["model"],
        "mode": selection.get("mode"),
        "active": descriptor["active"],
    })
    return merged(result)


def status_result(state: dict, since: str | None = None) -> dict:
    stream = live_stream(state)
    if stream is not None:
        return public_result(state, include_catalog=False, since=since)
    selection = state.get("selection")
    if not isinstance(selection, dict) or selection.get("kind") != "existing":
        return public_result(state, include_catalog=False, since=since)
    path_value = selection.get("path")
    if not isinstance(path_value, str):
        return public_result(state, error="selected session no longer exists", include_catalog=False)
    previous_feed = state.get("feed")
    feed = cached_event_feed(state, Path(path_value))
    if feed is not previous_feed:
        descriptor = session_descriptor(Path(path_value))
        if descriptor is None:
            return public_result(state, error="selected session no longer exists", include_catalog=False)
        selection.update({
            "session_id": descriptor["id"],
            "title": descriptor["title"],
            "model": descriptor["model"],
            "active": descriptor["active"],
        })
    result = public_result(state, include_catalog=False)
    result["feed"] = event_feed_payload(feed, since)
    return result


def persist_stream(state_path: Path, state: dict, stream: dict) -> bool:
    run_id = stream.get("run_id")
    if not isinstance(run_id, str):
        return False
    lock_path = state_path.with_name("chat.lock")
    with lock_path.open("a", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        current = read_state(state_path)
        current_stream = current.get("stream")
        if not isinstance(current_stream, dict) or current_stream.get("run_id") != run_id:
            return False
        sanitized = {
            **stream,
            "updated": time.time(),
            "messages": (stream.get("messages") or [])[-MAX_TRANSCRIPT_MESSAGES:],
            "events": (stream.get("events") or [])[-MAX_FEED_EVENTS:],
        }
        current["stream"] = sanitized
        write_state(state_path, current)
        state.clear()
        state.update(current)
        stream.clear()
        stream.update(sanitized)
        return True


def maybe_persist_stream(state_path: Path, state: dict, stream: dict, last_write: float) -> float:
    now = time.monotonic()
    if now - last_write < STREAM_WRITE_INTERVAL_SECONDS:
        return last_write
    persist_stream(state_path, state, stream)
    return now


def append_live_event(stream: dict, kind: str, text: str = "", **data) -> None:
    events = stream.setdefault("events", [])
    previous = events[-1] if events else None
    if kind == "assistant" and isinstance(previous, dict):
        if previous.get("kind") == "assistant" and previous.get("text") == text:
            return
        if previous.get("kind") == "assistant_delta":
            kind = "assistant"
    sequence = int(stream.get("sequence", 0)) + 1
    stream["sequence"] = sequence
    event = {
        "id": f"{stream.get('run_id', 'run')}:{sequence}",
        "sequence": sequence,
        "timestamp": time.time(),
        "kind": kind,
        "text": text,
    }
    event.update(data)
    if isinstance(previous, dict) and (
        (kind == "assistant_delta" and previous.get("kind") == "assistant_delta")
        or (kind == "assistant" and previous.get("kind") == "assistant_delta")
    ):
        if kind == "assistant_delta":
            event["text"] = str(previous.get("text") or "") + text
        events[-1] = event
    else:
        events.append(event)
    stream["events"] = events[-MAX_FEED_EVENTS:]


def begin_stream(state: dict, selection: dict, message: str) -> dict:
    history: list[dict] = []
    if selection.get("kind") == "existing" and isinstance(selection.get("path"), str):
        history = session_transcript(Path(selection["path"]))
    elif isinstance(selection.get("messages"), list):
        history = selection["messages"]
    now = time.time()
    stream = {
        "run_id": str(uuid.uuid4()),
        "state": "starting",
        "busy": True,
        "started": now,
        "updated": now,
        "cancel_requested": False,
        "error": None,
        "sequence": 0,
        "events": [],
        "messages": [*history[-MAX_TRANSCRIPT_MESSAGES:], {"role": "user", "text": message}],
    }
    append_live_event(stream, "run_started", "Starting agent")
    append_live_event(stream, "user", message)
    state["last_run"] = None
    state["stream"] = stream
    return stream


def append_stream_message(stream: dict, role: str, text: str, *, open_chunk: bool = False) -> None:
    messages = stream.setdefault("messages", [])
    if messages and messages[-1].get("role") == role and not open_chunk:
        messages[-1]["text"] = text
    else:
        messages.append({"role": role, "text": text})


def ensure_stream_assistant(stream: dict) -> None:
    messages = stream.setdefault("messages", [])
    if not messages or messages[-1].get("role") != "assistant":
        messages.append({"role": "assistant", "text": ""})


def update_omp_stream(stream: dict, event: dict, text_open: bool) -> bool:
    kind = event.get("type")
    if kind == "message_start":
        message = event.get("message")
        if isinstance(message, dict) and message.get("role") == "assistant":
            append_live_event(stream, "assistant_started", "")
        return text_open
    if kind == "message_update":
        assistant_event = event.get("assistantMessageEvent")
        if not isinstance(assistant_event, dict):
            return text_open
        kind2 = assistant_event.get("type")
        if kind2 == "text_start":
            append_stream_message(stream, "assistant", "", open_chunk=True)
            append_live_event(stream, "assistant_started", "")
            return True
        if kind2 == "text_delta":
            delta = assistant_event.get("delta")
            if isinstance(delta, str) and delta:
                ensure_stream_assistant(stream)
                stream["messages"][-1]["text"] = (stream["messages"][-1].get("text") or "") + delta
                append_live_event(stream, "assistant_delta", delta)
            return text_open
        if kind2 == "text_end":
            ensure_stream_assistant(stream)
            content = assistant_event.get("content")
            if isinstance(content, str):
                stream["messages"][-1]["text"] = content
                append_live_event(stream, "assistant", content)
            return False
        return text_open
    if kind == "message_end":
        pair = text_of_message({"type": "message", "message": event.get("message")})
        if pair is not None and pair[0] == "assistant":
            append_stream_message(stream, pair[0], pair[1])
            append_live_event(stream, "assistant", pair[1])
        return text_open
    for normalized in journal_events(event):
        append_live_event(
            stream,
            normalized.get("kind", "event"),
            normalized.get("text", ""),
            **{
                key: value
                for key, value in normalized.items()
                if key not in ("id", "sequence", "timestamp", "kind", "text")
            },
        )
    return text_open


def finish_stream(
    state_path: Path,
    state: dict,
    run_id: str,
    *,
    error: str | None = None,
) -> dict:
    with state_path.with_name("chat.lock").open("a", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        current = read_state(state_path)
        stream = current.get("stream")
        if not isinstance(stream, dict) or stream.get("run_id") != run_id:
            return public_result(current, error="run was superseded", include_catalog=False)
        terminal_state = "cancelled" if stream.get("cancel_requested") else ("failed" if error else "completed")
        if error:
            append_live_event(stream, "run_failed", error, error=True)
        else:
            append_live_event(stream, f"run_{terminal_state}", terminal_state)
        ended = time.time()
        current["last_run"] = {
            "run_id": run_id,
            "state": terminal_state,
            "started": stream.get("started"),
            "updated": ended,
            "ended": ended,
            "error": error,
        }
        if error is None and terminal_state == "completed":
            current["selection"] = state["selection"]
        current["stream"] = None
        result = public_result(current, error=error, include_catalog=False)
        write_state(state_path, current)
    return result


def parse_session_id(output: str) -> str | None:
    session_id = None
    for line in output.splitlines():
        event = parse_record(line)
        if event is not None and event.get("type") == "session" and isinstance(event.get("id"), str):
            session_id = event["id"]
    return session_id


def locate_session(session_id: str) -> Path | None:
    root = sessions_root()
    matches = list(root.rglob(f"*_{session_id}.jsonl")) if root.exists() else []
    return max(matches, key=lambda path: path.stat().st_mtime, default=None)


def omp_command(selection: dict, message: str) -> list[str]:
    command = [os.environ.get("OMP_BIN", "omp"), "-p", "--mode", "json", "--hide-thinking"]
    if selection.get("kind") == "existing":
        option = "--fork" if selection.get("mode") == "fork" else "--resume"
        command.extend([option, selection["path"]])
    else:
        command.extend(["--cwd", selection["cwd"]])
        if isinstance(selection.get("model"), str) and selection["model"]:
            command.extend(["--model", selection["model"]])
    command.extend(["--max-time", "600", message])
    return command


def hermes_command(selection: dict, message: str) -> list[str]:
    command = [os.environ.get("HERMES_BIN", "hermes")]
    if selection.get("kind") == "managed" and selection.get("session_id"):
        command.extend(["--resume", selection["session_id"]])
    command.extend(["--oneshot", message])
    model = selection.get("model")
    if isinstance(model, str) and "/" in model:
        provider, model_id = model.split("/", 1)
        command.extend(["--provider", provider, "--model", model_id])
    elif isinstance(model, str) and model:
        command.extend(["--model", model])
    return command


def hermes_session_rows() -> dict[str, dict]:
    database = hermes_home() / "state.db"
    try:
        connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True, timeout=2)
        rows = connection.execute(
            "SELECT id, cwd, model, title, last_activity_at FROM sessions WHERE source = 'cli'"
        ).fetchall()
        connection.close()
    except (OSError, sqlite3.Error):
        return {}
    return {
        row[0]: {"cwd": row[1], "model": row[2], "title": row[3], "modified": row[4] or 0}
        for row in rows if isinstance(row[0], str)
    }


def process_group_alive(process_group: int) -> bool:
    try:
        os.killpg(process_group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def cancel_stream(state_path: Path, state: dict) -> dict:
    stream = live_stream(state)
    if stream is None:
        return public_result(state, error="no coding session is running")
    run_id = stream["run_id"]
    stream["cancel_requested"] = True
    stream["state"] = "cancelling"
    stream["updated"] = time.time()
    append_live_event(stream, "run_cancel_requested", "Cancelling agent")
    write_state(state_path, state)
    process_group = stream.get("process_group")
    process_start = stream.get("process_start_time")
    process_pid = stream.get("pid")
    identity_matches = (
        isinstance(process_pid, int)
        and isinstance(process_start, str)
        and process_start_time(process_pid) == process_start
    )
    if isinstance(process_group, int) and identity_matches:
        try:
            os.killpg(process_group, signal.SIGTERM)
            deadline = time.monotonic() + CANCEL_GRACE_SECONDS
            while process_group_alive(process_group) and time.monotonic() < deadline:
                time.sleep(0.05)
            if process_group_alive(process_group):
                os.killpg(process_group, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except OSError as error:
            return public_result(state, error=str(error))
    ended = time.time()
    state["last_run"] = {
        "run_id": run_id,
        "state": "cancelled",
        "started": stream.get("started"),
        "updated": ended,
        "ended": ended,
        "error": None,
    }
    state["stream"] = None
    write_state(state_path, state)
    return public_result(state, include_catalog=False)


def send_omp(state: dict, selection: dict, message: str, run_id: str) -> dict:
    if selection["kind"] == "existing":
        descriptor = session_descriptor(Path(selection.get("path", "")))
        if descriptor is None:
            return finish_stream(state_root() / "state.json", state, run_id, error="selected session no longer exists")
        if selection.get("mode") != "fork":
            if not descriptor["resumable"]:
                return finish_stream(
                    state_root() / "state.json",
                    state,
                    run_id,
                    error="session is no longer resumable; select it again to fork it",
                )
            selection["signature"] = descriptor["signature"]
    state_path = state_root() / "state.json"
    stream = state.get("stream")
    if not isinstance(stream, dict) or stream.get("run_id") != run_id:
        return public_result(state, error="run was superseded", include_catalog=False)
    out_lines: list[str] = []
    text_open = False
    last_write = time.monotonic()
    process = None
    try:
        process = subprocess.Popen(
            omp_command(selection, message),
            cwd=selection.get("cwd") or None,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env={**os.environ, "NO_COLOR": "1"},
            start_new_session=False,
        )
        assert process.stdout is not None
        with process.stdout:
            for line in process.stdout:
                out_lines.append(line)
                event = parse_record(line)
                if event is not None:
                    text_open = update_omp_stream(stream, event, text_open)
                last_write = maybe_persist_stream(state_path, state, stream, last_write)
        returncode = process.wait(timeout=630)
        if returncode != 0:
            detail = [line.strip() for line in out_lines if line.strip() and not line.lstrip().startswith("{")]
            raise RuntimeError(detail[-1] if detail else f"OMP exited with status {returncode}")
        if selection["kind"] == "new" or selection.get("mode") == "fork":
            session_id = parse_session_id("".join(out_lines))
            path = locate_session(session_id) if session_id else None
            if path is None:
                raise RuntimeError("OMP session journal was not created")
            selection = {"kind": "existing", "harness": "omp", "path": str(path), "mode": "resume"}
            state["selection"] = selection
        descriptor = session_descriptor(Path(selection["path"]))
        if descriptor is None:
            raise RuntimeError("OMP session journal could not be read")
        selection.update({
            "signature": descriptor["signature"],
            "session_id": descriptor["id"],
            "title": descriptor["title"],
            "model": descriptor["model"],
            "active": descriptor["active"],
        })
    except subprocess.TimeoutExpired:
        if process is not None:
            process.kill()
            process.wait()
        return finish_stream(state_path, state, run_id, error="command timed out")
    except (OSError, RuntimeError) as error:
        return finish_stream(state_path, state, run_id, error=str(error))
    return finish_stream(state_path, state, run_id)


def send_hermes(state: dict, selection: dict, message: str, run_id: str) -> dict:
    before = hermes_session_rows() if selection.get("kind") == "new" else {}
    state_path = state_root() / "state.json"
    stream = state.get("stream")
    if not isinstance(stream, dict) or stream.get("run_id") != run_id:
        return public_result(state, error="run was superseded", include_catalog=False)
    out_lines: list[str] = []
    last_write = time.monotonic()
    process = None
    try:
        process = subprocess.Popen(
            hermes_command(selection, message),
            cwd=selection.get("cwd") or None,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env={**os.environ, "NO_COLOR": "1"},
            start_new_session=False,
        )
        assert process.stdout is not None
        with process.stdout:
            for line in process.stdout:
                out_lines.append(line)
                line = line.rstrip("\n")
                if line.strip():
                    messages = stream.setdefault("messages", [])
                    if messages and messages[-1].get("role") == "assistant":
                        messages[-1]["text"] = (messages[-1].get("text") or "") + line + "\n"
                    else:
                        messages.append({"role": "assistant", "text": line + "\n"})
                    append_live_event(stream, "assistant_delta", line + "\n")
                last_write = maybe_persist_stream(state_path, state, stream, last_write)
        returncode = process.wait(timeout=630)
        if returncode != 0:
            detail = [line.strip() for line in out_lines if line.strip() and not line.lstrip().startswith("{")]
            raise RuntimeError(detail[-1] if detail else f"Hermes exited with status {returncode}")
        response = "".join(out_lines).strip()
        if not response:
            raise RuntimeError("Hermes returned an empty response")
        if selection.get("kind") == "new":
            after = hermes_session_rows()
            candidates = [
                (identity, details) for identity, details in after.items()
                if identity not in before and details.get("cwd") == selection.get("cwd")
            ]
            if not candidates:
                candidates = [(identity, details) for identity, details in after.items() if identity not in before]
            if not candidates:
                raise RuntimeError("Hermes session was not created")
            session_id, details = max(candidates, key=lambda item: item[1].get("modified", 0))
            selection = {
                "kind": "managed",
                "harness": "hermes",
                "session_id": session_id,
                "cwd": selection["cwd"],
                "model": selection.get("model"),
                "title": details.get("title") or "Hermes Agent session",
                "messages": [],
            }
            state["selection"] = selection
        messages = selection.setdefault("messages", [])
        messages.extend([
            {"role": "user", "text": message},
            {"role": "assistant", "text": response},
        ])
        selection["messages"] = messages[-MAX_TRANSCRIPT_MESSAGES:]
    except subprocess.TimeoutExpired:
        if process is not None:
            process.kill()
            process.wait()
        return finish_stream(state_path, state, run_id, error="command timed out")
    except (OSError, RuntimeError) as error:
        return finish_stream(state_path, state, run_id, error=str(error))
    return finish_stream(state_path, state, run_id)


class HarnessAdapter:
    id = ""

    def run(self, state: dict, selection: dict, message: str, run_id: str) -> dict:
        raise NotImplementedError


class OmpHarnessAdapter(HarnessAdapter):
    id = "omp"

    def run(self, state: dict, selection: dict, message: str, run_id: str) -> dict:
        return send_omp(state, selection, message, run_id)


class HermesHarnessAdapter(HarnessAdapter):
    id = "hermes"

    def run(self, state: dict, selection: dict, message: str, run_id: str) -> dict:
        return send_hermes(state, selection, message, run_id)


HARNESS_ADAPTERS = {
    adapter.id: adapter
    for adapter in (OmpHarnessAdapter(), HermesHarnessAdapter())
}


def process_start_time(pid: int) -> str | None:
    try:
        fields = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8").split()
    except (FileNotFoundError, OSError, UnicodeError):
        return None
    return fields[21] if len(fields) > 21 else None


def run_selected(state: dict, message: str, run_id: str) -> dict:
    selection = state.get("selection")
    if not isinstance(selection, dict) or selection.get("kind") not in ("new", "existing", "managed"):
        return finish_stream(state_root() / "state.json", state, run_id, error="select or start a session first")
    harness = selection.get("harness", "omp")
    adapter = HARNESS_ADAPTERS.get(harness)
    if adapter is None:
        return finish_stream(
            state_root() / "state.json",
            state,
            run_id,
            error=f"unsupported harness: {harness}",
        )
    return adapter.run(state, selection, message, run_id)


def worker_log_path(run_id: str) -> Path:
    return state_root() / "runs" / f"{run_id}.log"


def start_send(state_path: Path, state: dict, message: str) -> dict:
    selection = state.get("selection")
    if not isinstance(selection, dict) or selection.get("kind") not in ("new", "existing", "managed"):
        return public_result(state, error="select or start a session first")
    stream = begin_stream(state, selection, message)
    run_id = stream["run_id"]
    write_state(state_path, state)
    log_path = worker_log_path(run_id)
    log_path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    worker_args = [
        sys.executable,
        str(Path(__file__).resolve()),
        "_worker",
        run_id,
        message.encode("utf-8").hex(),
    ]
    try:
        with log_path.open("ab") as worker_log, Path(os.devnull).open("rb") as devnull:
            os.fchmod(worker_log.fileno(), 0o600)
            worker_pid = os.posix_spawn(
                sys.executable,
                worker_args,
                os.environ.copy(),
                file_actions=[
                    (os.POSIX_SPAWN_DUP2, devnull.fileno(), 0),
                    (os.POSIX_SPAWN_DUP2, worker_log.fileno(), 1),
                    (os.POSIX_SPAWN_DUP2, worker_log.fileno(), 2),
                ],
                setsid=True,
            )
    except OSError as error:
        ended = time.time()
        state["last_run"] = {
            "run_id": run_id,
            "state": "failed",
            "started": stream["started"],
            "updated": ended,
            "ended": ended,
            "error": str(error),
        }
        state["stream"] = None
        write_state(state_path, state)
        return public_result(state, error=str(error), include_catalog=False)
    stream["pid"] = worker_pid
    stream["process_group"] = worker_pid
    stream["process_start_time"] = process_start_time(worker_pid)
    stream["state"] = "running"
    stream["updated"] = time.time()
    write_state(state_path, state)
    return public_result(state, include_catalog=False)


def run_worker(run_id: str, message_hex: str) -> int:
    try:
        message = decode_message(message_hex)
    except ValueError:
        return 2
    state_path = state_root() / "state.json"
    with state_path.with_name("chat.lock").open("a", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = read_state(state_path)
        stream = state.get("stream")
        if not isinstance(stream, dict) or stream.get("run_id") != run_id:
            return 0
        stream["state"] = "running"
        stream["updated"] = time.time()
        write_state(state_path, state)
    run_selected(state, message, run_id)
    return 0


TERMINAL_EXEC_ARGS: dict[str, tuple[str, ...]] = {
    "xdg-terminal-exec": (),
    "kitty": (),
    "kgx": (),
    "gnome-terminal": ("--",),
}


def terminal_emulator() -> str | None:
    override = os.environ.get("AGENTIK_TERMINAL")
    if override:
        return override
    for candidate in (
        "xdg-terminal-exec",
        "ghostty",
        "kitty",
        "foot",
        "alacritty",
        "gnome-terminal",
        "kgx",
        "konsole",
    ):
        if shutil.which(candidate):
            return candidate
    return None


def harness_terminal_command(selection: dict) -> list[str] | None:
    kind = selection.get("kind")
    harness = selection.get("harness", "omp")
    if kind == "existing":
        path = selection.get("path")
        if not isinstance(path, str) or not path:
            return None
        option = "--fork" if selection.get("mode") == "fork" else "--resume"
        return [executable("omp", "OMP_BIN") or "omp", option, path]
    if kind == "managed" and harness == "hermes":
        session_id = selection.get("session_id")
        if not isinstance(session_id, str) or not session_id:
            return None
        return [executable("hermes", "HERMES_BIN") or "hermes", "--resume", session_id]
    if kind == "new":
        if harness == "hermes":
            command = [executable("hermes", "HERMES_BIN") or "hermes"]
        else:
            command = [executable("omp", "OMP_BIN") or "omp"]
        model = selection.get("model")
        if isinstance(model, str) and model:
            if harness == "hermes" and "/" in model:
                provider, model_id = model.split("/", 1)
                command.extend(["--provider", provider, "--model", model_id])
            else:
                command.extend(["--model", model])
        return command
    return None



def open_in_terminal(state: dict) -> dict:
    selection = state.get("selection")
    if not isinstance(selection, dict) or selection.get("kind") not in ("new", "existing", "managed"):
        return public_result(state, error="select or start a session first")
    if live_stream(state) is not None:
        return public_result(state, error="a panel coding session is running; open the terminal after it finishes or cancel it")
    terminal = terminal_emulator()
    if terminal is None:
        return public_result(state, error="no terminal emulator found (set AGENTIK_TERMINAL)")
    command = harness_terminal_command(selection)
    if command is None:
        return public_result(state, error="this session cannot be opened in a terminal")
    argv = [
        terminal, *TERMINAL_EXEC_ARGS.get(terminal, ("-e",)),
        "sh", "-c", '"$@"; read -rp "Press Enter to close"', "agentik-open", *command,
    ]
    try:
        subprocess.Popen(
            argv, cwd=selection.get("cwd") or None, stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
        )
    except OSError as error:
        return public_result(state, error=str(error))
    result = public_result(state)
    result["launched"] = True
    result["terminal"] = terminal
    return result


def monitored_session_selection(session_id: str) -> dict:
    """Return a safe chat selection for an id emitted by the session monitor."""
    if not session_id or len(session_id) > MAX_MODEL_CHARS:
        raise ValueError("invalid session id")
    if session_id.startswith("hermes:"):
        hermes_id = session_id.removeprefix("hermes:")
        details = hermes_session_rows().get(hermes_id)
        if details is None:
            raise ValueError("Hermes session is no longer available")
        return {
            "kind": "managed",
            "harness": "hermes",
            "session_id": hermes_id,
            "cwd": details.get("cwd"),
            "model": details.get("model"),
            "title": details.get("title"),
            "messages": [],
        }
    if not all(character.isalnum() or character in "-_." for character in session_id):
        raise ValueError("invalid session id")
    path = locate_session(session_id)
    if path is None:
        raise ValueError("OMP session is no longer available")
    descriptor = session_descriptor(session_path(str(path)))
    if descriptor is None:
        raise ValueError("session could not be read")
    return {
        "kind": "existing",
        "harness": "omp",
        "path": descriptor["path"],
        "mode": "resume" if descriptor["resumable"] else "fork",
        "cwd": descriptor["cwd"],
        "signature": descriptor["signature"],
    }


def decode_new_selection(value_hex: str, harness_hex: str | None, model_hex: str | None) -> dict:
    cwd = str(Path(decode_value(value_hex)).expanduser().resolve())
    harnesses = available_harnesses()
    harness = decode_value(harness_hex) if harness_hex else (harnesses[0].get("id") if harnesses else "")
    details = harness_by_id(harness, harnesses)
    if details is None:
        raise ValueError("selected harness is not available")
    model = decode_value(model_hex) if model_hex else details.get("default_model")
    if not isinstance(model, str) or not model or len(model) > MAX_MODEL_CHARS or "\0" in model:
        raise ValueError("model name must be between 1 and 256 characters")
    return {"kind": "new", "harness": harness, "model": model, "cwd": cwd, "messages": []}


def recover_orphaned_run(state_path: Path, state: dict) -> bool:
    stream = live_stream(state)
    if stream is None:
        return False
    pid = stream.get("pid")
    expected_start = stream.get("process_start_time")
    age = max(0.0, time.time() - float(stream.get("started", time.time())))
    if pid is None and age < STARTUP_GRACE_SECONDS:
        return False
    if (
        isinstance(pid, int)
        and isinstance(expected_start, str)
        and process_start_time(pid) == expected_start
    ):
        return False
    error = "agent process ended before reporting a final result"
    append_live_event(stream, "run_orphaned", error, error=True)
    ended = time.time()
    state["last_run"] = {
        "run_id": stream.get("run_id"),
        "state": "orphaned",
        "started": stream.get("started"),
        "updated": ended,
        "ended": ended,
        "error": error,
    }
    state["stream"] = None
    write_state(state_path, state)
    return True




def dispatch(
    action: str, value_hex: str | None = None, harness_hex: str | None = None,
    model_hex: str | None = None,
) -> dict:
    root = state_root()
    root.mkdir(parents=True, mode=0o700, exist_ok=True)
    root.chmod(0o700)
    state_path = root / "state.json"
    lock_path = root / "chat.lock"
    with lock_path.open("a", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = read_state(state_path)
        recover_orphaned_run(state_path, state)
        if action == "cancel":
            return cancel_stream(state_path, state)
        if action == "reset":
            if live_stream(state) is not None:
                return public_result(state, error="cancel the running session before switching")
            state = empty_state()
            write_state(state_path, state)
            return public_result(state)
        if action == "load":
            result = public_result(state)
            if state.get("feed") is not None:
                write_state(state_path, state)
            return result
        if action == "refresh":
            try:
                (root / "catalog.json").unlink()
            except FileNotFoundError:
                pass
            available_harnesses(refresh=True)
            return public_result(state)
        if action == "open":
            return open_in_terminal(state)
        if action == "status":
            try:
                since = decode_value(value_hex) if value_hex is not None else None
            except ValueError:
                return public_result(state, error="invalid feed revision")
            before_feed = state.get("feed")
            result = status_result(state, since)
            if state.get("feed") is not before_feed:
                write_state(state_path, state)
            return result
        if value_hex is None:
            return public_result(state, error="missing value")
        if live_stream(state) is not None:
            return public_result(state, error="a coding session is already running")
        if action == "new":
            try:
                selection = decode_new_selection(value_hex, harness_hex, model_hex)
            except ValueError as error:
                return public_result(state, error=str(error))
            if not Path(selection["cwd"]).is_dir():
                return public_result(state, error="project directory does not exist")
            state["selection"] = selection
            state.pop("feed", None)
            write_state(state_path, state)
            return public_result(state)
        if action == "select":
            try:
                path = session_path(decode_value(value_hex))
            except ValueError as error:
                return public_result(state, error=str(error))
            descriptor = session_descriptor(path)
            if descriptor is None:
                return public_result(state, error="session could not be read")
            state["selection"] = {
                "kind": "existing",
                "harness": "omp",
                "path": str(path),
                "mode": "resume" if descriptor["resumable"] else "fork",
                "cwd": descriptor["cwd"],
                "signature": descriptor["signature"],
                "session_id": descriptor["id"],
                "title": descriptor["title"],
                "model": descriptor["model"],
                "active": descriptor["active"],
            }
            state.pop("feed", None)
            result = public_result(state)
            write_state(state_path, state)
            return result
        if action == "select-id":
            try:
                state["selection"] = monitored_session_selection(decode_value(value_hex))
            except ValueError as error:
                return public_result(state, error=str(error))
            state.pop("feed", None)
            result = public_result(state)
            write_state(state_path, state)
            return result
        if action == "send":
            try:
                message = decode_message(value_hex)
            except ValueError as error:
                return public_result(state, error=str(error))
            return start_send(state_path, state, message)
        return public_result(state, error=f"unknown action: {action}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action",
        choices=(
            "load", "send", "reset", "refresh", "new", "select", "select-id",
            "open", "status", "cancel", "_worker",
        ),
    )
    parser.add_argument("values", nargs="*")
    args = parser.parse_args()
    if args.action == "_worker":
        if len(args.values) != 2:
            parser.error("_worker requires RUN_ID and MESSAGE_HEX")
        return run_worker(args.values[0], args.values[1])
    values = args.values + [None, None, None]
    result = dispatch(args.action, values[0], values[1], values[2])
    json.dump(result, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
