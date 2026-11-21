--!nonstrict
-- Connected outputs (`umbriel outputs --json`) as numbered displays, matched to the config's [output.<name>]
-- entries (monitor name first, then connector), with their logical size, position and modes. Pure.
local M = {}

function M.round(v) return math.floor(v + 0.5) end
local round = M.round

local function monitorName(live)
  return type(live.config_name) == "string" and live.config_name ~= "" and live.config_name or nil
end

-- Displays sorted by connector, numbered from 1: {id, number, live, monitor, entryName, index (entry, or nil),
-- values, label (the entry's GUI-only display name, or nil)}. `monitor` is the monitor's name unless another
-- connected output reports the same one (identical monitors without a serial number), so entries can tell
-- them apart; `entryName` is the name a new entry gets: the monitor's, so the settings follow it between ports.
function M.list(outputs, items)
  local list, seen = {}, {}
  for _, live in ipairs(outputs or {}) do
    if type(live) == "table" and type(live.name) == "string" then
      table.insert(list, live)
      local monitor = monitorName(live)
      if monitor then seen[monitor] = (seen[monitor] or 0) + 1 end
    end
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  local displays = {}
  for number, live in ipairs(list) do
    local monitor = monitorName(live)
    if monitor and seen[monitor] > 1 then monitor = nil end
    local byMonitor, byConnector = nil, nil
    for index, item in ipairs(items or {}) do
      if monitor and item.name == monitor and not byMonitor then byMonitor = index end
      if item.name == live.name and not byConnector then byConnector = index end
    end
    local index = byMonitor or byConnector
    local label = index and items[index].label or nil
    table.insert(displays, { id = live.name, number = number, live = live, monitor = monitor,
                             entryName = monitor or live.name, index = index,
                             values = index and items[index].values or {},
                             label = type(label) == "string" and label ~= "" and label or nil })
  end
  return displays
end

-- The display an entry named `name` configures, or nil.
function M.forEntry(displays, name)
  for _, display in ipairs(displays) do
    if display.id == name or display.monitor == name then return display end
  end
  return nil
end

-- What the overview calls the display: its custom name, else the connector.
function M.name(display) return display.label or display.id end

function M.enabled(display)
  if display.values.enabled ~= nil then return display.values.enabled ~= false end
  return display.live.enabled ~= false
end

-- "2560x1440@164.999" → 2560, 1440, 164.999 (rate nil when absent); nil for other text.
function M.parseMode(text)
  if type(text) ~= "string" then return nil end
  local w, h, rest = string.match(text, "^%s*(%d+)%s*[xX]%s*(%d+)(.-)%s*$")
  if not w then return nil end
  local rate = nil
  if rest ~= "" then
    rate = tonumber(string.match(rest, "^@%s*([%d%.]+)$") or "")
    if not rate then return nil end
  end
  return tonumber(w), tonumber(h), rate
end

local function rateText(mhz) return string.format("%g", mhz / 1000) end

local function modeText(mode)
  return string.format("%dx%d@%s", mode.width, mode.height, rateText(mode.refresh_mhz))
end

local function currentMode(live)
  for _, mode in ipairs(live.modes or {}) do
    if mode.current == true then return mode end
  end
  return nil
end

-- The mode's pixel size: the entry's mode, else the current one (nil when neither is known).
function M.resolution(display)
  local w, h = M.parseMode(display.values.mode)
  if w then return w, h end
  local mode = currentMode(display.live)
  if mode and type(mode.width) == "number" and type(mode.height) == "number" then return mode.width, mode.height end
  return nil
end

local ROTATED = { ["90"] = true, ["270"] = true, ["flipped-90"] = true, ["flipped-270"] = true }

-- Logical size {w, h}: the entry's mode, scale and transform over the live ones. The live logical size when
-- the entry changes none of them.
function M.logicalSize(display)
  local live, values = display.live, display.values
  local size = type(live.logical_size) == "table" and live.logical_size or nil
  if values.mode == nil and values.scale == nil and values.transform == nil and size
      and type(size.width) == "number" and type(size.height) == "number" and size.width > 0 then
    return { w = round(size.width), h = round(size.height) }
  end
  local w, h = M.resolution(display)
  if not w or w <= 0 or h <= 0 then w, h = 1920, 1080 end
  local scale = tonumber(values.scale) or tonumber(live.scale) or 1
  if scale <= 0 then scale = 1 end
  local transform = values.transform or live.transform or "normal"
  w, h = round(w / scale), round(h / scale)
  if ROTATED[tostring(transform)] then w, h = h, w end
  return { w = w, h = h }
end

-- Where the display is: the entry's position, else where Umbriel put it (nil when neither is known).
local function position(display)
  local pos = display.values.position
  if type(pos) == "table" and tonumber(pos.x) and tonumber(pos.y) then return { x = pos.x, y = pos.y } end
  pos = display.live.position
  if type(pos) == "table" and tonumber(pos.x) and tonumber(pos.y) then return { x = pos.x, y = pos.y } end
  return nil
end

-- Rectangles {id, x, y, w, h} of the enabled displays; unknown positions go to the right of the others.
function M.rects(displays)
  local rects, unknown, right = {}, {}, 0
  for _, display in ipairs(displays) do
    if M.enabled(display) then
      local size, pos = M.logicalSize(display), position(display)
      local rect = { id = display.id, w = size.w, h = size.h }
      if pos then
        rect.x, rect.y = pos.x, pos.y
        right = math.max(right, pos.x + size.w)
      else
        table.insert(unknown, rect)
      end
      table.insert(rects, rect)
    end
  end
  for _, rect in ipairs(unknown) do
    rect.x, rect.y = right, 0
    right = right + rect.w
  end
  return rects
end

-- Resolutions by area (largest first), each {width, height, label, rates}; rates fastest first, each
-- {mhz, text ("164.999"), preferred, current}.
function M.modes(live)
  local byKey, list = {}, {}
  for _, mode in ipairs(live.modes or {}) do
    if type(mode) == "table" and type(mode.width) == "number" and type(mode.height) == "number"
        and type(mode.refresh_mhz) == "number" and mode.refresh_mhz > 0 then
      local key = mode.width .. "x" .. mode.height
      local res = byKey[key]
      if not res then
        res = { width = mode.width, height = mode.height, label = mode.width .. "×" .. mode.height, rates = {} }
        byKey[key] = res
        table.insert(list, res)
      end
      local text = rateText(mode.refresh_mhz)
      local seen = false
      for _, rate in ipairs(res.rates) do
        if rate.text == text then
          seen = true
          rate.preferred = rate.preferred or mode.preferred == true
          rate.current = rate.current or mode.current == true
        end
      end
      if not seen then
        table.insert(res.rates, { mhz = mode.refresh_mhz, text = text, preferred = mode.preferred == true,
                                  current = mode.current == true })
      end
    end
  end
  table.sort(list, function(a, b)
    if a.width * a.height ~= b.width * b.height then return a.width * a.height > b.width * b.height end
    return a.width > b.width
  end)
  for _, res in ipairs(list) do table.sort(res.rates, function(a, b) return a.mhz > b.mhz end) end
  return list
end

-- The preferred mode's text ("2560x1440@60"), or nil.
function M.preferredText(live)
  for _, mode in ipairs(live.modes or {}) do
    if mode.preferred == true and type(mode.width) == "number" and type(mode.refresh_mhz) == "number" then
      return modeText(mode)
    end
  end
  return nil
end

return M
