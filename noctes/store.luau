--!nonstrict
-- The note list and the file it lives in. Nothing else in noctes touches
-- notes.json, and nothing in here knows about desktop widgets, state keys or
-- panels - it stores notes and hands them back in order.
--
-- Order invariant: newest updatedAt first. Callers render the list directly and
-- never re-sort.

local colors = require("./colors.luau")

local M = {}

-- The shape written to disk: { version = 1, notes = { ... } }. Stamped so a
-- later format can be told apart from this one by something that has to read
-- both. A file with no version is this one, from before the stamp existed.
local SCHEMA_VERSION = 1

M.notes = {}
M.ready = false

local directory = nil
local idCounter = 0

-- False while notes.json could not be read and could not be moved out of the
-- way either. Saving then would replace notes nobody has seen with the ones in
-- memory, so nothing is written until a load succeeds.
local writable = true

-- Autosave fires about once a second while someone types, and each one would
-- otherwise rewrite the whole file. Mutations mark the list dirty instead, and
-- `flush` writes at most once per tick.
local saveDue = false

-- "" means automatic: the sheet then derives its paper from its key, so notes
-- look different from each other without anyone picking colors.
local function defaultColor()
  local configured = noctalia.getConfig("default_color")
  if type(configured) == "string" and colors.isKnown(configured) then
    return configured
  end
  return ""
end

local function storedColor(value)
  if type(value) ~= "string" or (value ~= "" and not colors.isKnown(value)) then
    return defaultColor()
  end
  return value
end

-- Unique within a run: nowMs alone collides when two notes are created in the
-- same millisecond.
local function newId()
  idCounter = idCounter + 1
  return string.format("%d-%d", math.floor(noctalia.nowMs()), idCounter)
end

-- updatedAt counts seconds, so two notes touched in the same second tie, and
-- table.sort is not stable: without the tie-breaks they could trade places on
-- any sort, and the note the panel falls back to would change under it.
local function sortNotes()
  table.sort(M.notes, function(a, b)
    local au, bu = a.updatedAt or 0, b.updatedAt or 0
    if au ~= bu then
      return au > bu
    end
    local ac, bc = a.createdAt or 0, b.createdAt or 0
    if ac ~= bc then
      return ac > bc
    end
    return a.id > b.id
  end)
end

local function normalize(raw)
  if type(raw) ~= "table" then
    return nil
  end
  local id = raw.id
  if type(id) ~= "string" or id == "" then
    id = newId()
  end
  local now = os.time()
  return {
    id = id,
    key = type(raw.key) == "string" and raw.key or "",
    title = type(raw.title) == "string" and raw.title or "",
    content = type(raw.content) == "string" and raw.content or "",
    color = storedColor(raw.color),
    createdAt = type(raw.createdAt) == "number" and raw.createdAt or now,
    updatedAt = type(raw.updatedAt) == "number" and raw.updatedAt or now,
  }
end

-- ── File ────────────────────────────────────────────────────────────────────

function M.path()
  if directory == nil then
    return nil
  end
  return directory .. "/notes.json"
end

-- Resolves the directory from `save_path`, falling back to the plugin's own
-- data directory, and creates it.
function M.useDirectory()
  local configured = noctalia.string.trim(noctalia.getConfig("save_path") or "")
  local dir = configured ~= "" and noctalia.expandPath(configured) or noctalia.pluginDataDir()

  if dir == nil or dir == "" then
    noctalia.log("noctes: no writable data directory")
    return nil
  end

  local ok, err = noctalia.mkdirAll(dir)
  if not ok then
    noctalia.log("noctes: mkdir failed: " .. tostring(err))
  end
  directory = dir
  return dir
end

-- Writes land on a sibling temp file and are renamed over the real one, which
-- is the one filesystem operation that either happens or does not. Writing in
-- place is a truncate followed by a write, and anything that interrupts it -
-- a crash, a full disk, the OOM killer - leaves half a JSON document where the
-- notes used to be.
local function writeJson(path, value)
  local encoded, err = noctalia.json.encode(value, true)
  if encoded == nil then
    noctalia.log("noctes: encode failed: " .. tostring(err))
    return false
  end

  local temp = path .. ".tmp"
  local ok, writeErr = noctalia.writeFile(temp, encoded)
  if not ok then
    noctalia.log("noctes: write failed: " .. tostring(writeErr))
    return false
  end

  local renamed, renameErr = noctalia.renameFile(temp, path)
  if not renamed then
    noctalia.log("noctes: rename failed: " .. tostring(renameErr))
    noctalia.removeFile(temp)
    return false
  end
  return true
end

local function writeNow()
  local path = M.path()
  if path ~= nil and writable then
    writeJson(path, { version = SCHEMA_VERSION, notes = M.notes })
  end
end

function M.flush()
  if saveDue then
    saveDue = false
    writeNow()
  end
end

-- The note list out of the decoded file, whatever shape it is in: this format,
-- the unversioned one that came before it, or a bare array from a hand-edited
-- file. A version from the future is read the same way and logged - dropping
-- notes because the stamp is unfamiliar is worse than ignoring a field.
local function notesIn(decoded)
  if type(decoded) ~= "table" then
    return {}
  end

  local version = tonumber(decoded.version)
  if version ~= nil and version > SCHEMA_VERSION then
    noctalia.log("noctes: notes.json is version " .. tostring(version)
      .. ", this plugin writes " .. tostring(SCHEMA_VERSION))
  end

  local list = type(decoded.notes) == "table" and decoded.notes or decoded
  local notes = {}
  if type(list) == "table" then
    for _, raw in ipairs(list) do
      local note = normalize(raw)
      if note ~= nil then
        table.insert(notes, note)
      end
    end
  end
  return notes
end

-- A crash between the temp file and the rename leaves the write behind and the
-- real file untouched. With the real file gone as well, the temp one is the
-- only copy of the notes there is, so it is adopted rather than swept up.
local function recoverTemp(path)
  local temp = path .. ".tmp"
  if noctalia.fileExists(path) or not noctalia.fileExists(temp) then
    return
  end
  if noctalia.renameFile(temp, path) then
    noctalia.log("noctes: recovered notes from " .. temp)
  end
end

-- A file that will not parse is moved aside rather than written over: it can
-- be a hand edit one comma short, and the next save would replace every note
-- in it with the list in memory - at startup, with nothing at all. The list in
-- memory carries on and saves to a fresh notes.json; the old file waits beside
-- it to be fixed.
local function setAside(path, why)
  noctalia.log("noctes: cannot read " .. path .. ": " .. tostring(why))
  local aside = string.format("%s.unreadable-%d", path, os.time())
  if noctalia.renameFile(path, aside) then
    writable = true
    saveDue = #M.notes > 0
    return { path = aside, moved = true }
  end
  noctalia.log("noctes: cannot move it aside either; not saving until it loads")
  writable = false
  return { path = path, moved = false }
end

-- Reads notes.json, replacing the list in memory. Synchronous: the file is
-- small, host calls do not count against the script's budget, and a read that
-- finishes before the next command runs cannot lose an edit that arrived
-- while it was in flight.
--
-- Returns nil, or { path, moved } when the file could not be read (see
-- setAside) so the caller can say so.
--
-- A folder with no notes.json yet gets the list in memory written into it:
-- switching `save_path` to an empty folder takes the notes along, and
-- switching to one that has notes shows those.
function M.load()
  -- Re-reading replaces the in-memory list, so anything still waiting on the
  -- debounce has to reach disk first or it is simply gone.
  M.flush()
  M.ready = true

  local path = M.path()
  if path == nil then
    return nil
  end

  recoverTemp(path)

  if not noctalia.fileExists(path) then
    writable = true
    saveDue = saveDue or #M.notes > 0
    return nil
  end

  local contents, err = noctalia.readFile(path)
  if contents == nil then
    return setAside(path, err)
  end

  local decoded, decodeErr = noctalia.json.decode(contents)
  -- Valid JSON that is not a table is not a note list either, and reading it
  -- as an empty one would save that emptiness over it.
  if type(decoded) ~= "table" then
    return setAside(path, decodeErr or "not a note list")
  end

  writable = true
  M.notes = notesIn(decoded)
  sortNotes()
  return nil
end

-- ── Queries ─────────────────────────────────────────────────────────────────

function M.byId(id)
  for index, note in ipairs(M.notes) do
    if note.id == id then
      return note, index
    end
  end
  return nil
end

-- "" is what every note with no sheet holds, so it names no note in particular.
function M.byKey(key)
  if type(key) ~= "string" or key == "" then
    return nil
  end
  for _, note in ipairs(M.notes) do
    if (note.key or "") == key then
      return note
    end
  end
  return nil
end

-- Every key currently spoken for, for the helper that has to pick a free one.
function M.keys()
  local keys = {}
  for _, note in ipairs(M.notes) do
    if (note.key or "") ~= "" then
      table.insert(keys, note.key)
    end
  end
  return keys
end

-- ── Mutations. Each one leaves the list sorted and the file pending. ─────────

function M.add(fields)
  fields = fields or {}
  local now = os.time()
  local note = {
    id = newId(),
    key = type(fields.key) == "string" and fields.key or "",
    title = type(fields.title) == "string" and fields.title or "",
    content = type(fields.content) == "string" and fields.content or "",
    color = storedColor(fields.color),
    createdAt = now,
    updatedAt = now,
  }
  table.insert(M.notes, note)
  sortNotes()
  saveDue = true
  return note
end

-- Returns the note when something changed and nil when nothing did - a Save
-- with no edit, a color picked twice. Then updatedAt stays, the list keeps its
-- order, and nothing is written or published.
function M.update(id, fields)
  local note = M.byId(id)
  if note == nil then
    return nil
  end
  local changed = false
  if type(fields.title) == "string" and fields.title ~= note.title then
    note.title = fields.title
    changed = true
  end
  if type(fields.content) == "string" and fields.content ~= note.content then
    note.content = fields.content
    changed = true
  end
  -- An empty string clears the color back to automatic.
  local color = fields.color
  if type(color) == "string" and color ~= note.color and (color == "" or colors.isKnown(color)) then
    note.color = color
    changed = true
  end
  if not changed then
    return nil
  end
  note.updatedAt = os.time()
  sortNotes()
  saveDue = true
  return note
end

-- Returns the key the note held, so the caller can take its sheet down too.
-- Gone for good: a post-it is a post-it, and the delete button asks twice.
function M.remove(id)
  local note, index = M.byId(id)
  if note == nil then
    return nil
  end
  table.remove(M.notes, index)
  saveDue = true
  return note.key or ""
end

-- Binds a note that had no sheet to the one just made for it. Keys are
-- unique, so taking one frees it from any note that held it. updatedAt stays:
-- getting paper is not an edit, and should not move the note up the list.
function M.setKey(id, key)
  local note = M.byId(id)
  if note == nil or type(key) ~= "string" or key == "" then
    return nil
  end
  for _, other in ipairs(M.notes) do
    if other.id ~= id and other.key == key then
      other.key = ""
    end
  end
  note.key = key
  saveDue = true
  return note
end

return M
