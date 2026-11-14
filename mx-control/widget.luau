--!nonstrict
-- Bar capsule: glyph and battery of the device with the lowest known level, so
-- the capsule always shows whichever device needs attention first. Hovering
-- lists every device with its battery. Left click opens the panel and right
-- click asks for a fresh read; both are manifest actions, so they can be
-- rebound per widget instance.

local shared = require("./shared.luau")

local showValue = noctalia.getConfig("show_value")
local status = noctalia.state.get(shared.STATUS_KEY)

-- The device kind picks the glyph; anything but a keyboard reads as a mouse,
-- as this is the MX mouse plugin. A missing kind also falls back to the mouse.
local function glyphFor(device, online)
	local kind = tostring((type(device) == "table" and device.kind) or "mouse"):lower()
	local base = kind == "keyboard" and "keyboard" or "mouse"
	return online and base or (base .. "-off")
end

-- One row per device, lowest level first, so the top row is the capsule's value.
local function deviceRows()
	local rows = {}
	for _, device in ipairs(shared.devicesByLevel(status)) do
		local value = device.online and shared.batteryText(device) or noctalia.tr("panel.offline")
		rows[#rows + 1] = { key = device.name or "MX", value = value }
	end
	return rows
end

local function render()
	local device = shared.lowestDevice(status)
	local code = shared.stateCode(status, os.time())
	local online = device ~= nil and device.online and code == nil

	local color = "on_surface"
	if not online then
		color = "on_surface_variant"
	else
		color = shared.levelRole(shared.batteryLevel(device)) or color
	end

	local children = { ui.glyph({ name = glyphFor(device, online), size = 16, color = color }) }
	if showValue and online then
		children[#children + 1] = ui.label({ text = shared.batteryText(device), color = color })
	end
	barWidget.render(ui.row({ gap = 4, align = "center" }, children))

	if device == nil or code ~= nil then
		barWidget.setTooltip(noctalia.tr("state." .. (code or "no_devices")))
		return
	end
	barWidget.setTooltip(deviceRows())
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
