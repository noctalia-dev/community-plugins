#!/usr/bin/env python3
"""Consent gate hook (lowcache/claude-companion plugin).

Turns a Claude Code `PreToolUse` hook into a desktop approval prompt: the tool call
blocks here while the consent panel asks you about it, and your answer is handed back
to Claude as a permission decision. Invoked from settings.snippet.json as:

    consent.py

Hook JSON arrives on stdin (tool_name, tool_input, tool_use_id, cwd, session_id,
permission_mode). A decision is returned by printing, on stdout:

    {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                            "permissionDecision": "allow"|"deny",
                            "permissionDecisionReason": "..."}}

Printing NOTHING means "no decision, proceed normally" — that is the fail-open path,
and every error route in this file takes it. A gate that hangs or crashes must degrade
to exactly the behaviour you had before the plugin was installed.

Three modes, read from the mode file that pulse-svc mirrors the `consent_mode` plugin
setting into (missing file → off, because a shell that is not running cannot answer):

    off      exit immediately; identical to not having the hook installed
    learn    record what came through, never block; seeds the allowlist from real
             traffic so the first ENFORCED session is already quiet
    enforce  block anything not already allowlisted

`permission_mode` is honoured: bypassPermissions and dontAsk are the user telling
Claude Code not to ask, and this hook is not entitled to overrule that.

Forgery: the request/response pair lives in $XDG_RUNTIME_DIR (0700, tmpfs, per-user)
and each request carries a nonce the response must echo. Without XDG_RUNTIME_DIR the
gate disables itself rather than fall back to a world-writable /tmp, where any local
process could drop an "allow" of its own.
"""
import json
import os
import secrets
import subprocess
import sys
import time

PLUGIN = "lowcache/claude-companion:pulse-svc"
PANEL = "lowcache/claude-companion:consent"
TARGET = "all"

# Self-timeout must sit UNDER the `timeout` configured on the hook in settings.json
# (120s there, 110s here). Reaching our own deadline lets us exit cleanly with no
# decision; letting Claude Code reap the process instead could truncate a half-written
# stdout into malformed JSON.
DEADLINE = 110.0
POLL = 0.075

# Tools whose consent key is the path they touch rather than a command string.
PATH_TOOLS = {"Write": "file_path", "Edit": "file_path", "NotebookEdit": "notebook_path"}

# The user has already told Claude Code not to ask in these modes.
SILENT_MODES = {"bypassPermissions", "dontAsk"}


def _runtime_dir():
    """Per-user tmpfs root, or None. Never falls back to a shared /tmp — see module docstring."""
    base = os.environ.get("XDG_RUNTIME_DIR")
    if not base or not os.path.isdir(base):
        return None
    path = os.path.join(base, "claude-companion")
    try:
        os.makedirs(path, mode=0o700, exist_ok=True)
    except OSError:
        return None
    return path


def _state_dir():
    """Durable root for the allowlist. Unlike the runtime dir this must survive a reboot."""
    base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    path = os.path.join(base, "noctalia", "claude-companion")
    try:
        os.makedirs(path, mode=0o700, exist_ok=True)
    except OSError:
        return None
    return path


def _mode(rt):
    """off | learn | enforce. Anything unreadable or unrecognised is off."""
    if not rt:
        return "off"
    try:
        with open(os.path.join(rt, "mode")) as f:
            value = f.read().strip()
    except OSError:
        return "off"
    return value if value in ("learn", "enforce") else "off"


def _key(tool, tool_input):
    """Stable identity for one tool call, as the allowlist stores it.

    Bash keys on the exact command string and path tools on the exact path: an exact
    match, never a pattern. Patterns would make this a classifier deciding what is
    safe, and shell composition (`git status && rm -rf ~`) defeats that in one line.
    """
    if tool == "Bash":
        return "Bash:" + str(tool_input.get("command", ""))
    field = PATH_TOOLS.get(tool)
    if field:
        return f"{tool}:{tool_input.get(field, '')}"
    return tool + ":" + json.dumps(tool_input, sort_keys=True)


def _allowed(key):
    sd = _state_dir()
    if not sd:
        return False
    try:
        with open(os.path.join(sd, "allow.jsonl")) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    if json.loads(line).get("key") == key:
                        return True
                except ValueError:
                    continue
    except OSError:
        pass
    return False


def _record(rt, tool, key, tool_input):
    """learn mode: append one observation. Ephemeral by design — an unpromoted week
    of observations is not something to carry across a reboot.

    Multi-line commands are observed but NOT recorded. The allowlist matches exactly,
    so an ad-hoc heredoc or a chained script will never recur verbatim: promoting one
    adds a key that can never match again and bloats the file it is meant to keep
    readable. They still prompt under enforce, which is the right outcome — a one-off
    multi-line script is precisely the thing worth being asked about.
    """
    if not rt or "\n" in key:
        return
    row = {
        "key": key,
        "tool": tool,
        "description": tool_input.get("description", ""),
        "at": int(time.time()),
    }
    try:
        fd = os.open(os.path.join(rt, "learn.jsonl"), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "a") as f:
            f.write(json.dumps(row) + "\n")
    except OSError:
        pass


def _decide(rt, data, tool, key, tool_input):
    """Publish the request, block on the panel, return "allow"/"deny" or None.

    None is every failure: shell offline, no answer before the deadline, a response
    that does not echo the nonce, malformed JSON. All of them fall through to Claude
    Code's own permission flow.
    """
    raw_id = str(data.get("tool_use_id") or "")
    req_id = "".join(c for c in raw_id if c.isalnum() or c in "-_") or secrets.token_hex(8)
    nonce = secrets.token_hex(16)

    cdir = os.path.join(rt, "consent")
    try:
        os.makedirs(cdir, mode=0o700, exist_ok=True)
    except OSError:
        return None

    req_path = os.path.join(cdir, req_id + ".req")
    res_path = os.path.join(cdir, req_id + ".res")
    request = {
        "id": req_id,
        "nonce": nonce,
        "tool": tool,
        "key": key,
        "command": tool_input.get("command", ""),
        "path": tool_input.get("file_path") or tool_input.get("notebook_path", ""),
        "description": tool_input.get("description", ""),
        "cwd": data.get("cwd", ""),
        "session": str(data.get("session_id") or "").split("-")[0],
    }
    try:
        fd = os.open(req_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(request, f)
    except OSError:
        return None

    # Fast-fail: if the dispatch does not land, the shell cannot be holding a panel
    # open, so waiting out the full deadline would stall Claude for no reason.
    #
    # Payload is the documented space-free CSV: "<request id>,<session id>". The
    # session field lets pulse-svc drive that session to needs_attention while the
    # prompt is outstanding, so the bar goes red without a second dispatch.
    try:
        dispatched = subprocess.run(
            ["noctalia", "msg", "plugin", PLUGIN, TARGET, "consent_request",
             req_id + "," + request["session"]],
            capture_output=True, timeout=3,
        )
        ok = dispatched.returncode == 0
    except Exception:  # noqa: BLE001 — noctalia missing or offline is a normal outcome
        ok = False
    if not ok:
        _unlink(req_path)
        return None

    try:
        subprocess.run(["noctalia", "msg", "panel-open", PANEL, req_id],
                       capture_output=True, timeout=3)
    except Exception:  # noqa: BLE001 — the panel can still be opened by hand
        pass

    deadline = time.monotonic() + DEADLINE
    verdict = None
    while time.monotonic() < deadline:
        try:
            with open(res_path) as f:
                answer = json.load(f)
        except (OSError, ValueError):
            time.sleep(POLL)
            continue
        # Constant-time compare is overkill for a same-uid nonce, but a mismatch must
        # be treated as absent rather than as a denial: a forged deny is a DoS too.
        if secrets.compare_digest(str(answer.get("nonce", "")), nonce):
            choice = answer.get("decision")
            if choice in ("allow", "deny"):
                verdict = choice
        break

    _unlink(req_path)
    _unlink(res_path)
    return verdict


def _unlink(path):
    try:
        os.unlink(path)
    except OSError:
        pass


def _emit(decision, reason):
    json.dump({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": decision,
        "permissionDecisionReason": reason,
    }}, sys.stdout)


def _reply(req_id, choice):
    """Panel side: answer an outstanding request (and optionally allowlist it).

    The panel never handles the nonce — it names a request and a verdict, and the
    nonce is lifted from the request file here. Keeping it out of the Luau surface
    means the shell command the panel builds carries nothing but an id already
    sanitised to [A-Za-z0-9_-] and a verdict from a fixed set.
    """
    rt = _runtime_dir()
    if not rt:
        return
    req_id = "".join(c for c in req_id if c.isalnum() or c in "-_")
    if not req_id:
        return
    cdir = os.path.join(rt, "consent")
    try:
        with open(os.path.join(cdir, req_id + ".req")) as f:
            request = json.load(f)
    except (OSError, ValueError):
        return

    if choice == "always":
        sd = _state_dir()
        key = request.get("key")
        if sd and key and not _allowed(key):
            try:
                fd = os.open(os.path.join(sd, "allow.jsonl"),
                             os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
                with os.fdopen(fd, "a") as f:
                    f.write(json.dumps({"key": key, "added": int(time.time())}) + "\n")
            except OSError:
                pass
        choice = "allow"
    if choice not in ("allow", "deny"):
        return

    try:
        fd = os.open(os.path.join(cdir, req_id + ".res"),
                     os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump({"nonce": request.get("nonce", ""), "decision": choice}, f)
    except OSError:
        pass


def _promote():
    """Fold every distinct key observed in learn mode into the allowlist.

    The one bulk action: after a week in learn, this is what makes the first ENFORCED
    session quiet. Keys already present are skipped, so it is safe to re-run.
    """
    rt, sd = _runtime_dir(), _state_dir()
    if not rt or not sd:
        return
    seen = []
    try:
        with open(os.path.join(rt, "learn.jsonl")) as f:
            for line in f:
                try:
                    key = json.loads(line).get("key")
                except ValueError:
                    continue
                if key and key not in seen and not _allowed(key):
                    seen.append(key)
    except OSError:
        return
    if not seen:
        return
    try:
        fd = os.open(os.path.join(sd, "allow.jsonl"),
                     os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "a") as f:
            for key in seen:
                f.write(json.dumps({"key": key, "added": int(time.time())}) + "\n")
    except OSError:
        pass


def main():
    if len(sys.argv) > 1:
        if sys.argv[1] == "reply" and len(sys.argv) > 3:
            _reply(sys.argv[2], sys.argv[3])
        elif sys.argv[1] == "promote":
            _promote()
        return

    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
    except (ValueError, OSError):
        return

    rt = _runtime_dir()
    mode = _mode(rt)
    if mode == "off":
        return
    if data.get("permission_mode") in SILENT_MODES:
        return

    tool = str(data.get("tool_name") or "")
    tool_input = data.get("tool_input")
    if not isinstance(tool_input, dict):
        return

    key = _key(tool, tool_input)
    if _allowed(key):
        return
    if mode == "learn":
        _record(rt, tool, key, tool_input)
        return

    verdict = _decide(rt, data, tool, key, tool_input)
    if verdict == "allow":
        _emit("allow", "Approved from the Noctalia consent panel.")
    elif verdict == "deny":
        _emit("deny", "Denied from the Noctalia consent panel.")
    # No verdict: print nothing and let Claude Code ask the way it always has.


if __name__ == "__main__":
    try:
        main()
    except Exception:  # noqa: BLE001 — a consent gate must never break a session
        pass
