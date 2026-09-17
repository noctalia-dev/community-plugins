local servicePath = assert(arg[1], "expected transformed service path")
local files = {}
local stateValues = {}
local watchers = {}
local clock = 1789200000000
local failRemovePath = nil
local failNextItemWrite = false
local writeTargets = {}
local removeTargets = {}

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
  if type(value) ~= "string" then return nil end
  local luaValue = value:gsub("%[", "{"):gsub("%]", "}")
    :gsub('"([^"\\]+)"%s*:', '["%1"]='):gsub("null", "nil")
  local chunk = load("return " .. luaValue, "json", "t", {})
  if chunk == nil then return nil end
  local ok, decoded = pcall(chunk)
  return ok and decoded or nil
end

local function listDir(path)
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
    if key == "fetch_metadata" or key == "sync_external_changes" then return false end
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
  http = function() error("metadata fetch should be disabled in tests") end,
  download = function() error("downloads should be disabled in tests") end,
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

math.randomseed(42)
dofile(servicePath)
assertEqual(stateValues["reading_list.ready"], true, "service should initialize")

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
  title = "First article", url = "https://example.com/first", source = "Example",
  topics = "lua, testing", collections = "Research", status = "reading",
  description = "A useful article.", rating = 4, review = "Worth reading.",
  notes = "Keep this note.\n\n## Personal heading",
} })
command({ op = "add", item = {
  title = "Second article", url = "https://example.com/second", collections = "Later",
} })
assertEqual(#items(), 2, "two items should be added")

local first = assert(findByTitle("First article"))
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
