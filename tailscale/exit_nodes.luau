--!nonstrict
-- The service publishes the CLI output separately from the status snapshot.
-- Parse only when a panel or launcher actually needs the list.
local lastOutput = nil
local nodes = {}

return function(output)
  output = type(output) == "string" and output or ""
  if output == lastOutput then
    return nodes
  end

  local list = {}
  for line in output:gmatch("[^\r\n]+") do
    local ip, host, rest = line:match("^%s*(%d+%.%d+%.%d+%.%d+)%s+(%S+)%s+(.*)$")
    if ip then
      local status = noctalia.string.trim(rest)
      local lower = status:lower()
      table.insert(list, {
        id = ip,
        ip = ip,
        name = host:match("^([^.]+)") or host,
        host = host,
        status = status,
        selected = lower:find("selected", 1, true) ~= nil,
        online = lower:find("offline", 1, true) == nil,
      })
    end
  end
  table.sort(list, function(a, b)
    if a.selected ~= b.selected then
      return a.selected
    end
    if a.online ~= b.online then
      return a.online
    end
    return a.name < b.name
  end)
  lastOutput, nodes = output, list
  return nodes
end
