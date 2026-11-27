--!nonstrict
-- Bar widget: the state of one unit (set per widget instance) as a circle glyph,
-- filled while the unit is active. Clicking opens the controls panel for that unit.

local common = require("./common.luau")

local POLL_MS = 3000

local tr = common.tr
local status = nil -- last queried { load, active, sub, description }, nil when unknown
local inflight = false

local function target()
  local unit = noctalia.getConfig("unit")
  unit = if type(unit) == "string" then common.trim(unit) else ""
  local scope = if noctalia.getConfig("scope") == "user" then "user" else "system"
  return unit, scope
end

local function render()
  local unit, scope = target()
  if unit == "" then
    barWidget.setGlyph("circle-dashed")
    barWidget.setGlyphColor("on_surface_variant")
    barWidget.setText("")
    barWidget.setTooltip(tr("widget.no-unit"))
    return
  end

  local glyph, color = common.stateIcon(status)
  barWidget.setGlyph(glyph)
  barWidget.setGlyphColor(color)
  local label = string.gsub(unit, "%.service$", "")
  barWidget.setText(if noctalia.getConfig("show_label") == true then label else "")
  barWidget.setTooltip({
    { key = tr("widget.tooltip.unit"), value = unit },
    { key = tr("widget.tooltip.scope"), value = common.scopeLabel(scope) },
    { key = tr("widget.tooltip.state"), value = common.stateText(status) },
  })
end

local function poll()
  local unit, scope = target()
  if unit == "" then
    status = nil
    render()
    return
  end
  if inflight then
    return
  end
  inflight = true
  local ok = common.queryUnit(scope, unit, function(st)
    inflight = false
    -- Drop a reply for a unit this instance no longer shows (settings changed meanwhile).
    local nowUnit, nowScope = target()
    if nowUnit == unit and nowScope == scope then
      status = st
    end
    render()
  end)
  if not ok then
    inflight = false
  end
end

noctalia.setUpdateInterval(POLL_MS)

function update()
  poll()
end

-- The action service publishes "result" when an action finishes: refresh right away.
noctalia.state.watch("result", function(r)
  if type(r) ~= "table" then
    return
  end
  local unit, scope = target()
  if r.unit == unit and r.scope == scope then
    poll()
  end
end)

function onClick()
  local unit, scope = target()
  if unit == "" then
    noctalia.notify(tr("widget.no-unit"), tr("widget.configure-hint"))
    return
  end
  noctalia.state.set("panel_target", { unit = unit, scope = scope, status = status, seq = noctalia.nowMs() })
  noctalia.togglePanel(common.PANEL_ID)
end

render()
poll()
