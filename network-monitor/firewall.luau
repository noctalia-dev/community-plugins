--!nonstrict

-- Reads UFW's saved configuration to decide whether a listener is actually reachable.
-- The files are world-readable on most distros, so this needs no root; `ufw status` and
-- `nft list ruleset` both do. Only UFW is understood: other firewalls report as unknown.

-- "unknown" means UFW is off or unreadable, so another firewall may or may not be in play.
export type Exposure = "local" | "unknown" | "firewalled" | "tailnet" | "limited" | "exposed"

export type Rule = {
  action: "allow" | "deny",
  proto: string, -- "any", "tcp", "udp", ...
  ports: { { number } }?, -- inclusive {lo, hi} ranges; nil means any port
  dst: string?, -- nil means any destination
  partial: boolean, -- only matches some traffic (source, source port or interface restricted)
}

export type Ruleset = {
  enabled: boolean,
  policy: string, -- DEFAULT_INPUT_POLICY: "DROP", "REJECT" or "ACCEPT"
  ipv6: boolean, -- false when UFW leaves ip6tables alone
  v4: { Rule },
  v6: { Rule },
}

local M = {}

local PATHS = {
  conf = "/etc/ufw/ufw.conf",
  defaults = "/etc/default/ufw",
  v4 = "/etc/ufw/user.rules",
  v6 = "/etc/ufw/user6.rules",
}

local RANK = { ["local"] = 0, unknown = 0, firewalled = 1, tailnet = 2, limited = 3, exposed = 4 }

-- Allows that UFW's stock before.rules / before6.rules add ahead of user rules. They only
-- admit specific sources or multicast destinations, so they make a port limited, never exposed.
local function builtin(port: number): Rule
  return { action = "allow", proto = "udp", ports = { { port, port } }, partial = true }
end
local BUILTIN_V4 = { builtin(68), builtin(5353), builtin(1900) } -- DHCP client, mDNS, UPnP
local BUILTIN_V6 = { builtin(546), builtin(5353), builtin(1900) }

local function isAnywhere(address: string): boolean
  return address == "0.0.0.0/0" or address == "::/0" or address == "any"
end

local function isWildcard(address: string): boolean
  return address == "0.0.0.0" or address == "::" or address == "*"
end

local function isLoopback(address: string): boolean
  return string.sub(address, 1, 4) == "127." or address == "::1"
end

-- Tailscale hands out addresses from these ranges and, in its default netfilter mode, accepts
-- everything arriving on tailscale0 before UFW's chains run. A port bound to one is open to
-- tailnet peers whatever UFW says, and to nobody else.
local function isTailnet(address: string): boolean
  local second = tonumber(string.match(address, "^100%.(%d+)%.%d+%.%d+$"))
  if second ~= nil then
    return second >= 64 and second <= 127
  end
  return string.sub(string.lower(address), 1, 15) == "fd7a:115c:a1e0:"
end

local function parsePorts(text: string): { { number } }?
  if text == "any" then
    return nil
  end
  local ranges = {}
  for _, entry in string.split(text, ",") do
    local lo, hi = string.match(entry, "^(%d+):(%d+)$")
    if lo then
      table.insert(ranges, { tonumber(lo), tonumber(hi) })
    elseif tonumber(entry) then
      table.insert(ranges, { tonumber(entry), tonumber(entry) })
    end
  end
  return ranges
end

-- `### tuple ### <action> <proto> <dport> <dst> <sport> <src> [<dapp> <sapp>] <dir>[_<iface>] [comment=<hex>]`
-- is the machine-readable line UFW writes above every rule it manages.
function M.parseRules(text: string): { Rule }
  local rules = {}
  for line in string.gmatch(text or "", "[^\n]+") do
    local tuple = string.match(line, "^### tuple ###%s*(.-)%s*$")
    if tuple == nil then
      continue
    end
    local tokens = {}
    for token in string.gmatch(tuple, "%S+") do
      if string.sub(token, 1, 8) ~= "comment=" then
        table.insert(tokens, token)
      end
    end
    if #tokens < 6 then
      continue
    end
    -- Route rules govern forwarded traffic, not connections to this host.
    if string.find(tokens[1], ":", 1, true) then
      continue
    end
    local direction = if #tokens >= 7 then tokens[#tokens] else "in"
    local dir, iface = string.match(direction, "^(%a+)_?(.*)$")
    if dir ~= "in" then
      continue
    end

    -- allow, allow_log, allow_log-all, limit, deny, reject...
    local verb = string.match(tokens[1], "^(%a+)")
    local action = if verb == "allow" or verb == "limit" then "allow" else "deny"
    table.insert(rules, {
      action = action,
      proto = tokens[2],
      ports = parsePorts(tokens[3]),
      dst = if isAnywhere(tokens[4]) then nil else tokens[4],
      partial = tokens[5] ~= "any" or not isAnywhere(tokens[6]) or (iface ~= nil and iface ~= ""),
    })
  end
  return rules
end

local function setting(text: string?, name: string): string?
  if text == nil then
    return nil
  end
  for line in string.gmatch(text, "[^\n]+") do
    local value = string.match(line, `^%s*{name}%s*=%s*"?([^"%s]*)"?`)
    if value ~= nil then
      return value
    end
  end
  return nil
end

-- `read` returns a file's text or nil. Returns nil when UFW isn't installed or its rules
-- can't be read, since then nothing can be said about reachability.
function M.load(read: (string) -> string?): Ruleset?
  local conf = read(PATHS.conf)
  if conf == nil or conf == "" then
    return nil
  end
  local enabled = string.lower(setting(conf, "ENABLED") or "no") == "yes"
  if not enabled then
    return { enabled = false, policy = "ACCEPT", ipv6 = false, v4 = {}, v6 = {} }
  end

  local defaults = read(PATHS.defaults)
  local v4 = read(PATHS.v4)
  if v4 == nil or v4 == "" then
    return nil
  end
  local ipv6 = string.lower(setting(defaults, "IPV6") or "yes") == "yes"
  local v6 = if ipv6 then read(PATHS.v6) else ""
  if ipv6 and (v6 == nil or v6 == "") then
    return nil
  end

  local ruleset = {
    enabled = true,
    policy = string.upper(setting(defaults, "DEFAULT_INPUT_POLICY") or "DROP"),
    ipv6 = ipv6,
    v4 = table.clone(BUILTIN_V4),
    v6 = table.clone(BUILTIN_V6),
  }
  for _, rule in M.parseRules(v4) do
    table.insert(ruleset.v4, rule)
  end
  for _, rule in M.parseRules(v6) do
    table.insert(ruleset.v6, rule)
  end
  return ruleset
end

local function matchesPort(rule: Rule, proto: string, port: number): boolean
  if rule.proto ~= "any" and rule.proto ~= proto then
    return false
  end
  if rule.ports == nil then
    return true
  end
  for _, range in rule.ports do
    if port >= range[1] and port <= range[2] then
      return true
    end
  end
  return false
end

-- How much of the traffic to `address` a rule's destination covers.
local function destinationScope(dst: string?, address: string): "none" | "partial" | "full"
  if dst == nil then
    return "full"
  end
  if isWildcard(address) then
    return "partial"
  end
  local host = string.gsub(dst, "/%d+$", "")
  if host == address and (host == dst or string.match(dst, "/32$") or string.match(dst, "/128$")) then
    return "full"
  end
  -- A wider subnet may or may not contain the bind address; assume it can.
  return if string.find(dst, "/", 1, true) then "partial" else "none"
end

-- UFW's user chain is first-match: a rule matching all remaining traffic settles it, while
-- narrower allows only open the port to some peers.
local function evaluate(rules: { Rule }, policy: string, proto: string, port: number, address: string): Exposure
  local someAllowed = false
  for _, rule in rules do
    if not matchesPort(rule, proto, port) then
      continue
    end
    local scope = destinationScope(rule.dst, address)
    if scope == "none" then
      continue
    end
    if rule.partial or scope == "partial" then
      someAllowed = someAllowed or rule.action == "allow"
    elseif rule.action == "allow" then
      return "exposed"
    else
      return if someAllowed then "limited" else "firewalled"
    end
  end
  if policy == "ACCEPT" then
    return "exposed"
  end
  return if someAllowed then "limited" else "firewalled"
end

local function worse(a: Exposure, b: Exposure): Exposure
  return if RANK[b] > RANK[a] then b else a
end

-- The most reachable of a listener's bind addresses decides its label.
function M.classify(listener, ruleset: Ruleset?): Exposure
  if listener.localOnly then
    return "local"
  end
  if ruleset == nil or not ruleset.enabled then
    return "unknown"
  end
  local result: Exposure = "local"
  for _, address in listener.addresses do
    if isLoopback(address) then
      continue
    end
    if isTailnet(address) then
      result = worse(result, "tailnet")
      continue
    end
    local v6 = address == "*" or string.find(address, ":", 1, true) ~= nil
    local v4 = address == "*" or not v6
    if v4 then
      result = worse(result, evaluate(ruleset.v4, ruleset.policy, listener.proto, listener.port, address))
    end
    if v6 then
      local exposure = if ruleset.ipv6
        then evaluate(ruleset.v6, ruleset.policy, listener.proto, listener.port, address)
        else "exposed"
      result = worse(result, exposure)
    end
  end
  return result
end

-- Reads through `noctalia.readFile`, treating errors and missing files alike.
function M.loadSystem(): Ruleset?
  return M.load(function(path)
    local ok, text = pcall(noctalia.readFile, path)
    return if ok and type(text) == "string" then text else nil
  end)
end

return M
