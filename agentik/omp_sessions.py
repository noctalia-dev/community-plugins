#!/usr/bin/env python3
"""Read local OMP journals and live Hermes processes without modifying them."""

from __future__ import annotations

import datetime
import hashlib
import json
import os
import re
import sqlite3
import sys
import time
from contextlib import closing
from pathlib import Path

PILL_IDLE_SECONDS = 5 * 60
ACTIVE_SECONDS = 120
EXITED_WINDOW_SECONDS = 600
PAUSED_RETENTION_SECONDS = EXITED_WINDOW_SECONDS
JOURNALS = Path.home() / ".omp/agent/sessions"
HERMES_DB = Path.home() / ".hermes/state.db"

CACHE_PATH = Path(os.environ.get(
    "AGENTIK_JOURNAL_INDEX",
    Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "agentik/journal-index.json",
))


def excluded_projects(encoded: str | None = None) -> set[str]:
    if encoded is None:
        value = os.environ.get("AGENTIK_EXCLUDED_PROJECTS", "")
    else:
        try:
            value = bytes.fromhex(encoded).decode("utf-8")
        except (ValueError, UnicodeDecodeError) as error:
            raise ValueError("invalid excluded-project encoding") from error
    return {item.strip() for item in value.split(",") if item.strip()}


def tail_lines(path: Path, limit: int = 96) -> list[str]:
    with path.open("rb") as journal:
        journal.seek(0, 2)
        size = journal.tell()
        journal.seek(max(0, size - 65_536))
        return journal.read().decode("utf-8", errors="replace").splitlines()[-limit:]


def local_project_directory(value: str) -> str | None:
    """Accept only absolute filesystem paths from model-authored tool records."""
    if "\0" in value:
        return None
    try:
        candidate = Path(value).expanduser()
        if not candidate.is_absolute():
            return None
        return str(candidate.resolve(strict=False))
    except (OSError, RuntimeError):
        return None


def tool_cwd(record: dict) -> str | None:
    message = record.get("message")
    if not isinstance(message, dict):
        return None
    content = message.get("content")
    if not isinstance(content, list):
        return None
    for item in reversed(content):
        if item.get("type") != "toolCall":
            continue
        arguments = item.get("arguments")
        if isinstance(arguments, dict) and isinstance(arguments.get("cwd"), str):
            return local_project_directory(arguments["cwd"])
    return None


_CHOICE_CUE = re.compile(r"\b(choose|choice|option|prefer|select|which)\b", re.IGNORECASE)
_NUMBERED_CHOICE = re.compile(r"^\s*(\d+)[.)]\s+(.+?)\s*$", re.MULTILINE)


def get_propositions(record: dict) -> list[dict[str, str]] | None:
    """Return explicit or clearly marked, contiguous assistant choices."""
    data = record.get("data")
    raw_options = data.get("propositions", data.get("options")) if isinstance(data, dict) else None
    if isinstance(raw_options, list):
        choices = []
        for index, option in enumerate(raw_options, start=1):
            if isinstance(option, str) and option.strip():
                choices.append({"value": str(index), "label": option.strip()[:144]})
            elif isinstance(option, dict):
                value = option.get("value")
                label = option.get("label")
                if isinstance(value, str) and value and isinstance(label, str) and label:
                    choices.append({"value": value[:72], "label": label[:144]})
        return choices or None

    message = record.get("message")
    if not isinstance(message, dict) or message.get("role") != "assistant":
        return None
    content = message.get("content")
    if not isinstance(content, list):
        return None
    text = "\n".join(
        item["text"] for item in content
        if isinstance(item, dict) and isinstance(item.get("text"), str)
    )

    blocks: list[list[re.Match[str]]] = []
    for match in _NUMBERED_CHOICE.finditer(text):
        if blocks and text[blocks[-1][-1].end():match.start()].strip() == "":
            blocks[-1].append(match)
        else:
            blocks.append([match])
    for block in blocks:
        if len(block) < 2:
            continue
        if [match.group(1) for match in block] != [str(index) for index in range(1, len(block) + 1)]:
            continue
        start = max(0, block[0].start() - 240)
        end = min(len(text), block[-1].end() + 240)
        if not _CHOICE_CUE.search(text[start:end]):
            continue
        return [
            {"value": match.group(1), "label": match.group(2).strip()[:144]}
            for match in block
        ]
    return None

def todo_snapshot(record: dict) -> tuple[str | None, str, int | None, int | None, bool] | None:
    message = record.get("message")
    if not isinstance(message, dict) or message.get("role") != "toolResult":
        return None
    if message.get("toolName") != "todo":
        return None
    content = message.get("content")
    if not isinstance(content, list):
        return None

    text = "\n".join(
        item["text"] for item in content
        if isinstance(item, dict) and isinstance(item.get("text"), str)
    )
    match = re.search(r"Overall:\s*(\d+)\s*/\s*(\d+)\s+done\b", text)
    completed = int(match.group(1)) if match else None
    total = int(match.group(2)) if match else None
    if "Remaining items: none." in text:
        return None, "active", completed, total, False
    active = re.search(r"^\s*-\s+(.+?)\s+\[in_progress\]", text, re.MULTILINE)
    if active:
        return active.group(1), "active", completed, total, True
    blocked = re.search(r"^\s*-\s+(.+?)\s+\(blocked:", text, re.MULTILINE)
    if blocked:
        return blocked.group(1), "blocked", completed, total, False
    return None, "active", completed, total, False

def activity_state(activity: str) -> str:
    normalized = activity.lower()
    states = (
        ("connecting", ("connect", "network", "http", "download", "upload", "fetch")),
        ("solving", ("test", "validat", "debug", "diagnos", "verif", "fix", "check", "prov", "compar")),
        ("searching", ("search", "research", "locat", "find", "inspect", "read", "list", "inventor", "audit", "map")),
        ("composing", ("writ", "edit", "implement", "create", "build", "generat", "apply", "update", "patch", "optim")),
        ("weaving", ("merg", "coordinat", "integrat", "synchron", "publish", "push", "releas")),
        ("breathing", ("idle", "complet", "done", "finish", "pause", "sleep")),
        ("listening", ("wait", "listen", "input", "prompt", "ask")),
        ("shaping", ("design", "plan", "refactor", "structure", "scaffold", "model")),
    )
    for state, keywords in states:
        if any(keyword in normalized for keyword in keywords):
            return state
    return "working"


def parse_timestamp(value: object) -> float | None:
    if not isinstance(value, str):
        return None
    try:
        return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def empty_metadata() -> dict:
    return {
        "activity": "Working", "cwd": None, "task": None, "attention": "active",
        "propositions": None, "todo_completed": None, "todo_total": None,
        "todo_active": False, "first_ts": None, "last_ts": None, "agent": None,
        "model": None, "turn_status": "running", "termination": None,
    }


def apply_record(metadata: dict, record: dict) -> None:
    message = record.get("message")
    if isinstance(message, dict):
        role = message.get("role")
        if role == "user":
            metadata["propositions"] = None
            metadata["turn_status"] = "running"
            metadata["termination"] = None
        elif role == "assistant":
            stop_reason = message.get("stopReason")
            if stop_reason == "stop":
                metadata["turn_status"] = "waiting"
            elif stop_reason == "error":
                metadata["turn_status"] = "failed"
            elif stop_reason == "aborted":
                metadata["turn_status"] = "cancelled"
            elif stop_reason == "toolUse":
                metadata["turn_status"] = "running"
    epoch = parse_timestamp(record.get("timestamp"))
    if epoch is not None:
        metadata["first_ts"] = epoch if metadata["first_ts"] is None else min(metadata["first_ts"], epoch)
        metadata["last_ts"] = epoch if metadata["last_ts"] is None else max(metadata["last_ts"], epoch)
    candidate_cwd = tool_cwd(record)
    if candidate_cwd:
        metadata["cwd"] = candidate_cwd
    data = record.get("data")
    if isinstance(data, dict):
        if isinstance(data.get("intent"), str) and data["intent"]:
            metadata["activity"] = data["intent"]
            metadata["turn_status"] = "running"
            metadata["termination"] = None
        kind = data.get("kind")
        if kind == "fatal":
            metadata["termination"] = "failed"
        elif kind == "signal":
            metadata["termination"] = "cancelled"
        elif kind == "normal" and data.get("reason") == "dispose":
            metadata["termination"] = "completed"
    snapshot = todo_snapshot(record)
    if snapshot is not None:
        (metadata["task"], metadata["attention"], metadata["todo_completed"],
         metadata["todo_total"], metadata["todo_active"]) = snapshot
        if metadata["attention"] == "blocked":
            metadata["turn_status"] = "blocked"
        elif metadata["todo_active"]:
            metadata["turn_status"] = "running"
    propositions = get_propositions(record)
    if propositions:
        metadata["propositions"] = propositions
    record_type = record.get("type")
    if record_type in ("session", "title", "title_change"):
        title = record.get("title")
        if isinstance(title, str) and title:
            metadata["agent"] = title
    elif record_type == "model_change":
        model = record.get("model")
        if isinstance(model, str) and model:
            metadata["model"] = model


class JournalIndex:
    """Persist only parsed session metadata and consume appended journal bytes."""

    def __init__(self, path: Path):
        self.path = path
        try:
            loaded = json.loads(path.read_text(encoding="utf-8"))
            self.entries = (
                loaded.get("entries", {})
                if isinstance(loaded, dict) and loaded.get("version") == 2
                else {}
            )
        except (FileNotFoundError, OSError, json.JSONDecodeError):
            self.entries = {}
        self.original = json.dumps(
            {"version": 2, "entries": self.entries},
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )

    def metadata(self, journal_path: Path) -> dict:
        stat = journal_path.stat()
        key = str(journal_path.resolve())
        entry = self.entries.get(key)
        if (
            isinstance(entry, dict)
            and entry.get("device") == stat.st_dev
            and entry.get("inode") == stat.st_ino
            and entry.get("size") == stat.st_size
            and entry.get("mtime_ns") == stat.st_mtime_ns
            and isinstance(entry.get("metadata"), dict)
        ):
            return dict(entry["metadata"])
        with journal_path.open("rb") as journal:
            head = hashlib.sha256(journal.read(1024)).hexdigest()
        reusable = (
            isinstance(entry, dict)
            and entry.get("device") == stat.st_dev
            and entry.get("inode") == stat.st_ino
            and entry.get("head") == head
            and isinstance(entry.get("offset"), int)
            and 0 <= entry["offset"] <= stat.st_size
            and isinstance(entry.get("metadata"), dict)
        )
        metadata = dict(entry["metadata"]) if reusable else empty_metadata()
        offset = entry["offset"] if reusable else 0
        with journal_path.open("rb") as journal:
            journal.seek(offset)
            data = journal.read()
        complete = data.rfind(b"\n")
        if complete >= 0:
            for line in data[:complete].decode("utf-8", errors="replace").splitlines():
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(record, dict):
                    apply_record(metadata, record)
            offset += complete + 1
        self.entries[key] = {
            "device": stat.st_dev,
            "inode": stat.st_ino,
            "head": head,
            "size": stat.st_size,
            "mtime_ns": stat.st_mtime_ns,
            "offset": offset,
            "metadata": metadata,
        }
        return metadata

    def prune_and_save(self, existing: set[str]) -> None:
        self.entries = {key: value for key, value in self.entries.items() if key in existing}
        serialized = json.dumps(
            {"version": 2, "entries": self.entries},
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        if serialized == self.original:
            return
        self.path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
        try:
            self.path.parent.chmod(0o700)
            temporary = self.path.with_suffix(".tmp")
            temporary.write_text(serialized, encoding="utf-8")
            temporary.chmod(0o600)
            temporary.replace(self.path)
        except OSError:
            pass


def metadata_from_journal(path: Path) -> dict:
    metadata = empty_metadata()
    with path.open("r", encoding="utf-8", errors="replace") as journal:
        for line in journal:
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(record, dict):
                apply_record(metadata, record)
    return metadata


def running_omp_journals() -> set[str]:
    """Return journals held open by this user's interactive OMP processes."""
    journals: set[str] = set()
    uid = os.getuid()
    for process in Path("/proc").iterdir():
        if not process.name.isdigit():
            continue
        try:
            if process.stat().st_uid != uid:
                continue
            arguments = process.joinpath("cmdline").read_bytes().split(b"\0")
            if not arguments or Path(arguments[0].decode("utf-8", errors="ignore")).name != "omp":
                continue
            for descriptor in process.joinpath("fd").iterdir():
                target = str(descriptor.resolve())
                if "/.omp/agent/sessions/" in target and target.endswith(".jsonl"):
                    journals.add(target)
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
    return journals


def session(
    path: Path,
    now: float,
    index: JournalIndex | None = None,
    live: bool | None = None,
) -> dict | None:
    stat = path.stat()
    age = now - stat.st_mtime
    exited = None
    if live is False:
        if age > EXITED_WINDOW_SECONDS:
            return None
        exited = max(0, int(age))
    elif live is None and age > ACTIVE_SECONDS:
        if age > EXITED_WINDOW_SECONDS:
            return None
        exited = int(age)

    metadata = index.metadata(path) if index is not None else metadata_from_journal(path)
    activity = metadata["activity"]
    attention = metadata["attention"]
    status = metadata["turn_status"]
    if live is False or exited is not None:
        status = metadata["termination"] or (
            status if status in {"failed", "cancelled"} else "completed"
        )
    elif attention == "blocked":
        status = "blocked"
    if status == "waiting" or (attention == "active" and activity_state(activity) == "listening"):
        attention = "waiting"
    state = activity_state(activity)
    if status in {"blocked", "waiting"}:
        state = "listening"
    elif status in {"completed", "failed", "cancelled"}:
        state = "done"
    duration = max(0, int(now - metadata["first_ts"])) if metadata["first_ts"] is not None else max(0, int(age))
    quiet = (
        exited is None
        and status == "running"
        and attention == "active"
        and age > PILL_IDLE_SECONDS
    )
    if quiet and age > PAUSED_RETENTION_SECONDS:
        return None
    cwd = metadata["cwd"]
    return {
        "id": path.stem.rsplit("_", 1)[-1], "project": Path(cwd).name if cwd else "terminal",
        "cwd": cwd, "activity": activity[:72], "task": metadata["task"][:72] if metadata["task"] else None,
        "state": state, "status": status, "attention": attention,
        "duration": duration, "idle": max(0, int(age)),
        "quiet": quiet,
        "exited": exited,
        "agent": metadata["agent"][:72] if metadata["agent"] else None,
        "model": metadata["model"][:72] if metadata["model"] else None,
        "todo_completed": metadata["todo_completed"], "todo_total": metadata["todo_total"],
        "todo_active": metadata["todo_active"], "propositions": metadata["propositions"],
        "started_at": metadata["first_ts"], "last_activity_at": metadata["last_ts"],
        "harness": "omp",
    }


def running_hermes_processes() -> list[tuple[int, str | None]]:
    """Return the current user's interactive Hermes processes and their cwd."""
    processes = []
    uid = os.getuid()
    for process in Path("/proc").iterdir():
        if not process.name.isdigit():
            continue
        try:
            if process.stat().st_uid != uid:
                continue
            arguments = process.joinpath("cmdline").read_bytes().split(b"\0")
            if not any(Path(argument.decode("utf-8", errors="ignore")).name == "hermes" for argument in arguments):
                continue
            cwd = str(process.joinpath("cwd").resolve())
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        processes.append((int(process.name), cwd))
    return processes


def active_hermes_sessions(now: float) -> list[dict]:
    """Represent live Hermes processes using their latest unclosed local session."""
    processes = running_hermes_processes()
    if not processes:
        return []

    rows: list[sqlite3.Row] = []
    try:
        with closing(sqlite3.connect(f"{HERMES_DB.as_uri()}?mode=ro", uri=True)) as connection:
            connection.row_factory = sqlite3.Row
            rows = connection.execute(
                """
                SELECT id, title, model, cwd, started_at, last_activity_at, last_activity_description
                FROM sessions
                WHERE ended_at IS NULL AND archived = 0
                ORDER BY last_activity_at DESC
                LIMIT ?
                """,
                (len(processes),),
            ).fetchall()
    except (OSError, sqlite3.Error):
        rows = []

    sessions = []
    unused = {row["id"]: row for row in rows if isinstance(row["id"], str)}
    for pid, process_cwd in processes:
        row = next(
            (
                candidate for candidate in unused.values()
                if isinstance(candidate["cwd"], str) and candidate["cwd"] == process_cwd
            ),
            None,
        )
        if row is not None:
            unused.pop(row["id"], None)
        if row is None and len(processes) == 1 and len(rows) == 1:
            row = rows[0]
            if isinstance(row["id"], str):
                unused.pop(row["id"], None)
        cwd = row["cwd"] if row is not None and isinstance(row["cwd"], str) and row["cwd"] else process_cwd
        title = row["title"] if row is not None and isinstance(row["title"], str) and row["title"] else None
        model = row["model"] if row is not None and isinstance(row["model"], str) and row["model"] else None
        activity = (
            row["last_activity_description"]
            if row is not None and isinstance(row["last_activity_description"], str)
                and row["last_activity_description"]
            else "Running Hermes Agent"
        )
        started_at = row["started_at"] if row is not None else now
        try:
            duration = max(0, int(now - float(started_at)))
        except (TypeError, ValueError):
            duration = 0
        sessions.append({
            "id": f"hermes:{row['id']}" if row is not None else f"hermes:pid:{pid}",
            "project": Path(cwd).name if cwd else "terminal",
            "cwd": cwd,
            "activity": activity[:72],
            "task": title[:72] if title else None,
            "state": activity_state(activity),
            "status": "running",
            "attention": "active",
            "duration": duration,
            "idle": 0,
            "quiet": False,
            "exited": None,
            "agent": "Hermes Agent",
            "model": model[:72] if model else None,
            "todo_completed": None,
            "todo_total": None,
            "todo_active": False,
            "propositions": None,
            "harness": "hermes",
        })
    return sessions

def main(encoded_excluded_projects: str | None = None) -> None:
    now = time.time()
    active_items = []
    quiet_items = []
    exited_items = []
    index = JournalIndex(CACHE_PATH)
    existing = set()
    excluded = excluded_projects(encoded_excluded_projects)
    live_journals = running_omp_journals()
    if JOURNALS.exists():
        for path in JOURNALS.rglob("*.jsonl"):
            resolved = str(path.resolve())
            existing.add(resolved)
            # An absent journal FD can be a normal gap between OMP writes. Let
            # session() apply its short grace window before declaring exit.
            liveness = True if resolved in live_journals else None
            item = session(path, now, index, live=liveness)
            if item is None:
                continue
            if item["project"] in excluded or (item["cwd"] and item["cwd"] in excluded):
                continue
            if item["exited"] is not None:
                exited_items.append(item)
            elif item["quiet"]:
                quiet_items.append(item)
            else:
                active_items.append(item)
    index.prune_and_save(existing)
    active_items.extend(active_hermes_sessions(now))
    active_items.sort(key=lambda item: item["duration"])
    quiet_items.sort(key=lambda item: item["idle"])
    exited_items.sort(key=lambda item: item["exited"])
    history_slots = max(0, 8 - len(active_items))
    sessions = active_items + (quiet_items + exited_items)[:history_slots]
    print(json.dumps({"active": len(active_items), "sessions": sessions}))


if __name__ == "__main__":
    if len(sys.argv) > 2:
        raise SystemExit("usage: omp_sessions.py [excluded-projects-hex]")
    main(sys.argv[1] if len(sys.argv) == 2 else None)
