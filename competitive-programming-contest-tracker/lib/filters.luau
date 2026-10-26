--!nonstrict
local platforms = require("./platforms.luau")
local store = require("./store.luau")
local types = require("./types.luau")

local M = {}

M.RANGES = {
  { id = "24h", labelKey = "filters.range_24h", secs = 24 * 3600 },
  { id = "7d", labelKey = "filters.range_7d", secs = 7 * 24 * 3600 },
  { id = "all", labelKey = "filters.range_all", secs = nil },
} :: { types.Range }

local FILE = "filters.json"

function M.defaults(): types.Filters
  local shown: { [string]: boolean } = {}
  for _, p in ipairs(platforms.list) do
    shown[p.id] = true
  end
  return {
    platforms = shown,
    range = "all",
    favoritesOnly = false,
    favorites = {},
    savedOnly = false,
    saved = {},
  }
end

function M.load(): types.Filters
  local f = M.defaults()
  local saved = store.read(FILE)
  if type(saved) ~= "table" then
    return f
  end
  if type(saved.platforms) == "table" then
    for id in pairs(f.platforms) do
      if saved.platforms[id] ~= nil then
        f.platforms[id] = saved.platforms[id] == true
      end
    end
  end
  if type(saved.range) == "string" then
    f.range = saved.range
  end
  if type(saved.favoritesOnly) == "boolean" then
    f.favoritesOnly = saved.favoritesOnly
  end
  if type(saved.savedOnly) == "boolean" then
    f.savedOnly = saved.savedOnly
  end
  if type(saved.saved) == "table" then
    for url, c in pairs(saved.saved) do
      if type(url) == "string" and type(c) == "table" and type(c.name) == "string"
        and type(c.start) == "number" and type(c.dur) == "number" and type(c.src) == "string" then
        f.saved[url] = { src = c.src, name = c.name, start = c.start, dur = c.dur, url = url }
      end
    end
  end
  if type(saved.favorites) == "table" then
    for url, on in pairs(saved.favorites) do
      if on == true and type(url) == "string" then
        f.favorites[url] = true
      end
    end
  end
  return f
end

function M.save(f: types.Filters)
  store.write(FILE, f)
end

function M.visible(c: types.Contest, f: types.Filters, now: number, useRange: boolean): boolean
  if f.platforms[c.src] == false then
    return false
  end
  if c.start + c.dur <= now then
    return false
  end
  if f.favoritesOnly and not f.favorites[c.url] then
    return false
  end
  if useRange and c.start > now then
    for _, r in ipairs(M.RANGES) do
      if r.id == f.range and r.secs and c.start - now > r.secs then
        return false
      end
    end
  end
  return true
end

function M.visiblePast(c: types.Contest, f: types.Filters): boolean
  if f.platforms[c.src] == false then
    return false
  end
  if f.savedOnly and not f.saved[c.url] then
    return false
  end
  return true
end

return M
