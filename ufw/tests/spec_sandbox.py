#!/usr/bin/env python3
"""Runs the plugin's real BATCH_SCRIPT and argvs against real ufw in the bwrap sandbox.

    python3 ufw/tests/spec_sandbox.py

The script and argvs come from commands.luau itself, through a tiny Lua driver (`lua -e`,
with run.lua's loadModule), printed as JSON. Root argvs run in the sandbox without their
leading `pkexec`: `/bin/sh -c BATCH_SCRIPT ufw-batch <op>...`. Only made-up rules are used;
the host's /etc/ufw files are never read (only the real user.rules mtime is compared).
"""

import importlib.util
import json
import os
import pathlib
import shlex
import shutil
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
PLUGIN = HERE.parent
sys.path.insert(0, str(HERE))
from sandbox import Sandbox, available  # noqa: E402

US = "\x1f"

_spec = importlib.util.spec_from_file_location("capture_fixtures", HERE / "capture-fixtures.py")
_capture = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_capture)
FIXTURE_SHAPES = list(_capture.SHAPES)

# Shapes beyond Task 2's fixtures, each backing a REMOVABLE_SHAPES entry.
EXTRA_SHAPES = [
    "allow log 41001/tcp",
    "allow in on eth9 log-all to any port 41002",
    "allow from 0.0.0.0/0 to any port 41003 proto tcp",
    "allow from ::/0 to any port 41004 proto udp",
    "allow from 192.0.2.0/24 port 41005 to any port 41006 proto udp",
    "allow from any to 10.0.0.0/8 port 41007 proto tcp",
    "allow 'WWW Full'",
    "deny out on eth9 to any port 41008",
    "route allow in on eth9 to any port 41009 proto tcp",
]
ALL_SHAPES = FIXTURE_SHAPES + EXTRA_SHAPES

DRIVER = r"""
local DIR = os.getenv("UFW_DIR")
local function readAll(path)
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  return text
end
local chunkLoader = loadstring or load
local cache = {}
function loadModule(relative)
  if cache[relative] == nil then
    local src = readAll(DIR .. relative)
    src = src:gsub("^%-%-!%S+%s*\n", "")
    cache[relative] = { value = assert(chunkLoader(src, "@" .. relative))() }
  end
  return cache[relative].value
end
function require(path)
  return loadModule(assert(path:match("^%./(.+%.luau)$")))
end
local json = dofile(DIR .. "tests/json.lua")
local commands = loadModule("commands.luau")
local rules = loadModule("rules.luau")
local req = assert(json.decode(readAll(os.getenv("UFW_DRIVER_IN"))))

local function parsed(r)
  local list = rules.parseRules(r.v4, r.v6, r.ipv6)
  local extra = rules.parseRules(r.extra or "", nil, true)
  local byId = {}
  for _, rule in ipairs(list) do byId[rule.id] = rule end
  for _, rule in ipairs(extra) do byId[rule.id] = rule end
  return list, byId
end

local function lineIds(text)
  local out = {}
  for line in string.gmatch(text or "", "[^\n]+") do
    if string.find(line, "### tuple ###", 1, true) == 1 then
      local one = rules.parseRules(line .. "\n### END RULES ###\n", nil, true)[1]
      out[#out + 1] = { line, one and one.id or "" }
    end
  end
  return out
end

local out = {}
if req.cmd == "consts" then
  local shapes = {}
  for key in pairs(commands.REMOVABLE_SHAPES) do shapes[#shapes + 1] = key end
  table.sort(shapes)
  out = {
    batch = commands.BATCH_SCRIPT,
    enable_active = commands.argv("enable", { hasSystemctl = true, unit = { active = "active" } }),
    enable_inactive = commands.argv("enable", { hasSystemctl = true, unit = { active = "inactive" } }),
    disable = commands.argv("disable", {}),
    load_rules = commands.argv("load_rules", {}),
    shapes = shapes,
  }
elseif req.cmd == "parse" then
  local list, byId = parsed(req)
  local rows = {}
  for i, rule in ipairs(list) do
    rows[i] = {
      id = rule.id, shape = commands.shapeKey(rule), removable = commands.isRemovableShape(rule),
      v4 = rule.v4, v6 = rule.v6, comment = rule.comment or "",
      delete = commands.deleteArgs(rule) or {},
      save = commands.saveArgv({ { id = "r", kind = "remove", ruleId = rule.id } }, byId),
    }
  end
  out = { rules = rows, v4lines = lineIds(req.v4), v6lines = lineIds(req.v6) }
elseif req.cmd == "save" then
  local _, byId = parsed(req)
  local argv, order = commands.saveArgv(req.pending, byId)
  out = { argv = argv, order = order }
elseif req.cmd == "validate" then
  local op, err = commands.validateAdd(req.port, req.proto, req.comment)
  out = { ok = op ~= nil, err = err or "" }
elseif req.cmd == "batch" then
  local b = commands.parseBatch(req.stdout)
  local results = {}
  for i = 1, req.n do
    local r = b.results[i]
    if r == nil then
      results[i] = "none"
    elseif r.ok then
      results[i] = "ok"
    elseif r.written then
      results[i] = "written"
    else
      results[i] = { code = r.code or -1, msg = r.msg or "" }
    end
  end
  out = { complete = b.complete, results = results, dump = b.dump }
elseif req.cmd == "applied" then
  -- the service's check of a `written` op, against the rules parsed from the files
  local list = rules.parseRules(req.v4, req.v6, req.ipv6)
  local before = nil
  if req.before_v4 ~= nil then
    before = rules.parseRules(req.before_v4, req.before_v6, req.ipv6)
  end
  local applied = {}
  for i, op in ipairs(req.pending) do
    applied[i] = commands.applied(op, list, req.ipv6, before)
  end
  out = { applied = applied }
end
io.write(assert(json.encode(out)))
"""

_failures = 0


def check(name, cond, detail=""):
    global _failures
    print(("ok    " if cond else "FAIL  ") + name + ("" if cond or not detail else "  -- " + detail))
    if not cond:
        _failures += 1
    return cond


def lua(request):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(request, f)
        path = f.name
    try:
        env = dict(os.environ, UFW_DIR=str(PLUGIN) + "/", UFW_DRIVER_IN=path)
        proc = subprocess.run(["lua", "-e", DRIVER], capture_output=True, text=True, env=env, timeout=30)
    finally:
        os.unlink(path)
    if proc.returncode != 0:
        raise RuntimeError("lua driver failed: " + proc.stderr)
    return json.loads(proc.stdout)


CONSTS = None


def consts():
    global CONSTS
    if CONSTS is None:
        CONSTS = lua({"cmd": "consts"})
    return CONSTS


def run_root(sb, argv, shell=None, **kw):
    """Runs a plugin root argv in the sandbox, without its leading pkexec."""
    assert argv[0] == "pkexec", argv
    rest = list(argv[1:])
    if shell is not None:
        assert rest[0] == "/bin/sh"
        rest = list(shell) + rest[1:]
    return sb.run(rest, **kw)


def batch(stdout, n):
    return lua({"cmd": "batch", "stdout": stdout, "n": n})


def files(sb):
    return sb.read("user.rules"), sb.read("user6.rules")


def ufw_cmds(cmds):
    return [["ufw"] + shlex.split(c) for c in cmds]


def set_ipv6(sb, on):
    path = sb.root / "default-ufw"
    text = path.read_text()
    path.write_text(text.replace("IPV6=yes", "IPV6=no") if not on else text.replace("IPV6=no", "IPV6=yes"))


def restore(sb, v4, v6):
    (sb.root / "etc-ufw" / "user.rules").write_text(v4)
    (sb.root / "etc-ufw" / "user6.rules").write_text(v6)


def without_blocks(text, ids_by_line, target):
    """text minus every rule block (tuple line up to the next '### ' line) whose tuple is target."""
    out, removed, skipping = [], 0, False
    for line in text.splitlines(keepends=True):
        bare = line.rstrip("\n")
        if bare.startswith("### "):
            skipping = bare.startswith("### tuple ###") and ids_by_line.get(bare) == target
            if skipping:
                removed += 1
        if not skipping:
            out.append(line)
    return "".join(out), removed


def save_argv(sb, pending, extra=""):
    v4, v6 = files(sb)
    return lua({"cmd": "save", "pending": pending, "v4": v4, "v6": v6, "ipv6": True, "extra": extra})


# ---------------------------------------------------------------------------

def test_add():
    with Sandbox() as sb:
        pending = [
            {"id": "a1", "kind": "add", "port": 41100, "proto": "both"},
            {"id": "a2", "kind": "add", "port": 41101, "proto": "tcp"},
            {"id": "a3", "kind": "add", "port": 41102, "proto": "udp"},
            {"id": "a4", "kind": "add", "port": 41103, "proto": "tcp", "comment": "api dev server"},
        ]
        save = save_argv(sb, pending)
        code, out, err = run_root(sb, save["argv"])
        b = batch(out, 4)
        v4, v6 = files(sb)
        hexc = "api dev server".encode().hex()
        check("sandbox: add batch exits 0", code == 0, err)
        check("sandbox: add all ops ok", b["results"] == ["ok"] * 4, str(b["results"]))
        check("sandbox: add dump complete", b["complete"] is True)
        check("sandbox: add both tuple v4/v6",
              "### tuple ### allow any 41100 0.0.0.0/0 any 0.0.0.0/0 in\n" in v4
              and "### tuple ### allow any 41100 ::/0 any ::/0 in\n" in v6)
        check("sandbox: add tcp tuple", "### tuple ### allow tcp 41101 0.0.0.0/0 any 0.0.0.0/0 in\n" in v4
              and "### tuple ### allow tcp 41101 ::/0 any ::/0 in\n" in v6)
        check("sandbox: add udp tuple", "### tuple ### allow udp 41102 0.0.0.0/0 any 0.0.0.0/0 in\n" in v4
              and "### tuple ### allow udp 41102 ::/0 any ::/0 in\n" in v6)
        check("sandbox: add comment tuple",
              ("### tuple ### allow tcp 41103 0.0.0.0/0 any 0.0.0.0/0 in comment=%s\n" % hexc) in v4
              and ("### tuple ### allow tcp 41103 ::/0 any ::/0 in comment=%s\n" % hexc) in v6)
        check("sandbox: add dump v4 matches file", b["dump"].get("v4") == v4)


def test_comments():
    punct = "".join(chr(c) for c in range(0x20, 0x7F) if not chr(c).isalnum() and chr(c) not in "'\"\\")
    comments = [
        "a" + punct + "z",                       # every allowed punctuation char, and a space
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz 0123456789",
        "x  $(touch /pwned) `id` ${HOME} *",     # shell syntax is just text
        "on", "comment", "from", "proto", "to",  # ufw keywords it does accept as a comment
        "a" * 64,
    ]
    for c in comments:
        assert lua({"cmd": "validate", "port": "41200", "proto": "tcp", "comment": c})["ok"], c
    with Sandbox() as sb:
        pending = [{"id": "c%d" % i, "kind": "add", "port": 41200 + i, "proto": "tcp", "comment": c}
                   for i, c in enumerate(comments)]
        save = save_argv(sb, pending)
        code, out, _ = run_root(sb, save["argv"])
        b = batch(out, len(comments))
        v4, v6 = files(sb)
        rows = lua({"cmd": "parse", "v4": v4, "v6": v6, "ipv6": True})["rules"]
        got = sorted(r["comment"] for r in rows)
        check("sandbox: comment with spaces and every allowed punctuation char", code == 0
              and b["results"] == ["ok"] * len(comments) and got == sorted(comments),
              "%s %s" % (b["results"], got))
        check("sandbox: shell syntax in a comment ran nothing", not (sb.root / "pwned").exists()
              and not pathlib.Path("/pwned").exists())
    # comments ufw refuses, which validateAdd refuses too
    refused = ["in", "out", "log", "log-all", "--rootdir=/x", "--datadir=/x"]
    with Sandbox() as sb:
        res = sb.run_many([["ufw", "--dry-run", "allow", "41300/tcp", "comment", c] for c in refused])
        for c, (code, out, err) in zip(refused, res):
            v = lua({"cmd": "validate", "port": "41300", "proto": "tcp", "comment": c})
            check("sandbox: ufw refuses comment %r and so does validateAdd" % c,
                  code != 0 and not v["ok"] and v["err"] == "add.error_comment", (out + err).strip())


def test_round_trips(ipv6):
    mode = "ipv6" if ipv6 else "ipv6=no"
    shapes = ALL_SHAPES if ipv6 else [s for s in ALL_SHAPES if "2001:db8" not in s and "::/0" not in s]
    proven = set()
    with Sandbox() as sb:
        set_ipv6(sb, ipv6)
        res = sb.run_many(ufw_cmds(shapes))
        bad = [(s, r) for s, r in zip(shapes, res) if r[0] != 0 or "ERROR" in r[1] + r[2]]
        check("sandbox: %s: every shape added" % mode, not bad, str(bad))
        v4, v6 = files(sb)
        data = lua({"cmd": "parse", "v4": v4, "v6": v6, "ipv6": ipv6})
        ids = {line: rid for line, rid in list(data["v4lines"] or []) + list(data["v6lines"] or [])}
        check("sandbox: %s: one parsed rule per shape" % mode, len(data["rules"]) == len(shapes),
              "%d rules for %d shapes" % (len(data["rules"]), len(shapes)))
        for rule in data["rules"]:
            name = "sandbox: %s: round trip %s [%s]" % (mode, rule["shape"], rule["id"])
            if not rule["removable"]:
                check(name + " (shape is not removable)", False, rule["id"])
                continue
            restore(sb, v4, v6)
            code, out, err = run_root(sb, rule["save"])
            b = batch(out, 1)
            a4, a6 = files(sb)
            want4, n4 = without_blocks(v4, ids, rule["id"])
            want6, n6 = without_blocks(v6, ids, rule["id"]) if ipv6 else (v6, 0)
            copies = (n4 == (1 if rule["v4"] else 0)) and (n6 == (1 if rule["v6"] else 0)) and n4 + n6 > 0
            good = (code == 0 and b["results"] == ["ok"] and b["complete"] and copies
                    and a4 == want4 and a6 == want6)
            if good:
                proven.add(rule["shape"])
            check(name, good, "exit %d results %s copies v4=%d v6=%d v4same=%s v6same=%s args=%s" % (
                code, b["results"], n4, n6, a4 == want4, a6 == want6, rule["delete"]))
    missing = sorted(set(consts()["shapes"]) - proven)
    check("sandbox: %s: every REMOVABLE_SHAPES entry is proven" % mode, not missing, str(missing))


def test_multi_tuple_app():
    """A profile with several port specs writes one tuple per spec, and one delete by app name
    removes all of them, so those rows must not be removable one by one."""
    with Sandbox() as sb:
        res = sb.run_many(ufw_cmds(["allow XMPP", "allow WWW"]))
        assert all(r[0] == 0 for r in res), res
        v4, v6 = files(sb)
        rows = lua({"cmd": "parse", "v4": v4, "v6": v6, "ipv6": True})["rules"]
        xmpp = [r for r in rows if r["id"].endswith("|XMPP||0|")]
        www = [r for r in rows if r["id"].endswith("|WWW||0|")]
        check("sandbox: multi-tuple app profile gives two rows", len(xmpp) == 2, str(len(xmpp)))
        check("sandbox: multi-tuple app rows are not removable", all(not r["removable"] for r in xmpp))
        check("sandbox: lone app row next to them is removable", len(www) == 1 and www[0]["removable"])
        res = sb.run_many([["ufw", "--force", "delete", "allow", "from", "any", "to", "any", "app", "XMPP"]])
        a4, _ = files(sb)
        check("sandbox: (why) one delete by app name removes both XMPP tuples",
              res[0][0] == 0 and "XMPP" not in a4 and "XMPP" in v4)
    with Sandbox() as sb:
        res = sb.run_many(ufw_cmds(["allow WWW", "route allow to any app WWW"]))
        assert all(r[0] == 0 for r in res), res
        v4, v6 = files(sb)
        rows = lua({"cmd": "parse", "v4": v4, "v6": v6, "ipv6": True})["rules"]
        check("sandbox: app rule with a route rule for the same app is not removable",
              len(rows) == 2 and all(not r["removable"] for r in rows))
        res = sb.run_many([["ufw", "--force", "delete", "allow", "from", "any", "to", "any", "app", "WWW"]])
        a4, _ = files(sb)
        check("sandbox: (why) a delete by app name also removes the route rule", res[0][0] == 0 and "WWW" not in a4)


def test_mid_batch_failure():
    with Sandbox() as sb:
        res = sb.run_many(ufw_cmds(["allow 41400/tcp", "allow 41401/tcp"]))
        assert all(r[0] == 0 for r in res), res
        ghost = "### tuple ### allow tcp 41499 0.0.0.0/0 any 0.0.0.0/0 in\n### END RULES ###\n"
        v4, v6 = files(sb)
        rows = lua({"cmd": "parse", "v4": v4, "v6": v6, "ipv6": True})["rules"]
        first = [r for r in rows if "|41400|" in r["id"]][0]["id"]
        ghost_id = "allow|in|tcp|41499|any||any|||0|"
        pending = [
            {"id": "add", "kind": "add", "port": 41402, "proto": "tcp"},
            {"id": "rm1", "kind": "remove", "ruleId": first},
            {"id": "rm2", "kind": "remove", "ruleId": ghost_id},
        ]
        save = save_argv(sb, pending, extra=ghost)
        check("sandbox: mid-batch order is removes then adds", save["order"] == ["rm1", "rm2", "add"], str(save["order"]))
        code, out, _ = run_root(sb, save["argv"])
        b = batch(out, 3)
        a4, a6 = files(sb)
        r2 = b["results"][1]
        check("sandbox: mid-batch failure: op 1 applied", b["results"][0] == "ok" and "41400" not in a4 and "41400" not in a6)
        check("sandbox: mid-batch failure: op 2 failed with ufw's message", isinstance(r2, dict)
              and "Could not delete non-existent rule" in r2["msg"], str(r2))
        check("sandbox: mid-batch failure: op 3 did not run", b["results"][2] == "none" and "41402" not in a4)
        ids = lua({"cmd": "parse", "v4": v4, "v6": v6, "ipv6": True})
        ids = {line: rid for line, rid in list(ids["v4lines"] or []) + list(ids["v6lines"] or [])}
        want4, n4 = without_blocks(v4, ids, first)
        want6, n6 = without_blocks(v6, ids, first)
        check("sandbox: mid-batch failure: other rules byte-identical", n4 == 1 and n6 == 1 and a4 == want4
              and a6 == want6 and "41401" in a4)
        check("sandbox: mid-batch failure: dump complete", b["complete"] is True and b["dump"].get("v4") == a4)
        check("sandbox: mid-batch failure: script exits 1", code == 1, str(code))
        # a ufw error (exit 1) also stops the batch
        bad = consts()["load_rules"] + [US.join(["rule", "allow", "99999"])]
        code, out, _ = run_root(sb, bad)
        b = batch(out, 1)
        check("sandbox: ufw error exit is a failure", isinstance(b["results"][0], dict) and b["results"][0]["code"] != 0
              and "Bad port" in b["results"][0]["msg"] and b["complete"], str(b["results"]))


def test_success_strings():
    """ufw 0.36.2 (backend_iptables.set_rule): a disabled firewall says "Rules updated" for adds and
    deletes; an enabled one says "Rule added" / "Rule deleted". An op is ok only with one of
    those, exit 0, and no "Could not" / "Skipping". "Rule updated" for an add means ufw replaced
    another rule (same tuple, other action), so it is a failure."""
    load = consts()["load_rules"]
    add = US.join(["rule", "allow", "41700/tcp"])
    delete = US.join(["delete", "allow", "in", "proto", "tcp", "from", "any", "to", "any", "port", "41700"])
    with Sandbox() as sb:
        res = sb.run_many([
            ["ufw", "--force", "enable"],
            ["ufw", "--force", "rule", "allow", "41701/tcp"],
            ["ufw", "--force", "delete", "allow", "41701/tcp"],
            load[1:] + [add],
            load[1:] + [add],
            load[1:] + [delete],
            ["ufw", "--force", "rule", "deny", "41703/tcp"],
            load[1:] + [US.join(["rule", "allow", "41703/tcp"])],
        ])
        check("sandbox: enabled ufw says Rule added", "Rule added" in res[1][1] and "Rules updated" not in res[1][1], res[1][1])
        check("sandbox: enabled ufw says Rule deleted", "Rule deleted" in res[2][1] and "Rules updated" not in res[2][1], res[2][1])
        b = batch(res[3][1], 1)
        check("sandbox: enabled: add op ok", res[3][0] == 0 and b["results"] == ["ok"], str(b["results"]))
        b = batch(res[4][1], 1)
        r = b["results"][0]
        check("sandbox: enabled: adding an existing rule (Skipping) is a failure", res[4][0] == 1 and isinstance(r, dict)
              and r["code"] == 0 and "Skipping adding existing rule" in r["msg"], str(r))
        b = batch(res[5][1], 1)
        check("sandbox: enabled: delete op ok", res[5][0] == 0 and b["results"] == ["ok"]
              and "41700" not in (b["dump"].get("v4") or "x41700"), str(b["results"]))
        b = batch(res[7][1], 1)
        r = b["results"][0]
        check("sandbox: enabled: an add that replaces a rule (Rule updated) is a failure", res[7][0] == 1
              and isinstance(r, dict) and "Rule updated" in r["msg"], str(r))
    with Sandbox() as sb:
        res = sb.run_many([["ufw", "--force", "rule", "allow", "41702/tcp"],
                           ["ufw", "--force", "delete", "allow", "41702/tcp"]])
        check("sandbox: disabled ufw says Rules updated for add and delete",
              all(r[0] == 0 and "Rules updated" in r[1] for r in res), str(res))
        b = batch(run_root(sb, load + [add])[1], 1)
        check("sandbox: disabled: add op ok", b["results"] == ["ok"], str(b["results"]))
        b = batch(run_root(sb, load + [add])[1], 1)
        check("sandbox: disabled: adding an existing rule (Skipping) is a failure",
              isinstance(b["results"][0], dict) and "Skipping" in b["results"][0]["msg"], str(b["results"]))
        b = batch(run_root(sb, load + [delete])[1], 1)
        check("sandbox: disabled: delete op ok", b["results"] == ["ok"], str(b["results"]))


def stopped_sandbox(sb, setup):
    """ufw.conf ENABLED=yes with no chains loaded: what `systemctl stop ufw` (the plugin's Turn
    off) leaves. `ufw enable` runs in one run(); every later run() has a fresh network
    namespace, so the chains are gone while ENABLED stays yes."""
    if setup:
        res = sb.run_many(ufw_cmds(setup))
        assert all(r[0] == 0 for r in res), res
    code, _, err = sb.run(["ufw", "--force", "enable"])
    assert code == 0, err
    _, out, _ = sb.run(["ufw", "status"])
    return "ENABLED=yes" in sb.read("ufw.conf") and "Status: inactive" in out


def applied(sb, pending, before=None):
    v4, v6 = files(sb)
    req = {"cmd": "applied", "pending": pending, "v4": v4, "v6": v6, "ipv6": True}
    if before is not None:
        req["before_v4"], req["before_v6"] = before
    return lua(req)["applied"]


def test_stopped_state():
    """Save while ufw is stopped (ENABLED=yes, chains unloaded). ufw writes its rules file, then
    fails on the running firewall ("problem running", exit 1) after the IPv4 file. The script
    reports `written`, writes the IPv6 copy with a second run and goes on, so every op is
    applied in one batch; the service then checks the dump (commands.applied)."""
    tag = "sandbox: stopped: "
    # adds: both families, tcp, udp with a comment
    with Sandbox() as sb:
        check(tag + "ENABLED=yes with no chains loaded", stopped_sandbox(sb, []))
        pending = [
            {"id": "a1", "kind": "add", "port": 41920, "proto": "both"},
            {"id": "a2", "kind": "add", "port": 41921, "proto": "tcp"},
            {"id": "a3", "kind": "add", "port": 41922, "proto": "udp", "comment": "stopped add"},
        ]
        code, out, err = run_root(sb, save_argv(sb, pending)["argv"])
        b = batch(out, 3)
        v4, v6 = files(sb)
        hexc = "stopped add".encode().hex()
        check(tag + "add batch exits 0", code == 0, err)
        check(tag + "every add is reported written", b["results"] == ["written"] * 3, str(b["results"]))
        check(tag + "add dump complete and matches the files", b["complete"] is True
              and b["dump"].get("v4") == v4 and b["dump"].get("v6") == v6)
        check(tag + "adds are in both files",
              "### tuple ### allow any 41920 0.0.0.0/0 any 0.0.0.0/0 in\n" in v4
              and "### tuple ### allow any 41920 ::/0 any ::/0 in\n" in v6
              and "### tuple ### allow tcp 41921 0.0.0.0/0 any 0.0.0.0/0 in\n" in v4
              and "### tuple ### allow tcp 41921 ::/0 any ::/0 in\n" in v6
              and ("### tuple ### allow udp 41922 0.0.0.0/0 any 0.0.0.0/0 in comment=%s\n" % hexc) in v4
              and ("### tuple ### allow udp 41922 ::/0 any ::/0 in comment=%s\n" % hexc) in v6)
        check(tag + "each add written once", v4.count("### tuple ###") == 3 and v6.count("### tuple ###") == 3)
        check(tag + "the service's check confirms every add", applied(sb, pending) == [True] * 3)
        check(tag + "still ENABLED=yes", "ENABLED=yes" in sb.read("ufw.conf"))
        # the same adds again: ufw skips them, and that stays a failure
        code, out, _ = run_root(sb, save_argv(sb, pending[:1])["argv"])
        r = batch(out, 1)["results"][0]
        check(tag + "adding an existing rule (Skipping) is a failure", code == 1 and isinstance(r, dict)
              and "Skipping adding existing rule" in r["msg"], str(r))
    # deletes: a rule with both copies, a v4-only and a v6-only one
    setup = ["allow 41930/tcp", "allow from 192.0.2.0/24 to any port 41931 proto tcp",
             "allow from 2001:db8::/32 to any port 41932 proto udp", "allow 41933/udp"]
    with Sandbox() as sb:
        check(tag + "ENABLED=yes with no chains loaded (deletes)", stopped_sandbox(sb, setup))
        v4, v6 = files(sb)
        data = lua({"cmd": "parse", "v4": v4, "v6": v6, "ipv6": True})
        ids = {line: rid for line, rid in list(data["v4lines"] or []) + list(data["v6lines"] or [])}
        targets = [r["id"] for r in data["rules"] if "|41933|" not in r["id"]]
        pending = [{"id": "r%d" % i, "kind": "remove", "ruleId": rid} for i, rid in enumerate(targets)]
        code, out, err = run_root(sb, save_argv(sb, pending)["argv"])
        b = batch(out, 3)
        a4, a6 = files(sb)
        want4, want6, n4, n6 = v4, v6, 0, 0
        for rid in targets:
            want4, k4 = without_blocks(want4, ids, rid)
            want6, k6 = without_blocks(want6, ids, rid)
            n4, n6 = n4 + k4, n6 + k6
        check(tag + "delete batch exits 0", code == 0, err)
        check(tag + "every delete is reported written", len(targets) == 3
              and b["results"] == ["written"] * 3, str(b["results"]))
        check(tag + "deletes removed exactly those rules (both copies), nothing else",
              n4 == 2 and n6 == 2 and a4 == want4 and a6 == want6 and "41933" in a4 and "41933" in a6)
        check(tag + "the service's check confirms every delete", applied(sb, pending) == [True] * 3)
        # a delete of a rule that is not there stays a failure
        ghost = "### tuple ### allow tcp 41939 0.0.0.0/0 any 0.0.0.0/0 in\n### END RULES ###\n"
        gone = [{"id": "g", "kind": "remove", "ruleId": "allow|in|tcp|41939|any||any|||0|"}]
        code, out, _ = run_root(sb, save_argv(sb, gone, extra=ghost)["argv"])
        r = batch(out, 1)["results"][0]
        check(tag + "deleting a non-existent rule is a failure", code == 1 and isinstance(r, dict)
              and "Could not delete non-existent rule" in r["msg"], str(r))
    # mixed: removes then adds, one prompt, every op applied
    with Sandbox() as sb:
        check(tag + "ENABLED=yes with no chains loaded (mixed)", stopped_sandbox(sb, ["allow 41940/tcp", "allow 41941"]))
        v4, v6 = files(sb)
        rows = lua({"cmd": "parse", "v4": v4, "v6": v6, "ipv6": True})["rules"]
        rm = [r["id"] for r in rows if "|41940|" in r["id"]][0]
        pending = [
            {"id": "add1", "kind": "add", "port": 41942, "proto": "tcp"},
            {"id": "rm", "kind": "remove", "ruleId": rm},
            {"id": "add2", "kind": "add", "port": 41943, "proto": "both"},
        ]
        save = save_argv(sb, pending)
        code, out, err = run_root(sb, save["argv"])
        b = batch(out, 3)
        a4, a6 = files(sb)
        check(tag + "mixed batch exits 0 with every op written", code == 0
              and b["results"] == ["written"] * 3, "%d %s %s" % (code, b["results"], err))
        check(tag + "mixed batch applied every op", "41940" not in a4 and "41940" not in a6
              and "41941" in a4 and "41941" in a6 and "41942" in a4 and "41942" in a6
              and "41943" in a4 and "41943" in a6)
        order = {op_id: i for i, op_id in enumerate(save["order"])}
        ordered = sorted(pending, key=lambda op: order[op["id"]])
        check(tag + "the service's check confirms the mixed batch", applied(sb, ordered) == [True] * 3)
        # the check is not fooled: an add that is not in the files, a remove that still is
        check(tag + "the check refuses ops the files don't show",
              applied(sb, [{"id": "x", "kind": "add", "port": 41944, "proto": "tcp"},
                           {"id": "y", "kind": "add", "port": 41942, "proto": "udp"},
                           {"id": "z", "kind": "remove", "ruleId": [r["id"] for r in rows if "|41941|" in r["id"]][0]}])
              == [False, False, False])
    # an add over an existing deny: ufw turns the deny into this allow ("Rule updated", then the
    # stopped reload fails). The files show an allow, but the add replaced a rule: not counted.
    with Sandbox() as sb:
        check(tag + "ENABLED=yes with no chains loaded (replace)", stopped_sandbox(sb, ["deny 41950/tcp"]))
        before = files(sb)
        pending = [{"id": "a", "kind": "add", "port": 41950, "proto": "tcp"}]
        code, out, err = run_root(sb, save_argv(sb, pending)["argv"])
        b = batch(out, 1)
        a4, a6 = files(sb)
        check(tag + "an add over a deny is reported written", b["results"] == ["written"], "%s %s" % (b["results"], err))
        check(tag + "(why) ufw turned the deny into an allow", "allow tcp 41950" in a4 and "allow tcp 41950" in a6
              and "deny tcp 41950" not in a4 + a6)
        check(tag + "the service's check refuses an add that replaced a deny", applied(sb, pending, before) == [False])
        check(tag + "(without the rules before, the files alone would pass it)", applied(sb, pending) == [True])


FAKE_LIVE_ERRORS = {
    # a loaded firewall: the reload flushed the chains, then the restore failed (backend_iptables
    # _reload_user_rules), or the live insert after the file was written failed (set_rule)
    "problem running iptables": "WARN: x\nERROR: problem running iptables\n",
    "problem running ip6tables": "ERROR: problem running ip6tables\n",
    "Could not update running firewall": "ERROR: Could not update running firewall\n",
}

FAKE_ERROR = """#!/bin/sh
echo "$*" >> {log}
printf '{text}'
exit 1
"""


def test_live_update_errors():
    """Only output ending in the bare "problem running" (the stopped state) is `written`. A live
    update that fails on a loaded firewall is a plain failure: no second run, the batch stops."""
    tag = "sandbox: live update error: "
    load = consts()["load_rules"]
    ops = [US.join(["rule", "allow", "41960/tcp"]), US.join(["rule", "allow", "41961/tcp"])]
    cases = dict(FAKE_LIVE_ERRORS)
    cases["bare problem running"] = "WARN: x\nERROR: problem running\n"
    for name, text in cases.items():
        with Sandbox() as sb:
            log = sb.root / "etc-ufw" / "fake-calls"  # /etc/ufw is the sandbox's writable copy
            fake = sb.root / "fake-ufw"
            fake.write_text(FAKE_ERROR.format(log="/etc/ufw/fake-calls", text=text))
            fake.chmod(0o755)
            code, out, _ = run_root(sb, load + ops, ro_binds=[(fake, "/usr/bin/ufw")])
            b = batch(out, 2)
            calls = log.read_text().splitlines() if log.exists() else []
            r = b["results"][0]
            if name == "bare problem running":
                check(tag + "bare \"problem running\" is written, run again, and the batch goes on",
                      code == 0 and b["results"] == ["written", "written"] and len(calls) == 4, "%d %s %s" % (code, b["results"], calls))
            else:
                check(tag + "%s is a plain failure" % name, code == 1 and isinstance(r, dict) and r["code"] == 1
                      and name in r["msg"] and b["results"][1] == "none" and len(calls) == 1 and b["complete"],
                      "%d %s %s" % (code, b["results"], calls))


FAKE_SILENT = """#!/bin/sh
echo "WARN: something else"
exit 0
"""


def test_unrecognised_output():
    """Exit 0 without a success line is not success, for adds and deletes."""
    with Sandbox() as sb:
        fake = sb.root / "fake-ufw"
        fake.write_text(FAKE_SILENT)
        fake.chmod(0o755)
        for kind, op in (("add", ["rule", "allow", "41800/tcp"]), ("delete", ["delete", "allow", "41800/tcp"])):
            code, out, _ = run_root(sb, consts()["load_rules"] + [US.join(op)], ro_binds=[(fake, "/usr/bin/ufw")])
            r = batch(out, 1)["results"][0]
            check("sandbox: %s with exit 0 but no success line is a failure" % kind, code == 1 and isinstance(r, dict)
                  and r["code"] == 0 and r["msg"] == "WARN: something else", str(r))


def test_dump():
    with Sandbox() as sb:
        sb.run_many(ufw_cmds(["allow 41500/udp"]))
        code, out, _ = run_root(sb, consts()["load_rules"])
        b = batch(out, 1)
        d = b["dump"]
        check("sandbox: no-op batch dumps files", code == 0 and b["complete"] and b["results"] == ["none"]
              and d.get("conf") == sb.read("ufw.conf") and d.get("defaults") == sb.read("default-ufw")
              and d.get("v4") == sb.read("user.rules") and d.get("v6") == sb.read("user6.rules")
              and "41500" in d.get("v4", ""))
        check("sandbox: no-op batch prints no op lines", "@@op" not in out and "@@msg" not in out)


def test_enable_disable():
    with Sandbox() as sb:
        code, _, err = run_root(sb, consts()["enable_active"])
        on = sb.read("ufw.conf")
        code2, _, err2 = run_root(sb, consts()["disable"])
        off = sb.read("ufw.conf")
        check("sandbox: enable sets ENABLED=yes", code == 0 and "ENABLED=yes" in on, err)
        check("sandbox: disable sets ENABLED=no", code2 == 0 and "ENABLED=no" in off, err2)
    with Sandbox() as sb:
        argv = consts()["enable_inactive"]
        code, out, err = run_root(sb, argv)
        check("sandbox: ENABLE_AND_START enables (systemctl half is Task 10)",
              argv[1:3] == ["/bin/sh", "-c"] and "ENABLED=yes" in sb.read("ufw.conf"), "%d %s" % (code, err))


FAKE_UFW = """#!/bin/sh
echo "argc=$#"
for a in "$@"; do echo "arg=[$a]"; done
echo 'raw $(touch {canary}) `touch {canary}` ${{HOME}} \\n \\\\ @@end'
exit 3
"""


def test_script_mechanics(shell_name, shell):
    """A fake ufw shows exactly what the script passes and that output is never re-expanded."""
    with Sandbox() as sb:
        canary = sb.root / "canary"
        fake = sb.root / "fake-ufw"
        fake.write_text(FAKE_UFW.format(canary=canary))
        fake.chmod(0o755)
        conf = sb.root / "etc-ufw" / "ufw.conf"
        conf.write_text("ENABLED=no")  # no trailing newline
        args = ["allow", "41600/tcp", "comment", "a  b * ? [x] $(touch %s) `id` ;|&" % canary]
        argv = consts()["load_rules"] + [US.join(args), US.join(["allow", "41601"])]
        code, out, err = run_root(sb, argv, shell=shell, ro_binds=[(fake, "/usr/bin/ufw")])
        b = batch(out, 2)
        r1 = b["results"][0]
        want = "\n".join(["argc=5", "arg=[--force]"] + ["arg=[%s]" % a for a in args]
                         + ["raw $(touch %s) `touch %s` ${HOME} \\n \\\\ @@end" % (canary, canary)])
        tag = "sandbox: script (%s): " % shell_name
        check(tag + "op is split on \\31 only, no globbing", isinstance(r1, dict) and r1["msg"] == want,
              repr(r1))
        check(tag + "failure code passed through and op 2 skipped", isinstance(r1, dict) and r1["code"] == 3
              and b["results"][1] == "none")
        check(tag + "nothing was executed from data or output", not canary.exists())
        check(tag + "file without trailing newline is terminated", b["dump"].get("conf") == "ENABLED=no\n"
              and "ENABLED=no\n@@file defaults\n" in out, repr(out[:200]))
        check(tag + "dump complete", b["complete"] is True and code == 1, "%d %s" % (code, err))


def main():
    if not available():
        print("SKIP  bwrap or ufw missing")
        return 0
    real = pathlib.Path("/etc/ufw/user.rules")
    before = os.stat(real).st_mtime_ns if real.exists() else None

    test_add()
    test_comments()
    test_round_trips(True)
    test_round_trips(False)
    test_multi_tuple_app()
    test_mid_batch_failure()
    test_success_strings()
    test_stopped_state()
    test_live_update_errors()
    test_unrecognised_output()
    test_dump()
    test_enable_disable()
    shells = [("/bin/sh", None), ("bash --posix", ["bash", "--posix"])]
    if shutil.which("dash"):
        shells.append(("dash", ["dash"]))
    if shutil.which("zsh"):
        shells.append(("zsh --emulate sh", ["zsh", "--emulate", "sh"]))
    for name, shell in shells:
        test_script_mechanics(name, shell)

    after = os.stat(real).st_mtime_ns if real.exists() else None
    check("sandbox: real user.rules mtime unchanged", before == after)
    print("%s" % ("all passed" if _failures == 0 else "%d failed" % _failures))
    return 1 if _failures else 0


if __name__ == "__main__":
    sys.exit(main())
