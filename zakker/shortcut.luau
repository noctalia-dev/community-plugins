-- Control-center tile: toggles periodic reminders on/off.
-- State is shared with the service via the in-memory channel.

local function isOn()
  return noctalia.state.get("zakker/enabled") ~= false
end

local function render()
  shortcut.setLabel("Zakker")
  if isOn() then
    shortcut.setIcon("bell")
  else
    shortcut.setIcon("bell-off")
  end
  shortcut.setActive(isOn())
end

render()

function onClick()
  local on = not isOn()
  noctalia.state.set("zakker/enabled", on)
  render()
  if on then
    noctalia.notify("Zakker", "Reminders resumed")
  else
    noctalia.notify("Zakker", "Reminders paused")
  end
end
