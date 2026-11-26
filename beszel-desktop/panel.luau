--!nonstrict
-- Beszel Desktop live telemetry panel.
-- Focused per-host dashboard: vitals strip, aligned 2-column grid of hover-scrubbable
-- CPU, memory, GPU, and dual-series network traces, per-core CPU heatmap, disk/pool
-- health, and optional top containers, inside a scrollable viewport.

local fmt = require("./lib/format.luau")

local STATE_KEY = "beszel.data"
local SELECTED_HOST_KEY = "beszel.selected_host"
local HEADER_ROW_HEIGHT = 22
local GRAPH_CARD_HEIGHT = 92
local FULL_GRAPH_HEIGHT = 80
local FOOTER_GRAPH_HEIGHT = 62
local FOOTER_ROW_HEIGHT = 14
local NET_SCALE_FLOOR_BPS = 10 * 1024
local MAX_CONTAINERS_SHOWN = 5
local INSTALL_COMMAND = "cargo install beszel-relay beszel-ctl"
local INIT_COMMAND = "beszel-ctl init"

local data = noctalia.state.get(STATE_KEY)
local selectedHostId = noctalia.state.get(SELECTED_HOST_KEY)
local isOpen = false
local copiedUntilMs = 0
local pendingCopyCommand = nil
local pendingBeszelUrl = nil

local hoveredCpuIndex = nil
local hoveredMemIndex = nil
local hoveredGpuIndex = nil
local hoveredNetIndex = nil
local hoveredCoreIndex = nil
local animatedCores = {}
local targetCores = {}
local render

local function resetHoverState()
  hoveredCpuIndex = nil
  hoveredMemIndex = nil
  hoveredGpuIndex = nil
  hoveredNetIndex = nil
  hoveredCoreIndex = nil
end

local function activeSystem()
  local systems = type(data) == "table" and data.systems or {}
  return fmt.findSystemById(systems, selectedHostId) or systems[1]
end

local function coreColor(pct, warnPct, dangerPct)
  if pct >= dangerPct then
    return "error"
  end
  if pct >= warnPct then
    return "tertiary"
  end
  if pct <= 4 then
    return "primary/0.22"
  end
  local ratio = fmt.clamp(pct / math.max(1, warnPct), 0, 1)
  local alpha = 0.42 + 0.58 * ratio
  return string.format("primary/%.2f", alpha)
end

local function coreColumnCount(count)
  if count <= 8 then
    return math.max(1, count)
  end
  if count <= 16 then
    return 8
  end
  if count <= 24 then
    return 12
  end
  return 16
end

local function coreBarHeight(rowCount)
  if rowCount <= 1 then
    return 76
  end
  if rowCount == 2 then
    return 36
  end
  return 22
end

local function extractSeries(samples, field)
  local values = {}
  if type(samples) ~= "table" then
    return values
  end
  for _, s in ipairs(samples) do
    local v = fmt.clamp((tonumber(s[field]) or 0) / 100.0, 0, 1)
    table.insert(values, v)
  end
  return values
end

local function extractGpuSeries(samples)
  local values = {}
  if type(samples) ~= "table" then
    return values
  end
  for _, s in ipairs(samples) do
    local gpu = fmt.primaryGpu(s)
    local pct = gpu ~= nil and (tonumber(gpu.usage_pct) or 0) or 0
    table.insert(values, fmt.clamp(pct / 100.0, 0, 1))
  end
  return values
end

local function extractNetworkSeries(samples)
  local recvNorm = {}
  local sentNorm = {}
  local hasAny = false
  local peakBps = 0

  if type(samples) == "table" then
    for _, s in ipairs(samples) do
      if fmt.hasNetwork(s) then
        hasAny = true
        local r = math.max(0, tonumber(s.net_recv_bps) or 0)
        local t = math.max(0, tonumber(s.net_sent_bps) or 0)
        if r > peakBps then
          peakBps = r
        end
        if t > peakBps then
          peakBps = t
        end
      end
    end
  end

  if not hasAny then
    return nil, nil, 0
  end

  local scaleMax = math.max(peakBps, NET_SCALE_FLOOR_BPS)
  for _, s in ipairs(samples) do
    local r = math.max(0, tonumber(s.net_recv_bps) or 0)
    local t = math.max(0, tonumber(s.net_sent_bps) or 0)
    table.insert(recvNorm, fmt.clamp(r / scaleMax, 0, 1))
    table.insert(sentNorm, fmt.clamp(t / scaleMax, 0, 1))
  end

  return recvNorm, sentNorm, peakBps
end

local function syncTargetCores(latest)
  targetCores = {}
  if latest ~= nil and type(latest.cpu_cores) == "table" then
    for i, val in ipairs(latest.cpu_cores) do
      targetCores[i] = fmt.clamp(tonumber(val) or 0, 0, 100)
    end
  end
  if #animatedCores ~= #targetCores then
    animatedCores = {}
    for i, val in ipairs(targetCores) do
      animatedCores[i] = val
    end
  end
end

local function cardHeader(titleText, rightNode)
  return ui.row({
    height = HEADER_ROW_HEIGHT,
    align = "center",
    justify = "space_between",
    gap = 6,
  }, {
    ui.label({
      text = titleText,
      fontSize = 13,
      fontWeight = "medium",
      color = "on_surface",
      flexGrow = 1,
      maxLines = 1,
    }),
    rightNode,
  })
end

local function hostGlyph(sys, latest)
  local osName = (type(sys) == "table" and type(sys.os_name) == "string")
    and string.lower(sys.os_name)
    or ""
  local osFamily = (type(sys) == "table" and type(sys.os) == "string")
    and string.lower(sys.os)
    or ""

  if string.find(osName, "ubuntu", 1, true) ~= nil then
    return "brand-ubuntu"
  end
  if string.find(osName, "debian", 1, true) ~= nil then
    return "brand-debian"
  end
  if osFamily == "macos" or string.find(osName, "macos", 1, true) ~= nil then
    return "brand-apple"
  end
  if osFamily == "windows" or string.find(osName, "windows", 1, true) ~= nil then
    return "brand-windows"
  end
  if type(latest) == "table" and latest.battery_pct ~= nil then
    return "device-laptop"
  end
  return "server"
end

local function hostIdentityLabel(sys)
  if type(sys) ~= "table" then
    return nil, nil
  end
  local rawOs = (type(sys.os_name) == "string" and sys.os_name ~= "") and sys.os_name or nil
  local osLabel = fmt.cleanOsName(rawOs)
  if osLabel == nil and type(sys.os) == "string" and sys.os ~= "" then
    osLabel = string.upper(string.sub(sys.os, 1, 1)) .. string.sub(sys.os, 2)
  end
  local rawCpu = (type(sys.cpu_model) == "string" and sys.cpu_model ~= "") and sys.cpu_model or nil
  local cpuLabel = fmt.cleanCpuModel(rawCpu)
  local kernel = (type(sys.kernel) == "string" and sys.kernel ~= "") and sys.kernel or nil
  local arch = (type(sys.arch) == "string" and sys.arch ~= "") and sys.arch or nil

  local primaryParts = {}
  if osLabel ~= nil then
    table.insert(primaryParts, osLabel)
  end
  if cpuLabel ~= nil then
    table.insert(primaryParts, cpuLabel)
  elseif kernel ~= nil then
    table.insert(primaryParts, kernel)
  end

  if #primaryParts == 0 then
    return nil, nil
  end

  local tooltipParts = {}
  if rawOs ~= nil or osLabel ~= nil then
    table.insert(tooltipParts, rawOs or osLabel)
  end
  if kernel ~= nil then
    table.insert(tooltipParts, "Kernel " .. kernel)
  end
  if rawCpu ~= nil then
    table.insert(tooltipParts, rawCpu)
  end
  if arch ~= nil then
    table.insert(tooltipParts, arch)
  end

  return table.concat(primaryParts, " · "), table.concat(tooltipParts, "\n")
end

local function batteryVisual(pct, state)
  local level = tonumber(pct) or 0
  if state == "charging" then
    return "battery-charging", "primary", noctalia.tr("panel.battery_charging")
  end
  if state == "full" then
    return "battery-4", "on_surface_variant", noctalia.tr("panel.battery_full")
  end
  if state == "idle" then
    return "battery-3", "on_surface_variant", noctalia.tr("panel.battery_idle")
  end
  local glyph = "battery-1"
  if level >= 85 then
    glyph = "battery-4"
  elseif level >= 55 then
    glyph = "battery-3"
  elseif level >= 25 then
    glyph = "battery-2"
  end
  local color = level <= 15 and "error" or "on_surface_variant"
  return glyph, color, noctalia.tr("panel.battery_discharging")
end

local function buildVitalsStrip(sys, latest)
  if noctalia.getConfig("show_vitals") == false then
    return nil
  end

  local leftLabel, leftTooltip = hostIdentityLabel(sys)
  local rightPills = {}

  local failedServices = tonumber(latest.failed_services) or 0
  if failedServices > 0 then
    table.insert(rightPills, ui.row({
      gap = 3,
      align = "center",
      tooltip = noctalia.tr("panel.failed_services_tooltip", { count = tostring(failedServices) }),
    }, {
      ui.glyph({ name = "alert-circle", size = 12, color = "error" }),
      ui.label({
        text = noctalia.tr("panel.failed_services", { count = tostring(failedServices) }),
        fontSize = 11,
        fontWeight = "semibold",
        color = "error",
        maxLines = 1,
      }),
    }))
  end

  local updatesTotal = tonumber(latest.updates_total) or 0
  if updatesTotal > 0 then
    local updatesSec = tonumber(latest.updates_security) or 0
    local uColor = updatesSec > 0 and "tertiary" or "on_surface_variant"
    local uText = updatesSec > 0
      and noctalia.tr("panel.updates_security_short", {
        total = tostring(updatesTotal),
        security = tostring(updatesSec),
      })
      or noctalia.tr("panel.updates_short", { total = tostring(updatesTotal) })
    local uTooltip = updatesSec > 0
      and noctalia.tr("panel.updates_security_tooltip", {
        total = tostring(updatesTotal),
        security = tostring(updatesSec),
      })
      or noctalia.tr("panel.updates_tooltip", { total = tostring(updatesTotal) })
    table.insert(rightPills, ui.row({
      gap = 3,
      align = "center",
      tooltip = uTooltip,
    }, {
      ui.glyph({ name = "package", size = 12, color = uColor }),
      ui.label({
        text = uText,
        fontSize = 11,
        fontWeight = updatesSec > 0 and "semibold" or "normal",
        color = uColor,
        maxLines = 1,
      }),
    }))
  end

  if latest.uptime_secs ~= nil then
    table.insert(rightPills, ui.row({ gap = 4, align = "center" }, {
      ui.glyph({ name = "clock", size = 12, color = "on_surface_variant" }),
      ui.label({
        text = noctalia.tr("panel.vitals_uptime", { uptime = fmt.formatUptime(latest.uptime_secs) }),
        fontSize = 11,
        color = "on_surface_variant",
        maxLines = 1,
      }),
    }))
  end

  if noctalia.getConfig("show_load") == true and type(latest.load_avg) == "table" and #latest.load_avg >= 3 then
    local coreCount = type(latest.cpu_cores) == "table" and #latest.cpu_cores or 0
    local loadText
    if coreCount > 0 then
      loadText = noctalia.tr("panel.vitals_load_cores", {
        l1 = string.format("%.2f", tonumber(latest.load_avg[1]) or 0),
        l5 = string.format("%.2f", tonumber(latest.load_avg[2]) or 0),
        l15 = string.format("%.2f", tonumber(latest.load_avg[3]) or 0),
        cores = tostring(coreCount),
      })
    else
      loadText = noctalia.tr("panel.vitals_load", {
        l1 = string.format("%.2f", tonumber(latest.load_avg[1]) or 0),
        l5 = string.format("%.2f", tonumber(latest.load_avg[2]) or 0),
        l15 = string.format("%.2f", tonumber(latest.load_avg[3]) or 0),
      })
    end
    table.insert(rightPills, ui.label({
      text = loadText,
      fontSize = 11,
      color = "on_surface_variant",
      maxLines = 1,
    }))
  end

  if latest.temp_max_c ~= nil then
    local tColor = fmt.tempSeverityColor(latest.temp_max_c, "on_surface_variant")
    table.insert(rightPills, ui.row({ gap = 3, align = "center" }, {
      ui.glyph({ name = "temperature", size = 12, color = tColor }),
      ui.label({
        text = fmt.formatTemp(latest.temp_max_c),
        fontSize = 11,
        fontWeight = tColor ~= "on_surface_variant" and "semibold" or "normal",
        color = tColor,
        maxLines = 1,
      }),
    }))
  end

  if latest.battery_pct ~= nil then
    local batGlyph, batColor, batTooltip = batteryVisual(latest.battery_pct, latest.battery_state)
    table.insert(rightPills, ui.row({ gap = 3, align = "center", tooltip = batTooltip }, {
      ui.glyph({ name = batGlyph, size = 12, color = batColor }),
      ui.label({
        text = string.format("%d%%", math.floor((tonumber(latest.battery_pct) or 0) + 0.5)),
        fontSize = 11,
        fontWeight = batColor ~= "on_surface_variant" and "semibold" or "normal",
        color = batColor,
        maxLines = 1,
      }),
    }))
  end

  if leftLabel == nil and #rightPills == 0 then
    return nil
  end

  local rowChildren = {}
  if leftLabel ~= nil then
    table.insert(rowChildren, ui.row({
      gap = 6,
      align = "center",
      flexGrow = 1,
      tooltip = leftTooltip,
    }, {
      ui.glyph({ name = hostGlyph(sys, latest), size = 13, color = "on_surface_variant" }),
      ui.label({
        text = leftLabel,
        fontSize = 11,
        color = "on_surface_variant",
        flexGrow = 1,
        maxLines = 1,
      }),
    }))
  end

  if #rightPills > 0 then
    table.insert(rowChildren, ui.row({ gap = 12, align = "center" }, rightPills))
  end

  return ui.row({
    gap = 12,
    paddingH = 10,
    paddingV = 6,
    radius = 8,
    fill = "surface_container_high",
    align = "center",
    justify = "space_between",
  }, rowChildren)
end

local function buildCpuSection(samples, latest, warnPct, dangerPct)
  local cpuSample = (hoveredCpuIndex ~= nil and samples[hoveredCpuIndex]) or latest
  local cpuPct = tonumber(cpuSample.cpu_pct) or 0
  local cpuColor = fmt.severityColor(cpuPct, "primary", warnPct, dangerPct)

  return ui.column({ gap = 6, flexGrow = 1 }, {
    cardHeader(
      noctalia.tr("panel.cpu"),
      ui.label({
        text = string.format("%.1f%%", cpuPct),
        fontSize = 15,
        fontWeight = "semibold",
        color = cpuColor,
      })
    ),
    ui.column({
      height = GRAPH_CARD_HEIGHT,
      padding = 6,
      radius = 8,
      fill = "surface_container_high",
    }, {
      ui.graph({
        key = "cpu-graph",
        height = FULL_GRAPH_HEIGHT,
        values = extractSeries(samples, "cpu_pct"),
        color = cpuColor,
        lineWidth = 2,
        fillOpacity = 0.22,
        onPointerMove = "onCpuGraphMove",
        onPointerLeave = "onCpuGraphLeave",
      }),
    }),
  })
end

local function buildCoreHeatmap(warnPct, dangerPct)
  if noctalia.getConfig("show_cores") == false then
    return nil
  end
  local count = #targetCores
  if count == 0 then
    return nil
  end

  local peak = 0
  for _, val in ipairs(targetCores) do
    if val > peak then
      peak = val
    end
  end

  local metaText
  if hoveredCoreIndex ~= nil and targetCores[hoveredCoreIndex] ~= nil then
    metaText = noctalia.tr("panel.cores_hover", {
      index = tostring(hoveredCoreIndex - 1),
      pct = tostring(math.floor(targetCores[hoveredCoreIndex] + 0.5)),
    })
  else
    metaText = noctalia.tr("panel.cores_summary", {
      count = tostring(count),
      peak = tostring(math.floor(peak + 0.5)),
    })
  end

  local cols = coreColumnCount(count)
  local rowCount = math.ceil(count / cols)
  local barHeight = coreBarHeight(rowCount)
  local gridRows = {}
  local idx = 1
  while idx <= count do
    local cells = {}
    for _ = 1, cols do
      local coreIdx = idx
      if coreIdx <= count then
        local shownVal = animatedCores[coreIdx] or targetCores[coreIdx] or 0
        local actualVal = math.floor((targetCores[coreIdx] or 0) + 0.5)
        local fillHeight = shownVal > 0.5
          and math.max(3, math.floor((shownVal / 100.0) * barHeight + 0.5))
          or 0
        local isHovered = hoveredCoreIndex == coreIdx

        local barChildren = {}
        if fillHeight > 0 then
          table.insert(barChildren, ui.box({
            height = fillHeight,
            radius = 2,
            fill = coreColor(shownVal, warnPct, dangerPct),
          }))
        end

        table.insert(cells, ui.column({
          key = "core-" .. tostring(coreIdx),
          flexGrow = 1,
          height = barHeight,
          justify = "end",
          radius = 3,
          fill = "surface_container_highest",
          border = isHovered and "on_surface/0.45" or nil,
          borderWidth = isHovered and 1 or nil,
          clip = true,
          onHover = "onCoreHover",
          tooltip = noctalia.tr("panel.cores_hover", {
            index = tostring(coreIdx - 1),
            pct = tostring(actualVal),
          }),
        }, barChildren))
      else
        table.insert(cells, ui.spacer({ flexGrow = 1 }))
      end
      idx += 1
    end
    table.insert(gridRows, ui.row({ gap = 4 }, cells))
  end

  return ui.column({ gap = 6, flexGrow = 1 }, {
    cardHeader(
      noctalia.tr("panel.cores"),
      ui.label({
        text = metaText,
        fontSize = 11,
        color = hoveredCoreIndex ~= nil and "on_surface" or "on_surface_variant",
      })
    ),
    ui.column({
      minHeight = GRAPH_CARD_HEIGHT,
      gap = 4,
      padding = 8,
      radius = 8,
      fill = "surface_container_high",
      justify = "center",
    }, gridRows),
  })
end

local function buildMemorySection(samples, latest, warnPct, dangerPct)
  local memSample = (hoveredMemIndex ~= nil and samples[hoveredMemIndex]) or latest
  local memPct = tonumber(memSample.mem_pct) or 0
  local memColor = fmt.severityColor(memPct, "secondary", warnPct, dangerPct)

  local memReadoutChildren = {}
  if memSample.mem_used_bytes ~= nil and memSample.mem_total_bytes ~= nil then
    table.insert(memReadoutChildren, ui.label({
      text = string.format(
        "%s / %s GiB",
        fmt.formatGiB(memSample.mem_used_bytes),
        fmt.formatGiB(memSample.mem_total_bytes)
      ),
      fontSize = 11,
      color = "on_surface_variant",
    }))
  end
  table.insert(memReadoutChildren, ui.label({
    text = string.format("%.1f%%", memPct),
    fontSize = 15,
    fontWeight = "semibold",
    color = memColor,
  }))

  local swapUsed = tonumber(memSample.swap_used_bytes) or 0
  local showSwapRow = noctalia.getConfig("show_swap") ~= false
    and swapUsed > 0
    and memSample.swap_total_bytes ~= nil

  local memCardChildren = {
    ui.graph({
      key = "mem-graph",
      height = showSwapRow and FOOTER_GRAPH_HEIGHT or FULL_GRAPH_HEIGHT,
      values = extractSeries(samples, "mem_pct"),
      color = memColor,
      lineWidth = 2,
      fillOpacity = 0.22,
      onPointerMove = "onMemGraphMove",
      onPointerLeave = "onMemGraphLeave",
    }),
  }

  if showSwapRow then
    table.insert(memCardChildren, ui.row({
      height = FOOTER_ROW_HEIGHT,
      align = "center",
      justify = "space_between",
    }, {
      ui.label({
        text = noctalia.tr("panel.swap"),
        fontSize = 10,
        color = "on_surface_variant",
      }),
      ui.label({
        text = string.format(
          "%s / %s GiB",
          fmt.formatGiB(swapUsed),
          fmt.formatGiB(memSample.swap_total_bytes)
        ),
        fontSize = 10,
        color = "on_surface_variant",
      }),
    }))
  end

  return ui.column({ gap = 6, flexGrow = 1 }, {
    cardHeader(
      noctalia.tr("panel.memory"),
      ui.row({ gap = 6, align = "center" }, memReadoutChildren)
    ),
    ui.column({
      height = GRAPH_CARD_HEIGHT,
      gap = 4,
      padding = 6,
      radius = 8,
      fill = "surface_container_high",
    }, memCardChildren),
  })
end

local function buildGpuSection(samples, latest, warnPct, dangerPct)
  if noctalia.getConfig("show_gpu") == false then
    return nil
  end
  local latestGpu = fmt.primaryGpu(latest)
  if latestGpu == nil then
    return nil
  end

  local sample = (hoveredGpuIndex ~= nil and samples[hoveredGpuIndex]) or latest
  local gpu = fmt.primaryGpu(sample) or latestGpu
  local gpuPct = tonumber(gpu.usage_pct) or 0
  local gpuColor = fmt.severityColor(gpuPct, "primary", warnPct, dangerPct)

  local metaParts = {}
  if gpu.mem_used_mb ~= nil and gpu.mem_total_mb ~= nil then
    table.insert(
      metaParts,
      string.format("%s / %s", fmt.formatMb(gpu.mem_used_mb), fmt.formatMb(gpu.mem_total_mb))
    )
  end
  if gpu.power_w ~= nil then
    table.insert(metaParts, string.format("%.0f W", tonumber(gpu.power_w) or 0))
  end

  local rightChildren = {}
  if #metaParts > 0 then
    table.insert(rightChildren, ui.label({
      text = table.concat(metaParts, " · "),
      fontSize = 11,
      color = "on_surface_variant",
      maxLines = 1,
    }))
  end
  table.insert(rightChildren, ui.label({
    text = string.format("%.0f%%", gpuPct),
    fontSize = 15,
    fontWeight = "semibold",
    color = gpuColor,
  }))

  local title = (type(gpu.name) == "string" and gpu.name ~= "")
    and gpu.name
    or noctalia.tr("panel.gpu")

  return ui.column({ gap = 6, flexGrow = 1 }, {
    cardHeader(title, ui.row({ gap = 6, align = "center" }, rightChildren)),
    ui.column({
      height = GRAPH_CARD_HEIGHT,
      padding = 6,
      radius = 8,
      fill = "surface_container_high",
    }, {
      ui.graph({
        key = "gpu-graph",
        height = FULL_GRAPH_HEIGHT,
        values = extractGpuSeries(samples),
        color = gpuColor,
        lineWidth = 2,
        fillOpacity = 0.22,
        onPointerMove = "onGpuGraphMove",
        onPointerLeave = "onGpuGraphLeave",
      }),
    }),
  })
end

local function buildNetworkSection(samples, latest)
  if noctalia.getConfig("show_network") == false then
    return nil
  end
  local recvSeries, sentSeries, peakBps = extractNetworkSeries(samples)
  if recvSeries == nil then
    return nil
  end

  local sample = (hoveredNetIndex ~= nil and samples[hoveredNetIndex]) or latest
  local recvBps = tonumber(sample.net_recv_bps) or 0
  local sentBps = tonumber(sample.net_sent_bps) or 0

  -- Distinct high-contrast palette roles: primary (download) vs tertiary (upload).
  local dlColor = "primary"
  local ulColor = "tertiary"

  return ui.column({ gap = 6, flexGrow = 1 }, {
    cardHeader(
      noctalia.tr("panel.network"),
      ui.row({ gap = 8, align = "center" }, {
        ui.row({ gap = 2, align = "center" }, {
          ui.glyph({ name = "arrow-down", size = 12, color = dlColor }),
          ui.label({
            text = fmt.formatRate(recvBps),
            fontSize = 12,
            fontWeight = "semibold",
            color = dlColor,
            maxLines = 1,
          }),
        }),
        ui.row({ gap = 2, align = "center" }, {
          ui.glyph({ name = "arrow-up", size = 12, color = ulColor }),
          ui.label({
            text = fmt.formatRate(sentBps),
            fontSize = 12,
            fontWeight = "semibold",
            color = ulColor,
            maxLines = 1,
          }),
        }),
      })
    ),
    ui.column({
      height = GRAPH_CARD_HEIGHT,
      gap = 4,
      padding = 6,
      radius = 8,
      fill = "surface_container_high",
    }, {
      ui.graph({
        key = "net-graph",
        height = FOOTER_GRAPH_HEIGHT,
        values = recvSeries,
        values2 = sentSeries,
        color = dlColor,
        color2 = ulColor,
        lineWidth = 2,
        fillOpacity = 0.18,
        onPointerMove = "onNetGraphMove",
        onPointerLeave = "onNetGraphLeave",
      }),
      ui.row({
        height = FOOTER_ROW_HEIGHT,
        align = "center",
        justify = "space_between",
      }, {
        ui.row({ gap = 10, align = "center" }, {
          ui.row({ gap = 4, align = "center" }, {
            ui.box({ width = 7, height = 7, radius = 4, fill = dlColor }),
            ui.label({
              text = noctalia.tr("panel.network_download"),
              fontSize = 10,
              color = "on_surface_variant",
            }),
          }),
          ui.row({ gap = 4, align = "center" }, {
            ui.box({ width = 7, height = 7, radius = 4, fill = ulColor }),
            ui.label({
              text = noctalia.tr("panel.network_upload"),
              fontSize = 10,
              color = "on_surface_variant",
            }),
          }),
        }),
        ui.label({
          text = noctalia.tr("panel.network_peak", { rate = fmt.formatRate(peakBps) }),
          fontSize = 10,
          color = "on_surface_variant",
        }),
      }),
    }),
  })
end

local function buildDiskSection(latest, warnPct, dangerPct)
  if noctalia.getConfig("show_disk") == false then
    return nil
  end
  local hasDiskPct = latest.disk_pct ~= nil
  local hasDiskIo = latest.disk_read_bps ~= nil or latest.disk_write_bps ~= nil
  local extraDisks = type(latest.extra_disks) == "table" and latest.extra_disks or {}
  local unhealthy = type(latest.unhealthy_pools) == "table" and latest.unhealthy_pools or {}
  if not hasDiskPct and not hasDiskIo and #extraDisks == 0 and #unhealthy == 0 then
    return nil
  end

  local headerRight = {}
  local cardChildren = {}

  if hasDiskPct then
    local pct = tonumber(latest.disk_pct) or 0
    local diskColor = fmt.severityColor(pct, "primary", warnPct, dangerPct)
    if latest.disk_used_gb ~= nil and latest.disk_total_gb ~= nil then
      table.insert(headerRight, ui.label({
        text = string.format(
          "%.0f / %.0f GiB",
          tonumber(latest.disk_used_gb) or 0,
          tonumber(latest.disk_total_gb) or 0
        ),
        fontSize = 11,
        color = "on_surface_variant",
      }))
    end
    table.insert(headerRight, ui.label({
      text = string.format("%.0f%%", pct),
      fontSize = 15,
      fontWeight = "semibold",
      color = diskColor,
    }))
    table.insert(cardChildren, ui.progress({
      progress = fmt.clamp(pct / 100.0, 0, 1),
      fill = diskColor,
      track = "surface_container_highest",
      height = 6,
      radius = 3,
    }))
  end

  -- Always keep the Disk I/O row present when disk stats exist so zero-I/O ticks
  -- never pop the row in/out and resize the panel.
  if hasDiskPct or hasDiskIo then
    table.insert(cardChildren, ui.row({ align = "center", justify = "space_between" }, {
      ui.label({
        text = noctalia.tr("panel.disk_io"),
        fontSize = 11,
        color = "on_surface_variant",
      }),
      ui.label({
        text = noctalia.tr("panel.disk_io_values", {
          read = fmt.formatRate(latest.disk_read_bps or 0),
          write = fmt.formatRate(latest.disk_write_bps or 0),
        }),
        fontSize = 11,
        color = "on_surface",
      }),
    }))
  end

  if #extraDisks > 0 then
    if #cardChildren > 0 then
      table.insert(cardChildren, ui.separator({ color = "outline_variant/0.35" }))
    end
    for i, disk in ipairs(extraDisks) do
      local pct = tonumber(disk.pct) or 0
      local extraColor = fmt.severityColor(pct, "primary", warnPct, dangerPct)
      table.insert(cardChildren, ui.column({
        key = "efs-" .. tostring(i) .. "-" .. tostring(disk.name or ""),
        gap = 3,
      }, {
        ui.row({ align = "center", justify = "space_between", gap = 6 }, {
          ui.label({
            text = tostring(disk.name or ""),
            fontSize = 11,
            color = "on_surface_variant",
            flexGrow = 1,
            maxLines = 1,
          }),
          ui.row({ gap = 6, align = "center" }, {
            ui.label({
              text = string.format(
                "%.0f / %.0f GiB",
                tonumber(disk.used_gb) or 0,
                tonumber(disk.total_gb) or 0
              ),
              fontSize = 10,
              color = "on_surface_variant",
            }),
            ui.label({
              text = string.format("%.0f%%", pct),
              fontSize = 11,
              fontWeight = "semibold",
              color = extraColor,
            }),
          }),
        }),
        ui.progress({
          progress = fmt.clamp(pct / 100.0, 0, 1),
          fill = extraColor,
          track = "surface_container_highest",
          height = 4,
          radius = 2,
        }),
      }))
    end
  end

  if #unhealthy > 0 then
    table.insert(cardChildren, ui.row({
      gap = 6,
      paddingH = 8,
      paddingV = 5,
      radius = 6,
      fill = "error_container",
      align = "center",
    }, {
      ui.glyph({ name = "alert-triangle", size = 13, color = "on_error_container" }),
      ui.label({
        text = noctalia.tr("panel.pool_degraded", { pools = table.concat(unhealthy, ", ") }),
        fontSize = 11,
        fontWeight = "medium",
        color = "on_error_container",
        maxLines = 2,
      }),
    }))
  end

  return ui.column({ gap = 6, flexGrow = 1 }, {
    cardHeader(noctalia.tr("panel.disk"), ui.row({ gap = 6, align = "center" }, headerRight)),
    ui.column({
      gap = 8,
      padding = 10,
      radius = 8,
      fill = "surface_container_high",
    }, cardChildren),
  })
end

local function buildContainersSection(latest)
  if noctalia.getConfig("show_containers") ~= true then
    return nil
  end
  if type(latest.containers) ~= "table" or #latest.containers == 0 then
    return nil
  end

  local rows = {}
  local limit = math.min(#latest.containers, MAX_CONTAINERS_SHOWN)
  for i = 1, limit do
    local c = latest.containers[i]
    table.insert(rows, ui.row({
      key = "ctr-" .. tostring(i) .. "-" .. tostring(c.name or ""),
      align = "center",
      justify = "space_between",
      gap = 8,
    }, {
      ui.label({
        text = tostring(c.name or ""),
        fontSize = 11,
        color = "on_surface",
        flexGrow = 1,
        maxLines = 1,
      }),
      ui.row({ gap = 8, align = "center" }, {
        ui.label({
          text = string.format("%.1f%%", tonumber(c.cpu_pct) or 0),
          width = 38,
          textAlign = "end",
          fontSize = 11,
          fontWeight = "medium",
          color = "on_surface",
        }),
        ui.label({
          text = fmt.formatMb(c.mem_mb or 0),
          width = 56,
          textAlign = "end",
          fontSize = 11,
          color = "on_surface_variant",
        }),
      }),
    }))
  end

  return ui.column({ gap = 6, flexGrow = 1 }, {
    cardHeader(
      noctalia.tr("panel.containers"),
      ui.label({
        text = noctalia.tr("panel.containers_count", { count = tostring(#latest.containers) }),
        fontSize = 11,
        color = "on_surface_variant",
      })
    ),
    ui.column({
      gap = 6,
      padding = 10,
      radius = 8,
      fill = "surface_container_high",
    }, rows),
  })
end

local function buildOnboardingCard(state)
  local isMissing = type(data) == "table" and data.ctlMissing == true
  local isCopied = noctalia.nowMs() < copiedUntilMs

  if isMissing or state == "disconnected" or state == "error" then
    local headingKey = isMissing and "panel.setup_install_title"
      or (state == "error" and "panel.setup_auth_title" or "panel.setup_init_title")
    local descKey = isMissing and "panel.setup_install_desc"
      or (state == "error" and "panel.setup_auth_desc" or "panel.setup_init_desc")
    local cmd = isMissing and INSTALL_COMMAND or INIT_COMMAND
    local btnKey = isCopied and "panel.setup_copied"
      or (isMissing and "panel.setup_copy_install" or "panel.setup_copy_init")

    pendingCopyCommand = cmd

    local children = {
      ui.label({
        text = noctalia.tr(headingKey),
        fontSize = 13,
        fontWeight = "semibold",
        color = "on_surface",
      }),
      ui.label({
        text = noctalia.tr(descKey),
        fontSize = 12,
        color = "on_surface_variant",
        maxLines = 4,
      }),
      ui.column({
        paddingH = 10,
        paddingV = 8,
        radius = 6,
        fill = "surface_container_highest",
      }, {
        ui.label({
          text = cmd,
          fontSize = 11,
          fontFamily = "monospace",
          color = "on_surface",
          maxLines = 3,
        }),
      }),
      ui.button({
        text = noctalia.tr(btnKey),
        glyph = isCopied and "check" or "copy",
        glyphSize = 14,
        variant = "primary",
        controlSize = "sm",
        onClick = "onCopySetupCommand",
      }),
    }

    if isMissing then
      table.insert(children, ui.label({
        text = noctalia.tr("panel.setup_alt"),
        fontSize = 11,
        color = "on_surface_variant",
        maxLines = 2,
      }))
    end

    return ui.column({
      gap = 10,
      padding = 12,
      radius = 8,
      fill = "surface_container_high",
    }, children)
  end

  pendingCopyCommand = nil
  return ui.column({
    padding = 16,
    radius = 8,
    fill = "surface_container_high",
    align = "center",
  }, {
    ui.label({
      text = noctalia.tr("panel.empty"),
      fontSize = 12,
      color = "on_surface_variant",
      maxLines = 2,
    }),
  })
end

render = function()
  if not isOpen then
    return
  end

  local warnPct, dangerPct = fmt.thresholds()
  local sys = activeSystem()
  local samples = (sys ~= nil and type(data) == "table" and type(data.historyBySystem) == "table")
    and (data.historyBySystem[sys.id] or {})
    or {}
  local latest = #samples > 0 and samples[#samples] or nil
  local state = fmt.effectiveState(data, sys, latest, "")

  syncTargetCores(latest)

  local title = sys ~= nil and sys.name or noctalia.tr("panel.title")
  local statusText = ""
  if type(data) == "table" and type(data.connection) == "table" and data.connection.last_error ~= nil then
    statusText = fmt.stateLabel(state, "") .. ": " .. tostring(data.connection.last_error)
  elseif state ~= "connected" then
    statusText = fmt.stateLabel(state, "")
  end

  pendingBeszelUrl = nil
  if type(data) == "table" and type(data.hubUrl) == "string"
      and string.match(data.hubUrl, "^https?://") ~= nil
      and sys ~= nil and type(sys.id) == "string" and sys.id ~= "" then
    pendingBeszelUrl = string.gsub(data.hubUrl, "/+$", "") .. "/system/" .. sys.id
  end

  local headerActions = {}
  if pendingBeszelUrl ~= nil then
    table.insert(headerActions, ui.button({
      glyph = "external-link",
      glyphSize = 14,
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr("panel.open_in_beszel", { host = title }),
      onClick = "onOpenInBeszel",
    }))
  end
  table.insert(headerActions, ui.button({
    glyph = "settings",
    glyphSize = 14,
    variant = "ghost",
    controlSize = "sm",
    tooltip = noctalia.tr("panel.open_settings"),
    onClick = "onOpenSettings",
  }))

  local header = ui.row({ align = "center", justify = "space_between", gap = 8 }, {
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({
        text = title,
        fontSize = 16,
        fontWeight = "semibold",
        color = "on_surface",
      }),
      ui.label({
        text = statusText,
        visible = statusText ~= "",
        fontSize = 11,
        color = fmt.stateColor(state),
        maxLines = 2,
      }),
    }),
    ui.row({ gap = 4, align = "center" }, headerActions),
  })

  if latest == nil then
    panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
      header,
      buildOnboardingCard(state),
    }))
    return
  end

  local scrollChildren = {}

  local vitals = buildVitalsStrip(sys, latest)
  if vitals ~= nil then
    table.insert(scrollChildren, vitals)
  end

  -- Ordered 2-column grid rows so left and right cards share exact row baselines.
  local cards = {
    buildCpuSection(samples, latest, warnPct, dangerPct),
    buildMemorySection(samples, latest, warnPct, dangerPct),
  }
  local function addCard(node)
    if node ~= nil then
      table.insert(cards, node)
    end
  end

  addCard(buildCoreHeatmap(warnPct, dangerPct))
  addCard(buildNetworkSection(samples, latest))
  addCard(buildGpuSection(samples, latest, warnPct, dangerPct))
  addCard(buildDiskSection(latest, warnPct, dangerPct))
  addCard(buildContainersSection(latest))

  local i = 1
  while i <= #cards do
    local leftCard = cards[i]
    local rightCard = cards[i + 1] or ui.spacer({ flexGrow = 1 })
    table.insert(scrollChildren, ui.row({ gap = 14, align = "start" }, {
      leftCard,
      rightCard,
    }))
    i += 2
  end

  panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
    header,
    ui.scroll({ key = "metrics-scroll", flexGrow = 1, gap = 12 }, scrollChildren),
  }))
end

local function sampleIndexFromNormX(normX)
  local sys = activeSystem()
  if sys == nil or type(data) ~= "table" or type(data.historyBySystem) ~= "table" then
    return nil
  end
  local samples = data.historyBySystem[sys.id]
  if type(samples) ~= "table" or #samples == 0 then
    return nil
  end
  local x = fmt.clamp(tonumber(normX) or 0, 0, 1)
  local idx = math.floor(x * (#samples - 1) + 0.5) + 1
  return fmt.clamp(idx, 1, #samples)
end

function onCpuGraphMove(normX)
  local nextIdx = sampleIndexFromNormX(normX)
  if nextIdx ~= hoveredCpuIndex then
    hoveredCpuIndex = nextIdx
    render()
  end
end

function onCpuGraphLeave()
  if hoveredCpuIndex ~= nil then
    hoveredCpuIndex = nil
    render()
  end
end

function onMemGraphMove(normX)
  local nextIdx = sampleIndexFromNormX(normX)
  if nextIdx ~= hoveredMemIndex then
    hoveredMemIndex = nextIdx
    render()
  end
end

function onMemGraphLeave()
  if hoveredMemIndex ~= nil then
    hoveredMemIndex = nil
    render()
  end
end

function onGpuGraphMove(normX)
  local nextIdx = sampleIndexFromNormX(normX)
  if nextIdx ~= hoveredGpuIndex then
    hoveredGpuIndex = nextIdx
    render()
  end
end

function onGpuGraphLeave()
  if hoveredGpuIndex ~= nil then
    hoveredGpuIndex = nil
    render()
  end
end

function onNetGraphMove(normX)
  local nextIdx = sampleIndexFromNormX(normX)
  if nextIdx ~= hoveredNetIndex then
    hoveredNetIndex = nextIdx
    render()
  end
end

function onNetGraphLeave()
  if hoveredNetIndex ~= nil then
    hoveredNetIndex = nil
    render()
  end
end

function onCoreHover(hoverState, key)
  local nextCore = nil
  if hoverState == "true" and type(key) == "string" then
    nextCore = tonumber(string.match(key, "^core%-(%d+)$"))
  end
  if nextCore ~= hoveredCoreIndex then
    hoveredCoreIndex = nextCore
    render()
  end
end

function onOpenSettings()
  noctalia.openSettings()
end

function onOpenInBeszel()
  if type(pendingBeszelUrl) ~= "string" or string.match(pendingBeszelUrl, "^https?://") == nil then
    return
  end
  noctalia.runAsync({ "xdg-open", pendingBeszelUrl })
  panel.close()
end

function onCopySetupCommand()
  if type(pendingCopyCommand) ~= "string" or pendingCopyCommand == "" then
    return
  end
  if noctalia.copyToClipboard(pendingCopyCommand, "text/plain") then
    copiedUntilMs = noctalia.nowMs() + 2500
    render()
  end
end

function onFrameTick(deltaMs)
  if not isOpen or #targetCores == 0 then
    return
  end
  local dt = fmt.clamp((tonumber(deltaMs) or 16) / 1000.0, 0.001, 0.1)
  local alpha = 1.0 - math.exp(-dt * 12.0)
  local changed = false

  for i, target in ipairs(targetCores) do
    local cur = animatedCores[i] or target
    local diff = target - cur
    if math.abs(diff) > 0.2 then
      animatedCores[i] = cur + diff * alpha
      changed = true
    elseif cur ~= target then
      animatedCores[i] = target
      changed = true
    end
  end

  if changed then
    render()
  end
end

noctalia.state.watch(STATE_KEY, function(nextData)
  data = nextData
  if isOpen then
    render()
  end
end)

noctalia.state.watch(SELECTED_HOST_KEY, function(hostId)
  if type(hostId) == "string" and hostId ~= "" and hostId ~= selectedHostId then
    selectedHostId = hostId
    resetHoverState()
    animatedCores = {}
    if isOpen then
      render()
    end
  end
end)

function onOpen(context)
  isOpen = true
  if type(context) == "string" and context ~= "" then
    local systems = type(data) == "table" and data.systems or {}
    local matched = fmt.findSystem(systems, context)
    if matched ~= nil then
      selectedHostId = matched.id
    end
  end
  resetHoverState()
  panel.setWantsSecondTicks(true)
  panel.setNeedsFrameTick(true)
  render()
end

function onClose()
  isOpen = false
  resetHoverState()
  panel.setWantsSecondTicks(false)
  panel.setNeedsFrameTick(false)
end

function update()
  if isOpen then
    render()
  end
end

function onConfigChanged()
  if isOpen then
    render()
  end
end
