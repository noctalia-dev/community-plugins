local servicePath = assert(arg[1], "expected transformed service path")
local files = {}
local stateValues = {}
local watchers = {}
local clock = 1789200000000
local failRemovePath = nil
local failNextItemWrite = false
local failNextList = true
local pendingHttp = nil
local pendingHttpRequest = nil
local downloadedUrls = {}
local writeTargets = {}
local removeTargets = {}
local jsonDecodeCalls = 0
local syncExternalChanges = false

local function jsonEscape(value)
  return '"' .. value:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"'
end

local function jsonEncode(value)
  local kind = type(value)
  if kind == "nil" then return "null" end
  if kind == "string" then return jsonEscape(value) end
  if kind == "number" or kind == "boolean" then return tostring(value) end
  if kind ~= "table" then return '""' end
  local isArray, count = true, 0
  for key, _ in pairs(value) do
    count = count + 1
    if type(key) ~= "number" then isArray = false end
  end
  local parts = {}
  if isArray then
    for index = 1, count do table.insert(parts, jsonEncode(value[index])) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  for key, item in pairs(value) do
    table.insert(parts, jsonEscape(tostring(key)) .. ":" .. jsonEncode(item))
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function jsonDecode(value)
  jsonDecodeCalls = jsonDecodeCalls + 1
  if type(value) ~= "string" then return nil end
  local luaValue = value:gsub("%[", "{"):gsub("%]", "}")
    :gsub('"([^"\\]+)"%s*:', '["%1"]='):gsub("null", "nil")
  local chunk = load("return " .. luaValue, "json", "t", {})
  if chunk == nil then return nil end
  local ok, decoded = pcall(chunk)
  return ok and decoded or nil
end

local function listDir(path)
  if failNextList then
    failNextList = false
    return nil, "forced transient listing failure"
  end
  local names, seen = {}, {}
  local prefix = path .. "/"
  for filePath, _ in pairs(files) do
    if filePath:sub(1, #prefix) == prefix then
      local name = filePath:sub(#prefix + 1)
      if not name:find("/", 1, true) and not seen[name] then
        seen[name] = true
        table.insert(names, name)
      end
    end
  end
  table.sort(names)
  return names
end

noctalia = {
  setUpdateInterval = function() end,
  nowMs = function() clock = clock + 1; return clock end,
  tr = function(key) return key end,
  getConfig = function(key)
    if key == "save_path" then return "/library" end
    if key == "fetch_metadata" then return false end
    if key == "sync_external_changes" then return syncExternalChanges end
    return nil
  end,
  expandPath = function(path) return path end,
  pluginDataDir = function() return "/plugin-data" end,
  mkdirAll = function() return true end,
  listDir = listDir,
  readFile = function(path)
    if files[path] == nil then return nil, "not found" end
    return files[path]
  end,
  writeFile = function(path, contents)
    table.insert(writeTargets, path)
    if failNextItemWrite and path:find("/Items/", 1, true) then
      failNextItemWrite = false
      return false, "forced write failure"
    end
    files[path] = contents
    return true
  end,
  renameFile = function(from, to)
    if files[from] == nil then return false, "source missing" end
    files[to], files[from] = files[from], nil
    return true
  end,
  removeFile = function(path)
    table.insert(removeTargets, path)
    if path == failRemovePath then return false, "forced delete failure" end
    files[path] = nil
    return true
  end,
  fileExists = function(path) return files[path] ~= nil end,
  json = { encode = jsonEncode, decode = jsonDecode },
  string = {
    trim = function(value) return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "") end,
  },
  state = {
    get = function(key) return stateValues[key] end,
    set = function(key, value)
      stateValues[key] = value
      if watchers[key] ~= nil then watchers[key](value) end
    end,
    watch = function(key, callback) watchers[key] = callback end,
  },
  http = function(request, callback)
    pendingHttpRequest = request
    pendingHttp = callback
    return true
  end,
  download = function(url, path, callback)
    table.insert(downloadedUrls, url)
    files[path] = "downloaded"
    callback(true)
    return true
  end,
}

local function command(value)
  noctalia.state.set("reading_list.cmd", value)
end

local function items()
  return stateValues["reading_list.items"] or {}
end

local function findByTitle(title)
  for _, item in ipairs(items()) do if item.title == title then return item end end
  return nil
end

local function findByUrl(url)
  for _, item in ipairs(items()) do if item.url == url then return item end end
  return nil
end

local function assertEqual(actual, expected, message)
  if actual ~= expected then
    error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

files["/library/Items/evil.md"] = [[---
reading_list: true
id: ../../pwned
title: Traversal fixture
cover: /library/.assets/../../cover-victim.md
---
]]
files["/library/.assets/../../cover-victim.md"] = "must survive"

local function scaleFixture(index)
  local id = "scale" .. tostring(index)
  return table.concat({
    "---",
    "reading_list: true",
    "id: \"" .. id .. "\"",
    "type: \"article\"",
    "title: \"Scale item " .. tostring(index) .. "\"",
    "url: \"https://example.com/scale/" .. tostring(index) .. "\"",
    "source: \"Example\"",
    "author: \"Writer\"",
    "description: \"A realistic persisted item\"",
    "topics: []",
    "collections: []",
    "status: \"unread\"",
    "favorite: false",
    "progress: 0",
    "current_page: 0",
    "total_pages: 0",
    "rating: 0",
    "estimated_minutes: 0",
    "queue_order: " .. tostring(index),
    "created_at: " .. tostring(1789000000 + index),
    "created: \"2026-09-20\"",
    "started_at: 0",
    "updated_at: 0",
    "finished_at: 0",
    "favicon: \"\"",
    "cover: \"\"",
    "---",
    "",
    "Scale note " .. tostring(index),
    "",
  }, "\n")
end

for index = 1, 32 do
  files["/library/Items/scale" .. tostring(index) .. ".md"] = scaleFixture(index)
end

math.randomseed(42)
dofile(servicePath)
assertEqual(stateValues["reading_list.ready"], true, "service should initialize")
assertEqual(stateValues["reading_list.error"], "", "a transient startup listing failure should self-repair")
assertEqual(#items(), 33, "a realistic library should load within the service callback")
assert(jsonDecodeCalls < 10, "ordinary persisted scalars should not require repeated JSON decoding")

jsonDecodeCalls = 0
syncExternalChanges = true
update()
assertEqual(jsonDecodeCalls, 0, "an unchanged library refresh should reuse parsed items")
local scaleItem = assert(findByTitle("Scale item 32"), "scale fixture should remain available after refresh")
command({ op = "set_status", id = scaleItem.id, status = "archived" })
assertEqual(findByTitle("Scale item 32").status, "archived",
  "archive commands should persist with a realistically sized library")
assert(files["/library/Items/scale32.md"]:find('status: "archived"', 1, true),
  "archived status should be written to the Markdown item")
files["/library/Items/scale32.md"] = files["/library/Items/scale32.md"]
  :gsub('status: "archived"', 'status: "reading"')
command({ op = "sync" })
assertEqual(findByTitle("Scale item 32").status, "reading",
  "an externally edited item should invalidate its parsed cache")
syncExternalChanges = false

for index = 1, 32 do files["/library/Items/scale" .. tostring(index) .. ".md"] = nil end
command({ op = "sync" })

local traversalFixture = assert(findByTitle("Traversal fixture"), "frontmatter item should load")
assertEqual(traversalFixture.id, "evil", "unsafe frontmatter id should fall back to the safe filename")
for _, path in ipairs(writeTargets) do
  assert(path:find("../", 1, true) == nil, "item writes must stay inside the library: " .. path)
end
assert(files["/library/Items/../../pwned.md"] == nil, "unsafe frontmatter id must not become a write path")
assert(files["/library/Items/evil.md"] ~= nil, "queue repair should use the safe filename-derived id")
command({ op = "remove", id = traversalFixture.id })
assert(files["/library/Items/evil.md"] == nil, "removal should use the safe filename-derived id")
for _, path in ipairs(removeTargets) do
  assert(path:find("../", 1, true) == nil, "item deletions must stay inside owned paths: " .. path)
end
assertEqual(files["/library/.assets/../../cover-victim.md"], "must survive",
  "frontmatter asset paths must not delete files outside the assets folder")

command({ op = "add", item = {
  title = "First article", url = "example.com/first", source = "Example",
  topics = "lua, testing", collections = "Research", status = "reading",
  description = "A useful article.", rating = 4, review = "Worth reading.",
  notes = "Keep this note.\n\n## Personal heading",
} })
command({ op = "add", item = {
  title = "Second article", url = "https://example.com/second", collections = "Later",
} })
assertEqual(#items(), 2, "two items should be added")

local first = assert(findByTitle("First article"))
assertEqual(first.url, "https://example.com/first", "a bare domain should default to HTTPS")
command({ op = "refresh_metadata", id = first.id })
assert(pendingHttp ~= nil, "metadata refresh should start an HTTP request")
pendingHttp(nil)
assertEqual(stateValues["reading_list.error"], "errors.metadata", "a missing metadata response should be reported")
assertEqual(findByTitle("First article").fetching, false, "a failed metadata request should not stay fetching")

local youtubeUrl = "https://www.youtube.com/watch?v=dgawYAH0pO4"
command({ op = "add", item = { url = youtubeUrl } })
local youtube = assert(findByUrl(youtubeUrl), "YouTube item should be added")
command({ op = "refresh_metadata", id = youtube.id })
assert(pendingHttpRequest.url:find("youtube.com/oembed", 1, true),
  "YouTube metadata should use the lightweight oEmbed endpoint")
pendingHttp({ ok = true, status = 200, body = jsonEncode({
  title = "Design Uber Eats",
  author_name = "Aced",
  provider_name = "YouTube",
  thumbnail_url = "https://i.ytimg.com/vi/dgawYAH0pO4/hqdefault.jpg",
}) })
youtube = assert(findByUrl(youtubeUrl))
assertEqual(youtube.title, "Design Uber Eats", "YouTube oEmbed should provide the title")
assertEqual(youtube.author, "Aced", "YouTube oEmbed should provide the channel author")
assertEqual(youtube.source, "YouTube", "YouTube oEmbed should provide the source")
assert(youtube.image:find("%-cover%.jpg$") ~= nil, "YouTube thumbnail should be downloaded locally")

local fallbackUrl = "https://example.org/metadata"
command({ op = "add", item = { url = fallbackUrl } })
local fallback = assert(findByUrl(fallbackUrl), "fallback item should be added")
command({ op = "refresh_metadata", id = fallback.id })
assertEqual(pendingHttpRequest.url, fallbackUrl, "ordinary websites should fetch their page directly")
pendingHttp({ ok = true, status = 200, body = "<html><head><script>" .. string.rep("x", 750000)
  .. "</script><meta name=twitter:title content='Fallback title'>"
  .. "<meta property=og:site_name content='Example Docs'>"
  .. "<meta name=twitter:description content='Useful &amp; resilient'>"
  .. "<meta itemprop=image content=/cover.webp><link rel=icon href=/icon.svg>"
  .. "<title>Plain title</title></head><body></body></html>" })
fallback = assert(findByUrl(fallbackUrl))
assertEqual(fallback.title, "Fallback title", "Twitter metadata should fall back when Open Graph is absent")
assertEqual(fallback.source, "Example Docs", "Open Graph site name should be collected")
assertEqual(fallback.description, "Useful & resilient", "HTML entities should be decoded")
assert(fallback.image:find("%-cover%.webp$") ~= nil, "relative preview URLs should resolve and download")
command({ op = "remove", id = youtube.id })
command({ op = "remove", id = fallback.id })

local second = assert(findByTitle("Second article"))
assert(first.queueOrder < second.queueOrder, "new items should append to the queue")
command({ op = "swap_queue", id = second.id, targetId = first.id })
assert(findByTitle("Second article").queueOrder < findByTitle("First article").queueOrder,
  "queue move should persist the new order")

command({ op = "set_status", id = first.id, status = "read" })
local finishedAt = assert(findByTitle("First article").finishedAt)
command({ op = "set_status", id = first.id, status = "archived" })
assertEqual(findByTitle("First article").finishedAt, finishedAt,
  "archiving a completed item should preserve its report history")

command({ op = "export", ids = { first.id, second.id }, format = "md", includeNotes = true })
local exportPath = assert(stateValues["reading_list.export_path"])
assert(files[exportPath]:find("First article", 1, true), "Markdown export should contain titles")

command({ op = "remove", id = first.id })
command({ op = "remove", id = second.id })
assertEqual(#items(), 0, "items should be removable before restore")
command({ op = "import_file", path = exportPath })
assertEqual(#items(), 2, "Markdown export should import both items")
local restored = assert(findByTitle("First article"), "Markdown import should restore the title")
assertEqual(restored.source, "Example", "Markdown import should restore the source")
assertEqual(restored.rating, 4, "Markdown import should restore the rating")
assertEqual(restored.review, "Worth reading.", "Markdown import should restore the review")
assertEqual(restored.notes, "Keep this note.\n\n## Personal heading", "Markdown import should preserve headings in notes")

failRemovePath = "/library/Items/" .. restored.id .. ".md"
command({ op = "remove", id = restored.id })
assert(findByTitle("First article") ~= nil, "failed disk deletion must keep the item in memory")
assertEqual(stateValues["reading_list.error"], "forced delete failure", "delete failure should be visible")
failRemovePath = nil

local countBeforeFailedAdd = #items()
failNextItemWrite = true
command({ op = "add", item = { title = "Must not appear" } })
assertEqual(#items(), countBeforeFailedAdd, "failed item save must roll back the in-memory add")

command({ op = "remove_collection", name = "Research", deleteItems = false })
restored = assert(findByTitle("First article"), "safe collection removal must keep items")
assertEqual(#restored.collections, 0, "safe collection removal should clear the assignment")

local disposable = assert(findByTitle("Second article"))
command({ op = "remove_collection", name = "Later", deleteItems = true })
assert(findByTitle("Second article") == nil, "destructive collection removal should delete its items")
assert(files["/library/Items/" .. disposable.id .. ".md"] == nil, "deleted item file should be removed")

command({ op = "sync" })
assert(findByTitle("First article") ~= nil, "saved items should survive a disk reload")
assert(files["/library/Collections.md"] ~= nil, "collection registry should be stored on disk")

local remaining = assert(findByTitle("First article"))
command({ op = "export", ids = { remaining.id }, format = "json", includeNotes = true })
local jsonPath = assert(stateValues["reading_list.export_path"])
command({ op = "remove", id = remaining.id })
command({ op = "import_file", path = jsonPath })
assert(findByTitle("First article") ~= nil, "JSON backup should restore an exported item")

files["/fixtures/bookmarks.html"] = '<a href="https://example.com/html">HTML bookmark</a>'
command({ op = "import_file", path = "/fixtures/bookmarks.html" })
assert(findByTitle("HTML bookmark") ~= nil, "HTML bookmarks should import their titles")

files["/fixtures/urls.txt"] = "https://example.com/plain\n"
command({ op = "import_file", path = "/fixtures/urls.txt" })
local plainFound = false
for _, item in ipairs(items()) do if item.url == "https://example.com/plain" then plainFound = true end end
assert(plainFound, "plain URL lists should import")

print("reading-list service tests: ok")
