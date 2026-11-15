--!nonstrict
-- Tablet Display bar widget: shows whether the tablet display is on; click
-- opens the panel, right-click toggles Extend.

local common = require("./lib/common.luau")
local tr = common.tr

local snapshot = common.snapshot()

local function render()
  local active = common.isActive(snapshot)
  local problem = snapshot.available == false or #(snapshot.errors or {}) > 0
  barWidget.setGlyph(snapshot.mode == "mirror" and "copy" or "device-tablet")
  if problem then
    barWidget.setGlyphColor("error")
  elseif active then
    barWidget.setGlyphColor("primary")
  else
    barWidget.setGlyphColor("on_surface")
  end
  barWidget.setText("")

  local rows = { { tr("title"), common.statusLine(snapshot) } }
  local client = common.clientLine(snapshot)
  if client ~= "" then
    table.insert(rows, { tr("panel.moonlight"), client })
  end
  if problem then
    table.insert(rows, { tr("widget.problem"), tostring((snapshot.errors or {})[1] or tr("widget.see_panel")) })
  end
  table.insert(rows, { "", tr("widget.hint") })
  barWidget.setTooltip(rows)
end

noctalia.state.watch(common.STATE_KEY, function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

render()

function onClick()
  noctalia.togglePanel(common.PANEL_ID)
end

function onRightClick()
  if (snapshot.pending or "") ~= "" then
    return
  end
  common.send(common.isActive(snapshot) and "off" or "extend")
end
