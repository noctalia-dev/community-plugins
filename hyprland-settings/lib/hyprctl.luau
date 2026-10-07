--!nonstrict
-- Reading the live values. `hyprctl descriptions` is never used for values:
-- its "current" field is wrong (shows kb_layout=us while de is set).

local M = {}

-- One process for every option: hyprctl --batch "j/getoption a; j/getoption b".
function M.readArgv(catalog)
  local parts = {}
  for _, option in ipairs(catalog.options) do
    table.insert(parts, "j/getoption " .. option.name)
  end
  return { "hyprctl", "--batch", table.concat(parts, "; ") }
end

-- "20 20 20 20" (top right bottom left) -> 20, or the four sides.
local function gaps(css)
  local t, r, b, l = css:match("^(%-?%d+) (%-?%d+) (%-?%d+) (%-?%d+)$")
  if t == nil then return nil end
  t, r, b, l = tonumber(t), tonumber(r), tonumber(b), tonumber(l)
  if t == r and t == b and t == l then return t end
  return { top = t, right = r, bottom = b, left = l }
end

local function value(option, raw)
  local kind = option.kind
  if kind == "gaps" then return raw.css and gaps(raw.css) or raw.int end
  if kind == "bool" then
    if raw.bool ~= nil then return raw.bool end
    if raw.int ~= nil then return raw.int ~= 0 end
    return nil
  end
  if kind == "string" or kind == "choice" then
    if raw.str == "[[EMPTY]]" then return "" end -- Hyprland's way of printing an empty string
    return raw.str
  end
  if kind == "int" or kind == "enum" then return raw.int end
  if kind == "float" then return raw.float or raw.int end
  return nil
end

-- Batch stdout -> { [path] = value }. Options Hyprland does not know are
-- left out, so the panel can show them as unavailable.
function M.parseRead(catalog, stdout, decode)
  local byName = {}
  for _, option in ipairs(catalog.options) do byName[option.name] = option end
  local values = {}
  for line in stdout:gmatch("[^\n]+") do
    if line:sub(1, 1) == "{" then
      local raw = decode(line)
      local option = raw and byName[raw.option]
      if option ~= nil then
        local v = value(option, raw)
        if v ~= nil then values[option.path] = v end
      end
    end
  end
  return values
end

return M
