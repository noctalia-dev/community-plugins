--!nonstrict
-- Monitor rules: modes, logical sizes, the left-to-right row, desc: matching.
-- `connected` is the decoded `hyprctl monitors all -j` array.

local M = {}

-- "1920x1080@144.00Hz" or "1920x1080@144" -> 1920, 1080, 144
function M.parseMode(mode)
  if type(mode) ~= "string" then return nil end
  local w, h, hz = mode:match("^(%d+)x(%d+)@([%d%.]+)")
  if w == nil then return nil end
  return tonumber(w), tonumber(h), tonumber(hz)
end

-- The rule form of an availableModes entry: drop the "Hz".
function M.ruleMode(available)
  return (available:gsub("Hz$", ""))
end

-- Size in layout pixels. Odd transforms (90/270 and their flips) swap axes.
-- Fails when the scale does not divide the mode into whole pixels, which
-- Hyprland would reject or silently adjust.
function M.logicalSize(mode, scale, transform)
  local w, h = M.parseMode(mode)
  if w == nil then return nil, "invalid mode " .. tostring(mode) end
  if type(scale) ~= "number" or scale ~= scale or scale <= 0 or scale == math.huge then
    return nil, "invalid scale"
  end
  if (transform or 0) % 2 == 1 then w, h = h, w end
  local lw, lh = w / scale, h / scale
  local rw, rh = math.round(lw), math.round(lh)
  if math.abs(lw - rw) > 1e-6 or math.abs(lh - rh) > 1e-6 then
    return nil, string.format("scale %s gives %.2fx%.2f, not whole pixels", tostring(scale), lw, lh)
  end
  return rw, rh
end

-- Left-to-right row, top edges aligned. Disabled entries take no space and
-- get no position (their saved one is kept). A mode keyword needs
-- entry.monitor (the connected monitor) to be resolved. Returns positions by index.
function M.layout(row)
  local positions, x = {}, 0
  for i, entry in ipairs(row) do
    if not entry.disabled then
      local mode = entry.monitor and M.resolveMode(entry.mode, entry.monitor) or entry.mode
      local w, err = M.logicalSize(mode, entry.scale, entry.transform)
      if w == nil then return nil, "monitor " .. i .. ": " .. err end
      positions[i] = string.format("%dx0", x)
      x += w
    end
  end
  return positions
end

-- Match by device, not by port: the same port carries different screens.
-- Falls back to the connector when the description is empty or not unique.
function M.ruleOutput(monitor, connected)
  local desc = monitor.description or ""
  if desc == "" then return monitor.name end
  for _, other in ipairs(connected) do
    if other ~= monitor and other.description == desc then return monitor.name end
  end
  return "desc:" .. desc
end

function M.matches(output, monitor)
  if output == monitor.name then return true end
  local desc = output:match("^desc:(.*)$")
  return desc ~= nil and desc ~= "" and (monitor.description or ""):sub(1, #desc) == desc
end

-- The rule that applies to a connected monitor: the last match wins, as in Hyprland.
function M.ruleFor(rules, monitor)
  local found = nil
  for _, rule in ipairs(rules) do
    if M.matches(rule.output, monitor) then found = rule end
  end
  return found
end

-- Hyprland's mode keywords resolved against a connected monitor's modes.
-- ponytail: "preferred" is taken as the first listed mode, which is what
-- Hyprland lists for the screens tested; read the EDID preference if that ever differs.
function M.resolveMode(mode, monitor)
  local modes = monitor.availableModes or {}
  if mode == "preferred" then return modes[1] and M.ruleMode(modes[1]) end
  if mode == "highres" or mode == "highrr" then
    local best, bestKey = nil, nil
    for _, available in ipairs(modes) do
      local w, h, hz = M.parseMode(available)
      local key = mode == "highres" and (w * h * 1000 + hz) or (hz * 1e8 + w * h)
      if bestKey == nil or key > bestKey then best, bestKey = available, key end
    end
    return best and M.ruleMode(best)
  end
  for _, available in ipairs(modes) do
    local aw, ah, ahz = M.parseMode(available)
    local w, h, hz = M.parseMode(mode)
    if w ~= nil and aw == w and ah == h and math.abs(ahz - hz) < 0.01 then return M.ruleMode(available) end
  end
  return nil
end

local KEYWORDS = { preferred = true, highres = true, highrr = true }
local AUTO = { auto = true, ["auto-right"] = true, ["auto-left"] = true, ["auto-up"] = true, ["auto-down"] = true,
  ["auto-center-right"] = true, ["auto-center-left"] = true, ["auto-center-up"] = true, ["auto-center-down"] = true }

local function concreteMode(mode)
  local w, h, hz = mode:match("^(%d+)x(%d+)@(%d+%.?%d*)$")
  return w ~= nil and tonumber(w) > 0 and tonumber(h) > 0 and tonumber(hz) > 0
end

-- Shape of one rule, connected or not.
function M.checkRule(rule)
  if type(rule) ~= "table" then return false, "rule is not a table" end
  if type(rule.output) ~= "string" or rule.output == "" or rule.output == "desc:" then return false, "missing output" end
  if type(rule.mode) ~= "string" or not (KEYWORDS[rule.mode] or concreteMode(rule.mode)) then
    return false, "invalid mode " .. tostring(rule.mode)
  end
  if type(rule.position) ~= "string" or not (AUTO[rule.position] or rule.position:match("^%-?%d+x%-?%d+$")) then
    return false, "invalid position " .. tostring(rule.position)
  end
  if type(rule.scale) ~= "number" or rule.scale ~= rule.scale or rule.scale <= 0 or rule.scale > 10 then
    return false, "invalid scale " .. tostring(rule.scale)
  end
  local tr = rule.transform or 0
  if type(tr) ~= "number" or tr ~= math.floor(tr) or tr < 0 or tr > 7 then return false, "transform must be 0-7" end
  if rule.disabled ~= nil and type(rule.disabled) ~= "boolean" then return false, "disabled must be true/false" end
  return true
end

-- Checks every rule, then the connected screens just before Apply: a
-- screen only counts as staying on when its rule is fully valid for it.
function M.validate(rules, connected)
  for i, rule in ipairs(rules) do
    local ok, err = M.checkRule(rule)
    if not ok then return false, "rule " .. i .. ": " .. err end
  end
  local active = 0
  for _, monitor in ipairs(connected) do
    local rule = M.ruleFor(rules, monitor)
    if rule == nil then
      if not monitor.disabled then active += 1 end
    elseif not rule.disabled then
      local mode = M.resolveMode(rule.mode, monitor)
      if mode == nil then return false, monitor.name .. ": mode " .. rule.mode .. " not supported" end
      local ok, err = M.logicalSize(mode, rule.scale, rule.transform)
      if not ok then return false, monitor.name .. ": " .. err end
      active += 1
    end
  end
  if active == 0 then return false, "at least one screen must stay on" end
  return true
end

return M
