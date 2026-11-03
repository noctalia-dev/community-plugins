--!nonstrict
-- Bar widget for Nothing/CMF earbuds

local STATUS_KEY = "nothing_ear_status"

local status = noctalia.state.get(STATUS_KEY) or {}

local function showLiveStatus()
	return noctalia.getConfig("show_in_bar") ~= false
end

local function showPercentage()
	return noctalia.getConfig("show_percentage") ~= false
end

local ICON_SIZE = 18

-- Icon shows what's connected (case > both buds > one bud) with a badge for
-- the noise mode. Images can't follow the theme color like glyphs do, so
-- each comes in a dark and a light tint.
local function setIcon(name)
	local file = "icons/bar-" .. name .. (noctalia.isDarkMode() and ".svg" or "-light.svg")
	barWidget.setImage(noctalia.pluginDir() .. "/" .. file, false, ICON_SIZE)
end

local function ancName(anc)
	if anc.mode == "anc" then
		local name = noctalia.tr("panel.mode.anc")
		if anc.strength ~= nil then
			name = name .. " (" .. noctalia.tr("panel.strength." .. anc.strength) .. ")"
		end
		return name
	elseif anc.mode == "transparency" then
		return noctalia.tr("panel.mode.transparency")
	end
	return noctalia.tr("panel.mode.off")
end

local function levelText(entry)
	local text = tostring(entry.level) .. "%"
	if entry.charging then
		text = text .. " (" .. noctalia.tr("panel.charging") .. ")"
	end
	return text
end

local function clickRows()
	return {
		{ key = noctalia.tr("widget.click.left"), value = noctalia.tr("widget.action.left_click") },
		{ key = noctalia.tr("widget.click.right"), value = noctalia.tr("widget.action.right_click") },
	}
end

local function render()
	barWidget.setVisible(true)

	if status.unconfigured then
		setIcon("disconnected")
		barWidget.setText("")
		barWidget.setTooltip({
			{ key = noctalia.tr("panel.title"), value = noctalia.tr("widget.not_configured") },
		})
		return
	end

	local connected = status.connected == true
	if not connected then
		setIcon("disconnected")
		barWidget.setText("")
		local rows = { { key = noctalia.tr("panel.title"), value = noctalia.tr("widget.not_connected") } }
		table.insert(rows, clickRows()[1])
		barWidget.setTooltip(rows)
		return
	end

	local anc = status.anc or {}
	local battery = status.battery or {}
	local hasLeft = type(battery.left) == "table"
	local hasRight = type(battery.right) == "table"
	local base = "pair"
	if type(battery.case) == "table" then
		base = "case"
	elseif hasLeft and not hasRight then
		base = "left"
	elseif hasRight and not hasLeft then
		base = "right"
	end
	local mode = (anc.mode == "anc" or anc.mode == "transparency") and anc.mode or "off"
	setIcon(base .. "-" .. mode)

	local l = battery.left and battery.left.level or nil
	local r = battery.right and battery.right.level or nil
	local level = nil
	if l ~= nil and r ~= nil then
		level = math.min(l, r)
	else
		level = l or r
	end

	if level ~= nil and not barWidget.isVertical() and showLiveStatus() then
		barWidget.setText(showPercentage() and (tostring(level) .. "%") or tostring(level))
	else
		barWidget.setText("")
	end

	local model = status.model or {}
	local tooltipRows = {
		{ key = model.name or noctalia.tr("panel.title"), value = noctalia.tr("panel.status.connected") },
	}
	-- Same left / case / right order as the panel and desktop widget.
	if type(battery.left) == "table" then
		table.insert(tooltipRows, { key = noctalia.tr("panel.left"), value = levelText(battery.left) })
	end
	if type(battery.case) == "table" then
		table.insert(tooltipRows, { key = noctalia.tr("panel.case"), value = levelText(battery.case) })
	end
	if type(battery.right) == "table" then
		table.insert(tooltipRows, { key = noctalia.tr("panel.right"), value = levelText(battery.right) })
	end
	if model.anc ~= false then
		table.insert(tooltipRows, { key = noctalia.tr("panel.noise_control"), value = ancName(anc) })
	end
	if status.mono_active then
		table.insert(tooltipRows, { key = noctalia.tr("panel.mono.title"), value = noctalia.tr("widget.on") })
	end
	for _, row in ipairs(clickRows()) do
		table.insert(tooltipRows, row)
	end
	barWidget.setTooltip(tooltipRows)
end

noctalia.state.watch(STATUS_KEY, function(value)
	if type(value) == "table" then
		status = value
		render()
	end
end)

function onConfigChanged()
	render()
end

render()
