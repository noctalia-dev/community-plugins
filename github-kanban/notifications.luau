-- Notifications have their own scheduler; legacy keeps the dashboard interval.
local Notifications = require("./lib/notifications.luau")
local Data = require("./lib/data.luau")
local notifications = Notifications.new(noctalia, Data)

-- A cheap scheduler tick also services coalesced refresh requests after the
-- server polling window; it does not issue an API request on each tick.
noctalia.setUpdateInterval(5000)
noctalia.state.watch("notification_action", function(action) notifications.action(action) end)
notifications.refresh()

function update() notifications.update() end
function onEnable() notifications.refresh() end
function onConfigChanged() notifications.configure() end
function onIpc(event)
  if event == "refresh" then notifications.refresh() end
end
