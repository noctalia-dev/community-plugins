--!nonstrict
-- Lyrics carousel panel: opens the floating window and offers
-- quick toggles.
--
-- Settings live in Noctalia's settings.toml
-- (`plugin_settings."faminec/lyrics-carousel"`), which is the same source the
-- plugin settings page uses. The panel writes there through a Python helper
-- and reloads the configuration, so both places always agree. The Python
-- script reads that same file, so changes apply live to the window that is
-- already open.
--
-- Every call to the Noctalia API is wrapped in `safe`: if one of them fails
-- (permissions, full disk, an API that does not exist) the panel reports it
-- instead of blowing up the script.

local settingsLib = require("./lib/settings.luau")

-- Default values and the list of keys live in lib/settings.luau
-- so the panel, the widget and the script share a single source.

-- kitty only accepts monospaced fonts; the rest are only valid in image mode.
local FONT_CHOICES = {
  "Departure Mono",
  "Press Start 2P",
  "Space Mono",
  "NType 82 Mono",
  "Lettera Mono LL",
  "IBM Plex Mono",
  "Nothing Font (5x7)",
  "Ndot 57",
  "Ndot 55",
  "Space Grotesk",
  "NType 82",
}

local ACCENT_CHOICES = { "primary", "green", "yellow", "blue", "magenta", "cyan", "red", "custom" }

-- Full keys: the resource validator needs to see them literally, not
-- concatenated ("accent_" .. name), or it flags them as nonexistent.
local ACCENT_KEYS = {
  primary = "accent_primary",
  green = "accent_green",
  yellow = "accent_yellow",
  blue = "accent_blue",
  magenta = "accent_magenta",
  cyan = "accent_cyan",
  red = "accent_red",
  custom = "accent_custom",
}

-- The functions call each other (a setting launches the window, the window
-- notifies the panel, the panel redraws). In Luau a `local function` only
-- exists from its declaration onwards: without these declarations, the
-- calls above would resolve against a global with no value (nil).
local render
local launch
local applyGeometry
local closePanel

local settings = {}
local trackTitle = ""
local trackArtist = ""
local launching = false
local lastError = ""
-- The font selector shows the list until the user picks
-- "Other". It is interface state, not a setting: nothing is written.
local fontCustom = nil
-- An async callback (playerctl, the helper) can arrive after the panel has
-- closed. Without this flag the callback would redraw a dead tree.
local panelClosed = false

local function tr(key, args)
  local ok, value = pcall(noctalia.tr, key, args)
  if ok and type(value) == "string" then
    return value
  end
  return key
end

-- --------------------------------------------------------- Protected API --

-- Wraps a call to the Noctalia API: if it fails, it reports and carries on.
local function safe(label, fn, ...)
  local args = { ... }
  local ok, result = pcall(fn, table.unpack(args))
  if not ok then
    lastError = tr("write_failed")
    noctalia.log("lyrics-carousel: " .. label .. ": " .. tostring(result))
    return nil
  end
  return result
end

-- Closes the panel without blowing up if the API fails.
closePanel = function()
  local ok, error = pcall(function()
    panel.close()
  end)
  if not ok then
    safe("log", noctalia.log, "lyrics-carousel: close: " .. tostring(error))
  end
end

local function reportError(message)
  lastError = tostring(message or tr("write_failed"))
  safe("log", noctalia.log, "lyrics-carousel: " .. lastError)
end

local function runAsync(argv, callback)
  local ok, started = pcall(noctalia.runAsync, argv, callback)
  if not ok then
    reportError(started)
    return false
  end
  if started == false then
    reportError(tr("write_failed"))
    return false
  end
  return true
end

-- ------------------------------------------------------------- Settings

-- Empties the local changes: from here on the real configuration wins.
local function refreshSettings()
  settings = {}
  settingsLib.refresh()
  -- The manifest only declares the bar icon: the panel manages all the other
  -- settings. `noctalia.getConfig` does not return them, so the real value is
  -- read from settings.toml with the helper (the same source the script
  -- reads). It is asynchronous: once it arrives, the panel redraws with the
  -- right value instead of the default one.
  local dir = noctalia.pluginDir()
  if dir == nil or dir == "" then
    return
  end
  runAsync({ "python3", dir .. "/bin/set-setting.py", "read" }, function(result)
    if result == nil or result.exitCode ~= 0 then
      return
    end
    settingsLib.useSaved(result.stdout)
    if not panelClosed then
      render()
    end
  end)
end

local function valueOf(key)
  -- What the panel just changed takes priority; otherwise, the effective
  -- value (overrides + Noctalia configuration).
  local value = settings[key]
  if value ~= nil then
    return value
  end
  return settingsLib.value(key)
end

-- Noctalia hands control values over as strings: a toggle sends
-- "true" / "false" (not a boolean). The normalization lives in
-- lib/settings.luau so the panel and the widget share it.
local truthy = settingsLib.truthy

local function boolOf(key)
  return truthy(valueOf(key))
end

local function numberOf(key)
  return tonumber(valueOf(key)) or settingsLib.DEFAULTS[key]
end

-- Limits for the numeric settings (lib/settings.luau, LIMITS).
-- The script clamps whatever reaches it; the panel cannot offer more than
-- the script accepts, or the user would see a value that does not apply.
-- Settings that change the geometry of the open window: touching them means
-- moving or resizing it, saving the value is not enough.
local GEOMETRY_KEYS = {
  width = true,
  height = true,
  anchor = true,
  custom_x = true,
  custom_y = true,
}

local LIMITS = settingsLib.LIMITS

local function clampSetting(key, value)
  -- Clamping and formatting: both come from the shared library, so the
  -- panel and the widget apply the same rules to the same setting.
  value = settingsLib.clamp(key, value)
  if value == nil then
    return nil
  end
  return settingsLib.validate(key, value)
end

-- Writes a setting into the plugin override layer.
--
-- Nothing is written to settings.toml while the panel is open: Noctalia
-- watches that file and reloads the configuration when it changes, which
-- closes the panel the user is looking at and discards the following
-- clicks. The overrides are flushed into settings.toml on close (see onClose).
local pendingWrites = 0

local function writeSetting(key, value)
  pendingWrites = pendingWrites + 1
  settingsLib.write(key, value, function(ok)
    pendingWrites = pendingWrites - 1
    if not ok then
      reportError(tr("write_failed"))
      render()
    end
  end)
end

local function setSetting(key, value, options)
  options = options or {}
  value = clampSetting(key, value)
  if value == nil then
    return
  end
  settings[key] = value
  -- Written right away: the widget applies it immediately (it reads the
  -- overrides every 1.2 s) and the panel stays open for further changes.
  writeSetting(key, value)
  if options.relaunch then
    launch()
  end
  if options.geometry then
    applyGeometry()
  end
  render()
end

local function toggleKey(key)
  setSetting(key, not boolOf(key))
end

-- ---------------------------------------------------------------- launch

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

local function outputGeometry()
  local outputs = safe("outputs", noctalia.outputs) or {}
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
  local started = runAsync({ "hyprctl", "dispatch", expression }, function(result)
    if result == nil or result.exitCode ~= 0 then
      local detail = ""
      if type(result) == "table" then
        detail = tostring(result.stderr or result.stdout or "")
      end
      safe("log", noctalia.log, "lyrics-carousel: " .. detail)
    end
    if callback ~= nil then
      callback(result ~= nil and result.exitCode == 0)
    end
  end)
  if not started and callback ~= nil then
    callback(false)
  end
end

-- Moves and resizes the existing window without recreating it.
applyGeometry = function()
  local screenWidth, screenHeight = outputGeometry()
  -- The window can never be larger than the monitor: Hyprland accepts the
  -- size but leaves the window clipped and impossible to move.
  local width = math.min(math.floor(numberOf("width")), screenWidth)
  local height = math.min(math.floor(numberOf("height")), screenHeight)
  local anchor = normalizeAnchor(valueOf("anchor"))
  local x, y
  if anchor == "custom" then
    x = math.floor(numberOf("custom_x"))
    y = math.floor(numberOf("custom_y"))
  else
    x, y = anchorPosition(anchor, width, height, screenWidth, screenHeight)
  end
  local window = "class:^noctalia-lyrics-carousel$"
  -- keep_aspect_ratio = false is essential: without that flag the
  -- Hyprland 0.57 dispatcher keeps the aspect ratio and discards the
  -- size change (the window keeps the size it already had).
  local resize = string.format(
    'hl.dsp.window.resize({ x = %d, y = %d, window = "%s", keep_aspect_ratio = false })',
    width,
    height,
    window
  )
  local move = string.format(
    'hl.dsp.window.move({ x = %d, y = %d, window = "%s" })', x, y, window
  )
  dispatch(resize, function()
    dispatch(move)
  end)
end

launch = function()
  if launching then
    return
  end
  launching = true
  -- Watchdog: if the window never gets created, the button does not hang.
  runAsync({ "sleep", "6" }, function()
    if launching then
      launching = false
      render()
    end
  end)
  refreshSettings()
  local family = tostring(valueOf("font_family"))
  local size = math.floor(numberOf("font_size"))
  local screenWidth, screenHeight = outputGeometry()
  local width = math.min(math.floor(numberOf("width")), screenWidth)
  local height = math.min(math.floor(numberOf("height")), screenHeight)
  local anchor = normalizeAnchor(valueOf("anchor"))

  local x, y
  if anchor == "custom" then
    x = math.floor(numberOf("custom_x"))
    y = math.floor(numberOf("custom_y"))
  else
    x, y = anchorPosition(anchor, width, height, screenWidth, screenHeight)
  end

  -- The script is launched by absolute path (and with python3): relying on
  -- PATH would require a symlink in ~/.local/bin that the plugin does not
  -- create, and this way the executable bit is not needed either.
  local script = "lyrics-carousel"
  local pluginDir = noctalia.pluginDir()
  if pluginDir ~= nil and pluginDir ~= "" then
    script = "python3 " .. pluginDir .. "/bin/lyrics-carousel"
  end
  -- The window is created with the pixel size that the exec_cmd rules
  -- dictate; inside kitty the script reads the real terminal size
  -- (kitty publishes it through TIOCGWINSZ), so nothing has to be passed
  -- through environment variables.
  local command = string.format(
    "kitty -o confirm_os_window_close=0 -o font_family=%s -o font_size=%d --class noctalia-lyrics-carousel --title lyrics -e sh -lc %s",
    shellQuote(family),
    size,
    shellQuote(script)
  )
  local rules = string.format(
    "{ float = true, move = { %d, %d }, size = { %d, %d } }",
    x, y, width, height
  )
  local expression = string.format("hl.dsp.exec_cmd(%s, %s)", luaQuote(command), rules)

  -- Restarts the previous window so it picks up the new typography.
  local started = runAsync(
    { "pkill", "-f", "noctalia-lyrics-carousel --title lyrics" },
    function()
      local ok = runAsync({ "sleep", "0.25" }, function()
        dispatch(expression, function(success)
          launching = false
          if not success then
            safe("notifyError", noctalia.notifyError, tr("title"), tr("launch_failed"))
          end
        end)
      end)
      if not ok then
        launching = false
        dispatch(expression, function(success)
          if not success then
            safe("notifyError", noctalia.notifyError, tr("title"), tr("launch_failed"))
          end
        end)
        render()
      end
    end
  )
  if not started then
    launching = false
    render()
  end
end

-- ------------------------------------------------------------- track

local function readTrack()
  local format = "{{playerInstance}}\t{{status}}\t{{title}}\t{{artist}}"
  runAsync({ "playerctl", "-a", "metadata", "--format", format }, function(result)
    if result == nil or result.exitCode ~= 0 or result.stdout == nil or result.stdout == "" then
      trackTitle = ""
      trackArtist = ""
      render()
      return
    end
    local playing = nil
    local fallback = nil
    for line in result.stdout:gmatch("[^\n]+") do
      local parts = {}
      for part in line:gmatch("[^\t]+") do
        parts[#parts + 1] = part
      end
      if #parts >= 4 then
        local entry = { title = parts[3], artist = parts[4] }
        if parts[2] == "Playing" and playing == nil then
          playing = entry
        elseif fallback == nil and entry.title ~= "" then
          fallback = entry
        end
      end
    end
    local chosen = playing or fallback
    trackTitle = chosen and chosen.title or ""
    trackArtist = chosen and chosen.artist or ""
    render()
  end)
end

-- -------------------------------------------------------------------- UI

local function toggleRow(key, label, glyph)
  return ui.row({ key = "row-" .. key, align = "center", gap = 10, paddingH = 4, padding = 4 }, {
    ui.glyph({ name = glyph, size = 14, color = "on_surface_variant" }),
    ui.label({ text = label, fontSize = 12, color = "on_surface", flexGrow = 1 }),
    ui.toggle({
      key = "toggle-" .. key,
      checked = boolOf(key),
      onChange = function(value)
        setSetting(key, truthy(value))
      end,
    }),
  })
end

local function chipRow(items)
  local chips = {}
  for _, item in ipairs(items) do
    table.insert(chips, ui.button({
      key = item.key,
      text = item.text,
      variant = item.selected and "secondary" or "ghost",
      fontSize = 11,
      onClick = item.onClick,
    }))
  end
  return ui.row({ gap = 6 }, chips)
end

-- Every font the panel offers, in the order they are shown.
local function fontNames()
  local names = {}
  for _, name in ipairs(FONT_CHOICES) do
    table.insert(names, name)
  end
  return names
end

local function fontListed(name)
  for _, candidate in ipairs(fontNames()) do
    if candidate == name then
      return true
    end
  end
  return false
end

local function fontIndex(name)
  for index, candidate in ipairs(fontNames()) do
    if candidate == name then
      return index - 1
    end
  end
  return nil
end

-- A single font selector: the list of available fonts plus a last option
-- to type one that is not in the list. There used to be two chip lists and
-- an always-visible field, and it was never clear which of the three won.
local function fontSelector()
  local names = fontNames()
  local current = tostring(valueOf("font_family"))
  local custom = fontCustom == true or not fontListed(current)
  local options = {}
  for index, name in ipairs(names) do
    options[index] = name
  end
  table.insert(options, tr("font_custom"))
  local selected = #names
  if not custom then
    selected = fontIndex(current) or 0
  end
  return ui.select({
    key = "font-select",
    options = options,
    selectedIndex = selected,
    controlSize = "sm",
    onChange = function(value)
      local index = tonumber(value) or 0
      if index >= #names then
        fontCustom = true
        render()
        return
      end
      fontCustom = false
      setSetting("font_family", names[index + 1])
    end,
  })
end

local function accentChips()
  local current = tostring(valueOf("accent"))
  local rows = {}
  local row = {}
  for index, name in ipairs(ACCENT_CHOICES) do
    table.insert(row, {
      key = "accent-" .. name,
      text = tr(ACCENT_KEYS[name]),
      selected = name == current,
      onClick = function()
        setSetting("accent", name)
      end,
    })
    -- Four per row: with all eight on a single row the names get
    -- cramped and the last one falls outside the panel.
    if index % 4 == 0 then
      table.insert(rows, chipRow(row))
      row = {}
    end
  end
  if #row > 0 then
    table.insert(rows, chipRow(row))
  end
  return ui.column({ gap = 4 }, rows)
end

-- The grid represents the screen: three rows of three buttons, in the
-- same order the user sees the positions in.
local ANCHOR_GRID = {
  { "top-left", "top-center", "top-right" },
  { "left-center", "center", "right-center" },
  { "bottom-left", "bottom-center", "bottom-right" },
}

local ANCHOR_KEYS = {
  ["top-left"] = "anchor_top_left",
  ["top-center"] = "anchor_top_center",
  ["top-right"] = "anchor_top_right",
  ["left-center"] = "anchor_left_center",
  center = "anchor_center",
  ["right-center"] = "anchor_right_center",
  ["bottom-left"] = "anchor_bottom_left",
  ["bottom-center"] = "anchor_bottom_center",
  ["bottom-right"] = "anchor_bottom_right",
  custom = "anchor_custom",
}

-- Nine buttons carrying the name of each position inside. They are pressed
-- directly: there is no dropdown to open to see where each one lands. The
-- custom position is the tenth button, below the grid.
local function anchorButtons()
  local current = normalizeAnchor(valueOf("anchor"))
  local rows = {}
  for _, names in ipairs(ANCHOR_GRID) do
    local buttons = {}
    for _, name in ipairs(names) do
      table.insert(buttons, ui.button({
        key = "anchor-" .. name,
        text = tr(ANCHOR_KEYS[name]),
        variant = name == current and "secondary" or "ghost",
        fontSize = 10,
        flexGrow = 1,
        onClick = function()
          setSetting("anchor", name, { geometry = true })
        end,
      }))
    end
    table.insert(rows, ui.row({ gap = 6 }, buttons))
  end
  table.insert(rows, ui.button({
    key = "anchor-custom",
    text = tr("anchor_custom"),
    variant = current == "custom" and "secondary" or "ghost",
    fontSize = 10,
    onClick = function()
      setSetting("anchor", "custom", { geometry = true })
    end,
  }))
  return ui.column({ gap = 6, align = "stretch" }, rows)
end

-- "-" and "+" buttons for a numeric value.
--
-- Hover changes nothing: the setting used to change when the mouse passed
-- over it, and a width that shrank on its own was a bug.
local function sizeStepper(key, min, max, step)
  local current = math.floor(numberOf(key))
  local function bump(delta)
    local newValue = math.floor(numberOf(key)) + delta
    if newValue < min then
      newValue = min
    elseif newValue > max then
      newValue = max
    end
    if newValue == math.floor(numberOf(key)) then
      return
    end
    setSetting(key, newValue, { geometry = true })
  end
  return ui.row({ align = "center", gap = 6 }, {
    ui.button({
      key = key .. "-dec",
      text = "-",
      variant = "ghost",
      fontSize = 12,
      onClick = function()
        bump(-step)
      end,
    }),
    ui.label({ text = tostring(current), fontSize = 12, color = "on_surface", flexGrow = 1 }),
    ui.button({
      key = key .. "-inc",
      text = "+",
      variant = "ghost",
      fontSize = 12,
      onClick = function()
        bump(step)
      end,
    }),
  })
end

-- Slider with its label and the value on the right. The limits are the
-- panel's: it cannot offer more than the script accepts.
local function sliderRow(key, label, min, max, step, integer)
  -- The displayed value is clamped: if the setting is out of range (for
  -- instance hand-written into settings.toml), the slider has to show the
  -- real value, not one the script is going to discard.
  local current = clampSetting(key, numberOf(key))
  if current == nil then
    current = min
  end
  local fmt = integer and "%d" or "%.2f"
  return ui.column({ gap = 4 }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = label, fontSize = 11, color = "on_surface_variant", flexGrow = 1 }),
      ui.label({ text = string.format(fmt, current), fontSize = 11, color = "on_surface" }),
    }),
    ui.slider({
      key = key,
      min = min,
      max = max,
      step = step,
      value = current,
      flexGrow = 1,
      onChange = function(value)
        local number = tonumber(value)
        if number == nil then
          return
        end
        if integer then
          number = math.floor(number)
        end
        setSetting(key, number)
      end,
    }),
  })
end

-- Text field with validation. Only values that match the pattern are
-- saved: a half-written color or a glyph name with uppercase letters would
-- leave the window without a color or without an icon.
local function inputRow(key, label, placeholder)
  -- The pattern for each field lives in lib/settings.luau (PATTERNS): the
  -- widget uses it through its IPC and both have to apply the same one.
  local pattern = settingsLib.PATTERNS[key]
  return ui.column({ gap = 4 }, {
    ui.label({ text = label, fontSize = 11, color = "on_surface_variant" }),
    ui.input({
      key = key,
      value = tostring(valueOf(key)),
      placeholder = placeholder,
      controlSize = "sm",
      onChange = function(value)
        if type(value) == "string" and (pattern == nil or value:match(pattern)) then
          setSetting(key, value)
        end
      end,
    }),
  })
end

render = function()
  if panelClosed then
    return
  end
  local direction = tostring(valueOf("direction"))
  local accent = tostring(valueOf("accent"))
  local currentFont = tostring(valueOf("font_family"))
  local customFont = fontCustom == true or not fontListed(currentFont)
  local subtitle = tr("subtitle")
  if trackTitle ~= "" then
    subtitle = trackTitle
    if trackArtist ~= "" then
      subtitle = subtitle .. " — " .. trackArtist
    end
  end

  local rows = {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "music", size = 18, color = "primary" }),
      ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
      ui.button({
        key = "open-settings",
        glyph = "settings",
        variant = "ghost",
        tooltip = tr("open_settings"),
        onClick = function()
          safe("openSettings", noctalia.openSettings)
        end,
      }),
      ui.button({
        key = "close-panel",
        -- "x" is the real name in the Tabler set; "close" also works
        -- (a Noctalia alias) but the validator does not know it.
        glyph = "x",
        variant = "ghost",
        tooltip = tr("close"),
        onClick = function()
          closePanel()
        end,
      }),
    }),
    ui.label({ text = subtitle, fontSize = 11, color = "on_surface_variant" }),
    ui.button({
      key = "launch",
      text = tr("launch"),
      variant = "primary",
      onClick = launch,
    }),
    ui.separator({ thickness = 1, spacing = 6 }),

    -- Display -------------------------------------------------------
    ui.label({ text = tr("section_display"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
    ui.row({ align = "center", gap = 10, paddingH = 4, padding = 4 }, {
      ui.glyph({ name = "arrows-vertical", size = 14, color = "on_surface_variant" }),
      ui.label({ text = tr("direction"), fontSize = 12, color = "on_surface", flexGrow = 1 }),
      ui.button({
        key = "dir-down",
        text = tr("down"),
        variant = direction == "down" and "secondary" or "ghost",
        fontSize = 11,
        onClick = function()
          setSetting("direction", "down")
        end,
      }),
      ui.button({
        key = "dir-up",
        text = tr("up"),
        variant = direction == "up" and "secondary" or "ghost",
        fontSize = 11,
        onClick = function()
          setSetting("direction", "up")
        end,
      }),
    }),
    -- What is drawn inside the window --------------------------------
    toggleRow("header", tr("header"), "heading"),
    toggleRow("marker", tr("marker"), "chevron-right"),
    toggleRow("karaoke", tr("karaoke"), "sun"),
    toggleRow("ghost", tr("ghost"), "sparkles"),
    toggleRow("footer", tr("footer"), "clock"),
    toggleRow("hints", tr("hints"), "keyboard"),

    -- Lyrics --------------------------------------------------------------
    ui.separator({ thickness = 1, spacing = 6 }),
    ui.label({ text = tr("section_lyrics"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
    sliderRow("active_scale", tr("active_scale"), 1.0, 2.5, 0.05, false),
    ui.row({ gap = 10 }, {
      ui.column({ flexGrow = 1, gap = 4 }, {
        sliderRow("visible_above", tr("visible_above"), 0, 20, 1, true),
      }),
      ui.column({ flexGrow = 1, gap = 4 }, {
        sliderRow("visible_below", tr("visible_below"), 0, 20, 1, true),
      }),
    }),
    sliderRow("spacing", tr("spacing"), 1, 6, 1, true),
    sliderRow("offset_ms", tr("offset_ms"), -3000, 3000, 10, true),

    -- Color --------------------------------------------------------------
    ui.separator({ thickness = 1, spacing = 6 }),
    ui.label({ text = tr("section_color"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
    ui.column({ gap = 4 }, {
      ui.label({ text = tr("accent"), fontSize = 11, color = "on_surface_variant" }),
      accentChips(),
    }),
    (function()
      if accent == "custom" then
        return inputRow("custom_color", tr("custom_color"), tr("color_placeholder"))
      end
      return ui.column({})
    end)(),

    -- Typography ---------------------------------------------------------
    ui.separator({ thickness = 1, spacing = 6 }),
    ui.label({ text = tr("section_font"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
    ui.label({ text = tr("font_family"), fontSize = 11, color = "on_surface_variant" }),
    fontSelector(),
    ui.label({ text = tr("font_hint"), fontSize = 10, color = "on_surface_variant" }),
    (function()
      if customFont then
        return inputRow("font_family", tr("font_custom_name"), tr("font_placeholder"))
      end
      return ui.column({})
    end)(),
    sliderRow("font_size", tr("font_size"), 6, 96, 1, true),

    -- Window ------------------------------------------------------------
    ui.separator({ thickness = 1, spacing = 6 }),
    ui.label({ text = tr("section_window"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
    ui.label({ text = tr("anchor"), fontSize = 11, color = "on_surface_variant" }),
    anchorButtons(),
    (function()
      if normalizeAnchor(valueOf("anchor")) == "custom" then
        local function coordinateInput(key, label)
          return ui.column({ flexGrow = 1, gap = 4 }, {
            ui.label({ text = label, fontSize = 10, color = "on_surface_variant" }),
            ui.input({
              -- The text field is not controlled from the tree: it needs a
              -- stable key so it keeps what the user types.
              key = key,
              value = tostring(math.floor(numberOf(key))),
              controlSize = "sm",
              onChange = function(v)
                local n = tonumber(v)
                if n == nil then
                  return
                end
                local value = math.floor(n)
                if value == math.floor(numberOf(key)) then
                  return
                end
                setSetting(key, value, { geometry = true })
              end,
            }),
          })
        end
        return ui.row({ gap = 10 }, {
          coordinateInput("custom_x", tr("custom_x")),
          coordinateInput("custom_y", tr("custom_y")),
        })
      end
      return ui.column({})
    end)(),
    ui.row({ gap = 10 }, {
      ui.column({ flexGrow = 1, gap = 4 }, {
        ui.label({ text = tr("width"), fontSize = 11, color = "on_surface_variant" }),
        -- The limits are this panel's: the script
        -- clamps whatever reaches it, so the panel cannot offer more.
        sizeStepper("width", 400, 3840, 100),
      }),
      ui.column({ flexGrow = 1, gap = 4 }, {
        ui.label({ text = tr("height"), fontSize = 11, color = "on_surface_variant" }),
        sizeStepper("height", 200, 2160, 50),
      }),
    }),
  }

  if lastError ~= "" then
    table.insert(rows, ui.label({ text = lastError, fontSize = 10, color = "error" }))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 8, align = "stretch" }, {
    ui.scroll({ flexGrow = 1, gap = 8 }, rows),
  }))
end

function onOpen()
  panelClosed = false
  -- Every open works out again whether the current font is in the list:
  -- that way a hand-picked font does not leave the field open forever.
  fontCustom = nil
  refreshSettings()
  readTrack()
  render()
end

-- Flushes the overrides into settings.toml: that way the plugin settings
-- page and the panel show the same thing. It waits for the writes that were
-- in flight so the last change is not lost.
local function mergeOverrides(attempts)
  if pendingWrites > 0 and (attempts or 0) < 20 then
    runAsync({ "sleep", "0.1" }, function()
      mergeOverrides((attempts or 0) + 1)
    end)
    return
  end
  settingsLib.merge(function(ok)
    refreshSettings()
    if not ok then
      -- The change stays in the override layer: if the user does not find
      -- out, they think it was saved and lose it on the next restart.
      reportError(tr("write_failed"))
      safe("notifyError", noctalia.notifyError, tr("title"), tr("write_failed"))
    end
  end)
end

function onClose()
  -- The reload that Noctalia triggers no longer gets in the way: it is closing.
  panelClosed = true
  mergeOverrides(0)
end

function onConfigChanged()
  refreshSettings()
  render()
end

function onIpc(event, payload)
  if event == "launch" then
    launch()
  elseif event == "toggle" then
    -- Toggles a boolean setting: toggle marker
    if type(payload) == "string" and settingsLib.BOOL_KEYS[payload] then
      toggleKey(payload)
    end
  elseif event == "set" then
    -- Sets a setting: "set font_size=26 int" or "set font_size 26 int"
    local key, value = settingsLib.parse(payload)
    if key ~= nil then
      -- setSetting clamps the value to the panel limits and refreshes
      -- the view: writing `settings` directly would skip that clamping.
      setSetting(key, value, { geometry = GEOMETRY_KEYS[key] == true })
    end
  elseif event == "refresh" then
    refreshSettings()
    readTrack()
    render()
  end
end

refreshSettings()
