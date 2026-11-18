--!nonstrict
-- Utilities shared by the plugin modules.

local M = {}

function M.trim(value)
  if value == nil then
    return ""
  end
  return (tostring(value):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- "My Widget!" -> "my-widget". It is the basis of the window class.
function M.slug(name)
  local result = tostring(name):lower():gsub("[^%w]+", "-")
  result = result:gsub("^%-+", ""):gsub("%-+$", "")
  if result == "" then
    return "app"
  end
  return result
end

function M.classFor(name)
  return "noctalia-term-" .. M.slug(name)
end

-- Path to a plugin file, tolerating a trailing slash in the directory.
function M.pluginPath(name)
  local dir = noctalia.pluginDir()
  if dir == nil then
    return nil
  end
  dir = tostring(dir):gsub("/+$", "")
  return dir .. "/" .. name
end

function M.shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

-- Lua string in double quotes, to embed it in the expression that
-- `hyprctl dispatch` receives.
function M.luaQuote(value)
  local escaped = tostring(value)
  escaped = escaped:gsub("\\", "\\\\")
  escaped = escaped:gsub('"', '\\"')
  escaped = escaped:gsub("\r", "\\r")
  escaped = escaped:gsub("\n", "\\n")
  return '"' .. escaped .. '"'
end

function M.clamp(value, low, high)
  if value < low then
    return low
  elseif value > high then
    return high
  end
  return value
end

function M.sortedKeys(map)
  local keys = {}
  for key in pairs(map or {}) do
    table.insert(keys, key)
  end
  table.sort(keys, function(a, b)
    local left = tostring(a):lower()
    local right = tostring(b):lower()
    if left == right then
      return tostring(a) < tostring(b)
    end
    return left < right
  end)
  return keys
end

function M.copyMap(map)
  local out = {}
  for key, value in pairs(map or {}) do
    out[key] = value
  end
  return out
end

function M.contains(list, value)
  for _, item in ipairs(list or {}) do
    if item == value then
      return true
    end
  end
  return false
end

function M.tableToString(t)
  if type(t) ~= "table" then
    return tostring(t)
  end
  local parts = {}
  for k, v in pairs(t) do
    table.insert(parts, string.format("%s=%s", tostring(k), tostring(v)))
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

return M
