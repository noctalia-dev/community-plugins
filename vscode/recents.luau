--!nonstrict
-- Pure parsing and merging of VS Code's recent folders/workspaces. No noctalia.* here.
-- Parsers take (text, decode) where decode(text) -> value, or (nil, err);
-- the caller passes noctalia.json.decode. Bad input yields nil, never an error.
local uris = require("./uris.luau")

local recents = {}

local function decodeText(text, decode)
  if type(text) ~= "string" or type(decode) ~= "function" then
    return nil
  end
  local ok, value = pcall(decode, text)
  if not ok or type(value) ~= "table" then
    return nil
  end
  return value
end

local function item(raw, kind)
  local uri = uris.parse(raw)
  if not uri then
    return nil
  end
  return { uri = uri, kind = kind }
end

function recents.parseDb(text, decode)
  local root = decodeText(text, decode)
  if not root or type(root.entries) ~= "table" then
    return nil
  end
  local out = {}
  for _, e in ipairs(root.entries) do
    if type(e) == "table" then
      local found
      if type(e.folderUri) == "string" then
        found = item(e.folderUri, "folder")
      elseif type(e.workspace) == "table" and type(e.workspace.configPath) == "string" then
        found = item(e.workspace.configPath, "workspace")
      end
      if found then
        out[#out + 1] = found
      end
    end
  end
  return out
end

local function rawFromMenuUri(u)
  if type(u) ~= "table" then
    return nil
  end
  if type(u.external) == "string" and u.external ~= "" then
    return u.external
  end
  if type(u.scheme) ~= "string" or type(u.path) ~= "string" then
    return nil
  end
  local path = u.path:gsub("[%%# ?]", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  return u.scheme .. "://" .. (type(u.authority) == "string" and u.authority or "") .. path
end

local MENU_KIND = { openRecentFolder = "folder", openRecentWorkspace = "workspace" }

-- storage.json can be large (118 KB on a real profile, ~1400 nodes of menu cache), and
-- the host gives a callback ~25 ms of Luau that runs ~40x slower than plain Lua. So the
-- Open Recent entries are found with a pattern scan (native string matching) and only
-- each entry's small "uri" object is decoded. Anything the scan cannot vouch for falls
-- back to decoding the file and walking only the menus' items/submenu lists.

local ENTRY = '^"(openRecent%a+)"%s*,%s*"uri"%s*:%s*()'

-- nil when the scan cannot be trusted (the caller then uses the full parse).
local function scanMenu(text, decode)
  local out = {}
  local pos = 1
  while true do
    -- Jump to each candidate with a plain find; pattern-match only there.
    local s = text:find('"openRecent', pos, true)
    if s == nil then
      break
    end
    local id, uriAt = text:match(ENTRY, s)
    if id == nil or not text:sub(math.max(1, s - 32), s - 1):find('"id"%s*:%s*$') then
      return nil -- not the id-then-uri layout this scan expects
    end
    local obj = text:match("^%b{}", uriAt)
    if obj == nil then
      return nil
    end
    pos = uriAt + #obj
    local kind = MENU_KIND[id]
    if kind then
      local u = decodeText(obj, decode)
      if u == nil then
        return nil -- e.g. a brace inside a path unbalanced the match
      end
      local raw = rawFromMenuUri(u)
      local found = raw and item(raw, kind)
      if found then
        out[#out + 1] = found
      end
    end
  end
  return out
end

local function walkItems(list, out)
  if type(list) ~= "table" then
    return
  end
  for _, node in ipairs(list) do
    if type(node) == "table" then
      local kind = type(node.id) == "string" and MENU_KIND[node.id] or nil
      if kind then
        local raw = rawFromMenuUri(node.uri)
        local found = raw and item(raw, kind)
        if found then
          out[#out + 1] = found
        end
      elseif type(node.submenu) == "table" then
        walkItems(node.submenu.items, out)
      end
    end
  end
end

local function fullParseMenu(text, decode)
  local root = decodeText(text, decode)
  if not root then
    return nil
  end
  local out = {}
  local data = root.lastKnownMenubarData
  if type(data) == "table" and type(data.menus) == "table" then
    local names = {}
    for name in pairs(data.menus) do
      names[#names + 1] = tostring(name)
    end
    table.sort(names) -- a handful of top-level menus; keeps the order stable
    for _, name in ipairs(names) do
      local menu = data.menus[name]
      if type(menu) == "table" then
        walkItems(menu.items, out)
      end
    end
  end
  return out
end

function recents.parseMenu(storageJsonText, decode)
  if type(storageJsonText) ~= "string" or type(decode) ~= "function" then
    return nil
  end
  -- A file caught mid-write is not a complete object: report it unreadable so the
  -- caller keeps the previous list.
  if not storageJsonText:sub(-64):find("}%s*$") then
    return nil
  end
  if not storageJsonText:find('"openRecent', 1, true) then
    return decodeText(storageJsonText, decode) and {} or nil
  end
  local fast = scanMenu(storageJsonText, decode)
  if fast ~= nil and #fast > 0 then
    return fast
  end
  return fullParseMenu(storageJsonText, decode)
end

function recents.parseWorkspaceJson(text, decode)
  local root = decodeText(text, decode)
  if not root then
    return nil
  end
  if type(root.folder) == "string" then
    return item(root.folder, "folder")
  end
  if type(root.workspace) == "string" then
    return item(root.workspace, "workspace")
  end
  return nil
end

-- Builds an Entry. Exported so the service can cache entries (opts.make in merge).
function recents.entry(uri, kind, mtime, home)
  return {
    key = uri.key,
    uri = uri.raw,
    kind = kind,
    remote = uri.remote,
    host = uri.host,
    path = uri.path,
    title = uris.title(uri, kind),
    subtitle = uris.subtitle(uri, home),
    mtime = mtime,
    pinned = false,
    missing = false,
  }
end

-- opts: home, hidden (set of keys), showRemote, make (an entry builder with
-- recents.entry's signature; defaults to it).
function recents.merge(head, wsList, opts)
  opts = opts or {}
  local makeEntry = opts.make or recents.entry
  local hidden = opts.hidden or {}
  local wsByKey = {}
  for _, w in ipairs(wsList or {}) do
    local prev = wsByKey[w.uri.key]
    if prev == nil or (w.mtime or 0) > (prev.mtime or 0) then
      wsByKey[w.uri.key] = w
    end
  end

  local out = {}
  local seen = {}
  local function allowed(uri)
    if hidden[uri.key] then
      return false
    end
    if opts.showRemote == false and uri.scheme == "vscode-remote" then
      return false
    end
    return true
  end

  for _, h in ipairs(head or {}) do
    local key = h.uri.key
    if not seen[key] then
      seen[key] = true
      if allowed(h.uri) then
        local w = wsByKey[key]
        out[#out + 1] = makeEntry(h.uri, h.kind, (w and w.mtime) or h.mtime, opts.home)
      end
    end
  end

  local tail = {}
  for i, w in ipairs(wsList or {}) do
    local key = w.uri.key
    if not seen[key] and wsByKey[key] == w then
      seen[key] = true
      if allowed(w.uri) then
        tail[#tail + 1] = { w = w, i = i }
      end
    end
  end
  table.sort(tail, function(a, b)
    local am, bm = a.w.mtime or 0, b.w.mtime or 0
    if am ~= bm then
      return am > bm
    end
    return a.i < b.i
  end)
  -- VS Code's menu list (the head) is a cache that can lag while VS Code keeps running,
  -- so history entries used more recently than every head entry go on top (the tail is
  -- already newest first). With no mtime on any head entry nothing is promoted.
  local headNewest = 0
  for _, e in ipairs(out) do
    if (e.mtime or 0) > headNewest then
      headNewest = e.mtime
    end
  end
  local top, rest = {}, {}
  for _, t in ipairs(tail) do
    local e = makeEntry(t.w.uri, t.w.kind, t.w.mtime, opts.home)
    if headNewest > 0 and (t.w.mtime or 0) > headNewest then
      top[#top + 1] = e
    else
      rest[#rest + 1] = e
    end
  end
  if #top == 0 then
    for _, e in ipairs(rest) do
      out[#out + 1] = e
    end
    return out
  end
  for _, e in ipairs(out) do
    top[#top + 1] = e
  end
  for _, e in ipairs(rest) do
    top[#top + 1] = e
  end
  return top
end

local function isLocalChecked(e)
  return e.remote == nil and e.key:sub(1, 7) == "file://" and e.path:sub(1, 1) == "/"
end

local function copy(e)
  local c = {}
  for k, v in pairs(e) do
    c[k] = v
  end
  return c
end

local function checkMissing(e, isMissing)
  if isMissing and isLocalChecked(e) then
    return isMissing(e) and true or false
  end
  return false
end

function recents.split(entries, pins, isMissing, hideMissing, home)
  local byKey = {}
  for _, e in ipairs(entries or {}) do
    byKey[e.key] = e
  end
  local pinnedSet = {}
  local pinned = {}
  for _, key in ipairs(pins or {}) do
    if not pinnedSet[key] then
      pinnedSet[key] = true
      local src = byKey[key]
      local e
      if src then
        e = copy(src)
      else
        local uri = uris.parse(key)
        if uri then
          local kind = uri.path:match("%.code%-workspace$") and "workspace" or "folder"
          e = recents.entry(uri, kind, nil, home)
        end
      end
      if e then
        e.pinned = true
        e.missing = checkMissing(e, isMissing)
        pinned[#pinned + 1] = e
      end
    end
  end
  local recent = {}
  for _, e in ipairs(entries or {}) do
    if not pinnedSet[e.key] then
      local missing = checkMissing(e, isMissing)
      if not (missing and hideMissing) then
        local c = copy(e)
        c.pinned = false
        c.missing = missing
        recent[#recent + 1] = c
      end
    end
  end
  return pinned, recent
end

return recents
