#!/usr/bin/env python3
"""Live checks of the Mullvad plugin against the running Noctalia shell and daemon.

    python3 mullvad/tests/e2e-live.py [--only NAME ...] [--lockdown] [--daemon] [--account]

Each check drives the plugin only through its IPC entry
(`noctalia msg plugin 3dprogramin/mullvad:service all request '<json>'`) and reads
the result twice: from the service's debug snapshot (state.json in its data dir)
and from the `mullvad` CLI directly.

The service writes state.json only while the marker file `debug` exists in its
data dir (the snapshot holds your IP and location). The script creates the marker
before its first request and, in its finally (also on Ctrl-C), removes the marker
and the state.json it caused.

Safety:
  * Every setting a check touches (relay location, multihop and its entry,
    lockdown, auto-connect, connected or not) is read through the CLI first
    (snapshot()) and written back through the CLI (restore()), never through the
    plugin: the user's own starting state, not a fixed baseline. Restore runs in
    try/finally and on SIGINT/SIGTERM, then reads everything back and fails loudly
    if anything differs (`relay get` must match the original text).
  * DNS must resolve before the run starts, and again within 15 s after every
    disconnect and after restore. Disconnecting has left /etc/resolv.conf empty on
    this machine before (NetworkManager manages DNS); if that happens the run stops
    at once and exits 2.
  * Checks in the lockdown, daemon and account groups only run with their flag,
    and those flags are for the user to run, not an agent.

Fresh state only: the service bumps `requestSeq` in its snapshot once it has fully
handled a request. send() records the value before sending and wait_state() only
accepts a snapshot with a higher one, so no check can pass on state left over from
before the plugin acted.

The snapshot also carries `serviceBootId` (unique per service start). send() records
it; if a later snapshot has another one, the plugin hot-reloaded (requestSeq restarted
at 0), and wait_state() fails at once instead of waiting out its timeout. Restore still
runs. `--selftest` checks this logic on fake data.

Anything printed passes through scrub(): no 16-digit run (an account number) is
ever written to the terminal.

Account checks: account_safe (agent-run) only redeems the invalid voucher
INVALID0000 and revokes a device name the account does not have, both refused
without changing anything. account_login (--account, user-run) logs out and back
in through the plugin with MULLVAD_ACCOUNT from the environment; it creates a new
device, and it never prints the number.
"""

import argparse
import json
import os
import pathlib
import re
import signal
import socket
import subprocess
import sys
import time

ENTRY = "3dprogramin/mullvad:service"
DATA_DIR = pathlib.Path.home() / ".local/state/noctalia/plugins/data/3dprogramin/mullvad"
STATE = DATA_DIR / "state.json"
DEBUG_MARKER = DATA_DIR / "debug"
DEBUG_WAIT_S = 10
NOCTALIA_LOG = pathlib.Path.home() / ".cache/noctalia/noctalia.log"
PLUGIN = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = PLUGIN / "tests" / "fixtures"
RESOLV = pathlib.Path("/etc/resolv.conf")
DNS_HOST = "mullvad.net"
DNS_WAIT_S = 15
GROUPS = ("lockdown", "daemon", "account")

CHECKS = []  # (name, group, fn) in registration order


class Skip(Exception):
    pass


class CheckFailed(Exception):
    pass


class DnsBroken(Exception):
    pass


class Interrupted(Exception):
    pass


def check(name, group=None):
    assert group is None or group in GROUPS, group

    def register(fn):
        CHECKS.append((name, group, fn))
        return fn

    return register


def scrub(text):
    return re.sub(r"\d{16,}", lambda m: "#" * len(m.group(0)), str(text))


def say(text=""):
    print(scrub(text), flush=True)


# ── plumbing ─────────────────────────────────────────────────────────────────


def cli(*args, timeout=60):
    """`mullvad <args>` directly; returns stdout (stripped). Never raises on exit code."""
    out = subprocess.run(["mullvad", *args], capture_output=True, text=True, timeout=timeout)
    return out.stdout.strip()


def cli_ok(*args, timeout=60):
    out = subprocess.run(["mullvad", *args], capture_output=True, text=True, timeout=timeout)
    if out.returncode != 0:
        raise RuntimeError("mullvad %s failed: %s" % (" ".join(args), scrub((out.stderr or out.stdout).strip())))
    return out.stdout.strip()


def cli_status():
    """`mullvad status --json`; {} when the daemon is down and prints nothing."""
    text = cli("status", "--json")
    try:
        return json.loads(text) if text else {}
    except ValueError:
        return {}


SENT = {"seq": None, "boot": None}  # requestSeq and serviceBootId seen just before the last send()

RELOADED = "the plugin reloaded during the check (its code changed?) — re-run the test"


def current_marks():
    for _ in range(20):
        state = read_state()
        if state is not None:
            return state.get("requestSeq", -1), state.get("serviceBootId")
        time.sleep(0.1)
    raise CheckFailed("cannot read %s" % STATE)


def dispatch(request):
    """One IPC request; (dispatched?, output)."""
    out = subprocess.run(["noctalia", "msg", "plugin", ENTRY, "all", "request", json.dumps(request)],
                         capture_output=True, text=True, timeout=10)
    text = (out.stdout + out.stderr).strip()
    return out.returncode == 0 and "dispatched" in text, text


def send(request, secret=False):
    """secret: the request holds the account number; no error names it."""
    SENT["seq"], SENT["boot"] = current_marks()
    ok, text = dispatch(request)
    if not ok:
        shown = {"action": request.get("action")} if secret else request
        raise CheckFailed("IPC request %s not dispatched: %s" % (shown, scrub(text)))
    return text


def debug_on(marker=None, state=None, poke=None, timeout=DEBUG_WAIT_S):
    """Create the marker that makes the service write state.json, and wait for its
    first dump. A state.json already there is stale (an older plugin, or a killed
    run) and would carry another serviceBootId, so it goes first."""
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
    """Remove the marker, then the state.json it caused. The service checks the
    marker and writes in one callback, so a short wait covers one in flight."""
    marker, state = marker or DEBUG_MARKER, state or STATE
    marker.unlink(missing_ok=True)
    time.sleep(0.3)
    state.unlink(missing_ok=True)


def read_state():
    """The service's last published snapshot, or None while it is mid-write."""
    try:
        return json.loads(STATE.read_text())
    except (OSError, ValueError):
        return None


def reloaded(state):
    """True when the snapshot comes from another service start than the last send()'s."""
    return SENT["boot"] is not None and state.get("serviceBootId") != SENT["boot"]


def fresh(state):
    """True once the service has handled the request of the last send()
    (same boot id; a reload is caught by reloaded())."""
    return SENT["seq"] is None or state.get("requestSeq", -1) > SENT["seq"]


def wait_state(pred, timeout=40, poll=0.5, what="condition"):
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
            raise CheckFailed("timed out after %ss waiting for %s; last state: %s"
                              % (timeout, what, summary(state)))
        time.sleep(poll)


def _selftest_fresh():
    """fresh()/reloaded() on fake snapshots; needs neither Mullvad nor Noctalia."""
    SENT["seq"], SENT["boot"] = 5, "boot-a"
    assert not fresh({"requestSeq": 5, "serviceBootId": "boot-a"}), "same seq is not fresh"
    assert fresh({"requestSeq": 6, "serviceBootId": "boot-a"}), "higher seq is fresh"
    assert not reloaded({"requestSeq": 6, "serviceBootId": "boot-a"}), "same boot id is no reload"
    assert reloaded({"requestSeq": 0, "serviceBootId": "boot-b"}), "new boot id is a reload"
    assert reloaded({"requestSeq": 0}), "a snapshot without boot id is a reload"
    SENT["boot"] = None
    assert not reloaded({"requestSeq": 0, "serviceBootId": "boot-b"}), "nothing recorded, nothing to compare"
    SENT["seq"], SENT["boot"] = 5, "boot-a"
    real = globals()["read_state"]
    try:
        globals()["read_state"] = lambda: {"requestSeq": 0, "serviceBootId": "boot-b"}
        try:
            wait_state(lambda s: True, timeout=30, poll=0.01)
            raise AssertionError("wait_state did not stop on a reload")
        except CheckFailed as err:
            assert "reloaded" in str(err), err
    finally:
        globals()["read_state"] = real
        SENT["seq"] = SENT["boot"] = None
    _selftest_debug()
    say("selftest ok")


def _selftest_debug():
    """debug_on()/debug_off() in a temporary directory, with a fake service that
    writes state.json only while the marker exists."""
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        marker, state = pathlib.Path(tmp) / "data" / "debug", pathlib.Path(tmp) / "data" / "state.json"
        state.parent.mkdir()
        state.write_text('{"serviceBootId": "stale"}')

        def poke():
            if marker.exists():
                state.write_text('{"serviceBootId": "fresh"}')

        debug_on(marker, state, poke, timeout=2)
        assert marker.exists(), "debug_on creates the marker"
        assert "fresh" in state.read_text(), "debug_on drops a stale state.json and waits for a new one"
        debug_off(marker, state)
        assert not marker.exists() and not state.exists(), "debug_off removes the marker and state.json"
        try:
            debug_on(marker, state, lambda: None, timeout=0.3)
            raise AssertionError("debug_on did not fail without a dump")
        except CheckFailed:
            pass
        debug_off(marker, state)
        assert not marker.exists(), "debug_off after a failed debug_on still removes the marker"


def summary(state):
    if not state:
        return "none"
    tunnel = state.get("tunnel") or {}
    return "seq=%s daemon=%s busy=%s tunnel=%s/%s(%s) exit=%s lastError=%s" % (
        state.get("requestSeq"), state.get("daemon"), state.get("busy"), tunnel.get("state"),
        tunnel.get("country"), tunnel.get("countryCode"), tunnel.get("mullvadExit"), state.get("lastError"))


def dns_ok():
    try:
        socket.getaddrinfo(DNS_HOST, 443)
        return True
    except OSError:
        return False


def resolv_size():
    try:
        return "%d bytes" % RESOLV.stat().st_size
    except OSError as err:
        return "unreadable (%s)" % err


def dns_guard(context):
    """DNS must resolve again within DNS_WAIT_S seconds; otherwise stop the run."""
    deadline = time.time() + DNS_WAIT_S
    while time.time() < deadline:
        if dns_ok():
            return
        time.sleep(1)
    raise DnsBroken(context)


def dns_message(context):
    return ("DNS stopped resolving after disconnect — /etc/resolv.conf may be empty. "
            "Reconnecting Wi-Fi (NetworkManager) fixes it. [%s; /etc/resolv.conf is %s]"
            % (context, resolv_size()))


# ── snapshot / restore (CLI only) ────────────────────────────────────────────


def relay_fields(text=None):
    """`mullvad relay get` as {key: value}, e.g. {"Location": "country ro", "Multihop state": "disabled"}."""
    fields = {}
    for line in (cli_ok("relay", "get") if text is None else text).splitlines():
        if ":" in line:
            key, value = line.split(":", 1)
            fields[key.strip()] = value.strip()
    if "Location" not in fields:
        raise RuntimeError("no Location line in `mullvad relay get`")
    return fields


def custom_list_names():
    """`mullvad custom-list list`: each name on its own line, its locations tab-indented."""
    return [line.rstrip() for line in cli_ok("custom-list", "list").splitlines()
            if line.strip() and not line[0].isspace()]


def location_args(value, list_names):
    """`relay set` (or `relay set entry`) arguments that put a printed location back,
    or None when the text is no form this script can write back.

    `relay get` prints (mullvad 2026.5): any | country se | city got, se |
    city got, se, hostname se-got-wg-001 | <custom list name> (bare; a list that
    no longer exists prints "invalid custom list").
    """
    if value == "any":
        return ["location", "any"]
    match = re.fullmatch(r"country (\S+)", value)
    if match:
        return ["location", match.group(1)]
    match = re.fullmatch(r"city ([^,]+), ([^,]+), hostname (\S+)", value)
    if match:
        return ["location", match.group(2), match.group(1), match.group(3)]
    match = re.fullmatch(r"city ([^,]+), ([^,]+)", value)
    if match:
        return ["location", match.group(2), match.group(1)]
    if value in list_names:
        return ["custom-list", value]
    return None


def on_off(text):
    """The on/off value after the last ':' of a `get` command, as a bool."""
    word = text.rsplit(":", 1)[-1].strip().lower()
    if word not in ("on", "off"):
        raise RuntimeError("cannot read on/off from %r" % text)
    return word == "on"


def read_settings():
    """Every setting any check touches, read through the CLI."""
    text = cli_ok("relay", "get")
    fields = relay_fields(text)
    return {
        "relay_get": text,
        "location": fields["Location"],
        "multihop": fields.get("Multihop state") == "enabled",
        "entry": fields.get("Multihop entry", ""),
        "lists": custom_list_names(),
        "lockdown": on_off(cli_ok("lockdown-mode", "get")),
        "auto_connect": on_off(cli_ok("auto-connect", "get")),
    }


def describe(snap):
    return ("relay location %s, multihop %s, entry %s, lockdown %s, auto-connect %s, %s" % (
        snap["location"], "on" if snap["multihop"] else "off", snap["entry"],
        "on" if snap["lockdown"] else "off", "on" if snap["auto_connect"] else "off",
        "connected" if snap.get("connected") else "disconnected"))


def snapshot():
    """The user's starting state, so restore() can put back exactly that."""
    snap = read_settings()
    for key in ("location", "entry"):
        if location_args(snap[key], snap["lists"]) is None:
            raise RuntimeError("refusing to start: the relay %s is %r, which is not a form this script "
                               "can put back (custom lists: %s). Nothing was changed."
                               % (key, snap[key], ", ".join(snap["lists"]) or "none"))
    snap["connected"] = cli_status().get("state") in ("connected", "connecting")
    return snap


_restored = False


def restore(snap):
    """Write the snapshot back through the CLI, then check it took. Idempotent;
    signals are held meanwhile.

    Lockdown goes off first when the user had it off (so nothing below runs blocked)
    and on last when they had it on. DNS is only checked when traffic may flow.
    """
    global _restored
    if _restored or snap is None:
        return
    _restored = True
    previous = {sig: signal.signal(sig, signal.SIG_IGN) for sig in (signal.SIGINT, signal.SIGTERM)}
    lockdown_back = not snap["lockdown"]  # nothing to put back when the user had it off
    try:
        say("restore: " + describe(snap))
        if not snap["lockdown"]:
            cli_ok("lockdown-mode", "set", "off")
        cli_ok("auto-connect", "set", "on" if snap["auto_connect"] else "off")
        cli_ok("relay", "set", "multihop", "on" if snap["multihop"] else "off")
        cli_ok("relay", "set", "entry", *location_args(snap["entry"], snap["lists"]))
        cli_ok("relay", "set", *location_args(snap["location"], snap["lists"]))
        if snap["connected"]:
            cli_ok("connect", "--wait", timeout=90)
        else:
            cli_ok("disconnect", "--wait", timeout=90)
        if snap["lockdown"]:
            cli_ok("lockdown-mode", "set", "on")
            lockdown_back = True
        if snap["connected"] or not snap["lockdown"]:
            dns_guard("after restore")
        now = read_settings()
        now["connected"] = cli_status().get("state") in ("connected", "connecting")
        wrong = [key for key in ("relay_get", "lockdown", "auto_connect", "connected") if now[key] != snap[key]]
        if wrong:
            raise RuntimeError("restore did not take for %s: now %s" % (", ".join(wrong), describe(now)))
    except Exception as err:
        if lockdown_back:
            raise
        raise RuntimeError("%s; lockdown mode was left OFF (you had it on): turn it back on with "
                           "`mullvad lockdown-mode set on`" % err) from err
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def on_signal(signum, _frame):
    raise Interrupted("signal %d" % signum)


# ── checks ───────────────────────────────────────────────────────────────────

CONTEXT = {}


def tunnel(state):
    return state.get("tunnel") or {}


def connected_where(state, country=None, not_code=None):
    t = tunnel(state)
    if state.get("busy") or t.get("state") != "connected" or t.get("mullvadExit") is not True:
        return False
    if country is not None and t.get("country") != country:
        return False
    if not_code is not None and t.get("countryCode") == not_code:
        return False
    return True


def assert_cli_connected(country=None):
    status = cli_status()
    location = (status.get("details") or {}).get("location") or {}
    if status.get("state") != "connected":
        raise CheckFailed("CLI state is %s" % status.get("state"))
    if location.get("mullvad_exit_ip") is not True:
        raise CheckFailed("CLI mullvad_exit_ip is %s" % location.get("mullvad_exit_ip"))
    if country is not None and location.get("country") != country:
        raise CheckFailed("CLI exit country is %s, want %s" % (location.get("country"), country))
    return location


@check("connect_country")
def connect_country():
    send({"action": "connect", "mode": "country", "country": "se"})
    state = wait_state(lambda s: connected_where(s, country="Sweden"), what="connected in Sweden")
    assert_cli_connected("Sweden")
    CONTEXT["last_code"] = tunnel(state).get("countryCode")
    return "exit %s (%s)" % (tunnel(state).get("hostname"), tunnel(state).get("city"))


@check("connect_my_country")
def connect_my_country():
    state = read_state() or {}
    real = state.get("realLocation")
    if not real or not real.get("country"):
        raise Skip("the service has not seen a real location yet (status shows location: null while "
                   "disconnected), so my_country cannot run")
    want = real["country"]
    names = {c.get("name") for c in state.get("relays") or []}
    expect = want if want in names else None  # else: nearest country, any exit
    send({"action": "connect", "mode": "my_country"})
    state = wait_state(lambda s: connected_where(s, country=expect), what="connected in %s" % (expect or "nearest"))
    assert_cli_connected(expect)
    CONTEXT["last_code"] = tunnel(state).get("countryCode")
    return "real location %s -> exit %s" % (want, tunnel(state).get("country"))


@check("connect_random")
def connect_random():
    before = read_state() or {}
    previous = CONTEXT.get("last_code") or tunnel(before).get("countryCode")
    send({"action": "connect", "mode": "random"})
    state = wait_state(lambda s: connected_where(s, not_code=previous),
                       what="connected outside %s" % previous)
    location = assert_cli_connected(tunnel(state).get("country"))
    if previous is not None and (location.get("hostname") or "").startswith(previous + "-"):
        raise CheckFailed("random exit %s is the previous country %s" % (location.get("hostname"), previous))
    CONTEXT["last_code"] = tunnel(state).get("countryCode")
    return "previous %s -> exit %s" % (previous, tunnel(state).get("country"))


@check("disconnect")
def disconnect():
    send({"action": "disconnect"})
    wait_state(lambda s: not s.get("busy") and tunnel(s).get("state") == "disconnected", what="disconnected")
    status = cli_status()
    if status.get("state") != "disconnected":
        raise CheckFailed("CLI state is %s" % status.get("state"))
    dns_guard("after the disconnect check")
    return "disconnected, DNS resolves"


def settings(state):
    return state.get("settings") or {}


def relay(state):
    return settings(state).get("relay") or {}


def idle(state):
    return not state.get("busy")


@check("multihop")
def multihop():
    send({"action": "set_multihop", "on": True})
    wait_state(lambda s: idle(s) and relay(s).get("multihop") is True, what="settings.relay.multihop on")
    if relay_fields().get("Multihop state") != "enabled":
        raise CheckFailed("CLI multihop state is %s" % relay_fields().get("Multihop state"))
    send({"action": "set_entry", "country": "se"})
    wait_state(lambda s: idle(s) and relay(s).get("entry", {}).get("kind") == "country"
               and relay(s).get("entry", {}).get("country") == "se",
               what="settings.relay.entry country se")
    if relay_fields().get("Multihop entry") != "country se":
        raise CheckFailed("CLI multihop entry is %s" % relay_fields().get("Multihop entry"))
    send({"action": "connect", "mode": "country", "country": "de"})
    state = wait_state(lambda s: connected_where(s, country="Germany") and tunnel(s).get("entryCountry") == "Sweden",
                       what="connected through Sweden to Germany")
    location = assert_cli_connected("Germany")
    if not location.get("entry_hostname"):
        raise CheckFailed("CLI entry_hostname is %r" % location.get("entry_hostname"))
    if location.get("entry_country") != "Sweden":
        raise CheckFailed("CLI entry country is %s, want Sweden" % location.get("entry_country"))
    send({"action": "disconnect"})
    wait_state(lambda s: idle(s) and tunnel(s).get("state") == "disconnected", what="disconnected")
    dns_guard("after the multihop check")
    send({"action": "set_multihop", "on": False})
    wait_state(lambda s: idle(s) and relay(s).get("multihop") is False, what="settings.relay.multihop off")
    if relay_fields().get("Multihop state") != "disabled":
        raise CheckFailed("CLI multihop state is %s after off" % relay_fields().get("Multihop state"))
    return "entry %s (%s) -> exit %s (%s), then multihop off" % (
        location.get("entry_hostname"), location.get("entry_country"), location.get("hostname"), location.get("country"))


@check("auto_connect")
def auto_connect():
    for on in (True, False):
        send({"action": "set_auto_connect", "on": on})
        wait_state(lambda s: idle(s) and settings(s).get("autoConnect") is on, what="settings.autoConnect %s" % on)
        if on_off(cli_ok("auto-connect", "get")) is not on:
            raise CheckFailed("CLI auto-connect is %s, want %s" % (cli_ok("auto-connect", "get"), on))
    return "on, then off; the CLI agreed each time"


@check("outside_change")
def outside_change():
    # A change made outside the plugin must show up within 40 s (the 30 s poll).
    current = relay_fields()["Location"]
    target = "ch" if current == "country de" else "de"
    before = read_state() or {}
    if relay(before).get("location", {}).get("country") == target:
        raise CheckFailed("the service already shows %s before the change" % target)
    cli_ok("relay", "set", "location", target)
    SENT["seq"] = None  # no request was sent: any snapshot that shows the change counts
    started = time.time()
    wait_state(lambda s: relay(s).get("location", {}).get("kind") == "country"
               and relay(s).get("location", {}).get("country") == target,
               timeout=40, what="settings.relay.location.country == %s" % target)
    return "%s -> country %s seen after %.0f s" % (current, target, time.time() - started)


FETCH = "import urllib.request; urllib.request.urlopen('https://am.i.mullvad.net/json', timeout=5)"


def fetch_ok():
    try:
        return subprocess.run(["python3", "-c", FETCH], capture_output=True, timeout=30).returncode == 0
    except subprocess.TimeoutExpired:
        return False


@check("lockdown", group="lockdown")
def lockdown():
    snap = CONTEXT["snap"]
    try:
        send({"action": "connect", "mode": "country", "country": "se"})
        wait_state(lambda s: connected_where(s, country="Sweden"), what="connected in Sweden")
        send({"action": "set_lockdown", "on": True})
        wait_state(lambda s: idle(s) and settings(s).get("lockdown") is True, what="settings.lockdown on")
        if not on_off(cli_ok("lockdown-mode", "get")):
            raise CheckFailed("CLI lockdown is off after set_lockdown on")
        send({"action": "disconnect"})
        wait_state(lambda s: idle(s) and tunnel(s).get("state") == "disconnected" and tunnel(s).get("lockedDown") is True,
                   what="disconnected and locked down")
        if (cli_status().get("details") or {}).get("locked_down") is not True:
            raise CheckFailed("CLI status is not locked_down")
        if fetch_ok():
            raise CheckFailed("https://am.i.mullvad.net/json answered while locked down")
        send({"action": "set_lockdown", "on": False})
        wait_state(lambda s: idle(s) and settings(s).get("lockdown") is False and tunnel(s).get("lockedDown") is not True,
                   what="settings.lockdown off")
        dns_guard("after lockdown off")
        deadline = time.time() + DNS_WAIT_S
        while not fetch_ok():
            if time.time() >= deadline:
                raise CheckFailed("https://am.i.mullvad.net/json still fails after lockdown off")
            time.sleep(1)
        return "blocked while locked down, open again after off"
    finally:
        # Never leave the next check running blocked.
        if not snap["lockdown"] and on_off(cli_ok("lockdown-mode", "get")):
            cli_ok("lockdown-mode", "set", "off")


def sysctl_ok(*args):
    return subprocess.run(["systemctl", *args], capture_output=True).returncode == 0


@check("daemon", group="daemon")
def daemon():
    was_enabled = sysctl_ok("is-enabled", "mullvad-daemon")
    say("Stopping the daemon: sudo may ask for your password.")
    if subprocess.run(["sudo", "systemctl", "stop", "mullvad-daemon"]).returncode != 0:
        raise CheckFailed("could not stop mullvad-daemon")
    failure = None
    try:
        wait_state(lambda s: s.get("daemon") == "down", what="daemon down")
        say("Sending start_service: enter your password in the polkit prompt.")
        send({"action": "start_service"})
        wait_state(lambda s: s.get("daemon") == "running" and s.get("bootEnabled") is True and not s.get("busy"),
                   timeout=90, what="daemon running and bootEnabled")
        cli_ok("connect", "--wait", timeout=60)
        wait_state(lambda s: tunnel(s).get("state") == "connected", timeout=5,
                   what="tunnel connected through the restarted status stream")
        cli_ok("disconnect")
        return "start_service brought the daemon back; status stream works"
    except BaseException as err:  # noqa: BLE001 - re-raised below, after cleanup
        failure = err
        raise
    finally:
        try:
            if not sysctl_ok("is-active", "mullvad-daemon"):
                say("The daemon is STOPPED. Starting it again: sudo may ask for your password.")
                subprocess.run(["sudo", "systemctl", "start", "mullvad-daemon"])
                if was_enabled and not sysctl_ok("is-enabled", "mullvad-daemon"):
                    subprocess.run(["sudo", "systemctl", "enable", "mullvad-daemon"])
            if cli_status().get("state") in ("connected", "connecting"):
                cli_ok("disconnect")
        except BaseException as cleanup_err:  # noqa: BLE001 - must not replace the original failure
            say("CLEANUP FAILED: %s: %s%s" % (type(cleanup_err).__name__, cleanup_err,
                "" if failure is None else " (original failure: %s: %s)" % (type(failure).__name__, failure)))
            if failure is None:
                raise


def account(state):
    return state.get("account") or {}


def message(key):
    """The English sentence for a lastError key (nested en.json), or None."""
    node = json.loads((PLUGIN / "translations" / "en.json").read_text())
    for part in key.split("."):
        node = node.get(part) if isinstance(node, dict) else None
    return node if isinstance(node, str) else None


def readable(key):
    text = message(key or "")
    if not text or "{" in text:
        raise CheckFailed("%s has no readable sentence in en.json (%r)" % (key, text))
    return text


# The plugin's own mapping (parse.commandError in parse.luau), run on live CLI text.
MAP_ERROR_LUA = (
    'local f = assert(io.open(os.getenv("PARSE_LUAU"))); '
    'local src = f:read("a"):gsub("^%-%-!%S+%s*\\n", ""); f:close(); '
    'local parse = assert(load(src))(); '
    'io.write(parse.commandError({ exitCode = 1, stdout = "", stderr = os.getenv("CLI_STDERR") }) or "")'
)


def plugin_error_key(stderr):
    env = dict(os.environ, PARSE_LUAU=str(PLUGIN / "parse.luau"), CLI_STDERR=stderr)
    out = subprocess.run(["lua", "-e", MAP_ERROR_LUA], capture_output=True, text=True, timeout=10, env=env)
    if out.returncode != 0:
        raise CheckFailed("running parse.commandError failed: %s" % scrub(out.stderr.strip()))
    return out.stdout or None


NO_SUCH_DEVICE = "No Such Device"


@check("account_safe")
def account_safe():
    before = read_state() or {}
    if account(before).get("loggedIn") is not True:
        raise Skip("the service does not show a logged-in account")
    names = [line.strip().lower() for line in cli_ok("account", "list-devices").splitlines()[1:]]
    if NO_SUCH_DEVICE.lower() in names:
        raise CheckFailed("refusing: this account really has a device named %r" % NO_SUCH_DEVICE)

    # 1. An invalid voucher: the CLI runs, Mullvad refuses it, nothing changes.
    send({"action": "redeem", "voucher": "INVALID0000"})
    state = wait_state(lambda s: idle(s) and s.get("lastError"), timeout=60, what="redeem refused")
    err = state["lastError"]
    if err.get("key") != "error.invalid_voucher":
        raise CheckFailed("redeem INVALID0000 gave %s" % err)
    voucher_text = readable(err["key"])

    # 2. A device the account does not have: refused by validation, nothing runs.
    #    A refusal from the CLI would carry its line as detail; validation has none.
    send({"action": "revoke_device", "name": NO_SUCH_DEVICE})
    state = wait_state(lambda s: idle(s) and s.get("lastError"), timeout=20, what="revoke refused")
    err = state["lastError"]
    if err.get("key") != "error.unknown_device" or err.get("detail") is not None:
        raise CheckFailed("revoke_device %r gave %s, want validation error.unknown_device" % (NO_SUCH_DEVICE, err))

    # 3. The CLI's own answer for that name is the fixture, and the plugin maps it.
    out = subprocess.run(["mullvad", "account", "revoke-device", "--", NO_SUCH_DEVICE],
                         capture_output=True, text=True, timeout=60)
    if out.returncode == 0:
        raise CheckFailed("mullvad account revoke-device %r succeeded" % NO_SUCH_DEVICE)
    want = (FIXTURES / "synthetic-account-revoke-device-unknown.txt").read_text()
    if out.stderr != want:
        raise CheckFailed("the CLI error changed: %r, fixture has %r" % (scrub(out.stderr), want))
    key = plugin_error_key(out.stderr)
    if key != "error.unknown_device":
        raise CheckFailed("parse.commandError maps the CLI error to %r" % key)

    # 4. Leave no error notice behind in the user's panel (the dismiss button's request).
    send({"action": "dismiss_error", "key": "error.unknown_device"})
    wait_state(lambda s: s.get("lastError") is None, timeout=20, what="lastError cleared")
    return "voucher: %r; unknown device refused before running; CLI %r -> %r; error dismissed" % (
        voucher_text, out.stderr.strip(), readable(key))


def number_found(digits):
    """Where the account number shows up among the files the plugin can write, plus the shell
    log and its rotated copies (noctalia.log.1, ...)."""
    places = [p for p in STATE.parent.glob("*") if p.is_file()]
    places += sorted(p for p in NOCTALIA_LOG.parent.glob(NOCTALIA_LOG.name + "*") if p.is_file())
    found = []
    for path in places:
        try:
            if digits in path.read_text(errors="replace"):
                found.append(str(path))
        except OSError:
            pass
    return found


@check("account_login", group="account")
def account_login():
    digits = re.sub(r"[\s-]", "", os.environ.get("MULLVAD_ACCOUNT", ""))
    if not re.fullmatch(r"\d{16}", digits):
        raise Skip("set MULLVAD_ACCOUNT to the 16-digit number of the account this device is logged in on")
    if digits not in cli("account", "get"):
        raise CheckFailed("the daemon is not logged in on MULLVAD_ACCOUNT; nothing was changed")
    try:
        send({"action": "logout"})
        wait_state(lambda s: idle(s) and account(s).get("loggedIn") is False, timeout=60, what="account.loggedIn false")
        if "Not logged in" not in cli("account", "get"):
            raise CheckFailed("the CLI is still logged in after logout")
        send({"action": "login", "number": digits}, secret=True)
        wait_state(lambda s: idle(s) and account(s).get("loggedIn") is True, timeout=60, what="account.loggedIn true")
        if digits not in cli("account", "get"):
            raise CheckFailed("the CLI is not logged in on MULLVAD_ACCOUNT after login")
        if re.search(r"\d{16}", STATE.read_text()):
            raise CheckFailed("state.json holds a 16-digit run")
        leaked = number_found(digits)
        if leaked:
            raise CheckFailed("the account number is in %s" % ", ".join(leaked))
        return "logged out and back in through the plugin; the number is in no plugin file or the shell log"
    finally:
        if digits not in cli("account", "get"):
            say("Logging back in through the CLI.")
            subprocess.run(["mullvad", "account", "login", digits], capture_output=True, timeout=60)


# ── main ─────────────────────────────────────────────────────────────────────


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--only", nargs="+", metavar="NAME", help="run only these checks")
    for group in GROUPS:
        parser.add_argument("--" + group, action="store_true", help="include the %s checks (user-run)" % group)
    parser.add_argument("--selftest", action="store_true", help="check the freshness/reload logic on fake data and exit")
    args = parser.parse_args()
    if args.selftest:
        _selftest_fresh()
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

    if not dns_ok():
        say("refusing to start: %s does not resolve. /etc/resolv.conf is %s. "
            "Reconnecting Wi-Fi (NetworkManager) fixes an empty resolv.conf." % (DNS_HOST, resolv_size()))
        return 2

    try:
        snap = snapshot()
    except RuntimeError as err:  # nothing has moved yet
        say(err)
        return 1
    CONTEXT["snap"] = snap
    say("snapshot: " + describe(snap))

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    results = []
    exit_code = 0
    try:
        debug_on()  # before the first send(): it reads state.json
        send({"action": "refresh"})
        state = wait_state(lambda s: s.get("daemon") == "running" and len(s.get("relays") or []) > 0,
                           timeout=20, what="service running with a relay list")
        say("service: %s, %d countries, realLocation=%s" % (
            summary(state), len(state.get("relays") or []), (state.get("realLocation") or {}).get("country")))

        for name, _, fn in selected:
            try:
                detail = fn()
                results.append((name, "PASS"))
                say("PASS  %s%s" % (name, ("   [%s]" % detail) if detail else ""))
            except Skip as why:
                results.append((name, "SKIP"))
                say("SKIP  %s   [%s]" % (name, why))
            except (DnsBroken, Interrupted):
                raise
            except Exception as why:  # noqa: BLE001 - CheckFailed, or a CLI/IPC error
                results.append((name, "FAIL"))
                say("FAIL  %s   [%s: %s]" % (name, type(why).__name__, why))
    except DnsBroken as why:
        say(dns_message(why))
        exit_code = 2
    except Interrupted as why:
        say("interrupted (%s); restoring" % why)
        exit_code = 130
    except CheckFailed as why:  # the service never came up (no dump, no relays)
        say("cannot start: %s" % why)
        exit_code = 1
    finally:
        try:
            restore(snap)
        except DnsBroken as why:
            say(dns_message(why))
            exit_code = 2
        except Exception as err:  # noqa: BLE001 - a failed restore must be loud
            say("RESTORE FAILED: %s" % err)
            exit_code = exit_code or 1
        finally:
            debug_off()

    if snap is not None:
        try:
            now = read_settings()
            now["connected"] = cli_status().get("state") in ("connected", "connecting")
            say("after: %s, DNS %s; relay get %s the original" % (
                describe(now), "ok" if dns_ok() else "BROKEN",
                "matches" if now["relay_get"] == snap["relay_get"] else "DIFFERS FROM"))
        except Exception as err:  # noqa: BLE001 - must not mask a DNS abort's exit 2
            say("after: could not read back the CLI state: %s" % err)
            exit_code = exit_code or 1
    counts = {kind: sum(1 for _, r in results if r == kind) for kind in ("PASS", "FAIL", "SKIP")}
    say("\n%d passed, %d failed, %d skipped" % (counts["PASS"], counts["FAIL"], counts["SKIP"]))
    if exit_code:
        return exit_code
    return 1 if counts["FAIL"] else 0


if __name__ == "__main__":
    sys.exit(main())
