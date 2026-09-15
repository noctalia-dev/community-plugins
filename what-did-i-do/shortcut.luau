-- shortcut.luau — control-center quick toggle for tracking.
--
-- Add from Settings → Control Center shortcuts. Shows the current tracking
-- state (from the service's shared state) and toggles pause/resume on click.

local active = false

local function render()
  local s = noctalia.state.get("wdid_state") or {}
  local unavailable = s.trackingAvailable == false
  local tracking = s.tracking ~= false
  active = tracking and not unavailable
  if unavailable then
    -- Honest tile: tracking does not exist on this compositor, so the tile
    -- must not present itself as a live pause/resume control.
    shortcut.setLabel(noctalia.tr("panel.unavailable"))
    shortcut.setIcon("plug-off")
    shortcut.setActive(false)
    return
  end
  shortcut.setLabel(tracking and noctalia.tr("shortcut.label") or noctalia.tr("shortcut.description"))
  shortcut.setIcon(tracking and "clock-hour-4" or "player-pause")
  shortcut.setActive(tracking)
end

function onClick()
  local s = noctalia.state.get("wdid_state") or {}
  if s.trackingAvailable == false then
    return -- nothing to toggle: tracking is unavailable on this compositor
  end
  noctalia.state.set("wdid_command", { op = "toggle" })
  -- Optimistic flip; the watch below corrects it on the next publish.
  active = not active
  render()
end

noctalia.state.watch("wdid_state", function(_value)
  render()
end)

render()
