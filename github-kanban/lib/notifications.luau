-- Account-scoped notification snapshots and optimistic, versioned read actions.
-- No token access: every GitHub request uses the existing gh session.
local Notifications = {}

-- gh performs this projection outside the Luau callback's 25 ms CPU budget.
local fields = "{id, updated_at, unread, last_read_at, reason, subject: (.subject | {title, url, type}), repository: (.repository | {full_name})}"
local projection = 'if type == "array" then map(' .. fields .. ') elif type == "object" and has("id") then ' .. fields .. ' else . end'
local idleInterval, busyInterval, readTimeout = 5000, 16, 120

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

function Notifications.new(env, Data, clock)
  local self = {}
  local now = clock or os.time
  local account, generation = nil, 0
  local serverItems, serverUnread, overrides, pageCache = {}, {}, {}, {}
  local queue, writeBusy, readBusy = {}, false, false
  local activeWriteId
  local nextPoll, nextAllowed, queuedRefresh = 0, 0, false
  local revision, failures, lastUpdate = 0, 0, 0
  local readError, writeErrors = "", {}
  local readSerial, readDeadline, readJob = 0, 0, nil
  local cached, cachePath
  local dataDir = env.pluginDataDir()
  if dataDir then
    cachePath = dataDir .. "/notifications.json"
    local raw = env.readFile(cachePath)
    if raw then cached = env.json.decode(raw) end
  end

  local function synced() return env.getConfig("notification_sync_mode") == "synced" end
  local function tickInterval(ms) env.setUpdateInterval(ms) end
  local function activeRead(serial) return readBusy and serial == readSerial end
  local function scheduleRead(serial, callback)
    if not activeRead(serial) then return end
    readDeadline = now() + readTimeout
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
  local function interval()
    if synced() then return math.max(60, tonumber(env.getConfig("notification_refresh_interval_seconds")) or 120) end
    return math.clamp(tonumber(env.getConfig("refresh_interval_minutes")) or 15, 5, 30) * 60
  end
  local function historyCutoff(rounded)
    local days = math.clamp(tonumber(env.getConfig("notification_history_days")) or 30, 1, 90)
    return os.date(rounded and "!%Y-%m-%dT00:00:00Z" or "!%Y-%m-%dT%H:%M:%SZ", now() - days * 86400)
  end
  local function effective(item)
    local result = copy(item)
    local record = overrides[item.id]
    if record and tostring(item.updatedAt or "") <= record.updatedAt then result.unread = false end
    return result
  end
  local function publish()
    local items, pending, count = {}, {}, 0
    local cutoff = historyCutoff()
    for _, item in ipairs(serverItems) do
      local projected = effective(item)
      -- History limits read items only; every unread item remains actionable.
      if projected.unread or tostring(item.updatedAt or "") >= cutoff then items[#items + 1] = projected end
    end
    for _, item in ipairs(serverUnread) do if effective(item).unread then count = count + 1 end end
    for id, record in pairs(overrides) do if record.pending then pending[id] = true end end
    env.state.set("notifications", items)
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
    local confirmed = {}
    for id, record in pairs(overrides) do if not record.pending then confirmed[id] = record end end
    local encoded = env.json.encode({ schema = 1, login = account, items = serverItems,
      unread = serverUnread, overrides = confirmed, last_update = lastUpdate })
    if encoded then env.writeFile(cachePath, encoded) end
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
  local function identity(callback)
    run({ "gh", "api", "--hostname", "github.com", "user", "--jq", ".login" }, function(result)
      local login = tostring(result.stdout or ""):match("^%s*([%w%-]+)%s*$")
      if result.exitCode ~= 0 or not login then callback(nil, message(result)); return end
      callback(string.lower(login))
    end)
  end
  local function setAccount(login)
    if account == login then return end
    account, generation = login, generation + 1
    serverItems, serverUnread, overrides, pageCache, queue = {}, {}, {}, {}, {}
    writeErrors, lastUpdate, revision = {}, 0, 0
    if type(cached) == "table" and cached.schema == 1 and cached.login == login then
      serverItems = type(cached.items) == "table" and cached.items or {}
      serverUnread = type(cached.unread) == "table" and cached.unread or {}
      lastUpdate = tonumber(cached.last_update) or 0
      for id, record in pairs(type(cached.overrides) == "table" and cached.overrides or {}) do
        if type(record) == "table" and type(record.updatedAt) == "string" and not record.pending
          and tonumber(record.expiresAt) and tonumber(record.expiresAt) > now() then
          overrides[id] = copy(record)
          overrides[id].expiresAt = tonumber(record.expiresAt)
          overrides[id].confirmedRevision = 0
        end
      end
    end
    cached = nil
    publish()
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
          coroutine.yield()
          for i, item in ipairs(raw) do
            if type(item) ~= "table" or not tostring(item.id or ""):match("^%d+$")
              or type(item.updated_at) ~= "string" then
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
    readDeadline = now() + readTimeout
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
        readBusy = false; readError = error; statusError(error)
        nextAllowed = math.max(nextAllowed, now() + 60); publish(); return
      end
      setAccount(login)
      local expectedGeneration, startedRevision = generation, revision
      local cache, cutoff = {}, historyCutoff(true)
      local function finish(items, unread, failure)
        if not activeRead(serial) then return end
        if failure then
          readBusy = false
          readError = failure; failures = math.min(failures + 1, 4)
          nextAllowed = math.max(nextAllowed, now() + 60 * 2 ^ (failures - 1))
          statusError(failure); publish(); return
        end
        if expectedGeneration ~= generation then return end
        local byId = {}
        for i, item in ipairs(items) do byId[item.id] = copy(item); pause(i) end
        local unreadById = {}
        for i, item in ipairs(unread) do
          unreadById[item.id] = item
          -- The later unread snapshot wins over the historical snapshot.
          byId[item.id] = copy(item)
          pause(i)
        end
        local combined = {}
        for id, item in pairs(byId) do
          item.unread = unreadById[id] ~= nil
          combined[#combined + 1] = item
          pause(#combined)
        end
        table.sort(combined, function(a, b) return a.updatedAt > b.updatedAt end)
        if expectedGeneration ~= generation then
          readBusy, queuedRefresh = false, true
          return
        end
        -- Commit a complete snapshot only after every page/batch succeeds.
        failures, readError, lastUpdate = 0, "", now()
        -- A newer mutation invalidates conditional pages collected before it.
        pageCache = startedRevision == revision and cache or {}
        serverItems, serverUnread = combined, unread
        for id, record in pairs(overrides) do
          if not record.pending and startedRevision >= (record.confirmedRevision or 0) then
            local remote = unreadById[id]
            if not remote or remote.updatedAt > record.updatedAt or now() >= record.expiresAt then overrides[id] = nil end
          end
        end
        env.state.set("notifications_status", next(writeErrors) and "error" or "ready")
        publish(); persist()
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
    if not record or record ~= action.record then drain(); return end
    writeBusy, activeWriteId = true, action.id
    local expectedAccount, expectedGeneration = account, generation
    local function finish(ok, error)
      writeBusy, activeWriteId = false, nil
      if generation == expectedGeneration and overrides[action.id] == record then
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
        pageCache = {}; queuedRefresh = true
        publish(); persist()
      end
      drain()
    end
    -- Recheck account and current thread version before every write, including batches.
    identity(function(login, error)
      if not login then finish(false, error); return end
      if login ~= expectedAccount or expectedGeneration ~= generation then
        if login ~= expectedAccount then setAccount(login) end
        finish(false, env.tr("status.auth_error")); self.refresh(); return
      end
      if not synced() then finish(false); return end
      run(api("notifications/threads/" .. action.id), function(result)
        if expectedGeneration ~= generation then finish(false); return end
        local code, _, body = response(result)
        local raw = env.json.decode(body)
        if result.exitCode ~= 0 or code ~= 200 or type(raw) ~= "table" then finish(false, message(result)); return end
        if tostring(raw.id or "") ~= action.id or type(raw.updated_at) ~= "string" or type(raw.unread) ~= "boolean" then
          finish(false, env.tr("status.unexpected_data")); return
        end
        if tostring(raw.updated_at or "") > record.updatedAt then
          -- Do not consume a comment that arrived after the displayed notification.
          local fresh = Data.notification(raw)
          for i, item in ipairs(serverItems) do if item.id == action.id then serverItems[i] = fresh end end
          for i, item in ipairs(serverUnread) do if item.id == action.id then serverUnread[i] = fresh end end
          finish(false, env.tr("status.notification_changed")); return
        end
        if raw.unread == false then finish(true); return end
        if not synced() or generation ~= expectedGeneration then finish(false); return end
        run(api("notifications/threads/" .. action.id, "PATCH"), function(patch)
          local status = response(patch)
          finish(patch.exitCode == 0 and (status == 205 or status == 304), message(patch))
        end)
      end)
    end)
  end

  local function enqueue(action)
    local id = tostring(action.id or "")
    if not account or not id:match("^%d+$") or (overrides[id] and overrides[id].pending) then return end
    local target
    for _, item in ipairs(serverItems) do if item.id == id then target = item; break end end
    if not target or not effective(target).unread or action.updatedAt ~= target.updatedAt then return end
    revision = revision + 1
    local record = { updatedAt = target.updatedAt, pending = true }
    overrides[id] = record; writeErrors[id] = nil
    queue[#queue + 1] = { id = id, record = record }
  end
  function self.action(action)
    if type(action) ~= "table" then return end
    if action.type == "refresh" then self.refresh(); return end
    if not synced() then return end
    if action.type == "mark_read" then enqueue(action)
    elseif action.type == "mark_visible_read" and type(action.items) == "table" then
      for _, item in ipairs(action.items) do if type(item) == "table" then enqueue(item) end end
    else return end
    publish(); drain()
  end
  function self.configure()
    if not synced() then
      queue = {}
      for id, record in pairs(overrides) do if record.pending and id ~= activeWriteId then overrides[id] = nil end end
    end
    self.refresh()
  end
  function self.update()
    if readBusy and now() >= readDeadline then
      -- An aborted callback cannot release readBusy. Invalidate its late replies
      -- and retain the previous complete snapshot while backing off for retry.
      readSerial, readBusy, readJob = readSerial + 1, false, nil
      failures = math.min(failures + 1, 4)
      nextAllowed = math.max(nextAllowed, now() + 60 * 2 ^ (failures - 1))
      queuedRefresh, readError = true, env.tr("status.notification_refresh_timeout")
      statusError(readError); publish(); tickInterval(idleInterval)
      return
    end
    if readJob then
      local job = readJob
      -- Clear before resuming: even a host CPU-budget abort leaves the watchdog
      -- able to recover, rather than resuming an abandoned coroutine forever.
      readJob = nil
      tickInterval(idleInterval)
      readDeadline = now() + readTimeout
      local ok = coroutine.resume(job)
      if ok and coroutine.status(job) ~= "dead" and readBusy then readJob = job end
      if readJob then tickInterval(busyInterval) end
      return
    end
    if now() >= nextAllowed and (queuedRefresh or now() >= nextPoll) then self.refresh() end
  end
  publish()
  env.state.set("notifications_status", "idle")
  return self
end

return Notifications
