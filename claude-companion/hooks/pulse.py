#!/usr/bin/env python3
"""Pulse hook dispatcher (lowcache/claude-companion plugin).

Bridges a Claude Code lifecycle hook to the pulse bar widget, enriching the
event with live model + token-burn telemetry parsed from the session transcript.
Invoked by the hooks in settings.snippet.json as:

    pulse.py <event>           # event name, e.g. turn_start / tool_start / ...

Hook JSON arrives on stdin (transcript_path, session_id). The widget is driven via
noctalia's documented plugin IPC (`noctalia msg --help`):

    noctalia msg plugin lowcache/claude-companion:pulse all <event> [payload]

`[payload]` is a single positional token, so the payload is a SPACE-FREE CSV the
widget (pulse.luau) parses:

    model,in,out,cacheCreate,cacheRead,session

The `session` (short id) tags EVERY event, so the widget can track each concurrent
session separately. The matching SessionEnd hook fires `session_end`, which retires
the session in the widget and drops its token cache here.

Token accounting is incremental: a per-session cache in $XDG_RUNTIME_DIR stores the
last byte offset + running sums, so each hook reads only newly-appended transcript
lines (O(delta), not O(whole transcript)). Transcript JSONL only appends; if it
ever shrinks (context compaction rewrites it), the cache resets.

Fail-open by contract: ANY error (no stdin, malformed transcript, noctalia offline)
still fires the bare event with no payload and never exits non-zero — a hook must
never block Claude or surface an error.

"""
import json
import os
import subprocess
import sys

PLUGIN = "lowcache/claude-companion:pulse"
TARGET = "all"


def _cache_path(session):
    base = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    safe = "".join(c for c in session if c.isalnum() or c in "-_") or "nosession"
    return os.path.join(base, f"noctalia-pulse-{safe}.json")


def _accumulate(transcript, session):
    """Sum usage over newly-appended transcript lines since the last call."""
    cache = _cache_path(session)
    st = {"offset": 0, "in": 0, "out": 0, "cc": 0, "cr": 0, "model": ""}
    try:
        with open(cache) as f:
            st.update(json.load(f))
    except (OSError, ValueError):
        pass

    if os.path.getsize(transcript) < st["offset"]:  # shrank (compaction) → reset
        st = {"offset": 0, "in": 0, "out": 0, "cc": 0, "cr": 0, "model": ""}

    with open(transcript) as f:
        f.seek(st["offset"])
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                msg = (json.loads(line).get("message") or {})
            except ValueError:
                continue
            u = msg.get("usage")
            if not u:
                continue
            st["in"] += u.get("input_tokens", 0) or 0
            st["out"] += u.get("output_tokens", 0) or 0
            st["cc"] += u.get("cache_creation_input_tokens", 0) or 0
            st["cr"] += u.get("cache_read_input_tokens", 0) or 0
            if msg.get("model"):
                st["model"] = msg["model"]
        st["offset"] = f.tell()

    tmp = cache + ".tmp"
    try:
        with open(tmp, "w") as f:
            json.dump(st, f)
        os.replace(tmp, cache)
    except OSError:
        pass
    return st


def _payload(data, event):
    """Build the CSV payload, or None when the event can't be attributed.

    Requires only a session id — every tagged event carries it so the widget can
    track sessions individually. Token figures are best-effort (zeros when the
    transcript is unreadable or empty); the widget decides whether to render them.
    `session_end` skips the transcript parse (the id alone retires the session).
    """
    session = data.get("session_id") or ""
    if not session:
        return None
    st = {"in": 0, "out": 0, "cc": 0, "cr": 0, "model": ""}
    transcript = data.get("transcript_path") or ""
    if event != "session_end" and transcript and os.path.isfile(transcript):
        try:
            st = _accumulate(transcript, session)
        except OSError:
            pass
    model = st["model"].replace("claude-", "") if st["model"] else "?"
    short = session.split("-")[0]
    return f"{model},{st['in']},{st['out']},{st['cc']},{st['cr']},{short}"


def _cleanup(session):
    """Drop a finished session's token cache (best-effort)."""
    if not session:
        return
    try:
        os.unlink(_cache_path(session))
    except OSError:
        pass


def main():
    event = sys.argv[1] if len(sys.argv) > 1 else "idle"
    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
    except (ValueError, OSError):
        data = {}
    payload = _payload(data, event)
    argv = ["noctalia", "msg", "plugin", PLUGIN, TARGET, event]
    if payload:
        argv.append(payload)
    if os.environ.get("NOCTALIA_PULSE_DRYRUN"):
        print(" ".join(argv))
    else:
        try:
            subprocess.run(argv, capture_output=True, timeout=3)
        except Exception:  # noqa: BLE001 — noctalia offline/missing must stay silent
            pass
    if event == "session_end":
        _cleanup(data.get("session_id") or "")


if __name__ == "__main__":
    main()
