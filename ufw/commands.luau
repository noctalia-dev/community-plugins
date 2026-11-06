--!nonstrict

-- Pure command building for the ufw plugin (no noctalia calls). Everything the plugin runs as
-- root is built here, from three fixed shell constants and argv tables:
--
-- * BATCH_SCRIPT runs as `pkexec /bin/sh -c BATCH_SCRIPT ufw-batch <op> <op> ...`. Each op is one
--   argv element: the ufw args after `ufw --force`, joined by the unit separator (\31). The
--   script splits an op with `set -f; IFS=<\31>; set -- $op` and runs `ufw --force "$@"`, so
--   request data is only ever positional args, never script text.
--   ufw writes its rules file before it touches the running firewall. With ufw stopped
--   (ENABLED=yes, chains unloaded: what Turn off leaves) that second step fails, exit 1, with
--   output ending in the bare "problem running" (the reload's flush of the missing chains), and
--   ufw gives up after the IPv4 file. Only then does the script run the op once more (that
--   writes the IPv6 file, or says Skipping / Could not delete when there is none), report it
--   `written` and go on. "problem running iptables" / "ip6tables" (a loaded firewall left
--   flushed) and "Could not update running firewall" stay plain failures. The service counts a
--   `written` op as saved only when ufw was not on before the Save and the dumped files show it
--   (commands.applied).
-- * ENABLE_AND_START, and the TERMINAL_COMMANDS handed to noctalia.runInTerminal.
--
-- Deletes are rebuilt from the parsed tuple. Only shapes whose round trip spec_sandbox.py
-- proves (the rebuilt delete removes exactly that rule, both copies, and nothing else) are in
-- REMOVABLE_SHAPES; deleteArgs returns nil for every other shape.

local rules = require("./rules.luau")

local commands = {}

local US = string.char(31)

local BATCH_SCRIPT = [=[
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LC_ALL=C
LANGUAGE=C
export PATH LC_ALL LANGUAGE
status=0
i=0
for op in "$@"; do
  i=$((i + 1))
  set -f
  IFS=$(printf '\037')
  set -- $op
  unset IFS
  if [ "$#" -eq 0 ]; then
    out='empty op'
    code=2
  else
    out=$(ufw --force "$@" 2>&1)
    code=$?
  fi
  ok=no
  if [ "$code" -eq 0 ]; then
    if [ "$1" = delete ] || [ "$2" = delete ]; then
      case $out in
        *"Rule deleted"*|*"Rules updated"*) ok=yes ;;
      esac
    else
      case $out in
        *"Rule added"*|*"Rules updated"*) ok=yes ;;
      esac
    fi
    case $out in
      *"Could not"*|*"Skipping"*) ok=no ;;
    esac
  else
    case $out in
      *"Could not delete"*|*"Skipping"*) ;;
      *"problem running")
        ufw --force "$@" >/dev/null 2>&1
        ok=written ;;
    esac
  fi
  if [ "$ok" = yes ]; then
    echo "@@op $i ok"
  else
    if [ "$ok" = written ]; then
      echo "@@op $i written $code"
    else
      echo "@@op $i fail $code"
    fi
    if [ -n "$out" ]; then
      sed 's/^/@@msg /' <<EOF
$out
EOF
    fi
    if [ "$ok" = no ]; then
      status=1
      break
    fi
  fi
done
dump() {
  echo "@@file $1"
  if [ -r "$2" ]; then
    cat "$2"
    [ -z "$(tail -c 1 "$2")" ] || echo
  fi
}
dump conf /etc/ufw/ufw.conf
dump defaults /etc/default/ufw
dump v4 /etc/ufw/user.rules
dump v6 /etc/ufw/user6.rules
echo "@@end"
exit "$status"
]=]

commands.BATCH_SCRIPT = BATCH_SCRIPT

local ENABLE_AND_START = "ufw --force enable && systemctl start ufw"

commands.ENABLE_AND_START = ENABLE_AND_START

commands.TERMINAL_COMMANDS = {
  enable = "sudo ufw --force enable",
  enable_and_start = "sudo sh -c 'ufw --force enable && systemctl start ufw'",
  start_service = "sudo systemctl start ufw",
  stop_service = "sudo systemctl stop ufw",
  disable_legacy = "sudo ufw disable",
  enable_at_boot = "sudo systemctl enable ufw",
}

commands.SYSTEMCTL_SHOW = { "systemctl", "show", "ufw", "--property=LoadState,ActiveState,UnitFileState" }

---------------------------------------------------------------------------
-- Validation

-- Linear (the one-pattern "^%s*(.-)%s*$" trim is quadratic on long input).
local function isSpace(byte)
  return byte == 32 or (byte >= 9 and byte <= 13)
end

local function trim(text)
  local first, last = 1, #text
  while first <= last and isSpace(string.byte(text, first)) do
    first = first + 1
  end
  while last >= first and isSpace(string.byte(text, last)) do
    last = last - 1
  end
  return string.sub(text, first, last)
end

-- Raw request input longer than this is refused before any other work.
local MAX_INPUT = 256

-- Whole-comment words ufw's parser rejects (it scans every argv for them), checked in the sandbox.
local COMMENT_WORDS = { ["in"] = true, ["out"] = true, ["log"] = true, ["log-all"] = true }

local PROTOS = { both = true, tcp = true, udp = true }

function commands.validateAdd(portText, proto, comment)
  if type(portText) ~= "string" or #portText > MAX_INPUT then
    return nil, "add.error_port"
  end
  if type(comment) == "string" and #comment > MAX_INPUT then
    return nil, "add.error_comment"
  end
  local port = trim(portText)
  if string.find(port, "/", 1, true) then
    return nil, "add.error_proto_in_port"
  end
  if not string.match(port, "^%d+$") then
    return nil, "add.error_port"
  end
  port = string.gsub(port, "^0+", "")
  if port == "" or #port > 5 then
    return nil, "add.error_port"
  end
  local number = tonumber(port)
  if number == nil or number < 1 or number > 65535 then
    return nil, "add.error_port"
  end
  if proto == nil then
    proto = "both"
  end
  if not PROTOS[proto] then
    return nil, "add.error_proto"
  end
  local text = nil
  if comment ~= nil then
    if type(comment) ~= "string" then
      return nil, "add.error_comment"
    end
    text = trim(comment)
    if text == "" then
      text = nil
    end
  end
  if text ~= nil then
    -- printable ASCII 0x20-0x7E, without ' " \ ; at most 64 characters
    if #text > 64 or string.find(text, "[^\32-\126]") or string.find(text, "['\"\\]") then
      return nil, "add.error_comment"
    end
    -- ufw's launcher takes any argv starting with --rootdir= / --datadir= as its own option
    if string.sub(text, 1, 1) == "-" then
      return nil, "add.error_comment"
    end
    if COMMENT_WORDS[string.lower(text)] then
      return nil, "add.error_comment"
    end
  end
  return { port = number, proto = proto, comment = text }, nil
end

---------------------------------------------------------------------------
-- ufw args (after `ufw --force`)

-- `ufw --force allow ...` is parsed as `ufw default allow` (ufw only inserts its implicit
-- "rule" when --force is absent), so adds spell out the documented optional `rule` keyword.
function commands.addArgs(op)
  local spec = string.format("%d", op.port)
  if op.proto == "tcp" or op.proto == "udp" then
    spec = spec .. "/" .. op.proto
  end
  local args = { "rule", "allow", spec }
  if op.comment ~= nil then
    args[#args + 1] = "comment"
    args[#args + 1] = op.comment
  end
  return args
end

local function portKind(port)
  if port == nil then
    return "-"
  end
  if string.find(port, ",", 1, true) then
    return "list"
  end
  if string.find(port, ":", 1, true) then
    return "range"
  end
  return "port"
end

-- The structural shape of a rule: everything that changes how its delete is spelled.
-- (The action word, the comment and the addresses themselves do not.)
function commands.shapeKey(rule)
  if type(rule) ~= "table" then
    return nil
  end
  local iface = "-"
  if rule.iface ~= nil then
    iface = "if"
    if string.find(rule.iface, ">", 1, true) then
      iface = "if2"
    end
  end
  local dst = portKind(rule.port)
  if rule.app ~= nil then
    dst = "app"
  end
  local parts = {
    rule.route and "route" or "rule",
    rule.direction or "?",
    iface,
    rule.log or "-",
    rule.proto == "any" and "any" or "proto",
    rule.from == "any" and "any" or "addr",
    portKind(rule.fromPort),
    rule.to == "any" and "any" or "addr",
    dst,
  }
  if rule.sapp ~= nil then
    parts[#parts + 1] = "sapp"
  end
  return table.concat(parts, " ")
end

-- Shapes whose rebuilt delete spec_sandbox.py round-trips, with IPv6 on and off.
-- route dir iface log proto from fromPort to dport
local REMOVABLE_SHAPES = {
  ["rule in - - proto any - any port"] = true,      -- allow 80/tcp, limit 22/tcp, reject 4445/udp
  ["rule in - - any any - any port"] = true,        -- deny 4444
  ["rule in - - proto addr - any port"] = true,     -- allow from 192.0.2.0/24 to any port 22 proto tcp
  ["rule in - - any addr - any -"] = true,          -- allow from 198.51.100.7
  ["rule in - - proto any - any range"] = true,     -- allow 60000:60010/tcp
  ["rule in - - proto any - any list"] = true,      -- allow proto tcp from any to any port 80,443
  ["rule in if - any any - any port"] = true,       -- allow in on eth9 to any port 43117
  ["rule out - - any any - any port"] = true,       -- allow out 43118
  ["rule in - - proto any - any app"] = true,       -- allow WWW, allow 'WWW Full'
  ["route in if2 - any any - any -"] = true,        -- route allow in on eth9 out on eth8
  ["rule in - log proto any - any port"] = true,    -- allow log 41001/tcp
  ["rule in if log-all any any - any port"] = true, -- allow in on eth9 log-all to any port 41002
  ["rule in - - proto addr port any port"] = true,  -- allow from 192.0.2.0/24 port 41005 to any port 41006 proto udp
  ["rule in - - proto any - addr port"] = true,     -- allow from any to 10.0.0.0/8 port 41007 proto tcp
  ["rule out if - any any - any port"] = true,      -- deny out on eth9 to any port 41008
  ["route in if - proto any - any port"] = true,    -- route allow in on eth9 to any port 41009 proto tcp
}

commands.REMOVABLE_SHAPES = REMOVABLE_SHAPES

function commands.isRemovableShape(rule)
  if type(rule) ~= "table" or rule.sapp ~= nil then
    return false
  end
  local key = commands.shapeKey(rule)
  if key == nil or not REMOVABLE_SHAPES[key] then
    return false
  end
  if not rule.v4 and not rule.v6 then
    return false
  end
  -- only the protocols the sandbox round-trips (not esp, ah, gre, igmp, ipv6)
  if rule.proto ~= "tcp" and rule.proto ~= "udp" and rule.proto ~= "any" then
    return false
  end
  -- a delete by app name removes every rule of that app tuple, so only a lone one is removable
  if rule.app ~= nil and rule.appTuples ~= 1 then
    return false
  end
  -- no field may be read by ufw as an option, split the op, or be empty
  local fields = { rule.action, rule.direction, rule.proto, rule.port, rule.from, rule.fromPort, rule.to,
    rule.app, rule.iface, rule.log }
  for i = 1, 10 do
    local value = fields[i]
    if value ~= nil then
      if type(value) ~= "string" or value == "" or string.sub(value, 1, 1) == "-"
        or string.find(value, US, 1, true) or string.find(value, "%c") then
        return false
      end
    end
  end
  return true
end

-- "any" for a rule with both copies; the family's own anywhere for a v4-only or v6-only rule,
-- so ufw deletes only the copy that exists.
local function address(value, rule)
  if value ~= "any" then
    return value
  end
  if rule.v4 and rule.v6 then
    return "any"
  end
  if rule.v6 then
    return "::/0"
  end
  return "0.0.0.0/0"
end

function commands.deleteArgs(rule)
  if not commands.isRemovableShape(rule) then
    return nil
  end
  local args = {}
  local function add(value)
    args[#args + 1] = value
  end
  if rule.route then
    add("route")
  end
  add("delete")
  add(rule.action)
  if rule.iface ~= nil then
    local i, o = string.match(rule.iface, "^(.-)>(.+)$")
    if i ~= nil then
      if i == "" then
        return nil
      end
      add("in")
      add("on")
      add(i)
      add("out")
      add("on")
      add(o)
    else
      add(rule.direction)
      add("on")
      add(rule.iface)
    end
  else
    add(rule.direction)
  end
  if rule.log ~= nil then
    add(rule.log)
  end
  if rule.proto ~= "any" and rule.app == nil then
    add("proto")
    add(rule.proto)
  end
  add("from")
  add(address(rule.from, rule))
  if rule.fromPort ~= nil then
    add("port")
    add(rule.fromPort)
  end
  add("to")
  add(address(rule.to, rule))
  if rule.app ~= nil then
    add("app")
    add(rule.app)
  elseif rule.port ~= nil then
    add("port")
    add(rule.port)
  end
  return args
end

---------------------------------------------------------------------------
-- Staging

local function copy(list)
  local out = {}
  for i, v in ipairs(list or {}) do
    out[i] = v
  end
  return out
end

-- A plain "allow <port>[/proto]" target: in, from anywhere to anywhere, no iface/app/route.
local function plainPortRule(rule)
  return rule.direction == "in" and not rule.route and rule.iface == nil and rule.app == nil
    and rule.sapp == nil and rule.fromPort == nil and rule.from == "any" and rule.to == "any"
    and rule.port ~= nil
end

local function protoOf(rule)
  if rule.proto == "any" then
    return "both"
  end
  return rule.proto
end

local function overlaps(protoA, protoB)
  return protoA == protoB or protoA == "both" or protoB == "both"
end

local function existsIn(rulesList, port, proto, exact)
  local text = tostring(port)
  for _, rule in ipairs(rulesList or {}) do
    if plainPortRule(rule) and rule.port == text then
      local p = protoOf(rule)
      if (exact and p == proto) or (not exact and overlaps(p, proto)) then
        return true
      end
    end
  end
  return false
end

local function findRule(rulesList, id)
  for _, rule in ipairs(rulesList or {}) do
    if rule.id == id then
      return rule
    end
  end
  return nil
end

function commands.stage(pending, rulesList, request, nextId)
  local out = copy(pending)
  if type(request) ~= "table" then
    return out, "error.unknown_action"
  end
  local action = request.action
  if action == "stage_add" then
    local port = request.port
    -- IPC callers may send the port as a JSON number
    if type(port) == "number" and port >= 0 and port < 1000000 and port == math.floor(port) then
      port = string.format("%d", port)
    end
    local op, err = commands.validateAdd(port, request.proto, request.comment)
    if op == nil then
      return out, err
    end
    if existsIn(rulesList, op.port, op.proto, false) then
      return out, "add.error_exists"
    end
    for _, other in ipairs(out) do
      if other.kind == "add" and other.port == op.port and overlaps(other.proto, op.proto) then
        return out, "add.error_exists"
      end
    end
    out[#out + 1] = { id = tostring(nextId), kind = "add", port = op.port, proto = op.proto, comment = op.comment }
    return out, nil
  elseif action == "stage_remove" then
    local rule = findRule(rulesList, request.rule)
    if rule == nil or not commands.isRemovableShape(rule) then
      return out, "error.not_removable"
    end
    for _, other in ipairs(out) do
      if other.kind == "remove" and other.ruleId == rule.id then
        return out, nil
      end
    end
    out[#out + 1] = { id = tostring(nextId), kind = "remove", ruleId = rule.id }
    return out, nil
  elseif action == "unstage" then
    -- staged ids are strings; IPC callers may send one as a JSON number
    local id = request.id
    if type(id) == "number" and id >= 0 and id < 1000000000 and id == math.floor(id) then
      id = string.format("%d", id)
    end
    local kept = {}
    for _, op in ipairs(out) do
      if op.id ~= id then
        kept[#kept + 1] = op
      end
    end
    return kept, nil
  elseif action == "discard" then
    return {}, nil
  end
  return out, "error.unknown_action"
end

-- Whether rulesList holds the rule a staged add writes: allow, no log, exactly that port and
-- protocol, with its IPv6 copy too when IPv6 is on.
local function addDone(op, rulesList, ipv6)
  local text = tostring(op.port)
  for _, rule in ipairs(rulesList or {}) do
    if rule.action == "allow" and rule.log == nil and plainPortRule(rule) and rule.port == text
      and protoOf(rule) == op.proto and rule.v4 == true and (rule.v6 == true or not ipv6) then
      return true
    end
  end
  return false
end

-- Drops removes whose rule is gone (or can no longer be removed) and adds that now exist
-- exactly: the same test as commands.applied (allow, port, protocol, both families when IPv6
-- is on). An add whose port has a deny rule, or only one family's copy, is still needed.
-- An op marked notLive (a Save wrote it to the files while ufw was on, but the running
-- firewall did not take it) is kept: the files showing it does not make it live.
function commands.reconcile(pending, rulesList, ipv6)
  local kept, dropped = {}, 0
  for _, op in ipairs(pending or {}) do
    local stale = false
    if op.notLive == true then
      stale = false
    elseif op.kind == "remove" then
      local rule = findRule(rulesList, op.ruleId)
      stale = rule == nil or not commands.isRemovableShape(rule)
    elseif op.kind == "add" then
      stale = addDone(op, rulesList, ipv6)
    end
    if stale then
      dropped = dropped + 1
    else
      kept[#kept + 1] = op
    end
  end
  return kept, dropped
end

-- Whether the rules list (parsed from a Save's dump) shows this staged op done: a remove's
-- rule is gone (both copies), an add's allow rule exists for exactly that port and protocol,
-- with its IPv6 copy too when IPv6 is on. before (the rules the Save started from, optional):
-- an add whose port and protocol already had a rule (a deny or limit ufw would turn into this
-- allow: "Rule updated", a failure when ufw is on) is not counted. A `written` batch result
-- counts as saved only when this is true.
function commands.applied(op, rulesList, ipv6, before)
  if type(op) ~= "table" then
    return false
  end
  if op.kind == "remove" then
    return findRule(rulesList, op.ruleId) == nil
  elseif op.kind == "add" then
    if before ~= nil and existsIn(before, op.port, op.proto, true) then
      return false
    end
    return addDone(op, rulesList, ipv6)
  end
  return false
end

---------------------------------------------------------------------------
-- Save / Load rules

local function encodeOp(args)
  for _, value in ipairs(args) do
    if type(value) ~= "string" or value == "" or string.find(value, US, 1, true) then
      return nil
    end
  end
  return table.concat(args, US)
end

-- Returns the argv, the Op ids in the order their results will come back (removes first,
-- then adds), and the ids of ops left out of the batch: a remove whose rule is missing or
-- unremovable, or an add that fails re-validation. Dropped ops were not saved.
function commands.saveArgv(pending, rulesById)
  local argv = { "pkexec", "/bin/sh", "-c", BATCH_SCRIPT, "ufw-batch" }
  local order, dropped = {}, {}
  local function push(op, args)
    local encoded = args and encodeOp(args)
    if encoded ~= nil then
      argv[#argv + 1] = encoded
      order[#order + 1] = op.id
    else
      dropped[#dropped + 1] = op.id
    end
  end
  for _, op in ipairs(pending or {}) do
    if op.kind == "remove" then
      local rule = rulesById and rulesById[op.ruleId]
      push(op, rule and commands.deleteArgs(rule))
    end
  end
  for _, op in ipairs(pending or {}) do
    if op.kind == "add" then
      local valid = nil
      if type(op.port) == "number" and op.port >= 1 and op.port <= 65535 and op.port == math.floor(op.port) then
        valid = commands.validateAdd(string.format("%d", op.port), op.proto, op.comment)
      end
      push(op, valid and commands.addArgs(valid))
    end
  end
  return argv, order, dropped
end

function commands.parseBatch(stdout)
  local results = {}
  local last = nil
  local lastLine = nil
  local inFiles = false -- op results only come before the first @@file; file lines are data
  for line in string.gmatch(stdout or "", "[^\n]+") do
    lastLine = line
    if string.sub(line, 1, 7) == "@@file " then
      inFiles = true
    end
    local i, word, code = nil, nil, nil
    if not inFiles then
      i, word, code = string.match(line, "^@@op (%d+) (%a+)%s*(%-?%d*)$")
    end
    if inFiles then
      last = nil
    elseif i ~= nil then
      local index = tonumber(i)
      if word == "ok" then
        results[index] = { ok = true }
        last = nil
      elseif word == "written" then
        -- in ufw's rules file, not in the running firewall: only the dump can confirm it
        last = { ok = false, written = true, code = tonumber(code) }
        results[index] = last
      else
        last = { ok = false, code = tonumber(code) }
        results[index] = last
      end
    elseif string.sub(line, 1, 6) == "@@msg " or line == "@@msg" then
      if last ~= nil then
        local text = string.sub(line, 7)
        if last.msg == nil then
          last.msg = text
        else
          last.msg = last.msg .. "\n" .. text
        end
      end
    end
  end
  return { results = results, dump = rules.parseDump(stdout), complete = lastLine == "@@end" }
end

---------------------------------------------------------------------------
-- Root actions

-- How Turn on is done, one choice for argv and terminalKey alike:
-- * "start_service": ufw.conf already says ENABLED=yes and the unit is stopped or failed, so
--   only the unit needs starting (restarting, when failed);
-- * "enable": ENABLED=no with the unit already up, or no systemctl: the plain enable;
-- * "enable_and_start": ENABLED=no (or unknown) and the unit isn't up: enable alone would load
--   the rules but leave the unit inactive (amber), so it is enable plus start, in one process.
local function enableChoice(snap)
  local unit = snap.unit or {}
  if snap.enabled == true and snap.hasSystemctl == true
    and (unit.active == "inactive" or unit.active == "failed") then
    return "start_service"
  end
  if not snap.hasSystemctl or unit.active == "active" then
    return "enable"
  end
  return "enable_and_start"
end

-- Turning off only stops the unit: `ufw disable` would write ENABLED=no and keep the firewall
-- off after a reboot, and nothing here ever disables the unit at boot.
function commands.argv(action, snap)
  snap = snap or {}
  local unit = snap.unit or {}
  if action == "enable" then
    local choice = enableChoice(snap)
    if choice == "start_service" then
      return commands.argv("start_service", snap)
    elseif choice == "enable" then
      return { "pkexec", "ufw", "--force", "enable" }
    end
    return { "pkexec", "/bin/sh", "-c", ENABLE_AND_START }
  elseif action == "disable" then
    if snap.hasSystemctl then
      return { "pkexec", "systemctl", "stop", "ufw" }
    end
    return { "pkexec", "ufw", "disable" }
  elseif action == "start_service" then
    if unit.active == "failed" then
      return { "pkexec", "systemctl", "restart", "ufw" }
    end
    return { "pkexec", "systemctl", "start", "ufw" }
  elseif action == "enable_at_boot" then
    return { "pkexec", "systemctl", "enable", "ufw" }
  elseif action == "load_rules" then
    return { "pkexec", "/bin/sh", "-c", BATCH_SCRIPT, "ufw-batch" }
  elseif action == "enable_polkit_agent" then
    return { "noctalia", "msg", "config-set", "shell.polkit_agent", "true" }
  end
  return nil
end

-- The TERMINAL_COMMANDS key for a root action name (the same choice as argv), or nil when the
-- action has no terminal command. Only action names resolve: constant names do not.
function commands.terminalKey(action, snap)
  snap = snap or {}
  if action == "enable" then
    return enableChoice(snap)
  elseif action == "disable" then
    if snap.hasSystemctl then
      return "stop_service"
    end
    return "disable_legacy"
  elseif action == "start_service" or action == "enable_at_boot" then
    return action
  end
  return nil
end

-- Mullvad's classification: timeout first; then 127 or stderr naming the authentication agent
-- (nothing could show a password prompt); then 126 (the prompt was dismissed or not authorized).
function commands.classifyPkexec(result)
  result = result or {}
  if result.timedOut then
    return "timeout"
  end
  if result.exitCode == 0 then
    return "ok"
  end
  local stderr = string.lower(result.stderr or "")
  if result.exitCode == 127 or string.find(stderr, "authentication agent", 1, true) ~= nil then
    return "no_agent"
  end
  if result.exitCode == 126 then
    return "cancelled"
  end
  return "failed"
end

-- missing: systemd has no ufw unit (LoadState=not-found; `systemctl show` still exits 0 and
-- says ActiveState=inactive), so the status falls back to ENABLED alone.
function commands.parseSystemctlShow(stdout)
  local active, fileState, missing = nil, nil, false
  for line in string.gmatch(stdout or "", "[^\n]+") do
    local key, value = string.match(line, "^(%w+)=(.*)$")
    if key == "LoadState" then
      missing = value == "not-found"
    elseif key == "ActiveState" and value ~= "" then
      active = value
    elseif key == "UnitFileState" and value ~= "" then
      fileState = value
    end
  end
  local bootEnabled = nil
  if fileState ~= nil then
    bootEnabled = fileState == "enabled"
  end
  return { active = active, bootEnabled = bootEnabled, missing = missing }
end

return commands
