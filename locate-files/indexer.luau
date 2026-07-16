--!nonstrict

local ACTIVE_POLL_MS = 5000

local dataDir = noctalia.pluginDataDir()
local pluginDir = noctalia.pluginDir()
local home = noctalia.getenv("HOME")

local database = dataDir ~= nil and dataDir .. "/home.db" or nil
local pathsCache = dataDir ~= nil and dataDir .. "/paths.cache" or nil
local statusFile = dataDir ~= nil and dataDir .. "/index.status" or nil
local metadataFile = dataDir ~= nil and dataDir .. "/index-metadata.json" or nil
local helper = pluginDir ~= nil and pluginDir .. "/update-index.sh" or nil

local indexing = false
local pending = false
local sequence = 0
local activeToken = nil
local activeSignature = nil

local function shellQuote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function normalizePath(value)
  local path = noctalia.string.trim(value)
  if path == "" then
    return nil
  end
  if path:sub(1, 1) ~= "/" and path:sub(1, 1) ~= "~" then
    path = home .. "/" .. path
  end
  path = noctalia.expandPath(path)
  if path ~= "/" then
    path = path:gsub("/+$", "")
  end
  return path
end

local function isWithin(path, root)
  return root == "/" or path == root or path:sub(1, #root + 1) == root .. "/"
end

local function configuredPrunes()
  local paths = {}
  for _, value in ipairs(noctalia.getConfig("blacklist_paths") or {}) do
    local path = normalizePath(value)
    if path ~= nil and isWithin(path, home) then
      local redundant = false
      for i = #paths, 1, -1 do
        if isWithin(path, paths[i]) then
          redundant = true
          break
        end
        if isWithin(paths[i], path) then
          table.remove(paths, i)
        end
      end
      if not redundant then
        table.insert(paths, path)
      end
    end
  end

  if dataDir ~= nil and isWithin(dataDir, home) then
    table.insert(paths, dataDir)
  end
  table.sort(paths)
  return paths
end

local function configuredPruneNames()
  local names = {}
  local seen = {}
  for _, value in ipairs(noctalia.getConfig("blacklist_names") or {}) do
    local name = noctalia.string.trim(value)
    if name ~= "" and not name:find("/") and not name:find("%s") and not seen[name] then
      seen[name] = true
      table.insert(names, name)
    end
  end
  table.sort(names)
  return names
end

local function configSignature(prunes, pruneNames)
  return noctalia.json.encode({ root = home, prunes = prunes, pruneNames = pruneNames, formatVersion = 3 }) or ""
end

local function readStatus()
  local raw = statusFile ~= nil and noctalia.readFile(statusFile) or nil
  if raw == nil then
    return nil, nil, nil
  end
  local status, token, detail = noctalia.string.trim(raw):match("^([^|]+)|([^|]+)|?(.*)$")
  return status, token, detail
end

local function publish(status, detail)
  noctalia.state.set("index_status", status)
  noctalia.state.set("index_detail", detail or "")
end

local function readMetadata()
  local raw = metadataFile ~= nil and noctalia.readFile(metadataFile) or nil
  if raw == nil then
    return nil
  end
  local value = noctalia.json.decode(raw)
  return type(value) == "table" and value or nil
end

local function saveMetadata(signature)
  local metadata = {
    signature = signature,
    builtAt = tonumber(noctalia.formatTime("%s")) or 0,
  }
  local encoded = noctalia.json.encode(metadata, true)
  if encoded ~= nil then
    noctalia.writeFile(metadataFile, encoded)
  end
end

local function buildCommand(token, prunes, pruneNames)
  local parts = {
    "sh",
    shellQuote(helper),
    shellQuote(database),
    shellQuote(pathsCache),
    shellQuote(statusFile),
    shellQuote(token),
    "updatedb",
    "--require-visibility", "no",
    "--database-root", shellQuote(home),
    "--output", shellQuote(database .. ".tmp." .. token),
    "--prunenames", "''",
    "--prunepaths", "''",
  }
  for _, path in ipairs(prunes) do
    table.insert(parts, "--add-single-prunepath")
    table.insert(parts, shellQuote(path))
  end
  for _, name in ipairs(pruneNames) do
    table.insert(parts, "--add-prunenames")
    table.insert(parts, shellQuote(name))
  end
  return table.concat(parts, " ")
end

local function startIndex()
  if indexing then
    pending = true
    return
  end
  if database == nil or pathsCache == nil or statusFile == nil or metadataFile == nil or helper == nil or home == nil then
    publish("error", "plugin directories are unavailable")
    return
  end
  if not noctalia.commandExists("updatedb") or not noctalia.commandExists("locate") or not noctalia.commandExists("flock") then
    publish("error", "updatedb, locate, or flock is not installed")
    return
  end

  local prunes = configuredPrunes()
  local pruneNames = configuredPruneNames()
  sequence += 1
  activeToken = noctalia.formatTime("%s") .. "-" .. tostring(sequence)
  activeSignature = configSignature(prunes, pruneNames)
  indexing = true
  publish("building", "")
  noctalia.setUpdateInterval(ACTIVE_POLL_MS)

  if not noctalia.runAsync(buildCommand(activeToken, prunes, pruneNames)) then
    indexing = false
    publish("error", "could not start updatedb")
  end
end

local function indexHasCurrentConfig()
  if database == nil or pathsCache == nil or not noctalia.fileExists(database) or not noctalia.fileExists(pathsCache) then
    return false
  end
  local metadata = readMetadata()
  if metadata == nil then
    return false
  end
  local signature = configSignature(configuredPrunes(), configuredPruneNames())
  if metadata.signature ~= signature then
    return false
  end
  return true
end

local function indexIsCurrent()
  if not indexHasCurrentConfig() then
    return false
  end
  local metadata = readMetadata()
  local refreshMinutes = noctalia.getConfig("index_refresh_minutes") or 60
  local now = tonumber(noctalia.formatTime("%s")) or 0
  return now - (metadata.builtAt or 0) < refreshMinutes * 60
end

local function scheduleIdlePoll()
  local metadata = readMetadata()
  if metadata == nil or metadata.builtAt == nil then
    noctalia.setUpdateInterval(60000)
    return
  end
  local refreshMinutes = noctalia.getConfig("index_refresh_minutes") or 60
  local refreshMs = refreshMinutes * 60 * 1000
  local now = tonumber(noctalia.formatTime("%s")) or 0
  local elapsedMs = (now - metadata.builtAt) * 1000
  local remainingMs = refreshMs - elapsedMs
  if remainingMs <= 0 then
    noctalia.setUpdateInterval(1000)
    return
  end
  noctalia.setUpdateInterval(remainingMs)
end

local function ensureIndex()
  if not indexing and not indexIsCurrent() then
    if not indexHasCurrentConfig() then
      noctalia.state.set("index_requires_rebuild", true)
    end
    startIndex()
  end
end

function update()
  local status, token, detail = readStatus()
  if indexing and status == "ready" then
    indexing = false
    if token == activeToken and activeSignature ~= nil then
      saveMetadata(activeSignature)
    end
    local currentSignature = configSignature(configuredPrunes(), configuredPruneNames())
    local matchesCurrentConfig = token == activeToken and activeSignature == currentSignature
    if pending or not matchesCurrentConfig then
      noctalia.state.set("index_requires_rebuild", true)
    else
      noctalia.state.set("index_requires_rebuild", false)
      publish("ready", "")
    end
  elseif indexing and status == "error" then
    indexing = false
    publish("error", detail)
  elseif status == "running" then
    publish("building", "")
  end

  if not indexing and pending then
    pending = false
    startIndex()
    return
  end

  ensureIndex()
  if indexing then
    noctalia.setUpdateInterval(ACTIVE_POLL_MS)
  else
    scheduleIdlePoll()
  end
end

function onConfigChanged()
  if not indexIsCurrent() then
    noctalia.state.set("index_requires_rebuild", true)
    startIndex()
  end
end

function onIpc(event, _payload)
  if event == "reindex" then
    startIndex()
  end
end

noctalia.state.watch("reindex_request", function(_value)
  startIndex()
end)

publish("checking", "")
update()
