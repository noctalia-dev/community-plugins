-- Account-scoped notification snapshots and optimistic, versioned read actions.
-- No token access: every GitHub request uses the existing gh session.
local Notifications = {}

-- gh performs this projection outside the Luau callback's 25 ms CPU budget.
local fields = "{id, updated_at, unread, last_read_at, reason, subject: (.subject | {title, url, type}), repository: (.repository | {full_name})}"
local projection = 'if type == "array" then map(' .. fields .. ') elif type == "object" and has("id") then ' .. fields .. ' else . end'
local idleInterval, busyInterval, requestTimeout = 5000, 16, 120

local function validSnapshot(items, step)
  if type(items) ~= "table" then return false end
  local count = 0
  for index, item in pairs(items) do
    if type(index) ~= "number" or index < 1 or index % 1 ~= 0 or type(item) ~= "table"
      or type(item.unread) ~= "boolean" then return false end
    for _, field in ipairs({ "id", "title", "reason", "type", "repository", "url", "updatedAt", "lastReadAt" }) do
      if type(item[field]) ~= "string" then return false end
    end
    if not item.id:match("^%d+$") then return false end
    count = count + 1
    step(count)
  end
  return count == #items
end

local function copy(item)
  local result = {}
  for key, value in pairs(item) do result[key] = value end
  return result
end

local function response(result)
  local output = tostring(result.stdout or "")
  -- Search only for the header delimiter. A pattern over the entire REST body
  -- can exhaust the callback budget before JSON decoding even begins.
  local first, last = output:find("\r\n\r\n", 1, true)
  if not first then first, last = output:find("\n\n", 1, true) end
  local head = first and output:sub(1, first - 1) or output
  local body = last and output:sub(last + 1) or ""
  local headers = {}
  for line in head:gsub("\r\n", "\n"):gmatch("[^\n]+") do
    local key, value = line:match("^([^:]+):%s*(.*)$")
    if key then headers[string.lower(key)] = value end
  end
  return tonumber(head:match("^HTTP/%S+%s+(%d+)")), headers, body
end

function Notifications.new(env, Data, clock, workClock)
  local self = {}
  local now = clock or os.time
  local elapsed = workClock or os.clock
  local account, generation = nil, 0
  local serverItems, serverUnread, overrides, pageCache, serverById = {}, {}, {}, {}, {}
  local queue, writeBusy, readBusy = {}, false, false
  local activeWriteId, activeWrite
  local nextPoll, nextAllowed, queuedRefresh = 0, 0, false
  local revision, failures, lastUpdate = 0, 0, 0
  local readError, writeErrors = "", {}
  local readSerial, readDeadline, readJob = 0, 0, nil
  local publishSerial, cacheJob, bulkJob, viewJob, viewDirty = 0, nil, nil, nil, false
  local views = {}
  local metadataJob, metadataDirty, pendingIds, readBalance = nil, false, {}, 0
  local cached, cachePath
  local dataDir = env.pluginDataDir()
  if dataDir then
    cachePath = dataDir .. "/notifications.json"
    local raw = env.readFile(cachePath)
    if raw then cached = env.json.decode(raw) end
  end

  local function synced() return env.getConfig("notification_sync_mode") == "synced" end
  local function tickInterval(ms) env.setUpdateInterval(ms) end
  local function updateTicker()
    tickInterval((readJob or cacheJob or bulkJob or viewJob or metadataJob or (not writeBusy and #queue > 0)) and busyInterval or idleInterval)
  end
  local function activeRead(serial) return readBusy and serial == readSerial end
  local function scheduleRead(serial, callback)
    if not activeRead(serial) then return end
    readDeadline = now() + requestTimeout
    readJob = coroutine.create(callback)
    tickInterval(busyInterval)
  end
  local function readCallback(serial, callback)
    return function(result, failure)
      scheduleRead(serial, function() callback(result, failure) end)
    end
  end
  local function pause(index)
    if index % 10 == 0 then coroutine.yield() end
  end
  local function resumeSlice(job, deadline)
    -- Keep small checkpoints, but avoid sleeping a frame after every one.
    -- Monotonic elapsed time includes native work; the hard resume cap also
    -- bounds a tick when the clock has poor resolution. No network polling is
    -- accelerated: only already-scheduled local coroutine work is advanced.
    local ok, error = true, nil
    for _ = 1, 16 do
      if elapsed() >= deadline then break end
      ok, error = coroutine.resume(job)
      if not ok or error == "frame" or coroutine.status(job) == "dead" then break end
    end
    return ok, error
  end
  local function interval()
    if synced() then return math.max(60, tonumber(env.getConfig("notification_refresh_interval_seconds")) or 120) end
    return math.clamp(tonumber(env.getConfig("refresh_interval_minutes")) or 15, 5, 30) * 60
  end
  local function historyCutoff(rounded)
    local days = math.clamp(tonumber(env.getConfig("notification_history_days")) or 30, 1, 90)
    return os.date(rounded and "!%Y-%m-%dT00:00:00Z" or "!%Y-%m-%dT%H:%M:%SZ", now() - days * 86400)
  end
  local function isUnread(item)
    local record = overrides[item.id]
    return item.unread and (not record or item.updatedAt > record.updatedAt)
  end
  local function effective(item)
    local view = views[item.id]
    if not view or view.source ~= item then
      view = { source = item, item = copy(item) }; views[item.id] = view
    end
    view.item.unread = isUnread(item)
    return view.item
  end
  local function unreadFor(id)
    local item = serverById[id]
    return item ~= nil and isUnread(item)
  end
  local function changedRead(id, before)
    local after = unreadFor(id)
    readBalance = readBalance + (after and 1 or 0) - (before and 1 or 0)
    pendingIds[id] = overrides[id] and overrides[id].pending and true or nil
  end
  local function cancelPending(id, record)
    local item = serverById[id]
    if item and item.unread and item.updatedAt <= record.updatedAt then readBalance = readBalance + 1 end
    overrides[id], pendingIds[id] = nil, nil
    local view = views[id]
    if item and view and view.source == item then view.item.unread = item.unread end
  end
  local publish
  publish = function(step, metadataOnly, viewOnly)
    if metadataOnly and #serverUnread > 1000 then
      if metadataJob then metadataDirty = true; return end
      local expectedGeneration, unread, records, balance = generation, serverUnread, table.clone(overrides), readBalance
      metadataJob = coroutine.create(function()
        local count = 0
        for i, item in ipairs(unread) do
          local record = records[item.id]
          if item.unread and (not record or item.updatedAt > record.updatedAt) then count = count + 1 end
          if i % 100 == 0 then coroutine.yield() end
        end
        coroutine.yield("frame")
        if generation ~= expectedGeneration or unread ~= serverUnread then return end
        -- Local mutations after this immutable snapshot contribute a delta;
        -- continuous writes cannot starve publication or restore an old count.
        env.state.set("notifications_count", math.clamp(count + readBalance - balance, 0, #unread))
        env.state.set("notifications_pending", pendingIds)
        coroutine.yield("frame")
        if generation ~= expectedGeneration or unread ~= serverUnread then return end
        env.state.set("notifications_last_update", lastUpdate)
        local errors = {}
        if readError ~= "" then errors[#errors + 1] = readError end
        for _, message in pairs(writeErrors) do errors[#errors + 1] = message end
        env.state.set("notifications_error", table.concat(errors, "\n"))
        if metadataDirty then metadataDirty = false; publish(nil, true) end
      end)
      updateTicker(); return
    end
    if not step and not metadataOnly and #serverItems > 250 then
      if viewJob then viewDirty = true
      else
        local expectedGeneration = generation
        viewJob = coroutine.create(function()
          publish(function(index) if index % 100 == 0 then coroutine.yield() end end, false, true)
          coroutine.yield("frame")
          if generation ~= expectedGeneration then return end
          if viewDirty then viewDirty = false; publish()
          else publish(nil, true) end
        end)
      end
      updateTicker()
      publish(nil, true)
      return
    end
    if not metadataOnly then publishSerial = publishSerial + 1 end
    local serial = publishSerial
    local advance = step or function() end
    local items, pending, count = {}, {}, 0
    local cutoff = historyCutoff()
    if not metadataOnly then
      for i, item in ipairs(serverItems) do
        local projected = effective(item)
        -- History limits read items only; every unread item remains actionable.
        if projected.unread or tostring(item.updatedAt or "") >= cutoff then items[#items + 1] = projected end
        advance(i)
        if serial ~= publishSerial then return end
      end
    end
    if viewOnly then
      coroutine.yield("frame")
      if serial ~= publishSerial then return end
      env.state.set("notifications", items)
      coroutine.yield("frame")
      return
    end
    for i, item in ipairs(serverUnread) do
      if isUnread(item) then count = count + 1 end
      advance(i)
      if serial ~= publishSerial then return end
    end
    for id, record in pairs(overrides) do if record.pending then pending[id] = true end end
    if not metadataOnly then
      if step and #serverItems > 250 then coroutine.yield("frame") end
      if serial ~= publishSerial then return end
      env.state.set("notifications", items)
      if step and #serverItems > 250 then coroutine.yield("frame") end
      if serial ~= publishSerial then return end
    end
    env.state.set("notifications_count", count)
    env.state.set("notifications_pending", pending)
    env.state.set("notifications_last_update", lastUpdate)
    local errors = {}
    if readError ~= "" then errors[#errors + 1] = readError end
    for _, message in pairs(writeErrors) do errors[#errors + 1] = message end
    env.state.set("notifications_error", table.concat(errors, "\n"))
  end
  local function persist()
    if not cachePath or not account then return end
    local expectedAccount, expectedGeneration, expectedRevision = account, generation, revision
    local snapshot, updated = serverItems, lastUpdate
    -- Encode bounded record groups on separate ticks. The outer JSON contains
    -- strings, so the host never marshals the entire object graph in one call.
    cacheJob = coroutine.create(function()
      local chunks, versions, batch = {}, {}, {}
      for i, item in ipairs(snapshot) do
        batch[#batch + 1] = item
        if #batch == 50 or i == #snapshot then
          chunks[#chunks + 1] = assert(env.json.encode(batch))
          batch = {}; coroutine.yield()
        end
      end
      for id, record in pairs(overrides) do
        if not record.pending then
          batch[#batch + 1] = { id = id, updatedAt = record.updatedAt, expiresAt = record.expiresAt }
          if #batch == 50 then
            versions[#versions + 1] = assert(env.json.encode(batch))
            batch = {}; coroutine.yield()
          end
        end
      end
      if #batch > 0 then versions[#versions + 1] = assert(env.json.encode(batch)); coroutine.yield() end
      -- A newer snapshot/action may replace or invalidate work between chunks.
      if account ~= expectedAccount or generation ~= expectedGeneration or revision ~= expectedRevision
        or serverItems ~= snapshot then return end
      coroutine.yield("frame")
      if account ~= expectedAccount or generation ~= expectedGeneration or revision ~= expectedRevision
        or serverItems ~= snapshot then return end
      local encoded = assert(env.json.encode({ schema = 2, login = expectedAccount, chunks = chunks,
        read_versions = versions, last_update = updated }))
      coroutine.yield("frame")
      if account ~= expectedAccount or generation ~= expectedGeneration or revision ~= expectedRevision
        or serverItems ~= snapshot then return end
      local ok, error = env.writeFile(cachePath, encoded)
      assert(ok, error or "cache file write failed")
    end)
    updateTicker()
  end
  local function restoreCache(login)
    if type(cached) ~= "table" or cached.login ~= login then return nil end
    if cached.schema == 1 then
      if validSnapshot(cached.items, pause) and validSnapshot(cached.unread, pause) then return cached end
      return nil
    end
    if cached.schema ~= 2 or type(cached.chunks) ~= "table" or type(cached.read_versions) ~= "table" then return nil end
    local restored = { items = {}, unread = {}, overrides = {}, last_update = cached.last_update }
    for _, chunk in ipairs(cached.chunks) do
      if type(chunk) ~= "string" then return nil end
      local items = env.json.decode(chunk)
      if not validSnapshot(items, pause) then return nil end
      for i, item in ipairs(items) do
        restored.items[#restored.items + 1] = item
        if item.unread then restored.unread[#restored.unread + 1] = item end
        pause(i)
      end
    end
    for _, chunk in ipairs(cached.read_versions) do
      if type(chunk) ~= "string" then return nil end
      local records = env.json.decode(chunk)
      if type(records) ~= "table" then return nil end
      for i, record in ipairs(records) do
        if type(record) ~= "table" or type(record.id) ~= "string" then return nil end
        restored.overrides[record.id] = record; pause(i)
      end
    end
    return restored
  end
  local function run(argv, callback)
    local called = false
    local started = env.runAsync(argv, function(result) called = true; callback(result) end)
    if not started and not called then callback({ exitCode = -1, stderr = env.tr("status.cli_start_failed") }) end
  end
  local function api(endpoint, method)
    local argv = { "gh", "api", "--hostname", "github.com", "--include", "--method", method or "GET",
      "-H", "Accept: application/vnd.github+json", "-H", "X-GitHub-Api-Version: 2022-11-28", endpoint }
    if method == nil or method == "GET" then
      argv[#argv + 1] = "--jq"; argv[#argv + 1] = projection
    end
    return argv
  end
  local function message(result)
    local text = tostring(result.stderr or ""):match("[^\r\n]+")
    return text and text ~= "" and text or env.tr("status.gh_request_failed")
  end
  local function statusError(text)
    local lower = string.lower(text)
    local auth = lower:find("401", 1, true) or lower:find("403", 1, true) or lower:find("auth", 1, true)
      or lower:find("scope", 1, true) or lower:find("token", 1, true)
    local limited = lower:find("rate limit", 1, true) or lower:find("rate-limit", 1, true) or lower:find("429", 1, true)
    env.state.set("notifications_status", limited and "rate_limited" or (auth and "auth_error" or "error"))
  end
  local function failRead(failure)
    readSerial, readBusy, readJob = readSerial + 1, false, nil
    failures = math.min(failures + 1, 4)
    nextAllowed = math.max(nextAllowed, now() + 60 * 2 ^ (failures - 1))
    queuedRefresh, readError = true, failure
    statusError(readError); publish(); updateTicker()
  end
  local function identity(callback, runner)
    (runner or run)({ "gh", "api", "--hostname", "github.com", "user", "--jq", ".login" }, function(result)
      local login = tostring(result.stdout or ""):match("^%s*([%w%-]+)%s*$")
      if result.exitCode ~= 0 or not login then callback(nil, message(result)); return end
      callback(string.lower(login))
    end)
  end
  local function setAccount(login)
    if account == login then return end
    account, generation = login, generation + 1
    -- Old-account commands may finish later; their tokens no longer own a slot.
    writeBusy, activeWriteId, activeWrite = false, nil, nil
    serverItems, serverUnread, overrides, pageCache, queue, serverById = {}, {}, {}, {}, {}, {}
    writeErrors, lastUpdate, revision, cacheJob, bulkJob, views, viewJob, viewDirty = {}, 0, 0, nil, nil, {}, nil, false
    metadataJob, metadataDirty, pendingIds, readBalance = nil, false, {}, 0
    local restoredCache = restoreCache(login)
    if restoredCache then
      serverItems, serverUnread = restoredCache.items, restoredCache.unread
      for i, item in ipairs(serverItems) do serverById[item.id] = item; pause(i) end
      lastUpdate = tonumber(restoredCache.last_update) or 0
      local restored = 0
      for id, record in pairs(type(restoredCache.overrides) == "table" and restoredCache.overrides or {}) do
        if type(record) == "table" and type(record.updatedAt) == "string" and not record.pending
          and tonumber(record.expiresAt) and tonumber(record.expiresAt) > now() then
          overrides[id] = copy(record)
          overrides[id].expiresAt = tonumber(record.expiresAt)
          overrides[id].confirmedRevision = 0
        end
        restored = restored + 1; pause(restored)
      end
    end
    cached = nil
    publish(pause)
    updateTicker()
  end
  local function pollHeaders(headers)
    nextAllowed = math.max(nextAllowed, now() + math.max(60, tonumber(headers["x-poll-interval"]) or 60))
    local retry = tonumber(headers["retry-after"])
    if retry then nextAllowed = math.max(nextAllowed, now() + retry) end
    if headers["x-ratelimit-remaining"] == "0" then
      nextAllowed = math.max(nextAllowed, tonumber(headers["x-ratelimit-reset"]) or 0)
    end
  end
  local function fetchPages(all, cutoff, expectedGeneration, serial, cache, callback)
    local items, seen = {}, {}
    local function page(number)
      local endpoint = "notifications?all=" .. tostring(all) .. "&per_page=50&page=" .. tostring(number)
      if cutoff then endpoint = endpoint .. "&since=" .. cutoff end
      local previous = pageCache[endpoint]
      local argv = api(endpoint)
      if previous and previous.modified then
        argv[#argv + 1] = "-H"; argv[#argv + 1] = "If-Modified-Since: " .. previous.modified
      end
      if previous and previous.etag then
        argv[#argv + 1] = "-H"; argv[#argv + 1] = "If-None-Match: " .. previous.etag
      end
      run(argv, readCallback(serial, function(result)
        if expectedGeneration ~= generation then callback(nil, env.tr("status.auth_error")); return end
        local code, headers, body = response(result)
        pollHeaders(headers)
        local entry
        if code == 304 and previous then
          entry = previous
        elseif result.exitCode == 0 and code == 200 then
          local raw = env.json.decode(body)
          if type(raw) ~= "table" or (next(raw) ~= nil and raw[1] == nil) then
            callback(nil, env.tr("status.invalid_json")); return
          end
          local normalized = {}
          -- Decode only the projected page, then normalize bounded batches on
          -- separate update ticks instead of inside the command callback.
          coroutine.yield("frame")
          for i, item in ipairs(raw) do
            if type(item) ~= "table" or not tostring(item.id or ""):match("^%d+$")
              or type(item.updated_at) ~= "string" or type(item.unread) ~= "boolean" then
              callback(nil, env.tr("status.unexpected_data")); return
            end
            normalized[#normalized + 1] = Data.notification(item)
            pause(i)
          end
          entry = { items = normalized, modified = headers["last-modified"], etag = headers.etag,
            more = headers.link and headers.link:find('rel="next"', 1, true) ~= nil or #raw == 50 }
        else callback(nil, message(result)); return end
        cache[endpoint] = entry
        for i, item in ipairs(entry.items) do
          if not seen[item.id] then seen[item.id] = true; items[#items + 1] = item end
          pause(i)
        end
        if entry.more then page(number + 1) else callback(items) end
      end))
    end
    page(1)
  end

  function self.refresh()
    queuedRefresh = true
    if readBusy or now() < nextAllowed then return end
    queuedRefresh, readBusy = false, true
    readSerial = readSerial + 1
    local serial = readSerial
    readDeadline = now() + requestTimeout
    nextPoll = now() + interval()
    if not env.commandExists("gh") then
      readBusy = false; readError = env.tr("status.missing_gh")
      env.state.set("notifications_status", "missing_gh"); publish(); return
    end
    readError = ""
    env.state.set("notifications_status", "loading")
    publish()
    identity(readCallback(serial, function(login, error)
      if not login then
        failRead(error); return
      end
      setAccount(login)
      local expectedGeneration, startedRevision = generation, revision
      local cache, cutoff = {}, historyCutoff(true)
      local function finish(items, unread, failure)
        if not activeRead(serial) then return end
        if failure then
          failRead(failure); return
        end
        if expectedGeneration ~= generation then return end
        local byId = {}
        for i, item in ipairs(items) do byId[item.id] = copy(item); pause(i) end
        local unreadById = {}
        for i, item in ipairs(unread) do
          local previous = byId[item.id]
          -- Read state may change without a version change, but an older page
          -- must not discard newer thread content or hide its unread update.
          if not previous or item.updatedAt >= previous.updatedAt then byId[item.id] = copy(item) end
          if byId[item.id].unread then unreadById[item.id] = byId[item.id] end
          pause(i)
        end
        local sortKeys = {}
        for id, item in pairs(byId) do
          item.unread = unreadById[id] ~= nil
          sortKeys[#sortKeys + 1] = item.updatedAt .. "\0" .. id
          pause(#sortKeys)
        end
        -- Native string sorting avoids thousands of Luau comparator calls in
        -- one update. IDs make equal timestamps deterministic without dropping
        -- records; extraction and projection remain split across ticks.
        table.sort(sortKeys)
        local combined, canonicalUnread = {}, {}
        for i = #sortKeys, 1, -1 do
          local key = sortKeys[i]
          local item = byId[key:sub(key:find("\0", 1, true) + 1)]
          combined[#combined + 1] = item
          if item.unread then canonicalUnread[#canonicalUnread + 1] = item end
          pause(#combined)
        end
        if expectedGeneration ~= generation then
          readBusy, queuedRefresh = false, true
          return
        end
        -- Commit a complete snapshot only after every page/batch succeeds.
        failures, readError, lastUpdate = 0, "", now()
        -- A newer mutation invalidates conditional pages collected before it.
        pageCache = startedRevision == revision and cache or {}
        serverItems, serverUnread, serverById, views, viewJob, viewDirty = combined, canonicalUnread, byId, {}, nil, false
        metadataJob, metadataDirty, readBalance = nil, false, 0
        for id, record in pairs(overrides) do
          if not record.pending and startedRevision >= (record.confirmedRevision or 0) then
            local remote = unreadById[id]
            if not remote or remote.updatedAt > record.updatedAt or now() >= record.expiresAt then overrides[id] = nil end
          end
        end
        if startedRevision == revision then
          for id in pairs(writeErrors) do if not unreadById[id] then writeErrors[id] = nil end end
        end
        publish(pause)
        if expectedGeneration == generation and activeRead(serial) then
          env.state.set("notifications_status", next(writeErrors) and "error" or "ready")
          persist()
        end
        readBusy = false
      end
      fetchPages(true, cutoff, expectedGeneration, serial, cache, function(items, error)
        if not items then finish(nil, nil, error); return end
        fetchPages(false, nil, expectedGeneration, serial, cache, function(unread, failure) finish(items, unread, failure) end)
      end)
    end))
  end

  local drain
  drain = function()
    if writeBusy or #queue == 0 then return end
    local action = table.remove(queue, 1)
    local record = overrides[action.id]
    if not record or record ~= action.record then updateTicker(); return end
    writeBusy, activeWriteId, activeWrite = true, action.id, action
    updateTicker()
    local expectedAccount, expectedGeneration = account, generation
    local function finish(ok, error)
      if activeWrite ~= action then return end
      writeBusy, activeWriteId, activeWrite = false, nil, nil
      updateTicker()
      if generation == expectedGeneration and overrides[action.id] == record then
        local wasUnread = unreadFor(action.id)
        revision = revision + 1
        if ok then
          record.pending, record.confirmedRevision, record.expiresAt = false, revision, now() + 600
          writeErrors[action.id] = nil
          if not readBusy and readError == "" and not next(writeErrors) then env.state.set("notifications_status", "ready") end
        else
          overrides[action.id] = nil
          writeErrors[action.id] = error or env.tr("status.gh_request_failed")
          statusError(writeErrors[action.id])
        end
        changedRead(action.id, wasUnread)
        pageCache = {}; queuedRefresh = true
        if serverById[action.id] then effective(serverById[action.id]) end
        publish(); persist()
      end
    end
    action.cancel = function()
      -- A missing PATCH reply is ambiguous: reconcile by reading, never replay
      -- the write. Release queued actions for an explicit manual retry as well.
      for _, waiting in ipairs(queue) do
        if overrides[waiting.id] == waiting.record then
          cancelPending(waiting.id, waiting.record)
        end
      end
      queue, bulkJob = {}, nil
      finish(false, env.tr("status.notification_write_timeout"))
    end
    local function runWrite(argv, callback)
      action.deadline = now() + requestTimeout
      run(argv, function(result)
        if activeWrite ~= action then return end
        if expectedGeneration ~= generation then finish(false); return end
        callback(result)
      end)
    end
    -- Recheck account and current thread version before every write, including batches.
    identity(function(login, error)
      if not login then finish(false, error); return end
      if login ~= expectedAccount or expectedGeneration ~= generation then
        if login ~= expectedAccount then setAccount(login) end
        finish(false, env.tr("status.auth_error")); self.refresh(); return
      end
      if not synced() then finish(false); return end
      runWrite(api("notifications/threads/" .. action.id), function(result)
        if expectedGeneration ~= generation then finish(false); return end
        local code, _, body = response(result)
        local raw = env.json.decode(body)
        if result.exitCode ~= 0 or code ~= 200 or type(raw) ~= "table" then finish(false, message(result)); return end
        if tostring(raw.id or "") ~= action.id or type(raw.updated_at) ~= "string" or type(raw.unread) ~= "boolean" then
          finish(false, env.tr("status.unexpected_data")); return
        end
        if tostring(raw.updated_at or "") > record.updatedAt then
          -- Do not consume a comment that arrived after the displayed notification.
          -- Counter jobs retain this array and old overrides across ticks. Drop
          -- their partial count before replacing an item with a newer version.
          metadataJob, metadataDirty = nil, false
          local fresh = Data.notification(raw)
          serverById[action.id] = fresh
          for i, item in ipairs(serverItems) do if item.id == action.id then serverItems[i] = fresh end end
          for i, item in ipairs(serverUnread) do if item.id == action.id then serverUnread[i] = fresh end end
          finish(false, env.tr("status.notification_changed")); return
        end
        if raw.unread == false then finish(true); return end
        if not synced() or generation ~= expectedGeneration then finish(false); return end
        runWrite(api("notifications/threads/" .. action.id, "PATCH"), function(patch)
          local status = response(patch)
          finish(patch.exitCode == 0 and (status == 205 or status == 304), message(patch))
        end)
      end)
    end, runWrite)
  end

  local function enqueue(action)
    local id = tostring(action.id or "")
    if not account or not id:match("^%d+$") or (overrides[id] and overrides[id].pending) then return end
    local target = serverById[id]
    if not target or not isUnread(target) or action.updatedAt ~= target.updatedAt then return end
    revision = revision + 1
    local record = { updatedAt = target.updatedAt, pending = true }
    overrides[id] = record; writeErrors[id] = nil
    changedRead(id, true)
    effective(target)
    queue[#queue + 1] = { id = id, record = record }
  end
  function self.action(action)
    if type(action) ~= "table" then return end
    if action.type == "refresh" then self.refresh(); return end
    if not synced() then return end
    if action.type == "mark_read" then enqueue(action)
    elseif action.type == "mark_visible_read" and type(action.items) == "table" then
      if #action.items > 250 then
        if bulkJob then return end
        local expectedGeneration = generation
        bulkJob = coroutine.create(function()
          for i, item in ipairs(action.items) do
            if expectedGeneration ~= generation or not synced() then return end
            if type(item) == "table" then enqueue(item) end
            if i % 100 == 0 then coroutine.yield() end
          end
          publish(); drain()
        end)
        updateTicker(); return
      end
      for _, item in ipairs(action.items) do if type(item) == "table" then enqueue(item) end end
    else return end
    publish(); drain()
  end
  function self.configure()
    if not synced() then
      queue, bulkJob = {}, nil
      for id, record in pairs(overrides) do
        if record.pending and id ~= activeWriteId then
          cancelPending(id, record)
        end
      end
    end
    updateTicker()
    self.refresh()
  end
  function self.update()
    local deadline = elapsed() + 0.002
    if activeWrite and now() >= activeWrite.deadline then activeWrite.cancel() end
    if not writeBusy and #queue > 0 then drain() end
    if readBusy and now() >= readDeadline then
      -- An aborted callback cannot release readBusy. Invalidate its late replies
      -- and retain the previous complete snapshot while backing off for retry.
      failRead(env.tr("status.notification_refresh_timeout"))
      return
    end
    if readJob then
      local job = readJob
      -- Clear before resuming: even a host CPU-budget abort leaves the watchdog
      -- able to recover, rather than resuming an abandoned coroutine forever.
      readJob = nil
      tickInterval(idleInterval)
      readDeadline = now() + requestTimeout
      local ok, error = resumeSlice(job, deadline)
      if not ok then
        env.log("Notification refresh processing failed: " .. tostring(error):sub(1, 300))
        failRead(env.tr("status.notification_refresh_failed")); return
      end
      if ok and coroutine.status(job) ~= "dead" and readBusy then readJob = job end
      updateTicker()
      return
    end
    if bulkJob then
      local job = bulkJob
      bulkJob = nil
      local ok, error = coroutine.resume(job)
      if not ok then
        env.log("Notification batch could not be queued: " .. tostring(error):sub(1, 300))
      elseif coroutine.status(job) ~= "dead" then bulkJob = job end
      updateTicker()
      return
    end
    if metadataJob then
      local job = metadataJob
      metadataJob = nil
      local ok, error = resumeSlice(job, deadline)
      if not ok then env.log("Notification counters could not be updated: " .. tostring(error):sub(1, 300))
      elseif coroutine.status(job) ~= "dead" then metadataJob = job end
      updateTicker()
      return
    end
    if viewJob then
      local job = viewJob
      viewJob = nil
      local ok, error = coroutine.resume(job)
      if not ok then env.log("Notification view could not be updated: " .. tostring(error):sub(1, 300))
      elseif coroutine.status(job) ~= "dead" then viewJob = job end
      updateTicker()
      return
    end
    if cacheJob then
      local job = cacheJob
      cacheJob = nil
      local ok, error = resumeSlice(job, deadline)
      if not ok then env.log("Notification cache could not be saved: " .. tostring(error):sub(1, 300))
      elseif coroutine.status(job) ~= "dead" then cacheJob = job end
      updateTicker()
      if cacheJob then return end
    end
    if now() >= nextAllowed and (queuedRefresh or now() >= nextPoll) then self.refresh() end
  end
  publish()
  env.state.set("notifications_status", "idle")
  return self
end

return Notifications
