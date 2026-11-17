#!/usr/bin/env python3
"""Fail if a real LogonBox value appears in the given paths or in git history.

  python3 -I logonbox/tests/privacy-check.py [paths...]     # default: logonbox

The real values (e-mail, user name, hostnames, IPs, owner, key strings) are learned from a
live `logonbox-vpn-cli show '.*'`, in memory only (the learning code is the scrubber's in
capture-fixtures.py). When the CLI is not usable, the private raw captures in
fixtures/private/ are used instead. The tool scans every text file under the paths and the
output of `git log -p`, and prints only file:line (or commit:file:diff-line), never a value.
"""

import importlib.util
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SKIP_DIRS = {".git", "__pycache__", "private"}
MIN_LEN = 4          # shorter learned values (a 2-letter owner) would match everything
KEY_RUN = re.compile(r"[A-Za-z0-9+/=]{32,}")


def load_capture():
    spec = importlib.util.spec_from_file_location("capture_fixtures", os.path.join(HERE, "capture-fixtures.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def raw_show(capture):
    try:
        out, _, code = capture.run([capture.CLI, "show", ".*"], 30)
        if code == 0 and "Connection:" in out:
            return out
    except (OSError, subprocess.TimeoutExpired):
        pass
    parts = []
    for name in ("show-disconnected.txt", "show-connected.txt"):
        path = os.path.join(capture.PRIVATE, name)
        if os.path.exists(path):
            parts.append(capture.read(path))
    return "\n".join(parts)


def learn():
    capture = load_capture()
    raw = raw_show(capture)
    if not raw:
        raise SystemExit("privacy: cannot learn real values (no live show, no private raw capture)")
    scrubber = capture.Scrubber()
    scrubber.learn(raw)
    values = set(scrubber.learned())
    values.update(scrubber.users)
    for line in raw.splitlines():
        if "Key" in line.split(":")[0]:
            values.add(line.partition(":")[2].strip())
    values.update(KEY_RUN.findall(raw))
    values = {v for v in values if len(v) >= MIN_LEN}
    if not values:
        raise SystemExit("privacy: nothing learned from the show output")
    return sorted(values, key=len, reverse=True)


def matches(line, needles):
    low = line.lower()
    return any(n.lower() in low for n in needles)


def scan_paths(paths, needles):
    hits = []
    for top in paths:
        walker = [(os.path.dirname(top), [], [os.path.basename(top)])] if os.path.isfile(top) else None
        for dirpath, dirs, files in walker or os.walk(top):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
            for name in files:
                path = os.path.join(dirpath, name)
                try:
                    with open(path, encoding="utf-8") as handle:
                        for number, line in enumerate(handle, 1):
                            if matches(line, needles):
                                hits.append("%s:%d" % (os.path.relpath(path, ROOT), number))
                except (UnicodeDecodeError, OSError):
                    continue
    return hits


def scan_history(needles):
    proc = subprocess.run(["git", "-C", ROOT, "log", "-p", "--all", "--format=@@commit %h"],
                          capture_output=True, text=True, errors="replace", stdin=subprocess.DEVNULL)
    hits = []
    commit = path = ""
    number = 0
    for line in proc.stdout.splitlines():
        number += 1
        if line.startswith("@@commit "):
            commit, path, number = line.split()[1], "", 0
        elif line.startswith("+++ "):
            path = line[6:] if line.startswith("+++ b/") else line[4:]
        elif line.startswith(("+", "-")) and matches(line, needles):
            hits.append("git:%s:%s:diff-line %d" % (commit, path, number))
    return hits


def main(argv):
    paths = [os.path.abspath(p) for p in argv] or [os.path.join(ROOT, "logonbox")]
    needles = learn()
    hits = scan_paths(paths, needles) + scan_history(needles)
    if hits:
        print("privacy: FAILED, a real value appears at:", file=sys.stderr)
        for hit in sorted(set(hits)):
            print("  " + hit, file=sys.stderr)
        return 1
    print("privacy: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
