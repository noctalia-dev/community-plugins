--!nonstrict
-- Bounded read-only cache. One request per key; epoch discards obsolete replies.
-- This module cannot send SMS, dial or execute Deck actions.
local M = {}
local size = require("../cache_size.luau")
-- Validate fields the UI consumes as strings, numbers and arrays.
-- A malformed response must not evict the last valid cached result.
local function finite(value)
  return type(value) == "number" and value == value and math.abs(value) <= 9007199254740991
end
local function optionalFields(value, names, kind)
  for _, name in ipairs(names) do
    local field = value[name]
    if field ~= nil and (type(field) ~= kind or (kind == "number" and not finite(field))) then
      return false
    end
  end
  return true
end
local function array(value, validItem)
  if type(value) ~= "table" then
    return false
  end
  local count = 0
  for key, item in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or not validItem(item) then
      return false
    end
    count = count + 1
  end
  for index = 1, count do
    if value[index] == nil then
      return false
    end
  end
  return true
end
local function validData(data)
  if
    type(data) ~= "table"
    or not optionalFields(data, { "notice" }, "string")
    or not optionalFields(data, { "more", "reply", "dial", "control" }, "boolean")
  then
    return false
  end
  if
    not array(data.items, function(item)
      return type(item) == "table"
        and type(item.id) == "string"
        and optionalFields(
          item,
          { "title", "subtitle", "kind", "number", "thumbnailPath", "iconPath" },
          "string"
        )
        and optionalFields(item, { "date", "size", "duration" }, "number")
        and (item.size == nil or item.size >= 0)
        and (item.duration == nil or item.duration >= 0)
        and (
          item.addresses == nil
          or array(item.addresses, function(address)
            return type(address) == "string"
          end)
        )
    end)
  then
    return false
  end
  if
    data.albums ~= nil
    and not array(data.albums, function(album)
      return type(album) == "table"
        and type(album.id) == "string"
        and optionalFields(album, { "name" }, "string")
    end)
  then
    return false
  end
  if data.active ~= nil then
    local active = data.active
    if
      type(active) ~= "table"
      or type(active.state) ~= "string"
      or not optionalFields(active, { "id", "name", "number" }, "string")
      or (active.state ~= "ended" and type(active.id) ~= "string")
    then
      return false
    end
  end
  return true
end
function M.new(cache, visibility, clock, snapshot, api, publish, onlineDevice, copy, limits)
  -- cache owns original responses; snapshot.page is the displayed projection.
  -- clock.ticks measures scheduler intervals, nowMs measures entry age.
  local credentials = api.credentials
  local request = api.request
  local PAGE_TTL_TICKS = { messages = 10, calls = 2, photos = 60, apps = 150, deck = 15 }
  local maxBytes = limits.pageCacheBytes or 4 * 1024 * 1024
  cache.errors = cache.errors or {}

  local function resetPages()
    cache.entries = {}
    cache.jobs = {}
    cache.retry = {}
    cache.errors = {}
    cache.epoch = cache.epoch + 1
    snapshot.page = nil
    snapshot.cacheEpoch = cache.epoch
  end

  local function pageIdentity(command)
    -- Length prefixes prevent collisions from separators inside search/id fields.
    local query = command.value
    local fields = {
      command.device,
      query.page,
      query.thread or "",
      query.album or "",
      tostring(query.before or ""),
      query.before_id or "",
      tostring(query.offset or 0),
      query.search or "",
      tostring(query.limit or 5),
    }
    for i, value in ipairs(fields) do
      local text = tostring(value)
      fields[i] = tostring(#text) .. ":" .. text
    end
    return table.concat(fields)
  end

  local function cacheTime()
    return noctalia.nowMs and noctalia.nowMs() or clock.ticks * limits.updateIntervalMs
  end

  local function previewData(data)
    -- Runtime JSON/state transfer copies data. Clone a page only when removing
    -- a missing preview, not on every warm read.
    local out = data
    local valid = true
    if noctalia.fileExists then
      for index, item in ipairs(data.items or {}) do
        for _, field in ipairs({ "thumbnailPath", "iconPath" }) do
          if type(item[field]) == "string" and not noctalia.fileExists(item[field]) then
            if out == data then
              out = copy(data)
            end
            out.items[index][field] = nil
            valid = false
          end
        end
      end
    end
    return out, valid
  end

  local function showPage(command, entry, refreshing, stale, err, preparedData, reason)
    local data = preparedData or (entry and previewData(entry.data) or nil)
    snapshot.page = {
      key = command.value.key,
      status = data and "ready" or (err or "loading"),
      data = data,
      refreshing = refreshing or false,
      stale = stale or false,
      error = reason,
    }
  end

  local function trimPages()
    -- Entry counts alone are insufficient: one page may contain large text.
    -- Estimate sizes on response arrival, not on every warm read.
    while true do
      local count, bytes, oldest, stamp = 0, 0, nil, math.huge
      for key, entry in pairs(cache.entries) do
        count = count + 1
        entry.weight = entry.weight or size(entry.data, maxBytes)
        bytes = bytes + entry.weight
        if entry.used < stamp then
          oldest, stamp = key, entry.used
        end
      end
      if count <= limits.pageCacheLimit and bytes <= maxBytes then
        return
      end
      cache.entries[oldest] = nil
    end
  end

  local function invalidateKind(device, kind)
    for key, e in pairs(cache.entries) do
      if e.device == device and e.kind == kind then
        cache.entries[key] = nil
        cache.retry[key] = nil
        cache.errors[key] = nil
      end
    end
    for key, e in pairs(cache.jobs) do
      if e.device == device and e.kind == kind then
        cache.jobs[key] = nil
      end
    end
  end

  local function readPage(command, quiet, force)
    -- quiet preserves selection; force bypasses TTL but not single-flight.
    local config, credentialError = credentials()
    if not config then
      resetPages()
      snapshot.state = "unconfigured"
      snapshot.error = credentialError
      publish()
      return
    end
    local query = command.value
    local key = pageIdentity(command)
    local entry = cache.entries[key]
    cache.clock = cache.clock + 1
    if entry then
      entry.used = cache.clock
    end
    local valid = true
    local displayData
    if entry then
      displayData, valid = previewData(entry.data)
    end
    local age = entry and cacheTime() - entry.at or 0
    local fresh = entry
      and not entry.failed
      and age >= 0
      and age < (PAGE_TTL_TICKS[query.page] or 10) * limits.updateIntervalMs
      and valid
    if query.page ~= "deck" and not onlineDevice(command.device) then
      showPage(command, entry, false, true, "failed", displayData, "phone_offline")
      publish()
      return
    end
    force = force == true or (not quiet and query.force == true)
    local backendForce = force or (entry and entry.failed) or false
    if not quiet and (entry or cache.jobs[key]) then
      showPage(
        command,
        entry,
        cache.jobs[key] ~= nil,
        entry ~= nil and not fresh,
        nil,
        displayData,
        entry and entry.error
      )
      publish()
    end
    if fresh and not force then
      return
    end
    if cache.jobs[key] then
      return
    end
    if not force and cache.retry[key] and clock.ticks < cache.retry[key] then
      if not entry then
        -- Retain the last error reason while throttling repeated reads.
        showPage(command, nil, false, true, "failed", nil, cache.errors[key] or "request_failed")
        publish()
      end
      return
    end
    local job =
      { epoch = cache.epoch, started = clock.ticks, device = command.device, kind = query.page }
    cache.jobs[key] = job
    if not quiet or not entry then
      showPage(command, entry, true, entry ~= nil, nil, displayData)
      publish()
    end
    request("/v1/page", {
      device = command.device,
      page = query.page,
      thread = query.thread,
      album = query.album,
      before = query.before,
      before_id = query.before_id,
      offset = query.offset,
      search = query.search,
      limit = query.limit,
      force = backendForce,
    }, function(ok, status, data, reason)
      -- Removed/replaced job or changed epoch: this response no longer has an owner.
      if cache.jobs[key] ~= job or job.epoch ~= cache.epoch then
        return
      end
      cache.jobs[key] = nil
      if status == 401 then
        resetPages()
        snapshot.state = "unauthorized"
        snapshot.error = "unauthorized"
        publish()
        return
      end
      local valid = validData(data)
      if ok and not valid then
        reason = "invalid_response"
      end
      ok = ok and valid
      if not ok then
        reason = reason or (status == 404 and "unsupported" or "request_failed")
      end
      local displayEntry = cache.entries[key]
      if ok then
        cache.clock = cache.clock + 1
        displayEntry = {
          data = data,
          at = cacheTime(),
          used = cache.clock,
          device = command.device,
          kind = query.page,
          weight = size(data, maxBytes),
        }
        -- Display an oversized response without retaining it in the cache;
        -- otherwise a single entry could exceed the whole storage budget.
        cache.entries[key] = displayEntry.weight <= maxBytes and displayEntry or nil
        cache.retry[key] = nil
        cache.errors[key] = nil
        trimPages()
      else
        cache.retry[key] = clock.ticks + limits.pageRetryTicks
        cache.errors[key] = reason
        if cache.entries[key] then
          cache.entries[key].failed = true
          cache.entries[key].error = reason
        end
      end
      if
        visibility.open
        and visibility.activePage
        and pageIdentity(visibility.activePage) == key
      then
        showPage(
          visibility.activePage,
          displayEntry,
          false,
          not ok,
          status == 404 and "unsupported" or "failed",
          nil,
          not ok and reason or nil
        )
        publish()
      end
    end, config)
  end
  return {
    reset = resetPages,
    identity = pageIdentity,
    show = showPage,
    invalidate = invalidateKind,
    read = readPage,
  }
end
return M
