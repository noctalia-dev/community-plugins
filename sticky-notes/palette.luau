--!nonstrict
-- Wallpaper-aware sticky colors.
--
-- The declarative UI can render palette role names, but the plugin API does
-- not expose their resolved RGB values. Ask Noctalia's own theme generator for
-- the active wallpaper palette, then blend its three accents with the classic
-- sticky colors. This keeps seven recognizable categories without hardcoding
-- a palette that clashes with the wallpaper.

local M = {}

local CLASSIC = {
  yellow = "#FFF59D",
  pink   = "#F8BBD9",
  red    = "#EF5350",
  blue   = "#B3E5FC",
  green  = "#DCEDC8",
  orange = "#FFA726",
  purple = "#E1BEE7",
}

-- Distribute the classic categories across the three wallpaper accents. The
-- classic color remains slightly dominant in the blend, so notes stay easy to
-- recognize even when two Material palette roles are close together.
local ROLE_BY_COLOR = {
  yellow = "primary",
  pink   = "secondary",
  red    = "tertiary",
  blue   = "primary",
  green  = "secondary",
  orange = "tertiary",
  purple = "primary",
}

local generated = nil
local resolvedSig = nil
local pendingSig = nil
local imageLookupPending = false
local onChanged = nil
local lastError = nil

local function logError(message)
  if message == lastError then return end
  lastError = message
  noctalia.log("StickyNotes: wallpaper palette unavailable: " .. message)
end

local function rgb(hex)
  if type(hex) ~= "string" then return nil end
  local r, g, b = hex:match("^#(%x%x)(%x%x)(%x%x)$")
  if r == nil then return nil end
  return { tonumber(r, 16), tonumber(g, 16), tonumber(b, 16) }
end

local function toHex(color)
  return string.format(
    "#%02X%02X%02X",
    math.max(0, math.min(255, math.floor(color[1] + 0.5))),
    math.max(0, math.min(255, math.floor(color[2] + 0.5))),
    math.max(0, math.min(255, math.floor(color[3] + 0.5)))
  )
end

local function mixHex(a, b, bWeight)
  local ar, br = rgb(a), rgb(b)
  if ar == nil then return b end
  if br == nil then return a end
  local aWeight = 1 - bWeight
  return toHex({
    ar[1] * aWeight + br[1] * bWeight,
    ar[2] * aWeight + br[2] * bWeight,
    ar[3] * aWeight + br[3] * bWeight,
  })
end

local function channelLuminance(value)
  local c = value / 255
  if c <= 0.04045 then return c / 12.92 end
  return ((c + 0.055) / 1.055) ^ 2.4
end

local function luminance(hex)
  local color = rgb(hex)
  if color == nil then return 0 end
  return 0.2126 * channelLuminance(color[1])
    + 0.7152 * channelLuminance(color[2])
    + 0.0722 * channelLuminance(color[3])
end

local function contrast(a, b)
  local l1, l2 = luminance(a), luminance(b)
  if l1 < l2 then l1, l2 = l2, l1 end
  return (l1 + 0.05) / (l2 + 0.05)
end

local function readableText(fill, palette)
  local candidates = {
    palette.on_surface,
    palette.surface,
    "#111111",
    "#FFFFFF",
  }
  local best, bestContrast = "#111111", 0
  for _, candidate in ipairs(candidates) do
    if rgb(candidate) ~= nil then
      local ratio = contrast(fill, candidate)
      if ratio > bestContrast then
        best, bestContrast = candidate, ratio
      end
    end
  end
  return best
end

local function paletteFrom(raw)
  local doc = noctalia.json.decode(raw or "")
  if type(doc) ~= "table" then return nil end
  local palette = {
    primary = doc.primary,
    secondary = doc.secondary,
    tertiary = doc.tertiary,
    primary_container = doc.primary_container,
    secondary_container = doc.secondary_container,
    tertiary_container = doc.tertiary_container,
    surface = doc.surface,
    on_surface = doc.on_surface,
  }
  if rgb(palette.primary) == nil
    or rgb(palette.secondary) == nil
    or rgb(palette.tertiary) == nil
    or rgb(palette.surface) == nil
  then
    return nil
  end
  return palette
end

local function roleAnchor(palette, role)
  local container = palette[role .. "_container"]
  if rgb(container) ~= nil then return container end
  -- Older palette output may omit container roles. Moving the accent toward
  -- the surface produces a similar card-friendly tone.
  return mixHex(palette[role], palette.surface, 0.55)
end

local function generate(palette)
  local styles = {}
  for id, classic in pairs(CLASSIC) do
    local anchor = roleAnchor(palette, ROLE_BY_COLOR[id])
    -- 54% classic preserves the named hue; 46% wallpaper tone harmonizes it.
    local fill = mixHex(anchor, classic, 0.54)
    styles[id] = { fill = fill, text = readableText(fill, palette) }
  end
  return styles
end

local function resolveImage(image)
  local dark = noctalia.isDarkMode()
  local scheme = noctalia.getSetting("theme.wallpaper_scheme")
  if type(scheme) ~= "string" or scheme == "" then scheme = "m3-tonal-spot" end
  local pureBlack = dark and noctalia.getSetting("theme.pure_black_dark") == true
  local sig = table.concat({ image, dark and "dark" or "light", scheme, pureBlack and "black" or "normal" }, "|")
  if sig == resolvedSig or sig == pendingSig then return end

  local argv = { "noctalia", "theme", image, dark and "--dark" or "--light", "--scheme", scheme }
  if pureBlack then table.insert(argv, "--pure-black") end
  pendingSig = sig
  local started = noctalia.runAsync(argv, function(result)
    if pendingSig ~= sig then return end
    pendingSig = nil
    if type(result) ~= "table" or result.exitCode ~= 0 then
      local detail = type(result) == "table" and noctalia.string.trim(result.stderr or "") or "command did not return a result"
      logError(detail ~= "" and detail or "theme generator failed")
      return
    end
    local palette = paletteFrom(result.stdout)
    if palette == nil then
      logError("theme generator returned invalid JSON")
      return
    end
    generated = generate(palette)
    resolvedSig = sig
    lastError = nil
    noctalia.log("StickyNotes: generated wallpaper colors from " .. image)
    if onChanged ~= nil then onChanged() end
  end, 8000)
  if started == false then
    pendingSig = nil
    logError("could not start noctalia theme")
  end
end

function M.refresh(connector)
  if noctalia.getConfig("no_colors") == true
    or noctalia.getConfig("use_wallpaper_colors") ~= true
  then
    return
  end
  if type(connector) ~= "string" or connector == "" then
    connector = noctalia.focusedOutputName()
  end

  -- This API is the cheapest source and updates with the shell wallpaper.
  local image = connector and noctalia.wallpaperPath(connector) or nil
  if type(image) == "string" and image ~= "" then
    resolveImage(image)
    return
  end

  -- Some Noctalia builds return nil from wallpaperPath() inside a panel even
  -- though the wallpaper service is active. Ask the running shell through its
  -- supported IPC command instead of guessing private settings keys.
  if imageLookupPending then return end
  imageLookupPending = true
  local argv = { "noctalia", "msg", "wallpaper-get" }
  if type(connector) == "string" and connector ~= "" then
    table.insert(argv, connector)
  end
  local started = noctalia.runAsync(argv, function(result)
    imageLookupPending = false
    if type(result) ~= "table" or result.exitCode ~= 0 then
      local detail = type(result) == "table" and noctalia.string.trim(result.stderr or "") or "command did not return a result"
      logError(detail ~= "" and detail or "could not query current wallpaper")
      return
    end
    local resolvedImage = noctalia.string.trim(result.stdout or "")
    if resolvedImage == "" then
      logError("wallpaper-get returned no current wallpaper path")
      return
    end
    resolveImage(resolvedImage)
  end, 3000)
  if started == false then
    imageLookupPending = false
    logError("could not start wallpaper lookup")
  end
end

function M.style(id)
  if generated == nil then return nil end
  return generated[id]
end

function M.setOnChanged(callback)
  onChanged = callback
end

return M
