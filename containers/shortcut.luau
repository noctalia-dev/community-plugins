--!nonstrict
-- Control-center tile: the same count as the bar widget, same toggle.

local PANEL_ID = "davinci13/containers:panel"
local KEY_SNAPSHOT = "snapshot"

local snapshot = nil

local function render()
  local web = snapshot ~= nil and snapshot.web or 0
  shortcut.setLabel(noctalia.tr("shortcut.label") .. "  " .. tostring(web))
  shortcut.setIcon("container")
  shortcut.setActive(web > 0)
  shortcut.setEnabled(true)
end

snapshot = noctalia.state.get(KEY_SNAPSHOT)
noctalia.state.watch(KEY_SNAPSHOT, function(value)
  snapshot = value
  render()
end)

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

render()
