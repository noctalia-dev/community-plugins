-- Read-only dashboard data service. All GitHub access is through `gh` and
-- every request is a direct argv invocation; this service never mutates GitHub.
local GitHub = require("./lib/github.luau")
local Data = require("./lib/data.luau")

local CACHE_FILE = "dashboard.json"
local DATA_KEYS = {
  "profile", "contributions", "following_users", "following_events", "following_repos",
  "following_repo_events", "my_prs", "review_prs", "authored_issues", "issues", "repositories", "actions",
}
local dashboard = { errors = {} }
local cachePath, cachedDashboard
local account, generation = nil, 0
local inFlight = false
local refreshSerial, refreshDeadline = 0, 0
local hasCachedData = false
local followingAvatarPaths = {}
local repositoryAvatarPaths = {}
local cachedAvatarUrl, cachedAvatarPath = nil, nil
local ownedAvatarPaths, pendingAvatarPaths = {}, {}

local function refreshInterval()
  return math.clamp(tonumber(noctalia.getConfig("refresh_interval_minutes")) or 15, 5, 30) * 60 * 1000
end

local function followingHistoryDays()
  return math.clamp(tonumber(noctalia.getConfig("following_history_days")) or 30, 1, 30)
end

local function activityHistoryDays()
  return math.clamp(tonumber(noctalia.getConfig("activity_history_days")) or 30, 1, 365)
end

local function configInt(key, default, minimum, maximum)
  return math.clamp(tonumber(noctalia.getConfig(key)) or default, minimum, maximum)
end

local function configSet(key)
  local set = {}
  local value = noctalia.getConfig(key)
  if type(value) == "table" then
    for _, item in ipairs(value) do set[string.lower(tostring(item))] = true end
  end
  return set
end

local function followingTypeEnabled(eventType)
  local key = "following_show_other"
  if eventType == "WatchEvent" then key = "following_show_stars"
  elseif eventType == "PushEvent" then key = "following_show_pushes"
  elseif eventType == "IssuesEvent" or eventType == "IssueCommentEvent" then key = "following_show_issues"
  elseif eventType == "PullRequestEvent" or eventType == "PullRequestReviewEvent" or eventType == "PullRequestReviewCommentEvent" then key = "following_show_pull_requests"
  elseif eventType == "ReleaseEvent" then key = "following_show_releases"
  elseif eventType == "ForkEvent" then key = "following_show_forks" end
  return noctalia.getConfig(key) ~= false
end

local function recentItems(items, days)
  local cutoff = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - days * 86400)
  local out = {}
  for _, item in ipairs(items) do
    local timestamp = item.updatedAt or item.createdAt or ""
    if timestamp == "" or timestamp >= cutoff then out[#out + 1] = item end
  end
  return out
end

local function recentFollowingItems(items)
  return recentItems(items, followingHistoryDays())
end

local function filterFollowingEvents(items)
  local ignoredUsers = configSet("following_ignored_users")
  local ignoredRepositories = configSet("following_ignored_repositories")
  local hideBots = noctalia.getConfig("following_hide_bots") == true
  local out = {}
  for _, item in ipairs(recentFollowingItems(items)) do
    local actor = string.lower(tostring(item.actor or ""))
    local repository = string.lower(tostring(item.repository or ""))
    local isBot = item.actorType == "Bot" or actor:match("%[bot%]$") ~= nil
    if not ignoredUsers[actor] and not ignoredRepositories[repository]
      and (not hideBots or not isBot) and followingTypeEnabled(item.type) then
      out[#out + 1] = item
    end
  end
  return out
end

local function publish(key, value)
  dashboard[key] = value
  noctalia.state.set(key, value)
end

local persist

-- Only remove files this service instance explicitly downloaded. Shared owner
-- images can have several references; pending downloads clean up on completion.
local function releaseAvatar(path)
  if not path or not ownedAvatarPaths[path] or pendingAvatarPaths[path] or cachedAvatarPath == path then return end
  for _, current in pairs(followingAvatarPaths) do if current == path then return end end
  for _, current in pairs(repositoryAvatarPaths) do if current == path then return end end
  if noctalia.removeFile(path) or not noctalia.fileExists(path) then ownedAvatarPaths[path] = nil end
end

local function pruneAvatars()
  local users, repositories = {}, {}
  for _, item in ipairs(dashboard.following_events or {}) do users[item.actor] = true end
  for _, item in ipairs(dashboard.following_repo_events or {}) do repositories[item.repository] = true end
  for login in pairs(followingAvatarPaths) do if not users[login] then followingAvatarPaths[login] = nil end end
  for name in pairs(repositoryAvatarPaths) do if not repositories[name] then repositoryAvatarPaths[name] = nil end end
  for path in pairs(ownedAvatarPaths) do releaseAvatar(path) end
end

local function publishFollowingAvatar(login, path)
  local previous = followingAvatarPaths[login]
  followingAvatarPaths[login] = path
  local changed = false
  for _, item in ipairs(dashboard.following_events or {}) do
    if item.actor == login then
      item.actorAvatarPath = path
      changed = true
    end
  end
  if changed then publish("following_events", dashboard.following_events) end
  releaseAvatar(previous)
end

local function cacheFollowingAvatars(users, index, expectedGeneration, expectedSerial)
  expectedGeneration = expectedGeneration or generation
  expectedSerial = expectedSerial or refreshSerial
  if expectedGeneration ~= generation or expectedSerial ~= refreshSerial then return end
  index = index or 1
  if index > #users then return end
  local user = users[index]
  local login = tostring(user.login or "")
  local url = tostring(user.avatarUrl or "")
  local dir = noctalia.pluginDataDir()
  if login == "" or url == "" or not dir then
    cacheFollowingAvatars(users, index + 1, expectedGeneration, expectedSerial)
    return
  end
  local dest = dir .. "/following-avatar-" .. account .. "-" .. tostring(generation) .. "-" .. tostring(refreshSerial) .. "-" .. login:gsub("[^%w%-]", "_")
  ownedAvatarPaths[dest], pendingAvatarPaths[dest] = true, true
  noctalia.download(url, dest, function(ok)
    pendingAvatarPaths[dest] = nil
    if expectedGeneration ~= generation or expectedSerial ~= refreshSerial then releaseAvatar(dest); return end
    if ok then publishFollowingAvatar(login, dest) else releaseAvatar(dest) end
    cacheFollowingAvatars(users, index + 1, expectedGeneration, expectedSerial)
  end)
end

local function avatarDest()
  local dir = noctalia.pluginDataDir()
  return dir and account and (dir .. "/profile-avatar-" .. account .. "-" .. tostring(generation) .. "-" .. tostring(refreshSerial)) or nil
end
local function cacheProfileAvatar(profile)
  local url = tostring(profile and profile.avatarUrl or "")
  local dest = avatarDest()
  if url == "" or not dest then return end
  if url == cachedAvatarUrl and cachedAvatarPath and noctalia.fileExists(cachedAvatarPath) then return end
  local expectedGeneration, expectedSerial = generation, refreshSerial
  ownedAvatarPaths[dest], pendingAvatarPaths[dest] = true, true
  noctalia.download(url, dest, function(ok)
    pendingAvatarPaths[dest] = nil
    if expectedGeneration ~= generation or expectedSerial ~= refreshSerial or not ok or dashboard.profile ~= profile then releaseAvatar(dest); return end
    local previous = cachedAvatarPath
    local changed = cachedAvatarUrl ~= url or profile.avatarPath ~= dest
    cachedAvatarUrl, cachedAvatarPath = url, dest
    profile.avatarPath = dest
    releaseAvatar(previous)
    if changed then
      publish("profile", profile)
      persist()
    end
  end)
end

local function publishRepositoryAvatar(fullName, path)
  local previous = repositoryAvatarPaths[fullName]
  repositoryAvatarPaths[fullName] = path
  local changed = false
  for _, item in ipairs(dashboard.following_repo_events or {}) do
    if item.repository == fullName then
      item.repositoryOwnerAvatarPath = path
      changed = true
    end
  end
  if changed then publish("following_repo_events", dashboard.following_repo_events) end
  releaseAvatar(previous)
end

local function cacheRepositoryAvatars(repositories, index, expectedGeneration, expectedSerial)
  expectedGeneration = expectedGeneration or generation
  expectedSerial = expectedSerial or refreshSerial
  if expectedGeneration ~= generation or expectedSerial ~= refreshSerial then return end
  index = index or 1
  if index > #repositories then return end
  local repository = repositories[index]
  local fullName = tostring(repository.fullName or "")
  local url = tostring(repository.ownerAvatarUrl or "")
  local dir = noctalia.pluginDataDir()
  if fullName == "" or url == "" or not dir then
    cacheRepositoryAvatars(repositories, index + 1, expectedGeneration, expectedSerial)
    return
  end
  local owner = tostring(repository.ownerLogin or fullName:match("^([^/]+)") or "owner")
  local dest = dir .. "/repository-owner-avatar-" .. account .. "-" .. tostring(generation) .. "-" .. tostring(refreshSerial) .. "-" .. owner:gsub("[^%w%-]", "_")
  -- Several starred repositories can share an owner and this round's image.
  if ownedAvatarPaths[dest] and not pendingAvatarPaths[dest] and noctalia.fileExists(dest) then
    publishRepositoryAvatar(fullName, dest)
    cacheRepositoryAvatars(repositories, index + 1, expectedGeneration, expectedSerial)
    return
  end
  ownedAvatarPaths[dest], pendingAvatarPaths[dest] = true, true
  noctalia.download(url, dest, function(ok)
    pendingAvatarPaths[dest] = nil
    if expectedGeneration ~= generation or expectedSerial ~= refreshSerial then releaseAvatar(dest); return end
    if ok then publishRepositoryAvatar(fullName, dest) else releaseAvatar(dest) end
    cacheRepositoryAvatars(repositories, index + 1, expectedGeneration, expectedSerial)
  end)
end

persist = function()
  if not cachePath or not account then return end
  local encoded = noctalia.json.encode(dashboard)
  if encoded then noctalia.writeFile(cachePath, encoded) end
end

local function loadCache()
  local dataDir = noctalia.pluginDataDir()
  if not dataDir then return end
  cachePath = dataDir .. "/" .. CACHE_FILE
  local raw = noctalia.readFile(cachePath)
  if not raw then return end
  local cached = noctalia.json.decode(raw)
  if type(cached) == "table" then cachedDashboard = cached end
end

local function setAccount(login)
  login = string.lower(login)
  if account == login then return end
  account, generation = login, generation + 1
  hasCachedData = false
  followingAvatarPaths, repositoryAvatarPaths, cachedAvatarUrl, cachedAvatarPath = {}, {}, nil, nil
  for _, key in ipairs(DATA_KEYS) do publish(key, {}) end
  pruneAvatars()
  dashboard.last_update, dashboard.login = nil, login
  noctalia.state.set("last_update", "")
  noctalia.state.set("login", login)
  local cached = cachedDashboard
  cachedDashboard = nil
  -- Older dashboard caches stored their owner in profile.login only.
  local owner = cached and (cached.login or (cached.profile and cached.profile.login))
  if type(owner) == "string" and string.lower(owner) == login then
    for _, key in ipairs(DATA_KEYS) do
      local value = cached[key]
      if type(value) == "table" then
        -- Legacy avatar files were shared between accounts. Only freshly
        -- verified downloads may attach an avatar path to restored data.
        if key == "profile" then value.avatarPath = nil end
        for _, item in ipairs(value) do
          if type(item) == "table" then item.actorAvatarPath, item.repositoryOwnerAvatarPath = nil, nil end
        end
        publish(key, value)
      end
    end
    hasCachedData = true
    dashboard.last_update = type(cached.last_update) == "number" and cached.last_update or nil
    noctalia.state.set("last_update", dashboard.last_update or "")
  end
  noctalia.state.set("dashboard", dashboard)
end

local function decode(result)
  if result.exitCode ~= 0 then
    local message = result.stderr or ""
    if message == "" then message = noctalia.tr("status.gh_request_failed") end
    return nil, message:gsub("[\r\n].*", "")
  end
  local parsed, err = noctalia.json.decode(result.stdout or "")
  if type(parsed) ~= "table" then return nil, tostring(err or noctalia.tr("status.invalid_json")) end
  return parsed
end

local function refresh()
  if inFlight then return end
  if not noctalia.commandExists("gh") then
    dashboard.status = "missing_gh"
    dashboard.stale = hasCachedData
    dashboard.errors = { gh = noctalia.tr("status.missing_gh") }
    noctalia.state.set("dashboard", dashboard)
    noctalia.state.set("status", dashboard.status)
    noctalia.state.set("stale", dashboard.stale)
    noctalia.state.set("errors", dashboard.errors)
    return
  end

  inFlight = true
  refreshSerial += 1
  local serial = refreshSerial
  refreshDeadline = noctalia.nowMs() + 120000
  noctalia.setUpdateInterval(1000)
  dashboard.status = "loading"
  dashboard.stale = true
  dashboard.errors = {}
  noctalia.state.set("status", "loading")
  noctalia.state.set("stale", true)
  noctalia.state.set("errors", dashboard.errors)

  local pending = 0
  local scheduling, verifying, authenticated = true, false, false
  local commands = GitHub.commands()
  local staged, followingAvatars, repositoryAvatars = {}, nil, nil
  local publishNow = publish
  local function publish(key, value) staged[key] = value end
  local function reportFailure(key, err)
    local message = tostring(err)
    dashboard.errors[key] = message
    local lower = string.lower(message)
    if lower:find("auth", 1, true) or lower:find("token", 1, true) or lower:find("401", 1, true) then
      dashboard.errors.auth = noctalia.tr("status.auth_error")
    end
  end
  local function finishRefresh(commit)
    -- Normal errors finish below. A hard callback-budget abort may interrupt
    -- that cleanup too, so retain the busy slot until state publication ends;
    -- the absolute watchdog can then recover it on an independent update.
    local ok, err = pcall(function()
      if commit then
        for key, value in pairs(staged) do publishNow(key, value) end
        hasCachedData = true
        dashboard.last_update = os.time()
        pruneAvatars()
        cacheProfileAvatar(dashboard.profile)
        if followingAvatars then cacheFollowingAvatars(followingAvatars) end
        if repositoryAvatars then cacheRepositoryAvatars(repositoryAvatars) end
      end
    end)
    if not ok then
      reportFailure("processing", noctalia.tr("status.unexpected_data"))
      noctalia.log("Dashboard processing failed: " .. tostring(err):sub(1, 300))
    end
    dashboard.status = dashboard.errors.auth and "auth_error" or (next(dashboard.errors) and "partial" or "ready")
    dashboard.stale = dashboard.status ~= "ready" and hasCachedData
    noctalia.state.set("error", dashboard.errors.auth or (dashboard.status == "partial" and noctalia.tr("status.request_error") or ""))
    noctalia.state.set("last_update", dashboard.last_update or "")
    noctalia.state.set("status", dashboard.status)
    noctalia.state.set("stale", dashboard.stale)
    noctalia.state.set("errors", dashboard.errors)
    noctalia.state.set("dashboard", dashboard)
    inFlight = false
    noctalia.setUpdateInterval(refreshInterval())
    if commit and ok then persist() end
  end
  local function verifiedProfile(raw)
    local profile = Data.profile(raw)
    if not profile or type(profile.login) ~= "string" or not profile.login:match("^[%w%-]+$") then
      return nil
    end
    return profile
  end
  local function finalizeRefresh()
    if scheduling or pending ~= 0 or verifying then return end
    if not authenticated then finishRefresh(false); return end
    -- gh reads its active account per command. Do not publish the data round
    -- unless identity still matches after every section has completed.
    verifying = true
    local called = false
    local expectedGeneration = generation
    local function verified(result)
      if called or serial ~= refreshSerial or not inFlight then return end
      called = true
      local ok, err = pcall(function()
        local raw, failure = decode(result)
        local profile = raw and verifiedProfile(raw)
        if not profile then reportFailure("profile", failure or noctalia.tr("status.unexpected_data")); finishRefresh(false); return end
        if expectedGeneration ~= generation or string.lower(profile.login) ~= account then
          setAccount(profile.login)
          publishNow("profile", profile)
          reportFailure("auth", noctalia.tr("status.auth_error"))
          finishRefresh(false)
          return
        end
        finishRefresh(true)
      end)
      if not ok then
        -- The watchdog owns cleanup if even final status publication aborted.
        noctalia.log("Dashboard identity verification failed: " .. tostring(err):sub(1, 300))
      end
    end
    local started = noctalia.runAsync(commands.profile, verified)
    if not started and not called then verified({exitCode = -1, stderr = noctalia.tr("status.cli_start_failed")}) end
  end
  local function finishOne()
    pending -= 1
    finalizeRefresh()
  end

  local function request(key, argv, normalize, after, publishResult, complete)
    pending += 1
    local called, expectedGeneration = false, generation
    local function replied(result)
      if called or serial ~= refreshSerial or not inFlight then return end
      called = true
      local succeeded = false
      local ok, err = pcall(function()
        if key ~= "profile" and expectedGeneration ~= generation then return end
        local decoded, failure = decode(result)
        if not decoded then reportFailure(key, failure); return end
        local value = normalize(decoded)
        if value == nil then reportFailure(key, noctalia.tr("status.unexpected_data")); return end
        dashboard.errors[key] = nil
        if publishResult ~= false then publish(key, value) end
        if after then after(decoded, value) end
        succeeded = true
      end)
      if not ok then
        reportFailure(key, noctalia.tr("status.unexpected_data"))
        noctalia.log("Dashboard request processing failed: " .. tostring(err):sub(1, 300))
      end
      if complete then
        local completed, error = pcall(complete, succeeded)
        if not completed then
          reportFailure(key, noctalia.tr("status.unexpected_data"))
          noctalia.log("Dashboard series processing failed: " .. tostring(error):sub(1, 300))
        end
      end
      finishOne()
    end
    local started = noctalia.runAsync(argv, replied)
    if not started and not called then replied({exitCode = -1, stderr = noctalia.tr("status.cli_start_failed")}) end
  end

  local function requestSeries(items, limit, outputKey, errorKey, command, normalize)
    local result = {}
    local index = 1
    local failed = false
    local function nextItem()
      if index > math.min(#items, limit) then
        if not failed then
          hasCachedData = true
          publish(outputKey, result)
        end
        return
      end
      local itemIndex = index
      local item = items[index]
      index += 1
      request(errorKey .. "." .. tostring(itemIndex), command(item), function(raw) return normalize(raw, item) end, function(_, values)
        for _, value in ipairs(values) do table.insert(result, value) end
      end, false, function(succeeded)
        if not succeeded then failed = true end
        nextItem()
      end)
    end
    nextItem()
  end

  local function requestRepositories()
    request("repositories", commands.repositories, function(raw) return Data.repositories(raw, "owner") end, function(_, repos)
      requestSeries(repos, GitHub.ACTION_REPO_LIMIT, "actions", "actions", function(repo)
        return GitHub.actions(repo.fullName)
      end, function(raw, repo) return recentItems(Data.runs(raw, repo.fullName), activityHistoryDays()) end)
    end)
  end

  local function requestDashboard()
    request("contributions", commands.contributions, Data.contributions)
    requestRepositories()
    request("following", commands.following, function(raw)
      local out = {}
      local ignoredUsers = configSet("following_ignored_users")
      local hideBots = noctalia.getConfig("following_hide_bots") == true
      for _, user in ipairs(raw) do
        local login = user.login or ""
        local isBot = user.type == "Bot" or string.lower(login):match("%[bot%]$") ~= nil
        if not ignoredUsers[string.lower(login)] and (not hideBots or not isBot) then
          table.insert(out, { login = login, name = user.name or login, avatarUrl = user.avatar_url or "", url = user.html_url or "", type = user.type or "" })
        end
      end
      return out
    end, function(_, users)
      local userLimit = configInt("following_user_limit", 4, 1, 12)
      local eventLimit = configInt("following_events_per_user", 30, 1, 30)
      local selectedUsers = {}
      for index = 1, math.min(#users, userLimit) do selectedUsers[#selectedUsers + 1] = users[index] end
      requestSeries(selectedUsers, userLimit, "following_events", "following_events", function(user)
        return GitHub.events(user.login, eventLimit)
      end, function(raw, user)
        local events = filterFollowingEvents(Data.events(raw, "user", user.name or user.login))
        for _, event in ipairs(events) do event.actorAvatarPath = followingAvatarPaths[event.actor] end
        return events
      end)
      publish("following_users", selectedUsers)
      followingAvatars = selectedUsers
    end)
    local function filterReleaseFeed(raw)
      local feed = Data.starredReleaseFeed(raw)
      local ignoredRepositories = configSet("following_ignored_repositories")
      local includePrereleases = noctalia.getConfig("following_include_prereleases") ~= false
      local releasesEnabled = noctalia.getConfig("following_show_releases") ~= false
      local filtered = {}
      for _, event in ipairs(recentFollowingItems(feed.events)) do
        if releasesEnabled and (includePrereleases or not event.prerelease)
          and not ignoredRepositories[string.lower(event.repository or "")] then
          filtered[#filtered + 1] = event
        end
      end
      feed.events = filtered
      local selected, byName = {}, {}
      for _, repository in ipairs(feed.repositories) do byName[repository.fullName] = repository end
      for _, event in ipairs(feed.events) do selected[#selected + 1] = byName[event.repository] end
      feed.repositories = selected
      return feed
    end
    local function publishReleaseFeed(feed)
      table.sort(feed.events, function(a, b) return a.createdAt > b.createdAt end)
      while #feed.events > Data.RELEASE_FEED_LIMIT do table.remove(feed.events) end
      local byName, repositories = {}, {}
      for _, repository in ipairs(feed.repositories) do byName[repository.fullName] = repository end
      for _, event in ipairs(feed.events) do repositories[#repositories + 1] = byName[event.repository] end
      feed.repositories = repositories
      for _, event in ipairs(feed.events) do event.repositoryOwnerAvatarPath = repositoryAvatarPaths[event.repository] end
      publish("following_repos", feed.repositories)
      publish("following_repo_events", feed.events)
      repositoryAvatars = feed.repositories
    end
    local starredLimit = configInt("starred_repository_limit", 100, 10, 100)
    local firstPageCount = math.min(50, starredLimit)
    request("following_repos", GitHub.starredReleases(firstPageCount), filterReleaseFeed, function(raw, firstFeed)
      local connection = raw.data and raw.data.viewer and raw.data.viewer.starredRepositories
      local pageInfo = connection and connection.pageInfo or {}
      local remaining = starredLimit - firstPageCount
      if remaining <= 0 or not pageInfo.hasNextPage or not pageInfo.endCursor then
        publishReleaseFeed(firstFeed)
        return
      end
      request("following_repos", GitHub.starredReleases(math.min(50, remaining), pageInfo.endCursor), filterReleaseFeed, function(_, secondFeed)
        local repositories, events = {}, {}
        for _, repository in ipairs(firstFeed.repositories) do repositories[#repositories + 1] = repository end
        for _, repository in ipairs(secondFeed.repositories) do repositories[#repositories + 1] = repository end
        for _, event in ipairs(firstFeed.events) do events[#events + 1] = event end
        for _, event in ipairs(secondFeed.events) do events[#events + 1] = event end
        publishReleaseFeed({ repositories = repositories, events = events })
      end, false)
    end, false)
    request("my_prs", commands.my_prs, function(raw) return recentItems(Data.issues(raw, "author"), activityHistoryDays()) end)
    request("review_prs", commands.review_prs, function(raw) return recentItems(Data.issues(raw, "review_requested"), activityHistoryDays()) end)
    request("authored_issues", commands.authored_issues, function(raw)
      return recentItems(Data.issues(raw, "author"), activityHistoryDays())
    end, nil, nil, function()
      request("issues", commands.issues, function(raw)
        return recentItems(Data.issues(raw, "assignee"), activityHistoryDays())
      end)
    end)
  end
  request("profile", commands.profile, verifiedProfile, function(_, profile)
    setAccount(profile.login)
    authenticated = true
    if cachedAvatarUrl == profile.avatarUrl and cachedAvatarPath and noctalia.fileExists(cachedAvatarPath) then
      profile.avatarPath = cachedAvatarPath
    end
    publishNow("profile", profile)
    requestDashboard()
  end, false)
  scheduling = false
  finalizeRefresh()
end

noctalia.setUpdateInterval(refreshInterval())
for _, key in ipairs(DATA_KEYS) do
  if dashboard[key] == nil then dashboard[key] = {} end
  noctalia.state.set(key, dashboard[key])
end
dashboard.stale = false
dashboard.status = "idle"
noctalia.state.set("stale", false)
noctalia.state.set("status", "idle")
noctalia.state.set("dashboard", dashboard)
loadCache()
refresh()

function update()
  if inFlight then
    if noctalia.nowMs() < refreshDeadline then return end
    -- Native callback-budget aborts can bypass Lua cleanup. Invalidate every
    -- late reply before releasing the slot; retain the last verified snapshot.
    refreshSerial += 1
    inFlight = false
    noctalia.setUpdateInterval(refreshInterval())
    dashboard.errors.refresh = noctalia.tr("status.request_error")
    dashboard.status, dashboard.stale = "partial", hasCachedData
    noctalia.state.set("error", dashboard.errors.refresh)
    noctalia.state.set("errors", dashboard.errors)
    noctalia.state.set("status", dashboard.status)
    noctalia.state.set("stale", dashboard.stale)
    noctalia.state.set("dashboard", dashboard)
    noctalia.log("Dashboard refresh timed out; retained the last verified snapshot")
    return
  end
  refresh()
end
function onEnable() refresh() end
function onConfigChanged()
  noctalia.setUpdateInterval(inFlight and 1000 or refreshInterval())
  refresh()
end
local function refreshAll()
  noctalia.state.set("notification_action", { type = "refresh", nonce = noctalia.nowMs() })
  refresh()
end
function onIpc(event)
  if event == "refresh" then refreshAll() end
end
noctalia.state.watch("refresh_request", refreshAll)
