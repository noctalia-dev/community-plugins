--!nonstrict
-- Docker & Podman Shipyard Quick Shortcut Tile

local PANEL_ID = "ishan0121/shipyard:manager"
local KEY_SNAPSHOT = "shipyard_snapshot"

local snapshot = noctalia.state.get(KEY_SNAPSHOT)

local function render()
  local containers = snapshot and snapshot.containers or {}
  local runningCount = 0
  for _, c in ipairs(containers) do
    if c.state == "running" then
      runningCount += 1
    end
  end

  shortcut.setLabel(noctalia.tr("name") .. " (" .. tostring(runningCount) .. ")")
  shortcut.setIcon("ship")
  shortcut.setActive(runningCount > 0)
  shortcut.setEnabled(true)
end

noctalia.state.watch(KEY_SNAPSHOT, function(val)
  snapshot = val
  render()
end)

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

render()
