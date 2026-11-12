--!nonstrict
-- Control-center tile: same toggle as the widget/panel.
local PLUGIN = "treeonlinux/social-block"
local SERVICE = PLUGIN .. ":service"

local blocked = noctalia.state.get("blocked") == true

local function send(event)
  noctalia.runAsync({ "noctalia", "msg", "plugin", SERVICE, "all", event })
end

local function render()
  shortcut.setLabel(blocked and "Social ON" or "Social Block")
  shortcut.setIcon("shield-lock", "shield")
  shortcut.setActive(blocked)
  shortcut.setEnabled(true)
end

noctalia.state.watch("blocked", function(value)
  blocked = value == true
  render()
end)

function onClick()
  send("toggle")
end

render()
