--!nonstrict
-- Gocryptfs manager panel: list, mount/unmount, add/edit, init, password prompt.

local STATE_KEY = "gocrypt_snapshot"
local COMMAND_KEY = "gocrypt_command"
local RESULT_KEY = "gocrypt_action_result"

local snapshot = noctalia.state.get(STATE_KEY) or {
  available = false,
  loading = true,
  busy = false,
  volumes = {},
  mountedCount = 0,
  totalCount = 0,
  error = "",
  updatedAt = 0,
  revision = 0,
}

local selectedId = ""
local requestCounter = 0
local feedback = ""
local feedbackError = false
local dirty = true

-- views: "list" | "form" | "password"
local view = "list"
local formMode = "add" -- add | edit | init
local formGeneration = 0
local formName = ""
local formCipher = ""
local formMount = ""
local formPassfile = ""
local formAllowOther = false
local formReadOnly = false
local formAutoMount = false
local formPlaintextNames = false
local formAesSiv = false
local formSavePassfile = true
local formPassword = ""
local formPasswordConfirm = ""
local formPasswordKey = 0
local formError = ""
local formEditId = ""

local passwordVolumeId = ""
local passwordVolumeName = ""
local passwordValue = ""
local passwordKey = 0
local passwordError = ""
-- "mount" | "store_keyring"
local passwordMode = "mount"
local passwordRememberKeyring = true

local render

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function nextRequestId()
  requestCounter += 1
  return `panel-{requestCounter}`
end

local function sendCommand(action, values)
  local command = {
    action = action,
    requestId = nextRequestId(),
  }
  if type(values) == "table" then
    for key, value in pairs(values) do
      command[key] = value
    end
  end
  noctalia.state.set(COMMAND_KEY, command)
  return command.requestId
end

local function selectedVolume()
  if selectedId == "" then
    return nil
  end
  for _, vol in ipairs(snapshot.volumes or {}) do
    if vol.id == selectedId then
      return vol
    end
  end
  return nil
end

local function resetForm()
  formName = ""
  formCipher = ""
  formMount = ""
  formPassfile = ""
  formAllowOther = false
  formReadOnly = false
  formAutoMount = true
  formPlaintextNames = false
  formAesSiv = false
  formSavePassfile = true
  formPassword = ""
  formPasswordConfirm = ""
  formPasswordKey += 1
  formError = ""
  formEditId = ""
  formGeneration += 1
end

local function fillFormFrom(vol)
  formName = tostring(vol.name or "")
  formCipher = tostring(vol.cipherDir or "")
  formMount = tostring(vol.mountPoint or "")
  formPassfile = tostring(vol.passfile or "")
  formAllowOther = vol.allowOther == true
  formReadOnly = vol.readOnly == true
  formAutoMount = vol.autoMount == true
  formPlaintextNames = false
  formAesSiv = false
  formSavePassfile = false
  formPassword = ""
  formPasswordConfirm = ""
  formPasswordKey += 1
  formError = ""
  formEditId = tostring(vol.id or "")
  formGeneration += 1
end

local function statusColor(vol)
  if vol.mounted then
    return "tertiary"
  end
  if vol.cipherExists == false or vol.initialized == false then
    return "error"
  end
  return "on_surface_variant"
end

local function volumeCard(vol)
  local selected = vol.id == selectedId
  local statusText = vol.mounted and tr("panel.status.mounted") or tr("panel.status.unmounted")
  local summary = `{vol.name}  ·  {statusText}  ·  {vol.mountPoint}`

  return ui.button({
    key = vol.id,
    text = summary,
    glyph = vol.mounted and "lock-open" or "lock",
    contentAlign = "start",
    variant = selected and "primary" or "outline",
    selected = selected,
    onClick = function()
      selectedId = vol.id
      feedback = ""
      render()
    end,
  })
end

local function selectionToolbar()
  local vol = selectedVolume()
  if vol == nil then
    return ui.label({ text = tr("panel.select_hint"), color = "on_surface_variant" })
  end

  local mounted = vol.mounted == true
  local busy = snapshot.busy == true
  local hasPassfile = type(vol.passfile) == "string" and vol.passfile ~= ""
  local useKeyring = vol.useKeyring == true
  local hints = {}
  if useKeyring then
    table.insert(hints, tr("panel.keyring_hint"))
  elseif hasPassfile then
    table.insert(hints, tr("panel.passfile_hint"))
  end
  if vol.autoMount == true and (useKeyring or hasPassfile) then
    table.insert(hints, tr("panel.automount_hint"))
  end

  local buttons = {
    ui.button({
      text = mounted and tr("actions.unmount") or tr("actions.mount"),
      glyph = mounted and "lock" or "lock-open",
      variant = "primary",
      enabled = not busy and snapshot.available == true,
      onClick = "onToggleMount",
    }),
    ui.button({
      text = tr("actions.open"),
      glyph = "folder-open",
      variant = "outline",
      enabled = not busy,
      onClick = "onOpenMount",
    }),
    ui.button({
      text = tr("actions.edit"),
      glyph = "edit",
      variant = "outline",
      enabled = not busy and not mounted,
      onClick = "onEdit",
    }),
    ui.button({
      text = tr("actions.remove"),
      glyph = "trash",
      variant = "destructive",
      enabled = not busy and not mounted,
      onClick = "onRemove",
    }),
  }

  return ui.column({ gap = 4, padding = 10, fill = "surface_variant/0.45", radius = 10 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = mounted and "lock-open" or "lock", size = 18, color = statusColor(vol) }),
      ui.label({ text = tostring(vol.name), fontWeight = "bold", flexGrow = 1, maxLines = 1 }),
      ui.label({
        text = mounted and tr("panel.status.mounted") or tr("panel.status.unmounted"),
        color = statusColor(vol),
        fontSize = 12,
      }),
    }),
    ui.label({
      text = tr("panel.cipher", { path = vol.cipherDir }),
      color = "on_surface_variant",
      fontSize = 12,
      maxLines = 1,
    }),
    ui.label({
      text = tr("panel.mountpoint", { path = vol.mountPoint }),
      color = "on_surface_variant",
      fontSize = 12,
      maxLines = 1,
    }),
    ui.label({
      text = table.concat(hints, " · "),
      color = "on_surface_variant",
      fontSize = 11,
      visible = #hints > 0,
    }),
    ui.row({ gap = 6, align = "center" }, buttons),
  })
end

local function volumeList()
  local vols = snapshot.volumes or {}
  if #vols == 0 then
    return ui.column({ align = "center", padding = 24, gap = 8 }, {
      ui.glyph({ name = "lock", size = 42, color = "on_surface_variant" }),
      ui.label({ text = tr("panel.empty"), color = "on_surface_variant", textAlign = "center" }),
    })
  end
  local rows = {}
  for _, vol in ipairs(vols) do
    table.insert(rows, volumeCard(vol))
  end
  return ui.column({ gap = 8 }, rows)
end

local function formTitle()
  if formMode == "edit" then
    return tr("panel.edit_title")
  end
  if formMode == "init" then
    return tr("panel.init_title")
  end
  return tr("panel.add_title")
end

local function formView()
  local isInit = formMode == "init"
  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = formTitle(), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "close", onClick = "onCancelForm" }),
    }),
    ui.label({
      text = isInit and tr("panel.init_help") or "",
      color = "on_surface_variant",
      fontSize = 12,
      visible = isInit,
    }),
    ui.label({ text = tr("panel.field.name"), color = "on_surface_variant" }),
    ui.input({
      key = `form-name-{formGeneration}`,
      value = formName,
      placeholder = tr("panel.field.name_placeholder"),
      onChange = "onFormName",
    }),
    ui.label({ text = tr("panel.field.cipher"), color = "on_surface_variant" }),
    ui.input({
      key = `form-cipher-{formGeneration}`,
      value = formCipher,
      placeholder = tr("panel.field.cipher_placeholder"),
      onChange = "onFormCipher",
    }),
    ui.label({ text = tr("panel.field.mount"), color = "on_surface_variant" }),
    ui.input({
      key = `form-mount-{formGeneration}`,
      value = formMount,
      placeholder = tr("panel.field.mount_placeholder"),
      onChange = "onFormMount",
    }),
  }

  if isInit then
    table.insert(children, ui.label({ text = tr("panel.field.password"), color = "on_surface_variant" }))
    table.insert(children, ui.input({
      key = `form-pw-{formGeneration}-{formPasswordKey}`,
      value = "",
      placeholder = tr("panel.password_placeholder"),
      password = true,
      onChange = "onFormPassword",
    }))
    table.insert(children, ui.label({ text = tr("panel.field.password_confirm"), color = "on_surface_variant" }))
    table.insert(children, ui.input({
      key = `form-pw2-{formGeneration}-{formPasswordKey}`,
      value = "",
      placeholder = tr("panel.field.password_confirm_placeholder"),
      password = true,
      onChange = "onFormPasswordConfirm",
    }))
    table.insert(children, ui.row({ gap = 10, align = "center" }, {
      ui.toggle({ checked = formPlaintextNames, onChange = "onFormPlaintextNames" }),
      ui.label({ text = tr("panel.field.plaintextnames"), flexGrow = 1 }),
    }))
    table.insert(children, ui.row({ gap = 10, align = "center" }, {
      ui.toggle({ checked = formAesSiv, onChange = "onFormAesSiv" }),
      ui.label({ text = tr("panel.field.aessiv"), flexGrow = 1 }),
    }))
    table.insert(children, ui.row({ gap = 10, align = "center" }, {
      ui.toggle({ checked = formSavePassfile, onChange = "onFormSavePassfile" }),
      ui.label({ text = tr("panel.field.save_passfile"), flexGrow = 1 }),
    }))
    table.insert(children, ui.row({ gap = 10, align = "center", visible = formSavePassfile }, {
      ui.toggle({ checked = formAutoMount, onChange = "onFormAutoMount" }),
      ui.label({ text = tr("panel.field.auto_mount"), flexGrow = 1 }),
    }))
  else
    -- Edit existing volume: keyring remember/forget + advanced passfile
    local editVol = selectedVolume()
    local editHasKeyring = editVol and editVol.useKeyring == true
    table.insert(children, ui.label({
      text = tr("panel.field.keyring_section"),
      color = "on_surface_variant",
      fontWeight = "bold",
    }))
    table.insert(children, ui.label({
      text = editHasKeyring and tr("panel.keyring_hint") or tr("panel.keyring_not_set"),
      color = editHasKeyring and "tertiary" or "on_surface_variant",
      fontSize = 12,
    }))
    table.insert(children, ui.row({ gap = 8, align = "center" }, {
      ui.button({
        text = tr("actions.remember"),
        glyph = "key",
        variant = "outline",
        enabled = snapshot.busy ~= true,
        onClick = "onRememberKeyring",
      }),
      ui.button({
        text = tr("actions.forget"),
        glyph = "key-off",
        variant = "destructive",
        enabled = snapshot.busy ~= true and editHasKeyring == true,
        onClick = "onForgetKeyring",
      }),
    }))
    table.insert(children, ui.label({
      text = tr("panel.keyring_help"),
      color = "on_surface_variant",
      fontSize = 11,
      maxLines = 4,
    }))
    table.insert(children, ui.label({ text = tr("panel.field.passfile"), color = "on_surface_variant" }))
    table.insert(children, ui.input({
      key = `form-passfile-{formGeneration}`,
      value = formPassfile,
      placeholder = tr("panel.field.passfile_placeholder"),
      onChange = "onFormPassfile",
    }))
    table.insert(children, ui.row({ gap = 10, align = "center" }, {
      ui.toggle({ checked = formAutoMount, onChange = "onFormAutoMount" }),
      ui.label({ text = tr("panel.field.auto_mount"), flexGrow = 1 }),
    }))
    table.insert(children, ui.label({
      text = tr("panel.field.auto_mount_help"),
      color = "on_surface_variant",
      fontSize = 11,
    }))
  end

  table.insert(children, ui.row({ gap = 10, align = "center" }, {
    ui.toggle({ checked = formAllowOther, onChange = "onFormAllowOther" }),
    ui.label({ text = tr("panel.field.allow_other"), flexGrow = 1 }),
  }))
  table.insert(children, ui.row({ gap = 10, align = "center" }, {
    ui.toggle({ checked = formReadOnly, onChange = "onFormReadOnly" }),
    ui.label({ text = tr("panel.field.read_only"), flexGrow = 1 }),
  }))
  table.insert(children, ui.label({ text = formError, color = "error", visible = formError ~= "" }))
  table.insert(children, ui.row({ justify = "end", gap = 8 }, {
    ui.button({ text = tr("actions.cancel"), variant = "outline", onClick = "onCancelForm" }),
    ui.button({
      text = isInit and tr("actions.init") or tr("actions.save"),
      glyph = isInit and "shield-lock" or "check",
      variant = "primary",
      enabled = snapshot.busy ~= true,
      onClick = "onSaveForm",
    }),
  }))

  return ui.scroll({ flexGrow = 1, gap = 10 }, children)
end

local function passwordView()
  local isStore = passwordMode == "store_keyring"
  local title = isStore
    and tr("panel.keyring_title", { name = passwordVolumeName })
    or tr("panel.password_title", { name = passwordVolumeName })
  local confirmText = isStore and tr("actions.remember") or tr("actions.mount")
  local confirmGlyph = isStore and "key" or "lock-open"
  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({
        text = title,
        fontSize = 16,
        fontWeight = "bold",
        flexGrow = 1,
      }),
      ui.button({ glyph = "close", onClick = "onCancelPassword" }),
    }),
    ui.label({
      text = isStore and tr("panel.keyring_label") or tr("panel.password_label"),
      color = "on_surface_variant",
    }),
    ui.input({
      key = "pw_" .. tostring(passwordKey),
      value = "",
      placeholder = tr("panel.password_placeholder"),
      password = true,
      focus = true,
      onChange = "onPasswordChange",
      onSubmit = "onConfirmPassword",
    }),
  }
  if not isStore then
    table.insert(children, ui.row({ gap = 10, align = "center" }, {
      ui.toggle({ checked = passwordRememberKeyring, onChange = "onPasswordRemember" }),
      ui.label({ text = tr("panel.remember_keyring"), flexGrow = 1 }),
    }))
  else
    table.insert(children, ui.label({
      text = tr("panel.keyring_help"),
      color = "on_surface_variant",
      fontSize = 11,
      maxLines = 4,
    }))
  end
  table.insert(children, ui.label({ text = passwordError, color = "error", visible = passwordError ~= "" }))
  table.insert(children, ui.row({ justify = "end", gap = 8 }, {
    ui.button({ text = tr("actions.cancel"), variant = "outline", onClick = "onCancelPassword" }),
    ui.button({
      text = confirmText,
      glyph = confirmGlyph,
      variant = "primary",
      enabled = snapshot.busy ~= true,
      onClick = "onConfirmPassword",
    }),
  }))
  return ui.column({ flexGrow = 1, gap = 12 }, children)
end

local function listView()
  local statusRows = {}
  if snapshot.loading == true then
    table.insert(statusRows, ui.label({ text = tr("panel.loading"), color = "on_surface_variant" }))
  end
  if snapshot.busy == true then
    table.insert(statusRows, ui.label({ text = tr("panel.busy"), color = "primary" }))
  end
  if type(snapshot.error) == "string" and snapshot.error ~= "" then
    table.insert(statusRows, ui.label({ text = snapshot.error, color = "error", maxLines = 2 }))
  end
  if feedback ~= "" then
    table.insert(statusRows, ui.label({
      text = feedback,
      color = feedbackError and "error" or "tertiary",
      maxLines = 2,
    }))
  end

  return ui.column({ flexGrow = 1, gap = 10 }, {
    selectionToolbar(),
    ui.column({ gap = 3 }, statusRows),
    ui.scroll({ flexGrow = 1, gap = 8 }, { volumeList() }),
  })
end

render = function()
  dirty = false

  local content
  if view == "form" then
    content = formView()
  elseif view == "password" then
    content = passwordView()
  else
    content = listView()
  end

  panel.render(ui.column({ flexGrow = 1, gap = 10 }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({
        name = "lock",
        size = 24,
        color = snapshot.available and "primary" or "on_surface_variant",
      }),
      ui.column({ flexGrow = 1, gap = 0 }, {
        ui.label({ text = tr("title"), fontSize = 18, fontWeight = "bold" }),
        ui.label({
          text = tr("panel.subtitle"),
          fontSize = 11,
          color = "on_surface_variant",
        }),
      }),
      ui.button({
        text = tr("actions.init"),
        glyph = "shield-lock",
        variant = "outline",
        visible = view == "list",
        onClick = "onInit",
      }),
      ui.button({
        text = tr("actions.add"),
        glyph = "plus",
        variant = "outline",
        visible = view == "list",
        onClick = "onAdd",
      }),
      ui.button({
        text = tr("actions.refresh"),
        glyph = "refresh",
        variant = "outline",
        visible = view == "list",
        onClick = "onRefresh",
      }),
      ui.button({ glyph = "close", onClick = "onCloseClicked" }),
    }),
    content,
    ui.label({
      text = (snapshot.updatedAt or 0) > 0
        and tr("panel.updated", { time = noctalia.formatTime("%H:%M:%S", snapshot.updatedAt) })
        or "",
      color = "on_surface_variant",
      fontSize = 11,
      visible = view == "list",
    }),
  }))
end

noctalia.state.watch(STATE_KEY, function(value)
  if type(value) ~= "table" then
    return
  end
  -- Always re-render on snapshot publish. Mounted flags live inside
  -- volumes[] and must update the list immediately after mount/unmount.
  snapshot = value
  if selectedId ~= "" and selectedVolume() == nil then
    selectedId = ""
  end
  dirty = true
end)

noctalia.state.watch(RESULT_KEY, function(result)
  if type(result) ~= "table" then
    return
  end
  if type(result.requestId) ~= "string" or not result.requestId:match("^panel%-") then
    return
  end
  feedback = tostring(result.message or "")
  feedbackError = result.ok ~= true
  if result.ok == true and (
    result.action == "add_volume"
    or result.action == "update_volume"
    or result.action == "init_volume"
  ) then
    view = "list"
    resetForm()
  end
  if result.ok == true and result.action == "mount" then
    view = "list"
    passwordValue = ""
    passwordError = ""
  end
  if result.ok ~= true and result.action == "mount" and view == "password" then
    passwordError = feedback
    passwordKey += 1
    passwordValue = ""
  end
  if result.ok ~= true and result.action == "init_volume" and view == "form" then
    formError = feedback
    formPassword = ""
    formPasswordConfirm = ""
    formPasswordKey += 1
  end
  dirty = true
end)

panel.setWantsSecondTicks(true)

function onOpen(_context)
  view = "list"
  feedback = ""
  sendCommand("refresh")
  render()
end

function update()
  if dirty then
    render()
  end
end

function onCloseClicked()
  panel.close()
end

function onRefresh()
  sendCommand("refresh")
end

function onAdd()
  formMode = "add"
  resetForm()
  formAutoMount = false
  view = "form"
  render()
end

function onInit()
  formMode = "init"
  resetForm()
  formAutoMount = true
  formSavePassfile = true
  view = "form"
  render()
end

function onEdit()
  local vol = selectedVolume()
  if not vol then
    return
  end
  formMode = "edit"
  fillFormFrom(vol)
  view = "form"
  render()
end

function onCancelForm()
  view = "list"
  formError = ""
  formPassword = ""
  formPasswordConfirm = ""
  render()
end

function onFormName(value) formName = value end
function onFormCipher(value) formCipher = value end
function onFormMount(value) formMount = value end
function onFormPassfile(value) formPassfile = value end
function onFormPassword(value) formPassword = if type(value) == "string" then value else "" end
function onFormPasswordConfirm(value) formPasswordConfirm = if type(value) == "string" then value else "" end

function onFormAllowOther(value)
  formAllowOther = value == "true"
  render()
end
function onFormReadOnly(value)
  formReadOnly = value == "true"
  render()
end
function onFormAutoMount(value)
  formAutoMount = value == "true"
  render()
end
function onFormPlaintextNames(value)
  formPlaintextNames = value == "true"
  render()
end
function onFormAesSiv(value)
  formAesSiv = value == "true"
  render()
end
function onFormSavePassfile(value)
  formSavePassfile = value == "true"
  if not formSavePassfile then
    formAutoMount = false
  end
  render()
end

function onSaveForm()
  local name = noctalia.string.trim(formName)
  local cipher = noctalia.string.trim(formCipher)
  local mount = noctalia.string.trim(formMount)
  if name == "" or cipher == "" or mount == "" then
    formError = tr("panel.field.required")
    render()
    return
  end

  if formMode == "init" then
    if formPassword == "" then
      formError = tr("panel.password_required")
      render()
      return
    end
    if formPassword ~= formPasswordConfirm then
      formError = tr("panel.field.password_mismatch")
      formPassword = ""
      formPasswordConfirm = ""
      formPasswordKey += 1
      render()
      return
    end
    formError = ""
    sendCommand("init_volume", {
      name = name,
      cipherDir = cipher,
      mountPoint = mount,
      password = formPassword,
      plaintextNames = formPlaintextNames,
      aesSiv = formAesSiv,
      savePassfile = formSavePassfile,
      autoMount = formAutoMount and formSavePassfile,
      allowOther = formAllowOther,
      readOnly = formReadOnly,
    })
    formPassword = ""
    formPasswordConfirm = ""
    formPasswordKey += 1
    render()
    return
  end

  formError = ""
  local payload = {
    name = name,
    cipherDir = cipher,
    mountPoint = mount,
    passfile = noctalia.string.trim(formPassfile),
    allowOther = formAllowOther,
    readOnly = formReadOnly,
    autoMount = formAutoMount,
  }
  if formMode == "edit" then
    payload.id = formEditId
    sendCommand("update_volume", payload)
  else
    sendCommand("add_volume", payload)
  end
  render()
end

function onRemove()
  local vol = selectedVolume()
  if not vol then
    return
  end
  sendCommand("remove_volume", { id = vol.id })
end

-- Named onOpenMount so it does not override the panel lifecycle onOpen().
function onOpenMount()
  local vol = selectedVolume()
  if not vol then
    return
  end
  sendCommand("open", { id = vol.id })
end

local function openPasswordPrompt(vol, mode)
  passwordVolumeId = vol.id
  passwordVolumeName = vol.name
  passwordValue = ""
  passwordError = ""
  passwordMode = mode or "mount"
  passwordRememberKeyring = true
  passwordKey += 1
  view = "password"
  render()
end

function onToggleMount()
  local vol = selectedVolume()
  if not vol then
    return
  end
  if vol.mounted then
    sendCommand("unmount", { id = vol.id })
    return
  end
  -- Prefer keyring or existing passfile without prompting.
  if vol.useKeyring == true or (type(vol.passfile) == "string" and vol.passfile ~= "") then
    sendCommand("mount", { id = vol.id })
    return
  end
  openPasswordPrompt(vol, "mount")
end

function onRememberKeyring()
  local vol = selectedVolume()
  if not vol then
    return
  end
  -- Keep edit context: after save, return to list via cancel/result
  openPasswordPrompt(vol, "store_keyring")
end

function onForgetKeyring()
  local vol = selectedVolume()
  if not vol then
    return
  end
  sendCommand("forget_keyring", { id = vol.id })
  -- Stay on edit form; snapshot watch will refresh useKeyring flag
  render()
end

function onPasswordChange(value)
  passwordValue = if type(value) == "string" then value else ""
end

function onPasswordRemember(value)
  passwordRememberKeyring = value == true or value == "true"
end

function onCancelPassword()
  passwordValue = ""
  passwordError = ""
  passwordMode = "mount"
  view = "list"
  render()
end

function onConfirmPassword()
  if snapshot.busy then
    return
  end
  if passwordValue == "" then
    passwordError = tr("panel.password_required")
    render()
    return
  end
  local pw = passwordValue
  local mode = passwordMode
  local id = passwordVolumeId
  passwordValue = ""
  passwordError = ""
  passwordMode = "mount"
  if mode == "store_keyring" then
    sendCommand("store_keyring", {
      id = id,
      password = pw,
      enableAutoMount = true,
    })
  else
    sendCommand("mount", {
      id = id,
      password = pw,
      storeKeyring = passwordRememberKeyring == true,
    })
  end
  passwordKey += 1
  view = "list"
  render()
end
