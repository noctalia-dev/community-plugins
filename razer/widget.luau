--!strict
local Razer = require("./razer_dbus.luau")

function update()
  noctalia.setUpdateInterval(5000)

  local daemonActive = noctalia.state.get("razer_daemon_active")
  local devices = noctalia.state.get("razer_devices") or {}

  if daemonActive == false then
    barWidget.setGlyph("mouse-2")
    barWidget.setText("")
    barWidget.setTooltip("OpenRazer daemon not running")
    return
  end

  if #devices == 0 then
    barWidget.setGlyph("mouse-2")
    barWidget.setText("")
    barWidget.setTooltip("No Razer devices connected")
    return
  end

  -- Pick the primary device (prefer mouse or device with battery)
  local primary = devices[1]
  for _, dev in ipairs(devices) do
    if dev.hasBattery then
      primary = dev
      break
    end
  end

  -- Choose appropriate glyph
  local glyph = "mouse-2"
  if primary.deviceType == "keyboard" then
    glyph = "keyboard"
  elseif primary.deviceType == "headset" then
    glyph = "headphones"
  end
  barWidget.setGlyph(glyph)

  -- Format display text (Battery % for wireless, no DPI on bar icon)
  local showPct = noctalia.getConfig("show_percentage")
  if showPct and primary.hasBattery then
    local chg = primary.isCharging and " ⚡" or ""
    barWidget.setText(string.format("%d%%%s", primary.battery, chg))
  else
    barWidget.setText("")
  end

  -- Tooltip with summary
  local lines = {}
  for _, dev in ipairs(devices) do
    local status = "connected"
    if dev.hasBattery then
      status = string.format("%d%%%s", dev.battery, dev.isCharging and " (charging)" or "")
    elseif dev.dpi and dev.dpi > 0 then
      status = string.format("%d DPI", dev.dpi)
    end
    table.insert(lines, string.format("%s: %s", dev.name, status))
  end
  barWidget.setTooltip(table.concat(lines, "\n") .. "\n(Click: details | Right-click: sync theme)")
end

function onClick()
  noctalia.togglePanel("detluck/razer:panel")
end

function onRightClick()
  -- Trigger theme sync via IPC to the service
  noctalia.runAsync({"noctalia", "msg", "plugin", "detluck/razer:monitor", "all", "sync_theme"})
  noctalia.notify("Razer Lighting", "Synced RGB with active theme color")
end

function onScroll(axis: string, steps: number)
  local devices = noctalia.state.get("razer_devices") or {}
  if #devices == 0 then return end

  local delta = -steps * 10 -- scroll up increases, scroll down decreases
  for _, dev in ipairs(devices) do
    local newBr = math.clamp(dev.brightness + delta, 0, 100)
    Razer.setBrightness(dev.serial, newBr)
  end
end
