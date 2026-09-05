local PANEL_ID = "aceix/hyprmodoro:panel"

local transport = "UNKNOWN"
local phase = "IDLE"
local state = "STOPPED"
local paused = false
local time = "--:--"
local work = 25
local isVertical = false
local hasTooltip = false

local GLYPHS = { IDLE = "hourglass", WORK = "brain", REST = "moon", WAITING = "player-pause" }
local COLORS = { IDLE = "on_surface_variant", WORK = "primary", REST = "tertiary", WAITING = "warning" }

local function tone()
  if transport == "ABSENT" then return "on_surface/0.35" end
  if paused then return "on_surface/0.5" end
  return COLORS[phase] or COLORS.IDLE
end

local function glyphName()
  if paused then return "player-pause" end
  return GLYPHS[phase] or GLYPHS.IDLE
end

local function tooltipRows()
  if transport == "ABSENT" then
    return { { key = noctalia.tr("title"), value = noctalia.tr("err.absent_title") } }
  end

  local rows = {
    { key = noctalia.tr("ui.phase"), value = noctalia.tr("phase." .. phase:lower()) },
  }
  if state ~= "STOPPED" then
    table.insert(rows, { key = noctalia.tr("ui.remaining"), value = time })
  end
  table.insert(rows, {
    key = noctalia.tr("ui.durations"),
    value = string.format("%d / %d %s", work, noctalia.state.get("hm.rest") or 5, noctalia.tr("ui.minutes_short")),
  })
  if transport == "READONLY" then
    table.insert(rows, { key = noctalia.tr("err.readonly_title"), value = noctalia.tr("ui.see_readme") })
  end
  return rows
end

local function setTooltip()
  barWidget.setTooltip(tooltipRows())
  hasTooltip = true
end

local function clearTooltip()

  if hasTooltip then
    barWidget.clearTooltip()
    hasTooltip = false
  end
end

local function render()
  local showIdle = noctalia.getConfig("show_when_idle")

  local configured = noctalia.getConfig("glyph")
  local glyph = glyphName()
  if phase == "IDLE" and not paused and type(configured) == "string" and configured ~= "" then
    glyph = configured
  end

  setTooltip()

  if isVertical then
    barWidget.render(ui.column({ align = "center" }, {
      ui.glyph({ name = glyph, color = tone() }),
    }))
    return
  end

  local idle = state == "STOPPED" or transport == "ABSENT"
  if idle and showIdle == false then
    barWidget.render(ui.row({ align = "center" }, {
      ui.glyph({ name = glyph, color = tone() }),
    }))
    return
  end

  barWidget.render(ui.row({ gap = 6, align = "center" }, {
    ui.glyph({ name = glyph, color = tone() }),
    ui.label({
      text = idle and string.format("%d%s", work, noctalia.tr("ui.minutes_short")) or time,
      fontWeight = "bold",
      color = tone(),
    }),
  }))
end

function update()
  isVertical = barWidget.isVertical()
  render()
end

noctalia.state.watch("hm.transport", function(v) transport = v or "UNKNOWN"; render() end)
noctalia.state.watch("hm.phase", function(v) phase = v or "IDLE"; render() end)
noctalia.state.watch("hm.state", function(v) state = v or "STOPPED"; render() end)
noctalia.state.watch("hm.paused", function(v) paused = v == true; render() end)
noctalia.state.watch("hm.work", function(v) work = tonumber(v) or work; render() end)
noctalia.state.watch("hm.time", function(v)
  time = v or "--:--"
  if state ~= "STOPPED" then render() end
end)

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
  noctalia.state.set("hm.cmd", state == "STOPPED" and "START" or "PAUSE")
end

function onScroll(_axis, steps, _startsGesture)
  if state ~= "STOPPED" then return end
  local delta = -(tonumber(steps) or 0)
  if delta == 0 then return end
  local target = math.max(1, math.min(180, work + delta))
  if target == work then return end
  work = target
  noctalia.state.set("hm.cmd", "SET_WORK:" .. tostring(target))
  render()
end

function onExit(_signal, _reason)
  clearTooltip()
end

transport = noctalia.state.get("hm.transport") or "UNKNOWN"
phase = noctalia.state.get("hm.phase") or "IDLE"
state = noctalia.state.get("hm.state") or "STOPPED"
paused = noctalia.state.get("hm.paused") == true
time = noctalia.state.get("hm.time") or "--:--"
work = tonumber(noctalia.state.get("hm.work")) or 25
render()
