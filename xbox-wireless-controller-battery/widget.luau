--!nonstrict
-- Bar widget: battery of every connected Xbox controller. Controllers show up
-- in /sys/class/power_supply while connected: xpadneo as xpadneo_battery_<n>,
-- xone as gip<n>.<m>, the kernel's Bluetooth HID battery as hid-<mac>-battery
-- with "Xbox Wireless Controller" as model_name. An entry matches when its
-- name or model_name contains one of the comma-separated match patterns.
--
-- The directory listing is checked every two seconds, so a controller appears
-- or disappears right away; the battery itself is re-read on poll_interval.
-- Pads that only report a coarse capacity_level (no capacity file) show that
-- level instead of a percentage.

local common = require("./common.luau")

local POWER_SUPPLY = "/sys/class/power_supply"
local LOW_LEVELS = { Low = true, Critical = true }
-- Rough percentage per capacity_level, only for the glyph and lowest-pad pick.
local LEVEL_PERCENT = { Full = 100, High = 75, Normal = 50, Low = 20, Critical = 5 }

local pads = {}
local signature = nil
local lastRead = -math.huge

local function settings()
	return {
		pollInterval = common.int(noctalia.getConfig("poll_interval"), 30),
		lowThreshold = common.int(noctalia.getConfig("low_threshold"), 20),
		showLowestOnly = common.bool(noctalia.getConfig("show_lowest_only"), false),
		match = noctalia.getConfig("match") or "xpadneo,gip,xbox",
		notifyLow = common.bool(noctalia.getConfig("notify_low"), true),
		notifyFull = common.bool(noctalia.getConfig("notify_full"), false),
		batteryGlyph = common.bool(noctalia.getConfig("battery_glyph"), false),
		iconOnly = common.bool(noctalia.getConfig("icon_only"), false),
	}
end

local function readProp(dir, name)
	local value = noctalia.readFile(`{dir}/{name}`)
	return value and noctalia.string.trim(value) or nil
end

local function patterns(cfg)
	local list = {}
	for part in cfg.match:gmatch("[^,]+") do
		part = noctalia.string.trim(part):lower()
		if part ~= "" then
			table.insert(list, part)
		end
	end
	return list
end

local function matches(text, list)
	text = text:lower()
	for _, pattern in ipairs(list) do
		if text:find(pattern, 1, true) then
			return true
		end
	end
	return false
end

-- Power-supply entries that look like controllers, sorted for stable numbering.
local function findEntries(cfg)
	local list = patterns(cfg)
	local found = {}
	local entries = noctalia.listDir(POWER_SUPPLY) or {}
	table.sort(entries)
	for _, entry in ipairs(entries) do
		local dir = `{POWER_SUPPLY}/{entry}`
		-- Laptop and UPS batteries have scope "System"; never count those.
		if readProp(dir, "scope") ~= "System" and (matches(entry, list) or matches(readProp(dir, "model_name") or "", list)) then
			table.insert(found, entry)
		end
	end
	return found
end

local function readPad(entry)
	local dir = `{POWER_SUPPLY}/{entry}`
	local status = readProp(dir, "status") or ""
	-- model_name may carry the pad's MAC: "Xbox Wireless Controller [ec:83:...]".
	local name = (readProp(dir, "model_name") or ""):gsub("%s*%[.-%]$", "")
	local capacityLevel = readProp(dir, "capacity_level")
	local level = tonumber(readProp(dir, "capacity") or "")
	return {
		id = entry,
		name = name ~= "" and name or noctalia.tr("gamepad.name"),
		level = level,
		capacityLevel = capacityLevel,
		approx = level or LEVEL_PERCENT[capacityLevel],
		charging = status == "Charging" or status == "Full",
	}
end

local function padText(pad)
	if pad.level then
		return `{pad.level}%`
	elseif pad.capacityLevel and pad.capacityLevel ~= "Unknown" then
		return noctalia.tr(`gamepad.level.{pad.capacityLevel:lower()}`)
	end
	return "--"
end

local function isLow(cfg, pad)
	if pad.charging then
		return false
	elseif pad.level then
		return pad.level <= cfg.lowThreshold
	end
	return LOW_LEVELS[pad.capacityLevel] == true
end

local function render(cfg)
	barWidget.setVisible(#pads > 0)
	if #pads == 0 then
		return
	end

	local lowest = nil
	local anyLow, anyCharging = false, false
	local texts, rows = {}, {}
	for index, pad in ipairs(pads) do
		local text = padText(pad)
		table.insert(texts, #pads > 1 and `{index}:{text}` or text)
		anyLow = anyLow or isLow(cfg, pad)
		anyCharging = anyCharging or pad.charging
		if lowest == nil or (pad.approx or 101) < (lowest.approx or 101) then
			lowest = pad
		end
		local status = noctalia.tr(pad.charging and "common.charging" or "common.discharging")
		local key = #pads > 1 and `{index}. {pad.name}` or pad.name
		table.insert(rows, { key = key, value = `{text} · {status}` })
	end

	local text
	if cfg.showLowestOnly then
		text = padText(lowest)
		anyCharging = lowest.charging
	else
		text = table.concat(texts, " ")
	end
	common.present(cfg, "device-gamepad-2", lowest.approx, anyCharging, text)
	common.setRole(anyLow and "error" or "")
	barWidget.setTooltip(rows)
end

local function readAll(cfg, entries)
	local previous = {}
	for _, pad in ipairs(pads) do
		previous[pad.id] = true
	end
	pads = {}
	for _, entry in ipairs(entries) do
		local pad = readPad(entry)
		table.insert(pads, pad)
		previous[entry] = nil
		common.checkAlerts(cfg, entry, pad.name, pad.approx, pad.charging)
	end
	-- Disconnected pads start fresh when they come back.
	for id in pairs(previous) do
		common.forgetAlerts(id)
	end
	lastRead = noctalia.nowMs()
	render(cfg)
end

local function refresh(force)
	local cfg = settings()
	local entries = findEntries(cfg)
	local current = table.concat(entries, ",")
	local due = noctalia.nowMs() - lastRead >= cfg.pollInterval * 1000
	if force or due or current ~= signature then
		signature = current
		readAll(cfg, entries)
	end
end

noctalia.setUpdateInterval(2000)

function update()
	refresh(false)
end

function onClick()
	refresh(true)
end

function onIpc(event, _payload)
	if event == "refresh" then
		refresh(true)
	end
end

refresh(true)
