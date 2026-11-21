--!nonstrict
-- Unsaved edits survive a Noctalia restart (or an app crash) as draft.json in the plugin data directory;
-- config edits for another config wait in draft-other-config.json until that config opens.
local store = require("./store.luau")
local kit = require("../ui/kit.luau")

local M = {}

local function dataFile(name)
  local dir = noctalia.pluginDataDir()
  return dir and (dir .. "/" .. name) or nil
end

local function draftPath() return dataFile("draft.json") end
local function parkedPath() return dataFile("draft-other-config.json") end

local function readJson(path)
  local raw = noctalia.readFile(path)
  return raw and noctalia.json.decode(raw)
end

local function restoredNote(count) return "Restored " .. kit.plural(count, "unsaved change") .. " from last time." end

local function desktopDraft()
  local d = store.desktop
  if not d or not store.desktopChanges() then return store.desktopDraft end  -- not loaded yet: keep the pending one
  return { userdirs = { revision = d.userdirs.revision, values = d.userdirs.values },
           apps = { revision = d.apps.revision, roles = d.apps.roles, mimes = d.apps.mimes } }
end

function M.save()
  local path = draftPath()
  if not path or not (store.state or store.desktop) then return end
  local desktop = desktopDraft()
  if store.pendingCount() == 0 and not desktop then
    if noctalia.fileExists(path) then noctalia.removeFile(path) end
    return
  end
  local draft = { desktop = desktop }
  if store.state then
    draft.path, draft.revision, draft.fields = store.state.path, store.state.revision, store.fieldChanges
    draft.entryOps, draft.mapOps = store.entryOps, store.mapOps
    draft.keybinds = store.keybindsDirty and store.keybinds or nil
  end
  local encoded, encodeError = noctalia.json.encode(draft)
  if not encoded then return false, encodeError end
  return noctalia.writeFile(path, encoded)  -- ok, error: the caller decides whether to tell
end

-- Config edits of a draft, applied through the setters; returns how many survived.
local function applyConfigDraft(draft)
  local restored = 0
  for fid, change in pairs(draft.fields or {}) do
    if store.meta.fields[fid] and type(change) == "table" then
      -- Through the setters: an edit that was saved after the draft was written is no change any more.
      if change.unset then
        store.unsetField(fid, change.follow)
      else
        store.setField(fid, change.value, change.follow)
      end
      if store.fieldChanges[fid] then restored = restored + 1 end
    end
  end
  if store.equal(draft.revision, store.state.revision) then
    for _, op in ipairs(draft.entryOps or {}) do store.entryOp(op.editor, op); restored = restored + 1 end
    for _, op in ipairs(draft.mapOps or {}) do
      if op.op == "remove" then store.mapRemove(op.editor, op.name) else store.mapSet(op.editor, op.name, op.value, op.from) end
      restored = restored + 1
    end
    if draft.keybinds then store.restoreKeybinds(draft.keybinds); restored = restored + 1 end
  end
  store.history, store.future = {}, {}  -- the restored draft is where undo stops
  return restored
end

local function hasConfigEdits(draft)
  return next(draft.fields or {}) ~= nil or #(draft.entryOps or {}) > 0 or #(draft.mapOps or {}) > 0
    or draft.keybinds ~= nil
end

-- Re-apply a draft after the first `read`; returns a message or nil. Desktop edits don't depend on the
-- config and are applied when the desktop files load. Config edits for another file than the one that
-- opened are parked (M.restoreParked brings them back when that file is opened), never dropped.
function M.restore()
  local path = draftPath()
  if not path or not noctalia.fileExists(path) or not store.state then return nil end
  local draft = readJson(path)
  if type(draft) ~= "table" then noctalia.removeFile(path) return nil end
  local desktopNote = nil
  if type(draft.desktop) == "table" then
    if store.desktop then desktopNote = store.applyDesktopDraft(draft.desktop) else store.desktopDraft = draft.desktop end
  end
  if draft.path ~= store.state.path then
    local parked = parkedPath()
    if type(draft.path) ~= "string" or not parked or not hasConfigEdits(draft) then
      noctalia.removeFile(path)
      return desktopNote
    end
    draft.desktop = nil
    local encoded = noctalia.json.encode(draft)
    local written, writeError = false, "could not encode them"
    if encoded then written, writeError = noctalia.writeFile(parked, encoded) end
    if not written then  -- draft.json stays, so nothing is lost; it is tried again next time
      return "Unsaved edits for " .. draft.path .. " could not be set aside (" .. tostring(writeError) .. ")."
    end
    noctalia.removeFile(path)
    local note = "Unsaved edits for " .. draft.path .. " were kept; open that config to get them back."
    return desktopNote and (note .. " " .. desktopNote) or note
  end
  noctalia.removeFile(path)
  local restored = applyConfigDraft(draft)
  if restored == 0 then return desktopNote end
  local note = restoredNote(restored)
  return desktopNote and (note .. " " .. desktopNote) or note
end

-- After a config loads: put back parked edits that belong to it (only while it has no edits of its own).
function M.restoreParked()
  local parked = parkedPath()
  if not parked or not store.state or store.hasConfigChanges() or not noctalia.fileExists(parked) then return nil end
  local draft = readJson(parked)
  if type(draft) ~= "table" then noctalia.removeFile(parked) return nil end
  if draft.path ~= store.state.path then return nil end
  noctalia.removeFile(parked)
  local restored = applyConfigDraft(draft)
  if restored == 0 then return nil end
  return restoredNote(restored)
end

return M
