--!nonstrict
-- Bar indicator. Red while passwordless sudo is active; clicking it then
-- revokes the grant immediately. While inactive, clicking opens the duration
-- picker. Right click always opens the panel.

local common = require("./lib/common.luau")
local tr = noctalia.tr

local glyph = noctalia.getConfig("glyph") or "shield-lock"
local hideWhenInactive = noctalia.getConfig("hide_when_inactive") == true
local showCountdown = noctalia.getConfig("show_countdown") == true

local function render()
  local s = common.status()
  barWidget.setGlyph(glyph)

  if s.active then
    barWidget.setVisible(true)
    barWidget.setGlyphColor("error")
    barWidget.setColor("error")
    local remaining = s.mode == "timed" and (s.deadline - common.nowSec()) or nil
    if showCountdown and remaining then
      barWidget.setText(common.formatShort(remaining))
    else
      barWidget.setText("")
    end

    local rows = { { tr("tooltip.title"), tr("state.on") } }
    if s.mode == "timed" then
      table.insert(rows, { tr("tooltip.expires"), `{common.formatClock(s.deadline)} ({common.formatRemaining(remaining)})` })
    elseif s.mode == "permanent" then
      table.insert(rows, { tr("tooltip.expires"), tr("tooltip.never") })
    else
      table.insert(rows, { tr("tooltip.source"), tr("tooltip.external") })
    end
    table.insert(rows, { "", s.busy and tr("tooltip.working") or tr("tooltip.click_disable") })
    barWidget.setTooltip(rows)
  else
    barWidget.setVisible(not hideWhenInactive)
    barWidget.setGlyphColor("on_surface")
    barWidget.setColor("on_surface")
    barWidget.setText("")
    barWidget.setTooltip({
      { tr("tooltip.title"), tr("state.off") },
      { "", s.busy and tr("tooltip.waiting_auth") or tr("tooltip.click_enable") },
    })
  end
end

noctalia.state.watch("status", function()
  render()
end)

-- Keeps the countdown in the tooltip/label fresh; no sudo calls here.
function update()
  render()
end

function onClick()
  local s = common.status()
  if s.busy then
    return
  end
  if s.active then
    common.send("disable")
  else
    noctalia.togglePanel(common.PANEL)
  end
end

function onRightClick()
  noctalia.togglePanel(common.PANEL)
end

noctalia.setUpdateInterval(showCountdown and 1000 or 15000)
render()
