--!nonstrict
-- Shared shelf model. Every entry (service, panel, widget) reads and writes the
-- same JSON file in the plugin data dir, then publishes the result on
-- noctalia.state so the other entries re-render without touching the disk.
--
-- File format: { "version": 1, "items": [ { "path": "/abs/path", "added": 1790000000 } ] }
-- Items are newest first.

local M = {}

M.ITEMS_KEY = "shelf.items"
M.REQUEST_KEY = "shelf.request"
M.HELPER_KEY = "shelf.helperOpen"
M.PANEL_OPEN_KEY = "shelf.panelOpen"
M.PANEL_VIEW_KEY = "shelf.panelView" -- { id, view }: a section the panel should show
M.PANEL_ID = "alok-debnath/shelf:panel"

function M.path()
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return nil
  end
  return dir .. "/shelf.json"
end

function M.load()
  local path = M.path()
  if path == nil or not noctalia.fileExists(path) then
    return {}
  end
  local raw = noctalia.readFile(path)
  if raw == nil then
    return {}
  end
  local data = noctalia.json.decode(raw)
  if type(data) ~= "table" or type(data.items) ~= "table" then
    return {}
  end
  local items = {}
  for _, item in ipairs(data.items) do
    if type(item) == "table" and type(item.path) == "string" and item.path ~= "" then
      table.insert(items, { path = item.path, added = tonumber(item.added) or 0 })
    end
  end
  return items
end

function M.save(items)
  local path = M.path()
  if path == nil then
    noctalia.log("shelf: no plugin data dir; cannot save")
    return false
  end
  local encoded = noctalia.json.encode({ version = 1, items = items }, true)
  -- Write then rename, so the drop window never reads a half-written file.
  local tmp = path .. ".tmp"
  local ok, err = noctalia.writeFile(tmp, encoded)
  if ok then
    ok, err = noctalia.renameFile(tmp, path)
  end
  if not ok then
    noctalia.log("shelf: save failed: " .. tostring(err))
    return false
  end
  noctalia.state.set(M.ITEMS_KEY, items)
  return true
end

-- Loads fresh from disk, applies fn(items), and saves when fn returns true.
-- Reading first keeps edits from the panel and the service from clobbering
-- each other.
function M.mutate(fn)
  local items = M.load()
  if fn(items) then
    M.save(items)
  end
  return items
end

-- Returns the items currently published, falling back to the file.
function M.current()
  local items = noctalia.state.get(M.ITEMS_KEY)
  if type(items) == "table" then
    return items
  end
  return M.load()
end

local function indexOf(items, path)
  for i, item in ipairs(items) do
    if item.path == path then
      return i
    end
  end
  return nil
end

-- Adds paths to the top of the shelf. A path already on the shelf moves to the
-- top instead of appearing twice. Returns the number of paths given that were
-- new.
function M.add(paths)
  local added = 0
  M.mutate(function(items)
    local now = os.time()
    for i = #paths, 1, -1 do
      local path = paths[i]
      if type(path) == "string" and #path > 1 then
        path = string.gsub(path, "/+$", "") -- "/a/b/" and "/a/b" are one entry
      end
      if type(path) == "string" and path ~= "" then
        local at = indexOf(items, path)
        if at ~= nil then
          table.remove(items, at)
        else
          added = added + 1
        end
        table.insert(items, 1, { path = path, added = now })
      end
    end
    return true
  end)
  return added
end

function M.remove(paths)
  local drop = {}
  for _, p in ipairs(paths) do
    drop[p] = true
  end
  M.mutate(function(items)
    local changed = false
    for i = #items, 1, -1 do
      if drop[items[i].path] then
        table.remove(items, i)
        changed = true
      end
    end
    return changed
  end)
end

function M.clear()
  M.save({})
end

-- Moves `path` so it sits before `beforePath` (nil = end of the list).
function M.move(path, beforePath)
  M.mutate(function(items)
    local from = indexOf(items, path)
    if from == nil or path == beforePath then
      return false
    end
    local item = table.remove(items, from)
    local to = beforePath and indexOf(items, beforePath) or (#items + 1)
    if to == nil then
      to = #items + 1
    end
    table.insert(items, to, item)
    return to ~= from
  end)
end

-- Asks the service to open, close, or toggle the drop window. The id makes
-- two identical requests in a row still count as a change.
function M.request(action)
  noctalia.state.set(M.REQUEST_KEY, {
    id = tostring(noctalia.nowMs()) .. "-" .. tostring(math.random(1, 1000000)),
    action = action,
  })
end

-- Path helpers ---------------------------------------------------------------

function M.basename(path)
  local trimmed = string.gsub(path, "/+$", "")
  return string.match(trimmed, "([^/]+)$") or path
end

function M.dirname(path)
  local trimmed = string.gsub(path, "/+$", "")
  local dir = string.match(trimmed, "^(.*)/[^/]*$")
  if dir == nil or dir == "" then
    return "/"
  end
  return dir
end

function M.prettyDir(path)
  local dir = M.dirname(path)
  local home = noctalia.getenv("HOME") or ""
  if home ~= "" then
    if dir == home then
      return "~"
    end
    if string.sub(dir, 1, #home + 1) == home .. "/" then
      return "~" .. string.sub(dir, #home + 1)
    end
  end
  return dir
end

-- file:// URI with each path segment percent-encoded.
function M.fileUri(path)
  local parts = {}
  for segment in string.gmatch(path, "[^/]+") do
    table.insert(parts, noctalia.string.urlEncode(segment))
  end
  return "file:///" .. table.concat(parts, "/")
end

function M.uriList(paths)
  local lines = {}
  for _, p in ipairs(paths) do
    table.insert(lines, M.fileUri(p))
  end
  return table.concat(lines, "\r\n") .. "\r\n"
end

-- Pulls absolute paths out of clipboard text: file:// URIs or plain paths, one
-- per line. Only paths that exist are kept.
function M.pathsFromText(text)
  local paths = {}
  if type(text) ~= "string" then
    return paths
  end
  for line in string.gmatch(text, "[^\r\n]+") do
    line = noctalia.string.trim(line)
    if string.sub(line, 1, 7) == "file://" then
      -- Drop the scheme and any host part, keeping the leading slash.
      local rest = string.gsub(string.sub(line, 8), "^[^/]*", "")
      line = noctalia.string.urlDecode(rest)
    end
    if string.sub(line, 1, 1) == "/" and noctalia.fileExists(line) then
      table.insert(paths, line)
    end
  end
  return paths
end

-- noctalia.clipboardText() returns the clipboard history's last text entry, which
-- never holds files copied in a file manager. wl-paste reads the live selection
-- and can ask for the file formats, preferred in this order.
local PASTE_TYPES = {
  "text/uri-list", "x-special/gnome-copied-files",
  "text/plain;charset=utf-8", "text/plain", "UTF8_STRING",
}
local CLIPBOARD_TIMEOUT_MS = 2000

-- Calls onPaths with the existing paths on the clipboard (maybe none), or with
-- nil when wl-paste is not installed.
function M.readClipboardPaths(onPaths)
  if not noctalia.commandExists("wl-paste") then
    onPaths(nil)
    return
  end
  noctalia.runAsync({ "wl-paste", "--list-types" }, function(listed)
    -- wl-paste exits non-zero when nothing is copied.
    local offered = {}
    if listed.exitCode == 0 then
      for line in string.gmatch(listed.stdout, "[^\r\n]+") do
        offered[noctalia.string.trim(line)] = true
      end
    end
    local mimeType = nil
    for _, candidate in ipairs(PASTE_TYPES) do
      if offered[candidate] then
        mimeType = candidate
        break
      end
    end
    if mimeType == nil then
      onPaths({})
      return
    end
    noctalia.runAsync({ "wl-paste", "--no-newline", "--type", mimeType }, function(result)
      onPaths(M.pathsFromText(result.exitCode == 0 and result.stdout or nil))
    end, CLIPBOARD_TIMEOUT_MS)
  end, CLIPBOARD_TIMEOUT_MS)
end

function M.formatSize(bytes)
  if bytes == nil then
    return ""
  end
  local units = { "B", "kB", "MB", "GB", "TB" }
  local value, unit = bytes, 1
  while value >= 1000 and unit < #units do
    value = value / 1000
    unit = unit + 1
  end
  if unit == 1 then
    return string.format("%d %s", math.floor(value), units[unit])
  end
  return string.format("%.1f %s", value, units[unit])
end

local IMAGE_EXT = { png = true, jpg = true, jpeg = true, webp = true, gif = true, bmp = true, avif = true }

local GLYPH_BY_EXT = {
  pdf = "file-type-pdf",
  zip = "file-zip", gz = "file-zip", xz = "file-zip", tar = "file-zip", ["7z"] = "file-zip", rar = "file-zip", zst = "file-zip",
  mp3 = "file-music", flac = "file-music", ogg = "file-music", wav = "file-music", m4a = "file-music", opus = "file-music",
  mp4 = "movie", mkv = "movie", webm = "movie", mov = "movie", avi = "movie",
  csv = "file-spreadsheet", xlsx = "file-spreadsheet", ods = "file-spreadsheet",
  txt = "file-text", md = "file-text", doc = "file-text", docx = "file-text", odt = "file-text",
  lua = "file-code", luau = "file-code", py = "file-code", js = "file-code", ts = "file-code", json = "file-code",
  toml = "file-code", rs = "file-code", go = "file-code", c = "file-code", cpp = "file-code", sh = "file-code",
  svg = "photo",
}

function M.extension(path)
  local ext = string.match(M.basename(path), "%.([^.]+)$")
  return ext and string.lower(ext) or ""
end

function M.isImage(path)
  return IMAGE_EXT[M.extension(path)] == true
end

function M.glyphFor(path, isDir)
  if isDir then
    return "folder"
  end
  if M.isImage(path) then
    return "photo"
  end
  return GLYPH_BY_EXT[M.extension(path)] or "file"
end

return M
