--!nonstrict

local status = noctalia.state.get("lid_guard_status") or {
  active = false,
  busy = false,
  available = true,
}
local requestId = 0

local function render()
  local active = status.active == true
  shortcut.setLabel(if active then noctalia.tr("shortcut.active") else noctalia.tr("shortcut.inactive"))
  shortcut.setIcon("shield-lock", "shield-off")
  shortcut.setActive(active)
  shortcut.setEnabled(status.available ~= false and status.busy ~= true)
end

noctalia.state.watch("lid_guard_status", function(value)
  if type(value) == "table" then
    status = value
    render()
  end
end)

render()

function onClick()
  if status.available == false or status.busy == true then return end
  requestId += 1
  noctalia.state.set("lid_guard_command", {
    action = "toggle",
    requestId = `shortcut-{requestId}`,
  })
end
