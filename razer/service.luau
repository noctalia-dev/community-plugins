--!strict
local Razer = require("./razer_dbus.luau")

local lastAppliedColor = ""
local lastDpiMap: { [string]: number } = {}
local lastBrightnessMap: { [string]: number } = {}
local lowBatteryWarned: { [string]: boolean } = {}

function update()
  noctalia.setUpdateInterval(1000)

  Razer.checkDaemon(function(daemonRunning)
    noctalia.state.set("razer_daemon_active", daemonRunning)

    if not daemonRunning then
      noctalia.state.set("razer_devices", {})
      return
    end

    Razer.getDevices(function(serials)
      if #serials == 0 then
        noctalia.state.set("razer_devices", {})
        return
      end

      local devices = {}
      local completed = 0

      for _, serial in ipairs(serials) do
        Razer.getDeviceInfo(serial, function(info)
          completed = completed + 1
          if info then
            table.insert(devices, info)

            -- Check low battery alert
            local threshold = noctalia.getConfig("low_battery_threshold") or 20
            if info.hasBattery and info.battery <= threshold and not info.isCharging then
              if not lowBatteryWarned[serial] then
                noctalia.notifyError("Razer Battery Low", string.format("%s is at %d%%", info.name, info.battery))
                lowBatteryWarned[serial] = true
              end
            elseif info.hasBattery and info.battery > threshold then
              lowBatteryWarned[serial] = false
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
                  break
                end
              end

              if lastDpiMap[dev.serial] ~= dev.dpi or lastBrightnessMap[dev.serial] ~= dev.brightness then
                stateChanged = true
                lastDpiMap[dev.serial] = dev.dpi
                lastBrightnessMap[dev.serial] = dev.brightness
                dev.customDpiInput = tostring(dev.dpi)
              end
            end

            noctalia.state.set("razer_devices", devices)

            if stateChanged then
              noctalia.runAsync({"noctalia", "msg", "plugin", "detluck/razer:panel", "all", "refresh"})
            end

            -- Auto-sync theme color if enabled
            local syncEnabled = noctalia.getConfig("sync_theme_color")
            if syncEnabled then
              syncThemeColor(devices)
            end
          end
        end)
      end
    end)
  end)
end

function syncThemeColor(devices: { any }?)
  local targetDevices = devices or noctalia.state.get("razer_devices") or {}
  local primaryHex = Razer.getThemeColor()
  if not primaryHex or primaryHex == lastAppliedColor then
    return
  end

  local cleanHex = primaryHex:gsub("#", "")
  if #cleanHex ~= 6 then return end

  local r = tonumber(cleanHex:sub(1, 2), 16) or 0
  local g = tonumber(cleanHex:sub(3, 4), 16) or 255
  local b = tonumber(cleanHex:sub(5, 6), 16) or 0

  for _, dev in ipairs(targetDevices) do
    Razer.setStatic(dev.serial, r, g, b)
  end

  lastAppliedColor = primaryHex
  noctalia.log("Synced Razer lighting to theme: #" .. cleanHex)
end

function onIpc(event: string, payload: string)
  if event == "sync_theme" then
    lastAppliedColor = "" -- force sync
    syncThemeColor()
  elseif event == "refresh" then
    update()
  end
end
