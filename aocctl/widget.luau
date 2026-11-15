--!nonstrict
-- The AOC monitor's brightness on the bar. Each bar controls the monitor it sits on, and hides
-- on monitors that aren't AOC. Click opens the panel with every setting and preset; scrolling
-- changes brightness in 5% steps. Reads the monitor once a minute and when the pointer arrives.
local lib = require("./lib.luau")

local STEP = 5
local POLL_MS = 60000
-- How long to wait before looking for the monitor again when this bar's output has none
local RESCAN_MS = 300000

local display = nil -- this bar's AOC monitor, from `aocctl list`
local problem = nil -- why the widget can't show a value
local brightness = nil -- { value, max }
local lastScan = nil
local reading = false
local target = nil -- brightness the scroll wheel asked for and that isn't written yet
local writing = nil -- brightness being written now
local held = 0 -- brightness change scrolled while a read ran; applied to what it reads
-- This bar's output. barWidget.outputName() answers only inside update(), not while the script
-- loads or in callbacks, so update() keeps it here.
local output = nil

local function percent(b)
  if b.max == nil or b.max == 0 then
    return b.value
  end
  return math.floor(b.value * 100 / b.max + 0.5)
end

local function render()
  if display == nil and problem == nil then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)
  if problem then
    barWidget.setGlyph("device-desktop-exclamation")
    barWidget.setText("")
    barWidget.setGlyphColor("on_surface_variant")
    barWidget.setTooltip(problem)
    return
  end
  barWidget.setGlyph("brightness-half")
  barWidget.setGlyphColor("on_surface")
  local rows = { { lib.modelName(display), display.connector } }
  if brightness then
    barWidget.setText(`{percent(brightness)}%`)
    table.insert(rows, { "Brightness", `{percent(brightness)}%` })
  else
    barWidget.setText("…")
  end
  table.insert(rows, { "Click", "settings and presets" })
  table.insert(rows, { "Scroll", "brightness" })
  barWidget.setTooltip(rows)
end

local function watchBrightness()
  noctalia.state.watch(lib.brightnessKey(display.connector), function(b)
    if b and writing == nil then
      brightness = b
      render()
    end
  end)
end

local applyScroll

local function readBrightness()
  if display == nil or not lib.reachable(display) or reading or writing ~= nil then
    return
  end
  reading = true
  lib.run({ "get", "brightness", "--display", display.connector }, 15000, function(data, err)
    reading = false
    local row = data and data.settings and data.settings[1]
    local delta = held
    held = 0
    if row and row.value then
      problem = nil
      brightness = { value = row.value, max = row.max }
      noctalia.state.set(lib.brightnessKey(display.connector), brightness)
    else
      problem = `{lib.modelName(display)}: {err or (row and row.error) or "no reading"}`
      lastScan = nil -- the monitor may have been unplugged or replugged: look again
    end
    render()
    if delta ~= 0 and problem == nil then
      applyScroll(delta)
    end
  end)
end

-- Finds this bar's monitor with `aocctl list`, then reads its brightness
local function scan()
  if not noctalia.commandExists("aocctl") then
    problem = "aocctl isn't installed or isn't on PATH"
    render()
    return
  end
  lastScan = noctalia.nowMs()
  lib.run({ "list" }, 15000, function(list, err)
    if list == nil then
      problem = `aocctl: {err}`
      render()
      return
    end
    local found = lib.pickDisplay(list, output, false)
    local changed = (found and found.connector) ~= (display and display.connector)
    display = found
    problem = nil
    if found and not lib.reachable(found) then
      problem = `{lib.modelName(found)}: {found.status}`
    end
    if found and changed then
      watchBrightness()
    end
    render()
    readBrightness()
  end)
end

-- Writes the newest scroll target; a scroll during a write is written once that one finishes.
local function writeTarget()
  if writing ~= nil or target == nil or display == nil then
    return
  end
  local value = target
  target = nil
  writing = value
  lib.run({ "set", "brightness", tostring(value), "--display", display.connector }, 15000, function(data, err)
    writing = nil
    if data and data.read_back then
      brightness = { value = data.read_back, max = brightness and brightness.max or 100 }
      noctalia.state.set(lib.brightnessKey(display.connector), brightness)
    end
    if data and data.status == "verified" then
      render()
      writeTarget()
      return
    end
    -- Not confirmed: drop scrolls counted from the value that didn't stick, and read the
    -- monitor unless it already told us what it has
    target = nil
    noctalia.notifyError("AOC brightness", err or (data.error and `couldn't read it back: {data.error}`) or `the monitor reads back {data.read_back}`)
    render()
    if not (data and data.read_back) then
      readBrightness()
    end
  end)
end

-- Moves the brightness by `delta` from the newest value: the one asked for, being written,
-- or last read
applyScroll = function(delta)
  local max = brightness.max or 100
  local base = target or writing or brightness.value
  target = math.clamp(base + delta, 0, max)
  local shown = { value = target, max = max }
  noctalia.osd.show("brightness-half", `{percent(shown)}%`, { progress = target / max })
  barWidget.setText(`{percent(shown)}%`)
  writeTarget()
end

function onScroll(axis, steps)
  if axis ~= "vertical" or steps == 0 or display == nil or brightness == nil or problem then
    return
  end
  -- Whole detents up (negative steps) raise brightness; a partial touchpad step counts as one
  local detents = math.max(1, math.floor(math.abs(steps) + 0.5))
  local delta = (steps < 0 and detents or -detents) * STEP
  if reading then
    held += delta -- the monitor may have changed since the last read: wait for this one
  else
    applyScroll(delta)
  end
end

-- Reads again when the pointer arrives, so a scroll starts from the monitor's current value
-- even if it changed since the last poll (the monitor's own buttons, another program)
function onHover(entered)
  if entered then
    readBrightness()
  end
end

function onClick()
  noctalia.state.set("panelDisplay", { connector = display and display.connector or output, at = noctalia.nowMs() })
  noctalia.togglePanel(lib.PANEL)
end

function update()
  -- The output isn't known yet while the script loads: tick fast until it is
  if output == nil then
    output = barWidget.outputName()
    if output == nil then
      return
    end
    noctalia.setUpdateInterval(POLL_MS)
  end
  if display == nil or problem then
    if lastScan == nil or noctalia.nowMs() - lastScan >= RESCAN_MS or problem then
      scan()
    end
  else
    readBrightness()
  end
end

noctalia.setUpdateInterval(1000)
render()
