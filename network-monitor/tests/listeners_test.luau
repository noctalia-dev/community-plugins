--!nonstrict

local listeners = require("../listeners.luau")

local sample = [[
tcp LISTEN 0 511 0.0.0.0:3773 0.0.0.0:* users:(("t3code",pid=4104,fd=3))
tcp LISTEN 0 4096 127.0.0.53%lo:53 0.0.0.0:*
tcp LISTEN 0 4096 [::]:5355 [::]:*
udp UNCONN 0 0 [fe80::dff3:6e2f:8009:2255]%enp34s0:546 [::]:*
tcp LISTEN 0 511 0.0.0.0:3000 0.0.0.0:* users:(("node",pid=5000,fd=20))
tcp LISTEN 0 511 [::]:3000 [::]:* users:(("node",pid=5000,fd=21))
tcp LISTEN 0 511 127.0.0.1:6463 0.0.0.0:* users:(("electron",pid=1582,fd=144))
tcp LISTEN 0 511 [::1]:6463 [::]:* users:(("electron",pid=1582,fd=145))
]]

local t3code = { key = "tcp:3773:4104", port = 3773, proto = "tcp", pid = 4104, process = "t3code", addresses = { "0.0.0.0" }, localOnly = false }
local node = { key = "tcp:3000:5000", port = 3000, proto = "tcp", pid = 5000, process = "node", addresses = { "0.0.0.0", "::" }, localOnly = false }
local electron = { key = "tcp:6463:1582", port = 6463, proto = "tcp", pid = 1582, process = "electron", addresses = { "127.0.0.1", "::1" }, localOnly = true }
local resolved = { key = "tcp:53:0", port = 53, proto = "tcp", pid = 0, process = "", addresses = { "127.0.0.53" }, localOnly = true }
local llmnr = { key = "tcp:5355:0", port = 5355, proto = "tcp", pid = 0, process = "", addresses = { "::" }, localOnly = false }
local dhcp = { key = "udp:546:0", port = 546, proto = "udp", pid = 0, process = "", addresses = { "fe80::dff3:6e2f:8009:2255" }, localOnly = false }

local shared = 'tcp LISTEN 0 128 127.0.0.1:8766 0.0.0.0:* users:(("gunicorn",pid=301,fd=3),("gunicorn",pid=302,fd=3),("gunicorn",pid=300,fd=3))'
local function worker(pid)
  return { key = `tcp:8766:{pid}`, port = 8766, proto = "tcp", pid = pid, process = "gunicorn", addresses = { "127.0.0.1" }, localOnly = true }
end

local cases = {
  { name = "defaults", filters = { includeUdp = false, hideSystemPorts = true, onlyOwnProcesses = false }, expected = { node, t3code, electron, llmnr } },
  { name = "no filters", filters = { includeUdp = true, hideSystemPorts = false, onlyOwnProcesses = false }, expected = { node, t3code, electron, resolved, dhcp, llmnr } },
  { name = "only own processes", filters = { includeUdp = true, hideSystemPorts = false, onlyOwnProcesses = true }, expected = { node, t3code, electron } },
  { name = "every owner of a shared socket", filters = { includeUdp = false, hideSystemPorts = true, onlyOwnProcesses = false }, expected = { worker(301), worker(302), worker(300) }, text = shared },
  { name = "empty input", filters = { includeUdp = true, hideSystemPorts = false, onlyOwnProcesses = false }, expected = {}, text = "" },
}

local function deepEqual(a, b): boolean
  if type(a) ~= "table" or type(b) ~= "table" then
    return a == b
  end
  for k, v in a do
    if not deepEqual(v, b[k]) then
      return false
    end
  end
  for k in b do
    if a[k] == nil then
      return false
    end
  end
  return true
end

local function show(value): string
  if type(value) ~= "table" then
    return if type(value) == "string" then `"{value}"` else tostring(value)
  end
  local keys = {}
  for k in value do
    table.insert(keys, k)
  end
  table.sort(keys, function(x, y)
    return tostring(x) < tostring(y)
  end)
  local parts = {}
  for _, k in keys do
    table.insert(parts, if type(k) == "number" then show(value[k]) else `{k} = {show(value[k])}`)
  end
  return `\{ {table.concat(parts, ", ")} }`
end

return function(report)
  local failed = 0
  for _, case in cases do
    local actual = listeners.parse(case.text or sample, case.filters)
    if deepEqual(actual, case.expected) then
      report(`ok - {case.name}`)
    else
      failed += 1
      report(`not ok - {case.name}\n  expected {show(case.expected)}\n  actual   {show(actual)}`)
    end
  end

  local commands = {
    { name = "stop known pid", listener = node, expected = { "kill", "5000" } },
    { name = "stop hidden owner", listener = llmnr, expected = { "pkexec", "fuser", "-k", "-TERM", "5355/tcp" } },
    { name = "stop UDP listener", listener = dhcp, expected = { "pkexec", "fuser", "-k", "-TERM", "546/udp" } },
  }
  for _, case in commands do
    local actual = listeners.stopCommand(case.listener)
    if deepEqual(actual, case.expected) then
      report(`ok - {case.name}`)
    else
      failed += 1
      report(`not ok - {case.name}: {show(actual)}`)
    end
  end

  if failed > 0 then
    error(`{failed} cases failed`)
  end
end
