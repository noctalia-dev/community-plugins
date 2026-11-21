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

-- Stable IDs of one disk from its sysfs files, which the kernel does not
-- renumber across reboots the way it does nvme0n1/nvme1n1 or sda/sdb.
-- `read(path)` returns the file's contents or nil. Returns
-- { serial = ..., wwid = ..., model = ... } with missing ones left out.
function M.readIds(read, base)
	local function value(path)
		local text = read(path)
		if text == nil then
			return nil
		end
		local clean = trim(text)
		if clean == "" then
			return nil
		end
		return clean
	end
	return {
		serial = value(base .. "/device/serial"),
		-- NVMe has wwid on the disk, SATA/SCSI on the device.
		wwid = value(base .. "/wwid") or value(base .. "/device/wwid"),
		model = value(base .. "/device/model"),
	}
end

-- Physical disks and their IDs: { names }, { [name] = ids }. Whole disks
-- with a backing device: /sys/block lists every block device without its
-- partitions, and only real hardware has a `device` link there. `api` holds
-- listDir, fileExists and readFile (noctalia's, or stubs in the tests).
function M.scan(api, root)
	root = root or "/sys/block"
	local names = {}
	local ids = {}
	for _, name in ipairs(api.listDir(root) or {}) do
		local base = root .. "/" .. name
		if api.fileExists(base .. "/device") then
			names[#names + 1] = name
			ids[name] = M.readIds(api.readFile, base)
		end
	end
	table.sort(names)
	return names, ids
end

-- The ID to copy for a disk: the serial number, else the WWID, else the
-- kernel name. Returns the value and which kind it is.
function M.preferredId(name, ids)
	ids = ids or {}
	if ids.serial ~= nil then
		return ids.serial, "serial"
	end
	if ids.wwid ~= nil then
		return ids.wwid, "wwid"
	end
	return name, "name"
end

-- Whether a configured entry names the disk with these IDs: its kernel name,
-- serial, WWID (with or without the eui./uuid./naa. prefix) or model.
local function matches(entry, name, ids)
	if entry == name then
		return true
	end
	if ids == nil then
		return false
	end
	local wanted = string.lower(entry)
	for _, key in ipairs({ "serial", "wwid", "model" }) do
		local id = ids[key]
		if id ~= nil then
			local lower = string.lower(id)
			if wanted == lower then
				return true
			end
			if key == "wwid" and wanted == (lower:gsub("^%a+%.", "")) then
				return true
			end
		end
	end
	return false
end

-- The kernel name a configured entry stands for: a present disk's name or
-- one of its stable IDs. Anything else (a partition such as sda1, a disk not
-- plugged in) comes back unchanged.
function M.resolve(entry, physical, ids)
	for _, name in ipairs(physical or {}) do
		if entry == name then
			return name
		end
	end
	for _, name in ipairs(physical or {}) do
		if matches(entry, name, (ids or {})[name]) then
			return name
		end
	end
	return entry
end

-- The configured entry for a disk in a map keyed by kernel name or stable ID
-- (disk_colors), or nil.
function M.lookup(map, name, ids)
	if type(map) ~= "table" then
		return nil
	end
	if map[name] ~= nil then
		return map[name]
	end
	local keys = {}
	for key in pairs(map) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	for _, key in ipairs(keys) do
		if matches(trim(key), name, ids) then
			return map[key]
		end
	end
	return nil
end

-- The disks to watch: the configured entries in their order, or every
-- physical disk when the list is empty. Entries may be kernel names or stable
-- IDs (see resolve). Partitions, loop, zram and device-mapper devices are not
-- physical disks, so the default never counts the same I/O twice. For the
-- physical disks, entries in `order` come first in that order (entries that
-- are not present are skipped), the rest follow sorted by serial number, so
-- the order survives reboots, and drives plugged in later still show up.
function M.select(configured, physical, order, ids)
	ids = ids or {}
	local names = {}
	local seen = {}
	local function add(name)
		if not seen[name] then
			seen[name] = true
			names[#names + 1] = name
		end
	end
	for _, entry in ipairs(cleanList(configured)) do
		add(M.resolve(entry, physical, ids))
	end
	if #names > 0 then
		return names
	end
	local present = {}
	for _, name in ipairs(physical or {}) do
		present[name] = true
	end
	for _, entry in ipairs(cleanList(order)) do
		local name = M.resolve(entry, physical, ids)
		if present[name] then
			add(name)
		end
	end
	local rest = {}
	for name in pairs(present) do
		if not seen[name] then
			rest[#rest + 1] = name
		end
	end
	local function sortKey(name)
		local diskIds = ids[name] or {}
		return diskIds.serial or diskIds.wwid or name
	end
	table.sort(rest, function(a, b)
		local ka, kb = sortKey(a), sortKey(b)
		if ka ~= kb then
			return ka < kb
		end
		return a < b
	end)
	for _, name in ipairs(rest) do
		add(name)
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
