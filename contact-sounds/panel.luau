-- panel.luau
-- Lists the configured contacts with buttons to play, add and delete them.
-- Each row shows a photo/icon (contact photo, group photo or app icon) at the
-- start; folder entries get a menu-list of their sounds. The contact data is
-- owned by the service (see service.luau): it is read from Noctalia's
-- app-managed settings.toml on first run, then synced to the panel through
-- noctalia.state ("contacts.data"). Every mutation (add/edit/delete/reorder)
-- is sent as a command ("contacts.cmd") that the service applies and persists
-- to its own data file — no config-reload, so the panel never closes while
-- editing, exactly like the inventory-manager plugin.

--!nonstrict

local KIND_ORDER = { "contact", "group", "app" }
local SOUND_EXTS = { ogg = true, mp3 = true, wav = true }

local nameDraft = ""
local pathDraft = ""
local soundDraft = "" -- picked sound inside the folder ("" = random)
local imageDraft = ""
local kindDraft = "contact"
local modeDraft = "file" -- "file" | "folder"
local pathInputMode = "existing" -- for folder mode: "existing" | "new"
local formVersion = 0
local showForm = false
local editingName = nil
local pendingDelete = nil
local render

-- Absolute sound path -> duration in seconds, probed lazily by
-- scripts/sound_durations.py. Used to only offer the stop button for long
-- sounds (longer than STOP_DURATION_THRESHOLD).
local durations = {}
local durationBatchPending = false
local STOP_DURATION_THRESHOLD = 5

local function tr(key)
  return noctalia.tr(key)
end

local function shellQuote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- ---------------------------------------------------------------------------
-- Config + filesystem helpers
-- ---------------------------------------------------------------------------

local function cfgMap(key)
  local v = noctalia.getConfig(key) or {}
  local out = {}
  for k, val in pairs(v) do
    out[tostring(k)] = tostring(val)
  end
  return out
end

local function cfgList(key)
  local v = noctalia.getConfig(key) or {}
  if type(v) ~= "table" then
    return {}
  end
  local out = {}
  for _, s in ipairs(v) do
    out[#out + 1] = tostring(s)
  end
  return out
end

local function expandPath(p)
  if p:sub(1, 1) == "~" then
    return noctalia.expandPath(p)
  end
  return p
end

local function fileExt(p)
  local ext = p:match("%.([^./]+)$")
  return ext and ext:lower() or ""
end

local function listSounds(dir)
  local out = {}
  local names = noctalia.listDir(dir)
  if names then
    for _, n in ipairs(names) do
      if SOUND_EXTS[fileExt(n)] then
        out[#out + 1] = n
      end
    end
  end
  table.sort(out)
  return out
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Authoritative contact tables published by the service through noctalia.state
-- ("contacts.data"). Before the first publish (or the fallback label below) the
-- panel reads the same keys from config so the first frame is never empty.
--
-- state.watch only fires on *changes*, so a panel runtime created after the
-- service published (e.g. after a plugin reload) would never learn about the
-- current data and would fall back to the stale settings.toml config — hiding
-- every contact that only exists in the service's state.json. Seed from the
-- in-memory channel up front; the watch below covers future publishes.
local data = noctalia.state.get("contacts.data") -- { contacts, kinds, images, folder_sounds, order, sound_folders }

local function cloneMap(t)
  local out = {}
  for k, v in pairs(t) do
    out[k] = v
  end
  return out
end

local function cloneList(t)
  local out = {}
  for i, v in ipairs(t) do
    out[i] = v
  end
  return out
end

-- The six mutable tables with the current data; used both for rendering and
-- as a base to build the next state after a mutation.
local function dataTables()
  local d = data or noctalia.state.get("contacts.data") or {}
  return {
    contacts      = d.contacts or cfgMap("contacts"),
    kinds         = d.kinds or cfgMap("contact_kinds"),
    images        = d.images or cfgMap("contact_images"),
    folder_sounds = d.folder_sounds or cfgMap("folder_sounds"),
    order         = d.order or cfgList("contact_order"),
    sound_folders = d.sound_folders or cfgList("sound_folders"),
  }
end

-- Builds the next state from copies of the current one after a mutation,
-- updates the published copy optimistically (so the row moves instantly) and
-- hands the full tables to the service via noctalia.state, which persists and
-- republishes — the panel stays open. `seq` lets the service ignore a command
-- that gets delivered twice (around a service restart), so the "saved"
-- notification fires exactly once per action. The counter is kept in the state
-- channel (which survives a panel reload) so it never repeats across reloads.
local cmdSeq = noctalia.state.get("contacts.cmd_seq") or 0
local function sendMutate(next)
  cmdSeq = cmdSeq + 1
  noctalia.state.set("contacts.cmd_seq", cmdSeq)
  noctalia.state.set("contacts.cmd", { op = "mutate", data = next, seq = cmdSeq })
  data = next
  render()
end

local function contacts()
  local out = {}
  local t = dataTables()
  local kinds = t.kinds
  local images = t.images
  local folderSounds = t.folder_sounds
  for name, path in pairs(t.contacts) do
    local entry = {
      name = name,
      path = path,
      kind = kinds[name] or "contact",
      image = images[name],
    }
    local abs = expandPath(path)
    local info = noctalia.fileInfo(abs)
    if info and info.isDir then
      entry.isFolder = true
      entry.folderPath = abs
      entry.sounds = listSounds(abs)
      entry.folderSound = folderSounds[name]
    end
    table.insert(out, entry)
  end
  -- Custom order from the `order` list; anything not listed keeps
  -- alphabetical order after the listed contacts.
  local order = t.order
  local rank = {}
  for i, n in ipairs(order) do
    if not rank[n] then
      rank[n] = i
    end
  end
  table.sort(out, function(a, b)
    local ra, rb = rank[a.name], rank[b.name]
    if ra and rb then
      return ra < rb
    end
    if ra then
      return true
    end
    if rb then
      return false
    end
    return a.name < b.name
  end)
  return out
end

-- ---------------------------------------------------------------------------
-- Sound durations (probed lazily via scripts/sound_durations.py)
-- ---------------------------------------------------------------------------

-- The distinct audio files that can actually play (folder members resolved to
-- their absolute paths), so the stop button can be gated on real durations.
-- Only the picked member is probed when a folder has an explicit selection;
-- random folders probe every member because the next play could be any of them.
local function soundPathsToProbe()
  local out = {}
  local seen = {}
  for _, c in ipairs(contacts()) do
    local list = {}
    if c.isFolder then
      if c.folderSound and c.folderSound ~= "" then
        for _, s in ipairs(c.sounds) do
          if s == c.folderSound then
            list[#list + 1] = c.folderPath .. "/" .. s
            break
          end
        end
      else
        for _, s in ipairs(c.sounds) do
          list[#list + 1] = c.folderPath .. "/" .. s
        end
      end
    else
      list[#list + 1] = expandPath(c.path)
    end
    for i = 1, #list do
      local p = list[i]
      if p ~= "" and not seen[p] then
        seen[p] = true
        out[#out + 1] = p
      end
    end
  end
  return out
end

-- Last path component: the file name shown to the user.
local function fileName(path)
  local base = (path or ""):match("([^/]+)$")
  return base or path or ""
end

-- Sound this contact actually plays, shown as a small caption under the name.
-- Folders show the picked member, or the folder name when picking randomly.
local function contactSoundName(contact)
  if contact.isFolder then
    if contact.folderSound and contact.folderSound ~= "" then
      return fileName(contact.folderSound)
    end
    if #(contact.sounds or {}) == 1 then
      return fileName(contact.sounds[1])
    end
    return tr("panel.random_sound")
  end
  return fileName(contact.path)
end

-- Duration of the sound this contact actually plays, or nil while still
-- unknown. For a folder with a picked sound only that file counts; without a
-- pick the longest member is used as the worst case for the random choice.
local function contactDuration(contact)
  if contact.isFolder then
    if contact.folderSound and contact.folderSound ~= "" then
      return durations[contact.folderPath .. "/" .. contact.folderSound]
    end
    local best = 0
    for _, s in ipairs(contact.sounds) do
      local d = durations[contact.folderPath .. "/" .. s]
      if d and d > best then
        best = d
      end
    end
    if best > 0 then
      return best
    end
    return nil
  end
  return durations[expandPath(contact.path)]
end

-- Probes every sound still missing a cached duration in one async batch and
-- re-renders when it resolves. Called from render(); no-op while a batch is in
-- flight so repeated frames don't pile up subprocesses.
local function ensureDurations()
  local dir = noctalia.pluginDir()
  if not dir or durationBatchPending then
    return
  end
  local missing = {}
  for _, p in ipairs(soundPathsToProbe()) do
    if durations[p] == nil then
      missing[#missing + 1] = p
    end
  end
  if #missing == 0 then
    return
  end
  durationBatchPending = true
  local parts = {}
  for _, p in ipairs(missing) do
    parts[#parts + 1] = shellQuote(p)
  end
  noctalia.runAsync(
    "python3 " .. shellQuote(dir .. "/scripts/sound_durations.py") .. " " .. table.concat(parts, " "),
    function(result)
      durationBatchPending = false
      if result and result.exitCode == 0 and result.stdout then
        local i = 1
        for line in result.stdout:gmatch("[^\n]+") do
          if missing[i] then
            local v = tonumber(line)
            if v then
              durations[missing[i]] = v
            end
          end
          i = i + 1
        end
      end
      render()
    end
  )
end

-- Known sound-folder paths: the registry (persists even when every entry that
-- used a folder is deleted) plus any folder still in use, deduplicated.
local function knownFolders()
  local set = {}
  local t = dataTables()
  for _, path in pairs(t.contacts) do
    local abs = expandPath(path)
    local info = noctalia.fileInfo(abs)
    if info and info.isDir then
      local norm = abs:gsub("/+$", "")
      if #(listSounds(abs) or {}) > 0 then
        set[norm] = true
      end
    end
  end
  for _, path in ipairs(t.sound_folders) do
    if path and path ~= "" then
      local abs = expandPath(path):gsub("/+$", "")
      if abs ~= "" then
        local info = noctalia.fileInfo(abs)
        if info and info.isDir and #(listSounds(abs) or {}) > 0 then
          set[abs] = true
        end
      end
    end
  end
  local list = {}
  for p in pairs(set) do
    table.insert(list, p)
  end
  table.sort(list)
  return list
end

-- ---------------------------------------------------------------------------
-- Editing
-- ---------------------------------------------------------------------------

-- Every mutation is applied to a copy of the current state and handed to the
-- service through noctalia.state (see sendMutate); nothing here touches the
-- filesystem or reloads the config, so the panel never closes while editing.

local function clearForm()
  nameDraft = ""
  pathDraft = ""
  soundDraft = ""
  imageDraft = ""
  kindDraft = "contact"
  modeDraft = "file"
  pathInputMode = "existing"
  editingName = nil
  formVersion = formVersion + 1
end

local function deleteContact(name)
  local t = dataTables()
  t.contacts = cloneMap(t.contacts)
  t.kinds = cloneMap(t.kinds)
  t.images = cloneMap(t.images)
  t.folder_sounds = cloneMap(t.folder_sounds)
  t.order = cloneList(t.order)
  t.contacts[name] = nil
  t.kinds[name] = nil
  t.images[name] = nil
  t.folder_sounds[name] = nil
  for i, n in ipairs(t.order) do
    if n == name then
      table.remove(t.order, i)
      break
    end
  end
  pendingDelete = nil
  sendMutate(t)
end

local function startEdit(contact)
  editingName = contact.name
  nameDraft = contact.name
  pathDraft = contact.path
  soundDraft = contact.folderSound or ""
  imageDraft = contact.image or ""
  kindDraft = contact.kind or "contact"
  modeDraft = contact.isFolder and "folder" or "file"
  pathInputMode = "existing"
  showForm = true
  formVersion = formVersion + 1
  render()
end

local function saveForm()
  local name = trim(nameDraft)
  local path = trim(pathDraft)
  local image = trim(imageDraft)
  if name == "" or path == "" then
    noctalia.notifyError(tr("panel.title"), tr("panel.invalid_contact"))
    return
  end
  if modeDraft == "folder" then
    local abs = expandPath(path)
    local info = noctalia.fileInfo(abs)
    if not (info and info.isDir and #(listSounds(abs) or {}) > 0) then
      noctalia.notifyError(tr("panel.title"), tr("panel.need_sounds"))
      return
    end
  end
  local t = dataTables()
  t.contacts = cloneMap(t.contacts)
  t.kinds = cloneMap(t.kinds)
  t.images = cloneMap(t.images)
  t.folder_sounds = cloneMap(t.folder_sounds)
  t.sound_folders = cloneList(t.sound_folders)
  t.order = cloneList(t.order)

  local renamed = editingName and name ~= editingName
  if renamed then
    t.contacts[editingName] = nil
    t.kinds[editingName] = nil
    t.images[editingName] = nil
    t.folder_sounds[editingName] = nil
    for i, n in ipairs(t.order) do
      if n == editingName then
        t.order[i] = name
        break
      end
    end
  end

  t.contacts[name] = path
  t.kinds[name] = kindDraft or "contact"
  t.images[name] = image
  if modeDraft == "folder" then
    t.folder_sounds[name] = soundDraft or ""
  else
    t.folder_sounds[name] = ""
  end

  if modeDraft == "folder" and path ~= "" and pathInputMode == "new" then
    local abs = trim(expandPath(path):gsub("/+$", ""))
    local found = false
    for _, p in ipairs(t.sound_folders) do
      if p == abs then
        found = true
        break
      end
    end
    if not found then
      table.insert(t.sound_folders, abs)
    end
  end

  if not editingName then
    table.insert(t.order, name)
  end

  editingName = nil
  showForm = false
  sendMutate(t)
end

local function playContact(name)
  local safe = shellQuote(name)
  noctalia.runAsync("noctalia msg plugin nilsonlinux/contact-sounds:monitor all play " .. safe)
end

local function stopSounds()
  noctalia.runAsync("noctalia msg plugin nilsonlinux/contact-sounds:monitor all stop")
end

-- Persists a full contact order through the service: the new order list is
-- merged into the current state and sent as a mutation — no config-reload, so
-- the panel stays open while reordering.
local function persistOrder(names)
  local t = dataTables()
  t.order = cloneList(names)
  sendMutate(t)
end

-- Drag-and-drop handler for the insertion strips: `payload` is the dragged
-- contact's name, `value` is the strip's position (1 = before the first row,
-- #contacts+1 = after the last one). The dragged contact is inserted so it
-- occupies that position in the current order.
function onContactDrop(payload, value)
  if type(payload) ~= "string" or payload == "" or type(value) ~= "string" then
    return
  end
  local insertAt = tonumber(value)
  if insertAt == nil then
    return
  end
  local names = {}
  for _, c in ipairs(contacts()) do
    names[#names + 1] = c.name
  end
  local n = #names
  if n == 0 then
    return
  end
  local current = 0
  for i, nm in ipairs(names) do
    if nm == payload then
      current = i
      break
    end
  end
  if current == 0 then
    return
  end
  local out = {}
  for i, nm in ipairs(names) do
    if i ~= current then
      table.insert(out, nm)
    end
  end
  -- Strip `t` is "before item t" in the current order (t = #names+1 means
  -- "after the last row"). Once the dragged entry is removed, the insertion
  -- point shifts down by one when it sat before that item.
  local target = math.max(1, math.min(insertAt, n + 1))
  local newPos = target
  if target > current then
    newPos = target - 1
  end
  table.insert(out, math.max(1, math.min(newPos, #out + 1)), payload)
  local same = #out == #names
  if same then
    for i, nm in ipairs(out) do
      if nm ~= names[i] then
        same = false
        break
      end
    end
  end
  if same then
    return
  end
  persistOrder(out)
end

-- ---------------------------------------------------------------------------
-- Avatars (explicit photo, otherwise the first letter of the name)
-- ---------------------------------------------------------------------------

-- Default avatar: the first letter of the entry name, centered in a circle.
-- Each contact gets its own stable color, picked from a palette by hashing the
-- name, so two entries never share the same hue.
local AVATAR_COLORS = {
  "#e53935", "#d81b60", "#8e24aa", "#5e35b1", "#3949ab", "#1e88e5",
  "#00acc1", "#00897b", "#43a047", "#7cb342", "#fb8c00", "#f4511e",
  "#6d4c41", "#546e7a", "#039be5", "#9c27b0",
}

local function avatarColor(name)
  local hash = 0
  for i = 1, #name do
    hash = (hash * 31 + name:byte(i)) % 104729
  end
  return AVATAR_COLORS[(hash % #AVATAR_COLORS) + 1]
end

local function initialFor(contact)
  local c = (trim(contact.name):sub(1, 1) or ""):upper()
  if c == "" then
    c = "?"
  end
  return c
end

local function avatarFor(contact)
  local img
  if contact.image and contact.image ~= "" and noctalia.fileExists(expandPath(contact.image)) then
    img = expandPath(contact.image)
  end
  if img then
    return ui.image({ path = img, width = 48, height = 48, radius = 24, fit = "cover" })
  end
  return ui.row({
    width  = 48,
    height = 48,
    fill   = avatarColor(contact.name),
    radius = 24,
    align  = "center",
    justify = "center",
  }, {
    ui.label({ text = initialFor(contact), fontWeight = "bold", color = "#ffffff", fontSize = 22 }),
  })
end

-- ---------------------------------------------------------------------------
-- Rows
-- ---------------------------------------------------------------------------

-- Compact icon-only button for the action column. Every button here is
-- outlined so the row actions read like the rest of the panel's controls.
local function iconBtn(extra)
  local props = { variant = "outline", controlSize = "sm", height = 24, glyphSize = 14 }
  for k, v in pairs(extra) do
    props[k] = v
  end
  return ui.button(props)
end

-- Drag handle for the reorder feature. `liftFromLayout` + `previewAncestor`
-- make the whole row lift off the layout and follow the pointer while
-- dragging — live feedback, just like link-ip-monitor.
local function dragHandle(contact, index)
  return ui.dragSource({
    key             = "grip-" .. tostring(index),
    dragType        = "contact",
    payload         = contact.name,
    previewAncestor = 1,
    liftFromLayout  = true,
    enabled         = true,
    width           = 20,
    height          = 20,
    align           = "center",
    justify         = "center",
    tooltip         = tr("panel.reorder_tooltip"),
  }, {
    ui.glyph({ name = "menu-2", size = 14, color = "on_surface_variant" }),
  })
end

-- Plain row card. The drop targets are the thin insertion strips between
-- rows (see insertionZone), matching link-ip-monitor.
local function rowCard(children, contact)
  return ui.column({
    key         = "row-" .. tostring(contact.name),
    gap         = 6,
    padding     = 8,
    radius      = 8,
    fill        = "surface_variant/0.4",
    border      = "outline",
    borderWidth = 1,
  }, children)
end

-- Thin strip between rows (and before the first / after the last) that
-- accepts a dropped contact. `expandOnDrag` animates it open while the drag
-- passes over it, so the user sees exactly where the row will land.
local function insertionZone(index)
  return ui.dropZone({
    key          = "gap-" .. tostring(index),
    accepts      = { "contact" },
    value        = tostring(index),
    onDrop       = "onContactDrop",
    height       = 3,
    radius       = 4,
    expandOnDrag = true,
    hitSlop      = 24,
  })
end

render = function()
  ensureDurations()
  local list = contacts()
  local showSoundName = noctalia.getConfig("show_sound_name") ~= false
  local rows = {}

  for i, contact in ipairs(list) do
    table.insert(rows, insertionZone(i))

    local cardChildren = {}

    -- Main line: drag handle + avatar + contact name + action buttons. The
    -- handle is a direct child so `previewAncestor = 1` lifts the row card.
    local nameChildren = {
      ui.label({ text = contact.name, fontWeight = "bold", fontSize = 16, maxLines = 1 }),
    }
    if showSoundName then
      table.insert(nameChildren, ui.column({ align = "start" }, {
        ui.row({
          gap       = 6,
          align     = "center",
          fill      = "surface_variant/0.5",
          radius    = 999,
          paddingH  = 10,
          paddingV  = 3,
        }, {
          ui.label({ text = contactSoundName(contact), fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
        }),
      }))
    end
    local mainRowChildren = {
      dragHandle(contact, i),
      ui.row({ gap = 8, align = "center", flexGrow = 1, minWidth = 0 }, {
        avatarFor(contact),
        ui.column({ gap = 4, flexGrow = 1, minWidth = 0 }, nameChildren),
      }),
    }

    local actionButtons = {}
    local deleting = pendingDelete == contact.name
    if deleting then
      table.insert(actionButtons, iconBtn({
        glyph       = "check",
        variant     = "destructive",
        tooltip     = tr("panel.delete_confirm_tooltip"),
        onClick     = function()
          deleteContact(contact.name)
        end,
      }))
      table.insert(actionButtons, iconBtn({
        glyph       = "x",
        tooltip     = tr("panel.delete_cancel_tooltip"),
        onClick     = function()
          pendingDelete = nil
          render()
        end,
      }))
    else
      table.insert(actionButtons, iconBtn({
        glyph       = "pencil",
        tooltip     = tr("panel.edit_tooltip"),
        onClick     = function()
          startEdit(contact)
        end,
      }))
      table.insert(actionButtons, iconBtn({
        glyph       = "trash",
        tooltip     = tr("panel.delete_tooltip"),
        onClick     = function()
          pendingDelete = contact.name
          render()
        end,
      }))
    end
    table.insert(actionButtons, iconBtn({
      glyph       = "player-play",
      tooltip     = tr("panel.play_tooltip"),
      onClick     = function()
        playContact(contact.name)
      end,
    }))
    local duration = contactDuration(contact)
    if duration and duration > STOP_DURATION_THRESHOLD then
      table.insert(actionButtons, iconBtn({
        glyph       = "player-stop",
        tooltip     = tr("panel.stop_tooltip"),
        onClick     = function()
          stopSounds()
        end,
      }))
    end

    table.insert(mainRowChildren, ui.row({ gap = 4, align = "center" }, actionButtons))
    table.insert(cardChildren, ui.row({ gap = 8, align = "center", justify = "space_between" }, mainRowChildren))

    table.insert(rows, rowCard(cardChildren, contact))
  end
  table.insert(rows, insertionZone(#list + 1))

  local body
  if #rows == 0 then
    if showForm then
      body = ui.spacer({ flexGrow = 1 })
    else
      body = ui.column({ gap = 10, align = "center", flexGrow = 1, justify = "center" }, {
        ui.glyph({ name = "bell-ringing", size = 36, color = "outline" }),
        ui.label({ text = tr("panel.empty_state"), color = "outline", textAlign = "center" }),
      })
    end
  else
    body = ui.scroll({ gap = 2, flexGrow = 1 }, rows)
  end

  local function openForm()
    modeDraft = "folder"
    nameDraft = ""
    pathDraft = ""
    soundDraft = ""
    imageDraft = ""
    kindDraft = "contact"
    pathInputMode = "existing"
    editingName = nil
    if #knownFolders() > 0 then
      pathDraft = knownFolders()[1]
    end
    showForm = true
    formVersion = formVersion + 1
    render()
  end

  local function closeForm()
    showForm = false
    clearForm()
    render()
  end

  local children = {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = tr("panel.title"), fontSize = 15, fontWeight = "bold" }),
      ui.row({ gap = 4 }, {
        ui.button({
          glyph       = "close",
          variant     = "outline",
          controlSize = "sm",
          tooltip     = tr("panel.cancel_tooltip"),
          onClick     = closeForm,
          visible     = showForm,
        }),
        ui.button({
          glyph       = "plus",
          variant     = "outline",
          controlSize = "sm",
          tooltip     = tr("panel.add_folder_tooltip"),
          onClick     = openForm,
          visible     = not showForm,
        }),
        ui.button({ glyph = "settings", variant = "outline", controlSize = "sm", tooltip = tr("panel.settings_tooltip"), onClick = "onSettingsClicked" }),
        ui.button({ glyph = "close", variant = "outline", controlSize = "sm", onClick = "onCloseClicked" }),
      }),
    }),
    ui.separator({}),
  }

  -- The form is always part of the tree; `visible` is toggled instead of
  -- inserting/removing a subtree, so toggling it never reflows the flex body
  -- into a broken first frame. A hidden column collapses.
  local isEditing = editingName ~= nil

  local known = knownFolders()

  -- Keeps the picked sound valid for the current folder: a sound that no longer
  -- exists in the folder is demoted back to "random".
  local function clampSoundDraft()
    if pathDraft ~= "" then
      local found = false
      for _, s in ipairs(listSounds(expandPath(pathDraft)) or {}) do
        if s == soundDraft then
          found = true
          break
        end
      end
      if not found then
        soundDraft = ""
      end
    else
      soundDraft = ""
    end
  end

  local pathControl
  local pathToggle

  -- Both adding and editing list the sound folders already in use by other
  -- contacts (only those that actually contain audio files), so a contact can
  -- be pointed at a folder without retyping the path. The pencil switches to
  -- typing a new folder path.
  local inKnown = false
  local sel = 0
  if pathDraft ~= "" then
    for i, p in ipairs(known) do
      if p == pathDraft then
        inKnown = true
        sel = i - 1
        break
      end
    end
  end
  if pathDraft ~= "" and not inKnown then
    pathInputMode = "new"
  end
  if #known > 0 and pathInputMode == "existing" then
    pathControl = ui.select({
      key           = "path-select-" .. formVersion,
      options       = known,
      selectedIndex = sel,
      controlSize   = "sm",
      flexGrow      = 1,
      onChange      = function(value)
        local idx = tonumber(value)
        if idx ~= nil and known[idx + 1] then
          pathDraft = known[idx + 1]
          clampSoundDraft()
          render()
        end
      end,
    })
    pathToggle = ui.button({
      glyph       = "pencil",
      variant     = "outline",
      controlSize = "sm",
      tooltip     = tr("panel.folder_switch_new"),
      onClick     = function()
        pathInputMode = "new"
        render()
      end,
    })
  else
    pathInputMode = "new"
    pathControl = ui.input({
      key         = "path-input-" .. formVersion,
      value       = pathDraft,
      flexGrow    = 1,
      placeholder = tr("panel.add_path_folder"),
      onChange    = function(value)
        pathDraft = value
        clampSoundDraft()
        render()
      end,
    })
    if #known > 0 then
      pathToggle = ui.button({
        glyph       = "list",
        variant     = "outline",
        controlSize = "sm",
        tooltip     = tr("panel.folder_switch_existing"),
        onClick     = function()
          local inList = false
          for _, p in ipairs(known) do
            if p == pathDraft then
              inList = true
              break
            end
          end
          pathInputMode = "existing"
          if pathDraft == "" or not inList then
            pathDraft = known[1]
          end
          clampSoundDraft()
          render()
        end,
      })
    end
  end

  local pathRowElements = { pathControl }
  if pathToggle then
    table.insert(pathRowElements, pathToggle)
  end
  local pathRow = ui.row({ gap = 6, align = "center" }, pathRowElements)

  local formChildren = {}
  table.insert(formChildren, ui.label({ text = isEditing and tr("panel.edit_title") or tr("panel.add_title"), fontWeight = "bold" }))
  table.insert(formChildren, ui.input({
    key         = "add-name-" .. formVersion,
    value       = nameDraft,
    width       = "100%",
    placeholder = tr("panel.add_name"),
    onChange    = function(value)
      nameDraft = value
      render()
    end,
  }))
  table.insert(formChildren, pathRow)
  if modeDraft == "folder" then
    -- List the sounds inside the chosen folder so a specific sound can be
    -- picked by name instead of typing the full path. "" means random.
    local folderPath = pathDraft ~= "" and expandPath(pathDraft) or ""
    local sounds = folderPath ~= "" and (listSounds(folderPath) or {}) or {}
    local options = { tr("panel.folder_random") }
    for _, s in ipairs(sounds) do
      options[#options + 1] = s
    end
    local sel = 0
    for i, s in ipairs(sounds) do
      if s == soundDraft then
        sel = i
        break
      end
    end
    table.insert(formChildren, ui.select({
      key           = "folder-sound-select-" .. formVersion,
      options       = options,
      selectedIndex = sel,
      controlSize   = "sm",
      width         = "100%",
      onChange      = function(value)
        local idx = tonumber(value) or 0
        soundDraft = ""
        if idx >= 1 and sounds[idx] then
          soundDraft = sounds[idx]
        end
        render()
      end,
    }))
  end
  table.insert(formChildren, ui.input({
    key         = "add-image-" .. formVersion,
    value       = imageDraft,
    width       = "100%",
    placeholder = tr("panel.add_image"),
    onChange    = function(value)
      imageDraft = value
      render()
    end,
  }))
  table.insert(formChildren, ui.row({ gap = 6 }, {
    ui.button({
      text         = isEditing and tr("panel.save_button") or tr("panel.add_button"),
      glyph        = isEditing and "device-floppy" or "plus",
      variant      = "outline",
      flexGrow     = 1,
      contentAlign = "center",
      onClick      = saveForm,
    }),
    ui.button({
      text    = tr("panel.cancel"),
      glyph   = "x",
      variant = "outline",
      onClick = closeForm,
    }),
  }))

  table.insert(children, ui.column({ gap = 6, visible = showForm }, formChildren))
  table.insert(children, ui.separator({ visible = showForm }))

  table.insert(children, body)

  panel.render(ui.column({ gap = 10, padding = 12, flexGrow = 1, align = "stretch" }, children))
end

function onOpen(_context)
  render()
end

noctalia.state.watch("contacts.data", function(d)
  if type(d) == "table" then
    data = d
    render()
  end
end)

function onConfigChanged()
  -- Long cache lifetimes would hide that the sound behind a path changed after
  -- an edit (same path, different duration), so drop it and let the next frame
  -- re-probe only the paths that are actually used.
  durations = {}
  render()
end

function onSettingsClicked()
  noctalia.openSettings()
end

function onCloseClicked()
  panel.close()
end