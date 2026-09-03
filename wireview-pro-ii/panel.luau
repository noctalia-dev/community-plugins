--!nonstrict

-- Palette roles resolve live, so the panel follows every Noctalia theme and
-- mode change without needing to restart the plugin.
local SURFACE = "surface"
local TEXT = "on_surface"
local MUTED = "on_surface_variant"
local DIM = "on_surface_variant/0.72"
local LINE = "outline/0.55"
local TRACK = "surface_variant"
local ACCENT = "primary"
local DANGER = "error"

local snapshot = noctalia.state.get("wireview.snapshot")
local series = noctalia.state.get("wireview.series") or {}
local status = noctalia.state.get("wireview.status")
local configuration = noctalia.state.get("wireview.config")
local operation = noctalia.state.get("wireview.config.operation")
local screenOperation = noctalia.state.get("wireview.screen.operation")
local faultOperation = noctalia.state.get("wireview.fault.operation")
local faultObservations = noctalia.state.get("wireview.fault.observations")
local opened = false
local activeTab = "overview"
local draft = nil
local draftRevision = nil
local draftDirty = false
local confirmPermanent = false
local requestSequence = 0
local localMessage = nil
local render

local FAN_MODES = { "curve", "fixed" }
local FAN_MODE_LABELS = { "Curve", "Fixed" }
local TEMP_SOURCES = { "maximum", "input", "output", "external1", "external2" }
local TEMP_SOURCE_LABELS = { "Maximum", "Input", "Output", "External 1", "External 2" }
local AVERAGING_VALUES = { 22, 44, 89, 177, 354, 709, 1417 }
local AVERAGING_LABELS = { "22 ms", "44 ms", "89 ms", "177 ms", "354 ms", "709 ms", "1417 ms" }
local SCREEN_VALUES = { "main", "simple", "current", "temperature", "status" }
local SCREEN_LABELS = { "Main", "Simple", "Current", "Temperature", "Status" }
local CURRENT_SCREEN_VALUES = { "", "main", "simple", "current", "temperature", "status" }
local CURRENT_SCREEN_LABELS = { "Choose screen", "Main", "Simple", "Current", "Temperature", "Status" }
local FAULT_BITS = {
  chip_over_temperature = 1,
  sensor_over_temperature = 2,
  over_current = 4,
  wire_over_current = 8,
  over_power = 16,
  current_imbalance = 32,
}
local FAULT_CLEAR_HANDLERS = {
  chip_over_temperature = "onClearChipTemperatureClicked",
  sensor_over_temperature = "onClearSensorTemperatureClicked",
  over_current = "onClearTotalCurrentClicked",
  wire_over_current = "onClearWireAlarmClicked",
  over_power = "onClearPowerClicked",
  current_imbalance = "onClearImbalanceClicked",
}

-- These identifiers are decoded by wireviewd from the six documented device
-- fault bits. Keep register codes out of the normal UI: people need the
-- condition, current reading, limit, and next action.
local FAULT_INFO = {
  chip_over_temperature = {
    category = "INTERNAL TEMPERATURE",
    title = "Monitoring chip is too hot",
    action = "Reduce load and check WireView airflow and fan operation.",
  },
  sensor_over_temperature = {
    category = "OVER TEMPERATURE",
    title = "Connector temperature is too high",
    action = "Reduce load. Reseat and inspect the connector and cable for heat or discoloration.",
  },
  over_current = {
    category = "OVER CURRENT",
    title = "Total current is too high",
    action = "Reduce GPU load or verify the configured total-current limit.",
  },
  wire_over_current = {
    category = "WIRE OVER CURRENT",
    title = "A conductor is carrying too much current",
    action = "Inspect and reseat the connector and cable; check for uneven contact.",
  },
  over_power = {
    category = "OVER POWER",
    title = "Total power is too high",
    action = "Reduce GPU load or verify the configured total-power limit.",
  },
  current_imbalance = {
    category = "CURRENT IMBALANCE",
    title = "Current is uneven across conductors",
    action = "Reseat the connector. Check the cable for heat, discoloration, or poor contact.",
  },
}

local function copyValue(value)
  if type(value) ~= "table" then
    return value
  end
  local copied = {}
  for key, child in pairs(value) do
    copied[key] = copyValue(child)
  end
  return copied
end

local function number(value, fallback)
  local parsed = tonumber(value)
  return parsed ~= nil and parsed or fallback
end

local function hasActiveFaults()
  return type(snapshot) == "table" and number(snapshot.active_fault_mask, 0) ~= 0
end

local function knownFaultCount(faults, unknownMask)
  local count = type(faults) == "table" and #faults or 0
  return count + (number(unknownMask, 0) ~= 0 and 1 or 0)
end

local function format(value, decimals)
  local parsed = tonumber(value)
  if parsed == nil then
    return "—"
  end
  return string.format("%." .. tostring(decimals) .. "f", parsed)
end

local function relativeTime(timestamp)
  local seconds = math.max(0, os.time() - math.floor(number(timestamp, os.time())))
  if seconds < 5 then
    return "just now"
  end
  if seconds < 60 then
    return tostring(seconds) .. "s ago"
  end
  if seconds < 3600 then
    return tostring(math.floor(seconds / 60)) .. "m ago"
  end
  if seconds < 86400 then
    return tostring(math.floor(seconds / 3600)) .. "h ago"
  end
  return tostring(math.floor(seconds / 86400)) .. "d ago"
end

local function sampleObservedAt()
  if type(snapshot) ~= "table" then
    return nil
  end
  local milliseconds = tonumber(snapshot.observed_at_ms)
  return milliseconds ~= nil and math.floor(milliseconds / 1000) or nil
end

local function indexOf(values, selected)
  for index, value in ipairs(values) do
    if value == selected then
      return index - 1
    end
  end
  return 0
end

local function valueAt(values, index)
  return values[math.floor(number(index, 0)) + 1]
end

local function currentSettings()
  return type(configuration) == "table" and type(configuration.settings) == "table"
    and configuration.settings or nil
end

local function faultThresholds()
  local settings = currentSettings()
  return settings and type(settings.fault_thresholds) == "table" and settings.fault_thresholds or {}
end

local function faultIsActive(name)
  if snapshot == nil or type(snapshot.active_faults) ~= "table" then
    return false
  end
  for _, fault in ipairs(snapshot.active_faults) do
    if fault == name then
      return true
    end
  end
  return false
end

local function faultIsLogged(name)
  if snapshot == nil or type(snapshot.logged_faults) ~= "table" then
    return false
  end
  for _, fault in ipairs(snapshot.logged_faults) do
    if fault == name then
      return true
    end
  end
  return false
end

local function faultClearPending()
  return type(faultOperation) == "table" and faultOperation.status == "running"
end

local function screenChangePending()
  return type(screenOperation) == "table" and screenOperation.status == "running"
end

local function currentScreen()
  if type(screenOperation) ~= "table" then
    return nil
  end
  for _, screen in ipairs(SCREEN_VALUES) do
    if screenOperation.screen == screen then
      return screen
    end
  end
  return nil
end

local function screenLabel(screen)
  local index = indexOf(SCREEN_VALUES, screen)
  return screen ~= nil and SCREEN_LABELS[index + 1] or nil
end

local function recentScreenOperation()
  if type(screenOperation) ~= "table" or screenOperation.message == nil then
    return nil
  end
  local age = os.time() - math.floor(number(screenOperation.updated_at, os.time()))
  if screenOperation.status == "running" or age <= 8 then
    return screenOperation
  end
  return nil
end

local function faultOperationFor(name)
  if type(faultOperation) ~= "table" or faultOperation.fault ~= name then
    return nil
  end
  local age = os.time() - math.floor(number(faultOperation.updated_at, os.time()))
  if faultOperation.status == "running" or age <= 12 then
    return faultOperation
  end
  return nil
end

local function faultObservedAt(name, active)
  if type(faultObservations) ~= "table" then
    return nil
  end
  local observations = active and faultObservations.active or faultObservations.logged
  return type(observations) == "table" and tonumber(observations[name]) or nil
end

local function requestFaultClear(name)
  local bit = FAULT_BITS[name]
  if bit == nil or (not faultIsActive(name) and not faultIsLogged(name)) then
    return
  end
  requestSequence = requestSequence + 1
  noctalia.state.set("wireview.fault.request", {
    id = "clear:" .. tostring(os.time()) .. ":" .. tostring(requestSequence),
    action = "clear",
    fault = name,
    active_mask = faultIsActive(name) and bit or 0,
    logged_mask = faultIsLogged(name) and bit or 0,
    confirm = true,
  })
end

local function exceedsThreshold(value, key)
  local limit = number(faultThresholds()[key], nil)
  return limit ~= nil and number(value, 0) > limit
end

local function temperatureIsHigh(value)
  return exceedsThreshold(value, "temperature_c")
end

local function totalCurrentIsHigh()
  return exceedsThreshold(snapshot and snapshot.total_current_a, "total_current_a")
    or faultIsActive("over_current")
end

local function totalPowerIsHigh()
  return exceedsThreshold(snapshot and snapshot.total_power_w, "total_power_w")
    or faultIsActive("over_power")
end

local function syncDraft(force)
  local settings = currentSettings()
  if settings == nil then
    return
  end
  local revision = configuration.revision
  if force or draft == nil or (not draftDirty and revision ~= draftRevision) then
    draft = copyValue(settings)
    draft.daemon = copyValue(configuration.daemon or {})
    draftRevision = revision
    draftDirty = false
    confirmPermanent = false
  end
end

local function markDraftChanged()
  draftDirty = true
  confirmPermanent = false
  localMessage = nil
  render()
end

local function tabButton(id, label)
  local selected = activeTab == id
  local faultAttention = id == "faults" and hasActiveFaults()
  return ui.column({
    flexGrow = 1,
    gap = 7,
    paddingH = 8,
    paddingV = 8,
    align = "stretch",
    onClick = function()
      activeTab = id
      render()
    end,
  }, {
    ui.label({
      text = faultAttention and label .. " (" .. tostring(knownFaultCount(
        snapshot.active_faults,
        snapshot.unknown_active_fault_mask
      )) .. ")" or label,
      color = faultAttention and DANGER or (selected and TEXT or MUTED),
      fontWeight = (selected or faultAttention) and "bold" or "normal",
      fontSize = 11,
      textAlign = "center",
    }),
    ui.box({ height = 2, fill = selected and (faultAttention and DANGER or ACCENT) or "surface/0" }),
  })
end

local function statusState()
  return type(status) == "table" and tostring(status.state or "offline") or "offline"
end

local function telemetryIsLive()
  return type(snapshot) == "table" and snapshot.stale ~= true and statusState() == "ready"
end

local function stackedFaultLayout()
  return noctalia.getConfig("faults_layout") == "stacked"
end

local function statusColor()
  if hasActiveFaults() then
    return DANGER
  end
  local state = statusState()
  if state == "ready" then
    return ACCENT
  end
  if state == "error" or state == "incompatible" then
    return DANGER
  end
  return DIM
end

local function header()
  local state = statusState()
  local live = telemetryIsLive()
  local activeCount = hasActiveFaults() and knownFaultCount(
    snapshot.active_faults,
    snapshot.unknown_active_fault_mask
  ) or 0
  local statusText = not live and (state == "ready" and "STALE" or string.upper(state))
    or (activeCount > 0 and "FAULT"
    or (state == "ready" and "LIVE"
    or (state == "connecting" and "CONNECTING" or string.upper(state))
    ))
  local observedAt = sampleObservedAt()
  local statusMessage = not live and (type(snapshot) == "table"
      and "Values frozen; last sample " .. relativeTime(observedAt)
      or (status and tostring(status.message or "") or "Waiting for wireviewd"))
    or (activeCount > 0
    and tostring(activeCount) .. (activeCount == 1 and " active fault" or " active faults")
    or (observedAt ~= nil and "Updated " .. relativeTime(observedAt) or "Live device telemetry"))
  return ui.column({ gap = 0 }, {
    ui.row({ paddingH = 18, paddingV = 12, align = "center", gap = 12 }, {
      ui.glyph({ name = "bolt", size = 20, color = ACCENT }),
      ui.column({ flexGrow = 1, gap = 2 }, {
        ui.row({ gap = 6, align = "center" }, {
          ui.label({ text = "WireView", color = TEXT, fontSize = 16, fontWeight = "bold" }),
          ui.label({ text = "PRO II", color = ACCENT, fontSize = 10, fontWeight = "bold" }),
        }),
        ui.row({ gap = 6, align = "center" }, {
          ui.box({ width = 6, height = 6, radius = 3, fill = statusColor() }),
          ui.label({ text = statusText, color = statusColor(), fontSize = 10, fontWeight = "bold" }),
          ui.label({
            text = statusMessage,
            color = MUTED,
            fontSize = 10,
            maxLines = 1,
          }),
        }),
      }),
      ui.column({ gap = 1, align = "end" }, {
        ui.label({
          text = live and "LIVE POWER" or "LAST POWER",
          color = totalPowerIsHigh() and DANGER or DIM,
          fontSize = 9,
          fontWeight = "bold",
        }),
        ui.row({ gap = 5, align = "end" }, {
          ui.label({
            text = format(snapshot and snapshot.total_power_w, 1),
            color = totalPowerIsHigh() and DANGER or TEXT,
            fontSize = 25,
            fontWeight = "heavy",
            fontFamily = "monospace",
          }),
          ui.label({ text = "W", color = totalPowerIsHigh() and DANGER or ACCENT, fontSize = 10, fontWeight = "bold" }),
        }),
      }),
      ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", onClick = "onCloseClicked" }),
    }),
    ui.separator({ color = LINE, thickness = 1 }),
    ui.row({ paddingH = 10, gap = 0, align = "stretch" }, {
      tabButton("overview", "OVERVIEW"),
      tabButton("pins", "PINS"),
      tabButton("faults", "FAULTS"),
      tabButton("configure", "CONFIGURE"),
    }),
    ui.separator({ color = LINE, thickness = 1 }),
  })
end

local function emptyState(title, detail)
  return ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 8 }, {
    ui.glyph({ name = "plug-off", size = 30, color = DIM }),
    ui.label({ text = title, color = TEXT, fontSize = 15, fontWeight = "bold", textAlign = "center" }),
    ui.label({ text = detail, color = MUTED, fontSize = 11, textAlign = "center", maxLines = 3 }),
  })
end

local function telemetryBanner()
  if type(snapshot) ~= "table" or telemetryIsLive() then
    return nil
  end
  local state = statusState()
  local title = state == "stale" and "TELEMETRY PAUSED" or "TELEMETRY UNAVAILABLE"
  local detail = state == "stale"
    and "No fresh sample has arrived. Values below are frozen at " .. os.date("%H:%M:%S", sampleObservedAt()) .. "."
    or "Showing the last received sample. Reconnect the device service to resume live monitoring."
  return ui.row({ paddingH = 18, paddingV = 8, gap = 9, align = "center" }, {
    ui.glyph({ name = "cloud-off", size = 15, color = DANGER }),
    ui.label({ text = title, color = DANGER, fontSize = 9, fontWeight = "bold" }),
    ui.label({ text = detail, color = MUTED, fontSize = 10, flexGrow = 1, maxLines = 1 }),
  })
end

local function pinValues(index)
  if type(snapshot) ~= "table" then
    return 0, 0, 0
  end
  local power = type(snapshot.pin_power_w) == "table" and number(snapshot.pin_power_w[index], 0) or 0
  local current = type(snapshot.pin_currents_a) == "table" and number(snapshot.pin_currents_a[index], 0) or 0
  local voltage = type(snapshot.pin_voltages_v) == "table" and number(snapshot.pin_voltages_v[index], 0) or 0
  return power, current, voltage
end

local function pinRow(index, expanded)
  local power, current, voltage = pinValues(index)
  local currentHigh = exceedsThreshold(current, "wire_current_a")
  local pinColor = currentHigh and DANGER or ACCENT
  local maxPinPower = math.max(number(snapshot and snapshot.cable_capability_w, 600) / 6, 1)
  local progress = math.max(0, math.min(1, power / maxPinPower))
  local pinAction = currentHigh and faultIsActive("wire_over_current")
    and ui.button({
      glyph = "x",
      tooltip = "Clear this conductor alarm on the device",
      variant = "ghost",
      height = 24,
      enabled = not faultClearPending(),
      onClick = "onClearWireAlarmClicked",
    })
    or ui.label({
      text = string.format("%.1f%%", progress * 100),
      color = pinColor,
      fontSize = 9,
      fontWeight = "bold",
    })

  if not expanded then
    return ui.row({ flexGrow = 1, gap = 9, paddingV = 8, align = "center" }, {
      ui.label({
        text = "P" .. tostring(index) .. (currentHigh and "!" or ""),
        color = pinColor,
        fontSize = 10,
        fontWeight = "bold",
        width = 22,
      }),
      ui.progress({
        progress = progress,
        flexGrow = 1,
        height = 3,
        radius = 1,
        fill = pinColor,
        track = TRACK,
      }),
      ui.label({
        text = format(current, 2) .. " A",
        color = currentHigh and DANGER or MUTED,
        fontSize = 10,
        fontFamily = "monospace",
        width = 64,
        textAlign = "end",
      }),
    })
  end

  return ui.column({ height = 96, gap = 7, paddingV = 10, align = "stretch" }, {
    ui.row({ align = "end", gap = 7 }, {
      ui.label({ text = "P" .. tostring(index), color = pinColor, fontSize = 11, fontWeight = "bold", width = 24 }),
      currentHigh and ui.label({
        text = "ABOVE LIMIT",
        color = DANGER,
        fontSize = 9,
        fontWeight = "bold",
      }) or ui.spacer({ width = 0 }),
      ui.label({
        text = format(power, 2),
        color = currentHigh and DANGER or TEXT,
        fontSize = 21,
        fontWeight = "heavy",
        fontFamily = "monospace",
      }),
      ui.label({ text = "W", color = MUTED, fontSize = 9 }),
      ui.spacer({ flexGrow = 1 }),
      pinAction,
    }),
    ui.progress({
      progress = progress,
      height = 3,
      radius = 1,
      fill = pinColor,
      track = TRACK,
    }),
    ui.row({ justify = "space_between", align = "center" }, {
      ui.label({
        text = format(current, 2) .. " A",
        color = currentHigh and DANGER or MUTED,
        fontSize = 10,
        fontWeight = currentHigh and "bold" or "normal",
        fontFamily = "monospace",
      }),
      ui.label({ text = format(voltage, 2) .. " V", color = MUTED, fontSize = 10, fontFamily = "monospace" }),
    }),
  })
end

local function metric(label, value, unit, accent)
  local valueColor = type(accent) == "string" and accent or (accent and ACCENT or TEXT)
  local supportingColor = valueColor == DANGER and DANGER or MUTED
  return ui.column({ gap = 3, flexGrow = 1 }, {
    ui.label({ text = label, color = valueColor == DANGER and DANGER or DIM, fontSize = 9, fontWeight = "bold" }),
    ui.row({ gap = 4, align = "end" }, {
      ui.label({
        text = value,
        color = valueColor,
        fontSize = 17,
        fontWeight = "heavy",
        fontFamily = "monospace",
      }),
      ui.label({ text = unit, color = supportingColor, fontSize = 9 }),
    }),
  })
end

local function metricStrip()
  return ui.row({ height = 72, paddingV = 10, gap = 12, align = "stretch" }, {
    metric("VOLTAGE", format(snapshot.avg_voltage_v, 2), "V"),
    ui.separator({ orientation = "vertical", color = LINE, thickness = 1 }),
    metric("CURRENT", format(snapshot.total_current_a, 2), "A", totalCurrentIsHigh() and DANGER or false),
    ui.separator({ orientation = "vertical", color = LINE, thickness = 1 }),
    metric(
      "INPUT TEMP",
      format(snapshot.input_temp_c, 1),
      "°C",
      temperatureIsHigh(snapshot.input_temp_c) and DANGER or false
    ),
    ui.separator({ orientation = "vertical", color = LINE, thickness = 1 }),
    metric(
      "OUTPUT TEMP",
      format(snapshot.output_temp_c, 1),
      "°C",
      temperatureIsHigh(snapshot.output_temp_c) and DANGER or false
    ),
    ui.separator({ orientation = "vertical", color = LINE, thickness = 1 }),
    metric("FAN", format(snapshot.fan_duty_percent, 0), "%"),
    ui.separator({ orientation = "vertical", color = LINE, thickness = 1 }),
    metric("CABLE", tostring(math.floor(number(snapshot.cable_capability_w, 0))), "W", true),
  })
end

local function overview()
  if type(snapshot) ~= "table" then
    return emptyState("Waiting for WireView Pro II", status and status.message or "Connect wireviewd to begin.")
  end
  local powerValues = type(series.power) == "table" and series.power or {}
  local pinRows = {}
  for index = 1, 6 do
    table.insert(pinRows, pinRow(index, false))
    if index < 6 then
      table.insert(pinRows, ui.separator({ color = LINE, thickness = 1 }))
    end
  end

  local loadPercent = number(snapshot.total_power_w, 0)
    / math.max(number(snapshot.cable_capability_w, 1), 1) * 100

  return ui.column({ flexGrow = 1, padding = 18, gap = 14, align = "stretch" }, {
    ui.row({ flexGrow = 1, gap = 20, align = "stretch" }, {
      ui.column({ width = 190, gap = 0 }, pinRows),
      ui.column({ flexGrow = 1, gap = 10 }, {
        ui.row({ align = "end" }, {
          ui.column({ gap = 2, flexGrow = 1 }, {
            ui.label({ text = "POWER / 2 MINUTES", color = DIM, fontSize = 9, fontWeight = "bold" }),
            ui.label({
              text = string.format("%.1f%% LOAD", loadPercent),
              color = totalPowerIsHigh() and DANGER or TEXT,
              fontSize = 17,
              fontWeight = "bold",
              fontFamily = "monospace",
            }),
          }),
          ui.column({ gap = 2, align = "end" }, {
            ui.label({ text = "CABLE LIMIT", color = DIM, fontSize = 9, fontWeight = "bold" }),
            ui.label({
              text = tostring(math.floor(number(snapshot.cable_capability_w, 0))) .. " W",
              color = ACCENT,
              fontSize = 11,
              fontWeight = "bold",
              fontFamily = "monospace",
            }),
          }),
        }),
        ui.graph({
          values = powerValues,
          color = totalPowerIsHigh() and DANGER or ACCENT,
          lineWidth = 2,
          fillOpacity = 0.12,
          flexGrow = 1,
        }),
        ui.row({ align = "center" }, {
          ui.label({ text = "-2:00", color = DIM, fontSize = 9, fontFamily = "monospace" }),
          ui.spacer({ flexGrow = 1 }),
          ui.label({ text = "-1:00", color = DIM, fontSize = 9, fontFamily = "monospace" }),
          ui.spacer({ flexGrow = 1 }),
          ui.label({ text = "NOW", color = ACCENT, fontSize = 9, fontWeight = "bold" }),
        }),
      }),
    }),
    ui.separator({ color = LINE, thickness = 1 }),
    metricStrip(),
  })
end

local function pinsView()
  if type(snapshot) ~= "table" then
    return emptyState("No pin telemetry", "Waiting for a complete six-conductor sample.")
  end
  local left = {}
  local right = {}
  for index = 1, 3 do
    table.insert(left, pinRow(index, true))
    if index < 3 then
      table.insert(left, ui.separator({ color = LINE, thickness = 1 }))
    end
  end
  for index = 4, 6 do
    table.insert(right, pinRow(index, true))
    if index < 6 then
      table.insert(right, ui.separator({ color = LINE, thickness = 1 }))
    end
  end
  return ui.scroll({ flexGrow = 1, padding = 18, gap = 14, align = "stretch" }, {
    ui.row({ align = "end" }, {
      ui.label({ text = "SIX-CONDUCTOR BALANCE", color = TEXT, fontSize = 15, fontWeight = "bold" }),
      ui.spacer({ flexGrow = 1 }),
      ui.label({
        text = format(snapshot.avg_voltage_v, 2) .. " V BUS",
        color = ACCENT,
        fontSize = 10,
        fontWeight = "bold",
      }),
    }),
    ui.separator({ color = LINE, thickness = 1 }),
    ui.row({ height = 292, gap = 28, align = "stretch" }, {
      ui.column({ flexGrow = 1, gap = 0, align = "stretch" }, left),
      ui.separator({ orientation = "vertical", color = LINE, thickness = 1 }),
      ui.column({ flexGrow = 1, gap = 0, align = "stretch" }, right),
    }),
    ui.separator({ color = LINE, thickness = 1 }),
    ui.row({ height = 72, gap = 20, align = "stretch" }, {
      metric("CONTROLLER VDD", format(snapshot.vdd_v, 2), "V"),
      ui.separator({ orientation = "vertical", color = LINE, thickness = 1 }),
      metric(
        "EXTERNAL 1",
        snapshot.external_1_present == true and format(snapshot.external_1_temp_c, 1) or "—",
        snapshot.external_1_present == true and "°C" or "NOT FITTED",
        snapshot.external_1_present == true and temperatureIsHigh(snapshot.external_1_temp_c) and DANGER or false
      ),
      ui.separator({ orientation = "vertical", color = LINE, thickness = 1 }),
      metric(
        "EXTERNAL 2",
        snapshot.external_2_present == true and format(snapshot.external_2_temp_c, 1) or "—",
        snapshot.external_2_present == true and "°C" or "NOT FITTED",
        snapshot.external_2_present == true and temperatureIsHigh(snapshot.external_2_temp_c) and DANGER or false
      ),
      ui.separator({ orientation = "vertical", color = LINE, thickness = 1 }),
      metric("CAPABILITY", tostring(math.floor(number(snapshot.cable_capability_w, 0))), "W", true),
    }),
  })
end

local function hottestTemperature()
  local candidates = {
    { "Input", number(snapshot and snapshot.input_temp_c, 0) },
    { "Output", number(snapshot and snapshot.output_temp_c, 0) },
  }
  if snapshot and snapshot.external_1_present == true then
    table.insert(candidates, { "External 1", number(snapshot.external_1_temp_c, 0) })
  end
  if snapshot and snapshot.external_2_present == true then
    table.insert(candidates, { "External 2", number(snapshot.external_2_temp_c, 0) })
  end
  local hottest = candidates[1]
  for _, candidate in ipairs(candidates) do
    if candidate[2] > hottest[2] then
      hottest = candidate
    end
  end
  return hottest[1], hottest[2]
end

local function pinCurrentExtremes()
  local currents = snapshot and snapshot.pin_currents_a
  if type(currents) ~= "table" or #currents == 0 then
    return 1, 0, 1, 0
  end
  local highIndex, highValue, lowIndex, lowValue = 1, number(currents[1], 0), 1, number(currents[1], 0)
  for index, rawValue in ipairs(currents) do
    local value = number(rawValue, 0)
    if value > highValue then
      highIndex, highValue = index, value
    end
    if value < lowValue then
      lowIndex, lowValue = index, value
    end
  end
  return highIndex, highValue, lowIndex, lowValue
end

local function faultContext(fault)
  local limits = faultThresholds()
  if fault == "chip_over_temperature" then
    return "The device's internal safety temperature was exceeded."
  end
  if fault == "sensor_over_temperature" then
    local source, temperature = hottestTemperature()
    return source .. " " .. format(temperature, 1) .. " °C now / "
      .. format(limits.temperature_c, 1) .. " °C limit"
  end
  if fault == "over_current" then
    return format(snapshot and snapshot.total_current_a, 2) .. " A now / "
      .. format(limits.total_current_a, 0) .. " A limit"
  end
  if fault == "wire_over_current" then
    local pin, current = pinCurrentExtremes()
    return "P" .. tostring(pin) .. " " .. format(current, 2) .. " A now / "
      .. format(limits.wire_current_a, 1) .. " A per-wire limit"
  end
  if fault == "over_power" then
    return format(snapshot and snapshot.total_power_w, 1) .. " W now / "
      .. format(limits.total_power_w, 0) .. " W limit"
  end
  if fault == "current_imbalance" then
    local highPin, highValue, lowPin, lowValue = pinCurrentExtremes()
    return "P" .. tostring(highPin) .. " " .. format(highValue, 2) .. " A high, P"
      .. tostring(lowPin) .. " " .. format(lowValue, 2) .. " A low / "
      .. format(limits.current_imbalance_percent, 0) .. "% limit above "
      .. format(limits.current_imbalance_min_load_a, 0) .. " A total"
  end
  return "The device reported a fault that this plugin does not yet recognize."
end

local function faultItem(fault, active)
  local info = FAULT_INFO[fault]
  if info == nil then
    return nil
  end
  local clearHandler = FAULT_CLEAR_HANDLERS[fault]
  local operationForFault = faultOperationFor(fault)
  local pending = operationForFault ~= nil and operationForFault.status == "running"
  local alarmColor = active and DANGER or MUTED
  local titleColor = active and DANGER or TEXT
  local actions = {
    ui.label({
      text = active and "ACTIVE NOW" or "RECORDED",
      color = alarmColor,
      fontSize = 9,
      fontWeight = "bold",
    }),
  }
  if clearHandler ~= nil then
    table.insert(actions, ui.button({
      glyph = pending and "hourglass" or "x",
      tooltip = not telemetryIsLive() and "Reconnect live telemetry before clearing this alarm"
        or (active and "Clear this active alarm on the device"
        or "Clear this recorded alarm on the device"),
      variant = "ghost",
      height = 24,
      enabled = telemetryIsLive() and not faultClearPending(),
      onClick = clearHandler,
    }))
  end
  local details = {
    ui.row({ height = 24, align = "center" }, {
      ui.label({ text = info.category, color = alarmColor, fontSize = 9, fontWeight = "bold" }),
      ui.spacer({ flexGrow = 1 }),
      ui.row({ gap = 10, align = "center" }, actions),
    }),
    ui.label({ text = info.title, color = titleColor, fontSize = 13, fontWeight = "bold", maxLines = 1 }),
    ui.label({ text = faultContext(fault), color = active and TEXT or MUTED, fontSize = 10, maxLines = 1 }),
    ui.label({ text = info.action, color = active and MUTED or DIM, fontSize = 10, maxLines = 2 }),
  }
  local observedAt = faultObservedAt(fault, active)
  if observedAt ~= nil then
    table.insert(details, ui.label({
      text = active and "Observed " .. relativeTime(observedAt) .. " this session"
        or "History first observed " .. relativeTime(observedAt) .. " this session",
      color = DIM,
      fontSize = 9,
      maxLines = 1,
    }))
  end
  if operationForFault ~= nil then
    local feedback = operationForFault.status == "running" and "CLEARING ON DEVICE"
      or (operationForFault.status == "success" and "CLEARED ON DEVICE"
      or (operationForFault.status == "warning" and "CONDITION STILL PRESENT" or "CLEAR FAILED"))
    table.insert(details, ui.label({
      text = feedback .. " · " .. tostring(operationForFault.message or ""),
      color = (operationForFault.status == "error" or operationForFault.status == "warning") and DANGER or ACCENT,
      fontSize = 9,
      fontWeight = "bold",
      maxLines = 2,
    }))
  end
  local itemHeight = operationForFault ~= nil and 150 or (observedAt ~= nil and 128 or 110)
  return ui.row({ height = itemHeight, gap = 10, paddingV = 8, align = "stretch" }, {
    ui.box({ width = 3, fill = alarmColor }),
    ui.column({ flexGrow = 1, gap = 3, align = "stretch" }, details),
  })
end

local function faultList(title, faults, unknownMask, active, naturalHeight)
  local count = knownFaultCount(faults, unknownMask)
  local children = {
    ui.row({ align = "center" }, {
      ui.label({ text = title, color = TEXT, fontSize = 13, fontWeight = "bold" }),
      ui.spacer({ flexGrow = 1 }),
      ui.label({
        text = count == 0 and "CLEAR" or tostring(count) .. (count == 1 and " FAULT" or " FAULTS"),
        color = count > 0 and (active and DANGER or MUTED) or ACCENT,
        fontSize = 10,
        fontWeight = "bold",
      }),
    }),
    ui.separator({ color = LINE, thickness = 1 }),
  }
  if count == 0 then
    table.insert(children, ui.column({
      height = stackedFaultLayout() and 110 or 248,
      gap = 8,
      align = "center",
      justify = "center",
    }, {
      ui.glyph({ name = "circle-check", size = 24, color = ACCENT }),
      ui.label({
        text = active and "No active faults" or "No recorded faults",
        color = TEXT,
        fontSize = 12,
        fontWeight = "bold",
        textAlign = "center",
      }),
      ui.label({
        text = active and "All monitored limits are within range."
          or "No fault events are stored on the device.",
        color = MUTED,
        fontSize = 10,
        textAlign = "center",
      }),
    }))
  else
    for _, fault in ipairs(faults) do
      local item = faultItem(tostring(fault), active)
      if item ~= nil then
        table.insert(children, item)
      end
    end
  end
  if number(unknownMask, 0) ~= 0 then
    local unknownColor = active and DANGER or MUTED
    table.insert(children, ui.row({ gap = 10, paddingV = 8, align = "stretch" }, {
      ui.box({ width = 3, fill = unknownColor }),
      ui.column({ flexGrow = 1, gap = 3 }, {
        ui.label({ text = "UNRECOGNIZED DEVICE FAULT", color = unknownColor, fontSize = 9, fontWeight = "bold" }),
        ui.label({ text = "Unknown firmware fault", color = active and DANGER or TEXT, fontSize = 13, fontWeight = "bold" }),
        ui.label({
          text = string.format("Diagnostic code 0x%04X", math.floor(number(unknownMask, 0))),
          color = TEXT,
          fontSize = 10,
          fontFamily = "monospace",
        }),
        ui.label({ text = "Update wireviewd and this plugin before diagnosing it.", color = MUTED, fontSize = 10 }),
      }),
    }))
  end
  local props = { gap = 8, align = "stretch" }
  if not naturalHeight then
    props.flexGrow = 1
  end
  return ui.column(props, children)
end

local function faultPane(title, faults, unknownMask, active)
  if knownFaultCount(faults, unknownMask) > 2 then
    return ui.scroll({ flexGrow = 1 }, {
      faultList(title, faults, unknownMask, active),
    })
  end
  return faultList(title, faults, unknownMask, active)
end

local function faultsView()
  if type(snapshot) ~= "table" then
    return emptyState("No fault status", "Waiting for wireviewd telemetry.")
  end
  local activeCount = knownFaultCount(snapshot.active_faults, snapshot.unknown_active_fault_mask)
  local loggedCount = knownFaultCount(snapshot.logged_faults, snapshot.unknown_logged_fault_mask)
  local statusLabel = activeCount > 0
    and tostring(activeCount) .. (activeCount == 1 and " ACTIVE FAULT" or " ACTIVE FAULTS")
    or (loggedCount > 0 and "NO ACTIVE FAULTS / " .. tostring(loggedCount) .. " RECORDED" or "SYSTEM NOMINAL")
  local operationVisible = type(faultOperation) == "table"
    and faultOperation.message ~= nil
    and faultOperationFor(faultOperation.fault) ~= nil
  local operationSummary = type(faultOperation) == "table" and (
    faultOperation.status == "running" and "CLEARING DEVICE ALARM"
    or (faultOperation.status == "success" and "ALARM CLEARED"
    or (faultOperation.status == "warning" and "ALARM STILL PRESENT" or "CLEAR FAILED"))
  ) or nil
  local visibleStatus = operationVisible and operationSummary or statusLabel
  local visibleStatusColor = operationVisible
    and ((faultOperation.status == "error" or faultOperation.status == "warning") and DANGER or ACCENT)
    or (activeCount > 0 and DANGER or ACCENT)
  local limits = faultThresholds()
  local _, hottest = hottestTemperature()
  local _, maxWire = pinCurrentExtremes()
  local faultSection
  if stackedFaultLayout() then
    faultSection = ui.column({ gap = 18, align = "stretch" }, {
      faultList("ACTIVE NOW", snapshot.active_faults, snapshot.unknown_active_fault_mask, true, true),
      ui.separator({ color = LINE, thickness = 1 }),
      faultList("RECORDED HISTORY", snapshot.logged_faults, snapshot.unknown_logged_fault_mask, false, true),
    })
  else
    faultSection = ui.row({ height = 312, gap = 28, align = "stretch" }, {
      faultPane("ACTIVE NOW", snapshot.active_faults, snapshot.unknown_active_fault_mask, true),
      ui.separator({ orientation = "vertical", color = LINE, thickness = 1 }),
      faultPane("RECORDED HISTORY", snapshot.logged_faults, snapshot.unknown_logged_fault_mask, false),
    })
  end
  local children = {
    ui.row({ align = "end" }, {
      ui.label({ text = "FAULT STATUS", color = TEXT, fontSize = 15, fontWeight = "bold" }),
      ui.spacer({ flexGrow = 1 }),
      ui.label({
        text = visibleStatus,
        color = visibleStatusColor,
        fontSize = 10,
        fontWeight = "bold",
        maxLines = 1,
      }),
    }),
    ui.separator({ color = LINE, thickness = 1 }),
    faultSection,
    ui.separator({ color = LINE, thickness = 1 }),
    ui.row({ height = 72, gap = 20, align = "stretch" }, {
      metric(
        "TEMPERATURE",
        format(hottest, 1) .. " / " .. format(limits.temperature_c, 1),
        "°C",
        (temperatureIsHigh(hottest)
          or faultIsActive("chip_over_temperature")
          or faultIsActive("sensor_over_temperature")) and DANGER or false
      ),
      ui.separator({ orientation = "vertical", color = LINE, thickness = 1 }),
      metric(
        "TOTAL CURRENT",
        format(snapshot.total_current_a, 2) .. " / " .. format(limits.total_current_a, 0),
        "A",
        totalCurrentIsHigh() and DANGER or false
      ),
      ui.separator({ orientation = "vertical", color = LINE, thickness = 1 }),
      metric(
        "MAX WIRE",
        format(maxWire, 2) .. " / " .. format(limits.wire_current_a, 1),
        "A",
        (exceedsThreshold(maxWire, "wire_current_a")
          or faultIsActive("wire_over_current")
          or faultIsActive("current_imbalance")) and DANGER or false
      ),
      ui.separator({ orientation = "vertical", color = LINE, thickness = 1 }),
      metric(
        "POWER",
        format(snapshot.total_power_w, 1) .. " / " .. format(limits.total_power_w, 0),
        "W",
        totalPowerIsHigh() and DANGER or false
      ),
    }),
  }
  return ui.scroll({ flexGrow = 1, padding = 18, gap = 14, align = "stretch" }, children)
end

local function settingBlock(label, value, control)
  return ui.column({ gap = 6, paddingV = 5, align = "stretch" }, {
    ui.row({ align = "center" }, {
      ui.label({ text = label, color = TEXT, fontSize = 11, fontWeight = "bold" }),
      ui.spacer({ flexGrow = 1 }),
      ui.label({ text = value, color = ACCENT, fontSize = 10, fontFamily = "monospace" }),
    }),
    control,
  })
end

local function buildChanges(persist)
  local settings = currentSettings()
  if settings == nil or draft == nil then
    return {}
  end
  local items = {}
  local function changed(key, before, after)
    if tostring(before) ~= tostring(after) then
      table.insert(items, { key = key, value = after })
    end
  end
  changed("fan.mode", settings.fan.mode, draft.fan.mode)
  changed("fan.temperature_source", settings.fan.temperature_source, draft.fan.temperature_source)
  changed("fan.duty_min_percent", settings.fan.duty_min_percent, draft.fan.duty_min_percent)
  changed("fan.duty_max_percent", settings.fan.duty_max_percent, draft.fan.duty_max_percent)
  changed("backlight_percent", settings.backlight_percent, draft.backlight_percent)
  changed("averaging_ms", settings.averaging_ms, draft.averaging_ms)
  changed("logging_interval_seconds", settings.logging_interval_seconds, draft.logging_interval_seconds)
  changed("display.default_screen", settings.display.default_screen, draft.display.default_screen)
  changed(
    "fault_thresholds.temperature_c",
    settings.fault_thresholds.temperature_c,
    draft.fault_thresholds.temperature_c
  )
  changed(
    "fault_thresholds.total_current_a",
    settings.fault_thresholds.total_current_a,
    draft.fault_thresholds.total_current_a
  )
  changed(
    "fault_thresholds.wire_current_a",
    settings.fault_thresholds.wire_current_a,
    draft.fault_thresholds.wire_current_a
  )
  changed(
    "fault_thresholds.total_power_w",
    settings.fault_thresholds.total_power_w,
    draft.fault_thresholds.total_power_w
  )
  changed(
    "fault_thresholds.current_imbalance_percent",
    settings.fault_thresholds.current_imbalance_percent,
    draft.fault_thresholds.current_imbalance_percent
  )
  changed(
    "fault_thresholds.current_imbalance_min_load_a",
    settings.fault_thresholds.current_imbalance_min_load_a,
    draft.fault_thresholds.current_imbalance_min_load_a
  )
  if not persist then
    changed(
      "daemon.poll_interval_ms",
      configuration.daemon and configuration.daemon.poll_interval_ms,
      draft.daemon and draft.daemon.poll_interval_ms
    )
  end
  return items
end

local function submitChanges(persist)
  local items = buildChanges(persist)
  if #items == 0 then
    localMessage = persist
      and "No changed device settings to store. Daemon polling is runtime-only."
      or "No settings changed."
    confirmPermanent = false
    render()
    return
  end
  requestSequence = requestSequence + 1
  noctalia.state.set("wireview.config.request", {
    id = tostring(os.time()) .. ":" .. tostring(requestSequence),
    action = "apply",
    persist = persist,
    items = items,
  })
  localMessage = nil
  confirmPermanent = false
  render()
end

local function configureView()
  if type(configuration) ~= "table" or configuration.loading == true then
    return emptyState("Reading device configuration", "Requesting active settings from wireviewd.")
  end
  if configuration.error ~= nil then
    return emptyState("Configuration unavailable", tostring(configuration.error))
  end
  syncDraft(false)
  if draft == nil then
    return emptyState("Configuration unavailable", "wireviewd returned no editable settings.")
  end

  local visibleScreenOperation = recentScreenOperation()
  local operationText = localMessage
    or (visibleScreenOperation and visibleScreenOperation.message)
    or (type(operation) == "table" and operation.message)
    or (draftDirty and "Unsaved changes" or "Active settings match the device")
  local operationColor = visibleScreenOperation ~= nil
      and (visibleScreenOperation.status == "error" and DANGER or ACCENT)
    or (type(operation) == "table" and operation.status == "error" and DANGER
    or (draftDirty and ACCENT or MUTED))
  local controlsEnabled = not (type(operation) == "table" and operation.status == "running")

  local fanColumn = ui.column({ flexGrow = 1, gap = 3, align = "stretch" }, {
    ui.label({ text = "FAN CONTROL", color = DIM, fontSize = 9, fontWeight = "bold" }),
    settingBlock("Mode", string.upper(tostring(draft.fan.mode)), ui.select({
      options = FAN_MODE_LABELS,
      selectedIndex = indexOf(FAN_MODES, draft.fan.mode),
      controlSize = "sm",
      enabled = controlsEnabled,
      onChange = "onFanModeChanged",
    })),
    settingBlock("Temperature source", tostring(draft.fan.temperature_source), ui.select({
      options = TEMP_SOURCE_LABELS,
      selectedIndex = indexOf(TEMP_SOURCES, draft.fan.temperature_source),
      controlSize = "sm",
      enabled = controlsEnabled,
      onChange = "onTemperatureSourceChanged",
    })),
    settingBlock("Minimum duty", tostring(math.floor(number(draft.fan.duty_min_percent, 0))) .. "%", ui.slider({
      min = 0,
      max = 100,
      step = 1,
      value = number(draft.fan.duty_min_percent, 0),
      controlSize = "sm",
      enabled = controlsEnabled,
      onChange = "onFanMinimumChanged",
    })),
    settingBlock("Maximum duty", tostring(math.floor(number(draft.fan.duty_max_percent, 100))) .. "%", ui.slider({
      min = 0,
      max = 100,
      step = 1,
      value = number(draft.fan.duty_max_percent, 100),
      controlSize = "sm",
      enabled = controlsEnabled,
      onChange = "onFanMaximumChanged",
    })),
  })

  local systemColumn = ui.column({ flexGrow = 1, gap = 3, align = "stretch" }, {
    ui.label({ text = "DISPLAY + SAMPLING", color = DIM, fontSize = 9, fontWeight = "bold" }),
    settingBlock("Backlight", tostring(math.floor(number(draft.backlight_percent, 100))) .. "%", ui.slider({
      min = 0,
      max = 100,
      step = 1,
      value = number(draft.backlight_percent, 100),
      controlSize = "sm",
      enabled = controlsEnabled,
      onChange = "onBacklightChanged",
    })),
    settingBlock("Sensor averaging", tostring(draft.averaging_ms) .. " ms", ui.select({
      options = AVERAGING_LABELS,
      selectedIndex = indexOf(AVERAGING_VALUES, draft.averaging_ms),
      controlSize = "sm",
      enabled = controlsEnabled,
      onChange = "onAveragingChanged",
    })),
    settingBlock("Screen shown now", screenLabel(currentScreen()) or "SELECT", ui.select({
      options = CURRENT_SCREEN_LABELS,
      selectedIndex = indexOf(CURRENT_SCREEN_VALUES, currentScreen() or ""),
      controlSize = "sm",
      enabled = controlsEnabled and not screenChangePending(),
      onChange = "onCurrentScreenChanged",
    })),
    settingBlock("Default screen", tostring(draft.display.default_screen), ui.select({
      options = SCREEN_LABELS,
      selectedIndex = indexOf(SCREEN_VALUES, draft.display.default_screen),
      controlSize = "sm",
      enabled = controlsEnabled,
      onChange = "onDefaultScreenChanged",
    })),
    settingBlock(
      "Device logging",
      tostring(math.floor(number(draft.logging_interval_seconds, 60))) .. " s",
      ui.slider({
        min = 0,
        max = 255,
        step = 1,
        value = number(draft.logging_interval_seconds, 60),
        controlSize = "sm",
        enabled = controlsEnabled,
        onChange = "onLoggingIntervalChanged",
      })
    ),
    settingBlock(
      "Daemon polling",
      tostring(math.floor(number(draft.daemon.poll_interval_ms, 500))) .. " ms",
      ui.slider({
        min = 100,
        max = 5000,
        step = 100,
        value = number(draft.daemon.poll_interval_ms, 500),
        controlSize = "sm",
        enabled = controlsEnabled,
        onChange = "onPollIntervalChanged",
      })
    ),
  })

  local thresholdA = ui.column({ flexGrow = 1, gap = 3, align = "stretch" }, {
    settingBlock(
      "Temperature alarm",
      format(draft.fault_thresholds.temperature_c, 1) .. " °C",
      ui.slider({
        min = 0,
        max = 120,
        step = 0.1,
        value = number(draft.fault_thresholds.temperature_c, 80),
        controlSize = "sm",
        enabled = controlsEnabled,
        onChange = "onFaultTemperatureChanged",
      })
    ),
    settingBlock(
      "Total current alarm",
      tostring(math.floor(number(draft.fault_thresholds.total_current_a, 55))) .. " A",
      ui.slider({
        min = 0,
        max = 150,
        step = 1,
        value = number(draft.fault_thresholds.total_current_a, 55),
        controlSize = "sm",
        enabled = controlsEnabled,
        onChange = "onFaultTotalCurrentChanged",
      })
    ),
  })

  local thresholdB = ui.column({ flexGrow = 1, gap = 3, align = "stretch" }, {
    settingBlock(
      "Per-wire current alarm",
      format(draft.fault_thresholds.wire_current_a, 1) .. " A",
      ui.slider({
        min = 0,
        max = 25.5,
        step = 0.1,
        value = number(draft.fault_thresholds.wire_current_a, 10.5),
        controlSize = "sm",
        enabled = controlsEnabled,
        onChange = "onFaultWireCurrentChanged",
      })
    ),
    settingBlock(
      "Total power alarm",
      tostring(math.floor(number(draft.fault_thresholds.total_power_w, 660))) .. " W",
      ui.slider({
        min = 0,
        max = 2000,
        step = 1,
        value = number(draft.fault_thresholds.total_power_w, 660),
        controlSize = "sm",
        enabled = controlsEnabled,
        onChange = "onFaultPowerChanged",
      })
    ),
  })

  local thresholdC = ui.column({ flexGrow = 1, gap = 3, align = "stretch" }, {
    settingBlock(
      "Current imbalance alarm",
      tostring(math.floor(number(draft.fault_thresholds.current_imbalance_percent, 40))) .. "%",
      ui.slider({
        min = 0,
        max = 100,
        step = 1,
        value = number(draft.fault_thresholds.current_imbalance_percent, 40),
        controlSize = "sm",
        enabled = controlsEnabled,
        onChange = "onFaultImbalanceChanged",
      })
    ),
    settingBlock(
      "Imbalance minimum load",
      tostring(math.floor(number(draft.fault_thresholds.current_imbalance_min_load_a, 6))) .. " A",
      ui.slider({
        min = 0,
        max = 10,
        step = 1,
        value = number(draft.fault_thresholds.current_imbalance_min_load_a, 6),
        controlSize = "sm",
        enabled = controlsEnabled,
        onChange = "onFaultImbalanceMinimumLoadChanged",
      })
    ),
  })

  local actions = {
    ui.button({
      text = "RESET",
      variant = "ghost",
      controlSize = "sm",
      enabled = controlsEnabled and draftDirty,
      onClick = "onResetDraftClicked",
    }),
    ui.button({
      text = "APPLY FOR SESSION",
      variant = "outline",
      controlSize = "sm",
      enabled = controlsEnabled and draftDirty,
      onClick = "onApplyTemporaryClicked",
    }),
    ui.button({
      text = confirmPermanent and "STORE TO DEVICE" or "REVIEW DEVICE STORE",
      variant = confirmPermanent and "primary" or "outline",
      controlSize = "sm",
      enabled = controlsEnabled and draftDirty,
      onClick = confirmPermanent and "onStoreConfirmedClicked" or "onStoreReviewClicked",
    }),
  }

  local body = {
    ui.row({ align = "end" }, {
      ui.label({ text = "DEVICE CONFIGURATION", color = TEXT, fontSize = 15, fontWeight = "bold" }),
      ui.spacer({ flexGrow = 1 }),
      ui.label({ text = "DEVICE CONNECTED", color = ACCENT, fontSize = 9, fontWeight = "bold" }),
    }),
    ui.separator({ color = LINE, thickness = 1 }),
  }
  if confirmPermanent then
    table.insert(body, ui.row({ gap = 9, paddingV = 8, align = "center" }, {
      ui.box({ width = 3, height = 30, fill = ACCENT }),
      ui.label({
        text = "This writes changed device settings to nonvolatile memory. Daemon polling stays runtime-only.",
        color = TEXT,
        fontSize = 10,
        flexGrow = 1,
      }),
    }))
  end
  table.insert(body, ui.scroll({ flexGrow = 1, align = "stretch" }, {
    ui.column({ gap = 12, align = "stretch" }, {
      ui.label({ text = "FAULT LIMITS", color = DIM, fontSize = 9, fontWeight = "bold" }),
      ui.row({ gap = 18, align = "stretch" }, {
        thresholdA,
        ui.separator({ orientation = "vertical", color = LINE, thickness = 1 }),
        thresholdB,
        ui.separator({ orientation = "vertical", color = LINE, thickness = 1 }),
        thresholdC,
      }),
      ui.separator({ color = LINE, thickness = 1 }),
      ui.row({ gap = 28, align = "stretch" }, {
        fanColumn,
        ui.separator({ orientation = "vertical", color = LINE, thickness = 1 }),
        systemColumn,
      }),
    }),
  }))
  table.insert(body, ui.separator({ color = LINE, thickness = 1 }))
  table.insert(body, ui.label({
    text = operationText,
    color = operationColor,
    fontSize = 10,
    maxLines = 2,
  }))
  table.insert(body, ui.row({ gap = 8, align = "center", justify = "end" }, actions))
  return ui.column({
    height = 542,
    padding = 18,
    gap = 10,
    align = "stretch",
    justify = "start",
  }, body)
end

render = function()
  if not opened then
    return
  end
  local body = overview()
  if activeTab == "pins" then
    body = pinsView()
  elseif activeTab == "faults" then
    body = faultsView()
  elseif activeTab == "configure" then
    body = configureView()
  end
  local children = { header() }
  local banner = telemetryBanner()
  if banner ~= nil then
    table.insert(children, banner)
    table.insert(children, ui.separator({ color = LINE, thickness = 1 }))
  end
  table.insert(children, ui.column({ flexGrow = 1, opacity = telemetryIsLive() and 1 or 0.52 }, { body }))
  panel.render(ui.column({ flexGrow = 1, gap = 0, fill = SURFACE, align = "stretch" }, children))
end

function onOpen()
  opened = true
  panel.setWantsSecondTicks(true)
  syncDraft(false)
  noctalia.state.set("wireview.config.request", {
    id = "open:" .. tostring(os.time()),
    action = "refresh",
  })
  render()
end

function update()
  render()
end

function onClose()
  opened = false
end

function onCloseClicked()
  panel.close()
end

-- Makes every dashboard view directly addressable for shell automation and
-- accessibility tooling without pointer injection.
function onIpc(event, payload)
  if event ~= "tab" then
    return
  end
  if payload == "overview" or payload == "pins" or payload == "faults" or payload == "configure" then
    activeTab = payload
    render()
  end
end

function onFanModeChanged(index)
  if draft ~= nil then
    draft.fan.mode = valueAt(FAN_MODES, index) or draft.fan.mode
    markDraftChanged()
  end
end

function onTemperatureSourceChanged(index)
  if draft ~= nil then
    draft.fan.temperature_source = valueAt(TEMP_SOURCES, index) or draft.fan.temperature_source
    markDraftChanged()
  end
end

function onFanMinimumChanged(value)
  if draft ~= nil then
    draft.fan.duty_min_percent = math.min(number(value, 0), number(draft.fan.duty_max_percent, 100))
    markDraftChanged()
  end
end

function onFanMaximumChanged(value)
  if draft ~= nil then
    draft.fan.duty_max_percent = math.max(number(value, 100), number(draft.fan.duty_min_percent, 0))
    markDraftChanged()
  end
end

function onBacklightChanged(value)
  if draft ~= nil then
    draft.backlight_percent = number(value, 100)
    markDraftChanged()
  end
end

function onAveragingChanged(index)
  if draft ~= nil then
    draft.averaging_ms = valueAt(AVERAGING_VALUES, index) or draft.averaging_ms
    markDraftChanged()
  end
end

function onDefaultScreenChanged(index)
  if draft ~= nil then
    draft.display.default_screen = valueAt(SCREEN_VALUES, index) or draft.display.default_screen
    markDraftChanged()
  end
end

function onCurrentScreenChanged(index)
  local screen = valueAt(CURRENT_SCREEN_VALUES, index)
  if screen == nil or screen == "" then
    return
  end
  requestSequence = requestSequence + 1
  localMessage = nil
  noctalia.state.set("wireview.screen.request", {
    id = "screen:" .. tostring(os.time()) .. ":" .. tostring(requestSequence),
    action = "set",
    screen = screen,
  })
end

function onLoggingIntervalChanged(value)
  if draft ~= nil then
    draft.logging_interval_seconds = number(value, 60)
    markDraftChanged()
  end
end

function onPollIntervalChanged(value)
  if draft ~= nil then
    draft.daemon.poll_interval_ms = math.floor(number(value, 500) / 100 + 0.5) * 100
    markDraftChanged()
  end
end

function onFaultTemperatureChanged(value)
  if draft ~= nil then
    draft.fault_thresholds.temperature_c = math.floor(number(value, 80) * 10 + 0.5) / 10
    markDraftChanged()
  end
end

function onFaultTotalCurrentChanged(value)
  if draft ~= nil then
    draft.fault_thresholds.total_current_a = math.floor(number(value, 55) + 0.5)
    markDraftChanged()
  end
end

function onFaultWireCurrentChanged(value)
  if draft ~= nil then
    draft.fault_thresholds.wire_current_a = math.floor(number(value, 10.5) * 10 + 0.5) / 10
    markDraftChanged()
  end
end

function onFaultPowerChanged(value)
  if draft ~= nil then
    draft.fault_thresholds.total_power_w = math.floor(number(value, 660) + 0.5)
    markDraftChanged()
  end
end

function onFaultImbalanceChanged(value)
  if draft ~= nil then
    draft.fault_thresholds.current_imbalance_percent = math.floor(number(value, 40) + 0.5)
    markDraftChanged()
  end
end

function onFaultImbalanceMinimumLoadChanged(value)
  if draft ~= nil then
    draft.fault_thresholds.current_imbalance_min_load_a = math.floor(number(value, 6) + 0.5)
    markDraftChanged()
  end
end

function onClearChipTemperatureClicked()
  requestFaultClear("chip_over_temperature")
end

function onClearSensorTemperatureClicked()
  requestFaultClear("sensor_over_temperature")
end

function onClearTotalCurrentClicked()
  requestFaultClear("over_current")
end

function onClearWireAlarmClicked()
  requestFaultClear("wire_over_current")
end

function onClearPowerClicked()
  requestFaultClear("over_power")
end

function onClearImbalanceClicked()
  requestFaultClear("current_imbalance")
end

function onResetDraftClicked()
  syncDraft(true)
  localMessage = "Draft reset to active settings."
  render()
end

function onApplyTemporaryClicked()
  submitChanges(false)
end

function onStoreReviewClicked()
  confirmPermanent = true
  render()
end

function onStoreConfirmedClicked()
  submitChanges(true)
end

noctalia.state.watch("wireview.snapshot", function(value)
  snapshot = value
  render()
end)

noctalia.state.watch("wireview.series", function(value)
  series = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("wireview.status", function(value)
  status = value
  render()
end)

noctalia.state.watch("wireview.config", function(value)
  configuration = value
  syncDraft(false)
  render()
end)

noctalia.state.watch("wireview.config.operation", function(value)
  operation = value
  if type(value) == "table" and value.status == "success" then
    draftDirty = false
  end
  render()
end)

noctalia.state.watch("wireview.screen.operation", function(value)
  screenOperation = value
  render()
end)

noctalia.state.watch("wireview.fault.operation", function(value)
  faultOperation = value
  render()
end)

noctalia.state.watch("wireview.fault.observations", function(value)
  faultObservations = value
  render()
end)
