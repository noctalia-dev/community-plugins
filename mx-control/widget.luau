--!nonstrict
-- Bar capsule: mouse glyph and battery of the MX device the service reports.
-- Left click opens the panel and right click asks for a fresh read; both are
-- manifest actions, so they can be rebound per widget instance.

local shared = require("./shared.luau")

local showValue = noctalia.getConfig("show_value")
local status = noctalia.state.get(shared.STATUS_KEY)

local function render()
	local device = shared.pickDevice(status)
	local code = shared.stateCode(status, os.time())
	local online = device ~= nil and device.online and code == nil

	local color = "on_surface"
	if not online then
		color = "on_surface_variant"
	else
		color = shared.levelRole(shared.batteryLevel(device)) or color
	end

	local children = { ui.glyph({ name = online and "mouse" or "mouse-off", size = 16, color = color }) }
	if showValue and online then
		children[#children + 1] = ui.label({ text = shared.batteryText(device), color = color })
	end
	barWidget.render(ui.row({ gap = 4, align = "center" }, children))

	if device == nil or code ~= nil then
		barWidget.setTooltip(noctalia.tr("state." .. (code or "no_devices")))
		return
	end
	barWidget.setTooltip({
		{ key = device.name or "MX", value = online and shared.batteryText(device) or noctalia.tr("panel.offline") },
		{ key = noctalia.tr("panel.connection"), value = tostring(device.connection or "") },
	})
end

noctalia.state.watch(shared.STATUS_KEY, function(value)
	status = value
	render()
end)

-- Re-render now and then so a stale snapshot is shown as offline without a new publish.
function update()
	noctalia.setUpdateInterval(30000)
	render()
end
