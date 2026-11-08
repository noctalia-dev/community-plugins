#!/usr/bin/env python3
"""Live checks of the VS Code plugin against the real Noctalia, niri and editor.

    python3 vscode/tests/e2e-live.py --dry-run                 environment only: no windows, no clone
    python3 vscode/tests/e2e-live.py                           both flavors that are installed
    python3 vscode/tests/e2e-live.py --flavor code --flavor codium
    python3 vscode/tests/e2e-live.py --clone-url URL --big-url URL

THE LIVE RUN OPENS AND CLOSES REAL EDITOR WINDOWS. Run it at the keyboard with the screen
unlocked. It needs a running Noctalia, `niri msg`, and the editor commands.

What it does, per flavor (`code`, `codium`):
  * creates /tmp/noctalia-vscode-e2e-<rand>/{alpha,"beta gamma"}, a .code-workspace and a
    throwaway editor profile (written to the plugin's `test-config-dir` marker, so every
    window opens with --user-data-dir <that profile>: no restored session, and the user's own
    editor is never touched);
  * touches the `debug` marker (the plugin then writes state.json: counts and /tmp/noctalia-
    vscode-e2e- projects only) and drives the service over IPC;
  * never changes your Noctalia config: `noctalia msg config-set` cannot address a plugin's
    settings (its key "3dprogramin/vscode" holds a slash; every quoting was tried), so the
    plugin's own `editor` setting decides the flavor. A flavor that the plugin is
    not using is SKIPPED with a note (a FAIL when you named it with --flavor) (set Editor in the plugin's settings, or leave it on Auto
    and close the other editor's windows); and the clone checks (e), (f) run only with
    `--clone-dir /tmp/noctalia-vscode-e2e-<anything>` after you set the plugin's Clone folder
    to that same path in its settings (the script reads the plugin's effective Clone folder from
    state.json first and refuses to send any clone request unless it is that path).
Checks (a)-(d) run for every flavor; (e) and (f) run once, for the first flavor:
  (a) open_path alpha: within 15 s exactly one new window of that flavor titled alpha, and no
      other new window of that flavor (no restored session);
  (b) the same for the quoted path 'beta gamma';
  (c) open_path of a missing path sets pathError;
  (d) pin, unpin and hide change data.json and state.json; opening the project unhides it;
  (e) clone of --clone-url (default octocat/Hello-World, the one network use) reaches done;
  (f) cancel_clone during a clone of --big-url (default github.com/git/git) reaches cancelled
      and leaves no git process.
It prints pass/fail lines and counts only (never a title or a path), closes the windows it
opened by id through niri, and in `finally` (also on SIGTERM and SIGHUP) removes the markers,
the temp folders and its pins. A window is closed only when its id was not there before the
action AND its title contains one of: alpha, beta gamma, the cloned repository's name; other
new windows are only counted in a note. Exit 0 when everything passed, 1 otherwise.
"""

import argparse
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.parse

PLUGIN = "3dprogramin/vscode"
SERVICE = PLUGIN + ":service"
DATA = pathlib.Path.home() / ".local/state/noctalia/plugins/data/3dprogramin/vscode"
E2E_PREFIX = "/tmp/noctalia-vscode-e2e-"
FLAVORS = {
    # flavor id used by the plugin's state, setting value, command, niri app_ids (lowercase)
    "code": {"state_id": "code", "setting": "code", "cmd": "code",
             "app_ids": {"code", "com.microsoft.vscode", "code-url-handler"}},
    "codium": {"state_id": "codium", "setting": "codium", "cmd": "codium",
               "app_ids": {"codium", "vscodium", "com.vscodium.codium", "codium-url-handler"}},
}
DEFAULT_CLONE_URL = "https://github.com/octocat/Hello-World.git"
DEFAULT_BIG_URL = "https://github.com/git/git.git"

results = []  # (name, ok, detail)
_seq = [0]


def record(name, ok, detail=""):
    results.append((name, ok, detail))
    print("%s  %s%s" % ("PASS" if ok else "FAIL", name, ("  (" + detail + ")") if detail else ""), flush=True)
    return ok


# ── low-level helpers ────────────────────────────────────────────────────────

def run(argv, timeout=15):
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None


def ipc(action, **fields):
    _seq[0] += 1
    fields.update(action=action, requestId="e2e-%d-%d" % (os.getpid(), _seq[0]))
    r = run(["noctalia", "msg", "plugin", SERVICE, "all", "request", json.dumps(fields)])
    return r is not None and r.returncode == 0


def read_json(path):
    try:
        return json.loads(pathlib.Path(path).read_text())
    except (OSError, ValueError):
        return None


def state():
    return read_json(DATA / "state.json")


def wait_for(pred, timeout, interval=0.3, nudge=None):
    """Polls pred() until it returns something truthy; returns it, or None on timeout."""
    end = time.time() + timeout
    last_nudge = 0
    while True:
        v = pred()
        if v:
            return v
        if time.time() >= end:
            return None
        if nudge is not None and time.time() - last_nudge > 2:
            nudge()
            last_nudge = time.time()
        time.sleep(interval)


def windows():
    r = run(["niri", "msg", "-j", "windows"])
    if r is None or r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout)
    except ValueError:
        return None


def flavor_windows(flavor):
    ids = FLAVORS[flavor]["app_ids"]
    return [w for w in (windows() or []) if str(w.get("app_id", "")).lower() in ids]


def close_window(wid):
    run(["niri", "msg", "action", "close-window", "--id", str(wid)])


def valid_e2e_dir(path):
    """True for a normalized path strictly inside the e2e prefix (every deletion checks this)."""
    real = os.path.realpath(path)
    return real.startswith(E2E_PREFIX) and real != E2E_PREFIX and ".." not in real.split("/")


def safe_rmtree(path):
    if path and valid_e2e_dir(str(path)):
        shutil.rmtree(os.path.realpath(str(path)), ignore_errors=True)


def clean_clone_dir_arg(raw):
    """The --clone-dir value as a real path, or None when it is not acceptable."""
    if raw is None or ".." in raw.split("/") or not raw.startswith("/"):
        return None
    real = os.path.realpath(raw)
    return real if valid_e2e_dir(real) else None


def file_key(path):
    return "file://" + urllib.parse.quote(path)


# ── environment ──────────────────────────────────────────────────────────────

def check_environment():
    ok = True
    r = run(["pgrep", "-x", "noctalia"])
    ok &= record("env: noctalia running", r is not None and r.returncode == 0)
    w = windows()
    ok &= record("env: niri msg works", w is not None, "%d windows" % len(w) if w is not None else "")
    found = [f for f, spec in FLAVORS.items() if shutil.which(spec["cmd"])]
    ok &= record("env: flavor commands", len(found) > 0,
                 "found %s, missing %s" % (",".join(found) or "none",
                                           ",".join(f for f in FLAVORS if f not in found) or "none"))
    ok &= record("env: IPC reachable (refresh)", ipc("refresh"))
    r = run(["noctalia", "msg", "config-get", "plugins.enabled"])
    ok &= record("env: config-get works", r is not None and r.returncode == 0)
    ok &= debug_round_trip()
    return ok, found


def debug_round_trip():
    marker, st = DATA / "debug", DATA / "state.json"
    DATA.mkdir(parents=True, exist_ok=True)
    try:
        marker.touch()
        got = wait_for(lambda: state(), 8, nudge=lambda: ipc("refresh"))
        ok1 = isinstance(got, dict) and "counts" in got
        record("env: debug marker writes state.json", ok1,
               ("pinned %s, recent %s" % (got["counts"].get("pinned"), got["counts"].get("recent"))) if ok1 else "")
    finally:
        try:
            marker.unlink()
        except OSError:
            pass
    gone = wait_for(lambda: not st.exists(), 8, nudge=lambda: ipc("refresh"))
    ok2 = bool(gone)
    if not ok2:
        try:
            st.unlink()
        except OSError:
            pass
    record("env: removing the marker removes state.json", ok2)
    return ok1 and ok2


# ── live checks ──────────────────────────────────────────────────────────────

class Run:
    def __init__(self, tmp):
        self.tmp = tmp
        self.opened = []  # window ids we own: new, and titled with one of our names
        self.unmatched = set()  # new windows of the flavor with another title: never touched

    def new_windows(self, flavor, before_ids):
        return [w for w in flavor_windows(flavor) if w["id"] not in before_ids]

    def claim(self, flavor, before_ids, needles):
        """Records the new windows whose title has one of the needles; counts the rest."""
        mine = []
        for w in self.new_windows(flavor, before_ids):
            if any(n in str(w.get("title", "")) for n in needles):
                if w["id"] not in self.opened:
                    self.opened.append(w["id"])
                mine.append(w)
            else:
                self.unmatched.add(w["id"])
        return mine

    def open_and_check(self, label, flavor, text, needle):
        before = {w["id"] for w in flavor_windows(flavor)}
        if not ipc("open_path", text=text):
            return record(label, False, "request failed")
        hit = wait_for(lambda: self.claim(flavor, before, [needle]), 15)
        time.sleep(2)  # a restored session would show up as extra windows by now
        self.claim(flavor, before, [needle])
        now = self.new_windows(flavor, before)
        titled_n = len([w for w in now if needle in str(w.get("title", ""))])
        other_n = len(now) - titled_n
        return record(label, bool(hit) and titled_n == 1 and other_n == 0,
                      "new windows %d, matching %d, others %d" % (len(now), titled_n, other_n))

    def close_all(self):
        for wid in self.opened:
            close_window(wid)
        self.opened = []

    def data_json(self):
        return read_json(DATA / "data.json") or {}


def check_flavor(rn, flavor, first, args):
    spec = FLAVORS[flavor]
    tmp = rn.tmp
    alpha = tmp / "alpha"
    beta = tmp / "beta gamma"
    profile = tmp / ("profile-" + flavor)
    profile.mkdir(exist_ok=True)
    (DATA / "test-config-dir").write_text(str(profile))
    ipc("refresh")
    chosen = wait_for(lambda: (state() or {}).get("flavor", {}).get("id") == spec["state_id"], 12,
                      nudge=lambda: ipc("refresh"))
    if not chosen:
        if args.flavor:  # asked for by name: not testing it is a failure
            record("%s: plugin uses the flavor" % flavor, False, "set Editor in the plugin's settings")
        else:
            print("SKIP  %s: the plugin is not using this flavor (set Editor in the plugin's settings)" % flavor)
        return
    p = flavor + ": "
    rn.open_and_check(p + "(a) open_path alpha -> one new window", flavor, str(alpha), "alpha")
    rn.open_and_check(p + "(b) quoted path with a space -> one new window", flavor, "'%s'" % beta, "beta gamma")

    # (c) a missing path
    ipc("open_path", text=str(tmp / "no-such-folder"))
    err = wait_for(lambda: (state() or {}).get("pathError"), 6)
    record(p + "(c) missing path sets pathError", bool(err), str(err or ""))
    ipc("dismiss_error")

    # (d) pin / unpin / hide
    key = file_key(str(alpha))
    ipc("pin", key=key)
    ok = wait_for(lambda: key in rn.data_json().get("pins", []) and
                  any(e.get("key") == key for e in (state() or {}).get("pinned", [])), 6)
    record(p + "(d) pin -> data.json and state.json", bool(ok))
    ipc("unpin", key=key)
    ok = wait_for(lambda: key not in rn.data_json().get("pins", []) and
                  not any(e.get("key") == key for e in (state() or {}).get("pinned", [])), 6)
    record(p + "(d) unpin -> data.json and state.json", bool(ok))
    ipc("hide", key=key)
    ok = wait_for(lambda: key in rn.data_json().get("hidden", []) and
                  not any(e.get("key") == key for e in (state() or {}).get("recent", [])), 6)
    record(p + "(d) hide -> data.json and state.json", bool(ok))
    # opening a hidden project shows it again (also restores data.json)
    before = {w["id"] for w in flavor_windows(flavor)}
    ipc("open", key=key)
    ok = wait_for(lambda: key not in rn.data_json().get("hidden", []), 6)
    record(p + "(d) opening a hidden project unhides it", bool(ok))
    wait_for(lambda: rn.claim(flavor, before, ["alpha"]), 15)
    time.sleep(1)
    rn.claim(flavor, before, ["alpha"])

    if first and args.clone_dir:
        check_clone(rn, flavor, args)
    rn.close_all()


def git_procs(folder):
    """Processes whose command is git (or a git-* helper) and whose arguments name our clone folder."""
    r = run(["pgrep", "-a", "-f", str(folder) + "/"])
    if r is None or r.returncode != 0:
        return 0
    n = 0
    for line in r.stdout.splitlines():
        parts = line.split(None, 2)
        if len(parts) >= 2 and os.path.basename(parts[1]).split("-")[0] == "git":
            n += 1
    return n


def check_clone(rn, flavor, args):
    tmp = rn.tmp
    clones = pathlib.Path(args.clone_dir)  # already a validated real path
    clones.mkdir(parents=True, exist_ok=True)

    def cs():
        return (state() or {}).get("clone", {}).get("state")

    def start(url):
        # Refuse before anything is sent unless the plugin's own Clone folder is ours.
        eff = wait_for(lambda: (state() or {}).get("cloneDir"), 6, nudge=lambda: ipc("refresh"))
        if not eff or os.path.realpath(eff) != str(clones):
            record(flavor + ": plugin's Clone folder is --clone-dir", False,
                   "set the plugin's Clone folder to --clone-dir; no clone was started")
            return False
        ipc("dismiss_error")
        if not wait_for(lambda: cs() == "idle", 6):
            record(flavor + ": no clone state left over", False, "state %s" % cs())
            return False
        seq = (state() or {}).get("requestSeq", 0)
        ipc("clone", url=url)
        if not wait_for(lambda: cs() in ("running", "done", "failed", "exists")
                        and (state() or {}).get("requestSeq", 0) > seq, 15):
            record(flavor + ": the clone request was handled", False, "state %s" % cs())
            return False
        return True

    # (e) a small clone reaches done
    name = args.clone_url.rstrip("/").rsplit("/", 1)[-1]
    name = name[:-4] if name.endswith(".git") else name
    before = {w["id"] for w in flavor_windows(flavor)}
    if not start(args.clone_url):
        return
    done = wait_for(lambda: (state() or {}).get("clone", {}).get("state") in ("done", "failed", "exists"), 120)
    st = (state() or {}).get("clone", {}).get("state")
    ok = bool(done) and st == "done" and (clones / name / ".git").exists()
    record(flavor + ": (e) clone reaches done", ok, "state %s" % st)
    # a finished clone opens the project: close that window (by its title)
    wait_for(lambda: rn.claim(flavor, before, [name]), 15)
    time.sleep(1)
    rn.claim(flavor, before, [name])
    ipc("dismiss_error")
    wait_for(lambda: (state() or {}).get("clone", {}).get("state") == "idle", 5)

    # (f) cancel a big clone
    if not start(args.big_url):
        return
    started = wait_for(lambda: (state() or {}).get("clone", {}).get("state") == "running", 15)
    time.sleep(3)
    ipc("cancel_clone")
    cancelled = wait_for(lambda: (state() or {}).get("clone", {}).get("state") == "cancelled", 15)
    gone = wait_for(lambda: git_procs(clones) == 0, 10)
    record(flavor + ": (f) cancel_clone reaches cancelled", bool(started) and bool(cancelled),
           "started %s, cancelled %s" % (bool(started), bool(cancelled)))
    record(flavor + ": (f) no git process left", bool(gone), "left %d" % git_procs(clones))
    ipc("dismiss_error")


def live(args, found):
    flavors = args.flavor or found
    flavors = [f for f in flavors if f in found]
    if not flavors:
        record("live: a requested flavor is installed", False)
        return
    if args.clone_dir:
        clean = clean_clone_dir_arg(args.clone_dir)
        if clean is None:
            record("live: --clone-dir is an absolute path under " + E2E_PREFIX + " (no ..)", False)
            return
        args.clone_dir = clean
    if not args.clone_dir:
        print("NOTE  clone checks (e), (f) skipped: pass --clone-dir (see --help)")
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="noctalia-vscode-e2e-", dir="/tmp"))
    assert str(tmp).startswith(E2E_PREFIX)
    (tmp / "alpha").mkdir()
    (tmp / "beta gamma").mkdir()
    (tmp / "work.code-workspace").write_text(json.dumps({"folders": [{"path": "alpha"}]}))
    rn = Run(tmp)
    marker = DATA / "debug"

    def on_signal(signum, frame):
        sys.exit(130)  # the finally below runs

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGHUP, on_signal)
    try:
        DATA.mkdir(parents=True, exist_ok=True)
        marker.touch()
        ipc("refresh")
        for i, f in enumerate(flavors):
            check_flavor(rn, f, i == 0, args)
    finally:
        rn.close_all()
        # best effort: leave no pin or hidden mark behind
        key = file_key(str(tmp / "alpha"))
        ipc("unpin", key=key)
        if key in rn.data_json().get("hidden", []):
            for f in flavors:
                before = {w["id"] for w in flavor_windows(f)}
                ipc("open", key=key)
                time.sleep(4)
                rn.claim(f, before, ["alpha"])
            rn.close_all()
        for name in ("test-config-dir", "debug"):
            try:
                (DATA / name).unlink()
            except OSError:
                pass
        ipc("refresh")
        wait_for(lambda: not (DATA / "state.json").exists(), 8, nudge=lambda: ipc("refresh"))
        time.sleep(1)
        safe_rmtree(tmp)
        safe_rmtree(args.clone_dir)
        leftover = (DATA / "state.json").exists() or (DATA / "debug").exists() or tmp.exists()
        record("cleanup: markers, state.json and temp folder removed", not leftover)
        if rn.unmatched:
            print("NOTE  %d new window(s) of the flavor had other titles and were left alone" % len(rn.unmatched))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dry-run", action="store_true", help="check the environment only")
    ap.add_argument("--flavor", action="append", choices=sorted(FLAVORS), help="repeatable; default: all installed")
    ap.add_argument("--clone-url", default=DEFAULT_CLONE_URL)
    ap.add_argument("--big-url", default=DEFAULT_BIG_URL)
    ap.add_argument("--clone-dir", help="run the clone checks; must be /tmp/noctalia-vscode-e2e-<name> and "
                    "the same as the plugin's Clone folder setting")
    args = ap.parse_args()
    ok, found = check_environment()
    if not args.dry_run and ok:
        live(args, found)
    elif not args.dry_run:
        print("environment checks failed; the live run was not started")
    passed = sum(1 for _, o, _ in results if o)
    print("\n%d passed, %d failed%s" % (passed, len(results) - passed, " (dry run)" if args.dry_run else ""))
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
