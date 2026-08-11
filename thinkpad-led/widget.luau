--!nonstrict
-- ThinkPad lid logo LED — bar widget
-- A red dot in the bar that directly controls the /sys/class/leds/tpacpi::lid_logo_dot LED.
--   Left click : toggle on / off

local LED_PATH = "/sys/class/leds/tpacpi::lid_logo_dot/brightness"

-- Tri-state: true = on, false = off, nil = unknown (path missing, unreadable, etc).
local ledOn = nil
local pending = false -- true while a toggle write is in flight
local writeFailed = false -- true if the last write attempt did not succeed

-- Reads the LED brightness straight from sysfs instead of trusting any cached
-- guess. Returns nil when the file can't be read (missing device, no
-- permissions, etc), which the UI renders as an "unavailable" state.
local function readLedState()
  local contents = noctalia.readFile(LED_PATH)
  if not contents then
    return nil
  end
  local value = tonumber((contents:gsub("%s+", "")))
  if not value then
    return nil
  end
  return value > 0
end

local function statusColor()
  if ledOn then
    return "error"
  else
    return "outline"
  end
end

local function render()
  barWidget.render(ui.box({
    width = 10,
    height = 10,
    radius = 5,
    fill = statusColor(),
    border = "outline",
    borderWidth = 1,
  }))

  if ledOn == nil then
    barWidget.setTooltip("ThinkPad LED: unavailable (check permissions on " .. LED_PATH .. ")")
  elseif pending then
    barWidget.setTooltip("ThinkPad LED: updating…")
  elseif writeFailed then
    barWidget.setTooltip("ThinkPad LED: last toggle failed (permission denied?)")
  elseif ledOn then
    barWidget.setTooltip("ThinkPad LED: ON (Left click: turn off)")
  else
    barWidget.setTooltip("ThinkPad LED: OFF (Left click: turn on)")
  end
end

function update()
  if not pending then
    ledOn = readLedState()
  end
  render()
end

function onClick()
  if pending then
    return
  end

  -- Toggle off the actual hardware state, not a guessed one.
  local current = readLedState()
  if current == nil then
    ledOn = nil
    render()
    return
  end

  local target = not current
  local val = target and "255" or "0"

  pending = true
  writeFailed = false
  render()

  local started = noctalia.runAsync(`sh -c "echo {val} > {LED_PATH}"`, function(result)
    pending = false
    writeFailed = result.exitCode ~= 0
    -- Trust the hardware over the write result: read the brightness back
    -- rather than assuming the echo did what we asked.
    ledOn = readLedState()
    render()
  end)

  if not started then
    pending = false
    writeFailed = true
    ledOn = readLedState()
    render()
  end
end
