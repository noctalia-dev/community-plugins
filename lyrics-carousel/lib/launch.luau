--!nonstrict
-- Shared launcher for the floating lyrics window.
--
-- The bar widget and the panel must open exactly the same window: placing
-- this logic here prevents the two entry points from drifting apart. The
-- previous window is stopped with the same `pkill -f` the panel used
-- before, matched on the window title the launch command sets.

local settings = require("./settings.luau")

local M = {}

local launching = false
local launchToken = 0

local ANCHORS = {
  ["top-left"] = true,
  ["top-center"] = true,
  ["top-right"] = true,
  ["left-center"] = true,
  ["center"] = true,
  ["right-center"] = true,
  ["bottom-left"] = true,
  ["bottom-center"] = true,
  ["bottom-right"] = true,
  ["custom"] = true,
}

-- Legacy aliases (including the old Spanish values) are kept so settings saved
-- by earlier versions keep resolving to the same anchor.
local ANCHOR_ALIASES = {
  ["topleft"] = "top-left",
  ["topcenter"] = "top-center",
  ["topright"] = "top-right",
  ["left"] = "left-center",
  ["leftcenter"] = "left-center",
  ["middle"] = "center",
  ["centre"] = "center",
  ["centro"] = "center",
  ["right"] = "right-center",
  ["rightcenter"] = "right-center",
  ["bottomleft"] = "bottom-left",
  ["bottomcenter"] = "bottom-center",
  ["bottomright"] = "bottom-right",
  ["top"] = "top-center",
  ["bottom"] = "bottom-center",
  ["arriba"] = "top-center",
  ["abajo"] = "bottom-center",
  ["izquierda"] = "left-center",
  ["derecha"] = "right-center",
}

local function normalizeAnchor(value)
  local key = tostring(value or ""):lower():gsub("%s+", "-"):gsub("_", "-"):gsub("%-+", "-")
  key = key:gsub("^%-", ""):gsub("%-$", "")
  if ANCHORS[key] then
    return key
  end
  return ANCHOR_ALIASES[key] or "center"
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function luaQuote(value)
  local escaped = tostring(value)
  escaped = escaped:gsub("\\", "\\\\")
  escaped = escaped:gsub('"', '\\"')
  escaped = escaped:gsub("\r", "\\r")
  escaped = escaped:gsub("\n", "\\n")
  return '"' .. escaped .. '"'
end

local function outputGeometry()
  local outputs = noctalia.outputs() or {}
  local chosen = nil
  for _, output in ipairs(outputs) do
    if output.focused then
      chosen = output
      break
    end
  end
  chosen = chosen or outputs[1]
  if chosen ~= nil then
    local width = tonumber(chosen.width) or 0
    local height = tonumber(chosen.height) or 0
    if width >= 320 and height >= 240 then
      return math.floor(width), math.floor(height)
    end
  end
  return 1920, 1080
end

local function anchorPosition(anchor, width, height, screenWidth, screenHeight)
  local margin = 16
  local x
  local y
  if anchor == "top-left" or anchor == "left-center" or anchor == "bottom-left" then
    x = margin
  elseif anchor == "top-right" or anchor == "right-center" or anchor == "bottom-right" then
    x = screenWidth - width - margin
  else
    x = math.floor((screenWidth - width) / 2)
  end
  if anchor == "top-left" or anchor == "top-center" or anchor == "top-right" then
    y = margin
  elseif anchor == "bottom-left" or anchor == "bottom-center" or anchor == "bottom-right" then
    y = screenHeight - height - margin
  else
    y = math.floor((screenHeight - height) / 2)
  end
  return x, y
end

local function dispatch(expression, callback)
  noctalia.runAsync({ "hyprctl", "dispatch", expression }, function(result)
    callback(result ~= nil and result.exitCode == 0)
  end)
end

local function loadSaved(callback)
  local dir = noctalia.pluginDir()
  if dir == nil or dir == "" then
    callback()
    return
  end
  noctalia.runAsync(
    { "python3", dir .. "/bin/set-setting.py", "read" },
    function(result)
      if result ~= nil and result.exitCode == 0 then
        settings.useSaved(result.stdout)
      end
      callback()
    end
  )
end

local function start(options, valueOf, token)
  local family = tostring(valueOf("font_family") or settings.DEFAULTS.font_family)
  local size = math.floor(tonumber(valueOf("font_size")) or settings.DEFAULTS.font_size)
  local screenWidth, screenHeight = outputGeometry()
  local width = math.min(
    math.floor(tonumber(valueOf("width")) or settings.DEFAULTS.width),
    screenWidth
  )
  local height = math.min(
    math.floor(tonumber(valueOf("height")) or settings.DEFAULTS.height),
    screenHeight
  )
  local anchor = normalizeAnchor(valueOf("anchor"))
  local x, y
  if anchor == "custom" then
    x = math.floor(tonumber(valueOf("custom_x")) or 0)
    y = math.floor(tonumber(valueOf("custom_y")) or 0)
  else
    x, y = anchorPosition(anchor, width, height, screenWidth, screenHeight)
  end

  local pluginDir = noctalia.pluginDir()
  if pluginDir == nil or pluginDir == "" then
    if options.onError ~= nil then
      options.onError("plugin_dir")
    end
    return false
  end

  local script = "python3 " .. pluginDir .. "/bin/lyrics-carousel"
  local command = string.format(
    "kitty -o confirm_os_window_close=0 -o font_family=%s -o font_size=%d --class noctalia-lyrics-carousel --title lyrics -e sh -lc %s",
    shellQuote(family),
    size,
    shellQuote(script)
  )
  local rules = string.format(
    "{ float = true, move = { %d, %d }, size = { %d, %d } }",
    x,
    y,
    width,
    height
  )
  local expression = string.format("hl.dsp.exec_cmd(%s, %s)", luaQuote(command), rules)

  local function finish(success)
    -- A newer launch may have started while this one was dispatching: do
    -- not clear its state or report an error that belongs to the old one.
    if token ~= launchToken then
      return
    end
    launching = false
    if options.onState ~= nil then
      options.onState(false)
    end
    if not success and options.onError ~= nil then
      options.onError("launch_failed")
    end
  end

  -- Restart the previous window so it picks up the new typography, and
  -- give it one frame to restore the terminal before creating the new one.
  noctalia.runAsync(
    { "pkill", "-f", "noctalia-lyrics-carousel --title lyrics" },
    function()
      noctalia.runAsync({ "sleep", "0.25" }, function()
        dispatch(expression, finish)
      end)
    end
  )
  return true
end

--- Opens the lyrics window.
---
--- `options.valueOf` lets the panel use its not-yet-flushed local values.
--- Without it, the overrides and the saved settings are read first, which is
--- what the bar widget needs.
function M.launch(options)
  options = options or {}
  if launching then
    return false
  end
  launching = true
  launchToken = launchToken + 1
  local token = launchToken
  if options.onState ~= nil then
    options.onState(true)
  end
  -- Watchdog: if the dispatch callback never fires, the launcher would stay
  -- busy and the next click would do nothing.
  noctalia.runAsync({ "sleep", "6" }, function()
    if token == launchToken and launching then
      launching = false
    end
  end)

  local function continue()
    settings.refresh()
    local valueOf = options.valueOf or settings.value
    local started = start(options, valueOf, token)
    if not started then
      launching = false
      if options.onState ~= nil then
        options.onState(false)
      end
    end
  end

  if options.valueOf ~= nil then
    continue()
  else
    loadSaved(continue)
  end
  return true
end

return M
