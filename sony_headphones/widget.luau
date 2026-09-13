--!nonstrict
-- Bar widget for Sony Headphones

local SNAPSHOT_KEY = "sony_headphones_snapshot"

local snapshot = noctalia.state.get(SNAPSHOT_KEY) or {}
local hideWhenDisconnected = noctalia.getConfig("hide_when_disconnected") ~= false

local function getModeName(mode)
	if mode == "anc" then
		return noctalia.tr("panel.mode.anc")
	elseif mode == "transparency" then
		return noctalia.tr("panel.mode.transparency")
	elseif mode == "off" then
		return noctalia.tr("panel.mode.off")
	end
	return mode or ""
end

local function render()
	local connected = snapshot.connected == true

	if hideWhenDisconnected then
		barWidget.setVisible(connected)
	else
		barWidget.setVisible(true)
	end

	if not connected then
		barWidget.setGlyph("headphones-off")
		barWidget.setGlyphColor("disabled")
		barWidget.setText("")
		barWidget.setTooltip({
			{ key = noctalia.tr("widget.status"), value = noctalia.tr("widget.not_connected") },
			{ key = noctalia.tr("widget.action.left_click"), value = noctalia.tr("widget.action.open_controls") },
		})
		return
	end

	local mode = snapshot.noise_mode or "off"
	if mode == "anc" then
		barWidget.setGlyph("shield-check")
		barWidget.setGlyphColor("primary")
	elseif mode == "transparency" then
		barWidget.setGlyph("ear")
		barWidget.setGlyphColor("secondary")
	else
		barWidget.setGlyph("headphones")
		barWidget.setGlyphColor("default")
	end

	local bLevel = snapshot.battery
	if bLevel == nil or bLevel < 0 then
		bLevel = snapshot.battery_left
	end
	if bLevel == nil then
		bLevel = -1
	end

	if bLevel >= 0 and not barWidget.isVertical() then
		barWidget.setText(tostring(bLevel) .. "%")
	else
		barWidget.setText("")
	end

	local tooltipRows = {
		{ key = noctalia.tr("widget.device"), value = snapshot.model_name or snapshot.device_name or noctalia.tr("panel.title") },
		{ key = noctalia.tr("widget.mode"), value = getModeName(mode) },
	}

	if mode == "transparency" and snapshot.ambient_level ~= nil then
		table.insert(tooltipRows, { key = noctalia.tr("panel.ambient_level"), value = tostring(snapshot.ambient_level) })
	end

	if bLevel >= 0 then
		local chargingStr = snapshot.charging and (" (" .. noctalia.tr("panel.charging") .. ")") or ""
		table.insert(tooltipRows, { key = noctalia.tr("panel.battery"), value = tostring(bLevel) .. "%" .. chargingStr })
	end

	table.insert(tooltipRows, { key = noctalia.tr("widget.action.left_click"), value = noctalia.tr("widget.action.open_controls") })
	table.insert(tooltipRows, { key = noctalia.tr("widget.action.right_click"), value = noctalia.tr("widget.action.cycle_noise") })

	barWidget.setTooltip(tooltipRows)
end

noctalia.state.watch(SNAPSHOT_KEY, function(value)
	if type(value) == "table" then
		snapshot = value
		render()
	end
end)

function onConfigChanged()
	hideWhenDisconnected = noctalia.getConfig("hide_when_disconnected") ~= false
	render()
end

render()
