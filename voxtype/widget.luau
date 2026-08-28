--!nonstrict
-- Voxtype bar widget.
--
-- `voxtype status --follow --format json` emits one JSON object immediately,
-- then another whenever the dictation state changes. The command's emoji
-- `text` value is intentionally ignored so Noctalia can render a themeable
-- glyph instead. Voxtype's `--extended` output always expands the tooltip with
-- all three fields; the nested settings choose which fields also appear on the
-- bar.

local SHOW_ALT = noctalia.getConfig("show_alt") == true
local SHOW_EXTENDED = noctalia.getConfig("show_extended") == true
local EXTENDED_FIELDS = {
  { name = "model", visible = noctalia.getConfig("show_model") ~= false },
  { name = "device", visible = noctalia.getConfig("show_device") ~= false },
  { name = "backend", visible = noctalia.getConfig("show_backend") ~= false },
}

local STATES = {
  idle = {
    glyph = noctalia.getConfig("idle_glyph") or "microphone-2-off",
    color = noctalia.getConfig("idle_color") or "on_surface",
  },
  streaming = {
    glyph = noctalia.getConfig("streaming_glyph") or "microphone-2",
    color = noctalia.getConfig("streaming_color") or "error",
  },
  recording = {
    glyph = noctalia.getConfig("recording_glyph") or "microphone-2",
    color = noctalia.getConfig("recording_color") or "error",
  },
  transcribing = {
    glyph = noctalia.getConfig("transcribing_glyph") or "loader",
    color = noctalia.getConfig("transcribing_color") or "primary",
  },
  stopped = {
    glyph = noctalia.getConfig("stopped_glyph") or "microphone-2-off",
    color = noctalia.getConfig("stopped_color") or "error",
  },
}

local function render(status)
  if type(status) ~= "table" then
    return
  end

  local state = STATES[status.class]
  if state == nil then
    noctalia.log("voxtype: ignored unknown status class " .. tostring(status.class))
    return
  end

  barWidget.setGlyph(state.glyph)
  barWidget.setGlyphColor(state.color)

  local text = {}
  if SHOW_ALT and type(status.alt) == "string" then
    table.insert(text, status.alt)
  end
  if SHOW_EXTENDED then
    for _, field in ipairs(EXTENDED_FIELDS) do
      local value = status[field.name]
      if field.visible and type(value) == "string" and value ~= "" then
        table.insert(text, noctalia.tr("widget." .. field.name, { value = value }))
      end
    end
  end
  barWidget.setText(table.concat(text, " · "))

  if type(status.tooltip) == "string" then
    barWidget.setTooltip(status.tooltip)
  else
    barWidget.clearTooltip()
  end
end

local function onStatusLine(line)
  local ok, status = pcall(noctalia.json.decode, line)
  if not ok or type(status) ~= "table" then
    noctalia.log("voxtype: ignored invalid status JSON")
    return
  end
  render(status)
end

-- Use the configured idle appearance while waiting for the command's initial
-- status line.
barWidget.setGlyph(STATES.idle.glyph)
barWidget.setGlyphColor(STATES.idle.color)
barWidget.setText("")
barWidget.setTooltip(noctalia.tr("widget.waiting"))

if not noctalia.commandExists("voxtype") then
  barWidget.setGlyph("microphone-off")
  barWidget.setGlyphColor("error")
  barWidget.setTooltip(noctalia.tr("widget.unavailable"))
else
  local command = "voxtype status --follow --format json"
  if SHOW_EXTENDED then
    command = command .. " --extended"
  end

  -- runStream has no exit callback or restart policy. Keep the retry lifecycle
  -- in one managed shell process: only one status command runs at a time, a
  -- failure waits before restarting, and the loop ends once its host is gone.
  local retryLoop = 'P=$PPID; while kill -0 "$P" 2>/dev/null; do '
    .. command .. "; sleep 2; done"
  if not noctalia.runStream(retryLoop, onStatusLine) then
    barWidget.setGlyph("microphone-off")
    barWidget.setGlyphColor("error")
    barWidget.setTooltip(noctalia.tr("widget.stream_error"))
  end
end
