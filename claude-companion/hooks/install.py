#!/usr/bin/env python3
"""Hook installer and checker (lowcache/claude-companion plugin).

    python3 hooks/install.py            # add missing hooks, repair stale paths
    python3 hooks/install.py --check    # report only; exit 1 if anything is off

Wires the lifecycle hooks in ENTRIES into Claude Code's settings.json. The same list
lives in hooks/settings.snippet.json for a manual merge; tests/install_spec.py keeps
the two in step. A hook whose script path is wrong fails silently and the plugin just
looks dead, which is how every release through 1.5.x shipped to catalog users. This
exists to make that failure loud: the sessions panel runs --check each time it opens.

Our entries are recognised by script (hooks/pulse.py <event>, hooks/consent.py), so a
stale path is repaired in place with the rest of the command kept; every other hook
(memd, rtk, ...) is left untouched. Writes are atomic, keep the file's mode, and take a
backup first. Malformed or read-only settings are refused, never rewritten.

Exit codes: 0 ok / installed, 1 --check found problems, 2 refused (nothing written).
"""
import copy
import glob
import json
import os
import re
import shutil
import stat
import sys
import tempfile
import time

PLUGIN_NAME = "claude-companion"

# (event, matcher, script, arg, timeout). consent.py's 120 s sits above the hook's own
# 110 s deadline, so the hook, not Claude Code reaping it, decides when to fall through.
ENTRIES = [
    ("SessionStart", "*", "pulse.py", "idle", None),
    ("UserPromptSubmit", "*", "pulse.py", "turn_start", None),
    ("PreToolUse", "*", "pulse.py", "tool_start", None),
    ("PreToolUse", "^(Bash|Write|Edit|NotebookEdit)$", "consent.py", None, 120),
    ("PostToolUse", "*", "pulse.py", "turn_start", None),
    ("Notification", "*", "pulse.py", "needs_attention", None),
    ("Stop", "*", "pulse.py", "turn_end", None),
    ("SessionEnd", "*", "pulse.py", "session_end", None),
]

# python3 exits 2 on a missing script, and exit 2 from a PreToolUse hook BLOCKS the
# tool call; the guard keeps a broken path from ever stopping Claude.
GUARD = " 2>/dev/null || true"

_SCRIPT = r"/hooks/(?:pulse|consent)\.py"
_END = r"(?![\w.-])"  # whole word: not pulse.py.bak, not idle2
_OURS = re.compile(
    r"""(?:"(?P<dq>[^"]*%s)"|'(?P<sq>[^']*%s)'|(?P<bare>[^\s"';&|]*%s)%s)(?:\s+(?P<arg>[a-z_]+)%s)?"""
    % (_SCRIPT, _SCRIPT, _SCRIPT, _END, _END)
)
OWNERS = (PLUGIN_NAME, "noctalia-claude-plugin")  # dir names a hook path may carry


class Refused(Exception):
    """Settings cannot be safely read or written; nothing is changed."""


def _xdg(noctalia_var, xdg_var, fallback):
    root = os.environ.get(noctalia_var) or os.environ.get(xdg_var) or os.path.expanduser(fallback)
    return os.path.join(root, "noctalia")


def install_dirs():
    """Where Noctalia loads this plugin from (file_utils.h stateDir/dataDir)."""
    state = _xdg("NOCTALIA_STATE_HOME", "XDG_STATE_HOME", "~/.local/state")
    data = _xdg("NOCTALIA_DATA_HOME", "XDG_DATA_HOME", "~/.local/share")
    dirs = sorted(glob.glob(os.path.join(state, "plugins", "materialized", "*", PLUGIN_NAME)))
    dirs.append(os.path.join(data, "plugins", PLUGIN_NAME))
    return dirs


def plugin_base(here):
    """The path to write into hooks: the install location this copy is, if any."""
    real = os.path.realpath(here)
    for cand in install_dirs():
        if os.path.realpath(cand) == real:
            return cand
    return here


def home_form(path):
    home = os.path.expanduser("~").rstrip("/")
    if home and (path == home or path.startswith(home + "/")):
        return "$HOME" + path[len(home):]
    return path


def shell_path(path):
    """A sh word for absolute path that reads back identically via _match."""
    rel = home_form(path)
    tail = rel[len("$HOME"):] if rel.startswith("$HOME/") else rel
    if re.fullmatch(r"[\w./@+-]*", tail):
        return rel
    if not re.search(r'["\\$`]', tail):
        return '"' + rel + '"'
    if "'" not in path:
        return "'" + path + "'"  # literal: no $HOME, nothing expands
    raise Refused("cannot quote the plugin path %r; merge hooks/settings.snippet.json by hand" % path)


def _script_word(base, script):
    return shell_path(os.path.join(base, "hooks", script))


def command_for(base, script, arg):
    return "python3 " + _script_word(base, script) + (" " + arg if arg else "") + GUARD


def _expand(path, literal=False):
    return path if literal else os.path.expanduser(os.path.expandvars(path))


def _label(ev, script, arg):
    return "%s %s%s" % (ev, script, " " + arg if arg else "")


def _match(command, base):
    """(path span, path, realpath, script, arg) if command runs OUR script, else None."""
    if not isinstance(command, str):
        return None
    m = _OURS.search(command)
    if not m:
        return None
    name = "dq" if m.group("dq") else "sq" if m.group("sq") else "bare"
    path = m.group(name)
    quote = 0 if name == "bare" else 1
    span = (m.start(name) - quote, m.end(name) + quote)
    real = os.path.realpath(_expand(path, literal=name == "sq"))
    owner = os.path.basename(os.path.dirname(os.path.dirname(path)))
    if not real.startswith(os.path.realpath(base) + os.sep) and owner not in OWNERS:
        return None
    script = os.path.basename(path)
    return span, path, real, script, (m.group("arg") if script == "pulse.py" else None)


def plan(settings, base):
    """Return (updated copy of settings, problems). No problems means no change."""
    if not isinstance(settings, dict):
        raise Refused("settings.json is not a JSON object")
    out = copy.deepcopy(settings)
    hooks = out.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise Refused('"hooks" in settings.json is not an object')

    timeouts = {(ev, s, a): to for ev, _, s, a, to in ENTRIES}
    seen, problems = set(), []
    for ev, groups in hooks.items():
        if not isinstance(groups, list):
            continue
        emptied = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                continue
            keep = []
            for h in group["hooks"]:
                hit = _match(h.get("command"), base) if isinstance(h, dict) else None
                key = (ev, hit[3], hit[4]) if hit else None
                if key not in timeouts:
                    keep.append(h)
                    continue
                if key in seen:
                    problems.append("duplicate: " + _label(*key))
                    continue
                seen.add(key)
                (start, end), path, real, script, _ = hit
                if real != os.path.realpath(os.path.join(base, "hooks", script)):
                    problems.append("stale: %s -> %s" % (_label(*key), path))
                    h["command"] = h["command"][:start] + _script_word(base, script) + h["command"][end:]
                want = timeouts[key]
                have = h.get("timeout")
                if want and not (isinstance(have, (int, float)) and have >= want):
                    problems.append("timeout: %s needs >= %ss" % (_label(*key), want))
                    h["timeout"] = want
                keep.append(h)
            if group["hooks"] and not keep:
                emptied.append(group)
            group["hooks"] = keep
        if emptied:
            groups[:] = [g for g in groups if not any(g is e for e in emptied)]

    for ev, matcher, script, arg, timeout in ENTRIES:
        if (ev, script, arg) in seen:
            continue
        problems.append("missing: " + _label(ev, script, arg))
        groups = hooks.setdefault(ev, [])
        if not isinstance(groups, list):
            raise Refused('"hooks.%s" in settings.json is not a list' % ev)
        entry = {"type": "command", "command": command_for(base, script, arg)}
        if timeout:
            entry["timeout"] = timeout
        groups.append({"matcher": matcher, "hooks": [entry]})
    return out, problems


def default_settings_path():
    root = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    return os.path.join(root, "settings.json")


def _sig(path):
    """Identity of the file's current contents, or None if it does not exist."""
    try:
        st = os.stat(path)
    except FileNotFoundError:
        return None
    return st.st_ino, st.st_size, st.st_mtime_ns


def load(path):
    """(parsed settings or None when absent, _sig at read time)."""
    try:
        with open(path, encoding="utf-8") as f:
            st = os.fstat(f.fileno())
            text = f.read()
    except FileNotFoundError:
        return None, None
    except OSError as e:
        raise Refused("cannot read %s: %s" % (path, e.strerror))
    try:
        data = json.loads(text) if text.strip() else {}
    except ValueError as e:
        raise Refused("%s is not valid JSON (%s); fix it by hand first" % (path, e))
    return data, (st.st_ino, st.st_size, st.st_mtime_ns)


def save(path, settings, expect):
    """Atomic write with a unique backup; refuses if the file changed since load()."""
    target = os.path.realpath(path)  # write through a symlink, never replace it
    folder = os.path.dirname(target)
    exists = os.path.exists(target)
    if os.path.isdir(folder) and not (os.access(folder, os.W_OK) and (not exists or os.access(target, os.W_OK))):
        raise Refused("%s is read-only; add the hooks where it is generated "
                      "(see hooks/settings.snippet.json)" % target)
    backup = tmp = None
    try:
        os.makedirs(folder, mode=0o700, exist_ok=True)
        if exists:
            stamp = backup = "%s.bak.%s-%s" % (target, PLUGIN_NAME, time.strftime("%Y%m%d-%H%M%S"))
            n = 1
            while os.path.exists(backup):
                backup, n = "%s-%d" % (stamp, n), n + 1
            shutil.copy2(target, backup)
        mode = stat.S_IMODE(os.stat(target).st_mode) if exists else 0o600
        fd, tmp = tempfile.mkstemp(dir=folder, prefix=".settings.", suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(json.dumps(settings, indent=2, ensure_ascii=False) + "\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        if _sig(target) != expect:
            raise Refused("%s changed while installing; run it again" % target)
        os.replace(tmp, target)
        tmp = None
    except OSError as e:
        raise Refused("cannot write %s: %s" % (target, e.strerror or e))
    finally:
        if tmp and os.path.exists(tmp):
            os.unlink(tmp)
    return backup


def main(argv):
    check = "--check" in argv
    path = default_settings_path()
    if "--settings" in argv:
        i = argv.index("--settings")
        if i + 1 >= len(argv):
            print("usage: install.py [--check] [--settings PATH]", file=sys.stderr)
            return 2
        path = argv[i + 1]
    base = plugin_base(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    try:
        fix = "python3 " + _script_word(base, "install.py")
        current, sig = load(path)
        updated, problems = plan(current if current is not None else {}, base)
        if current is None:
            problems.insert(0, "missing: %s" % path)
        if check:
            for p in problems:
                print(p)
            if problems:
                print("fix: " + fix)
                return 1
            print("ok: %d hooks wired in %s" % (len(ENTRIES), path))
            return 0
        if not problems:
            print("ok: nothing to change in %s" % path)
            return 0
        backup = save(path, updated, sig)
    except Refused as e:
        print("refused: %s" % e, file=sys.stderr)
        return 2
    for p in problems:
        print("fixed " + p)
    print("wrote %s%s" % (path, " (backup: %s)" % backup if backup else ""))
    print("new Claude sessions pick this up; a running one may need /hooks opened or a restart")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
