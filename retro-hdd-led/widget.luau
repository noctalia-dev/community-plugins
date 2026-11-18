--!nonstrict
-- Bar widget: a disk activity LED like the one on the front of old PC cases.
-- It samples /proc/diskstats every poll interval and lights while the watched
-- disks read or write. One LED for both directions or one each for read and
-- write, for all disks together or per disk. The tooltip shows the current
-- rate per disk.

local diskstats = require("./lib/diskstats.luau")
local format = require("./lib/format.luau")
local colors = require("./lib/colors.luau")

local DISKSTATS = "/proc/diskstats"
local SYS_BLOCK = "/sys/block"
-- How often the list of physical disks is refreshed, for hot-plugged drives.
local RESCAN_MS = 10000
-- Window for the tooltip rates; shorter would make them jump around.
local RATE_WINDOW_MS = 1000
local GAP = 4
-- Space between the LED groups of two disks in per-disk mode.
local DISK_GAP = 7

local function config(key, fallback)
	local value = noctalia.getConfig(key)
	if value == nil then
		return fallback
	end
	return value
end

local function clampInt(value, low, high, fallback)
	local n = tonumber(value)
	if n == nil then
		return fallback
	end
	return math.max(low, math.min(high, math.floor(n)))
end

local physical = {}
local lastScanMs = nil
local previous = nil
local rateBase = nil
local rateBaseMs = 0
local pending = false
local readError = nil
-- Disks shown and their state at the last sample.
local names = {}
local states = {}
local shownKey = nil

-- Whole disks with a backing device: /sys/block lists every block device
-- without its partitions, and only real hardware has a `device` link there.
local function scanDisks(now)
	lastScanMs = now
	local found = {}
	local entries = noctalia.listDir(SYS_BLOCK) or {}
	for _, name in ipairs(entries) do
		if noctalia.fileExists(SYS_BLOCK .. "/" .. name .. "/device") then
			found[#found + 1] = name
		end
	end
	physical = found
end

local function isSplit()
	return config("mode", "combined") == "split"
end

local function isPerDisk()
	return config("per_disk", false) == true
end

local function led(color, on)
	local size = clampInt(config("size", 8), 4, 24, 8)
	local props = {
		width = size,
		height = size,
		radius = size / 2,
	}
	if on then
		props.fill = color
		if config("glow", true) ~= false then
			props.softness = 1
		end
	else
		props.fill = format.dim(color, clampInt(config("off_brightness", 20), 0, 100, 20) / 100)
	end
	return ui.box(props)
end

local function lookupColor(role)
	return noctalia.getColor(role)
end

-- Read and write color for one disk, or for all disks when name is nil.
local function colorsFor(name)
	local entry = nil
	if name ~= nil then
		local map = config("disk_colors", {})
		if type(map) == "table" then
			entry = map[name]
		end
	end
	-- With the automatic write color on, an empty global write color makes
	-- forDisk derive it from the read color.
	local writeColor = ""
	if config("auto_write_color", true) == false then
		writeColor = config("write_color", "primary")
	end
	return colors.forDisk(entry, config("read_color", "primary"), writeColor, lookupColor)
end

-- The LEDs for one activity state: one shared LED in the read color, or a
-- read and a write LED.
local function ledsFor(reading, writing, name)
	local readColor, writeColor = colorsFor(name)
	if isSplit() then
		return { led(readColor, reading), led(writeColor, writing) }
	end
	return { led(readColor, reading or writing) }
end

-- Activity of all watched disks together.
local function combinedState()
	local reading, writing = false, false
	for _, name in ipairs(names) do
		local state = states[name]
		if state ~= nil then
			reading = reading or state.read
			writing = writing or state.write
		end
	end
	return reading, writing
end

local function stateKey()
	-- The theme colors are part of the key, so a palette change redraws the
	-- derived colors on the next sample.
	local palette = tostring(noctalia.getColor("primary")) .. tostring(noctalia.getColor("on_surface"))
	if not isPerDisk() then
		local reading, writing = combinedState()
		return palette .. tostring(reading) .. tostring(writing)
	end
	local parts = {}
	for _, name in ipairs(names) do
		local state = states[name] or {}
		parts[#parts + 1] = name .. "=" .. tostring(state.read) .. tostring(state.write)
	end
	return palette .. table.concat(parts, ",")
end

local function render(force)
	local key = stateKey()
	if not force and key == shownKey then
		return
	end
	shownKey = key
	local container = barWidget.isVertical() and ui.column or ui.row
	local tree
	if isPerDisk() and #names > 0 then
		local groups = {}
		for _, name in ipairs(names) do
			local state = states[name] or {}
			local leds = ledsFor(state.read == true, state.write == true, name)
			if #leds == 1 then
				groups[#groups + 1] = leds[1]
			else
				groups[#groups + 1] = container({ gap = GAP, align = "center" }, leds)
			end
		end
		tree = container({ gap = isSplit() and DISK_GAP or GAP, align = "center", justify = "center" }, groups)
	else
		local reading, writing = combinedState()
		tree = container({ gap = GAP, align = "center", justify = "center" }, ledsFor(reading, writing, nil))
	end
	barWidget.render(tree)
end

local function setTooltip(current, rates)
	if readError ~= nil then
		barWidget.setTooltip({ { key = noctalia.tr("tooltip.title"), value = readError } })
		return
	end
	if #names == 0 then
		barWidget.setTooltip({ { key = noctalia.tr("tooltip.title"), value = noctalia.tr("tooltip.no_disks") } })
		return
	end
	local rows = {}
	for _, name in ipairs(names) do
		local rate = rates[name]
		if current[name] == nil then
			rows[#rows + 1] = { key = name, value = noctalia.tr("tooltip.not_found") }
		elseif rate == nil then
			rows[#rows + 1] = { key = name, value = "…" }
		else
			rows[#rows + 1] = { key = name, value = noctalia.tr("tooltip.read", { rate = format.rate(rate.read) }) }
			rows[#rows + 1] = { key = "", value = noctalia.tr("tooltip.write", { rate = format.rate(rate.written) }) }
		end
	end
	barWidget.setTooltip(rows)
end

local function onStats(text, err)
	pending = false
	local now = noctalia.nowMs()
	if text == nil then
		readError = tostring(err or DISKSTATS)
		previous, rateBase = nil, nil
		states = {}
		render(false)
		setTooltip({}, {})
		return
	end
	readError = nil
	if lastScanMs == nil or now - lastScanMs >= RESCAN_MS then
		scanDisks(now)
	end
	local current = diskstats.parse(text)
	local watched = diskstats.select(config("disks", {}), physical)
	if table.concat(watched, ",") ~= table.concat(names, ",") then
		-- Disks came or went: the rate window has to start over.
		names = watched
		rateBase = nil
	end
	if previous ~= nil then
		states = diskstats.activityPerDisk(previous, current, names)
	else
		states = {}
	end
	previous = current
	if rateBase == nil then
		rateBase, rateBaseMs = current, now
		setTooltip(current, {})
	elseif now - rateBaseMs >= RATE_WINDOW_MS then
		setTooltip(current, diskstats.rates(rateBase, current, names, now - rateBaseMs))
		rateBase, rateBaseMs = current, now
	end
	render(false)
end

local function applyInterval()
	noctalia.setUpdateInterval(clampInt(config("poll_ms", 100), 30, 1000, 100))
end

function update()
	if pending then
		return
	end
	pending = noctalia.readFileAsync(DISKSTATS, onStats)
end

function onConfigChanged()
	applyInterval()
	-- The disk list may have changed: rescan and start the rate window over.
	lastScanMs, rateBase = nil, nil
	render(true)
end

applyInterval()
render(true)
update()
