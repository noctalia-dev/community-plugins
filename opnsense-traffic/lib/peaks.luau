--!nonstrict
-- Peak rates per interface for the adaptive scale, kept on disk so they
-- survive restarts. Two records per interface:
--   all     - highest rate since `since` (the last reset), used for "unlimited"
--   buckets - highest rate per 15-minute slot, so a hold time of N hours is the
--             maximum over the slots of the last N hours
-- Times are Unix seconds.

local M = {}

local BUCKET = 15 * 60
local MAX_HOLD_HOURS = 720
local SAVE_EVERY = 60

local store = {}
local dirty = false
local lastSave = 0
local path = nil

local function file()
	if path == nil then
		local dir = noctalia.pluginDataDir()
		if dir == nil then
			return nil
		end
		path = dir .. "/peaks.json"
	end
	return path
end

function M.load()
	local p = file()
	if p == nil or not noctalia.fileExists(p) then
		return
	end
	local data = noctalia.json.decode(noctalia.readFile(p) or "")
	if type(data) == "table" then
		store = data
	end
end

function M.save(force)
	local now = os.time()
	if not dirty or (not force and now - lastSave < SAVE_EVERY) then
		return
	end
	local p = file()
	if p ~= nil then
		noctalia.writeFile(p, noctalia.json.encode(store))
	end
	dirty = false
	lastSave = now
end

local function entry(id, now)
	local e = store[id]
	if type(e) ~= "table" then
		e = { since = now, all = { rx = 0, tx = 0 }, buckets = {} }
		store[id] = e
		dirty = true
	end
	return e
end

local function raise(record, key, value, now)
	if value > (record[key] or 0) then
		record[key] = value
		record[key .. "At"] = now
		return true
	end
	return false
end

function M.record(id, rx, tx, now)
	local e = entry(id, now)
	local changed = raise(e.all, "rx", rx, now)
	changed = raise(e.all, "tx", tx, now) or changed

	local start = now - now % BUCKET
	local last = e.buckets[#e.buckets]
	if last == nil or last.t ~= start then
		last = { t = start, rx = 0, tx = 0 }
		table.insert(e.buckets, last)
		changed = true
	end
	changed = raise(last, "rx", rx, now) or changed
	changed = raise(last, "tx", tx, now) or changed

	-- Slots older than the longest hold time are never needed again.
	local cutoff = now - MAX_HOLD_HOURS * 3600
	while #e.buckets > 0 and e.buckets[1].t + BUCKET <= cutoff do
		table.remove(e.buckets, 1)
	end
	dirty = dirty or changed
end

-- Peaks within the hold time (hours, 0 = since the last reset).
function M.current(id, holdHours, now)
	local e = entry(id, now)
	if holdHours <= 0 then
		return {
			rx = e.all.rx or 0,
			rxAt = e.all.rxAt,
			tx = e.all.tx or 0,
			txAt = e.all.txAt,
			since = e.since,
		}
	end
	local from = now - holdHours * 3600
	local result = { rx = 0, tx = 0, since = math.max(e.since, from) }
	for _, b in ipairs(e.buckets) do
		-- A slot counts while any part of it lies in the window.
		if b.t + BUCKET > from then
			if (b.rx or 0) > result.rx then
				result.rx = b.rx
				result.rxAt = b.rxAt
			end
			if (b.tx or 0) > result.tx then
				result.tx = b.tx
				result.txAt = b.txAt
			end
		end
	end
	return result
end

function M.reset(id, now)
	store[id] = { since = now, all = { rx = 0, tx = 0 }, buckets = {} }
	dirty = true
	M.save(true)
end

M.MAX_HOLD_HOURS = MAX_HOLD_HOURS

return M
