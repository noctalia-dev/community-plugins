local M = {}
local adapter = require("./adapters/init.luau")

local DEFAULTS = {
  disable_wallpaper = true,
  disable_blur = true,
  disable_animations = true,
  disable_shadows = true,
  hide_widgets = true,
  enable_dnd = true,
  clear_notifications = true,
  set_power_profile = true,
  hide_bar = false,
  hide_dock = false,
  disable_osd = true,
  pause_media = false,
  hook_on_enter = "",
  hook_on_exit = "",
}

local function getSetting(key)
  local val = noctalia.getConfig(key)
  if val == nil then
    return DEFAULTS[key]
  end
  return val
end

local function getSnapshotFile()
  local dataDir = noctalia.pluginDataDir and noctalia.pluginDataDir()
  if dataDir and dataDir ~= "" then
    if noctalia.mkdirAll then
      pcall(noctalia.mkdirAll, dataDir)
    end
    return dataDir .. "/snapshot.json"
  end
  local home = noctalia.getenv("HOME") or ""
  local cacheDir = home .. "/.cache/noctalia-performance-plus"
  if noctalia.mkdirAll then
    pcall(noctalia.mkdirAll, cacheDir)
  end
  return cacheDir .. "/snapshot.json"
end

local isActive = false
local isActivating = false
local activationEpoch = 0

local function saveSnapshot(snapshot)
  -- Retain original snapshot until active-to-inactive transition
  if noctalia.state.get("snapshot") ~= nil then
    return
  end
  noctalia.state.set("snapshot", snapshot)
  local path = getSnapshotFile()
  if path then
    noctalia.writeFile(path, noctalia.json.encode(snapshot))
  end
end

local function loadSnapshot()
  local snap = noctalia.state.get("snapshot")
  if snap then
    return snap
  end
  local path = getSnapshotFile()
  if path and noctalia.fileExists(path) then
    local content = noctalia.readFile(path)
    if content and content ~= "" then
      local decoded = noctalia.json.decode(content)
      if decoded then
        noctalia.state.set("snapshot", decoded)
        return decoded
      end
    end
  end
  return nil
end

local function clearSnapshot()
  noctalia.state.set("snapshot", nil)
  local path = getSnapshotFile()
  if path and noctalia.fileExists(path) then
    noctalia.removeFile(path)
  end
end

local function setWallpapers(enabled)
  local outputs = noctalia.outputs()
  for _, out in ipairs(outputs) do
    noctalia.setWallpaperEnabled(out.name, enabled)
  end
end

local function setDesktopWidget(enabled)
  local action = enabled and "desktop-widgets-show" or "desktop-widgets-hide"
  noctalia.runAsync({"noctalia", "msg", action})
end

local function setDnd(enabled)
  noctalia.runAsync({"noctalia", "msg", "notification-dnd-set", enabled and "true" or "false"})
end

local function clearActiveNotifications()
  noctalia.runAsync({"noctalia", "msg", "notification-clear-active"})
end

local function setPowerProfile(profile)
  if profile and profile ~= "" then
    noctalia.runAsync({"noctalia", "msg", "power-set", profile})
 end
end

local function setBarVisibility(show)
  noctalia.runAsync({"noctalia", "msg", show and "bar-show" or "bar-hide"})
end

local function setDockVisibility(show)
  noctalia.runAsync({"noctalia", "msg", show and "dock-show" or "dock-hide"})
end

local function setOsdEnabled(enabled)
  noctalia.runAsync({"noctalia", "msg", enabled and "osd-enable" or "osd-disable"})
end

local function pauseMediaPlayback()
  noctalia.runAsync({"noctalia", "msg", "media", "pause"})
end

local function runHook(cmd)
  if cmd and cmd ~= "" then
    noctalia.runAsync(cmd)
  end
end

function M.toggle(perfMode)
  if perfMode then
    -- Idempotency check: if already active or currently activating, no-op
    if isActive or isActivating or loadSnapshot() ~= nil then
      noctalia.state.set("performance", true)
      return
    end

    isActivating = true
    activationEpoch = activationEpoch + 1
    local currentEpoch = activationEpoch
    noctalia.state.set("performance", true)

    local queryCmd = [[sh -c '
dnd=$(noctalia msg notification-dnd-status 2>/dev/null | tr -d "\r\n")
power=$(powerprofilesctl get 2>/dev/null | tr -d "\r\n")
status=$(noctalia msg status 2>/dev/null || echo "{}")
echo "{\"dnd\":\"$dnd\",\"power\":\"$power\",\"status\":$status}"
']]

    noctalia.runAsync(queryCmd, function(result)
      if currentEpoch ~= activationEpoch then
        return
      end
      if not isActivating or noctalia.state.get("performance") ~= true then
        isActivating = false
        return
      end
      isActivating = false
      isActive = true

      if loadSnapshot() == nil then
        local data = nil
        if result and result.stdout and result.stdout ~= "" then
          data = noctalia.json.decode(result.stdout)
        end

        local snapshot = {
          dnd = (data and (data.dnd == "on" or data.dnd == "true")),
          power_profile = (data and data.power and data.power ~= "") and data.power or "balanced",
          bar_visible = (data and data.status and data.status.barVisible == true),
          desktop_widgets = noctalia.getSetting("desktop_widgets.enabled") ~= false,
          osd = noctalia.getSetting("osd.enabled") ~= false,
          dock = noctalia.getSetting("dock.enabled") ~= false,
        }
        saveSnapshot(snapshot)
      end

      -- 1. Wallpapers (release background textures & surfaces)
      if getSetting("disable_wallpaper") then
        setWallpapers(false)
      end

      -- 2. Desktop Widgets (stop rendering and compute)
      if getSetting("hide_widgets") then
        setDesktopWidget(false)
      end

      -- 3. Notifications Do Not Disturb
      if getSetting("enable_dnd") then
        setDnd(true)
      end

      -- 4. Clear currently visible notification popups
      if getSetting("clear_notifications") then
        clearActiveNotifications()
      end

      -- 5. Power Profile (UPower / powerprofilesctl governor)
      if getSetting("set_power_profile") then
        setPowerProfile("performance")
      end

      -- 6. Hide Status Bar (complete screen immersion)
      if getSetting("hide_bar") then
        setBarVisibility(false)
      end

      -- 7. Hide Dock
      if getSetting("hide_dock") then
        setDockVisibility(false)
      end

      -- 8. Disable OSD Popups (prevent game interruptions)
      if getSetting("disable_osd") then
        setOsdEnabled(false)
      end

      -- 9. Pause background media playback
      if getSetting("pause_media") then
        pauseMediaPlayback()
      end

      -- 10. Custom Shell Hooks (v4 parity)
      runHook(getSetting("hook_on_enter"))

      -- 11. Compositor Visual Effects (Blur, Animations, Shadows)
      local opts = {
        blur = getSetting("disable_blur"),
        animations = getSetting("disable_animations"),
        shadows = getSetting("disable_shadows"),
      }
      adapter.enable(opts)
    end)
  else
    activationEpoch = activationEpoch + 1
    local wasActive = isActive or isActivating
    isActive = false
    isActivating = false
    noctalia.state.set("performance", false)

    local snapshot = loadSnapshot()
    -- Idempotency check: if inactive and no snapshot exists, do not apply fallbacks
    if snapshot == nil and not wasActive then
      return
    end

    if snapshot ~= nil then
      -- 1. Wallpapers (restore background surfaces)
      if getSetting("disable_wallpaper") then
        setWallpapers(true)
      end

      -- 2. Desktop Widgets (restore only if previously enabled)
      if getSetting("hide_widgets") then
        if snapshot.desktop_widgets ~= false then
          setDesktopWidget(true)
        end
      end

      -- 3. Notifications Do Not Disturb (restore original state)
      if getSetting("enable_dnd") then
        local prevDnd = (snapshot.dnd == true)
        setDnd(prevDnd)
      end

      -- 5. Power Profile (restore recorded previous profile)
      if getSetting("set_power_profile") then
        local prevPower = snapshot.power_profile or "balanced"
        setPowerProfile(prevPower)
      end

      -- 6. Status Bar (restore only if previously visible)
      if getSetting("hide_bar") then
        if snapshot.bar_visible == true then
          setBarVisibility(true)
        end
      end

      -- 7. Dock (restore only if previously enabled)
      if getSetting("hide_dock") then
        if snapshot.dock ~= false then
          setDockVisibility(true)
        end
      end

      -- 8. OSD Popups (restore only if previously enabled)
      if getSetting("disable_osd") then
        if snapshot.osd ~= false then
          setOsdEnabled(true)
        end
      end

      -- 10. Custom Shell Hooks
      runHook(getSetting("hook_on_exit"))

      -- 11. Compositor Visual Effects (Blur, Animations, Shadows)
      local opts = {
        blur = getSetting("disable_blur"),
        animations = getSetting("disable_animations"),
        shadows = getSetting("disable_shadows"),
      }
      adapter.disable(opts)

      -- Cleanup recorded snapshot (retaining until active-to-inactive transition completes)
      clearSnapshot()
    else
      clearSnapshot()
    end
  end
end

return M
