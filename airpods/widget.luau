--!nonstrict
-- Bar widget. Shows the device outline (buds / pro / max, matching the model
-- the daemon reports) plus the lowest battery. Left-click opens the panel and
-- right-click cycles the listening mode via the manifest actions, so no pointer
-- callbacks live here.

local SNAPSHOT_KEY = "airpods_snapshot"

local snapshot = noctalia.state.get(SNAPSHOT_KEY) or {}
local hideWhenDisconnected = noctalia.getConfig("hide_when_disconnected") ~= false

local function variant()
	if snapshot.isHeadset == true then
		return "max"
	end
	if snapshot.isProSeries == true then
		return "pro"
	end
	return "buds"
end

local function iconPath()
	local base = variant()
	if snapshot.primaryState == "charging" then
		return "icons/" .. base .. "-charging.svg"
	end
	if snapshot.primaryState == "low" then
		return "icons/" .. base .. "-low.svg"
	end
	return "icons/" .. base .. (noctalia.isDarkMode() and ".svg" or "-light.svg")
end

local function trValue(value, onKey, offKey)
	if value == true then
		return noctalia.tr(onKey)
	end
	return noctalia.tr(offKey)
end

local function render()
	local hasAirPods = snapshot.hasAirPods == true
	local hasBattery = snapshot.hasBattery == true
	local daemonReachable = snapshot.daemonReachable == true

	if hideWhenDisconnected then
		barWidget.setVisible(hasAirPods or hasBattery)
	else
		barWidget.setVisible(true)
	end

	local container = barWidget.isVertical() and ui.column or ui.row
	local children = {
		ui.image({
			path = iconPath(),
			width = 16,
			height = 16,
			fit = "contain",
			opacity = hasAirPods and 1 or 0.5,
		}),
	}
	barWidget.render(container({ gap = 5, align = "center" }, children))

	local rows = {}
	if hasAirPods then
		if snapshot.isHeadset == true then
			table.insert(rows, { key = noctalia.tr("panel.headphones"), value = snapshot.headsetText or "--" })
		else
			table.insert(rows, { key = noctalia.tr("panel.left"), value = snapshot.leftText or "--" })
			table.insert(rows, { key = noctalia.tr("panel.right"), value = snapshot.rightText or "--" })
			table.insert(rows, { key = noctalia.tr("panel.case"), value = snapshot.caseText or "--" })
		end
		if snapshot.noiseModeName ~= "" then
			table.insert(rows, { key = noctalia.tr("widget.mode"), value = snapshot.noiseModeName })
		end
		if snapshot.supportsConversationalAwareness == true then
			table.insert(rows, {
				key = noctalia.tr("panel.conversation_awareness"),
				value = trValue(snapshot.conversationalAwareness, "common.on", "common.off"),
			})
		end
		table.insert(rows, { key = noctalia.tr("panel.ear_detection"), value = snapshot.earDetectionName or "" })
		barWidget.setTooltip(rows)
	else
		barWidget.setTooltip(daemonReachable and noctalia.tr("widget.not_connected") or noctalia.tr("widget.daemon_down"))
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
	-- Re-render on a slow tick so a light/dark theme switch picks up the right
	-- icon variant even when the daemon's status has not changed.
	render()
end

render()
