--!nonstrict
-- Bar widget. Left click toggles, right click opens the presets panel, scroll
-- adds (up) or removes (down) time. All state lives in the service.

local C = require("./common.luau")

local status = C.status()

local function render()
  local on = status.active == true
  local color = if status.busy then "primary" elseif on then "tertiary" else "on_surface_variant"
  local glyph = if on then "coffee" else "coffee-off"

  local children = { ui.glyph({ name = glyph, color = color }) }
  local showRemaining = noctalia.getConfig("show_remaining") ~= false
  if status.remaining and showRemaining and not barWidget.isVertical() then
    table.insert(children, ui.label({ text = C.short(status.remaining), color = color }))
  end
  barWidget.render(ui.row({ gap = 4, align = "center" }, children))

  local rows = {
    { key = noctalia.tr("title"), value = if on then noctalia.tr("state.on") else noctalia.tr("state.off") },
  }
  if status.remaining then
    table.insert(rows, { key = noctalia.tr("tooltip.remaining"), value = C.short(status.remaining) })
  elseif on and not status.owned and not status.session then
    table.insert(rows, { key = "", value = noctalia.tr("tooltip.external") })
  end
  if status.lidHeld then
    table.insert(rows, { key = "", value = noctalia.tr("tooltip.lid") })
  end
  table.insert(rows, { key = "", value = noctalia.tr("tooltip.hint") })
  barWidget.setTooltip(rows)
end

noctalia.state.watch(C.STATUS, function(value)
  if type(value) == "table" then
    status = value
    render()
  end
end)

function onClick()
  C.send("toggle")
end

function onRightClick()
  noctalia.togglePanel(C.PANEL)
end

function onScroll(axis, steps, _startsGesture)
  if axis ~= "vertical" or steps == 0 then
    return
  end
  local step = tonumber(noctalia.getConfig("scroll_step_minutes")) or 15
  -- Negative steps are wheel-up: add time.
  C.send("add", tostring(-steps * step))
end

render()
