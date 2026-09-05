--!nonstrict
-- Sticky Notes service — owns the full note list and blur state.
--
-- Save path (resolved once at startup):
--   1. The "save_path" config setting, if non-empty (~ is expanded).
--   2. ~/Documents/sticky-notes  (default, user-readable).
--   3. pluginDataDir()           (last-resort fallback).
--
-- File format controlled by the "file_format" setting:
--   json -> notes.json  (array of notes, full metadata)
--   md   -> notes.md    (markdown, one ## section per note)
--   txt  -> notes.txt   (plain text, notes separated by ---)
--
-- State:
--   sticky_notes.notes      -> { { id, content, color, createdAt, pinned }, ... }
--   sticky_notes.blurred    -> bool
--   sticky_notes.ready      -> bool (saved notes have finished loading)
--   sticky_notes.save_path  -> string (resolved absolute dir, informational)
-- Commands (sticky_notes.cmd):
--   { op = "add" }
--   { op = "remove",     id = "..." }
--   { op = "update",     id = "...", content = "...", color = "..." }
--   { op = "toggle_pin", id = "..." }
--   { op = "move",       id = "...", group = "p" | "u", index = N }
--   { op = "toggle_blur" }
--   { op = "sync" }
--
-- Storage invariant: `notes` is kept in display order — pinned notes first
-- (newest-first within each group). All mutations preserve this so the
-- panel can render `notes` directly without re-sorting.

noctalia.setUpdateInterval(60000)

local notes = {}
local blurred = false
local resolvedDir = nil
local loaded = false

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
  return noctalia.json.encode({ notes = notes, blurred = blurred })
end

local function serializeMd()
  local parts = {}
  for i, n in ipairs(notes) do
    local meta = noctalia.json.encode({ id = n.id, color = n.color, createdAt = n.createdAt, pinned = n.pinned == true })
    table.insert(parts, string.format(
      "## Note %d\n\n<!-- sticky-notes %s -->\n\n%s\n",
      i,
      meta or "{}",
      n.content or ""
    ))
  end
  local header = blurred and "<!-- blurred: true -->\n\n" or ""
  return header .. table.concat(parts, "\n---\n\n")
end

local function serializeTxt()
  local parts = {}
  for i, n in ipairs(notes) do
    table.insert(parts, string.format(
      "[Note %d | id:%s color:%s pinned:%s]\n%s",
      i, n.id, n.color, n.pinned == true and "true" or "false", n.content or ""
    ))
  end
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
        table.insert(notes, {
          id        = n.id,
          content   = type(n.content) == "string" and n.content or "",
          color     = type(n.color) == "string" and n.color or "yellow",
          createdAt = type(n.createdAt) == "number" and n.createdAt or 0,
          pinned    = n.pinned == true,
        })
      end
    end
  end
  if decoded.blurred == true then blurred = true end
end

local function parseMd(raw)
  if raw:match("<!%-%- blurred: true %-%->") then blurred = true end
  for metaJson, body in raw:gmatch("<!%-%- sticky%-notes (%b{}) %-%->(.-)\n%-%-%-") do
    local meta = noctalia.json.decode(metaJson)
    if type(meta) == "table" and type(meta.id) == "string" then
      table.insert(notes, {
        id        = meta.id,
        content   = noctalia.string.trim(body),
        color     = type(meta.color) == "string" and meta.color or "yellow",
        createdAt = type(meta.createdAt) == "number" and meta.createdAt or 0,
        pinned    = meta.pinned == true,
      })
    end
  end
  -- Grab the last note (no trailing ---)
  local lastMeta, lastBody = raw:match("<!%-%- sticky%-notes (%b{}) %-%->(.-)$")
  if lastMeta and lastBody then
    local already = false
    local meta = noctalia.json.decode(lastMeta)
    if type(meta) == "table" and type(meta.id) == "string" then
      for _, n in ipairs(notes) do
        if n.id == meta.id then already = true; break end
      end
      if not already then
        table.insert(notes, {
          id        = meta.id,
          content   = noctalia.string.trim(lastBody),
          color     = type(meta.color) == "string" and meta.color or "yellow",
          createdAt = type(meta.createdAt) == "number" and meta.createdAt or 0,
          pinned    = meta.pinned == true,
        })
      end
    end
  end
end

local function parseTxt(raw)
  if raw:match("%[blurred:true%]") then blurred = true end
  local function insertTxt(id, color, pinnedStr, body)
    table.insert(notes, {
      id        = id,
      content   = noctalia.string.trim(body),
      color     = color,
      createdAt = 0,
      pinned    = pinnedStr == "true",
    })
  end
  -- New format with pinned flag.
  for sectionId, sectionColor, sectionPinned, sectionBody in raw:gmatch(
    "%[Note %d+ | id:([%w_]+) color:([%a]+) pinned:(%a+)%]\n(.-)\n\n%-%-%-%\n"
  ) do
    insertTxt(sectionId, sectionColor, sectionPinned, sectionBody)
  end
  if #notes == 0 then
    -- Legacy format without pinned flag (defaults to unpinned).
    for sectionId, sectionColor, sectionBody in raw:gmatch(
      "%[Note %d+ | id:([%w_]+) color:([%a]+)%]\n(.-)\n\n%-%-%-%\n"
    ) do
      insertTxt(sectionId, sectionColor, "false", sectionBody)
    end
  end
  if #notes == 0 then
    -- Fallback: last (or only) section has no trailing ---.
    for sectionId, sectionColor, sectionPinned, sectionBody in raw:gmatch(
      "%[Note %d+ | id:([%w_]+) color:([%a]+) pinned:(%a+)%]\n(.*)"
    ) do
      insertTxt(sectionId, sectionColor, sectionPinned, sectionBody)
    end
  end
  if #notes == 0 then
    for sectionId, sectionColor, sectionBody in raw:gmatch(
      "%[Note %d+ | id:([%w_]+) color:([%a]+)%]\n(.*)"
    ) do
      insertTxt(sectionId, sectionColor, "false", sectionBody)
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
  noctalia.state.set("sticky_notes.blurred", blurred)
  noctalia.state.set("sticky_notes.ready", loaded)
end

-- -------------------------------------------------------------------------
-- Note mutations
-- -------------------------------------------------------------------------
local function makeId()
  return tostring(noctalia.nowMs()) .. tostring(math.random(1000, 9999))
end

local function hasEmptyNote()
  for _, n in ipairs(notes) do
    if noctalia.string.trim(n.content or "") == "" then return true end
  end
  return false
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
  if hasEmptyNote() then
    -- Don't pile up empty notes; surface the existing empty one instead.
    publish()
    return
  end
  local color = noctalia.getConfig("default_color") or "yellow"
  local note = {
    id        = makeId(),
    content   = "",
    color     = color,
    createdAt = math.floor(noctalia.nowMs() / 1000),
    pinned    = false,
  }
  -- Insert at the top of the unpinned group (right after all pinned notes).
  table.insert(notes, pinnedCount() + 1, note)
  saveData()
  publish()
end

local function removeNote(id)
  for i, n in ipairs(notes) do
    if n.id == id then
      table.remove(notes, i)
      saveData()
      publish()
      return
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
  elseif op == "move" then
    moveTo(cmd.id, cmd.group, cmd.index)
  elseif op == "toggle_blur" then
    toggleBlur()
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

initSavePath(function()
  loadData()
  sortDisplay()
  loaded = true
  publish()
end)
