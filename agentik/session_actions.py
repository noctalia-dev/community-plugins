#!/usr/bin/env python3
"""Read-only tool activity and identity-checked focus of existing terminals."""
from __future__ import annotations

from collections import OrderedDict
from contextlib import closing
from dataclasses import dataclass
import json
import os
from pathlib import Path
import sqlite3
import subprocess

MAX_OPERATIONS = 12
PROC_ROOT = Path("/proc")
_JOURNALS: OrderedDict[str, dict] = OrderedDict()


def _bridge():
    # chat_bridge dispatches back into this module; do not import it eagerly.
    import chat_bridge
    return chat_bridge


def _compact(value: object, limit: int = 160) -> str:
    return " ".join(value.split())[:limit] if isinstance(value, str) else ""


def normalize_tools(records: list[dict], live: bool) -> list[dict]:
    """Correlate actual call IDs, never infer completion from assistant prose."""
    operations: OrderedDict[str, dict] = OrderedDict()
    for record in records:
        identity = str(record.get("id", ""))
        timestamp = record.get("timestamp")
        message = record.get("message")
        candidates = []
        if (isinstance(message, dict) and message.get("role") == "user") or record.get("customType") == "session_exit":
            for operation in operations.values():
                if operation["status"] == "running":
                    operation["status"] = "unknown"
        if isinstance(message, dict):
            if message.get("role") == "assistant":
                content = message.get("content")
                if isinstance(content, list):
                    for index, item in enumerate(content):
                        if isinstance(item, dict) and item.get("type") == "toolCall":
                            candidates.append((item.get("id"), f"{identity}:{index}", item.get("name"), item.get("intent"), None))
            elif message.get("role") == "toolResult":
                candidates.append((message.get("toolCallId"), identity, message.get("toolName"), None, message))
        if record.get("type") == "custom":
            data = record.get("data")
            if record.get("customType") == "tool_execution_start" and isinstance(data, dict):
                candidates.append((data.get("toolCallId"), identity, data.get("toolName"), data.get("intent"), None))
        for call_id, fallback, tool, intent, result in candidates:
            key = "tool:" + (call_id if isinstance(call_id, str) and call_id else "record:" + fallback)
            operation = operations.get(key)
            if operation is None:
                operation = {"id": key, "kind": "tool", "tool": _compact(tool, 72) or "tool", "text": _compact(intent) or _compact(tool, 72) or "Tool operation", "status": "running", "timestamp": timestamp}
                operations[key] = operation
            elif intent:
                operation["text"] = _compact(intent)
            if result is not None:
                # Explicit isError:false or a recorded OMP result is completion.
                # Hermes outputs without a native error flag retain unknown status.
                error = result.get("isError")
                operation["status"] = "failed" if error is True else "unknown" if result.get("statusUnknown") else "completed"
                detail = _compact(result.get("activityText") or _bridge().event_text(result.get("content")), 320)
                if detail:
                    operation["detail"] = detail
                operation["timestamp"] = timestamp
    values = list(operations.values())[-MAX_OPERATIONS:]
    if not live:
        for operation in values:
            if operation["status"] == "running":
                operation["status"] = "unknown"
    return values


def _slim_record(record: dict) -> dict:
    slim = {key: record[key] for key in ("id", "parentId", "timestamp", "type", "customType", "title") if key in record}
    message = record.get("message")
    if isinstance(message, dict) and message.get("role") in ("assistant", "toolResult"):
        if message["role"] == "toolResult":
            slim["message"] = {key: message[key] for key in ("role", "toolName", "toolCallId", "isError") if key in message}
            slim["message"]["activityText"] = _compact(_bridge().event_text(message.get("content")), 320)
        else:
            content = message.get("content")
            slim["message"] = {"role": "assistant", "content": [
                {key: item[key] for key in ("type", "id", "name", "intent") if key in item}
                for item in content if isinstance(item, dict) and item.get("type") == "toolCall"
            ] if isinstance(content, list) else []}
    elif isinstance(message, dict) and message.get("role") == "user":
        slim["message"] = {"role": "user"}
    data = record.get("data")
    if isinstance(data, dict) and slim.get("customType") in ("tool_execution_start", "session_exit"):
        slim["data"] = {key: data[key] for key in ("toolCallId", "toolName", "intent", "kind") if key in data}
    return slim


def _journal_branch(path: Path) -> list[dict]:
    """Incrementally retain identities and compact tool data, not transcript bytes."""
    signature = _bridge().journal_signature(path)
    key = str(path)
    cache = _JOURNALS.get(key)
    compatible = cache and all(cache["signature"].get(field) == signature.get(field) for field in ("device", "inode", "head")) and cache["offset"] <= signature["size"]
    if not compatible:
        cache = {"signature": signature, "offset": 0, "records": OrderedDict()}
    with path.open("rb") as journal:
        journal.seek(cache["offset"])
        while True:
            start = journal.tell()
            line = journal.readline()
            if not line or not line.endswith(b"\n"):
                cache["offset"] = start
                break
            record = _bridge().parse_record(line.decode("utf-8", errors="replace"))
            if isinstance(record, dict) and isinstance(record.get("id"), str):
                cache["records"][record["id"]] = _slim_record(record)
    cache["signature"] = signature
    _JOURNALS[key] = cache
    _JOURNALS.move_to_end(key)
    while len(_JOURNALS) > 4:
        _JOURNALS.popitem(last=False)
    entries = cache["records"]
    leaf = next(reversed(entries.values()), None)
    branch = []
    seen = set()
    while leaf is not None and leaf["id"] not in seen:
        seen.add(leaf["id"])
        branch.append(leaf)
        leaf = entries.get(leaf.get("parentId"))
    branch.reverse()
    return branch


def _hermes_records(session_id: str) -> list[dict]:
    database = (_bridge().hermes_home() / "state.db").resolve()
    with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=2)) as connection:
        rows = connection.execute("SELECT id, role, substr(content, 1, 512), tool_call_id, tool_calls, tool_name, timestamp FROM messages WHERE session_id = ? AND (role IN ('user', 'tool') OR tool_calls IS NOT NULL) ORDER BY id", (session_id,)).fetchall()
    records = []
    for identity, role, content, call_id, calls, tool, timestamp in rows:
        message = {"role": "assistant", "content": []}
        if role == "assistant" and calls:
            try:
                calls = json.loads(calls) if isinstance(calls, str) else calls
            except (ValueError, TypeError):
                calls = []
            if isinstance(calls, list):
                for call in calls:
                    if isinstance(call, dict) and isinstance(call.get("function"), dict):
                        message["content"].append({"type": "toolCall", "id": call.get("id"), "name": call["function"].get("name")})
        elif role == "tool":
            # The Hermes DB has no native isError field. Do not parse result prose.
            message = {"role": "toolResult", "toolCallId": call_id, "toolName": tool, "activityText": _compact(content, 320), "statusUnknown": True}
        elif role == "user":
            message = {"role": "user"}
        else:
            continue
        records.append({"id": str(identity), "timestamp": timestamp, "message": message})
    return records


@dataclass(frozen=True)
class Process:
    pid: int
    ppid: int
    start: str
    argv: tuple[str, ...]
    comm: str
    tty: str | None


def _process(pid: int) -> Process | None:
    path = PROC_ROOT / str(pid)
    try:
        if path.stat().st_uid != os.getuid():
            return None
        raw = (path / "stat").read_text()
        # comm can contain spaces and parentheses; fields after the last ')' are stable.
        fields = raw[raw.rfind(")") + 2:].split()
        if fields[0] == "Z":
            return None
        argv = tuple(os.fsdecode(item) for item in (path / "cmdline").read_bytes().split(b"\0") if item)
        try:
            tty = os.readlink(path / "fd/0")
        except OSError:
            tty = None
        if tty is None or not tty.startswith("/dev/pts/") or not tty.removeprefix("/dev/pts/").isdigit():
            tty = None
        return Process(pid, int(fields[1]), fields[19], argv, (path / "comm").read_text().strip(), tty)
    except (OSError, ValueError, IndexError):
        return None


def _harness_process(process: Process, harness: str) -> bool:
    if harness == "omp":
        return process.comm == "omp" or bool(process.argv and Path(process.argv[0]).name == "omp")
    return any(Path(argument).name == "hermes" for argument in process.argv[:3])


def _same_user_file(path: Path) -> bool:
    return path.stat().st_uid == os.getuid()


def _started_at(process: Process) -> float:
    boot = next(float(line.split()[1]) for line in (PROC_ROOT / "stat").read_text().splitlines() if line.startswith("btime "))
    return boot + int(process.start) / os.sysconf("SC_CLK_TCK")


def _owns(process: Process, selection: dict) -> bool:
    harness = selection.get("harness", "omp")
    if not _harness_process(process, harness):
        return False
    if harness == "omp":
        journal = Path(selection["path"]).resolve()
        try:
            for descriptor in (PROC_ROOT / str(process.pid) / "fd").iterdir():
                if descriptor.resolve() == journal:
                    return True
        except OSError:
            pass
        if process.tty:
            crumb = Path.home() / ".omp/agent/terminal-sessions" / ("pts-" + process.tty.rsplit("/", 1)[-1])
            try:
                lines = crumb.read_text().splitlines() if _same_user_file(crumb) else []
                return len(lines) >= 2 and crumb.stat().st_mtime >= _started_at(process) and Path(lines[1]).expanduser().resolve() == journal
            except (OSError, ValueError, StopIteration):
                pass
        return False
    session_id = selection.get("session_id")
    if session_id == f"pid:{process.pid}":
        return True
    if not process.tty:
        return False
    crumb = _bridge().hermes_home() / "terminal-sessions" / ("tty-" + process.tty.strip("/").replace("/", "-"))
    try:
        data = json.loads(crumb.read_text()) if _same_user_file(crumb) else {}
        # A TTY may have been recycled since an old breadcrumb was recorded.
        return isinstance(data, dict) and data.get("session_id") == session_id and isinstance(data.get("ts"), (int, float)) and data["ts"] >= _started_at(process)
    except (OSError, ValueError, StopIteration):
        return False


def _owners(selection: dict) -> list[Process]:
    owners = []
    for path in PROC_ROOT.iterdir():
        if path.name.isdigit():
            process = _process(int(path.name))
            if process is not None and _owns(process, selection):
                owners.append(process)
    return owners


def _selection(session_id: str) -> dict:
    if not session_id or len(session_id) > 256:
        raise ValueError("invalid session id")
    if session_id.startswith("hermes:pid:"):
        pid = session_id.removeprefix("hermes:pid:")
        if not pid.isascii() or not pid.isdigit() or int(pid) <= 0:
            raise ValueError("invalid Hermes process id")
        return {"harness": "hermes", "session_id": f"pid:{int(pid)}"}
    return _bridge().monitored_session_selection(session_id)


def activity(session_id: str) -> dict:
    try:
        selection = _selection(session_id)
        if selection.get("harness") == "hermes":
            records = [] if selection["session_id"].startswith("pid:") else _hermes_records(selection["session_id"])
        else:
            records = _journal_branch(Path(selection["path"]))
        events = normalize_tools(records, bool(_owners(selection)))
        return {"ok": True, "session_id": session_id, "events": events}
    except (OSError, ValueError, sqlite3.Error) as error:
        return {"ok": False, "session_id": session_id, "events": [], "error": str(error)}


def _compositor_windows() -> tuple[str, list[dict]]:
    if os.environ.get("NIRI_SOCKET"):
        compositor, command = "niri", ["niri", "msg", "--json", "windows"]
    elif os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        compositor, command = "hyprland", ["hyprctl", "clients", "-j"]
    else:
        raise ValueError("Terminal focus supports Niri and Hyprland only")
    result = subprocess.run(command, capture_output=True, text=True, timeout=5, check=True)
    windows = json.loads(result.stdout)
    if not isinstance(windows, list):
        raise ValueError("Compositor returned invalid window identities")
    return compositor, [window for window in windows if isinstance(window, dict)]


def _ancestor_chain(owner: Process) -> list[Process]:
    chain = []
    process = owner
    seen = set()
    while process is not None and process.pid not in seen:
        seen.add(process.pid)
        chain.append(process)
        if process.comm in ("tmux: server", "tmux", "zellij"):
            raise ValueError("Terminal ownership is ambiguous through a multiplexer")
        process = _process(process.ppid)
    return chain


def _choose_window(owner: Process, windows: list[dict], title: str | None = None) -> tuple[dict, list[Process], str]:
    chain = _ancestor_chain(owner)
    for ancestor in chain:
        matches = [window for window in windows if type(window.get("pid")) is int and window["pid"] == ancestor.pid]
        if not matches:
            continue
        if len(matches) == 1:
            return matches[0], chain[:chain.index(ancestor) + 1], "unique-process-ancestry"
        # No title substring, cwd, workspace, or current-focus heuristic is proof.
        exact = [window for window in matches if (title and window.get("title") == title) or (owner.tty and window.get("tty") == owner.tty)]
        if len(exact) == 1:
            return exact[0], chain[:chain.index(ancestor) + 1], "process-ancestry-exact-title-or-tty"
        raise ValueError("Terminal ownership is ambiguous: shared process has multiple windows")
    raise ValueError("No compositor window belongs to the live session process")


def focus_session(session_id: str) -> dict:
    try:
        selection = _selection(session_id)
        owners = _owners(selection)
        if not owners:
            raise ValueError("Session has exited or its owning terminal cannot be proven")
        if len(owners) != 1:
            raise ValueError("Session ownership is ambiguous: multiple live processes")
        compositor, windows = _compositor_windows()
        owner = owners[0]
        title = selection.get("title")
        if selection.get("harness") == "omp":
            records = _journal_branch(Path(selection["path"]))
            title = next((record.get("title") for record in reversed(records) if record.get("type") in ("title", "title_change") and isinstance(record.get("title"), str)), None)
        window, chain, confidence = _choose_window(owner, windows, title)
        # Catch exits, reparenting and PID reuse before invoking focus.
        if any(_process(process.pid) != process for process in chain) or not _owns(owner, selection):
            raise ValueError("Session process identity changed before focus")
        if compositor == "niri":
            identity = window.get("id")
            if type(identity) is not int or identity < 0:
                raise ValueError("Invalid Niri window identity")
            command = ["niri", "msg", "action", "focus-window", "--id", str(identity)]
        else:
            identity = window.get("address")
            if not isinstance(identity, str) or not identity.startswith("0x") or not identity[2:] or any(character not in "0123456789abcdefABCDEF" for character in identity[2:]):
                raise ValueError("Invalid Hyprland window identity")
            command = ["hyprctl", "dispatch", "focuswindow", "address:" + identity]
        result = subprocess.run(command, capture_output=True, text=True, timeout=5, check=True)
        if compositor == "hyprland" and result.stdout.strip() != "ok":
            raise ValueError("Hyprland did not acknowledge focus: " + _compact(result.stdout, 160))
        return {"ok": True, "focused": True, "session_id": session_id, "confidence": confidence, "compositor": compositor, "window_id": identity}
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        return {"ok": False, "focused": False, "session_id": session_id, "error": str(error)}
