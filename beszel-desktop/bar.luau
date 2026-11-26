--!nonstrict
-- Beszel Desktop bar widget.
-- Supports multiple independent host instances via per-widget `system` setting,
-- per-widget metric toggles (CPU, memory, GPU, temp, disk, split/combined network),
-- monochrome icons in normal state (colored only on warning/danger), and
-- scroll-to-switch when unpinned.

local fmt = require("./lib/format.luau")

local PANEL_ID = "henriksvensson/beszel-desktop:panel"
local STATE_KEY = "beszel.data"
local SELECTED_HOST_KEY = "beszel.selected_host"

local data = noctalia.state.get(STATE_KEY)
local sessionHostId = nil

noctalia.setUpdateInterval(1000)

local function resolveDisplayedSystem(systems, filter)
  if sessionHostId ~= nil then
    local overridden = fmt.findSystemById(systems, sessionHostId)
    if overridden ~= nil then
      return overridden
    end
    sessionHostId = nil
  end
  return fmt.findSystem(systems, filter)
end

local function metricColor(state, statusColor, pct, warnPct, dangerPct)
  if state ~= "connected" then
    return statusColor
  end
  return fmt.severityColor(pct, "on_surface", warnPct, dangerPct)
end

local function buildTooltip(sys, latest, state, filter)
  local rows = {}
  if sys ~= nil then
    table.insert(rows, { key = noctalia.tr("tooltip.host"), value = sys.name })
    local osLabel = fmt.cleanOsName(sys.os_name)
    if osLabel ~= nil then
      table.insert(rows, { key = noctalia.tr("tooltip.os"), value = osLabel })
    end
  end
  if latest ~= nil then
    table.insert(rows, {
      key = noctalia.tr("tooltip.cpu"),
      value = string.format("%.1f%%", tonumber(latest.cpu_pct) or 0),
    })

    local memText
    if latest.mem_used_bytes ~= nil and latest.mem_total_bytes ~= nil then
      memText = string.format(
        "%.0f%% (%s)",
        tonumber(latest.mem_pct) or 0,
        fmt.formatGiBCompact(latest.mem_used_bytes, latest.mem_total_bytes)
      )
    else
      memText = string.format("%.1f%%", tonumber(latest.mem_pct) or 0)
    end
    table.insert(rows, { key = noctalia.tr("tooltip.memory"), value = memText })

    local swapUsed = tonumber(latest.swap_used_bytes) or 0
    if swapUsed > 0 and latest.swap_total_bytes ~= nil then
      table.insert(rows, {
        key = noctalia.tr("tooltip.swap"),
        value = string.format(
          "%s / %s GiB",
          fmt.formatGiB(swapUsed),
          fmt.formatGiB(latest.swap_total_bytes)
        ),
      })
    end

    local gpu = fmt.primaryGpu(latest)
    if gpu ~= nil then
      local gpuParts = { string.format("%.0f%%", tonumber(gpu.usage_pct) or 0) }
      if gpu.mem_used_mb ~= nil and gpu.mem_total_mb ~= nil then
        table.insert(
          gpuParts,
          string.format("%s / %s", fmt.formatMb(gpu.mem_used_mb), fmt.formatMb(gpu.mem_total_mb))
        )
      end
      if gpu.power_w ~= nil then
        table.insert(gpuParts, string.format("%.0fW", tonumber(gpu.power_w) or 0))
      end
      table.insert(rows, {
        key = noctalia.tr("tooltip.gpu"),
        value = table.concat(gpuParts, " · "),
      })
    end

    if latest.temp_max_c ~= nil then
      table.insert(rows, {
        key = noctalia.tr("tooltip.temp"),
        value = fmt.formatTemp(latest.temp_max_c),
      })
    end

    if latest.disk_pct ~= nil then
      local diskText = string.format("%.0f%%", tonumber(latest.disk_pct) or 0)
      if latest.disk_used_gb ~= nil and latest.disk_total_gb ~= nil then
        diskText = string.format(
          "%s (%.0f / %.0f GiB)",
          diskText,
          tonumber(latest.disk_used_gb) or 0,
          tonumber(latest.disk_total_gb) or 0
        )
      end
      table.insert(rows, { key = noctalia.tr("tooltip.disk"), value = diskText })
    end

    if fmt.hasNetwork(latest) then
      table.insert(rows, {
        key = noctalia.tr("tooltip.network"),
        value = string.format(
          "↓ %s  ↑ %s",
          fmt.formatRate(latest.net_recv_bps or 0),
          fmt.formatRate(latest.net_sent_bps or 0)
        ),
      })
    end

    if latest.uptime_secs ~= nil then
      table.insert(rows, {
        key = noctalia.tr("tooltip.uptime"),
        value = fmt.formatUptime(latest.uptime_secs),
      })
    end

    local failedServices = tonumber(latest.failed_services) or 0
    if failedServices > 0 then
      table.insert(rows, {
        key = noctalia.tr("tooltip.services"),
        value = noctalia.tr("panel.failed_services", { count = tostring(failedServices) }),
      })
    end

    local updatesTotal = tonumber(latest.updates_total) or 0
    if updatesTotal > 0 then
      local updatesSec = tonumber(latest.updates_security) or 0
      local updText = updatesSec > 0
        and noctalia.tr("panel.updates_security_short", {
          total = tostring(updatesTotal),
          security = tostring(updatesSec),
        })
        or noctalia.tr("panel.updates_short", { total = tostring(updatesTotal) })
      table.insert(rows, { key = noctalia.tr("tooltip.updates"), value = updText })
    end
  end
  table.insert(rows, { key = noctalia.tr("tooltip.status"), value = fmt.stateLabel(state, filter) })
  return rows
end

local function barPill(glyphName, text, width, color)
  return ui.row({ gap = 3, align = "center" }, {
    ui.glyph({ name = glyphName, size = 14, color = color }),
    ui.label({
      text = text,
      width = width,
      maxWidth = width,
      textAlign = "end",
      color = color,
      maxLines = 1,
    }),
  })
end

local function appendNetworkItems(items, latest, networkMode, color)
  if networkMode == "off" or not fmt.hasNetwork(latest) then
    return
  end
  local recv = tonumber(latest.net_recv_bps) or 0
  local sent = tonumber(latest.net_sent_bps) or 0

  if networkMode == "split" then
    table.insert(items, ui.row({ gap = 5, align = "center" }, {
      barPill("arrow-down", fmt.formatCompactRate(recv), 48, color),
      barPill("arrow-up", fmt.formatCompactRate(sent), 48, color),
    }))
  elseif networkMode == "combined" then
    table.insert(items, barPill("arrows-up-down", fmt.formatCompactRate(recv + sent), 48, color))
  elseif networkMode == "download" then
    table.insert(items, barPill("arrow-down", fmt.formatCompactRate(recv), 48, color))
  elseif networkMode == "upload" then
    table.insert(items, barPill("arrow-up", fmt.formatCompactRate(sent), 48, color))
  end
end

local function renderVertical(latest, state, statusColor, warnPct, dangerPct, opts)
  local rows = {}
  local baseColor = state == "connected" and "on_surface" or statusColor
  local mutedColor = state == "connected" and "on_surface_variant" or statusColor

  if opts.showCpu then
    local pct = tonumber(latest.cpu_pct) or 0
    table.insert(rows, ui.label({
      text = fmt.padPercent(pct),
      color = metricColor(state, statusColor, pct, warnPct, dangerPct),
      fontWeight = "medium",
      maxLines = 1,
    }))
  end
  if opts.showMem then
    local pct = tonumber(latest.mem_pct) or 0
    table.insert(rows, ui.label({
      text = fmt.padPercent(pct),
      color = state == "connected"
        and fmt.severityColor(pct, "on_surface_variant", warnPct, dangerPct)
        or statusColor,
      maxLines = 1,
    }))
  end
  if opts.showGpu then
    local gpu = fmt.primaryGpu(latest)
    if gpu ~= nil then
      local pct = tonumber(gpu.usage_pct) or 0
      table.insert(rows, ui.label({
        text = fmt.padPercent(pct),
        color = metricColor(state, statusColor, pct, warnPct, dangerPct),
        maxLines = 1,
      }))
    end
  end
  if opts.showTemp and latest.temp_max_c ~= nil then
    table.insert(rows, ui.label({
      text = fmt.formatTemp(latest.temp_max_c),
      color = state == "connected"
        and fmt.tempSeverityColor(latest.temp_max_c, "on_surface_variant")
        or statusColor,
      maxLines = 1,
    }))
  end
  if opts.showDisk and latest.disk_pct ~= nil then
    local pct = tonumber(latest.disk_pct) or 0
    table.insert(rows, ui.label({
      text = fmt.padPercent(pct),
      color = metricColor(state, statusColor, pct, warnPct, dangerPct),
      maxLines = 1,
    }))
  end
  if opts.networkMode ~= "off" and fmt.hasNetwork(latest) then
    local recv = tonumber(latest.net_recv_bps) or 0
    local sent = tonumber(latest.net_sent_bps) or 0
    if opts.networkMode == "split" then
      table.insert(rows, ui.label({
        text = fmt.formatCompactRate(recv),
        color = baseColor,
        maxLines = 1,
      }))
      table.insert(rows, ui.label({
        text = fmt.formatCompactRate(sent),
        color = mutedColor,
        maxLines = 1,
      }))
    elseif opts.networkMode == "combined" then
      table.insert(rows, ui.label({
        text = fmt.formatCompactRate(recv + sent),
        color = mutedColor,
        maxLines = 1,
      }))
    elseif opts.networkMode == "download" then
      table.insert(rows, ui.label({
        text = fmt.formatCompactRate(recv),
        color = mutedColor,
        maxLines = 1,
      }))
    elseif opts.networkMode == "upload" then
      table.insert(rows, ui.label({
        text = fmt.formatCompactRate(sent),
        color = mutedColor,
        maxLines = 1,
      }))
    end
  end

  if #rows == 0 then
    local pct = tonumber(latest.cpu_pct) or 0
    table.insert(rows, ui.label({
      text = fmt.padPercent(pct),
      color = metricColor(state, statusColor, pct, warnPct, dangerPct),
      fontWeight = "medium",
      maxLines = 1,
    }))
  end

  barWidget.render(ui.column({ gap = 2, align = "center" }, rows))
end

local function render()
  local filter = noctalia.getConfig("system") or ""
  local opts = {
    showHost = noctalia.getConfig("show_host_name") ~= false,
    showCpu = noctalia.getConfig("show_cpu") ~= false,
    showMem = noctalia.getConfig("show_memory") ~= false,
    showGpu = noctalia.getConfig("show_gpu") == true,
    showTemp = noctalia.getConfig("show_temp") == true,
    showDisk = noctalia.getConfig("show_disk") == true,
    networkMode = noctalia.getConfig("network_mode") or "off",
  }
  local warnPct, dangerPct = fmt.thresholds()

  local systems = type(data) == "table" and data.systems or {}
  local sys = resolveDisplayedSystem(systems, filter)
  local effectiveFilter = sessionHostId ~= nil and "" or filter
  local latest = sys ~= nil and fmt.latestSample(data, sys.id) or nil
  local state = fmt.effectiveState(data, sys, latest, effectiveFilter)
  local statusColor = fmt.stateColor(state)

  barWidget.setTooltip(buildTooltip(sys, latest, state, effectiveFilter))

  local showMetrics = latest ~= nil
    and state ~= "disconnected"
    and state ~= "auth_error"
    and state ~= "not_found"

  if not showMetrics then
    barWidget.render(ui.label({
      text = fmt.stateLabel(state, effectiveFilter),
      color = statusColor,
      maxLines = 1,
    }))
    return
  end

  if barWidget.isVertical() then
    renderVertical(latest, state, statusColor, warnPct, dangerPct, opts)
    return
  end

  local baseColor = state == "connected" and "on_surface" or statusColor
  local items = {}

  if opts.showHost and sys ~= nil then
    table.insert(items, ui.label({
      text = sys.name,
      color = baseColor,
      maxLines = 1,
    }))
  end

  if opts.showCpu then
    local pct = tonumber(latest.cpu_pct) or 0
    table.insert(
      items,
      barPill("cpu-usage", fmt.padPercent(pct), 34, metricColor(state, statusColor, pct, warnPct, dangerPct))
    )
  end

  if opts.showMem then
    local pct = tonumber(latest.mem_pct) or 0
    table.insert(
      items,
      barPill("memory", fmt.padPercent(pct), 34, metricColor(state, statusColor, pct, warnPct, dangerPct))
    )
  end

  if opts.showGpu then
    local gpu = fmt.primaryGpu(latest)
    if gpu ~= nil then
      local pct = tonumber(gpu.usage_pct) or 0
      table.insert(
        items,
        barPill("cpu-2", fmt.padPercent(pct), 34, metricColor(state, statusColor, pct, warnPct, dangerPct))
      )
    end
  end

  if opts.showTemp and latest.temp_max_c ~= nil then
    local tempColor = state == "connected"
      and fmt.tempSeverityColor(latest.temp_max_c, "on_surface")
      or statusColor
    table.insert(items, barPill("temperature", fmt.formatTemp(latest.temp_max_c), 38, tempColor))
  end

  if opts.showDisk and latest.disk_pct ~= nil then
    local pct = tonumber(latest.disk_pct) or 0
    table.insert(
      items,
      barPill("database", fmt.padPercent(pct), 34, metricColor(state, statusColor, pct, warnPct, dangerPct))
    )
  end

  appendNetworkItems(items, latest, opts.networkMode, baseColor)

  -- Never render an empty bar pill if all enabled metrics are absent on this host.
  if #items == 0 then
    if sys ~= nil then
      table.insert(items, ui.label({
        text = sys.name,
        color = baseColor,
        maxLines = 1,
      }))
    else
      local pct = tonumber(latest.cpu_pct) or 0
      table.insert(
        items,
        barPill("cpu-usage", fmt.padPercent(pct), 30, metricColor(state, statusColor, pct, warnPct, dangerPct))
      )
    end
  end

  barWidget.render(ui.row({ gap = 8, align = "center" }, items))
end

noctalia.state.watch(STATE_KEY, function(nextData)
  data = nextData
  render()
end)

function update()
  render()
end

function onConfigChanged()
  sessionHostId = nil
  render()
end

function onScroll(axis, steps, startsGesture)
  if axis ~= "vertical" or not startsGesture then
    return
  end
  -- Only allow scroll-to-switch on unpinned bar widgets.
  local filter = noctalia.string.trim(noctalia.getConfig("system") or "")
  if filter ~= "" then
    return
  end
  local systems = type(data) == "table" and data.systems or {}
  if #systems < 2 then
    return
  end
  local current = resolveDisplayedSystem(systems, filter)
  local currentIndex = 1
  if current ~= nil then
    for i, s in ipairs(systems) do
      if s.id == current.id then
        currentIndex = i
        break
      end
    end
  end
  local delta = (tonumber(steps) or 0) > 0 and 1 or -1
  local nextIndex = ((currentIndex - 1 + delta) % #systems) + 1
  sessionHostId = systems[nextIndex].id
  render()
end

function onClick()
  local filter = noctalia.getConfig("system") or ""
  local systems = type(data) == "table" and data.systems or {}
  local sys = resolveDisplayedSystem(systems, filter)
  if sys ~= nil then
    noctalia.state.set(SELECTED_HOST_KEY, sys.id)
  end
  noctalia.togglePanel(PANEL_ID)
end

render()
