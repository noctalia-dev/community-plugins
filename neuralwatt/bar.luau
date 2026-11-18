--!nonstrict
-- Bar widget entry: the Neuralwatt energy capsule.
--
--   barWidget.render(tree)      declarative ui.* tree (replaces the default row)
--   barWidget.isVertical()      a row in a horizontal bar, a column in a side bar
--   barWidget.setTooltip(rows)  structured key/value tooltip
--   noctalia.togglePanel(id)    left click opens the usage panel
--
-- The widget owns no polling logic: it reads the shared "quota" state, and a
-- right click asks the service for a fresh reading.

local util = require("./lib/util.luau")

local quota = noctalia.state.get("quota")
local isVertical = false

-- Which reading the capsule prints, from its own widget setting.
local function mode()
	local value = noctalia.getConfig("bar_mode")
	if value == "remaining" or value == "percent" or value == "none" then
		return value
	end
	return "used"
end

local function headline(q, m)
	if m == "percent" then
		-- No subscription (or an unusable fraction) still falls through to the
		-- credit balance below, instead of showing an empty capsule.
		local percent = util.pct(q.kwhFraction)
		if percent then
			return percent
		end
	end
	if m == "remaining" and q.kwhRemaining then
		return noctalia.tr("bar.remaining", { kwh = util.kwh(q.kwhRemaining) })
	end
	if q.kwhUsed and q.kwhIncluded then
		return string.format("%s/%s kWh", util.kwhValue(q.kwhUsed), util.kwhValue(q.kwhIncluded))
	end
	if q.creditsRemaining then
		return util.money(q.creditsRemaining)
	end
	return nil
end

-- The tooltip carries the detail the capsule cannot: a key/value row per fact,
-- so hovering answers "how much is left and when does it renew".
local function tooltipRows(q)
	local rows = {}
	local function row(key, value)
		if value ~= nil and value ~= "" then
			table.insert(rows, { key = key, value = value })
		end
	end

	if q.kwhUsed and q.kwhIncluded then
		row(noctalia.tr("field.allowance"), string.format("%s / %s kWh", util.kwhValue(q.kwhUsed), util.kwhValue(q.kwhIncluded)))
	end
	if q.kwhRemaining then
		row(noctalia.tr("field.remaining"), util.kwh(q.kwhRemaining))
	end
	-- Recomputed here, not read from state: a countdown cached at poll time would
	-- sit on screen unchanged for up to a full refresh interval.
	local renews = util.countdown(q.periodEnd)
	if renews then
		row(noctalia.tr("field.renews"), renews)
	end
	row(noctalia.tr("field.plan"), q.plan)
	row(noctalia.tr("field.cost"), util.money(q.monthCost))
	if q.creditsRemaining then
		row(noctalia.tr("field.balance"), util.money(q.creditsRemaining))
	end
	return rows
end

local function render()
	local m = mode()
	local text = noctalia.tr("bar.empty")
	local tint = "on_surface_variant"

	if type(quota) == "table" and quota.ok then
		text = headline(quota, m) or noctalia.tr("bar.empty")
		tint = util.severity(quota.kwhFraction)
	end

	if type(quota) ~= "table" then
		barWidget.setTooltip(noctalia.tr("bar.title"))
	elseif not quota.ok then
		barWidget.setTooltip(noctalia.tr("bar.tooltip_text", {
			text = quota.message or noctalia.tr("bar.unavailable"),
		}))
	else
		local rows = tooltipRows(quota)
		barWidget.setTooltip(#rows > 0 and rows or noctalia.tr("bar.title"))
	end

	local children = { ui.image({ path = util.logoPath(), width = 15, height = 15, fit = "contain" }) }
	if m ~= "none" then
		table.insert(children, ui.label({ text = text, fontWeight = "semibold", color = tint }))
	end

	local container = isVertical and ui.column or ui.row
	barWidget.render(container({ gap = 6, align = "center" }, children))
end

noctalia.state.watch("quota", function(value)
	quota = value
	render()
end)

-- Re-render every minute: the tooltip's renewal countdown is recomputed on each
-- render, so it must not wait for the next poll (up to refresh_interval_sec).
noctalia.setUpdateInterval(60000)

function update()
	isVertical = barWidget.isVertical()
	render()
end

function onClick()
	noctalia.togglePanel(util.PLUGIN_ID .. ":usage")
end

-- Right click refreshes without opening a panel.
function onRightClick()
	noctalia.state.set("quota.cmd", (noctalia.state.get("quota.cmd") or 0) + 1)
end

-- Draw once immediately: at startup the service has usually not published yet,
-- and update() only fires on the first tick.
render()
