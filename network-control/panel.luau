--!nonstrict
-- Network Control panel - pick a NetworkManager connection, see what it is doing
-- right now, and edit how it gets its address.
--
-- The panel owns no nmcli call: every action becomes one "network.request" on the
-- plugin's shared state, the service answers with a fresh "network.state".
--
-- The editing fields are drafts. Nothing is written until Apply, and what Apply
-- writes is the diff the panel shows underneath - so switching a connection from
-- DHCP to a static address is a legible list of property changes, not a guess.
-- Once the write lands, the service arms a countdown and the panel grows a Keep
-- button: a wrong address is one click (or one timeout) away from being undone.

local net = require("./net.luau")

local snapshot = { available = false, connections = {} }
-- Collapsible Wi-Fi picker. `wifiPasswordSsid` names the entry whose password
-- field is open, and wifiGen re-seeds those inputs (value seeds once per key).
local wifiOpen = false
local wifiPasswordSsid = nil
local wifiPassword = ""
local manualSsid = ""
local manualPassword = ""
local wifiGen = 0
local draft = nil
local draftUuid = nil
local draftReady = false
-- Bumped whenever the fields are re-seeded from a fresh profile: ui.input seeds
-- its text once per key, so a new key is the only way to show new server values.
local gen = 0
local lastBusy = false

local METHOD_KEYS = {
  auto = "method.auto",
  manual = "method.manual",
  ["link-local"] = "method.link_local",
  disabled = "method.disabled",
  ignore = "method.ignore",
}

local FIELD_KEYS = {
  ipv4_method = "field.ipv4_method",
  ipv4_addresses = "field.ipv4_addresses",
  ipv4_gateway = "field.ipv4_gateway",
  ipv4_dns = "field.ipv4_dns",
  ipv4_dns_search = "field.ipv4_dns_search",
  ipv6_method = "field.ipv6_method",
  ipv6_addresses = "field.ipv6_addresses",
  ipv6_gateway = "field.ipv6_gateway",
  ipv6_dns = "field.ipv6_dns",
  ipv6_dns_search = "field.ipv6_dns_search",
}

local KIND_GLYPHS = {
  wifi = "wifi",
  ethernet = "plug-connected",
  dummy = "binary-tree",
  bridge = "network",
  loopback = "refresh",
  vpn = "shield-lock",
}

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function request(value)
  noctalia.state.set("network.request", value)
end

local function methodKey(method)
  return METHOD_KEYS[method] or "method.unknown"
end

local function methodLabel(method)
  return tr(methodKey(method))
end

local function fieldLabel(key)
  return tr("field." .. key)
end

local function orEmpty(value)
  if value == nil or value == "" then
    return tr("panel.empty")
  end
  return value
end

local function displayValue(key, value)
  if value == nil or value == "" then
    return tr("panel.empty")
  end
  if key == "ipv4_method" or key == "ipv6_method" then
    return methodLabel(value)
  end
  return value
end

local function kindGlyph(kind)
  return KIND_GLYPHS[kind] or "network"
end

local function connectionByUuid(uuid)
  for _, connection in ipairs(snapshot.connections or {}) do
    if connection.uuid == uuid then
      return connection
    end
  end
  return nil
end

-- ── draft ────────────────────────────────────────────────────────────────────

local function seedDraft()
  local source = snapshot.profile or net.EMPTY_FORM
  draft = {}
  for _, field in ipairs(net.FIELDS) do
    draft[field.key] = source[field.key] or ""
  end
  draftUuid = snapshot.selected
  draftReady = snapshot.profile ~= nil
  gen = gen + 1
end

-- Re-seed only when the fields no longer describe what is on screen: the
-- selection moved, the first profile arrived, or a write landed. A background
-- refresh must never wipe what is being typed.
local function syncDraft()
  if snapshot.selected == nil then
    draft = nil
    return
  end
  if draft == nil or draftUuid ~= snapshot.selected or (not draftReady and snapshot.profile ~= nil) then
    seedDraft()
  end
end

local function desiredForm()
  if draft == nil then
    return nil, nil
  end
  return net.validateForm(draft)
end

local function changeList()
  local desired = desiredForm()
  if desired == nil or snapshot.profile == nil then
    return {}
  end
  return net.diff(snapshot.profile, desired)
end

-- ── widgets ──────────────────────────────────────────────────────────────────

local render -- forward declaration: the cards below re-render the panel

local function sectionTitle(key)
  return ui.label({ text = tr(key), fontWeight = "bold", fontSize = 13 })
end

local function keyValueRow(key, value, glyph)
  return ui.row({ gap = 6, align = "center" }, {
    ui.glyph({ name = glyph, size = 14, color = "on_surface_variant" }),
    ui.label({ text = tr(key), fontSize = 11, color = "on_surface_variant", width = 110 }),
    ui.label({ text = value, fontSize = 11, flexGrow = 1, maxLines = 1 }),
  })
end

local function fieldInput(key, placeholder, enabled)
  return ui.column({ gap = 2, flexGrow = 1, minWidth = 120 }, {
    ui.label({ text = fieldLabel(key), fontSize = 10, color = "on_surface_variant" }),
    ui.input({
      key = key .. ":" .. tostring(gen),
      value = draft ~= nil and draft[key] or "",
      placeholder = placeholder,
      fontSize = 12,
      controlSize = "sm",
      enabled = enabled,
      onChange = function(text)
        if draft ~= nil then
          draft[key] = tostring(text)
        end
      end,
      onSubmit = function()
        render()
      end,
    }),
  })
end

local function methodSelect(prefix, enabled)
  local methods = prefix == "ipv4" and net.V4_METHODS or net.V6_METHODS
  local labels = {}
  local selectedIndex = 0
  for index, method in ipairs(methods) do
    labels[index] = methodLabel(method)
    if draft ~= nil and draft[prefix .. "_method"] == method then
      selectedIndex = index - 1
    end
  end
  return ui.column({ gap = 2, flexGrow = 1, minWidth = 130 }, {
    ui.label({ text = fieldLabel(prefix .. "_method"), fontSize = 10, color = "on_surface_variant" }),
    ui.select({
      key = "method:" .. prefix .. ":" .. tostring(gen),
      options = labels,
      selectedIndex = selectedIndex,
      enabled = enabled,
      controlSize = "sm",
      onChange = function(index)
        if draft == nil then
          return
        end
        local method = methods[tonumber(index) + 1]
        if method ~= nil then
          draft[prefix .. "_method"] = method
        end
        render()
      end,
    }),
  })
end

-- The live block: what the interface actually holds right now, which is the only
-- way to tell a written profile from an applied one.
local function liveBlock(live)
  local children = {}
  if live == nil then
    table.insert(children, ui.label({ text = tr("panel.no_live"), fontSize = 11, color = "on_surface_variant" }))
    return ui.column({ gap = 4 }, children)
  end
  local addresses = #live.ipv4_addresses > 0 and table.concat(live.ipv4_addresses, ", ") or tr("panel.empty")
  table.insert(children, keyValueRow("panel.live_ipv4", addresses, "route"))
  table.insert(children, keyValueRow("panel.live_gateway", orEmpty(live.ipv4_gateway), "arrow-up"))
  table.insert(children, keyValueRow("panel.live_dns",
    #live.ipv4_dns > 0 and table.concat(live.ipv4_dns, ", ") or tr("panel.empty"), "server"))
  if #live.ipv6_addresses > 0 then
    table.insert(children, keyValueRow("panel.live_ipv6", table.concat(live.ipv6_addresses, ", "), "world"))
  end
  table.insert(children, keyValueRow("panel.live_device", live.device .. " — " .. live.state, "device-desktop"))
  return ui.column({ gap = 4, padding = 8, radius = 8, fill = "surface_variant/0.3" }, children)
end

local function connectionRow(connection)
  local selected = connection.uuid == snapshot.selected
  local detail = connection.device ~= "" and connection.device or tr("panel.no_device")
  return ui.row({ gap = 8, align = "center" }, {
    ui.glyph({
      name = kindGlyph(connection.kind),
      size = 16,
      color = connection.active and "primary" or "on_surface_variant",
    }),
    ui.button({
      key = "pick:" .. connection.uuid,
      text = connection.name,
      variant = selected and "secondary" or "ghost",
      contentAlign = "start",
      flexGrow = 1,
      enabled = not snapshot.busy,
      onClick = function()
        request({ action = "select", uuid = connection.uuid })
      end,
    }),
    ui.label({
      text = connection.active and (tr("panel.active") .. " — " .. detail) or detail,
      fontSize = 10,
      color = connection.active and "primary" or "on_surface_variant",
      width = 150,
      maxLines = 1,
      textAlign = "end",
    }),
  })
end

local function pendingBanner(pending)
  local remaining = math.max(0, math.ceil((pending.deadline_ms - (snapshot.now_ms or 0)) / 1000))
  return ui.column({ gap = 8, padding = 10, radius = 8, fill = "error/0.12", border = "error/0.5", borderWidth = 1 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "hourglass", size = 18, color = "error" }),
      ui.label({
        text = tr("panel.pending", { name = pending.name, seconds = remaining }),
        fontSize = 12,
        flexGrow = 1,
      }),
    }),
    ui.row({ gap = 8 }, {
      ui.button({
        text = tr("panel.keep"),
        glyph = "check",
        variant = "primary",
        flexGrow = 1,
        onClick = function()
          request({ action = "keep" })
        end,
      }),
      ui.button({
        text = tr("panel.revert_now"),
        glyph = "arrow-back-up",
        variant = "destructive",
        flexGrow = 1,
        onClick = function()
          request({ action = "revert" })
        end,
      }),
    }),
  })
end

local function changesBlock(changes, invalidReason)
  local children = {}
  if invalidReason ~= nil then
    table.insert(children, ui.row({ gap = 6, align = "center", padding = 8, radius = 8, fill = "error/0.12" }, {
      ui.glyph({ name = "alert-triangle", size = 16, color = "error" }),
      ui.label({ text = invalidReason, fontSize = 11, color = "error", flexGrow = 1 }),
    }))
  end
  if #changes == 0 then
    if invalidReason == nil then
      table.insert(children, ui.label({ text = tr("panel.no_changes"), fontSize = 11, color = "on_surface_variant" }))
    end
    return ui.column({ gap = 6 }, children)
  end
  table.insert(children, ui.label({
    text = tr("panel.changes", { count = #changes }),
    fontSize = 11,
    fontWeight = "bold",
  }))
  for _, change in ipairs(changes) do
    table.insert(children, ui.row({ gap = 6, align = "center" }, {
      ui.label({ text = fieldLabel(change.key), fontSize = 10, color = "on_surface_variant", width = 120 }),
      ui.label({ text = displayValue(change.key, change.from), fontSize = 10, width = 110, maxLines = 1 }),
      ui.glyph({ name = "arrow-right", size = 12, color = "on_surface_variant" }),
      ui.label({ text = displayValue(change.key, change.to), fontSize = 10, flexGrow = 1, maxLines = 1, color = "primary" }),
    }))
  end
  return ui.column({ gap = 4 }, children)
end

local function editorCard(connection)
  local busy = snapshot.busy == true
  local locked = busy or snapshot.pending ~= nil or not snapshot.permission_ok
  local desired, reasonKey, item = desiredForm()
  local invalid = nil
  if reasonKey ~= nil then
    invalid = tr(reasonKey, { value = tostring(item or "") })
  end
  local changes = desired ~= nil and changeList() or {}
  local v4Method = draft ~= nil and draft.ipv4_method or "auto"
  local v6Method = draft ~= nil and draft.ipv6_method or "auto"
  local v4Addressed = not net.ADDRESSLESS_METHODS[v4Method]
  local v6Addressed = not net.ADDRESSLESS_METHODS[v6Method]

  local applyEnabled = not locked and invalid == nil and #changes > 0

  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = kindGlyph(connection.kind), size = 18, color = "primary" }),
      ui.column({ gap = 0, flexGrow = 1 }, {
        ui.label({ text = connection.name, fontWeight = "bold", fontSize = 13 }),
        ui.label({
          text = connection.kind .. (connection.device ~= "" and (" — " .. connection.device) or ""),
          fontSize = 10,
          color = "on_surface_variant",
        }),
      }),
      ui.button({
        text = connection.active and tr("panel.disconnect") or tr("panel.connect"),
        glyph = connection.active and "plug-off" or "plug-connected",
        variant = "outline",
        controlSize = "sm",
        enabled = not busy,
        onClick = function()
          request({ action = connection.active and "down" or "up", uuid = connection.uuid })
        end,
      }),
    }),
    liveBlock(snapshot.live),
    ui.separator({}),
    ui.row({ gap = 8, align = "end" }, {
      methodSelect("ipv4", not locked),
      ui.label({
        text = tr("panel.profile_hint"),
        fontSize = 10,
        color = "on_surface_variant",
        flexGrow = 1,
        maxLines = 2,
      }),
    }),
    ui.row({ gap = 8 }, {
      fieldInput("ipv4_addresses", "192.168.1.50/24", not locked and v4Addressed),
      fieldInput("ipv4_gateway", "192.168.1.1", not locked and v4Addressed),
    }),
    ui.row({ gap = 8 }, {
      fieldInput("ipv4_dns", "1.1.1.1, 8.8.8.8", not locked),
      fieldInput("ipv4_dns_search", "lan", not locked),
    }),
    ui.separator({}),
    ui.row({ gap = 8, align = "end" }, {
      methodSelect("ipv6", not locked),
      ui.label({
        text = tr("panel.ipv6_hint"),
        fontSize = 10,
        color = "on_surface_variant",
        flexGrow = 1,
        maxLines = 2,
      }),
    }),
    ui.row({ gap = 8 }, {
      fieldInput("ipv6_addresses", "2001:db8::5/64", not locked and v6Addressed),
      fieldInput("ipv6_gateway", "fe80::1", not locked and v6Addressed),
    }),
    ui.row({ gap = 8 }, {
      fieldInput("ipv6_dns", "2606:4700:4700::1111", not locked),
      fieldInput("ipv6_dns_search", "lan", not locked),
    }),
    ui.separator({}),
    changesBlock(changes, invalid),
    ui.row({ gap = 8 }, {
      ui.button({
        text = tr("panel.apply"),
        glyph = "check",
        variant = "primary",
        flexGrow = 1,
        enabled = applyEnabled,
        onClick = function()
          if snapshot.selected ~= nil and draft ~= nil then
            request({ action = "apply", uuid = snapshot.selected, form = draft })
          end
        end,
      }),
      ui.button({
        text = tr("panel.reset"),
        glyph = "arrow-back-up",
        variant = "outline",
        enabled = draft ~= nil and not busy,
        onClick = function()
          seedDraft()
          render()
        end,
      }),
    }),
  }

  if snapshot.backup ~= nil then
    table.insert(children, ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "history", size = 14, color = "on_surface_variant" }),
      ui.label({
        text = tr("panel.backup", {
          summary = snapshot.backup.summary,
          time = noctalia.formatTime("%H:%M", snapshot.backup.at),
        }),
        fontSize = 10,
        color = "on_surface_variant",
        flexGrow = 1,
        maxLines = 2,
      }),
      ui.button({
        text = tr("panel.restore"),
        variant = "outline",
        controlSize = "sm",
        enabled = not locked,
        onClick = function()
          request({ action = "restore" })
        end,
      }),
    }))
  end

  return ui.column({ gap = 10, padding = 10, radius = 8, border = "outline/0.4", borderWidth = 1 }, children)
end

local function radioRow()
  local radios = snapshot.radio or {}
  local wifi = radios.wifi
  if wifi == nil then
    return ui.column({})
  end
  local available_ = wifi ~= "missing" and wifi ~= "unknown"
  return ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = wifi == "enabled" and "wifi" or "wifi-off", size = 16, color = "primary" }),
    ui.label({ text = tr("panel.wifi_radio"), fontSize = 12, flexGrow = 1 }),
    ui.toggle({
      key = "radio-wifi",
      checked = wifi == "enabled",
      enabled = available_ and not snapshot.busy,
      onChange = function(value)
        request({ action = "radio", kind = "wifi", on = tostring(value) == "true" })
      end,
    }),
  })
end

-- ── wi-fi picker ─────────────────────────────────────────────────────────────

local function securityGlyph(network)
  if net.isOpenNetwork(network.security) then
    return "lock-open"
  end
  return "lock"
end

local function networkDetail(network, saved)
  local parts = { net.isOpenNetwork(network.security) and tr("wifi.open") or network.security }
  if network.aps > 1 then
    table.insert(parts, tr("wifi.aps", { count = network.aps }))
  end
  if net.isEnterprise(network.security) then
    table.insert(parts, tr("wifi.enterprise_short"))
  end
  if saved then
    table.insert(parts, tr("wifi.saved"))
  end
  return table.concat(parts, " · ")
end

local function passwordRow(network)
  local connect = function()
    local ssid = network.ssid
    local secret = wifiPassword
    request({ action = "wifi-connect", ssid = ssid, password = secret })
    wifiPasswordSsid = nil
    wifiPassword = ""
    wifiGen = wifiGen + 1
    render()
  end
  return ui.row({ gap = 6, align = "center", padding = 6, radius = 6, fill = "surface_variant/0.35" }, {
    ui.input({
      key = "wifi-pw:" .. network.ssid .. ":" .. tostring(wifiGen),
      value = "",
      placeholder = tr("wifi.password_placeholder"),
      fontSize = 12,
      controlSize = "sm",
      password = true,
      submitOnEnter = true,
      focus = true,
      flexGrow = 1,
      onChange = function(text)
        wifiPassword = tostring(text)
      end,
      onSubmit = connect,
    }),
    ui.button({
      text = tr("wifi.connect"),
      glyph = "check",
      variant = "primary",
      controlSize = "sm",
      onClick = connect,
    }),
    ui.button({
      glyph = "x",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("wifi.cancel"),
      onClick = function()
        wifiPasswordSsid = nil
        wifiPassword = ""
        wifiGen = wifiGen + 1
        render()
      end,
    }),
  })
end

local function networkRow(network)
  local saved = type(snapshot.saved_ssids) == "table" and snapshot.saved_ssids[network.ssid] ~= nil
  local enterprise = net.isEnterprise(network.security)
  local locked = snapshot.busy == true or snapshot.scanning == true
  local busyLabel = network.in_use and tr("wifi.connected") or tr("wifi.connect")

  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({
        name = "antenna-bars-" .. tostring(net.signalBars(network.signal)),
        size = 16,
        color = network.in_use and "primary" or "on_surface_variant",
      }),
      ui.column({ gap = 0, flexGrow = 1 }, {
        ui.label({ text = network.ssid, fontSize = 12, maxLines = 1, fontWeight = network.in_use and "bold" or "normal" }),
        ui.label({ text = networkDetail(network, saved), fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
      }),
      ui.glyph({ name = securityGlyph(network), size = 13, color = "on_surface_variant" }),
      ui.label({
        text = tostring(network.signal) .. "%",
        fontSize = 10,
        width = 42,
        textAlign = "end",
        color = "on_surface_variant",
      }),
      ui.button({
        text = busyLabel,
        variant = network.in_use and "secondary" or "outline",
        controlSize = "sm",
        enabled = not locked and not network.in_use and not enterprise,
        onClick = function()
          if enterprise then
            return
          end
          if net.needsPassword(network.security) and not saved then
            -- Ask for the secret before touching the radio.
            wifiPasswordSsid = network.ssid
            wifiPassword = ""
            wifiGen = wifiGen + 1
            render()
            return
          end
          request({ action = "wifi-connect", ssid = network.ssid })
        end,
      }),
    }),
  }
  if wifiPasswordSsid == network.ssid then
    table.insert(children, passwordRow(network))
  end
  return ui.column({ gap = 4 }, children)
end

local function manualRow()
  local connect = function()
    if manualSsid == "" then
      return
    end
    request({ action = "wifi-connect", ssid = manualSsid, password = manualPassword, hidden = true })
    manualSsid = ""
    manualPassword = ""
    wifiGen = wifiGen + 1
    render()
  end
  local locked = snapshot.busy == true or snapshot.scanning == true
  return ui.column({ gap = 4, padding = 6, radius = 6, fill = "surface_variant/0.2" }, {
    ui.label({ text = tr("wifi.manual"), fontSize = 10, color = "on_surface_variant" }),
    ui.row({ gap = 6, align = "center" }, {
      ui.input({
        key = "manual-ssid:" .. tostring(wifiGen),
        value = "",
        placeholder = tr("wifi.manual_placeholder"),
        fontSize = 12,
        controlSize = "sm",
        flexGrow = 1,
        enabled = not locked,
        onChange = function(text)
          manualSsid = tostring(text)
        end,
        onSubmit = connect,
      }),
      ui.input({
        key = "manual-pw:" .. tostring(wifiGen),
        value = "",
        placeholder = tr("wifi.password"),
        fontSize = 12,
        controlSize = "sm",
        password = true,
        flexGrow = 1,
        enabled = not locked,
        onChange = function(text)
          manualPassword = tostring(text)
        end,
        onSubmit = connect,
      }),
      ui.button({
        glyph = "arrow-right",
        variant = "outline",
        controlSize = "sm",
        tooltip = tr("wifi.connect"),
        enabled = not locked and manualSsid ~= "",
        onClick = connect,
      }),
    }),
  })
end

local function wifiSection()
  local networks = snapshot.networks or {}
  local scanning = snapshot.scanning == true
  local radioOn = (snapshot.radio or {}).wifi == "enabled"
  local age = snapshot.scanned_age_ms
  local status
  if scanning then
    status = tr("wifi.scanning")
  elseif #networks > 0 then
    status = tr("wifi.found", { count = #networks })
    if type(age) == "number" and age > 60000 then
      status = status .. " · " .. tr("wifi.age_min", { minutes = math.floor(age / 60000) })
    end
  else
    status = tr("wifi.empty")
  end

  local header = ui.row({ gap = 6, align = "center" }, {
    ui.button({
      glyph = wifiOpen and "chevron-down" or "chevron-right",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("wifi.toggle"),
      onClick = function()
        wifiOpen = not wifiOpen
        if wifiOpen and #networks == 0 and radioOn then
          request({ action = "scan" })
        end
        render()
      end,
    }),
    ui.glyph({ name = radioOn and "wifi" or "wifi-off", size = 16, color = radioOn and "primary" or "on_surface_variant" }),
    ui.label({ text = tr("wifi.section"), fontWeight = "bold", fontSize = 13 }),
    ui.label({ text = status, fontSize = 10, color = "on_surface_variant", flexGrow = 1, maxLines = 1, textAlign = "end" }),
    ui.button({
      glyph = "refresh",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("wifi.scan"),
      enabled = radioOn and not scanning and snapshot.busy ~= true,
      onClick = function()
        request({ action = "scan", rescan = true })
      end,
    }),
  })

  if not wifiOpen then
    return ui.column({ gap = 4 }, { header })
  end

  local children = { header }
  if not radioOn then
    table.insert(children, ui.label({ text = tr("wifi.radio_off"), fontSize = 11, color = "error" }))
  end
  if #networks == 0 then
    if radioOn then
      table.insert(children, ui.label({ text = tr("wifi.empty_hint"), fontSize = 11, color = "on_surface_variant" }))
    end
  else
    for _, network in ipairs(networks) do
      table.insert(children, networkRow(network))
    end
  end
  table.insert(children, manualRow())
  return ui.column({ gap = 6, padding = 8, radius = 8, border = "outline/0.4", borderWidth = 1 }, children)
end

local function primarySummary()
  local primary = snapshot.primary
  if primary == nil then
    return ui.row({ gap = 8, align = "center", padding = 8, radius = 8, fill = "surface_variant/0.3" }, {
      ui.glyph({ name = "network-off", size = 16, color = "error" }),
      ui.label({ text = tr("panel.offline"), fontSize = 12, color = "error", flexGrow = 1 }),
    })
  end
  local address = orEmpty(primary.address)
  local connection = primary.live ~= nil and primary.live.connection or ""
  return ui.row({ gap = 8, align = "center", padding = 8, radius = 8, fill = "surface_variant/0.3" }, {
    ui.glyph({ name = "world", size = 16, color = "primary" }),
    ui.label({
      text = tr("panel.primary", { device = primary.device, address = address, name = connection }),
      fontSize = 11,
      flexGrow = 1,
      maxLines = 2,
    }),
  })
end

function render()
  local children = {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "network", size = 20, color = "primary" }),
      ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "refresh", variant = "ghost", tooltip = tr("panel.refresh"), onClick = function()
        request({ action = "refresh" })
      end }),
      ui.button({ glyph = "x", variant = "ghost", onClick = function()
        panel.close()
      end }),
    }),
  }

  if snapshot.available ~= true then
    table.insert(children, ui.row({ gap = 8, align = "center", padding = 10, radius = 8, fill = "error/0.12" }, {
      ui.glyph({ name = "alert-triangle", size = 18, color = "error" }),
      ui.label({ text = tr("panel.unavailable"), fontSize = 12, flexGrow = 1 }),
    }))
    panel.render(ui.column({ flexGrow = 1, gap = 10, padding = 10 }, children))
    return
  end

  table.insert(children, primarySummary())
  if snapshot.permission_ok ~= true then
    table.insert(children, ui.row({ gap = 8, align = "center", padding = 8, radius = 8, fill = "error/0.12" }, {
      ui.glyph({ name = "lock", size = 16, color = "error" }),
      ui.label({ text = tr("panel.permission"), fontSize = 11, color = "error", flexGrow = 1 }),
    }))
  end
  if snapshot.pending ~= nil then
    table.insert(children, pendingBanner(snapshot.pending))
  end
  if snapshot.busy == true then
    table.insert(children, ui.label({ text = tr("panel.busy"), fontSize = 11, color = "primary" }))
  end
  if type(snapshot.error) == "string" and snapshot.error ~= "" then
    table.insert(children, ui.label({ text = snapshot.error, fontSize = 11, color = "error" }))
  end

  table.insert(children, radioRow())
  table.insert(children, wifiSection())
  table.insert(children, ui.separator({}))

  table.insert(children, sectionTitle("panel.connections"))
  local shown = 0
  for _, connection in ipairs(snapshot.connections or {}) do
    if connection.editable then
      table.insert(children, connectionRow(connection))
      shown = shown + 1
    end
  end
  if shown == 0 then
    table.insert(children, ui.label({ text = tr("panel.no_connections"), fontSize = 11, color = "on_surface_variant" }))
  end

  local connection = connectionByUuid(snapshot.selected)
  if connection ~= nil then
    table.insert(children, ui.separator({}))
    table.insert(children, sectionTitle("panel.edit"))
    table.insert(children, editorCard(connection))
  end

  table.insert(children, ui.label({
    text = tr("panel.confirm_note", { seconds = snapshot.confirm_seconds or 0 }),
    fontSize = 10,
    color = "on_surface_variant",
    opacity = 0.8,
    maxLines = 3,
  }))

  panel.render(ui.scroll({ flexGrow = 1, gap = 10, padding = 10 }, children))
end

function onOpen(_context)
  local state = noctalia.state.get("network.state")
  if type(state) == "table" then
    snapshot = state
  end
  draft = nil
  draftReady = false
  syncDraft()
  request({ action = "refresh" })
  if #(snapshot.networks or {}) == 0 then
    -- cached list first: opening the panel must not block on a 6s radio scan
    request({ action = "scan" })
  end
  render()
end

function onClose()
  -- Nothing runs in the background here: the service owns every call.
end

noctalia.state.watch("network.state", function(value)
  if type(value) ~= "table" then
    return
  end
  local wasBusy = lastBusy
  lastBusy = value.busy == true
  snapshot = value
  if wasBusy and not lastBusy then
    -- A write landed (or was reverted): the stored profile moved under us.
    draftReady = false
  end
  syncDraft()
  render()
end)

render()
