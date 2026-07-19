--!nonstrict

local snapshot = noctalia.state.get("snapshot")
local history = noctalia.state.get("drive_history") or { drives = {} }
local preferences = noctalia.state.get("drive_preferences") or { schema = 1, order = {}, drives = {} }
local opened = false
local expandedDriveId = nil
local editingDriveId = nil
local currentDrives = {}
local currentIssues = {}
local dismissRequestNonce = 0
local pendingSelfTest = nil
local selfTestLaunch = nil
local confirmUninstall = false
local showCollectorSettings = false
local hiddenSelection = 1
local aliasDraft = ""
local warningDraft = ""
local criticalDraft = ""
local lifeDraft = ""
local alertsDraft = true
local presenceDraft = false
local EDITABLE_PREFERENCE_FIELDS = {
  "alias", "warning_temperature", "critical_temperature", "life_warning_percent",
  "alerts_enabled", "presence_alert_enabled",
}
local MIN_TREND_SAMPLES = 4

local function number(value, fallback)
  local parsed = tonumber(value)
  return parsed ~= nil and parsed or fallback
end

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local function formatBytes(value)
  local bytes = tonumber(value)
  if bytes == nil then
    return noctalia.tr("common.not_available")
  end
  local units = { "B", "KiB", "MiB", "GiB", "TiB", "PiB" }
  local index = 1
  while bytes >= 1024 and index < #units do
    bytes /= 1024
    index += 1
  end
  if index <= 3 then
    return string.format("%.0f %s", bytes, units[index])
  end
  return string.format("%.1f %s", bytes, units[index])
end

local function formatHours(value)
  local hours = tonumber(value)
  if hours == nil then
    return noctalia.tr("common.not_available")
  end
  if hours >= 8760 then
    return noctalia.tr("common.duration_years", { value = string.format("%.1f", hours / 8760) })
  elseif hours >= 24 then
    return noctalia.tr("common.duration_days", { value = string.format("%.0f", hours / 24) })
  end
  return noctalia.tr("common.duration_hours", { value = string.format("%.0f", hours) })
end

local function formatPowerOn(drive)
  local formatted = formatHours(drive.power_on_hours)
  return drive.power_on_hours_saturated and "≥ " .. formatted or formatted
end

local function formatPercent(value)
  local percent = tonumber(value)
  return percent ~= nil and string.format("%.0f%%", percent) or noctalia.tr("common.not_available")
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function driveId(drive)
  return tostring(drive.id or drive.serial or drive.device or "unknown")
end

local function driveName(drive)
  return tostring(drive.display_name or drive.model or drive.device or noctalia.tr("alerts.unknown_drive"))
end

local function preferenceFor(id)
  preferences.drives = type(preferences.drives) == "table" and preferences.drives or {}
  local entry = preferences.drives[id]
  if type(entry) ~= "table" then
    entry = {}
    preferences.drives[id] = entry
  end
  return entry
end

local function savePreferences()
  local directory = noctalia.pluginDataDir()
  if directory == nil then
    noctalia.notifyError(noctalia.tr("preferences.title"), noctalia.tr("preferences.save_failed"))
    return false
  end
  preferences.schema = 1
  preferences.order = type(preferences.order) == "table" and preferences.order or {}
  preferences.drives = type(preferences.drives) == "table" and preferences.drives or {}
  local encoded = noctalia.json.encode(preferences, true)
  if encoded == nil then
    noctalia.notifyError(noctalia.tr("preferences.title"), noctalia.tr("preferences.save_failed"))
    return false
  end
  local path = directory .. "/drive-preferences.json"
  local temporary = path .. ".tmp"
  if not noctalia.writeFile(temporary, encoded) or not noctalia.renameFile(temporary, path) then
    noctalia.notifyError(noctalia.tr("preferences.title"), noctalia.tr("preferences.save_failed"))
    return false
  end
  noctalia.state.set("drive_preferences", preferences)
  return true
end

local function temperatureColor(value, drive)
  local warning = number(drive and drive.warning_temperature,
    number(noctalia.getConfig("warning_temperature"), 65))
  local critical = math.max(warning + 1, number(drive and drive.critical_temperature,
    number(noctalia.getConfig("critical_temperature"), 80)))
  if value == nil then
    return "on_surface_variant"
  elseif value >= critical then
    return "error"
  elseif value >= warning then
    return "secondary"
  end
  return "primary"
end

local function metric(icon, label, value, color)
  return ui.row({ gap = 8, align = "center", flexGrow = 1 }, {
    ui.glyph({ name = icon, size = 14, color = color or "on_surface_variant" }),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = label, fontSize = 11, color = "on_surface_variant" }),
      ui.label({ text = value, fontWeight = "medium", color = color or "on_surface" }),
    }),
  })
end

local function progressMetric(label, value, display, fill)
  local progress = value ~= nil and clamp(number(value, 0) / 100, 0, 1) or 0
  return ui.column({ gap = 5, flexGrow = 1, align = "stretch" }, {
    ui.row({ justify = "space_between", align = "center" }, {
      ui.label({ text = label, fontSize = 11, color = "on_surface_variant" }),
      ui.label({ text = display, fontSize = 11, fontWeight = "bold", color = fill }),
    }),
    ui.progress({ progress = progress, fill = fill, height = 6, radius = 3 }),
  })
end

local function summaryCard(value, label, detail, color)
  local children = {
    ui.label({ text = value, fontSize = 20, fontWeight = "bold", color = color }),
    ui.label({ text = label, fontSize = 11, color = "on_surface_variant" }),
  }
  if detail ~= nil and tostring(detail) ~= "" then
    table.insert(children, ui.label({ text = tostring(detail), fontSize = 9,
      color = "on_surface_variant/0.78", maxLines = 1 }))
  end
  return ui.column({ gap = 2, padding = 10, radius = 10,
    fill = color .. "/0.12", flexGrow = 1 }, children)
end

local function healthInfo(drive)
  if drive.health == "passed" then
    return noctalia.tr("health.passed"), "primary", "check"
  elseif drive.health == "failed" then
    return noctalia.tr("health.failed"), "error", "alert-triangle"
  end
  return noctalia.tr("health.unknown"), "on_surface_variant", "help-circle"
end

local function appendMetricRows(target, metrics)
  local index = 1
  while index <= #metrics do
    local row = { metrics[index] }
    if metrics[index + 1] ~= nil then
      table.insert(row, metrics[index + 1])
    end
    table.insert(target, ui.row({ gap = 14, align = "center" }, row))
    index += 2
  end
end

local function alertsCard(issues)
  if type(issues) ~= "table" or #issues == 0 then
    return nil
  end

  local header = {
    ui.glyph({ name = "alert-triangle", size = 17, color = "error" }),
    ui.label({
      text = noctalia.tr("alerts.active_title", { count = #issues }),
      fontWeight = "bold",
      color = "error",
      flexGrow = 1,
    }),
  }
  table.insert(header, ui.button({ text = noctalia.tr("alerts.dismiss_all"), variant = "ghost", controlSize = "sm",
    onClick = "onDismissAllAlertsClicked" }))
  local rows = { ui.row({ gap = 7, align = "center" }, header) }
  for index, issue in ipairs(issues) do
    local color = issue.severity == "critical" and "error" or "secondary"
    table.insert(rows, ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = issue.severity == "critical" and "alert-octagon" or "alert-circle", size = 13, color = color }),
      ui.label({ text = tostring(issue.message or issue.title), fontSize = 11, color = "on_surface", flexGrow = 1 }),
      ui.button({ glyph = "x", tooltip = noctalia.tr("alerts.dismiss"), variant = "ghost", controlSize = "sm",
        enabled = index <= 32, onClick = "onDismissAlert" .. tostring(index) .. "Clicked" }),
    }))
  end

  return ui.column({ gap = 7, padding = 11, radius = 10, fill = "error/0.10", border = "error/0.30", borderWidth = 1 }, rows)
end

local function dependencyCard(dependencies)
  if type(dependencies) ~= "table" or dependencies.ready then
    return nil
  end

  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "package", size = 18, color = "error" }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = noctalia.tr("dependencies.title"), fontWeight = "bold", color = "error" }),
        ui.label({
          text = noctalia.tr("dependencies.missing", { missing = tostring(dependencies.missing_text or "") }),
          fontSize = 11,
          color = "on_surface_variant",
          flexGrow = 1,
        }),
      }),
    }),
  }

  if dependencies.install_command ~= nil and dependencies.install_command ~= "" then
    table.insert(children, ui.column({ gap = 4, fill = "surface/0.48", radius = 8, padding = 8 }, {
      ui.label({
        text = noctalia.tr("dependencies.command", {
          manager = tostring(dependencies.package_manager or noctalia.tr("dependencies.package_manager")),
        }),
        fontSize = 10,
        color = "on_surface_variant",
      }),
      ui.label({ text = tostring(dependencies.install_command), fontSize = 10, color = "on_surface", maxLines = 2 }),
    }))
  else
    table.insert(children, ui.label({
      text = noctalia.tr("dependencies.manual_install"),
      fontSize = 11,
      color = "on_surface_variant",
    }))
  end

  local actions = {}
  if dependencies.can_install and dependencies.install_command ~= nil then
    table.insert(actions, ui.button({
      text = noctalia.tr("dependencies.install"),
      variant = "primary",
      onClick = "onInstallDependenciesClicked",
    }))
    table.insert(actions, ui.button({
      text = noctalia.tr("dependencies.copy_command"),
      variant = "outline",
      onClick = "onCopyInstallCommandClicked",
    }))
  end
  table.insert(actions, ui.button({
    text = noctalia.tr("dependencies.recheck"),
    variant = "ghost",
    onClick = "onRefreshClicked",
  }))
  table.insert(children, ui.row({ gap = 8, align = "center" }, actions))

  return ui.column({
    gap = 9,
    padding = 11,
    radius = 10,
    fill = "error/0.10",
    border = "error/0.32",
    borderWidth = 1,
  }, children)
end

local function collectorCard(collector)
  if showCollectorSettings or type(collector) ~= "table" then
    return nil
  end
  local status = tostring(collector.status or "not-installed")
  if status == "healthy" or status == "disabled" then
    return nil
  end
  local color = status == "stale" and "error" or "secondary"
  local actions = {}
  local actionKey = status == "stale" and "collector.start"
    or (collector.installed and "collector.upgrade" or "collector.install")
  local actionHandler = status == "stale" and "onStartCollectorClicked"
    or "onInstallCollectorClicked"
  table.insert(actions, ui.button({
    text = noctalia.tr(actionKey), variant = "primary", controlSize = "sm", onClick = actionHandler,
  }))
  table.insert(actions, ui.button({
    text = noctalia.tr("collector.copy_install"), variant = "outline", controlSize = "sm",
    onClick = "onCopyCollectorCommandClicked",
  }))
  if collector.installed then
    table.insert(actions, ui.button({
      text = noctalia.tr("collector.remove"), variant = confirmUninstall and "destructive" or "ghost",
      controlSize = "sm", onClick = "onUninstallCollectorClicked",
    }))
  end
  table.insert(actions, ui.button({
    text = noctalia.tr("dependencies.recheck"), variant = "ghost", controlSize = "sm",
    onClick = "onRefreshClicked",
  }))

  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "shield-cog", size = 17, color = color }),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = noctalia.tr("collector.title"), fontWeight = "bold", color = color }),
        ui.label({
          text = noctalia.tr("collector.status_" .. status:gsub("%-", "_"), {
            version = tostring(collector.version or collector.expected_version or ""),
          }),
          fontSize = 11, color = "on_surface_variant",
        }),
      }),
    }),
  }
  if confirmUninstall then
    table.insert(children, ui.label({
      text = noctalia.tr("collector.remove_confirm"), fontSize = 11, color = "error",
    }))
  end
  table.insert(children, ui.row({ gap = 7, align = "center" }, actions))
  return ui.column({
    gap = 8, padding = 10, radius = 10, fill = color .. "/0.08",
    border = color .. "/0.24", borderWidth = 1,
  }, children)
end

local function collectorSettingsCard(collector)
  if not showCollectorSettings or type(collector) ~= "table" then
    return nil
  end
  local status = tostring(collector.status or "not-installed")
  local enabled = collector.enabled == true
  local color = status == "healthy" and "primary"
    or (status == "disabled" and "on_surface_variant"
      or (status == "stale" and "error" or "secondary"))
  local actions = {
    ui.button({ text = noctalia.tr("collector.open_settings"), glyph = "settings", variant = "outline",
      controlSize = "sm", onClick = "onOpenPluginSettingsClicked" }),
  }

  if enabled and status == "not-installed" then
    table.insert(actions, 1, ui.button({ text = noctalia.tr("collector.install"), variant = "primary",
      controlSize = "sm", onClick = "onInstallCollectorClicked" }))
  elseif enabled and status == "upgrade-required" then
    table.insert(actions, 1, ui.button({ text = noctalia.tr("collector.upgrade"), variant = "primary",
      controlSize = "sm", onClick = "onInstallCollectorClicked" }))
  elseif enabled and status == "stale" and collector.enable_command ~= nil then
    table.insert(actions, 1, ui.button({ text = noctalia.tr("collector.start"), variant = "primary",
      controlSize = "sm", onClick = "onStartCollectorClicked" }))
  elseif status == "healthy" and collector.disable_command ~= nil then
    table.insert(actions, 1, ui.button({ text = noctalia.tr("collector.pause"), variant = "ghost",
      controlSize = "sm", onClick = "onPauseCollectorClicked" }))
  elseif not enabled and collector.installed and collector.disable_command ~= nil then
    table.insert(actions, 1, ui.button({ text = noctalia.tr("collector.stop_service"), variant = "ghost",
      controlSize = "sm", onClick = "onPauseCollectorClicked" }))
  end

  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "shield-cog", size = 17, color = color }),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = noctalia.tr("collector.settings_title"), fontWeight = "bold", color = color }),
        ui.label({
          text = noctalia.tr("collector.status_" .. status:gsub("%-", "_"), {
            version = tostring(collector.version or collector.expected_version or ""),
          }),
          fontSize = 11, color = "on_surface_variant", maxLines = 2,
        }),
      }),
    }),
    ui.row({ gap = 8, padding = 8, radius = 8, fill = "surface/0.42", align = "center" }, {
      ui.glyph({ name = "server", size = 14, color = "on_surface_variant" }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = noctalia.tr("collector.basic_title"), fontWeight = "bold", fontSize = 11 }),
        ui.label({ text = noctalia.tr("collector.basic_features"), fontSize = 10,
          color = "on_surface_variant", maxLines = 2 }),
      }),
    }),
    ui.row({ gap = 8, padding = 8, radius = 8, fill = "primary/0.10", align = "center" }, {
      ui.glyph({ name = "shield-check", size = 14, color = "primary" }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = noctalia.tr("collector.full_title"), fontWeight = "bold", fontSize = 11,
          color = "primary" }),
        ui.label({ text = noctalia.tr("collector.full_features"), fontSize = 10,
          color = "on_surface_variant", maxLines = 3 }),
      }),
    }),
    ui.label({ text = noctalia.tr("collector.settings_hint"), fontSize = 10,
      color = "on_surface_variant", maxLines = 2 }),
    ui.row({ gap = 7, align = "center" }, actions),
  }
  if confirmUninstall then
    table.insert(children, ui.label({ text = noctalia.tr("collector.remove_confirm"),
      fontSize = 10, color = "error" }))
  end
  if collector.installed then
    table.insert(children, ui.button({ text = noctalia.tr("collector.remove"),
      variant = confirmUninstall and "destructive" or "ghost", controlSize = "sm",
      onClick = "onUninstallCollectorClicked" }))
  end
  return ui.column({
    gap = 8, padding = 10, radius = 10, fill = "surface_variant/0.24",
    border = "outline/0.38", borderWidth = 1,
  }, children)
end

local function trendCard(drive)
  local historyDrives = type(history.drives) == "table" and history.drives or {}
  local entry = historyDrives[driveId(drive)]
  local samples = type(entry) == "table" and entry.samples or {}
  if #samples < MIN_TREND_SAMPLES then
    return nil
  end
  local temperatures = {}
  local life = {}
  local hasTemperatures = true
  local hasLife = true
  for _, sample in ipairs(samples) do
    local temperature = tonumber(sample.hotspot_temperature_c or sample.temperature_c)
    local remaining = tonumber(sample.remaining_life_percent)
    if temperature == nil then
      hasTemperatures = false
    else
      table.insert(temperatures, clamp(temperature / 100, 0, 1))
    end
    if remaining == nil then
      hasLife = false
    else
      table.insert(life, clamp(remaining / 100, 0, 1))
    end
  end
  if not hasTemperatures then temperatures = {} end
  if not hasLife then life = {} end
  if #temperatures < MIN_TREND_SAMPLES and #life < MIN_TREND_SAMPLES then
    return nil
  end
  local primaryValues = #temperatures >= MIN_TREND_SAMPLES and temperatures or life
  local secondaryValues = #temperatures >= MIN_TREND_SAMPLES and #life >= MIN_TREND_SAMPLES and life or nil
  local primaryColor = #temperatures >= MIN_TREND_SAMPLES and "secondary" or "primary"
  local legend = {}
  if #temperatures >= MIN_TREND_SAMPLES then
    table.insert(legend, ui.label({ text = "● " .. noctalia.tr("history.hotspot"), fontSize = 10, color = "secondary" }))
  end
  if #life >= MIN_TREND_SAMPLES then
    table.insert(legend, ui.label({ text = "● " .. noctalia.tr("history.life"), fontSize = 10, color = "primary" }))
  end
  return ui.column({ gap = 5, padding = 8, radius = 9, fill = "surface/0.38" }, {
    ui.row({ justify = "space_between", align = "center" }, {
      ui.label({ text = noctalia.tr("history.title"), fontSize = 11, fontWeight = "bold" }),
      ui.label({ text = noctalia.tr("history.samples", { count = #samples }), fontSize = 10, color = "on_surface_variant" }),
    }),
    ui.graph({ values = primaryValues, values2 = secondaryValues, color = primaryColor, color2 = "primary",
      lineWidth = 2, fillOpacity = 0.10, height = 44 }),
    ui.row({ gap = 12, align = "center" }, legend),
  })
end

local function selfTestCard(drive)
  local firmwareState = tostring(drive.self_test_state or "unsupported")
  local launch = selfTestLaunch ~= nil and selfTestLaunch.drive_id == driveId(drive) and selfTestLaunch or nil
  local state = launch ~= nil and launch.state ~= "failed" and firmwareState ~= "running"
    and launch.state or firmwareState
  local color = state == "failed" and "error"
    or ((state == "running" or state == "authorizing" or state == "starting") and "secondary" or "primary")
  local collector = snapshot and snapshot.system_collector or {}
  local helper = collector.helper_available == true
  local authorization = collector.authorization_available == true
  local canStart = helper and authorization
  local pending = pendingSelfTest ~= nil and pendingSelfTest.drive_id == driveId(drive)
  local completion = tonumber(drive.self_test_completion_percent)
  local status = drive.self_test_status or noctalia.tr("self_test.unavailable")
  if launch ~= nil and firmwareState ~= "running" then
    if launch.state == "authorizing" then
      status = noctalia.tr("self_test.authorizing")
    elseif launch.state == "starting" then
      status = noctalia.tr("self_test.starting")
    elseif launch.state == "failed" then
      status = launch.error or noctalia.tr("self_test.launch_failed")
    end
  end
  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "stethoscope", size = 15, color = color }),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = noctalia.tr("self_test.title"), fontSize = 11, fontWeight = "bold" }),
        ui.label({ text = tostring(status),
          fontSize = 10, color = "on_surface_variant" }),
      }),
    }),
  }
  if firmwareState == "running" and completion ~= nil then
    table.insert(children, ui.column({ gap = 4 }, {
      ui.row({ justify = "space_between", align = "center" }, {
        ui.label({ text = noctalia.tr("self_test.progress"), fontSize = 10, color = "on_surface_variant" }),
        ui.label({ text = formatPercent(completion), fontSize = 10, fontWeight = "bold", color = color }),
      }),
      ui.progress({ progress = clamp(completion / 100, 0, 1), fill = color, height = 5 }),
    }))
  end
  if drive.self_test_supported then
    if pending then
      table.insert(children, ui.label({
        text = noctalia.tr("self_test.confirm", { type = noctalia.tr("self_test." .. pendingSelfTest.kind) }),
        fontSize = 11, color = "secondary",
      }))
      table.insert(children, ui.row({ gap = 7 }, {
        ui.button({ text = noctalia.tr("self_test.confirm_action"), variant = "primary", controlSize = "sm",
          onClick = "onConfirmSelfTestClicked" }),
        ui.button({ text = noctalia.tr("self_test.cancel"), variant = "ghost", controlSize = "sm",
          onClick = "onCancelSelfTestClicked" }),
      }))
    else
      table.insert(children, ui.row({ gap = 7 }, {
        ui.button({ text = noctalia.tr("self_test.short"), variant = "outline", controlSize = "sm",
          enabled = canStart and firmwareState ~= "running" and state ~= "authorizing" and state ~= "starting",
          onClick = "onStartShortSelfTestClicked" }),
        ui.button({ text = noctalia.tr("self_test.long"), variant = "outline", controlSize = "sm",
          enabled = canStart and firmwareState ~= "running" and state ~= "authorizing" and state ~= "starting",
          onClick = "onStartLongSelfTestClicked" }),
      }))
      if not helper then
        table.insert(children, ui.label({ text = noctalia.tr("self_test.helper_required"),
          fontSize = 10, color = "on_surface_variant" }))
      elseif not authorization then
        table.insert(children, ui.label({ text = noctalia.tr("self_test.authorization_required"),
          fontSize = 10, color = "error" }))
      end
    end
  end
  return ui.column({ gap = 7, padding = 9, radius = 9, fill = color .. "/0.08",
    border = color .. "/0.20", borderWidth = 1 }, children)
end

local function preferenceEditor(drive)
  local thresholdFields = {
    ui.column({ gap = 3, flexGrow = 1 }, {
      ui.label({ text = noctalia.tr("preferences.warning_temperature"), fontSize = 10, color = "on_surface_variant" }),
      ui.input({ key = driveId(drive) .. "-warning", value = warningDraft, placeholder = "65",
        controlSize = "sm", onChange = "onWarningThresholdChanged" }),
    }),
    ui.column({ gap = 3, flexGrow = 1 }, {
      ui.label({ text = noctalia.tr("preferences.critical_temperature"), fontSize = 10, color = "on_surface_variant" }),
      ui.input({ key = driveId(drive) .. "-critical", value = criticalDraft, placeholder = "80",
        controlSize = "sm", onChange = "onCriticalThresholdChanged" }),
    }),
  }
  if drive.kind ~= "hdd" then
    table.insert(thresholdFields, ui.column({ gap = 3, flexGrow = 1 }, {
      ui.label({ text = noctalia.tr("preferences.life_warning"), fontSize = 10, color = "on_surface_variant" }),
      ui.input({ key = driveId(drive) .. "-life", value = lifeDraft, placeholder = "20",
        controlSize = "sm", onChange = "onLifeThresholdChanged" }),
    }))
  end

  return ui.column({ gap = 8, padding = 10, radius = 9, fill = "primary/0.07",
    border = "primary/0.24", borderWidth = 1 }, {
    ui.row({ justify = "space_between", align = "center" }, {
      ui.label({ text = noctalia.tr("preferences.title"), fontWeight = "bold", color = "primary" }),
      ui.row({ gap = 5 }, {
        ui.button({ glyph = "arrow-up", tooltip = noctalia.tr("preferences.move_up"), variant = "ghost",
          controlSize = "sm", onClick = "onMoveDriveUpClicked" }),
        ui.button({ glyph = "arrow-down", tooltip = noctalia.tr("preferences.move_down"), variant = "ghost",
          controlSize = "sm", onClick = "onMoveDriveDownClicked" }),
      }),
    }),
    ui.label({ text = noctalia.tr("preferences.alias"), fontSize = 10, color = "on_surface_variant" }),
    ui.input({ key = driveId(drive) .. "-alias", value = aliasDraft,
      placeholder = drive.model or drive.device, controlSize = "sm", onChange = "onAliasChanged" }),
    ui.row({ gap = 8, align = "center" }, thresholdFields),
    ui.row({ gap = 12, align = "center" }, {
      ui.toggle({ checked = alertsDraft, onChange = "onDriveAlertsChanged" }),
      ui.label({ text = noctalia.tr("preferences.alerts"), fontSize = 11, flexGrow = 1 }),
      ui.toggle({ checked = presenceDraft, onChange = "onPresenceAlertsChanged" }),
      ui.label({ text = noctalia.tr("preferences.presence"), fontSize = 11, flexGrow = 1 }),
    }),
    ui.row({ gap = 7, justify = "end" }, {
      ui.button({ text = noctalia.tr("preferences.hide"), variant = "ghost", controlSize = "sm",
        onClick = "onHideDriveClicked" }),
      ui.button({ text = noctalia.tr("self_test.cancel"), variant = "ghost", controlSize = "sm",
        onClick = "onCancelDrivePreferencesClicked" }),
      ui.button({ text = noctalia.tr("preferences.save"), variant = "primary", controlSize = "sm",
        onClick = "onSaveDrivePreferencesClicked" }),
    }),
  })
end

local function driveCard(drive, index)
  local id = driveId(drive)
  local expanded = expandedDriveId == id
  local isHdd = drive.kind == "hdd"
  local healthText, healthColor, healthIcon = healthInfo(drive)
  local temperature = tonumber(drive.temperature_c)
  local hotspot = tonumber(drive.hotspot_temperature_c) or temperature
  local alertTemperature = noctalia.getConfig("use_hotspot_temperature") == false and temperature or hotspot
  local tempColor = temperatureColor(alertTemperature, drive)
  local tempText = hotspot ~= nil and string.format("%.0f °C", hotspot) or noctalia.tr("common.not_available")
  if temperature ~= nil and hotspot ~= nil and hotspot > temperature then
    tempText = noctalia.tr("metrics.hotspot_and_composite", {
      hotspot = string.format("%.0f °C", hotspot),
      composite = string.format("%.0f °C", temperature),
    })
  end
  local life = tonumber(drive.remaining_life_percent)
  local lifeText = formatPercent(life)
  if drive.remaining_life_estimated then
    lifeText = "~" .. lifeText
  end
  local lifeWarning = number(drive.life_warning_percent,
    number(noctalia.getConfig("life_warning_percent"), 20))
  local lifeColor = life ~= nil and (life <= 10 and "error"
    or (life <= lifeWarning and "secondary" or "primary")) or "on_surface_variant"
  local storage = tonumber(drive.storage_usage_percent)
  local storageColor = storage ~= nil and (storage >= 95 and "error" or (storage >= 85 and "secondary" or "primary")) or "on_surface_variant"
  local storageText = storage ~= nil and formatPercent(storage) or noctalia.tr("storage.not_mounted")
  local transport = string.upper(tostring(drive.transport or "unknown"))
  local device = tostring(drive.device or "")

  local details = {
    metric("temperature", noctalia.tr("metrics.temperature"), tempText, tempColor),
    metric(healthIcon, noctalia.tr("metrics.smart_health"), healthText, healthColor),
  }
  local progressRows = {}
  if not isHdd then
    table.insert(progressRows, progressMetric(
      drive.remaining_life_estimated and noctalia.tr("metrics.life_remaining_estimated") or noctalia.tr("metrics.life_remaining"),
      life,
      lifeText,
      lifeColor
    ))
  end
  table.insert(progressRows, progressMetric(noctalia.tr("metrics.storage_used"), storage, storageText, storageColor))

  local ioDetails = {}
  if drive.data_written_bytes ~= nil then
    table.insert(ioDetails, metric("database-export", noctalia.tr("metrics.data_written"), formatBytes(drive.data_written_bytes)))
  end
  if drive.data_read_bytes ~= nil then
    table.insert(ioDetails, metric("database-import", noctalia.tr("metrics.data_read"), formatBytes(drive.data_read_bytes)))
  end

  local wearDetails = {}
  if drive.percentage_used ~= nil then
    table.insert(wearDetails, metric(
      "gauge",
      noctalia.tr("metrics.endurance_used"),
      formatPercent(drive.percentage_used),
      number(drive.percentage_used, 0) >= 90 and "error" or "on_surface"
    ))
  end
  if drive.available_spare_percent ~= nil then
    local spare = number(drive.available_spare_percent, 100)
    local spareThreshold = number(drive.available_spare_threshold_percent, 10)
    table.insert(wearDetails, metric(
      "shield-check",
      noctalia.tr("metrics.available_spare"),
      formatPercent(drive.available_spare_percent),
      spare <= math.max(5, spareThreshold / 2) and "error"
        or (spare <= spareThreshold and "secondary" or "on_surface")
    ))
  end

  local powerDetails = {
    metric("clock", noctalia.tr("metrics.power_on"), formatPowerOn(drive)),
  }

  local thermalDetails = {}
  if type(drive.temperature_sensors_c) == "table" and #drive.temperature_sensors_c > 0 then
    local sensors = {}
    for sensorIndex, sensor in ipairs(drive.temperature_sensors_c) do
      table.insert(sensors, string.format("S%d %.0f°", sensorIndex, number(sensor, 0)))
    end
    table.insert(thermalDetails, metric("temperature-sun", noctalia.tr("metrics.temperature_sensors"),
      table.concat(sensors, "  ·  "), tempColor))
  end
  if drive.device_warning_temperature_c ~= nil or drive.device_critical_temperature_c ~= nil then
    local warningLimit = tonumber(drive.device_warning_temperature_c)
    local criticalLimit = tonumber(drive.device_critical_temperature_c)
    table.insert(thermalDetails, metric("temperature-cog", noctalia.tr("metrics.device_temperature_limits"),
      (warningLimit ~= nil and string.format("%.0f°", warningLimit) or noctalia.tr("common.not_available"))
        .. " / "
        .. (criticalLimit ~= nil and string.format("%.0f°", criticalLimit) or noctalia.tr("common.not_available"))))
  end
  if drive.power_cycles ~= nil then
    table.insert(powerDetails, metric("repeat", noctalia.tr("metrics.power_cycles"), tostring(math.floor(number(drive.power_cycles, 0)))))
  end
  if drive.start_stop_count ~= nil then
    table.insert(powerDetails, metric("player-play", noctalia.tr("metrics.start_stop_count"),
      tostring(math.floor(number(drive.start_stop_count, 0)))))
  end
  if drive.load_cycle_count ~= nil then
    table.insert(powerDetails, metric("refresh", noctalia.tr("metrics.load_cycle_count"),
      tostring(math.floor(number(drive.load_cycle_count, 0)))))
  end

  local errorDetails = {}
  if drive.unsafe_shutdowns ~= nil then
    table.insert(errorDetails, metric(
      "bolt-off",
      noctalia.tr("metrics.unsafe_shutdowns"),
      tostring(math.floor(number(drive.unsafe_shutdowns, 0))),
      number(drive.unsafe_shutdowns, 0) > 0 and "secondary" or "on_surface"
    ))
  end

  if drive.media_errors ~= nil then
    table.insert(errorDetails, metric(
      "alert-circle",
      noctalia.tr("metrics.media_errors"),
      tostring(math.floor(number(drive.media_errors, 0))),
      number(drive.media_errors, 0) > 0 and "error" or "on_surface"
    ))
  end

  local integrityDetails = {}
  if drive.error_log_entries ~= nil and drive.error_log_entries ~= drive.media_errors then
    table.insert(integrityDetails, metric(
      "file-alert",
      noctalia.tr("metrics.error_log_entries"),
      tostring(math.floor(number(drive.error_log_entries, 0))),
      number(drive.error_log_entries, 0) > 0 and "secondary" or "on_surface"
    ))
  end
  if drive.critical_warning ~= nil then
    table.insert(integrityDetails, metric(
      "alert-octagon",
      noctalia.tr("metrics.critical_warning"),
      string.format("0x%02X", math.floor(number(drive.critical_warning, 0))),
      number(drive.critical_warning, 0) > 0 and "error" or "primary"
    ))
  end
  if drive.reallocated_sectors ~= nil then
    table.insert(integrityDetails, metric(
      "replace",
      noctalia.tr("metrics.reallocated"),
      tostring(math.floor(number(drive.reallocated_sectors, 0))),
      number(drive.reallocated_sectors, 0) > 0 and "error" or "primary"
    ))
  end
  if drive.pending_sectors ~= nil then
    table.insert(integrityDetails, metric(
      "hourglass",
      noctalia.tr("metrics.pending"),
      tostring(math.floor(number(drive.pending_sectors, 0))),
      number(drive.pending_sectors, 0) > 0 and "error" or "primary"
    ))
  end
  if drive.uncorrectable_errors ~= nil then
    table.insert(integrityDetails, metric(
      "alert-hexagon",
      noctalia.tr("metrics.uncorrectable"),
      tostring(math.floor(number(drive.uncorrectable_errors, 0))),
      number(drive.uncorrectable_errors, 0) > 0 and "error" or "primary"
    ))
  end
  if drive.spin_retry_count ~= nil then
    table.insert(integrityDetails, metric(
      "repeat",
      noctalia.tr("metrics.spin_retry_count"),
      tostring(math.floor(number(drive.spin_retry_count, 0))),
      number(drive.spin_retry_count, 0) > 0 and "error" or "primary"
    ))
  end
  if drive.command_timeout_count ~= nil then
    table.insert(integrityDetails, metric(
      "clock-exclamation",
      noctalia.tr("metrics.command_timeout_count"),
      tostring(math.floor(number(drive.command_timeout_count, 0))),
      number(drive.command_timeout_count, 0) > 0 and "secondary" or "primary"
    ))
  end
  if drive.interface_crc_errors ~= nil then
    table.insert(integrityDetails, metric(
      "link-off",
      noctalia.tr("metrics.interface_crc_errors"),
      tostring(math.floor(number(drive.interface_crc_errors, 0))),
      number(drive.interface_crc_errors, 0) > 0 and "secondary" or "primary"
    ))
  end

  local identity = {
    ui.label({ text = driveName(drive), fontWeight = "bold", color = "on_surface" }),
    ui.label({
      text = transport .. "  •  " .. formatBytes(drive.capacity_bytes) .. "  •  " .. device,
      fontSize = 11,
      color = "on_surface_variant",
    }),
  }
  local compactMetrics = {
    metric("temperature", isHdd and noctalia.tr("metrics.temperature") or noctalia.tr("metrics.hotspot_temperature"),
      tempText, tempColor),
    isHdd and metric("clock", noctalia.tr("metrics.power_on"), formatPowerOn(drive))
      or metric("battery-vertical", noctalia.tr("metrics.life_remaining"), lifeText, lifeColor),
    metric(healthIcon, noctalia.tr("metrics.smart_health"), healthText, healthColor),
  }

  local children = {
    ui.row({ gap = 10, align = "center" }, {
      ui.column({ width = 36, height = 36, radius = 10, fill = tempColor .. "/0.16", align = "center", justify = "center" }, {
        ui.glyph({ name = drive.kind == "ssd" and "server" or "disc", size = 19, color = tempColor }),
      }),
      ui.column({ gap = 2, flexGrow = 1 }, identity),
      ui.row({ fill = healthColor .. "/0.16", radius = 8, paddingH = 8, paddingV = 4, align = "center", gap = 4 }, {
        ui.glyph({ name = healthIcon, size = 12, color = healthColor }),
        ui.label({ text = healthText, fontSize = 11, fontWeight = "bold", color = healthColor }),
      }),
      ui.button({
        glyph = expanded and "chevron-up" or "chevron-down", variant = "ghost", controlSize = "sm",
        tooltip = noctalia.tr(expanded and "panel.collapse" or "panel.expand"),
        enabled = index <= 32, onClick = "onDrive" .. tostring(index) .. "Clicked",
      }),
    }),
    ui.row({ gap = 14, align = "center" }, compactMetrics),
  }

  if expanded then
    if drive.serial ~= nil and drive.serial ~= "" then
      table.insert(children, ui.label({
        text = noctalia.tr("metrics.serial", { value = tostring(drive.serial) }),
        fontSize = 10, color = "on_surface_variant/0.78", maxLines = 1,
      }))
    end
    if type(drive.mount_points) == "table" and #drive.mount_points > 0 then
      table.insert(children, ui.label({
        text = noctalia.tr("metrics.mounted_at", { paths = table.concat(drive.mount_points, "  ·  ") }),
        fontSize = 10, color = "primary/0.88", maxLines = 2,
      }))
    end
    table.insert(children, ui.row({ gap = 16, align = "center" }, details))
    table.insert(children, ui.row({ gap = 16, align = "center" }, progressRows))
    appendMetricRows(children, wearDetails)
    appendMetricRows(children, ioDetails)
    appendMetricRows(children, powerDetails)
    appendMetricRows(children, thermalDetails)
    appendMetricRows(children, errorDetails)
    appendMetricRows(children, integrityDetails)
    local trends = trendCard(drive)
    if trends ~= nil then
      table.insert(children, trends)
    end
    table.insert(children, selfTestCard(drive))
    table.insert(children, ui.row({ gap = 7, justify = "end" }, {
      ui.button({ text = noctalia.tr("preferences.edit"), glyph = "settings", variant = "ghost",
        controlSize = "sm", onClick = "onEditExpandedDriveClicked" }),
    }))
  end

  if drive.smart_sleeping then
    table.insert(children, ui.row({ gap = 7, align = "center", fill = "primary/0.08", radius = 8, padding = 8 }, {
      ui.glyph({ name = "moon", size = 13, color = "primary" }),
      ui.label({ text = noctalia.tr("smart.sleeping"), fontSize = 11, color = "on_surface_variant", flexGrow = 1 }),
    }))
  elseif not drive.smart_available then
    table.insert(children, ui.row({ gap = 7, align = "center", fill = "secondary/0.12", radius = 8, padding = 8 }, {
      ui.glyph({ name = "info-circle", size = 13, color = "secondary" }),
      ui.label({ text = noctalia.tr("smart.access_limited"), fontSize = 11, color = "on_surface_variant", flexGrow = 1 }),
    }))
  end

  if expanded and drive.smart_completeness == "partial" then
    table.insert(children, ui.row({ gap = 7, align = "center", fill = "secondary/0.12", radius = 8, padding = 8 }, {
      ui.glyph({ name = "file-alert", size = 13, color = "secondary" }),
      ui.label({ text = noctalia.tr("smart.partial_details"), fontSize = 11, color = "on_surface_variant", flexGrow = 1 }),
    }))
    for _, message in ipairs(drive.smart_messages or {}) do
      table.insert(children, ui.label({ text = "• " .. tostring(message.message or message),
        fontSize = 10, color = "on_surface_variant", maxLines = 3 }))
    end
  end
  if expanded and editingDriveId == id then
    table.insert(children, preferenceEditor(drive))
  end

  return ui.column({
    key = tostring(drive.id or device),
    gap = 12,
    padding = 14,
    radius = 14,
    fill = "surface_variant/0.34",
    border = "outline/0.38",
    borderWidth = 1,
    align = "stretch",
  }, children)
end

local function visibleDrives()
  local drives = {}
  local showHdd = noctalia.getConfig("show_hdd") ~= false
  if snapshot ~= nil and type(snapshot.disks) == "table" then
    for _, drive in ipairs(snapshot.disks) do
      if (drive.kind == "ssd" or showHdd) and drive.hidden ~= true then
        table.insert(drives, drive)
      end
    end
  end
  return drives
end

local function hiddenDrivesCard()
  local hidden = {}
  if snapshot ~= nil and type(snapshot.disks) == "table" then
    for _, drive in ipairs(snapshot.disks) do
      if drive.hidden == true then
        table.insert(hidden, drive)
      end
    end
  end
  if #hidden == 0 then
    return nil
  end
  hiddenSelection = math.max(1, math.min(hiddenSelection, #hidden))
  local options = {}
  for _, drive in ipairs(hidden) do
    table.insert(options, driveName(drive))
  end
  return ui.column({ gap = 7, padding = 10, radius = 9, fill = "surface_variant/0.22" }, {
    ui.label({ text = noctalia.tr("preferences.hidden_drives"), fontWeight = "bold", fontSize = 11 }),
    ui.row({ gap = 7, align = "center" }, {
      ui.select({ options = options, selectedIndex = hiddenSelection - 1, controlSize = "sm",
        flexGrow = 1, onChange = "onHiddenDriveSelected" }),
      ui.button({ text = noctalia.tr("preferences.restore"), variant = "outline", controlSize = "sm",
        onClick = "onRestoreHiddenDriveClicked" }),
    }),
  })
end

local function render()
  if not opened then
    return
  end

  local summary = snapshot and snapshot.summary or {}
  local drives = visibleDrives()
  currentDrives = drives
  currentIssues = type(snapshot and snapshot.issues) == "table" and snapshot.issues or {}
  local includeHdd = noctalia.getConfig("show_hdd") ~= false
  local hottest = tonumber(includeHdd and summary.hottest_drive_temperature_c or summary.hottest_ssd_temperature_c)
  local hottestDriveName = includeHdd and summary.hottest_drive_name or summary.hottest_ssd_drive_name
  local remaining = tonumber(summary.worst_ssd_remaining_life_percent)
  local lowestLifeDriveName = summary.worst_ssd_life_drive_name
  local ssdCount = number(summary.ssd_count, 0)
  local hddCount = includeHdd and number(summary.hdd_count, 0) or 0
  local driveCount = ssdCount + hddCount
  local smartAvailable = includeHdd and number(summary.smart_available_count,
      number(summary.ssd_smart_available_count, 0) + number(summary.hdd_smart_available_count, 0))
    or number(summary.ssd_smart_available_count, 0)
  local headerStatus = snapshot and snapshot.collecting and noctalia.tr("panel.refreshing") or noctalia.tr("panel.updated", {
    time = tostring(snapshot and snapshot.generated_at_local or noctalia.tr("common.never")),
  })

  local body = {}
  if snapshot == nil then
    table.insert(body, ui.column({ gap = 10, align = "center", justify = "center", flexGrow = 1 }, {
      ui.glyph({ name = "server-off", size = 36, color = "on_surface_variant" }),
      ui.label({ text = noctalia.tr("panel.waiting"), color = "on_surface_variant" }),
    }))
  else
    local dependencyStatus = dependencyCard(snapshot.dependencies)
    if dependencyStatus ~= nil then
      table.insert(body, dependencyStatus)
    end
    local collectorStatus = collectorCard(snapshot.system_collector)
    if collectorStatus ~= nil then
      table.insert(body, collectorStatus)
    end
    local collectorSettings = collectorSettingsCard(snapshot.system_collector)
    if collectorSettings ~= nil then
      table.insert(body, collectorSettings)
    end

    local hottestColor = temperatureColor(hottest)
    local summaryCards = {
      summaryCard(tostring(driveCount), noctalia.tr("summary.drives"),
        noctalia.tr("summary.drive_mix", { ssds = ssdCount, hdds = hddCount }), "primary"),
      summaryCard(hottest ~= nil and string.format("%.0f °C", hottest) or "-- °C",
        noctalia.tr("summary.hottest"), hottestDriveName, hottestColor),
    }
    if ssdCount > 0 then
      table.insert(summaryCards, summaryCard(formatPercent(remaining),
        noctalia.tr("summary.lowest_ssd_life"), lowestLifeDriveName, "secondary"))
    end
    table.insert(body, ui.row({ gap = 10, align = "stretch" }, summaryCards))

    local alerts = alertsCard(currentIssues)
    if alerts ~= nil then
      table.insert(body, alerts)
    end

    local sleeping = number(summary.sleeping_count, 0)
    if smartAvailable + sleeping < driveCount then
      table.insert(body, ui.row({ gap = 8, padding = 10, radius = 10, fill = "secondary/0.12", align = "center" }, {
        ui.glyph({ name = "shield-lock", size = 16, color = "secondary" }),
        ui.column({ gap = 2, flexGrow = 1 }, {
          ui.label({ text = noctalia.tr("smart.partial_title"), fontWeight = "bold", color = "secondary" }),
          ui.label({ text = noctalia.tr("smart.partial_body", { available = smartAvailable,
            total = driveCount - sleeping }), fontSize = 11, color = "on_surface_variant" }),
        }),
      }))
    end

    if snapshot.collector_error ~= nil and snapshot.collector_error ~= "" then
      table.insert(body, ui.label({ text = tostring(snapshot.collector_error), color = "error", fontSize = 11 }))
    end

    if #drives == 0 then
      table.insert(body, ui.label({ text = noctalia.tr("panel.no_drives"), color = "on_surface_variant" }))
    else
      for index, drive in ipairs(drives) do
        table.insert(body, driveCard(drive, index))
      end
    end
    local hiddenStatus = hiddenDrivesCard()
    if hiddenStatus ~= nil then
      table.insert(body, hiddenStatus)
    end
  end

  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
    ui.row({ align = "center", gap = 10 }, {
      ui.column({ width = 38, height = 38, radius = 11, fill = "primary/0.16", align = "center", justify = "center" }, {
        ui.glyph({ name = "server-2", size = 20, color = "primary" }),
      }),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = noctalia.tr("panel.title"), fontSize = 17, fontWeight = "bold", color = "on_surface" }),
        ui.label({ text = headerStatus, fontSize = 11, color = "on_surface_variant" }),
      }),
      ui.button({ glyph = "settings", variant = showCollectorSettings and "primary" or "ghost",
        tooltip = noctalia.tr("collector.settings_title"), onClick = "onToggleCollectorSettingsClicked" }),
      ui.button({ glyph = "refresh", variant = "ghost", onClick = "onRefreshClicked" }),
      ui.button({ glyph = "x", variant = "ghost", onClick = "onCloseClicked" }),
    }),
    ui.scroll({ flexGrow = 1, gap = 12 }, body),
  }))
end

local function selfTestSignature(drive)
  if drive == nil then return "" end
  return table.concat({
    tostring(drive.self_test_state or ""),
    tostring(drive.self_test_status or ""),
    tostring(drive.self_test_lifetime_hours or ""),
    tostring(drive.self_test_error_count or ""),
  }, "|")
end

local function reconcileSelfTestLaunch(value)
  if selfTestLaunch == nil or selfTestLaunch.state == "authorizing" or selfTestLaunch.state == "failed" then
    return
  end
  local drive = nil
  for _, candidate in ipairs(value and value.disks or {}) do
    if driveId(candidate) == selfTestLaunch.drive_id then
      drive = candidate
      break
    end
  end
  if drive == nil then return end
  if tostring(drive.self_test_state) == "running" then
    selfTestLaunch.observed_running = true
    return
  end
  local generated = number(value and value.generated_at_epoch, 0)
  local changed = generated > number(selfTestLaunch.accepted_snapshot_epoch, 0)
    and selfTestSignature(drive) ~= tostring(selfTestLaunch.baseline_signature or "")
  local expired = os.time() - number(selfTestLaunch.accepted_at, os.time()) >= 180
  if selfTestLaunch.observed_running or changed or expired then
    selfTestLaunch = nil
  end
end

noctalia.state.watch("snapshot", function(value)
  snapshot = value
  reconcileSelfTestLaunch(value)
  render()
end)

noctalia.state.watch("drive_history", function(value)
  history = type(value) == "table" and value or { drives = {} }
  render()
end)

noctalia.state.watch("drive_preferences", function(value)
  if type(value) == "table" then
    preferences = value
  end
  render()
end)

local function toggleDriveAt(index)
  local drive = currentDrives[index]
  if drive == nil then
    return
  end
  local id = driveId(drive)
  if expandedDriveId == id then
    expandedDriveId = nil
    editingDriveId = nil
    pendingSelfTest = nil
  else
    expandedDriveId = id
  end
  render()
end

function onDrive1Clicked() toggleDriveAt(1) end
function onDrive2Clicked() toggleDriveAt(2) end
function onDrive3Clicked() toggleDriveAt(3) end
function onDrive4Clicked() toggleDriveAt(4) end
function onDrive5Clicked() toggleDriveAt(5) end
function onDrive6Clicked() toggleDriveAt(6) end
function onDrive7Clicked() toggleDriveAt(7) end
function onDrive8Clicked() toggleDriveAt(8) end
function onDrive9Clicked() toggleDriveAt(9) end
function onDrive10Clicked() toggleDriveAt(10) end
function onDrive11Clicked() toggleDriveAt(11) end
function onDrive12Clicked() toggleDriveAt(12) end
function onDrive13Clicked() toggleDriveAt(13) end
function onDrive14Clicked() toggleDriveAt(14) end
function onDrive15Clicked() toggleDriveAt(15) end
function onDrive16Clicked() toggleDriveAt(16) end
function onDrive17Clicked() toggleDriveAt(17) end
function onDrive18Clicked() toggleDriveAt(18) end
function onDrive19Clicked() toggleDriveAt(19) end
function onDrive20Clicked() toggleDriveAt(20) end
function onDrive21Clicked() toggleDriveAt(21) end
function onDrive22Clicked() toggleDriveAt(22) end
function onDrive23Clicked() toggleDriveAt(23) end
function onDrive24Clicked() toggleDriveAt(24) end
function onDrive25Clicked() toggleDriveAt(25) end
function onDrive26Clicked() toggleDriveAt(26) end
function onDrive27Clicked() toggleDriveAt(27) end
function onDrive28Clicked() toggleDriveAt(28) end
function onDrive29Clicked() toggleDriveAt(29) end
function onDrive30Clicked() toggleDriveAt(30) end
function onDrive31Clicked() toggleDriveAt(31) end
function onDrive32Clicked() toggleDriveAt(32) end

local function sendDismissRequest(request)
  dismissRequestNonce += 1
  request.nonce = dismissRequestNonce
  noctalia.state.set("dismiss_alert_request", request)
end

local function dismissAlertAt(index)
  local issue = currentIssues[index]
  if issue ~= nil and issue.id ~= nil then
    sendDismissRequest({ id = tostring(issue.id) })
  end
end

function onDismissAlert1Clicked() dismissAlertAt(1) end
function onDismissAlert2Clicked() dismissAlertAt(2) end
function onDismissAlert3Clicked() dismissAlertAt(3) end
function onDismissAlert4Clicked() dismissAlertAt(4) end
function onDismissAlert5Clicked() dismissAlertAt(5) end
function onDismissAlert6Clicked() dismissAlertAt(6) end
function onDismissAlert7Clicked() dismissAlertAt(7) end
function onDismissAlert8Clicked() dismissAlertAt(8) end
function onDismissAlert9Clicked() dismissAlertAt(9) end
function onDismissAlert10Clicked() dismissAlertAt(10) end
function onDismissAlert11Clicked() dismissAlertAt(11) end
function onDismissAlert12Clicked() dismissAlertAt(12) end
function onDismissAlert13Clicked() dismissAlertAt(13) end
function onDismissAlert14Clicked() dismissAlertAt(14) end
function onDismissAlert15Clicked() dismissAlertAt(15) end
function onDismissAlert16Clicked() dismissAlertAt(16) end
function onDismissAlert17Clicked() dismissAlertAt(17) end
function onDismissAlert18Clicked() dismissAlertAt(18) end
function onDismissAlert19Clicked() dismissAlertAt(19) end
function onDismissAlert20Clicked() dismissAlertAt(20) end
function onDismissAlert21Clicked() dismissAlertAt(21) end
function onDismissAlert22Clicked() dismissAlertAt(22) end
function onDismissAlert23Clicked() dismissAlertAt(23) end
function onDismissAlert24Clicked() dismissAlertAt(24) end
function onDismissAlert25Clicked() dismissAlertAt(25) end
function onDismissAlert26Clicked() dismissAlertAt(26) end
function onDismissAlert27Clicked() dismissAlertAt(27) end
function onDismissAlert28Clicked() dismissAlertAt(28) end
function onDismissAlert29Clicked() dismissAlertAt(29) end
function onDismissAlert30Clicked() dismissAlertAt(30) end
function onDismissAlert31Clicked() dismissAlertAt(31) end
function onDismissAlert32Clicked() dismissAlertAt(32) end

function onDismissAllAlertsClicked()
  if #currentIssues > 0 then
    sendDismissRequest({ all = true })
  end
end

local function expandedDrive()
  for _, drive in ipairs(currentDrives) do
    if driveId(drive) == expandedDriveId then
      return drive
    end
  end
  return nil
end

local function setPreferenceDrafts(drive)
  local entry = preferenceFor(driveId(drive))
  aliasDraft = tostring(entry.alias or "")
  warningDraft = entry.warning_temperature ~= nil and tostring(entry.warning_temperature) or ""
  criticalDraft = entry.critical_temperature ~= nil and tostring(entry.critical_temperature) or ""
  lifeDraft = entry.life_warning_percent ~= nil and tostring(entry.life_warning_percent) or ""
  alertsDraft = entry.alerts_enabled ~= false
  presenceDraft = entry.presence_alert_enabled == nil and drive.presence_alert_enabled == true
    or entry.presence_alert_enabled == true
end

function onEditExpandedDriveClicked()
  local drive = expandedDrive()
  if drive == nil then return end
  editingDriveId = driveId(drive)
  setPreferenceDrafts(drive)
  render()
end

function onAliasChanged(value) aliasDraft = tostring(value or "") end
function onWarningThresholdChanged(value) warningDraft = tostring(value or "") end
function onCriticalThresholdChanged(value) criticalDraft = tostring(value or "") end
function onLifeThresholdChanged(value) lifeDraft = tostring(value or "") end

function onDriveAlertsChanged(value)
  if editingDriveId ~= nil then
    alertsDraft = value == true or tostring(value) == "true"
    render()
  end
end

function onPresenceAlertsChanged(value)
  if editingDriveId ~= nil then
    presenceDraft = value == true or tostring(value) == "true"
    render()
  end
end

local function optionalThreshold(value, minimum, maximum)
  local trimmed = noctalia.string.trim(tostring(value or ""))
  if trimmed == "" then return nil end
  local parsed = tonumber(trimmed)
  if parsed == nil then return false end
  return clamp(parsed, minimum, maximum)
end

function onSaveDrivePreferencesClicked()
  if editingDriveId == nil then return end
  local warning = optionalThreshold(warningDraft, 30, 100)
  local critical = optionalThreshold(criticalDraft, 31, 110)
  local life = optionalThreshold(lifeDraft, 1, 100)
  if warning == false or critical == false or life == false or (warning ~= nil and critical ~= nil and critical <= warning) then
    noctalia.notifyError(noctalia.tr("preferences.title"), noctalia.tr("preferences.invalid_thresholds"))
    return
  end
  local entry = preferenceFor(editingDriveId)
  local previous = {}
  for _, key in ipairs(EDITABLE_PREFERENCE_FIELDS) do previous[key] = entry[key] end
  entry.alias = noctalia.string.trim(aliasDraft)
  entry.warning_temperature = warning
  entry.critical_temperature = critical
  entry.life_warning_percent = life
  entry.alerts_enabled = alertsDraft
  entry.presence_alert_enabled = presenceDraft
  if savePreferences() then
    editingDriveId = nil
    noctalia.notify(noctalia.tr("preferences.title"), noctalia.tr("preferences.saved"))
  else
    for _, key in ipairs(EDITABLE_PREFERENCE_FIELDS) do entry[key] = previous[key] end
  end
  render()
end

function onCancelDrivePreferencesClicked()
  editingDriveId = nil
  render()
end

local function ensureOrder()
  preferences.order = type(preferences.order) == "table" and preferences.order or {}
  local seen = {}
  for _, id in ipairs(preferences.order) do seen[tostring(id)] = true end
  for _, drive in ipairs(snapshot and snapshot.disks or {}) do
    local id = driveId(drive)
    if not seen[id] then
      table.insert(preferences.order, id)
      seen[id] = true
    end
  end
end

local function moveEditingDrive(delta)
  if editingDriveId == nil then return end
  ensureOrder()
  for index, id in ipairs(preferences.order) do
    if tostring(id) == editingDriveId then
      local destination = math.max(1, math.min(#preferences.order, index + delta))
      preferences.order[index], preferences.order[destination] = preferences.order[destination], preferences.order[index]
      if not savePreferences() then
        preferences.order[index], preferences.order[destination] = preferences.order[destination], preferences.order[index]
        render()
      end
      return
    end
  end
end

function onMoveDriveUpClicked() moveEditingDrive(-1) end
function onMoveDriveDownClicked() moveEditingDrive(1) end

function onHideDriveClicked()
  if editingDriveId == nil then return end
  local entry = preferenceFor(editingDriveId)
  local previous = entry.hidden
  entry.hidden = true
  if savePreferences() then
    editingDriveId = nil
    expandedDriveId = nil
  else
    entry.hidden = previous
  end
  render()
end

function onHiddenDriveSelected(value)
  hiddenSelection = math.max(1, (tonumber(value) or 0) + 1)
end

function onRestoreHiddenDriveClicked()
  local hidden = {}
  for _, drive in ipairs(snapshot and snapshot.disks or {}) do
    if drive.hidden == true then table.insert(hidden, drive) end
  end
  local drive = hidden[hiddenSelection]
  if drive ~= nil then
    local entry = preferenceFor(driveId(drive))
    local previous = entry.hidden
    entry.hidden = false
    if savePreferences() then
      hiddenSelection = 1
    else
      entry.hidden = previous
    end
    render()
  end
end

function onStartShortSelfTestClicked()
  local drive = expandedDrive()
  if drive ~= nil then
    if selfTestLaunch ~= nil and selfTestLaunch.drive_id == driveId(drive) and selfTestLaunch.state == "failed" then
      selfTestLaunch = nil
    end
    pendingSelfTest = { drive_id = driveId(drive), kind = "short", device = drive.smart_device or drive.device }
    render()
  end
end

function onStartLongSelfTestClicked()
  local drive = expandedDrive()
  if drive ~= nil then
    if selfTestLaunch ~= nil and selfTestLaunch.drive_id == driveId(drive) and selfTestLaunch.state == "failed" then
      selfTestLaunch = nil
    end
    pendingSelfTest = { drive_id = driveId(drive), kind = "long", device = drive.smart_device or drive.device }
    render()
  end
end

function onCancelSelfTestClicked()
  pendingSelfTest = nil
  render()
end

local function selfTestError(result)
  if result.timedOut == true then
    return noctalia.tr("self_test.authorization_timeout")
  end
  if tonumber(result.exitCode) == 126 then
    return noctalia.tr("self_test.authorization_cancelled")
  end
  local detail = noctalia.string.trim(tostring(result.stderr or ""))
  if detail == "" then detail = noctalia.string.trim(tostring(result.stdout or "")) end
  if #detail > 240 then detail = detail:sub(1, 237) .. "..." end
  return detail ~= "" and detail or noctalia.tr("self_test.launch_failed")
end

function onConfirmSelfTestClicked()
  if pendingSelfTest == nil then return end
  local request = pendingSelfTest
  pendingSelfTest = nil
  local drive = expandedDrive()
  selfTestLaunch = {
    drive_id = request.drive_id,
    kind = request.kind,
    state = "authorizing",
    baseline_signature = selfTestSignature(drive),
  }
  render()
  local command = "pkexec /usr/local/libexec/noctalia-gustav0ar-drive-health/smart-action.sh "
    .. shellQuote(request.kind) .. " " .. shellQuote(request.device)
  local launched = noctalia.runAsync(command, function(result)
    if selfTestLaunch == nil or selfTestLaunch.drive_id ~= request.drive_id then return end
    local exitCode = tonumber(result.exitCode)
    -- smartctl bits 3-7 report existing drive-health findings, not whether the
    -- self-test command was accepted. Bits 0-2 are the command/device failures.
    local accepted = result.timedOut ~= true and exitCode ~= nil and exitCode >= 0 and exitCode % 8 == 0
    if accepted then
      selfTestLaunch.state = "starting"
      selfTestLaunch.accepted_at = os.time()
      selfTestLaunch.accepted_snapshot_epoch = number(snapshot and snapshot.generated_at_epoch, 0)
      noctalia.notify(noctalia.tr("self_test.title"), noctalia.tr("self_test.started_background"))
      local nonce = number(noctalia.state.get("refresh_nonce"), 0) + 1
      noctalia.state.set("refresh_nonce", nonce)
    else
      selfTestLaunch.state = "failed"
      selfTestLaunch.error = selfTestError(result)
      noctalia.notifyError(noctalia.tr("self_test.title"), selfTestLaunch.error)
    end
    render()
  end, 120000)
  if not launched then
    selfTestLaunch.state = "failed"
    selfTestLaunch.error = noctalia.tr("self_test.launch_failed")
    noctalia.notifyError(noctalia.tr("self_test.title"), selfTestLaunch.error)
    render()
  end
end

function onInstallCollectorClicked()
  local command = snapshot and snapshot.system_collector and snapshot.system_collector.install_command or nil
  if command == nil or command == "" then return end
  if noctalia.runInTerminal(command) then
    noctalia.notify(noctalia.tr("collector.title"), noctalia.tr("collector.terminal_opened"))
  end
end

function onStartCollectorClicked()
  local command = snapshot and snapshot.system_collector and snapshot.system_collector.enable_command or nil
  if command == nil or command == "" then return end
  if noctalia.runInTerminal(command) then
    noctalia.notify(noctalia.tr("collector.title"), noctalia.tr("collector.start_terminal_opened"))
  end
end

function onPauseCollectorClicked()
  local command = snapshot and snapshot.system_collector and snapshot.system_collector.disable_command or nil
  if command == nil or command == "" then return end
  if noctalia.runInTerminal(command) then
    noctalia.notify(noctalia.tr("collector.title"), noctalia.tr("collector.pause_terminal_opened"))
  end
end

function onToggleCollectorSettingsClicked()
  showCollectorSettings = not showCollectorSettings
  confirmUninstall = false
  render()
end

function onOpenPluginSettingsClicked()
  panel.close()
  noctalia.runAsync("noctalia msg settings-open plugins", function(_result) end, 5000)
  noctalia.notify(noctalia.tr("collector.settings_title"), noctalia.tr("collector.settings_opened"))
end

function onCopyCollectorCommandClicked()
  local collector = snapshot and snapshot.system_collector or nil
  local command = collector and collector.status == "stale" and collector.enable_command
    or (collector and collector.install_command or nil)
  if command ~= nil and noctalia.copyToClipboard(command, "text/plain") then
    noctalia.notify(noctalia.tr("collector.title"), noctalia.tr("dependencies.copied"))
  end
end

function onUninstallCollectorClicked()
  if not confirmUninstall then
    confirmUninstall = true
    render()
    return
  end
  local command = snapshot and snapshot.system_collector and snapshot.system_collector.uninstall_command or nil
  if command ~= nil and noctalia.runInTerminal(command) then
    noctalia.notify(noctalia.tr("collector.title"), noctalia.tr("collector.uninstall_terminal_opened"))
  end
  confirmUninstall = false
  render()
end

function onOpen(_context)
  opened = true
  render()
end

function onClose()
  opened = false
  pendingSelfTest = nil
  confirmUninstall = false
  showCollectorSettings = false
end

function onRefreshClicked()
  local nonce = number(noctalia.state.get("refresh_nonce"), 0) + 1
  noctalia.state.set("refresh_nonce", nonce)
end

function onInstallDependenciesClicked()
  local dependencies = snapshot and snapshot.dependencies or nil
  local command = dependencies and dependencies.install_command or nil
  if command == nil or command == "" then
    noctalia.notifyError(noctalia.tr("dependencies.title"), noctalia.tr("dependencies.manual_install"))
    return
  end

  noctalia.notify(noctalia.tr("dependencies.install_title"), noctalia.tr("dependencies.install_body"))
  noctalia.runInTerminal(command)
end

function onCopyInstallCommandClicked()
  local dependencies = snapshot and snapshot.dependencies or nil
  local command = dependencies and dependencies.install_command or nil
  if command == nil or command == "" then
    return
  end
  if noctalia.copyToClipboard(command, "text/plain") then
    noctalia.notify(noctalia.tr("dependencies.title"), noctalia.tr("dependencies.copied"))
  end
end

function onCloseClicked()
  panel.close()
end
