--!nonstrict

local DEFAULT_MAX_RESULTS = 50
local DEFAULT_FUZZY_CANDIDATE_LIMIT = 150
local MAX_CANDIDATES = 500
local CANDIDATE_MULTIPLIER = 4
local MIN_FUZZY_QUERY_LENGTH = 3

local TYPE_ALIASES = {
  any = "any",
  file = "file",
  f = "file",
  directory = "directory",
  dir = "directory",
  d = "directory",
}

local dataDir = noctalia.pluginDataDir()
local database = dataDir ~= nil and dataDir .. "/home.db" or nil
local pathsCache = dataDir ~= nil and dataDir .. "/paths.cache" or nil
local queryGeneration = 0

local function shellQuote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function buildExactCommand(request, limit)
  return "locate -d " .. shellQuote(database)
    .. " -0 -e -i -l " .. tostring(limit) .. " -- " .. shellQuote(request.text)
end

local function buildFuzzyCommand(request, limit)
  return "fzf --read0 --print0 --scheme=path --filter=" .. shellQuote(request.text)
    .. " < " .. shellQuote(pathsCache) .. " | head -z -n " .. tostring(limit)
end

local function showStatus(query, titleKey, glyph, subtitle)
  launcher.setResults(query, {
    {
      id = "",
      title = noctalia.tr(titleKey),
      subtitle = subtitle,
      glyph = glyph,
    },
  })
end

local function parseFlags(rawFlags)
  local flags = {}
  for flag in rawFlags:gmatch("%S+") do
    table.insert(flags, flag)
  end

  local options = { hidden = false, kind = "any", forceFuzzy = false }
  local i = 1
  while i <= #flags do
    local flag = flags[i]
    if flag == "--hidden" or flag == "-h" then
      options.hidden = true
    elseif flag == "--fuzzy" then
      options.forceFuzzy = true
    elseif flag == "--type" or flag == "-t" then
      i += 1
      if flags[i] == nil then
        return nil, noctalia.tr("launcher.flags.type_missing")
      end
      options.kind = flags[i]
    else
      local kind = flag:match("^%-%-type=(.+)$")
      if kind == nil then
        return nil, noctalia.tr("launcher.flags.unknown", { flag = flag })
      end
      options.kind = kind
    end
    i += 1
  end

  local normalizedKind = TYPE_ALIASES[options.kind]
  if normalizedKind == nil then
    return nil, noctalia.tr("launcher.flags.type_invalid", { value = options.kind })
  end
  options.kind = normalizedKind
  return options, nil
end

local function parseRequest(query, generation)
  local input = noctalia.string.trim(query)
  local text, rawFlags = input:match("^(.-)%s+%-%-%s*(.*)$")
  if text == nil then
    text = input
    rawFlags = ""
  end

  local options, err = parseFlags(rawFlags)
  if err ~= nil then
    return nil, err
  end

  local fuzzyMode = noctalia.getConfig("fuzzy_mode") or "fallback"
  if fuzzyMode ~= "fallback" and fuzzyMode ~= "always" and fuzzyMode ~= "off" then
    fuzzyMode = "fallback"
  end

  return {
    query = query,
    text = noctalia.string.trim(text),
    hidden = options.hidden,
    kind = options.kind,
    forceFuzzy = options.forceFuzzy,
    fuzzyMode = fuzzyMode,
    maxResults = noctalia.getConfig("max_results") or DEFAULT_MAX_RESULTS,
    generation = generation,
  }, nil
end

local function isCurrent(request)
  return request.generation == queryGeneration
end

local function fuzzyEligible(request)
  return #request.text >= MIN_FUZZY_QUERY_LENGTH
end

local function fuzzyCandidateLimit()
  local configured = tonumber(noctalia.getConfig("fuzzy_candidate_limit")) or DEFAULT_FUZZY_CANDIDATE_LIMIT
  return math.max(100, math.min(math.floor(configured), 200))
end

local function exactCandidateLimit(request)
  local needsFiltering = not request.hidden or request.kind ~= "any"
  local multiplier = needsFiltering and CANDIDATE_MULTIPLIER or 1
  return math.min(request.maxResults * multiplier, MAX_CANDIDATES)
end

local function kindMatches(kind, info)
  if kind == "any" then
    return true
  end
  return info ~= nil and (kind == "directory") == info.isDir
end

local function needsFileInfo(request)
  if request.kind ~= "any" then
    return true
  end
  return (tonumber(noctalia.getConfig("file_weight")) or 0) ~= 0
    or (tonumber(noctalia.getConfig("directory_weight")) or 0) ~= 0
end

local function pathTitle(path)
  local cleanPath = path == "/" and path or path:gsub("/+$", "")
  return cleanPath:match("([^/]+)$") or cleanPath
end

local function scoreCandidate(path, request, source, rank, candidateLimit, info)
  local filenameScore = noctalia.fuzzyScore(request.text, pathTitle(path))
  local pathScore = noctalia.fuzzyScore(request.text, path)
  local lexicalScore
  if filenameScore ~= nil then
    lexicalScore = filenameScore * 5 + (pathScore or 0) * 0.25
  elseif pathScore ~= nil then
    lexicalScore = pathScore
  else
    return nil
  end

  local rankBonus = 0
  if source == "fuzzy" then
    rankBonus = (candidateLimit - rank + 1) / candidateLimit * 2
  end

  local typeWeight = 0
  if info ~= nil then
    typeWeight = tonumber(noctalia.getConfig(info.isDir and "directory_weight" or "file_weight")) or 0
  end

  return lexicalScore + rankBonus + typeWeight + (tonumber(noctalia.getConfig("global_score_bias")) or -100)
end

local function collectResults(stdout, request, source, candidateLimit)
  local rows = {}
  local needsInfo = needsFileInfo(request)
  local rank = 0
  for path in stdout:gmatch("([^%z]+)") do
    rank += 1
    local hidden = path:find("/%.") ~= nil
    if request.hidden or not hidden then
      local info = needsInfo and noctalia.fileInfo(path) or nil
      if kindMatches(request.kind, info) then
        local score = scoreCandidate(path, request, source, rank, candidateLimit, info)
        if score ~= nil then
          table.insert(rows, {
            id = path,
            title = pathTitle(path),
            subtitle = path,
            glyph = info ~= nil and info.isDir and "folder" or "file",
            score = score,
            rank = rank,
          })
        end
      end
    end
  end
  table.sort(rows, function(a, b)
    if a.score == b.score then
      return a.rank < b.rank
    end
    return a.score > b.score
  end)
  while #rows > request.maxResults do
    table.remove(rows)
  end
  for _, row in ipairs(rows) do
    row.rank = nil
  end
  return rows
end

local function searchFailed(result)
  return result.timedOut or (result.exitCode ~= 0 and noctalia.string.trim(result.stderr) ~= "")
end

local function publishRows(rows, request)
  if not isCurrent(request) then
    return
  end
  if #rows > 0 then
    launcher.setResults(request.query, rows)
  else
    showStatus(request.query, "launcher.no_results", "file-off", request.text)
  end
end

local function startFuzzySearch(request)
  if not fuzzyEligible(request) then
    if isCurrent(request) then
      showStatus(request.query, "launcher.fuzzy_too_short", "search", noctalia.tr("launcher.fuzzy_too_short_subtitle"))
    end
    return
  end
  if not noctalia.commandExists("fzf") then
    if isCurrent(request) then
      showStatus(request.query, "launcher.error", "alert-triangle", "fzf is not installed")
    end
    return
  end

  local candidateLimit = fuzzyCandidateLimit()
  local started = noctalia.runAsync(buildFuzzyCommand(request, candidateLimit), function(result)
    if not isCurrent(request) then
      return
    end
    if searchFailed(result) then
      showStatus(request.query, "launcher.error", "alert-triangle", noctalia.string.trim(result.stderr))
      return
    end
    publishRows(collectResults(result.stdout, request, "fuzzy", candidateLimit), request)
  end)
  if not started and isCurrent(request) then
    showStatus(request.query, "launcher.error", "alert-triangle", nil)
  end
end

local function startExactSearch(request)
  local candidateLimit = exactCandidateLimit(request)
  local started = noctalia.runAsync(buildExactCommand(request, candidateLimit), function(result)
    if not isCurrent(request) then
      return
    end
    if searchFailed(result) then
      showStatus(request.query, "launcher.error", "alert-triangle", noctalia.string.trim(result.stderr))
      return
    end

    local rows = collectResults(result.stdout, request, "exact", candidateLimit)
    if #rows == 0 and request.fuzzyMode == "fallback" and fuzzyEligible(request) then
      startFuzzySearch(request)
      return
    end
    publishRows(rows, request)
  end)
  if not started and isCurrent(request) then
    showStatus(request.query, "launcher.error", "alert-triangle", nil)
  end
end

local function startSearch(request)
  if request.forceFuzzy or request.fuzzyMode == "always" then
    startFuzzySearch(request)
  else
    startExactSearch(request)
  end
end

function onQuery(query)
  queryGeneration += 1
  local generation = queryGeneration
  if noctalia.string.trim(query) == "--reindex" then
    launcher.setResults(query, {
      {
        id = "action:reindex",
        title = noctalia.tr("launcher.reindex"),
        subtitle = noctalia.tr("launcher.reindex_subtitle"),
        glyph = "database-cog",
      },
    })
    return
  end

  local request, parseError = parseRequest(query, generation)
  if parseError ~= nil then
    showStatus(query, "launcher.flags.error", "alert-triangle", parseError)
    return
  end

  if request.text == "" then
    showStatus(query, "launcher.hint", "search", noctalia.tr("launcher.hint_subtitle"))
    return
  end

  local requiresFuzzy = request.forceFuzzy or request.fuzzyMode == "always"
  if requiresFuzzy and not fuzzyEligible(request) then
    showStatus(query, "launcher.fuzzy_too_short", "search", noctalia.tr("launcher.fuzzy_too_short_subtitle"))
    return
  end

  if not noctalia.commandExists("locate") then
    showStatus(query, "launcher.missing", "alert-triangle", noctalia.tr("launcher.missing_subtitle"))
    return
  end

  local indexStatus = noctalia.state.get("index_status")
  local requiresRebuild = noctalia.state.get("index_requires_rebuild") == true
  if database == nil or pathsCache == nil or not noctalia.fileExists(database) or not noctalia.fileExists(pathsCache) or requiresRebuild then
    local failed = indexStatus == "error"
    local titleKey = failed and "launcher.index_error" or "launcher.index_building"
    local subtitle = failed and noctalia.state.get("index_detail") or noctalia.tr("launcher.index_building_subtitle")
    showStatus(query, titleKey, failed and "alert-triangle" or "database-cog", subtitle)
    return
  end

  showStatus(query, "launcher.searching", "loader", nil)
  startSearch(request)
end

function onActivate(path)
  if path == "action:reindex" then
    local request = noctalia.state.get("reindex_request") or 0
    noctalia.state.set("reindex_request", request + 1)
    noctalia.notify(noctalia.tr("title"), noctalia.tr("launcher.reindex_started"))
    return
  end
  if path ~= "" and not noctalia.runAsync("xdg-open " .. shellQuote(path)) then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("launcher.open_error"))
  end
end
