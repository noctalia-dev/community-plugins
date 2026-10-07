--!nonstrict
-- Noctes service - the one owner of the note list, and the only entry that
-- touches disk.
--
-- It owns no logic of its own: `store` keeps the notes and their file, `desk`
-- keeps the sheets in Noctalia's settings, and this wires the two to the
-- surfaces. Every surface (bar widget, panel, each sheet) is a thin client that
-- reads noctes.* state and mutates through noctes.cmd.
--
-- State published. noctalia.state.set wakes every watcher of a key on every
-- call, whether the value changed or not - the host compares nothing - and
-- every sheet on the desk watches these. So each key is set when it changes
-- and at no other time: a heartbeat, or a publish that resends unchanged keys
-- alongside the one that changed, redraws the whole desk.
--   noctes.notes        -> { { id, key, title, content, color, createdAt, updatedAt }, ... }
--   noctes.ready        -> true once the file has been read
--   noctes.boundKeys    -> { { key, output }, ... } - which notes have a sheet
--   noctes.editing      -> note id the panel should open ("" = nothing selected)
--   noctes.themeColors  -> the plugin-wide switch, mirrored for the sheets
--   noctes.paperOpacity -> likewise
--   noctes.sheetsReady  -> false when the helper cannot run, so no sheet can be
--                          drawn and the panel says so instead of offering one
--
-- A note's `key` is the handle a sheet binds to, so it survives the list
-- reordering. Keys are unique; "" means the note has no sheet.
--
-- Commands accepted on noctes.cmd:
--   { op = "spawn_widget", near? }       -- note and sheet together, on the
--                                       -- screen holding the sheet keyed `near`
--   { op = "ensure", key }              -- select the note with that key,
--                                       -- creating it if absent
--   { op = "update", id, title?, content?, color? }
--   { op = "remove", id }               -- takes the sheet down too
--   { op = "set_color", id, color }     -- "" clears to automatic
--   { op = "toggle_edit" }              -- Noctalia's widget editor
--   { op = "refresh" }                  -- re-read the sheet list
--   { op = "reload" }                   -- re-read notes.json
--   { op = "gather" }                   -- sheets off a dead output

local store = require("./store.luau")
local desk = require("./desk.luau")

-- nil until the first read, so that read is published even when it finds no
-- sheets: the state store outlives this service, and can still hold the list
-- a previous run published.
local boundKeys = nil

-- The save_path the notes were last read under.
local savePath = nil

-- ── Publishing ──────────────────────────────────────────────────────────────

local published = {}

-- For the scalar keys: set only when the value differs from the last one set.
local function publishValue(key, value)
  if published[key] == value then
    return
  end
  published[key] = value
  noctalia.state.set(key, value)
end

-- Called only after the list changed; every caller checks that first.
local function publishNotes()
  noctalia.state.set("noctes.notes", store.notes)
end

-- The plugin-wide look, mirrored into state for the sheets: a desktop widget's
-- getConfig sees its own settings, not the plugin's.
local function publishPrefs()
  publishValue("noctes.themeColors", noctalia.getConfig("theme_colors") == true)
  publishValue("noctes.paperOpacity", tonumber(noctalia.getConfig("paper_opacity")) or 0.96)
end

local function sameBound(a, b)
  if a == nil or b == nil or #a ~= #b then
    return false
  end
  for index, entry in ipairs(a) do
    if entry.key ~= b[index].key or entry.output ~= b[index].output then
      return false
    end
  end
  return true
end

-- The panel has no keyboard-less way in: a sheet that creates a note has to
-- hand it over for editing.
local function select(id)
  noctalia.state.set("noctes.editing", id)
end

local refreshBoundKeys

-- A sheet added through Noctalia's widget editor arrives with no key, square
-- and framed, because those are fields a plugin cannot set as it is created.
-- Adopting them here is what keeps that route working without a file watcher.
-- The sheet list is re-read afterwards whether or not the helper ran.
local function tidySheets()
  local started = desk.scatter(store.keys(), function()
    refreshBoundKeys(false)
  end)
  if not started then
    refreshBoundKeys(false)
  end
end

-- Deleting a sheet in Noctalia's widget editor deletes its note. A note is
-- only ever reached through its sheet, so one whose sheet is gone is a note
-- nobody can see again, and the post-it was deleted the way the host deletes
-- one - the same as the panel's bin, which also takes both.
--
-- Only a sheet this machine has seen counts: see desk.remembered. And only
-- one that is gone from widget_order as well as from its table, since a read
-- that caught the file half-written lacks the tables at the end but still
-- lists them up top.
local function removeNoteOnly(id)
  if store.remove(id) == nil then
    return
  end
  publishNotes()
  if noctalia.state.get("noctes.editing") == id then
    select("")
  end
end

local function forgetDeletedSheets(bound, listed)
  local current = {}
  for _, sheet in ipairs(bound) do
    current[sheet.key] = sheet.id
  end

  local seen = desk.remembered()
  local kept, gone, total = {}, {}, 0
  for key, id in pairs(seen) do
    total = total + 1
    if current[key] == nil then
      if listed[id] then
        kept[key] = id
      else
        table.insert(gone, key)
      end
    end
  end

  -- Every sheet this machine knew, gone in one read, is not someone deleting
  -- post-its in the editor: it is a reset or replaced settings.toml. The notes
  -- stay, and what is forgotten is which sheets they had.
  if #gone > 1 and #gone == total then
    noctalia.log("noctes: every known sheet is gone at once; keeping their notes")
    gone = {}
  end

  for _, key in ipairs(gone) do
    local note = store.byKey(key)
    if note ~= nil then
      removeNoteOnly(note.id)
    end
  end

  local changed = #gone > 0
  for key, id in pairs(current) do
    kept[key] = id
    changed = changed or seen[key] ~= id
  end
  for key in pairs(seen) do
    changed = changed or kept[key] == nil
  end
  if changed then
    desk.remember(kept)
  end
end

refreshBoundKeys = function(adopt)
  desk.boundKeys(function(bound, loose, listed)
    forgetDeletedSheets(bound, listed or {})
    if not sameBound(bound, boundKeys) then
      boundKeys = bound
      noctalia.state.set("noctes.boundKeys", boundKeys)
    end
    if loose > 0 and adopt ~= false then
      tidySheets()
    end
  end)
end

local function keyIsBound(key)
  for _, bound in ipairs(boundKeys or {}) do
    if bound.key == key then
      return true
    end
  end
  return false
end

-- A sheet the helper has just made is on the desk now, whatever the next read
-- of settings.toml says. Published before the note that goes with it, so the
-- panel never flashes that note as "not on screen" while the file is re-read.
local function markBound(key, output)
  if keyIsBound(key) then
    return
  end
  local next = {}
  for _, bound in ipairs(boundKeys or {}) do
    table.insert(next, bound)
  end
  table.insert(next, { key = key, output = output or "?" })
  boundKeys = next
  noctalia.state.set("noctes.boundKeys", boundKeys)
end

-- ── Commands ────────────────────────────────────────────────────────────────

local function addNote(fields)
  local note = store.add(fields)
  publishNotes()
  select(note.id)
  return note
end

local function updateNote(id, fields)
  if store.update(id, fields) ~= nil then
    publishNotes()
  end
end

-- The panel's bin: the note and its sheet together.
local function removeNote(id)
  local note = store.byId(id)
  if note == nil then
    return
  end
  local key = note.key or ""
  removeNoteOnly(id)
  if key ~= "" then
    desk.remove(key, function()
      refreshBoundKeys()
    end)
  end
end

-- Note and sheet in one go: the sheet is created first, because the helper is
-- what picks a key that nothing else holds. `fields` is what the note starts
-- with - the text of an IPC `new`.
--
-- With no helper there is no sheet, and the note is still the point: it is
-- created loose, the panel edits it like any other, and it gets its sheet at
-- the first start where the helper runs (stickLooseNotes).
--
-- `near` is the key of the note the panel was showing. The new sheet lands on
-- that one's screen, because that is the screen its owner is looking at.
local function spawnWidget(near, fields)
  local content = fields ~= nil and fields.content or nil
  local started = desk.add({ avoid = store.keys(), near = near }, function(key, output)
    markBound(key, output)
    addNote({ key = key, content = content })
    refreshBoundKeys()
  end)

  if started == false then
    addNote({ content = content })
  end
end

-- A note with no sheet at all, made while python3 was missing, is a note
-- nobody can reach once another one is newer: the panel has no list, and it
-- has no key to name over IPC. So once the helper answers, each one gets a
-- sheet, the way New would have given it one.
--
-- One at a time. The helper serializes them anyway, and a failure then stops
-- the round after its one notification instead of raising one per note; the
-- next start tries again.
local function stickLooseNotes()
  local loose = nil
  for _, note in ipairs(store.notes) do
    if (note.key or "") == "" then
      loose = note
      break
    end
  end
  if loose == nil then
    return
  end

  local id = loose.id
  desk.add({ avoid = store.keys() }, function(key, output)
    markBound(key, output)
    if store.setKey(id, key) ~= nil then
      publishNotes()
    end
    refreshBoundKeys()
    stickLooseNotes()
  end)
end

-- Gives a sheet back to a note whose own was deleted from Noctalia's widget
-- editor. No button offers this - it is the `stick` IPC event, by key, for the
-- note that would otherwise have no way back onto the desk.
--
-- A key already on the desk is left alone: two sheets on one key would both
-- draw the same note. The helper refuses a second sheet for a key as well, so
-- a keybind pressed twice before it answers still makes one.
local function stickKey(key)
  if store.byKey(key) == nil or keyIsBound(key) then
    return
  end
  desk.add({ key = key, avoid = store.keys() }, function(_, output)
    markBound(key, output)
    refreshBoundKeys()
  end)
end

-- Sheets bound to a disconnected output are on no screen at all, and sheets
-- that were moved off one go back when it returns. Nothing else moves, so this
-- is safe on every output change.
local function gatherSheets()
  desk.gather(function(result)
    if result.exitCode == 0 then
      refreshBoundKeys()
    end
  end)
end

-- Called by a sheet that has no note yet: it knows its key, not whether
-- anything answers to it.
local function ensureKey(key)
  if type(key) ~= "string" or key == "" then
    return
  end
  local existing = store.byKey(key)
  if existing ~= nil then
    select(existing.id)
    return
  end
  addNote({ key = key })
end

-- ── Loading ─────────────────────────────────────────────────────────────────

local function configuredPath()
  return noctalia.string.trim(noctalia.getConfig("save_path") or "")
end

local function tiltWanted()
  return noctalia.getConfig("tilt") ~= false
end

-- A notes.json that would not read was moved aside, or could not even be
-- that. Either way its owner has to know: the notes in it are not on screen.
local function reportUnreadable(problem)
  if problem == nil then
    return
  end
  local body = problem.moved and "notify.unreadable.moved" or "notify.unreadable.stuck"
  noctalia.notifyError(noctalia.tr("notify.unreadable.title"),
    noctalia.tr(body, { path = problem.path }))
end

local function loadNotes()
  savePath = configuredPath()
  store.useDirectory()
  reportUnreadable(store.load())
  publishNotes()
  publishValue("noctes.ready", store.ready)
end

local function reload()
  loadNotes()
  refreshBoundKeys()
end

-- ── Wiring ──────────────────────────────────────────────────────────────────

noctalia.state.watch("noctes.cmd", function(cmd)
  if type(cmd) ~= "table" then
    return
  end

  local op = cmd.op
  if op == "spawn_widget" then
    spawnWidget(cmd.near)
  elseif op == "ensure" then
    ensureKey(cmd.key)
  elseif op == "update" then
    updateNote(cmd.id, cmd)
  elseif op == "set_color" then
    updateNote(cmd.id, { color = cmd.color })
  elseif op == "remove" then
    removeNote(cmd.id)
  elseif op == "toggle_edit" then
    desk.toggleEditor()
  elseif op == "refresh" then
    refreshBoundKeys()
  elseif op == "gather" then
    gatherSheets()
  elseif op == "reload" then
    reload()
  end
end)

-- For keybinds and scripts:
--   noctalia msg plugin remo/noctes:service all desk
--   noctalia msg plugin remo/noctes:service all new ["text"]   -- desk, with text
--   noctalia msg plugin remo/noctes:service all open <key>
--   noctalia msg plugin remo/noctes:service all move
--   noctalia msg plugin remo/noctes:service all stick <key>
--   noctalia msg plugin remo/noctes:service all gather
--   noctalia msg plugin remo/noctes:service all reload
function onIpc(event, payload)
  if event == "desk" then
    spawnWidget()
  elseif event == "new" then
    spawnWidget(nil, { content = payload })
  elseif event == "open" then
    ensureKey(noctalia.string.trim(payload or ""))
  elseif event == "move" then
    desk.toggleEditor()
  elseif event == "stick" then
    stickKey(noctalia.string.trim(payload or ""))
  elseif event == "gather" then
    gatherSheets()
  elseif event == "reload" then
    reload()
  end
end

-- A monitor came or went. A sheet bound to the connector that left is still in
-- settings.toml and still bound to a note, and is drawn on nothing at all, so
-- it comes to a screen that exists - and goes back when its own returns.
function onOutputsChanged()
  gatherSheets()
end

-- Settings changed. The host calls this in place, without restarting the
-- service, for every change - each step of the opacity slider is one. Only a
-- new save_path means reading the notes again; re-reading and republishing
-- them for anything else would redraw every sheet on the desk for nothing.
function onConfigChanged()
  publishPrefs()
  desk.syncTilt(tiltWanted())
  if configuredPath() ~= savePath then
    reload()
  end
end

function update()
  store.flush()
end

function onExit()
  store.flush()
end

noctalia.setUpdateInterval(2000)

select("")
publishPrefs()
desk.probe(function(ready)
  publishValue("noctes.sheetsReady", ready)
  if ready then
    stickLooseNotes()
  end
end)
desk.syncTilt(tiltWanted())
loadNotes()
-- Once per start: adopt keyless sheets, and drop settings an older noctes left
-- on its sheets, which the host would otherwise warn about on every load.
tidySheets()
