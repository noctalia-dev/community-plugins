#!/usr/bin/env python3
"""Throwaway ufw sandbox for tests: real `ufw` against a private copy of /etc/ufw.

    python3 ufw/tests/sandbox.py --selftest

Sandbox() builds a temp root from sandbox-templates/ (empty user*.rules, ufw.conf,
/etc/default/ufw) plus the stock before*/after* rules, sysctl.conf and applications.d
copied from the host. It NEVER copies the host's user*.rules, ufw.conf or
/etc/default/ufw. run() executes inside bwrap with the root's files bind-mounted over
the real paths, as fake root in a user namespace with no network.
Files under the root persist across run() calls in one Sandbox, but kernel state
(`ufw enable`) does not: each run() has a fresh netns. Use run_many() for sequences.
"""

import os
import pathlib
import shlex
import shutil
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
TEMPLATES = HERE / "sandbox-templates"
HOST_ETC = pathlib.Path("/etc/ufw")
NAMES = ("user.rules", "user6.rules", "ufw.conf", "default-ufw")


def available():
    return shutil.which("bwrap") is not None and shutil.which("ufw") is not None


class Sandbox:
    def __enter__(self):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix="ufw-sandbox-"))
        etc = self.root / "etc-ufw"
        etc.mkdir()
        for name in ("user.rules", "user6.rules", "ufw.conf"):
            shutil.copy(TEMPLATES / name, etc / name)
        shutil.copy(TEMPLATES / "default-ufw", self.root / "default-ufw")
        for path in HOST_ETC.iterdir():
            if path.is_file() and (path.name.startswith(("before", "after")) and path.name.endswith(".rules")):
                shutil.copy(path, etc / path.name)
            elif path.name == "sysctl.conf" and path.is_file():
                shutil.copy(path, etc / path.name)
        apps = HOST_ETC / "applications.d"
        if apps.is_dir():
            shutil.copytree(apps, etc / "applications.d")
        return self

    def __exit__(self, *exc):
        shutil.rmtree(self.root, ignore_errors=True)
        return False

    def run(self, argv, ro_binds=()):
        """ro_binds: extra (source, dest) read-only bind mounts, e.g. a fake binary."""
        extra = []
        for src, dest in ro_binds:
            extra += ["--ro-bind", str(src), str(dest)]
        cmd = [
            "bwrap", "--dev-bind", "/", "/",
            "--bind", str(self.root / "etc-ufw"), "/etc/ufw",
            "--bind", str(self.root / "default-ufw"), "/etc/default/ufw",
            "--tmpfs", "/run",
        ] + extra + [
            "--unshare-user", "--uid", "0", "--gid", "0", "--unshare-net", "--cap-add", "ALL",
        ] + list(argv)
        proc = subprocess.run(cmd, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60)
        err = "\n".join(l for l in proc.stderr.splitlines() if not l.startswith("WARN: uid is 0"))
        return proc.returncode, proc.stdout, err

    def run_many(self, argvs):
        """Run several commands in ONE bwrap (one network namespace), so kernel
        state such as `ufw enable` survives from one command to the next. Each run()
        gets a fresh namespace, so a later `ufw status` there would report inactive.
        Returns [(exit, stdout, stderr), ...]."""
        mark = "@@UFW-SANDBOX-END@@"
        script = "".join(
            "%s; echo \"%s $?\"; echo \"%s\" >&2\n" % (" ".join(shlex.quote(a) for a in argv), mark, mark)
            for argv in argvs
        )
        # exit code goes on a stdout marker line; stderr is split by its own marker
        _, out, err = self.run(["sh", "-c", script])
        results = []
        out_parts = out.split(mark + " ")
        err_parts = [p.strip("\n") for p in err.split(mark)]
        # out_parts[0] is command 1 stdout; each later part starts with "<code>\n" then the next stdout
        stdout_chunks, codes = [out_parts[0]], []
        for part in out_parts[1:]:
            code, _, rest = part.partition("\n")
            codes.append(int(code))
            stdout_chunks.append(rest)
        for i, code in enumerate(codes):
            results.append((code, stdout_chunks[i], err_parts[i] if i < len(err_parts) else ""))
        return results

    def read(self, name):
        assert name in NAMES, name
        path = {"user.rules": "etc-ufw/user.rules", "user6.rules": "etc-ufw/user6.rules",
                "ufw.conf": "etc-ufw/ufw.conf", "default-ufw": "default-ufw"}[name]
        return (self.root / path).read_text()


def selftest():
    if not available():
        print("SKIP  bwrap or ufw missing")
        return 0
    real = HOST_ETC / "user.rules"
    before = os.stat(real).st_mtime_ns if real.exists() else None
    failures = 0

    def check(name, cond):
        nonlocal failures
        print(("ok    " if cond else "FAIL  ") + name)
        if not cond:
            failures += 1

    with Sandbox() as sb:
        res = sb.run_many([["ufw", "--force", "enable"], ["ufw", "allow", "49152/tcp"], ["ufw", "status"]])
        check("enable exits 0", res[0][0] == 0)
        check("allow exits 0", res[1][0] == 0)
        out = res[2][1]
        check("status active", "Status: active" in out)
        check("status lists 49152/tcp", "49152/tcp" in out)
        check("ufw.conf enabled in sandbox", "ENABLED=yes" in sb.read("ufw.conf"))
        check("user.rules written in sandbox", "49152" in sb.read("user.rules"))
    after = os.stat(real).st_mtime_ns if real.exists() else None
    check("real user.rules mtime unchanged", before == after)
    return failures


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(1 if selftest() else 0)
    print(__doc__)
