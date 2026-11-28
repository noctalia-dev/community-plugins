--!nonstrict
-- LAMZU-protocol mouse battery - [[widget]] (bar).
--
-- Every `poll_seconds` it runs the bundled lamzu-battery.py (one-shot hidraw
-- query, JSON on stdout) and shows a mouse glyph with the battery percentage.
-- While the mouse sleeps, the last level seen this session stays visible and
-- the tooltip says so. Click to refresh immediately.

local HELPER = noctalia.pluginDir() .. "/lamzu-battery.py"

local lowThreshold = noctalia.getConfig("low_threshold")
local showPercent = noctalia.getConfig("show_percent")
local hideWhenMissing = noctalia.getConfig("hide_when_missing")
local pollSeconds = noctalia.getConfig("poll_seconds")
local normalColor = noctalia.getConfig("normal_color")
local chargingColor = noctalia.getConfig("charging_color")
local lowColor = noctalia.getConfig("low_color")

local running = false
local lastPercent = nil
local lastCharging = false
local lastName = nil
local lastUpdated = nil

local function ago(ts)
  local s = os.time() - ts
  if s < 90 then
    return noctalia.tr("ui.just-now")
  elseif s < 5400 then
    return noctalia.tr("ui.minutes-ago", { n = math.floor(s / 60) })
  end
  return noctalia.tr("ui.hours-ago", { n = math.floor(s / 3600) })
end

local function show(glyph, text, color, tooltip)
  barWidget.setVisible(true)
  barWidget.setGlyph(glyph)
  barWidget.setText(showPercent and text or "")
  barWidget.setGlyphColor(color)
  barWidget.setTooltip(tooltip)
end

local function showProblem(key)
  if hideWhenMissing and key == "ui.no-device" then
    barWidget.setVisible(false)
    return
  end
  show("mouse-off", "", key == "ui.no-device" and "on_surface_variant" or lowColor, noctalia.tr(key))
end

local function showLevel(asleep)
  local color = normalColor
  if lastCharging then
    color = chargingColor
  elseif lastPercent <= lowThreshold then
    color = lowColor
  end
  local lines = { lastName, tostring(lastPercent) .. "%" .. (lastCharging and (" " .. noctalia.tr("ui.charging")) or "") }
  if asleep then
    table.insert(lines, noctalia.tr("ui.asleep-last-known"))
  end
  table.insert(lines, noctalia.tr("ui.updated", { when = ago(lastUpdated) }))
  show(lastCharging and "bolt" or "mouse", tostring(lastPercent) .. "%", color, table.concat(lines, "\n"))
end

local function onResult(result)
  running = false
  if type(result) ~= "table" or result.timedOut or result.exitCode ~= 0 then
    showProblem("ui.helper-failed")
    return
  end
  local decoded = noctalia.json.decode(result.stdout or "")
  local devices = type(decoded) == "table" and decoded.devices or nil
  if type(devices) ~= "table" or #devices == 0 then
    showProblem("ui.no-device")
    return
  end

  local asleep, denied = nil, false
  for _, dev in devices do
    if dev.status == "ok" then
      lastPercent = dev.percent
      lastCharging = dev.charging == true
      lastName = dev.name
      lastUpdated = os.time()
      showLevel(false)
      return
    elseif dev.status == "asleep" then
      asleep = asleep or dev
    elseif dev.status == "no_permission" then
      denied = true
    end
  end

  if asleep ~= nil then
    if lastPercent ~= nil then
      showLevel(true)
    else
      show("mouse", "", "on_surface_variant", asleep.name .. "\n" .. noctalia.tr("ui.asleep"))
    end
  elseif denied then
    showProblem("ui.no-permission")
  else
    showProblem("ui.query-failed")
  end
end

local function refresh()
  if running then
    return
  end
  if not noctalia.commandExists("python3") then
    showProblem("ui.no-python")
    return
  end
  running = true
  noctalia.runAsync({ "python3", "-B", "-I", HELPER }, onResult, 10000)
end

function update()
  noctalia.setUpdateInterval(pollSeconds * 1000)
  refresh()
end

function onClick()
  refresh()
end
