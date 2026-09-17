-- panel.luau
-- Lists the configured contacts with buttons to play, add and delete them.
-- Each row shows a photo/icon (contact photo, group photo or app icon) at the
-- start; folder entries get a menu-list of their sounds. The contacts maps
-- live in Noctalia's app-managed settings.toml; edits go through
-- edit_contacts.sh followed by a config-reload.

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

local function contacts()
  local out = {}
  local contactsCfg = cfgMap("contacts")
  local kinds = cfgMap("contact_kinds")
  local images = cfgMap("contact_images")
  local folderSounds = cfgMap("folder_sounds")
  for name, path in pairs(contactsCfg) do
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
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

-- Known sound-folder paths: the registry (persists even when every entry that
-- used a folder is deleted) plus any folder still in use, deduplicated.
local function knownFolders()
  local set = {}
  for _, path in pairs(cfgMap("contacts")) do
    local abs = expandPath(path)
    local info = noctalia.fileInfo(abs)
    if info and info.isDir then
      local norm = abs:gsub("/+$", "")
      if #(listSounds(abs) or {}) > 0 then
        set[norm] = true
      end
    end
  end
  for path in pairs(cfgMap("sound_folders")) do
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

-- Runs one or more edit_contacts.sh steps, then a config-reload, then (unless
-- noReopen) reopens the panel so the rows refresh.
local function runEditChain(steps, opts)
  opts = opts or {}
  local dir = noctalia.pluginDir()
  if not dir then
    return
  end
  local parts = {}
  for _, args in ipairs(steps) do
    local quoted = {}
    for _, a in ipairs(args) do
      quoted[#quoted + 1] = shellQuote(a)
    end
    parts[#parts + 1] = "bash " .. shellQuote(dir .. "/scripts/edit_contacts.sh") .. " " .. table.concat(quoted, " ")
  end
  local cmd = table.concat(parts, " && ") .. " && noctalia msg config-reload"
  if not opts.noReopen then
    cmd = cmd .. " && noctalia msg panel-open nilsonlinux/contact-sounds:Panel"
  end
  noctalia.runAsync(cmd, function(result)
    if result and result.exitCode == 0 then
      if not opts.noReopen then
        formVersion = formVersion + 1
        nameDraft = ""
        pathDraft = ""
        soundDraft = ""
        imageDraft = ""
        modeDraft = "file"
        kindDraft = "contact"
        pathInputMode = "existing"
      end
      noctalia.notify(tr("panel.title"), tr("panel.saved"))
    else
      noctalia.notifyError(tr("panel.title"), tr("panel.error_saving"))
    end
    if opts.onDone then
      opts.onDone()
    end
    render()
  end)
end

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
  runEditChain({ { "del", name } }, {
    onDone = function()
      pendingDelete = nil
      render()
    end,
  })
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
  local steps = {}
  if editingName then
    if name ~= editingName then
      steps[#steps + 1] = { "set", editingName, name, path }
    else
      steps[#steps + 1] = { "sound", name, path }
    end
  else
    steps[#steps + 1] = { "add", name, path }
  end
  steps[#steps + 1] = { "kind", name, kindDraft or "contact" }
  steps[#steps + 1] = { "image", name, image }
  if modeDraft == "folder" and path ~= "" and pathInputMode == "new" then
    steps[#steps + 1] = { "folderadd", path }
  end
  if modeDraft == "folder" then
    steps[#steps + 1] = { "fsound", name, soundDraft or "" }
  end
  runEditChain(steps, {
    onDone = function()
      editingName = nil
      showForm = false
      render()
    end,
  })
end

local function playContact(name)
  local safe = shellQuote(name)
  noctalia.runAsync("noctalia msg plugin nilsonlinux/contact-sounds:monitor all play " .. safe)
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

-- Compact icon-only button for the action column.
local function iconBtn(extra)
  local props = { variant = "ghost", controlSize = "sm", height = 24, glyphSize = 14 }
  for k, v in pairs(extra) do
    props[k] = v
  end
  return ui.button(props)
end

local function rowCard(children)
  return ui.column({
    gap    = 6,
    padding = 8,
    radius = 8,
    fill   = "surface_variant/0.4",
    border = "outline",
    borderWidth = 1,
  }, children)
end

render = function()
  local list = contacts()
  local rows = {}

  for _, contact in ipairs(list) do
    local cardChildren = {}

    -- Main line: avatar + contact name + action buttons (compact).
    local mainRowChildren = {
      ui.row({ gap = 8, align = "center", flexGrow = 1, minWidth = 0 }, {
        avatarFor(contact),
        ui.label({ text = contact.name, fontWeight = "bold", fontSize = 16, maxLines = 1 }),
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
      variant     = "primary",
      tooltip     = tr("panel.play_tooltip"),
      onClick     = function()
        playContact(contact.name)
      end,
    }))

    table.insert(mainRowChildren, ui.row({ gap = 4, align = "center" }, actionButtons))
    table.insert(cardChildren, ui.row({ gap = 8, align = "center", justify = "space_between" }, mainRowChildren))

    table.insert(rows, rowCard(cardChildren))
  end

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
    body = ui.scroll({ gap = 6, flexGrow = 1 }, rows)
  end

  local function openForm()
    modeDraft = "folder"
    pathDraft = ""
    soundDraft = ""
    pathInputMode = "existing"
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
      variant      = "primary",
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

function onConfigChanged()
  render()
end

function onSettingsClicked()
  noctalia.openSettings()
end

function onCloseClicked()
  panel.close()
end