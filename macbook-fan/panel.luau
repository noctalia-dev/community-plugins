--!nonstrict
-- MacBook Fan & Thermal Attached Popup Panel
-- Provides detailed telemetry, progress gauges, fan control (auto/manual), and health diagnostics.

local SNAPSHOT = "macbook_fan.snapshot"
local COMMAND = "macbook_fan.command"

local snap = noctalia.state.get(SNAPSHOT) or {
  rpm = 0,
  min_rpm = 1200,
  max_rpm = 6500,
  target_rpm = 1200,
  percent = 0,
  temp = 0,
  daemon_active = false,
  driver_available = false,
  control_mode = "auto",
  display_mode = "rpm",
}

local currentTargetRpm = nil

local function completeOnboarding()
  noctalia.state.set(COMMAND, {
    action = "complete_onboarding",
  })
end

local function setDisplayMode(mode)
  noctalia.state.set(COMMAND, {
    action = "set_display_mode",
    mode = mode,
  })
end

local dir = (noctalia.pluginDir and noctalia.pluginDir()) or ""
local isLocal = string.find(dir, "local/") ~= nil
local PLUGIN_ID = isLocal and "local/macbook-fan" or "blackx16/macbook-fan"
local PANEL_AUTO = PLUGIN_ID .. ":panel"
local PANEL_MANUAL = PLUGIN_ID .. ":panel_manual"

local function setControlMode(mode)
  local prevMode = snap.control_mode or "auto"
  snap.control_mode = mode
  noctalia.state.set(COMMAND, {
    action = "set_fan_mode",
    mode = mode,
    rpm = currentTargetRpm,
  })
  if mode ~= prevMode then
    local targetPanel = (mode == "manual") and PANEL_MANUAL or PANEL_AUTO
    panel.close()
    noctalia.togglePanel(targetPanel)
  end
end

local lastSentRpm = nil
local function setFanRpm(rpm)
  currentTargetRpm = rpm
  if lastSentRpm == rpm then
    return
  end
  lastSentRpm = rpm
  noctalia.state.set(COMMAND, {
    action = "set_rpm",
    rpm = rpm,
  })
end

local function runSetup()
  noctalia.state.set(COMMAND, {
    action = "run_setup",
  })
end

local function getAccentRole()
  if not snap.driver_available then
    return "error"
  end
  local t = snap.temp or 0
  local r = snap.rpm or 0
  if t >= 80 or r >= 5000 then
    return "error"
  elseif t >= 65 or r >= 3200 then
    return "secondary"
  end
  return "primary"
end

local function modeButton(mode, label)
  local current = snap.display_mode or "rpm"
  local isSelected = (current == mode)
  return ui.button({
    text = label,
    variant = isSelected and "primary" or "ghost",
    flexGrow = 1,
    controlSize = "sm",
    onClick = function()
      setDisplayMode(mode)
    end,
  })
end

local function presetButton(targetVal, label, tooltip)
  local isSelected = (currentTargetRpm == targetVal)
  return ui.button({
    text = label,
    tooltip = tooltip,
    variant = isSelected and "secondary" or "ghost",
    flexGrow = 1,
    controlSize = "sm",
    onClick = function()
      setFanRpm(targetVal)
    end,
  })
end

local function render()
  local accent = getAccentRole()
  local minR = snap.min_rpm or 1200
  local maxR = snap.max_rpm or 6500
  local span = math.max(1, maxR - minR)
  local progressVal = math.clamp(((snap.rpm or 0) - minR) / span, 0, 1)

  local controlMode = snap.control_mode or "auto"
  if currentTargetRpm == nil then
    currentTargetRpm = snap.target_rpm or snap.rpm or minR
  end
  currentTargetRpm = math.clamp(currentTargetRpm, minR, maxR)
  local targetPct = math.clamp(math.floor(((currentTargetRpm - minR) / span) * 100), 0, 100)

  local isHealthy = (snap.driver_available == true) and (snap.daemon_active == true)
  local isOnboarding = (snap.onboarded ~= true) or (not isHealthy)

  local children = {}

  -- 1. Header
  table.insert(children, ui.row({ align = "center", justify = "space_between", gap = 8 }, {
    ui.row({ align = "center", gap = 6 }, {
      ui.glyph({ name = "car-fan", color = accent, size = 18 }),
      ui.label({
        text = noctalia.tr("panel.title"),
        fontSize = 15,
        fontWeight = "bold",
        color = "on_surface",
      }),
    }),
    ui.button({
      glyph = "x",
      tooltip = noctalia.tr("panel.close"),
      variant = "ghost",
      controlSize = "sm",
      onClick = function()
        panel.close()
      end,
    }),
  }))

  -- 2. Fan RPM & Gauge
  table.insert(children, ui.column({ gap = 3 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.row({ gap = 6, align = "center" }, {
        ui.label({
          text = string.format("%d RPM", snap.rpm or 0),
          fontSize = 18,
          fontWeight = "bold",
          color = accent,
        }),
      }),
      ui.row({
        fill = accent .. "/0.15",
        radius = 6,
        paddingH = 6,
        paddingV = 2,
      }, {
        ui.label({
          text = string.format("%d%%", snap.percent or 0),
          fontSize = 12,
          fontWeight = "bold",
          color = accent,
        }),
      }),
    }),

    ui.progress({
      progress = progressVal,
      height = 6,
      radius = 4,
      fill = accent,
      track = "secondary/0.2",
    }),

    ui.row({ justify = "space_between" }, {
      ui.label({
        text = string.format("%d RPM", minR),
        fontSize = 10,
        color = "on_surface_variant",
      }),
      ui.label({
        text = string.format("%d RPM", maxR),
        fontSize = 10,
        color = "on_surface_variant",
      }),
    }),
  }))

  -- 3. Telemetry Cards
  local controllerText = noctalia.tr("panel.controller_stopped")
  if controlMode == "manual" then
    controllerText = noctalia.tr("panel.controller_manual")
  elseif snap.daemon_active then
    controllerText = noctalia.tr("panel.controller_daemon")
  end

  table.insert(children, ui.column({ gap = 3 }, {
    ui.label({
      text = noctalia.tr("panel.telemetry_title"),
      fontSize = 10,
      fontWeight = "bold",
      color = "on_surface_variant",
    }),
    ui.row({ gap = 6, align = "center" }, {
      ui.row({
        fill = "secondary/0.15",
        radius = 8,
        paddingH = 8,
        paddingV = 4,
        gap = 6,
        flexGrow = 1,
        align = "center",
      }, {
        ui.glyph({ name = "flame", size = 15, color = accent }),
        ui.column({ gap = 1 }, {
          ui.label({ text = noctalia.tr("panel.temperature"), fontSize = 10, color = "on_surface_variant" }),
          ui.label({ text = string.format("%.1f °C", snap.temp or 0), fontSize = 12, fontWeight = "bold", color = "on_surface" }),
        }),
      }),
      ui.row({
        fill = "secondary/0.15",
        radius = 8,
        paddingH = 8,
        paddingV = 4,
        gap = 6,
        flexGrow = 1,
        align = "center",
      }, {
        ui.glyph({ name = "cpu", size = 15, color = "primary" }),
        ui.column({ gap = 1 }, {
          ui.label({ text = noctalia.tr("panel.controller"), fontSize = 10, color = "on_surface_variant" }),
          ui.label({
            text = controllerText,
            fontSize = 12,
            fontWeight = "bold",
            color = (controlMode == "manual" or snap.daemon_active) and "primary" or "secondary",
          }),
        }),
      }),
    }),
  }))

  -- 4. Fan Speed Control (Auto / Manual)
  local controlChildren = {
    ui.label({
      text = noctalia.tr("panel.control_title"),
      fontSize = 10,
      fontWeight = "bold",
      color = "on_surface_variant",
    }),
    ui.row({ gap = 6 }, {
      ui.button({
        text = noctalia.tr("panel.control_auto"),
        variant = (controlMode == "auto") and "primary" or "ghost",
        flexGrow = 1,
        controlSize = "sm",
        onClick = function()
          setControlMode("auto")
        end,
      }),
      ui.button({
        text = noctalia.tr("panel.control_manual"),
        variant = (controlMode == "manual") and "primary" or "ghost",
        flexGrow = 1,
        controlSize = "sm",
        onClick = function()
          setControlMode("manual")
        end,
      }),
    }),
  }

  if controlMode == "auto" then
    table.insert(controlChildren, ui.row({
      fill = "secondary/0.15",
      radius = 8,
      paddingH = 8,
      paddingV = 4,
      gap = 6,
      align = "center",
    }, {
      ui.glyph({ name = "flame", size = 14, color = accent }),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({
          text = noctalia.tr("panel.auto_status"),
          fontSize = 11,
          fontWeight = "medium",
          color = "on_surface",
        }),
        ui.label({
          text = noctalia.tr("panel.auto_desc"),
          fontSize = 10,
          color = "on_surface_variant",
        }),
      }),
    }))
  else
    -- Manual Control: Drag slider, steppers, and presets
    table.insert(controlChildren, ui.column({ gap = 4 }, {
      ui.row({ align = "center", justify = "space_between" }, {
        ui.label({
          text = string.format(noctalia.tr("panel.target_format"), currentTargetRpm, targetPct),
          fontSize = 11,
          fontWeight = "bold",
          color = "primary",
        }),
        ui.row({ gap = 6 }, {
          ui.button({
            text = "-250",
            tooltip = noctalia.tr("panel.stepper_decrease"),
            variant = "ghost",
            controlSize = "sm",
            onClick = function()
              setFanRpm(math.max(minR, currentTargetRpm - 250))
            end,
          }),
          ui.button({
            text = "+250",
            tooltip = noctalia.tr("panel.stepper_increase"),
            variant = "ghost",
            controlSize = "sm",
            onClick = function()
              setFanRpm(math.min(maxR, currentTargetRpm + 250))
            end,
          }),
        }),
      }),

      ui.slider({
        min = minR,
        max = maxR,
        step = 50,
        value = currentTargetRpm,
        controlSize = "sm",
        onChange = function(val)
          local n = tonumber(val)
          if n then
            setFanRpm(math.floor(n))
          end
        end,
      }),

      ui.row({ gap = 6 }, {
        presetButton(minR, noctalia.tr("panel.preset_min"), noctalia.tr("panel.preset_tooltip_min")),
        presetButton(2800, "2800", noctalia.tr("panel.preset_tooltip_mid1")),
        presetButton(4500, "4500", noctalia.tr("panel.preset_tooltip_mid2")),
        presetButton(maxR, noctalia.tr("panel.preset_max"), noctalia.tr("panel.preset_tooltip_max")),
      }),
    }))
  end

  table.insert(children, ui.column({ gap = 4 }, controlChildren))

  -- 5. Display Mode Switcher
  table.insert(children, ui.column({ gap = 3 }, {
    ui.label({
      text = noctalia.tr("panel.display_mode"),
      fontSize = 10,
      fontWeight = "bold",
      color = "on_surface_variant",
    }),
    ui.row({ gap = 6 }, {
      modeButton("rpm", noctalia.tr("panel.mode_rpm")),
      modeButton("percent", noctalia.tr("panel.mode_percent")),
      modeButton("both", noctalia.tr("panel.mode_both")),
    }),
  }))

  -- 6. Requirements / Health (Onboarding) or Single Small Action Button (After Onboarding)
  if isOnboarding then
    local statusRows = {
      ui.label({
        text = snap.driver_available and noctalia.tr("panel.driver_loaded") or noctalia.tr("panel.driver_missing"),
        fontSize = 11,
        color = snap.driver_available and "on_surface" or "error",
      }),
      ui.label({
        text = snap.daemon_active and noctalia.tr("panel.service_running") or noctalia.tr("panel.service_inactive"),
        fontSize = 11,
        color = snap.daemon_active and "on_surface" or "secondary",
      }),
    }

    local actionButtons = {
      ui.button({
        text = noctalia.tr("panel.setup"),
        glyph = "tool",
        variant = isHealthy and "secondary" or "primary",
        controlSize = "sm",
        onClick = runSetup,
      }),
    }

    if isHealthy then
      table.insert(actionButtons, ui.button({
        text = noctalia.tr("panel.done"),
        variant = "primary",
        controlSize = "sm",
        onClick = completeOnboarding,
      }))
    end

    table.insert(children, ui.column({ gap = 3 }, {
      ui.label({
        text = noctalia.tr("panel.prereqs_title"),
        fontSize = 10,
        fontWeight = "bold",
        color = isHealthy and "on_surface_variant" or "error",
      }),
      ui.row({
        fill = "secondary/0.15",
        radius = 8,
        paddingH = 8,
        paddingV = 5,
        align = "center",
        justify = "space_between",
      }, {
        ui.column({ gap = 2 }, statusRows),
        ui.row({ gap = 4 }, actionButtons),
      }),
    }))
  else
    -- After onboarding: a single small button where user can verify or reinstall the drivers and stuff
    table.insert(children, ui.button({
      text = noctalia.tr("panel.verify_drivers"),
      tooltip = noctalia.tr("panel.run_setup"),
      glyph = "tool",
      variant = "ghost",
      controlSize = "sm",
      onClick = runSetup,
    }))
  end

  panel.render(ui.column({ gap = 5, padding = 8 }, children))
end

function onOpen(_context)
  snap = noctalia.state.get(SNAPSHOT) or snap
  if snap.target_rpm and snap.target_rpm > 0 then
    currentTargetRpm = snap.target_rpm
  end
  render()
end

noctalia.state.watch(SNAPSHOT, function(val)
  if type(val) == "table" then
    snap = val
    if currentTargetRpm == nil and snap.target_rpm and snap.target_rpm > 0 then
      currentTargetRpm = snap.target_rpm
    end
    render()
  end
end)

function update()
  render()
end

render()
