--!nonstrict
-- HerdR bar widget: a compact rollup over the service-owned snapshot.

local snapshot = {
  available = false,
  running = 0,
  agents = 0,
  blocked = 0,
  done = 0,
  working = 0,
  idle = 0,
  unknown = 0,
}

local function overallStatus()
  if snapshot.available ~= true then return "unavailable" end
  if (snapshot.blocked or 0) > 0 then return "blocked" end
  if (snapshot.done or 0) > 0 then return "done" end
  if (snapshot.working or 0) > 0 then return "working" end
  if (snapshot.idle or 0) > 0 then return "idle" end
  return "unknown"
end

local function statusColor(status)
  if status == "blocked" then return noctalia.getConfig("color_blocked") or "error" end
  if status == "unavailable" then return "error" end
  if status == "done" then return noctalia.getConfig("color_done") or "tertiary" end
  if status == "working" then return noctalia.getConfig("color_working") or "primary" end
  return "on_surface_variant"
end

-- Noctalia seeds each entry runtime with its own declared setting fields plus the
-- plugin-level ones, never another entry's. The colors and the pane filter are
-- declared on this widget, so the panel and the service cannot read them directly:
-- republish them into plugin state, which every entry of the plugin shares.
local function publishSharedSettings()
  noctalia.state.set("herdr.settings", {
    color_blocked = noctalia.getConfig("color_blocked") or "error",
    color_done = noctalia.getConfig("color_done") or "tertiary",
    color_working = noctalia.getConfig("color_working") or "primary",
    hide_agentless_panes = noctalia.getConfig("hide_agentless_panes") ~= false,
  })
end

local function renderTooltip()
  if snapshot.available ~= true then
    barWidget.setTooltip(snapshot.error or noctalia.tr("error.herdr_missing"))
    return
  end

  local rows = {
    { key = noctalia.tr("tooltip.sessions"), value = tostring(snapshot.running or 0) },
    { key = noctalia.tr("tooltip.agents"), value = tostring(snapshot.agents or 0) },
  }

  if (snapshot.blocked or 0) > 0 then
    table.insert(rows, { key = noctalia.tr("status.blocked"), value = tostring(snapshot.blocked) })
  end
  if (snapshot.done or 0) > 0 then
    table.insert(rows, { key = noctalia.tr("status.done"), value = tostring(snapshot.done) })
  end
  if (snapshot.working or 0) > 0 then
    table.insert(rows, { key = noctalia.tr("status.working"), value = tostring(snapshot.working) })
  end

  barWidget.setTooltip(rows)
end

local function render()
  local status = overallStatus()
  local color = statusColor(status)
  local attentionCount = (snapshot.blocked or 0) + (snapshot.done or 0)
  barWidget.setVisible(true)

  local displayMode = noctalia.getConfig("display_mode") or "icon_and_count"
  local hideCountWhenZero = noctalia.getConfig("hide_count_when_zero")
  if hideCountWhenZero == nil then
    hideCountWhenZero = true
  end

  local showCount = true
  if displayMode == "icon" then
    showCount = false
  elseif snapshot.available == true and attentionCount == 0 and hideCountWhenZero == true then
    showCount = false
  end

  local glyph = ui.glyph({ name = "robot", color = color })
  local children = { glyph }

  if showCount then
    local count = snapshot.available == true and tostring(attentionCount) or "!"
    local label = ui.label({
      text = count,
      color = color,
      fontWeight = "bold",
      fontSize = barWidget.isVertical() and 9 or 12,
    })
    table.insert(children, label)
  end

  if barWidget.isVertical() then
    barWidget.render(ui.column({ gap = 0, align = "center" }, children))
  else
    barWidget.render(ui.row({ gap = 5, align = "center" }, children))
  end

  renderTooltip()
end

function update()
  render()
end

function onClick()
  noctalia.togglePanel("hy4ri/herdr:panel")
end

function onConfigChanged()
  publishSharedSettings()
  render()
end

noctalia.state.watch("herdr.state", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

publishSharedSettings()
snapshot = noctalia.state.get("herdr.state") or snapshot
render()
