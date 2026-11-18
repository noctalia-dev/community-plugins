--!nonstrict
local status = {}
local opened = false
local gesture = nil
local drawer = nil
local confirmUnpair = false
local text, filePath = "", ""
local host, pairPort, connectPort, code = "", "", "", ""
local inputRevision, commandId = 0, 0
local render
local typedText, typingTarget, typingSince = "", "", 0
local pendingScroll = nil
local pointerX, pointerY = nil, nil
local lastScrollAt = 0
local pendingWindow = nil
local renameKey, renameText = "", ""
local sizeIndex, sizeDirection, sizeReady, sizeHovered = 3, -1, false, false
local hoveredControl = nil
local SIZE_FACTORS = { 0.60, 0.75, 1.0 }
local SIZE_NAMES = { "small", "medium", "large" }
local PANEL_INSET, HEADER_HEIGHT = 21, 64
local SECTION_GAP, BODY_GAP = 14, 24
local NETWORK_GLYPHS = {
  USB = "usb", ["WI-FI"] = "wifi", ["5G"] = "signal-5g", NR = "signal-5g",
  LTE = "signal-lte", ["4G"] = "signal-4g", HSPA = "signal-h", ["HSPA+"] = "signal-h",
  ["H+"] = "signal-h", H = "signal-h", UMTS = "signal-3g", WCDMA = "signal-3g",
  EVDO = "signal-3g", CDMA2000 = "signal-3g", CDMA = "signal-3g", ["3G"] = "signal-3g",
  EDGE = "signal-e", E = "signal-e", GPRS = "signal-g", G = "signal-g", GSM = "signal-2g",
  IDEN = "signal-2g", ["2G"] = "signal-2g",
}

-- v4 NText/NIcon use points; native controls use logical pixels at 96 DPI.
local function points(size) return size * 96 / 72 end

local function tr(key) return noctalia.tr(key) end

local function label(props)
  props.fontFamily = "Adwaita Sans"
  props.fontSize = props.fontSize or points(11)
  props.fontWeight = props.fontWeight or "medium"
  return ui.label(props)
end

local function command(action, values, phone)
  local request = values or {}
  request.action = action
  if phone then request.target = status.serial or "" end
  commandId += 1
  request.id = commandId
  noctalia.state.set("command", request)
end

local function syncInputTicks()
  panel.setNeedsFrameTick(typedText ~= "" or pendingScroll ~= nil)
end

local function flushTyping()
  if typedText ~= "" then
    command("text", { text = typedText, target = typingTarget })
    typedText = ""
  end
  syncInputTicks()
end

local function queueTyping(value)
  if #typedText + #value > 1024 then flushTyping() end
  if typedText == "" then
    typingTarget = status.serial
    typingSince = noctalia.nowMs()
  end
  typedText ..= value
  panel.setNeedsFrameTick(true)
end

local function flushScroll()
  if not pendingScroll then return end
  flushTyping()
  local scroll = pendingScroll
  pendingScroll = nil
  local horizontal = math.abs(scroll.dx) > math.abs(scroll.dy)
  local delta = if horizontal then scroll.dx else scroll.dy
  if delta ~= 0 then
    local distance = math.clamp(delta * 0.12, -0.45, 0.45)
    local x, y = math.clamp(scroll.x, 0.12, 0.88), math.clamp(scroll.y, 0.12, 0.88)
    local center = if horizontal then x else y
    local first = math.clamp(center + distance / 2, 0.12, 0.88)
    local last = math.clamp(center - distance / 2, 0.12, 0.88)
    command("gesture", {
      points = if horizontal then { first, y, last, y } else { x, first, x, last }, duration = 120,
    }, true)
    lastScrollAt = noctalia.nowMs()
  end
  syncInputTicks()
end

local function toggleDrawer(name)
  drawer = if drawer == name then nil else name
  confirmUnpair = false
  if drawer == "wireless" then
    host, pairPort, connectPort, code = status.wirelessHost or "", "", "", ""
    inputRevision += 1
    command("wirelessOpen", { kdeTarget = status.selectedKde or "" })
  end
  render()
end

local function caption(key)
  return label({ text = tr(key), fontSize = points(10 * 1.15), color = "on_surface_variant", maxLines = 1 })
end

local function button(key, action, enabled)
  return ui.button({ text = tr(key), controlSize = "sm", enabled = enabled ~= false, onClick = action })
end

local function icon(key, glyph, action, enabled, active, size, glyphSize)
  size = size or 32
  local allowed = enabled ~= false
  local hovered = allowed and hoveredControl == key
  return ui.column({
    key = key, width = size, height = size, minWidth = size, minHeight = size,
    align = "center", justify = "center", radius = size / 2,
    fill = if active then "primary/0.18" elseif hovered then "primary/0.10" else "surface_container/0.55",
    border = if active then "primary/0.4" elseif hovered then "primary/0.25" else "outline_variant/0.22", borderWidth = 1,
    opacity = if allowed then 1 else 0.6, tooltip = tr(key),
    onClick = if allowed then action else nil,
    onHover = if allowed then "onControlHover" else nil,
  }, {
    ui.glyph({ name = glyph, size = glyphSize or points(13),
      color = if active or hovered then "primary" else "on_surface" }),
  })
end

local function selectedKde()
  for _, device in status.kde or {} do
    if device.id == status.selectedKde then return device end
  end
  return nil
end

local function selectedAdb()
  for _, device in status.adb or {} do
    if device.serial == status.serial then return device end
  end
  return nil
end

local function nameKey()
  local device = selectedKde()
  if device then return "kde:" .. device.id end
  return if selectedAdb() then "adb:" .. status.serial else ""
end

local function deviceName(key, original)
  return (status.names and status.names[key]) or original
end

local function brand(name)
  local lower = string.lower(name)
  local family = "android"
  if string.find(lower, "pixel") or string.find(lower, "google") then family = "google"
  elseif string.find(lower, "xiaomi") or string.find(lower, "redmi") or string.find(lower, "poco") then family = "xiaomi"
  elseif string.find(lower, "moto") then family = "motorola" end
  return "Assets/brand-badges/" .. family .. ".svg"
end

local function sectionTitle(key)
  return label({ text = tr(key), fontSize = if sizeIndex == 1 then 11 else 12,
    fontWeight = "bold", color = "on_surface_variant", maxLines = 1 })
end

local function metric(glyph, title, value, color, detail)
  local badgeSize = ({ 34, 42, 50 })[sizeIndex]
  local values = {
    label({ text = value, fontSize = ({ 18, 20, 22 })[sizeIndex], fontWeight = "bold",
      color = color or "on_surface", maxLines = 1 }),
  }
  if detail then
    table.insert(values, label({ text = tr(detail), fontSize = 11, color = "primary", maxLines = 1 }))
  end
  return ui.row({ key = title, height = ({ 46, 60, 76 })[sizeIndex], gap = 12, align = "center" }, {
    ui.column({ width = badgeSize, height = badgeSize, minWidth = badgeSize,
      align = "center", justify = "center", radius = math.round(badgeSize * 0.3), fill = "surface_container/0.65",
    }, {
      ui.glyph({ name = glyph, size = math.round(badgeSize * 0.52), color = "primary" }),
    }),
    ui.column({ gap = 3, flexGrow = 1, minWidth = 0 }, {
      label({ text = tr(title), fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
      ui.row({ gap = 7, align = "center" }, values),
    }),
  })
end

local function quickAction(key, glyph, action, enabled, active)
  local allowed = enabled ~= false
  local hovered = allowed and hoveredControl == key
  local badgeSize = ({ 30, 36, 44 })[sizeIndex]
  return ui.column({ key = key, flexGrow = 1, minWidth = 0, height = ({ 70, 86, 108 })[sizeIndex],
    padding = 8, gap = 6, align = "center", justify = "center", radius = 18,
    fill = if active then "primary/0.14" elseif hovered then "primary/0.08" else "surface_container/0.45",
    border = if active then "primary/0.4" elseif hovered then "primary/0.22" else "outline_variant/0.16", borderWidth = 1,
    opacity = if allowed then 1 else 0.5, tooltip = tr(key),
    onClick = if allowed then action else nil,
    onHover = if allowed then "onControlHover" else nil,
  }, {
    ui.column({ width = badgeSize, height = badgeSize, radius = badgeSize / 2,
      fill = if active then "primary/0.22" elseif hovered then "primary/0.14" else "surface_container/0.65",
      align = "center", justify = "center",
    }, {
      ui.glyph({ name = glyph, size = math.round(badgeSize * 0.56),
        color = if active or hovered then "primary" else "on_surface" }),
    }),
    label({ text = tr(key), fontSize = if sizeIndex == 1 then 11 else 13, fontWeight = "medium",
      color = if active or hovered then "primary" else "on_surface", maxLines = 1 }),
  })
end

local function deviceControls(width, device)
  local kdeNames, kdeIndex = { tr("devices.adb_only") }, 0
  for index, entry in status.kde or {} do
    table.insert(kdeNames, deviceName("kde:" .. entry.id, entry.name) .. (if entry.reachable then "" else " · " .. tr("status.disconnected")))
    if entry.id == status.selectedKde then kdeIndex = index end
  end
  local adbNames, adbEntries, adbIndex = { tr("devices.choose_adb") }, { "" }, 0
  for _, entry in status.adb or {} do
    if entry.state == "device" then
      table.insert(adbNames, deviceName("adb:" .. entry.serial, entry.name) .. " · " .. entry.serial)
      table.insert(adbEntries, entry.serial)
      if entry.serial == status.serial then adbIndex = #adbNames - 1 end
    end
  end
  local children = {
    caption("devices.kde"),
    ui.select({ key = "kde", width = width, options = kdeNames, selectedIndex = kdeIndex, onChange = function(value)
      local entry = status.kde and status.kde[tonumber(value)]
      gesture = nil
      confirmUnpair = false
      command("select", { kde = entry and entry.id or "" })
    end }),
  }
  local needsAdbChoice = not device and (#adbEntries > 2 or (#adbEntries == 2 and (not status.serial or status.serial == "")))
  if needsAdbChoice then
    table.insert(children, caption("devices.adb"))
    table.insert(children, ui.select({ key = "adb", width = width, options = adbNames, selectedIndex = adbIndex, onChange = function(value)
      gesture = nil
      command("select", { serial = adbEntries[(tonumber(value) or 0) + 1] or "" })
    end }))
  else
    table.insert(children, caption("devices.automatic"))
    table.insert(children, label({ text = if status.serial and status.serial ~= "" then tr("status.connected")
      else tr("devices.waiting_adb"), fontSize = 12, maxLines = 3, maxWidth = width }))
  end
  if device then
    table.insert(children, ui.row({ gap = 8 }, {
      button("actions.pair", function() command("pair", { kdeTarget = device.id }) end, not device.paired),
      button(if confirmUnpair then "actions.confirm_unpair" else "actions.unpair", function()
        if confirmUnpair then command("unpair", { kdeTarget = device.id }); confirmUnpair = false
        else confirmUnpair = true; render() end
      end, device.paired),
    }))
  end
  for _, entry in status.adb or {} do
    if not device and entry.state ~= "device" then
      table.insert(children, label({ text = entry.serial .. ": " .. entry.state, color = "error", maxLines = 2 }))
    end
  end
  table.insert(children, button("actions.refresh", function() command("refresh") end))
  return children
end

local function wirelessControls(width)
  if status.qrActive then
    return {
      caption("wireless.scan_qr"),
      ui.image({ key = status.qrPath, path = status.qrPath, width = math.min(width, 240), height = 240 }),
      button("wireless.cancel_qr", function() command("cancelQr") end),
    }
  end
  return {
    label({ text = tr("wireless.instructions"), fontSize = 12, color = "on_surface_variant", maxLines = 5, maxWidth = width }),
    label({ text = tr("wireless." .. (status.wirelessState or "idle")), fontSize = 12,
      color = if status.wirelessState == "timeout" then "error" else "on_surface_variant", maxLines = 4, maxWidth = width }),
    ui.input({ key = "host", value = host, controlSize = "sm", placeholder = tr("wireless.host"), onChange = function(value) host = value end }),
    ui.input({ key = "pair-port", value = pairPort, controlSize = "sm", placeholder = tr("wireless.pair_port"), onChange = function(value) pairPort = value end }),
    ui.input({ key = "code-" .. inputRevision, value = code, password = true, controlSize = "sm",
      placeholder = tr("wireless.code"), onChange = function(value) code = value end }),
    button("wireless.pair", function()
      command("pairAdb", { host = host, port = pairPort, code = code, kdeTarget = status.selectedKde or "" })
      code = ""; inputRevision += 1; render()
    end),
    ui.separator(),
    ui.input({ key = "connect-port", value = connectPort, controlSize = "sm",
      placeholder = tr("wireless.connect_port"), onChange = function(value) connectPort = value end }),
    ui.row({ gap = 8 }, {
      button("wireless.connect", function() command("connectAdb", { host = host, port = connectPort,
        kdeTarget = status.selectedKde or "" }) end),
      button("wireless.discover", function() command("autoConnect", { host = host,
        kdeTarget = status.selectedKde or "" }) end, status.wirelessState ~= "scanning"),
    }),
    button("wireless.qr", function() command("qr", { kdeTarget = status.selectedKde or "" }) end),
  }
end

local function drawerContent(width, device, active)
  if drawer == "rename" then
    return {
      caption("rename.local_only"),
      ui.input({ key = "rename-" .. inputRevision, value = renameText, controlSize = "sm",
        placeholder = tr("rename.name"), onChange = function(value) renameText = value end, onSubmit = "onRenameDevice" }),
      button("rename.save", onRenameDevice),
      button("rename.reset", function() renameText = ""; onRenameDevice() end),
    }
  end
  if drawer == "devices" then return deviceControls(width, device) end
  if drawer == "wireless" then return wirelessControls(width) end
  if drawer == "more" then
    local kdeReady = device ~= nil and device.paired and device.reachable
    local function item(key, glyph, action, enabled)
      return ui.button({ key = key, text = tr(key), glyph = glyph, variant = "ghost",
        contentAlign = "start", controlSize = "sm", enabled = enabled ~= false, onClick = action })
    end
    return {
      item("actions.browse", "folder", function() command("browse", { kdeTarget = device and device.id }) end, kdeReady),
      item("actions.send_file", "send", function() toggleDrawer("share") end, kdeReady),
      item("actions.ring", "radar", function() command("ring", { kdeTarget = device and device.id }) end, kdeReady),
      ui.separator({ color = "outline_variant/0.18" }),
      item("actions.type_text", "keyboard", function() toggleDrawer("text") end, active),
      item("actions.diagnostics", "info-circle", function() toggleDrawer("info") end),
      item("actions.settings", "settings", function() noctalia.openSettings() end),
    }
  end
  if drawer == "share" then
    return {
      caption("actions.file_path"),
      ui.input({ key = "file", value = filePath, controlSize = "sm", placeholder = tr("actions.file_path"),
        onChange = function(value) filePath = value end }),
      button("actions.send_file", function()
        command("share", { path = filePath, kdeTarget = device and device.id })
      end, device ~= nil and device.paired and device.reachable),
    }
  end
  if drawer == "text" then
    return {
      caption("actions.type_text"),
      ui.input({ key = "text-" .. inputRevision, value = text, controlSize = "sm",
        placeholder = tr("actions.type_text"), enabled = active, onSubmit = "onSendText",
        onChange = function(value) text = value end }),
      button("actions.send_text", onSendText, active),
    }
  end
  local children = {
    button("actions.devices", function() toggleDrawer("devices") end),
    button("actions.type_text", function() toggleDrawer("text") end, active),
    button("actions.settings", function() noctalia.openSettings() end),
    button("actions.refresh", function() command("refresh") end),
  }
  for name, available in status.tools or {} do
    table.insert(children, ui.row({ gap = 8 }, {
      ui.glyph({ name = if available then "check" else "x", size = 14, color = if available then "primary" else "error" }),
      label({ text = name, fontSize = 12, color = "on_surface_variant" }),
    }))
  end
  table.insert(children, button("actions.close", function() panel.close() end))
  return children
end

render = function()
  if not opened then return end
  local active = status.serial ~= nil and status.serial ~= ""
  local streaming = status.phase == "streaming"
  local mirroring = streaming or status.phase == "starting"
  local device, adb = selectedKde(), selectedAdb()
  local kdeReady = device ~= nil and device.paired and device.reachable
  local originalName = if device then device.name elseif adb then adb.name else tr("title")
  local identity = nameKey()
  local name = deviceName(identity, originalName)
  local phoneHeight = math.floor(math.clamp(noctalia.getConfig("preview_height") or 720, 240, 720) * SIZE_FACTORS[sizeIndex])
  local panelWidth = 680 -- Upstream owns panel width; height follows the content.
  local contentWidth = panelWidth - PANEL_INSET * 2
  local aspect = if status.screen then status.width / status.height else 597 / 1241
  local phoneWidth = math.floor(phoneHeight * aspect)
  local maximumPhoneWidth = contentWidth - BODY_GAP - 220
  if phoneWidth > maximumPhoneWidth then
    phoneWidth = maximumPhoneWidth
    phoneHeight = math.floor(phoneWidth / aspect)
  end
  local navigationScale = math.max(0.75, SIZE_FACTORS[sizeIndex])
  local navigationSize = math.round(42 * navigationScale)
  local navigationGlyphSize = points(10) * (if sizeIndex == 3 then 1 else 0.91)
  local function navigationButton(key, glyph, androidKey)
    return ui.column({ key = key .. "-slot", width = phoneWidth * 0.32, height = navigationSize,
      align = "center", justify = "center",
    }, {
      icon(key, glyph, function() command("key", { key = androidKey }, true) end,
        active, false, navigationSize, navigationGlyphSize),
    })
  end
  local rightWidth = contentWidth - phoneWidth - BODY_GAP
  local phoneColumnHeight = phoneHeight + SECTION_GAP + navigationSize
  local minimumBodyHeight = if drawer == "wireless" then 620 elseif drawer then 504 else ({ 478, 586, 704 })[sizeIndex]
  local bodyHeight = math.max(phoneColumnHeight, minimumBodyHeight)
  local frame = if streaming then ui.pixelStream({ key = "phone", path = status.socket or "",
    width = phoneWidth, height = phoneHeight, radius = 0,
    onPointerDown = "onPixelDown", onPointerUp = "onPixelUp",
    onPointerMove = "onPixelMove", onPointerCancel = "onPixelCancel",
    onRightClick = "onPixelBack", onMiddleClick = "onPixelHome", onScroll = "onPixelScroll",
    onTextInput = "onPixelText", onKeyEvent = "onPixelKey",
  }) else ui.image({ key = "phone-placeholder", path = "Assets/phone-idle.svg",
    width = phoneWidth, height = phoneHeight, fit = "stretch",
  })

  local info
  if drawer then
    local heading = if drawer == "wireless" then "actions.wireless" elseif drawer == "share" then "actions.send_file"
      elseif drawer == "devices" then "actions.devices" elseif drawer == "text" then "actions.type_text"
      elseif drawer == "more" then "actions.more"
      elseif drawer == "rename" then "actions.rename_device" else "actions.diagnostics"
    local children = {
      ui.row({ align = "center", gap = 8 }, {
        label({ text = tr(heading), fontSize = 15, fontWeight = "bold", flexGrow = 1 }),
        icon("actions.back_to_status", "x", function() drawer = nil; render() end),
      }),
    }
    for _, child in drawerContent(rightWidth - 24, device, active) do table.insert(children, child) end
    info = ui.column({ key = "drawer", width = rightWidth, padding = 12, gap = 10, radius = 18,
      fill = "surface_container/0.4", border = "outline_variant/0.2", borderWidth = 1 }, children)
  else
    local telemetry = if kdeReady then device else (status.phone or {})
    local battery = telemetry.battery or -1
    local network = if kdeReady and device.network and device.network ~= "" then device.network
      elseif adb then (if adb.usb then "USB" else "Wi-Fi") else tr("device.unknown")
    local signal = telemetry.signal or -1
    local strength = if signal < 0 then "unknown" elseif signal == 0 then "none" elseif signal == 1 then "weak"
      elseif signal == 2 then "fair" elseif signal == 3 then "good" else "excellent"
    local batteryIcon = if battery < 0 then "battery-exclamation" elseif telemetry.charging then "battery-charging-2"
      elseif battery < 5 then "battery" elseif battery < 25 then "battery-1" elseif battery < 50 then "battery-2"
      elseif battery < 75 then "battery-3" else "battery-4"
    local metrics = {
      metric(batteryIcon, "device.battery",
        if battery < 0 then tr("device.unknown") else tostring(battery) .. "%",
        if battery >= 0 and battery < 20 then "error" elseif battery > 95 then "primary" else "on_surface",
        if telemetry.charging then "device.charging" else nil),
      metric(NETWORK_GLYPHS[string.upper(network)] or "wave-square", "device.network", network),
      metric(if signal < 0 then "antenna-bars-off" else "antenna-bars-" .. tostring(math.clamp(signal + 1, 1, 5)),
        "device.signal", tr("signal." .. strength)),
    }
    if telemetry.notifications ~= nil then
      table.insert(metrics, metric("bell", "device.notifications", tostring(telemetry.notifications)))
    end
    local children = {
      ui.column({ key = "device-status", gap = 8 }, {
        sectionTitle("sections.device_status"),
        ui.separator({ color = "outline_variant/0.18", spacing = 0 }),
        ui.column({ gap = 6 }, metrics),
      }),
      ui.column({ key = "quick-actions", gap = 10 }, {
        sectionTitle("sections.quick_actions"),
        ui.row({ gap = 10 }, {
          quickAction("actions.screenshot", "camera", function() command("screenshot", nil, true) end, active, false),
          quickAction(if status.recording then "actions.stop_recording" else "actions.record", "video",
            function() command("record", nil, true) end, active, status.recording),
        }),
        ui.row({ gap = 10 }, {
          quickAction("actions.keep_awake", "coffee", function() command("keepAwake", nil, true) end,
            mirroring, status.keepAwake),
          quickAction("actions.dim", "moon", function() command("dim", nil, true) end, mirroring, status.dim),
        }),
      }),
    }
    if status.error and status.error ~= "" then
      table.insert(children, label({ text = status.error, fontSize = 12, maxLines = 7,
        maxWidth = rightWidth, color = "error" }))
    end
    local footer = ui.column({ key = "preview-status", gap = 10 }, {
      ui.separator({ color = "outline_variant/0.18", spacing = 0 }),
      ui.row({ gap = 8, align = "center" }, {
        ui.box({ width = 6, height = 6, radius = 3, fill = if streaming then "primary" else "outline_variant/0.6" }),
        label({ text = (if streaming then tr("status.live_preview") .. " · " else "")
          .. tr(if status.audio then "status.audio_on" else "status.audio_off"),
          fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
      }),
    })
    local contentProps = { key = "status-content", flexGrow = 1, gap = if sizeIndex == 1 then 10 else 16 }
    local content = if status.error and status.error ~= "" then ui.scroll(contentProps, children)
      else ui.column(contentProps, children)
    info = ui.column({ key = "status", width = rightWidth, height = bodyHeight,
      gap = if sizeIndex == 1 then 10 else 16, paddingV = 6, align = "stretch" }, {
      content,
      footer,
    })
  end

  -- The host supplies 14px; v4's nested 9 + 6 + 6 margins total 21px.
  panel.render(ui.column({ padding = PANEL_INSET - 14, gap = SECTION_GAP, align = "stretch" }, {
    ui.row({ key = "header", height = HEADER_HEIGHT, gap = 10, paddingH = 12, paddingV = 10, align = "center",
      fill = "surface_container/0.5", radius = 22, borderWidth = 0 }, {
      ui.column({ key = "phone-size", width = 34, height = 34, align = "center", justify = "center",
        onClick = "onCyclePhoneSize", onHover = "onSizeHover",
        tooltip = tr("size.tooltip") .. " " .. tr("size." .. SIZE_NAMES[sizeIndex])
          .. " (" .. tostring(SIZE_FACTORS[sizeIndex] * 100) .. "%)",
      }, {
        if sizeHovered then ui.glyph({ name = "resize", size = 21, color = "on_surface" })
          else ui.image({ path = brand(originalName), width = 34, height = 34 }),
      }),
      ui.column({ key = "device-name", flexGrow = 1, minWidth = 0, gap = 4, justify = "center",
        tooltip = tr("actions.rename_device"), onClick = if identity ~= "" then function()
          renameKey, renameText = identity, name
          inputRevision += 1
          drawer = "rename"
          render()
        end else nil,
      }, {
        label({ text = name, fontSize = if sizeIndex == 1 then 21 else 24,
          fontWeight = "bold", color = "on_surface", maxLines = 1 }),
        ui.row({ gap = 6, align = "center" }, {
          ui.box({ width = 5, height = 5, radius = 2.5, fill = if active or kdeReady then "primary" else "outline_variant" }),
          label({ text = tr(if active then "status.adb_connected" elseif kdeReady then "status.kde_connected" else "status.disconnected"),
            fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
        }),
      }),
      ui.row({ key = "header-actions", gap = 6, align = "center" }, {
        icon("actions.unlock", "lock-open", function() command("unlock", nil, true) end, active and not status.busy),
        icon("actions.devices", "devices", function() toggleDrawer("devices") end, true, drawer == "devices"),
        icon("actions.open_window", "external-link", onOpenWindow, active and not status.busy),
        icon("actions.audio", if status.audio then "volume" else "volume-off",
          function() command("audio", nil, true) end, active),
        icon("actions.wireless", "wifi", function() toggleDrawer("wireless") end, true, drawer == "wireless"),
        icon("actions.more", "dots", function() toggleDrawer("more") end, true, drawer == "more"),
      }),
    }),
    ui.row({ key = "body", height = bodyHeight, gap = BODY_GAP, align = "start" }, {
      ui.column({ key = "phone-column", width = phoneWidth, gap = SECTION_GAP, align = "center" }, {
        frame,
        ui.row({ width = phoneWidth, paddingH = phoneWidth * 0.02, gap = 0 }, {
          navigationButton("navigation.back", "arrow-back", 4),
          navigationButton("navigation.home", "home", 3),
          navigationButton("navigation.recents", "layout-grid", 187),
        }),
      }),
      info,
    }),
  }))
end

function onControlHover(entered, key)
  if entered == "true" then hoveredControl = key
  elseif hoveredControl == key then hoveredControl = nil end
  render()
end

function onRenameDevice()
  if not opened or renameKey == "" or renameKey ~= nameKey() then return end
  command("rename", { nameKey = renameKey, name = renameText })
  renameKey, renameText, drawer = "", "", nil
  render()
end

function onOpenWindow()
  if not opened or not status.serial or status.serial == "" or status.busy then return end
  flushTyping()
  gesture, pendingScroll = nil, nil
  pointerX, pointerY = nil, nil
  syncInputTicks()
  pendingWindow = tostring(noctalia.nowMs()) .. "-" .. tostring(commandId + 1)
  command("window", { token = pendingWindow }, true)
end

function onCyclePhoneSize()
  if not opened then return end
  flushTyping()
  gesture, pendingScroll = nil, nil
  pointerX, pointerY = nil, nil
  if sizeIndex == 3 then sizeDirection = -1 elseif sizeIndex == 1 then sizeDirection = 1 end
  sizeIndex += sizeDirection
  if sizeIndex == 3 then sizeDirection = -1 elseif sizeIndex == 1 then sizeDirection = 1 end
  sizeReady = true
  command("size", { preset = sizeIndex, direction = sizeDirection })
  syncInputTicks()
  render()
end

function onSizeHover(entered)
  sizeHovered = entered == "true"
  render()
end

function onOpen()
  opened = true
  pendingWindow = nil
  gesture = nil
  pointerX, pointerY = nil, nil
  drawer = nil
  status = noctalia.state.get("status") or {}
  host = status.wirelessHost or ""
  sizeIndex = status.phoneSize or 3
  sizeDirection = status.phoneSizeDirection or (if sizeIndex == 3 then -1 else 1)
  sizeReady = status.phoneSize ~= nil
  sizeHovered = false
  hoveredControl = nil
  command("open")
  render()
end

function onClose()
  opened = false
  pendingWindow = nil
  hoveredControl = nil
  renameKey, renameText = "", ""
  gesture = nil
  pointerX, pointerY = nil, nil
  code, text = "", ""
  typedText = ""
  pendingScroll = nil
  panel.setNeedsFrameTick(false)
  inputRevision += 1
  command("close")
end

function onExit()
  if opened then onClose() end
end

local function phonePosition(normX, normY, inside)
  if not opened or status.phase ~= "streaming" then return nil end
  local px, py = tonumber(normX), tonumber(normY)
  local screen = status.screen
  if not px or not py or not screen then return nil end
  -- The streamed image includes the bezel; Android coordinates must not.
  local x, y = px * status.width - screen.x, py * status.height - screen.y
  local radius = screen.radius
  local dx = x - math.clamp(x, radius, screen.width - radius)
  local dy = y - math.clamp(y, radius, screen.height - radius)
  if inside then
    if x < 0 or x > screen.width or y < 0 or y > screen.height or dx * dx + dy * dy > radius * radius then return nil end
  end
  return { x = math.clamp(x / screen.width, 0, 1), y = math.clamp(y / screen.height, 0, 1) }
end

function onPixelMove(x, y)
  if not opened or status.phase ~= "streaming" then return end
  pointerX, pointerY = tonumber(x), tonumber(y)
end

function onPixelDown(x, y)
  gesture = nil
  local position = phonePosition(x, y, true)
  if not position then return end
  flushScroll()
  flushTyping()
  onPixelMove(x, y)
  gesture = { x = position.x, y = position.y, time = noctalia.nowMs(), serial = status.serial }
end

function onPixelUp(x, y)
  local first = gesture
  gesture = nil
  local position = phonePosition(x, y, false)
  if not first or not position or first.serial ~= status.serial then return end
  command("gesture", { points = { first.x, first.y, position.x, position.y },
    duration = math.clamp(noctalia.nowMs() - first.time, 50, 3000) }, true)
end

function onPixelCancel()
  gesture, pendingScroll = nil, nil
  pointerX, pointerY = nil, nil
  syncInputTicks()
end

local function mouseKey(x, y, key)
  if not phonePosition(x, y, true) then return end
  flushScroll()
  flushTyping()
  gesture = nil
  command("key", { key = key }, true)
end

function onPixelBack(x, y) mouseKey(x, y, 4) end
function onPixelHome(x, y) mouseKey(x, y, 3) end

function onPixelScroll(dx, dy)
  local position = phonePosition(pointerX, pointerY, true)
  if not position or gesture then return end
  flushTyping()
  local previous = pendingScroll
  pendingScroll = {
    x = position.x, y = position.y,
    dx = math.clamp((previous and previous.dx or 0) + (tonumber(dx) or 0), -4, 4),
    dy = math.clamp((previous and previous.dy or 0) + (tonumber(dy) or 0), -4, 4),
  }
  syncInputTicks()
end

function onSendText()
  if text == "" then return end
  command("text", { text = text }, true)
  text = ""; inputRevision += 1; render()
end

function onPixelText(value)
  if not opened or status.phase ~= "streaming" or value == "" then return end
  flushScroll()
  queueTyping(value)
end

function onPixelKey(chord, pressed)
  if not opened or status.phase ~= "streaming" or pressed ~= "true" then return end
  flushScroll()
  -- Noctalia delivers text separately; other keys use capture_keys-style chords.
  if string.lower(chord) == "ctrl+v" then
    flushTyping()
    local clipboard = noctalia.clipboardText()
    if clipboard and clipboard ~= "" then command("text", { text = clipboard }, true) end
    return
  end
  chord = string.gsub(chord, "^Shift%+", "")
  local keys = {
    BackSpace = 67, Delete = 112, Return = 66, KP_Enter = 66,
    Left = 21, Up = 19, Right = 22, Down = 20,
    Home = 122, End = 123, Prior = 92, Next = 93, Page_Up = 92, Page_Down = 93,
  }
  if keys[chord] then
    flushTyping()
    command("key", { key = keys[chord] }, true)
  end
end

function onFrameTick()
  if typedText ~= "" and noctalia.nowMs() - typingSince >= 40 then flushTyping() end
  if pendingScroll and not status.busy and noctalia.nowMs() - lastScrollAt >= 180 then flushScroll() end
end

noctalia.state.watch("status", function(value)
  if type(value) ~= "table" then return end
  if value.selectedKde ~= status.selectedKde then
    host, pairPort, connectPort, code = value.wirelessHost or "", "", "", ""
    inputRevision += 1
    if drawer == "wireless" then
      command("wirelessOpen", { kdeTarget = value.selectedKde or "" })
    end
  elseif drawer == "wireless" and host == "" then
    host = value.wirelessHost or ""
  end
  if drawer == "wireless" and value.wirelessState == "connected" then connectPort = value.wirelessPort or "" end
  if value.serial ~= status.serial then pendingWindow = nil end
  if opened and pendingWindow and value.windowRequest == pendingWindow then
    pendingWindow = nil
    status = value
    panel.close()
    return
  end
  if not sizeReady and value.phoneSize then
    sizeIndex, sizeDirection = value.phoneSize, value.phoneSizeDirection or (if value.phoneSize == 3 then -1 else 1)
    sizeReady = true
  end
  if value.serial ~= status.serial or value.phase ~= "streaming" then
    gesture = nil
    pointerX, pointerY = nil, nil
    typedText = ""
    pendingScroll = nil
    panel.setNeedsFrameTick(false)
  end
  status = value
  if drawer == "rename" and renameKey ~= nameKey() then
    renameKey, renameText, drawer = "", "", nil
  end
  render()
end)
