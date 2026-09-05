--!nonstrict
-- Bar widget for OPPO Pods

local SNAPSHOT_KEY = "oppo_pods_snapshot"

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
			{ key = noctalia.tr("panel.title"), value = noctalia.tr("widget.not_connected") },
			{ key = noctalia.tr("widget.action.left_click"), value = noctalia.tr("panel.title") }
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

	-- Pick battery level to show on bar (minimum of active buds, or whichever is available)
	local bLevel = -1
	local l = snapshot.battery_left or -1
	local r = snapshot.battery_right or -1

	if l >= 0 and r >= 0 then
		bLevel = math.min(l, r)
	elseif l >= 0 then
		bLevel = l
	elseif r >= 0 then
		bLevel = r
	end

	if bLevel >= 0 and not barWidget.isVertical() then
		barWidget.setText(tostring(bLevel) .. "%")
	else
		barWidget.setText("")
	end

	-- Build detailed tooltip rows
	local tooltipRows = {
		{ key = "Device", value = snapshot.model_name or snapshot.device_name or noctalia.tr("panel.title") },
		{ key = noctalia.tr("widget.mode"), value = getModeName(mode) },
	}

	if l >= 0 then
		local chargingStr = snapshot.charging_left and (" (" .. noctalia.tr("panel.charging") .. ")") or ""
		table.insert(tooltipRows, { key = noctalia.tr("panel.left"), value = tostring(l) .. "%" .. chargingStr })
	end

	if r >= 0 then
		local chargingStr = snapshot.charging_right and (" (" .. noctalia.tr("panel.charging") .. ")") or ""
		table.insert(tooltipRows, { key = noctalia.tr("panel.right"), value = tostring(r) .. "%" .. chargingStr })
	end

	if snapshot.battery_case and snapshot.battery_case > 0 then
		local metaStr = ""
		if snapshot.charging_case then
			metaStr = " (" .. noctalia.tr("panel.charging") .. ")"
		elseif snapshot.case_offline then
			metaStr = " (" .. noctalia.tr("panel.case_offline") .. ")"
		end
		table.insert(tooltipRows, { key = noctalia.tr("panel.case"), value = tostring(snapshot.battery_case) .. "%" .. metaStr })
	end

	table.insert(tooltipRows, { key = "Left Click", value = noctalia.tr("widget.action.left_click") })
	table.insert(tooltipRows, { key = "Right Click", value = noctalia.tr("widget.action.right_click") })

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
