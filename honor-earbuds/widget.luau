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

local function availableLevel(value)
	if type(value) ~= "number" or value <= 0 then
		return nil
	end
	return value
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
		barWidget.setGlyphColor("outline_variant")
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

	-- Overall earbud battery: ignore an earbud that reports 0 (in the case / off)
	-- and average the remaining earbuds.
	local l = availableLevel(snapshot.battery_left)
	local r = availableLevel(snapshot.battery_right)

	local bLevel = nil
	if l and r then
		bLevel = math.floor((l + r) / 2 + 0.5)
	elseif l then
		bLevel = l
	elseif r then
		bLevel = r
	end

	if bLevel ~= nil then
		barWidget.setText(tostring(bLevel) .. "%")
		if barWidget.isVertical() then
			barWidget.setGlyphColor(bLevel <= 20 and "error" or "default")
		end
	else
		barWidget.setText("")
	end

	local tooltipRows = {
		{ key = noctalia.tr("panel.title"), value = snapshot.model_name or "Honor Choice Earbuds X5" },
		{ key = noctalia.tr("widget.mode"), value = getModeName(mode) },
	}

	if snapshot.battery_left ~= nil then
		local chg = snapshot.charging_left and (" (" .. noctalia.tr("panel.charging") .. ")") or ""
		local value = l ~= nil and (tostring(l) .. "%" .. chg) or noctalia.tr("panel.status.disconnected")
		table.insert(tooltipRows, { key = noctalia.tr("panel.left"), value = value })
	end

	if snapshot.battery_right ~= nil then
		local chg = snapshot.charging_right and (" (" .. noctalia.tr("panel.charging") .. ")") or ""
		local value = r ~= nil and (tostring(r) .. "%" .. chg) or noctalia.tr("panel.status.disconnected")
		table.insert(tooltipRows, { key = noctalia.tr("panel.right"), value = value })
	end

	if snapshot.battery_case then
		local chg = snapshot.charging_case and (" (" .. noctalia.tr("panel.charging") .. ")") or ""
		table.insert(tooltipRows, { key = noctalia.tr("panel.case"), value = tostring(snapshot.battery_case) .. "%" .. chg })
	end

	table.insert(tooltipRows, { key = noctalia.tr("widget.action.left_click_label"), value = noctalia.tr("widget.action.left_click") })
	table.insert(tooltipRows, { key = noctalia.tr("widget.action.right_click_label"), value = noctalia.tr("widget.action.right_click") })

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
