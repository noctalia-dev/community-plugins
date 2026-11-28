--!nonstrict
-- EncoBuds panel.
--
-- A UI client of the service snapshot, laid out like the HeyMelody device
-- page: product render, L/R battery, three round listening-mode buttons, the
-- current ANC level, device management, game mode, prompt volume and
-- "find my earbuds". Every action is a command published on
-- `encobuds.cmd`; the service owns Bluetooth and the EncoBuds process.

local PRODUCT_NAMES = {
  ["06C410"] = "OPPO Enco Air5 Pro",
}

local PRODUCT_IMAGE = "assets/enco-air5-pro.png"

local MODE_LABEL_KEY = {
  [1] = "mode.anc",
  [4] = "mode.deep",
  [5] = "mode.mid",
  [6] = "mode.light",
  [7] = "mode.smart",
}

local MODE_BUTTONS = {
  { key = "anc", glyph = "headphones", label = "mode.anc" },
  { key = "off", glyph = "headphones-off", label = "mode.off" },
  { key = "trans", glyph = "ear", label = "mode.trans" },
}

local ANC_LEVELS = {
  { key = "smart", label = "mode.short.smart", id = 7 },
  { key = "deep", label = "mode.short.deep", id = 4 },
  { key = "mid", label = "mode.short.mid", id = 5 },
  { key = "light", label = "mode.short.light", id = 6 },
}

local snapshot = nil
local isOpen = false
local volumeDraft = nil
local volumeDragging = false
local lastNonce = 0
local lastRefreshSent = 0

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function trim(text)
  return noctalia.string.trim(text or "")
end

local function decode(encoded)
  if encoded == nil then
    return nil
  end
  local value = noctalia.json.decode(encoded)
  if type(value) ~= "table" then
    return nil
  end
  return value
end

local function send(fields)
  local nonce = math.max(noctalia.nowMs(), lastNonce + 1)
  lastNonce = nonce
  fields.n = nonce
  noctalia.state.set("encobuds.cmd", noctalia.json.encode(fields))
end

local function online()
  return snapshot ~= nil and snapshot.phase == "online"
end

local function busy()
  return snapshot ~= nil and snapshot.busy ~= nil
end

local function enabled()
  return online() and not busy()
end

local function compact(list)
  local out = {}
  for _, node in ipairs(list) do
    if node ~= nil then
      out[#out + 1] = node
    end
  end
  return out
end

local render

local function family(mode)
  if mode == 0 or mode == 3 then
    return "off"
  end
  if mode == 2 or mode == 8 or mode == 9 then
    return "trans"
  end
  return "anc"
end

local function levelLabel(mode)
  if mode == 1 or mode == 7 then
    return tr("panel.auto")
  end
  local key = mode ~= nil and MODE_LABEL_KEY[mode] or nil
  return key and tr(key) or "?"
end

local function deviceName(st)
  local custom = trim(noctalia.getConfig("device_name") or "")
  if custom ~= "" then
    return custom
  end
  local product = st and st.product
  if product ~= nil and PRODUCT_NAMES[product] ~= nil then
    return PRODUCT_NAMES[product]
  end
  return tr("title")
end

local function batteryGlyph(level)
  if level == nil then
    return "battery-off"
  elseif level >= 88 then
    return "battery-4"
  elseif level >= 63 then
    return "battery-3"
  elseif level >= 38 then
    return "battery-2"
  elseif level >= 13 then
    return "battery-1"
  end
  return "battery"
end

local function batteryMini(labelKey, value)
  local level = value and value.level or nil
  local charging = value ~= nil and value.charging == true
  local color = charging and "tertiary"
    or (level ~= nil and level <= 20 and "error" or "on_surface/0.65")
  return ui.row({ gap = 3, align = "center" }, {
    ui.glyph({
      name = charging and "battery-charging" or batteryGlyph(level),
      size = 13,
      color = color,
    }),
    ui.label({
      text = tr(labelKey) .. " " .. (level ~= nil and (tostring(level) .. "%") or "--"),
      fontSize = 10,
      color = "on_surface/0.65",
    }),
  })
end

local function batteryRow(st)
  local batt = st.battery or {}
  return ui.row({ gap = 10, align = "center" }, compact({
    batteryMini("battery.short.left", batt.left),
    batteryMini("battery.short.right", batt.right),
    batt.case ~= nil and batteryMini("battery.short.case", batt.case) or nil,
  }))
end

local function aboutText(st)
  if st == nil or not online() then
    return nil
  end
  return tr("panel.about_line", {
    product = tostring(st.product or "?"),
    firmware = tostring(st.firmware or "?"),
  })
end

local function header(st)
  local info = {
    ui.label({ text = deviceName(st), fontSize = 17, fontWeight = "bold", maxLines = 1 }),
  }

  if online() then
    table.insert(info, batteryRow(st))
  else
    local subtitle
    if st == nil or st.phase == "loading" then
      subtitle = tr("status.loading")
    elseif st.phase == "offline" then
      subtitle = tr("status.offline")
    else
      subtitle = tr("status.error")
    end
    table.insert(info, ui.label({ text = subtitle, fontSize = 10, color = "on_surface/0.55" }))
  end

  return ui.row({ gap = 10, align = "center" }, {
    ui.column({
      width = 42,
      height = 42,
      radius = 13,
      fill = online() and "primary/0.15" or "on_surface/0.08",
      align = "center",
      justify = "center",
      tooltip = aboutText(st),
    }, {
      ui.glyph({
        name = online() and "device-airpods" or "bluetooth-off",
        size = 21,
        color = online() and "primary" or "on_surface/0.45",
      }),
    }),
    ui.column({ gap = 5, flexGrow = 1 }, info),
    ui.button({
      glyph = "refresh",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("panel.refresh"),
      enabled = not busy(),
      onClick = function()
        send({ action = "refresh" })
      end,
    }),
    ui.button({
      glyph = "settings",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("panel.settings"),
      onClick = function()
        noctalia.openSettings()
      end,
    }),
  })
end

local function hero()
  if noctalia.getConfig("show_product_image") == false then
    return nil
  end
  return ui.column({ align = "center", paddingV = 2 }, {
    ui.image({
      path = PRODUCT_IMAGE,
      width = 132,
      height = 132,
      fit = "contain",
      opacity = online() and 1 or 0.45,
      tooltip = aboutText(snapshot),
    }),
  })
end

local function modeButtons(st)
  local current = family(st.mode)
  local cells = {}
  for _, item in ipairs(MODE_BUTTONS) do
    local selected = current == item.key
    local canAct = enabled()
    table.insert(cells, ui.column({
      key = "mode-" .. item.key,
      flexGrow = 1,
      gap = 7,
      align = "center",
      opacity = canAct and 1 or 0.55,
      tooltip = tr(item.label),
      onClick = function()
        -- Clicking the active family is a no-op; ANC levels are still
        -- selectable in the detail card below.
        if canAct and not selected then
          send({ action = "set_mode", mode = item.key })
        end
      end,
    }, {
      ui.column({
        width = 54,
        height = 54,
        radius = 27,
        fill = selected and "primary" or "on_surface/0.08",
        align = "center",
        justify = "center",
      }, {
        ui.glyph({
          name = item.glyph,
          size = 25,
          color = selected and "on_primary" or "on_surface/0.7",
        }),
      }),
      ui.label({
        text = tr(item.label),
        fontSize = 10,
        fontWeight = selected and "bold" or "medium",
        color = selected and "primary" or "on_surface/0.65",
        textAlign = "center",
        maxLines = 2,
      }),
    }))
  end
  return ui.row({ gap = 6, align = "start" }, cells)
end

-- ANC is the only family with selectable levels. Off and transparency are
-- complete modes of their own, so they get no detail row or chips.
local function detailCard(st)
  if family(st.mode) ~= "anc" then
    return nil
  end

  local chips = {}
  for _, level in ipairs(ANC_LEVELS) do
    local selected = st.mode == level.id or (level.id == 7 and st.mode == 1)
    table.insert(chips, ui.button({
      key = "level-" .. level.key,
      text = tr(level.label),
      fontSize = 10,
      variant = selected and "primary" or "outline",
      controlSize = "sm",
      flexGrow = 1,
      enabled = enabled(),
      onClick = function()
        send({ action = "set_mode", mode = level.key })
      end,
    }))
  end

  return ui.column({ gap = 6, padding = 8, radius = 12, fill = "surface_container/0.5" }, {
    ui.row({ justify = "space_between", align = "center" }, {
      ui.label({ text = tr("mode.anc"), fontSize = 13, fontWeight = "bold" }),
      ui.label({ text = levelLabel(st.mode), fontSize = 11, color = "on_surface/0.6" }),
    }),
    ui.row({ gap = 6 }, chips),
  })
end

local function sectionLabel(text, extra)
  return ui.row({ gap = 6, align = "center" }, compact({
    ui.label({ text = text, fontSize = 11, fontWeight = "bold", color = "on_surface/0.6", flexGrow = 1 }),
    extra ~= nil and ui.label({ text = extra, fontSize = 10, color = "on_surface/0.4" }) or nil,
  }))
end

local function deviceGlyph(kind)
  if kind == 1 then
    return "device-mobile"
  elseif kind == 2 then
    return "device-laptop"
  elseif kind == 3 then
    return "device-tablet"
  elseif kind == 4 or kind == 5 then
    return "device-watch"
  end
  return "devices"
end

local function deviceStatus(device)
  if device.current == true then
    return tr("panel.this_pc"), "primary"
  elseif device.connected == true and device.playing == true then
    return tr("panel.playing"), "tertiary"
  elseif device.connected == true then
    return tr("panel.connected"), "primary"
  end
  return tr("panel.not_connected"), "on_surface/0.5"
end

local function deviceCell(device, st)
  local connected = device.connected == true
  local current = device.current == true
  local status, statusColor = deviceStatus(device)
  local canAct = enabled() and not current
  return ui.column({
    key = "device-" .. device.mac,
    flexGrow = 1,
    gap = 4,
    align = "center",
    opacity = enabled() and 1 or 0.6,
    tooltip = tostring(device.mac) .. " · " .. status,
    onClick = function()
      if canAct then
        send({
          action = "device",
          verb = connected and "disconnect" or "connect",
          target = device.mac,
        })
      end
    end,
  }, {
    ui.column({
      width = 46,
      height = 46,
      radius = 23,
      fill = connected and "primary" or "on_surface/0.08",
      align = "center",
      justify = "center",
    }, {
      ui.glyph({
        name = deviceGlyph(device.type),
        size = 21,
        color = connected and "on_primary" or "on_surface/0.55",
      }),
    }),
    ui.label({
      text = tostring(device.name),
      fontSize = 10,
      fontWeight = "bold",
      color = connected and "on_surface" or "on_surface/0.55",
      maxLines = 1,
      textAlign = "center",
    }),
    ui.label({
      text = status,
      fontSize = 9,
      color = statusColor,
      maxLines = 1,
      textAlign = "center",
    }),
  })
end

local function devicesSection(st)
  local devices = st.devices or {}
  local rows = {}
  local cells = {}
  for _, device in ipairs(devices) do
    table.insert(cells, deviceCell(device, st))
  end
  if #cells == 0 then
    table.insert(rows, ui.label({
      text = tr("panel.no_devices"),
      fontSize = 11,
      color = "on_surface/0.55",
    }))
  else
    for i = 1, #cells, 3 do
      local row = {}
      for j = i, math.min(i + 2, #cells) do
        table.insert(row, cells[j])
      end
      while #row < 3 do
        table.insert(row, ui.spacer({ flexGrow = 1 }))
      end
      table.insert(rows, ui.row({ gap = 8 }, row))
    end
  end

  return ui.column({ gap = 5 }, {
    sectionLabel(tr("panel.device_management"), `({#devices})`),
    ui.column({ gap = 8, padding = 8, radius = 12, fill = "surface_container/0.5" }, rows),
  })
end

local function gamingSection(st)
  return ui.column({ gap = 5 }, {
    sectionLabel(tr("panel.gaming_features")),
    ui.row({
      gap = 8,
      padding = 8,
      radius = 12,
      fill = "surface_container/0.5",
      align = "center",
    }, {
      ui.glyph({
        name = "device-gamepad-2",
        size = 18,
        color = st.game == true and "primary" or "on_surface/0.55",
      }),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = tr("panel.game"), fontSize = 12, fontWeight = "bold" }),
        ui.label({ text = tr("panel.game_hint"), fontSize = 9, color = "on_surface/0.55" }),
      }),
      ui.toggle({
        checked = st.game == true,
        enabled = enabled(),
        onChange = function(value)
          send({ action = "game", value = value == "true" and "on" or "off" })
        end,
      }),
    }),
  })
end

local function volumeSection(st)
  local level = volumeDraft or st.volume
  return ui.column({ gap = 5 }, {
    sectionLabel(tr("panel.earbud_settings")),
    ui.column({
      gap = 6,
      padding = 8,
      radius = 12,
      fill = "surface_container/0.5",
    }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.glyph({ name = "volume", size = 17, color = "on_surface/0.6" }),
        ui.column({ gap = 1, flexGrow = 1 }, {
          ui.label({ text = tr("panel.volume"), fontSize = 12, fontWeight = "bold" }),
          ui.label({ text = tr("panel.volume_hint"), fontSize = 9, color = "on_surface/0.55" }),
        }),
        ui.label({
          text = level ~= nil and tostring(level * 10) .. "%" or "--",
          fontSize = 11,
          fontWeight = "bold",
          color = "primary",
        }),
      }),
      ui.slider({
        min = 2,
        max = 10,
        step = 1,
        value = level or 5,
        controlSize = "sm",
        enabled = enabled(),
        onChange = function(value)
          volumeDraft = tonumber(value)
          volumeDragging = true
          render()
        end,
        onDragEnd = function()
          local value = volumeDraft or st.volume
          volumeDragging = false
          if value ~= nil then
            send({ action = "volume", value = value })
          end
        end,
      }),
    }),
  })
end

local function findSection(st)
  local ringing = st.ringing == true
  -- A ring holds the single RFCOMM link, so the service marks itself busy.
  -- The stop button must stay usable while that is the active command.
  local canAct = online() and (not busy() or ringing)
  local function toggle()
    if canAct then
      send({ action = "find", value = ringing and "off" or "on" })
    end
  end
  return ui.column({ gap = 5 }, {
    sectionLabel(tr("panel.other_features")),
    ui.row({
      key = "find",
      gap = 8,
      padding = 8,
      radius = 12,
      fill = "surface_container/0.5",
      align = "center",
      opacity = canAct and 1 or 0.6,
      onClick = toggle,
    }, {
      ui.glyph({
        name = ringing and "bell-off" or "bell-ringing",
        size = 18,
        color = ringing and "error" or "primary",
      }),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({
          text = ringing and tr("panel.find_stop") or tr("panel.find"),
          fontSize = 12,
          fontWeight = "bold",
          color = ringing and "error" or "on_surface",
        }),
        ui.label({
          text = ringing and tr("panel.find_ringing") or tr("panel.find_hint"),
          fontSize = 9,
          color = "on_surface/0.55",
        }),
      }),
      ui.button({
        glyph = ringing and "bell-off" or "bell-ringing",
        variant = ringing and "destructive" or "primary",
        controlSize = "sm",
        enabled = canAct,
        tooltip = ringing and tr("panel.find_ringing") or tr("panel.find_hint"),
        onClick = toggle,
      }),
    }),
  })
end

local function errorBox(st)
  if st == nil or st.error == nil or st.phase == "online" then
    return nil
  end
  return ui.column({
    gap = 3,
    padding = 8,
    radius = 8,
    fill = "error/0.12",
  }, {
    ui.label({ text = tostring(st.error), fontSize = 10, color = "error", maxLines = 5 }),
  })
end

render = function()
  if not isOpen then
    return
  end
  local st = snapshot
  local children = { header(st) }

  if st ~= nil and st.phase == "online" then
    local image = hero()
    if image ~= nil then
      table.insert(children, image)
    end
    table.insert(children, modeButtons(st))
    local levels = detailCard(st)
    if levels ~= nil then
      table.insert(children, levels)
    end
    if noctalia.getConfig("show_devices") ~= false then
      table.insert(children, devicesSection(st))
    end
    table.insert(children, gamingSection(st))
    table.insert(children, volumeSection(st))
    table.insert(children, findSection(st))
  else
    local error = errorBox(st)
    if error ~= nil then
      table.insert(children, error)
    end
    table.insert(children, ui.column({
      gap = 6,
      padding = 12,
      radius = 10,
      fill = "surface_container/0.5",
    }, {
      ui.glyph({ name = "bluetooth-off", size = 24, color = "on_surface/0.4" }),
      ui.label({
        text = (st == nil or st.phase == "loading") and tr("status.loading") or tr("status.offline"),
        fontSize = 12,
        fontWeight = "bold",
        color = "on_surface/0.75",
      }),
      ui.label({ text = tr("panel.offline_hint"), fontSize = 10, color = "on_surface/0.55", maxLines = 3 }),
    }))
  end

  -- Content-sized panel: normally everything fits, so no scrollbar is shown.
  -- Keep the scroll view as a fallback for unusually tall content.
  panel.render(ui.column({ gap = 8, padding = 12, flexGrow = 1 }, {
    ui.scroll({ gap = 8, flexGrow = 1 }, children),
  }))
end

noctalia.state.watch("encobuds.state", function(encoded)
  snapshot = decode(encoded)
  if not volumeDragging then
    volumeDraft = snapshot and snapshot.volume or volumeDraft
  end
  render()
end)

function onOpen(_context)
  isOpen = true
  snapshot = decode(noctalia.state.get("encobuds.state"))
  volumeDraft = snapshot and snapshot.volume or nil
  volumeDragging = false
  render()

  -- onOpen also runs when the host recreates the surface; refreshing only a
  -- stale snapshot keeps that from turning into refresh -> render -> onOpen
  -- -> refresh. A real open after a while still refreshes immediately.
  local now = noctalia.nowMs()
  local updated = snapshot and snapshot.updatedAt or 0
  if snapshot == nil or now - lastRefreshSent > 5000 or now - updated > 5000 then
    lastRefreshSent = now
    send({ action = "refresh" })
  end
end

function onClose()
  isOpen = false
  volumeDragging = false
end
