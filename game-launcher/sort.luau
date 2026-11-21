-- Shared ordering for both panels and the /g provider.
--
-- "last_played" mirrors Steam's library: games that were played come first,
-- newest first, and never-played games follow alphabetically. The scanner
-- supplies the launcher-owned timestamps (Steam, Lutris, Heroic); a launch
-- performed through this plugin is recorded immediately in recent.json, so a
-- freshly started game jumps to the top before its launcher writes the time.
local recent = require("./recent.luau")

local M = {}

local MODES = { last_played = true, name = true }

local function validMode(mode)
  return type(mode) == "string" and MODES[mode] == true
end

local function configMode()
  local ok, val = pcall(noctalia.getConfig, "sort_mode")
  if ok and validMode(val) then return val end
  return "last_played"
end

-- Panels and the launcher provider run in separate VMs. The shared state key
-- lets the in-panel sort button change the order everywhere at once.
function M.current()
  local ok, val = pcall(noctalia.state.get, "sort_mode")
  if ok and validMode(val) then return val end
  return configMode()
end

function M.set(mode)
  if not validMode(mode) then return M.current() end
  pcall(noctalia.state.set, "sort_mode", mode)
  return mode
end

function M.cycle()
  return M.set(M.current() == "last_played" and "name" or "last_played")
end

function M.label(mode)
  if (mode or M.current()) == "name" then return "Name (A–Z)" end
  return "Last played"
end

local function titleOf(item)
  local text = item.name or item.title or ""
  return text:lower()
end

function M.timestamp(item, recentMap)
  local best = tonumber(item.last_played) or 0
  local recorded = recentMap[item.id]
  if type(recorded) == "number" and recorded > best then best = recorded end
  return best
end

function M.apply(list, mode)
  mode = mode or M.current()
  if mode == "name" then
    local recentMap = recent.get()
    local newest, newestTs = nil, 0
    for _, item in ipairs(list) do
      local ts = M.timestamp(item, recentMap)
      if ts > newestTs then newest, newestTs = item, ts end
    end
    table.sort(list, function(a, b)
      local an, bn = titleOf(a), titleOf(b)
      if an ~= bn then return an < bn end
      return tostring(a.id or "") < tostring(b.id or "")
    end)
    -- The last played game stays on top, everything else is alphabetical.
    if newest ~= nil then
      for i, item in ipairs(list) do
        if item == newest then
          table.remove(list, i)
          table.insert(list, 1, newest)
          break
        end
      end
    end
    return list
  end

  local recentMap = recent.get()
  local decorated = {}
  for i, item in ipairs(list) do
    decorated[i] = {
      item = item,
      pos = i,
      ts = M.timestamp(item, recentMap),
      name = titleOf(item),
    }
  end
  table.sort(decorated, function(a, b)
    if a.ts ~= b.ts then return a.ts > b.ts end
    -- Never-played games (and equal timestamps) read alphabetically; identical
    -- names keep the scanner's order.
    if a.ts == 0 and a.name ~= b.name then return a.name < b.name end
    return a.pos < b.pos
  end)
  for i, d in ipairs(decorated) do list[i] = d.item end
  return list
end

-- Newest played entry of a list, plus its timestamp. Used for the badge.
function M.newest(list)
  local recentMap = recent.get()
  local best, bestTs = nil, 0
  for _, item in ipairs(list) do
    local ts = M.timestamp(item, recentMap)
    if ts > bestTs then best, bestTs = item, ts end
  end
  return best, bestTs
end

return M
