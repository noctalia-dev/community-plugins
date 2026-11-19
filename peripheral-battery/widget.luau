--!nonstrict
-- Bar widget: peripheral battery summary with tooltip and panel toggle.

local PANEL_ID = "nemanja/peripheral-battery:panel"
local KEY_SNAPSHOT = "snapshot"

local snapshot = noctalia.state.get(KEY_SNAPSHOT)
local lastRenderKey = nil

local function shortPct(n)
  if n == nil then return "?" end
  return tostring(math.floor(n + 0.5)) .. "%"
end

local function summaryText(s)
  if s == nil then return "…" end
  if s.error then return "!" end
  local devices = s.devices or {}
  local total = s.total or #devices
  if total == 0 then return "—" end

  local lowest = s.lowest
  if total == 1 then
    local d = devices[1]
    if d then
      if type(d.percentage) == "number" then return shortPct(d.percentage) end
      local lvl = d.batteryLevel
      if lvl ~= nil and lvl ~= "" then return lvl end
    end
    return "1"
  end

  if type(lowest) == "number" then
    return tostring(total) .. " · " .. shortPct(lowest)
  end
  return tostring(total)
end

local function summaryColor(s)
  if s ~= nil and s.error then
    return "error"
  end
  return "on_surface"
end

local function tooltipRows(s)
  local rows = {}
  if s == nil then
    rows[1] = { key = "Peripheral Battery", value = "Loading…" }
    return rows
  end
  if s.error then
    rows[1] = { key = "Peripheral Battery", value = "Error" }
    rows[2] = { key = "Details", value = tostring(s.error) }
    return rows
  end

  local devices = s.devices or {}
  local total = s.total or #devices
  if total == 0 then
    rows[1] = { key = "Peripherals", value = "No battery devices found" }
    rows[2] = { key = "Hint", value = "Connect a wireless peripheral or check UPower" }
    return rows
  end

  rows[1] = { key = "Peripherals", value = tostring(total) .. " device(s)" }
  for i = 1, #devices do
    local d = devices[i]
    local val
    if type(d.percentage) == "number" then
      val = shortPct(d.percentage)
    elseif d.batteryLevel ~= nil and d.batteryLevel ~= "" then
      val = d.batteryLevel
    else
      val = "?"
    end
    if d.charging then
      val = val .. " ⚡"
    elseif d.full then
      val = val .. " ✓"
    end
    local st = d.state
    if st ~= nil and st ~= "" and st ~= "unknown" and st ~= "discharging" then
      val = val .. " (" .. st .. ")"
    end
    rows[#rows + 1] = { key = (d.name or "Peripheral"), value = val }
  end
  if s.updatedAt then
    rows[#rows + 1] = { key = "Updated", value = os.date("%H:%M:%S", s.updatedAt) }
  end
  return rows
end

local function pickGlyph(s)
  local devices = (s and s.devices) or {}
  local n = (s and s.total) or #devices
  if n == 1 and devices[1] ~= nil then
    return devices[1].glyph or "battery"
  end
  if n > 1 then return "devices" end
  return "mouse"
end

local function render()
  local s = snapshot
  local glyph = pickGlyph(s)
  local text = summaryText(s)
  local color = summaryColor(s)
  local rows = tooltipRows(s)
  local lastRow = rows[#rows]
  local renderKey = table.concat({
    glyph,
    text,
    color,
    tostring(#rows),
    tostring(s and s.updatedAt or ""),
    tostring(s and s.error or ""),
    lastRow and tostring(lastRow.value) or "",
  }, "\31")

  if renderKey == lastRenderKey then
    return
  end
  lastRenderKey = renderKey

  barWidget.setGlyph(glyph)
  barWidget.setText(text)
  barWidget.setColor(color)
  barWidget.setTooltip(rows)
end

noctalia.state.watch(KEY_SNAPSHOT, function(v)
  snapshot = v
  render()
end)

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

render()
