--!nonstrict
-- AniList (UNOFFICIAL) background service: OAuth token storage, GraphQL queries, and list mutations.
-- The panel and widget only talk through noctalia.state; they never hit the network.

local GRAPHQL_URL = "https://graphql.anilist.co"
local TOKEN_FILE = "token.json"
local OAUTH_CREDS_FILE = "oauth_credentials.json"
local OAUTH_RESULT_FILE = "oauth_result.json"

local CHUNK_SIZE = 50
local BACKGROUND_COVER_BATCH = 12
local FINALIZE_SORT_BATCH = 100
local FETCH_UPDATE_MS = 300
local COVER_UPDATE_MS = 120
local MAX_CONCURRENT_COVERS = 6

local accessToken = ""
local viewer = nil
local snapshot = {
  revision = 0,
  oauthLoading = false,
  loading = false,
  refreshing = false,
  busy = false,
  error = "",
  viewer = nil,
  anime = {},
  manga = {},
  loadProgress = nil,
}
local oauthRunning = false
local oauthCredPath = ""
local oauthResultPath = ""
local oauthStartedAt = 0

local libraryFetch = nil
local finalizeQueue = nil
local legacyCachePurged = false
local pendingLegacyPurge = false

local coverDownloadsInFlight = {}
local coverLoadingIds = {}
local lastCoverPriority = {}
local activeCoverDownloads = 0
local pendingCoverSnapshot = false
local pendingPriorityCovers = {}
local backgroundCoverCursor = { listKey = "anime", index = 1 }
local backgroundCoversActive = false

local function tr(key, subst)
  return noctalia.tr("service." .. key, subst)
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function tokenPath()
  local dir = noctalia.pluginDataDir()
  if not dir then
    return nil
  end
  return dir .. "/" .. TOKEN_FILE
end

local function trim(value)
  return noctalia.string.trim(tostring(value or ""))
end

local function readStoredToken()
  local path = tokenPath()
  if not path then
    return ""
  end
  local raw = noctalia.readFile(path)
  if not raw or raw == "" then
    return ""
  end
  local ok, parsed = pcall(noctalia.json.decode, raw)
  if not ok or type(parsed) ~= "table" or type(parsed.access_token) ~= "string" then
    noctalia.removeFile(path)
    return ""
  end
  return trim(parsed.access_token)
end

local function writeStoredToken(token)
  local path = tokenPath()
  if not path then
    return false
  end
  local payload = noctalia.json.encode({
    access_token = token,
    saved_at = os.time(),
  })
  return noctalia.writeFile(path, payload)
end

local function clearStoredToken()
  local path = tokenPath()
  if path then
    noctalia.removeFile(path)
  end
end

local function resolveToken()
  local fromSetting = noctalia.getConfig("access_token")
  local token = trim(fromSetting)
  if token ~= "" then
    return token
  end
  return readStoredToken()
end

local function publishSnapshot()
  snapshot.revision += 1
  noctalia.state.set("anilist_snapshot", snapshot)
end

local function clearLoadProgress()
  snapshot.loadProgress = nil
end

local function setLoadProgress(animeLoaded, mangaLoaded)
  snapshot.loadProgress = {
    animeLoaded = animeLoaded or 0,
    mangaLoaded = mangaLoaded or 0,
  }
end

local function setError(message)
  snapshot.error = message or ""
  snapshot.oauthLoading = false
  snapshot.loading = false
  snapshot.refreshing = false
  clearLoadProgress()
  libraryFetch = nil
  finalizeQueue = nil
  publishSnapshot()
end

local function mediaTotal(media)
  if type(media) ~= "table" then
    return nil
  end
  if media.type == "MANGA" then
    local chapters = tonumber(media.chapters)
    if chapters and chapters > 0 then
      return chapters
    end
    return nil
  end
  local episodes = tonumber(media.episodes)
  if episodes and episodes > 0 then
    return episodes
  end
  return nil
end

local function normalizeEntry(entry, mediaType)
  local media = entry.media or {}
  local title = media.title and media.title.userPreferred or ("#" .. tostring(entry.mediaId or media.id or "?"))
  local cover = media.coverImage or {}
  local nextAiring = media.nextAiringEpisode

  return {
    listEntryId = entry.id,
    mediaId = entry.mediaId or media.id,
    status = entry.status or "CURRENT",
    progress = tonumber(entry.progress) or 0,
    progressVolumes = tonumber(entry.progressVolumes) or 0,
    score = entry.score,
    total = mediaTotal(media),
    volumes = tonumber(media.volumes),
    title = title,
    coverColor = cover.color or "#334155",
    coverUrl = cover.extraLarge or cover.large or cover.medium or nil,
    coverPath = nil,
    mediaType = mediaType,
    nextEpisode = nextAiring and nextAiring.episode or nil,
    nextAiringAt = nextAiring and nextAiring.airingAt or nil,
    updatedAt = tonumber(entry.updatedAt) or 0,
  }
end

local function mergeEntries(target, entries, mediaType)
  for _, entry in ipairs(entries) do
    if type(entry) == "table" and entry.media then
      local normalized = normalizeEntry(entry, mediaType)
      local mediaId = normalized.mediaId
      if mediaId then
        local existing = target[mediaId]
        if not existing or (normalized.updatedAt or 0) >= (existing.updatedAt or 0) then
          target[mediaId] = normalized
        end
      end
    end
  end
end

local function mergeListsInto(byMediaId, lists, mediaType)
  if type(lists) ~= "table" then
    return
  end
  for _, list in ipairs(lists) do
    if type(list) == "table" and type(list.entries) == "table" then
      mergeEntries(byMediaId, list.entries, mediaType)
    end
  end
end

local function sortedKeysFor(byMediaId)
  local keys = {}
  for mediaId, row in pairs(byMediaId) do
    table.insert(keys, { mediaId = mediaId, title = (row.title or ""):lower() })
  end
  table.sort(keys, function(a, b)
    return a.title < b.title
  end)
  return keys
end

local function appendSortedRows(target, byMediaId, keys, startIndex, batchSize)
  local limit = math.min(#keys, startIndex + batchSize - 1)
  for index = startIndex, limit do
    local mediaId = keys[index].mediaId
    local row = byMediaId[mediaId]
    if row then
      table.insert(target, row)
    end
  end
  return limit + 1
end

local COVER_DIR_NAME = "covers"
local COVER_CACHE_VERSION = 2
local MAX_PRIORITY_COVERS = 48

local function hasPendingCoverWork()
  if next(pendingPriorityCovers) ~= nil then
    return true
  end
  return backgroundCoversActive
end

local OAUTH_POLL_MS = 500

local function syncUpdateInterval()
  if oauthRunning then
    noctalia.setUpdateInterval(OAUTH_POLL_MS)
    return
  end
  if libraryFetch ~= nil or finalizeQueue ~= nil or snapshot.loading or snapshot.refreshing then
    noctalia.setUpdateInterval(FETCH_UPDATE_MS)
  elseif activeCoverDownloads > 0 or hasPendingCoverWork() then
    noctalia.setUpdateInterval(COVER_UPDATE_MS)
  else
    noctalia.setUpdateInterval(30000)
    flushCoverSnapshot()
  end
end

local function coversDir()
  local dataDir = noctalia.pluginDataDir()
  if not dataDir then
    return nil
  end
  return dataDir .. "/" .. COVER_DIR_NAME
end

local function coverCacheDir()
  local dir = coversDir()
  if not dir then
    return nil
  end
  return dir .. "/v" .. tostring(COVER_CACHE_VERSION)
end

local function coverCachePath(mediaId)
  local dir = coverCacheDir()
  if not dir or not mediaId then
    return nil
  end
  return dir .. "/" .. tostring(mediaId) .. ".jpg"
end

local function coverMetaPath(mediaId)
  local path = coverCachePath(mediaId)
  if not path then
    return nil
  end
  return path .. ".meta.json"
end

local function isCoverCacheValid(mediaId, url)
  local path = coverCachePath(mediaId)
  local metaPath = coverMetaPath(mediaId)
  if not path or not metaPath or not noctalia.fileExists(path) then
    return false
  end

  local raw = noctalia.readFile(metaPath)
  if not raw or raw == "" then
    return false
  end

  local ok, parsed = pcall(noctalia.json.decode, raw)
  if not ok or type(parsed) ~= "table" then
    return false
  end

  return parsed.url == url and parsed.version == COVER_CACHE_VERSION
end

local function writeCoverMeta(mediaId, url)
  local metaPath = coverMetaPath(mediaId)
  if not metaPath then
    return
  end
  noctalia.writeFile(metaPath, noctalia.json.encode({
    url = url,
    version = COVER_CACHE_VERSION,
  }))
end

local function removeCoverCache(mediaId)
  local path = coverCachePath(mediaId)
  local metaPath = coverMetaPath(mediaId)
  if path then
    noctalia.removeFile(path)
  end
  if metaPath then
    noctalia.removeFile(metaPath)
  end
end

local function purgeLegacyCoverCache()
  local dir = coversDir()
  if not dir then
    return
  end

  local entries = noctalia.listDir(dir) or {}
  for _, name in ipairs(entries) do
    local path = dir .. "/" .. name
    if name:match("%.jpg$") or name:match("_xl%.jpg$") or name:match("%.meta%.json$") then
      noctalia.removeFile(path)
    elseif name:match("^v%d+$") and name ~= ("v" .. tostring(COVER_CACHE_VERSION)) then
      local files = noctalia.listDir(path) or {}
      for _, file in ipairs(files) do
        noctalia.removeFile(path .. "/" .. file)
      end
    end
  end

  local cacheDir = coverCacheDir()
  if cacheDir then
    noctalia.mkdirAll(cacheDir)
  end
  legacyCachePurged = true
end

local function attachCoverPathForEntry(row)
  if type(row) ~= "table" then
    return
  end
  local url = row.coverUrl
  if isCoverCacheValid(row.mediaId, url) then
    row.coverPath = coverCachePath(row.mediaId)
    return
  end
  row.coverPath = nil
  if row.mediaId and url then
    removeCoverCache(row.mediaId)
  end
end

local function publishCoverLoadingState()
  local ids = {}
  for mediaId in pairs(coverLoadingIds) do
    table.insert(ids, mediaId)
  end
  noctalia.state.set("anilist_cover_loading", ids)
end

local function setCoverLoading(mediaId, loading)
  if not mediaId then
    return
  end
  if loading then
    coverLoadingIds[mediaId] = true
  else
    coverLoadingIds[mediaId] = nil
  end
  publishCoverLoadingState()
end

local function needsCoverDownload(entry)
  if type(entry) ~= "table" then
    return false
  end
  local mediaId = entry.mediaId
  local url = entry.coverUrl
  if not mediaId or type(url) ~= "string" or url == "" then
    return false
  end
  return not isCoverCacheValid(mediaId, url)
end

local function requestCoverSnapshot()
  pendingCoverSnapshot = true
end

local function flushCoverSnapshot()
  if pendingCoverSnapshot then
    pendingCoverSnapshot = false
    publishSnapshot()
  end
end

local function findEntry(mediaId)
  if not mediaId then
    return nil
  end
  for _, list in ipairs({ snapshot.anime, snapshot.manga }) do
    for _, entry in ipairs(list) do
      if entry.mediaId == mediaId then
        return entry
      end
    end
  end
  return nil
end

local function setEntryCoverPath(mediaId, path)
  local entry = findEntry(mediaId)
  if entry then
    entry.coverPath = path
    requestCoverSnapshot()
  end
end

local function downloadCoverForEntry(row)
  if type(row) ~= "table" then
    return
  end

  local mediaId = row.mediaId
  local url = row.coverUrl
  if not mediaId or type(url) ~= "string" or url == "" then
    return
  end

  local path = coverCachePath(mediaId)
  if not path then
    return
  end

  if isCoverCacheValid(mediaId, url) then
    row.coverPath = path
    return
  end

  removeCoverCache(mediaId)

  if coverDownloadsInFlight[mediaId] then
    return
  end

  if activeCoverDownloads >= MAX_CONCURRENT_COVERS then
    return
  end

  local dir = coverCacheDir()
  if dir then
    noctalia.mkdirAll(dir)
  end

  coverDownloadsInFlight[mediaId] = true
  setCoverLoading(mediaId, true)
  activeCoverDownloads += 1
  syncUpdateInterval()

  local started = noctalia.download(url, path, function(ok)
    coverDownloadsInFlight[mediaId] = nil
    setCoverLoading(mediaId, false)
    activeCoverDownloads = math.max(0, activeCoverDownloads - 1)
    if ok then
      writeCoverMeta(mediaId, url)
      setEntryCoverPath(mediaId, path)
    end
    syncUpdateInterval()
  end)

  if not started then
    coverDownloadsInFlight[mediaId] = nil
    setCoverLoading(mediaId, false)
    activeCoverDownloads = math.max(0, activeCoverDownloads - 1)
    syncUpdateInterval()
  end
end

local function queuePriorityCovers(mediaIds)
  if type(mediaIds) ~= "table" then
    return
  end
  for _, id in ipairs(mediaIds) do
    local mediaId = tonumber(id)
    if mediaId then
      pendingPriorityCovers[mediaId] = true
    end
  end
  syncUpdateInterval()
end

local function processPriorityCovers()
  local processed = 0
  for mediaId in pairs(pendingPriorityCovers) do
    if activeCoverDownloads >= MAX_CONCURRENT_COVERS or processed >= MAX_PRIORITY_COVERS then
      break
    end
    pendingPriorityCovers[mediaId] = nil
    local entry = findEntry(mediaId)
    if entry then
      attachCoverPathForEntry(entry)
      if needsCoverDownload(entry) then
        downloadCoverForEntry(entry)
      end
    end
    processed += 1
  end

  if not hasPendingCoverWork() and activeCoverDownloads == 0 then
    syncUpdateInterval()
  end
end

local function nextBackgroundCoverEntry()
  local order = { "anime", "manga" }
  local startIndex = 1
  for index, key in ipairs(order) do
    if key == backgroundCoverCursor.listKey then
      startIndex = index
      break
    end
  end

  for offset = 0, #order - 1 do
    local key = order[((startIndex - 1 + offset) % #order) + 1]
    local list = if key == "manga" then snapshot.manga else snapshot.anime
    local cursor = if key == backgroundCoverCursor.listKey then backgroundCoverCursor.index else 1
    while cursor <= #list do
      local entry = list[cursor]
      backgroundCoverCursor.listKey = key
      backgroundCoverCursor.index = cursor + 1
      if entry and entry.coverPath == nil and entry.coverUrl then
        return entry
      end
      cursor += 1
    end
  end

  return nil
end

local function processBackgroundCovers()
  if not backgroundCoversActive then
    return
  end

  local processed = 0
  while processed < BACKGROUND_COVER_BATCH do
    if activeCoverDownloads >= MAX_CONCURRENT_COVERS then
      break
    end

    local savedCursor = {
      listKey = backgroundCoverCursor.listKey,
      index = backgroundCoverCursor.index,
    }
    local entry = nextBackgroundCoverEntry()
    if entry == nil then
      backgroundCoversActive = false
      syncUpdateInterval()
      return
    end

    attachCoverPathForEntry(entry)
    if needsCoverDownload(entry) and entry.mediaId then
      if activeCoverDownloads >= MAX_CONCURRENT_COVERS then
        backgroundCoverCursor = savedCursor
        break
      end
      downloadCoverForEntry(entry)
    end
    processed += 1
  end
end

local function resetBackgroundCovers()
  backgroundCoverCursor = { listKey = "anime", index = 1 }
  backgroundCoversActive = true
end

local LIST_QUERY = [[
query ($userId: Int, $type: MediaType, $chunk: Int, $perChunk: Int) {
  MediaListCollection(
    userId: $userId
    type: $type
    forceSingleCompletedList: true
    chunk: $chunk
    perChunk: $perChunk
  ) {
    hasNextChunk
    lists {
      name
      isCustomList
      status
      entries {
        id
        mediaId
        status
        progress
        progressVolumes
        score(format: POINT_100)
        updatedAt
        media {
          id
          type
          episodes
          chapters
          volumes
          coverImage { color extraLarge large medium }
          title { userPreferred }
          nextAiringEpisode { airingAt episode }
        }
      }
    }
  }
}
]]

local VIEWER_QUERY = [[
query {
  Viewer {
    id
    name
  }
}
]]

local SAVE_PROGRESS_MUTATION = [[
mutation ($mediaId: Int, $progress: Int, $status: MediaListStatus) {
  SaveMediaListEntry(mediaId: $mediaId, progress: $progress, status: $status) {
    id
    progress
    status
    media {
      id
      episodes
      chapters
      title { userPreferred }
    }
  }
}
]]

local function decodeParsed(parsed)
  if type(parsed.errors) == "table" and #parsed.errors > 0 then
    local message = parsed.errors[1].message or tr("mutation_failed")
    if message:lower():find("invalid token", 1, true)
      or message:lower():find("unauthorized", 1, true) then
      return nil, tr("invalid_token")
    end
    return nil, message
  end

  if type(parsed.data) == "table" then
    return parsed.data, nil
  end

  if parsed.Viewer or parsed.MediaListCollection or parsed.SaveMediaListEntry then
    return parsed, nil
  end

  return nil, tr("invalid_response")
end

local function setLoadError(message)
  if message == tr("invalid_token")
    or message == tr("invalid_response")
    or message == tr("empty_response") then
    accessToken = ""
    clearStoredToken()
    viewer = nil
    snapshot.viewer = nil
    snapshot.anime = {}
    snapshot.manga = {}
  end
  setError(message)
end

local function decodeBody(body)
  if type(body) == "table" then
    return decodeParsed(body)
  end

  if type(body) ~= "string" then
    return nil, tr("invalid_response")
  end

  body = trim(body)
  if body == "" then
    return nil, tr("empty_response")
  end

  local ok, parsed = pcall(noctalia.json.decode, body)
  if not ok or type(parsed) ~= "table" then
    noctalia.log("anilist: could not parse API response: " .. body:sub(1, 120))
    return nil, tr("invalid_response")
  end

  return decodeParsed(parsed)
end

local function graphqlRequest(query, variables, callback)
  if accessToken == "" then
    callback(nil, tr("not_configured"))
    return false
  end

  local body = noctalia.json.encode({
    query = query,
    variables = variables or {},
  })

  return noctalia.http({
    url = GRAPHQL_URL,
    method = "POST",
    headers = {
      "Content-Type: application/json",
      "Accept: application/json",
      "Authorization: Bearer " .. accessToken,
      "User-Agent: noctalia-anilist-plugin",
    },
    body = body,
  }, function(response)
    if not response then
      callback(nil, tr("network_error"))
      return
    end

    local bodyText = response.body
    if type(bodyText) == "string" and bodyText ~= "" then
      local data, err = decodeBody(bodyText)
      if data then
        callback(data, err)
        return
      end
      if err then
        callback(nil, err)
        return
      end
    end

    if response.status < 200 or response.status >= 300 then
      callback(nil, tr("network_error"))
      return
    end

    callback(nil, tr("network_error"))
  end)
end

local function newFetchJob(mediaType, userId)
  return {
    mediaType = mediaType,
    userId = userId,
    chunk = 0,
    byMediaId = {},
    pendingLists = nil,
    hasNextChunk = false,
    inFlight = false,
    done = false,
    error = nil,
    loadedCount = 0,
    needsMerge = false,
    awaitingChunk = true,
  }
end

local function publishFetchProgress(fetch)
  if fetch.mode == "reload" and fetch.single then
    local job = fetch.single
    local loaded = job.loadedCount or 0
    if job.mediaType == "ANIME" then
      local mangaLoaded = type(snapshot.loadProgress) == "table" and snapshot.loadProgress.mangaLoaded or 0
      setLoadProgress(loaded, mangaLoaded)
    else
      local animeLoaded = type(snapshot.loadProgress) == "table" and snapshot.loadProgress.animeLoaded or 0
      setLoadProgress(animeLoaded, loaded)
    end
    publishSnapshot()
    return
  end

  local animeLoaded = fetch.anime and (fetch.anime.loadedCount or 0) or 0
  local mangaLoaded = fetch.manga and (fetch.manga.loadedCount or 0) or 0
  setLoadProgress(animeLoaded, mangaLoaded)
  publishSnapshot()
end

local function startChunkFetch(job)
  if job.inFlight or job.done or job.error or not job.awaitingChunk then
    return false
  end

  job.awaitingChunk = false
  job.inFlight = true
  local started = graphqlRequest(LIST_QUERY, {
    userId = job.userId,
    type = job.mediaType,
    chunk = job.chunk,
    perChunk = CHUNK_SIZE,
  }, function(data, err)
    job.inFlight = false
    if not data then
      job.error = err
      job.done = true
      return
    end
    local collection = data.MediaListCollection
    job.pendingLists = collection and collection.lists or {}
    job.hasNextChunk = collection and collection.hasNextChunk == true
    job.needsMerge = true
    syncUpdateInterval()
  end)

  if not started then
    job.inFlight = false
    job.awaitingChunk = true
    job.error = tr("network_error")
    job.done = true
    return false
  end

  return true
end

local function beginFinalize(fetch)
  if fetch.mode == "reload" and fetch.single then
    local job = fetch.single
    if job.error then
      snapshot.refreshing = false
      setLoadError(job.error)
      return
    end
    finalizeQueue = {
      mode = "reload",
      mediaType = job.mediaType,
      byMediaId = job.byMediaId,
      rows = {},
      keys = nil,
      keyIndex = 1,
      phase = "keys",
    }
  else
    local animeJob = fetch.anime
    local mangaJob = fetch.manga
    for _, job in ipairs({ animeJob, mangaJob }) do
      if job.error then
        setLoadError(job.error)
        return
      end
    end
    finalizeQueue = {
      mode = "full",
      animeByMediaId = animeJob.byMediaId,
      mangaByMediaId = mangaJob.byMediaId,
      animeRows = {},
      mangaRows = {},
      phase = "anime_keys",
      keys = nil,
      keyIndex = 1,
    }
  end

  libraryFetch = nil
  clearLoadProgress()
  syncUpdateInterval()
end

local function finishFinalize(queue)
  if queue.mode == "reload" then
    if queue.mediaType == "ANIME" then
      snapshot.anime = queue.rows
    else
      snapshot.manga = queue.rows
    end
    snapshot.refreshing = false
  else
    snapshot.anime = queue.animeRows
    snapshot.manga = queue.mangaRows
    snapshot.loading = false
    pendingLegacyPurge = not legacyCachePurged
  end

  snapshot.error = ""
  finalizeQueue = nil
  resetBackgroundCovers()
  queuePriorityCovers(lastCoverPriority)
  publishSnapshot()
  syncUpdateInterval()
end

local function processFinalizeQueue()
  if finalizeQueue == nil then
    return
  end

  local queue = finalizeQueue

  if queue.mode == "reload" then
    if queue.phase == "keys" then
      queue.keys = sortedKeysFor(queue.byMediaId)
      queue.phase = "rows"
      queue.keyIndex = 1
      return
    end
    queue.keyIndex = appendSortedRows(queue.rows, queue.byMediaId, queue.keys, queue.keyIndex, FINALIZE_SORT_BATCH)
    if queue.keyIndex <= #queue.keys then
      return
    end
    finishFinalize(queue)
    return
  end

  if queue.phase == "anime_keys" then
    queue.keys = sortedKeysFor(queue.animeByMediaId)
    queue.phase = "anime"
    queue.keyIndex = 1
    return
  end

  if queue.phase == "anime" then
    queue.keyIndex = appendSortedRows(queue.animeRows, queue.animeByMediaId, queue.keys, queue.keyIndex, FINALIZE_SORT_BATCH)
    if queue.keyIndex <= #queue.keys then
      return
    end
    queue.phase = "manga_keys"
    return
  end

  if queue.phase == "manga_keys" then
    queue.keys = sortedKeysFor(queue.mangaByMediaId)
    queue.phase = "manga"
    queue.keyIndex = 1
    return
  end

  if queue.phase == "manga" then
    queue.keyIndex = appendSortedRows(queue.mangaRows, queue.mangaByMediaId, queue.keys, queue.keyIndex, FINALIZE_SORT_BATCH)
    if queue.keyIndex <= #queue.keys then
      return
    end
    finishFinalize(queue)
  end
end

local function fetchReadyToFinalize(fetch)
  if fetch.mode == "reload" then
    local job = fetch.single
    return job ~= nil and (job.error ~= nil or job.done)
  end

  local anime = fetch.anime
  local manga = fetch.manga
  if not anime or not manga then
    return false
  end
  if anime.error ~= nil or manga.error ~= nil then
    return true
  end
  return anime.done and manga.done
end

local function processFetchJob(job, fetch)
  if job.needsMerge then
    mergeListsInto(job.byMediaId, job.pendingLists, job.mediaType)
    job.pendingLists = nil
    job.needsMerge = false
    local total = 0
    for _ in pairs(job.byMediaId) do
      total += 1
    end
    job.loadedCount = total
    publishFetchProgress(fetch)

    if job.hasNextChunk then
      job.chunk += 1
      job.awaitingChunk = true
    else
      job.done = true
    end
  end
end

local function pickNextFetchJob(fetch)
  if fetch.mode == "reload" then
    return fetch.single
  end

  local anime = fetch.anime
  local manga = fetch.manga
  if anime and anime.awaitingChunk and not anime.inFlight and not anime.done and anime.error == nil then
    return anime
  end
  if manga and manga.awaitingChunk and not manga.inFlight and not manga.done and manga.error == nil then
    return manga
  end
  return nil
end

local function processLibraryFetch()
  if libraryFetch == nil then
    return
  end

  local fetch = libraryFetch

  if fetch.mode == "reload" then
    processFetchJob(fetch.single, fetch)
  else
    processFetchJob(fetch.anime, fetch)
    processFetchJob(fetch.manga, fetch)
  end

  if fetchReadyToFinalize(fetch) then
    beginFinalize(fetch)
    return
  end

  local nextJob = pickNextFetchJob(fetch)
  if nextJob then
    startChunkFetch(nextJob)
  end
end

local function loadLibrary()
  if accessToken == "" then
    snapshot.viewer = nil
    snapshot.anime = {}
    snapshot.manga = {}
    snapshot.loading = false
    snapshot.oauthLoading = false
    snapshot.error = ""
    clearLoadProgress()
    libraryFetch = nil
    publishSnapshot()
    return
  end

  snapshot.oauthLoading = false
  snapshot.loading = true
  snapshot.error = ""
  setLoadProgress(0, 0)
  libraryFetch = nil
  finalizeQueue = nil
  publishSnapshot()
  syncUpdateInterval()

  graphqlRequest(VIEWER_QUERY, nil, function(data, err)
    if not data or not data.Viewer then
      setLoadError(err or tr("invalid_token"))
      return
    end

    viewer = data.Viewer
    snapshot.viewer = viewer
    publishSnapshot()

    libraryFetch = {
      mode = "full",
      anime = newFetchJob("ANIME", viewer.id),
      manga = newFetchJob("MANGA", viewer.id),
    }
    syncUpdateInterval()
  end)
end

local function reloadMediaType(mediaType, silent)
  if accessToken == "" then
    return
  end

  if mediaType ~= "ANIME" and mediaType ~= "MANGA" then
    loadLibrary()
    return
  end

  if not viewer or not viewer.id then
    loadLibrary()
    return
  end

  if snapshot.loading or snapshot.refreshing or snapshot.busy or libraryFetch ~= nil then
    return
  end

  if not silent then
    snapshot.refreshing = true
  end
  snapshot.error = ""
  if not silent then
    setLoadProgress(0, 0)
  end
  publishSnapshot()
  syncUpdateInterval()

  libraryFetch = {
    mode = "reload",
    single = newFetchJob(mediaType, viewer.id),
  }
end

local function applyProgressDelta(mediaId, delta, forceStatus, forcedProgress)
  if snapshot.busy then
    return
  end

  local entry = findEntry(mediaId)
  if not entry then
    return
  end

  local total = entry.total
  local nextProgress = forcedProgress
  local nextStatus = forceStatus or entry.status

  if nextProgress == nil then
    nextProgress = math.max(0, (entry.progress or 0) + delta)
    nextStatus = entry.status

    if delta < 0 and entry.status == "COMPLETED" then
      if not total or nextProgress < total then
        nextStatus = "CURRENT"
      end
    end

    if total and nextProgress >= total then
      nextProgress = total
      nextStatus = "COMPLETED"
    elseif delta > 0 and entry.status == "PLANNING" then
      nextStatus = "CURRENT"
    end
  end

  snapshot.busy = true
  publishSnapshot()

  graphqlRequest(SAVE_PROGRESS_MUTATION, {
    mediaId = mediaId,
    progress = nextProgress,
    status = nextStatus,
  }, function(data, err)
    snapshot.busy = false
    if not data or not data.SaveMediaListEntry then
      setError(err or tr("mutation_failed"))
      return
    end

    local saved = data.SaveMediaListEntry
    entry.progress = tonumber(saved.progress) or nextProgress
    entry.status = saved.status or nextStatus
    if saved.media then
      entry.total = mediaTotal(saved.media)
    end
    publishSnapshot()
  end)
end

local function clientCredentials()
  local clientId = noctalia.getConfig("client_id")
  local clientSecret = noctalia.getConfig("client_secret")
  if type(clientId) ~= "string" then clientId = "" end
  if type(clientSecret) ~= "string" then clientSecret = "" end
  clientId = trim(clientId)
  clientSecret = trim(clientSecret)
  return clientId, clientSecret
end

local function setToken(token)
  token = trim(token)
  if token == "" then
    accessToken = ""
    clearStoredToken()
    viewer = nil
    snapshot.viewer = nil
    snapshot.anime = {}
    snapshot.manga = {}
    snapshot.error = ""
    snapshot.oauthLoading = false
    snapshot.loading = false
    clearLoadProgress()
    libraryFetch = nil
    finalizeQueue = nil
    publishSnapshot()
    return
  end

  accessToken = token
  writeStoredToken(token)
  loadLibrary()
end

local function finishOAuth()
  if oauthCredPath ~= "" then
    noctalia.removeFile(oauthCredPath)
  end
  if oauthResultPath ~= "" then
    noctalia.removeFile(oauthResultPath)
  end
  oauthRunning = false
  oauthCredPath = ""
  oauthResultPath = ""
  oauthStartedAt = 0
  snapshot.oauthLoading = false
  noctalia.setUpdateInterval(30000)
end

local function handleOAuthPayload(parsed)
  if type(parsed) ~= "table" or parsed.ok == nil then
    return false
  end

  finishOAuth()
  if parsed.ok == true and type(parsed.access_token) == "string" then
    setToken(parsed.access_token)
    return true
  end

  setError(tostring(parsed.error or tr("oauth_failed")))
  return true
end

local function oauthResultPathForPoll()
  if oauthResultPath ~= "" then
    return oauthResultPath
  end
  local dataDir = noctalia.pluginDataDir()
  if not dataDir then
    return ""
  end
  return dataDir .. "/" .. OAUTH_RESULT_FILE
end

local function startOAuthLogin()
  if oauthRunning then
    setError(tr("oauth_busy"))
    return
  end

  snapshot.error = ""

  local clientId, clientSecret = clientCredentials()
  if clientId == "" or clientSecret == "" then
    setError(tr("not_configured"))
    return
  end

  if not noctalia.commandExists("python3") then
    setError(tr("oauth_unavailable"))
    return
  end

  local pluginDir = noctalia.pluginDir()
  if not pluginDir then
    setError(tr("oauth_unavailable"))
    return
  end

  local dataDir = noctalia.pluginDataDir()
  if not dataDir then
    setError(tr("oauth_unavailable"))
    return
  end

  local credPath = dataDir .. "/" .. OAUTH_CREDS_FILE
  local resultPath = dataDir .. "/" .. OAUTH_RESULT_FILE
  noctalia.removeFile(resultPath)

  local credOk = noctalia.writeFile(credPath, noctalia.json.encode({
    client_id = clientId,
    client_secret = clientSecret,
  }))
  if not credOk then
    setError(tr("oauth_unavailable"))
    return
  end

  local scriptPath = pluginDir .. "/scripts/oauth_login.py"
  local python = if noctalia.commandExists("stdbuf")
    then "stdbuf -oL -eL python3 -u"
    else "python3 -u"
  local command = python
    .. " "
    .. shellQuote(scriptPath)
    .. " "
    .. shellQuote(credPath)
    .. " "
    .. shellQuote(resultPath)

  oauthRunning = true
  oauthCredPath = credPath
  oauthResultPath = resultPath
  oauthStartedAt = os.clock()
  snapshot.oauthLoading = true
  snapshot.loading = false
  snapshot.error = ""
  clearLoadProgress()
  publishSnapshot()
  noctalia.setUpdateInterval(OAUTH_POLL_MS)

  local function handleOAuthLine(line)
    line = trim(line or "")
    if line == "" then
      return
    end

    local ok, parsed = pcall(noctalia.json.decode, line)
    if ok then
      handleOAuthPayload(parsed)
    end
  end

  local started = noctalia.runStream(command, handleOAuthLine)
  if not started then
    finishOAuth()
    setError(tr("oauth_unavailable"))
  end
end

local function pollOAuthResult()
  if not oauthRunning and not snapshot.oauthLoading then
    return
  end

  local path = oauthResultPathForPoll()
  if path == "" then
    return
  end

  local raw = noctalia.readFile(path)
  if raw and raw ~= "" then
    local ok, parsed = pcall(noctalia.json.decode, raw)
    if ok and handleOAuthPayload(parsed) then
      return
    end
  end

  if oauthRunning and oauthStartedAt > 0 and (os.clock() - oauthStartedAt) > 185 then
    finishOAuth()
    setError(tr("oauth_failed"))
  end
end

function update()
  if oauthRunning or snapshot.oauthLoading then
    noctalia.setUpdateInterval(OAUTH_POLL_MS)
  end

  pollOAuthResult()

  if pendingLegacyPurge then
    pendingLegacyPurge = false
    purgeLegacyCoverCache()
  end

  processLibraryFetch()
  processFinalizeQueue()
  processPriorityCovers()
  processBackgroundCovers()

  if activeCoverDownloads > 0 then
    flushCoverSnapshot()
  end
end

local function loginWithInput(input)
  input = trim(input)
  if input == "" then
    return
  end

  if input:sub(1, 3) == "eyJ" then
    setToken(input)
    return
  end

  setError(tr("oauth_failed"))
end

local function processCommand(command)
  if type(command) ~= "table" then
    return
  end

  local action = command.action
  if action == "refresh" then
    local mediaType = tostring(command.mediaType or "")
    local silent = command.silent == true
    if mediaType == "ANIME" or mediaType == "MANGA" then
      reloadMediaType(mediaType, silent)
    else
      loadLibrary()
    end
  elseif action == "start_oauth" then
    startOAuthLogin()
  elseif action == "login" then
    loginWithInput(tostring(command.token or ""))
  elseif action == "logout" then
    setToken("")
  elseif action == "prioritize_covers" then
    local ids = {}
    if type(command.mediaIds) == "table" then
      for _, id in ipairs(command.mediaIds) do
        local mediaId = tonumber(id)
        if mediaId then
          table.insert(ids, mediaId)
        end
      end
    end
    lastCoverPriority = ids
    queuePriorityCovers(lastCoverPriority)
  elseif action == "increment" then
    applyProgressDelta(tonumber(command.mediaId), 1, nil)
  elseif action == "decrement" then
    applyProgressDelta(tonumber(command.mediaId), -1, nil)
  elseif action == "complete" then
    local mediaId = tonumber(command.mediaId)
    local entry = mediaId and findEntry(mediaId) or nil
    if entry then
      applyProgressDelta(mediaId, 0, "COMPLETED", entry.total or entry.progress or 0)
    end
  elseif action == "open_media" then
    local mediaId = tonumber(command.mediaId)
    local mediaType = tostring(command.mediaType or "ANIME"):lower()
    if mediaId then
      local segment = if mediaType == "manga" then "manga" else "anime"
      noctalia.runAsync("xdg-open " .. shellQuote("https://anilist.co/" .. segment .. "/" .. mediaId) .. " >/dev/null 2>&1")
    end
  end
end

noctalia.state.watch("anilist_command", function(command)
  processCommand(command)
end)

function onIpc(event, payload)
  if event == "refresh" then
    loadLibrary()
  elseif event == "logout" then
    setToken("")
  elseif event == "login" and type(payload) == "string" then
    loginWithInput(payload)
  end
end

function init()
  if not legacyCachePurged then
    purgeLegacyCoverCache()
  end
  accessToken = resolveToken()
  publishSnapshot()
  if accessToken ~= "" then
    loadLibrary()
  end
end

init()
