#!/usr/bin/env python3
"""Live checks of the UFW plugin against the running Noctalia shell and the real ufw.

    python3 ufw/tests/e2e-live.py --selftest        (agent-safe: fake data, no root)
    python3 ufw/tests/e2e-live.py [--only NAME ...] [--toggle] [--service]   (user-run)

The live run is for the user: it types the password, and nothing in ufw/ may change while it
runs (Noctalia hot-reloads the plugin). Never run it without --selftest from an agent.

Checks, in order (each password prompt is announced with a `PROMPT` line first):
  baseline          no root: the service reads what the files say
  save_add_remove   2 prompts: Save an add of a free high port, then Save its remove
  save_cancel       1 prompt, which the user CANCELS: the add stays staged, nothing changes
  load_rules        1 prompt: the batch script's dump gives the same rules, no error
  enable_at_boot    1 prompt, only when the unit is already enabled at boot (a no-op then)
  toggle            --toggle, 4 prompts: Turn off, Save add + Save remove while stopped
                    (save_while_stopped), Turn on
  service           --service, 1 pkexec prompt + `sudo systemctl stop ufw` (1 sudo prompt
                    unless sudo has your password cached): stop from outside, Start ufw
At the start it prints the plan and the prompts to expect and waits for Enter; at the end it
prints how many prompts each check caused.

Each check drives the plugin only through its IPC entry
(`noctalia msg plugin 3dprogramin/ufw:service all request '<json>'`) and reads the result
from the service's debug file (state.json in its data dir: counts and keys only) and from
the files in /etc directly.

The service writes state.json only while the marker file `debug` exists in its data dir.
The script creates the marker before its first request and, in its finally (also on Ctrl-C),
removes the marker and the state.json it caused. It refuses to run while `fixture-root`
exists there (test mode would read fixtures instead of /etc).

Safety:
  * record() reads ufw.conf, /etc/default/ufw, the tuple lines of both rules files and the
    unit's state at the start, into memory only. Nothing of it is ever printed.
  * restore() runs in try/finally and on SIGINT/SIGTERM. It turns ufw back on (or off) as
    recorded and starts the unit if it was active, and only then deletes the e2e rules this
    run created (by their comment), with `sudo ufw --force delete <spec>`, once more after a
    stopped ufw's "problem running" (that one wrote user.rules only). An e2e rule an earlier
    run left is reported, never deleted. It never runs `ufw reset` and never deletes another
    rule. verify_restored() runs after it even when it failed.
  * verify_restored() compares every recorded field and prints only `match` or
    `MISMATCH: <field name>`.
  * Output is counts, field names and pass/fail. Never a port, address or comment of the
    user's rules.

Fresh state only: the snapshot's `requestSeq` goes up once the service has handled a
request. send() records it (and `seq`) before sending; wait_state() only accepts a snapshot
with a higher requestSeq. `seq` goes up on every publish, and both only ever go up within one
service start. Every read of the snapshot (current_marks, so send, and wait_state) keeps the
highest seq and requestSeq of the run: one lower than that comes from a new service start (a
hot reload), between requests as much as during one, and raises Reloaded: the run stops and
restores.
`--selftest` checks this logic, debug_on/debug_off, record/restore/verify_restored and every
check, against a temporary /etc, a fake sudo and a fake plugin (its IPC and state.json).
"""

import argparse
import json
import os
import pathlib
import random
import re
import secrets
import signal
import subprocess
import sys
import tempfile
import time

ENTRY = "3dprogramin/ufw:service"
DATA_DIR = pathlib.Path.home() / ".local/state/noctalia/plugins/data/3dprogramin/ufw"
STATE = DATA_DIR / "state.json"
DEBUG_MARKER = DATA_DIR / "debug"
FIXTURE_ROOT = DATA_DIR / "fixture-root"
DEBUG_WAIT_S = 10
E2E_PREFIX = "noctalia-ufw-e2e-"
RULES_FILES = ("ufw/user.rules", "ufw/user6.rules")
IPC_TIMEOUT_S = 10
GROUPS = ("toggle", "service")
# A root action waits for a person at the password prompt: the plugin gives pkexec 60 s, and
# its watchdog 5 s more.
PROMPT_WAIT_S = 80
# Free ports for the e2e rule come from the dynamic range.
PORT_RANGE = (49152, 65535)

# Where the files live and how root and systemctl are reached; --selftest swaps them all.
CONF = {
    "etc": pathlib.Path("/etc"),
    "proc": pathlib.Path("/proc"),
    "sudo": ["sudo"],
    "systemctl": ["systemctl"],
    "noctalia": ["noctalia"],
}

CHECKS = []  # (name, group, fn) in registration order
PLAN = {}  # name -> (prompts(rec) -> (pkexec, sudo), what to do at the prompts)


class Skip(Exception):
    pass


class CheckFailed(Exception):
    pass


class Reloaded(CheckFailed):
    """The plugin restarted mid-run: the run stops (and restores) instead of going on."""


class Interrupted(Exception):
    pass


def check(name, group=None, prompts=lambda rec: (0, 0), note=""):
    assert group is None or group in GROUPS, group

    def register(fn):
        CHECKS.append((name, group, fn))
        PLAN[name] = (prompts, note)
        return fn

    return register


def say(text=""):
    print(text, flush=True)


def ask(text):
    return input(text)


# ── password prompts ─────────────────────────────────────────────────────────

CONTEXT = {}
CREATED = set()  # the e2e comments this run created: restore deletes only these
PROMPTS = {}  # where ("record", a check's name, "restore") -> {"pkexec": n, "sudo": n}


def count_prompt(kind, n=1):
    where = CONTEXT.get("where", "record")
    PROMPTS.setdefault(where, {"pkexec": 0, "sudo": 0})[kind] += n


def prompts_of(where):
    got = PROMPTS.get(where, {"pkexec": 0, "sudo": 0})
    return got["pkexec"], got["sudo"]


def sudo_run(args, timeout=90):
    """One sudo command. `sudo -n true` first tells whether sudo will ask for the password
    (nothing cached): that is a prompt, announced and counted."""
    cached = subprocess.run(CONF["sudo"] + ["-n", "true"], capture_output=True, text=True,
                            timeout=10).returncode == 0
    if not cached:
        # args here are fixed words, a path in /etc or this script's own e2e port
        say("PROMPT (sudo, in this terminal): type your password for `sudo %s`" % " ".join(args[:3]))
        count_prompt("sudo")
    return subprocess.run(CONF["sudo"] + list(args), capture_output=True, text=True, timeout=timeout)


# ── IPC and the debug file ───────────────────────────────────────────────────

SENT = {"seq": None, "request": None}  # seq and requestSeq seen just before the last send()
HIGH = {"seq": None, "request": None}  # the highest seq and requestSeq seen this run

RELOADED = "the plugin reloaded during the check (seq went backwards; its code changed?) — re-run the test"


def read_state():
    """The service's last debug snapshot, or None while it is mid-write."""
    try:
        return json.loads(STATE.read_text())
    except (OSError, ValueError):
        return None


def note_marks(state):
    """Every snapshot read: Reloaded when seq or requestSeq went below what this run saw."""
    if reloaded(state):
        raise Reloaded(RELOADED)
    for key, field in (("seq", "seq"), ("request", "requestSeq")):
        value = state.get(field, -1)
        if HIGH[key] is None or value > HIGH[key]:
            HIGH[key] = value


def current_marks():
    for _ in range(20):
        state = read_state()
        if state is not None:
            note_marks(state)
            return state.get("seq", -1), state.get("requestSeq", -1)
        time.sleep(0.1)
    raise CheckFailed("cannot read the service's debug file")


def dispatch(request):
    """One IPC request; (dispatched?, output). A missing or hanging `noctalia` is a
    CheckFailed, not a traceback."""
    try:
        out = subprocess.run(CONF["noctalia"] + ["msg", "plugin", ENTRY, "all", "request", json.dumps(request)],
                             capture_output=True, text=True, timeout=IPC_TIMEOUT_S)
    except FileNotFoundError:
        raise CheckFailed("cannot reach noctalia: the `noctalia` command was not found")
    except subprocess.TimeoutExpired:
        raise CheckFailed("cannot reach noctalia: `noctalia msg` did not answer within %ss" % IPC_TIMEOUT_S)
    text = (out.stdout + out.stderr).strip()
    return out.returncode == 0 and "dispatched" in text, text


def send(request):
    """Requests carry no user rule data (the e2e rule is the script's own), so they may be shown."""
    SENT["seq"], SENT["request"] = current_marks()
    ok, text = dispatch(request)
    if not ok:
        raise CheckFailed("IPC request %s not dispatched: %s" % (request.get("action"), text))
    return text


def reloaded(state):
    """True when the snapshot's seq (or requestSeq) is lower than the one seen before the
    last send() or the highest one seen this run: a new service start."""
    for marks in (SENT, HIGH):
        if marks["seq"] is not None and state.get("seq", -1) < marks["seq"]:
            return True
        if marks["request"] is not None and state.get("requestSeq", -1) < marks["request"]:
            return True
    return False


def fresh(state):
    """True once the service has handled the request of the last send()."""
    return SENT["request"] is None or state.get("requestSeq", -1) > SENT["request"]


def wait_state(pred, timeout=40, poll=0.5, what="condition"):
    deadline = time.time() + timeout
    state = None
    while True:
        state = read_state()
        if state is not None:
            note_marks(state)
        if state is not None and fresh(state):
            try:
                if pred(state):
                    return state
            except (KeyError, TypeError, AttributeError):
                pass
        if time.time() >= deadline:
            raise CheckFailed("timed out after %ss waiting for %s; last state: %s"
                              % (timeout, what, summary(state)))
        time.sleep(poll)


def summary(state):
    """Counts and keys only (state.json holds nothing else)."""
    if not state:
        return "none"
    return "seq=%s req=%s status=%s rules=%s allowed=%s pending=%s busy=%s error=%s notice=%s" % (
        state.get("seq"), state.get("requestSeq"), state.get("status"), state.get("ruleCount"),
        state.get("allowedCount"), state.get("pendingCount"), state.get("busy"),
        state.get("lastErrorKey"), state.get("noticeKey"))


def idle(state):
    return not state.get("busy")


def debug_on(marker=None, state=None, poke=None, timeout=DEBUG_WAIT_S):
    """Create the marker that makes the service write state.json, and wait for its first
    dump. A state.json already there is stale (an older plugin, or a killed run): it goes first."""
    marker, state = marker or DEBUG_MARKER, state or STATE
    poke = poke or (lambda: dispatch({"action": "refresh"}))
    state.unlink(missing_ok=True)
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.touch()
    deadline = time.time() + timeout
    while time.time() < deadline:
        poke()  # a refresh makes the service publish, which writes the dump
        for _ in range(10):
            if state.exists():
                return
            time.sleep(0.1)
    raise CheckFailed("the service wrote no %s within %ss of creating %s (is the plugin loaded?)"
                      % (state, timeout, marker))


def debug_off(marker=None, state=None):
    """Remove the marker, then the state.json it caused. The service checks the marker and
    writes in one callback, so a short wait covers one in flight."""
    marker, state = marker or DEBUG_MARKER, state or STATE
    marker.unlink(missing_ok=True)
    time.sleep(0.3)
    state.unlink(missing_ok=True)


# ── record / restore (files and sudo only, never the plugin) ─────────────────


def etc(relative):
    return CONF["etc"] / relative


def read_text(path):
    """A root-owned file: read directly, or through sudo cat on a locked-down distro.
    Kept in memory; never printed."""
    try:
        return path.read_text()
    except PermissionError:
        out = sudo_run(["cat", str(path)], timeout=60)
        if out.returncode != 0:
            raise RuntimeError("cannot read %s (exit %d)" % (path.name, out.returncode))
        return out.stdout


def tuples(text):
    return [line.rstrip() for line in text.splitlines() if line.startswith("### tuple ###")]


def unit_state():
    out = subprocess.run(CONF["systemctl"] + ["show", "ufw", "--property=ActiveState,UnitFileState"],
                         capture_output=True, text=True, timeout=10)
    fields = dict(line.split("=", 1) for line in out.stdout.splitlines() if "=" in line)
    return fields.get("ActiveState", ""), fields.get("UnitFileState", "")


def conf_enabled(text):
    match = re.search(r'^\s*ENABLED\s*=\s*"?(\w+)', text, re.M)
    return bool(match) and match.group(1).lower() == "yes"


RECORD_FIELDS = ("conf", "defaults", "v4_tuples", "v6_tuples", "unit_active", "unit_file_state")


def record():
    """The user's starting state, in memory only."""
    active, file_state = unit_state()
    return {
        "conf": read_text(etc("ufw/ufw.conf")),
        "defaults": read_text(etc("default/ufw")),
        "v4_tuples": tuples(read_text(etc("ufw/user.rules"))),
        "v6_tuples": tuples(read_text(etc("ufw/user6.rules"))),
        "unit_active": active,
        "unit_file_state": file_state,
    }


def tuple_comment(line):
    match = re.search(r"\scomment=([0-9a-fA-F]*)$", line)
    if not match:
        return None
    try:
        return bytes.fromhex(match.group(1)).decode("utf-8", "replace")
    except ValueError:
        return None


def e2e_delete_spec(line):
    """The `ufw delete` args for one of this script's own rules (a plain `allow <port>[/proto]`
    with an e2e comment), or None for any other tuple."""
    comment = tuple_comment(line)
    if comment is None or not comment.startswith(E2E_PREFIX):
        return None
    body = re.sub(r"\s+comment=\S*$", "", line[len("### tuple ###"):]).split()
    # action proto dport dst sport src dir
    if len(body) != 7:
        return None
    action, proto, dport, dst, sport, src, direction = body
    if action != "allow" or direction != "in" or sport != "any" or not dport.isdigit():
        return None
    if dst not in ("0.0.0.0/0", "::/0") or src not in ("0.0.0.0/0", "::/0"):
        return None
    if proto in ("tcp", "udp"):
        return ["allow", "%s/%s" % (dport, proto)]
    if proto == "any":
        return ["allow", dport]
    return None


def e2e_rules(created):
    """Delete specs of the e2e rules this run created (comments in `created`) now in the files
    (v4 and v6 copies share one), the number of this run's e2e tuples whose shape this script
    can't delete, and the number of e2e rules (by comment) an earlier run left."""
    specs, odd, leftover = [], 0, set()
    for name in RULES_FILES:
        for line in tuples(read_text(etc(name))):
            comment = tuple_comment(line)
            if comment is None or not comment.startswith(E2E_PREFIX):
                continue
            if comment not in created:
                leftover.add(comment)
                continue
            spec = e2e_delete_spec(line)
            if spec is None:
                odd += 1
            elif spec not in specs:
                specs.append(spec)
    return specs, odd, len(leftover)


def delete_e2e_rule(spec):
    """`sudo ufw --force delete <spec>`. With ufw stopped (ENABLED=yes, unit inactive) ufw
    writes user.rules, fails on the running firewall with "problem running" and never gets
    to user6.rules: once more writes that one (as the batch script does)."""
    out = sudo_run(["ufw", "--force", "delete"] + list(spec))
    text = (out.stdout + out.stderr).rstrip()
    if out.returncode != 0 and text.endswith("problem running"):
        sudo_run(["ufw", "--force", "delete"] + list(spec))
        return
    if out.returncode != 0:
        raise RuntimeError("`sudo ufw --force delete` failed (exit %d)" % out.returncode)


def root(*args):
    out = sudo_run(args)
    if out.returncode != 0:
        # args here are fixed words or this script's own e2e port: no user rule data
        raise RuntimeError("`sudo %s` failed (exit %d)" % (" ".join(args[:3]), out.returncode))


_restored = False


def restore(rec, created=None):
    """Put the recorded state back. Idempotent; signals are held meanwhile.

    ufw goes back on (or off) and the unit is started first, so the e2e deletes run against a
    running firewall and write both rules files; a failed or refused delete never keeps ufw
    off or the unit stopped. Only this run's e2e rules (`created`, default CREATED) are
    deleted, then the files are scanned again. Every failure is collected and raised at the
    end."""
    global _restored
    if _restored or rec is None:
        return
    _restored = True
    previous = {sig: signal.signal(sig, signal.SIG_IGN) for sig in (signal.SIGINT, signal.SIGTERM)}
    errors = []

    def step(fn):
        try:
            fn()
        except Exception as err:  # noqa: BLE001 - collected, raised after every step ran
            errors.append(str(err))

    mine = CREATED if created is None else created

    def delete_e2e():
        specs, odd, leftover = e2e_rules(mine)
        if leftover:
            say("restore: found %d leftover e2e rule(s) from an earlier run; remove by hand" % leftover)
        failed = []
        for spec in specs:
            try:
                delete_e2e_rule(spec)
            except Exception as err:  # noqa: BLE001 - the rescan below says what is left
                failed.append(str(err))
        left, odd, _ = e2e_rules(mine)
        if specs:
            say("restore: deleted %d e2e rule(s), %d left" % (len(specs) - len(left), len(left)))
        problems = list(failed)
        if left:
            problems.append("%d e2e rule(s) of this run are still there; remove them by hand" % len(left))
        if odd:
            problems.append("%d e2e tuple(s) have a shape this script can't delete; remove them by hand" % odd)
        if problems:
            raise RuntimeError("; ".join(problems))

    def put_enabled_back():
        was_on = conf_enabled(rec["conf"])
        now_on = conf_enabled(read_text(etc("ufw/ufw.conf")))
        if was_on and not now_on:
            root("ufw", "--force", "enable")
            say("restore: turned ufw back on")
        elif now_on and not was_on:
            root("ufw", "disable")
            say("restore: turned ufw back off")

    def start_unit():
        if rec["unit_active"] == "active" and unit_state()[0] != "active":
            root("systemctl", "start", "ufw")
            say("restore: started the ufw unit")

    try:
        step(put_enabled_back)
        step(start_unit)
        step(delete_e2e)
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    if errors:
        raise RuntimeError("; ".join(errors))


def verify_restored(rec):
    """Every recorded field against now; prints only `match` or `MISMATCH: <field>`."""
    now = record()
    ok = True
    for field in RECORD_FIELDS:
        if now[field] == rec[field]:
            say("match")
        else:
            say("MISMATCH: %s" % field)
            ok = False
    return ok


def on_signal(signum, _frame):
    """Ctrl-C / SIGTERM: both are ignored from here on, so a second one can't land before the
    cleanup's finally has started."""
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    raise Interrupted("signal %d" % signum)


# ── checks ───────────────────────────────────────────────────────────────────

RNG = random.Random()
USED_PORTS = set()  # e2e ports of this run: a leftover of a failed check is never reused
# a refusal: no pkexec ran, so no prompt was shown
NOT_SHOWN = ("error.no_polkit_agent", "error.busy", "error.test_mode", "error.unknown_action")


def on_and_active(rec):
    return conf_enabled(rec["conf"]) and rec["unit_active"] == "active"


def boot_enabled(rec):
    return rec["unit_file_state"] == "enabled"


def stopped_status(rec):
    """What a stopped unit shows: red `stopped` while it starts at boot, amber otherwise."""
    return "stopped" if boot_enabled(rec) else "not_running"


def ipv6_on(defaults_text):
    match = re.search(r'^\s*IPV6\s*=\s*"?(\w+)', defaults_text, re.M)
    return bool(match) and match.group(1).lower() == "yes"


def current_tuples():
    return tuple(tuples(read_text(etc(name))) for name in RULES_FILES)


def recorded_tuples(rec):
    return rec["v4_tuples"], rec["v6_tuples"]


def e2e_ids(state):
    """comment -> rule id of the e2e rules the service sees (an empty map may come as [])."""
    ids = state.get("e2eRuleIds")
    return ids if isinstance(ids, dict) else {}


def covered(lines):
    """(low, high) port ranges of the dport field of these tuples; `any` covers nothing here
    (it is a rule on addresses, and the e2e rule's port is not in it as a number)."""
    ranges = []
    for line in lines:
        body = line[len("### tuple ###"):].split()
        if len(body) < 3:
            continue
        for part in body[2].split(","):
            low, _, high = part.partition(":")
            if low.isdigit() and (high == "" or high.isdigit()):
                ranges.append((int(low), int(high or low)))
    return ranges


def local_ports():
    """Every local port a socket uses now (/proc/net), so the e2e rule never opens a port
    something listens on."""
    ports = set()
    for name in ("tcp", "tcp6", "udp", "udp6"):
        try:
            text = (CONF["proc"] / "net" / name).read_text()
        except OSError:
            continue
        for line in text.splitlines()[1:]:
            fields = line.split()
            if len(fields) > 1 and ":" in fields[1]:
                try:
                    ports.add(int(fields[1].rsplit(":", 1)[1], 16))
                except ValueError:
                    pass
    return ports


def pick_port(lines):
    """A port in PORT_RANGE no tuple covers, no socket uses and this run has not used."""
    ranges, used = covered(lines), local_ports()
    for _ in range(500):
        port = RNG.randint(*PORT_RANGE)
        if port in USED_PORTS or port in used or any(low <= port <= high for low, high in ranges):
            continue
        USED_PORTS.add(port)
        return port
    raise CheckFailed("found no free port in %d-%d" % PORT_RANGE)


def new_e2e():
    """A free port (against the recorded and the current tuples) and a fresh e2e comment."""
    rec = CONTEXT["rec"]
    lines = list(rec["v4_tuples"]) + list(rec["v6_tuples"])
    for part in current_tuples():
        lines += part
    port, comment = pick_port(lines), E2E_PREFIX + secrets.token_hex(3)
    CREATED.add(comment)  # before it is staged: restore may delete only what this run made
    return port, comment


def e2e_lines(comment):
    """The tuples carrying this comment, per rules file."""
    return tuple([line for line in part if tuple_comment(line) == comment] for part in current_tuples())


def expect_in_files(comment, port, prefix=""):
    """The e2e rule is in user.rules (and in user6.rules while IPv6 is on), as a plain
    tcp allow that restore can delete."""
    v4, v6 = e2e_lines(comment)
    want_v6 = ipv6_on(read_text(etc("default/ufw")))
    problems = []
    if len(v4) != 1:
        problems.append("%d copies in user.rules, not 1" % len(v4))
    if len(v6) != (1 if want_v6 else 0):
        problems.append("%d copies in user6.rules, not %d" % (len(v6), 1 if want_v6 else 0))
    for line in v4 + v6:
        if e2e_delete_spec(line) != ["allow", "%d/tcp" % port]:
            problems.append("a copy is not a plain `allow %d/tcp`" % port)
    if problems:
        raise CheckFailed(prefix + "the saved e2e rule: " + "; ".join(problems))


def expect_gone(comment, state, prefix=""):
    v4, v6 = e2e_lines(comment)
    if v4 or v6:
        raise CheckFailed(prefix + "the e2e rule is still in the files (%d+%d copies)" % (len(v4), len(v6)))
    if comment in e2e_ids(state):
        raise CheckFailed(prefix + "the service still lists the e2e rule")


def expect_clean(state, prefix="", pending=0, notice=None):
    """After a request: no error, `pending` ops staged, the notice expected."""
    problems = []
    if state.get("lastErrorKey"):
        problems.append("error %s" % state.get("lastErrorKey"))
    if state.get("pendingCount") != pending:
        problems.append("%s op(s) pending, not %d" % (state.get("pendingCount"), pending))
    if state.get("noticeKey") != notice:
        problems.append("notice %s, not %s" % (state.get("noticeKey"), notice))
    if problems:
        raise CheckFailed(prefix + "; ".join(problems))


def staged(request):
    """A staging request (no root); returns the fresh snapshot."""
    send(request)
    return wait_state(lambda s: True, timeout=20, what="%s handled" % request["action"])


def stage_add(port, comment, prefix=""):
    state = staged({"action": "stage_add", "port": port, "proto": "tcp", "comment": comment})
    if state.get("lastErrorKey") or state.get("pendingCount") != 1 or state.get("pendingKinds") != ["add"]:
        raise CheckFailed(prefix + "staging the add: error %s, %s pending"
                          % (state.get("lastErrorKey"), state.get("pendingCount")))
    return state


def stage_remove(rule_id, prefix=""):
    state = staged({"action": "stage_remove", "rule": rule_id})
    if state.get("lastErrorKey") or state.get("pendingCount") != 1 or state.get("pendingKinds") != ["remove"]:
        raise CheckFailed(prefix + "staging the remove: error %s, %s pending"
                          % (state.get("lastErrorKey"), state.get("pendingCount")))
    return state


def root_action(request, prompt, cancel=False):
    """A request the plugin runs through pkexec: one password prompt (none when the plugin
    refused it). Returns the snapshot once the action has ended and everything was re-read.
    A prompt cancelled where the password was wanted fails the check at once."""
    say("PROMPT (pkexec): %s" % prompt)
    send(request)
    count_prompt("pkexec")
    state = wait_state(idle, timeout=PROMPT_WAIT_S, what="%s to finish" % request["action"])
    if state.get("lastErrorKey") in NOT_SHOWN:
        count_prompt("pkexec", -1)
    if not cancel and state.get("noticeKey") == "notice.cancelled":
        raise CheckFailed("the password prompt for %s was cancelled" % request["action"])
    return state


def recover_running():
    """A check that stopped ufw failed: start the unit again now rather than at the end."""
    rec = CONTEXT["rec"]
    try:
        if rec["unit_active"] == "active" and unit_state()[0] != "active":
            say("recovering: starting the ufw unit again now")
            if sudo_run(["systemctl", "start", "ufw"]).returncode != 0:
                say("recovering: `sudo systemctl start ufw` failed; restore tries again at the end")
    except Interrupted:
        raise
    except Exception as err:  # noqa: BLE001 - restore tries again at the end
        say("recovering failed (%s); restore tries again at the end" % type(err).__name__)


def stopped_problems(state, conf_text, unit, boot_before, expected="stopped"):
    """What is wrong after a stop, as a list of short texts (empty = right). Turn off only
    stops the unit: ufw.conf keeps ENABLED=yes and the boot setting is untouched."""
    problems = []
    if state.get("status") != expected:
        problems.append("status is %s, not %s" % (state.get("status"), expected))
    if not conf_enabled(conf_text):
        problems.append("ENABLED in ufw.conf is no longer yes")
    if unit[0] != "inactive":
        problems.append("the unit is %s, not inactive" % (unit[0] or "unknown"))
    if unit[1] != boot_before:
        problems.append("the boot setting changed")
    return problems


def on_problems(state, conf_text, unit, boot_before):
    """What is wrong after Turn on / Start ufw (empty = right)."""
    problems = []
    if state.get("status") != "on":
        problems.append("status is %s, not on" % state.get("status"))
    if state.get("lastErrorKey"):
        problems.append("error %s" % state.get("lastErrorKey"))
    if not conf_enabled(conf_text):
        problems.append("ENABLED in ufw.conf is not yes")
    if unit[0] != "active":
        problems.append("the unit is %s, not active" % (unit[0] or "unknown"))
    if unit[1] != boot_before:
        problems.append("the boot setting changed")
    return problems


def wait_status(status, what):
    """The status after a root action: the action's own re-read normally has it already."""
    return wait_state(lambda s: idle(s) and s.get("status") == status, timeout=15, what=what)


@check("baseline")
def baseline():
    """The service reads the same state as the files: no root, nothing changes."""
    state = wait_state(idle, timeout=20, what="service idle")
    rec = CONTEXT["rec"]
    if state.get("enabled") is not conf_enabled(rec["conf"]):
        raise CheckFailed("enabled differs from ufw.conf")
    if state.get("unitActive") != (rec["unit_active"] or None):
        raise CheckFailed("unitActive differs from systemctl")
    no_tuples = not rec["v4_tuples"] and not rec["v6_tuples"]
    if (state.get("ruleCount") == 0) != no_tuples:
        raise CheckFailed("the service has %s rules, the files %s tuples"
                          % (state.get("ruleCount"), "no" if no_tuples else "some"))
    return "status %s, %s rules, %s allowed in" % (state.get("status"), state.get("ruleCount"), state.get("allowedCount"))


@check("save_add_remove", prompts=lambda rec: (2, 0), note="type your password at both")
def save_add_remove():
    """Save an add of a free port, find it by its comment, then Save its remove."""
    rec = CONTEXT["rec"]
    port, comment = new_e2e()
    stage_add(port, comment)
    state = root_action({"action": "save"}, "type your password (save_add_remove: Save the e2e add, port %d)" % port)
    expect_clean(state, "after the add: ")
    expect_in_files(comment, port)
    rule_id = e2e_ids(state).get(comment)
    if rule_id is None:
        raise CheckFailed("the service does not list the saved e2e rule")
    stage_remove(rule_id)
    state = root_action({"action": "save"}, "type your password (save_add_remove: Save the e2e remove)")
    expect_clean(state, "after the remove: ")
    expect_gone(comment, state)
    if current_tuples() != recorded_tuples(rec):
        raise CheckFailed("the other tuples changed")
    return "added and removed one rule on port %d; every other tuple unchanged" % port


@check("save_cancel", prompts=lambda rec: (1, 0), note="press CANCEL, do not type the password")
def save_cancel():
    """Save an add, the user cancels the prompt: the op stays staged and nothing changes."""
    port, comment = new_e2e()
    before = current_tuples()
    stage_add(port, comment)
    state = root_action({"action": "save"}, "press CANCEL now, do not type the password (save_cancel)", cancel=True)
    v4, v6 = e2e_lines(comment)
    if v4 or v6 or comment in e2e_ids(state):
        raise CheckFailed("the Save went through (was the password typed instead of Cancel?); "
                          "restore removes the rule")
    expect_clean(state, "after Cancel: ", pending=1, notice="notice.cancelled")
    if current_tuples() != before:
        raise CheckFailed("the rules files changed")
    state = staged({"action": "discard"})
    if state.get("pendingCount") != 0:
        raise CheckFailed("discard left %s op(s) pending" % state.get("pendingCount"))
    return "cancelled: op kept, files unchanged, then discarded"


def files_readable():
    return all(os.access(etc(name), os.R_OK)
               for name in ("ufw/ufw.conf", "default/ufw", "ufw/user.rules", "ufw/user6.rules"))


@check("load_rules", prompts=lambda rec: (1, 0), note="type your password")
def load_rules():
    """Load rules (the batch script's dump, as root): the same rules, no error. With the files
    readable the re-read that ends the action puts the source back to `files`; `root` stays
    only while they are unreadable."""
    before = wait_state(idle, timeout=20, what="service idle")
    state = root_action({"action": "load_rules"}, "type your password (load_rules)")
    expect_clean(state)
    source = "files" if files_readable() else "root"
    if state.get("source") != source:
        raise CheckFailed("source is %s, not %s" % (state.get("source"), source))
    if state.get("ruleCount") != before.get("ruleCount"):
        raise CheckFailed("%s rules after Load rules, %s before" % (state.get("ruleCount"), before.get("ruleCount")))
    return "source %s, %s rules" % (source, state.get("ruleCount"))


@check("enable_at_boot", prompts=lambda rec: (1, 0) if boot_enabled(rec) else (0, 0), note="type your password")
def enable_at_boot():
    """Start at boot, only where it is a no-op (the unit already starts at boot): boot is
    never changed by this script."""
    rec = CONTEXT["rec"]
    if not boot_enabled(rec):
        raise Skip("the unit is %s at boot, not enabled: running Start at boot would change boot, so this check does not"
                   % (rec["unit_file_state"] or "unknown"))
    state = root_action({"action": "enable_at_boot"}, "type your password (enable_at_boot: a no-op here)")
    expect_clean(state)
    if state.get("bootEnabled") is not True:
        raise CheckFailed("the service says the unit is not enabled at boot")
    if unit_state() != (rec["unit_active"], rec["unit_file_state"]):
        raise CheckFailed("the unit's state changed")
    return "still enabled at boot, unit unchanged"


def save_while_stopped():
    """While ufw is stopped: Save an add (written to both files, op no longer pending, the
    "takes effect when ufw is turned on" notice), then Save its remove."""
    prefix = "save_while_stopped: "
    port, comment = new_e2e()
    stage_add(port, comment, prefix)
    state = root_action({"action": "save"},
                        "type your password (toggle/save_while_stopped: Save the e2e add, port %d)" % port)
    expect_clean(state, prefix + "after the add: ", notice="notice.saved_not_live")
    expect_in_files(comment, port, prefix)
    rule_id = e2e_ids(state).get(comment)
    if rule_id is None:
        raise CheckFailed(prefix + "the service does not list the saved e2e rule")
    stage_remove(rule_id, prefix)
    state = root_action({"action": "save"}, "type your password (toggle/save_while_stopped: Save the e2e remove)")
    if state.get("lastErrorKey") or state.get("pendingCount") != 0:
        raise CheckFailed(prefix + "after the remove: error %s, %s pending"
                          % (state.get("lastErrorKey"), state.get("pendingCount")))
    expect_gone(comment, state, prefix)
    return "save_while_stopped ok (remove notice %s)" % state.get("noticeKey")


@check("toggle", group="toggle", prompts=lambda rec: (4, 0) if on_and_active(rec) else (0, 0),
       note="type your password at all four")
def toggle():
    """Turn off, Save while stopped, Turn on, through the plugin. Needs ufw on and the unit
    active to start. A failure starts the unit again at once."""
    rec = CONTEXT["rec"]
    if not on_and_active(rec):
        raise Skip("ufw must be on and active when the run starts")
    boot_before = rec["unit_file_state"]
    stopped = stopped_status(rec)
    try:
        state = root_action({"action": "disable"}, "type your password (toggle: Turn off)")
        if state.get("lastErrorKey"):
            raise CheckFailed("Turn off: error %s" % state.get("lastErrorKey"))
        state = wait_status(stopped, "status %s after Turn off" % stopped)
        problems = stopped_problems(state, read_text(etc("ufw/ufw.conf")), unit_state(), boot_before, stopped)
        if problems:
            raise CheckFailed("after Turn off: " + "; ".join(problems))
        sws = save_while_stopped()
        state = root_action({"action": "enable"}, "type your password (toggle: Turn on)")
        if state.get("lastErrorKey"):
            raise CheckFailed("Turn on: error %s" % state.get("lastErrorKey"))
        state = wait_status("on", "status on after Turn on")
        problems = on_problems(state, read_text(etc("ufw/ufw.conf")), unit_state(), boot_before)
        if problems:
            raise CheckFailed("after Turn on: " + "; ".join(problems))
    except Interrupted:
        raise
    except Exception:
        recover_running()
        raise
    return "off -> %s (ENABLED=yes, boot unchanged); %s; on -> on (ENABLED=yes, boot unchanged)" % (stopped, sws)


@check("service", group="service", prompts=lambda rec: (1, 1) if on_and_active(rec) else (0, 0),
       note="sudo (in this terminal, unless cached), then pkexec: type your password at both")
def service_restart():
    """`sudo systemctl stop ufw` from outside the plugin: the plugin shows it stopped; Start
    ufw through the plugin turns it green. A failure starts the unit again at once."""
    rec = CONTEXT["rec"]
    if not on_and_active(rec):
        raise Skip("ufw must be on and active when the run starts")
    boot_before = rec["unit_file_state"]
    stopped = stopped_status(rec)
    try:
        if sudo_run(["systemctl", "stop", "ufw"]).returncode != 0:
            raise CheckFailed("`sudo systemctl stop ufw` failed")
        send({"action": "refresh"})
        state = wait_status(stopped, "status %s after the stop" % stopped)
        problems = stopped_problems(state, read_text(etc("ufw/ufw.conf")), unit_state(), boot_before, stopped)
        if problems:
            raise CheckFailed("after the stop: " + "; ".join(problems))
        state = root_action({"action": "start_service"}, "type your password (service: Start ufw)")
        if state.get("lastErrorKey"):
            raise CheckFailed("Start ufw: error %s" % state.get("lastErrorKey"))
        state = wait_status("on", "status on after Start ufw")
        problems = on_problems(state, read_text(etc("ufw/ufw.conf")), unit_state(), boot_before)
        if problems:
            raise CheckFailed("after Start ufw: " + "; ".join(problems))
    except Interrupted:
        raise
    except Exception:
        recover_running()
        raise
    return "stopped from outside -> %s; Start ufw -> on (unit active)" % stopped


# ── selftest ─────────────────────────────────────────────────────────────────

FAKE_SUDO = r'''
import os, pathlib, re, signal, sys
root = pathlib.Path(sys.argv[1])
args = sys.argv[2:]
unit = root / "unit"
boot = root / "boot"
log = root / "sudo.log"
cached = root / "sudo-cached"
plain = args[:1] == ["--no-root"]  # the fake systemctl the script runs without sudo
if plain:
    args = args[1:]
if args == ["-n", "true"]:
    sys.exit(0 if cached.exists() else 1)
if not plain:
    cached.touch()  # the password was typed: sudo remembers it
    with log.open("a") as f:
        f.write(" ".join(args) + "\n")
if args[:1] == ["systemctl"] and args[1:2] == ["show"]:
    active = unit.read_text().strip() if unit.exists() else "inactive"
    file_state = boot.read_text().strip() if boot.exists() else "enabled"
    print("ActiveState=%s\nUnitFileState=%s" % (active, file_state))
elif args[:3] == ["systemctl", "start", "ufw"]:
    if (root / "start-fails").exists():
        sys.exit(1)
    trigger = root / "sigint-on-start"
    if trigger.exists():  # Ctrl-C while the script waits for this command
        trigger.unlink()
        os.kill(os.getppid(), signal.SIGINT)
    unit.write_text("active\n")
elif args[:3] == ["systemctl", "stop", "ufw"]:
    unit.write_text("inactive\n")
elif args[:1] == ["cat"] and len(args) == 2:
    sys.stdout.write(pathlib.Path(args[1]).read_text())
elif args[:2] == ["ufw", "--force"] and args[2:3] == ["enable"]:
    conf = root / "ufw/ufw.conf"
    conf.write_text(re.sub(r"ENABLED=\w+", "ENABLED=yes", conf.read_text()))
elif args[:2] == ["ufw", "disable"]:
    conf = root / "ufw/ufw.conf"
    conf.write_text(re.sub(r"ENABLED=\w+", "ENABLED=no", conf.read_text()))
elif args[:4] == ["ufw", "--force", "delete", "allow"] and len(args) == 5:
    port, _, proto = args[4].partition("/")
    proto = proto or "any"

    def drop(name):
        path = root / name
        lines = path.read_text().splitlines(True)
        keep = [l for l in lines if not re.match(r"### tuple ### allow %s %s \S+ any \S+ in( |$)" % (proto, port), l)]
        path.write_text("".join(keep))
        return len(keep) != len(lines)

    stopped = "ENABLED=yes" in (root / "ufw/ufw.conf").read_text() and \
        (not unit.exists() or unit.read_text().strip() != "active")
    if stopped:
        # the real ufw while stopped: writes user.rules, then fails on the unloaded chains
        # and gives up before user6.rules
        if drop("ufw/user.rules"):
            print("ERROR: problem running")
            sys.exit(1)
        if not drop("ufw/user6.rules"):
            print("Could not delete non-existent rule")
            sys.exit(1)
        print("Could not delete non-existent rule\nRule deleted (v6)")
    else:
        drop("ufw/user.rules")
        drop("ufw/user6.rules")
else:
    sys.exit(3)
'''

V4_TEMPLATE = """*filter
### RULES ###

### tuple ### allow tcp 41100 0.0.0.0/0 any 0.0.0.0/0 in
-A ufw-user-input -p tcp --dport 41100 -j ACCEPT

### tuple ### allow tcp 41101 0.0.0.0/0 any 0.0.0.0/0 in comment=6b656570
-A ufw-user-input -p tcp --dport 41101 -j ACCEPT

### END RULES ###
COMMIT
"""

EMPTY_RULES = """*filter
### RULES ###

### END RULES ###
COMMIT
"""


def hexed(text):
    return text.encode().hex()


def _selftest_fresh():
    """fresh()/reloaded()/wait_state on fake snapshots; needs neither ufw nor Noctalia."""
    SENT["seq"], SENT["request"] = 40, 5
    assert not fresh({"seq": 41, "requestSeq": 5}), "same requestSeq is not fresh"
    assert fresh({"seq": 42, "requestSeq": 6}), "higher requestSeq is fresh"
    assert not reloaded({"seq": 40, "requestSeq": 5}), "same seq is no reload"
    assert reloaded({"seq": 3, "requestSeq": 6}), "seq going backwards is a reload"
    assert reloaded({"requestSeq": 6}), "a snapshot without seq is a reload"
    assert reloaded({"seq": 50, "requestSeq": 1}), "requestSeq going backwards is a reload"
    SENT["seq"] = SENT["request"] = None
    assert not reloaded({"seq": 1}), "nothing recorded, nothing to compare"
    SENT["seq"], SENT["request"] = 40, 5
    real = globals()["read_state"]
    try:
        globals()["read_state"] = lambda: {"seq": 2, "requestSeq": 9, "busy": False}
        try:
            wait_state(lambda s: True, timeout=30, poll=0.01)
            raise AssertionError("wait_state did not stop on a reload")
        except Reloaded as err:
            assert "reloaded" in str(err), err
        globals()["read_state"] = lambda: {"seq": 41, "requestSeq": 5, "busy": False}
        try:
            wait_state(lambda s: True, timeout=0.2, poll=0.01)
            raise AssertionError("wait_state accepted a stale snapshot")
        except CheckFailed as err:
            assert "timed out" in str(err) and not isinstance(err, Reloaded), err
        globals()["read_state"] = lambda: {"seq": 45, "requestSeq": 6, "busy": False}
        assert wait_state(idle, timeout=1, poll=0.01)["seq"] == 45, "fresh snapshot accepted"
        assert HIGH == {"seq": 45, "requestSeq": 6} or (HIGH["seq"], HIGH["request"]) == (45, 6), HIGH
        # a reload between two requests: the next send()'s first read sees it
        globals()["read_state"] = lambda: {"seq": 2, "requestSeq": 0, "busy": False}
        SENT["seq"] = SENT["request"] = None
        try:
            current_marks()
            raise AssertionError("current_marks did not see a reload between requests")
        except Reloaded:
            pass
        HIGH["seq"], HIGH["request"] = 45, 6
        globals()["read_state"] = lambda: {"seq": 46, "requestSeq": 5, "busy": False}
        try:
            current_marks()
            raise AssertionError("requestSeq below the run's highest is a reload")
        except Reloaded:
            pass
        globals()["read_state"] = lambda: {"seq": 47, "requestSeq": 6, "busy": False}
        assert current_marks() == (47, 6) and HIGH["seq"] == 47, "going up is no reload"
    finally:
        globals()["read_state"] = real
        SENT["seq"] = SENT["request"] = HIGH["seq"] = HIGH["request"] = None
    say("selftest: fresh/reload ok")


def _selftest_debug():
    """debug_on()/debug_off() in a temporary directory, with a fake service that writes
    state.json only while the marker exists."""
    with tempfile.TemporaryDirectory() as tmp:
        marker, state = pathlib.Path(tmp) / "data" / "debug", pathlib.Path(tmp) / "data" / "state.json"
        state.parent.mkdir()
        state.write_text('{"seq": 999}')

        def poke():
            if marker.exists():
                state.write_text('{"seq": 1}')

        debug_on(marker, state, poke, timeout=2)
        assert marker.exists(), "debug_on creates the marker"
        assert '"seq": 1' in state.read_text(), "debug_on drops a stale state.json and waits for a new one"
        debug_off(marker, state)
        assert not marker.exists() and not state.exists(), "debug_off removes the marker and state.json"
        try:
            debug_on(marker, state, lambda: None, timeout=0.3)
            raise AssertionError("debug_on did not fail without a dump")
        except CheckFailed:
            pass
        debug_off(marker, state)
        assert not marker.exists(), "debug_off after a failed debug_on still removes the marker"
    say("selftest: debug marker ok")


def _fake_etc(root_dir, rules_text=V4_TEMPLATE):
    (root_dir / "ufw").mkdir(exist_ok=True)
    (root_dir / "default").mkdir(exist_ok=True)
    (root_dir / "ufw/ufw.conf").write_text("ENABLED=yes\nLOGLEVEL=low\n")
    (root_dir / "default/ufw").write_text('IPV6=yes\nDEFAULT_INPUT_POLICY="DROP"\n')
    (root_dir / "ufw/user.rules").write_text(rules_text)
    (root_dir / "ufw/user6.rules").write_text(rules_text.replace("0.0.0.0/0", "::/0"))
    (root_dir / "unit").write_text("active\n")
    fake = root_dir / "fake_sudo.py"
    fake.write_text(FAKE_SUDO)
    CONF["etc"] = root_dir
    CONF["proc"] = root_dir / "proc"
    CONF["sudo"] = [sys.executable, "-I", str(fake), str(root_dir)]
    CONF["systemctl"] = CONF["sudo"] + ["--no-root", "systemctl"]


def _selftest_restore():
    """record/restore/verify_restored against a temporary /etc and a fake sudo."""
    global _restored
    saved = dict(CONF)
    real_say = globals()["say"]
    with tempfile.TemporaryDirectory() as tmp:
        root_dir = pathlib.Path(tmp)
        _fake_etc(root_dir)
        lines = []
        globals()["say"] = lambda text="": lines.append(str(text))
        CREATED.clear()
        CREATED.update({E2E_PREFIX + "abc123", E2E_PREFIX + "x"})  # as if this run made them
        try:
            rec = record()
            assert set(rec) == set(RECORD_FIELDS), "record has every field"
            assert len(rec["v4_tuples"]) == 2 and rec["unit_active"] == "active", "record reads files and unit"

            # what a test run may leave behind: its own rule, ufw off, the unit stopped,
            # plus an e2e-named rule of a shape the script must not touch
            e2e = "### tuple ### allow tcp 41234 %s any %s in comment=" + hexed(E2E_PREFIX + "abc123") + "\n"
            for name, anywhere in (("ufw/user.rules", "0.0.0.0/0"), ("ufw/user6.rules", "::/0")):
                path = root_dir / name
                path.write_text(path.read_text().replace("### END RULES ###", e2e % (anywhere, anywhere) + "### END RULES ###"))
            (root_dir / "ufw/ufw.conf").write_text("ENABLED=no\nLOGLEVEL=low\n")
            (root_dir / "unit").write_text("inactive\n")
            assert e2e_rules(CREATED) == ([["allow", "41234/tcp"]], 0, 0), "both copies give one delete"
            assert e2e_rules(set()) == ([], 0, 1), "another run's e2e rule is a leftover, not ours"

            lines.clear()
            assert not verify_restored(rec), "a changed state does not verify"
            assert "MISMATCH: conf" in lines and "MISMATCH: v4_tuples" in lines and "MISMATCH: unit_active" in lines, lines
            assert all(l == "match" or l.startswith("MISMATCH: ") for l in lines), "verify prints only match/MISMATCH"

            _restored = False
            restore(rec)
            restore(rec)  # idempotent
            calls = (root_dir / "sudo.log").read_text().splitlines()
            assert calls.count("ufw --force delete allow 41234/tcp") == 1, calls
            assert "ufw --force enable" in calls and "systemctl start ufw" in calls, calls
            assert calls.index("systemctl start ufw") < calls.index("ufw --force delete allow 41234/tcp"), \
                "ufw runs again before the e2e delete: %s" % calls
            assert not any("41100" in c or "41101" in c for c in calls), "restore never touches other rules"

            lines.clear()
            assert verify_restored(rec), lines
            assert lines == ["match"] * len(RECORD_FIELDS), lines

            # never delete: another comment, or an e2e comment on a shape it can't rebuild
            other = "### tuple ### allow tcp 41300 0.0.0.0/0 any 0.0.0.0/0 in comment=" + hexed("noctalia-ufw-e3e-x")
            odd = "### tuple ### allow tcp 41301 0.0.0.0/0 any 192.0.2.0/24 in comment=" + hexed(E2E_PREFIX + "x")
            assert e2e_delete_spec(other) is None and e2e_delete_spec(odd) is None
            assert e2e_delete_spec(e2e % ("::/0", "::/0")) == ["allow", "41234/tcp"]
            path = root_dir / "ufw/user.rules"
            path.write_text(path.read_text().replace("### END RULES ###", odd + "\n### END RULES ###"))
            (root_dir / "ufw/ufw.conf").write_text("ENABLED=no\nLOGLEVEL=low\n")
            (root_dir / "unit").write_text("inactive\n")
            (root_dir / "sudo.log").write_text("")
            _restored = False
            try:
                restore(rec)
                raise AssertionError("restore did not fail on an e2e rule it can't delete")
            except RuntimeError as err:
                assert "by hand" in str(err) and "41301" not in str(err), err
            calls = (root_dir / "sudo.log").read_text().splitlines()
            assert "ufw --force enable" in calls and "systemctl start ufw" in calls, \
                "an undeletable e2e rule still lets restore turn ufw on and start the unit: %s" % calls
            assert conf_enabled((root_dir / "ufw/ufw.conf").read_text()), "ufw is back on"

            # a failing delete (fake sudo exits 3 for an unknown spec) does not stop the rest
            path.write_text(V4_TEMPLATE.replace("### END RULES ###",
                                                (e2e % ("0.0.0.0/0", "0.0.0.0/0")).replace("allow tcp", "allow udp")
                                                + "### END RULES ###"))
            (root_dir / "ufw/ufw.conf").write_text("ENABLED=no\nLOGLEVEL=low\n")
            real_delete = globals()["delete_e2e_rule"]

            def failing_delete(spec):
                raise RuntimeError("`sudo ufw --force delete` failed (exit 1)")

            globals()["delete_e2e_rule"] = failing_delete
            _restored = False
            try:
                restore(rec)
                raise AssertionError("restore hid a failed delete")
            except RuntimeError as err:
                assert "delete" in str(err) and "1 e2e rule(s) of this run are still there" in str(err), err
            finally:
                globals()["delete_e2e_rule"] = real_delete
            assert conf_enabled((root_dir / "ufw/ufw.conf").read_text()), "a failed delete still re-enables ufw"

            # Turn off through the plugin only stops the unit: restore starts it again and
            # touches neither ufw.conf nor the boot setting
            (root_dir / "ufw/ufw.conf").write_text("ENABLED=yes\nLOGLEVEL=low\n")
            (root_dir / "unit").write_text("inactive\n")
            (root_dir / "sudo.log").write_text("")
            path.write_text(V4_TEMPLATE)
            (root_dir / "ufw/user6.rules").write_text(V4_TEMPLATE.replace("0.0.0.0/0", "::/0"))
            _restored = False
            restore(rec)
            calls = (root_dir / "sudo.log").read_text().splitlines()
            assert "systemctl start ufw" in calls, calls
            assert not any(c.startswith("ufw ") or "enable" in c or "disable" in c for c in calls), calls
            assert unit_state() == ("active", "enabled")
            assert stopped_problems({"status": "stopped"}, "ENABLED=yes\n", ("inactive", "enabled"), "enabled") == []
            assert len(stopped_problems({"status": "off"}, "ENABLED=no\n", ("active", "disabled"), "enabled")) == 4
            assert stopped_problems({"status": "not_running"}, "ENABLED=yes\n", ("inactive", "disabled"), "disabled",
                                    "not_running") == []
            assert on_problems({"status": "on"}, "ENABLED=yes\n", ("active", "enabled"), "enabled") == []
            assert len(on_problems({"status": "stopped", "lastErrorKey": "error.timeout"}, "ENABLED=no\n",
                                   ("inactive", "disabled"), "enabled")) == 5
            fake_stop = subprocess.run(CONF["sudo"] + ["systemctl", "stop", "ufw"]).returncode
            assert fake_stop == 0 and unit_state()[0] == "inactive"

            # a turned-off-at-start firewall is turned back off
            (root_dir / "ufw/user.rules").write_text(V4_TEMPLATE)
            rec_off = record()
            rec_off["conf"] = "ENABLED=no\nLOGLEVEL=low\n"
            _restored = False
            restore(rec_off)
            assert "ufw disable" in (root_dir / "sudo.log").read_text().splitlines()

            # 0 rules: record, restore and verify work on empty rules files
            for name in RULES_FILES:
                (root_dir / name).write_text(EMPTY_RULES)
            (root_dir / "unit").write_text("active\n")
            rec_empty = record()
            assert rec_empty["v4_tuples"] == [] and rec_empty["v6_tuples"] == []
            for name, anywhere in (("ufw/user.rules", "0.0.0.0/0"), ("ufw/user6.rules", "::/0")):
                (root_dir / name).write_text(EMPTY_RULES.replace("### END RULES ###",
                                                                 e2e % (anywhere, anywhere) + "### END RULES ###"))
            _restored = False
            restore(rec_empty)
            lines.clear()
            assert verify_restored(rec_empty), lines

            # ufw stopped (ENABLED=yes, unit inactive) and recorded so: the real delete writes
            # user.rules only and says "problem running"; once more writes user6.rules
            (root_dir / "ufw/ufw.conf").write_text("ENABLED=yes\nLOGLEVEL=low\n")
            (root_dir / "unit").write_text("inactive\n")
            (root_dir / "sudo.log").write_text("")
            for name in RULES_FILES:
                (root_dir / name).write_text(EMPTY_RULES)
            rec_stopped = record()
            for name, anywhere in (("ufw/user.rules", "0.0.0.0/0"), ("ufw/user6.rules", "::/0")):
                (root_dir / name).write_text(EMPTY_RULES.replace("### END RULES ###",
                                                                 e2e % (anywhere, anywhere) + "### END RULES ###"))
            out = subprocess.run(CONF["sudo"] + ["ufw", "--force", "delete", "allow", "41234/tcp"],
                                 capture_output=True, text=True)
            assert out.returncode == 1 and out.stdout.rstrip().endswith("problem running"), out
            assert not tuples((root_dir / "ufw/user.rules").read_text()) and \
                tuples((root_dir / "ufw/user6.rules").read_text()), "the fake models the IPv4-only write"
            (root_dir / "ufw/user.rules").write_text(EMPTY_RULES.replace(
                "### END RULES ###", e2e % ("0.0.0.0/0", "0.0.0.0/0") + "### END RULES ###"))
            (root_dir / "sudo.log").write_text("")
            _restored = False
            restore(rec_stopped)
            calls = (root_dir / "sudo.log").read_text().splitlines()
            assert calls == ["ufw --force delete allow 41234/tcp"] * 2, calls
            lines.clear()
            assert verify_restored(rec_stopped), lines

            # an e2e rule an earlier run left: reported, never deleted, and verify still matches
            (root_dir / "unit").write_text("active\n")
            old = "### tuple ### allow tcp 41235 %s any %s in comment=" + hexed(E2E_PREFIX + "0ld0ld") + "\n"
            for name, anywhere in (("ufw/user.rules", "0.0.0.0/0"), ("ufw/user6.rules", "::/0")):
                (root_dir / name).write_text(EMPTY_RULES.replace("### END RULES ###",
                                                                 old % (anywhere, anywhere) + "### END RULES ###"))
            rec_left = record()
            (root_dir / "sudo.log").write_text("")
            lines.clear()
            _restored = False
            restore(rec_left)
            assert "restore: found 1 leftover e2e rule(s) from an earlier run; remove by hand" in lines, lines
            assert (root_dir / "sudo.log").read_text() == "", "a leftover is never deleted"
            lines.clear()
            assert verify_restored(rec_left), lines
        finally:
            CONF.clear()
            CONF.update(saved)
            CREATED.clear()
            globals()["say"] = real_say
            _restored = False
    handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        on_signal(signal.SIGTERM, None)
        raise AssertionError("on_signal did not raise")
    except Interrupted:
        assert signal.getsignal(signal.SIGINT) == signal.SIG_IGN == signal.getsignal(signal.SIGTERM), \
            "on_signal ignores further signals before it raises"
    finally:
        for sig, handler in handlers.items():
            signal.signal(sig, handler)
    say("selftest: record/restore ok")


def _selftest_ports():
    """Free-port pick: never a covered port (single, list, range), a used socket or a port
    this run used; 0 rules is fine."""
    saved = dict(CONF)
    with tempfile.TemporaryDirectory() as tmp:
        net = pathlib.Path(tmp) / "net"
        net.mkdir()
        (net / "tcp").write_text("  sl  local_address rem_address   st\n"
                                 "   0: 0100007F:C351 00000000:0000 0A\n")  # 50001
        CONF["proc"] = pathlib.Path(tmp)
        try:
            lines = ["### tuple ### allow tcp 49152:49999 0.0.0.0/0 any 0.0.0.0/0 in",
                     "### tuple ### allow tcp 50002,50003 0.0.0.0/0 any 0.0.0.0/0 in",
                     "### tuple ### allow any 22 0.0.0.0/0 any 10.0.0.0/8 in",
                     "### tuple ### allow any any 0.0.0.0/0 any 192.0.2.0/24 in"]
            assert covered(lines) == [(49152, 49999), (50002, 50002), (50003, 50003), (22, 22)], covered(lines)
            assert local_ports() == {50001}
            real_range = globals()["PORT_RANGE"]
            globals()["PORT_RANGE"] = (49998, 50004)
            USED_PORTS.clear()
            try:
                got = {pick_port(lines) for _ in range(2)}
                assert got == {50000, 50004}, got
                try:
                    pick_port(lines)
                    raise AssertionError("pick_port reused a port")
                except CheckFailed as err:
                    assert "no free port" in str(err)
                USED_PORTS.clear()
                assert pick_port([]) in (49998, 49999, 50000, 50002, 50003, 50004), "0 rules: any unused port"
            finally:
                globals()["PORT_RANGE"] = real_range
                USED_PORTS.clear()
        finally:
            CONF.clear()
            CONF.update(saved)
    say("selftest: free port ok")


class FakePlugin:
    """The service as the live script sees it: IPC requests in, state.json (the debug view)
    out while the marker exists. Root actions edit the temporary /etc as pkexec would, at
    once (the user "types the password"), except the Saves listed in cancel_saves."""

    def __init__(self, root_dir, marker, path):
        self.root, self.marker, self.path = root_dir, marker, path
        self.seq = self.request_seq = 0
        self.pending, self.next_id = [], 0
        self.error = self.notice = None
        self.saves = 0
        self.cancel_saves = set()
        self.cancel_actions = set()  # root actions whose prompt the "user" cancels
        self.hooks = {}  # action -> fn(fake), run after the request was handled and published
        self.actions = []
        self.reload_at = None  # the request count at which the service "restarts"
        self.sigint_at = None  # (action, n): send SIGINT to this process after its n-th call
        self.before_read = None  # called before each read of state.json by the script

    def read(self, name):
        return (self.root / name).read_text()

    def unit(self):
        active = (self.root / "unit").read_text().strip()
        boot = self.root / "boot"
        return active, boot.read_text().strip() if boot.exists() else "enabled"

    def rules(self):
        """One rule per v4/v6 tuple pair (addresses folded together)."""
        seen = []
        for name in RULES_FILES:
            for line in tuples(self.read(name)):
                key = line.replace("::/0", "0.0.0.0/0")
                if key not in seen:
                    seen.append(key)
        return seen

    def status(self):
        enabled = conf_enabled(self.read("ufw/ufw.conf"))
        active, boot = self.unit()
        if not enabled:
            return "off"
        if active == "active":
            return "on"
        if active == "failed":
            return "failed"
        return "stopped" if active == "inactive" and boot == "enabled" else "not_running"

    def view(self):
        rules = self.rules()
        e2e = {}
        for i, line in enumerate(rules):
            comment = tuple_comment(line)
            if comment and comment.startswith(E2E_PREFIX):
                e2e[comment] = "r%d" % i
        active, boot = self.unit()
        return {
            "seq": self.seq, "requestSeq": self.request_seq, "status": self.status(),
            "enabled": conf_enabled(self.read("ufw/ufw.conf")), "unitActive": active,
            "bootEnabled": boot == "enabled", "ruleCount": len(rules), "allowedCount": len(rules),
            "pendingCount": len(self.pending), "pendingKinds": [op["kind"] for op in self.pending],
            "busy": False, "lastErrorKey": self.error, "noticeKey": self.notice,
            "e2eRuleIds": e2e or [], "source": "files", "testMode": False, "busyAction": None,
        }

    def publish(self):
        self.seq += 1
        if self.marker.exists():
            self.path.write_text(json.dumps(self.view()))

    def edit_rules(self, add=None, drop=None):
        ipv6 = ipv6_on(self.read("default/ufw"))
        for name, anywhere in (("ufw/user.rules", "0.0.0.0/0"), ("ufw/user6.rules", "::/0")):
            text = self.read(name)
            if add is not None and (name == "ufw/user.rules" or ipv6):
                port, comment = add
                text = text.replace("### END RULES ###",
                                    "### tuple ### allow tcp %d %s any %s in comment=%s\n\n### END RULES ###"
                                    % (port, anywhere, anywhere, hexed(comment)))
            if drop is not None:
                text = "".join(l for l in text.splitlines(True)
                               if l.rstrip().replace("::/0", "0.0.0.0/0") != drop)
            (self.root / name).write_text(text)

    def save(self):
        if not self.pending:
            return
        self.saves += 1
        if self.saves in self.cancel_saves:
            self.notice = "notice.cancelled"
            return
        stopped = self.status() != "on"
        for op in self.pending:
            if op["kind"] == "add":
                self.edit_rules(add=(op["port"], op["comment"]))
            else:
                self.edit_rules(drop=op["line"])
        self.pending = []
        self.notice = "notice.saved_not_live" if stopped else None

    def handle(self, request):
        action = request["action"]
        self.error = None
        if action == "stage_add":
            self.next_id += 1
            self.pending.append({"kind": "add", "port": request["port"], "comment": request["comment"]})
            return
        if action == "stage_remove":
            rules = self.rules()
            index = int(str(request["rule"])[1:])
            self.pending.append({"kind": "remove", "line": rules[index]})
            return
        if action == "discard":
            self.pending = []
            return
        if action == "refresh":
            return
        self.notice = None
        if action in self.cancel_actions:
            self.notice = "notice.cancelled"
            return
        if action == "save":
            self.save()
        elif action == "disable":
            (self.root / "unit").write_text("inactive\n")
        elif action in ("enable", "start_service"):
            (self.root / "unit").write_text("active\n")
        elif action in ("load_rules", "enable_at_boot"):
            pass
        else:
            self.error = "error.unknown_action"

    def dispatch(self, request):
        action = request["action"]
        self.actions.append(action)
        self.handle(request)
        self.request_seq += 1
        if self.reload_at is not None and len(self.actions) == self.reload_at:
            self.seq = self.request_seq = 0  # a hot reload: the new service starts from 0
        self.publish()
        hook = self.hooks.pop(action, None)
        if hook is not None:
            hook(self)
        if self.sigint_at and self.sigint_at[0] == action:
            self.sigint_at = (action, self.sigint_at[1] - 1)
            if self.sigint_at[1] == 0:
                self.sigint_at = None
                os.kill(os.getpid(), signal.SIGINT)  # the real handler raises Interrupted
        return True, "dispatched"


def _fake_run(argv, rules_text=V4_TEMPLATE, setup=None, fixture=False, pending=0, ask_fn=None, real_ipc=False):
    """main(argv) against a temporary /etc, a fake sudo and a FakePlugin; returns
    (exit code, output lines, fake, root dir state after the run)."""
    global _restored
    saved_conf = dict(CONF)
    patched = ("say", "ask", "dispatch", "read_state", "STATE", "DEBUG_MARKER", "FIXTURE_ROOT")
    saved = {name: globals()[name] for name in patched}
    handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
    lines = []
    with tempfile.TemporaryDirectory() as tmp:
        root_dir = pathlib.Path(tmp)
        _fake_etc(root_dir, rules_text)
        (root_dir / "sudo-cached").unlink(missing_ok=True)
        data = root_dir / "data"
        data.mkdir()
        fake = FakePlugin(root_dir, data / "debug", data / "state.json")
        for i in range(pending):
            fake.pending.append({"kind": "add", "port": 41500 + i, "comment": "user"})
        if fixture:
            (data / "fixture-root").write_text(str(root_dir))
        if setup is not None:
            setup(fake, root_dir)
        real_read = saved["read_state"]

        def read_state():
            if fake.before_read is not None:
                fake.before_read()
            return real_read()

        globals().update(say=lambda text="": lines.append(str(text)),
                         ask=ask_fn or (lambda text: lines.append(text) or ""),
                         dispatch=saved["dispatch"] if real_ipc else fake.dispatch, read_state=read_state,
                         STATE=data / "state.json", DEBUG_MARKER=data / "debug",
                         FIXTURE_ROOT=data / "fixture-root")
        _restored = False
        SENT["seq"] = SENT["request"] = None
        USED_PORTS.clear()
        try:
            code = main(argv)
        finally:
            globals().update(saved)
            CONF.clear()
            CONF.update(saved_conf)
            for sig, handler in handlers.items():
                signal.signal(sig, handler)
            _restored = False
            SENT["seq"] = SENT["request"] = HIGH["seq"] = HIGH["request"] = None
            CREATED.clear()
        after = {
            "marker": (data / "debug").exists() or (data / "state.json").exists(),
            "unit": (root_dir / "unit").read_text().strip(),
            "conf": (root_dir / "ufw/ufw.conf").read_text(),
            "e2e": sum(1 for name in RULES_FILES for l in tuples((root_dir / name).read_text())
                       if (tuple_comment(l) or "").startswith(E2E_PREFIX)),
            "sudo": (root_dir / "sudo.log").read_text().splitlines() if (root_dir / "sudo.log").exists() else [],
        }
    return code, lines, fake, after


def _results(lines):
    return {l.split()[1]: l.split()[0] for l in lines if l.split()[:1] in (["PASS"], ["FAIL"], ["SKIP"])}


def _selftest_checks():
    """Every check against the fake plugin: a full --toggle --service run (with rules and
    with none), Cancel answered wrong, a reload mid-run, Ctrl-C mid-check, test mode."""
    full = ["--toggle", "--service"]
    names = ["baseline", "save_add_remove", "save_cancel", "load_rules", "enable_at_boot", "toggle", "service"]

    def cancel_third(fake, _root):
        fake.cancel_saves = {3}

    for rules_text in (V4_TEMPLATE, EMPTY_RULES):
        code, lines, fake, after = _fake_run(full, rules_text, cancel_third)
        assert code == 0, lines
        assert _results(lines) == {name: "PASS" for name in names}, lines
        assert lines.count("match") == len(RECORD_FIELDS) and not any("MISMATCH" in l for l in lines), lines
        assert not after["marker"] and after["unit"] == "active" and after["e2e"] == 0, after
        assert after["sudo"] == ["systemctl stop ufw"], "the only sudo call is the outside stop: %s" % after["sudo"]
        assert fake.actions.count("save") == 5 and "discard" in fake.actions, fake.actions
        for action in ("disable", "enable", "start_service", "load_rules", "enable_at_boot"):
            assert fake.actions.count(action) == 1, (action, fake.actions)
        plan = "\n".join(lines[:lines.index("Press Enter to start, or Ctrl-C to quit without changing anything: ")])
        assert "password prompts to expect: 11 (pkexec 10, sudo up to 1)" in plan, plan
        assert "across three prompts (two Saves and Turn on)" in plan and "may also ask for your sudo password" in plan, plan
        assert "prompt 3 (save_cancel): press CANCEL" in plan, plan
        assert "password prompts this run caused: 11 (pkexec 10, sudo 1)" in lines, lines
        assert any(l.split()[:3] == ["PASS", "save_add_remove", "2"] for l in lines), lines
        assert any(l.split()[:3] == ["PASS", "toggle", "4"] for l in lines), lines
        assert any(l.split()[:3] == ["PASS", "service", "2"] for l in lines), lines
        # the plugin's own rules and the user's: never printed
        assert not any(re.search(r"\b4110[01]\b", l) for l in lines), "a user rule's port was printed"
        assert not any(re.search(r"\bkeep\b", l) or "6b656570" in l for l in lines), "a user rule's comment was printed"

    # no flags: the four default checks; a unit not enabled at boot skips enable_at_boot
    def boot_disabled(fake, root_dir):
        fake.cancel_saves = {3}
        (root_dir / "boot").write_text("disabled\n")

    code, lines, fake, after = _fake_run([], setup=boot_disabled)
    assert code == 0 and _results(lines) == {"baseline": "PASS", "save_add_remove": "PASS", "save_cancel": "PASS",
                                             "load_rules": "PASS", "enable_at_boot": "SKIP"}, lines
    assert "enable_at_boot" not in fake.actions and after["sudo"] == [], (fake.actions, after)
    assert "password prompts to expect: 4 (pkexec 4, sudo up to 0)" in lines, lines

    # amber, not red, after a stop when the unit does not start at boot
    code, lines, _, after = _fake_run(["--only", "toggle", "service"] + full, setup=boot_disabled)
    assert code == 0 and _results(lines) == {"toggle": "PASS", "service": "PASS"}, lines
    assert any("off -> not_running" in l for l in lines), lines

    # the prompt that should be cancelled is answered: save_cancel fails, restore removes the rule
    code, lines, _, after = _fake_run(["--only", "save_cancel"])
    assert code == 1 and _results(lines) == {"save_cancel": "FAIL"}, lines
    assert any("password typed instead of Cancel" in l for l in lines), lines
    assert after["e2e"] == 0 and "restore: deleted 1 e2e rule(s), 0 left" in lines, lines
    assert not any("MISMATCH" in l for l in lines), lines

    # a save that never reaches the files fails the check (and restore has nothing to delete)
    def lost_save(fake, _root):
        fake.save = lambda: (fake.pending.clear(), setattr(fake, "notice", None))

    code, lines, _, after = _fake_run(["--only", "save_add_remove"], setup=lost_save)
    assert code == 1 and _results(lines) == {"save_add_remove": "FAIL"} and after["e2e"] == 0, lines
    assert any("0 copies in user.rules" in l for l in lines), lines

    # Save while stopped without the "takes effect when ufw is turned on" notice: toggle fails,
    # and the unit is started again at once (sudo), before the restore
    def no_notice(fake, _root):
        real = fake.save

        def save():
            real()
            if fake.notice == "notice.saved_not_live":
                fake.notice = None
        fake.save = save

    code, lines, _, after = _fake_run(["--only", "toggle", "--toggle"], setup=no_notice)
    assert not any("leftover" in l for l in lines), "this run's own rule is no leftover"
    assert code == 1 and _results(lines) == {"toggle": "FAIL"}, lines
    assert any("save_while_stopped: after the add: notice None, not notice.saved_not_live" in l for l in lines), lines
    assert any(l == "recovering: starting the ufw unit again now" for l in lines), lines
    assert after["sudo"][0] == "systemctl start ufw" and after["unit"] == "active" and after["e2e"] == 0, after
    assert len(after["sudo"]) == 2 and re.fullmatch(r"ufw --force delete allow \d+/tcp", after["sudo"][1]), \
        "restore then deletes the e2e rule the failed check had saved: %s" % after["sudo"]
    assert "password prompts this run caused: 3 (pkexec 2, sudo 1)" in lines, lines

    # Ctrl-C while recover_running waits for `sudo systemctl start ufw`: the run stops (it
    # does not go on to the next check), and restore starts the unit and deletes the rule
    def interrupt_recovery(fake, root_dir):
        no_notice(fake, root_dir)
        (root_dir / "sigint-on-start").touch()

    code, lines, fake, after = _fake_run(["--only", "toggle", "service"] + full, setup=interrupt_recovery)
    assert code == 130 and any(l.startswith("interrupted (signal %d)" % signal.SIGINT) for l in lines), lines
    assert _results(lines) == {} and "start_service" not in fake.actions, (lines, fake.actions)
    assert not any(l.startswith("recovering failed") for l in lines), lines
    assert after["unit"] == "active" and after["e2e"] == 0 and not after["marker"], after
    assert lines.count("match") == len(RECORD_FIELDS), lines

    # Ctrl-C while tidy_plugin discards between checks: the run stops there
    def stuck_save(fake, _root):
        fake.save = lambda: setattr(fake, "error", "error.save_partial")
        fake.sigint_at = ("discard", 1)

    code, lines, fake, after = _fake_run(["--only", "save_add_remove", "save_cancel"], setup=stuck_save)
    assert code == 130 and _results(lines) == {"save_add_remove": "FAIL"}, lines
    assert fake.actions.count("stage_add") == 1 and fake.pending == [], fake.actions
    assert lines.count("match") == len(RECORD_FIELDS) and not after["marker"], lines

    # a reload between stage_add and save: the save is never sent, the run stops
    def reload_between(fake, _root):
        def after_stage(f):
            reads = {"n": 0}

            def before_read():
                reads["n"] += 1
                if reads["n"] == 2:  # 1: stage_add's wait; 2: the save's send()
                    f.before_read = None
                    f.seq = f.request_seq = 0
                    f.pending = []
                    f.publish()
            f.before_read = before_read
        fake.hooks["stage_add"] = after_stage

    code, lines, fake, after = _fake_run(["--only", "save_add_remove", "save_cancel"], setup=reload_between)
    assert code == 1 and _results(lines) == {"save_add_remove": "FAIL"}, lines
    assert any(l.startswith("stopping:") and "reloaded" in l for l in lines), lines
    assert "save" not in fake.actions and fake.actions.count("stage_add") == 1, fake.actions
    assert lines.count("match") == len(RECORD_FIELDS) and not after["marker"], lines

    # noctalia missing, or not answering: a clean "cannot start", then restore and verify
    def no_noctalia(_fake, root_dir):
        CONF["noctalia"] = [str(root_dir / "no-such-noctalia")]

    code, lines, _, after = _fake_run(full, setup=no_noctalia, real_ipc=True)
    assert code == 1 and "cannot start: cannot reach noctalia: the `noctalia` command was not found" in lines, lines
    assert lines.count("match") == len(RECORD_FIELDS) and not after["marker"] and after["sudo"] == [], (lines, after)

    def hanging_noctalia(_fake, root_dir):
        script = root_dir / "slow-noctalia"
        script.write_text("#!/bin/sh\nexec sleep 5\n")
        script.chmod(0o755)
        CONF["noctalia"] = [str(script)]

    real_timeout = globals()["IPC_TIMEOUT_S"]
    globals()["IPC_TIMEOUT_S"] = 0.3
    try:
        code, lines, _, after = _fake_run(full, setup=hanging_noctalia, real_ipc=True)
    finally:
        globals()["IPC_TIMEOUT_S"] = real_timeout
    assert code == 1 and any(l.startswith("cannot start: cannot reach noctalia: `noctalia msg` did not answer")
                             for l in lines), lines
    assert lines.count("match") == len(RECORD_FIELDS) and not after["marker"], lines

    # Turn off cancelled by mistake: toggle fails at once, saying so
    def cancel_turn_off(fake, _root):
        fake.cancel_actions = {"disable"}

    started = time.time()
    code, lines, fake, after = _fake_run(["--only", "toggle", "--toggle"], setup=cancel_turn_off)
    assert code == 1 and any("the password prompt for disable was cancelled" in l for l in lines), lines
    assert time.time() - started < 10 and "save" not in fake.actions and after["sudo"] == [], (fake.actions, after)

    # the plugin's cleanup failing never skips the restore
    def tidy_breaks(fake, _root):
        fake.cancel_saves = {3}
        real = fake.dispatch

        def dispatch(request):
            if request["action"] == "discard":
                raise subprocess.TimeoutExpired("noctalia", 10)
            return real(request)
        fake.dispatch = dispatch
        fake.sigint_at = ("stage_add", 1)

    code, lines, fake, after = _fake_run(["--only", "save_add_remove"], setup=tidy_breaks)
    assert code == 130 and any(l.startswith("cleanup in the plugin failed") for l in lines), lines
    assert lines.count("match") == len(RECORD_FIELDS) and not after["marker"], lines

    # a hot reload mid-run stops the run at once and restores
    def reload_on_save(fake, _root):
        fake.reload_at = 3  # refresh, stage_add, save

    code, lines, fake, after = _fake_run(full, setup=reload_on_save)
    assert code == 1 and _results(lines) == {"baseline": "PASS", "save_add_remove": "FAIL"}, lines
    assert any(l.startswith("stopping:") and "reloaded" in l for l in lines), lines
    assert "disable" not in fake.actions and after["e2e"] == 0 and not after["marker"], (fake.actions, after)

    # Ctrl-C while ufw is stopped with the e2e rule saved: restore deletes it, starts the unit
    def sigint_mid_toggle(fake, _root):
        fake.sigint_at = ("save", 1)

    code, lines, fake, after = _fake_run(["--only", "toggle", "--toggle"], setup=sigint_mid_toggle)
    assert code == 130 and any(l.startswith("interrupted (signal %d)" % signal.SIGINT) for l in lines), lines
    assert "enable" not in fake.actions, "nothing runs after Ctrl-C: %s" % fake.actions
    assert after["unit"] == "active" and after["e2e"] == 0 and not after["marker"], after
    assert "systemctl start ufw" in after["sudo"] and "ufw --force delete allow" in " ".join(after["sudo"]), after
    deletes = [i for i, c in enumerate(after["sudo"]) if c.startswith("ufw --force delete")]
    assert len(deletes) == 1 and after["sudo"].index("systemctl start ufw") < deletes[0], \
        "the unit runs again before the delete, so one delete writes both files: %s" % after["sudo"]
    assert lines.count("match") == len(RECORD_FIELDS) and not any("MISMATCH" in l for l in lines), lines

    # a restore that fails (the unit won't start) is loud, and verify still runs and names it
    def start_fails(fake, root_dir):
        fake.sigint_at = ("save", 1)
        (root_dir / "start-fails").touch()

    code, lines, fake, after = _fake_run(["--only", "toggle", "--toggle"], setup=start_fails)
    assert code == 130 and any(l.startswith("RESTORE FAILED:") for l in lines), lines
    assert "MISMATCH: unit_active" in lines and lines.count("match") == len(RECORD_FIELDS) - 1, lines
    assert after["unit"] == "inactive" and not after["marker"], after

    # Ctrl-C after the add is only staged: cleanup discards it in the plugin
    def sigint_after_stage(fake, _root):
        fake.sigint_at = ("stage_add", 1)

    code, lines, fake, _ = _fake_run(["--only", "save_add_remove"], setup=sigint_after_stage)
    assert code == 130 and fake.pending == [] and fake.actions[-1] == "discard", (fake.actions, lines)

    # test mode: refuse before recording or touching anything
    code, lines, fake, after = _fake_run(full, fixture=True)
    assert code == 1 and any(l.startswith("refusing to start:") for l in lines), lines
    assert fake.actions == [] and after["sudo"] == [] and not after["marker"], (fake.actions, after)

    # staged changes of the user's own: refuse, and never discard them
    code, lines, fake, after = _fake_run(full, pending=2)
    assert code == 1 and any("2 staged change(s)" in l for l in lines), lines
    assert len(fake.pending) == 2 and "discard" not in fake.actions and after["sudo"] == [], (fake.actions, after)

    # Ctrl-C (or end of input) at the Enter prompt: nothing changes
    def interrupted_ask(_text):
        raise KeyboardInterrupt

    code, lines, fake, after = _fake_run(full, ask_fn=interrupted_ask)
    assert code == 1 and "nothing was changed" in lines, lines
    assert fake.actions == [] and after["sudo"] == [] and not after["marker"], (fake.actions, after)
    say("selftest: checks ok")


def selftest():
    _selftest_fresh()
    _selftest_debug()
    _selftest_restore()
    _selftest_ports()
    names = [name for name, _, _ in CHECKS]
    assert names == ["baseline", "save_add_remove", "save_cancel", "load_rules", "enable_at_boot",
                     "toggle", "service"], names
    _selftest_checks()
    say("selftest ok")


# ── main ─────────────────────────────────────────────────────────────────────


def tidy_plugin():
    """Before restoring: let a running root action end (a Save whose prompt is still open
    could otherwise add the e2e rule after the restore), then discard what the run staged.
    Called only once the run started with nothing staged, so nothing of the user's goes.
    Never raises: the restore after it must run."""
    try:
        _tidy_plugin()
    except Interrupted:
        raise  # between checks: Ctrl-C stops the run (in the final cleanup signals are ignored)
    except Exception as err:  # noqa: BLE001 - the restore after it must run
        say("cleanup in the plugin failed (%s); restoring anyway" % type(err).__name__)


def _tidy_plugin():
    # nothing is known to run until the service has handled the last request (or says busy)
    deadline = time.time() + 10
    state = read_state()
    while (state is None or not (state.get("busy") or fresh(state) or reloaded(state))) \
            and time.time() < deadline:
        time.sleep(0.2)
        state = read_state()
    if state is not None and state.get("busy"):
        say("waiting for the plugin's running action to end (answer or cancel the open password prompt)")
        deadline = time.time() + PROMPT_WAIT_S
        while state is not None and state.get("busy") and time.time() < deadline:
            time.sleep(0.5)
            state = read_state()
        if state is not None and state.get("busy"):
            say("the plugin is still busy; restoring anyway")
            return
    if state is not None and state.get("pendingCount"):
        dispatch({"action": "discard"})
        say("cleanup: discarded %s staged e2e change(s) in the plugin" % state.get("pendingCount"))


def print_plan(selected, rec):
    """Which checks run, the prompts to expect and the one to cancel."""
    say("checks: %s" % ", ".join(name for name, _, _ in selected))
    total_p = total_s = 0
    rows = []
    for name, _, _ in selected:
        prompts, note = PLAN[name]
        pkexec, sudo = prompts(rec)
        first = total_p + total_s + 1
        total_p, total_s = total_p + pkexec, total_s + sudo
        rows.append((name, pkexec, sudo, note, first))
    say("password prompts to expect: %d (pkexec %d, sudo up to %d)" % (total_p + total_s, total_p, total_s))
    for name, pkexec, sudo, note, first in rows:
        n = pkexec + sudo
        if n:
            say("  %-16s %d   %s" % (name, n, note))
    for name, pkexec, sudo, note, first in rows:
        if name == "save_cancel" and pkexec:
            say("prompt %d (save_cancel): press CANCEL, do not type the password" % first)
    if any(name == "toggle" and pkexec for name, pkexec, _, _, _ in rows):
        say("toggle keeps the firewall down from Turn off until Turn on: across three prompts "
            "(two Saves and Turn on), so answer them promptly")
    if any(name == "service" and pkexec for name, pkexec, _, _, _ in rows):
        say("service keeps the firewall down from the sudo stop until Start ufw (one prompt)")
    say("a failure (or Ctrl-C) may also ask for your sudo password: to start ufw again, or at "
        "the end to remove the e2e rule or put ufw back")
    say("every prompt is announced by a PROMPT line first; nothing else needs you")


def print_summary(results):
    say("\nsummary (password prompts per check):")
    for name, result in results:
        pkexec, sudo = prompts_of(name)
        say("  %-4s  %-16s %d%s" % (result, name, pkexec + sudo, "  (sudo %d)" % sudo if sudo else ""))
    for where in ("record", "restore"):
        pkexec, sudo = prompts_of(where)
        if pkexec + sudo:
            say("        %-16s %d  (sudo %d)" % (where, pkexec + sudo, sudo))
    pkexec = sum(p["pkexec"] for p in PROMPTS.values())
    sudo = sum(p["sudo"] for p in PROMPTS.values())
    say("password prompts this run caused: %d (pkexec %d, sudo %d)" % (pkexec + sudo, pkexec, sudo))


def run(selected, rec):
    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)
    results = []
    exit_code = 0
    may_discard = False
    try:
        CONTEXT["where"] = "start"
        debug_on()  # before the first send(): it reads state.json
        state = read_state() or {}
        if state.get("testMode"):
            raise CheckFailed("the service is in test mode")
        send({"action": "refresh"})
        state = wait_state(idle, timeout=20, what="service idle after refresh")
        say("service: " + summary(state))
        if state.get("pendingCount"):
            raise CheckFailed("the panel has %s staged change(s): Save or Discard them, then run this again"
                              % state.get("pendingCount"))
        may_discard = True
        for name, _, fn in selected:
            CONTEXT["where"] = name
            try:
                detail = fn()
                results.append((name, "PASS"))
                say("PASS  %s%s" % (name, ("   [%s]" % detail) if detail else ""))
            except Skip as why:
                results.append((name, "SKIP"))
                say("SKIP  %s   [%s]" % (name, why))
            except Interrupted:
                raise
            except Reloaded:
                results.append((name, "FAIL"))
                say("FAIL  %s   [reloaded]" % name)
                raise
            except Exception as why:  # noqa: BLE001 - CheckFailed, or an IPC error
                results.append((name, "FAIL"))
                say("FAIL  %s   [%s: %s]" % (name, type(why).__name__, why))
            tidy_plugin()
    except Interrupted as why:
        say("interrupted (%s); restoring" % why)
        exit_code = 130
    except Reloaded as why:
        say("stopping: %s" % why)
        exit_code = 1
    except CheckFailed as why:  # the service never came up, or the run may not start
        say("cannot start: %s" % why)
        exit_code = 1
    finally:
        # nothing may interrupt the cleanup: a second Ctrl-C could leave the marker behind
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        CONTEXT["where"] = "restore"
        try:
            if may_discard:
                tidy_plugin()
            try:
                restore(rec)
            except Exception as err:  # noqa: BLE001 - a failed restore must be loud
                say("RESTORE FAILED: %s" % err)
                exit_code = exit_code or 1
            try:  # always, also after a failed restore: what is still off is named
                if not verify_restored(rec):
                    say("RESTORE INCOMPLETE: see the MISMATCH lines above")
                    exit_code = exit_code or 1
            except Exception as err:  # noqa: BLE001
                say("VERIFY FAILED: %s" % err)
                exit_code = exit_code or 1
        finally:
            debug_off()

    print_summary(results)
    counts = {kind: sum(1 for _, r in results if r == kind) for kind in ("PASS", "FAIL", "SKIP")}
    say("\n%d passed, %d failed, %d skipped" % (counts["PASS"], counts["FAIL"], counts["SKIP"]))
    if exit_code:
        return exit_code
    return 1 if counts["FAIL"] else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--only", nargs="+", metavar="NAME", help="run only these checks")
    for group in GROUPS:
        parser.add_argument("--" + group, action="store_true", help="include the %s checks (user-run)" % group)
    parser.add_argument("--selftest", action="store_true",
                        help="check the script on fake data (no root, no Noctalia) and exit")
    args = parser.parse_args(argv)
    if args.selftest:
        selftest()
        return 0

    known = [name for name, _, _ in CHECKS]
    if args.only:
        unknown = [name for name in args.only if name not in known]
        if unknown:
            parser.error("unknown check(s): %s (known: %s)" % (", ".join(unknown), ", ".join(known)))
    selected = [(name, group, fn) for name, group, fn in CHECKS
                if (not args.only or name in args.only) and (group is None or getattr(args, group))]
    if not selected:
        parser.error("nothing selected (grouped checks need their flag)")
    if FIXTURE_ROOT.exists():
        say("refusing to start: %s exists (the plugin would read fixtures, not /etc)" % FIXTURE_ROOT)
        return 1

    CONTEXT.clear()
    PROMPTS.clear()
    CREATED.clear()
    SENT["seq"] = SENT["request"] = HIGH["seq"] = HIGH["request"] = None
    CONTEXT["where"] = "record"
    try:
        rec = record()
    except (OSError, RuntimeError) as err:  # nothing has moved yet
        say("cannot record the starting state: %s" % err)
        return 1
    CONTEXT["rec"] = rec
    say("recorded: %d v4 and %d v6 tuples, unit %s, %s at boot"
        % (len(rec["v4_tuples"]), len(rec["v6_tuples"]), rec["unit_active"] or "unknown",
           rec["unit_file_state"] or "unknown"))
    print_plan(selected, rec)
    try:
        ask("Press Enter to start, or Ctrl-C to quit without changing anything: ")
    except (EOFError, KeyboardInterrupt):
        say("nothing was changed")
        return 1
    return run(selected, rec)


if __name__ == "__main__":
    sys.exit(main())
