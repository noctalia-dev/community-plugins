--!nonstrict

local STATE_KEY = "librelinkup_status"
local COMMAND_KEY = "librelinkup_command"

local glyph = noctalia.getConfig("glyph") or "droplet"
local showUnit = noctalia.getConfig("show_unit")
showUnit = (showUnit == true or showUnit == "true")

local lowThreshold = 70
local highThreshold = 180

local status = noctalia.state.get(STATE_KEY) or {
  loading = true,
  error = "",
  glucose = nil,
  arrow = "",
  timestamp = "",
}

local function roundedGlucose(value)
  if value == nil then
    return nil
  end
  return math.floor(value + 0.5)
end

local function glucoseColor(value)
  if value == nil then return "on_surface_variant" end
  if value < lowThreshold then return "error" end
  if value > highThreshold then return "warning" end
  return "primary"
end

local function formatText()
  if status.loading and status.glucose == nil and status.error == "" then
    return "..."
  end
  if status.error ~= "" and status.glucose == nil then
    return "!"
  end
  if status.glucose == nil then
    return "--"
  end

  local text = tostring(roundedGlucose(status.glucose))
  if status.arrow ~= "" then
    text = text .. " " .. status.arrow
  end
  if showUnit then
    text = text .. " mg/dL"
  end
  return text
end

local function formatTooltip()
  if status.error ~= "" and status.glucose == nil then
    return status.error .. "\n" .. noctalia.tr("disclaimer.summary")
  end
  if status.glucose == nil then
    return noctalia.tr("tooltip.loading")
  end

  local lines = {
    noctalia.tr("tooltip.reading", {
      value = tostring(roundedGlucose(status.glucose)),
      unit = "mg/dL",
      arrow = status.arrow ~= "" and status.arrow or "?",
    }),
  }

  if status.timestamp ~= "" then
    table.insert(lines, noctalia.tr("tooltip.measured", { time = status.timestamp }))
  end

  table.insert(lines, noctalia.tr("disclaimer.summary"))

  return table.concat(lines, "\n")
end

local function render()
  local color = glucoseColor(status.glucose)
  barWidget.setGlyph(glyph)
  barWidget.setText(formatText())
  barWidget.setColor(color)
  barWidget.setGlyphColor(color)
  barWidget.setTooltip(formatTooltip())
end

noctalia.state.watch(STATE_KEY, function(value)
  if type(value) ~= "table" then return end
  status = value
  lowThreshold = tonumber(value.lowThreshold) or 70
  highThreshold = tonumber(value.highThreshold) or 180
  render()
end)

function onClick()
  noctalia.state.set(COMMAND_KEY, { action = "refresh" })
end

function onConfigChanged()
  glyph = noctalia.getConfig("glyph") or "droplet"
  showUnit = noctalia.getConfig("show_unit")
  showUnit = (showUnit == true or showUnit == "true")
  render()
end

render()
