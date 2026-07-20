--!nonstrict
-- AniList background service: OAuth token storage, GraphQL queries, and list mutations.
-- The panel and widget only talk through noctalia.state; they never hit the network.

local GRAPHQL_URL = "https://graphql.anilist.co"
local TOKEN_FILE = "token.json"
local OAUTH_CREDS_FILE = "oauth_credentials.json"
local OAUTH_RESULT_FILE = "oauth_result.json"

local accessToken = ""
local viewer = nil
local snapshot = {
  revision = 0,
  loading = false,
  refreshing = false,
  busy = false,
  error = "",
  viewer = nil,
  anime = {},
  manga = {},
}
local oauthRunning = false
local oauthCredPath = ""
local oauthResultPath = ""
local oauthStartedAt = 0

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
  local parsed = noctalia.json.decode(raw)
  if type(parsed) == "table" and type(parsed.access_token) == "string" then
    return trim(parsed.access_token)
  end
  return ""
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

local function setError(message)
  snapshot.error = message or ""
  snapshot.loading = false
  snapshot.refreshing = false
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

local function flattenCollection(lists, mediaType)
  local byMediaId = {}
  if type(lists) ~= "table" then
    return {}
  end
  for _, list in ipairs(lists) do
    if type(list) == "table" and type(list.entries) == "table" then
      mergeEntries(byMediaId, list.entries, mediaType)
    end
  end
  local rows = {}
  for _, row in pairs(byMediaId) do
    table.insert(rows, row)
  end
  table.sort(rows, function(a, b)
    return (a.title or ""):lower() < (b.title or ""):lower()
  end)
  return rows
end

local COVER_DIR_NAME = "covers"
local COVER_CACHE_VERSION = 2
local coverDownloadsInFlight = {}
local coverLoadingIds = {}
local lastCoverPriority = {}
local activeCoverDownloads = 0
local pendingCoverSnapshot = false
local MAX_BACKGROUND_COVERS = 64
local MAX_PRIORITY_COVERS = 48

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
end

local function attachCoverPaths(rows)
  for _, row in ipairs(rows or {}) do
    local url = row.coverUrl
    if isCoverCacheValid(row.mediaId, url) then
      row.coverPath = coverCachePath(row.mediaId)
    else
      row.coverPath = nil
      if row.mediaId and url then
        removeCoverCache(row.mediaId)
      end
    end
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

local function setEntryCoverPath(mediaId, path)
  for _, list in ipairs({ snapshot.anime, snapshot.manga }) do
    for _, entry in ipairs(list) do
      if entry.mediaId == mediaId then
        entry.coverPath = path
        requestCoverSnapshot()
        return
      end
    end
  end
end

local function syncCoverDownloadInterval()
  if activeCoverDownloads > 0 then
    noctalia.setUpdateInterval(120)
  else
    noctalia.setUpdateInterval(30000)
    flushCoverSnapshot()
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

  local dir = coverCacheDir()
  if dir then
    noctalia.mkdirAll(dir)
  end

  coverDownloadsInFlight[mediaId] = true
  setCoverLoading(mediaId, true)
  activeCoverDownloads += 1
  syncCoverDownloadInterval()

  local started = noctalia.download(url, path, function(ok)
    coverDownloadsInFlight[mediaId] = nil
    setCoverLoading(mediaId, false)
    activeCoverDownloads = math.max(0, activeCoverDownloads - 1)
    if ok then
      writeCoverMeta(mediaId, url)
      setEntryCoverPath(mediaId, path)
    end
    syncCoverDownloadInterval()
  end)

  if not started then
    coverDownloadsInFlight[mediaId] = nil
    setCoverLoading(mediaId, false)
    activeCoverDownloads = math.max(0, activeCoverDownloads - 1)
    syncCoverDownloadInterval()
  end
end

local function queueCoverDownloads(priorityMediaIds)
  local prioritySet = {}
  local priorityEntries = {}
  local backgroundEntries = {}
  local downloadQueue = {}

  if type(priorityMediaIds) == "table" then
    for _, id in ipairs(priorityMediaIds) do
      local mediaId = tonumber(id)
      if mediaId and not prioritySet[mediaId] then
        prioritySet[mediaId] = true
        if #priorityEntries < MAX_PRIORITY_COVERS then
          local entry = findEntry(mediaId)
          if entry then
            table.insert(priorityEntries, entry)
          end
        end
      end
    end
  end

  local backgroundCount = 0
  for _, list in ipairs({ snapshot.anime, snapshot.manga }) do
    for _, entry in ipairs(list) do
      if not prioritySet[entry.mediaId] then
        backgroundCount += 1
        if backgroundCount <= MAX_BACKGROUND_COVERS then
          table.insert(backgroundEntries, entry)
        end
      end
    end
  end

  for _, entry in ipairs(priorityEntries) do
    table.insert(downloadQueue, entry)
  end
  for _, entry in ipairs(backgroundEntries) do
    table.insert(downloadQueue, entry)
  end

  for _, entry in ipairs(downloadQueue) do
    if needsCoverDownload(entry) and entry.mediaId then
      coverLoadingIds[entry.mediaId] = true
    end
  end
  publishCoverLoadingState()

  for _, entry in ipairs(downloadQueue) do
    downloadCoverForEntry(entry)
  end
end

local LIST_QUERY = [[
query ($userId: Int, $type: MediaType) {
  MediaListCollection(userId: $userId, type: $type, forceSingleCompletedList: true) {
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

local function decodeBody(body)
  if type(body) ~= "string" or body == "" then
    return nil, "empty response"
  end
  local ok, parsed = pcall(noctalia.json.decode, body)
  if not ok or type(parsed) ~= "table" then
    return nil, "invalid json"
  end
  if type(parsed.errors) == "table" and #parsed.errors > 0 then
    local message = parsed.errors[1].message or tr("mutation_failed")
    if message:lower():find("invalid token", 1, true) then
      return nil, tr("invalid_token")
    end
    return nil, message
  end
  return parsed.data, nil
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
    },
    body = body,
  }, function(response)
    if not response then
      callback(nil, tr("network_error"))
      return
    end
    if response.status < 200 or response.status >= 300 then
      callback(nil, tr("network_error"))
      return
    end
    local data, err = decodeBody(response.body)
    callback(data, err)
  end)
end

local function fetchMediaType(mediaType, userId, callback)
  graphqlRequest(LIST_QUERY, {
    userId = userId,
    type = mediaType,
  }, function(data, err)
    if not data then
      callback(nil, err)
      return
    end
    local collection = data.MediaListCollection
    local lists = collection and collection.lists or {}
    callback(flattenCollection(lists, mediaType), nil)
  end)
end

local function loadLibrary()
  if accessToken == "" then
    snapshot.viewer = nil
    snapshot.anime = {}
    snapshot.manga = {}
    snapshot.loading = false
    snapshot.error = ""
    publishSnapshot()
    return
  end

  snapshot.loading = true
  snapshot.error = ""
  publishSnapshot()

  graphqlRequest(VIEWER_QUERY, nil, function(data, err)
    if not data or not data.Viewer then
      setError(err or tr("invalid_token"))
      return
    end

    viewer = data.Viewer
    snapshot.viewer = viewer
    local userId = viewer.id

    local animeRows = nil
    local mangaRows = nil
    local fetchError = nil
    local pending = 2

    local function doneOne()
      pending -= 1
      if pending > 0 then
        return
      end
      if fetchError then
        setError(fetchError)
        return
      end
      snapshot.anime = animeRows or {}
      snapshot.manga = mangaRows or {}
      purgeLegacyCoverCache()
      attachCoverPaths(snapshot.anime)
      attachCoverPaths(snapshot.manga)
      queueCoverDownloads(lastCoverPriority)
      snapshot.loading = false
      snapshot.error = ""
      publishSnapshot()
    end

    fetchMediaType("ANIME", userId, function(rows, typeErr)
      if typeErr then
        fetchError = typeErr
      else
        animeRows = rows
      end
      doneOne()
    end)

    fetchMediaType("MANGA", userId, function(rows, typeErr)
      if typeErr then
        fetchError = typeErr
      else
        mangaRows = rows
      end
      doneOne()
    end)
  end)
end

local function reloadMediaType(mediaType)
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

  if snapshot.loading or snapshot.refreshing or snapshot.busy then
    return
  end

  snapshot.refreshing = true
  snapshot.error = ""
  publishSnapshot()

  fetchMediaType(mediaType, viewer.id, function(rows, err)
    snapshot.refreshing = false
    if err then
      snapshot.error = err
      publishSnapshot()
      return
    end

    if mediaType == "ANIME" then
      snapshot.anime = rows or {}
      attachCoverPaths(snapshot.anime)
    else
      snapshot.manga = rows or {}
      attachCoverPaths(snapshot.manga)
    end

    queueCoverDownloads(lastCoverPriority)
    snapshot.error = ""
    publishSnapshot()
  end)
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
    snapshot.loading = false
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

local function startOAuthLogin()
  if oauthRunning then
    setError(tr("oauth_busy"))
    return
  end

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
  local command = "python3 "
    .. shellQuote(scriptPath)
    .. " "
    .. shellQuote(credPath)
    .. " "
    .. shellQuote(resultPath)

  oauthRunning = true
  oauthCredPath = credPath
  oauthResultPath = resultPath
  oauthStartedAt = os.clock()
  snapshot.loading = true
  snapshot.error = ""
  publishSnapshot()
  noctalia.setUpdateInterval(500)

  local function handleOAuthLine(line)
    line = (line or ""):gsub("^%s+", ""):gsub("%s+$", "")
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
  if not oauthRunning or oauthResultPath == "" then
    return
  end

  local raw = noctalia.readFile(oauthResultPath)
  if raw and raw ~= "" then
    local ok, parsed = pcall(noctalia.json.decode, raw)
    if ok and handleOAuthPayload(parsed) then
      return
    end
  end

  if oauthStartedAt > 0 and (os.clock() - oauthStartedAt) > 185 then
    finishOAuth()
    setError(tr("oauth_failed"))
  end
end

function update()
  pollOAuthResult()
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
    if mediaType == "ANIME" or mediaType == "MANGA" then
      reloadMediaType(mediaType)
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
    queueCoverDownloads(lastCoverPriority)
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
  purgeLegacyCoverCache()
  accessToken = resolveToken()
  publishSnapshot()
  if accessToken ~= "" then
    loadLibrary()
  end
end

init()
