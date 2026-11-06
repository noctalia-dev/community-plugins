-- OpenCode Monitor service: polls the local OpenCode v2 server and publishes
-- a compact snapshot for the bar widget and the details panel.

local shared = require("./shared.luau")

local busy = false
local busySince = 0
local cycle = 0
local currentInterval = nil
local currentServerKey = ""
local activeCtx = nil

local sessionCache = {}
local recentList = {}
local lastListAt = 0
local listInFlight = false
local listStartedAt = 0
local listGeneration = 0
local lastListError = nil
local lastListTruncated = false
local pendingCtx = nil

local WATCHDOG_MS = 15000
local LIST_INTERVAL_MS = 30000
local RELATED_MAX = 12
local RELATED_MAX_DEPTH = 3
local RELATED_TOTAL_MAX = 200
local MAX_SESSIONS = 200
local MAX_ACTIVE = 64
local MAX_PERMISSIONS = 64
local DETAIL_MAX_SESSIONS = 8
local DETAIL_MAX_INFLIGHT = 3
local DETAIL_REQUESTS = 4

local function asArray(value)
  if type(value) == "table" then
    return value
  end
  return {}
end

local function dataArray(envelope)
  if type(envelope) == "table" and type(envelope.data) == "table" then
    return envelope.data
  end
  return {}
end

local function firstMessage(envelope)
  local messages = dataArray(envelope)
  return messages[1]
end

local function modelID(value)
  if type(value) == "table" then
    value = value.id
  end
  if type(value) ~= "string" then
    return nil
  end
  local model = shared.cut(value, 80)
  if model == "" then
    return nil
  end
  return model
end

local function tokensInfo(info)
  local tokens = type(info) == "table" and info.tokens or nil
  if type(tokens) ~= "table" then
    return { input = 0, output = 0, reasoning = 0, cacheRead = 0, cacheWrite = 0, total = 0 }
  end
  local cache = type(tokens.cache) == "table" and tokens.cache or {}
  local input = tonumber(tokens.input) or 0
  local output = tonumber(tokens.output) or 0
  local reasoning = tonumber(tokens.reasoning) or 0
  local cacheRead = tonumber(cache.read) or 0
  local cacheWrite = tonumber(cache.write) or 0
  return {
    input = input,
    output = output,
    reasoning = reasoning,
    cacheRead = cacheRead,
    cacheWrite = cacheWrite,
    total = input + output + reasoning + cacheRead + cacheWrite,
  }
end

local function extractSession(data)
  local value = data
  if type(data) == "table" and type(data.data) == "table" and data.data.id ~= nil then
    value = data.data
  end
  if type(value) == "table" and shared.isSafeSessionID(value.id) then
    return value
  end
  return nil
end

local DETAIL_SPECS = {
  { key = "session", suffix = "", extract = extractSession },
  { key = "forms", suffix = "/form", extract = dataArray },
  { key = "inbox", suffix = "/inbox", extract = dataArray },
  { key = "message", suffix = "/message?limit=1&order=desc", extract = firstMessage },
}

local function baseSession(info, id, fallbackMessage)
  info = type(info) == "table" and info or {}
  local message = type(fallbackMessage) == "table" and fallbackMessage or {}
  local model = modelID(info.model) or modelID(message.model)
  local directory = ""
  local location = info.location
  if type(location) == "table" and type(location.directory) == "string" then
    directory = shared.cut(location.directory, 200)
  end
  local title = ""
  if type(info.title) == "string" then
    title = shared.redact(info.title, 90)
  end
  if title == "" then
    title = "Session " .. tostring(id or "?"):sub(1, 14)
  end
  local parentID = info.parentID
  if not shared.isSafeSessionID(parentID) then
    parentID = nil
  end
  local parentTitle = nil
  if parentID and sessionCache[parentID] then
    parentTitle = shared.redact(sessionCache[parentID].title or "", 90)
    if parentTitle == "" then
      parentTitle = nil
    end
  end
  local agent = info.agent or message.agent
  if type(agent) ~= "string" then
    agent = "?"
  else
    agent = shared.cut(agent, 64)
    if agent == "" then
      agent = "?"
    end
  end
  local outcome = info.outcome
  if type(outcome) == "string" then
    outcome = shared.cut(outcome, 40)
  else
    outcome = nil
  end
  return {
    id = id,
    title = title,
    parentID = parentID,
    parentTitle = parentTitle,
    isChild = parentID ~= nil,
    agent = agent,
    model = model,
    shortDirectory = shared.shortPath(directory, 52),
    cost = tonumber(info.cost) or 0,
    tokens = tokensInfo(info),
    outcome = outcome,
    updatedAt = shared.timeField(info.time, "updated") or shared.timeField(message.time, "created"),
  }
end

local function makeRecent(info, now)
  local session = baseSession(info, info.id, nil)
  local status = "idle"
  if session.outcome == "failed" then
    status = "failed"
  elseif session.outcome == "succeeded" then
    status = "done"
  end
  session.status = status
  session.isActive = false
  session.queued = 0
  session.updatedLabel = shared.relativeTime(session.updatedAt, now)
  session.activity = nil
  session.wait = nil
  return session
end

local function ensureActive(ctx, id, forced)
  if not shared.isSafeSessionID(id) then
    return false
  end
  if ctx.active[id] then
    return true
  end
  if ctx.activeCount >= MAX_ACTIVE then
    return false
  end
  ctx.active[id] = true
  ctx.activeCount = ctx.activeCount + 1
  if forced then
    ctx.forced[id] = true
  end
  return true
end

local function publishOffline(reason)
  local now = noctalia.nowMs()
  local snapshot = {
    generatedAt = now,
    server = {
      state = "offline",
      message = shared.redact(reason or "OpenCode is not running", 200),
      updatedAt = now,
    },
    counts = {
      active = 0,
      waiting = 0,
      queued = 0,
      recent = 0,
    },
    sessions = {},
    recent = {},
  }
  noctalia.state.set(shared.SNAPSHOT_KEY, snapshot)
end

local function publish(ctx)
  local now = noctalia.nowMs()
  local active = {}

  for id in pairs(ctx.active) do
    if shared.isSafeSessionID(id) then
      local details = type(ctx.details[id]) == "table" and ctx.details[id] or {}
      local detailSession = details.session
      if type(detailSession) == "table"
        and detailSession.id == id
        and shared.isSafeSessionID(detailSession.id)
      then
        sessionCache[id] = detailSession
      else
        detailSession = nil
      end
      local info = detailSession or sessionCache[id]
      local message = details.message
      local session = baseSession(info, id, message)

      local permissions = ctx.permissions[id]
      local forms = asArray(details.forms)
      local permissionWait = shared.permissionWait(permissions)
      local formWait = shared.formWait(forms)
      local wait = permissionWait or formWait

      local isActive = ctx.active[id] == true and not ctx.forced[id]
      local status
      if wait then
        status = wait.kind == "permission" and "waiting_permission" or "waiting_input"
      elseif isActive then
        status = "running"
      elseif session.outcome == "failed" then
        status = "failed"
      elseif session.outcome == "succeeded" then
        status = "done"
      else
        status = "idle"
      end

      local activity = shared.extractActivity(message)
      if isActive and not activity and not wait then
        activity = {
          kind = "working",
          name = "working",
          label = "Working",
          glyph = "loader",
          detail = "",
          since = session.updatedAt,
        }
      end

      session.status = status
      session.isActive = isActive
      session.wait = wait
      session.activity = activity
      session.queued = #asArray(details.inbox)
      session.updatedLabel = shared.relativeTime(session.updatedAt, now)
      if details.incomplete == true or (type(details.errors) == "table" and #details.errors > 0) then
        session.detailsIncomplete = true
      end
      active[#active + 1] = session
    end
  end

  table.sort(active, function(left, right)
    local leftRank = shared.statusMeta(left.status).rank
    local rightRank = shared.statusMeta(right.status).rank
    if leftRank ~= rightRank then
      return leftRank < rightRank
    end
    local leftSince = (left.activity and left.activity.since) or left.updatedAt or 0
    local rightSince = (right.activity and right.activity.since) or right.updatedAt or 0
    if leftSince ~= rightSince then
      return leftSince > rightSince
    end
    return (left.updatedAt or 0) > (right.updatedAt or 0)
  end)

  local recentMinutes = shared.intSetting("recent_minutes", 120, 1, 1440)
  local recentCount = shared.intSetting("recent_count", 8, 1, 30)
  local cutoff = now - recentMinutes * 60000
  local recent = {}
  for _, info in ipairs(recentList) do
    local sessionID = info.id
    local archived = type(info.time) == "table" and info.time.archived ~= nil
    local updatedAt = shared.timeField(info.time, "updated") or 0
    if shared.isSafeSessionID(sessionID)
      and not ctx.active[sessionID]
      and not archived
      and updatedAt >= cutoff
    then
      recent[#recent + 1] = makeRecent(info, now)
    end
  end
  table.sort(recent, function(left, right)
    return (left.updatedAt or 0) > (right.updatedAt or 0)
  end)
  while #recent > recentCount do
    table.remove(recent)
  end

  -- Index every known raw session by parent once, using data already fetched
  -- for this poll. Children are stored as ids; their panel-facing records are
  -- materialized lazily and cached, so a child is only formatted when a
  -- published root actually reaches it.
  local activeByID = {}
  for _, session in ipairs(active) do
    if type(session) == "table" and shared.isSafeSessionID(session.id) then
      activeByID[session.id] = session
    end
  end

  local childrenByParent = {}
  local directCount = {}
  local indexed = {}
  local function indexSession(info)
    if type(info) ~= "table" then
      return
    end
    local id = info.id
    local parentID = info.parentID
    if not shared.isSafeSessionID(id)
      or not shared.isSafeSessionID(parentID)
      or id == parentID
      or indexed[id]
    then
      return
    end
    indexed[id] = true
    local bucket = childrenByParent[parentID]
    if not bucket then
      bucket = {}
      childrenByParent[parentID] = bucket
    end
    bucket[#bucket + 1] = id
    directCount[parentID] = (directCount[parentID] or 0) + 1
  end
  for _, info in pairs(sessionCache) do
    indexSession(info)
  end
  for _, details in pairs(ctx.details) do
    if type(details) == "table" then
      indexSession(details.session)
    end
  end

  -- Stable sibling order: active children first, then id. Sorted once.
  for _, bucket in pairs(childrenByParent) do
    table.sort(bucket, function(left, right)
      local leftActive = activeByID[left] ~= nil
      local rightActive = activeByID[right] ~= nil
      if leftActive ~= rightActive then
        return leftActive
      end
      return left < right
    end)
  end

  local childRecords = {}
  local function childRecord(id)
    local cached = childRecords[id]
    if cached ~= nil then
      if cached == false then
        return nil
      end
      return cached
    end

    local activeSession = activeByID[id]
    if activeSession then
      local record = {
        id = activeSession.id,
        title = activeSession.title,
        agent = activeSession.agent,
        model = activeSession.model,
        status = activeSession.status,
        isActive = activeSession.isActive,
        wait = activeSession.wait,
        activity = activeSession.activity,
        queued = activeSession.queued,
        tokens = activeSession.tokens,
        cost = activeSession.cost,
        updatedAt = activeSession.updatedAt,
        updatedLabel = activeSession.updatedLabel,
      }
      childRecords[id] = record
      return record
    end

    local info = sessionCache[id]
    if type(info) ~= "table" then
      local details = ctx.details[id]
      info = type(details) == "table" and details.session or nil
    end
    if type(info) ~= "table" then
      childRecords[id] = false
      return nil
    end

    local title = ""
    if type(info.title) == "string" then
      title = shared.redact(info.title, 72)
    end
    if title == "" then
      title = "Session " .. id:sub(1, 14)
    end
    local agent = info.agent
    if type(agent) ~= "string" then
      agent = "?"
    else
      agent = shared.cut(agent, 48)
      if agent == "" then
        agent = "?"
      end
    end
    local outcome = info.outcome
    if type(outcome) == "string" then
      outcome = shared.cut(outcome, 24)
    else
      outcome = nil
    end
    local status = "idle"
    if outcome == "failed" then
      status = "failed"
    elseif outcome == "succeeded" then
      status = "done"
    end
    local updatedAt = shared.timeField(info.time, "updated")
    local record = {
      id = id,
      title = title,
      agent = agent,
      model = modelID(info.model),
      outcome = outcome,
      status = status,
      isActive = false,
      wait = nil,
      activity = nil,
      queued = 0,
      tokens = tokensInfo(info),
      cost = tonumber(info.cost) or 0,
      updatedAt = updatedAt,
      updatedLabel = shared.relativeTime(updatedAt, now),
    }
    childRecords[id] = record
    return record
  end

  local function attachRelated(session)
    if type(session) ~= "table" or not shared.isSafeSessionID(session.id) then
      return
    end
    local rootID = session.id
    local related = {}
    local seen = { [rootID] = true }
    local queue = { rootID }
    local head = 1
    local levelEnd = #queue
    local depth = 1
    local total = 0
    while head <= #queue and depth <= RELATED_MAX_DEPTH and total < RELATED_TOTAL_MAX do
      while head <= levelEnd do
        local parentID = queue[head]
        head = head + 1
        local bucket = childrenByParent[parentID]
        if type(bucket) == "table" then
          for index = 1, #bucket do
            if total >= RELATED_TOTAL_MAX then
              break
            end
            local childID = bucket[index]
            if not seen[childID] then
              seen[childID] = true
              local record = childRecord(childID)
              if record then
                total = total + 1
                if #related < RELATED_MAX then
                  related[#related + 1] = {
                    id = record.id,
                    title = record.title,
                    agent = record.agent,
                    model = record.model,
                    outcome = record.outcome,
                    status = record.status,
                    isActive = record.isActive,
                    wait = record.wait,
                    activity = record.activity,
                    queued = record.queued,
                    tokens = record.tokens,
                    cost = record.cost,
                    updatedAt = record.updatedAt,
                    updatedLabel = record.updatedLabel,
                    depth = depth,
                    childCount = directCount[childID] or 0,
                  }
                end
                if depth < RELATED_MAX_DEPTH then
                  queue[#queue + 1] = childID
                end
              end
            end
          end
        end
        if total >= RELATED_TOTAL_MAX then
          break
        end
      end
      levelEnd = #queue
      depth = depth + 1
    end
    session.related = related
    session.relatedCount = #related
    session.relatedTotal = total
  end

  -- Attach only to the sessions that are actually published.
  for _, session in ipairs(active) do
    attachRelated(session)
  end
  for _, session in ipairs(recent) do
    attachRelated(session)
  end

  local waiting = 0
  local queued = 0
  for _, session in ipairs(active) do
    if session.status == "waiting_permission" or session.status == "waiting_input" then
      waiting = waiting + 1
    end
    queued = queued + (session.queued or 0)
  end

  local warnings = {}
  local incomplete = false
  local function warn(text)
    warnings[#warnings + 1] = shared.redact(text, 160)
    incomplete = true
  end
  if ctx.errors.active then
    warn("Active sessions: " .. tostring(ctx.errors.active))
  end
  if ctx.truncatedActive then
    warn("Active sessions truncated")
  end
  if ctx.errors.permission then
    warn("Permissions: " .. tostring(ctx.errors.permission))
  end
  if ctx.truncatedPermissions then
    warn("Permission requests truncated")
  end
  if ctx.detailsIncomplete then
    if ctx.errors.details then
      warn("Session details: " .. tostring(ctx.errors.details))
    else
      warn("Session details incomplete")
    end
  end
  if lastListError then
    warn("Session list: " .. tostring(lastListError))
  end
  if lastListTruncated then
    warn("Session list truncated")
  end

  local state = incomplete and "degraded" or "online"
  if ctx.errors.active and ctx.errors.permission then
    state = "error"
  end

  local knownIDs = {}
  for _, session in ipairs(active) do
    if type(session) == "table" and shared.isSafeSessionID(session.id) then
      knownIDs[session.id] = true
    end
  end
  for _, session in ipairs(recent) do
    if type(session) == "table" and shared.isSafeSessionID(session.id) then
      knownIDs[session.id] = true
    end
  end
  local visibleRecentCount = 0
  for _, session in ipairs(recent) do
    local hidden = type(session) == "table"
      and session.isChild
      and session.parentID ~= nil
      and knownIDs[session.parentID] == true
    if not hidden then
      visibleRecentCount = visibleRecentCount + 1
    end
  end

  local visibleActiveCount = 0
  for _, session in ipairs(active) do
    local waitingSession = session.status == "waiting_permission" or session.status == "waiting_input"
    local hidden = type(session) == "table"
      and session.isChild
      and session.parentID ~= nil
      and activeByID[session.parentID] ~= nil
    if waitingSession or not hidden then
      visibleActiveCount = visibleActiveCount + 1
    end
  end

  local displayURL = ""
  if type(ctx.server.displayURL) == "string" then
    displayURL = ctx.server.displayURL
  end
  if displayURL == "" then
    local _, sanitized = shared.sanitizeServiceURL(ctx.server.url)
    displayURL = sanitized or ""
  end
  local version = ctx.server.version
  if type(version) == "string" or type(version) == "number" then
    version = shared.redact(version, 40)
    if version == "" then
      version = nil
    end
  else
    version = nil
  end
  local pid = ctx.server.pid
  if type(pid) ~= "string" and type(pid) ~= "number" then
    pid = nil
  end
  if type(pid) == "string" then
    pid = shared.redact(pid, 32)
    if pid == "" then
      pid = nil
    end
  end

  local warningText = #warnings > 0 and shared.redact(table.concat(warnings, "; "), 240) or nil
  local snapshot = {
    generatedAt = now,
    server = {
      state = state,
      message = #warnings > 0 and shared.shorten(warnings[1], 160) or nil,
      warning = warningText,
      url = displayURL,
      version = version,
      pid = pid,
      updatedAt = now,
      pollInterval = currentInterval,
      incomplete = incomplete or nil,
    },
    counts = {
      active = visibleActiveCount,
      waiting = waiting,
      queued = queued,
      recent = visibleRecentCount,
      total = visibleActiveCount + visibleRecentCount,
    },
    primary = active[1],
    sessions = active,
    recent = recent,
  }
  noctalia.state.set(shared.SNAPSHOT_KEY, snapshot)
end

-- Publishing a full snapshot is deliberately deferred out of HTTP callbacks:
-- Noctalia enforces a CPU budget there, and building related trees for dozens
-- of sessions can exceed it. update()/startCycle() flush the finished context.
local function complete(ctx)
  if ctx.done or ctx.token ~= cycle then
    return
  end
  ctx.done = true
  pendingCtx = ctx
  busy = false
end

local function flushPending()
  local ctx = pendingCtx
  pendingCtx = nil
  if not ctx then
    return
  end
  if activeCtx == ctx then
    activeCtx = nil
  end
  if ctx.token ~= cycle then
    ctx.server = nil
    return
  end
  local ok, err = pcall(publish, ctx)
  ctx.server = nil
  if not ok then
    pcall(publishOffline, "OpenCode Monitor internal error: " .. shared.shorten(tostring(err), 180))
  end
end

local function recordDetail(ctx, task, data, err)
  local details = ctx.details[task.id]
  if not details then
    return
  end
  if data then
    local value = data
    if task.extract then
      local extractOk, extracted = pcall(task.extract, data)
      if extractOk then
        value = extracted
      else
        value = nil
        ctx.detailsIncomplete = true
      end
    end
    if task.key == "session" and type(value) == "table" and value.id ~= task.id then
      value = nil
    end
    if value ~= nil then
      details[task.key] = value
    elseif task.key == "session" then
      ctx.detailsIncomplete = true
    end
  else
    local message = shared.redact(err or "Request failed", 140)
    details.errors = details.errors or {}
    details.errors[#details.errors + 1] = message
    details.incomplete = true
    ctx.detailsIncomplete = true
    if not ctx.errors.details then
      ctx.errors.details = message
    end
  end
end

local function pumpDetails(ctx)
  if ctx.pumping or ctx.done or ctx.token ~= cycle then
    return
  end
  ctx.pumping = true
  while not ctx.done and ctx.token == cycle
    and ctx.detailInFlight < DETAIL_MAX_INFLIGHT
    and ctx.detailIndex <= #ctx.detailQueue
  do
    local task = ctx.detailQueue[ctx.detailIndex]
    ctx.detailIndex = ctx.detailIndex + 1
    ctx.detailInFlight = ctx.detailInFlight + 1
    local settled = false

    local function settle(data, err)
      if settled then
        return
      end
      settled = true
      if ctx.token ~= cycle or ctx.done then
        return
      end
      local recordOk, recordErr = pcall(recordDetail, ctx, task, data, err)
      if not recordOk then
        ctx.detailsIncomplete = true
        if not ctx.errors.details then
          ctx.errors.details = shared.redact(tostring(recordErr), 140)
        end
      end
      ctx.detailInFlight = ctx.detailInFlight - 1
      ctx.detailRemaining = ctx.detailRemaining - 1
      if ctx.detailRemaining <= 0 then
        complete(ctx)
      else
        pumpDetails(ctx)
      end
    end

    local callOk, callError = pcall(shared.apiGet, ctx.server, task.path, settle)
    if not callOk and not settled then
      settled = true
      if ctx.token == cycle and not ctx.done then
        local recordOk = pcall(recordDetail, ctx, task, nil, "Request failed: " .. tostring(callError))
        if not recordOk then
          ctx.detailsIncomplete = true
        end
        ctx.detailInFlight = ctx.detailInFlight - 1
        ctx.detailRemaining = ctx.detailRemaining - 1
      end
    end
  end
  ctx.pumping = false
  if not ctx.done and ctx.token == cycle and ctx.detailRemaining <= 0 and #ctx.detailQueue > 0 then
    complete(ctx)
  end
end

local function finishPart(ctx)
  if ctx.done or ctx.detailsStarted then
    return
  end
  ctx.pending = ctx.pending - 1
  if ctx.pending > 0 then
    return
  end
  ctx.detailsStarted = true

  local ids = {}
  for id in pairs(ctx.active) do
    if shared.isSafeSessionID(id) then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids, function(left, right)
    local leftForced = ctx.forced[left] == true
    local rightForced = ctx.forced[right] == true
    if leftForced ~= rightForced then
      return leftForced
    end
    return left < right
  end)
  for _, id in ipairs(ids) do
    ctx.details[id] = { errors = {} }
  end
  if #ids == 0 then
    complete(ctx)
    return
  end

  local selected = math.min(#ids, DETAIL_MAX_SESSIONS)
  if #ids > DETAIL_MAX_SESSIONS then
    ctx.detailsIncomplete = true
    for index = DETAIL_MAX_SESSIONS + 1, #ids do
      ctx.details[ids[index]].incomplete = true
    end
  end
  local queue = {}
  for index = 1, selected do
    local id = ids[index]
    local encoded = shared.encodePathSegment(id)
    for specIndex = 1, DETAIL_REQUESTS do
      local spec = DETAIL_SPECS[specIndex]
      if spec then
        queue[#queue + 1] = {
          id = id,
          key = spec.key,
          path = "/api/session/" .. encoded .. spec.suffix,
          extract = spec.extract,
        }
      end
    end
  end
  ctx.detailQueue = queue
  ctx.detailIndex = 1
  ctx.detailRemaining = #queue
  ctx.detailInFlight = 0
  ctx.pumping = false
  if #queue == 0 then
    complete(ctx)
    return
  end
  pumpDetails(ctx)
end

-- Invalidate every list request currently in flight. A stale callback may still
-- arrive later, but it will see a different generation and return without
-- touching listInFlight, recentList/sessionCache, or lastListAt.
local function invalidateSessionList()
  listGeneration = listGeneration + 1
  listInFlight = false
  listStartedAt = 0
end

local function refreshSessionList(server)
  if listInFlight then
    return
  end
  local requestKey = shared.serverKey(server)
  listGeneration = listGeneration + 1
  local requestGeneration = listGeneration
  listInFlight = true
  listStartedAt = noctalia.nowMs()

  local startedOk, startError = pcall(shared.apiGet, server, "/api/session", function(data, err)
    if requestGeneration ~= listGeneration then
      return
    end
    listInFlight = false
    if requestKey ~= currentServerKey then
      return
    end
    if data then
      local fresh = {}
      local cache = {}
      local truncated = false
      local scanned = 0
      for _, info in ipairs(dataArray(data)) do
        scanned = scanned + 1
        if scanned > MAX_SESSIONS * 2 then
          truncated = true
          break
        end
        if #fresh >= MAX_SESSIONS then
          truncated = true
          break
        end
        if type(info) == "table" and shared.isSafeSessionID(info.id) then
          local archived = type(info.time) == "table" and info.time.archived ~= nil
          if not archived then
            cache[info.id] = info
            fresh[#fresh + 1] = info
          end
        end
      end
      recentList = fresh
      sessionCache = cache
      lastListAt = noctalia.nowMs()
      lastListError = nil
      lastListTruncated = truncated
    else
      lastListAt = noctalia.nowMs()
      lastListError = shared.redact(err or "Request failed", 160)
    end
  end)

  -- apiGet completes false-start requests synchronously. This only covers
  -- an unexpected synchronous error before that completion ran.
  if not startedOk and requestGeneration == listGeneration then
    listInFlight = false
    lastListAt = noctalia.nowMs()
    lastListError = "Request failed: " .. shared.redact(tostring(startError), 120)
  end
end

local function startCycle()
  flushPending()
  if busy then
    return
  end

  local server, serviceError = shared.findService()
  if not server then
    publishOffline(serviceError)
    return
  end

  local key = shared.serverKey(server)
  if key ~= currentServerKey then
    currentServerKey = key
    sessionCache = {}
    recentList = {}
    lastListAt = 0
    lastListError = nil
    lastListTruncated = false
    invalidateSessionList()
  end

  local now = noctalia.nowMs()
  busy = true
  busySince = now
  cycle = cycle + 1
  local token = cycle

  if listInFlight and now - listStartedAt > WATCHDOG_MS then
    invalidateSessionList()
  end

  if now - lastListAt >= LIST_INTERVAL_MS then
    refreshSessionList(server)
  end

  local ctx = {
    token = token,
    server = server,
    active = {},
    forced = {},
    permissions = {},
    details = {},
    errors = {},
    pending = 2,
    done = false,
    activeCount = 0,
    truncatedActive = false,
    truncatedPermissions = false,
    detailsIncomplete = false,
    detailsStarted = false,
    detailQueue = {},
    detailIndex = 1,
    detailRemaining = 0,
    detailInFlight = 0,
    pumping = false,
  }
  activeCtx = ctx

  shared.apiGet(server, "/api/session/active", function(data, err)
    if ctx.token ~= cycle or ctx.done then
      return
    end
    if data then
      local activeMap = type(data.data) == "table" and data.data or nil
      if activeMap then
        local scanned = 0
        for sessionID, value in pairs(activeMap) do
          scanned = scanned + 1
          if scanned > MAX_ACTIVE * 4 then
            ctx.truncatedActive = true
            break
          end
          if type(sessionID) == "string"
            and shared.isSafeSessionID(sessionID)
            and type(value) == "table"
          then
            if value.type == nil or value.type == "running" then
              if not ctx.active[sessionID] and not ensureActive(ctx, sessionID, false) then
                ctx.truncatedActive = true
                break
              end
            end
          end
        end
      end
    else
      ctx.errors.active = shared.redact(err or "Request failed", 160)
    end
    finishPart(ctx)
  end)

  shared.apiGet(server, "/api/permission/request", function(data, err)
    if ctx.token ~= cycle or ctx.done then
      return
    end
    if data then
      local accepted = 0
      local scanned = 0
      for _, permission in ipairs(dataArray(data)) do
        scanned = scanned + 1
        if scanned > MAX_PERMISSIONS * 4 then
          ctx.truncatedPermissions = true
          break
        end
        if accepted >= MAX_PERMISSIONS then
          ctx.truncatedPermissions = true
          break
        end
        if type(permission) == "table" and shared.isSafeSessionID(permission.sessionID) then
          local sessionID = permission.sessionID
          local bucket = ctx.permissions[sessionID]
          if not bucket then
            if ensureActive(ctx, sessionID, true) then
              bucket = {}
              ctx.permissions[sessionID] = bucket
            else
              ctx.truncatedPermissions = true
            end
          end
          if bucket then
            bucket[#bucket + 1] = permission
            accepted = accepted + 1
          end
        end
      end
    else
      ctx.errors.permission = shared.redact(err or "Request failed", 160)
    end
    finishPart(ctx)
  end)
end

-- ------------------------------------------------------------------ entry

noctalia.state.watch(shared.REFRESH_KEY, function()
  if not busy then
    startCycle()
  end
end)

-- Noctalia exposes no HTTP cancellation: a request started before a reset can
-- hold a host slot for up to 30s. The bumped cycle and ctx.done make every late
-- callback return before it can touch current state.
local function resetTransient()
  local ctx = activeCtx
  activeCtx = nil
  if ctx then
    ctx.done = true
    ctx.detailQueue = {}
    ctx.detailIndex = 0
    ctx.detailRemaining = 0
    ctx.detailInFlight = 0
    ctx.pumping = false
    ctx.details = {}
    ctx.active = {}
    ctx.permissions = {}
    ctx.server = nil
  end
  busy = false
  busySince = 0
  pendingCtx = nil
  lastListAt = 0
  cycle = cycle + 1
  invalidateSessionList()
end

function update()
  local interval = shared.intSetting("poll_interval", 2, 1, 15)
  if interval ~= currentInterval then
    currentInterval = interval
    noctalia.setUpdateInterval(interval * 1000)
  end

  local now = noctalia.nowMs()
  flushPending()
  if busy and now - busySince > WATCHDOG_MS then
    resetTransient()
  end
  if not busy then
    startCycle()
  end
end

function onIpc(event)
  if event == "refresh" or event == "reload" then
    if event == "reload" then
      resetTransient()
    else
      flushPending()
    end
    if not busy then
      startCycle()
    end
  end
end

function onConfigChanged()
  currentInterval = nil
  resetTransient()
  startCycle()
end

function onEnable()
  resetTransient()
  startCycle()
end

noctalia.setUpdateInterval(2000)
update()
