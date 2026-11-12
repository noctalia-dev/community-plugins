#!/usr/bin/env python3
"""Live checks of the LogonBox plugin against the running Noctalia shell.

    python3 logonbox/tests/e2e-live.py --selftest

Each check drives the plugin only through its IPC entry
(`noctalia msg plugin 3dprogramin/logonbox:service all request '<json>'`) and reads
the result from the service's debug snapshot (state.json in its data dir).

The service writes state.json only while the marker file `debug` exists in its data
dir. `with debug_marker():` creates the marker, waits for the first dump, and on exit
(also on an exception) removes the marker and the state.json it caused. The dump
holds no host, account or DNS, but it is still never left on disk.

`with simulate(mode):` writes the `simulate` file (a fake problem state, no real
account data) and always removes it on exit, then asks the service to re-read.

Fresh state only: the service bumps `requestSeq` once it has fully handled a request.
ipc() records it (and `serviceBootId`) before sending, and wait_state() only accepts a
snapshot with a higher requestSeq from the same service start. A hot reload during a
check fails it at once instead of waiting out the timeout.

Safety: ensure_disconnected() runs in main()'s `finally` once any check has sent
connect/disconnect: every connection the CLI reports as
connected or connecting is disconnected through the CLI, so a check always leaves the
VPN down. Nothing printed holds an e-mail, host or IP (scrub()); raw CLI output is
never printed.

Usage:
    python3 logonbox/tests/e2e-live.py             # connect_disconnect, outside_change,
                                                   # busy_refused, simulate_states
    python3 logonbox/tests/e2e-live.py --service   # interactive, user-run (sudo): the plugin
                                                   # follows a LogonBox service stop/start
"""

import argparse
import contextlib
import json
import pathlib
import re
import shutil
import signal
import subprocess
import sys
import time

ENTRY = "3dprogramin/logonbox:service"
DATA_DIR = pathlib.Path.home() / ".local/state/noctalia/plugins/data/3dprogramin/logonbox"
STATE = DATA_DIR / "state.json"
DEBUG_MARKER = DATA_DIR / "debug"
SIMULATE = DATA_DIR / "simulate"
DEBUG_WAIT_S = 10
NOCTALIA_LOG = pathlib.Path.home() / ".cache/noctalia/noctalia.log"
OPT_CLI = "/opt/logonbox-vpn-client/logonbox-vpn-cli"
SIM_MODES = ("not_installed", "service_down", "no_connections", "needs_signin", "reboot_needed", "multi")


class CheckFailed(Exception):
    pass


def scrub(text):
    text = str(text)
    text = re.sub(r"[A-Za-z][\w+.-]*://\S+", "<url>", text)
    text = re.sub(r"[\w.%+-]+@[\w.-]+", "<email>", text)
    text = re.sub(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", "<ip>", text)
    text = re.sub(r"\b[\w-]+(?:\.[\w-]+)*\.[A-Za-z]{2,}\b", "<host>", text)
    return text


def say(text=""):
    print(scrub(text), flush=True)


# ── IPC and state ────────────────────────────────────────────────────────────

VPN_ACTIONS = ("connect", "disconnect")
TOUCHED = {"vpn": False}  # a check sent connect/disconnect: main() then runs ensure_disconnected()
SENT = {"seq": None, "boot": None}  # requestSeq and serviceBootId seen just before the last ipc()

RELOADED = "the plugin reloaded during the check (its code changed?) - re-run the test"


def read_state():
    """The service's last published snapshot, or None while it is missing or mid-write."""
    try:
        return json.loads(STATE.read_text())
    except (OSError, ValueError):
        return None


def dispatch(request):
    """One IPC request; (dispatched?, output)."""
    out = subprocess.run(["noctalia", "msg", "plugin", ENTRY, "all", "request", json.dumps(request)],
                         capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=10)
    text = (out.stdout + out.stderr).strip()
    return out.returncode == 0 and "dispatched" in text, text


def ipc(request):
    """Send one request; records requestSeq/serviceBootId first (when a dump exists)."""
    state = read_state()
    if state is not None:
        SENT["seq"], SENT["boot"] = state.get("requestSeq", -1), state.get("serviceBootId")
    else:
        SENT["seq"], SENT["boot"] = None, None
    if request.get("action") in VPN_ACTIONS:
        TOUCHED["vpn"] = True
    ok, text = dispatch(request)
    if not ok:
        raise CheckFailed("IPC request %s not dispatched: %s" % (request.get("action"), scrub(text)))
    return text


def reloaded(state):
    return SENT["boot"] is not None and state.get("serviceBootId") != SENT["boot"]


def fresh(state):
    return SENT["seq"] is None or state.get("requestSeq", -1) > SENT["seq"]


def summary(state):
    if not state:
        return "none"
    rows = ["%s:%s" % (c.get("id"), c.get("status")) for c in state.get("connections") or []]
    return "seq=%s installed=%s service=%s busy=%s rows=[%s] inFlight=%s lastError=%s simulate=%s" % (
        state.get("requestSeq"), state.get("installed"), state.get("service"), state.get("busy"),
        ",".join(rows), state.get("inFlight"), (state.get("lastError") or {}).get("key"), state.get("simulate"))


def wait_state(pred, timeout=40, poll=0.5, what="condition"):
    """Poll state.json until pred(state) holds on a fresh snapshot from the same service start."""
    deadline = time.time() + timeout
    state = None
    while True:
        state = read_state()
        if state is not None and reloaded(state):
            raise CheckFailed(RELOADED)
        if state is not None and fresh(state):
            try:
                if pred(state):
                    return state
            except (KeyError, TypeError, AttributeError):
                pass
        if time.time() >= deadline:
            raise CheckFailed("timed out after %ss waiting for %s; last state: %s" % (timeout, what, summary(state)))
        time.sleep(poll)


@contextlib.contextmanager
def debug_marker(timeout=DEBUG_WAIT_S):
    """The service writes state.json while this is active. A state.json already there
    is stale (another service start, or a killed run), so it goes first."""
    STATE.unlink(missing_ok=True)
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    DEBUG_MARKER.touch()
    try:
        deadline = time.time() + timeout
        while not STATE.exists():
            if time.time() >= deadline:
                raise CheckFailed("the service wrote no %s within %ss (is the plugin loaded?)" % (STATE, timeout))
            dispatch({"action": "refresh"})  # a refresh publishes, which writes the dump
            for _ in range(10):
                if STATE.exists():
                    break
                time.sleep(0.1)
        yield
    finally:
        DEBUG_MARKER.unlink(missing_ok=True)
        time.sleep(0.3)  # one publish in flight
        STATE.unlink(missing_ok=True)


@contextlib.contextmanager
def simulate(mode, timeout=20):
    """Fake one problem state; the file is always removed on exit and the service re-reads."""
    if mode not in SIM_MODES:
        raise ValueError("unknown simulate mode %r" % mode)
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    SIMULATE.write_text(mode + "\n")
    try:
        ipc({"action": "refresh"})
        wait_state(lambda s: s.get("simulate") == mode, timeout=timeout, what="simulate=%s" % mode)
        yield
    finally:
        SIMULATE.unlink(missing_ok=True)
        try:
            ipc({"action": "refresh"})
            if STATE.exists():
                wait_state(lambda s: s.get("simulate") is None, timeout=timeout, what="simulate off")
        except CheckFailed as err:
            say("warning: %s" % err)


# ── CLI (safety net only) ────────────────────────────────────────────────────


def cli_path():
    return shutil.which("logonbox-vpn-cli") or (OPT_CLI if pathlib.Path(OPT_CLI).exists() else None)


def cli_statuses():
    """{id: status} from `show .*`; the output itself is never printed or kept."""
    cli = cli_path()
    if cli is None:
        return {}
    try:
        out = subprocess.run([cli, "show", ".*"], capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=30)
    except (subprocess.TimeoutExpired, OSError) as err:
        say("warning: could not read connection status (%s)" % type(err).__name__)
        return {}
    statuses, current = {}, None
    for line in out.stdout.splitlines():
        m = re.match(r"\s*Connection:\s*(\d+)\s*$", line)
        if m:
            current = int(m.group(1))
            continue
        m = re.match(r"\s*Status:\s*(\S+)", line)
        if m and current is not None:
            statuses[current] = m.group(1)
    return statuses


def ensure_disconnected():
    """Disconnect every connection that is up or coming up. Runs in `finally`."""
    cli = cli_path()
    if cli is None:
        return
    for conn_id, status in sorted(cli_statuses().items()):
        if status in ("CONNECTED", "CONNECTING", "TEMPORARILY_OFFLINE"):
            say("cleanup: disconnecting connection %d (%s)" % (conn_id, status))
            try:
                subprocess.run([cli, "disconnect", str(conn_id)], capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60)
            except (subprocess.TimeoutExpired, OSError) as err:
                say("warning: disconnect %d failed (%s)" % (conn_id, type(err).__name__))
    left = {i: s for i, s in cli_statuses().items() if s not in ("DISCONNECTED",)}
    if left:
        say("WARNING: still not disconnected: %s" % left)


# ── checks ───────────────────────────────────────────────────────────────────


def log_size():
    try:
        return NOCTALIA_LOG.stat().st_size
    except OSError:
        return 0


def lua_errors_since(offset):
    """Lines Noctalia logged since offset that look like a Lua error from this plugin."""
    try:
        with NOCTALIA_LOG.open("rb") as handle:
            handle.seek(offset)
            text = handle.read().decode("utf-8", "replace")
    except OSError:
        return []
    bad = []
    for line in text.splitlines():
        lower = line.lower()
        # The plugin logs translation keys such as "error.read" at INF: not errors.
        if "logonbox" in lower and ("[err]" in lower or "traceback" in lower or ".luau:" in lower):
            bad.append(line)
    return bad


def selftest():
    """IPC reaches the service: a refresh over IPC is handled (requestSeq goes up) and
    published to state.json; no Lua error from the plugin lands in the log."""
    start = log_size()
    with debug_marker():
        first = wait_state(lambda s: "serviceBootId" in s, timeout=DEBUG_WAIT_S, what="first dump")
        say("service: %s" % summary(first))
        ipc({"action": "refresh"})
        after = wait_state(lambda s: True, timeout=40, what="refresh handled over IPC")
        say("after IPC refresh: %s" % summary(after))
        if after.get("requestSeq", -1) <= first.get("requestSeq", -1):
            raise CheckFailed("requestSeq did not go up")
    errors = lua_errors_since(start)
    if errors:
        for line in errors:
            say("log: %s" % line)
        raise CheckFailed("Noctalia logged %d error line(s) for logonbox" % len(errors))
    say("selftest PASS")


def row0(state):
    for conn in state.get("connections") or []:
        if conn.get("id") == 0:
            return conn
    return None


def status0(state):
    row = row0(state)
    return row.get("status") if row else None


def timed(label, started):
    say("  %s after %.1fs" % (label, time.time() - started))


def check_connect_disconnect():
    """IPC connect -> CONNECTED within 15 s with parsed DNS (count only) -> IPC disconnect."""
    ensure_disconnected()
    ipc({"action": "refresh"})
    wait_state(lambda s: status0(s) == "DISCONNECTED", timeout=15, what="row 0 DISCONNECTED at start")
    t0 = time.time()
    ipc({"action": "connect", "id": 0})
    up = wait_state(lambda s: status0(s) == "CONNECTED", timeout=15, what="row 0 CONNECTED")
    timed("CONNECTED", t0)
    count = row0(up).get("dnsCount")
    if not isinstance(count, int) or count < 1:
        raise CheckFailed("row 0 CONNECTED but dnsCount is %r (expected >= 1)" % (count,))
    say("  dns servers parsed: %d" % count)
    t0 = time.time()
    ipc({"action": "disconnect", "id": 0})
    wait_state(lambda s: status0(s) == "DISCONNECTED", timeout=10, what="row 0 DISCONNECTED")
    timed("DISCONNECTED", t0)


def run_cli(*args):
    cli = cli_path()
    if cli is None:
        raise CheckFailed("logonbox-vpn-cli not found")
    out = subprocess.run([cli] + list(args), capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60)
    if out.returncode != 0:
        raise CheckFailed("logonbox-vpn-cli %s exited %d" % (args[0], out.returncode))


def check_outside_change():
    """A connect/disconnect made outside the plugin reaches state.json via the stream, far
    sooner than the 60 s poll."""
    TOUCHED["vpn"] = True
    ensure_disconnected()
    ipc({"action": "refresh"})
    wait_state(lambda s: status0(s) == "DISCONNECTED", timeout=15, what="row 0 DISCONNECTED at start")
    t0 = time.time()
    run_cli("connect", "0")
    wait_state(lambda s: status0(s) == "CONNECTED", timeout=5, what="CONNECTED after outside connect")
    timed("CONNECTED (outside)", t0)
    t0 = time.time()
    run_cli("disconnect", "0")
    wait_state(lambda s: status0(s) == "DISCONNECTED", timeout=5, what="DISCONNECTED after outside disconnect")
    timed("DISCONNECTED (outside)", t0)


def check_busy_refused():
    """A second action while one is running is refused with error.busy and runs nothing."""
    ensure_disconnected()
    ipc({"action": "refresh"})
    wait_state(lambda s: status0(s) == "DISCONNECTED", timeout=15, what="row 0 DISCONNECTED at start")
    ipc({"action": "connect", "id": 0})
    ipc({"action": "disconnect", "id": 0})
    wait_state(lambda s: (s.get("lastError") or {}).get("key") == "error.busy", timeout=10, poll=0.1,
               what="lastError error.busy")
    say("  second action refused (busy)")
    wait_state(lambda s: status0(s) == "CONNECTED", timeout=40, what="row 0 CONNECTED after busy refusal")
    ipc({"action": "disconnect", "id": 0})
    wait_state(lambda s: status0(s) == "DISCONNECTED", timeout=15, what="row 0 DISCONNECTED")


def sim_expect(mode, pred, text):
    with simulate(mode):
        state = wait_state(pred, timeout=10, what=text)
        say("  %s: %s" % (mode, summary(state)))


def check_simulate_states():
    one = lambda s: len(s.get("connections") or [])
    sim_expect("not_installed", lambda s: s["installed"] is False and one(s) == 0, "installed=false, no rows")
    sim_expect("service_down", lambda s: s["installed"] is True and s["service"] == "down" and one(s) == 0,
               "service=down, no rows")
    sim_expect("no_connections", lambda s: s["installed"] is True and s["service"] == "running" and one(s) == 0,
               "running, no rows")
    sim_expect("needs_signin", lambda s: one(s) == 1 and row0(s)["authorized"] is False, "one unauthorized row")
    sim_expect("reboot_needed", lambda s: s["rebootNeeded"] is True and one(s) == 1, "rebootNeeded, one row")
    sim_expect("multi", lambda s: one(s) == 3 and status0(s) == "CONNECTED", "three rows, row 0 CONNECTED")


CHECKS = (
    ("connect_disconnect", check_connect_disconnect),
    ("outside_change", check_outside_change),
    ("busy_refused", check_busy_refused),
    ("simulate_states", check_simulate_states),
)


def wait_service(want_down, timeout):
    """Wait for service == down (or back to running with a connection list)."""
    if want_down:
        return wait_state(lambda s: s.get("service") == "down", timeout=timeout, what="service down")
    return wait_state(lambda s: s.get("service") == "running" and len(s.get("connections") or []) > 0,
                      timeout=timeout, what="the connection list back")


SERVICE = {"stopped": False}
START_REMINDER = "REMINDER: logonbox-vpn-service may still be stopped - run:  sudo systemctl start logonbox-vpn-service"


def remind_service():
    if SERVICE["stopped"]:
        say(START_REMINDER)


def ask(text):
    say(text)
    input("  press Enter when done: ")


def check_service_restart():
    """Interactive (the user runs the two sudo commands): the plugin follows the LogonBox
    service down and up, and the stream is restarted."""
    ipc({"action": "refresh"})
    wait_state(lambda s: s.get("service") == "running", timeout=15, what="service running at start")
    SERVICE["stopped"] = True  # from the moment the user is asked, assume it may be stopped
    ask("run:  sudo systemctl stop logonbox-vpn-service   (if this script dies, start it again with: sudo systemctl start logonbox-vpn-service)")
    ipc({"action": "refresh"})
    t0 = time.time()
    wait_service(True, 65)
    timed("service=down", t0)
    ask("run:  sudo systemctl start logonbox-vpn-service")
    ipc({"action": "refresh"})
    t0 = time.time()
    wait_service(False, 65)
    timed("list back", t0)
    SERVICE["stopped"] = False
    TOUCHED["vpn"] = True
    t0 = time.time()
    run_cli("connect", "0")
    wait_state(lambda s: status0(s) == "CONNECTED", timeout=5, what="CONNECTED via the restarted stream")
    timed("CONNECTED (outside, after restart)", t0)
    run_cli("disconnect", "0")
    wait_state(lambda s: status0(s) == "DISCONNECTED", timeout=10, what="DISCONNECTED")


def on_sigint(signum, frame):
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    SIMULATE.unlink(missing_ok=True)
    DEBUG_MARKER.unlink(missing_ok=True)
    ensure_disconnected()
    STATE.unlink(missing_ok=True)
    remind_service()
    sys.exit(130)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--selftest", action="store_true", help="check only that IPC reaches the service")
    parser.add_argument("--service", action="store_true",
                        help="interactive: stop/start logonbox-vpn-service yourself (needs sudo)")
    args = parser.parse_args()
    signal.signal(signal.SIGINT, on_sigint)
    signal.signal(signal.SIGTERM, on_sigint)
    failed = 0
    try:
        if args.selftest:
            selftest()
        else:
            checks = (("service_restart", check_service_restart),) if args.service else CHECKS
            start = log_size()
            with debug_marker():
                for name, fn in checks:
                    say("== %s" % name)
                    try:
                        fn()
                        say("PASS %s" % name)
                    except CheckFailed as err:
                        failed += 1
                        say("FAIL %s: %s" % (name, err))
                        remind_service()
                    except Exception as err:  # a crash fails this check, the rest still run
                        failed += 1
                        say("FAIL %s: unexpected %s" % (name, type(err).__name__))
                        remind_service()
            errors = lua_errors_since(start)
            for line in errors:
                say("log: %s" % line)
            if errors:
                failed += 1
                say("FAIL: Noctalia logged %d error line(s) for logonbox" % len(errors))
            say("%d check(s) failed" % failed if failed else "ALL PASS")
    except CheckFailed as err:
        say("FAIL: %s" % err)
        remind_service()
        return 1
    finally:
        SIMULATE.unlink(missing_ok=True)
        if TOUCHED["vpn"] or not args.selftest:
            ensure_disconnected()
        remind_service()
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
