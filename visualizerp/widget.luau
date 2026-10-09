--!nonstrict
-- Scope bar widget.
--
-- Renders the waveform envelope captured by the plugin's service as an
-- oscilloscope trace. The service owns the capture (bin/pwscope on PipeWire);
-- this file only shapes shared state into a ui.graph and a tooltip.

local DATA_KEY = "viz.data"
local TARGET_KEY = "viz.target"
local STATUS_KEY = "viz.status"
local PITCH_KEY = "viz.pitch"

local data = noctalia.state.get(DATA_KEY)
local target = noctalia.state.get(TARGET_KEY)
local status = noctalia.state.get(STATUS_KEY)
local pitch = noctalia.state.get(PITCH_KEY)

local function number(value, fallback)
	local n = tonumber(value)
	if n == nil then
		return fallback
	end
	return n
end

-- Byte level (128 = silence) to 0..1 amplitude for meters.
local function level01(value)
	local amp = math.abs(number(value, 128) - 128) / 127
	if amp > 1.0 then amp = 1.0 end
	return amp
end

-- Byte level (128 = silence) to decibels for the tooltip.
local function levelText(value)
	local amp = math.abs(number(value, 128) - 128) / 127
	if amp < 0.0005 then
		return "-inf dB"
	end
	return string.format("%.1f dB", 20 * math.log10(amp))
end

local METER_WIDTH = 40
local METER_HEIGHT = 8

local function meterRow(labelText, amp, fill, maxW, h, radius, showLabels)
	local children = {}

	if showLabels then
		children[#children + 1] = ui.label({
			text = labelText,
			fontSize = 9,
			color = "on_surface_variant",
		})
	end

	children[#children + 1] = ui.box({
		fill = fill,
		width = math.floor(maxW * amp + 0.5),
		height = h,
		radius = radius,
	})

	return ui.row({ gap = 4, align = "center" }, children)
end

local function render()
	-- Not capturing yet, or helper missing: show a bare glyph, not an empty graph.
	if type(data) ~= "table" or type(data.upper) ~= "table" or #data.upper < 2 then
		if status ~= nil and status.state == "error" then
			barWidget.setGlyph("alert-triangle")
			barWidget.setGlyphColor("error")
		else
			barWidget.setGlyph("activity")
			barWidget.setGlyphColor("on_surface_variant")
		end
		barWidget.setTooltip(
			status ~= nil and status.state == "error"
				and noctalia.tr("widget.unavailable")
				or noctalia.tr("widget.waiting")
		)
		return
	end

	local rms_amp = level01(data.rms)
	local peak_amp = level01(data.peak)

	local trace_color = noctalia.getConfig("color") or "primary"
	local rms_color = noctalia.getConfig("rms_color") or trace_color
	local peak_color = noctalia.getConfig("peak_color") or "error"
	local meter_radius = number(noctalia.getConfig("meter_radius"), 2)
	local meter_width = number(noctalia.getConfig("meter_width"), METER_WIDTH)
	local meter_height = number(noctalia.getConfig("meter_height"), METER_HEIGHT)
	local meter_gap = number(noctalia.getConfig("meter_gap"), 4)
	local show_labels = noctalia.getConfig("show_meter_labels") ~= false

	-- Main graph on the left, two horizontal meters on the right.
	local props = {
		values = data.upper,
		color = trace_color,
		lineWidth = number(noctalia.getConfig("line_width"), 1),
		fillOpacity = number(noctalia.getConfig("fill_opacity"), 0.0),
		width = number(noctalia.getConfig("width"), 140),
		height = number(noctalia.getConfig("height"), 20),
	}
	if noctalia.getConfig("draw_band") == true and type(data.lower) == "table" then
		props.values2 = data.lower
		props.color2 = noctalia.getConfig("color2") or "on_surface_variant"
	end

	-- Right-side meter column (RMS top, Peak bottom).
	local meter_col = ui.column({ gap = 4, align = "start" }, {
		meterRow("RMS", rms_amp, rms_color, meter_width, meter_height,
			 meter_radius, show_labels),
		meterRow("PK", peak_amp, peak_color, meter_width, meter_height,
			 meter_radius, show_labels),
	})

	barWidget.render(ui.row({ align = "center", flexGrow = 1, gap = meter_gap }, {
		ui.graph(props),
		meter_col,
	}))

	local rows = {}
	if type(target) == "string" and target ~= "" then
		rows[#rows + 1] = { key = noctalia.tr("tooltip.target"), value = target }
	end
	if type(pitch) == "number" and pitch > 0 then
		rows[#rows + 1] = {
			key = noctalia.tr("tooltip.pitch"),
			value = string.format("%.1f Hz", pitch),
		}
	end
	rows[#rows + 1] = { key = noctalia.tr("tooltip.rms"), value = levelText(data.rms) }
	rows[#rows + 1] = { key = noctalia.tr("tooltip.peak"), value = levelText(data.peak) }
	rows[#rows + 1] = { key = noctalia.tr("tooltip.frame"), value = tostring(data.seq) }
	barWidget.setTooltip(rows)
end

function update()
	-- Safety net only; state.watch drives live updates as frames arrive.
	noctalia.setUpdateInterval(2000)
	render()
end

function onConfigChanged()
	render()
end

noctalia.state.watch(DATA_KEY, function(value)
	if type(value) == "table" then
		data = value
		render()
	end
end)

noctalia.state.watch(TARGET_KEY, function(value)
	target = value
	render()
end)

noctalia.state.watch(PITCH_KEY, function(value)
	pitch = value
	render()
end)

noctalia.state.watch(STATUS_KEY, function(value)
	status = value
	render()
end)

render()