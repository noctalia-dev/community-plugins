--!nonstrict
-- Sticky Notes service — owns the full note list and blur state.
--
-- Save path (resolved once at startup):
--   1. The "save_path" config setting, if non-empty (~ is expanded).
--   2. ~/Documents/sticky-notes  (default, user-readable).
--   3. pluginDataDir()           (last-resort fallback).
--
-- File format controlled by the "file_format" setting:
--   json -> notes.json  (one array of notes, full metadata)
--   md   -> notes.md    (markdown, one ## section per note)
--   txt  -> notes.txt   (plain text, notes separated by ---)
-- Archived notes are stored in the same file as active ones, marked with an
-- "archived" flag (a metadata key in JSON and Markdown, a header field in
-- plain text).
--
-- State:
--   sticky_notes.notes      -> { { id, content, color, createdAt, pinned, blurred }, ... }
--   sticky_notes.archived   -> { { id, content, color, createdAt, pinned, blurred }, ... }
--   sticky_notes.blurred    -> bool
--   sticky_notes.ready      -> bool (saved notes have finished loading)
--   sticky_notes.save_path  -> string (resolved absolute dir, informational)
--   sticky_notes.edit_note  -> { id, created } for the empty note to edit
-- IPC: new-note opens the panel with quick-capture context.
-- Commands (sticky_notes.cmd):
--   { op = "add" }
--   { op = "remove",     id = "..." }
--   { op = "update",     id = "...", content = "...", color = "..." }
--   { op = "toggle_pin", id = "..." }
--   { op = "toggle_note_blur", id = "..." }
--   { op = "move",       id = "...", group = "p" | "u", index = N }
--   { op = "archive",    id = "..." }
--   { op = "unarchive",  id = "..." }
--   { op = "toggle_blur" }
--   { op = "set_blur", value = true | false }
--   { op = "sync" }
--
-- Storage invariant: `notes` is kept in display order — pinned notes first
-- (newest-first within each group). All mutations preserve this so the
-- panel can render `notes` directly without re-sorting. `archived` holds the
-- read-only archive in its own stable order: most recently archived first.

noctalia.setUpdateInterval(60000)

local notes = {}
local archived = {}
local blurred = false
local resolvedDir = nil
local loaded = false
local pendingAdd = false

-- -------------------------------------------------------------------------
-- Path / format helpers
-- -------------------------------------------------------------------------
local function fileFormat()
  local fmt = noctalia.getConfig("file_format") or "json"
  if fmt == "md" or fmt == "txt" then return fmt end
  return "json"
end

local function notesFilePath()
  if resolvedDir == nil then return nil end
  return resolvedDir .. "/notes." .. fileFormat()
end

local function expandTilde(path, homeDir)
  if path:sub(1, 1) == "~" then return homeDir .. path:sub(2) end
  return path
end

local function initSavePath(callback)
  noctalia.runAsync({ "sh", "-c", "printf '%s' \"$HOME\"" }, function(homeResult)
    local home = homeResult.stdout and noctalia.string.trim(homeResult.stdout) or ""
    local configured = noctalia.string.trim(noctalia.getConfig("save_path") or "")
    local dir
    if configured ~= "" then
      dir = expandTilde(configured, home)
    elseif home ~= "" then
      dir = home .. "/Documents/sticky-notes"
    else
      dir = noctalia.pluginDataDir()
    end
    if dir ~= nil then
      noctalia.runAsync({ "mkdir", "-p", dir }, function()
        resolvedDir = dir
        noctalia.state.set("sticky_notes.save_path", resolvedDir or "")
        callback()
      end)
    else
      resolvedDir = noctalia.pluginDataDir()
      noctalia.state.set("sticky_notes.save_path", resolvedDir or "")
      callback()
    end
  end)
end

-- -------------------------------------------------------------------------
-- Serialisation helpers per format
-- -------------------------------------------------------------------------
local function serializeJson()
  -- Notes live in one array, as in the other formats: an archived note carries
  -- an `archived` flag instead of moving to its own array, so a file written
  -- here still loads every note on an older plugin version (archived notes
  -- simply reappear in the list).
  local entries = {}
  local function append(list, isArchived)
    for _, n in ipairs(list) do
      table.insert(entries, {
        id        = n.id,
        content   = n.content,
        color     = n.color,
        createdAt = n.createdAt,
        pinned    = n.pinned == true,
        blurred   = n.blurred == true,
        archived  = isArchived and true or nil,
      })
    end
  end
  append(notes, false)
  append(archived, true)
  return noctalia.json.encode({ notes = entries, blurred = blurred })
end

local function serializeMd()
  local parts = {}
  -- Sections are written in list order: active notes (already in display
  -- order), then the archive. Archived sections carry an `archived` flag in
  -- their metadata comment; active notes keep their previous metadata shape.
  local function append(list, isArchived, offset)
    for i, n in ipairs(list) do
      local meta = noctalia.json.encode({
        id        = n.id,
        color     = n.color,
        createdAt = n.createdAt,
        pinned    = n.pinned == true,
        blurred   = n.blurred == true,
        archived  = isArchived and true or nil,
      })
      table.insert(parts, string.format(
        "## Note %d\n\n<!-- sticky-notes %s -->\n\n%s\n",
        offset + i,
        meta or "{}",
        n.content or ""
      ))
    end
  end
  append(notes, false, 0)
  append(archived, true, #notes)
  local header = blurred and "<!-- blurred: true -->\n\n" or ""
  return header .. table.concat(parts, "\n---\n\n")
end

local function serializeTxt()
  local parts = {}
  local function append(list, isArchived, offset)
    for i, n in ipairs(list) do
      table.insert(parts, string.format(
        "[Note %d | id:%s color:%s pinned:%s blurred:%s archived:%s]\n%s",
        offset + i,
        n.id,
        n.color,
        n.pinned == true and "true" or "false",
        n.blurred == true and "true" or "false",
        isArchived and "true" or "false",
        n.content or ""
      ))
    end
  end
  append(notes, false, 0)
  append(archived, true, #notes)
  local header = blurred and "[blurred:true]\n\n" or ""
  return header .. table.concat(parts, "\n\n---\n\n")
end

-- -------------------------------------------------------------------------
-- Deserialisation helpers per format
-- -------------------------------------------------------------------------
local function parseJson(raw)
  local decoded = noctalia.json.decode(raw)
  if type(decoded) ~= "table" then return end
  if type(decoded.notes) == "table" then
    for _, n in ipairs(decoded.notes) do
      if type(n) == "table" and type(n.id) == "string" and n.id ~= "" then
        table.insert(n.archived == true and archived or notes, {
          id        = n.id,
          content   = type(n.content) == "string" and n.content or "",
          color     = type(n.color) == "string" and n.color or "yellow",
          createdAt = type(n.createdAt) == "number" and n.createdAt or 0,
          pinned    = n.pinned == true,
          blurred   = n.blurred == true,
        })
      end
    end
  end
  if decoded.blurred == true then blurred = true end
end

local function parseMd(raw)
  if raw:match("<!%-%- blurred: true %-%->") then blurred = true end
  -- The serializer intentionally omits a trailing separator. Appending one
  -- only while parsing lets this single loop read that final note too.
  for metaJson, body in (raw .. "\n---"):gmatch("<!%-%- sticky%-notes (%b{}) %-%->(.-)\n%-%-%-") do
    local meta = noctalia.json.decode(metaJson)
    if type(meta) == "table" and type(meta.id) == "string" then
      table.insert(meta.archived == true and archived or notes, {
        id        = meta.id,
        content   = noctalia.string.trim(body),
        color     = type(meta.color) == "string" and meta.color or "yellow",
        createdAt = type(meta.createdAt) == "number" and meta.createdAt or 0,
        pinned    = meta.pinned == true,
        blurred   = meta.blurred == true,
      })
    end
  end
end

local function parseTxt(raw)
  if raw:match("%[blurred:true%]") then blurred = true end
  local function insertTxt(id, color, pinnedStr, blurredStr, archivedStr, body)
    table.insert(archivedStr == "true" and archived or notes, {
      id        = id,
      content   = noctalia.string.trim(body),
      color     = color,
      createdAt = 0,
      pinned    = pinnedStr == "true",
      blurred   = blurredStr == "true",
    })
  end
  -- The serializer omits a separator after the final note. Add one only for
  -- parsing so each format loop handles every section, including the last.
  local terminated = raw .. "\n\n---\n"
  -- Current format with pinned, per-note blur and archive flags.
  for sectionId, sectionColor, sectionPinned, sectionBlurred, sectionArchived, sectionBody in terminated:gmatch(
    "%[Note %d+ | id:([%w_]+) color:([%a]+) pinned:(%a+) blurred:(%a+) archived:(%a+)%]\n(.-)\n\n%-%-%-%\n"
  ) do
    insertTxt(sectionId, sectionColor, sectionPinned, sectionBlurred, sectionArchived, sectionBody)
  end
  -- Every fallback below predates archives, so its notes are active ones.
  if #notes + #archived == 0 then
    -- Previous format with pinned and per-note blur flags.
    for sectionId, sectionColor, sectionPinned, sectionBlurred, sectionBody in terminated:gmatch(
      "%[Note %d+ | id:([%w_]+) color:([%a]+) pinned:(%a+) blurred:(%a+)%]\n(.-)\n\n%-%-%-%\n"
    ) do
      insertTxt(sectionId, sectionColor, sectionPinned, sectionBlurred, "false", sectionBody)
    end
  end
  if #notes + #archived == 0 then
    -- Previous format with a pinned flag (per-note blur defaults to false).
    for sectionId, sectionColor, sectionPinned, sectionBody in terminated:gmatch(
      "%[Note %d+ | id:([%w_]+) color:([%a]+) pinned:(%a+)%]\n(.-)\n\n%-%-%-%\n"
    ) do
      insertTxt(sectionId, sectionColor, sectionPinned, "false", "false", sectionBody)
    end
  end
  if #notes + #archived == 0 then
    -- Legacy format without pinned flag (defaults to unpinned).
    for sectionId, sectionColor, sectionBody in terminated:gmatch(
      "%[Note %d+ | id:([%w_]+) color:([%a]+)%]\n(.-)\n\n%-%-%-%\n"
    ) do
      insertTxt(sectionId, sectionColor, "false", "false", "false", sectionBody)
    end
  end
end

-- -------------------------------------------------------------------------
-- Persistence
-- -------------------------------------------------------------------------
local function saveData()
  local path = notesFilePath()
  if path == nil then return end
  local fmt = fileFormat()
  local encoded
  if fmt == "md" then
    encoded = serializeMd()
  elseif fmt == "txt" then
    encoded = serializeTxt()
  else
    encoded = serializeJson()
  end
  if encoded ~= nil then
    noctalia.writeFile(path, encoded)
  end
end

local function loadData()
  notes = {}
  archived = {}
  blurred = false
  local path = notesFilePath()
  if path == nil then return end
  local raw = noctalia.readFile(path)
  if raw == nil then return end
  local fmt = fileFormat()
  if fmt == "md" then
    parseMd(raw)
  elseif fmt == "txt" then
    parseTxt(raw)
  else
    parseJson(raw)
  end
end

-- -------------------------------------------------------------------------
-- Publish
-- -------------------------------------------------------------------------
local function publish()
  noctalia.state.set("sticky_notes.notes", notes)
  noctalia.state.set("sticky_notes.archived", archived)
  noctalia.state.set("sticky_notes.blurred", blurred)
  noctalia.state.set("sticky_notes.ready", loaded)
end

-- -------------------------------------------------------------------------
-- Note mutations
-- -------------------------------------------------------------------------
local function makeId()
  return tostring(noctalia.nowMs()) .. tostring(math.random(1000, 9999))
end

local function emptyNote()
  for _, n in ipairs(notes) do
    if noctalia.string.trim(n.content or "") == "" then return n end
  end
  return nil
end

local function pinnedCount()
  local count = 0
  for _, n in ipairs(notes) do
    if n.pinned == true then count += 1 end
  end
  return count
end

-- Sort storage into canonical display order: pinned first, newest-first
-- within each group (createdAt descending).
local function sortDisplay()
  table.sort(notes, function(a, b)
    local ap = a.pinned == true
    local bp = b.pinned == true
    if ap ~= bp then return ap end
    return (a.createdAt or 0) > (b.createdAt or 0)
  end)
end

local function addNote()
  if not loaded then
    -- A shortcut may arrive while the asynchronous save-path setup is running.
    pendingAdd = true
    return
  end
  local existing = emptyNote()
  if existing ~= nil then
    -- Don't pile up empty notes; surface the existing empty one instead.
    publish()
    noctalia.state.set("sticky_notes.edit_note", { id = existing.id, created = false })
    return
  end
  local color = noctalia.getConfig("default_color") or "yellow"
  local note = {
    id        = makeId(),
    content   = "",
    color     = color,
    createdAt = math.floor(noctalia.nowMs() / 1000),
    pinned    = false,
    blurred   = false,
  }
  -- Insert at the top of the unpinned group (right after all pinned notes).
  table.insert(notes, pinnedCount() + 1, note)
  saveData()
  publish()
  noctalia.state.set("sticky_notes.edit_note", { id = note.id, created = true })
end

-- Deleting works from either list: the archive view exposes the same delete
-- flow as the active list.
local function removeNote(id)
  for _, list in ipairs({ notes, archived }) do
    for i, n in ipairs(list) do
      if n.id == id then
        table.remove(list, i)
        saveData()
        publish()
        return
      end
    end
  end
end

local function updateNote(id, content, color)
  for _, n in ipairs(notes) do
    if n.id == id then
      local changed = false
      if content ~= nil and n.content ~= content then
        n.content = content
        changed = true
      end
      if color ~= nil and n.color ~= color then
        n.color = color
        changed = true
      end
      if changed then
        saveData()
        publish()
      end
      return
    end
  end
end

local function toggleBlur()
  blurred = not blurred
  saveData()
  publish()
end

local function toggleNoteBlur(id)
  for _, n in ipairs(notes) do
    if n.id == id then
      n.blurred = not (n.blurred == true)
      saveData()
      publish()
      return
    end
  end
end

-- Toggling pin needs to also reposition the note in storage so the display
-- invariant holds: pinning → move to the end of the pinned group; unpinning
-- → move to the top of the unpinned group. Both target positions happen to
-- resolve to `pinnedCount() + 1` after removing the note from its old slot.
local function togglePin(id)
  local fromIdx = nil
  for i, n in ipairs(notes) do
    if n.id == id then fromIdx = i; break end
  end
  if fromIdx == nil then return end
  local note = table.remove(notes, fromIdx)
  note.pinned = not (note.pinned == true)
  table.insert(notes, pinnedCount() + 1, note)
  saveData()
  publish()
end

-- Move a note into `group` ("p" | "u") at 1-based `index` within that group.
-- Setting note.pinned from the target group means a cross-group drag also
-- flips the pin state, which matches the visual (dragging into the pinned
-- section pins the note, and vice versa).
local function moveTo(id, group, index)
  local fromIdx = nil
  for i, n in ipairs(notes) do
    if n.id == id then fromIdx = i; break end
  end
  if fromIdx == nil then return end
  local wantPinned = group == "p"
  local targetIndex = tonumber(index)
  if targetIndex == nil then return end

  local note = table.remove(notes, fromIdx)
  note.pinned = wantPinned

  local pCount = pinnedCount() -- excludes the removed note
  local insertAt
  if wantPinned then
    insertAt = math.max(1, math.min(targetIndex, pCount + 1))
  else
    local unpinnedSlots = (#notes - pCount) + 1
    insertAt = pCount + math.max(1, math.min(targetIndex, unpinnedSlots))
  end

  table.insert(notes, insertAt, note)
  saveData()
  publish()
end

-- Archiving moves a note out of the active list and to the top of the archive
-- list, where it stays readable but cannot be edited. The pin flag is cleared
-- so a restored note returns to the top of the unpinned group instead of
-- silently coming back pinned.
local function archiveNote(id)
  for i, n in ipairs(notes) do
    if n.id == id then
      -- A blank note holds nothing to keep as a reference, so archiving it
      -- follows the existing empty-note rule and deletes it instead.
      if noctalia.string.trim(n.content or "") == "" then
        removeNote(id)
        return
      end
      local note = table.remove(notes, i)
      note.pinned = false
      table.insert(archived, 1, note)
      saveData()
      publish()
      return
    end
  end
end

-- Restoring puts a note back at the top of the unpinned group, the same place
-- a newly created note lands. Archived notes keep their text, colour and
-- privacy flag; only the pin state is dropped (archiving clears it).
local function unarchiveNote(id)
  for i, n in ipairs(archived) do
    if n.id == id then
      local note = table.remove(archived, i)
      note.pinned = false
      table.insert(notes, pinnedCount() + 1, note)
      saveData()
      publish()
      return
    end
  end
end

-- -------------------------------------------------------------------------
-- Commands from the panel
-- -------------------------------------------------------------------------
noctalia.state.watch("sticky_notes.cmd", function(cmd)
  if type(cmd) ~= "table" then return end
  local op = cmd.op
  if op == "add" then
    addNote()
  elseif op == "remove" then
    removeNote(cmd.id)
  elseif op == "update" then
    updateNote(cmd.id, cmd.content, cmd.color)
  elseif op == "toggle_pin" then
    togglePin(cmd.id)
  elseif op == "toggle_note_blur" then
    toggleNoteBlur(cmd.id)
  elseif op == "move" then
    moveTo(cmd.id, cmd.group, cmd.index)
  elseif op == "archive" then
    archiveNote(cmd.id)
  elseif op == "unarchive" then
    unarchiveNote(cmd.id)
  elseif op == "toggle_blur" then
    toggleBlur()
  elseif op == "set_blur" then
    if type(cmd.value) == "boolean" and blurred ~= cmd.value then
      blurred = cmd.value
      saveData()
      publish()
    end
  elseif op == "sync" then
    -- Panels may start after this service has published its initial state.
    -- Re-publish on open so they always receive the persisted note list.
    publish()
  end
  noctalia.state.set("sticky_notes.cmd", nil)
end)

function update()
  publish()
end

function onIpc(event, _payload)
  if event ~= "new-note" then return end
  -- panel-open keeps an already-open panel visible and delivers the context
  -- again. Let the panel save its local draft before asking us to add a note.
  noctalia.runAsync({
    "noctalia", "msg", "panel-open", "ahmedhossamdev/sticky-notes:panel", "new-note",
  }, function(result)
    if result.exitCode ~= 0 then
      noctalia.log("StickyNotes: could not open quick capture: " .. (result.stderr or ""))
    end
  end)
end

initSavePath(function()
  loadData()
  sortDisplay()
  loaded = true
  if pendingAdd then
    pendingAdd = false
    addNote()
  else
    publish()
  end
end)
