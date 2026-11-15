--!nonstrict
-- Handy bar indicator. The service owns Handy; this widget only renders the
-- published snapshot and sends commands through the shared state channel.

local snapshot = noctalia.state.get("snapshot")
local commandCounter = 0
local showStateText = noctalia.getConfig("show_state_text") == true

local function translated(key, fallback)
  local value = noctalia.tr(key)
  if value == nil or value == key then
    return fallback
  end
  return value
end

local function sendCommand(action)
  commandCounter += 1
  noctalia.state.set("command", {
    action = action,
    nonce = tostring(noctalia.nowMs()) .. ":" .. tostring(commandCounter),
  })
end

local function preview(text)
  local value = tostring(text or ""):gsub("%s+", " ")
  if #value > 90 then
    return value:sub(1, 89) .. "…"
  end
  return value
end

local function render(value)
  snapshot = value or snapshot

  if snapshot == nil then
    barWidget.setGlyph("microphone")
    barWidget.setGlyphColor("on_surface_variant")
    barWidget.setText("")
    barWidget.setTooltip(translated("state.unavailable", "Unavailable"))
    return
  end

  if snapshot.error ~= nil then
    barWidget.setGlyph("alert-triangle")
    barWidget.setGlyphColor("error")
    barWidget.setText("")
    barWidget.setTooltip(tostring(snapshot.error))
    return
  end

  if not snapshot.running then
    barWidget.setGlyph("microphone-off")
    barWidget.setGlyphColor("on_surface_variant")
    barWidget.setText(showStateText and "OFF" or "")
    barWidget.setTooltip(translated("widget.offline", "Handy is not running — click to launch"))
    return
  end

  local state = snapshot.state or "idle"
  local glyph = "microphone"
  local color = "on_surface"
  local tooltip = translated("widget.idle", "Handy ready — click to start dictation")

  if state == "recording" then
    glyph = "player-record-filled"
    color = "error"
    tooltip = translated("widget.recording", "Handy recording — click to stop")
  elseif state == "transcribing" then
    glyph = "loader"
    color = "primary"
    tooltip = translated("widget.transcribing", "Handy transcribing…")
  end

  if snapshot.latest ~= nil and snapshot.latest.text ~= "" then
    tooltip = tooltip .. "\n" .. preview(snapshot.latest.text)
  end

  local text = ""
  if showStateText then
    if state == "recording" then
      text = "REC"
    elseif state == "transcribing" then
      text = "…"
    end
  end

  barWidget.setGlyph(glyph)
  barWidget.setGlyphColor(color)
  barWidget.setText(text)
  barWidget.setTooltip(tooltip)
end

noctalia.state.watch("snapshot", function(value)
  render(value)
end)

function onClick()
  sendCommand("toggle")
end

function onRightClick()
  noctalia.togglePanel("ooodnakov/handy:panel")
end

render(snapshot)
