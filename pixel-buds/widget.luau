--!nonstrict
-- Bar widget. Shows a headphones glyph plus the emptiest bud's battery (or the
-- single BlueZ percentage for buds in battery-only mode).
-- Left-click opens the panel and right-click cycles the noise-control mode via
-- the manifest actions, so no pointer callbacks live here.

local SNAPSHOT_KEY = "pixelbuds_snapshot"

local snapshot = noctalia.state.get(SNAPSHOT_KEY) or {}
local hideWhenDisconnected = noctalia.getConfig("hide_when_disconnected") ~= false
local showPercentage = noctalia.getConfig("show_percentage") ~= false

local function glyphColor()
	if snapshot.hasBuds ~= true then
		return "on_surface_variant"
	end
	if snapshot.primaryState == "low" then
		return "error"
	end
	if snapshot.primaryState == "charging" then
		return "primary"
	end
	return "on_surface"
end

local function render()
	local hasBuds = snapshot.hasBuds == true

	if hideWhenDisconnected then
		barWidget.setVisible(snapshot.connected == true)
	else
		barWidget.setVisible(true)
	end

	local container = barWidget.isVertical() and ui.column or ui.row
	local children = {
		ui.glyph({
			name = hasBuds and "headphones" or "headphones-off",
			size = 16,
			color = glyphColor(),
		}),
	}
	if showPercentage and hasBuds and tostring(snapshot.primaryText or "") ~= "" then
		table.insert(children, ui.label({ text = snapshot.primaryText }))
	end
	barWidget.render(container({ gap = 5, align = "center" }, children))

	if hasBuds and snapshot.mode == "basic" then
		barWidget.setTooltip({
			{ key = noctalia.tr("panel.buds"), value = snapshot.combinedText or "--" },
		})
	elseif hasBuds then
		local rows = {
			{ key = noctalia.tr("panel.left"), value = snapshot.leftText or "--" },
			{ key = noctalia.tr("panel.right"), value = snapshot.rightText or "--" },
			{ key = noctalia.tr("panel.case"), value = snapshot.caseText or "--" },
		}
		if snapshot.anc ~= "unknown" and tostring(snapshot.ancName or "") ~= "" then
			table.insert(rows, { key = noctalia.tr("widget.mode"), value = snapshot.ancName })
		end
		barWidget.setTooltip(rows)
	elseif snapshot.pbpctrlFound == false and snapshot.mode ~= "basic" then
		barWidget.setTooltip(noctalia.tr("widget.pbpctrl_missing"))
	elseif snapshot.connected == true then
		barWidget.setTooltip(noctalia.tr("widget.unreachable"))
	else
		barWidget.setTooltip(noctalia.tr("widget.not_connected"))
	end
end

noctalia.state.watch(SNAPSHOT_KEY, function(value)
	if type(value) == "table" then
		snapshot = value
		render()
	end
end)

render()
