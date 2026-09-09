--!nonstrict
-- Bar widget: buds outline plus lowest battery.

local SNAPSHOT_KEY = "sankity/soundcore-buds:snapshot"

local NOISE_ANC = 1
local LEVEL_UNKNOWN = -1

local snapshot = noctalia.state.get(SNAPSHOT_KEY) or {}
local hideWhenDisconnected = noctalia.getConfig("hide_when_disconnected") ~= false
local iconSetting = noctalia.getConfig("icon") or "Auto"

local function iconVariant()
	if iconSetting == "Over-ear" then
		return "max"
	end
	if iconSetting == "Earbuds" then
		return "pro"
	end
	if snapshot.isHeadset == true then
		return "max"
	end
	return "pro"
end

local function modeText()
	local base = snapshot.noiseModeName or ""
	if snapshot.topMode == NOISE_ANC and tostring(snapshot.subModeName or "") ~= "" then
		return base .. " · " .. snapshot.subModeName
	end
	return base
end

local function iconPath()
	local base = "icons/" .. iconVariant()
	if snapshot.primaryState == "charging" then
		return base .. "-charging.svg"
	end
	if snapshot.primaryState == "low" then
		return base .. "-low.svg"
	end
	if noctalia.isDarkMode() then
		return base .. ".svg"
	end
	return base .. "-light.svg"
end

local function render()
	local connected = snapshot.connected == true
	local backendOk = snapshot.backendOk ~= false

	if hideWhenDisconnected then
		barWidget.setVisible(connected)
	else
		barWidget.setVisible(true)
	end

	local container = barWidget.isVertical() and ui.column or ui.row
	barWidget.render(container({ gap = 5, align = "center" }, {
		ui.image({
			path = iconPath(),
			width = 16,
			height = 16,
			fit = "contain",
			opacity = (connected and snapshot.stale ~= true) and 1 or 0.5,
		}),
		ui.label({ text = snapshot.primaryText ~= "" and snapshot.primaryText or "--" }),
	}))

	if connected then
		local rows = {}
		if snapshot.isHeadset == true then
			table.insert(rows, { key = noctalia.tr("panel.headphones"), value = snapshot.headsetText or "--" })
		else
			table.insert(rows, { key = noctalia.tr("panel.left"), value = snapshot.leftText or "--" })
			table.insert(rows, { key = noctalia.tr("panel.right"), value = snapshot.rightText or "--" })
			if snapshot.caseBattery.level ~= LEVEL_UNKNOWN then
				table.insert(rows, { key = noctalia.tr("panel.case"), value = snapshot.caseText or "--" })
			end
		end
		if snapshot.availableModes ~= nil and #snapshot.availableModes > 0 then
			table.insert(rows, { key = noctalia.tr("widget.mode"), value = modeText() })
		end
		if snapshot.findingSide ~= nil and snapshot.findingSide ~= "" then
			table.insert(rows, { key = noctalia.tr("widget.finding"), value = tostring(snapshot.findingSide) })
		end
		if snapshot.stale == true then
			table.insert(rows, { key = noctalia.tr("widget.stale"), value = "" })
		end
		barWidget.setTooltip(rows)
	else
		if not backendOk then
			barWidget.setTooltip(noctalia.tr("widget.openscq30_missing"))
		else
			barWidget.setTooltip(noctalia.tr("widget.not_connected"))
		end
	end
end

noctalia.state.watch(SNAPSHOT_KEY, function(value)
	if type(value) == "table" then
		snapshot = value
		render()
	end
end)

noctalia.setUpdateInterval(2000)

function update()
	-- Slow tick picks up light/dark switches with no state change.
	render()
end

render()
