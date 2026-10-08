--!nonstrict
-- Input Echo Bar starts one host-managed input stream. The packaged helper
-- formats events and emits an empty text value after the configured timeout.

local function shellQuote(value: string): string
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local timeoutMs = tonumber(noctalia.getConfig("timeout_ms")) or 2000
if timeoutMs < 250 or timeoutMs > 10000 then
  timeoutMs = 2000
end
timeoutMs = math.floor(timeoutMs)

local showMouseEvents = noctalia.getConfig("show_mouse_events") ~= false
local pluginDir = noctalia.pluginDir() or ""
local helper = pluginDir .. "/input_echo.py"
local command = "showmethekey-cli | python3 -u "
  .. shellQuote(helper)
  .. " --timeout-ms "
  .. tostring(timeoutMs)
if showMouseEvents then
  command = command .. " --show-mouse-events"
end

local function hide()
  barWidget.setText("")
  barWidget.setVisible(false)
  barWidget.clearTooltip()
end

local function applyLine(line: string)
  local ok, event = pcall(noctalia.json.decode, line)
  if not ok or type(event) ~= "table" then
    return
  end

  local text = event.text
  if type(text) ~= "string" or text == "" then
    hide()
    return
  end

  barWidget.setGlyph(event.kind == "mouse" and "mouse" or "keyboard")
  barWidget.setText(text)
  barWidget.setTooltip(text)
  barWidget.setVisible(true)
end

function onRightClick()
  noctalia.openSettings()
end

hide()
if not noctalia.runStream(command, applyLine) then
  noctalia.notifyError("Input Echo Bar", "Unable to start the input event stream")
end

-- The host owns the runStream process group and terminates the pipeline when
-- this widget exits or reloads; the plugin does not create its own daemon.
local _ = onRightClick
