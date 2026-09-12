-- panel.luau
-- Lists the configured contacts with buttons to play, add and delete them.
-- The contacts map lives in Noctalia's app-managed settings.toml; edits go
-- through edit_contacts.sh followed by a config-reload.

--!nonstrict

local loaded = {} -- [slug] = { loaded = bool, name = string, path = string }

local nameDraft = ""
local pathDraft = ""
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

local function contacts()
  local out = {}
  for name, path in pairs(noctalia.getConfig("contacts") or {}) do
    table.insert(out, { name = tostring(name), path = tostring(path) })
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

local function playContact(name)
  local safe = shellQuote(name)
  noctalia.runAsync("noctalia msg plugin nilsonlinux/contact-sounds:monitor all play " .. safe)
end

local function runEdit(args, onDone)
  local dir = noctalia.pluginDir()
  if not dir then
    return
  end
  local cmd = "bash " .. shellQuote(dir .. "/scripts/edit_contacts.sh") .. " " .. args .. " && noctalia msg config-reload && noctalia msg panel-open nilsonlinux/contact-sounds:Panel"
  noctalia.runAsync(cmd, function(result)
    if result and result.exitCode == 0 then
      formVersion = formVersion + 1
      nameDraft = ""
      pathDraft = ""
      noctalia.notify(tr("panel.title"), tr("panel.saved"))
    else
      noctalia.notifyError(tr("panel.title"), tr("panel.error_saving"))
    end
    if onDone then
      onDone()
    end
  end)
end

local function clearForm()
  nameDraft = ""
  pathDraft = ""
  editingName = nil
  formVersion = formVersion + 1
end

local function deleteContact(name)
  runEdit("del " .. shellQuote(name), function()
    pendingDelete = nil
    render()
  end)
end

local function startEdit(contact)
  editingName = contact.name
  nameDraft = contact.name
  pathDraft = contact.path
  showForm = true
  formVersion = formVersion + 1
  render()
end

local function saveForm()
  local name = nameDraft:gsub("^%s+", ""):gsub("%s+$", "")
  local path = pathDraft:gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" or path == "" then
    noctalia.notifyError(tr("panel.title"), tr("panel.invalid_contact"))
    return
  end
  if editingName then
    runEdit("set " .. shellQuote(editingName) .. " " .. shellQuote(name) .. " " .. shellQuote(path), function()
      editingName = nil
      showForm = false
      render()
    end)
  else
    runEdit("add " .. shellQuote(name) .. " " .. shellQuote(path), function()
      render()
    end)
  end
end

local function statusGlyph(name)
  for _, entry in pairs(loaded) do
    if entry.name == name then
      if entry.loaded then
        return "circle-check", "primary"
      end
      return "alert-circle", "error"
    end
  end
  return "loader", "outline"
end

render = function()
  local list = contacts()
  local rows = {}

  for _, contact in ipairs(list) do
    local glyph, glyphColor = statusGlyph(contact.name)

    local rowChildren = {
      ui.glyph({ name = glyph, size = 16, color = glyphColor }),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = contact.name, fontWeight = "bold", maxLines = 1 }),
        ui.label({ text = contact.path, fontSize = 12, color = "outline", maxLines = 1 }),
      }),
    }

    local deleting = pendingDelete == contact.name
    if deleting then
      table.insert(rowChildren, ui.button({
        glyph       = "check",
        variant     = "destructive",
        controlSize = "sm",
        tooltip     = tr("panel.delete_confirm_tooltip"),
        onClick     = function()
          deleteContact(contact.name)
        end,
      }))
      table.insert(rowChildren, ui.button({
        glyph       = "x",
        variant     = "ghost",
        controlSize = "sm",
        tooltip     = tr("panel.delete_cancel_tooltip"),
        onClick     = function()
          pendingDelete = nil
          render()
        end,
      }))
    else
      table.insert(rowChildren, ui.button({
        glyph       = "pencil",
        variant     = "ghost",
        controlSize = "sm",
        tooltip     = tr("panel.edit_tooltip"),
        onClick     = function()
          startEdit(contact)
        end,
      }))
      table.insert(rowChildren, ui.button({
        glyph       = "trash",
        variant     = "ghost",
        controlSize = "sm",
        tooltip     = tr("panel.delete_tooltip"),
        onClick     = function()
          pendingDelete = contact.name
          render()
        end,
      }))
    end
    table.insert(rowChildren, ui.button({
      glyph       = "player-play",
      variant     = "primary",
      controlSize = "sm",
      tooltip     = tr("panel.play_tooltip"),
      onClick     = function()
        playContact(contact.name)
      end,
    }))

    table.insert(rows, ui.row({
      gap         = 10,
      padding     = 10,
      radius      = 8,
      fill        = "surface_variant/0.4",
      border      = "outline",
      borderWidth = 1,
      align       = "center",
      key         = contact.name,
    }, rowChildren))
  end

  local body
  if #rows == 0 then
    body = ui.column({ gap = 10, align = "center", flexGrow = 1, justify = "center" }, {
      ui.glyph({ name = "bell-ringing", size = 36, color = "outline" }),
      ui.label({ text = tr("panel.empty_state"), color = "outline", textAlign = "center" }),
    })
  else
    body = ui.scroll({ gap = 6, flexGrow = 1 }, rows)
  end

  local function toggleForm()
    showForm = not showForm
    if not showForm then
      clearForm()
    end
    render()
  end

  local children = {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = tr("panel.title"), fontSize = 15, fontWeight = "bold" }),
      ui.row({ gap = 4 }, {
        ui.button({
          glyph       = showForm and "close" or "plus",
          variant     = "outline",
          controlSize = "sm",
          tooltip     = showForm and tr("panel.cancel_tooltip") or tr("panel.add_tooltip"),
          onClick     = toggleForm,
        }),
        ui.button({ glyph = "settings", variant = "outline", controlSize = "sm", tooltip = tr("panel.settings_tooltip"), onClick = "onSettingsClicked" }),
        ui.button({ glyph = "close", variant = "outline", controlSize = "sm", onClick = "onCloseClicked" }),
      }),
    }),
    ui.separator({}),
  }

  if showForm then
    local isEditing = editingName ~= nil
    table.insert(children, ui.column({ gap = 6 }, {
      ui.label({ text = isEditing and tr("panel.edit_title") or tr("panel.add_title"), fontWeight = "bold" }),
      ui.input({ key = "add-name-" .. formVersion, value = nameDraft, width = "100%", placeholder = tr("panel.add_name"), onChange = function(value) nameDraft = value end }),
      ui.input({ key = "add-path-" .. formVersion, value = pathDraft, width = "100%", placeholder = tr("panel.add_path"), onChange = function(value) pathDraft = value end }),
      ui.row({ gap = 6 }, {
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
          onClick = toggleForm,
        }),
      }),
    }))
    table.insert(children, ui.separator({}))
  end

  table.insert(children, body)

  panel.render(ui.column({ gap = 10, padding = 12, height = 530 }, children))
end

noctalia.state.watch("loaded", function(raw)
  if not raw then
    return
  end
  local ok, decoded = pcall(noctalia.json.decode, raw)
  if ok and type(decoded) == "table" then
    loaded = decoded
  end
  render()
end)

function onOpen(_context)
  local raw = noctalia.state.get("loaded")
  if raw then
    local ok, decoded = pcall(noctalia.json.decode, raw)
    if ok and type(decoded) == "table" then
      loaded = decoded
    end
  end
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