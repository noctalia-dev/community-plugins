--!nonstrict
-- The loaded config snapshot plus every unsaved edit, and the change set sent to the helper on save.
local choices = require("./choices.luau")
local format = require("../ui/format.luau")

local M = {}

M.meta = nil         -- pages, groups, fields, editors, actions (from `meta`)
M.searchIndex = nil  -- { { id, lowercased text } } loaded on first search
M.state = nil        -- last `read` snapshot
M.fieldChanges = {}  -- field id -> { value = v } or { unset = true }
M.entries = {}       -- editor id -> working copy of entry items
M.entryOps = {}      -- ordered entry operations, replayed by the helper
M.maps = {}          -- map editor id -> working { name, text } rows
M.mapOps = {}
M.keybinds = nil     -- working { rows, groups }
M.keybindsDirty = false
M.desktop = nil      -- { userdirs = {...}, apps = {...} }
M.rebuild = nil      -- nil follows the file (banners present), else true/false
M.history = {}       -- undo steps, newest last (see M.undo)
M.future = {}        -- redo steps, next last (see M.redo); valid while `serial` is unchanged

local function deepCopy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = deepCopy(item) end
  return result
end
M.deepCopy = deepCopy

local function equal(a, b)
  if type(a) ~= type(b) then
    -- an absent table value and an empty one are the same to TOML lists
    if type(a) == "table" and b == nil then return next(a) == nil end
    if type(b) == "table" and a == nil then return next(b) == nil end
    return false
  end
  if type(a) ~= "table" then return a == b end
  for key, item in pairs(a) do
    if not equal(item, b[key]) then return false end
  end
  for key in pairs(b) do
    if a[key] == nil then return false end
  end
  return true
end

M.equal = equal  -- deep equality (revisions are tables)

local function normalizeColor(value)
  if type(value) ~= "string" or not string.match(value, "^#%x+$") then return nil end
  if #value == 7 then return string.upper(value) .. "FF" end
  if #value == 9 then return string.upper(value) end
  return nil
end

-- ------------------------------------------------------------------ fields
local function field(fid) return M.meta and M.meta.fields[fid] end

-- Current value of a page field and whether its key is set.
function M.value(fid)
  local change = M.fieldChanges[fid]
  if change then
    if change.unset then return nil, false end
    return change.value, true
  end
  local base = M.state and M.state.fields[fid]
  return base, base ~= nil
end

function M.isChanged(fid) return M.fieldChanges[fid] ~= nil end

-- ------------------------------------------------------------------ history
local HISTORY_LIMIT = 50

-- Every edit bumps `serial`; a save remembers it (saveMark) so edits made while it runs survive (markSaved).
M.serial = 0
local keybindsSerial = 0

-- Steps recorded inside M.group (nil otherwise): they become one step, and never merge with an older one.
local grouping = nil

local function remember(step)
  if grouping then table.insert(grouping, step); return end
  table.insert(M.history, step)
  if #M.history > HISTORY_LIMIT then table.remove(M.history, 1) end
end

-- The newest step that an edit may merge into.
local function topStep()
  if grouping then return grouping[#grouping] end
  return M.history[#M.history]
end

-- Runs `fn`, recording every edit it makes as one undo step (e.g. a default display: its entry and a field).
function M.group(fn)
  if grouping then return fn() end
  grouping = {}
  local ok, err = pcall(fn)
  local steps = grouping
  grouping = nil
  if #steps == 1 then remember(steps[1])
  elseif #steps > 1 then remember({ kind = "group", steps = steps }) end
  if not ok then error(err, 0) end
end

-- Repeated edits of one value (typing, slider drags) are one step: only the first records what it replaces.
local function rememberField(fid)
  M.serial = M.serial + 1
  local top = topStep()
  if top and top.kind == "field" and top.id == fid then return end
  remember({ kind = "field", id = fid, previous = deepCopy(M.fieldChanges[fid]) })
end

function M.setField(fid, value)
  rememberField(fid)
  local base = M.state and M.state.fields[fid]
  if base ~= nil and equal(base, value) then
    M.fieldChanges[fid] = nil
  else
    M.fieldChanges[fid] = { value = value }
  end
end

function M.unsetField(fid)
  rememberField(fid)
  local base = M.state and M.state.fields[fid]
  M.fieldChanges[fid] = base ~= nil and { unset = true } or nil
end

function M.revertField(fid)
  rememberField(fid)
  M.fieldChanges[fid] = nil
end

function M.differs(field, value)
  if value == nil then return false end
  if field.kind == "color" then
    local a, b = normalizeColor(value), normalizeColor(field.default)
    if a and b then return a ~= b end
  end
  return not equal(value, field.default)
end

function M.isOverridden(fid)
  local value, set = M.value(fid)
  return set and M.differs(field(fid), value)
end

function M.groupCounts(fids)
  local changed, overridden = 0, 0
  for _, fid in ipairs(fids) do
    if M.fieldChanges[fid] then changed = changed + 1 end
    if M.isOverridden(fid) then overridden = overridden + 1 end
  end
  return changed, overridden
end

-- ------------------------------------------------------------------ entries
-- Display title for an entry, following the app's rules for automatic names.
function M.entryTitle(eid, index, item)
  if M.meta.editors[eid].mode == "map" then return tostring(item.name), false end
  local prefix = tostring(index) .. ". "
  if item.label and item.label ~= "" then return prefix .. item.label, false end
  local values = item.values or {}
  if values.name ~= nil and values.name ~= "" then return prefix .. tostring(values.name), false end
  for _, key in ipairs({ "app_id", "title", "namespace" }) do
    local value = values["match." .. key]
    if value ~= nil and value ~= "" then return prefix .. format.readableMatch(key, value), true end
  end
  if values.index ~= nil then return prefix .. "Workspace " .. tostring(values.index), true end
  for path, value in pairs(values) do
    if string.sub(path, 1, 6) == "match." and type(value) == "boolean" then
      local word = string.gsub(string.gsub(string.sub(path, 7), "^is_", ""), "_", " ")
      return prefix .. (value and word or ("not " .. word)), true
    end
  end
  return prefix .. "(matches everything)", true
end

function M.entryItems(eid) return M.entries[eid] or {} end

local function applyEntryOp(items, op)
  local kind = op.op
  if kind == "add" then
    table.insert(items, { name = op.name, label = "", values = {} })
  elseif kind == "remove" then
    table.remove(items, op.index + 1)
  elseif kind == "move" then
    local item = table.remove(items, op.index + 1)
    table.insert(items, op.to + 1, item)
  elseif kind == "duplicate" then
    local copy = deepCopy(items[op.index + 1])
    copy.label = ""
    if op.name then copy.name = op.name; table.insert(items, copy)
    else table.insert(items, op.index + 2, copy) end
  elseif kind == "label" then
    items[op.index + 1].label = op.text
  elseif kind == "set" then
    items[op.index + 1].values[op.field] = op.value
  elseif kind == "unset" then
    items[op.index + 1].values[op.field] = nil
  end
end

-- Apply an entry operation locally and record it for the helper.
function M.entryOp(eid, op)
  M.serial = M.serial + 1
  applyEntryOp(M.entries[eid], op)
  op.editor = eid
  local kind = op.op
  local last = M.entryOps[#M.entryOps]
  local top = topStep()
  if (kind == "set" or kind == "label") and last and last.editor == eid and last.op == kind
      and last.index == op.index and last.field == op.field then
    -- a batch (a display arrangement) stays its own step: typing after it is a new one
    if not (top and top.kind == "entry" and top.editor == eid and not top.batch) then
      remember({ kind = "entry", editor = eid, ops = { table.unpack(M.entryOps) } })
    end
    M.entryOps[#M.entryOps] = op  -- typing replaces the previous edit of the same value
  else
    remember({ kind = "entry", editor = eid, ops = { table.unpack(M.entryOps) } })
    table.insert(M.entryOps, op)
  end
end

local SHIFTS = { remove = true, move = true, duplicate = true }  -- ops that change later entries' indexes

-- Drops a pending set/unset of the same entry value as `op` (it replaces it), unless entries moved since.
local function dropReplaced(eid, op)
  for i = #M.entryOps, 1, -1 do
    local old = M.entryOps[i]
    if old.editor == eid then
      if SHIFTS[old.op] then return end
      if (old.op == "set" or old.op == "unset") and old.index == op.index and old.field == op.field then
        table.remove(M.entryOps, i)
        return
      end
    end
  end
end

-- Several entry operations as one undo step (a display arrangement writes every display's position). A set
-- replaces a pending edit of the same value, so dragging displays around doesn't pile up changes.
function M.entryOpsBatch(eid, ops)
  if #ops == 0 then return end
  M.serial = M.serial + 1
  remember({ kind = "entry", editor = eid, ops = { table.unpack(M.entryOps) }, batch = true })
  for _, op in ipairs(ops) do
    applyEntryOp(M.entries[eid], op)
    op.editor = eid
    if op.op == "set" or op.op == "unset" then dropReplaced(eid, op) end
    table.insert(M.entryOps, op)
  end
end

local function countOps(ops, eid)
  local count = 0
  for _, op in ipairs(ops) do
    if op.editor == eid then count = count + 1 end
  end
  return count
end

-- A copy of the snapshot's entry items (or map rows) of one editor with that editor's recorded ops replayed.
local function replayEditor(items, ops, apply, eid)
  items = deepCopy(items)
  for _, op in ipairs(ops) do
    if op.editor == eid then apply(items, op) end
  end
  return items
end

-- The same for every editor at once.
local function replayAll(snapshot, ops, apply)
  local result = deepCopy(snapshot)
  for _, op in ipairs(ops) do
    if result[op.editor] then apply(result[op.editor], op) end
  end
  return result
end

function M.entryOpCount(eid) return countOps(M.entryOps, eid) end

-- ------------------------------------------------------------------ maps
function M.mapRows(eid) return M.maps[eid] or {} end

local function applyMapOp(rows, op)
  if op.op == "set" then
    local found = false
    for _, row in ipairs(rows) do
      if row[1] == (op.from or op.name) then row[1] = op.name; row[2] = op.value; found = true end
    end
    if not found then table.insert(rows, { op.name, op.value }) end
  else
    for index, row in ipairs(rows) do
      if row[1] == op.name then table.remove(rows, index); break end
    end
  end
end

local function mapOp(op)
  M.serial = M.serial + 1
  remember({ kind = "map", editor = op.editor, ops = { table.unpack(M.mapOps) } })
  applyMapOp(M.maps[op.editor], op)
  table.insert(M.mapOps, op)
end

function M.mapSet(eid, name, text, from)
  mapOp({ editor = eid, op = "set", name = name, value = text, from = from })
end

function M.mapRemove(eid, name)
  mapOp({ editor = eid, op = "remove", name = name })
end

function M.mapOpCount(eid) return countOps(M.mapOps, eid) end

-- Names the config defines, for choices (see choices.luau).
function M.namedChoices(kind, base, extra) return choices.named(M, kind, base, extra) end

-- ------------------------------------------------------------------ keybinds
-- The keybinds page edits rows in place and then calls this; `shadow` is the list as of the last recorded
-- step, which is what an undo returns to. `step` names the edit (e.g. "key:3"); repeats of it are one step.
local shadow = nil
function M.keybindsChanged(step)
  M.serial = M.serial + 1
  keybindsSerial = M.serial
  local top = topStep()
  if not (step and top and top.kind == "keybinds" and top.step == step) then
    local before = shadow or { rows = {}, groups = {} }
    remember({ kind = "keybinds", step = step, rows = before.rows, groups = before.groups, dirty = M.keybindsDirty })
  end
  M.keybindsDirty = true
  shadow = deepCopy(M.keybinds)
end

local function resetKeybinds(source)
  M.keybinds = { rows = deepCopy(source.rows), groups = deepCopy(source.groups) }
  shadow = deepCopy(M.keybinds)
end

-- Drafted keybinds replace the working list as one unsaved change.
function M.restoreKeybinds(keybinds)
  resetKeybinds(keybinds)
  M.keybindsDirty = true
end

-- ------------------------------------------------------------------ desktop
local function desktopTable(part)
  local d = M.desktop
  if part == "userdirs" then return d.userdirs.values end
  return part == "roles" and d.apps.roles or d.apps.mimes
end

-- part: "userdirs" (folder key), "roles" (role name) or "mimes" (MIME type).
function M.setDesktop(part, key, value)
  M.serial = M.serial + 1
  local values = desktopTable(part)
  local top = topStep()
  if not (top and top.kind == "desktop" and top.part == part and top.key == key) then
    remember({ kind = "desktop", part = part, key = key, previous = values[key] })
  end
  values[key] = value
end

function M.desktopChanges()
  local d = M.desktop
  if not d then return nil end
  local request, any = {}, false
  local folders = {}
  for key, value in pairs(d.userdirs.values) do
    if value ~= (d.userdirs.original[key] or "") then folders[key] = value; any = true end
  end
  for key in pairs(d.userdirs.original) do
    if d.userdirs.values[key] == nil then folders[key] = ""; any = true end
  end
  if next(folders) then request.userdirs = { revision = d.userdirs.revision, changes = folders } end
  local apps = {}
  for role, value in pairs(d.apps.roles) do
    if value ~= (d.apps.originalRoles[role] or "") and value ~= "<multiple>" then
      table.insert(apps, { kind = "role", key = role, value = value })
    end
  end
  for mime, value in pairs(d.apps.mimes) do
    if value ~= (d.apps.originalMimes[mime] or "") then
      table.insert(apps, { kind = "mime", key = mime, value = value })
    end
  end
  if #apps > 0 then request.apps = { revision = d.apps.revision, changes = apps }; any = true end
  return any and request or nil
end

-- ------------------------------------------------------------------ undo
-- The step that puts back what `step` is about to change (for redo).
local function inverse(step)
  if step.kind == "field" then return { kind = "field", id = step.id, previous = deepCopy(M.fieldChanges[step.id]) } end
  if step.kind == "entry" then return { kind = "entry", editor = step.editor, ops = { table.unpack(M.entryOps) } } end
  if step.kind == "map" then return { kind = "map", editor = step.editor, ops = { table.unpack(M.mapOps) } } end
  if step.kind == "keybinds" then
    return { kind = "keybinds", step = step.step, rows = deepCopy(M.keybinds.rows), groups = deepCopy(M.keybinds.groups),
             dirty = M.keybindsDirty }
  end
  return { kind = "desktop", part = step.part, key = step.key,
           previous = M.desktop and desktopTable(step.part)[step.key] or nil }
end

-- Applies `step` and returns its inverse. A group's parts run newest first; the inverse lists their inverses
-- in that order, so applying it runs them oldest first.
local function undoStep(step)
  if step.kind == "group" then
    local back = {}
    for i = #step.steps, 1, -1 do table.insert(back, undoStep(step.steps[i])) end
    return { kind = "group", steps = back }
  end
  local back = inverse(step)
  if step.kind == "keybinds" then keybindsSerial = M.serial end
  if step.kind == "field" then
    M.fieldChanges[step.id] = step.previous
  elseif step.kind == "entry" then
    M.entryOps = step.ops
    M.entries[step.editor] = replayEditor(M.state.editors[step.editor], M.entryOps, applyEntryOp, step.editor)
  elseif step.kind == "map" then
    M.mapOps = step.ops
    M.maps[step.editor] = replayEditor(M.state.maps[step.editor], M.mapOps, applyMapOp, step.editor)
  elseif step.kind == "keybinds" then
    resetKeybinds(step)
    M.keybindsDirty = step.dirty
  elseif step.kind == "desktop" then
    if M.desktop then desktopTable(step.part)[step.key] = step.previous end
  end
  return back
end

local futureSerial = nil  -- `serial` after the last undo/redo: any edit since then drops the redo steps

-- Reverts the newest step; returns false when there is nothing to undo.
function M.undo()
  local step = table.remove(M.history)
  if not step then return false end
  if futureSerial ~= M.serial then M.future = {} end
  M.serial = M.serial + 1
  table.insert(M.future, undoStep(step))
  futureSerial = M.serial
  return true
end

function M.canRedo() return #M.future > 0 and futureSerial == M.serial end

-- Re-applies the newest undone step; returns false when there is none (or an edit came after the undo).
function M.redo()
  if not M.canRedo() then return false end
  M.serial = M.serial + 1
  table.insert(M.history, undoStep(table.remove(M.future)))
  futureSerial = M.serial
  return true
end

function M.canUndo() return #M.history > 0 end

-- ------------------------------------------------------------------ totals
function M.pendingCount()
  local count = #M.entryOps + #M.mapOps
  for _ in pairs(M.fieldChanges) do count = count + 1 end
  if M.keybindsDirty then count = count + 1 end
  local desktop = M.desktopChanges()
  if desktop then
    if desktop.userdirs then for _ in pairs(desktop.userdirs.changes) do count = count + 1 end end
    if desktop.apps then count = count + #desktop.apps.changes end
  end
  return count
end

function M.hasConfigChanges()
  return next(M.fieldChanges) ~= nil or #M.entryOps > 0 or #M.mapOps > 0 or M.keybindsDirty
end

function M.changeSet()
  local changes = { revision = M.state.revision, fields = M.fieldChanges, entries = M.entryOps, maps = M.mapOps }
  if M.keybindsDirty then
    local rows, locks = {}, {}
    for _, row in ipairs(M.keybinds.rows) do
      table.insert(rows, { key = row.key, action = row.action, opts = row.opts or {}, group = row.group or "" })
      if row.locked then table.insert(locks, row.key) end
    end
    changes.keybinds = { rows = rows, groups = M.keybinds.groups, locks = locks }
  end
  if M.rebuild ~= nil then changes.rebuild = M.rebuild end
  return changes
end

-- Field changes that the snapshot already holds are no longer changes.
local function dropSavedFieldChanges(state)
  for fid, change in pairs(M.fieldChanges) do
    local base = state.fields[fid]
    if (change.unset and base == nil) or (not change.unset and equal(change.value, base)) then
      M.fieldChanges[fid] = nil
    end
  end
end

-- Replace the snapshot. Field edits survive a reload; index-based edits survive only when the
-- file is unchanged, since rules may have moved. Returns a note when edits were dropped.
function M.load(state)
  local previous = M.state
  local sameFile = previous ~= nil and previous.path == state.path
  local unchanged = sameFile and equal(previous.revision, state.revision)
  local dropped = false
  if not sameFile then
    M.fieldChanges = {}
  else
    dropSavedFieldChanges(state)
  end
  if not unchanged then
    dropped = #M.entryOps > 0 or #M.mapOps > 0 or M.keybindsDirty
    M.entryOps, M.mapOps, M.keybindsDirty = {}, {}, false
  end
  M.state = state
  if not unchanged or not M.keybinds then
    M.entries = deepCopy(state.editors)
    M.maps = deepCopy(state.maps)
    resetKeybinds(state.keybinds)
    M.history, M.future = {}, {}  -- steps of the old snapshot can't be replayed on this one
  end
  if dropped then return "The config changed on disk; rule, curve and keybind edits were discarded." end
  return nil
end

-- What a save is about to write; pass it back to markSaved when the save succeeds.
function M.saveMark()
  return { serial = M.serial, entries = #M.entryOps, maps = #M.mapOps }
end

local function rest(list, from)
  local out = {}
  for i = from + 1, #list do table.insert(out, list[i]) end
  return out
end

-- After a successful save: take the saved snapshot and drop only what that save wrote. Edits made while it
-- ran stay pending, replayed on the new snapshot (the saved ops are a prefix of the op lists, so the newer
-- ones still apply). Returns true when such newer edits exist.
function M.markSaved(state, mark)
  local newer = M.serial ~= mark.serial
  local entryOps, mapOps = rest(M.entryOps, mark.entries), rest(M.mapOps, mark.maps)
  local keepKeybinds = newer and M.keybindsDirty and keybindsSerial > mark.serial
  M.state = state
  dropSavedFieldChanges(state)
  M.entryOps, M.mapOps = entryOps, mapOps
  M.entries = replayAll(state.editors, entryOps, applyEntryOp)
  M.maps = replayAll(state.maps, mapOps, applyMapOp)
  if keepKeybinds then
    shadow = deepCopy(M.keybinds)
  else
    resetKeybinds(state.keybinds)
    M.keybindsDirty = false
  end
  M.history, M.future = {}, {}  -- older steps refer to the previous snapshot
  return newer
end

function M.discardAll()
  M.fieldChanges, M.entryOps, M.mapOps, M.keybindsDirty = {}, {}, {}, false
  M.desktopDraft = nil
  M.history, M.future = {}, {}
  if M.state then
    M.entries = deepCopy(M.state.editors)
    M.maps = deepCopy(M.state.maps)
    resetKeybinds(M.state.keybinds)
  end
  if M.desktop then
    M.desktop.userdirs.values = deepCopy(M.desktop.userdirs.original)
    M.desktop.apps.roles = deepCopy(M.desktop.apps.originalRoles)
    M.desktop.apps.mimes = deepCopy(M.desktop.apps.originalMimes)
  end
end

-- Desktop edits from a draft wait here until the desktop files are loaded (see drafts.restore).
M.desktopDraft = nil

-- Puts drafted desktop edits back when the files are unchanged; returns a message or nil.
function M.applyDesktopDraft(draft)
  local d, before = M.desktop, M.desktopChanges()
  local skipped = false
  if type(draft.userdirs) == "table" then
    if draft.userdirs.revision == d.userdirs.revision then
      d.userdirs.values = deepCopy(draft.userdirs.values or {})
    else
      skipped = true
    end
  end
  if type(draft.apps) == "table" then
    if draft.apps.revision == d.apps.revision then
      d.apps.roles = deepCopy(draft.apps.roles or {})
      d.apps.mimes = deepCopy(draft.apps.mimes or {})
    else
      skipped = true
    end
  end
  if skipped then return "User folders or default apps changed on disk; their unsaved edits were discarded." end
  if M.desktopChanges() and not before then return "Restored unsaved user folder and default app edits." end
  return nil
end

-- Returns a message when drafted desktop edits were restored or dropped.
function M.loadDesktop(data)
  local apps = data.apps
  M.desktop = {
    userdirs = { values = deepCopy(data.userdirs.values), original = deepCopy(data.userdirs.values),
                 revision = data.userdirs.revision },
    apps = { roles = deepCopy(apps.roles), originalRoles = deepCopy(apps.roles), mimes = deepCopy(apps.mimes),
             originalMimes = deepCopy(apps.mimes), revision = apps.revision, apps = apps.apps,
             names = apps.names or {},  -- names of assigned apps missing from `apps` (NoDisplay)
             roleMimes = apps.role_mimes, extensions = apps.extensions or {} },
  }
  local draft = M.desktopDraft
  M.desktopDraft = nil
  return draft and M.applyDesktopDraft(draft) or nil
end

-- One desktop part was written (the other may have failed): its values become the saved state.
function M.desktopSaved(part, revision)
  local d = M.desktop
  if not d or type(revision) ~= "string" then return end
  if part == "userdirs" then
    d.userdirs.original, d.userdirs.revision = deepCopy(d.userdirs.values), revision
  else
    d.apps.originalRoles, d.apps.originalMimes = deepCopy(d.apps.roles), deepCopy(d.apps.mimes)
    d.apps.revision = revision
  end
end

-- Both desktop parts were written: drop them until the caller reloads, along with the undo steps
-- that would revert what was just saved.
function M.desktopSavedAll()
  M.desktop = nil
  M.history, M.future = {}, {}
end

return M
