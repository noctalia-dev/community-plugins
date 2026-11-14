--!nonstrict
-- Bar widget: next prayer + countdown. Click opens the times panel.

local showCountdown = noctalia.getConfig("show_countdown")
local showName = noctalia.getConfig("show_name")
local glyph = noctalia.getConfig("glyph") or "building-mosque"

showCountdown = showCountdown ~= false and showCountdown ~= "false"
showName = showName ~= false and showName ~= "false"

local prayers = {}
local tomorrowFajr = nil
local hasData = false
local errorMsg = ""
local isJumuah = false
local location = ""

local function nowSeconds()
	local t = os.date("*t")
	return t.hour * 3600 + t.min * 60 + t.sec
end

local function formatCountdown(secs)
	if secs < 0 then
		secs = 0
	end
	local h = math.floor(secs / 3600)
	local m = math.floor((secs % 3600) / 60)
	local s = secs % 60
	if h > 0 then
		return string.format("%d:%02d:%02d", h, m, s)
	end
	return string.format("%d:%02d", m, s)
end

local function formatShort(secs)
	if secs < 0 then
		secs = 0
	end
	local h = math.floor(secs / 3600)
	local m = math.floor((secs % 3600) / 60)
	if h > 0 then
		return string.format("%dsa %ddk", h, m)
	end
	if m > 0 then
		return string.format("%ddk", m)
	end
	return noctalia.tr("panel.now")
end

local function prayerName(id)
	if id == "Dhuhr" and isJumuah then
		return noctalia.tr("prayer.jumuah")
	end
	return noctalia.tr("prayer." .. string.lower(id))
end

local function findNext()
	if #prayers == 0 then
		return nil, nil
	end
	local now = nowSeconds()
	for _, p in ipairs(prayers) do
		if p.seconds > now then
			return p, p.seconds - now
		end
	end
	if tomorrowFajr then
		return { id = "Fajr", time = prayers[1] and prayers[1].time or "?", seconds = tomorrowFajr },
			(86400 - now) + tomorrowFajr
	end
	return prayers[1], nil
end

local function render()
	if not hasData then
		barWidget.setGlyph(glyph)
		barWidget.setText(errorMsg ~= "" and "!" or "…")
		barWidget.setTooltip(errorMsg ~= "" and errorMsg or noctalia.tr("panel.loading"))
		return
	end

	local nextPrayer, remaining = findNext()
	if not nextPrayer then
		barWidget.setGlyph(glyph)
		barWidget.setText("…")
		return
	end

	local name = prayerName(nextPrayer.id)
	local parts = {}
	if showName then
		parts[#parts + 1] = name
	end
	if showCountdown and remaining ~= nil then
		if remaining <= 60 then
			parts[#parts + 1] = noctalia.tr("panel.now")
		else
			parts[#parts + 1] = formatCountdown(remaining)
		end
	elseif not showCountdown then
		parts[#parts + 1] = nextPrayer.time
	end

	barWidget.setGlyph(glyph)
	barWidget.setText(table.concat(parts, " "))

	local tip = {
		{ key = noctalia.tr("tooltip.next"), value = name },
		{ key = noctalia.tr("tooltip.time"), value = nextPrayer.time },
	}
	if remaining ~= nil then
		tip[#tip + 1] = { key = noctalia.tr("tooltip.in"), value = formatShort(remaining) }
	end
	if location ~= "" then
		tip[#tip + 1] = { key = noctalia.tr("tooltip.location"), value = location }
	end
	barWidget.setTooltip(tip)

	if remaining ~= nil and remaining <= 300 then
		barWidget.setColor("primary")
		barWidget.setGlyphColor("primary")
	else
		barWidget.setColor("on_surface")
		barWidget.setGlyphColor("on_surface")
	end
end

noctalia.state.watch("prayers", function(val)
	if type(val) == "table" and #val > 0 then
		prayers = val
		hasData = true
		errorMsg = ""
	end
	render()
end)

noctalia.state.watch("tomorrowFajr", function(val)
	tomorrowFajr = tonumber(val)
	render()
end)

noctalia.state.watch("isJumuah", function(val)
	isJumuah = val == true
	render()
end)

noctalia.state.watch("location", function(val)
	if type(val) == "string" then
		location = val
	end
end)

noctalia.state.watch("error", function(val)
	if type(val) == "string" and val ~= "" then
		errorMsg = val
		if not hasData then
			render()
		end
	end
end)

noctalia.setUpdateInterval(1000)

function update()
	render()
end

function onClick()
	noctalia.togglePanel("bekiryildirimcode/prayer-times:panel")
end

function onConfigChanged()
	showCountdown = noctalia.getConfig("show_countdown")
	showName = noctalia.getConfig("show_name")
	glyph = noctalia.getConfig("glyph") or "building-mosque"
	showCountdown = showCountdown ~= false and showCountdown ~= "false"
	showName = showName ~= false and showName ~= "false"
	render()
end

-- Seed from existing service state
local existing = noctalia.state.get("prayers")
if type(existing) == "table" and #existing > 0 then
	prayers = existing
	hasData = true
end
local tf = noctalia.state.get("tomorrowFajr")
if tf then
	tomorrowFajr = tonumber(tf)
end
local jm = noctalia.state.get("isJumuah")
if jm ~= nil then
	isJumuah = jm == true
end
local loc = noctalia.state.get("location")
if type(loc) == "string" then
	location = loc
end

barWidget.setGlyph(glyph)
barWidget.setText("…")
render()
