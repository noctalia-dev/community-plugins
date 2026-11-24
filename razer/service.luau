--!strict
local Razer = require("./razer_dbus.luau")

local lastAppliedColorMap: { [string]: string } = {}
local lastDpiMap: { [string]: number } = {}
local lastBrightnessMap: { [string]: number } = {}
local lowBatteryWarned: { [string]: boolean } = {}
local lowBatteryStreak: { [string]: number } = {}
local lastBatteryMap: { [string]: number } = {}
local batteryDropStreak: { [string]: number } = {}

local CONFIRM_STREAK = 3
local MAX_SINGLE_POLL_DROP = 25

local function resetBatteryTracking()
  lowBatteryStreak = {}
  lastBatteryMap = {}
  batteryDropStreak = {}
end

function update()
  noctalia.setUpdateInterval(1000)

  Razer.checkDaemon(function(daemonRunning)
    noctalia.state.set("razer_daemon_active", daemonRunning)

    if not daemonRunning then
      resetBatteryTracking()
      noctalia.state.set("razer_devices", {})
      return
    end

    Razer.getDevices(function(serials)
      if #serials == 0 then
        resetBatteryTracking()
        noctalia.state.set("razer_devices", {})
        return
      end

      local devices = {}
      local completed = 0

      for _, serial in ipairs(serials) do
        Razer.getDeviceInfo(serial, function(info)
          completed = completed + 1
          if info then
            -- Stabilize transient bogus battery drops (e.g. OpenRazer re-init glitches)
            if info.hasBattery then
              local prevBattery = lastBatteryMap[serial]
              if prevBattery ~= nil and (prevBattery - info.battery) >= MAX_SINGLE_POLL_DROP then
                batteryDropStreak[serial] = (batteryDropStreak[serial] or 0) + 1
                if batteryDropStreak[serial] < CONFIRM_STREAK then
                  info.battery = prevBattery
                else
                  lastBatteryMap[serial] = info.battery
                  batteryDropStreak[serial] = 0
                end
              else
                lastBatteryMap[serial] = info.battery
                batteryDropStreak[serial] = 0
              end
            else
              lastBatteryMap[serial] = nil
              batteryDropStreak[serial] = nil
            end

            table.insert(devices, info)

            -- Check low battery alert (debounced across consecutive polls)
            local threshold = noctalia.getConfig("low_battery_threshold") or 20
            if info.hasBattery and info.battery <= threshold and not info.isCharging then
              lowBatteryStreak[serial] = (lowBatteryStreak[serial] or 0) + 1
              if lowBatteryStreak[serial] >= CONFIRM_STREAK and not lowBatteryWarned[serial] then
                noctalia.notifyError("Razer Battery Low", string.format("%s is at %d%%", info.name, info.battery))
                lowBatteryWarned[serial] = true
              end
            else
              lowBatteryStreak[serial] = 0
              if info.hasBattery and info.battery > threshold then
                lowBatteryWarned[serial] = false
              end
            end
          end

          if completed == #serials then
            -- Preserve UI-specific fields from old devices state
            local oldDevices = noctalia.state.get("razer_devices") or {}
            local stateChanged = false

            for _, dev in ipairs(devices) do
              for _, old in ipairs(oldDevices) do
                if old.serial == dev.serial then
                  dev.activeLightingMode = old.activeLightingMode
                  dev.currentColorHex = old.currentColorHex
                  dev.customColorInput = old.customColorInput
                  dev.themeRole = old.themeRole
                  dev.roleMenuOpen = old.roleMenuOpen
                  break
                end
              end

              if not dev.activeLightingMode then
                dev.activeLightingMode = "theme"
              end

              if lastDpiMap[dev.serial] ~= dev.dpi or lastBrightnessMap[dev.serial] ~= dev.brightness then
                stateChanged = true
                lastDpiMap[dev.serial] = dev.dpi
                lastBrightnessMap[dev.serial] = dev.brightness
                dev.customDpiInput = dev.dpi > 0 and tostring(dev.dpi) or ""
              end
            end

            noctalia.state.set("razer_devices", devices)

            if stateChanged then
              noctalia.runAsync({"noctalia", "msg", "plugin", "detluck/razer:panel", "all", "refresh"})
            end

            -- Auto-sync theme color for devices in theme mode
            syncThemeColor(devices)
          end
        end)
      end
    end)
  end)
end

function syncThemeColor(devices: { any }?)
  local targetDevices = devices or noctalia.state.get("razer_devices") or {}
  local anyColorChanged = false

  for _, dev in ipairs(targetDevices) do
    if dev.activeLightingMode == "theme" then
      local role = dev.themeRole or "primary"
      local themeHex = Razer.getThemeColor(role)
      if themeHex and themeHex ~= lastAppliedColorMap[dev.serial] then
        local cleanHex = themeHex:gsub("#", "")
        if #cleanHex == 6 then
          local r = tonumber(cleanHex:sub(1, 2), 16) or 0
          local g = tonumber(cleanHex:sub(3, 4), 16) or 255
          local b = tonumber(cleanHex:sub(5, 6), 16) or 0
          Razer.setStatic(dev.serial, r, g, b)
          lastAppliedColorMap[dev.serial] = themeHex
          dev.currentColorHex = themeHex
          anyColorChanged = true
          noctalia.log(string.format("Synced %s lighting to theme (%s): #%s", dev.name, role, cleanHex))
        end
      end
    else
      lastAppliedColorMap[dev.serial] = nil
    end
  end

  if anyColorChanged then
    noctalia.state.set("razer_devices", targetDevices)
    noctalia.runAsync({"noctalia", "msg", "plugin", "detluck/razer:panel", "all", "refresh"})
  end
end

function onIpc(event: string, payload: string)
  if event == "sync_theme" then
    lastAppliedColorMap = {} -- force sync
    local devs = noctalia.state.get("razer_devices") or {}
    for _, dev in ipairs(devs) do
      dev.activeLightingMode = "theme"
    end
    noctalia.state.set("razer_devices", devs)
    syncThemeColor(devs)
  elseif event == "refresh" then
    update()
  end
end
