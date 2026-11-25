--!nonstrict
-- Presentation memory avoids a blank frame before the service responds.
-- service/pages.luau still owns freshness, TTL, HTTP, auth and single-flight.
local size = require("../cache_size.luau")
local access = require("../message_access.luau")
local M = {}
local navigationFields = {
  "offset",
  "cursors",
  "before",
  "beforeId",
  "thread",
  "threadList", -- Replaced as a unit; the thread-list pager never mutates a saved value.
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
  local function put(key, value, pin)
    local weight = size(value, maxBytes)
    if entries[key] then
      bytes = bytes - entries[key].weight
      entries[key] = nil
    end
    if weight > maxBytes then
      return
    end
    if pin then
      for _, entry in pairs(entries) do
        if entry.pin == pin then entry.pin = nil end
      end
    end
    clock = clock + 1
    entries[key] = { value = value, weight = weight, used = clock, pin = pin }
    bytes = bytes + weight
    while true do
      local count, oldest, stamp, rank = 0, nil, math.huge, math.huge
      for id, entry in pairs(entries) do
        count = count + 1
        local priority = entry.pin and 1 or 0
        if priority < rank or (priority == rank and entry.used < stamp) then
          oldest, stamp, rank = id, entry.used, priority
        end
      end
      if count <= maxEntries and bytes <= maxBytes then
        break
      end
      bytes = bytes - entries[oldest].weight
      entries[oldest] = nil
    end
  end
  local function discard(test)
    for key, entry in pairs(entries) do
      if test(entry.value) then
        entries[key] = nil
        bytes = bytes - entry.weight
      end
    end
  end
  local function scrub(replace)
    local changes = {}
    for key, entry in pairs(entries) do
      local updated = replace(entry.value)
      if updated then changes[key] = updated end
    end
    for key, value in pairs(changes) do put(key, value) end
  end
  return { get = get, put = put, discard = discard, scrub = scrub }
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
    local value = { device = device, kind = page }
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
  local function remember(view, expectedKey)
    -- Accept only the exact request, never another page or a late response.
    if
      view
      and view.key == (expectedKey or model.pageKey)
      and view.status == "ready"
      and not view.partial
      and type(view.data) == "table"
    then
      local device, kind = view.device or model.pageDevice, view.kind or model.page
      views.put(view.key, {
        key = view.key, status = "ready", data = view.data, device = device, kind = kind,
        thread = view.thread or (kind == "messages" and model.thread and model.thread.id or ""),
      }, kind == "photos" and device or nil)
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
        device = saved.device,
        kind = saved.kind,
        thread = saved.thread,
        stale = true,
        refreshing = not incoming or incoming.key ~= key or incoming.status == "loading",
        refreshFailed = incoming and incoming.key == key and incoming.status ~= "loading" or false,
        error = incoming and incoming.key == key and incoming.error or nil,
      }
    end
    return incoming and incoming.key == key and incoming or nil
  end
  local function discard(test)
    views.discard(test)
    navigation.discard(test)
  end
  local function clear()
    views = store(24, 4 * 1024 * 1024)
    navigation = store(32, 256 * 1024)
    model.pageView = nil
  end
  local function revokeSms(affected)
    views.discard(function(v) return v.kind == "messages" and affected(v.device) and access.smsThread(v.thread) end)
    views.scrub(function(v)
      if v.kind == "messages" and affected(v.device) and v.thread == "" then
        local data = access.withoutSms(v.data)
        if data ~= v.data then
          return { key = v.key, status = v.status, data = data, device = v.device, kind = v.kind, thread = "" }
        end
      end
    end)
    navigation.discard(function(v)
      return v.kind == "messages" and affected(v.device) and v.thread
        and (v.thread.kind == "sms" or access.smsThread(v.thread.id))
    end)
  end
  local function revokeChats(policy, previousInstance)
    views.discard(function(v)
      return v.kind == "messages" and access.chatThread(v.thread)
        and not access.allowsScope(policy, v.data.appScope, previousInstance)
    end)
    views.scrub(function(v)
      if v.kind == "messages" and v.thread == "" then
        local data = access.withoutHiddenChats(v.data, policy, previousInstance)
        if data ~= v.data then
          return { key = v.key, status = v.status, data = data, device = v.device, kind = v.kind, thread = "" }
        end
      end
    end)
    navigation.scrub(function(v)
      if v.kind == "messages" and v.thread and access.chatThread(v.thread.id)
        and not access.allowsScope(policy, v.thread.appScope, previousInstance)
      then
        local next = {}
        for field, value in pairs(v) do next[field] = value end
        next.thread, next.before, next.beforeId = nil, nil, nil
        next.offset, next.cursors = 0, {}
        return next
      end
    end)
  end
  return {
    save = save, restore = restore, remember = remember, resolve = resolve, clear = clear, discard = discard,
    revokeSms = revokeSms, revokeChats = revokeChats,
    saved = function(key)
      return views.get(key)
    end,
  }
end
return M
