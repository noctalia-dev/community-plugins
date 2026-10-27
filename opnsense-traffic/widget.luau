--!nonstrict
-- Bar widget: one direction (download or upload) of the selected OPNsense
-- interface, laid out like Noctalia's built-in network_rx/network_tx sysmon
-- widgets - glyph, gauge or graph, value - with the same sizes, units and
-- highlight gradient. Left-click opens the panel through the manifest action.

local format = require("./lib/format.luau")

local SNAPSHOT_KEY = "opnsense_snapshot"

-- Built-in sysmon geometry (Style::fontSizeBody = 14, spaceXs = 4), in
-- unscaled px; the bar scales ui.* sizes by the widget scale.
local BODY = 14
local GAP = 4
local GAUGE_STEM = math.floor(BODY * 0.85 + 0.5)
local GAUGE_THICKNESS = math.max(3, math.floor(BODY * 0.3 + 0.5))
local GRAPH_WIDTH = 50
local GRAPH_HEIGHT = 16
-- Share of the gradient reached the moment the highlight starts, as built in.
local ACTIVITY_ONSET = 0.25

local snapshot = noctalia.state.get(SNAPSHOT_KEY) or {}

local function config(key, fallback)
	local value = noctalia.getConfig(key)
	if value == nil then
		return fallback
	end
	return value
end

local function isUpload()
	return config("direction", "download") == "upload"
end

-- Line speed in bytes/s for this direction, 0 when not configured.
local function lineSpeed()
	local mbit = tonumber(config(isUpload() and "line_up_mbit" or "line_down_mbit", 0)) or 0
	return mbit * 125000
end

local function scaleMax()
	local line = lineSpeed()
	if line > 0 then
		return line
	end
	local history = snapshot.history or {}
	return tonumber(isUpload() and history.peakTx or history.peakRx) or 0
end

local function normalized(value)
	local max = scaleMax()
	if max <= 0 then
		return 0
	end
	return math.max(0, math.min(1, value / max))
end

-- Same curve as the built-in widgets: nothing below highlight_from, then ramps
-- from ACTIVITY_ONSET to full at highlight_full (both % of the line speed).
-- Only with a configured line speed, as a peak-relative scale would always
-- look critical at its own peak.
local function highlightFactor(value)
	local line = lineSpeed()
	if line <= 0 then
		return 0
	end
	local full = math.max(tonumber(config("highlight_full", 90)) or 90, 1) / 100
	local from = math.min(math.max(tonumber(config("highlight_from", 50)) or 50, 0) / 100, full)
	local share = value / line
	if share >= full then
		return 1
	elseif share <= from then
		return 0
	end
	return ACTIVITY_ONSET + (1 - ACTIVITY_ONSET) * (share - from) / (full - from)
end

local function hexToRgb(hex)
	local r, g, b = tostring(hex or ""):match("^#(%x%x)(%x%x)(%x%x)")
	if r == nil then
		return nil
	end
	return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)
end

local function resolveColor(spec)
	if type(spec) == "string" and spec:sub(1, 1) == "#" then
		return spec
	end
	return noctalia.getColor(tostring(spec or "error"))
end

-- The widget foreground the built-in widgets use: the instance's `color`,
-- else the `color` of the bar it sits on, else on_surface. The script does not
-- know its instance name, so take the first instance of this widget type.
local function foreground()
	local widgets = noctalia.getSetting("widget") or {}
	local bars = noctalia.getSetting("bar") or {}
	for _, barName in ipairs(bars.order or {}) do
		local bar = bars[barName] or {}
		for _, section in ipairs({ "start", "center", "end" }) do
			for _, name in ipairs(bar[section] or {}) do
				local instance = widgets[name]
				if type(instance) == "table" and instance.type == "dmopp/opnsense-traffic:traffic" then
					return instance.color or bar.color or "on_surface"
				end
			end
		end
	end
	return "on_surface"
end

-- Color for value, gauge and graph; nil keeps the bar's own foreground.
local function valueColor(value)
	local factor = highlightFactor(value)
	if factor <= 0 then
		return nil
	end
	local br, bg, bb = hexToRgb(resolveColor(foreground()))
	local hr, hg, hb = hexToRgb(resolveColor(config("highlight_color", "error")))
	if br == nil or hr == nil then
		return nil
	end
	local function mix(a, b)
		return math.floor(a + (b - a) * factor + 0.5)
	end
	return string.format("#%02X%02X%02X", mix(br, hr), mix(bg, hg), mix(bb, hb))
end

local function gauge(progress, color, vertical)
	local fill = color or foreground()
	local track = fill .. "/0.3"
	if vertical then
		return ui.progress({
			progress = progress,
			fill = fill,
			track = track,
			width = math.max(16, GAUGE_STEM),
			height = GAUGE_THICKNESS,
			radius = GAUGE_THICKNESS / 2,
		})
	end
	-- ui.progress is horizontal only; the built-in gauge on a horizontal bar is
	-- a vertical stem, so build it from a track column filled from the bottom.
	local filled = math.floor(progress * GAUGE_STEM + 0.5)
	local children = {}
	if filled > 0 then
		children[1] = ui.box({ width = GAUGE_THICKNESS, height = filled, fill = fill, radius = GAUGE_THICKNESS / 2 })
	end
	return ui.column({
		width = GAUGE_THICKNESS,
		height = GAUGE_STEM,
		fill = track,
		radius = GAUGE_THICKNESS / 2,
		justify = "end",
	}, children)
end

local function graph(color, vertical)
	local history = snapshot.history or {}
	local series = (isUpload() and history.tx or history.rx) or {}
	local max = scaleMax()
	local values = {}
	for i, v in ipairs(series) do
		values[i] = max > 0 and math.max(0, math.min(1, v / max)) or 0
	end
	return ui.graph({
		values = values,
		color = color or foreground(),
		lineWidth = 0.75,
		fillOpacity = 0.15,
		width = GRAPH_WIDTH,
		height = vertical and GAUGE_STEM or GRAPH_HEIGHT,
	})
end

local function valueText(value)
	if snapshot.error ~= nil and snapshot.error ~= "" then
		return "--"
	end
	local text = format.rate(value, config("speed_unit", "auto"), config("speed_compact", false) == true)
	if config("show_units", true) == false then
		text = format.stripUnit(text)
	end
	return text
end

local function tooltip()
	local err = tostring(snapshot.error or "")
	if err ~= "" then
		return { { key = "OPNsense", value = err } }
	end
	local unit = config("speed_unit", "auto")
	local name = tostring(snapshot.selectedName or "")
	if snapshot.selectedDevice ~= nil and snapshot.selectedDevice ~= "" then
		name = name .. " (" .. snapshot.selectedDevice .. ")"
	end
	return {
		{ key = noctalia.tr("tooltip.interface"), value = name },
		{ key = noctalia.tr("tooltip.download"), value = format.rate(snapshot.rx, unit, false) },
		{ key = noctalia.tr("tooltip.upload"), value = format.rate(snapshot.tx, unit, false) },
	}
end

local function render()
	local vertical = barWidget.isVertical()
	local value = tonumber(isUpload() and snapshot.tx or snapshot.rx) or 0
	local color = valueColor(value)

	local identity = nil
	if config("show_glyph", true) ~= false then
		local name = tostring(config(isUpload() and "upload_glyph" or "download_glyph", ""))
		if name == "" then
			name = isUpload() and "upload" or "download"
		end
		identity = ui.glyph({ name = name, color = color })
	end

	local visualization = nil
	local mode = config("visualization", "gauge")
	if mode == "graph" and vertical then
		-- Like the built-in widget: no room for a graph on a side bar.
		mode = "gauge"
	end
	if mode == "gauge" then
		visualization = gauge(normalized(value), color, vertical)
	elseif mode == "graph" then
		visualization = graph(color, vertical)
	end

	local label = nil
	if config("show_value", true) ~= false then
		local props = { text = valueText(value), color = color, textAlign = vertical and "center" or "end" }
		if vertical then
			props.fontSize = 13
		end
		local minWidth = tonumber(config("label_min_width", 0)) or 0
		if minWidth > 0 and not vertical then
			label = ui.row({ minWidth = minWidth, justify = "end", align = "center" }, { ui.label(props) })
		else
			label = ui.label(props)
		end
	end

	local parts = {}
	local ordered = { identity, visualization, label }
	if config("glyph_position", "before") == "after" then
		ordered = { label, visualization, identity }
	end
	for i = 1, 3 do
		if ordered[i] ~= nil then
			table.insert(parts, ordered[i])
		end
	end
	if #parts == 0 then
		parts[1] = ui.glyph({ name = isUpload() and "upload" or "download" })
	end

	local container = vertical and ui.column or ui.row
	barWidget.render(container({ gap = GAP, align = "center" }, parts))
	barWidget.setTooltip(tooltip())
end

noctalia.state.watch(SNAPSHOT_KEY, function(value)
	if type(value) == "table" then
		snapshot = value
		render()
	end
end)

render()
