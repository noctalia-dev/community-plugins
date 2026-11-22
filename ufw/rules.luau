--!nonstrict

-- Pure parsers for UFW's on-disk state (no noctalia calls; must not require commands.luau).
--
-- user.rules / user6.rules hold one machine-readable line above every rule UFW manages
-- (layout captured from the sandbox fixtures and ufw/backend_iptables.py):
--
--   ### tuple ### <action> <proto> <dport> <dst> <sport> <src> [<dapp> <sapp>] <dir>[_<iface>] [comment=<hex>]
--
-- * 6 fields (+dir = 7) for plain rules; 8 (+dir = 9) when an app profile is involved.
--   Length 6 or 8 is the old format without a direction (means "in"). Anything outside 6..9 is skipped.
-- * action: allow | limit | deny | reject, with an optional "_log" / "_log-all" suffix (Rule.log).
--   Route rules are "route:<action>". Rules that match anything, e.g. `allow 80`, have proto "any".
-- * dport / sport: "80", "60000:60010", "80,443" or "any". dst / src: an address, a CIDR, "0.0.0.0/0" (v4
--   anywhere) or "::/0" (v6 anywhere). Note `allow from X` puts X in src and `allow ... to Y` in dst.
-- * dapp / sapp: "-" when unused, else the profile name with spaces as %20. For `allow WWW` the dport is
--   still resolved ("80", proto "tcp") and the dapp is "WWW".
-- * dir: "in" or "out", then "_<iface>" for one interface (`allow in on eth9` -> "in_eth9"), or
--   "in_<iface>!out_<iface>" when a route rule names both (`route allow in on eth9 out on eth8`).
-- * comment=<hex> is always last: the comment text as hex bytes.
-- * The file ends the rule list with a "### END RULES ###" line; its absence means truncation.
--
-- Rule.iface for a two-interface route rule is "<in>><out>" (e.g. "eth9>eth8").
-- Rule.app is the dapp (destination app profile), Rule.sapp the source app profile.

local M = {}

local function anyOf(address)
  if address == nil or address == "" or address == "0.0.0.0/0" or address == "::/0" then
    return "any"
  end
  return address
end

-- action|direction|proto|port|from|fromPort|to|app|iface|route|sapp; the comment and the log type
-- are not part of the id (ufw never keeps two rules that differ only in those). route is "1" or "0".
-- v4 and v6 copies of one rule therefore share an id.
function M.ruleId(fields)
  return table.concat({
    fields.action or "",
    fields.direction or "",
    fields.proto or "",
    fields.port or "",
    anyOf(fields.from),
    fields.fromPort or "",
    anyOf(fields.to),
    fields.app or "",
    fields.iface or "",
    fields.route and "1" or "0",
    fields.sapp or "",
  }, "|")
end

local function setting(text, name)
  for line in string.gmatch(text or "", "[^\n]+") do
    local value = string.match(line, "^%s*" .. name .. "%s*=%s*\"?([^\"%s]*)\"?")
    if value ~= nil then
      return value
    end
  end
  return nil
end

function M.parseConf(text)
  local enabled = setting(text, "ENABLED")
  local result = { loglevel = setting(text, "LOGLEVEL") }
  if enabled ~= nil then
    result.enabled = string.lower(enabled) == "yes"
  end
  return result
end

function M.parseDefaults(text)
  local ipv6 = setting(text, "IPV6")
  return {
    input = setting(text, "DEFAULT_INPUT_POLICY"),
    ipv6 = not (ipv6 ~= nil and string.lower(ipv6) == "no"),
  }
end

local function unhex(hex)
  return (string.gsub(hex, "%x%x", function(pair)
    return string.char(tonumber(pair, 16))
  end))
end

local function noAny(value)
  if value == "any" then
    return nil
  end
  return value
end

local function parseTuple(line)
  local body = string.match(line, "^### tuple ###%s*(.-)%s*$")
  if body == nil then
    return nil
  end
  local comment = nil
  local hex = string.match(body, "%scomment=(%S*)$")
  if hex ~= nil then
    comment = unhex(hex)
    body = string.match(body, "^(.-)%s+comment=")
  end
  local tokens = {}
  for token in string.gmatch(body, "%S+") do
    tokens[#tokens + 1] = token
  end
  local n = #tokens
  if n < 6 or n > 9 then
    return nil
  end
  local direction, iface = "in", nil
  if n == 7 or n == 9 then
    local last = tokens[n]
    direction = string.match(last, "^[^_]+")
    local rest = string.match(last, "^[^_]+_(.+)$")
    if rest ~= nil then
      local i, o = string.match(rest, "^(.-)!out_(.+)$")
      if i ~= nil then
        iface = i .. ">" .. o
      elseif string.sub(last, 1, 3) == "in_" or string.sub(last, 1, 4) == "out_" then
        iface = rest
      else
        return nil
      end
    end
  end
  if direction ~= "in" and direction ~= "out" then
    return nil
  end
  local route = false
  local action = tokens[1]
  if string.find(action, ":", 1, true) then
    route = true
    action = string.match(action, ":(.*)$")
  end
  local log = string.match(action, "^[a-z]+_(log.*)$")
  if log ~= nil and log ~= "log" and log ~= "log-all" then
    return nil
  end
  action = string.match(action, "^[a-z]+")
  if action ~= "allow" and action ~= "limit" and action ~= "deny" and action ~= "reject" then
    return nil
  end
  local app, sapp = nil, nil
  if n >= 8 and tokens[7] ~= "-" then
    app = (string.gsub(tokens[7], "%%20", " "))
  end
  if n >= 8 and tokens[8] ~= "-" then
    sapp = (string.gsub(tokens[8], "%%20", " "))
  end
  local rule = {
    action = action,
    direction = direction,
    proto = tokens[2],
    port = noAny(tokens[3]),
    app = app,
    sapp = sapp,
    log = log,
    from = anyOf(tokens[6]),
    fromPort = noAny(tokens[5]),
    to = anyOf(tokens[4]),
    iface = iface,
    route = route,
    comment = comment,
    v4 = false,
    v6 = false,
  }
  rule.id = M.ruleId(rule)
  return rule
end

-- Returns the Rules found in one file, plus whether the file ends with its END RULES marker.
local function parseFile(text, byId, order, flag)
  local complete = false
  for line in string.gmatch(text or "", "[^\n]+") do
    if string.find(line, "### END RULES ###", 1, true) == 1 then
      complete = true
    else
      local rule = parseTuple(line)
      if rule ~= nil then
        local existing = byId[rule.id]
        if existing == nil then
          byId[rule.id] = rule
          order[#order + 1] = rule
          existing = rule
        end
        existing[flag] = true
        if existing.comment == nil then
          existing.comment = rule.comment
        end
      end
    end
  end
  return complete
end

-- ufw's "app tuple" (backend get_app_tuple): one `ufw delete ... app X` removes every rule
-- sharing it, e.g. both tuples a "5222/tcp|5269/tcp" profile writes, and also a route rule for
-- the same app (the tuple has no route flag). The action and log type are left out too, which
-- only ever counts more rules than ufw would delete.
local function appTupleKey(rule)
  return table.concat({ rule.app or "", rule.to, rule.sapp or "", rule.fromPort or "", rule.from,
    rule.direction, rule.iface or "" }, "|")
end

function M.parseRules(v4text, v6text, ipv6)
  local byId, order = {}, {}
  local complete = parseFile(v4text, byId, order, "v4")
  if ipv6 then
    -- with IPv6 on, rules are only complete once user6.rules was parsed too: otherwise every
    -- both-copies rule would look v4-only (and its delete would leave the v6 copy)
    if v6text == nil or not parseFile(v6text, byId, order, "v6") then
      complete = false
    end
  end
  -- Rule.appTuples: how many listed rules share this app rule's app tuple (1 = only itself)
  local counts = {}
  for _, rule in ipairs(order) do
    if rule.app ~= nil then
      local key = appTupleKey(rule)
      counts[key] = (counts[key] or 0) + 1
    end
  end
  for _, rule in ipairs(order) do
    if rule.app ~= nil then
      rule.appTuples = counts[appTupleKey(rule)]
    end
  end
  return order, complete
end

local SECTIONS = { conf = true, defaults = true, v4 = true, v6 = true }

-- Splits the batch script's output into its `@@file <name>` sections (see Task 4's BATCH_SCRIPT).
function M.parseDump(stdout)
  local result = {}
  local current = nil
  local lines = nil
  local function flush()
    if current ~= nil then
      result[current] = table.concat(lines)
    end
    current, lines = nil, nil
  end
  for line in string.gmatch(stdout or "", "[^\n]*\n?") do
    if line ~= "" then
      local bare = (string.gsub(line, "\n$", ""))
      if string.sub(bare, 1, 2) == "@@" then
        local name = string.match(bare, "^@@file (%S+)$")
        if bare == "@@end" then
          flush()
        elseif name ~= nil and SECTIONS[name] then
          flush()
          current, lines = name, {}
        elseif name ~= nil then
          flush()
        elseif current ~= nil then
          -- another marker inside a section ends it
          flush()
        end
      elseif current ~= nil then
        lines[#lines + 1] = bare .. "\n"
      end
    end
  end
  flush()
  return result
end

return M
