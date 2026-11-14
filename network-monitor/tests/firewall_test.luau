--!nonstrict

local firewall = require("../firewall.luau")

local CONF = "ENABLED=yes\nLOGLEVEL=low\n"
local DEFAULTS = 'IPV6=yes\nDEFAULT_INPUT_POLICY="DROP"\nDEFAULT_OUTPUT_POLICY="ACCEPT"\n'

local V4 = [[
*filter
### RULES ###

### tuple ### allow any 3000 0.0.0.0/0 any 0.0.0.0/0 in
-A ufw-user-input -p tcp --dport 3000 -j ACCEPT
### tuple ### allow tcp 47984,47989,48010 0.0.0.0/0 any 0.0.0.0/0 in
### tuple ### allow tcp 6000:6010 0.0.0.0/0 any 0.0.0.0/0 in comment=6465616d6f
### tuple ### deny tcp 7000 0.0.0.0/0 any 10.0.0.5 in
### tuple ### allow tcp 7000 0.0.0.0/0 any 0.0.0.0/0 in
### tuple ### allow tcp 7100 0.0.0.0/0 any 0.0.0.0/0 in_tailscale0
### tuple ### limit tcp 22 0.0.0.0/0 any 0.0.0.0/0 OpenSSH - in
### tuple ### deny tcp 7200 0.0.0.0/0 any 0.0.0.0/0 in
### tuple ### allow tcp 7200 0.0.0.0/0 any 0.0.0.0/0 in
### tuple ### allow tcp 7300 192.168.1.10 any 0.0.0.0/0 in
### tuple ### route:allow tcp 7400 0.0.0.0/0 any 0.0.0.0/0 in_eth0!out_wg0
### tuple ### allow tcp 7500 0.0.0.0/0 any 0.0.0.0/0 out

### END RULES ###
]]

local V6 = [[
### RULES ###
### tuple ### allow any 3000 ::/0 any ::/0 in
### tuple ### allow tcp 8443 ::/0 any ::/0 in
### END RULES ###
]]

local function reader(files)
  return function(path)
    return files[path]
  end
end

local function system(overrides)
  local files = {
    ["/etc/ufw/ufw.conf"] = CONF,
    ["/etc/default/ufw"] = DEFAULTS,
    ["/etc/ufw/user.rules"] = V4,
    ["/etc/ufw/user6.rules"] = V6,
  }
  for k, v in overrides or {} do
    files[k] = if v == false then nil else v
  end
  return firewall.load(reader(files))
end

local function tcp(port, addresses)
  local localOnly = true
  for _, a in addresses do
    localOnly = localOnly and (string.sub(a, 1, 4) == "127." or a == "::1")
  end
  return { port = port, proto = "tcp", addresses = addresses, localOnly = localOnly }
end

local function udp(port, addresses)
  local l = tcp(port, addresses)
  l.proto = "udp"
  return l
end

local base = system()
-- UFW appends new rules, so a host-wide allow lands after the port rules.
local hostAllowed = system({ ["/etc/ufw/user.rules"] = V4 .. "### tuple ### allow any any 0.0.0.0/0 any 192.168.1.33 in\n" })

local cases = {
  { name = "loopback is local", listener = tcp(3245, { "127.0.0.1" }), ruleset = base, expected = "local" },
  { name = "no rule, DROP policy", listener = tcp(8000, { "0.0.0.0" }), ruleset = base, expected = "firewalled" },
  { name = "dual-stack no rule", listener = tcp(9100, { "*" }), ruleset = base, expected = "firewalled" },
  { name = "allow any proto", listener = tcp(3000, { "0.0.0.0", "::" }), ruleset = base, expected = "exposed" },
  { name = "multiport list", listener = tcp(47989, { "0.0.0.0" }), ruleset = base, expected = "exposed" },
  { name = "port range with comment", listener = tcp(6005, { "0.0.0.0" }), ruleset = base, expected = "exposed" },
  { name = "allow from one host", listener = tcp(8000, { "0.0.0.0" }), ruleset = hostAllowed, expected = "limited" },
  { name = "host allow before port allow", listener = tcp(3000, { "0.0.0.0" }), ruleset = hostAllowed, expected = "exposed" },
  { name = "narrow deny, broad allow", listener = tcp(7000, { "0.0.0.0" }), ruleset = base, expected = "exposed" },
  { name = "interface-only allow", listener = tcp(7100, { "0.0.0.0" }), ruleset = base, expected = "limited" },
  { name = "limit counts as allow", listener = tcp(22, { "0.0.0.0" }), ruleset = base, expected = "exposed" },
  { name = "first match wins", listener = tcp(7200, { "0.0.0.0" }), ruleset = base, expected = "firewalled" },
  { name = "route rule ignored", listener = tcp(7400, { "0.0.0.0" }), ruleset = base, expected = "firewalled" },
  { name = "outbound rule ignored", listener = tcp(7500, { "0.0.0.0" }), ruleset = base, expected = "firewalled" },
  { name = "allow to other address", listener = tcp(7300, { "10.0.0.2" }), ruleset = base, expected = "firewalled" },
  { name = "allow to bind address", listener = tcp(7300, { "192.168.1.10" }), ruleset = base, expected = "exposed" },
  { name = "allow to one address of wildcard", listener = tcp(7300, { "0.0.0.0" }), ruleset = base, expected = "limited" },
  { name = "v6-only rule, v4 bind", listener = tcp(8443, { "0.0.0.0" }), ruleset = base, expected = "firewalled" },
  { name = "v6-only rule, v6 bind", listener = tcp(8443, { "::" }), ruleset = base, expected = "exposed" },
  { name = "v6-only rule, dual-stack", listener = tcp(8443, { "*" }), ruleset = base, expected = "exposed" },
  { name = "builtin mDNS allow", listener = udp(5353, { "0.0.0.0" }), ruleset = base, expected = "limited" },
  { name = "tcp rule skips udp", listener = udp(47989, { "0.0.0.0" }), ruleset = base, expected = "firewalled" },
  { name = "tailscale v4 bind", listener = tcp(37893, { "100.95.51.113" }), ruleset = base, expected = "tailnet" },
  { name = "tailscale v6 bind", listener = tcp(50693, { "fd7a:115c:a1e0::c701:3372" }), ruleset = base, expected = "tailnet" },
  { name = "tailscale ignores ufw allow", listener = tcp(3000, { "100.64.0.1" }), ruleset = base, expected = "tailnet" },
  { name = "outside tailscale range", listener = tcp(8000, { "100.128.0.1" }), ruleset = base, expected = "firewalled" },
  { name = "ACCEPT policy", listener = tcp(8000, { "0.0.0.0" }), ruleset = system({ ["/etc/default/ufw"] = 'DEFAULT_INPUT_POLICY="ACCEPT"' }), expected = "exposed" },
  { name = "ufw disabled", listener = tcp(8000, { "0.0.0.0" }), ruleset = system({ ["/etc/ufw/ufw.conf"] = "ENABLED=no\n" }), expected = "unknown" },
  { name = "ufw not installed", listener = tcp(8000, { "0.0.0.0" }), ruleset = system({ ["/etc/ufw/ufw.conf"] = false }), expected = "unknown" },
  { name = "rules unreadable", listener = tcp(8000, { "0.0.0.0" }), ruleset = system({ ["/etc/ufw/user.rules"] = false }), expected = "unknown" },
  { name = "ipv6 unmanaged", listener = tcp(8000, { "::" }), ruleset = system({ ["/etc/default/ufw"] = "IPV6=no\n", ["/etc/ufw/user6.rules"] = false }), expected = "exposed" },
  { name = "ipv6 unmanaged, v4 bind", listener = tcp(8000, { "0.0.0.0" }), ruleset = system({ ["/etc/default/ufw"] = "IPV6=no\n", ["/etc/ufw/user6.rules"] = false, ["/etc/ufw/user.rules"] = "### RULES ###\n" }), expected = "firewalled" },
}

return function(report)
  local failed = 0
  for _, case in cases do
    local actual = firewall.classify(case.listener, case.ruleset)
    if actual == case.expected then
      report(`ok - firewall: {case.name}`)
    else
      failed += 1
      report(`not ok - firewall: {case.name}: expected {case.expected}, got {actual}`)
    end
  end
  if failed > 0 then
    error(`{failed} firewall cases failed`)
  end
end
