--!nonstrict
-- Bar widget: wattage while a USB-C port is charging or supplying power,
-- otherwise the connected-device count. A thin view over the snapshot that
-- service.luau publishes.
--
--   left click  -> toggle the device panel
--   right click -> ask the service for a fresh reading

local model = require("./lib/model.luau")

local PANEL_ID = "yangkx/usbeehive:devices"
local idleDisplay = noctalia.getConfig("idle_display") or "count"

local function tooltipFor(snap)
  if snap.status == "starting" then
    return noctalia.tr("status.starting")
  end
  local rows = {}
  if snap.error ~= nil then
    table.insert(rows, { noctalia.tr("tooltip.error"), snap.error })
  end
  if snap.flow.mode ~= "idle" then
    local value = snap.flow.mw > 0 and noctalia.tr("power.up_to", { watts = model.watts(snap.flow.mw) }) or ""
    table.insert(rows, { noctalia.tr("tooltip." .. snap.flow.mode), value })
  end
  for _, w in ipairs(snap.warnings) do
    table.insert(rows, { w.headline, w.summary })
  end
  table.insert(rows, { noctalia.tr("tooltip.devices"), tostring(snap.count) })
  for _, d in ipairs(snap.devices) do
    if d.isPeripheral then
      table.insert(rows, { d.headline, model.speed(d.linkSpeedMbps) })
    end
  end
  return rows
end

local function render(value)
  local snap = value or model.emptySnapshot()
  local flow = snap.flow
  local accent = #snap.warnings > 0 and "tertiary" or "primary"
  local visible, glyph, glyphColor, text = true, model.flowGlyph(flow.mode), accent, ""

  if snap.error ~= nil then
    glyph, glyphColor = "plug-x", "error"
  elseif flow.mode ~= "idle" then
    text = flow.mw > 0 and model.watts(flow.mw) or ""
  else
    visible = idleDisplay ~= "hidden"
    if #snap.warnings == 0 then
      glyphColor = snap.status == "starting" and "on_surface_variant" or "on_surface"
    end
    text = (idleDisplay == "count" and snap.count > 0) and tostring(snap.count) or ""
  end

  barWidget.setVisible(visible)
  barWidget.setGlyph(glyph)
  barWidget.setGlyphColor(glyphColor)
  barWidget.setColor("on_surface")
  barWidget.setText(text)
  barWidget.setTooltip(tooltipFor(snap))
end

noctalia.state.watch("snapshot", render)
render(noctalia.state.get("snapshot"))

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
  noctalia.state.set("command", model.refreshCommand(noctalia.nowMs()))
end
