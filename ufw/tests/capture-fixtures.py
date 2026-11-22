#!/usr/bin/env python3
"""Regenerate tests/fixtures/ from the bwrap ufw sandbox (made-up rules only).

    python3 ufw/tests/capture-fixtures.py

Ends with a privacy check: no fixture may contain a tuple line of the real
/etc/ufw/user*.rules. Those lines are only held in memory, never printed.
"""

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from sandbox import Sandbox, available  # noqa: E402

OUT = pathlib.Path(__file__).resolve().parent / "fixtures"

SHAPES = [
    "allow 80/tcp",
    "allow 5173/udp",
    "allow 8080/tcp comment 'api dev server'",
    "allow from 192.0.2.0/24 to any port 22 proto tcp",
    "allow from 198.51.100.7",
    "limit 22/tcp",
    "deny 4444",
    "reject 4445/udp",
    "allow 60000:60010/tcp",
    "allow proto tcp from any to any port 80,443",
    "allow in on eth9 to any port 43117",
    "allow out 43118",
    "allow WWW",
    "route allow in on eth9 out on eth8",
    "allow from 2001:db8::/32 to any port 2222 proto tcp",
]


def ufw_cmds(cmds):
    import shlex
    return [["ufw"] + shlex.split(c) for c in cmds]


def put(name, text):
    (OUT / name).write_text(text)


def main():
    if not available():
        print("bwrap or ufw missing")
        return 1
    OUT.mkdir(exist_ok=True)

    with Sandbox() as sb:
        res = sb.run_many(ufw_cmds(["allow 49152"]))
        assert res[0][0] == 0, res
        put("simple-v4v6.rules", sb.read("user.rules"))
        put("simple-v6.rules", sb.read("user6.rules"))

    with Sandbox() as sb:
        res = sb.run_many(ufw_cmds(SHAPES))
        for cmd, (code, out, err) in zip(SHAPES, res):
            if code != 0:
                print("REJECTED (%d): ufw %s\n  %s %s" % (code, cmd, out.strip(), err.strip()))
                return 1
        put("shapes.rules", sb.read("user.rules"))
        put("shapes6.rules", sb.read("user6.rules"))

    with Sandbox() as sb:
        put("conf-off.conf", sb.read("ufw.conf"))
        res = sb.run_many([["ufw", "--force", "enable"]])
        assert res[0][0] == 0, res
        put("conf-on.conf", sb.read("ufw.conf"))

    with Sandbox() as sb:
        path = sb.root / "default-ufw"
        path.write_text(path.read_text().replace("IPV6=yes", "IPV6=no"))
        put("default-ipv6-no", sb.read("default-ufw"))

    with Sandbox() as sb:
        res = sb.run_many(ufw_cmds(["default allow incoming"]))
        assert res[0][0] == 0, res
        put("default-accept", sb.read("default-ufw"))

    # synthetic
    shapes = (OUT / "shapes.rules").read_text()
    cut = shapes.index("### END RULES ###")
    put("truncated.rules", shapes[:cut])
    put("garbage.rules", shapes.replace("### tuple ### allow tcp 80 0.0.0.0/0 any 0.0.0.0/0 in\n",
                                        "### tuple ### allow tcp 80\n", 1))
    assert "### tuple ### allow tcp 80\n" in (OUT / "garbage.rules").read_text()

    # privacy: compare against real tuple lines, in memory only
    real = set()
    for name in ("user.rules", "user6.rules"):
        try:
            for line in pathlib.Path("/etc/ufw", name).read_text().splitlines():
                if line.startswith("### tuple"):
                    real.add(line)
        except OSError:
            pass
    for f in sorted(OUT.iterdir()):
        for line in f.read_text().splitlines():
            if line in real:
                print("privacy: FAIL in %s" % f.name)
                return 1
    print("privacy: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
