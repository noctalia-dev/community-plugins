--!nonstrict
-- Bounded read-only cache. One request per key; epoch discards obsolete replies.
-- This module cannot send SMS, dial or execute Deck actions.
local M = {}
local size = require("../cache_size.luau")
local access = require("../message_access.luau")
local pageData = require("./page_data.luau")
local TTL_TICKS = { messages = 10, calls = 2, photos = 60, apps = 150, deck = 15 }
local SURFACES = { "page", "threads" }

local function featureReason(data, page)
  if data.unsupported == true then return "feature_unsupported" end
  local upgrade = data.upgrade
  if type(upgrade) ~= "table" then return "permission" end
  if page == "apps" and data.feature == "mirroring.app_windows"
    and upgrade.action == "raisePower" and upgrade.target == "elevated"
  then return "apps_elevated" end
  if upgrade.action == "enableToggle" then return "feature_toggle_disabled" end
  if upgrade.action == "updateApp" then
    if upgrade.target == "phone" then return "feature_update_phone" end
    if upgrade.target == "desktop" then return "feature_update_desktop" end
  end
  return "permission"
end

---@class NectarLinkPageQuery
---@field page NectarLinkSection
---@field key string
---@field thread string?
---@field album string?
---@field before number?
---@field before_id string?
---@field offset number?
---@field search string?
---@field limit number?
---@field force boolean?

---@class NectarLinkPageCommand
---@field device string
---@field value NectarLinkPageQuery

---@class NectarLinkPageScope
---@field device string
---@field kind NectarLinkSection
---@field thread string

---@class NectarLinkPageFailure: NectarLinkPageScope
---@field untilTick integer
---@field reason string

--- Own the response cache, its in-flight jobs, and the UI projections.
function M.new(visibility, clock, snapshot, api, publish, onlineDevice, limits)
  local credentials = api.credentials
  local request = api.request
  local maxBytes = limits.pageCacheBytes or 4 * 1024 * 1024
  local cache = { entries = {}, jobs = {}, failures = {}, epoch = 0, used = 0 }
  local lastPhoto = {}

  local function resetPages()
    cache.entries = {}
    cache.jobs = {}
    cache.failures = {}
    lastPhoto = {}
    cache.epoch = cache.epoch + 1
    snapshot.page = nil
    snapshot.threads = nil
    snapshot.cacheEpoch = cache.epoch
    snapshot.messagesDenied = nil
    snapshot.deniedPages = nil
    snapshot.pageRevocations = nil
    snapshot.smsDenied = nil
  end

  ---@param command NectarLinkPageCommand
  ---@return boolean
  local function threadIndex(command)
    local query = command.value
    return snapshot.pageCacheV2 == true and query.page == "messages" and (query.thread or "") == ""
  end

  --- Length prefixes keep separator characters in IDs and searches unambiguous.
  ---@param command NectarLinkPageCommand
  ---@return string
  local function pageIdentity(command)
    local query = command.value
    if threadIndex(command) then
      return "threads:" .. command.device
    end
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

  local function showPage(command, entry, refreshing, stale, err, preparedData, reason, surface)
    local data = preparedData or (entry and pageData.previews(entry.data, command.value.page, noctalia.fileExists))
    if data and threadIndex(command) then
      local query = command.value
      local offset, limit = query.offset or 0, query.limit or 7
      local items = {}
      for i = offset + 1, math.min(offset + limit, #data.items) do
        items[#items + 1] = data.items[i]
      end
      data = { items = items, more = #data.items > offset + limit, notice = data.notice }
    end
    snapshot[surface or "page"] = {
      key = command.value.key,
      device = command.device,
      kind = command.value.page,
      thread = command.value.thread or "",
      status = data and "ready" or (err or "loading"),
      data = data,
      refreshing = refreshing or false,
      stale = stale or false,
      error = reason,
      partial = entry and entry.partial or nil,
    }
  end

  local function forCurrent(key, apply)
    if not visibility.open then return end
    if visibility.activePage and pageIdentity(visibility.activePage) == key then
      apply(visibility.activePage, "page")
    end
    if visibility.threads and pageIdentity(visibility.threads) == key then
      apply(visibility.threads, "threads")
    end
  end

  local function emitPage(key, entry, refreshing, stale, status, reason)
    forCurrent(key, function(command, surface)
      showPage(command, entry, refreshing, stale, status, nil, reason, surface)
    end)
    publish()
  end

  local function isLanding(query)
    return (query.thread or "") == "" and (query.album or "") == ""
      and (query.offset or 0) == 0 and query.before == nil and (query.search or "") == ""
  end

  local function trimPages()
    -- Entry counts alone are insufficient: one page may contain large text.
    -- Estimate sizes on response arrival, not on every warm read.
    while true do
      local count, bytes, oldest, stamp, rank = 0, 0, nil, math.huge, math.huge
      for key, entry in pairs(cache.entries) do
        count = count + 1
        entry.weight = entry.weight or size(entry.data, maxBytes)
        bytes = bytes + entry.weight
        local priority = (entry.landing or lastPhoto[entry.device] == key) and 1 or 0
        if priority < rank or (priority == rank and entry.used < stamp) then
          oldest, stamp, rank = key, entry.used, priority
        end
      end
      if count <= limits.pageCacheLimit and bytes <= maxBytes then
        return
      end
      cache.entries[oldest] = nil
    end
  end

  --- Record why a page is in cooldown, even when it has no cached response.
  ---@param key string
  ---@param scope NectarLinkPageScope
  ---@param reason string
  local function deferRead(key, scope, reason)
    ---@type NectarLinkPageFailure
    local failure = {
      device = scope.device, kind = scope.kind, thread = scope.thread,
      untilTick = clock.ticks + limits.pageRetryTicks, reason = reason,
    }
    cache.failures[key] = failure
  end

  local function clearFailures(matches)
    for key, failure in pairs(cache.failures) do
      if matches(failure) then cache.failures[key] = nil end
    end
  end

  local function invalidateKind(device, kind, thread)
    local function matches(e)
      return (not device or e.device == device) and (not kind or e.kind == kind)
        and (not thread or e.thread == thread)
    end
    for key, e in pairs(cache.entries) do
      if matches(e) then
        cache.entries[key] = nil
      end
    end
    for key, e in pairs(cache.jobs) do
      if matches(e) then
        cache.jobs[key] = nil
      end
    end
    clearFailures(matches)
    if device and (not kind or kind == "photos") then lastPhoto[device] = nil end
    for _, surface in ipairs(SURFACES) do
      local shown = snapshot[surface]
      if shown and matches(shown) then snapshot[surface] = nil end
    end
  end

  local function deny(device, kind, reason)
    invalidateKind(device, kind)
    local scope = device and (kind .. ":" .. device) or kind
    snapshot.pageRevocations = snapshot.pageRevocations or {}
    snapshot.pageRevocations[scope] = (snapshot.pageRevocations[scope] or 0) + 1
    if not device then
      snapshot.messagesDenied = true
    else
      snapshot.deniedPages = snapshot.deniedPages or {}
      snapshot.deniedPages[scope] = true
    end
    local function showDenied(current, surface)
      if current and current.value.page == kind and (not device or current.device == device) then
        deferRead(pageIdentity(current), {
          device = current.device, kind = kind, thread = current.value.thread or "",
        }, reason)
        showPage(current, nil, false, false, "failed", nil, reason, surface)
      end
    end
    if visibility.open then
      showDenied(visibility.activePage, "page")
      showDenied(visibility.threads, "threads")
    end
  end

  local function revokePrivate()
    invalidateKind(nil, "messages")
    snapshot.pageRevocations = snapshot.pageRevocations or {}
    snapshot.pageRevocations.messages = (snapshot.pageRevocations.messages or 0) + 1
    snapshot.messagesDenied = nil
  end

  local function allowPrivate()
    snapshot.messagesDenied = nil
    clearFailures(function(failure) return failure.reason == "private_api_disabled" end)
  end

  local function setNotificationPolicy(policy, previousInstance)
    local function readsChats(entry)
      return entry.kind == "messages" and not access.smsThread(entry.thread)
    end
    for key, job in pairs(cache.jobs) do
      if readsChats(job) then cache.jobs[key], cache.failures[key] = nil, nil end
    end
    clearFailures(function(failure) return failure.reason == "chat_unavailable" end)
    local function scrub(entry)
      if not readsChats(entry) then return true end
      if access.chatThread(entry.thread) then
        return entry.data and access.allowsScope(policy, entry.data.appScope, previousInstance)
      end
      local data = access.withoutHiddenChats(entry.data, policy, previousInstance)
      if data ~= entry.data then entry.data, entry.weight = data, nil end
      return true
    end
    for key, entry in pairs(cache.entries) do
      if not scrub(entry) then cache.entries[key] = nil
      elseif entry.kind == "messages" and entry.thread == "" then
        entry.policyStale = true -- A now-visible chat may need to be added back.
        cache.failures[key] = nil
      end
    end
    for _, surface in ipairs(SURFACES) do
      local view = snapshot[surface]
      if view and readsChats(view) then
        if not scrub(view) then snapshot[surface] = nil
        else view.refreshing = false end
      end
    end
  end

  local function allowApps(device)
    if snapshot.deniedPages then snapshot.deniedPages["apps:" .. device] = nil end
    clearFailures(function(failure) return failure.device == device and failure.kind == "apps" end)
  end

  local function smsDenied(device)
    return snapshot.smsDenied ~= nil and snapshot.smsDenied[device] == true
  end

  local function setSmsAccess(device, allowed)
    if allowed == true then
      if snapshot.smsDenied then snapshot.smsDenied[device] = nil end
      return
    end
    if allowed ~= false or smsDenied(device) then return end
    snapshot.smsDenied = snapshot.smsDenied or {}
    snapshot.smsDenied[device] = true
    snapshot.pageRevocations = snapshot.pageRevocations or {}
    local scope = "sms:" .. device
    snapshot.pageRevocations[scope] = (snapshot.pageRevocations[scope] or 0) + 1
    local function matches(e)
      return e.device == device and e.kind == "messages" and (e.thread == "" or access.smsThread(e.thread))
    end
    for key, entry in pairs(cache.entries) do
      if matches(entry) then
        if access.smsThread(entry.thread) then
          cache.entries[key] = nil
        else
          entry.data = access.withoutSms(entry.data)
          entry.weight = nil
          entry.failed = true
        end
      end
    end
    for key, job in pairs(cache.jobs) do
      if matches(job) then
        cache.jobs[key] = nil
      end
    end
    clearFailures(matches)
    for _, surface in ipairs(SURFACES) do
      local view = snapshot[surface]
      if view and matches(view) then
        if access.smsThread(view.thread) then
          snapshot[surface] = nil
        else
          view.data = access.withoutSms(view.data)
          view.refreshing = false
        end
      end
    end
  end

  local readPage
  local function followRefresh(key, job)
    if not job.refreshRequested or job.epoch ~= cache.epoch then return end
    forCurrent(key, function(current, pane)
      if job.refreshRequested then
        job.refreshRequested = nil
        readPage(current, false, true, pane)
      end
    end)
  end

  local function keepPreview(key, job)
    local previous = cache.entries[key]
    if (previous and not previous.partial) or not job.preview or not job.preview.partial then return end
    local data = job.preview.data
    local weight = size(data, maxBytes)
    if weight > maxBytes then return end
    cache.used = cache.used + 1
    cache.entries[key] = {
      data = data, partial = true, at = cacheTime(), used = cache.used, weight = weight,
      device = job.device, kind = job.kind, thread = job.thread,
    }
    trimPages()
  end

  local function currentJob(key, job)
    return cache.jobs[key] == job and job.epoch == cache.epoch
  end

  --- Drop only the data covered by a confirmed authorization failure.
  local function rejectRead(key, job, status, data)
    if status == 401 then
      resetPages()
      snapshot.state = "unauthorized"
      snapshot.error = "unauthorized"
    else
      local code = type(data) == "table" and data.error
      local device, section, thread = job.device, job.kind, job.thread
      if section == "messages" and access.chatThread(thread)
        and ((status == 404 and code == "chat_unavailable") or (status == 403 and code == "feature_denied"))
      then
        -- Older desktop builds report an individual hidden chat as a feature denial.
        local reason = status == 404 and "chat_unavailable" or featureReason(data, section)
        invalidateKind(device, section, thread)
        local current = visibility.activePage
        if visibility.open and current and current.device == device
          and current.value.page == section and current.value.thread == thread
        then
          deferRead(pageIdentity(current), job, reason)
          showPage(current, nil, false, false, "failed", nil, reason)
        end
      elseif status == 403 and section == "messages" and code == "sms_denied" then
        setSmsAccess(device, false)
        if cache.jobs[key] == job then cache.jobs[key] = nil end
      elseif status == 403 and code == "not_allowed" and section == "messages" then
        deny(nil, section, "private_api_disabled")
        deferRead(key, job, "private_api_disabled")
      elseif status == 403 and code == "feature_denied" then
        local reason = featureReason(data, section)
        deny(device, section, reason)
        deferRead(key, job, reason)
      else
        return false
      end
    end
    publish()
    return true
  end

  local function savePage(key, job, data, at)
    cache.used = cache.used + 1
    local entry = {
      data = data, at = at or cacheTime(), used = cache.used,
      device = job.device, kind = job.kind, weight = size(data, maxBytes),
      thread = job.thread, landing = job.landing,
    }
    -- Oversized but valid replies can be displayed without entering the LRU.
    cache.entries[key] = entry.weight <= maxBytes and entry or nil
    cache.failures[key] = nil
    trimPages()
    return entry
  end

  local function failRead(key, job, reason)
    cache.jobs[key] = nil
    keepPreview(key, job)
    deferRead(key, job, reason)
    local previous = cache.entries[key]
    if previous then
      previous.failed = true
      previous.error = reason
    end
    return previous or job.preview
  end

  --- Read or display a cached page, joining any in-flight request for the same key.
  ---@param command NectarLinkPageCommand
  ---@param quiet boolean?
  ---@param force boolean?
  ---@param surface ("page"|"threads"|"warm")?
  readPage = function(command, quiet, force, surface)
    -- Quiet reads do not queue another refresh; only an explicit click does.
    local config, credentialError = credentials()
    if not config then
      resetPages()
      snapshot.state = "unconfigured"
      snapshot.error = credentialError
      publish()
      return
    end
    local query, device = command.value, command.device
    local thread = query.thread or ""
    if query.page == "messages" and smsDenied(device) and access.smsThread(thread) then
      if not quiet then
        showPage(command, nil, false, false, "failed", nil, "sms_denied", surface)
        publish()
      end
      return
    end
    local key = pageIdentity(command)
    local index = threadIndex(command)
    local warm = surface == "warm"
    local progressivePhoto = snapshot.pageCacheV2 == true and query.page == "photos"
    if not warm and not quiet and query.page == "photos" then lastPhoto[device] = key end
    local entry = cache.entries[key]
    if entry then
      cache.used = cache.used + 1
      entry.used = cache.used
    end
    local valid = true
    local displayData
    if entry then
      displayData, valid = pageData.previews(entry.data, query.page, noctalia.fileExists)
    end
    local now = entry and cacheTime()
    local age = entry and now - entry.at or 0
    local pendingDetails = progressivePhoto and entry and entry.detailsRetryAt
    local retryDetails = pendingDetails and not quiet and force ~= true and query.force ~= true
      and now >= entry.detailsRetryAt
    local fresh = entry
      and not entry.partial
      and not entry.failed
      and not entry.policyStale
      and age >= 0
      and age < (TTL_TICKS[query.page] or 10) * limits.updateIntervalMs
      and valid
    if query.page ~= "deck" and not onlineDevice(device) then
      if not warm then
        showPage(command, entry, false, true, "failed", displayData, "phone_offline", surface)
        publish()
      end
      return
    end
    force = force == true or (not quiet and query.force == true)
    local backendForce = force or (entry and entry.failed) or false
    local pending = cache.jobs[key]
    if not quiet and (entry or pending) then
      showPage(
        command,
        entry or pending.preview,
        pending ~= nil,
        entry ~= nil and not fresh,
        nil,
        displayData,
        entry and entry.error,
        surface
      )
      publish()
    end
    -- Every offset reads the same index. Paging never waits for a phone
    -- refresh: that is done explicitly or by the scheduler.
    if not force and not retryDetails
      and (fresh or (index and entry and not entry.partial and not entry.policyStale and not quiet)) then
      return
    end
    if pending then
      if not quiet then
        if force and not pending.forced then pending.refreshRequested = true end
        if not entry and pending.localPreview then pending.localPreview(query) end
      end
      return
    end
    local failure = cache.failures[key]
    if not force and failure and clock.ticks < failure.untilTick then
      if not entry and not warm then
        -- Retain the last error reason while throttling repeated reads.
        showPage(command, nil, false, true, "failed", nil, failure.reason, surface)
        publish()
      end
      return
    end
    local job = {
      epoch = cache.epoch, started = clock.ticks, device = device, kind = query.page, thread = thread,
      forced = backendForce,
      landing = index or ((query.page == "apps" or query.page == "photos") and isLanding(query)),
    }
    local function loadDetails(result, data, ids)
      job.preview = result
      job.details = true
      job.started = clock.ticks
      emitPage(key, result, true, false)
      request("/v1/page", {
        device = device, page = "photos", photo_ids = ids, force = force,
      }, function(ok, status, details)
        if not currentJob(key, job) or rejectRead(key, job, status, details) then return end
        cache.jobs[key] = nil
        local failed = true
        if ok and pageData.valid(details) then
          local merged, complete = pageData.mergePhotoDetails(data, details)
          failed = not complete
          result = savePage(key, job, merged, result.at)
        end
        result.detailsRetryAt = failed and (cacheTime() + limits.pageRetryTicks * limits.updateIntervalMs) or nil
        result.error = failed and "photo_details_unavailable" or nil
        emitPage(key, result, false, failed, nil, result.error)
        followRefresh(key, job)
      end, config)
    end
    cache.jobs[key] = job
    if retryDetails then
      loadDetails(entry, displayData, pageData.missingThumbnails(displayData))
      return
    end
    if not warm and (not quiet or not entry) then
      showPage(command, entry, true, entry ~= nil, nil, displayData, nil, surface)
      publish()
    end
    local function localPreview(visibleQuery)
      if job.localPreviewStarted or snapshot.messagesDenied or not snapshot.localMessageThreads
        or (visibleQuery.offset or 0) ~= 0 or not currentJob(key, job)
      then return end
      job.localPreviewStarted = true
      request("/v1/page", {
        device = device, page = "messages", limit = visibleQuery.limit, local_only = true,
        thread_index = index or nil,
      }, function(ok, status, data)
        if not currentJob(key, job) or rejectRead(key, job, status, data) then return end
        if ok and pageData.valid(data) and #data.items > 0 then
          if smsDenied(device) then data = access.withoutSms(data) end
          data = access.withoutHiddenChats(data, snapshot.notificationPolicy)
          job.preview = { data = data, partial = true }
          emitPage(key, job.preview, true, true)
        end
      end, config)
    end
    if not entry and query.page == "messages" and thread == "" then
      job.localPreview = localPreview
      if not warm then
        localPreview(query)
        if not currentJob(key, job) then return end
      end
    end
    request("/v1/page", {
      device = device,
      page = query.page,
      thread = query.thread,
      album = query.album,
      before = query.before,
      before_id = query.before_id,
      offset = query.offset,
      search = query.search,
      limit = query.limit,
      force = backendForce,
      thread_index = index or nil,
      photo_rows_only = progressivePhoto or nil,
    }, function(ok, status, data, reason)
      -- Removed/replaced job or changed epoch: this response no longer has an owner.
      if not currentJob(key, job) or rejectRead(key, job, status, data) then return end
      if ok and not pageData.valid(data) then ok, reason = false, "invalid_response" end
      if not ok then
        if status == 409 and type(data) == "table" and data.error == "timeout" then reason = "timeout" end
        reason = reason or (status == 404 and "unsupported" or "request_failed")
        emitPage(key, failRead(key, job, reason), false, true, status == 404 and "unsupported" or "failed", reason)
        followRefresh(key, job)
        return
      end
      if query.page == "messages" and thread == "" then
        if smsDenied(device) then data = access.withoutSms(data) end
        data = access.withoutHiddenChats(data, snapshot.notificationPolicy)
      elseif query.page == "messages" and access.chatThread(thread)
        and not access.allowsScope(snapshot.notificationPolicy, data.appScope)
      then
        rejectRead(key, job, 404, { error = "chat_unavailable" })
        return
      end
      if query.page == "messages" and (data.smsIncomplete or data.localChatsIncomplete) then
        local previous = cache.entries[key]
        if (not previous or previous.partial) and (index or (query.offset or 0) == 0) and #data.items > 0 then
          job.preview = { data = data, partial = true }
        end
        local incomplete = data.localChatsIncomplete and "local_chats_unavailable" or "sms_unavailable"
        emitPage(key, failRead(key, job, incomplete), false, true, "failed", incomplete)
        followRefresh(key, job)
        return
      end
      if query.page == "messages" then snapshot.messagesDenied = nil end
      if snapshot.deniedPages then snapshot.deniedPages[query.page .. ":" .. device] = nil end
      local ids
      if progressivePhoto then
        ids = pageData.missingThumbnails(data)
        if #ids == 0 and data.albums and not force then ids = nil end
        local previous = cache.entries[key]
        if not data.albums and previous then data.albums = previous.data.albums end
      end
      local result = savePage(key, job, data)
      if not ids then
        cache.jobs[key] = nil
        emitPage(key, result, false, false)
        followRefresh(key, job)
        return
      end

      -- The grid is ready; album metadata and missing images do not gate it.
      loadDetails(result, data, ids)
    end, config)
  end

  local function timeout(key, job)
    if not currentJob(key, job) then return end
    local entry, reason
    if job.details then
      cache.jobs[key] = nil
      entry = cache.entries[key]
      reason = "photo_details_unavailable"
      if entry then
        -- Detail failures have their own deadline; the rows remain usable.
        entry.detailsRetryAt = cacheTime() + limits.pageRetryTicks * limits.updateIntervalMs
        entry.error = reason
        cache.failures[key] = nil
      else
        deferRead(key, job, "timeout")
      end
    else
      reason = "timeout"
      entry = failRead(key, job, reason)
    end
    emitPage(key, entry or job.preview, false, true, "failed", reason)
    followRefresh(key, job)
  end

  --- Expire reads and their cooldowns without exposing the cache to the scheduler.
  local function expire()
    local expired
    for key, job in pairs(cache.jobs) do
      if clock.ticks - job.started >= limits.timeoutTicks then
        expired = expired or {}
        expired[key] = job
      end
    end
    if expired then
      for key, job in pairs(expired) do timeout(key, job) end
    end
    for key, failure in pairs(cache.failures) do
      if clock.ticks >= failure.untilTick then cache.failures[key] = nil end
    end
  end

  return {
    reset = resetPages,
    expire = expire,
    deny = deny,
    revokePrivate = revokePrivate,
    allowPrivate = allowPrivate,
    setNotificationPolicy = setNotificationPolicy,
    allowApps = allowApps,
    cancelInactiveRefreshes = function()
      for key, job in pairs(cache.jobs) do
        if job.refreshRequested then
          local current = false
          forCurrent(key, function() current = true end)
          if not current then job.refreshRequested = nil end
        end
      end
    end,
    setSmsAccess = setSmsAccess,
    invalidate = invalidateKind,
    read = readPage,
    hasJob = function() return next(cache.jobs) ~= nil end,
    hasCachedPage = function(command)
      local entry = cache.entries[pageIdentity(command)]
      return entry ~= nil and not entry.partial
    end,
    time = cacheTime,
    isIndex = threadIndex,
  }
end
return M
