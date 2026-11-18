--!nonstrict

local COMMAND_KEY = "hotspot_command"

local status = noctalia.state.get("hotspot_status") or {
  active = false,
  busy = false,
  available = true,
}

local function sendCommand(action)
  noctalia.state.set(COMMAND_KEY, { action = action })
end

local function render()
  local active = status.active == true
  shortcut.setLabel(if active then noctalia.tr("shortcut.active") else noctalia.tr("shortcut.inactive"))
  shortcut.setIcon("router", "wifi-off")
  shortcut.setActive(active)
  shortcut.setEnabled(status.available ~= false and status.busy ~= true)
end

noctalia.state.watch("hotspot_status", function(value)
  if type(value) == "table" then
    status = value
    render()
  end
end)

render()

function onClick()
  if status.available == false or status.busy == true then return end
  sendCommand("toggle")
end
