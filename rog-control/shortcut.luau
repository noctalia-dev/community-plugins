--!nonstrict
-- ROG Control Control Center tile: the current performance mode.
-- Click steps to the next mode; right-click opens the panel.

local model = require("./lib/model.luau")

local snapshot = { available = false }

local function render()
  local a = snapshot.asusd
  local p = a ~= nil and model.profile(a.profile) or nil
  shortcut.setEnabled(snapshot.available == true)
  shortcut.setIcon(p ~= nil and p.glyph or "gauge")
  shortcut.setLabel(p ~= nil and noctalia.tr(p.key) or noctalia.tr("plugin.name"))
  -- "Active" marks the non-default modes, the way Do Not Disturb lights up.
  shortcut.setActive(p ~= nil and p.value ~= 0)
end

function onClick()
  noctalia.state.set(model.REQUEST, { action = "cycleProfile", value = 1, at = noctalia.nowMs() })
end

function onRightClick()
  noctalia.togglePanel(model.PANEL_ID)
end

noctalia.state.watch(model.STATE, function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

snapshot = noctalia.state.get(model.STATE) or snapshot
render()
