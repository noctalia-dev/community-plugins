--!nonstrict
-- Bar widget: WhatsApp glyph plus an unread badge. Left click opens the panel.

local common = require("./lib/common.luau")
local style = require("./lib/style.luau")

local status = noctalia.state.get(common.KEY_STATUS) or { state = "connecting", detail = "" }
local unread = noctalia.state.get(common.KEY_UNREAD) or 0

local function tooltip(): string
  local state = status.state
  if state == "connected" then
    if unread > 0 then
      return noctalia.trp("bar.unread", unread)
    end
    return noctalia.tr("bar.no_unread")
  end
  return noctalia.tr("status." .. (state or "error"))
end

local function render()
  local problem = common.isProblem(status.state)
  local hide = noctalia.getConfig("hide_when_empty") == true
  barWidget.setVisible(not (hide and unread == 0 and not problem))

  local children = {
    ui.glyph({
      name = "brand-whatsapp",
      size = style.barGlyph,
      color = if problem then "error" else "on_surface",
    }),
  }
  if unread > 0 then
    table.insert(
      children,
      ui.row({ fill = "primary", radius = style.radius.card, paddingH = style.gap.sm, align = "center" }, {
        ui.label({
          text = common.badgeText(unread),
          color = "on_primary",
          fontWeight = "bold",
          fontSize = style.font.caption,
        }),
      })
    )
  end
  local container = if barWidget.isVertical() then ui.column else ui.row
  barWidget.render(container({ gap = style.gap.sm, align = "center" }, children))
  barWidget.setTooltip(tooltip())
end

noctalia.state.watch(common.KEY_STATUS, function(value)
  status = value or { state = "error", detail = "" }
  render()
end)

noctalia.state.watch(common.KEY_UNREAD, function(value)
  unread = tonumber(value) or 0
  render()
end)

function onClick()
  noctalia.togglePanel(common.panelId())
end

-- Nothing to poll: rendering follows the shared state.
function update()
  noctalia.setUpdateInterval(60000)
  render()
end

render()
