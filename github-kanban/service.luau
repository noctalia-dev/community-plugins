-- Read-only dashboard data service. All GitHub access is through `gh` and
-- every request is a direct argv invocation; this service never mutates GitHub.
local GitHub = require("./lib/github.luau")
local Data = require("./lib/data.luau")

local CACHE_FILE = "dashboard.json"
local DATA_KEYS = {
  "profile", "contributions", "notifications", "following_events", "following_repos",
  "following_repo_events", "my_prs", "review_prs", "authored_issues", "issues", "repositories", "actions",
}
local dashboard = { errors = {} }
local cachePath
local inFlight = false
local hasCachedData = false
local followingAvatarPaths = {}
local repositoryAvatarPaths = {}

local function refreshInterval()
  return math.clamp(tonumber(noctalia.getConfig("refresh_interval_minutes")) or 15, 5, 30) * 60 * 1000
end

local function followingHistoryDays()
  return math.clamp(tonumber(noctalia.getConfig("following_history_days")) or 30, 1, 30)
end

local function notificationHistoryDays()
  return math.clamp(tonumber(noctalia.getConfig("notification_history_days")) or 30, 1, 90)
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

local function list() return {} end

local function unreadCount(items)
  local count = 0
  for _, item in ipairs(type(items) == "table" and items or {}) do
    if item.unread == true then count += 1 end
  end
  return count
end

local function publishFollowingAvatar(login, path)
  followingAvatarPaths[login] = path
  local changed = false
  for _, item in ipairs(dashboard.following_events or {}) do
    if item.actor == login then
      item.actorAvatarPath = path
      changed = true
    end
  end
  if changed then publish("following_events", dashboard.following_events) end
end

local function cacheFollowingAvatars(users, index)
  index = index or 1
  if index > #users then return end
  local user = users[index]
  local login = tostring(user.login or "")
  local url = tostring(user.avatarUrl or "")
  local dir = noctalia.pluginDataDir()
  if login == "" or url == "" or not dir then
    cacheFollowingAvatars(users, index + 1)
    return
  end
  local dest = dir .. "/following-avatar-" .. login:gsub("[^%w%-]", "_")
  noctalia.download(url, dest, function(ok)
    if ok then publishFollowingAvatar(login, dest) end
    cacheFollowingAvatars(users, index + 1)
  end)
end

local cachedAvatarUrl = nil
local function avatarDest()
  local dir = noctalia.pluginDataDir()
  return dir and (dir .. "/profile-avatar") or nil
end
local function cacheProfileAvatar(profile)
  local url = tostring(profile and profile.avatarUrl or "")
  local dest = avatarDest()
  if url == "" or not dest then return end
  if url == cachedAvatarUrl and noctalia.fileExists(dest) then return end
  noctalia.download(url, dest, function(ok)
    if not ok or dashboard.profile ~= profile then return end
    local changed = cachedAvatarUrl ~= url or profile.avatarPath ~= dest
    cachedAvatarUrl = url
    profile.avatarPath = dest
    if changed then
      publish("profile", profile)
      persist()
    end
  end)
end

local function publishRepositoryAvatar(fullName, path)
  repositoryAvatarPaths[fullName] = path
  local changed = false
  for _, item in ipairs(dashboard.following_repo_events or {}) do
    if item.repository == fullName then
      item.repositoryOwnerAvatarPath = path
      changed = true
    end
  end
  if changed then publish("following_repo_events", dashboard.following_repo_events) end
end

local function cacheRepositoryAvatars(repositories, index)
  index = index or 1
  if index > #repositories then return end
  local repository = repositories[index]
  local fullName = tostring(repository.fullName or "")
  local url = tostring(repository.ownerAvatarUrl or "")
  local dir = noctalia.pluginDataDir()
  if fullName == "" or url == "" or not dir then
    cacheRepositoryAvatars(repositories, index + 1)
    return
  end
  local owner = tostring(repository.ownerLogin or fullName:match("^([^/]+)") or "owner")
  local dest = dir .. "/repository-owner-avatar-" .. owner:gsub("[^%w%-]", "_")
  noctalia.download(url, dest, function(ok)
    if ok then publishRepositoryAvatar(fullName, dest) end
    cacheRepositoryAvatars(repositories, index + 1)
  end)
end

persist = function()
  if not cachePath then return end
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
  if type(cached) ~= "table" then return end
  for _, key in ipairs(DATA_KEYS) do
    if cached[key] ~= nil then
      dashboard[key] = cached[key]
      noctalia.state.set(key, cached[key])
    end
  end
  hasCachedData = true
  dashboard.errors = {}
  dashboard.notifications_count = unreadCount(dashboard.notifications)
  if type(cached.last_update) == "number" then dashboard.last_update = cached.last_update end
  dashboard.stale = true
  dashboard.status = "stale"
  noctalia.state.set("dashboard", dashboard)
  noctalia.state.set("notifications_count", dashboard.notifications_count)
  noctalia.state.set("last_update", dashboard.last_update or "")
  noctalia.state.set("stale", true)
  noctalia.state.set("status", "stale")
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
  dashboard.status = "loading"
  dashboard.stale = true
  dashboard.errors = {}
  noctalia.state.set("status", "loading")
  noctalia.state.set("stale", true)
  noctalia.state.set("errors", dashboard.errors)

  local pending = 0
  local scheduling = true
  local function finalizeRefresh()
    if scheduling or pending ~= 0 then return end
    inFlight = false
    dashboard.status = dashboard.errors.auth and "auth_error" or (next(dashboard.errors) and "partial" or "ready")
    dashboard.stale = dashboard.status ~= "ready" and hasCachedData
    local errorText = dashboard.errors.auth or (dashboard.status == "partial" and noctalia.tr("status.request_error") or "")
    noctalia.state.set("error", errorText)
    dashboard.last_update = os.time()
    noctalia.state.set("last_update", dashboard.last_update)
    noctalia.state.set("status", dashboard.status)
    noctalia.state.set("stale", dashboard.stale)
    noctalia.state.set("errors", dashboard.errors)
    noctalia.state.set("dashboard", dashboard)
    persist()
  end
  local function finishOne()
    pending -= 1
    finalizeRefresh()
  end

  local function request(key, argv, normalize, after, publishResult, complete)
    pending += 1
    local started = noctalia.runAsync(argv, function(result)
      local succeeded = false
      local decoded, err = decode(result)
      if decoded == nil then
        dashboard.errors[key] = err
        local lower = string.lower(err)
        if lower:find("auth", 1, true) or lower:find("token", 1, true) or lower:find("401", 1, true) then
          dashboard.status = "auth_error"
          dashboard.errors.auth = noctalia.tr("status.auth_error")
          noctalia.state.set("error", dashboard.errors.auth)
        end
        noctalia.state.set("errors", dashboard.errors)
      else
        local value = normalize(decoded)
        if value == nil then
          dashboard.errors[key] = noctalia.tr("status.unexpected_data")
          noctalia.state.set("errors", dashboard.errors)
        else
          dashboard.errors[key] = nil
          hasCachedData = true
          succeeded = true
          if publishResult ~= false then publish(key, value) end
          if after then
            after(decoded, value)
          end
        end
      end
      if complete then complete(succeeded) end
      finishOne()
    end)
    if not started then
      dashboard.errors[key] = noctalia.tr("status.cli_start_failed")
      if complete then complete(false) end
      finishOne()
    end
  end

  local commands = GitHub.commands()
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

  request("profile", commands.profile, function(raw)
    local value = Data.profile(raw)
    if value then
      local dest = avatarDest()
      if dest and noctalia.fileExists(dest) then value.avatarPath = dest end
    end
    return value
  end, function(_, profile)
    dashboard.login = profile.login
    noctalia.state.set("login", profile.login)
    noctalia.state.set("dashboard", dashboard)
    cacheProfileAvatar(profile)
  end)
  request("contributions", commands.contributions, Data.contributions)
  request("notifications", commands.notifications, function(raw)
    return recentItems(Data.notifications(raw), notificationHistoryDays())
  end, function(_, items)
    local unread = unreadCount(items)
    dashboard.notifications_count = unread
    noctalia.state.set("notifications_count", unread)
  end, nil, requestRepositories)
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
    cacheFollowingAvatars(selectedUsers)
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
    for _, event in ipairs(feed.events) do event.repositoryOwnerAvatarPath = repositoryAvatarPaths[event.repository] end
    publish("following_repos", feed.repositories)
    publish("following_repo_events", feed.events)
    cacheRepositoryAvatars(feed.repositories)
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
      table.sort(events, function(a, b) return a.createdAt > b.createdAt end)
      while #events > Data.RELEASE_FEED_LIMIT do table.remove(events) end
      local selected, byName = {}, {}
      for _, repository in ipairs(repositories) do byName[repository.fullName] = repository end
      for _, event in ipairs(events) do selected[#selected + 1] = byName[event.repository] end
      publishReleaseFeed({ repositories = selected, events = events })
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
  for _, key in ipairs({ "notifications", "following_events", "following_repo_events", "my_prs", "review_prs", "authored_issues", "issues", "repositories", "following_repos" }) do
    if dashboard[key] == nil then publish(key, list()) end
  end
  scheduling = false
  finalizeRefresh()
end

noctalia.setUpdateInterval(refreshInterval())
for _, key in ipairs(DATA_KEYS) do
  if dashboard[key] == nil then dashboard[key] = {} end
  noctalia.state.set(key, dashboard[key])
end
dashboard.notifications_count = 0
dashboard.stale = false
dashboard.status = "idle"
noctalia.state.set("notifications_count", 0)
noctalia.state.set("stale", false)
noctalia.state.set("status", "idle")
noctalia.state.set("dashboard", dashboard)
loadCache()
refresh()

function update() refresh() end
function onEnable() refresh() end
function onConfigChanged()
  noctalia.setUpdateInterval(refreshInterval())
  refresh()
end
function onIpc(event)
  if event == "refresh" then refresh() end
end
noctalia.state.watch("refresh_request", function() refresh() end)
