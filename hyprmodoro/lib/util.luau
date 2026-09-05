local M = {}

function M.trim(s)
  if type(s) ~= "string" then return "" end
  return s:match("^%s*(.-)%s*$") or ""
end

function M.shq(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

function M.luaStr(s)
  local out = tostring(s)
  out = out:gsub("\\", "\\\\")
  out = out:gsub('"', '\\"')
  out = out:gsub("\n", "\\n")
  out = out:gsub("\r", "\\r")
  out = out:gsub("\t", "\\t")
  return '"' .. out .. '"'
end

function M.clamp(n, lo, hi)
  n = tonumber(n) or lo
  if n < lo then return lo end
  if n > hi then return hi end
  return n
end

function M.round(n)
  return math.floor((tonumber(n) or 0) + 0.5)
end

function M.splitLines(s)
  local out = {}
  for line in tostring(s):gmatch("[^\r\n]+") do
    local t = M.trim(line)
    if t ~= "" then table.insert(out, t) end
  end
  return out
end

function M.dirname(path)
  local dir = tostring(path):match("^(.*)/[^/]*$")
  if dir == nil or dir == "" then return "." end
  return dir
end

function M.parseClock(s)
  s = M.trim(s)
  local parts = {}
  for chunk in s:gmatch("[^:]+") do table.insert(parts, tonumber(chunk)) end
  if #parts == 2 and parts[1] and parts[2] then
    return parts[1] * 60 + parts[2]
  elseif #parts == 3 and parts[1] and parts[2] and parts[3] then
    return parts[1] * 3600 + parts[2] * 60 + parts[3]
  end
  return nil
end

function M.parsePresets(raw, max)
  local out = {}
  max = max or 6
  for chunk in tostring(raw or ""):gmatch("[^,]+") do
    local w, r = chunk:match("^%s*(%d+)%s*/%s*(%d+)%s*$")
    w, r = tonumber(w), tonumber(r)
    if w and r and w >= 1 and w <= 180 and r >= 1 and r <= 60 then
      table.insert(out, { work = w, rest = r })
      if #out >= max then break end
    end
  end
  return out
end

return M
