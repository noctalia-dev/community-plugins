--!nonstrict
-- UFW bar widget: a thin client. The service owns all state and model.barView decides what
-- to show; this only maps it onto barWidget calls.

local model = require("./model.luau")

local snapshot = nil

local function countPill(text)
  return ui.row({ paddingH = 4, align = "center", radius = 6, fill = "surface_container_high" }, {
    ui.label({ text = text, fontSize = 11 }),
  })
end

local function render()
  -- `== false` so an unset setting keeps its default (true).
  local view = model.barView(
    snapshot,
    noctalia.getConfig("show_label") ~= false,
    noctalia.getConfig("show_count") ~= false
  )
  local children = { ui.box({ width = 8, height = 8, radius = 4, fill = view.dot }) }
  if view.text ~= nil then
    table.insert(children, ui.label({ text = view.text }))
  end
  if view.count ~= nil then
    table.insert(children, countPill(view.count))
  end
  barWidget.render(ui.row({ gap = 4, align = "center" }, children))
  barWidget.setTooltip(view.tooltip)
end

-- Re-applies the view each tick; this is how a settings change takes effect.
function update()
  render()
end

function onClick()
  noctalia.togglePanel("3dprogramin/ufw:panel")
end

noctalia.state.watch("ufw.state", function(value)
  snapshot = value
  render()
end)

-- a bar loaded after the service (a reload, a second screen) draws the last snapshot at once
local initial = noctalia.state.get("ufw.state")
if type(initial) == "table" then
  snapshot = initial
end
render()

-- state.watch does not replay an old value, so ask the service for a snapshot.
noctalia.state.set("ufw.request", { action = "refresh" })
