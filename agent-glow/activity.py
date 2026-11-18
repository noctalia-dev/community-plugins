#!/usr/bin/env python3
"""Agent Glow session probe — real agent data, not guesswork.

Claude Code: live `claude --resume <uuid>` processes are joined to their
transcripts (~/.claude/projects/*/<uuid>.jsonl). The transcript mtime is the
activity signal (every reply, tool result, and compaction appends to it);
the first user message becomes the session name; the process cwd is the
project. No hooks required, works for already-running sessions.

opencode: sessions come straight from opencode.db (session_v2): real titles,
directories, and time_updated. A session is live while any opencode process
runs and hot while recently updated.

CPU sampling remains as a fallback signal for anything unmatched.

Output (stdout, one JSON object):

  {"sessions": [{"family", "key", "name", "project", "last_active",
                 "cpu", "hot_by"}], "groups": {...}, "hot": [...]}
"""

import argparse
import glob
import json
import os
import re
import sqlite3
import stat
import sys
import tempfile
import time

NCORES = os.cpu_count() or 1
STATE_ENV = "XDG_RUNTIME_DIR"
STATE_NAME = "agent-glow-activity.json"
STATE_FORMAT = 2
MAX_CMDLINE = 200
MAX_STATE_AGE = 30
OCODE_DB = os.path.expanduser("~/.local/share/opencode/opencode.db")
CLAUDE_PROJECTS = os.path.expanduser("~/.claude/projects")
MAX_NAME_LEN = 80


def default_state_path():
    """State lives only in the user's runtime dir, never in shared /tmp.

    Without XDG_RUNTIME_DIR there is no private place to write, so the probe
    does not persist anything rather than drop a world-readable cache of
    process data into a world-writable directory.
    """
    runtime = os.environ.get(STATE_ENV)
    if not runtime:
        return None
    return os.path.join(runtime, STATE_NAME)


# ── /proc snapshots (CPU fallback) ──────────────────────────────────────────

def read_total_jiffies():
    with open("/proc/stat") as handle:
        parts = handle.readline().split()[1:]
    return sum(int(field) for field in parts)


def read_stat(pid):
    try:
        with open(f"/proc/{pid}/stat") as handle:
            fields = handle.read().rsplit(")", 1)[1].split()
        return int(fields[11]) + int(fields[12]), int(fields[1])
    except (OSError, ValueError, IndexError):
        return None


def read_cmdline(pid):
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as handle:
            raw = handle.read().replace(b"\0", b" ").decode("utf-8", "replace").strip()
        return raw[:MAX_CMDLINE]
    except OSError:
        return None


def read_cwd(pid):
    try:
        return os.readlink(f"/proc/{pid}/cwd")
    except OSError:
        return ""


def own_family(cmdline, patterns):
    """The first configured pattern this pid's own cmdline matches, else ''."""
    lowered = cmdline.lower()
    for pattern in patterns:
        if pattern in lowered:
            return pattern
    return ""


def snapshot(known=None, patterns=()):
    """jiffies+ppid for every pid, plus that pid's own matched agent family.

    Only the resolved family is kept, never the raw command line: cmdlines can
    carry secrets (tokens passed as arguments), and the state cache is written
    to disk. Reusing the cached family for known pids halves /proc reads.
    """
    if known is None:
        known = {}
    self_pid = str(os.getpid())
    procs = {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit() or pid == self_pid:
            continue
        stats = read_stat(pid)
        if stats is None:
            continue
        cached = known.get(pid)
        if cached is not None and len(cached) == 3 and cached[2] is not None:
            procs[pid] = [stats[0], stats[1], cached[2]]
            continue
        cmdline = read_cmdline(pid)
        if not cmdline:
            continue
        procs[pid] = [stats[0], stats[1], own_family(cmdline, patterns)]
    return {"ts": time.time(), "total": read_total_jiffies(), "procs": procs}


def family_of(pid, procs):
    """Walk up to the nearest ancestor (or self) with a matched family."""
    seen = set()
    depth = 0
    current = pid
    while current and current != "0" and current not in seen and depth < 16:
        seen.add(current)
        entry = procs.get(current)
        if entry is None:
            return None
        if entry[2]:
            return entry[2]
        current = str(entry[1])
        depth += 1
    return None


def cpu_by_pid(before, after):
    """Per-pid CPU in % of one core between two snapshots."""
    result = {}
    elapsed = after["total"] - before["total"]
    if elapsed <= 0:
        return result
    for pid, entry in after["procs"].items():
        old = before["procs"].get(pid)
        if old is None:
            continue
        pct = 100.0 * (entry[0] - old[0]) * NCORES / elapsed
        if pct > 0:
            result[pid] = round(pct, 1)
    return result


# ── state file ──────────────────────────────────────────────────────────────

def load_state(path):
    if not path:
        return None
    try:
        info = os.lstat(path)
        if not stat.S_ISREG(info.st_mode):
            return None  # symlink, fifo, or anything that is not a real file
        with open(path) as handle:
            state = json.load(handle)
        if not isinstance(state, dict) or state.get("v") != STATE_FORMAT:
            return None
        if not isinstance(state.get("procs"), dict):
            return None
        if time.time() - float(state.get("ts", 0)) > MAX_STATE_AGE:
            return None
        return state
    except (OSError, ValueError, TypeError):
        return None


def save_state(path, snap):
    if not path:
        return
    tmp = None
    try:
        directory = os.path.dirname(path) or "."
        fd, tmp = tempfile.mkstemp(dir=directory, prefix=".agent-glow-", suffix=".tmp")
        with os.fdopen(fd, "w") as handle:
            json.dump(snap, handle)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)  # replaces a planted symlink at `path`, never follows it
        tmp = None
    except OSError:
        pass
    finally:
        if tmp is not None:
            try:
                os.unlink(tmp)
            except OSError:
                pass


# ── Claude transcripts ──────────────────────────────────────────────────────

RESUME_RE = re.compile(r"--resume\s+([0-9a-fA-F-]{8,})")


def extract_prompt_text(obj):
    """Best-effort first-user-message text from a transcript line object."""
    try:
        message = obj.get("message", {})
        content = message.get("content", "")
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            texts = [b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text"]
            return "\n".join(t for t in texts if t)
    except (AttributeError, TypeError):
        pass
    return ""


TAG_RE = re.compile(r"<[a-zA-Z][^>]*>.*?</[a-zA-Z][^>]*>|<[a-zA-Z][^>/]*/>|<command-name>.*", re.DOTALL)


def clean_prompt(text):
    text = TAG_RE.sub(" ", text)
    return " ".join(text.split())


def first_prompt(path):
    found = 0
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            for _ in range(4000):
                line = handle.readline()
                if not line:
                    break
                try:
                    obj = json.loads(line)
                except ValueError:
                    continue
                if obj.get("type") == "user":
                    text = clean_prompt(extract_prompt_text(obj))
                    if text:
                        return text[:MAX_NAME_LEN]
                    found += 1
                    if found >= 5:
                        break
    except OSError:
        pass
    return ""


def find_transcript(uuid, cached_path=None):
    if cached_path:
        try:
            real = os.path.realpath(cached_path)
            base = os.path.realpath(CLAUDE_PROJECTS)
            if (
                os.path.isfile(real)
                and os.path.basename(real) == uuid + ".jsonl"
                and os.path.commonpath([real, base]) == base
            ):
                return real
        except (OSError, ValueError):
            pass
    if not re.fullmatch(r"[0-9a-fA-F-]{8,}", uuid or ""):
        return None
    matches = glob.glob(os.path.join(CLAUDE_PROJECTS, "*", uuid + ".jsonl"))
    return matches[0] if matches else None


def collect_claude(procs, cpu, names_cache):
    """Live claude processes joined to transcripts -> session dicts."""
    sessions = []
    for pid, entry in procs.items():
        cmdline = entry[2]
        if "claude" not in cmdline.lower():
            continue
        match = RESUME_RE.search(cmdline)
        uuid = match.group(1) if match else None
        if uuid is None:
            continue
        cached = names_cache.get(uuid, {})
        path = find_transcript(uuid, cached.get("path"))
        if path is None:
            continue
        try:
            last_active = os.path.getmtime(path)
        except OSError:
            continue
        name = cached.get("name", "")
        if not name:
            name = first_prompt(path)
            names_cache[uuid] = {"name": name, "path": path}
        project = read_cwd(pid) or ""
        sessions.append({
            "family": "claude",
            "key": uuid,
            "name": name or "claude session",
            "project": project,
            "last_active": last_active,
            "cpu": cpu.get(pid, 0.0),
            "live": True,
        })
    return sessions


# ── opencode database ───────────────────────────────────────────────────────

def collect_opencode(any_live, limit_recent=10):
    sessions = []
    try:
        db = sqlite3.connect(f"file:{OCODE_DB}?mode=ro", uri=True, timeout=2)
    except sqlite3.Error:
        return sessions
    try:
        rows = db.execute(
            "select id, title, directory, time_updated, agent from session_v2 "
            "order by time_updated desc limit 60"
        ).fetchall()
    except sqlite3.Error:
        return sessions
    finally:
        db.close()
    now = time.time()
    for sid, title, directory, updated_ms, agent in rows:
        try:
            last_active = float(updated_ms) / 1000
        except (TypeError, ValueError):
            continue
        if now - last_active > 3600 and len(sessions) >= limit_recent:
            continue
        sessions.append({
            "family": "opencode",
            "key": str(sid),
            "name": (title or "untitled").strip()[:MAX_NAME_LEN] or "untitled",
            "project": directory or "",
            "last_active": last_active,
            "cpu": 0.0,
            "agent": agent or "",
            "live": (now - last_active) < 900,
        })
        if len(sessions) >= limit_recent and now - last_active > 3600:
            break
    if not any_live:
        return []
    return sessions


# ── main ────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--patterns", default="opencode,claude")
    parser.add_argument("--threshold", type=float, default=15.0)
    parser.add_argument("--session-timeout", type=float, default=120.0)
    parser.add_argument("--state", default=default_state_path())
    args = parser.parse_args()

    patterns = [t.strip().lower() for t in args.patterns.split(",") if t.strip()]
    timeout = max(15.0, min(900.0, args.session_timeout))
    now = time.time()

    previous = load_state(args.state)
    known = previous["procs"] if previous is not None else None
    # Single snapshot per run, diffed against the previous tick's snapshot.
    # Short-lived children are covered by session freshness + heartbeats.
    after = snapshot(known, patterns)

    names_cache = {}
    if previous is not None and isinstance(previous.get("names"), dict):
        names_cache = previous["names"]

    cpu = {}
    if previous is not None:
        cpu = cpu_by_pid(previous, after)

    groups = {p: 0.0 for p in patterns}
    for pid, pct in cpu.items():
        family = family_of(pid, after["procs"])
        if family is not None and pct > groups[family]:
            groups[family] = round(pct, 1)

    any_opencode_live = any(family_of(pid, after["procs"]) == "opencode" for pid in after["procs"])
    sessions = collect_claude(after["procs"], cpu, names_cache) + collect_opencode(any_opencode_live)
    save_state(args.state, {**after, "names": names_cache, "v": STATE_FORMAT})

    for session in sessions:
        fresh = (now - session["last_active"]) < timeout
        session["hot_by"] = "fresh" if fresh else "stale"
        # Freshness of real agent data decides. CPU is only a fallback
        # signal for agent families without a session collector (see groups).
        session["is_hot"] = fresh

    hot = sorted({s["family"] for s in sessions if s["is_hot"]})
    for pattern, pct in groups.items():
        if pct >= args.threshold and pattern not in hot:
            hot.append(pattern)
    hot.sort()

    print(json.dumps({"sessions": sessions, "groups": groups, "hot": hot}))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:  # noqa: BLE001
        print(f"session probe failed: {error}", file=sys.stderr)
        sys.exit(1)
