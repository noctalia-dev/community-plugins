--!nonstrict
-- VPN Manager panel: connection list (connect/disconnect/star/delete),
-- import form (file path or pasted config), and trusted-network management.

local connections = {}
local trustedNetworks = {}
local currentNetworks = {}
local defaultVpnUuid = ""
local availableProtocols = {}

local pendingDeleteVpn = nil
local expandedUuid = nil
local details = { uuid = "", rows = {} }

local showAdd = false
local IMPORT_TYPES = {
  { label = noctalia.tr("panel.auto_detect"), value = "" },
  { label = "OpenVPN (.ovpn)", value = "openvpn" },
  { label = "WireGuard (.conf)", value = "wireguard" },
  { label = "Cisco AnyConnect (openconnect)", value = "openconnect" },
  { label = "Cisco legacy VPN (vpnc)", value = "vpnc" },
}
local importTypeIndex = 0
local pathDraft = ""
local picking = false
local lastImport = { ok = true, reason = "", path = "", at = 0 }
local pathKey = 0
local pasteDraft = ""
local pasteKey = 0

local showTrust = false
local trustDraft = ""
local trustKey = 0

local function importTypeLabels()
  local labels = {}
  for _, t in ipairs(IMPORT_TYPES) do
    table.insert(labels, t.label)
  end
  return labels
end

local function statusDot(active, busy)
  return ui.box({
    width = 8,
    height = 8,
    radius = 4,
    fill = if busy then "on_surface_variant" elseif active then "primary" else "outline",
  })
end

local function protocolBadge(available)
  return ui.glyph({
    name = if available then "check" else "x",
    size = 12,
    color = if available then "primary" else "on_surface_variant",
  })
end

local function detailsBlock(uuid, row)
  local lines = {}
  if not row.active then
    table.insert(lines, ui.label({
      text = noctalia.tr("panel.details_inactive"),
      fontSize = 11,
      color = "on_surface_variant",
      maxLines = 2,
    }))
  elseif details.uuid ~= uuid or #details.rows == 0 then
    table.insert(lines, ui.label({
      text = noctalia.tr("panel.details_loading"),
      fontSize = 11,
      color = "on_surface_variant",
    }))
  else
    for _, d in ipairs(details.rows) do
      table.insert(lines, ui.row({ key = `detail-{uuid}-{d.label}`, gap = 6 }, {
        ui.label({ text = d.label, fontSize = 11, color = "on_surface_variant", width = 70 }),
        ui.label({ text = d.value, fontSize = 11, flexGrow = 1, maxLines = 1 }),
      }))
    end
  end

  table.insert(lines, ui.button({
    key = "edit-" .. uuid,
    text = noctalia.tr("panel.edit"),
    glyph = "pencil",
    variant = "outline",
    controlSize = "sm",
    onClick = function()
      noctalia.state.set("vpn.cmd", { op = "edit", uuid = uuid })
    end,
  }))

  return ui.column({ gap = 4, paddingH = 4 }, lines)
end

local function connectionRow(row)
  local uuid = row.uuid
  local deleting = pendingDeleteVpn == uuid

  local trailing
  if deleting then
    trailing = ui.row({ gap = 4, align = "center" }, {
      ui.button({
        glyph = "check",
        variant = "destructive",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.delete_confirm", { name = row.name }),
        onClick = function()
          pendingDeleteVpn = nil
          noctalia.state.set("vpn.cmd", { op = "delete", uuid = uuid })
        end,
      }),
      ui.button({
        glyph = "x",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          pendingDeleteVpn = nil
          render()
        end,
      }),
    })
  else
    trailing = ui.row({ gap = 2, align = "center" }, {
      ui.button({
        glyph = if row.isDefault then "star-filled" else "star",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.use_as_default"),
        onClick = function()
          noctalia.state.set("vpn.cmd", { op = "setDefault", uuid = if row.isDefault then "" else uuid })
        end,
      }),
      ui.toggle({
        checked = row.active,
        enabled = not row.busy,
        onChange = function(_value)
          if row.active then
            noctalia.state.set("vpn.cmd", { op = "disconnect", uuid = uuid })
          else
            noctalia.state.set("vpn.cmd", { op = "connect", uuid = uuid })
          end
        end,
      }),
      ui.button({
        key = "info-" .. uuid,
        glyph = expandedUuid == uuid and "chevron-up" or "info-circle",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.details"),
        onClick = function()
          if expandedUuid == uuid then
            expandedUuid = nil
          else
            expandedUuid = uuid
            details = { uuid = uuid, rows = {} }
            noctalia.state.set("vpn.cmd", { op = "details", uuid = uuid })
          end
          render()
        end,
      }),
      ui.button({
        glyph = "trash",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.delete"),
        onClick = function()
          pendingDeleteVpn = uuid
          render()
        end,
      }),
    })
  end

  local header = ui.row({
    gap = 8,
    align = "center",
  }, {
    statusDot(row.active, row.busy),
    ui.column({ flexGrow = 1, gap = 1 }, {
      ui.label({ text = row.name, fontWeight = "bold", fontSize = 13 }),
      ui.label({ text = row.protocol, color = "on_surface_variant", fontSize = 10 }),
    }),
    trailing,
  })

  local children = { header }
  if expandedUuid == uuid then
    table.insert(children, detailsBlock(uuid, row))
  end

  return ui.column({
    key = "vpn-" .. uuid,
    gap = 6,
    paddingV = 6,
    paddingH = 8,
    fill = "surface_variant/0.35",
    radius = 8,
  }, children)
end

local function connectionsSection()
  local rows = {}
  if #connections == 0 then
    table.insert(rows, ui.label({
      text = noctalia.tr("panel.no_connections"),
      color = "on_surface_variant",
      fontSize = 12,
      maxLines = 3,
    }))
  else
    for _, row in ipairs(connections) do
      table.insert(rows, connectionRow(row))
    end
  end
  return ui.column({ gap = 6 }, rows)
end

local function addSection()
  if not showAdd then
    return ui.button({
      text = noctalia.tr("panel.add_vpn"),
      glyph = "plus",
      variant = "outline",
      onClick = function()
        showAdd = true
        render()
      end,
    })
  end

  local protoNote = {}
  for _, t in ipairs(IMPORT_TYPES) do
    if t.value ~= "" then
      table.insert(protoNote, ui.row({ gap = 4, align = "center" }, {
        protocolBadge(availableProtocols[t.value] == true),
        ui.label({ text = t.label, fontSize = 10, color = "on_surface_variant" }),
      }))
    end
  end
  -- no wrap support on ui.row: lay badges out two per row instead of one long strip
  local protoRows = {}
  for i = 1, #protoNote, 2 do
    local rowItems = { protoNote[i] }
    if protoNote[i + 1] ~= nil then
      table.insert(rowItems, protoNote[i + 1])
    end
    table.insert(protoRows, ui.row({ gap = 14 }, rowItems))
  end

  local banner = {}
  if lastImport.ok == false and lastImport.reason ~= "" then
    table.insert(banner, ui.column({ gap = 2, padding = 6, fill = "error/0.15", radius = 6 }, {
      ui.row({ gap = 6, align = "center" }, {
        ui.glyph({ name = "alert-triangle", size = 14, color = "error" }),
        ui.label({
          text = noctalia.tr("panel.import_failed"),
          fontSize = 12,
          fontWeight = "bold",
          color = "error",
          flexGrow = 1,
        }),
        ui.button({
          glyph = "x",
          variant = "ghost",
          controlSize = "sm",
          tooltip = noctalia.tr("panel.dismiss"),
          onClick = function()
            -- Clear the shared record too, or onOpen reads the failure straight
            -- back out of the service state and the banner returns.
            lastImport = { ok = true, reason = "", path = "", at = 0 }
            noctalia.state.set("vpn.cmd", { op = "dismissImportError" })
            showAdd = false
            render()
          end,
        }),
      }),
      ui.label({ text = lastImport.reason, fontSize = 11, color = "on_surface_variant", maxLines = 4 }),
      ui.label({
        text = lastImport.path ~= "" and lastImport.path or "",
        fontSize = 10,
        color = "on_surface_variant",
        maxLines = 1,
        visible = lastImport.path ~= "",
      }),
    }))
  end

  local body = {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = noctalia.tr("panel.add_vpn"), fontWeight = "bold", fontSize = 13, flexGrow = 1 }),
      ui.button({
        glyph = "x",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          showAdd = false
          render()
        end,
      }),
    }),
    ui.column({ gap = 4 }, protoRows),
    ui.label({ text = noctalia.tr("panel.protocol"), fontSize = 11, color = "on_surface_variant" }),
    ui.select({
      key = "import-type",
      options = importTypeLabels(),
      selectedIndex = importTypeIndex,
      onChange = function(index, _text)
        importTypeIndex = tonumber(index) or 0
        render()
      end,
    }),
    ui.label({ text = noctalia.tr("panel.import_from_file"), fontSize = 11, color = "on_surface_variant" }),
    ui.row({ gap = 6, align = "center" }, {
      ui.input({
        key = "path-" .. pathKey,
        value = pathDraft,
        placeholder = noctalia.tr("panel.path_placeholder"),
        flexGrow = 1,
        onChange = function(value)
          pathDraft = value
        end,
        onSubmit = "onImportPath",
      }),
      ui.button({
        glyph = "folder-open",
        variant = "outline",
        tooltip = noctalia.tr("panel.browse"),
        enabled = not picking,
        onClick = function()
          noctalia.state.set("vpn.cmd", { op = "pick" })
          -- The picker is a separate window that takes focus; a panel left open
          -- underneath it holds a layer-shell grab and the picker cannot be
          -- clicked. Close deliberately, as other plugins do when they launch
          -- something on top. The chosen file imports on its own.
          panel.close()
        end,
      }),
      ui.button({ text = noctalia.tr("panel.import"), onClick = "onImportPath" }),
    }),
    ui.label({ text = noctalia.tr("panel.or_paste"), fontSize = 11, color = "on_surface_variant" }),
    ui.input({
      key = "paste-" .. pasteKey,
      value = pasteDraft,
      placeholder = noctalia.tr("panel.paste_placeholder"),
      multiline = true,
      height = 90,
      onChange = function(value)
        pasteDraft = value
      end,
    }),
    ui.button({ text = noctalia.tr("panel.import_pasted"), variant = "primary", onClick = "onImportPaste" }),
    ui.label({
      text = noctalia.tr("panel.manual_note"),
      fontSize = 10,
      color = "on_surface_variant",
      maxLines = 4,
    }),
  }

  -- A failed import is shown above the form, since the picker closes the panel
  -- and the toast is long gone by the time the panel is reopened.
  for _, node in ipairs(body) do
    table.insert(banner, node)
  end

  return ui.column({ gap = 8, padding = 8, fill = "surface_variant/0.25", radius = 8 }, banner)
end

local function trustSection()
  local header = ui.row({ align = "center", justify = "space_between" }, {
    ui.label({ text = noctalia.tr("panel.trusted_networks"), fontWeight = "bold", fontSize = 13, flexGrow = 1 }),
    ui.button({
      glyph = if showTrust then "chevron-up" else "chevron-down",
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr(showTrust and "panel.collapse" or "panel.expand"),
      onClick = function()
        showTrust = not showTrust
        render()
      end,
    }),
  })

  if not showTrust then
    return header
  end

  local rows = { header }
  if #trustedNetworks == 0 then
    table.insert(rows, ui.label({
      text = noctalia.tr("panel.trusted_none"),
      color = "on_surface_variant",
      fontSize = 11,
      maxLines = 3,
    }))
  else
    for _, name in ipairs(trustedNetworks) do
      table.insert(rows, ui.row({
        key = "trust-" .. name,
        gap = 6,
        align = "center",
        paddingV = 3,
        paddingH = 6,
        fill = "surface_variant/0.25",
        radius = 6,
      }, {
        ui.glyph({ name = "wifi", size = 12, color = "on_surface_variant" }),
        ui.label({ text = name, fontSize = 12, flexGrow = 1 }),
        ui.button({
          glyph = "trash",
          variant = "ghost",
          controlSize = "sm",
          onClick = function()
            noctalia.state.set("vpn.cmd", { op = "untrust", name = name })
          end,
        }),
      }))
    end
  end

  local untrustedCurrent = {}
  for _, net in ipairs(currentNetworks) do
    if not net.trusted then
      table.insert(untrustedCurrent, net)
    end
  end
  for _, net in ipairs(untrustedCurrent) do
    table.insert(rows, ui.button({
      key = "add-current-" .. net.key,
      text = noctalia.tr("panel.trust_current", { name = net.key }),
      variant = "outline",
      controlSize = "sm",
      onClick = function()
        noctalia.state.set("vpn.cmd", { op = "trust", name = net.key })
      end,
    }))
  end

  table.insert(rows, ui.row({ gap = 6, align = "center" }, {
    ui.input({
      key = "trust-add-" .. trustKey,
      value = trustDraft,
      placeholder = noctalia.tr("panel.trust_placeholder"),
      flexGrow = 1,
      onChange = function(value)
        trustDraft = value
      end,
      onSubmit = "onTrustAdd",
    }),
    ui.button({ glyph = "plus", tooltip = noctalia.tr("panel.trust_add"), onClick = "onTrustAdd" }),
  }))

  return ui.column({ gap = 6 }, rows)
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
          noctalia.state.set("vpn.cmd", { op = "refresh" })
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
    ui.scroll({ flexGrow = 1, gap = 12 }, {
      connectionsSection(),
      addSection(),
      ui.separator({}),
      trustSection(),
    }),
  }))
end

-- The select reports its own index; guard the lookup anyway, because a nil
-- here would throw inside a UI callback and take the panel down with it.
local function selectedImportType()
  local entry = IMPORT_TYPES[importTypeIndex + 1]
  local value = entry ~= nil and entry.value or ""
  return value ~= "" and value or nil
end

function onImportPath()
  local typeValue = selectedImportType()
  noctalia.state.set("vpn.cmd", { op = "import", path = pathDraft, importType = typeValue })
  pathDraft = ""
  pathKey += 1
  render()
end

function onImportPaste()
  local typeValue = selectedImportType()
  noctalia.state.set("vpn.cmd", { op = "importText", text = pasteDraft, importType = typeValue })
  pasteDraft = ""
  pasteKey += 1
  render()
end

function onTrustAdd()
  local name = noctalia.string.trim(trustDraft)
  if name ~= "" then
    noctalia.state.set("vpn.cmd", { op = "trust", name = name })
  end
  trustDraft = ""
  trustKey += 1
  render()
end

function onOpen(_context)
  pendingDeleteVpn = nil
  expandedUuid = nil
  details = { uuid = "", rows = {} }
  lastImport = noctalia.state.get("vpn.lastImport") or lastImport
  -- Land on the import form when the last attempt failed, so the reason is
  -- visible rather than lost with the toast.
  showAdd = lastImport.ok == false
  connections = noctalia.state.get("vpn.connections") or {}
  trustedNetworks = noctalia.state.get("vpn.trustedNetworks") or {}
  currentNetworks = noctalia.state.get("vpn.currentNetworks") or {}
  defaultVpnUuid = noctalia.state.get("vpn.defaultVpnUuid") or ""
  availableProtocols = noctalia.state.get("vpn.availableProtocols") or {}
  noctalia.state.set("vpn.cmd", { op = "refresh" })
  render()
end

noctalia.state.watch("vpn.lastImport", function(value)
  if type(value) == "table" then
    lastImport = {
      ok = value.ok ~= false,
      reason = type(value.reason) == "string" and value.reason or "",
      path = type(value.path) == "string" and value.path or "",
      at = tonumber(value.at) or 0,
    }
    if not lastImport.ok then
      showAdd = true
    end
  end
  render()
end)

noctalia.state.watch("vpn.picking", function(value)
  picking = value == true
  render()
end)

noctalia.state.watch("vpn.details", function(value)
  if type(value) == "table" then
    details = { uuid = value.uuid or "", rows = type(value.rows) == "table" and value.rows or {} }
  end
  render()
end)

noctalia.state.watch("vpn.connections", function(value)
  connections = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("vpn.trustedNetworks", function(value)
  trustedNetworks = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("vpn.currentNetworks", function(value)
  currentNetworks = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("vpn.defaultVpnUuid", function(value)
  defaultVpnUuid = type(value) == "string" and value or ""
end)

noctalia.state.watch("vpn.availableProtocols", function(value)
  availableProtocols = type(value) == "table" and value or {}
end)
