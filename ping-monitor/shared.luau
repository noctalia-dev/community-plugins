--!nonstrict
local M = {}

function M.snapshot()
  local raw = noctalia.state.get("snap")
  if raw then
    local ok, data = pcall(noctalia.json.decode, raw)
    if ok and type(data) == "table" and type(data.devices) == "table" then return data end
  end
  return { devices = {}, muted = false, days = 14 }
end

function M.color(status)
  if status == "up" then return "primary" end
  if status == "down" then return "error" end
  return "on_surface_variant"
end

-- overall status: down if any device is down, up if all are up
function M.overall(devices)
  local anyDown, allUp = false, #devices > 0
  for _, d in devices do
    if d.status == "down" then anyDown = true end
    if d.status ~= "up" then allUp = false end
  end
  if anyDown then return "down" end
  if allUp then return "up" end
  return "unknown"
end

function M.label(d)
  if d.name and d.name ~= "" then return d.name .. " (" .. d.ip .. ")" end
  return d.ip
end

return M
