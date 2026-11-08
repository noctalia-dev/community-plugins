#!/usr/bin/env python3
"""Fails if anything of the user's real ufw rules appears in the given files or in the git history.

    python3 ufw/tests/privacy-check.py [paths ...]     files and directories (default: ufw/)
    python3 ufw/tests/privacy-check.py --git [paths]   also scan every line of `git log -p --all`
    python3 ufw/tests/privacy-check.py --backups [paths]  also load the dated backups
        /etc/ufw/user*.rules.* (unreadable ones are skipped) and match the 6-field tuple
        prefix (action proto dport dst sport src) of every tuple as well

It reads /etc/ufw/user.rules and user6.rules into memory only and looks for:
  * any whole tuple line (whitespace-normalised),
  * any real comment (decoded from the tuple's `comment=` field, 6+ characters, and its raw form),
  * any real address except a plain "anywhere" and the exact made-up fixture addresses
    (192.0.2.0/24, 198.51.100.7, 10.0.0.0/8, 2001:db8::/32). Every other address counts,
    including a real LAN address inside one of those ranges (such as 10.1.2.3).

On a hit it prints only the place (file:line, or commit, file and line for the history) and
never the match. Exit 0 and `privacy: ok (N patterns)` when nothing was found, 1 on a hit, 2 when
either real rules file cannot be read or on an unexpected error (type only). With no real rules
it prints `nothing to check` and exits 0.
"""

import glob
import ipaddress
import pathlib
import re
import subprocess
import sys
import urllib.parse

RULE_FILES = ("/etc/ufw/user.rules", "/etc/ufw/user6.rules")
# The made-up addresses the fixtures and docs use (global constraints), exempt as exact strings
# only. Their bare network addresses are not searched for on their own either: "10.0.0.0" would
# match inside "10.0.0.0/8".
FIXTURE_ADDRS = {"192.0.2.0/24", "198.51.100.7", "10.0.0.0/8", "2001:db8::/32"}
FIXTURE_BASES = {a.split("/")[0] for a in FIXTURE_ADDRS}
SKIP_DIRS = {"__pycache__", ".git", ".superpowers"}
MIN_COMMENT = 6


def norm(line):
    return " ".join(line.split())


def decode_comment(raw):
    """ufw stores a comment as hex (older) or percent-encoded text; try both."""
    out = {raw}
    try:
        out.add(bytes.fromhex(raw).decode("utf-8"))
    except ValueError:
        pass
    out.add(urllib.parse.unquote(raw))
    return {c for c in out if c}


def backup_files():
    return sorted(glob.glob("/etc/ufw/user*.rules.*"))


def load_secrets(backups=False):
    tuples, comments, addrs, prefixes = set(), set(), set(), set()
    readable = 0
    names = list(RULE_FILES)
    if backups:
        names += backup_files()
    for name in names:
        try:
            text = pathlib.Path(name).read_text()
        except OSError:
            continue
        if name in RULE_FILES:
            readable += 1
        for line in text.splitlines():
            if not line.startswith("### tuple ###"):
                continue
            tuples.add(norm(line))
            fields = line.split()
            if backups and len(fields) >= 9:
                prefixes.add(" ".join(fields[3:9]))
            for token in fields[3:]:
                if token.startswith("comment="):
                    for c in decode_comment(token[len("comment="):]):
                        if len(c) >= MIN_COMMENT:
                            comments.add(c)
                    continue
                if "=" in token:
                    continue
                try:
                    net = ipaddress.ip_network(token, strict=False)
                except ValueError:
                    continue
                if net.prefixlen == 0 or token in FIXTURE_ADDRS:
                    continue
                addrs.add(token)
                base = str(net.network_address)
                if base not in FIXTURE_BASES:
                    addrs.add(base)
    if readable != len(RULE_FILES):
        raise RuntimeError("cannot read both " + " and ".join(RULE_FILES))
    patterns = [re.compile(r"(?<![0-9A-Za-z:.])" + re.escape(a) + r"(?![0-9A-Za-z:])") for a in sorted(addrs)]
    return tuples, comments, patterns, prefixes


class Scanner:
    def __init__(self, backups=False):
        self.tuples, self.comments, self.addr_patterns, self.prefixes = load_secrets(backups)
        self.count = len(self.tuples) + len(self.comments) + len(self.addr_patterns) + len(self.prefixes)

    def hit(self, line):
        flat = norm(line)
        for t in self.tuples:
            if t in flat:
                return True
        for t in self.prefixes:
            if t in flat:
                return True
        for c in self.comments:
            if c in line:
                return True
        for p in self.addr_patterns:
            if p.search(line):
                return True
        return False


def files_under(paths):
    for path in paths:
        p = pathlib.Path(path)
        if p.is_file():
            yield p
        elif p.is_dir():
            for f in sorted(p.rglob("*")):
                if f.is_file() and not (set(f.parts) & SKIP_DIRS):
                    yield f


def scan_files(scanner, paths):
    hits = []
    for f in files_under(paths):
        try:
            text = f.read_text(errors="replace")
        except OSError:
            continue
        for n, line in enumerate(text.splitlines(), 1):
            if scanner.hit(line):
                hits.append("%s:%d" % (f, n))
    return hits


def scan_git(scanner):
    hits = []
    proc = subprocess.Popen(["git", "log", "-p", "--all", "--format=@@commit %h"],
                            stdout=subprocess.PIPE, text=True, errors="replace")
    commit, path, n = "?", "?", 0
    for line in proc.stdout:
        line = line.rstrip("\n")
        if line.startswith("@@commit "):
            commit, path, n = line[9:], "(message)", 0
            continue
        if line.startswith("+++ "):
            path = line[4:]
            continue
        n += 1
        if scanner.hit(line):
            hits.append("commit %s %s: diff line %d" % (commit, path, n))
    proc.wait()
    return hits


def main(argv):
    git = "--git" in argv
    backups = "--backups" in argv
    paths = [a for a in argv if a not in ("--git", "--backups")] or ["ufw"]
    try:
        scanner = Scanner(backups)
    except RuntimeError as err:
        print("privacy: %s" % err)
        return 2
    if scanner.count == 0:
        print("privacy: nothing to check (0 real rules)")
        return 0
    hits = scan_files(scanner, paths)
    if git:
        hits += scan_git(scanner)
    if hits:
        print("privacy: FOUND real rule data at:")
        for h in hits:
            print("  " + h)
        return 1
    print("privacy: ok (%d patterns)" % scanner.count)
    return 0


if __name__ == "__main__":
    try:
        code = main(sys.argv[1:])
    except Exception as err:  # noqa: BLE001 - never print a message: it could hold rule data
        print("privacy: unexpected %s" % type(err).__name__)
        code = 2
    sys.exit(code)
