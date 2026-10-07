--!nonstrict
-- Saved state -> the text of hyprland-settings.lua (Lua 5.5, read by Hyprland).
--
-- state = {
--   options  = { [path] = { value = ..., why = "..." } },
--   preset   = { name = "futurista", why = "..." } or nil,
--   monitors = { { output, mode, position, scale, transform?, disabled?, why? } },
-- }
-- Modules are passed in instead of required: the plugin host wants
-- require("./x.luau"), the luau test CLI wants require("./x").

local M = {}

local function quote(text)
  return '"' .. text:gsub('[%c"\\]', function(c)
    if c == "\n" then return "\\n" end
    if c == '"' or c == "\\" then return "\\" .. c end
    return string.format("\\%03d", string.byte(c))
  end) .. '"'
end

-- One line, no control characters: a reason must never become code.
local function comment(why)
  if type(why) ~= "string" then return nil end
  why = why:gsub("%c", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if why == "" then return nil end
  return "-- why: " .. why
end

local function finite(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- Shortest text that reads back as exactly the same number.
local function number(v)
  if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return string.format("%d", v) end
  return tostring(v)
end

local function inRange(option, v)
  return (option.min == nil or v >= option.min) and (option.max == nil or v <= option.max)
end

-- Returns the Lua literal for a value, or nil and an error.
function M.literal(option, v)
  local kind = option.kind
  if kind == "bool" then
    if type(v) ~= "boolean" then return nil, "expected boolean" end
    return tostring(v)
  elseif kind == "string" then
    if type(v) ~= "string" then return nil, "expected string" end
    return quote(v)
  elseif kind == "choice" then
    if not table.find(option.choices, v) then return nil, "not one of the choices" end
    return quote(v)
  elseif kind == "enum" then
    if not table.find(option.choices, v) then return nil, "not one of the choices" end
    return string.format("%d", v)
  elseif kind == "int" or kind == "float" then
    if not finite(v) then return nil, "expected a finite number" end
    if kind == "int" and v ~= math.floor(v) then return nil, "expected an integer" end
    if not inRange(option, v) then return nil, "out of range" end
    return kind == "int" and string.format("%d", v) or number(v)
  elseif kind == "gaps" then
    if finite(v) then
      if v ~= math.floor(v) or not inRange(option, v) then return nil, "invalid gap" end
      return string.format("%d", v)
    end
    if type(v) ~= "table" then return nil, "expected a number or four sides" end
    local parts = {}
    for _, side in ipairs({ "top", "right", "bottom", "left" }) do
      local s = v[side]
      if not finite(s) or s ~= math.floor(s) or not inRange(option, s) then return nil, "invalid gap " .. side end
      table.insert(parts, string.format("%s = %d", side, s))
    end
    if v.top == v.right and v.top == v.bottom and v.top == v.left then return string.format("%d", v.top) end
    return "{ " .. table.concat(parts, ", ") .. " }"
  end
  return nil, "unknown kind " .. tostring(kind)
end

-- Builds the nested hl.config table in catalog order.
local function configBlock(catalog, options, out)
  local root = { keys = {}, children = {} }
  for _, option in ipairs(catalog.options) do
    local entry = options[option.path]
    if entry ~= nil then
      local literal, err = M.literal(option, entry.value)
      if literal == nil then return nil, option.path .. ": " .. err end
      local node = root
      local parts = string.split(option.path, ".")
      for i = 1, #parts - 1 do
        local key = parts[i]
        if node.children[key] == nil then
          node.children[key] = { keys = {}, children = {} }
          table.insert(node.keys, key)
        end
        node = node.children[key]
      end
      local leaf = parts[#parts]
      table.insert(node.keys, leaf)
      node.children[leaf] = { literal = literal, why = comment(entry.why) }
    end
  end
  for path in pairs(options) do
    if catalog.byPath[path] == nil then return nil, "unknown option " .. path end
  end
  if #root.keys == 0 then return true end

  local function emit(node, indent)
    for _, key in ipairs(node.keys) do
      local child = node.children[key]
      if child.literal ~= nil then
        if child.why then table.insert(out, indent .. child.why) end
        table.insert(out, indent .. key .. " = " .. child.literal .. ",")
      else
        table.insert(out, indent .. key .. " = {")
        emit(child, indent .. "    ")
        table.insert(out, indent .. "},")
      end
    end
  end
  table.insert(out, "hl.config({")
  emit(root, "    ")
  table.insert(out, "})")
  table.insert(out, "")
  return true
end

local function presetBlock(preset, presets, out)
  local data = presets[preset.name]
  if data == nil then return nil, "unknown preset " .. tostring(preset.name) end
  table.insert(out, "-- Animations: preset " .. quote(data.name))
  local why = comment(preset.why)
  if why then table.insert(out, why) end
  for _, curve in ipairs(data.curves) do
    local p = curve.points
    table.insert(out, string.format('hl.curve(%s, { type = "bezier", points = { {%s, %s}, {%s, %s} } })',
      quote(curve.name), number(p[1][1]), number(p[1][2]), number(p[2][1]), number(p[2][2])))
  end
  for _, leaf in ipairs(data.reset) do
    table.insert(out, string.format("hl.animation({ leaf = %s, enabled = false })", quote(leaf)))
  end
  for _, a in ipairs(data.animations) do
    local style = a.style and (", style = " .. quote(a.style)) or ""
    table.insert(out, string.format("hl.animation({ leaf = %s, enabled = true, speed = %s, bezier = %s%s })",
      quote(a.leaf), number(a.speed), quote(a.bezier), style))
  end
  table.insert(out, "")
  return true
end

local function monitorBlock(monitors, out)
  for i, m in ipairs(monitors) do
    if type(m.output) ~= "string" or m.output == "" then return nil, "monitor " .. i .. ": missing output" end
    if not finite(m.scale) or m.scale <= 0 then return nil, "monitor " .. i .. ": invalid scale" end
    if type(m.mode) ~= "string" or type(m.position) ~= "string" then return nil, "monitor " .. i .. ": missing mode or position" end
    local why = comment(m.why)
    if why then table.insert(out, why) end
    table.insert(out, "hl.monitor({")
    table.insert(out, "    output   = " .. quote(m.output) .. ",")
    table.insert(out, "    mode     = " .. quote(m.mode) .. ",")
    table.insert(out, "    position = " .. quote(m.position) .. ",")
    table.insert(out, "    scale    = " .. number(m.scale) .. ",")
    if m.transform ~= nil and (type(m.transform) ~= "number" or m.transform ~= math.floor(m.transform)
        or m.transform < 0 or m.transform > 7) then
      return nil, "monitor " .. i .. ": transform must be 0-7"
    end
    if m.transform ~= nil and m.transform ~= 0 then
      table.insert(out, "    transform = " .. string.format("%d", m.transform) .. ",")
    end
    if m.disabled then table.insert(out, "    disabled = true,") end
    table.insert(out, "})")
  end
  if #monitors > 0 then table.insert(out, "") end
  return true
end

-- Returns the file text, or nil and an error. Never a partial file.
-- `revision` is read back with `hyprctl repl` to prove Hyprland loaded this file.
function M.render(state, catalog, presets, revision)
  local out = {
    "-- Generated by Hyprland Settings (michael-retunzew/hyprland-settings).",
    "-- Change values in the panel: edits made here are overwritten on the next Apply.",
    "",
  }
  if revision ~= nil then
    if type(revision) ~= "string" or not revision:match("^[%w%-]+$") then return nil, "invalid revision" end
    table.insert(out, "HYPRLAND_SETTINGS_REVISION = " .. quote(revision))
    table.insert(out, "")
  end
  local ok, err = configBlock(catalog, state.options or {}, out)
  if not ok then return nil, err end
  if state.preset ~= nil then
    ok, err = presetBlock(state.preset, presets, out)
    if not ok then return nil, err end
  end
  ok, err = monitorBlock(state.monitors or {}, out)
  if not ok then return nil, err end
  return table.concat(out, "\n")
end

return M
