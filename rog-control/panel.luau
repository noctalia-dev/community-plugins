--!nonstrict
-- ROG Control panel.
--
-- Everything the hardware does is shown from the service's snapshot; every
-- control sends one request back. Live readings (fans, CPU temperature, whether
-- the NVIDIA GPU is awake, the power source) are plain sysfs reads made once a
-- second while the panel is open, never otherwise. Reading runtime_status does not
-- wake the GPU.

local model = require("./lib/model.luau")

local snapshot = { available = false }
local live = {} -- sysfs readings, refreshed each second while open
local lastLiveSig = ""
local paths = nil -- discovered once: hwmon fans, coretemp, dGPU, power supplies
local product = nil -- the laptop's name, read once
local isOpen = false

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function request(action, value)
  noctalia.state.set(model.REQUEST, { action = action, value = value, at = noctalia.nowMs() })
end

-- sysfs ---------------------------------------------------------------------

local function read(path)
  local text = noctalia.readFile(path)
  return text ~= nil and noctalia.string.trim(text) or nil
end

local function discover()
  paths = { fans = {}, cpuTemp = nil, gpu = nil, mains = nil, battery = nil }
  for _, h in ipairs(noctalia.listDir("/sys/class/hwmon") or {}) do
    local base = `/sys/class/hwmon/{h}`
    local name = read(`{base}/name`)
    if name == "asus" then
      for i = 1, 4 do
        local label = read(`{base}/fan{i}_label`)
        if label ~= nil then
          table.insert(paths.fans, { label = label, path = `{base}/fan{i}_input` })
        end
      end
    elseif name == "coretemp" then
      paths.cpuTemp = `{base}/temp1_input` -- package temperature
    end
  end
  for _, dev in ipairs(noctalia.listDir("/sys/bus/pci/devices") or {}) do
    local base = `/sys/bus/pci/devices/{dev}`
    local class = read(`{base}/class`) or ""
    if read(`{base}/vendor`) == "0x10de" and string.sub(class, 1, 4) == "0x03" then
      paths.gpu = `{base}/power/runtime_status`
      break
    end
  end
  for _, name in ipairs(noctalia.listDir("/sys/class/power_supply") or {}) do
    local base = `/sys/class/power_supply/{name}`
    local kind = read(`{base}/type`)
    if kind == "Mains" then
      paths.mains = base
    elseif kind == "Battery" and paths.battery == nil then
      paths.battery = base
    end
  end
end

local function sample()
  if paths == nil then
    discover()
  end
  local fresh = { fans = {} }
  for _, fan in ipairs(paths.fans) do
    table.insert(fresh.fans, { label = fan.label, rpm = tonumber(read(fan.path)) })
  end
  if paths.cpuTemp ~= nil then
    local milli = tonumber(read(paths.cpuTemp))
    fresh.cpuTemp = milli ~= nil and math.round(milli / 1000) or nil
  end
  if paths.gpu ~= nil then
    fresh.gpu = read(paths.gpu)
  end
  if paths.mains ~= nil then
    fresh.pluggedIn = read(`{paths.mains}/online`) == "1"
  end
  if paths.battery ~= nil then
    fresh.capacity = tonumber(read(`{paths.battery}/capacity`))
    fresh.status = read(`{paths.battery}/status`)
  end
  live = fresh
end

-- Building blocks -----------------------------------------------------------

local function sectionTitle(key)
  return ui.label({ text = tr(key), fontWeight = "bold", fontSize = 13 })
end

local function caption(text)
  return ui.label({ text = text, color = "on_surface_variant", fontSize = 11, maxLines = 2 })
end

local function card(children)
  return ui.column({ gap = 8, padding = 12, radius = 8, fill = "surface_container/0.35" }, children)
end

local function settingRow(label, control)
  return ui.row({ gap = 10, align = "center" }, {
    ui.label({ text = label, fontSize = 13, flexGrow = 1 }),
    control,
  })
end

-- A row of equal buttons where exactly one is the current choice.
local function segmented(options, current, onPick, enabled)
  local buttons = {}
  for _, option in ipairs(options) do
    table.insert(buttons, ui.button({
      key = tostring(option.value),
      text = option.text,
      glyph = option.glyph,
      selected = option.value == current,
      enabled = enabled ~= false,
      controlSize = option.size or "md",
      flexGrow = 1,
      onClick = function()
        if option.value ~= current then
          onPick(option.value)
        end
      end,
    }))
  end
  return ui.row({ gap = 6 }, buttons)
end

-- Sections ------------------------------------------------------------------

local function header()
  if product == nil then
    product = read("/sys/class/dmi/id/product_family") or read("/sys/class/dmi/id/product_name") or "ASUS"
  end
  local parts = {}
  if live.pluggedIn ~= nil then
    table.insert(parts, tr(live.pluggedIn and "power.plugged_in" or "power.battery"))
  end
  if live.capacity ~= nil then
    table.insert(parts, `{live.capacity}%`)
  end
  local a = snapshot.asusd
  local charge = snapshot.charge
  if live.pluggedIn and live.status == "Not charging" and charge ~= nil and charge.enabled then
    table.insert(parts, tr("power.held"))
  elseif live.status == "Charging" then
    table.insert(parts, tr("power.charging"))
  end

  return ui.row({ gap = 10, align = "center" }, {
    ui.glyph({ name = "device-laptop", size = 22, color = "primary" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = product, fontWeight = "bold", fontSize = 14, maxLines = 1 }),
      caption(table.concat(parts, " · ")),
    }),
    ui.button({
      glyph = "settings",
      variant = "ghost",
      tooltip = tr("panel.settings"),
      onClick = function()
        noctalia.openSettings()
      end,
    }),
  })
end

local function performanceSection(a)
  local options = {}
  for _, p in ipairs(model.availableProfiles(a.profileChoices)) do
    table.insert(options, { value = p.value, text = tr(p.key), glyph = p.glyph })
  end
  local children = {
    sectionTitle("section.performance"),
    segmented(options, a.profile, function(value)
      request("profile", value)
    end),
  }
  local onBattery, onAc = model.profile(a.profileOnBattery), model.profile(a.profileOnAc)
  if onBattery ~= nil and onAc ~= nil then
    table.insert(children, caption(tr("performance.defaults", { battery = tr(onBattery.key), ac = tr(onAc.key) })))
  end
  return card(children)
end

local function gpuStatusLine()
  local key, colour = nil, "on_surface_variant"
  if live.gpu == "suspended" then
    key = "gpu.asleep"
  elseif live.gpu == "active" or live.gpu == "resuming" then
    key, colour = "gpu.awake", "primary"
  elseif paths ~= nil and paths.gpu == nil then
    key = "gpu.off"
  end
  if key == nil then
    return nil
  end
  return ui.row({ gap = 8, align = "center" }, {
    ui.box({ width = 8, height = 8, radius = 4, fill = colour }),
    ui.label({ text = tr(key), fontSize = 12, color = "on_surface_variant" }),
  })
end

local function graphicsSection(s)
  local gpu = s.gpu
  local fw = s.asusd ~= nil and s.asusd.gpuFirmware or nil
  if gpu == nil and fw == nil then
    return nil
  end

  local children = { sectionTitle("section.graphics") }
  if gpu ~= nil then
    local supported = {}
    for _, v in ipairs(gpu.supported or {}) do
      supported[v] = true
    end
    local options = {}
    for _, g in ipairs(model.GPU_MODES) do
      if supported[g.value] then
        table.insert(options, { value = g.value, text = tr(g.key), glyph = g.glyph })
      end
    end
    table.insert(children, segmented(options, gpu.mode, function(value)
      request("gpuMode", value)
    end))

    local pending = model.gpuMode(gpu.pending)
    if gpu.action ~= nil and gpu.action ~= model.GPU_ACTION_NONE and pending ~= nil then
      local reboot = gpu.action == model.GPU_ACTION_REBOOT
      table.insert(children, ui.row({ gap = 8, align = "center", padding = 10, radius = 8, fill = "primary/0.12" }, {
        ui.glyph({ name = reboot and "refresh" or "logout", size = 16, color = "primary" }),
        ui.label({
          text = tr(reboot and "gpu.pending_reboot" or "gpu.pending_logout", { mode = tr(pending.key) }),
          fontSize = 12,
          flexGrow = 1,
          maxLines = 2,
        }),
        ui.button({
          text = tr(reboot and "gpu.restart" or "gpu.log_out"),
          variant = "primary",
          controlSize = "sm",
          onClick = function()
            noctalia.runAsync({ "noctalia", "msg", "panel-toggle", "session" })
          end,
        }),
        ui.button({
          text = tr("gpu.cancel"),
          variant = "ghost",
          controlSize = "sm",
          onClick = function()
            request("gpuMode", gpu.mode)
          end,
        }),
      }))
    end
  else
    -- No supergfxd: say which mode the firmware is in; switching is left to a
    -- tool that can safely unload the NVIDIA driver first.
    local key = fw.muxDiscrete and "gpu.ultimate" or (fw.dgpuDisabled and "gpu.eco" or "gpu.standard")
    table.insert(children, settingRow(tr("gpu.mode"), ui.label({ text = tr(key), fontSize = 13, fontWeight = "medium" })))
  end

  local status = gpuStatusLine()
  if status ~= nil then
    table.insert(children, status)
  end
  return card(children)
end

-- The charge limit is UPower's, shared with Noctalia's own battery controls; the
-- percentage is UPower's configured limit. The one-off full charge is asusd's.
local function batterySection(a, charge)
  if charge == nil then
    return nil
  end
  local children = {
    sectionTitle("section.battery"),
    settingRow(tr("battery.limit", { percent = charge.limit or 80 }), ui.toggle({
      checked = charge.enabled,
      onChange = function(value)
        request("chargeLimit", value == "true")
      end,
    })),
  }
  if charge.enabled and a.chargeLimit ~= nil and a.chargeLimit < 100 then
    table.insert(children, ui.button({
      text = tr("battery.full_once"),
      glyph = "battery-charging",
      variant = "outline",
      controlSize = "sm",
      onClick = function()
        request("fullCharge")
      end,
    }))
  end
  return card(children)
end

local function displaySection(a)
  if a.overdrive == nil then
    return nil
  end
  return card({
    sectionTitle("section.display"),
    settingRow(tr("display.overdrive"), ui.toggle({
      checked = a.overdrive == 1,
      onChange = function(value)
        request("overdrive", value == "true")
      end,
    })),
  })
end

local BRIGHTNESS_KEYS = { [0] = "keyboard.off", [1] = "keyboard.low", [2] = "keyboard.medium", [3] = "keyboard.high" }

local function keyboardRows(aura, prefs)
  local rows = {}

  local levels = {}
  for _, v in ipairs(aura.brightnessChoices) do
    if BRIGHTNESS_KEYS[v] ~= nil then
      table.insert(levels, { value = v, text = tr(BRIGHTNESS_KEYS[v]), size = "sm" })
    end
  end
  if #levels > 0 then
    table.insert(rows, ui.label({ text = tr("lighting.keyboard"), fontSize = 13 }))
    table.insert(rows, segmented(levels, aura.brightness, function(value)
      request("keyboardBrightness", value)
    end))
  end

  local modeNames, modeValues, selected = {}, {}, 0
  for _, v in ipairs(aura.modes) do
    if model.AURA_MODES[v] ~= nil then
      table.insert(modeNames, tr(model.AURA_MODES[v]))
      table.insert(modeValues, v)
      if v == aura.mode then
        selected = #modeValues - 1
      end
    end
  end
  if #modeValues > 1 then
    table.insert(rows, settingRow(tr("lighting.effect"), ui.select({
      options = modeNames,
      selectedIndex = selected,
      controlSize = "sm",
      width = 170,
      onChange = function(index)
        local v = modeValues[(tonumber(index) or 0) + 1]
        if v ~= nil and v ~= aura.mode then
          request("keyboardMode", v)
        end
      end,
    })))
  end

  -- Rainbows pick their own colours, so the colour controls only appear for
  -- single-colour effects.
  if aura.mode == 0 or aura.mode == 1 or aura.mode == 10 then
    table.insert(rows, settingRow(tr("lighting.follow_theme"), ui.toggle({
      checked = prefs.followTheme == true,
      onChange = function(value)
        request("followTheme", value == "true")
      end,
    })))
    if prefs.followTheme ~= true then
      local current = type(aura.data) == "table" and type(aura.data[3]) == "table"
          and model.hex(aura.data[3][1], aura.data[3][2], aura.data[3][3])
        or (prefs.colour or "#ffffff")
      table.insert(rows, ui.row({
        gap = 10,
        align = "center",
        onClick = function()
          noctalia.openColorPicker(current, function(colour)
            if colour ~= nil then
              request("keyboardColour", colour)
            end
          end)
        end,
      }, {
        ui.label({ text = tr("lighting.colour"), fontSize = 13, flexGrow = 1 }),
        ui.box({ width = 22, height = 22, radius = 11, fill = current, border = "outline_variant", borderWidth = 1 }),
      }))
    end
  end
  return rows
end

local function lightingSection(a, prefs)
  if a.aura == nil and a.slash == nil then
    return nil
  end
  local children = { sectionTitle("section.lighting") }
  if a.aura ~= nil then
    for _, row in ipairs(keyboardRows(a.aura, prefs)) do
      table.insert(children, row)
    end
  end
  if a.slash ~= nil then
    if a.aura ~= nil then
      table.insert(children, ui.separator({ spacing = 4 }))
    end
    table.insert(children, settingRow(tr("lighting.slash"), ui.toggle({
      checked = a.slash.enabled == true,
      onChange = function(value)
        request("slash", value == "true")
      end,
    })))
    if a.slash.enabled == true then
      local names, values, selected = {}, {}, 0
      for i, m in ipairs(model.SLASH_MODES) do
        table.insert(names, m.name)
        table.insert(values, m.value)
        if m.value == a.slash.mode then
          selected = i - 1
        end
      end
      table.insert(children, settingRow(tr("lighting.animation"), ui.select({
        options = names,
        selectedIndex = selected,
        controlSize = "sm",
        width = 170,
        onChange = function(index)
          local v = values[(tonumber(index) or 0) + 1]
          if v ~= nil and v ~= a.slash.mode then
            request("slashMode", v)
          end
        end,
      })))
    end
  end
  return card(children)
end

local FAN_KEYS = { cpu_fan = "sensors.cpu_fan", gpu_fan = "sensors.gpu_fan", mid_fan = "sensors.mid_fan" }

local function stat(label, value)
  return ui.column({ gap = 2, flexGrow = 1 }, {
    ui.label({ text = label, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    ui.label({ text = value, fontSize = 13, fontWeight = "medium", maxLines = 1 }),
  })
end

local function sensorsSection()
  local stats = {}
  if live.cpuTemp ~= nil then
    table.insert(stats, stat(tr("sensors.cpu"), `{live.cpuTemp} °C`))
  end
  for _, fan in ipairs(live.fans or {}) do
    local key = FAN_KEYS[fan.label]
    local value = fan.rpm ~= nil and (fan.rpm > 0 and tr("sensors.rpm", { rpm = fan.rpm }) or tr("sensors.idle")) or "—"
    table.insert(stats, stat(key ~= nil and tr(key) or fan.label, value))
  end
  if #stats == 0 then
    return nil
  end
  return card({ sectionTitle("section.sensors"), ui.row({ gap = 12 }, stats) })
end

local function unavailable()
  return card({
    ui.row({ gap = 10, align = "center" }, {
      ui.glyph({ name = "alert-triangle", size = 20, color = "error" }),
      ui.label({ text = snapshot.error or tr("error.no_asusd"), fontSize = 13, flexGrow = 1, maxLines = 3 }),
    }),
    caption(tr("error.hint")),
  })
end

-- Render ------------------------------------------------------------------------

local function render()
  if not isOpen then
    return
  end
  local children = { header() }
  local a = snapshot.asusd
  if snapshot.available ~= true or a == nil then
    table.insert(children, unavailable())
  else
    for _, section in ipairs({
      performanceSection(a),
      graphicsSection(snapshot),
      batterySection(a, snapshot.charge),
      displaySection(a),
      lightingSection(a, snapshot.prefs or {}),
      sensorsSection(),
    }) do
      if section ~= nil then
        table.insert(children, section)
      end
    end
  end
  panel.render(ui.column({ gap = 12, padding = 14 }, children))
end

local function liveSignature()
  local parts = { tostring(live.cpuTemp), tostring(live.gpu), tostring(live.pluggedIn), tostring(live.capacity), tostring(live.status) }
  for _, fan in ipairs(live.fans or {}) do
    -- Fans wander by a few rpm; round so the panel doesn't redraw for noise.
    table.insert(parts, tostring(fan.rpm ~= nil and math.round(fan.rpm / 50) or nil))
  end
  return table.concat(parts, "|")
end

function onOpen()
  isOpen = true
  sample()
  lastLiveSig = liveSignature()
  render()
end

function onClose()
  isOpen = false
end

function update()
  if not isOpen then
    return
  end
  sample()
  local sig = liveSignature()
  if sig ~= lastLiveSig then
    lastLiveSig = sig
    render()
  end
end

noctalia.state.watch(model.STATE, function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

-- Live readings tick once a second, and only while the panel is open.
panel.setWantsSecondTicks(true)
noctalia.setUpdateInterval(3600000)
snapshot = noctalia.state.get(model.STATE) or snapshot
