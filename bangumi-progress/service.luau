--!nonstrict
-- Bangumi Progress service: personal access token, v0 API access, cover cache, and progress updates.
-- The desktop widget, bar widget, and panel communicate only through noctalia.state and never access the network directly.

local API_BASE = "https://api.bgm.tv"
local USER_AGENT = "noctalia-bangumi-progress/1.1.0 (https://github.com/noctalia-dev/community-plugins)"
local SUBJECT_TYPE_ANIME = 2
local PAGE_LIMIT = 50
local COVER_DIR = "covers"
local BADGE_BASELINES_FILE = "badge-baselines.json"
local CACHE_FILE = "cache.json"
local CACHE_VERSION = 1
local MAX_CONCURRENT_COVERS = 2
local MIN_IDLE_MS = 30000

-- Collection types: 1 Wish, 2 Completed, 3 Watching, 4 On Hold, 5 Dropped.
local TYPE_WISH = 1
local TYPE_DONE = 2
local TYPE_WATCHING = 3
local TYPE_ON_HOLD = 4
local TYPE_DROPPED = 5
local ALL_TYPES = { TYPE_WISH, TYPE_DONE, TYPE_WATCHING, TYPE_ON_HOLD, TYPE_DROPPED }

local snapshot = {
  revision = 0,
  loading = false,
  refreshing = false,
  busy = false,
  error = "",
  viewer = nil,
  authMode = "none", -- "token" | "public" | "none"
  collections = {},
}
for _, t in ipairs(ALL_TYPES) do
  table.insert(snapshot.collections, { type = t, loaded = false, total = 0, rows = {} })
end

local accessToken = ""
local username = ""
local refreshMs = 30 * 60000
local fetchInFlight = {} -- type -> true
local coversInFlight = {} -- subjectId -> true
local coverQueue = {}     -- rows waiting for a download slot
local activeCoverDownloads = 0
local lastAutoRefreshAt = 0
local persistCache

local function trim(value)
  return noctalia.string.trim(tostring(value or ""))
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function publishSnapshot()
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

local function resolveAuth()
  accessToken = trim(noctalia.getConfig("access_token") or "")
  username = trim(noctalia.getConfig("username") or "")
  if accessToken ~= "" then
    return "token"
  end
  if username ~= "" then
    return "public"
  end
  return "none"
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
  local coverUrl = images.grid or images.medium or images.common or nil
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
    coverPath = nil,
  }
end

-- Fetch one collection type, paging through the API, then cb({rows=..., total=...})
-- or cb({error = "unauthorized" | "network" | "http_<status>" | "parse"}).
local function fetchCollectionType(collectionType, cb)
  local key = tostring(collectionType)
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
      if not ok then
        fetchInFlight[key] = nil
        cb({ error = "network" })
        return
      end
      if status == 401 or status == 403 then
        fetchInFlight[key] = nil
        cb({ error = "unauthorized" })
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

local function processCoverQueue()
  local cachedCoversChanged = false
  while activeCoverDownloads < MAX_CONCURRENT_COVERS and #coverQueue > 0 do
    local row = table.remove(coverQueue, 1)
    if row and not row.coverPath and row.coverUrl then
      activeCoverDownloads += 1
      local dir = coverDir()
      if not dir then
        activeCoverDownloads -= 1
        return
      end
      local ext = (row.coverUrl:match("%.(%w+)$") or "jpg"):lower()
      if ext == "jpeg" then
        ext = "jpg"
      end
      local path = dir .. "/" .. tostring(row.subjectId) .. "." .. ext
      coversInFlight[row.subjectId] = true
      if noctalia.fileExists(path) then
        row.coverPath = path
        coversInFlight[row.subjectId] = nil
        activeCoverDownloads -= 1
        cachedCoversChanged = true
      else
        local accepted = noctalia.download(row.coverUrl, path, function(downloadOk)
          activeCoverDownloads -= 1
          coversInFlight[row.subjectId] = nil
          if downloadOk then
            row.coverPath = path
          end
          publishSnapshot()
          processCoverQueue()
        end)
        if not accepted then
          activeCoverDownloads -= 1
          coversInFlight[row.subjectId] = nil
        end
      end
    end
  end
  -- Cached files are resolved synchronously. Publishing once per hit can cause
  -- a burst of full UI rebuilds before the host completes its first layout.
  if cachedCoversChanged then
    publishSnapshot()
  end
end

-- Queue cover downloads for rows that still need one (deduplicated).
local function queueCovers(rows)
  for _, row in ipairs(rows) do
    if row.coverUrl and not row.coverPath and not coversInFlight[row.subjectId] then
      coversInFlight[row.subjectId] = true
      table.insert(coverQueue, row)
    end
  end
  processCoverQueue()
end

-- The /v0/me identity cache uses the configured refresh_minutes lifetime.
local meCache = { result = nil, fetchedAt = 0 }

local function fetchMe(cb)
  if meCache.result and (os.time() - meCache.fetchedAt) * 1000 < refreshMs then
    cb(meCache.result)
    return
  end
  apiGet("/v0/me", "", function(ok, status, body)
    if not ok then
      cb({ error = "network" })
      return
    end
    if status == 401 or status == 403 then
      cb({ error = "unauthorized" })
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
  if snapshot.loading then
    return
  end
  snapshot.loading = true
  snapshot.error = ""
  if not silent then
    snapshot.refreshing = true
  end
  publishSnapshot()

  local function finish(collection, result)
    snapshot.loading = false
    snapshot.refreshing = false
    if result.error then
      setError(result.error)
      if cb then
        cb(false)
      end
      return
    end
    collection.loaded = true
    collection.total = result.total or #result.rows
    collection.rows = result.rows
    collection.fetchedAt = os.time()
    queueCovers(result.rows)
    buildUnwatchedQueue()
    publishSnapshot()
    persistCache()
    if cb then
      cb(true)
    end
  end

  if accessToken ~= "" then
    fetchMe(function(meResult)
      if meResult.error then
        snapshot.loading = false
        snapshot.refreshing = false
        setError(meResult.error)
        if cb then
          cb(false)
        end
        return
      end
      snapshot.viewer = meResult
      snapshot.authMode = "token"
      -- PAT reads require an explicit username because /v0/users/-/collections returns 404.
      if meResult.username and meResult.username ~= "" then
        username = meResult.username
      end
      publishSnapshot()
      fetchCollectionType(TYPE_WATCHING, function(result)
        finish(collectionOf(TYPE_WATCHING), result)
      end)
    end)
  else
    snapshot.viewer = { username = username, nickname = username }
    snapshot.authMode = "public"
    publishSnapshot()
    fetchCollectionType(TYPE_WATCHING, function(result)
      finish(collectionOf(TYPE_WATCHING), result)
    end)
  end
end

-- Lazy-load a non-watching type for the panel.
local function loadType(collectionType, cb)
  local collection = collectionOf(collectionType)
  if not collection then
    if cb then
      cb(false)
    end
    return
  end
  if collection.loaded or fetchInFlight[tostring(collectionType)] then
    if cb then
      cb(true)
    end
    return
  end
  snapshot.loading = true
  publishSnapshot()
  fetchCollectionType(collectionType, function(result)
    snapshot.loading = false
    if result.error then
      setError(result.error)
      if cb then
        cb(false)
      end
      return
    end
    collection.loaded = true
    collection.total = result.total or #result.rows
    collection.rows = result.rows
    collection.fetchedAt = os.time()
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
  if snapshot.loading then
    return
  end
  -- Reload the watching list first, then every panel category already loaded.
  local reloadTypes = {}
  for _, t in ipairs(ALL_TYPES) do
    local c = collectionOf(t)
    if c and c.loaded then
      if t ~= TYPE_WATCHING then
        table.insert(reloadTypes, t)
      end
      c.loaded = false
      c.total = 0
      c.rows = {}
    end
  end
  local function loadNext(index)
    local t = reloadTypes[index]
    if not t then
      return
    end
    loadType(t, function(ok)
      if ok then
        loadNext(index + 1)
      end
    end)
  end
  loadWatching(silent, function(ok)
    if ok then
      loadNext(1)
    end
  end)
end

panelRefresh = function()
  local now = os.time()
  if lastPanelRefreshAt > 0 and (now - lastPanelRefreshAt) * 1000 < refreshMs then
    return
  end
  lastPanelRefreshAt = now
  refreshAll(true)
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

local function fetchEpisodes(subjectId, cb, force)
  if not force and episodeCache[subjectId] then
    cb(episodeCache[subjectId])
    return
  end
  local byEp = {}
  local maxEp = 0
  local airedEp = 0
  local today = todayString()
  local offset = 0
  local function nextPage()
    local query = "subject_id=" .. tostring(subjectId) .. "&type=0&limit=" .. PAGE_LIMIT .. "&offset=" .. offset
    apiGet("/v0/episodes", query, function(ok, status, body)
      if not ok or status ~= 200 then
        cb(nil)
        return
      end
      local parsedOk, parsed = pcall(noctalia.json.decode, body)
      if not parsedOk or type(parsed) ~= "table" then
        cb(nil)
        return
      end
      local page = parsed.data
      if type(page) ~= "table" then
        cb(nil)
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
        episodeCache[subjectId] = cache
        if persistCache then
          persistCache()
        end
        cb(cache)
      end
    end)
  end
  nextPage()
end

-- ===== Unwatched episode calculation =====
-- For unfinished Watching entries, count aired but unwatched episodes
-- (airedEp - epStatus). The bar reports additions since the last progress
-- update. airedEpBySubject preserves broadcast progress across row refreshes.
local unwatchedQueue = {}
local unwatchedQueued = {}     -- subjectId -> true
local unwatchedInFlight = {}   -- subjectId -> true
local activeUnwatchedFetches = 0
local UNWATCHED_MAX_CONCURRENT = 2
local airedEpBySubject = {}    -- subjectId -> airedEp, retained across refreshes
local badgeBaselines = {}      -- subjectId -> unwatched count at the last progress action

local function loadBadgeBaselines()
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
  for subjectId, value in pairs(parsed) do
    local id = tonumber(subjectId)
    local baseline = tonumber(value)
    if id and baseline then
      badgeBaselines[id] = math.max(0, baseline)
    end
  end
end

local function saveBadgeBaselines()
  local dir = noctalia.pluginDataDir()
  if not dir then
    return
  end
  local encoded = {}
  for subjectId, baseline in pairs(badgeBaselines) do
    encoded[tostring(subjectId)] = baseline
  end
  noctalia.writeFile(dir .. "/" .. BADGE_BASELINES_FILE, noctalia.json.encode(encoded))
end

local function acknowledgeRow(row)
  if row.airedEp == nil then
    return
  end
  badgeBaselines[row.subjectId] = math.max(0, row.airedEp - (row.epStatus or 0))
  saveBadgeBaselines()
end

persistCache = function()
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
    viewer = snapshot.viewer,
    meCache = meCache,
    collections = snapshot.collections,
    episodes = episodes,
  }
  noctalia.writeFile(dir .. "/" .. CACHE_FILE, noctalia.json.encode(payload))
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
  if mode == "public" then
    local cachedUsername = cachedViewer and tostring(cachedViewer.username or "") or ""
    if cachedUsername ~= configuredUsername then
      return false
    end
  end

  snapshot.viewer = cachedViewer
  snapshot.authMode = mode
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
  return true
end

recomputeUnwatched = function()
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
  if baselinesChanged then
    saveBadgeBaselines()
  end
  snapshot.unwatched = anyKnown and total or nil
  publishSnapshot()
end

buildUnwatchedQueue = function()
  local watching = collectionOf(TYPE_WATCHING)
  local rows = watching and watching.rows or {}
  for _, row in ipairs(rows) do
    if row.eps and row.eps > 0 and (row.epStatus or 0) < row.eps then
      local subjectId = row.subjectId
      local cached = airedEpBySubject[subjectId]
      local cache = episodeCache[subjectId]
      if cached ~= nil and cache and (os.time() - cache.fetchedAt) * 1000 < refreshMs then
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
        local watching = collectionOf(TYPE_WATCHING)
        for _, row in ipairs(watching and watching.rows or {}) do
          if row.subjectId == subjectId then
            row.airedEp = cache.airedEp or 0
            break
          end
        end
      end
      recomputeUnwatched()
      processUnwatchedQueue()
    end, true)
  end
end

local function patchEpisodes(subjectId, episodeIds, epType, cb)
  if accessToken == "" then
    cb({ error = "unauthorized" })
    return
  end
  if snapshot.busy then
    cb({ error = "busy" })
    return
  end
  snapshot.busy = true
  publishSnapshot()
  local url = API_BASE .. "/v0/users/-/collections/" .. tostring(subjectId) .. "/episodes"
  local body = noctalia.json.encode({ episode_id = episodeIds, type = epType })
  local accepted = noctalia.http({
    url = url,
    method = "PATCH",
    headers = defaultHeaders({ "Content-Type: application/json" }),
    body = body,
  }, function(resp)
    snapshot.busy = false
    local ok = resp.ok == true
    local status = resp.status or 0
    if not ok then
      cb({ error = "network" })
      return
    end
    if status == 401 or status == 403 then
      cb({ error = "unauthorized" })
      return
    end
    if status == 200 or status == 204 then
      cb({ ok = true })
      return
    end
    cb({ error = "http_" .. tostring(status) })
  end)
  if not accepted then
    snapshot.busy = false
    cb({ error = "network" })
  end
end

local function rowFor(subjectId)
  for _, c in ipairs(snapshot.collections) do
    for _, row in ipairs(c.rows) do
      if row.subjectId == subjectId then
        return row
      end
    end
  end
  return nil
end

local function failWrite(errorCode)
  snapshot.error = errorCode
  publishSnapshot()
end

local function updateAnimeProgress(subjectId, delta)
  local row = rowFor(subjectId)
  if not row then
    return
  end
  fetchEpisodes(subjectId, function(cache)
    if not cache then
      failWrite("episodes_unavailable")
      return
    end
    if delta > 0 then
      local nextEp = row.epStatus + 1
      local eid = cache.byEp[nextEp]
      if not eid then
        failWrite("no_next_episode")
        return
      end
      patchEpisodes(subjectId, { eid }, 2, function(result)
        if result.ok then
          row.epStatus = nextEp
          row.updatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
          acknowledgeRow(row)
          recomputeUnwatched()
          persistCache()
        else
          failWrite(result.error)
        end
      end)
    else
      local curEp = row.epStatus
      local eid = cache.byEp[curEp]
      if curEp <= 0 or not eid then
        failWrite("no_prev_episode")
        return
      end
      patchEpisodes(subjectId, { eid }, 0, function(result)
        if result.ok then
          row.epStatus = curEp - 1
          row.updatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
          acknowledgeRow(row)
          recomputeUnwatched()
          persistCache()
        else
          failWrite(result.error)
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
  if row.epStatus >= (row.eps or 0) then
    return
  end
  fetchEpisodes(subjectId, function(cache)
    if not cache then
      failWrite("episodes_unavailable")
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
      row.epStatus = math.max(row.epStatus, cache.maxEp)
      row.updatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
      acknowledgeRow(row)
      recomputeUnwatched()
      persistCache()
      return
    end
    patchEpisodes(subjectId, ids, 2, function(result)
      if result.ok then
        row.epStatus = math.max(row.epStatus, cache.maxEp)
        row.updatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
        acknowledgeRow(row)
        recomputeUnwatched()
        persistCache()
      else
        failWrite(result.error)
      end
    end)
  end)
end

local function openSubject(subjectId)
  noctalia.runAsync("xdg-open " .. shellQuote("https://bgm.tv/subject/" .. tostring(subjectId)) .. " >/dev/null 2>&1")
end

local function processCommand(command)
  if type(command) ~= "table" then
    return
  end
  local action = command.action
  if action == "refresh" then
    if command.silent == true then
      panelRefresh() -- Throttled refresh when opening the panel.
    else
      refreshAll(false) -- The manual refresh button always refreshes.
    end
  elseif action == "load_type" then
    loadType(tonumber(command.type))
  elseif action == "increment" then
    updateAnimeProgress(tonumber(command.subjectId), 1)
  elseif action == "decrement" then
    updateAnimeProgress(tonumber(command.subjectId), -1)
  elseif action == "complete" then
    markDone(tonumber(command.subjectId))
  elseif action == "open_subject" then
    openSubject(tonumber(command.subjectId))
  end
end

local function syncInterval()
  local ms = refreshMs
  if snapshot.loading or snapshot.refreshing then
    ms = 5000
  elseif snapshot.busy then
    ms = 2000
  end
  noctalia.setUpdateInterval(ms)
end

function update()
  syncInterval()
  processUnwatchedQueue()
  if not snapshot.loading and not snapshot.refreshing and not snapshot.busy then
    local nowMs = noctalia.nowMs()
    if lastAutoRefreshAt == 0 then
      lastAutoRefreshAt = nowMs
    elseif (nowMs - lastAutoRefreshAt) >= refreshMs then
      lastAutoRefreshAt = nowMs
      refreshAll(true)
    end
  end
end

noctalia.state.watch("bgm_command", function(command)
  processCommand(command)
  publishSnapshot()
end)

function onIpc(event, _payload)
  if event == "refresh" then
    refreshAll(true)
  elseif event == "logout" then
    snapshot.viewer = nil
    snapshot.authMode = "none"
    snapshot.unwatched = nil
    meCache = { result = nil, fetchedAt = 0 }
    unwatchedQueue = {}
    unwatchedQueued = {}
    unwatchedInFlight = {}
    activeUnwatchedFetches = 0
    airedEpBySubject = {}
    for _, c in ipairs(snapshot.collections) do
      c.loaded = false
      c.total = 0
      c.rows = {}
    end
    publishSnapshot()
  end
end

function init()
  loadBadgeBaselines()
  local mode = resolveAuth()
  refreshMs = math.max(MIN_IDLE_MS, (tonumber(noctalia.getConfig("refresh_minutes")) or 30) * 60000)
  if mode == "none" then
    snapshot.viewer = nil
    snapshot.authMode = "none"
    setError("not_configured")
    noctalia.setUpdateInterval(MIN_IDLE_MS)
    return
  end
  local restored = loadPersistentCache(mode, username)
  local watching = collectionOf(TYPE_WATCHING)
  if restored and watching and watching.loaded then
    queueCovers(watching.rows)
    buildUnwatchedQueue()
    publishSnapshot()
    local ageMs = (os.time() - (watching.fetchedAt or 0)) * 1000
    if ageMs >= 0 and ageMs < refreshMs then
      lastAutoRefreshAt = noctalia.nowMs()
      return
    end
  end
  lastAutoRefreshAt = 0
  loadWatching(false)
end

init()


-- The host invokes entry points by name; this reference suppresses static-analysis unused warnings.
local _ = { update, onIpc }
