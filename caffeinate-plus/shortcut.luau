--!nonstrict
-- Control Center tile. Click toggles; right click opens the presets panel.

local C = require("./common.luau")

local status = C.status()

local function render()
  local label = noctalia.tr("title")
  if status.remaining then
    label = `{label} · {C.short(status.remaining)}`
  end
  shortcut.setLabel(label)
  shortcut.setIcon("coffee", "coffee-off")
  shortcut.setActive(status.active == true)
  shortcut.setEnabled(not status.busy)
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

render()
