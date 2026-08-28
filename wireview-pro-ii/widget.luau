--!nonstrict

local snapshot = noctalia.state.get("wireview.snapshot")
local status = noctalia.state.get("wireview.status")

local function formatNumber(value, decimals)
  local number = tonumber(value)
  if number == nil then
    return "—"
  end
  return string.format("%." .. tostring(decimals) .. "f", number)
end

local function statusColor()
  if snapshot ~= nil and tonumber(snapshot.active_fault_mask) ~= nil
    and tonumber(snapshot.active_fault_mask) ~= 0 then
    return "error"
  end
  if status ~= nil and status.state == "ready" then
    return "primary"
  end
  if status ~= nil and (status.state == "error" or status.state == "incompatible") then
    return "error"
  end
  return "on_surface_variant"
end

local function telemetryIsLive()
  return snapshot ~= nil and snapshot.stale ~= true and status ~= nil and status.state == "ready"
end

local function render()
  local vertical = barWidget.isVertical()
  local hasFault = snapshot ~= nil and tonumber(snapshot.active_fault_mask) ~= nil
    and tonumber(snapshot.active_fault_mask) ~= 0
  local live = telemetryIsLive()
  local container = vertical and ui.column or ui.row
  local children = {
    ui.box({ width = 6, height = 6, radius = 3, fill = statusColor() }),
    ui.glyph({ name = "bolt", size = 14, color = hasFault and "error" or "primary" }),
  }
  if not vertical then
    table.insert(children, ui.label({
      text = snapshot and formatNumber(snapshot.total_power_w, 0) .. " W" or "WireView",
      color = hasFault and "error" or (live and "on_surface" or "on_surface_variant"),
      fontWeight = "bold",
    }))
    if snapshot ~= nil then
      table.insert(children, ui.label({
        text = live and formatNumber(snapshot.input_temp_c, 0) .. "°" or "STALE",
        color = "on_surface_variant",
        fontWeight = live and "normal" or "bold",
      }))
    end
  end
  barWidget.render(container({ gap = 5, align = "center" }, children))

  local stateText = status and status.message or "Waiting for wireviewd"
  if snapshot ~= nil and not live then
    stateText = "Telemetry unavailable; displayed values are frozen"
  end
  if hasFault then
    local count = type(snapshot.active_faults) == "table" and #snapshot.active_faults or 0
    stateText = tostring(math.max(count, 1)) .. (count == 1 and " active fault" or " active faults")
  end
  if snapshot ~= nil then
    barWidget.setTooltip({
      { key = "Power", value = formatNumber(snapshot.total_power_w, 1) .. " W" },
      { key = "Current", value = formatNumber(snapshot.total_current_a, 2) .. " A" },
      { key = "Input", value = formatNumber(snapshot.input_temp_c, 1) .. " °C" },
      { key = "Status", value = stateText },
    })
  else
    barWidget.setTooltip(stateText)
  end
end

function onClick()
  noctalia.togglePanel("gustav0ar/wireview-pro-ii:dashboard")
end

noctalia.state.watch("wireview.snapshot", function(value)
  snapshot = value
  render()
end)

noctalia.state.watch("wireview.status", function(value)
  status = value
  render()
end)

function update()
  noctalia.setUpdateInterval(1000)
  render()
end
