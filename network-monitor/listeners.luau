--!nonstrict

export type Listener = {
  key: string,
  port: number,
  proto: "tcp" | "udp",
  pid: number, -- 0 when the owner is hidden from us (another user or root)
  process: string, -- "" when the owner is hidden
  addresses: { string },
  localOnly: boolean, -- every address is loopback
}

export type Filters = {
  includeUdp: boolean,
  hideSystemPorts: boolean,
  onlyOwnProcesses: boolean,
}

local M = {}

local function isLoopback(address: string): boolean
  return string.sub(address, 1, 4) == "127." or address == "::1"
end

-- Rows sharing proto+port+pid (e.g. IPv4 and IPv6 binds of one server) merge into one listener.
function M.parse(text: string, filters: Filters): { Listener }
  local byKey: { [string]: Listener } = {}
  local order: { [Listener]: number } = {}
  local result: { Listener } = {}

  for line in string.gmatch(text, "[^\n]+") do
    -- Netid State Recv-Q Send-Q Local:Port Peer:Port [users:(("name",pid=N,fd=N))]
    local parts = {}
    for part in string.gmatch(line, "%S+") do
      table.insert(parts, part)
    end
    if #parts < 6 then
      continue
    end

    local proto = parts[1]
    local address, portText = string.match(parts[5], "^(.*):([^:]*)$")
    local port = tonumber(portText)
    if (proto ~= "tcp" and proto ~= "udp") or port == nil then
      continue
    end
    if proto == "udp" and not filters.includeUdp then
      continue
    end
    if filters.hideSystemPorts and port < 1024 then
      continue
    end
    local process, pidText = string.match(line, 'users:%(%("(.-)",pid=(%d+)')
    local pid = tonumber(pidText) or 0
    if filters.onlyOwnProcesses and pid == 0 then
      continue
    end

    address = string.gsub(address, "%%.*$", "")
    address = string.gsub(address, "^%[", "")
    address = string.gsub(address, "%]$", "")

    local key = `{proto}:{port}:{pid}`
    local listener = byKey[key]
    if listener == nil then
      listener = {
        key = key,
        port = port,
        proto = proto,
        pid = pid,
        process = process or "",
        addresses = {},
        localOnly = true,
      }
      byKey[key] = listener
      table.insert(result, listener)
      order[listener] = #result
    end
    if not table.find(listener.addresses, address) then
      table.insert(listener.addresses, address)
      listener.localOnly = listener.localOnly and isLoopback(address)
    end
  end

  -- Known owners first, then by port; ties keep `ss` order (table.sort is not stable).
  table.sort(result, function(a, b)
    if (a.pid == 0) ~= (b.pid == 0) then
      return a.pid ~= 0
    end
    if a.port ~= b.port then
      return a.port < b.port
    end
    return order[a] < order[b]
  end)
  return result
end

-- Without a pid the owner isn't visible to us, so polkit elevates a kill by port instead.
function M.stopCommand(listener: Listener): { string }
  if listener.pid > 0 then
    return { "kill", tostring(listener.pid) }
  end
  return { "pkexec", "fuser", "-k", "-TERM", `{listener.port}/{listener.proto}` }
end

return M
