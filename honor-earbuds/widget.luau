--!nonstrict
-- Bar widget for Honor Choice Earbuds X5

local SNAPSHOT_KEY = "honor_earbuds_snapshot"

local snapshot = noctalia.state.get(SNAPSHOT_KEY) or {}
local hideWhenDisconnected = noctalia.getConfig("hide_when_disconnected") == true

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
		barWidget.setGlyphColor("outline")
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

	-- Battery to show on the bar: minimum of available earbuds
	local bLevel = -1
	local l = snapshot.battery_left
	local r = snapshot.battery_right

	if l and r then
		bLevel = math.min(l, r)
	elseif l then
		bLevel = l
	elseif r then
		bLevel = r
	end

	if bLevel >= 0 and not barWidget.isVertical() then
		barWidget.setText(tostring(bLevel) .. "%")
	else
		barWidget.setText("")
	end

	local tooltipRows = {
		{ key = "Device", value = snapshot.model_name or "Honor Choice Earbuds X5" },
		{ key = noctalia.tr("widget.mode"), value = getModeName(mode) },
	}

	if l then
		local chg = snapshot.charging_left and (" (" .. noctalia.tr("panel.charging") .. ")") or ""
		table.insert(tooltipRows, { key = noctalia.tr("panel.left"), value = tostring(l) .. "%" .. chg })
	end

	if r then
		local chg = snapshot.charging_right and (" (" .. noctalia.tr("panel.charging") .. ")") or ""
		table.insert(tooltipRows, { key = noctalia.tr("panel.right"), value = tostring(r) .. "%" .. chg })
	end

	if snapshot.battery_case then
		local chg = snapshot.charging_case and (" (" .. noctalia.tr("panel.charging") .. ")") or ""
		table.insert(tooltipRows, { key = noctalia.tr("panel.case"), value = tostring(snapshot.battery_case) .. "%" .. chg })
	end

	table.insert(tooltipRows, { key = "ЛКМ", value = noctalia.tr("widget.action.left_click") })
	table.insert(tooltipRows, { key = "ПКМ", value = noctalia.tr("widget.action.right_click") })

	barWidget.setTooltip(tooltipRows)
end

noctalia.state.watch(SNAPSHOT_KEY, function(value)
	if type(value) == "table" then
		snapshot = value
		render()
	end
end)

function onConfigChanged()
	hideWhenDisconnected = noctalia.getConfig("hide_when_disconnected") == true
	render()
end

render()
