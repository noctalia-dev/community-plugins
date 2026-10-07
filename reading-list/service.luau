--!nonstrict
-- Reading List service
--
-- The library is an Obsidian-friendly folder. Every item is one Markdown file
-- with YAML frontmatter; downloaded favicons and covers live in .assets/.

noctalia.setUpdateInterval(30000)

local items = {}
local ready = false
local rootDir = nil
local itemsDir = nil
local assetsDir = nil
local exportsDir = nil
local collectionsPath = nil
local collections = {}
local fetching = {}
-- Sync polls still read each small note so external edits are detected, but
-- unchanged notes keep their parsed item instead of spending the callback's
-- CPU budget decoding the same frontmatter every 30 seconds.
local itemCache = {}
local lastError = ""

local VALID_TYPES = { article = true, book = true, image = true }
local VALID_STATUS = { unread = true, reading = true, read = true, archived = true }

local function completionTimestamp(status, existing, now)
  if status == "read" then return (existing or 0) > 0 and existing or now end
  if status == "archived" then return existing or 0 end
  return 0
end

local function trim(value)
  return noctalia.string.trim(type(value) == "string" and value or "")
end

local function validWebUrl(url)
  return type(url) == "string"
    and (url:match("^https://[^%s]+$") ~= nil or url:match("^http://[^%s]+$") ~= nil)
end

local function domainFromUrl(url)
  local host = type(url) == "string" and url:match("^https?://([^/%?#]+)") or nil
  if host == nil then return "" end
  return host:gsub(":%d+$", ""):gsub("^www%.", "")
end

local function normalizedUrl(url)
  local value = trim(url)
  if value:match("^//") then
    value = "https:" .. value
  elseif not validWebUrl(value)
      and (value:match("^[%w%-][%w%.%-]*[%.][%w%-]+$")
        or value:match("^[%w%-][%w%.%-]*[%.][%w%-]+[:/%?#]")
        or value:match("^localhost$") or value:match("^localhost[:/%?#]")) then
    value = "https://" .. value
  end
  value = value:gsub("#.*$", "")
  local question = value:find("?", 1, true)
  if question == nil then return value end
  local base = value:sub(1, question - 1)
  local query = value:sub(question + 1)
  local kept = {}
  for parameter in query:gmatch("[^&]+") do
    local key = (parameter:match("^([^=]+)") or parameter):lower()
    if key:sub(1, 4) ~= "utm_" and key ~= "fbclid" and key ~= "gclid" then
      table.insert(kept, parameter)
    end
  end
  return #kept > 0 and (base .. "?" .. table.concat(kept, "&")) or base
end

local function makeId()
  return tostring(math.floor(noctalia.nowMs())) .. tostring(math.random(1000, 9999))
end

local function validItemId(value)
  return type(value) == "string" and value:match("^[%w_-]+$") ~= nil
end

local function itemPath(id)
  if itemsDir == nil or not validItemId(id) then return nil end
  return itemsDir .. "/" .. id .. ".md"
end

local function findItem(id)
  for _, item in ipairs(items) do
    if item.id == id then return item end
  end
  return nil
end

local function sortItems()
  table.sort(items, function(a, b)
    if (a.favorite == true) ~= (b.favorite == true) then return a.favorite == true end
    return (a.createdAt or 0) > (b.createdAt or 0)
  end)
end

local function publish()
  sortItems()
  if itemsDir ~= nil then
    for _, item in ipairs(items) do item.notePath = itemPath(item.id) or "" end
  end
  noctalia.state.set("reading_list.items", items)
  noctalia.state.set("reading_list.ready", ready)
  noctalia.state.set("reading_list.save_path", rootDir or "")
  noctalia.state.set("reading_list.collections", collections)
  noctalia.state.set("reading_list.error", lastError)
end

local function yamlValue(value)
  local encoded = noctalia.json.encode(value)
  return encoded or "\"\""
end

local function dateOnly(timestamp)
  if type(timestamp) ~= "number" or timestamp <= 0 then return "" end
  local ok, result = pcall(os.date, "%Y-%m-%d", timestamp)
  return ok and result or ""
end

local function serializeItem(item)
  local topics = type(item.topics) == "table" and item.topics or {}
  local collections = type(item.collections) == "table" and item.collections or {}
  local lines = {
    "---",
    "reading_list: true",
    "id: " .. yamlValue(item.id or ""),
    "type: " .. yamlValue(item.type or "article"),
    "title: " .. yamlValue(item.title or ""),
    "url: " .. yamlValue(item.url or ""),
    "source: " .. yamlValue(item.source or ""),
    "author: " .. yamlValue(item.author or ""),
    "description: " .. yamlValue(item.description or ""),
    "topics: " .. yamlValue(topics),
    "collections: " .. yamlValue(collections),
    "status: " .. yamlValue(item.status or "unread"),
    "favorite: " .. tostring(item.favorite == true),
    "progress: " .. tostring(item.progress or 0),
    "current_page: " .. tostring(item.currentPage or 0),
    "total_pages: " .. tostring(item.totalPages or 0),
    "rating: " .. tostring(item.rating or 0),
    "estimated_minutes: " .. tostring(item.estimatedMinutes or 0),
    "queue_order: " .. tostring(item.queueOrder or 0),
    "created_at: " .. tostring(item.createdAt or 0),
    "created: " .. yamlValue(dateOnly(item.createdAt)),
    "started_at: " .. tostring(item.startedAt or 0),
    "updated_at: " .. tostring(item.updatedAt or 0),
    "finished_at: " .. tostring(item.finishedAt or 0),
    "favicon: " .. yamlValue(item.icon or ""),
    "cover: " .. yamlValue(item.image or ""),
    "---",
    "",
    trim(item.review) ~= "" and ("## Review\n\n" .. item.review .. "\n\n## Notes\n") or "",
    item.notes or "",
  }
  return table.concat(lines, "\n") .. "\n"
end

local function decodeScalar(raw)
  raw = trim(raw)
  -- Values written by serializeItem are overwhelmingly simple JSON scalars.
  -- Keep those in Luau and reserve the host JSON decoder for arrays and
  -- escaped strings; hundreds of decoder crossings can exhaust one callback.
  if raw == "true" then return true end
  if raw == "false" then return false end
  local number = tonumber(raw)
  if number ~= nil then return number end
  if raw == "[]" then return {} end
  if raw == "{}" then return {} end
  if raw:sub(1, 1) == "\"" and raw:sub(-1) == "\""
      and raw:find("\\", 2, true) == nil then
    return raw:sub(2, -2)
  end
  local decoded = noctalia.json.decode(raw)
  if decoded ~= nil then return decoded end
  return raw
end

local function mergedCollections(stored)
  local result, seen = {}, {}
  local function include(value)
    local name = trim(value)
    local key = name:lower()
    if name ~= "" and not seen[key] then
      seen[key] = true
      table.insert(result, name)
    end
  end
  for _, name in ipairs(type(stored) == "table" and stored or {}) do include(name) end
  for _, item in ipairs(items) do
    for _, name in ipairs(item.collections or {}) do include(name) end
  end
  table.sort(result, function(a, b) return a:lower() < b:lower() end)
  return result
end

local function saveCollections()
  if collectionsPath == nil then return false end
  local content = table.concat({
    "---",
    "reading_list_collections: true",
    "collections: " .. yamlValue(collections),
    "---",
    "",
    "# Reading List Collections",
    "",
    "This file is managed by the Reading List plugin.",
    "",
  }, "\n")
  local temporary = collectionsPath .. ".tmp"
  local ok, err = noctalia.writeFile(temporary, content)
  if ok then ok, err = noctalia.renameFile(temporary, collectionsPath) end
  if not ok then
    noctalia.removeFile(temporary)
    lastError = err or noctalia.tr("errors.save-collections")
    return false
  end
  return true
end

local function loadCollections()
  if collectionsPath == nil then return end
  local raw = noctalia.readFile(collectionsPath)
  local stored = {}
  if type(raw) == "string" then
    local encoded = raw:match("\ncollections:%s*(.-)\n")
    local decoded = encoded ~= nil and decodeScalar(encoded) or nil
    if type(decoded) == "table" then stored = decoded end
  end
  collections = mergedCollections(stored)
  if raw == nil and #collections > 0 then saveCollections() end
end

local function registerCollections(values)
  local combined = {}
  for _, name in ipairs(collections) do table.insert(combined, name) end
  for _, name in ipairs(type(values) == "table" and values or {}) do table.insert(combined, name) end
  local before = #collections
  collections = mergedCollections(combined)
  if #collections ~= before then saveCollections() end
end

local function addCollection(value)
  local name = trim(value)
  if name == "" then return end
  for _, existing in ipairs(collections) do
    if existing:lower() == name:lower() then publish(); return end
  end
  table.insert(collections, name)
  table.sort(collections, function(a, b) return a:lower() < b:lower() end)
  if not saveCollections() then
    for index, collection in ipairs(collections) do
      if collection == name then table.remove(collections, index); break end
    end
  end
  publish()
end

local function parseItem(raw, fallbackId)
  if type(raw) ~= "string" then return nil end
  local frontmatter, notes = raw:match("^%-%-%-%s*\n(.-)\n%-%-%-%s*\n?(.*)$")
  if frontmatter == nil then return nil end
  local data = {}
  for line in (frontmatter .. "\n"):gmatch("(.-)\n") do
    local key, value = line:match("^([%w_%-]+):%s*(.*)$")
    if key ~= nil then data[key] = decodeScalar(value) end
  end
  if data.reading_list ~= true and data.id == nil then return nil end
  local id = trim(data.id)
  if not validItemId(id) then id = trim(fallbackId) end
  if not validItemId(id) then return nil end
  local itemType = VALID_TYPES[data.type] and data.type or "article"
  local status = VALID_STATUS[data.status] and data.status or "unread"
  local topics = type(data.topics) == "table" and data.topics or {}
  local collections = type(data.collections) == "table" and data.collections or {}
  local cleanTopics = {}
  for _, value in ipairs(topics) do
    local topic = trim(value)
    if topic ~= "" then table.insert(cleanTopics, topic) end
  end
  local cleanCollections = {}
  for _, value in ipairs(collections) do
    local collection = trim(value)
    if collection ~= "" then table.insert(cleanCollections, collection) end
  end
  local review = ""
  if notes:match("^## Review%s*\n") then
    review, notes = notes:match("^## Review%s*\n+(.-)\n+## Notes%s*\n?(.*)$")
  end
  return {
    id = id,
    type = itemType,
    title = trim(data.title),
    url = trim(data.url),
    source = trim(data.source),
    author = trim(data.author),
    description = trim(data.description),
    topics = cleanTopics,
    collections = cleanCollections,
    status = status,
    favorite = data.favorite == true,
    progress = math.max(0, math.min(100, tonumber(data.progress) or 0)),
    currentPage = math.max(0, tonumber(data.current_page) or 0),
    totalPages = math.max(0, tonumber(data.total_pages) or 0),
    rating = math.max(0, math.min(5, tonumber(data.rating) or 0)),
    estimatedMinutes = math.max(0, tonumber(data.estimated_minutes) or 0),
    queueOrder = math.max(0, tonumber(data.queue_order) or 0),
    createdAt = tonumber(data.created_at) or 0,
    startedAt = tonumber(data.started_at) or 0,
    updatedAt = tonumber(data.updated_at) or 0,
    finishedAt = tonumber(data.finished_at) or 0,
    icon = trim(data.favicon),
    image = trim(data.cover),
    review = review or "",
    notes = notes or "",
    fetching = false,
  }
end

local function saveItem(item)
  if itemsDir == nil or item == nil then return false end
  item.updatedAt = math.floor(noctalia.nowMs() / 1000)
  local path = itemPath(item.id)
  if path == nil then
    lastError = noctalia.tr("errors.save")
    return false
  end
  local temporary = path .. ".tmp"
  local content = serializeItem(item)
  local ok, err = noctalia.writeFile(temporary, content)
  if ok then ok, err = noctalia.renameFile(temporary, path) end
  if not ok then
    noctalia.removeFile(temporary)
    lastError = err or noctalia.tr("errors.save")
    return false
  end
  itemCache[item.id .. ".md"] = { raw = content, item = item }
  lastError = ""
  return true
end

-- The library may live in a sync folder or be edited outside Noctalia. Recreate
-- its owned directories before retrying a failed listing so a brief mount/sync
-- race does not leave the panel stuck with a load error.
local function ensureLibraryDirectories()
  if itemsDir == nil or assetsDir == nil or exportsDir == nil then
    return false, noctalia.tr("errors.create-folder")
  end
  local ok, err = noctalia.mkdirAll(itemsDir)
  if ok then ok, err = noctalia.mkdirAll(assetsDir) end
  if ok then ok, err = noctalia.mkdirAll(exportsDir) end
  return ok == true, err
end

local function loadItems()
  if itemsDir == nil then return end
  local names, err = noctalia.listDir(itemsDir)
  if names == nil then
    -- A folder can disappear temporarily while a cloud/Obsidian sync is
    -- replacing it. mkdirAll is idempotent, so repair our directories and
    -- make one fresh attempt before presenting an error to the user.
    local repaired, repairErr = ensureLibraryDirectories()
    if repaired then names, err = noctalia.listDir(itemsDir) end
    if names == nil then
      lastError = err or repairErr or noctalia.tr("errors.load")
      publish()
      return
    end
  end
  if type(names) ~= "table" then
    lastError = err or noctalia.tr("errors.load")
    publish()
    return
  end
  local loaded = {}
  local refreshedCache = {}
  for _, name in ipairs(names) do
    if name:match("%.md$") then
      local raw = noctalia.readFile(itemsDir .. "/" .. name)
      local fallbackId = name:gsub("%.md$", "")
      local cached = itemCache[name]
      local item = cached ~= nil and cached.raw == raw and cached.item or parseItem(raw, fallbackId)
      if item ~= nil then
        table.insert(loaded, item)
        refreshedCache[name] = { raw = raw, item = item }
      end
    end
  end
  items = loaded
  itemCache = refreshedCache
  local queueItems = {}
  for _, item in ipairs(items) do table.insert(queueItems, item) end
  table.sort(queueItems, function(a, b)
    if (a.createdAt or 0) ~= (b.createdAt or 0) then return (a.createdAt or 0) < (b.createdAt or 0) end
    return tostring(a.id or "") < tostring(b.id or "")
  end)
  local nextOrder, used = 0, {}
  for _, item in ipairs(queueItems) do
    local order = math.floor(tonumber(item.queueOrder) or 0)
    if order <= 0 or used[order] then
      repeat nextOrder += 1 until not used[nextOrder]
      item.queueOrder = nextOrder
      saveItem(item)
    else
      item.queueOrder = order
      used[order] = true
      if order > nextOrder then nextOrder = order end
    end
    used[item.queueOrder] = true
  end
  lastError = ""
  publish()
end

local function deleteOwnedAsset(path)
  if type(path) ~= "string" or assetsDir == nil then return end
  local prefix = assetsDir .. "/"
  if path:sub(1, #prefix) ~= prefix then return end
  local filename = path:sub(#prefix + 1)
  if filename:match("^[%w_-]+%.[%a%d]+$") == nil then return end
  noctalia.removeFile(path)
end

local function htmlDecode(value)
  value = trim(value)
  value = value:gsub("&amp;", "&"):gsub("&quot;", "\"")
  value = value:gsub("&#39;", "'"):gsub("&apos;", "'")
  value = value:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&nbsp;", " ")
  value = value:gsub("&#[xX]([%da-fA-F]+);", function(n)
    local code = tonumber(n, 16)
    local ok, decoded = pcall(utf8.char, code or 0)
    return ok and decoded or ""
  end)
  value = value:gsub("&#(%d+);", function(n)
    local code = tonumber(n)
    local ok, decoded = pcall(utf8.char, code or 0)
    return ok and decoded or ""
  end)
  return value
end

local function tagAttribute(tag, name)
  for attr, quote, value in tag:gmatch("([%w_:%-]+)%s*=%s*([\"'])(.-)%2") do
    if attr:lower() == name:lower() then return value end
  end
  for attr, value in tag:gmatch("([%w_:%-]+)%s*=%s*([^%s\"'=<>`]+)") do
    if attr:lower() == name:lower() then return value end
  end
  return nil
end

local function firstValue(values, keys)
  for _, key in ipairs(keys) do
    local value = trim(values[key] or "")
    if value ~= "" then return value end
  end
  return ""
end

local function resolveUrl(base, candidate)
  candidate = trim(candidate)
  if candidate == "" then return "" end
  if validWebUrl(candidate) then return candidate end
  local scheme, host = base:match("^(https?)://([^/%?#]+)")
  if scheme == nil then return "" end
  if candidate:sub(1, 2) == "//" then return scheme .. ":" .. candidate end
  if candidate:sub(1, 1) == "/" then return scheme .. "://" .. host .. candidate end
  local directory = base:match("^(https?://.*/)") or (scheme .. "://" .. host .. "/")
  return directory .. candidate
end

local function pageMetadata(html, pageUrl)
  html = type(html) == "string" and html or ""
  local values = {}
  local title = ""
  local iconUrl = ""
  local headEnd = html:find("</[hH][eE][aA][dD]%s*>") or #html
  local cursor = 1

  -- Walk tags once. Large sites such as YouTube can put metadata hundreds of
  -- kilobytes into <head>; rescanning the full response for every field trips
  -- Noctalia's per-callback CPU budget.
  while cursor <= headEnd do
    local startAt, endAt, tagName, attributes = html:find("<%s*([%a]+)%s*([^>]*)>", cursor)
    if startAt == nil or startAt > headEnd then break end
    cursor = endAt + 1
    tagName = tagName:lower()
    if tagName == "meta" then
      local key = tagAttribute(attributes, "property") or tagAttribute(attributes, "name")
        or tagAttribute(attributes, "itemprop")
      local content = tagAttribute(attributes, "content")
      if type(key) == "string" and type(content) == "string" then
        key = key:lower()
        if values[key] == nil then values[key] = htmlDecode(content) end
      end
    elseif tagName == "link" then
      local rel = (tagAttribute(attributes, "rel") or ""):lower()
      local href = htmlDecode(tagAttribute(attributes, "href") or "")
      if iconUrl == "" and rel:find("icon", 1, true) ~= nil then
        iconUrl = resolveUrl(pageUrl, href)
      end
      local itemprop = tagAttribute(attributes, "itemprop")
      local content = tagAttribute(attributes, "content")
      if type(itemprop) == "string" and type(content) == "string"
          and values[itemprop:lower()] == nil then
        values[itemprop:lower()] = htmlDecode(content)
      end
    elseif tagName == "title" and title == "" then
      local closeAt = html:find("</[tT][iI][tT][lL][eE]%s*>", cursor)
      if closeAt ~= nil and closeAt <= headEnd then
        title = htmlDecode(html:sub(cursor, closeAt - 1):gsub("<[^>]+>", ""))
      end
    end
  end

  local scheme, host = pageUrl:match("^(https?)://([^/%?#]+)")
  if iconUrl == "" and scheme ~= nil then iconUrl = scheme .. "://" .. host .. "/favicon.ico" end
  local metadataTitle = firstValue(values, { "og:title", "twitter:title", "title" })
  return {
    title = metadataTitle ~= "" and metadataTitle
      or (title ~= "" and title or firstValue(values, { "name" })),
    source = firstValue(values, { "og:site_name", "application-name" }),
    author = firstValue(values, {
      "author", "article:author", "twitter:creator", "parsely-author", "dc.creator", "byl",
    }),
    description = firstValue(values, {
      "og:description", "twitter:description", "description",
    }),
    imageUrl = resolveUrl(pageUrl, firstValue(values, {
      "og:image:secure_url", "og:image", "og:image:url", "twitter:image", "twitter:image:src",
      "image", "thumbnailurl",
    })),
    iconUrl = iconUrl,
  }
end

local function hostMatches(host, domain)
  return host == domain or host:sub(-#domain - 1) == "." .. domain
end

local function providerMetadataUrl(url)
  local host = (url:match("^https?://([^/%?#]+)") or ""):lower():gsub(":%d+$", "")
  local videoId = nil
  if hostMatches(host, "youtu.be") then
    videoId = url:match("^https?://[^/]+/([%w_-]+)")
  elseif hostMatches(host, "youtube.com") or hostMatches(host, "youtube-nocookie.com") then
    videoId = url:match("[?&]v=([%w_-]+)")
      or url:match("^https?://[^/]+/shorts/([%w_-]+)")
      or url:match("^https?://[^/]+/embed/([%w_-]+)")
      or url:match("^https?://[^/]+/live/([%w_-]+)")
  end
  if videoId ~= nil then
    return "https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v="
      .. videoId .. "&format=json"
  end
  if hostMatches(host, "vimeo.com") then
    local videoNumber = url:match("^https?://[^/]+/(%d+)")
    if videoNumber ~= nil then
      return "https://vimeo.com/api/oembed.json?url=https://vimeo.com/" .. videoNumber
    end
  end
  return ""
end

local function assetExtension(url, fallback)
  local path = (url or ""):match("^[^?#]+") or ""
  local ext = path:match("%.([%a%d]+)$")
  if ext ~= nil then
    ext = ext:lower()
    if ext == "png" or ext == "jpg" or ext == "jpeg" or ext == "webp"
        or ext == "gif" or ext == "svg" or ext == "ico" then
      return "." .. ext
    end
  end
  return fallback
end

local function downloadAsset(id, kind, url, callback)
  if not validItemId(id) or not validWebUrl(url) or assetsDir == nil then callback(""); return end
  local fallback = kind == "favicon" and ".ico" or ".img"
  local path = assetsDir .. "/" .. id .. "-" .. kind .. assetExtension(url, fallback)
  local started = noctalia.download(url, path, function(ok)
    callback(ok and path or "")
  end)
  if not started then callback("") end
end

local function refreshMetadata(id)
  local item = findItem(id)
  if item == nil or not validWebUrl(item.url) or fetching[id] then return end
  fetching[id] = true
  item.fetching = true
  publish()

  local function fail()
    fetching[id] = nil
    local current = findItem(id)
    if current == nil then return end
    current.fetching = false
    lastError = noctalia.tr("errors.metadata")
    publish()
  end

  local function apply(metadata)
    fetching[id] = nil
    local current = findItem(id)
    if current == nil then return end
    current.fetching = false
    if trim(current.title) == "" and trim(metadata.title) ~= "" then current.title = trim(metadata.title) end
    if trim(current.source) == "" or trim(current.source) == domainFromUrl(current.url) then
      current.source = trim(metadata.source) ~= "" and trim(metadata.source) or domainFromUrl(current.url)
    end
    if trim(current.author) == "" and trim(metadata.author) ~= "" then current.author = trim(metadata.author) end
    if trim(current.description) == "" and trim(metadata.description) ~= "" then
      current.description = trim(metadata.description)
    end

    local pending = 0
    local function done()
      pending -= 1
      if pending <= 0 then saveItem(current); publish() end
    end
    if trim(metadata.iconUrl) ~= "" then
      pending += 1
      downloadAsset(id, "favicon", metadata.iconUrl, function(path)
        if path ~= "" then current.icon = path end
        done()
      end)
    end
    if noctalia.getConfig("download_previews") ~= false
        and trim(current.image) == "" and trim(metadata.imageUrl) ~= "" then
      pending += 1
      downloadAsset(id, "cover", metadata.imageUrl, function(path)
        if path ~= "" then current.image = path end
        done()
      end)
    end
    if pending == 0 then saveItem(current); publish() end
  end

  local function fetchPage()
    local started = noctalia.http({
      url = item.url,
      method = "GET",
      follow_redirects = true,
      headers = {
        "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/140.0.0.0 Safari/537.36",
        "Accept: text/html,application/xhtml+xml",
      },
    }, function(response)
      local success = type(response) == "table" and response.ok == true
        and type(response.status) == "number" and response.status >= 200 and response.status < 400
      if not success then
        fail()
        return
      end
      apply(pageMetadata(response.body, item.url))
    end)
    if not started then fail() end
  end

  local providerUrl = providerMetadataUrl(item.url)
  if providerUrl == "" then fetchPage(); return end
  local started = noctalia.http({
    url = providerUrl,
    method = "GET",
    follow_redirects = true,
    headers = { "Accept: application/json" },
  }, function(response)
    local success = type(response) == "table" and response.ok == true
      and type(response.status) == "number" and response.status >= 200 and response.status < 400
    local ok, data = pcall(noctalia.json.decode, success and response.body or "")
    if ok and type(data) == "table" and trim(data.title) ~= "" then
      local scheme, host = item.url:match("^(https?)://([^/%?#]+)")
      apply({
        title = data.title,
        source = data.provider_name or domainFromUrl(item.url),
        author = data.author_name or "",
        description = data.description or "",
        imageUrl = data.thumbnail_url or "",
        iconUrl = scheme ~= nil and (scheme .. "://" .. host .. "/favicon.ico") or "",
      })
    else
      fetchPage()
    end
  end)
  if not started then fetchPage() end
end

local function parseTopics(value)
  local result, seen = {}, {}
  if type(value) == "table" then
    for _, valueTopic in ipairs(value) do
      local topic = trim(valueTopic):gsub("^#", "")
      local key = topic:lower()
      if topic ~= "" and not seen[key] then seen[key] = true; table.insert(result, topic) end
    end
  elseif type(value) == "string" then
    for rawTopic in value:gmatch("[^,]+") do
      local topic = trim(rawTopic):gsub("^#", "")
      local key = topic:lower()
      if topic ~= "" and not seen[key] then seen[key] = true; table.insert(result, topic) end
    end
  end
  return result
end

local function nextQueueOrder()
  local highest = 0
  for _, item in ipairs(items) do
    if (tonumber(item.queueOrder) or 0) > highest then highest = tonumber(item.queueOrder) or 0 end
  end
  return math.floor(highest) + 1
end

local function cloneItem(item)
  local copy = {}
  for key, value in pairs(item) do
    if type(value) == "table" then
      local nested = {}
      for nestedKey, nestedValue in pairs(value) do nested[nestedKey] = nestedValue end
      copy[key] = nested
    else
      copy[key] = value
    end
  end
  return copy
end

local function restoreItem(item, snapshot)
  local keys = {}
  for key, _ in pairs(item) do table.insert(keys, key) end
  for _, key in ipairs(keys) do item[key] = nil end
  for key, value in pairs(snapshot) do item[key] = value end
end

local function addItem(data, skipMetadata)
  data = type(data) == "table" and data or {}
  local url = normalizedUrl(data.url)
  if url ~= "" and not validWebUrl(url) then
    lastError = noctalia.tr("errors.invalid-url"); publish(); return false
  end
  for _, existing in ipairs(items) do
    if url ~= "" and normalizedUrl(existing.url) == url then
      lastError = noctalia.tr("errors.duplicate"); publish(); return false
    end
  end
  local now = math.floor(noctalia.nowMs() / 1000)
  local item = {
    id = makeId(),
    type = VALID_TYPES[data.type] and data.type or "article",
    title = trim(data.title),
    url = url,
    source = trim(data.source),
    author = trim(data.author),
    description = trim(data.description),
    topics = parseTopics(data.topics),
    collections = parseTopics(data.collections),
    status = VALID_STATUS[data.status] and data.status or "unread",
    favorite = data.favorite == true,
    progress = math.max(0, math.min(100, tonumber(data.progress) or 0)),
    currentPage = math.max(0, tonumber(data.currentPage) or 0),
    totalPages = math.max(0, tonumber(data.totalPages) or 0),
    rating = math.max(0, math.min(5, tonumber(data.rating) or 0)),
    estimatedMinutes = math.max(0, tonumber(data.estimatedMinutes) or 0),
    queueOrder = math.max(1, tonumber(data.queueOrder) or nextQueueOrder()),
    createdAt = tonumber(data.createdAt) or now,
    startedAt = tonumber(data.startedAt) or (data.status == "reading" and now or 0),
    updatedAt = tonumber(data.updatedAt) or now,
    finishedAt = tonumber(data.finishedAt) or (data.status == "read" and now or 0),
    icon = "",
    image = trim(data.image),
    notes = data.notes or "",
    review = data.review or "",
    fetching = false,
  }
  if item.totalPages > 0 and item.currentPage > 0 then
    item.progress = math.min(100, math.floor((item.currentPage / item.totalPages) * 100 + 0.5))
  end
  if item.status == "read" then item.progress = 100 end
  if item.title == "" and item.url == "" then
    lastError = noctalia.tr("errors.title-required"); publish(); return false
  end
  if item.source == "" then item.source = domainFromUrl(item.url) end
  local remoteCover = validWebUrl(item.image) and item.image or ""
  if remoteCover ~= "" then item.image = "" end
  table.insert(items, item)
  if not saveItem(item) then
    table.remove(items)
    publish()
    return false
  end
  registerCollections(item.collections)
  publish()
  local function fetchAfterCover()
    if not skipMetadata and item.url ~= "" and noctalia.getConfig("fetch_metadata") ~= false then
      refreshMetadata(item.id)
    end
  end
  if remoteCover ~= "" then
    downloadAsset(item.id, "cover", remoteCover, function(path)
      local current = findItem(item.id)
      if current ~= nil and path ~= "" then
        current.image = path
        if not saveItem(current) then current.image = ""; deleteOwnedAsset(path) end
        publish()
      end
      fetchAfterCover()
    end)
  else
    fetchAfterCover()
  end
  return true
end

local function updateItem(data)
  local item = type(data) == "table" and findItem(data.id) or nil
  if item == nil then return end
  local url = normalizedUrl(data.url)
  if url ~= "" and not validWebUrl(url) then
    lastError = noctalia.tr("errors.invalid-url"); publish(); return
  end
  if trim(data.title) == "" and url == "" then
    lastError = noctalia.tr("errors.title-required"); publish(); return
  end
  for _, existing in ipairs(items) do
    if existing.id ~= item.id and url ~= "" and normalizedUrl(existing.url) == url then
      lastError = noctalia.tr("errors.duplicate"); publish(); return
    end
  end
  local previous = cloneItem(item)
  local oldUrl = item.url
  item.type = VALID_TYPES[data.type] and data.type or item.type
  item.title = trim(data.title)
  item.url = url
  item.source = trim(data.source)
  item.author = trim(data.author)
  item.description = trim(data.description)
  item.topics = parseTopics(data.topics)
  item.collections = parseTopics(data.collections)
  item.notes = data.notes or ""
  item.review = data.review or ""
  item.progress = math.max(0, math.min(100, tonumber(data.progress) or 0))
  item.currentPage = math.max(0, tonumber(data.currentPage) or 0)
  item.totalPages = math.max(0, tonumber(data.totalPages) or 0)
  item.rating = math.max(0, math.min(5, tonumber(data.rating) or 0))
  item.estimatedMinutes = math.max(0, tonumber(data.estimatedMinutes) or 0)
  if item.totalPages > 0 and item.currentPage > 0 then
    item.progress = math.min(100, math.floor((item.currentPage / item.totalPages) * 100 + 0.5))
  end
  local oldImage = item.image
  local requestedImage = trim(data.image)
  local remoteCover = validWebUrl(requestedImage) and requestedImage or ""
  item.image = remoteCover ~= "" and oldImage or requestedImage
  if VALID_STATUS[data.status] then
    item.status = data.status
    if data.status == "reading" and (item.startedAt or 0) == 0 then
      item.startedAt = math.floor(noctalia.nowMs() / 1000)
    end
    local now = math.floor(noctalia.nowMs() / 1000)
    item.finishedAt = completionTimestamp(data.status, item.finishedAt, now)
    if data.status == "read" then item.progress = 100 end
  end
  local urlChanged = item.url ~= oldUrl
  local oldIcon = item.icon
  if urlChanged then item.icon = "" end
  if not saveItem(item) then
    restoreItem(item, previous)
    publish()
    return
  end
  registerCollections(item.collections)
  if oldImage ~= item.image then deleteOwnedAsset(oldImage) end
  if urlChanged then deleteOwnedAsset(oldIcon) end
  publish()
  local function refreshAfterCover()
    if item.url ~= "" and urlChanged and noctalia.getConfig("fetch_metadata") ~= false then refreshMetadata(item.id) end
  end
  if remoteCover ~= "" then
    downloadAsset(item.id, "cover", remoteCover, function(path)
      local current = findItem(item.id)
      if current ~= nil and path ~= "" then
        local previousImage = current.image
        current.image = path
        if saveItem(current) then deleteOwnedAsset(previousImage)
        else current.image = previousImage; deleteOwnedAsset(path) end
        publish()
      end
      refreshAfterCover()
    end)
  else
    refreshAfterCover()
  end
end

local function deleteItemFiles(item)
  local path = itemPath(item.id)
  if path == nil then
    lastError = noctalia.tr("errors.delete")
    return false
  end
  local ok, err = noctalia.removeFile(path)
  if not ok then
    lastError = err or noctalia.tr("errors.delete")
    return false
  end
  deleteOwnedAsset(item.icon)
  deleteOwnedAsset(item.image)
  return true
end

local function removeItem(id)
  for index, item in ipairs(items) do
    if item.id == id then
      if deleteItemFiles(item) then
        table.remove(items, index)
        lastError = ""
      end
      publish()
      return
    end
  end
end

local function removeCollection(value, deleteItems)
  local name = trim(value)
  if name == "" then return end
  local key = name:lower()
  local operationOk = true

  for index = #items, 1, -1 do
    local item = items[index]
    local belongs = false
    for _, collection in ipairs(item.collections or {}) do
      if collection:lower() == key then belongs = true; break end
    end
    if belongs and deleteItems == true then
      if deleteItemFiles(item) then table.remove(items, index)
      else operationOk = false end
    elseif belongs then
      local remaining = {}
      for _, collection in ipairs(item.collections or {}) do
        if collection:lower() ~= key then table.insert(remaining, collection) end
      end
      local previous = item.collections
      item.collections = remaining
      if not saveItem(item) then item.collections = previous; operationOk = false end
    end
  end

  if operationOk then
    local remaining = {}
    for _, collection in ipairs(collections) do
      if collection:lower() ~= key then table.insert(remaining, collection) end
    end
    collections = remaining
    if saveCollections() then lastError = "" end
  end
  publish()
end

local function setStatus(id, status)
  local item = findItem(id)
  if item == nil or not VALID_STATUS[status] then return end
  local previous = cloneItem(item)
  item.status = status
  if status == "reading" and (item.startedAt or 0) == 0 then
    item.startedAt = math.floor(noctalia.nowMs() / 1000)
  end
  local now = math.floor(noctalia.nowMs() / 1000)
  item.finishedAt = completionTimestamp(status, item.finishedAt, now)
  if status == "read" then item.progress = 100 end
  if not saveItem(item) then restoreItem(item, previous) end
  publish()
end

local function swapQueueItems(id, targetId)
  local current, target = findItem(id), findItem(targetId)
  if current == nil or target == nil or current.id == target.id then return end
  local currentOrder, targetOrder = current.queueOrder, target.queueOrder
  current.queueOrder, target.queueOrder = targetOrder, currentOrder
  local currentSaved = saveItem(current)
  local targetSaved = currentSaved and saveItem(target)
  if not currentSaved or not targetSaved then
    local failure = lastError
    current.queueOrder, target.queueOrder = currentOrder, targetOrder
    saveItem(current)
    saveItem(target)
    lastError = failure
  end
  publish()
end

local function idSet(ids)
  local selected = {}
  if type(ids) == "table" then
    for _, id in ipairs(ids) do selected[id] = true end
  end
  return selected
end

local function bulkUpdate(ids, action, value)
  local selected = idSet(ids)
  local changed = 0
  local operationOk = true
  if action == "delete" then
    for index = #items, 1, -1 do
      local item = items[index]
      if selected[item.id] then
        if deleteItemFiles(item) then
          table.remove(items, index)
          changed += 1
        else operationOk = false end
      end
    end
  else
    local now = math.floor(noctalia.nowMs() / 1000)
    for _, item in ipairs(items) do
      if selected[item.id] then
        if action == "status" and VALID_STATUS[value] then
          local previous = {
            status = item.status, startedAt = item.startedAt,
            finishedAt = item.finishedAt, progress = item.progress,
          }
          item.status = value
          if value == "reading" and (item.startedAt or 0) == 0 then item.startedAt = now end
          item.finishedAt = completionTimestamp(value, item.finishedAt, now)
          if value == "read" then item.progress = 100 end
          if saveItem(item) then
            changed += 1
          else
            item.status, item.startedAt = previous.status, previous.startedAt
            item.finishedAt, item.progress = previous.finishedAt, previous.progress
            operationOk = false
          end
        elseif action == "collection" and trim(value) ~= "" then
          local exists = false
          for _, collection in ipairs(item.collections or {}) do
            if collection:lower() == trim(value):lower() then exists = true; break end
          end
          if not exists then
            table.insert(item.collections, trim(value))
            if saveItem(item) then changed += 1
            else table.remove(item.collections); operationOk = false end
          end
        end
      end
    end
  end
  if action == "collection" and trim(value) ~= "" then registerCollections({ value }) end
  if operationOk then lastError = "" end
  publish()
  noctalia.state.set("reading_list.bulk_result", changed)
end

local function selectedItems(ids)
  local selected = idSet(ids)
  local result = {}
  for _, item in ipairs(items) do
    if selected[item.id] then table.insert(result, item) end
  end
  return result
end

local function htmlEscape(value)
  return tostring(value or ""):gsub("&", "&amp;"):gsub("<", "&lt;")
    :gsub(">", "&gt;"):gsub("\"", "&quot;")
end

local function exportItems(ids, format, includeNotes)
  local chosen = selectedItems(ids)
  if #chosen == 0 or exportsDir == nil then
    lastError = noctalia.tr("errors.nothing-exported"); publish(); return
  end
  if format ~= "json" and format ~= "html" then format = "md" end
  local output = ""
  if format == "json" then
    local records = {}
    for _, item in ipairs(chosen) do
      table.insert(records, {
        type = item.type, title = item.title, url = item.url, source = item.source,
        author = item.author, description = item.description, topics = item.topics,
        collections = item.collections, status = item.status, favorite = item.favorite,
        progress = item.progress, currentPage = item.currentPage, totalPages = item.totalPages,
        rating = item.rating, estimatedMinutes = item.estimatedMinutes,
        queueOrder = item.queueOrder,
        createdAt = item.createdAt, startedAt = item.startedAt, finishedAt = item.finishedAt,
        image = item.image,
        review = includeNotes and item.review or "",
        notes = includeNotes and item.notes or "",
      })
    end
    output = noctalia.json.encode({ version = 2, exportedAt = math.floor(noctalia.nowMs() / 1000), items = records }, true) or "{}"
  elseif format == "html" then
    local rows = { "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><title>Reading List</title><style>body{font:16px system-ui;max-width:800px;margin:40px auto;padding:0 20px;color:#222}article{border-bottom:1px solid #ddd;padding:16px 0}small{color:#666}.tags{color:#1769aa}</style></head><body><h1>Reading List</h1>" }
    for _, item in ipairs(chosen) do
      local title = htmlEscape(item.title ~= "" and item.title or item.url)
      local heading = item.url ~= "" and ("<a href=\"" .. htmlEscape(item.url) .. "\">" .. title .. "</a>") or title
      table.insert(rows, "<article><h2>" .. heading .. "</h2><small>" .. htmlEscape(item.status) .. " · " .. htmlEscape(item.source) .. "</small>")
      if item.description ~= "" then table.insert(rows, "<p>" .. htmlEscape(item.description) .. "</p>") end
      if #(item.topics or {}) > 0 then table.insert(rows, "<p class=\"tags\">#" .. htmlEscape(table.concat(item.topics, " #")) .. "</p>") end
      if includeNotes and item.review ~= "" then table.insert(rows, "<h3>Review</h3><p>" .. htmlEscape(item.review):gsub("\n", "<br>") .. "</p>") end
      if includeNotes and item.notes ~= "" then table.insert(rows, "<p>" .. htmlEscape(item.notes):gsub("\n", "<br>") .. "</p>") end
      table.insert(rows, "</article>")
    end
    table.insert(rows, "</body></html>")
    output = table.concat(rows, "\n")
  else
    local rows = { "# Reading List", "" }
    for _, item in ipairs(chosen) do
      local title = item.title ~= "" and item.title or item.url
      table.insert(rows, "<!-- reading-list:item -->")
      table.insert(rows, item.url ~= "" and ("## [" .. title:gsub("%]", "\\]") .. "](" .. item.url .. ")") or ("## " .. title))
      table.insert(rows, "")
      table.insert(rows, "- Status: " .. item.status)
      if item.source ~= "" then table.insert(rows, "- Source: " .. item.source) end
      if #(item.topics or {}) > 0 then table.insert(rows, "- Topics: " .. table.concat(item.topics, ", ")) end
      if #(item.collections or {}) > 0 then table.insert(rows, "- Collections: " .. table.concat(item.collections, ", ")) end
      if (item.rating or 0) > 0 then table.insert(rows, "- Rating: " .. tostring(item.rating) .. "/5") end
      if item.description ~= "" then table.insert(rows, "\n" .. item.description) end
      if includeNotes and item.review ~= "" then table.insert(rows, "\n### Review\n\n" .. item.review) end
      if includeNotes and item.notes ~= "" then table.insert(rows, "\n### Notes\n\n" .. item.notes) end
      table.insert(rows, "")
    end
    output = table.concat(rows, "\n")
  end
  local stamp = os.date("%Y%m%d-%H%M%S")
  local path = exportsDir .. "/reading-list-" .. stamp .. "." .. format
  local ok, err = noctalia.writeFile(path .. ".tmp", output)
  if ok then ok, err = noctalia.renameFile(path .. ".tmp", path) end
  if not ok then
    noctalia.removeFile(path .. ".tmp")
    lastError = err or noctalia.tr("errors.export")
    publish(); return
  end
  lastError = ""
  publish()
  noctalia.state.set("reading_list.export_path", path)
end

local function urlAlreadyExists(url)
  if url == "" then return false end
  local normalized = normalizedUrl(url)
  for _, item in ipairs(items) do
    if normalizedUrl(item.url) == normalized then return true end
  end
  return false
end

local function parseExportMarkdown(raw)
  local records = {}
  local current = nil
  local descriptionLines = {}
  local noteLines = {}
  local reviewLines = {}
  local readingNotes = false
  local readingReview = false
  local hasMarkers = raw:find("<!-- reading-list:item -->", 1, true) ~= nil
  local awaitingHeading = false

  local function finish()
    if current == nil then return end
    current.description = trim(table.concat(descriptionLines, "\n"))
    current.notes = trim(table.concat(noteLines, "\n"))
    current.review = trim(table.concat(reviewLines, "\n"))
    table.insert(records, current)
    current = nil
    descriptionLines = {}
    noteLines = {}
    reviewLines = {}
    readingNotes = false
    readingReview = false
  end

  for line in (raw .. "\n"):gmatch("(.-)\n") do
    if line == "<!-- reading-list:item -->" then
      finish()
      awaitingHeading = true
    elseif line:match("^##%s+") and not line:match("^###%s+")
        and (not hasMarkers or awaitingHeading) then
      if not hasMarkers then finish() end
      awaitingHeading = false
      local title, url = line:match("^##%s+%[(.-)%]%((https?://.+)%)%s*$")
      if title ~= nil then
        current = { title = title:gsub("\\%]", "]"), url = url }
      else
        current = { title = trim(line:gsub("^##%s+", "")), url = "" }
      end
    elseif current ~= nil then
      local value = line:match("^%- Status:%s*(.*)$")
      if value ~= nil then
        current.status = trim(value)
      else
        value = line:match("^%- Source:%s*(.*)$")
        if value ~= nil then
          current.source = trim(value)
        else
          value = line:match("^%- Topics:%s*(.*)$")
          if value ~= nil then
            current.topics = trim(value)
          else
            value = line:match("^%- Collections:%s*(.*)$")
            if value ~= nil then
              current.collections = trim(value)
            else
              value = line:match("^%- Rating:%s*(%d+)")
              if value ~= nil then
                current.rating = tonumber(value) or 0
              elseif line:match("^###%s+Review%s*$") then
                readingReview = true
                readingNotes = false
              elseif line:match("^###%s+Notes%s*$") then
                readingNotes = true
                readingReview = false
              else
                if readingNotes then table.insert(noteLines, line)
                elseif readingReview then table.insert(reviewLines, line)
                else table.insert(descriptionLines, line) end
              end
            end
          end
        end
      end
    end
  end
  finish()
  return records
end

local function importFile(path)
  local raw, err = noctalia.readFile(path)
  if raw == nil then lastError = err or noctalia.tr("errors.import"); publish(); return end
  local extension = (path:match("%.([%a%d]+)$") or "txt"):lower()
  local records = {}
  if extension == "json" then
    local decoded = noctalia.json.decode(raw)
    local source = type(decoded) == "table" and (decoded.items or decoded) or {}
    for _, value in ipairs(source) do if type(value) == "table" then table.insert(records, value) end end
  elseif extension == "html" or extension == "htm" then
    for tag, label in raw:gmatch("<[aA]%s+([^>]-)>(.-)</[aA]>") do
      local url = htmlDecode(tagAttribute(tag, "href") or "")
      local title = htmlDecode(label:gsub("<[^>]+>", ""))
      if validWebUrl(url) then table.insert(records, { url = url, title = title }) end
    end
  elseif extension == "md" then
    local parsed = parseItem(raw, makeId())
    if parsed ~= nil then
      table.insert(records, parsed)
    else
      records = parseExportMarkdown(raw)
    end
  end
  if #records == 0 then
    for matchedUrl in raw:gmatch("https?://[^%s<>\"']+") do
      local url = matchedUrl:gsub("[%)%]%},%.%;]+$", "")
      table.insert(records, { url = url })
    end
  end
  local added, skipped = 0, 0
  for _, record in ipairs(records) do
    local url = normalizedUrl(record.url)
    if url ~= "" and urlAlreadyExists(url) then
      skipped += 1
    elseif addItem(record, true) then
      added += 1
    end
  end
  lastError = ""
  publish()
  noctalia.state.set("reading_list.import_result", { added = added, skipped = skipped })
end

local function initialize()
  local configured = trim(noctalia.getConfig("save_path"))
  if configured == "" then configured = "~/Documents/Reading List" end
  rootDir = noctalia.expandPath(configured)
  if rootDir == nil or rootDir == "" then rootDir = noctalia.pluginDataDir() end
  itemsDir = rootDir .. "/Items"
  assetsDir = rootDir .. "/.assets"
  exportsDir = rootDir .. "/Exports"
  collectionsPath = rootDir .. "/Collections.md"
  local ok, err = ensureLibraryDirectories()
  if not ok then lastError = err or noctalia.tr("errors.create-folder") end
  loadItems()
  loadCollections()
  ready = true
  publish()
end

noctalia.state.watch("reading_list.cmd", function(cmd)
  if type(cmd) ~= "table" then return end
  if cmd.op == "add" then
    addItem(cmd.item)
  elseif cmd.op == "update" then
    updateItem(cmd.item)
  elseif cmd.op == "remove" then
    removeItem(cmd.id)
  elseif cmd.op == "set_status" then
    setStatus(cmd.id, cmd.status)
  elseif cmd.op == "swap_queue" then
    swapQueueItems(cmd.id, cmd.targetId)
  elseif cmd.op == "toggle_favorite" then
    local item = findItem(cmd.id)
    if item ~= nil then
      local previous = cloneItem(item)
      item.favorite = not (item.favorite == true)
      if not saveItem(item) then restoreItem(item, previous) end
      publish()
    end
  elseif cmd.op == "refresh_metadata" then
    refreshMetadata(cmd.id)
  elseif cmd.op == "bulk" then
    bulkUpdate(cmd.ids, cmd.action, cmd.value)
  elseif cmd.op == "add_collection" then
    addCollection(cmd.name)
  elseif cmd.op == "remove_collection" then
    removeCollection(cmd.name, cmd.deleteItems == true)
  elseif cmd.op == "export" then
    exportItems(cmd.ids, cmd.format, cmd.includeNotes == true)
  elseif cmd.op == "import_file" then
    importFile(cmd.path)
  elseif cmd.op == "sync" then
    loadItems()
    loadCollections()
  elseif cmd.op == "clear_error" then
    lastError = ""; publish()
  end
  noctalia.state.set("reading_list.cmd", nil)
end)

function update()
  local metadataBusy = false
  for _, active in pairs(fetching) do if active then metadataBusy = true; break end end
  if ready and not metadataBusy and noctalia.getConfig("sync_external_changes") ~= false then
    loadItems()
    loadCollections()
  else
    publish()
  end
end

initialize()
