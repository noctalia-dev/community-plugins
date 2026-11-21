--!nonstrict
-- Presentation memory avoids a blank frame before the service responds.
-- service/pages.luau still owns freshness, TTL, HTTP, auth and single-flight.
local size = require("../cache_size.luau")
local M = {}
local navigationFields = {
  "offset",
  "cursors",
  "before",
  "beforeId",
  "thread",
  "album",
  "search",
  "searchDraft",
  "recipient",
}

local function store(maxEntries, maxBytes)
  local entries, clock, bytes = {}, 0, 0
  local function get(key)
    local entry = entries[key]
    if entry then
      clock = clock + 1
      entry.used = clock
      return entry.value
    end
  end
  local function put(key, value)
    local weight = size(value, maxBytes)
    if entries[key] then
      bytes = bytes - entries[key].weight
      entries[key] = nil
    end
    if weight > maxBytes then
      return
    end
    clock = clock + 1
    entries[key] = { value = value, weight = weight, used = clock }
    bytes = bytes + weight
    while true do
      local count, oldest, stamp = 0, nil, math.huge
      for id, entry in pairs(entries) do
        count = count + 1
        if entry.used < stamp then
          oldest, stamp = id, entry.used
        end
      end
      if count <= maxEntries and bytes <= maxBytes then
        break
      end
      bytes = bytes - entries[oldest].weight
      entries[oldest] = nil
    end
  end
  return { get = get, put = put }
end

function M.new(model)
  local views = store(24, 4 * 1024 * 1024)
  local navigation = store(32, 256 * 1024)
  local function navigationKey(device, page)
    return tostring(#device) .. ":" .. device .. page
  end
  local function save(device, page)
    if not device then
      return
    end
    local value = {}
    for _, field in ipairs(navigationFields) do
      value[field] = model[field]
    end
    -- cursors mutate in place; saved history must not share the same table.
    value.cursors = {}
    for key, cursor in pairs(model.cursors) do
      value.cursors[key] = cursor
    end
    navigation.put(navigationKey(device, page), value)
  end
  local function restore(device, page)
    local value = device and navigation.get(navigationKey(device, page))
    if not value then
      return
    end
    for _, field in ipairs(navigationFields) do
      model[field] = value[field]
    end
    model.cursors = {}
    for key, cursor in pairs(value.cursors) do
      model.cursors[key] = cursor
    end
  end
  local function remember(view)
    -- Accept only the exact request, never another page or a late response.
    if
      view
      and view.key == model.pageKey
      and view.status == "ready"
      and type(view.data) == "table"
    then
      views.put(view.key, { key = view.key, status = "ready", data = view.data })
    end
  end
  local function resolve(key, incoming)
    if
      incoming
      and incoming.key == key
      and incoming.status == "ready"
      and type(incoming.data) == "table"
    then
      return incoming
    end
    local saved = views.get(key)
    if saved then
      -- Do not claim the snapshot is fresh. A background read failure must
      -- not destroy the last successful result either.
      return {
        key = key,
        status = "ready",
        data = saved.data,
        stale = true,
        refreshing = not incoming or incoming.key ~= key or incoming.status == "loading",
        refreshFailed = incoming and incoming.key == key and incoming.status ~= "loading" or false,
        error = incoming and incoming.key == key and incoming.error or nil,
      }
    end
    return incoming and incoming.key == key and incoming or nil
  end
  local function clear()
    views = store(24, 4 * 1024 * 1024)
    navigation = store(32, 256 * 1024)
    model.pageView = nil
  end
  return { save = save, restore = restore, remember = remember, resolve = resolve, clear = clear }
end
return M
