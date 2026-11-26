--!nonstrict
-- Beszel Desktop bar widget.
-- Supports multiple independent host instances via per-widget `system` setting,
-- monochrome icons in normal state (colored only on warning/danger), and
-- scroll-to-switch across discovered hosts.

local fmt = require("./lib/format.luau")

local PANEL_ID = "henriksvensson/beszel-desktop:panel"
local STATE_KEY = "beszel.data"
local SELECTED_HOST_KEY = "beszel.selected_host"
local OPENED_SOURCE_KEY = "beszel.opened_source"

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

local function buildTooltip(sys, latest, state, filter)
  local rows = {}
  if sys ~= nil then
    table.insert(rows, { key = noctalia.tr("tooltip.host"), value = sys.name })
  end
  if latest ~= nil then
    table.insert(rows, {
      key = noctalia.tr("tooltip.cpu"),
      value = string.format("%.1f%%", tonumber(latest.cpu_pct) or 0),
    })
    local memText = string.format("%.1f%%", tonumber(latest.mem_pct) or 0)
    if latest.mem_used_bytes ~= nil and latest.mem_total_bytes ~= nil then
      memText = string.format(
        "%s (%s / %s GiB)",
        memText,
        fmt.formatGiB(latest.mem_used_bytes),
        fmt.formatGiB(latest.mem_total_bytes)
      )
    end
    table.insert(rows, { key = noctalia.tr("tooltip.memory"), value = memText })
  end
  table.insert(rows, { key = noctalia.tr("tooltip.status"), value = fmt.stateLabel(state, filter) })
  return rows
end

local function render()
  local filter = noctalia.getConfig("system") or ""
  local showHost = noctalia.getConfig("show_host_name") ~= false
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

  local cpuPct = tonumber(latest.cpu_pct) or 0
  local memPct = tonumber(latest.mem_pct) or 0

  local cpuColor = state == "connected"
    and fmt.severityColor(cpuPct, "on_surface", warnPct, dangerPct)
    or statusColor
  local memColor = state == "connected"
    and fmt.severityColor(memPct, "on_surface", warnPct, dangerPct)
    or statusColor

  if barWidget.isVertical() then
    barWidget.render(ui.column({ gap = 2, align = "center" }, {
      ui.label({
        text = fmt.padPercent(cpuPct),
        color = cpuColor,
        fontWeight = "medium",
        maxLines = 1,
      }),
      ui.label({
        text = fmt.padPercent(memPct),
        color = state == "connected"
          and fmt.severityColor(memPct, "on_surface_variant", warnPct, dangerPct)
          or statusColor,
        maxLines = 1,
      }),
    }))
    return
  end

  local items = {}
  if showHost and sys ~= nil then
    table.insert(items, ui.label({
      text = sys.name,
      color = state == "connected" and "on_surface" or statusColor,
      maxLines = 1,
    }))
  end

  table.insert(items, ui.row({ gap = 3, align = "center" }, {
    ui.glyph({ name = "cpu-usage", size = 14, color = cpuColor }),
    ui.label({
      text = fmt.padPercent(cpuPct),
      width = 30,
      textAlign = "end",
      color = cpuColor,
      maxLines = 1,
    }),
  }))

  table.insert(items, ui.row({ gap = 3, align = "center" }, {
    ui.glyph({ name = "memory", size = 14, color = memColor }),
    ui.label({
      text = fmt.padPercent(memPct),
      width = 30,
      textAlign = "end",
      color = memColor,
      maxLines = 1,
    }),
  }))

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
  local systems = type(data) == "table" and data.systems or {}
  if #systems < 2 then
    return
  end
  local filter = noctalia.getConfig("system") or ""
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
  noctalia.state.set(OPENED_SOURCE_KEY, {
    configuredFilter = filter,
    displayedHostId = sys ~= nil and sys.id or nil,
  })
  noctalia.togglePanel(PANEL_ID)
end

render()
