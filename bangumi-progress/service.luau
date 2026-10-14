--!nonstrict
-- Bangumi Progress service: PAT/browser authentication, v0 API access, and progress updates.
-- The desktop widget, bar widget, and panel communicate only through noctalia.state and never access the network directly.

local API_BASE = "https://api.bgm.tv"
local USER_AGENT = "noctalia-bangumi-progress/1.2.0 (https://github.com/noctalia-dev/community-plugins)"
local SUBJECT_TYPE_ANIME = 2
local PAGE_LIMIT = 50
local COVER_DIR = "covers"
local BADGE_BASELINES_FILE = "badge-baselines.json"
local CACHE_FILE = "cache.json"
local CACHE_VERSION = 2
local CALENDAR_FILE = "calendar.json"
local CALENDAR_VERSION = 1
local CALENDAR_TIMEOUT_MS = 60000
local MAX_CONCURRENT_COVERS = 2
local MIN_IDLE_MS = 30000
local PROFILE_DIR = "profiles"
local PROFILE_TIMEOUT_MS = 60000
local BAR_COUNT_TIMEOUT_MS = 60000
local BAR_RETRY_MS = 60000

-- Collection types: 1 Wish, 2 Completed, 3 Watching, 4 On Hold, 5 Dropped.
local TYPE_WISH = 1
local TYPE_DONE = 2
local TYPE_WATCHING = 3
local TYPE_ON_HOLD = 4
local TYPE_DROPPED = 5
local ALL_TYPES = { TYPE_WISH, TYPE_DONE, TYPE_WATCHING, TYPE_ON_HOLD, TYPE_DROPPED }

local function emptyCalendarDays()
  local days = {}
  for weekday = 1, 7 do
    table.insert(days, { weekday = weekday, rows = {} })
  end
  return days
end

local snapshot = {
  revision = 0,
  loading = false,
  refreshing = false,
  busy = false,
  error = "",
  viewer = nil,
  authMode = "none", -- "token" | "public" | "none"
  authSource = "none", -- "pat" | "oauth" | "public" | "none"; credentials never enter state.
  oauthAvailable = false,
  oauthBusy = false,
  oauthOperation = "",
  oauthError = "",
  collections = {},
  barCounts = {}, -- type string -> lightweight total; never marks a collection loaded
  calendar = { loaded = false, loading = false, error = "", fetchedAt = 0, days = emptyCalendarDays() },
}
for _, t in ipairs(ALL_TYPES) do
  table.insert(snapshot.collections, { type = t, loaded = false, total = 0, rows = {} })
end

local accessToken = ""
local username = ""
local refreshMs = 30 * 60000
local fetchInFlight = {} -- type -> true
local collectionRefreshActive = false -- Covers the whole multi-category refresh chain.
local coversInFlight = {} -- subjectId -> true
local failedCoverUrls = {} -- subjectId -> { url, at }; short cooldown after failed downloads
local coverQueue = {}     -- rows waiting for a download slot
local activeCoverDownloads = 0
local pendingCoverCollections = false
local pendingCoverCalendar = false
local coverPersistDueAt = 0
local COVER_PERSIST_INTERVAL_MS = 1000
local lastAutoRefreshAt = 0
local sessionGeneration = 0
local persistCache
local pendingEpisodePersistence = false
local pendingUnwatchedUpdate = false
local pendingBadgePersistence = false
local flushBadgePersistence
local episodePersistDueAt = 0
local EPISODE_PERSIST_INTERVAL_MS = 1000
local authReady = false
local oauthExpiresAt = 0
local oauthRetryAt = 0
local oauthGeneration = 0
local oauthStartedAt = 0
local oauthAttempt = ""
local oauthCounter = 0
local startOAuth
local cancelOAuth
local logoutOAuth
local refreshOAuth
local syncInterval
local calendarGeneration = 0
local calendarInFlight = false
local calendarStartedAt = 0
local calendarAttemptedAt = 0
local barCountRequests = {}
local lastBarWatchingAttemptAt = 0
local loadBarData
local profileState = { key = "", fetchedAt = 0, attemptedAt = 0, result = nil, inFlight = false, startedAt = 0, avatarInFlight = nil, avatarAttemptedAt = 0, avatarAttemptedUrl = nil, requestGeneration = 0 }

local function trim(value)
  return noctalia.string.trim(tostring(value or ""))
end

local function fresh(fetchedAt)
  local at = tonumber(fetchedAt) or 0
  local now = os.time()
  return at > 0 and now >= at and (now - at) * 1000 < refreshMs
end

local function tokenFingerprint(token)
  -- DJB2 uses 5381 as the seed and 33 as the multiplier; 2^32 keeps
  -- the accumulator in the 32-bit range. This is not cryptographic.
  local hash = 5381
  for index = 1, #token do
    local byte = string.byte(token, index)
    hash = (hash * 33 + byte) % 4294967296
  end
  return tostring(#token) .. ":" .. string.format("%08x", hash)
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local snapshotPublicationDepth = 0
local function publishSnapshot()
  -- OAuth completion can restore collections, covers and badge data in one
  -- callback. Serialize that large snapshot once after the callback settles.
  if snapshotPublicationDepth > 0 then return end
  snapshot.oauthReadOnly = snapshot.authSource == "oauth"
    and (not authReady or accessToken == "" or os.time() >= oauthExpiresAt)
  snapshot.canWrite = authReady and snapshot.authMode == "token" and accessToken ~= ""
    and not snapshot.oauthBusy and not snapshot.oauthReadOnly
  snapshot.oauthCanRetry = snapshot.authSource == "oauth" and not snapshot.oauthBusy
    and oauthRetryAt ~= math.huge
  snapshot.revision += 1
  noctalia.state.set("bgm_snapshot", snapshot)
end

local function setError(message)
  snapshot.error = message or ""
  snapshot.loading = false
  snapshot.refreshing = false
  publishSnapshot()
end

local function collectionOf(type)
  for _, c in ipairs(snapshot.collections) do
    if c.type == type then
      return c
    end
  end
  return nil
end

-- Rebuild on list replacement; download completions then touch only matching rows.
local collectionRowsBySubject = {}
local calendarRowsBySubject = {}
local function rebuildCollectionIndex()
  collectionRowsBySubject = {}
  for _, collection in ipairs(snapshot.collections) do
    for _, row in ipairs(collection.rows) do
      if row.subjectId ~= nil then
        local rows = collectionRowsBySubject[row.subjectId] or {}
        table.insert(rows, row)
        collectionRowsBySubject[row.subjectId] = rows
      end
    end
  end
end
local function rebuildCalendarIndex()
  calendarRowsBySubject = {}
  for _, day in ipairs(snapshot.calendar.days) do
    for _, row in ipairs(day.rows) do
      calendarRowsBySubject[row.subjectId] = row
    end
  end
end

local function rememberCollectionTotal(collection, error)
  local key = tostring(collection.type)
  local count = snapshot.barCounts[key] or { fetchedAt = 0 }
  local request = barCountRequests[key]
  if request then
    request.generation += 1
    request.inFlight = false
  end
  count.loading = false
  count.error = error or ""
  if error and collection.type == TYPE_WATCHING then lastBarWatchingAttemptAt = noctalia.nowMs() end
  if collection.loaded and (not error or count.total == nil) then
    count.total = collection.total
    count.fetchedAt = collection.fetchedAt
  end
  snapshot.barCounts[key] = count
end

-- /calendar is a public weekday reference, including long-running titles and
-- future premieres. Its date is a subject's premiere date, not an episode time.
local function positiveInteger(value)
  return type(value) == "number" and value > 0 and value < math.huge and value % 1 == 0
end

local function calendarDate(value)
  if type(value) ~= "string" then return nil end
  local year, month, day = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  year, month, day = tonumber(year), tonumber(month), tonumber(day)
  if not year or year < 1 or not month or month < 1 or month > 12 or not day then return nil end
  local lengths = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if year % 400 == 0 or (year % 4 == 0 and year % 100 ~= 0) then lengths[2] = 29 end
  return if day >= 1 and day <= lengths[month] then value else nil
end

local function calendarCoverUrl(value)
  return if type(value) == "string" and value:match("^https?://") then value else nil
end

local function existingDisplayCover(subjectId)
  local dir = noctalia.pluginDataDir()
  if not dir then return nil end
  -- This lookup is synchronous and never consumes a download slot.
  for _, extension in ipairs({ "jpg", "png", "webp" }) do
    local path = dir .. "/" .. COVER_DIR .. "/" .. tostring(subjectId) .. "-display." .. extension
    if noctalia.fileExists(path) then return path end
  end
  return nil
end

local function existingCalendarCover(subjectId)
  local display = existingDisplayCover(subjectId)
  if display then return display end
  local dir = noctalia.pluginDataDir()
  if not dir then return nil end
  for _, extension in ipairs({ "jpg", "png", "webp", "jpeg" }) do
    local path = dir .. "/" .. COVER_DIR .. "/" .. tostring(subjectId) .. "." .. extension
    if noctalia.fileExists(path) then return path end
  end
  return nil
end

local function calendarTitle(name, nameCn, subjectId)
  return if nameCn ~= "" then nameCn elseif name ~= "" then name else "#" .. tostring(subjectId)
end

local function calendarText(value)
  return if type(value) == "string" then trim(value) else ""
end

local function calendarArray(value)
  if type(value) ~= "table" then return false end
  local length = #value
  for key in pairs(value) do
    if not positiveInteger(key) or key > length then return false end
  end
  for index = 1, length do
    if value[index] == nil then return false end
  end
  return true
end

local function normalizeCalendar(parsed)
  if not calendarArray(parsed) or #parsed == 0 then return nil end
  local days, seen = emptyCalendarDays(), {}
  local seenWeekdays = {}
  for _, group in ipairs(parsed) do
    local weekday = type(group) == "table" and type(group.weekday) == "table" and group.weekday.id or nil
    -- A partial malformed response must not erase a previously populated day.
    if not positiveInteger(weekday) or weekday > 7 or seenWeekdays[weekday]
      or not calendarArray(group.items) then return nil end
    seenWeekdays[weekday] = true
    for _, item in ipairs(group.items) do
      if type(item) == "table" and item.type == SUBJECT_TYPE_ANIME and positiveInteger(item.id) and not seen[item.id] then
        seen[item.id] = true
        local name, nameCn = calendarText(item.name), calendarText(item.name_cn)
        local images = type(item.images) == "table" and item.images or {}
        table.insert(days[weekday].rows, {
          subjectId = item.id, title = calendarTitle(name, nameCn, item.id),
          name = name, nameCn = nameCn, airDate = calendarDate(item.air_date),
          coverUrl = calendarCoverUrl(images.medium) or calendarCoverUrl(images.large)
            or calendarCoverUrl(images.common) or calendarCoverUrl(images.grid),
          coverPath = existingCalendarCover(item.id),
        })
      end
    end
  end
  return days
end

local function loadCalendarCache()
  local dir = noctalia.pluginDataDir()
  if not dir then return end
  local contents = noctalia.readFile(dir .. "/" .. CALENDAR_FILE)
  if not contents or contents == "" then return end
  local ok, parsed = pcall(noctalia.json.decode, contents)
  if not ok or type(parsed) ~= "table" or parsed.version ~= CALENDAR_VERSION
    or not positiveInteger(parsed.fetchedAt) or parsed.fetchedAt > os.time()
    or not calendarArray(parsed.days) or #parsed.days ~= 7 then return end
  local days, seen = emptyCalendarDays(), {}
  for weekday = 1, 7 do
    local day = parsed.days[weekday]
    if type(day) ~= "table" or day.weekday ~= weekday or not calendarArray(day.rows) then return end
    for _, row in ipairs(day.rows) do
      if type(row) ~= "table" or not positiveInteger(row.subjectId) or seen[row.subjectId]
        or type(row.title) ~= "string" or trim(row.title) == ""
        or (row.airDate ~= nil and calendarDate(row.airDate) == nil) then return end
      seen[row.subjectId] = true
      table.insert(days[weekday].rows, {
        subjectId = row.subjectId, title = row.title,
        name = calendarText(row.name), nameCn = calendarText(row.nameCn), airDate = row.airDate,
        coverUrl = calendarCoverUrl(row.coverUrl), coverPath = existingCalendarCover(row.subjectId),
      })
    end
  end
  snapshot.calendar.loaded = true
  snapshot.calendar.days = days
  rebuildCalendarIndex()
  snapshot.calendar.fetchedAt = parsed.fetchedAt
end

local function persistCalendar()
  local dir = noctalia.pluginDataDir()
  if dir then
    noctalia.writeFile(dir .. "/" .. CALENDAR_FILE, noctalia.json.encode({
      version = CALENDAR_VERSION, fetchedAt = snapshot.calendar.fetchedAt, days = snapshot.calendar.days,
    }))
  end
end

local function cancelCalendar()
  calendarGeneration += 1
  calendarInFlight = false
  calendarStartedAt = 0
  snapshot.calendar.loading = false
end

local function loadCalendar(force)
  local calendar = snapshot.calendar
  if calendarInFlight then return end
  if not force and calendar.loaded and calendar.error == ""
    and os.time() >= calendar.fetchedAt and (os.time() - calendar.fetchedAt) * 1000 < refreshMs then return end
  if not force and calendar.error ~= "" and calendarAttemptedAt > 0
    and noctalia.nowMs() - calendarAttemptedAt < BAR_RETRY_MS then return end
  calendarGeneration += 1
  local generation = calendarGeneration
  calendarInFlight = true
  calendarStartedAt = noctalia.nowMs()
  calendarAttemptedAt = calendarStartedAt
  calendar.loading = true
  calendar.error = ""
  syncInterval()
  publishSnapshot()
  local function finish(error, days)
    if generation ~= calendarGeneration or not calendarInFlight then return end
    calendarInFlight = false
    calendarStartedAt = 0
    calendar.loading = false
    calendar.error = error or ""
    if error then calendarAttemptedAt = noctalia.nowMs() end
    if days then
      calendar.loaded = true
      calendar.days = days
      rebuildCalendarIndex()
      calendar.fetchedAt = os.time()
      persistCalendar()
    end
    syncInterval()
    publishSnapshot()
  end
  -- Explicit public headers: never pass a PAT or browser token to this endpoint.
  local accepted = noctalia.http({
    url = API_BASE .. "/calendar", method = "GET",
    headers = { "Accept: application/json", "User-Agent: " .. USER_AGENT },
  }, function(resp)
    if generation ~= calendarGeneration or not calendarInFlight then return end
    if resp.ok ~= true then finish("network"); return end
    if resp.status ~= 200 then finish("http_" .. tostring(resp.status or 0)); return end
    local ok, parsed = pcall(noctalia.json.decode, resp.body or "")
    local days = if ok then normalizeCalendar(parsed) else nil
    if not days then finish("parse"); return end
    finish(nil, days)
  end)
  if not accepted then finish("network") end
end

local function resolveAuth()
  accessToken = trim(noctalia.getConfig("access_token") or "")
  username = trim(noctalia.getConfig("username") or "")
  if accessToken ~= "" then
    snapshot.authSource = "pat"
    return "token"
  end
  if username ~= "" then
    snapshot.authSource = "public"
    return "public"
  end
  snapshot.authSource = "none"
  return "none"
end

local function oauthExpired()
  return snapshot.authSource == "oauth" and (accessToken == "" or os.time() >= oauthExpiresAt)
end

local function collectionsPath()
  -- With a personal access token, the /v0/users/-/collections read path returns
  -- 404 "user doesn't exist". Reads require an explicit username; PATCH writes do not.
  if username ~= "" then
    return "/v0/users/" .. noctalia.string.urlEncode(username) .. "/collections"
  end
  return "/v0/users/-/collections"
end

local function defaultHeaders(extra)
  local headers = {
    "Accept: application/json",
    "User-Agent: " .. USER_AGENT,
  }
  if accessToken ~= "" then
    table.insert(headers, "Authorization: Bearer " .. accessToken)
  end
  if type(extra) == "table" then
    for _, h in ipairs(extra) do
      table.insert(headers, h)
    end
  end
  return headers
end

-- onDone(ok, status, body)
local function apiGet(path, query, onDone)
  if not authReady or oauthExpired() then
    onDone(true, 401, "")
    return
  end
  local url = API_BASE .. path
  if query and query ~= "" then
    url = url .. "?" .. query
  end
  local accepted = noctalia.http({
    url = url,
    method = "GET",
    headers = defaultHeaders(),
  }, function(resp)
    onDone(resp.ok == true, resp.status or 0, resp.body or "")
  end)
  if not accepted then
    onDone(false, 0, "")
  end
end

-- Profile reads are panel-triggered and independent of collection/authentication
-- success. Public data never replaces the identity validated by /v0/me/OAuth.
local function profileEnabled(key)
  return noctalia.getConfig(key) == true
end

local function profileUrl(value)
  return if type(value) == "string" and value:match("^https://") then value else nil
end

local function profileKey(viewer)
  if not viewer then return "" end
  if snapshot.authMode == "token" then
    return if positiveInteger(tonumber(viewer.id)) then "user-" .. tostring(viewer.id) else ""
  end
  return if username ~= "" then "public-" .. tokenFingerprint(username):gsub(":", "-") else ""
end

local function profileDirectory()
  local dir = noctalia.pluginDataDir()
  if not dir then return nil end
  local path = dir .. "/" .. PROFILE_DIR
  if not noctalia.fileExists(path) then noctalia.mkdirAll(path) end
  return path
end

local function profileAvatarPath(key, url)
  local dir = noctalia.pluginDataDir()
  if not dir or not url then return nil end
  local extension = (url:match("%.(%w+)[?]?") or "jpg"):lower()
  if extension == "jpeg" then extension = "jpg" end
  if extension ~= "jpg" and extension ~= "png" and extension ~= "webp" then extension = "jpg" end
  return dir .. "/" .. PROFILE_DIR .. "/" .. key .. "-" .. tokenFingerprint(url):gsub(":", "-") .. "." .. extension
end

local function applyProfile(viewer)
  viewer.bio = ""
  viewer.avatarUrl = nil
  viewer.avatarPath = nil
  local result = profileState.result
  if not result then return end
  viewer.bio = result.bio or ""
  viewer.avatarUrl = result.avatarUrl
  local path = profileAvatarPath(profileState.key, result.avatarUrl)
  if path and noctalia.fileExists(path) then
    viewer.avatarPath = path
  else
    local fallback = profileAvatarPath(profileState.key, result.avatarFallbackUrl)
    if fallback and noctalia.fileExists(fallback) then viewer.avatarPath = fallback end
  end
  if snapshot.authMode == "public" then
    viewer.id = result.id
    viewer.nickname = if result.nickname ~= "" then result.nickname else viewer.nickname
  end
end

local function restoreProfile(viewer)
  local key = profileKey(viewer)
  if key ~= profileState.key then
    profileState = { key = key, fetchedAt = 0, attemptedAt = 0, result = nil, inFlight = false, startedAt = 0, avatarInFlight = nil, avatarAttemptedAt = 0, avatarAttemptedUrl = nil, requestGeneration = 0 }
    local dir = noctalia.pluginDataDir()
    local contents = dir and key ~= "" and noctalia.readFile(dir .. "/" .. PROFILE_DIR .. "/" .. key .. ".json")
    if contents then
      local ok, saved = pcall(noctalia.json.decode, contents)
      if ok and type(saved) == "table" and saved.version == 1 and saved.key == key
        and type(saved.result) == "table" and positiveInteger(saved.result.id)
        and (snapshot.authMode ~= "token" or saved.result.id == tonumber(viewer.id))
        and saved.result.username == viewer.username and type(saved.result.bio) == "string"
        and type(saved.result.nickname) == "string" then
        profileState.result = {
          id = saved.result.id, username = saved.result.username, nickname = saved.result.nickname,
          bio = saved.result.bio, bioKnown = saved.result.bioKnown == true,
          avatarUrl = profileUrl(saved.result.avatarUrl), avatarKnown = saved.result.avatarKnown == true,
          avatarFallbackUrl = profileUrl(saved.result.avatarFallbackUrl),
        }
        profileState.fetchedAt = tonumber(saved.fetchedAt) or 0
      end
    end
  end
  applyProfile(viewer)
end

local function persistProfile()
  local dir = profileDirectory()
  if dir and profileState.result then
    noctalia.writeFile(dir .. "/" .. profileState.key .. ".json", noctalia.json.encode({
      version = 1, key = profileState.key, fetchedAt = profileState.fetchedAt, result = profileState.result,
    }))
  end
end

local function downloadProfileAvatar()
  local viewer = snapshot.viewer
  if not viewer or not profileEnabled("show_profile_avatar") or not viewer.avatarUrl
    or (viewer.avatarPath == profileAvatarPath(profileState.key, viewer.avatarUrl)) or profileState.avatarInFlight
    or (profileState.avatarAttemptedUrl == viewer.avatarUrl and fresh(profileState.avatarAttemptedAt)) then return end
  local dir = profileDirectory()
  local path = profileAvatarPath(profileState.key, viewer.avatarUrl)
  if not dir or not path then return end
  local generation, key, url = sessionGeneration, profileState.key, viewer.avatarUrl
  profileState.avatarInFlight = url
  profileState.avatarAttemptedUrl = url
  profileState.avatarAttemptedAt = os.time()
  local accepted = noctalia.download(url, path, function(ok)
    if generation ~= sessionGeneration or key ~= profileState.key or profileState.avatarInFlight ~= url then return end
    profileState.avatarInFlight = nil
    if ok and snapshot.viewer and snapshot.viewer.avatarUrl == url then
      snapshot.viewer.avatarPath = path
      profileState.result.avatarFallbackUrl = nil
      persistProfile()
      publishSnapshot()
    end
  end)
  if not accepted then profileState.avatarInFlight = nil end
end

local function updateProfileData(parsed, viewer)
  local avatar = type(parsed.avatar) == "table" and parsed.avatar or {}
  local previous = profileState.result or {}
  local url = profileUrl(avatar.medium) or profileUrl(avatar.large) or profileUrl(avatar.small) or previous.avatarUrl
  local fallback = previous.avatarFallbackUrl
  if previous.avatarUrl and url ~= previous.avatarUrl then
    local previousPath = profileAvatarPath(profileState.key, previous.avatarUrl)
    if previousPath and noctalia.fileExists(previousPath) then fallback = previous.avatarUrl end
  end
  profileState.result = {
    id = parsed.id, username = viewer.username,
    nickname = if type(parsed.nickname) == "string" then parsed.nickname else previous.nickname or viewer.nickname or viewer.username,
    bio = if type(parsed.sign) == "string" then parsed.sign else previous.bio or "",
    bioKnown = type(parsed.sign) == "string" or previous.bioKnown == true,
    avatarUrl = url, avatarKnown = type(parsed.avatar) == "table" or previous.avatarKnown == true,
    avatarFallbackUrl = fallback,
  }
  profileState.fetchedAt = os.time()
  applyProfile(viewer)
  persistProfile()
end

local function loadProfile()
  local viewer = snapshot.viewer
  if not authReady or not viewer or (not profileEnabled("show_profile_avatar")
    and not profileEnabled("show_profile_bio") and not profileEnabled("show_profile_identity")) then return end
  restoreProfile(viewer)
  -- Authenticated identity (or a cached public ID) needs no supplemental read
  -- when both optional profile content fields are hidden.
  if not profileEnabled("show_profile_avatar") and not profileEnabled("show_profile_bio")
    and positiveInteger(tonumber(viewer.id)) then return end
  downloadProfileAvatar()
  local result = profileState.result
  local complete = result and (not profileEnabled("show_profile_bio") or result.bioKnown)
    and (not profileEnabled("show_profile_avatar") or result.avatarKnown)
  if profileState.key == "" or profileState.inFlight or fresh(profileState.attemptedAt)
    or (complete and fresh(profileState.fetchedAt)) then return end
  local generation, key = sessionGeneration, profileState.key
  local expectedId, expectedUsername = tonumber(viewer.id), viewer.username
  profileState.requestGeneration += 1
  local requestGeneration = profileState.requestGeneration
  profileState.inFlight = true
  profileState.startedAt = noctalia.nowMs()
  profileState.attemptedAt = os.time()
  local function finish()
    profileState.inFlight = false
    profileState.startedAt = 0
  end
  -- Never send credentials to the public profile endpoint or avatar CDN.
  local accepted = noctalia.http({
    url = API_BASE .. "/v0/users/" .. noctalia.string.urlEncode(expectedUsername), method = "GET",
    headers = { "Accept: application/json", "User-Agent: " .. USER_AGENT },
  }, function(resp)
    if generation ~= sessionGeneration or key ~= profileState.key
      or requestGeneration ~= profileState.requestGeneration or not profileState.inFlight then return end
    finish()
    if resp.ok ~= true or resp.status ~= 200 then return end
    local ok, parsed = pcall(noctalia.json.decode, resp.body or "")
    if not ok or type(parsed) ~= "table" or not positiveInteger(parsed.id)
      or parsed.username ~= expectedUsername
      or (snapshot.authMode == "token" and parsed.id ~= expectedId) then return end
    updateProfileData(parsed, snapshot.viewer)
    downloadProfileAvatar()
    publishSnapshot()
  end)
  if not accepted then finish() end
  syncInterval()
end

local function normalizeRow(item)
  local subject = type(item.subject) == "table" and item.subject or {}
  local name = tostring(subject.name or "")
  local nameCn = tostring(subject.name_cn or "")
  local title = nameCn
  if title == "" then
    title = name
  end
  if title == "" then
    title = "#" .. tostring(item.subject_id or "?")
  end
  local images = type(subject.images) == "table" and subject.images or {}
  local coverUrl = images.medium or images.large or images.common or images.grid or nil
  return {
    subjectId = tonumber(item.subject_id) or 0,
    type = tonumber(item.type) or TYPE_WATCHING,
    epStatus = tonumber(item.ep_status) or 0,
    volStatus = tonumber(item.vol_status) or 0,
    rate = tonumber(item.rate) or 0,
    comment = item.comment,
    private = item.private == true,
    updatedAt = item.updated_at,
    title = title,
    name = name,
    nameCn = nameCn,
    date = subject.date,
    eps = tonumber(subject.eps) or 0,
    volumes = tonumber(subject.volumes) or 0,
    score = subject.score,
    coverUrl = coverUrl,
    coverPath = existingDisplayCover(tonumber(item.subject_id) or 0),
  }
end

-- Fetch one collection type, paging through the API, then cb({rows=..., total=...})
-- or cb({error = "unauthorized" | "network" | "http_<status>" | "parse"}).
local function fetchCollectionType(collectionType, cb)
  local key = tostring(collectionType)
  local generation = sessionGeneration
  if fetchInFlight[key] then
    return
  end
  fetchInFlight[key] = true
  local rows = {}
  local offset = 0
  local total = nil

  local function nextPage()
    local query = "subject_type=" .. SUBJECT_TYPE_ANIME
      .. "&type=" .. collectionType
      .. "&limit=" .. PAGE_LIMIT
      .. "&offset=" .. offset
    apiGet(collectionsPath(), query, function(ok, status, body)
      if generation ~= sessionGeneration then
        return
      end
      if not ok then
        fetchInFlight[key] = nil
        cb({ error = "network" })
        return
      end
      if status == 401 or status == 403 then
        fetchInFlight[key] = nil
        cb({ error = if status == 403 then "forbidden" else "unauthorized" })
        return
      end
      if status ~= 200 then
        fetchInFlight[key] = nil
        cb({ error = "http_" .. tostring(status) })
        return
      end
      local parsedOk, parsed = pcall(noctalia.json.decode, body)
      if not parsedOk or type(parsed) ~= "table" then
        fetchInFlight[key] = nil
        cb({ error = "parse" })
        return
      end
      local page = parsed.data
      if type(page) ~= "table" then
        fetchInFlight[key] = nil
        cb({ error = "parse" })
        return
      end
      for _, item in ipairs(page) do
        if type(item) == "table" then
          table.insert(rows, normalizeRow(item))
        end
      end
      total = tonumber(parsed.total) or #rows
      offset += #page
      if offset < total and #page > 0 then
        nextPage()
      else
        fetchInFlight[key] = nil
        cb({ rows = rows, total = total })
      end
    end)
  end

  nextPage()
end

local function coverDir()
  local dir = noctalia.pluginDataDir()
  if not dir then
    return nil
  end
  local path = dir .. "/" .. COVER_DIR
  if not noctalia.fileExists(path) then
    noctalia.mkdirAll(path)
  end
  return path
end

-- Downloads can outlive the row that requested them. Resolve the current rows
-- by subject ID so a calendar/collection refresh cannot lose the local path.
local function applyCoverPath(subjectId, path)
  local collectionsChanged, calendarChanged = false, false
  for _, row in ipairs(collectionRowsBySubject[subjectId] or {}) do
    if row.coverPath ~= path then
      row.coverPath = path
      collectionsChanged = true
    end
  end
  local row = calendarRowsBySubject[subjectId]
  if row and row.coverPath ~= path then
    row.coverPath = path
    calendarChanged = true
  end
  return collectionsChanged, calendarChanged
end

local function flushCoverPersistence()
  if not pendingCoverCollections and not pendingCoverCalendar then return end
  if pendingCoverCollections then persistCache() end
  if pendingCoverCalendar then persistCalendar() end
  pendingCoverCollections = false
  pendingCoverCalendar = false
  coverPersistDueAt = 0
  syncInterval()
end

local function scheduleCoverPersistence(collectionsChanged, calendarChanged)
  if not collectionsChanged and not calendarChanged then return end
  pendingCoverCollections = pendingCoverCollections or collectionsChanged
  pendingCoverCalendar = pendingCoverCalendar or calendarChanged
  -- Keep a fixed deadline from the first change: sustained downloads must not
  -- postpone persistence indefinitely. Flush immediately when the queue drains.
  if coverPersistDueAt == 0 then coverPersistDueAt = noctalia.nowMs() + COVER_PERSIST_INTERVAL_MS end
  syncInterval()
end

local function processCoverQueue()
  local cachedCollectionsChanged, cachedCalendarChanged = false, false
  while activeCoverDownloads < MAX_CONCURRENT_COVERS and #coverQueue > 0 do
    local row = table.remove(coverQueue, 1)
    if row and not row.coverPath and row.coverUrl then
      activeCoverDownloads += 1
      local dir = coverDir()
      if not dir then
        activeCoverDownloads -= 1
        coversInFlight[row.subjectId] = nil
        failedCoverUrls[row.subjectId] = { url = row.coverUrl, at = os.time() }
        continue
      end
      local ext = (row.coverUrl:match("%.(%w+)$") or "jpg"):lower()
      if ext == "jpeg" then
        ext = "jpg"
      end
      if ext ~= "jpg" and ext ~= "png" and ext ~= "webp" then ext = "jpg" end
      -- A fixed display filename upgrades legacy grid thumbnails once, without
      -- creating a new file on every refresh or OAuth token rotation.
      local path = dir .. "/" .. tostring(row.subjectId) .. "-display." .. ext
      coversInFlight[row.subjectId] = true
      local generation = sessionGeneration
      if noctalia.fileExists(path) then
        local collectionsChanged, calendarChanged = applyCoverPath(row.subjectId, path)
        cachedCollectionsChanged = cachedCollectionsChanged or collectionsChanged
        cachedCalendarChanged = cachedCalendarChanged or calendarChanged
        row.coverPath = path
        coversInFlight[row.subjectId] = nil
        activeCoverDownloads -= 1
      else
        local accepted = noctalia.download(row.coverUrl, path, function(downloadOk)
          if generation ~= sessionGeneration then
            return
          end
          activeCoverDownloads -= 1
          coversInFlight[row.subjectId] = nil
          if downloadOk then
            failedCoverUrls[row.subjectId] = nil
            local collectionsChanged, calendarChanged = applyCoverPath(row.subjectId, path)
            row.coverPath = path
            scheduleCoverPersistence(collectionsChanged, calendarChanged)
            if collectionsChanged or calendarChanged then publishSnapshot() end
          else
            failedCoverUrls[row.subjectId] = { url = row.coverUrl, at = os.time() }
          end
          processCoverQueue()
        end)
        if not accepted then
          activeCoverDownloads -= 1
          coversInFlight[row.subjectId] = nil
          failedCoverUrls[row.subjectId] = { url = row.coverUrl, at = os.time() }
        end
      end
    elseif row then
      coversInFlight[row.subjectId] = nil
    end
  end
  -- Cached files are resolved synchronously. Publishing once per hit can cause
  -- a burst of full UI rebuilds before the host completes its first layout.
  scheduleCoverPersistence(cachedCollectionsChanged, cachedCalendarChanged)
  if cachedCollectionsChanged or cachedCalendarChanged then
    publishSnapshot()
  end
  if activeCoverDownloads == 0 and #coverQueue == 0 then flushCoverPersistence() end
end

-- Queue cover downloads for rows that still need one (deduplicated).
local function queueCovers(rows, prioritize)
  local cachedCollectionsChanged, cachedCalendarChanged = false, false
  for _, row in ipairs(rows) do
    -- Disk hits must be resolved before the in-flight guard or queue capacity:
    -- another slow download must never delay an already available local image.
    local cached = existingDisplayCover(row.subjectId)
    if cached then
      local changedCollections, changedCalendar = applyCoverPath(row.subjectId, cached)
      cachedCollectionsChanged = cachedCollectionsChanged or changedCollections
      cachedCalendarChanged = cachedCalendarChanged or changedCalendar
      row.coverPath = cached
    end
    if row.coverPath and not noctalia.fileExists(row.coverPath) then
      local changedCollections, changedCalendar = applyCoverPath(row.subjectId, nil)
      cachedCollectionsChanged = cachedCollectionsChanged or changedCollections
      cachedCalendarChanged = cachedCalendarChanged or changedCalendar
      row.coverPath = nil
    end
    if row.coverUrl and not row.coverPath and not coversInFlight[row.subjectId] then
      coversInFlight[row.subjectId] = true
      table.insert(coverQueue, row)
    end
  end
  scheduleCoverPersistence(cachedCollectionsChanged, cachedCalendarChanged)
  if cachedCollectionsChanged or cachedCalendarChanged then publishSnapshot() end
  if prioritize then
    -- Keep the two already-running transfers, but let the visible page take
    -- the next slots ahead of background work from a previously browsed type.
    local wanted, front, back = {}, {}, {}
    for _, row in ipairs(rows) do wanted[row.subjectId] = true end
    for _, row in ipairs(coverQueue) do
      table.insert(if wanted[row.subjectId] then front else back, row)
    end
    coverQueue = front
    for _, row in ipairs(back) do table.insert(coverQueue, row) end
  end
  processCoverQueue()
end

local function queueCollectionCovers(collection, subjectIds)
  local wanted = {}
  if type(subjectIds) == "table" then
    for index, id in ipairs(subjectIds) do
      if index > 64 then break end
      wanted[tonumber(id) or 0] = true
    end
  end
  local rows = {}
  for index, row in ipairs(collection.rows) do
    if (subjectIds == nil and index <= 32) or wanted[row.subjectId] then
      table.insert(rows, row)
    end
  end
  queueCovers(rows, type(subjectIds) == "table")
end

local function queueCalendarCovers(subjectIds)
  if noctalia.getConfig("timeline_show_covers") == false or type(subjectIds) ~= "table" then return end
  local wanted = {}
  for index, id in ipairs(subjectIds) do
    if index > 256 then break end
    if positiveInteger(id) then wanted[id] = true end
  end
  local rows = {}
  local cachedCollectionsChanged, cachedCalendarChanged = false, false
  for _, day in ipairs(snapshot.calendar.days) do
    for _, row in ipairs(day.rows) do
      if wanted[row.subjectId] then
        local path = existingCalendarCover(row.subjectId)
        local failed = failedCoverUrls[row.subjectId]
        local coolingDown = failed and failed.url == row.coverUrl
          and os.time() >= failed.at and os.time() - failed.at < 60
        if path then
          local collectionsChanged, calendarChanged = applyCoverPath(row.subjectId, path)
          cachedCollectionsChanged = cachedCollectionsChanged or collectionsChanged
          cachedCalendarChanged = cachedCalendarChanged or calendarChanged
        elseif row.coverUrl and not coolingDown then
          table.insert(rows, row)
        end
      end
    end
  end
  scheduleCoverPersistence(cachedCollectionsChanged, cachedCalendarChanged)
  if cachedCollectionsChanged or cachedCalendarChanged then publishSnapshot() end
  queueCovers(rows, true)
end

-- The /v0/me identity cache uses the configured refresh_minutes lifetime.
local meCache = { result = nil, fetchedAt = 0 }

local function fetchMe(cb)
  local generation = sessionGeneration
  if meCache.result and fresh(meCache.fetchedAt) then
    cb(meCache.result)
    return
  end
  apiGet("/v0/me", "", function(ok, status, body)
    if generation ~= sessionGeneration then
      return
    end
    if not ok then
      cb({ error = "network" })
      return
    end
    if status == 401 then
      cb({ error = "unauthorized" })
      return
    end
    if status == 403 then
      cb({ error = "forbidden" })
      return
    end
    if status ~= 200 then
      cb({ error = "http_" .. tostring(status) })
      return
    end
    local parsedOk, parsed = pcall(noctalia.json.decode, body)
    if not parsedOk or type(parsed) ~= "table" then
      cb({ error = "parse" })
      return
    end
    local result = {
      username = tostring(parsed.username or ""),
      nickname = tostring(parsed.nickname or ""),
      id = tonumber(parsed.id) or 0,
    }
    restoreProfile(result)
    -- /v0/me can already contain User profile fields. Cache those without an
    -- extra public request; downloading is still gated by load_profile.
    if positiveInteger(result.id) and (type(parsed.sign) == "string" or type(parsed.avatar) == "table") then
      updateProfileData(parsed, result)
    end
    meCache.result = result
    meCache.fetchedAt = os.time()
    cb(result)
  end)
end

-- Unwatched episode calculation for the bar's available-but-unwatched count.
-- Forward declarations; implementations follow fetchEpisodes.
local recomputeUnwatched
local buildUnwatchedQueue
local processUnwatchedQueue

local function loadWatching(silent, cb)
  if snapshot.loading or snapshot.busy then
    return
  end
  snapshot.loading = true
  local generation = sessionGeneration
  snapshot.error = ""
  if not silent then
    snapshot.refreshing = true
  end
  publishSnapshot()

  local function finish(collection, result)
    if generation ~= sessionGeneration then
      return
    end
    snapshot.loading = false
    snapshot.refreshing = collectionRefreshActive
    if result.error then
      rememberCollectionTotal(collection, result.error)
      setError(result.error)
      if cb then
        cb(false)
      end
      return
    end
    collection.loaded = true
    collection.total = result.total or #result.rows
    collection.rows = result.rows
    rebuildCollectionIndex()
    collection.fetchedAt = os.time()
    rememberCollectionTotal(collection)
    lastAutoRefreshAt = noctalia.nowMs()
    if noctalia.state.get("bgm_open") == true and noctalia.getConfig("show_collection_covers") ~= false then queueCollectionCovers(collection) end
    buildUnwatchedQueue()
    publishSnapshot()
    persistCache()
    if cb then
      cb(true)
    end
  end

  if accessToken ~= "" then
    fetchMe(function(meResult)
      if generation ~= sessionGeneration then
        return
      end
      if meResult.error then
        snapshot.loading = false
        snapshot.refreshing = false
        rememberCollectionTotal(collectionOf(TYPE_WATCHING), meResult.error)
        setError(meResult.error)
        if cb then
          cb(false)
        end
        return
      end
      snapshot.viewer = meResult
      restoreProfile(snapshot.viewer)
      snapshot.authMode = "token"
      -- PAT reads require an explicit username because /v0/users/-/collections returns 404.
      if meResult.username and meResult.username ~= "" then
        username = meResult.username
      end
      publishSnapshot()
      fetchCollectionType(TYPE_WATCHING, function(result)
        if generation ~= sessionGeneration then
          return
        end
        finish(collectionOf(TYPE_WATCHING), result)
      end)
    end)
  else
    snapshot.viewer = { username = username, nickname = username }
    restoreProfile(snapshot.viewer)
    snapshot.authMode = "public"
    publishSnapshot()
    fetchCollectionType(TYPE_WATCHING, function(result)
      if generation ~= sessionGeneration then
        return
      end
      finish(collectionOf(TYPE_WATCHING), result)
    end)
  end
end

-- Lazy-load a non-watching type for the panel.
local function loadType(collectionType, cb, force)
  if snapshot.loading or snapshot.busy then
    if cb then cb(false) end
    return
  end
  local collection = collectionOf(collectionType)
  if not collection then
    if cb then
      cb(false)
    end
    return
  end
  if (collection.loaded and fresh(collection.fetchedAt) and not force) or fetchInFlight[tostring(collectionType)] then
    if noctalia.state.get("bgm_open") == true and noctalia.getConfig("show_collection_covers") ~= false then queueCollectionCovers(collection) end
    if cb then
      cb(true)
    end
    return
  end
  snapshot.loading = true
  local generation = sessionGeneration
  publishSnapshot()
  fetchCollectionType(collectionType, function(result)
    if generation ~= sessionGeneration then
      return
    end
    snapshot.loading = false
    if result.error then
      rememberCollectionTotal(collection, result.error)
      setError(result.error)
      if cb then
        cb(false)
      end
      return
    end
    collection.loaded = true
    collection.total = result.total or #result.rows
    collection.rows = result.rows
    rebuildCollectionIndex()
    collection.fetchedAt = os.time()
    rememberCollectionTotal(collection)
    if noctalia.state.get("bgm_open") == true and noctalia.getConfig("show_collection_covers") ~= false then queueCollectionCovers(collection) end
    publishSnapshot()
    persistCache()
    if cb then
      cb(true)
    end
  end)
end

-- Silent refreshes triggered by opening the panel use the configured refresh_minutes throttle.
local lastPanelRefreshAt = 0
local panelRefresh -- Forward declaration; implemented after refreshAll.

local function refreshAll(silent)
  if not authReady or snapshot.loading or snapshot.busy or collectionRefreshActive or oauthExpired() then
    return
  end
  local generation = sessionGeneration
  collectionRefreshActive = true
  snapshot.refreshing = true
  -- Reload the watching list first, then every panel category already loaded.
  local reloadTypes = {}
  for _, t in ipairs(ALL_TYPES) do
    local c = collectionOf(t)
    if c and c.loaded then
      if t ~= TYPE_WATCHING then
        table.insert(reloadTypes, t)
      end
    end
  end
  local function loadNext(index)
    if generation ~= sessionGeneration then return end
    local t = reloadTypes[index]
    if not t then
      collectionRefreshActive = false
      snapshot.refreshing = false
      publishSnapshot()
      return
    end
    loadType(t, function(ok)
      if ok then
        loadNext(index + 1)
      else
        collectionRefreshActive = false
        snapshot.refreshing = false
        publishSnapshot()
      end
    end, true)
  end
  loadWatching(silent, function(ok)
    if generation ~= sessionGeneration then return end
    if ok then
      loadNext(1)
    else
      collectionRefreshActive = false
      snapshot.refreshing = false
      publishSnapshot()
    end
  end)
end

panelRefresh = function()
  local watching = collectionOf(TYPE_WATCHING)
  if watching and watching.loaded and fresh(watching.fetchedAt) then return end
  -- Failed background reads keep the old collection. Reopening must not turn
  -- that stale cache into an immediate retry loop; manual refresh still bypasses it.
  if snapshot.loading or fresh(lastPanelRefreshAt) then return end
  lastPanelRefreshAt = os.time()
  refreshAll(true)
end

local BAR_COLLECTION_TYPES = {
  wish = TYPE_WISH, completed = TYPE_DONE, watching = TYPE_WATCHING,
  on_hold = TYPE_ON_HOLD, dropped = TYPE_DROPPED,
}

local function loadBarCount(collectionType)
  if not authReady or snapshot.authMode == "none" or oauthExpired() or not snapshot.viewer then return end
  local key = tostring(collectionType)
  local collection = collectionOf(collectionType)
  local count = snapshot.barCounts[key]
  if collection and collection.loaded and fresh(collection.fetchedAt)
    and (not count or count.error == "")
    and (not count or (collection.fetchedAt or 0) >= (count.fetchedAt or 0)) then
    if not count or count.total ~= collection.total or count.fetchedAt ~= collection.fetchedAt or count.error ~= "" then
      rememberCollectionTotal(collection)
      publishSnapshot()
    end
    return
  end
  if count and fresh(count.fetchedAt) and count.error == "" then return end
  local request = barCountRequests[key]
  if request and (request.inFlight or (request.attemptedAt > 0
    and noctalia.nowMs() - request.attemptedAt < BAR_RETRY_MS)) then return end
  -- A panel request already obtains this same total; do not duplicate it.
  if fetchInFlight[key] then return end
  request = request or { generation = 0, attemptedAt = 0 }
  request.generation += 1
  request.inFlight = true
  request.attemptedAt = noctalia.nowMs()
  request.startedAt = request.attemptedAt
  barCountRequests[key] = request
  count = count or { fetchedAt = 0 }
  count.loading = true
  count.error = ""
  snapshot.barCounts[key] = count
  local generation, requestGeneration = sessionGeneration, request.generation
  syncInterval()
  publishSnapshot()
  local function finish(error, total)
    if generation ~= sessionGeneration or barCountRequests[key] ~= request
      or requestGeneration ~= request.generation or not request.inFlight then return end
    request.inFlight = false
    if error then request.attemptedAt = noctalia.nowMs() end
    count.loading = false
    count.error = error or ""
    if total ~= nil then
      count.total = total
      count.fetchedAt = os.time()
    end
    syncInterval()
    publishSnapshot()
  end
  apiGet(collectionsPath(), "subject_type=" .. SUBJECT_TYPE_ANIME .. "&type=" .. collectionType .. "&limit=1&offset=0", function(ok, status, body)
    if generation ~= sessionGeneration or requestGeneration ~= request.generation or not request.inFlight then return end
    if not ok then finish("network"); return end
    if status == 401 or status == 403 then finish(if status == 403 then "forbidden" else "unauthorized"); return end
    if status ~= 200 then finish("http_" .. tostring(status)); return end
    local parsedOk, parsed = pcall(noctalia.json.decode, body)
    local total = if parsedOk and type(parsed) == "table" then parsed.total else nil
    if type(total) ~= "number" or total < 0 or total >= math.huge or total % 1 ~= 0 then finish("parse"); return end
    finish(nil, total)
  end)
end

loadBarData = function(mode)
  if mode == "none" then return end
  if mode == "today_all" or mode == "today_watching" then loadCalendar(false) end
  if mode == "today_watching" or mode == "watching" or mode == "newly_unwatched" then
    local watching = collectionOf(TYPE_WATCHING)
    if not authReady or snapshot.authMode == "none" or oauthExpired() then return end
    if watching and watching.loaded and fresh(watching.fetchedAt) then return end
    if snapshot.loading or (lastBarWatchingAttemptAt > 0
      and noctalia.nowMs() - lastBarWatchingAttemptAt < BAR_RETRY_MS) then return end
    lastBarWatchingAttemptAt = noctalia.nowMs()
    loadWatching(true)
  elseif BAR_COLLECTION_TYPES[mode] then
    loadBarCount(BAR_COLLECTION_TYPES[mode])
  end
end

-- ===== Anime progress updates =====
-- Observed in August 2026: collection-level PATCH accepts ep_status only for
-- books and returns 400 "can't set 'ep_status' on non-book subject" for anime.
-- The legacy POST /collection/{id}/update resets the collection status to Wish
-- and must not be used. Anime progress must be updated episode by episode:
--   GET  /v0/episodes?subject_id=X&type=0         retrieve main-story episode IDs
--   PATCH /v0/users/-/collections/X/episodes      {"episode_id":[id],"type":2|0}
-- Broadcast progress cache: subjectId -> { byEp, maxEp, airedEp, fetchedAt }.
-- Its lifetime follows refresh_minutes; see the TTL check in buildUnwatchedQueue.
local episodeCache = {}

local function todayString()
  return os.date("%Y-%m-%d")
end

-- Batch episode metadata while broadcast requests are active. Keep a fixed
-- deadline so a slow/continuous queue cannot postpone persistence indefinitely.
local unwatchedQueue = {}
local unwatchedQueued = {}     -- subjectId -> true
local unwatchedInFlight = {}   -- subjectId -> true
local activeUnwatchedFetches = 0
local activeEpisodeFetches = 0

local function flushEpisodePersistence()
  local changed = pendingUnwatchedUpdate
  if changed then
    pendingUnwatchedUpdate = false
    recomputeUnwatched(true)
  end
  if pendingEpisodePersistence then persistCache() end
  flushBadgePersistence()
  if changed then publishSnapshot() end
  syncInterval()
end

local function flushDrainedEpisodes()
  if activeEpisodeFetches == 0 and activeUnwatchedFetches == 0 and #unwatchedQueue == 0 then
    flushEpisodePersistence()
  end
end

local function fetchEpisodes(subjectId, cb, force)
  local generation = sessionGeneration
  if not force and episodeCache[subjectId] and fresh(episodeCache[subjectId].fetchedAt) then
    cb(episodeCache[subjectId])
    return
  end
  activeEpisodeFetches += 1
  local function complete(cache)
    activeEpisodeFetches -= 1
    if cache then
      episodeCache[subjectId] = cache
      pendingEpisodePersistence = true
      if episodePersistDueAt == 0 then
        episodePersistDueAt = noctalia.nowMs() + EPISODE_PERSIST_INTERVAL_MS
      end
      syncInterval()
    end
    -- The caller applies aired progress to the current rows before persistence.
    cb(cache)
    if generation == sessionGeneration then flushDrainedEpisodes() end
  end
  local byEp = {}
  local maxEp = 0
  local airedEp = 0
  local today = todayString()
  local offset = 0
  local function nextPage()
    local query = "subject_id=" .. tostring(subjectId) .. "&type=0&limit=" .. PAGE_LIMIT .. "&offset=" .. offset
    apiGet("/v0/episodes", query, function(ok, status, body)
      if generation ~= sessionGeneration then
        return
      end
      if not ok or status ~= 200 then
        complete(nil)
        return
      end
      local parsedOk, parsed = pcall(noctalia.json.decode, body)
      if not parsedOk or type(parsed) ~= "table" then
        complete(nil)
        return
      end
      local page = parsed.data
      if type(page) ~= "table" then
        complete(nil)
        return
      end
      for _, e in ipairs(page) do
        local ep = tonumber(e.ep)
        local eid = tonumber(e.id)
        if ep and ep > 0 and eid then
          byEp[ep] = eid
          if ep > maxEp then
            maxEp = ep
          end
          -- A nonempty airdate no later than today means the episode has aired.
          local airdate = tostring(e.airdate or "")
          if airdate ~= "" and airdate <= today and ep > airedEp then
            airedEp = ep
          end
        end
      end
      offset += #page
      if offset < (tonumber(parsed.total) or offset) and #page > 0 then
        nextPage()
      else
        local cache = { byEp = byEp, maxEp = maxEp, airedEp = airedEp, fetchedAt = os.time() }
        complete(cache)
      end
    end)
  end
  nextPage()
end

-- ===== Unwatched episode calculation =====
-- For unfinished Watching entries, count aired but unwatched episodes
-- (airedEp - epStatus). The bar reports additions since the last progress
-- update. airedEpBySubject preserves broadcast progress across row refreshes.
local UNWATCHED_MAX_CONCURRENT = 2
local airedEpBySubject = {}    -- subjectId -> airedEp, retained across refreshes
local badgeBaselines = {}      -- subjectId -> unwatched count at the last progress action

-- Cancel old callbacks without discarding the last account's display/cache.
-- This is also used while logout is pending, before success is known.
local function suspendAccountRequests()
  flushCoverPersistence()
  flushEpisodePersistence()
  sessionGeneration += 1
  collectionRefreshActive = false
  cancelCalendar()
  fetchInFlight = {}
  barCountRequests = {}
  for _, count in pairs(snapshot.barCounts) do count.loading = false end
  lastBarWatchingAttemptAt = 0
  coversInFlight = {}
  failedCoverUrls = {}
  coverQueue = {}
  activeCoverDownloads = 0
  lastPanelRefreshAt = 0
  snapshot.loading = false
  snapshot.refreshing = false
  snapshot.busy = false
  profileState.inFlight = false
  profileState.startedAt = 0
  profileState.avatarInFlight = nil
  profileState.requestGeneration += 1
  unwatchedQueue = {}
  unwatchedQueued = {}
  unwatchedInFlight = {}
  activeUnwatchedFetches = 0
  activeEpisodeFetches = 0
end

local function clearAccountState()
  -- Persist pending paths under the old identity before an actual account clear.
  suspendAccountRequests()
  snapshot.barCounts = {}
  snapshot.viewer = nil
  profileState = { key = "", fetchedAt = 0, attemptedAt = 0, result = nil, inFlight = false, startedAt = 0, avatarInFlight = nil, avatarAttemptedAt = 0, avatarAttemptedUrl = nil, requestGeneration = 0 }
  snapshot.unwatched = nil
  meCache = { result = nil, fetchedAt = 0 }
  episodeCache = {}
  airedEpBySubject = {}
  badgeBaselines = {}
  for _, collection in ipairs(snapshot.collections) do
    collection.loaded = false
    collection.total = 0
    collection.rows = {}
    collection.fetchedAt = nil
  end
  rebuildCollectionIndex()
end

local function loadBadgeBaselines(mode)
  local dir = noctalia.pluginDataDir()
  if not dir then
    return
  end
  local contents = noctalia.readFile(dir .. "/" .. BADGE_BASELINES_FILE)
  if not contents or contents == "" then
    return
  end
  local ok, parsed = pcall(noctalia.json.decode, contents)
  if not ok or type(parsed) ~= "table" then
    return
  end
  if parsed.authMode ~= mode then
    return
  end
  if mode == "token" then
    if snapshot.authSource == "oauth" and parsed.authSource == "oauth" then
      if tonumber(parsed.accountId) ~= tonumber(snapshot.viewer and snapshot.viewer.id) then return end
    elseif parsed.authSource == "oauth" or parsed.tokenFingerprint ~= tokenFingerprint(accessToken) then
      return
    end
  end
  if mode == "public" and tostring(parsed.username or "") ~= username then
    return
  end
  if type(parsed.values) ~= "table" then
    return
  end
  for subjectId, value in pairs(parsed.values) do
    local id = tonumber(subjectId)
    local baseline = tonumber(value)
    if id and baseline then
      badgeBaselines[id] = math.max(0, baseline)
    end
  end
end

local function saveBadgeBaselines()
  pendingBadgePersistence = false
  local dir = noctalia.pluginDataDir()
  if not dir then
    return
  end
  local encoded = {}
  for subjectId, baseline in pairs(badgeBaselines) do
    encoded[tostring(subjectId)] = baseline
  end
  noctalia.writeFile(dir .. "/" .. BADGE_BASELINES_FILE, noctalia.json.encode({
    authMode = snapshot.authMode,
    authSource = snapshot.authSource,
    accountId = snapshot.authSource == "oauth" and snapshot.viewer and snapshot.viewer.id or nil,
    username = username,
    tokenFingerprint = accessToken ~= "" and tokenFingerprint(accessToken) or nil,
    values = encoded,
  }))
end

flushBadgePersistence = function()
  if pendingBadgePersistence then saveBadgeBaselines() end
end

local function acknowledgeRow(row)
  if row.airedEp == nil then
    return
  end
  badgeBaselines[row.subjectId] = math.max(0, row.airedEp - (row.epStatus or 0))
  pendingBadgePersistence = true
end

persistCache = function()
  if pendingUnwatchedUpdate then
    pendingUnwatchedUpdate = false
    recomputeUnwatched(true)
    flushBadgePersistence()
    publishSnapshot()
  end
  local dir = noctalia.pluginDataDir()
  if not dir then
    return
  end
  local episodes = {}
  for subjectId, cache in pairs(episodeCache) do
    local byEp = {}
    for ep, episodeId in pairs(cache.byEp or {}) do
      byEp[tostring(ep)] = episodeId
    end
    episodes[tostring(subjectId)] = {
      byEp = byEp,
      maxEp = cache.maxEp or 0,
      airedEp = cache.airedEp or 0,
      fetchedAt = cache.fetchedAt or 0,
    }
  end
  local payload = {
    version = CACHE_VERSION,
    savedAt = os.time(),
    authMode = snapshot.authMode,
    authSource = snapshot.authSource,
    accountId = snapshot.authSource == "oauth" and snapshot.viewer and snapshot.viewer.id or nil,
    tokenFingerprint = accessToken ~= "" and tokenFingerprint(accessToken) or nil,
    viewer = snapshot.viewer,
    meCache = meCache,
    collections = snapshot.collections,
    episodes = episodes,
  }
  noctalia.writeFile(dir .. "/" .. CACHE_FILE, noctalia.json.encode(payload))
  -- Collection/progress writes already include all completed episode metadata.
  pendingUnwatchedUpdate = false
  pendingEpisodePersistence = false
  episodePersistDueAt = 0
end

local function loadPersistentCache(mode, configuredUsername)
  local dir = noctalia.pluginDataDir()
  if not dir then
    return false
  end
  local contents = noctalia.readFile(dir .. "/" .. CACHE_FILE)
  if not contents or contents == "" then
    return false
  end
  local ok, parsed = pcall(noctalia.json.decode, contents)
  if not ok or type(parsed) ~= "table" or tonumber(parsed.version) ~= CACHE_VERSION then
    return false
  end
  if parsed.authMode ~= mode then
    return false
  end
  local cachedViewer = type(parsed.viewer) == "table" and parsed.viewer or nil
  if mode == "token" then
    if snapshot.authSource == "oauth" and parsed.authSource == "oauth" then
      local accountId = tonumber(snapshot.viewer and snapshot.viewer.id)
      if not accountId or tonumber(parsed.accountId) ~= accountId
        or tonumber(cachedViewer and cachedViewer.id) ~= accountId then return false end
    elseif parsed.authSource == "oauth" or parsed.tokenFingerprint ~= tokenFingerprint(accessToken) then
      return false
    elseif snapshot.authSource == "oauth"
      and tonumber(cachedViewer and cachedViewer.id) ~= tonumber(snapshot.viewer and snapshot.viewer.id) then
      return false
    end
  end
  if mode == "public" then
    local cachedUsername = cachedViewer and tostring(cachedViewer.username or "") or ""
    if cachedUsername ~= configuredUsername then
      return false
    end
  end

  snapshot.viewer = cachedViewer
  snapshot.authMode = mode
  if snapshot.viewer then restoreProfile(snapshot.viewer) end
  if type(parsed.meCache) == "table" and type(parsed.meCache.result) == "table" then
    meCache = {
      result = parsed.meCache.result,
      fetchedAt = tonumber(parsed.meCache.fetchedAt) or 0,
    }
  end
  if type(parsed.collections) == "table" then
    for _, cachedCollection in ipairs(parsed.collections) do
      local collection = collectionOf(tonumber(cachedCollection.type))
      if collection and type(cachedCollection.rows) == "table" then
        collection.loaded = cachedCollection.loaded == true
        collection.total = tonumber(cachedCollection.total) or #cachedCollection.rows
        collection.rows = cachedCollection.rows
        -- Repair paths before the restored collection reaches its first snapshot.
        -- Do not start downloads for unvisited categories during restoration.
        for _, row in ipairs(collection.rows) do
          local cached = existingDisplayCover(row.subjectId)
          if cached then row.coverPath = cached
          elseif row.coverPath and not noctalia.fileExists(row.coverPath) then row.coverPath = nil end
        end
        collection.fetchedAt = tonumber(cachedCollection.fetchedAt) or 0
      end
    end
  end
  if type(parsed.episodes) == "table" then
    for subjectId, cachedEpisode in pairs(parsed.episodes) do
      local id = tonumber(subjectId)
      if id and type(cachedEpisode) == "table" and type(cachedEpisode.byEp) == "table" then
        local byEp = {}
        for ep, episodeId in pairs(cachedEpisode.byEp) do
          local epNumber = tonumber(ep)
          local idNumber = tonumber(episodeId)
          if epNumber and idNumber then
            byEp[epNumber] = idNumber
          end
        end
        episodeCache[id] = {
          byEp = byEp,
          maxEp = tonumber(cachedEpisode.maxEp) or 0,
          airedEp = tonumber(cachedEpisode.airedEp) or 0,
          fetchedAt = tonumber(cachedEpisode.fetchedAt) or 0,
        }
        airedEpBySubject[id] = tonumber(cachedEpisode.airedEp) or 0
      end
    end
  end
  rebuildCollectionIndex()
  return true
end

recomputeUnwatched = function(deferPublication)
  local total = 0
  local anyKnown = false
  local baselinesChanged = false
  local watching = collectionOf(TYPE_WATCHING)
  for _, row in ipairs(watching and watching.rows or {}) do
    row.newlyUnwatched = 0
    if row.airedEp ~= nil then
      anyKnown = true
      local currentUnwatched = math.max(0, row.airedEp - (row.epStatus or 0))
      local baseline = badgeBaselines[row.subjectId]
      if baseline == nil then
        baseline = currentUnwatched
        badgeBaselines[row.subjectId] = baseline
        baselinesChanged = true
      end
      local newlyUnwatched = currentUnwatched - baseline
      if newlyUnwatched > 0 then
        row.newlyUnwatched = newlyUnwatched
        total += newlyUnwatched
      end
    end
  end
  if baselinesChanged then pendingBadgePersistence = true end
  snapshot.unwatched = anyKnown and total or nil
  if not deferPublication then
    pendingUnwatchedUpdate = false
    flushBadgePersistence()
    publishSnapshot()
  end
end

buildUnwatchedQueue = function()
  local watching = collectionOf(TYPE_WATCHING)
  local rows = watching and watching.rows or {}
  for _, row in ipairs(rows) do
    if positiveInteger(row.subjectId) and ((row.eps or 0) <= 0 or (row.epStatus or 0) < row.eps) then
      local subjectId = row.subjectId
      local cached = airedEpBySubject[subjectId]
      local cache = episodeCache[subjectId]
      if cached ~= nil and cache and fresh(cache.fetchedAt) then
        row.airedEp = cached
      elseif not unwatchedQueued[subjectId] and not unwatchedInFlight[subjectId] then
        unwatchedQueued[subjectId] = true
        table.insert(unwatchedQueue, subjectId)
      end
    end
  end
  recomputeUnwatched()
  -- Fill broadcast progress immediately after collection load or manual refresh.
  -- processUnwatchedQueue still limits concurrent title requests.
  processUnwatchedQueue()
end

processUnwatchedQueue = function()
  while activeUnwatchedFetches < UNWATCHED_MAX_CONCURRENT and #unwatchedQueue > 0 do
    local subjectId = table.remove(unwatchedQueue, 1)
    unwatchedQueued[subjectId] = nil
    if not subjectId then
      break
    end
    unwatchedInFlight[subjectId] = true
    activeUnwatchedFetches += 1
    fetchEpisodes(subjectId, function(cache)
      activeUnwatchedFetches -= 1
      unwatchedInFlight[subjectId] = nil
      if cache then
        airedEpBySubject[subjectId] = cache.airedEp or 0
        for _, row in ipairs(collectionRowsBySubject[subjectId] or {}) do
          row.airedEp = cache.airedEp or 0
        end
        pendingUnwatchedUpdate = true
      end
      processUnwatchedQueue()
    end, true)
  end
  -- Cache-hit callbacks may complete synchronously without a network response.
  flushDrainedEpisodes()
end

local function patchEpisodes(subjectId, episodeIds, epType, cb)
  if not authReady or accessToken == "" or oauthExpired() then
    cb({ error = "unauthorized" })
    return
  end
  local generation = sessionGeneration
  publishSnapshot()
  local url = API_BASE .. "/v0/users/-/collections/" .. tostring(subjectId) .. "/episodes"
  local body = noctalia.json.encode({ episode_id = episodeIds, type = epType })
  local accepted = noctalia.http({
    url = url,
    method = "PATCH",
    headers = defaultHeaders({ "Content-Type: application/json" }),
    body = body,
  }, function(resp)
    if generation ~= sessionGeneration then
      return
    end
    local ok = resp.ok == true
    local status = resp.status or 0
    if not ok then
      cb({ error = "network" })
      return
    end
    if status == 401 then
      cb({ error = "unauthorized" })
      return
    end
    if status == 403 then
      cb({ error = "forbidden" })
      return
    end
    if status == 200 or status == 204 then
      cb({ ok = true })
      return
    end
    cb({ error = "http_" .. tostring(status) })
  end)
  if not accepted then
    cb({ error = "network" })
  end
end

local function rowFor(subjectId)
  local rows = collectionRowsBySubject[subjectId]
  return rows and rows[1] or nil
end

local function failWrite(errorCode)
  snapshot.error = errorCode
  publishSnapshot()
end

local function beginProgress()
  if not authReady or accessToken == "" or oauthExpired() then
    failWrite("unauthorized")
    return false
  end
  if snapshot.busy or snapshot.oauthBusy or snapshot.loading or collectionRefreshActive or next(fetchInFlight) ~= nil then
    failWrite("busy")
    return false
  end
  snapshot.busy = true
  snapshot.error = ""
  syncInterval()
  publishSnapshot()
  return true
end

local function finishProgress(errorCode)
  snapshot.busy = false
  if errorCode then snapshot.error = errorCode end
  syncInterval()
  publishSnapshot()
end

local function applyProgress(subjectId, progress, cache)
  -- Resolve current indexed rows defensively even though collection reads are locked.
  for _, row in ipairs(collectionRowsBySubject[subjectId] or {}) do
    row.epStatus = progress
    row.updatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
    if cache then row.airedEp = cache.airedEp or 0 end
    acknowledgeRow(row)
  end
  pendingUnwatchedUpdate = false
  recomputeUnwatched(true)
  flushBadgePersistence()
  persistCache()
  finishProgress()
end

local function updateAnimeProgress(subjectId, delta)
  local row = rowFor(subjectId)
  if not row then
    return
  end
  if not beginProgress() then return end
  local generation = sessionGeneration
  fetchEpisodes(subjectId, function(cache)
    if generation ~= sessionGeneration then
      return
    end
    if not cache then
      finishProgress("episodes_unavailable")
      return
    end
    if delta > 0 then
      local nextEp = row.epStatus + 1
      local eid = cache.byEp[nextEp]
      if not eid then
        finishProgress("no_next_episode")
        return
      end
      patchEpisodes(subjectId, { eid }, 2, function(result)
        if generation ~= sessionGeneration then
          return
        end
        if result.ok then
          applyProgress(subjectId, nextEp, cache)
        else
          finishProgress(result.error)
        end
      end)
    else
      local curEp = row.epStatus
      local eid = cache.byEp[curEp]
      if curEp <= 0 or not eid then
        finishProgress("no_prev_episode")
        return
      end
      patchEpisodes(subjectId, { eid }, 0, function(result)
        if generation ~= sessionGeneration then
          return
        end
        if result.ok then
          applyProgress(subjectId, curEp - 1, cache)
        else
          finishProgress(result.error)
        end
      end)
    end
  end)
end

local function markDone(subjectId)
  local row = rowFor(subjectId)
  if not row then
    return
  end
  if (row.eps or 0) > 0 and row.epStatus >= row.eps then
    return
  end
  if not beginProgress() then return end
  local generation = sessionGeneration
  fetchEpisodes(subjectId, function(cache)
    if generation ~= sessionGeneration then
      return
    end
    if not cache then
      finishProgress("episodes_unavailable")
      return
    end
    local ids = {}
    for ep = row.epStatus + 1, cache.maxEp do
      local eid = cache.byEp[ep]
      if eid then
        table.insert(ids, eid)
      end
    end
    if #ids == 0 then
      applyProgress(subjectId, math.max(row.epStatus, cache.maxEp), cache)
      return
    end
    patchEpisodes(subjectId, ids, 2, function(result)
      if generation ~= sessionGeneration then
        return
      end
      if result.ok then
        applyProgress(subjectId, math.max(row.epStatus, cache.maxEp), cache)
      else
        finishProgress(result.error)
      end
    end)
  end)
end

local function openSubject(subjectId)
  noctalia.runAsync("xdg-open " .. shellQuote("https://bgm.tv/subject/" .. tostring(subjectId)) .. " >/dev/null 2>&1")
end

-- User OAuth tokens stay in the private helper session file and this service.
-- The shared snapshot contains only UI status, never tokens, codes, or app secrets.
local function oauthPaths()
  local pluginDir = noctalia.pluginDir()
  local dataDir = noctalia.pluginDataDir()
  if not pluginDir or not dataDir then
    return nil
  end
  -- Development overrides remain private; normal installs use the shipped app.
  -- A present but invalid override is an error, not a silent app switch.
  local localClient = pluginDir .. "/oauth-client.json"
  local client = if noctalia.fileExists(localClient) then localClient
    else pluginDir .. "/oauth-client.shared.json"
  return {
    script = pluginDir .. "/scripts/bangumi_oauth.py",
    client = client,
    data = dataDir .. "/oauth",
    session = dataDir .. "/oauth/oauth-session.json",
  }
end

local function readJson(path)
  local contents = noctalia.readFile(path)
  if not contents then return nil end
  local ok, value = pcall(noctalia.json.decode, contents)
  return if ok and type(value) == "table" then value else nil
end

local function updateOAuthAvailability()
  local paths = oauthPaths()
  local profile = paths and readJson(paths.client)
  snapshot.oauthAvailable = noctalia.commandExists("python3") and profile ~= nil
    and type(profile.client_id) == "string" and profile.client_id ~= ""
    and type(profile.client_secret) == "string" and profile.client_secret ~= ""
    and type(profile.redirect_uri) == "string" and profile.redirect_uri ~= ""
end

local function resumeManual()
  clearAccountState()
  accessToken = ""
  oauthExpiresAt = 0
  snapshot.oauthExpiresAt = nil
  snapshot.oauthError = ""
  snapshot.authMode = resolveAuth()
  authReady = true
  lastAutoRefreshAt = 0
  if snapshot.authMode == "none" then
    setError("not_configured")
    return
  end
  loadBadgeBaselines(snapshot.authMode)
  if loadPersistentCache(snapshot.authMode, username) then
    local watching = collectionOf(TYPE_WATCHING)
    if watching and watching.loaded then
      if noctalia.state.get("bgm_open") == true and noctalia.getConfig("show_collection_covers") ~= false then queueCollectionCovers(watching) end
      buildUnwatchedQueue()
    end
    publishSnapshot()
    if watching and watching.loaded and fresh(watching.fetchedAt) then
      lastAutoRefreshAt = noctalia.nowMs()
      return
    end
  end
  loadWatching(false)
end

local function useOAuthSession()
  local paths = oauthPaths()
  local session = paths and readJson(paths.session)
  if not session or session.version ~= 1 or type(session.access_token) ~= "string"
    or session.access_token == "" or type(session.username) ~= "string" or session.username == ""
    or not tonumber(session.user_id) or not tonumber(session.expires_at) then
    snapshot.oauthError = "oauth_storage_error"
    return false
  end
  local sameAccount = snapshot.authSource == "oauth" and snapshot.viewer
    and tonumber(snapshot.viewer.id) == tonumber(session.user_id)
  if not sameAccount then clearAccountState() end
  accessToken = session.access_token
  username = session.username
  oauthExpiresAt = tonumber(session.expires_at)
  snapshot.oauthExpiresAt = oauthExpiresAt
  snapshot.authSource = "oauth"
  snapshot.authMode = "token"
  snapshot.error = ""
  snapshot.oauthError = ""
  snapshot.viewer = {
    id = tonumber(session.user_id), username = username,
    nickname = tostring(session.nickname or username),
  }
  restoreProfile(snapshot.viewer)
  authReady = true
  oauthRetryAt = 0
  if session.relogin_required == true then
    accessToken = ""
    oauthRetryAt = math.huge
    snapshot.oauthError = "oauth_invalid_grant"
    snapshot.error = "unauthorized"
  end
  lastAutoRefreshAt = 0
  -- OAuth helper has validated this session's user ID. Scope private data by
  -- that ID and auth source so token rotation preserves the same account cache.
  if not sameAccount then
    loadBadgeBaselines("token")
    loadPersistentCache("token", username)
  end
  publishSnapshot()
  local watching = collectionOf(TYPE_WATCHING)
  if watching and watching.loaded then
    if noctalia.state.get("bgm_open") == true and noctalia.getConfig("show_collection_covers") ~= false then queueCollectionCovers(watching) end
    if not oauthExpired() then buildUnwatchedQueue() end
  end
  if watching and watching.loaded and fresh(watching.fetchedAt) then
    lastAutoRefreshAt = noctalia.nowMs()
    -- Recovered OAuth collections are already persisted by account ID. Token
    -- rotation alone does not change them; cover/episode changes save themselves.
  elseif not oauthExpired() then
    loadWatching(false)
  end
  return true
end

local function runOAuth(action, onDone, attempt)
  local paths = oauthPaths()
  if not paths or not noctalia.commandExists("python3") then
    snapshot.oauthError = "oauth_unavailable"
    publishSnapshot()
    return false
  end
  oauthGeneration += 1
  local generation = oauthGeneration
  oauthCounter += 1
  oauthAttempt = attempt or string.format("%d-%d-%08d", os.time(), noctalia.nowMs(), oauthCounter)
  snapshot.oauthBusy = true
  snapshot.oauthOperation = action
  oauthStartedAt = noctalia.nowMs()
  -- Keep OAuth progress and timeout checks responsive without an open panel;
  -- the ordinary collection refresh interval can be as long as a day.
  noctalia.setUpdateInterval(250)
  publishSnapshot()
  local done = false
  local function finish(result)
    if done or generation ~= oauthGeneration then return end
    done = true
    snapshot.oauthBusy = false
    snapshot.oauthOperation = ""
    oauthStartedAt = 0
    snapshotPublicationDepth += 1
    local ok, failure = pcall(onDone, result)
    snapshotPublicationDepth -= 1
    syncInterval()
    publishSnapshot()
    -- Restore publication before reporting an unexpected callback failure.
    if not ok then error(failure, 0) end
  end
  local command = "exec python3 -u " .. shellQuote(paths.script) .. " " .. shellQuote(action)
    .. " --data-dir " .. shellQuote(paths.data) .. " --client-file " .. shellQuote(paths.client)
    .. " --attempt-id " .. shellQuote(oauthAttempt) .. " 2>/dev/null"
  -- runStream is stopped by the host on reload and is not subject to the short runAsync timeout.
  local accepted = noctalia.runStream(command, function(line)
    local ok, result = pcall(noctalia.json.decode, line)
    if ok and type(result) == "table" and type(result.ok) == "boolean" then
      finish(result)
    end
  end)
  if not accepted then finish({ ok = false, error = "oauth_unavailable" }) end
  return accepted
end

startOAuth = function()
  if snapshot.oauthBusy or snapshot.busy then
    snapshot.oauthError = "oauth_busy"
    return
  end
  updateOAuthAvailability()
  if not snapshot.oauthAvailable then
    snapshot.oauthError = if noctalia.commandExists("python3") then "oauth_not_configured" else "oauth_unavailable"
    return
  end
  snapshot.oauthError = ""
  runOAuth("login", function(result)
    if result.ok then
      if useOAuthSession() then
        noctalia.notify(noctalia.tr("panel.oauth_signed_in_title"), noctalia.tr("panel.oauth_signed_in"))
      end
    else
      snapshot.oauthError = tostring(result.error or "oauth_unknown_error")
    end
  end)
end

cancelOAuth = function()
  if not snapshot.oauthBusy or snapshot.oauthOperation ~= "login" then return end
  local attempt = oauthAttempt
  runOAuth("cancel", function(result)
    if result.ok and result.completed == true then
      -- The helper committed before cancellation acquired its lock. Consume
      -- that account instead of discarding success and claiming cancellation.
      if useOAuthSession() then
        noctalia.notify(noctalia.tr("panel.oauth_signed_in_title"), noctalia.tr("panel.oauth_already_completed"))
      end
    else
      snapshot.oauthError = if result.ok then "oauth_cancelled" else tostring(result.error or "oauth_unknown_error")
    end
  end, attempt)
end

local function recoverAfterLogout(errorCode)
  -- Logout may have failed before deletion, or finished without a usable reply.
  -- Ask the helper to validate the surviving session/application before reuse.
  runOAuth("status", function(result)
    if result.ok and result.authenticated then
      if useOAuthSession() then
        if snapshot.oauthError == "" then snapshot.oauthError = errorCode end
        if oauthExpired() then snapshot.error = "unauthorized" end
        return
      end
    elseif result.ok then
      -- No session remains: keep the old display read-only until the user
      -- signs in again or explicitly completes disconnect. Never switch PATs.
      oauthRetryAt = math.huge
      snapshot.oauthError = if result.configured == false then "oauth_not_configured"
        else "oauth_not_authenticated"
    else
      if result.error == "oauth_client_changed" or result.error == "oauth_invalid_grant" then
        oauthRetryAt = math.huge
      end
      snapshot.oauthError = tostring(result.error or errorCode)
    end
    accessToken = ""
    authReady = false
    snapshot.error = "unauthorized"
  end)
end

logoutOAuth = function(returnToManual)
  if snapshot.oauthOperation == "logout" then return end
  -- Stop reads/writes and ignore old callbacks, but retain account data until
  -- the helper confirms deletion. A failure can then restore the same cache.
  suspendAccountRequests()
  accessToken = ""
  authReady = false
  runOAuth("logout", function(result)
    if result.ok then
      clearAccountState()
      oauthExpiresAt = 0
      snapshot.oauthExpiresAt = nil
      oauthRetryAt = 0
      local dir = noctalia.pluginDataDir()
      if dir then
        noctalia.removeFile(dir .. "/" .. CACHE_FILE)
        noctalia.removeFile(dir .. "/" .. BADGE_BASELINES_FILE)
      end
      if returnToManual == false then
        snapshot.authMode = "none"
        snapshot.authSource = "none"
        snapshot.oauthError = ""
        snapshot.error = "not_configured"
      else
        resumeManual()
      end
    else
      recoverAfterLogout(tostring(result.error or "oauth_unknown_error"))
    end
  end)
end

refreshOAuth = function(force)
  if snapshot.authSource ~= "oauth" or snapshot.oauthBusy or snapshot.busy
    or snapshot.loading or snapshot.refreshing or oauthRetryAt == math.huge
    or (not force and os.time() < oauthRetryAt) then return end
  oauthRetryAt = os.time() + 60
  runOAuth("refresh", function(result)
    if result.ok and useOAuthSession() then return end
    snapshot.oauthError = if result.ok then snapshot.oauthError
      else tostring(result.error or "oauth_unknown_error")
    local needsSignIn = result.error == "oauth_invalid_grant" or result.error == "oauth_client_changed"
    if needsSignIn then oauthRetryAt = math.huge end
    if needsSignIn or oauthExpired() or result.ok then
      -- Expired/revoked credentials disable authenticated operations, but
      -- transient network errors must not erase collections, episodes/badges.
      suspendAccountRequests()
      accessToken = ""
      snapshot.error = "unauthorized"
    end
  end)
end

local function processCommand(command)
  if type(command) ~= "table" then
    return
  end
  local action = command.action
  if action == "oauth_login" then
    startOAuth()
  elseif action == "oauth_refresh" then
    refreshOAuth(true)
  elseif action == "oauth_cancel" then
    cancelOAuth()
  elseif action == "oauth_logout" then
    logoutOAuth()
  elseif action == "load_profile" then
    loadProfile()
  elseif action == "load_calendar" then
    loadCalendar(command.force == true)
  elseif action == "refresh_calendar" then
    loadCalendar(true)
  elseif action == "load_calendar_covers" then
    queueCalendarCovers(command.subjectIds)
  elseif action == "load_bar_data" then
    local mode = command.mode
    if mode == "today_all" or mode == "today_watching" or mode == "newly_unwatched" or BAR_COLLECTION_TYPES[mode] then
      loadBarData(mode)
    end
  elseif action == "open_subject" then
    openSubject(tonumber(command.subjectId))
  elseif action == "refresh" and snapshot.authSource == "oauth"
    and (not authReady or oauthExpired()) then
    if command.silent ~= true then refreshOAuth(true) end
  elseif not authReady then
    return
  elseif action == "refresh" then
    if command.silent == true then
      panelRefresh() -- Throttled refresh when opening the panel.
    else
      refreshAll(false) -- The manual refresh button always refreshes.
    end
  elseif action == "load_type" then
    loadType(tonumber(command.type))
  elseif action == "load_covers" then
    local collection = collectionOf(tonumber(command.type))
    if collection and type(command.subjectIds) == "table" then
      queueCollectionCovers(collection, command.subjectIds)
    end
  elseif action == "increment" then
    updateAnimeProgress(tonumber(command.subjectId), 1)
  elseif action == "decrement" then
    updateAnimeProgress(tonumber(command.subjectId), -1)
  elseif action == "complete" then
    markDone(tonumber(command.subjectId))
  end
end

syncInterval = function()
  local ms = refreshMs
  for _, request in pairs(barCountRequests) do
    if request.inFlight then ms = math.min(ms, 5000); break end
  end
  if snapshot.oauthBusy then
    -- Check OAuth progress and deadlines even while the panel is closed.
    noctalia.setUpdateInterval(250)
    return
  elseif snapshot.authSource == "oauth" then
    ms = math.min(ms, 30000)
  end
  if snapshot.loading or snapshot.refreshing or snapshot.calendar.loading or profileState.inFlight then
    ms = 5000
  elseif snapshot.busy then
    ms = 2000
  end
  if pendingCoverCollections or pendingCoverCalendar then ms = math.min(ms, COVER_PERSIST_INTERVAL_MS) end
  if pendingEpisodePersistence or pendingUnwatchedUpdate or pendingBadgePersistence then
    ms = math.min(ms, EPISODE_PERSIST_INTERVAL_MS)
  end
  noctalia.setUpdateInterval(ms)
end

function update()
  syncInterval()
  if coverPersistDueAt > 0 and noctalia.nowMs() >= coverPersistDueAt then flushCoverPersistence() end
  if episodePersistDueAt > 0 and noctalia.nowMs() >= episodePersistDueAt then flushEpisodePersistence() end
  local barCountsChanged = false
  for key, request in pairs(barCountRequests) do
    if request.inFlight and noctalia.nowMs() - request.startedAt >= BAR_COUNT_TIMEOUT_MS then
      request.inFlight = false
      request.generation += 1
      request.attemptedAt = noctalia.nowMs()
      local count = snapshot.barCounts[key]
      if count then count.loading = false; count.error = "network" end
      barCountsChanged = true
    end
  end
  if barCountsChanged then syncInterval(); publishSnapshot() end
  if profileState.inFlight and noctalia.nowMs() - profileState.startedAt >= PROFILE_TIMEOUT_MS then
    profileState.inFlight = false
    profileState.startedAt = 0
  end
  if calendarInFlight and noctalia.nowMs() - calendarStartedAt >= CALENDAR_TIMEOUT_MS then
    cancelCalendar()
    calendarAttemptedAt = noctalia.nowMs()
    snapshot.calendar.error = "network"
    publishSnapshot()
  end
  -- A crashed helper may produce no final JSON. Bound the visible waiting state.
  if snapshot.oauthBusy and noctalia.nowMs() - oauthStartedAt > 240000 then
    local action = snapshot.oauthOperation
    if action == "login" then
      cancelOAuth()
    else
      oauthGeneration += 1
      snapshot.oauthBusy = false
      snapshot.oauthOperation = ""
    end
    snapshot.oauthError = "oauth_timeout"
    if action == "logout" then recoverAfterLogout("oauth_timeout") end
    publishSnapshot()
  end
  if not authReady then return end
  if snapshot.authSource == "oauth" and os.time() >= oauthExpiresAt - 120 then
    refreshOAuth()
  end
  if snapshot.oauthBusy or oauthExpired() then return end
  processUnwatchedQueue()
  if not snapshot.loading and not snapshot.refreshing and not snapshot.busy then
    local nowMs = noctalia.nowMs()
    if lastAutoRefreshAt == 0 then
      lastAutoRefreshAt = nowMs
    elseif nowMs < lastAutoRefreshAt or (nowMs - lastAutoRefreshAt) >= refreshMs then
      lastAutoRefreshAt = nowMs
      refreshAll(true)
    end
  end
end

noctalia.state.watch("bgm_command", function(command)
  processCommand(command)
  -- Cover completion/cache resolution publishes only when a path changes.
  if type(command) ~= "table" or (command.action ~= "load_covers" and command.action ~= "load_calendar_covers" and command.action ~= "load_bar_data") then
    publishSnapshot()
  end
end)

function onIpc(event, _payload)
  if event == "load_calendar" then
    loadCalendar(type(_payload) == "table" and _payload.force == true)
  elseif event == "refresh_calendar" then
    loadCalendar(true)
  elseif event == "refresh" then
    if snapshot.authSource == "oauth" and (not authReady or oauthExpired()) then
      refreshOAuth(true)
    else
      refreshAll(true)
    end
  elseif event == "logout" then
    if snapshot.authSource == "oauth" or snapshot.oauthBusy then
      logoutOAuth(false)
      return
    end
    clearAccountState()
    accessToken = ""
    authReady = false
    snapshot.authMode = "none"
    publishSnapshot()
  end
end

function init()
  refreshMs = math.max(MIN_IDLE_MS, (tonumber(noctalia.getConfig("refresh_minutes")) or 30) * 60000)
  loadCalendarCache()
  updateOAuthAvailability()
  local paths = oauthPaths()
  if not paths or not noctalia.readFile(paths.session) then
    resumeManual()
  else
    snapshot.authSource = "oauth"
    runOAuth("status", function(result)
      if result.ok and result.authenticated then
        if useOAuthSession() and oauthExpiresAt <= os.time() + 120 then refreshOAuth() end
      else
        -- Do not silently fall back to a different PAT account when saved OAuth is unusable.
        snapshot.oauthError = tostring(result.error or "oauth_not_configured")
      end
    end)
  end
  syncInterval()
end

init()


-- The host invokes entry points by name; this reference suppresses static-analysis unused warnings.
local _ = { update, onIpc }
