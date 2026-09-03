--!nonstrict

local SNAPSHOT = "battery.snapshot"
local COMMAND = "battery.command"

local snap = noctalia.state.get(SNAPSHOT) or {
  percent = 0,
  status = "Unknown",
  watt = 0,
  eta = "",
  profile = "balanced",
  threshold = 80,
  hasThreshold = false,
  hasProfile = false,
}

-- Live slider value while dragging; committed to the service on drag end.
local thresholdDraft = nil
local reqId = 0

local STATUS_KEY = {
  Charging = "status.charging",
  Discharging = "status.discharging",
  Full = "status.full",
  ["Not charging"] = "status.not_charging",
  Unknown = "status.unknown",
}

local function dispatch(action, value)
  reqId += 1
  noctalia.state.set(COMMAND, {
    action = action,
    value = value,
    requestId = tostring(os.time()) .. "-" .. tostring(reqId),
  })
end

local function batteryGlyph()
  local s = snap.status
  if s == "Charging" then
    return "battery-charging"
  elseif s == "Full" then
    return "battery-charging-2"
  end
  local p = snap.percent or 0
  if p >= 86 then
    return "battery-4"
  elseif p >= 56 then
    return "battery-3"
  elseif p >= 31 then
    return "battery-2"
  elseif p >= 11 then
    return "battery-1"
  end
  return "battery"
end

local function subLine()
  if snap.status == "Charging" and snap.eta ~= "" then
    return noctalia.tr("panel.time_to_full", { time = snap.eta })
  elseif snap.status == "Discharging" and snap.eta ~= "" then
    return noctalia.tr("panel.remaining", { time = snap.eta })
  end
  return string.format("%.1f W", snap.watt or 0)
end

local function profileButton(profile, glyph, handler)
  return ui.button({
    glyph = glyph,
    variant = (snap.profile == profile) and "primary" or "ghost",
    onClick = handler,
  })
end

local function render()
  local status = STATUS_KEY[snap.status] or "status.unknown"
  local threshold = thresholdDraft or snap.threshold or 80

  local sections = {
    ui.row({ gap = 10, align = "center", padding = 8, fill = "surface_variant/0.4", radius = 8 }, {
      ui.column({ align = "center", gap = 2 }, {
        ui.glyph({ name = batteryGlyph(), size = 22, color = "primary" }),
        ui.label({ text = (snap.percent or 0) .. "%", fontWeight = "bold" }),
      }),
      ui.separator({ orientation = "vertical" }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = noctalia.tr(status), fontWeight = "bold" }),
        ui.label({ text = subLine(), fontSize = 12, color = "on_surface_variant" }),
      }),
    }),
  }

  if snap.hasProfile then
    table.insert(sections, ui.label({
      text = noctalia.tr("panel.power_profile"),
      fontSize = 12,
      color = "on_surface_variant",
    }))
    table.insert(sections, ui.row({ gap = 8, justify = "center" }, {
      profileButton("power-saver", "leaf", "onProfilePowerSaver"),
      profileButton("balanced", "scale", "onProfileBalanced"),
      profileButton("performance", "gauge", "onProfilePerformance"),
    }))
  end

  if snap.hasThreshold then
    table.insert(sections, ui.label({
      text = noctalia.tr("panel.charge_threshold"),
      fontSize = 12,
      color = "on_surface_variant",
    }))
    table.insert(sections, ui.row({ gap = 10, align = "center" }, {
      ui.glyph({ name = "shield-heart", color = "on_surface_variant" }),
      ui.slider({
        min = 50,
        max = 100,
        step = 5,
        value = threshold,
        flexGrow = 1,
        onChange = "onThresholdChange",
        onDragEnd = "onThresholdCommit",
      }),
      ui.label({ text = threshold .. "%", fontWeight = "bold" }),
    }))
  end

  panel.render(ui.column({ gap = 6, padding = 10 }, sections))
end

function onOpen(_context)
  snap = noctalia.state.get(SNAPSHOT) or snap
  thresholdDraft = nil
  render()
end

noctalia.state.watch(SNAPSHOT, function(value)
  if type(value) == "table" then
    snap = value
    render()
  end
end)

function onProfilePowerSaver()
  dispatch("set_profile", "power-saver")
end

function onProfileBalanced()
  dispatch("set_profile", "balanced")
end

function onProfilePerformance()
  dispatch("set_profile", "performance")
end

function onThresholdChange(value)
  thresholdDraft = tonumber(value)
  render()
end

function onThresholdCommit()
  if thresholdDraft then
    dispatch("set_threshold", thresholdDraft)
    thresholdDraft = nil
  end
end
