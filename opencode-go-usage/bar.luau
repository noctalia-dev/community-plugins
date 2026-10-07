--!nonstrict
-- Bar widget entry for the Opencode Go usage capsule.
--
--   barWidget.render(tree)      declarative ui.* tree (replaces the default row)
--   barWidget.isVertical()      a row in a horizontal bar, a column in a side bar
--   barWidget.setTooltip(text)  hover text
--   noctalia.state.watch(...)   re-render when the service publishes new usage
--   noctalia.togglePanel(id)    left click opens the details panel
--
-- The widget owns no polling logic: it only reflects the shared "usage" state.

local PLUGIN_ID = "zumik3-del/opencode-go-usage"
local GLYPH = "brand-openai"

local usage = noctalia.state.get("usage")
local isVertical = false

local function formatPct(fraction)
	if type(fraction) ~= "number" or fraction < 0 then
		return nil
	end
	local v = fraction * 100
	if v > 999 then
		v = 999
	end
	local r = math.floor(v * 10 + 0.5) / 10
	if r == math.floor(r) then
		return string.format("%d%%", r)
	end
	return string.format("%.1f%%", r)
end

-- The bar shows one limit, chosen by the widget's own "bar_limit" setting.
-- "none" hides the percentage entirely and leaves just the glyph.
local function selectedMode()
	local mode = noctalia.getConfig("bar_limit")
	if mode == "none" then
		return "none"
	elseif mode == "week" or mode == "month" then
		return mode
	end
	return "5h"
end

local function selectedCard(mode)
	if mode == "none" or type(usage) ~= "table" then
		return nil
	end
	if mode == "week" then
		return usage.week
	elseif mode == "month" then
		return usage.month
	end
	return usage.fiveHour
end

local function render()
	local mode = selectedMode()
	local card = selectedCard(mode)
	local text, tooltip

	if not usage then
		text = noctalia.tr("bar.empty")
		tooltip = noctalia.tr("bar.title")
	elseif not usage.ok then
		text = noctalia.tr("bar.empty")
		tooltip = noctalia.tr("bar.tooltip_text", {
			text = usage.message or noctalia.tr("bar.unavailable"),
		})
	else
		local pct = card and formatPct(card.percent)
		if pct then
			text = pct
			tooltip = noctalia.tr("bar.tooltip_meter", { meter = card.name, percent = pct })
		else
			-- No meter for the selected limit (or the bar is in icon-only mode):
			-- fall back to the compact all-limits summary the service composes.
			local summary = type(usage.message) == "string" and usage.message or ""
			text = summary ~= "" and summary or noctalia.tr("bar.empty")
			tooltip = noctalia.tr("bar.tooltip_text", { text = text })
		end
		if usage.tier == "cancelling" then
			tooltip = tooltip .. " (" .. noctalia.tr("tier.cancelling") .. ")"
		end
	end

	barWidget.setTooltip(tooltip)

	local children = { ui.glyph({ name = GLYPH, color = "primary" }) }
	if mode ~= "none" then
		table.insert(children, ui.label({ text = text, fontWeight = "semibold" }))
	end

	local container = isVertical and ui.column or ui.row
	barWidget.render(container({ gap = 6, align = "center" }, children))
end

noctalia.state.watch("usage", function(value)
	usage = value
	render()
end)

function update()
	isVertical = barWidget.isVertical()
	render()
end

function onClick()
	noctalia.togglePanel(PLUGIN_ID .. ":panel")
end

-- Draw once immediately: at startup the service has usually not published yet,
-- and update() only fires on the first tick.
render()
