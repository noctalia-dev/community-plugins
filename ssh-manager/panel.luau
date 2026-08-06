--!nonstrict
-- SSH Manager panel: hosts (config) and keys/agent.

local STATE_KEY = "ssh_snapshot"
local COMMAND_KEY = "ssh_command"
local RESULT_KEY = "ssh_action_result"

local snapshot = noctalia.state.get(STATE_KEY) or {
  available = false,
  loading = true,
  busy = false,
  hosts = {},
  keys = {},
  hostCount = 0,
  keyCount = 0,
  agentKeys = 0,
  error = "",
  updatedAt = 0,
  revision = 0,
}

local tab = "hosts" -- hosts | keys
local selectedId = ""
local requestCounter = 0
local feedback = ""
local feedbackError = false
local dirty = true

-- views: list | host_form | key_form
local view = "list"
local formMode = "add" -- add | edit
local formGeneration = 0
local formError = ""

-- host form
local formAlias = ""
local formHostname = ""
local formUser = ""
local formPort = "22"
local formIdentity = ""
local formProxy = ""
local formCert = ""
local formExtra = ""
local formEditId = ""

-- key form
local formKeyName = ""
local formKeyTypeIndex = 0
local formKeyComment = ""
local formKeyPass = ""
local formKeyPassKey = 0
local keyTypes = { "ed25519", "rsa", "ecdsa" }

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

local function selectedHost()
  if tab ~= "hosts" or selectedId == "" then
    return nil
  end
  for _, host in ipairs(snapshot.hosts or {}) do
    if host.id == selectedId or host.alias == selectedId then
      return host
    end
  end
  return nil
end

local function selectedKey()
  if tab ~= "keys" or selectedId == "" then
    return nil
  end
  for _, key in ipairs(snapshot.keys or {}) do
    if key.id == selectedId then
      return key
    end
  end
  return nil
end

local function resetHostForm()
  formAlias = ""
  formHostname = ""
  formUser = ""
  formPort = "22"
  formIdentity = ""
  formProxy = ""
  formCert = ""
  formExtra = ""
  formEditId = ""
  formError = ""
  formGeneration += 1
end

local function fillHostForm(host)
  formAlias = tostring(host.alias or "")
  formHostname = tostring(host.hostname or "")
  formUser = tostring(host.user or "")
  formPort = tostring(host.port or "22")
  formIdentity = tostring(host.identityFile or "")
  formProxy = tostring(host.proxyJump or "")
  formCert = tostring(host.certificateFile or "")
  formExtra = ""
  formEditId = tostring(host.id or host.alias or "")
  formError = ""
  formGeneration += 1
  -- ask service for extra options
  sendCommand("get_host_extra", { id = formEditId })
end

local function resetKeyForm()
  formKeyName = ""
  formKeyComment = ""
  formKeyPass = ""
  formKeyPassKey += 1
  formError = ""
  local def = tostring(noctalia.getConfig("default_key_type") or "ed25519")
  formKeyTypeIndex = 0
  for i, t in ipairs(keyTypes) do
    if t == def then
      formKeyTypeIndex = i - 1
      break
    end
  end
  formGeneration += 1
end

local function hostCard(host)
  local selected = host.id == selectedId
  local subtitle = ""
  if host.wildcard then
    subtitle = tr("host.wildcard_readonly")
  else
    local user = host.user ~= "" and host.user or "?"
    local hn = host.hostname ~= "" and host.hostname or "?"
    local port = host.port ~= "" and host.port or "22"
    subtitle = `{user}@{hn}:{port}`
  end
  return ui.button({
    key = host.id,
    text = `{host.alias}  ·  {subtitle}`,
    glyph = host.wildcard and "asterisk" or "server",
    contentAlign = "start",
    variant = selected and "primary" or "outline",
    selected = selected,
    onClick = function()
      selectedId = host.id
      feedback = ""
      render()
    end,
  })
end

local function keyCard(key)
  local selected = key.id == selectedId
  local status = key.inAgent and tr("key.in_agent") or tr("key.not_in_agent")
  local typ = key.keyType ~= "" and key.keyType or "?"
  local text = `{key.name}  ·  {typ}  ·  {status}`
  return ui.button({
    key = key.id,
    text = text,
    glyph = key.inAgent and "key" or "key-off",
    contentAlign = "start",
    variant = selected and "primary" or "outline",
    selected = selected,
    onClick = function()
      selectedId = key.id
      feedback = ""
      render()
    end,
  })
end

local function hostToolbar()
  local host = selectedHost()
  if host == nil then
    return ui.label({ text = tr("panel.select_host"), color = "on_surface_variant" })
  end
  local busy = snapshot.busy == true
  local ro = host.wildcard == true

  local buttons = {
    ui.button({
      text = tr("actions.connect"),
      glyph = "terminal",
      variant = "primary",
      enabled = not busy and not ro,
      onClick = "onConnect",
    }),
    ui.button({
      text = tr("actions.edit"),
      glyph = "edit",
      variant = "outline",
      enabled = not busy and not ro,
      onClick = "onEditHost",
    }),
    ui.button({
      text = tr("actions.remove"),
      glyph = "trash",
      variant = "destructive",
      enabled = not busy and not ro,
      onClick = "onRemoveHost",
    }),
  }

  return ui.column({ gap = 4, padding = 10, fill = "surface_variant/0.45", radius = 10 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "server", size = 18, color = "primary" }),
      ui.label({ text = tostring(host.alias), fontWeight = "bold", flexGrow = 1, maxLines = 1 }),
    }),
    ui.label({
      text = host.hostname ~= "" and ("HostName " .. host.hostname) or "",
      color = "on_surface_variant",
      fontSize = 12,
      visible = host.hostname ~= "",
    }),
    ui.label({
      text = host.identityFile ~= "" and ("IdentityFile " .. host.identityFile) or "",
      color = "on_surface_variant",
      fontSize = 12,
      visible = host.identityFile ~= "",
      maxLines = 1,
    }),
    ui.label({
      text = host.proxyJump ~= "" and ("ProxyJump " .. host.proxyJump) or "",
      color = "on_surface_variant",
      fontSize = 12,
      visible = host.proxyJump ~= "",
      maxLines = 1,
    }),
    ui.row({ gap = 6, align = "center" }, buttons),
  })
end

local function keyToolbar()
  local key = selectedKey()
  if key == nil then
    return ui.label({ text = tr("panel.select_key"), color = "on_surface_variant" })
  end
  local busy = snapshot.busy == true

  local buttons = {
    ui.button({
      text = tr("actions.copy_pub"),
      glyph = "copy",
      variant = "primary",
      enabled = not busy and key.hasPublic == true,
      onClick = "onCopyPub",
    }),
    ui.button({
      text = key.inAgent and tr("actions.agent_remove") or tr("actions.agent_add"),
      glyph = key.inAgent and "unlink" or "link",
      variant = "outline",
      enabled = not busy and key.hasPrivate == true,
      onClick = "onToggleAgent",
    }),
  }

  return ui.column({ gap = 4, padding = 10, fill = "surface_variant/0.45", radius = 10 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "key", size = 18, color = key.inAgent and "tertiary" or "on_surface" }),
      ui.label({ text = tostring(key.name), fontWeight = "bold", flexGrow = 1, maxLines = 1 }),
      ui.label({
        text = key.inAgent and tr("key.in_agent") or tr("key.not_in_agent"),
        color = key.inAgent and "tertiary" or "on_surface_variant",
        fontSize = 12,
      }),
    }),
    ui.label({
      text = key.fingerprint ~= "" and tr("key.fingerprint", { fp = key.fingerprint }) or "",
      color = "on_surface_variant",
      fontSize = 11,
      maxLines = 1,
      visible = key.fingerprint ~= "",
    }),
    ui.label({
      text = key.comment ~= "" and key.comment or "",
      color = "on_surface_variant",
      fontSize = 12,
      visible = key.comment ~= "",
      maxLines = 1,
    }),
    ui.row({ gap = 6, align = "center" }, buttons),
  })
end

local function itemList()
  if tab == "hosts" then
    local hosts = snapshot.hosts or {}
    if #hosts == 0 then
      return ui.column({ align = "center", padding = 24, gap = 8 }, {
        ui.glyph({ name = "server-off", size = 42, color = "on_surface_variant" }),
        ui.label({ text = tr("panel.empty_hosts"), color = "on_surface_variant", textAlign = "center" }),
      })
    end
    local rows = {}
    for _, host in ipairs(hosts) do
      table.insert(rows, hostCard(host))
    end
    return ui.column({ gap = 8 }, rows)
  end

  local keys = snapshot.keys or {}
  if #keys == 0 then
    return ui.column({ align = "center", padding = 24, gap = 8 }, {
      ui.glyph({ name = "key-off", size = 42, color = "on_surface_variant" }),
      ui.label({ text = tr("panel.empty_keys"), color = "on_surface_variant", textAlign = "center" }),
    })
  end
  local rows = {}
  for _, key in ipairs(keys) do
    table.insert(rows, keyCard(key))
  end
  return ui.column({ gap = 8 }, rows)
end

local function hostFormView()
  local title = formMode == "edit" and tr("host.form_edit") or tr("host.form_add")
  return ui.scroll({ flexGrow = 1, gap = 8 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = title, fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "close", onClick = "onCancelForm" }),
    }),
    ui.label({ text = tr("host.alias"), color = "on_surface_variant" }),
    ui.input({
      key = `h-alias-{formGeneration}`,
      value = formAlias,
      placeholder = tr("host.alias_placeholder"),
      onChange = "onFormAlias",
    }),
    ui.label({ text = tr("host.hostname"), color = "on_surface_variant" }),
    ui.input({
      key = `h-hn-{formGeneration}`,
      value = formHostname,
      placeholder = tr("host.hostname_placeholder"),
      onChange = "onFormHostname",
    }),
    ui.row({ gap = 8 }, {
      ui.column({ flexGrow = 1, gap = 4 }, {
        ui.label({ text = tr("host.user"), color = "on_surface_variant" }),
        ui.input({
          key = `h-user-{formGeneration}`,
          value = formUser,
          placeholder = tr("host.user_placeholder"),
          onChange = "onFormUser",
        }),
      }),
      ui.column({ width = 100, gap = 4 }, {
        ui.label({ text = tr("host.port"), color = "on_surface_variant" }),
        ui.input({
          key = `h-port-{formGeneration}`,
          value = formPort,
          placeholder = tr("host.port_placeholder"),
          onChange = "onFormPort",
        }),
      }),
    }),
    ui.label({ text = tr("host.identity"), color = "on_surface_variant" }),
    ui.input({
      key = `h-id-{formGeneration}`,
      value = formIdentity,
      placeholder = tr("host.identity_placeholder"),
      onChange = "onFormIdentity",
    }),
    ui.label({ text = tr("host.proxyjump"), color = "on_surface_variant" }),
    ui.input({
      key = `h-pj-{formGeneration}`,
      value = formProxy,
      placeholder = tr("host.proxyjump_placeholder"),
      onChange = "onFormProxy",
    }),
    ui.label({ text = tr("host.certificate"), color = "on_surface_variant" }),
    ui.input({
      key = `h-cert-{formGeneration}`,
      value = formCert,
      placeholder = tr("host.certificate_placeholder"),
      onChange = "onFormCert",
    }),
    ui.label({ text = tr("host.extra"), color = "on_surface_variant" }),
    ui.input({
      key = `h-extra-{formGeneration}`,
      value = formExtra,
      placeholder = tr("host.extra_placeholder"),
      multiline = true,
      height = 90,
      onChange = "onFormExtra",
    }),
    ui.label({ text = formError, color = "error", visible = formError ~= "" }),
    ui.row({ justify = "end", gap = 8 }, {
      ui.button({ text = tr("actions.cancel"), variant = "outline", onClick = "onCancelForm" }),
      ui.button({
        text = tr("actions.save"),
        glyph = "check",
        variant = "primary",
        enabled = snapshot.busy ~= true,
        onClick = "onSaveHost",
      }),
    }),
  })
end

local function keyFormView()
  return ui.scroll({ flexGrow = 1, gap = 8 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = tr("key.form_generate"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "close", onClick = "onCancelForm" }),
    }),
    ui.label({ text = tr("key.name"), color = "on_surface_variant" }),
    ui.input({
      key = `k-name-{formGeneration}`,
      value = formKeyName,
      placeholder = tr("key.name_placeholder"),
      onChange = "onFormKeyName",
    }),
    ui.label({ text = tr("key.type"), color = "on_surface_variant" }),
    ui.select({
      key = `k-type-{formGeneration}`,
      options = keyTypes,
      selectedIndex = formKeyTypeIndex,
      onChange = "onFormKeyType",
    }),
    ui.label({ text = tr("key.comment"), color = "on_surface_variant" }),
    ui.input({
      key = `k-comment-{formGeneration}`,
      value = formKeyComment,
      placeholder = tr("key.comment_placeholder"),
      onChange = "onFormKeyComment",
    }),
    ui.label({ text = tr("key.passphrase"), color = "on_surface_variant" }),
    ui.input({
      key = `k-pass-{formGeneration}-{formKeyPassKey}`,
      value = "",
      placeholder = tr("key.passphrase_placeholder"),
      password = true,
      onChange = "onFormKeyPass",
    }),
    ui.label({ text = formError, color = "error", visible = formError ~= "" }),
    ui.row({ justify = "end", gap = 8 }, {
      ui.button({ text = tr("actions.cancel"), variant = "outline", onClick = "onCancelForm" }),
      ui.button({
        text = tr("actions.generate"),
        glyph = "key",
        variant = "primary",
        enabled = snapshot.busy ~= true,
        onClick = "onGenerateKey",
      }),
    }),
  })
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
    ui.row({ gap = 4, align = "center" }, {
      ui.button({
        text = tr("tabs.hosts"),
        selected = tab == "hosts",
        variant = tab == "hosts" and "primary" or "ghost",
        onClick = "onTabHosts",
      }),
      ui.button({
        text = tr("tabs.keys"),
        selected = tab == "keys",
        variant = tab == "keys" and "primary" or "ghost",
        onClick = "onTabKeys",
      }),
      ui.spacer({ flexGrow = 1 }),
      ui.label({
        text = tab == "hosts"
          and `{snapshot.hostCount or 0} hosts`
          or `{snapshot.agentKeys or 0}/{snapshot.keyCount or 0} agent`,
        color = "on_surface_variant",
        fontSize = 12,
      }),
    }),
    tab == "hosts" and hostToolbar() or keyToolbar(),
    ui.column({ gap = 3 }, statusRows),
    ui.scroll({ flexGrow = 1, gap = 8 }, { itemList() }),
  })
end

render = function()
  dirty = false
  local content
  if view == "host_form" then
    content = hostFormView()
  elseif view == "key_form" then
    content = keyFormView()
  else
    content = listView()
  end

  panel.render(ui.column({ flexGrow = 1, gap = 10 }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({
        name = "terminal-2",
        size = 24,
        color = snapshot.available and "primary" or "on_surface_variant",
      }),
      ui.column({ flexGrow = 1, gap = 0 }, {
        ui.label({ text = tr("title"), fontSize = 18, fontWeight = "bold" }),
        ui.label({ text = tr("panel.subtitle"), fontSize = 11, color = "on_surface_variant" }),
      }),
      ui.button({
        text = tab == "keys" and tr("actions.generate") or tr("actions.add"),
        glyph = "plus",
        variant = "outline",
        visible = view == "list",
        onClick = "onPrimaryAdd",
      }),
      ui.button({
        text = tr("actions.open_dir"),
        glyph = "folder",
        variant = "ghost",
        visible = view == "list",
        onClick = "onOpenDir",
      }),
      ui.button({
        glyph = "refresh",
        variant = "ghost",
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
  local changed = value.revision ~= snapshot.revision
    or value.busy ~= snapshot.busy
    or value.error ~= snapshot.error
    or value.agentKeys ~= snapshot.agentKeys
  snapshot = value
  if selectedId ~= "" then
    if tab == "hosts" and selectedHost() == nil then
      selectedId = ""
    elseif tab == "keys" and selectedKey() == nil then
      selectedId = ""
    end
  end
  if changed then
    dirty = true
  end
end)

noctalia.state.watch(RESULT_KEY, function(result)
  if type(result) ~= "table" then
    return
  end
  if type(result.requestId) ~= "string" or not result.requestId:match("^panel%-") then
    return
  end
  if result.action == "get_host_extra" then
    if type(result.extra) == "string" then
      formExtra = result.extra
      formGeneration += 1
      dirty = true
    end
    return
  end
  feedback = tostring(result.message or "")
  feedbackError = result.ok ~= true
  if result.ok == true and (
    result.action == "add_host"
    or result.action == "update_host"
    or result.action == "generate_key"
  ) then
    view = "list"
    formKeyPass = ""
    formKeyPassKey += 1
  end
  if result.ok ~= true and view ~= "list" then
    formError = feedback
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

function onCloseClicked() panel.close() end
function onRefresh() sendCommand("refresh") end
function onOpenDir() sendCommand("open_dir") end

function onTabHosts()
  tab = "hosts"
  selectedId = ""
  feedback = ""
  render()
end

function onTabKeys()
  tab = "keys"
  selectedId = ""
  feedback = ""
  render()
end

function onPrimaryAdd()
  if tab == "keys" then
    resetKeyForm()
    view = "key_form"
  else
    formMode = "add"
    resetHostForm()
    view = "host_form"
  end
  render()
end

function onCancelForm()
  view = "list"
  formError = ""
  formKeyPass = ""
  formKeyPassKey += 1
  render()
end

function onEditHost()
  local host = selectedHost()
  if not host or host.wildcard then
    return
  end
  formMode = "edit"
  fillHostForm(host)
  view = "host_form"
  render()
end

function onRemoveHost()
  local host = selectedHost()
  if not host or host.wildcard then
    return
  end
  sendCommand("remove_host", { id = host.id })
end

function onConnect()
  local host = selectedHost()
  if not host or host.wildcard then
    return
  end
  sendCommand("connect", { id = host.id })
end

function onCopyPub()
  local key = selectedKey()
  if not key then
    return
  end
  sendCommand("copy_pub", { id = key.name })
end

function onToggleAgent()
  local key = selectedKey()
  if not key then
    return
  end
  if key.inAgent then
    sendCommand("agent_remove", { id = key.name })
  else
    sendCommand("agent_add", { id = key.name })
  end
end

function onFormAlias(v) formAlias = v end
function onFormHostname(v) formHostname = v end
function onFormUser(v) formUser = v end
function onFormPort(v) formPort = v end
function onFormIdentity(v) formIdentity = v end
function onFormProxy(v) formProxy = v end
function onFormCert(v) formCert = v end
function onFormExtra(v) formExtra = v end
function onFormKeyName(v) formKeyName = v end
function onFormKeyComment(v) formKeyComment = v end
function onFormKeyPass(v) formKeyPass = if type(v) == "string" then v else "" end
function onFormKeyType(index, _text)
  formKeyTypeIndex = tonumber(index) or 0
end

function onSaveHost()
  local alias = noctalia.string.trim(formAlias)
  if alias == "" then
    formError = tr("host.required")
    render()
    return
  end
  formError = ""
  local payload = {
    alias = alias,
    hostname = noctalia.string.trim(formHostname),
    user = noctalia.string.trim(formUser),
    port = noctalia.string.trim(formPort),
    identityFile = noctalia.string.trim(formIdentity),
    proxyJump = noctalia.string.trim(formProxy),
    certificateFile = noctalia.string.trim(formCert),
    extra = formExtra,
  }
  if formMode == "edit" then
    payload.id = formEditId
    sendCommand("update_host", payload)
  else
    sendCommand("add_host", payload)
  end
  render()
end

function onGenerateKey()
  local name = noctalia.string.trim(formKeyName)
  if name == "" then
    formError = tr("key.required")
    render()
    return
  end
  formError = ""
  local keyType = keyTypes[formKeyTypeIndex + 1] or "ed25519"
  local pass = formKeyPass
  formKeyPass = ""
  formKeyPassKey += 1
  sendCommand("generate_key", {
    name = name,
    keyType = keyType,
    comment = noctalia.string.trim(formKeyComment),
    passphrase = pass,
  })
  render()
end
