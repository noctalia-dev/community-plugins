--!nonstrict
-- Lyrics Carousel plugin settings shared by the panel and the widget.
--
-- Changes are stored first in an overrides layer (a small JSON file that
-- Noctalia does not watch) and are flushed into the settings.toml when the
-- panel closes. Reason: writing the settings.toml makes Noctalia reload the
-- configuration, which closes the panel the user is looking at and drops
-- the following clicks.

local M = {}

local PLUGIN_ID = "faminec/lyrics-carousel"

local DEFAULTS = {
  font_family = "Departure Mono",
  font_size = 22,
  direction = "down",
  marker = false,
  karaoke = true,
  footer = false,
  hints = false,
  header = false,
  spacing = 2,
  ghost = true,
  offset_ms = 0,
  width = 1200,
  height = 820,
  anchor = "center",
  custom_x = 100,
  custom_y = 100,
  accent = "primary",
  custom_color = "#e46767",
  active_scale = 1.35,
  visible_above = 6,
  visible_below = 6,
  glyph = "music",
  translate_lyrics = false,
}

local BOOL_KEYS = {
  marker = true, karaoke = true, footer = true,
  hints = true, header = true, ghost = true,
}
local INT_KEYS = {
  font_size = true, spacing = true, offset_ms = true,
  width = true, height = true, visible_above = true, visible_below = true,
  custom_x = true, custom_y = true,
}
local FLOAT_KEYS = { active_scale = true }

M.BOOL_KEYS = BOOL_KEYS
M.INT_KEYS = INT_KEYS
M.FLOAT_KEYS = FLOAT_KEYS
M.DEFAULTS = DEFAULTS

--- Ranges (min, max) for the numeric settings.
---
--- The manifest only declares the bar icon, so these ranges are no longer
--- duplicated in two places: the panel applies them before writing and the
--- script applies them when reading. Both copies have to match (the
--- autotest checks this): if the panel let through a value that the script
--- discards, the user would see a number that is not applied.
local LIMITS = {
  font_size = { 6, 96 },
  spacing = { 1, 6 },
  offset_ms = { -3000, 3000 },
  width = { 400, 3840 },
  height = { 200, 2160 },
  custom_x = { 0, 10000 },
  custom_y = { 0, 10000 },
  visible_above = { 0, 20 },
  visible_below = { 0, 20 },
  active_scale = { 1.0, 2.5 },
}

M.LIMITS = LIMITS

--- Patterns for the free-text settings.
---
--- The glyph is a Material Symbols icon name and the color is a
--- hexadecimal value: if anything else is stored, the bar is left without
--- an icon or the window without a color. The patterns live here and not in
--- the panel so that both entry points (panel and widget) apply the same
--- ones: the widget IPC can also write these settings.
local PATTERNS = {
  glyph = "^[a-z0-9-]+$",
  custom_color = "^#%x%x%x%x%x%x$",
  -- The font is free text, but an empty one would leave the window without
  -- typography: the panel field and the widget IPC have to reject it alike. A
  -- line break is not valid either: the font is passed to the kitty command.
  font_family = "^[^\n]+$",
}

M.PATTERNS = PATTERNS

--- Validates the format of a free-text setting.
---
--- Returns the value if it matches the pattern and nil if it does not.
--- Settings without a pattern (or without a limit) are returned as they are.
function M.validate(key, value)
  local pattern = PATTERNS[key]
  if pattern == nil then
    return value
  end
  if type(value) ~= "string" or value:match(pattern) == nil then
    return nil
  end
  return value
end

--- Clamps a value to the limits of its setting.
---
--- It lives here and not in the panel so that both entry points (panel and
--- widget) clamp the same way: if each one did it on its own, the widget
--- would let you save a 500 in a field that the panel limits to 96.
function M.clamp(key, value)
  local limit = LIMITS[key]
  if limit == nil then
    return value
  end
  local number = tonumber(value)
  if number == nil then
    return nil
  end
  if number < limit[1] then
    number = limit[1]
  elseif number > limit[2] then
    number = limit[2]
  end
  if INT_KEYS[key] then
    number = math.floor(number)
  end
  return number
end

--- Normalizes a value to a boolean.
---
--- Noctalia does not always hand over the toggles as booleans: the `ui.toggle`
--- control passes the value as the string "true" or "false". Comparing with
--- `== true` would make an enabled toggle read as disabled.
---
--- It lives here and not in the panel so that the panel and the widget read
--- the values alike: if each one normalized on its own, they would differ.
function M.truthy(value)
  if type(value) == "boolean" then
    return value
  end
  if type(value) == "number" then
    return value ~= 0
  end
  if type(value) == "string" then
    local text = value:lower():gsub("%s+", "")
    return text == "true" or text == "1" or text == "yes" or text == "on"
  end
  return false
end

local function overridesPath()
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return nil
  end
  return dir .. "/overrides.json"
end

local function readOverrides()
  local path = overridesPath()
  if path == nil then
    return {}
  end
  local raw = noctalia.readFile(path)
  if raw == nil or raw == "" then
    return {}
  end
  local ok, data = pcall(noctalia.json.decode, raw)
  if not ok or type(data) ~= "table" then
    return {}
  end
  return data
end

-- The panel queries dozens of values per render: the overrides file is
-- cached so that it is not read on every query. The cache is invalidated
-- on write (M.refresh) and has a short expiry in case the change comes
-- from outside. Careful: os.clock() is CPU time, not wall-clock time, so
-- os.time() is used for the expiry.
local cached = {}
local cachedAt = 0
local CACHE_SECONDS = 2

function M.overrides()
  local now = os.time()
  if cachedAt ~= 0 and (now - cachedAt) < CACHE_SECONDS then
    return cached
  end
  cached = readOverrides()
  cachedAt = now
  return cached
end

--- Forces a re-read of the overrides (after writing).
function M.refresh()
  cachedAt = 0
  cached = {}
end

--- Effective value of a setting: overrides > configuration > saved > default.
function M.value(key)
  local override = M.overrides()[key]
  if override ~= nil then
    return override
  end
  local value = noctalia.getConfig(key)
  if value ~= nil then
    return value
  end
  -- The manifest only declares the bar icon: the panel manages the rest of
  -- the settings. `noctalia.getConfig` only returns the keys it knows, so
  -- for the rest we use what is stored in the settings.toml (the panel
  -- reads it with M.useSaved). It is the same source the script reads:
  -- without this lookup the panel would show the default values instead of
  -- the user's ones.
  local saved_value = M.saved()[key]
  if saved_value ~= nil then
    return saved_value
  end
  return DEFAULTS[key]
end

--- Values stored in the settings.toml.
---
--- The panel fetches them with the helper (`set-setting.py read`) and leaves
--- them here with M.useSaved. They do not expire: a value only changes when
--- the user changes it, and every path to change it (the panel, the
--- settings page, the widget IPC) asks for them again. Returning the last
--- known value is better than showing the default values.
local saved = nil

--- Loads the values read from the settings.toml (helper JSON).
function M.useSaved(raw)
  if type(raw) ~= "string" or raw == "" then
    return false
  end
  local ok, data = pcall(noctalia.json.decode, raw)
  if not ok or type(data) ~= "table" then
    return false
  end
  saved = data
  return true
end

function M.saved()
  return saved or {}
end

function M.kindOf(key)
  if BOOL_KEYS[key] then
    return "bool"
  elseif INT_KEYS[key] then
    return "int"
  elseif FLOAT_KEYS[key] then
    return "float"
  end
  return "string"
end

--- Writes a setting to the overrides layer (immediate, without reloading).
---
--- The callback receives true if the helper has stored the setting and false
--- if not: without it, the caller cannot know whether the change was lost.
function M.write(key, value, callback)
  local function finish(ok)
    M.refresh()
    if callback ~= nil then
      callback(ok)
    end
  end

  local dir = noctalia.pluginDir()
  if dir == nil then
    finish(false)
    return false
  end

  local ok, started = pcall(noctalia.runAsync, {
    "python3",
    dir .. "/bin/set-setting.py",
    "override",
    key,
    tostring(value),
    M.kindOf(key),
  }, function(result)
    local saved_value = result ~= nil and result.exitCode == 0
    if not saved_value then
      local detail = ""
      if type(result) == "table" then
        detail = tostring(result.stderr or result.stdout or "")
      end
      noctalia.log(
        "lyrics-carousel: could not save " .. key
          .. (detail ~= "" and (": " .. detail) or "")
      )
    end
    finish(saved_value)
  end)
  if not ok then
    noctalia.log("lyrics-carousel: could not save " .. key .. ": " .. tostring(started))
    finish(false)
    return false
  end
  if started == false then
    finish(false)
    return false
  end
  return true
end

--- Flushes the overrides into the settings.toml (so that the settings page
--- and the panel show the same thing).
function M.merge(callback)
  local dir = noctalia.pluginDir()
  if dir == nil then
    if callback ~= nil then
      callback(false)
    end
    return false
  end
  local ok, started = pcall(noctalia.runAsync, {
    "python3",
    dir .. "/bin/set-setting.py",
    "merge",
  }, function(result)
    M.refresh()
    local saved_value = result ~= nil and result.exitCode == 0
    if not saved_value then
      noctalia.log("lyrics-carousel: could not dump the settings")
    end
    if callback ~= nil then
      callback(saved_value)
    end
  end)
  if not ok then
    if callback ~= nil then
      callback(false)
    end
    return false
  end
  if started ~= true then
    if callback ~= nil then
      callback(false)
    end
    return false
  end
  return true
end

--- Parses an IPC payload: "key=value [type]" or "key value [type]".
function M.parse(payload)
  if type(payload) ~= "string" then
    return nil
  end
  local key
  local rest
  local head, tail = payload:match("^%s*([^=%s]+)%s*=%s*(.-)%s*$")
  if head ~= nil then
    key = head
    rest = tail or ""
  else
    local pieces = {}
    for piece in payload:gmatch("%S+") do
      pieces[#pieces + 1] = piece
    end
    if #pieces < 2 then
      return nil
    end
    key = table.remove(pieces, 1)
    rest = table.concat(pieces, " ")
  end
  key = key:gsub("^-+", "")
  if DEFAULTS[key] == nil then
    return nil
  end
  -- The type may be the last token; the value is everything else.
  local kind = nil
  local pieces = {}
  for piece in rest:gmatch("%S+") do
    pieces[#pieces + 1] = piece
  end
  local last = pieces[#pieces]
  -- The token is only consumed if a value is left behind: "font_family string"
  -- means the font "string", not an empty value of type string.
  if #pieces > 1 and (last == "bool" or last == "int" or last == "float" or last == "string") then
    kind = last
    table.remove(pieces)
  end
  local value = table.concat(pieces, " ")
  -- Without a type token it is deduced from the key: "set karaoke true" has
  -- to store a boolean, not the string "true" (the panel and the script
  -- read it differently and would contradict each other).
  if kind == nil then
    kind = M.kindOf(key)
  end
  if kind == "bool" then
    local text = value:lower():gsub("%s+", "")
    value = (text == "true" or text == "1" or text == "yes" or text == "on")
  elseif kind == "int" then
    local number = tonumber(value)
    if number == nil then
      return nil
    end
    value = math.floor(number)
  elseif kind == "float" then
    local number = tonumber(value)
    if number == nil then
      return nil
    end
    value = number
  end
  return key, value, kind
end

--- Sets a setting (or toggles it if no value is given).
---
--- If no value is passed, it is toggled: that only makes sense for a toggle,
--- so for any other setting nothing is touched. The current value is read
--- with the same normalization the panel uses, so that "true" (a string) is
--- read the same way in both places.
function M.apply(key, value)
  if value == nil then
    if not BOOL_KEYS[key] then
      return nil
    end
    value = not M.truthy(M.value(key))
  else
    -- The clamping happens here and not only in the helper: the widget
    -- writes through IPC and its value has to be the one the panel would see.
    value = M.clamp(key, value)
    if value == nil then
      -- Rejecting silently leaves the user (and the log) without knowing why
      -- the IPC did not change anything.
      noctalia.log("lyrics-carousel: value out of range for " .. tostring(key))
      return nil
    end
    -- Same for the format: a glyph with uppercase letters or a color that
    -- is not a hexadecimal value would leave the bar or the window without
    -- an icon or without a color.
    value = M.validate(key, value)
    if value == nil then
      noctalia.log("lyrics-carousel: invalid format for " .. tostring(key))
      return nil
    end
  end
  M.write(key, value)
  return value
end

return M
