-- widget.luau — bar widget entry.
--
-- Renders a compact "◷ 3h 42m" summary of today's tracked time, consuming
-- the service's shared state (never polls the compositor itself). Declarative
-- ui.* render with RTL support: on a vertical bar we stack (column); on a
-- horizontal bar the row follows the surface's writing direction, so glyph
-- and label order mirror naturally instead of assuming LTR.

local formatting = require("./lib/formatting.luau")

formatting._tr = noctalia.tr

local glyphSetting = noctalia.getConfig("glyph") or "clock-hour-4"
local showText = noctalia.getConfig("show_text") ~= false
local showGlyph = noctalia.getConfig("show_glyph") ~= false

-- Tick every second so the open session keeps counting between publishes.
noctalia.setUpdateInterval(1000)

local function render()
  local s = noctalia.state.get("wdid_state") or {}
  local paused = s.paused == true or s.tracking == false
  -- Phase 1 portability: unavailable compositor -> honest indicator, no
  -- fake live timer, compact as always.
  local unavailable = s.trackingAvailable == false

  -- The user can hide the widget from settings without removing it from the bar.
  barWidget.setVisible(noctalia.getConfig("show_bar_widget") ~= false)

  -- Today's total plus the live open session since the last publish (never
  -- extrapolated when tracking does not exist).
  local total = tonumber(s.todayTotal) or 0
  local since = tonumber(s.currentAppSinceMs)
  if not paused and not unavailable and since then
    total = total + math.max(0, math.floor((noctalia.nowMs() - since) / 1000))
  end

  local children = {}
  if showGlyph then
    children[#children + 1] = ui.glyph({
      name = unavailable and "plug-off" or (paused and "player-pause" or glyphSetting),
      size = 14,
      color = (paused or unavailable) and "on_surface/0.6" or "on_surface",
    })
  end
  if showText then
    children[#children + 1] = ui.label({
      text = formatting.fmtDuration(total),
      color = (paused or unavailable) and "on_surface/0.6" or "on_surface",
    })
  end
  if #children == 0 then
    children[1] = ui.glyph({ name = glyphSetting, size = 14 })
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 5, align = "center" }, children))

  -- Tooltip: slightly richer than the bar, still compact.
  local appsCount = tonumber(s.todayApps) or 0
  local detail
  if unavailable then
    detail = noctalia.tr("panel.unavailable")
  elseif paused then
    detail = noctalia.tr("widget.tooltip.paused")
  else
    detail = noctalia.tr("widget.tooltip.active")
      .. " "
      .. formatting.fmtDuration(total)
      .. " · "
      .. noctalia.trp("widget.tooltip.apps", appsCount, { count = appsCount })
    if type(s.currentAppName) == "string" and s.currentAppName ~= "" then
      detail = detail .. "\n" .. s.currentAppName
    end
  end
  barWidget.setTooltip(noctalia.tr("widget.tooltip.title") .. "\n" .. detail)
end

function update()
  render()
end

noctalia.state.watch("wdid_state", function(_value)
  render()
end)

function onClick()
  noctalia.togglePanel("alitura1/what-did-i-do:dashboard")
end

render()
