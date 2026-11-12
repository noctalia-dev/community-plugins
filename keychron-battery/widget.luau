--!nonstrict
-- Bar widget: mouse glyph + percentage, drawn with the native glyph/text API so
-- it takes the bar's own text and icon colors like the built-in widgets. Only a
-- low battery or a missing reading overrides them. When no battery level comes
-- in, the widget stays in the bar with an error state instead of disappearing.
-- Left-click opens the panel through the manifest action.

local SNAPSHOT_KEY = "keychron_snapshot"

local snapshot = noctalia.state.get(SNAPSHOT_KEY) or {}
local overridden = false

local function levelText(device)
	if type(device.level) == "number" then
		return tostring(device.level) .. "%"
	end
	return "--"
end

local function setAlert(on)
	if on then
		barWidget.setColor("error")
		barWidget.setGlyphColor("error")
		overridden = true
	elseif overridden then
		-- Empty role hands the color back to the bar.
		barWidget.setColor("")
		barWidget.setGlyphColor("")
		overridden = false
	end
end

local function renderMissing()
	local err = tostring(snapshot.error or "")
	barWidget.setGlyph("mouse-off")
	barWidget.setText("--")
	setAlert(true)
	barWidget.setTooltip({
		{ key = noctalia.tr("kind.mouse"), value = noctalia.tr("bar.no_value") },
		{ key = "", value = err ~= "" and err or noctalia.tr("bar.no_value_hint") },
	})
end

local function render()
	-- Stay hidden until the service has read UPower once, so startup does not
	-- flash the error state.
	if snapshot.updatedAt == nil then
		barWidget.setVisible(false)
		return
	end
	barWidget.setVisible(true)

	local devices = snapshot.devices or {}
	if #devices == 0 then
		renderMissing()
		return
	end

	local low = tonumber(noctalia.getConfig("low_threshold")) or 20
	local texts = {}
	local rows = {}
	local isLow = false
	local missing = false
	local charging = false
	for _, d in ipairs(devices) do
		table.insert(texts, levelText(d))
		if type(d.level) == "number" then
			if d.level <= low and not d.charging then
				isLow = true
			end
		else
			missing = true
		end
		charging = charging or d.charging
		local value = levelText(d) .. " · " .. noctalia.tr("connection." .. d.connection)
		if d.charging then
			value = value .. " · " .. noctalia.tr("panel.charging")
		end
		table.insert(rows, { key = d.displayName or "", value = value })
	end

	if missing then
		table.insert(rows, { key = "", value = noctalia.tr("bar.no_value_hint") })
	end

	barWidget.setGlyph(charging and "battery-charging" or (missing and #texts == 1) and "mouse-off" or "mouse")
	barWidget.setText(table.concat(texts, " "))
	setAlert(isLow or missing)
	barWidget.setTooltip(rows)
end

noctalia.state.watch(SNAPSHOT_KEY, function(value)
	if type(value) == "table" then
		snapshot = value
		render()
	end
end)

render()
