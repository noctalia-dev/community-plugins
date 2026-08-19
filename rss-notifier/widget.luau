-- widget.luau
-- Bar widget: RSS glyph with a colored pill (badge) of unread items next to
-- it on the left side, published by the service via noctalia.state.

local unread = 0

local function render()
  local children = {}

  if unread > 0 then
    -- pill: a container with a colored background and rounded corners, with
    -- the number inside - the closest the declarative API gets to a "badge"
    table.insert(children, ui.row({
      fill     = "primary",
      radius   = 8,
      paddingH = 5,
      paddingV = 1,
      align    = "center",
      justify  = "center",
    }, {
      ui.label({ text = tostring(unread), fontSize = 10, fontWeight = "bold", color = "on_primary" }),
    }))
  end

  table.insert(children, ui.glyph({ name = noctalia.getConfig("glyph") or "rss", size = 14 }))

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 4, align = "center" }, children))

  barWidget.setTooltip(unread > 0 and (tostring(unread) .. " novo(s) item(ns) nos feeds") or "Nenhum item novo")
end

noctalia.state.watch("unread", function(value)
  unread = value or 0
  render()
end)

render()

function update()
  noctalia.setUpdateInterval(5000) -- just keeps the widget "alive"; real data comes from state
end

function onConfigChanged()
  render() -- picks up the new glyph when the user changes the icon in the widget settings
end

function onClick()
  -- opens/closes the item list popup; the panel itself marks everything as
  -- read (resets the badge) when it's opened, via IPC to the service
  noctalia.togglePanel("nilsonlinux/rss-notifier:Panel")
end

function onRightClick()
  -- right click: forces an immediate feed check by sending an IPC event to
  -- the [[service]] entry (which is a singleton, target "all")
  noctalia.runAsync("noctalia msg plugin nilsonlinux/rss-notifier:fetcher all refresh")
  noctalia.notify("RSS/Atom Notifier", "Atualizando feeds...")
end

function onIpc(event, payload)
  if event == "set" then
    unread = tonumber(payload) or 0
    render()
  end
end
