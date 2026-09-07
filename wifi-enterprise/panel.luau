--!nonstrict
-- WiFi Enterprise panel: list of configured 802.1X profiles (connect/edit/
-- delete), plus an add/edit form for SSID, EAP method, phase 2 auth,
-- identity, password and the optional CA-cert/domain-match fields.

local EAP_METHODS = {
  { label = "PEAP", value = "peap" },
  { label = "TTLS", value = "ttls" },
  { label = "TLS", value = "tls" },
  { label = "FAST", value = "fast" },
  { label = "LEAP", value = "leap" },
}
local PHASE2_METHODS = {
  { label = "MSCHAPv2", value = "mschapv2" },
  { label = "PAP", value = "pap" },
  { label = "CHAP", value = "chap" },
  { label = "GTC", value = "gtc" },
  { label = "MD5", value = "md5" },
}

local profiles = {}
local scanResults = {}
local picking = false

local pendingDelete = nil

-- Add/edit form state. editingUuid == nil means "add new"; a form is shown
-- either way through `showForm`.
local showForm = false
local editingUuid = nil
local ssidDraft = ""
local ssidKey = 0
local manualSsid = false
local eapIndex = 0
local phase2Index = 0
local identityDraft = ""
local identityKey = 0
local anonIdentityDraft = ""
local anonIdentityKey = 0
local passwordDraft = ""
local passwordKey = 0
local useSystemCa = true
local caCertPathDraft = ""
local domainMatchDraft = ""
local domainMatchKey = 0
local showAdvanced = false

local function labelsOf(list)
  local labels = {}
  for _, e in ipairs(list) do
    table.insert(labels, e.label)
  end
  return labels
end

local function valueAt(list, index)
  local entry = list[index + 1]
  return entry ~= nil and entry.value or list[1].value
end

local function indexOfValue(list, value)
  for i, e in ipairs(list) do
    if e.value == value then
      return i - 1
    end
  end
  return 0
end

local function resetForm()
  editingUuid = nil
  ssidDraft = ""
  ssidKey += 1
  manualSsid = #scanResults == 0
  eapIndex = 0
  phase2Index = 0
  identityDraft = ""
  identityKey += 1
  anonIdentityDraft = ""
  anonIdentityKey += 1
  passwordDraft = ""
  passwordKey += 1
  useSystemCa = true
  caCertPathDraft = ""
  domainMatchDraft = ""
  domainMatchKey += 1
  showAdvanced = false
end

local function statusDot(active, busy)
  return ui.box({
    width = 8,
    height = 8,
    radius = 4,
    fill = if busy then "on_surface_variant" elseif active then "primary" else "outline",
  })
end

local function profileRow(row)
  local uuid = row.uuid
  local deleting = pendingDelete == uuid

  local trailing
  if deleting then
    trailing = ui.row({ gap = 4, align = "center" }, {
      ui.button({
        glyph = "check",
        variant = "destructive",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.delete_confirm", { name = row.name }),
        onClick = function()
          pendingDelete = nil
          noctalia.state.set("eapwifi.cmd", { op = "delete", uuid = uuid })
        end,
      }),
      ui.button({
        glyph = "x",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          pendingDelete = nil
          render()
        end,
      }),
    })
  else
    trailing = ui.row({ gap = 2, align = "center" }, {
      ui.button({
        glyph = "plug",
        variant = "ghost",
        controlSize = "sm",
        enabled = not row.active and not row.busy,
        tooltip = noctalia.tr("panel.connect"),
        onClick = function()
          noctalia.state.set("eapwifi.cmd", { op = "connect", uuid = uuid })
        end,
      }),
      ui.button({
        glyph = "pencil",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.edit"),
        onClick = function()
          editingUuid = uuid
          showForm = true
          ssidDraft = row.ssid
          manualSsid = true
          eapIndex = indexOfValue(EAP_METHODS, row.eap)
          phase2Index = indexOfValue(PHASE2_METHODS, row.phase2)
          identityDraft = ""
          identityKey += 1
          anonIdentityDraft = ""
          anonIdentityKey += 1
          passwordDraft = ""
          passwordKey += 1
          useSystemCa = true
          caCertPathDraft = ""
          domainMatchDraft = ""
          domainMatchKey += 1
          showAdvanced = false
          render()
        end,
      }),
      ui.button({
        glyph = "trash",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.delete"),
        onClick = function()
          pendingDelete = uuid
          render()
        end,
      }),
    })
  end

  return ui.row({
    key = "profile-" .. uuid,
    gap = 8,
    align = "center",
    paddingV = 6,
    paddingH = 8,
    fill = "surface_variant/0.35",
    radius = 8,
  }, {
    statusDot(row.active, row.busy),
    ui.column({ flexGrow = 1, gap = 1 }, {
      ui.label({ text = row.name, fontWeight = "bold", fontSize = 13 }),
      ui.label({ text = `{row.eap}/{row.phase2}`, color = "on_surface_variant", fontSize = 10 }),
    }),
    trailing,
  })
end

local function profilesSection()
  local rows = {}
  if #profiles == 0 then
    table.insert(rows, ui.label({
      text = noctalia.tr("panel.no_profiles"),
      color = "on_surface_variant",
      fontSize = 12,
      maxLines = 3,
    }))
  else
    for _, row in ipairs(profiles) do
      table.insert(rows, profileRow(row))
    end
  end
  return ui.column({ gap = 6 }, rows)
end

local function formSection()
  if not showForm then
    return ui.button({
      text = noctalia.tr("panel.add_profile"),
      glyph = "plus",
      variant = "outline",
      onClick = function()
        resetForm()
        showForm = true
        render()
      end,
    })
  end

  local ssidField
  if manualSsid or #scanResults == 0 then
    ssidField = ui.row({ gap = 6, align = "center" }, {
      ui.input({
        key = "ssid-" .. ssidKey,
        value = ssidDraft,
        placeholder = noctalia.tr("panel.ssid_placeholder"),
        flexGrow = 1,
        enabled = editingUuid == nil,
        onChange = function(value)
          ssidDraft = value
        end,
      }),
      ui.button({
        text = noctalia.tr("panel.scan_instead"),
        variant = "ghost",
        controlSize = "sm",
        visible = #scanResults > 0 and editingUuid == nil,
        onClick = function()
          manualSsid = false
          render()
        end,
      }),
    })
  else
    local options = {}
    for _, s in ipairs(scanResults) do
      table.insert(options, s.ssid)
    end
    local selectedIndex = 0
    for i, s in ipairs(scanResults) do
      if s.ssid == ssidDraft then
        selectedIndex = i - 1
      end
    end
    ssidField = ui.row({ gap = 6, align = "center" }, {
      ui.select({
        key = "ssid-select",
        options = options,
        selectedIndex = selectedIndex,
        flexGrow = 1,
        onChange = function(index, text)
          ssidDraft = text
        end,
      }),
      ui.button({
        text = noctalia.tr("panel.type_manually"),
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          manualSsid = true
          render()
        end,
      }),
    })
    if ssidDraft == "" and #scanResults > 0 then
      ssidDraft = scanResults[1].ssid
    end
  end

  local body = {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({
        text = editingUuid == nil and noctalia.tr("panel.add_profile") or noctalia.tr("panel.edit_profile"),
        fontWeight = "bold",
        fontSize = 13,
        flexGrow = 1,
      }),
      ui.button({
        glyph = "x",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          showForm = false
          render()
        end,
      }),
    }),
    ui.label({ text = noctalia.tr("panel.ssid"), fontSize = 11, color = "on_surface_variant" }),
    ssidField,
    ui.row({ gap = 8 }, {
      ui.column({ flexGrow = 1, gap = 2 }, {
        ui.label({ text = noctalia.tr("panel.eap_method"), fontSize = 11, color = "on_surface_variant" }),
        ui.select({
          key = "eap",
          options = labelsOf(EAP_METHODS),
          selectedIndex = eapIndex,
          onChange = function(index, _text)
            eapIndex = tonumber(index) or 0
          end,
        }),
      }),
      ui.column({ flexGrow = 1, gap = 2 }, {
        ui.label({ text = noctalia.tr("panel.phase2"), fontSize = 11, color = "on_surface_variant" }),
        ui.select({
          key = "phase2",
          options = labelsOf(PHASE2_METHODS),
          selectedIndex = phase2Index,
          onChange = function(index, _text)
            phase2Index = tonumber(index) or 0
          end,
        }),
      }),
    }),
    ui.label({ text = noctalia.tr("panel.identity"), fontSize = 11, color = "on_surface_variant" }),
    ui.input({
      key = "identity-" .. identityKey,
      value = identityDraft,
      placeholder = noctalia.tr("panel.identity_placeholder"),
      onChange = function(value)
        identityDraft = value
      end,
    }),
    ui.label({ text = noctalia.tr("panel.password"), fontSize = 11, color = "on_surface_variant" }),
    ui.input({
      key = "password-" .. passwordKey,
      value = passwordDraft,
      password = true,
      placeholder = editingUuid == nil and noctalia.tr("panel.password_placeholder") or noctalia.tr("panel.password_keep_placeholder"),
      onChange = function(value)
        passwordDraft = value
      end,
    }),
    ui.button({
      text = showAdvanced and noctalia.tr("panel.hide_advanced") or noctalia.tr("panel.show_advanced"),
      glyph = if showAdvanced then "chevron-up" else "chevron-down",
      variant = "ghost",
      controlSize = "sm",
      onClick = function()
        showAdvanced = not showAdvanced
        render()
      end,
    }),
  }

  if showAdvanced then
    table.insert(body, ui.label({ text = noctalia.tr("panel.anonymous_identity"), fontSize = 11, color = "on_surface_variant" }))
    table.insert(body, ui.input({
      key = "anon-" .. anonIdentityKey,
      value = anonIdentityDraft,
      placeholder = noctalia.tr("panel.anonymous_identity_placeholder"),
      onChange = function(value)
        anonIdentityDraft = value
      end,
    }))
    table.insert(body, ui.row({ gap = 6, align = "center" }, {
      ui.toggle({
        checked = useSystemCa,
        onChange = function(value)
          useSystemCa = value == "true"
          render()
        end,
      }),
      ui.label({ text = noctalia.tr("panel.use_system_ca"), fontSize = 11, flexGrow = 1 }),
    }))
    if not useSystemCa then
      table.insert(body, ui.row({ gap = 6, align = "center" }, {
        ui.label({
          text = caCertPathDraft ~= "" and caCertPathDraft or noctalia.tr("panel.no_ca_cert"),
          fontSize = 11,
          color = "on_surface_variant",
          flexGrow = 1,
          maxLines = 1,
        }),
        ui.button({
          text = noctalia.tr("panel.browse"),
          variant = "outline",
          controlSize = "sm",
          enabled = not picking,
          onClick = function()
            noctalia.state.set("eapwifi.cmd", { op = "pickCaCert" })
            -- The picker is a separate window that grabs focus; closing the
            -- panel avoids a layer-shell surface fighting it for input. The
            -- chosen path comes back through eapwifi.pickedCaCert and this
            -- form is restored on the next onOpen.
            panel.close()
          end,
        }),
      }))
    end
    table.insert(body, ui.label({ text = noctalia.tr("panel.domain_match"), fontSize = 11, color = "on_surface_variant" }))
    table.insert(body, ui.input({
      key = "domain-" .. domainMatchKey,
      value = domainMatchDraft,
      placeholder = noctalia.tr("panel.domain_match_placeholder"),
      onChange = function(value)
        domainMatchDraft = value
      end,
    }))
  end

  table.insert(body, ui.button({
    text = editingUuid == nil and noctalia.tr("panel.create") or noctalia.tr("panel.save"),
    variant = "primary",
    onClick = "onSubmit",
  }))

  return ui.column({ gap = 8, padding = 8, fill = "surface_variant/0.25", radius = 8 }, body)
end

function render()
  panel.render(ui.column({ flexGrow = 1, gap = 10, padding = 10 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({
        glyph = "refresh",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.refresh"),
        onClick = function()
          noctalia.state.set("eapwifi.cmd", { op = "refresh" })
        end,
      }),
      ui.button({
        glyph = "settings",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.plugin_settings"),
        onClick = function()
          noctalia.openSettings()
        end,
      }),
      ui.button({
        glyph = "x",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.close"),
        onClick = function()
          panel.close()
        end,
      }),
    }),
    ui.label({
      text = noctalia.tr("panel.stopgap_note"),
      fontSize = 10,
      color = "on_surface_variant",
      maxLines = 3,
    }),
    ui.scroll({ flexGrow = 1, gap = 12 }, {
      profilesSection(),
      formSection(),
    }),
  }))
end

function onSubmit()
  local ssid = noctalia.string.trim(ssidDraft)
  local identity = noctalia.string.trim(identityDraft)
  if ssid == "" or identity == "" then
    render()
    return
  end
  local fields = {
    ssid = ssid,
    eap = valueAt(EAP_METHODS, eapIndex),
    phase2 = valueAt(PHASE2_METHODS, phase2Index),
    identity = identity,
    anonymousIdentity = noctalia.string.trim(anonIdentityDraft),
    password = passwordDraft,
    useSystemCa = useSystemCa,
    caCertPath = caCertPathDraft,
    domainSuffixMatch = noctalia.string.trim(domainMatchDraft),
  }
  if editingUuid == nil then
    noctalia.state.set("eapwifi.cmd", { op = "create", fields = fields })
  else
    noctalia.state.set("eapwifi.cmd", { op = "update", uuid = editingUuid, fields = fields })
  end
  showForm = false
  render()
end

function onOpen(_context)
  pendingDelete = nil
  profiles = noctalia.state.get("eapwifi.profiles") or {}
  scanResults = noctalia.state.get("eapwifi.scanResults") or {}
  picking = noctalia.state.get("eapwifi.picking") == true

  local picked = noctalia.state.get("eapwifi.pickedCaCert")
  if type(picked) == "table" and picked.path ~= nil and picked.path ~= "" then
    -- The panel closes while the CA-cert picker is open (see formSection's
    -- browse button); if a form was in progress it stays open here so this
    -- reflects that same session, not a stray value from a previous run.
    caCertPathDraft = picked.path
    showForm = true
    showAdvanced = true
    useSystemCa = false
    noctalia.state.set("eapwifi.pickedCaCert", { path = "", at = 0 })
  end

  noctalia.state.set("eapwifi.cmd", { op = "refresh" })
  render()
end

noctalia.state.watch("eapwifi.profiles", function(value)
  profiles = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("eapwifi.scanResults", function(value)
  scanResults = type(value) == "table" and value or {}
end)

noctalia.state.watch("eapwifi.picking", function(value)
  picking = value == true
  render()
end)
