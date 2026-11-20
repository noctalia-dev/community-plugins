--!nonstrict
-- Parsing and arithmetic on /proc/diskstats, kept free of noctalia.* so the
-- tests can run it directly.
--
-- Each line of /proc/diskstats is "major minor name" followed by the I/O
-- counters; field 6 is sectors read and field 10 sectors written. The kernel
-- always counts these in 512-byte units, whatever the device's sector size.

local M = {}

M.SECTOR_BYTES = 512

-- Returns { [name] = { read = sectors, written = sectors } }.
function M.parse(text)
	local disks = {}
	for line in string.gmatch(text or "", "[^\n]+") do
		local fields = {}
		for field in string.gmatch(line, "%S+") do
			fields[#fields + 1] = field
		end
		if #fields >= 10 then
			local read = tonumber(fields[6])
			local written = tonumber(fields[10])
			if read ~= nil and written ~= nil then
				disks[fields[3]] = { read = read, written = written }
			end
		end
	end
	return disks
end

local function trim(s)
	return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Trimmed, non-empty, de-duplicated names in their given order.
local function cleanList(list)
	local names = {}
	local seen = {}
	for _, name in ipairs(list or {}) do
		local clean = trim(name)
		if clean ~= "" and not seen[clean] then
			seen[clean] = true
			names[#names + 1] = clean
		end
	end
	return names
end

-- The disks to watch: the configured names in their order, or every physical
-- disk when the list is empty. Partitions, loop, zram and device-mapper
-- devices are not physical disks, so the default never counts the same I/O
-- twice. For the physical disks, names in `order` come first in that order
-- (names that are not present are skipped), the rest follow sorted by name,
-- so drives plugged in later still show up.
function M.select(configured, physical, order)
	local names = cleanList(configured)
	if #names > 0 then
		return names
	end
	local present = {}
	for _, name in ipairs(physical or {}) do
		present[name] = true
	end
	local placed = {}
	for _, name in ipairs(cleanList(order)) do
		if present[name] then
			placed[name] = true
			names[#names + 1] = name
		end
	end
	local rest = {}
	for name in pairs(present) do
		if not placed[name] then
			rest[#rest + 1] = name
		end
	end
	table.sort(rest)
	for _, name in ipairs(rest) do
		names[#names + 1] = name
	end
	return names
end

-- Sector growth of one counter, 0 when it went backwards (device removed and
-- re-added, counter reset).
local function growth(before, after)
	local delta = (after or 0) - (before or 0)
	if delta < 0 then
		return 0
	end
	return delta
end

-- Per named disk, whether it read or wrote between two samples:
-- { [name] = { read = bool, write = bool } }. A disk missing from either
-- sample is idle, so a disk appearing does not flash its LED.
function M.activityPerDisk(previous, current, names)
	local states = {}
	for _, name in ipairs(names) do
		local before, after = previous[name], current[name]
		local state = { read = false, write = false }
		if before ~= nil and after ~= nil then
			state.read = growth(before.read, after.read) > 0
			state.write = growth(before.written, after.written) > 0
		end
		states[name] = state
	end
	return states
end

-- Whether any of the named disks read or wrote between two samples.
function M.activity(previous, current, names)
	local reading, writing = false, false
	for _, state in pairs(M.activityPerDisk(previous, current, names)) do
		reading = reading or state.read
		writing = writing or state.write
	end
	return reading, writing
end

-- Bytes per second for each named disk over elapsedMs. Disks missing from
-- either sample are left out.
function M.rates(previous, current, names, elapsedMs)
	local rates = {}
	if elapsedMs <= 0 then
		return rates
	end
	local scale = M.SECTOR_BYTES * 1000 / elapsedMs
	for _, name in ipairs(names) do
		local before, after = previous[name], current[name]
		if before ~= nil and after ~= nil then
			rates[name] = {
				read = growth(before.read, after.read) * scale,
				written = growth(before.written, after.written) * scale,
			}
		end
	end
	return rates
end

return M
