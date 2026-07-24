--!nonstrict
-- Tailscale toggle — the [[shortcut]] control-center tile.
--
-- Active while Tailscale is up; click to bring the connection down, click
-- again to bring it up. Mirrors the state published by the poller service.

local snapshot = nil
local cmdNonce = 0

local function render()
  local state = snapshot and snapshot.state or "stopped"
  shortcut.setLabel(noctalia.tr("shortcut.label"))
  shortcut.setIcon("topology-star-3", "topology-star-3")
  shortcut.setActive(state == "running")
  shortcut.setEnabled(state == "running" or state == "stopped")
end

noctalia.state.watch("ts.snapshot", function(encoded)
  snapshot = encoded and noctalia.json.decode(encoded) or nil
  render()
end)

function onClick()
  local state = snapshot and snapshot.state or "stopped"
  cmdNonce += 1
  local action = state == "running" and "down" or "up"
  noctalia.state.set("ts.cmd", noctalia.json.encode({ n = cmdNonce, action = action }))
end

render()
