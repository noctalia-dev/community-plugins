--!nonstrict

local Notifications = require("./lib/notifications.luau")

local inFlight = false
local pendingThreads = {}
local markAllPending = false
local cacheFilePath = nil

local function getCacheFilePath()
  if cacheFilePath ~= nil then
    return cacheFilePath
  end
  local dataDir = noctalia.pluginDataDir()
  if dataDir == nil then
    return nil
  end
  cacheFilePath = dataDir .. "/notifications.json"
  return cacheFilePath
end

local function persistCache(items, unreadCount)
  local path = getCacheFilePath()
  if path == nil then
    return
  end
  local payload = {
    items = items or {},
    unreadCount = unreadCount or 0,
    timestamp = noctalia.nowMs(),
  }
  local encoded, err = noctalia.json.encode(payload)
  if encoded ~= nil then
    noctalia.writeFile(path, encoded)
  else
    noctalia.log("GitHub Notifications: cache encode error: " .. tostring(err))
  end
end

local function loadCache()
  local path = getCacheFilePath()
  if path == nil then
    return
  end
  local contents, _err = noctalia.readFile(path)
  if contents == nil or contents == "" then
    return
  end
  local cached, decodeErr = noctalia.json.decode(contents)
  if type(cached) == "table" and type(cached.items) == "table" then
    noctalia.state.set("github_notifications:items", cached.items)
    noctalia.state.set("github_notifications:unread_count", tonumber(cached.unreadCount) or #cached.items)
    noctalia.state.set("github_notifications:last_updated", cached.timestamp or noctalia.nowMs())
    noctalia.state.set("github_notifications:stale", true)
    noctalia.state.set("github_notifications:status", "ready")
  else
    noctalia.log("GitHub Notifications: invalid cache file: " .. tostring(decodeErr))
  end
end

local function publishState(status, errorMsg)
  noctalia.state.set("github_notifications:status", status)
  noctalia.state.set("github_notifications:error", errorMsg or "")
end

local function classifyError(stderr)
  local lower = string.lower(stderr or "")
  if string.find(lower, "rate limit", 1, true) or string.find(lower, "rate-limit", 1, true) or string.find(lower, "secondary rate", 1, true) then
    return "rate_limited", noctalia.tr("status.rate_limited_detail")
  end
  if string.find(lower, "403", 1, true) or string.find(lower, "permission", 1, true) or string.find(lower, "scope", 1, true) or string.find(lower, "sso", 1, true) then
    return "auth_error", noctalia.tr("status.permission_denied")
  end
  if string.find(lower, "auth", 1, true) or string.find(lower, "token", 1, true) or string.find(lower, "login", 1, true) or string.find(lower, "401", 1, true) then
    return "auth_error", noctalia.tr("status.auth_error_detail")
  end
  if string.find(lower, "could not resolve host", 1, true) or string.find(lower, "connection refused", 1, true) or string.find(lower, "network", 1, true) or string.find(lower, "timed out", 1, true) or string.find(lower, "timeout", 1, true) then
    return "error", noctalia.tr("status.network_error")
  end
  return "error", noctalia.tr("status.request_failed")
end

local function refresh()
  if inFlight then
    return
  end

  if not noctalia.commandExists("gh") then
    inFlight = false
    publishState("missing_gh", "GitHub CLI (gh) is not installed on PATH.")
    return
  end

  inFlight = true
  publishState("loading", "")

  local perPageSetting = tostring(noctalia.getConfig("per_page") or "50")
  local perPage = tonumber(perPageSetting) or 50
  perPage = math.max(1, math.min(perPage, 50))
  local queryParam = string.format("notifications?all=false&per_page=%d", perPage)

  noctalia.runAsync({ "gh", "api", queryParam }, function(result)
    inFlight = false

    if result.exitCode ~= 0 then
      noctalia.log("GitHub Notifications: API request failed (exit code " .. tostring(result.exitCode) .. ")")
      local errStatus, errDetail = classifyError(result.stderr)
      publishState(errStatus, errDetail)
      return
    end

    -- If mark-all is currently in flight, drop stale GET results to prevent resurrection
    if markAllPending then
      return
    end

    local rawList, decodeErr = noctalia.json.decode(result.stdout or "[]")
    if type(rawList) ~= "table" then
      publishState("error", noctalia.tr("status.request_failed"))
      return
    end

    local rawItems = Notifications.normalizeList(rawList)
    local items = {}
    for _, item in ipairs(rawItems) do
      local idStr = tostring(item.id)
      -- Exclude any thread currently being marked as read
      if not pendingThreads[idStr] then
        table.insert(items, item)
      end
    end

    local unreadCount = #items

    noctalia.state.set("github_notifications:items", items)
    noctalia.state.set("github_notifications:unread_count", unreadCount)
    noctalia.state.set("github_notifications:last_updated", noctalia.nowMs())
    noctalia.state.set("github_notifications:stale", false)
    publishState("ready", "")

    persistCache(items, unreadCount)
  end)
end

local function markThreadRead(threadId)
  -- Validate thread ID format before using in REST endpoint path
  if not Notifications.isValidThreadId(threadId) then
    noctalia.log("GitHub Notifications: rejected invalid thread ID: " .. tostring(threadId))
    return
  end

  local idStr = tostring(threadId)

  -- Prevent duplicate simultaneous mark-read requests for the same thread
  if pendingThreads[idStr] == true then
    return
  end
  pendingThreads[idStr] = true

  local currentItems = noctalia.state.get("github_notifications:items") or {}
  local targetItem = nil
  local updatedItems = {}

  for _, item in ipairs(currentItems) do
    if tostring(item.id) == idStr then
      targetItem = item
    else
      table.insert(updatedItems, item)
    end
  end

  -- Optimistic local removal
  if targetItem then
    local newCount = math.max(0, #updatedItems)
    noctalia.state.set("github_notifications:items", updatedItems)
    noctalia.state.set("github_notifications:unread_count", newCount)
    persistCache(updatedItems, newCount)
  end

  -- Send PATCH request to GitHub API
  noctalia.runAsync({ "gh", "api", "--method", "PATCH", "notifications/threads/" .. idStr }, function(result)
    pendingThreads[idStr] = nil

    if result.exitCode ~= 0 then
      noctalia.log("GitHub Notifications: failed to mark thread " .. idStr .. " as read (exit code " .. tostring(result.exitCode) .. ")")

      -- Roll back optimistic removal on failure
      if targetItem then
        local itemsNow = noctalia.state.get("github_notifications:items") or {}
        local alreadyPresent = false
        for _, it in ipairs(itemsNow) do
          if tostring(it.id) == idStr then
            alreadyPresent = true
            break
          end
        end
        if not alreadyPresent then
          table.insert(itemsNow, 1, targetItem)
          local restoredCount = math.max(0, (noctalia.state.get("github_notifications:unread_count") or 0) + 1)
          noctalia.state.set("github_notifications:items", itemsNow)
          noctalia.state.set("github_notifications:unread_count", restoredCount)
          persistCache(itemsNow, restoredCount)
        end
      end

      local errStatus, errDetail = classifyError(result.stderr)
      publishState(errStatus, errDetail)
    end
  end)
end

local function markAllRead()
  if markAllPending then
    return
  end

  local items = noctalia.state.get("github_notifications:items") or {}
  if #items == 0 then
    return
  end

  markAllPending = true

  -- Optimistic local clear
  local previousItems = items
  local previousCount = #items
  noctalia.state.set("github_notifications:items", {})
  noctalia.state.set("github_notifications:unread_count", 0)
  persistCache({}, 0)

  -- Send PUT request to GitHub API
  noctalia.runAsync({ "gh", "api", "--method", "PUT", "notifications" }, function(result)
    markAllPending = false

    if result.exitCode ~= 0 then
      noctalia.log("GitHub Notifications: failed to mark all as read (exit code " .. tostring(result.exitCode) .. ")")
      -- Restore state on failure
      noctalia.state.set("github_notifications:items", previousItems)
      noctalia.state.set("github_notifications:unread_count", previousCount)
      persistCache(previousItems, previousCount)

      local errStatus, errDetail = classifyError(result.stderr)
      publishState(errStatus, errDetail)
    end
  end)
end

local function configureUpdateInterval()
  local intervalSetting = tostring(noctalia.getConfig("refresh_interval_seconds") or "120")
  local seconds = tonumber(intervalSetting) or 120
  if seconds < 30 then
    seconds = 30
  end
  noctalia.setUpdateInterval(seconds * 1000)
end

-- Initialize service
configureUpdateInterval()
loadCache()
refresh()

-- Listen for actions triggered from panel / widget via state
noctalia.state.watch("github_notifications:action", function(action)
  -- Validate shared-state payload structure and action type
  if type(action) ~= "table" or type(action.type) ~= "string" then
    return
  end

  if action.type == "refresh" then
    refresh()
  elseif action.type == "mark_read" then
    if Notifications.isValidThreadId(action.id) then
      markThreadRead(action.id)
    else
      noctalia.log("GitHub Notifications: received invalid action.id in mark_read")
    end
  elseif action.type == "mark_all_read" then
    markAllRead()
  end
end)

function update()
  refresh()
end

function onEnable()
  refresh()
end

function onConfigChanged()
  configureUpdateInterval()
  refresh()
end

function onIpc(event, payload)
  -- Validate external IPC commands
  if event == "refresh" then
    refresh()
  elseif event == "mark_read" then
    if Notifications.isValidThreadId(payload) then
      markThreadRead(payload)
    else
      noctalia.log("GitHub Notifications: received invalid IPC payload in mark_read: " .. tostring(payload))
    end
  elseif event == "mark_all_read" then
    markAllRead()
  end
end
