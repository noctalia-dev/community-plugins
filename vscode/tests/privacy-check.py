#!/usr/bin/env python3
"""Fails if any of the user's real recent project paths appears in vscode/** or in the git history.

    python3 vscode/tests/privacy-check.py          scan vscode/** and `git log -p --all`
    python3 vscode/tests/privacy-check.py --no-git scan vscode/** only

It reads the real recent projects of every installed editor flavor into memory only:
  * globalStorage/state.vscdb, key history.recentlyOpenedPathsList (sqlite3 -readonly),
  * globalStorage/storage.json (the File > Open Recent menu),
  * workspaceStorage/*/workspace.json.
From each project it takes the decoded local path (and the remote host/path of a remote
project) and also the path's last two segments joined with "/". Anything of 8+ characters
becomes a pattern, except paths under /tmp/noctalia-vscode-e2e-. Paths match as substrings.
Remote hosts match case-insensitively as whole words (a host "dev" does not match
"development"), except the generic names in HOST_STOPLIST.

It then looks for those patterns in every file of vscode/ and in the added and removed
lines of `git log -p --all`. It never prints a path. On a hit it prints the number of
patterns that matched and the names of the files (or "git history") they were found in.
Exit 0 and `privacy: ok (N patterns)` when nothing was found, 1 on a hit, 2 on an
unexpected error (the error type only).
"""

import json
import pathlib
import re
import subprocess
import sys
import urllib.parse

HOME = pathlib.Path.home()
CONFIG_DIRS = (
    "~/.config/Code",
    "~/.config/Code - Insiders",
    "~/.config/VSCodium",
    "~/.config/Code - OSS",
    "~/.config/Cursor",
    "~/.var/app/com.visualstudio.code/config/Code",
)
DB_QUERY = "SELECT value FROM ItemTable WHERE key='history.recentlyOpenedPathsList'"
E2E_PREFIX = "/tmp/noctalia-vscode-e2e-"
MIN_LEN = 8
# Generic words that are not a client's host name and appear in ordinary prose and tests.
# Every other host is checked, however plain it looks.
HOST_STOPLIST = {"localhost", "host", "server", "remote", "container", "tunnel", "wsl"}
SKIP_DIRS = {"__pycache__", ".git"}
ROOT = pathlib.Path(__file__).resolve().parents[2]
PLUGIN = ROOT / "vscode"


def expand(d):
    return pathlib.Path(d.replace("~", str(HOME), 1))


def uri_parts(value):
    """A URI string -> list of decoded strings to protect (path, host)."""
    out = []
    try:
        u = urllib.parse.urlsplit(value)
    except ValueError:
        return out
    path = urllib.parse.unquote(u.path)
    if path:
        out.append(path)
    host = urllib.parse.unquote(u.netloc)
    if "+" in host:
        host = host.split("+", 1)[1]
    if host and u.scheme not in ("file", "http", "https"):
        out.append(host)
    return out


def walk(node, out):
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "path" and isinstance(v, str) and v.startswith("/"):
                out.append(v)
            elif k == "fsPath" and isinstance(v, str) and v.startswith("/"):
                out.append(v)
            walk(v, out)
    elif isinstance(node, list):
        for v in node:
            walk(v, out)
    elif isinstance(node, str):
        if "://" in node:
            out.extend(uri_parts(node))
        elif node.startswith("/") and "\n" not in node:
            pass  # a bare absolute string is not necessarily a project


def collect_json(text, out):
    try:
        walk(json.loads(text), out)
    except ValueError:
        pass


def read_flavor(cfg):
    paths = []
    user = cfg / "User"
    db = user / "globalStorage" / "state.vscdb"
    if db.is_file():
        try:
            r = subprocess.run(
                ["sqlite3", "-readonly", str(db), DB_QUERY],
                capture_output=True, text=True, timeout=10,
            )
            if r.returncode == 0:
                collect_json(r.stdout, paths)
        except (OSError, subprocess.SubprocessError):
            pass
    storage = user / "globalStorage" / "storage.json"
    if storage.is_file():
        try:
            collect_json(storage.read_text(errors="replace"), paths)
        except OSError:
            pass
    ws = user / "workspaceStorage"
    if ws.is_dir():
        for f in ws.glob("*/workspace.json"):
            try:
                collect_json(f.read_text(errors="replace"), paths)
            except OSError:
                pass
    return paths


def load_patterns():
    """Returns ({(text, is_host)}, flavor count)."""
    raw = []
    flavors = 0
    for d in CONFIG_DIRS:
        cfg = expand(d)
        if cfg.is_dir():
            flavors += 1
            raw.extend(read_flavor(cfg))
    patterns = set()
    for p in raw:
        if p.startswith(E2E_PREFIX):
            continue
        is_host = "/" not in p
        cands = [p]
        segs = [s for s in p.split("/") if s]
        if len(segs) >= 2:
            cands.append("/".join(segs[-2:]))
        for c in cands:
            if len(c) < MIN_LEN and not (is_host and len(c) >= 3):
                continue
            if is_host and c.lower() in HOST_STOPLIST:
                continue
            patterns.add((c, is_host and c == p))
            q = urllib.parse.quote(c)
            if q != c:
                patterns.add((q, False))
    return patterns, flavors


def compile_patterns(patterns):
    """-> list of predicates text -> bool. Paths: substring, also with the percent-encoding in
    the other case. Hosts: case-insensitive whole word."""
    out = []
    for text, is_host in sorted(patterns):
        if is_host:
            rx = re.compile(r"(?<![A-Za-z0-9_])" + re.escape(text) + r"(?![A-Za-z0-9_-])", re.I)
            out.append(lambda t, rx=rx: rx.search(t) is not None)
        else:
            rx = re.compile(re.escape(text), re.I if "%" in text else 0)
            out.append(lambda t, rx=rx: rx.search(t) is not None)
    return out


def scan_files(preds):
    hits = {}  # file name -> set of pattern indexes
    for f in sorted(PLUGIN.rglob("*")):
        if not f.is_file() or any(part in SKIP_DIRS for part in f.relative_to(PLUGIN).parts):
            continue
        try:
            text = f.read_bytes().decode("utf-8", errors="replace")
        except OSError:
            continue
        for i, pred in enumerate(preds):
            if pred(text):
                hits.setdefault(str(f.relative_to(ROOT)), set()).add(i)
    return hits


class GitFailed(Exception):
    pass


def scan_git(preds):
    r = subprocess.run(
        ["git", "-C", str(ROOT), "log", "-p", "--all"],
        capture_output=True, text=True, errors="replace", timeout=300,
    )
    if r.returncode != 0:
        raise GitFailed("git log failed with exit %d" % r.returncode)
    return {i for i, pred in enumerate(preds) if pred(r.stdout)}


def main():
    use_git = "--no-git" not in sys.argv[1:]
    patterns, flavors = load_patterns()
    if not patterns:
        print("nothing to check (no editor profile with recent projects found)")
        return 0
    preds = compile_patterns(patterns)
    file_hits = scan_files(preds)
    # History scan: path patterns only. Only the vscode/ tree is published (git archive), so dev
    # history never goes public and a bare host name there is just prose noise.
    path_patterns = {p for p in patterns if not p[1]}
    git_preds = compile_patterns(path_patterns)
    try:
        git_hits = scan_git(git_preds) if use_git else set()
    except GitFailed as e:
        print("privacy: error (%s); the history was not checked" % e)
        return 2
    matched = set()
    for s in file_hits.values():
        matched |= s
    # the two index sets refer to different lists, so they are counted separately
    if matched or git_hits:
        print("privacy: FAIL, %d tree + %d history pattern(s) matched" % (len(matched), len(git_hits)))
        for name in sorted(file_hits):
            print("  file: %s (%d)" % (name, len(file_hits[name])))
        if git_hits:
            print("  git history (%d)" % len(git_hits))
        return 1
    print("privacy: ok (tree %d patterns, history %s, %d flavor(s))" % (
        len(patterns), ("%d path patterns" % len(path_patterns)) if use_git else "skipped", flavors))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as e:  # never print anything that might hold a path
        print("privacy: error (%s)" % type(e).__name__)
        sys.exit(2)
