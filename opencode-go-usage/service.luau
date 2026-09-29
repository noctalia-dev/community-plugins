--!nonstrict
-- Headless [[service]] entry: polls the Opencode Go usage endpoint and publishes
-- the parsed result to noctalia.state for the bar widget and panel to render.
--
--   noctalia.http({ url, headers }, cb)   async HTTP; headers are full "K: V" lines
--   noctalia.state.set / get / watch      shared with the plugin's other entries
--   noctalia.getConfig(key)               plugin-level [[setting]] values
--   noctalia.setUpdateInterval(ms)        tick rate for update()
--
-- The bar and panel are thin clients: they only read the "usage" state key.

local API_URL = "https://opencode.ai/console/api/go/status"
local REFRESH_CMD = "usage.cmd"

-- ── ISO-8601 -> epoch seconds ────────────────────────────────────────────────
-- Computed arithmetically (days-from-civil) instead of via os.time({...}),
-- because os.time interprets a table as *local* time and would shift every
-- countdown by the host's UTC offset.

local function daysFromCivil(y, m, d)
	y = y - (m <= 2 and 1 or 0)
	local era = (y >= 0 and y or y - 399) // 400
	local yoe = y - era * 400
	local doy = (153 * (m + (m > 2 and -3 or 9)) + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

local function isoToEpoch(ts)
	if type(ts) ~= "string" then
		return nil
	end
	local y, mo, d, h, mi, s, rest = ts:match(
		"^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$"
	)
	if not y then
		return nil
	end
	-- Fractional seconds ("...:02.220Z") are intentionally dropped.
	local epoch = daysFromCivil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
		+ tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s)
	-- "Z" means UTC (offset 0); "+HH:MM" / "-HH:MM" shift the instant.
	local sign, oh, om = rest:match("^([%+%-])(%d%d):(%d%d)$")
	if sign then
		local offset = tonumber(oh) * 3600 + tonumber(om) * 60
		epoch = epoch + (sign == "-" and offset or -offset)
	end
	return epoch
end

-- ── formatting ───────────────────────────────────────────────────────────────

local function meterFraction(meter)
	if type(meter) ~= "table" then
		return -1
	end
	local limit = tonumber(meter.limitMicroCents)
	local used = tonumber(meter.usedMicroCents)
	if not limit or limit <= 0 or not used then
		return -1
	end
	return math.max(0, used / limit)
end

local function formatResetLine(ts)
	local epoch = isoToEpoch(ts)
	if not epoch then
		return ""
	end
	local diff = epoch - os.time()
	if diff <= 0 then
		return "Resets now"
	end
	local hours = diff // 3600
	local mins = (diff % 3600) // 60
	if hours >= 24 then
		return string.format("Resets in %dd %dh", hours // 24, hours % 24)
	elseif hours > 0 then
		return string.format("Resets in %dh %dm", hours, mins)
	end
	return string.format("Resets in %dm", mins)
end

-- Average headroom per remaining day, as a fraction of the limit.
local function dailyRemaining(fraction, ts)
	if fraction < 0 then
		return -1
	end
	local epoch = isoToEpoch(ts)
	if not epoch then
		return -1
	end
	local secs = epoch - os.time()
	if secs <= 0 then
		return -1
	end
	return (1 - fraction) / math.max(1, math.ceil(secs / 86400))
end

local function pctInt(fraction)
	if fraction < 0 then
		return "0"
	end
	return tostring(math.floor(fraction * 100 + 0.5))
end

-- ── state ────────────────────────────────────────────────────────────────────

local function failState(message)
	noctalia.state.set("usage", {
		ready = false,
		ok = false,
		message = message,
		fiveHour = nil,
		week = nil,
		month = nil,
		tier = "",
	})
end

local function limitCard(name, meter, endsAt)
	return {
		name = name,
		percent = meterFraction(meter),
		reset = formatResetLine(endsAt),
		daily = dailyRemaining(meterFraction(meter), endsAt),
	}
end

local function parseUsage(body)
	local data = noctalia.json.decode(body)
	local access = data and data.access
	local meters = access and access.meters
	if type(meters) ~= "table" then
		failState("Usage unavailable (check API key)")
		return
	end

	local fiveHour, week, month = meters.fiveHour, meters.week, meters.month
	local endsAt = access.endsAt

	local parts = {}
	for _, entry in { { fiveHour, "5h" }, { week, "week" }, { month, "month" } } do
		if entry[1] then
			table.insert(parts, entry[2] .. " " .. pctInt(meterFraction(entry[1])))
		end
	end

	noctalia.state.set("usage", {
		ready = true,
		ok = true,
		message = table.concat(parts, " \u{b7} "),
		tier = access.cancelAtPeriodEnd and "Cancelling" or "Active",
		fiveHour = limitCard("5-hour Usage", fiveHour, fiveHour and fiveHour.resetsAt),
		week = limitCard("Weekly Usage", week, week and week.resetsAt),
		month = limitCard("Monthly Usage", month, endsAt),
	})
end

-- ── fetch ────────────────────────────────────────────────────────────────────

local inFlight = false

local function fetchUsage()
	if inFlight then
		return
	end
	local apiKey = noctalia.getConfig("api_key")
	if type(apiKey) ~= "string" or apiKey == "" then
		failState("Set API key in settings")
		return
	end

	inFlight = true
	-- headers is a LIST of full "Header: value" lines, not a key/value map.
	noctalia.http({
		url = API_URL,
		headers = {
			"Authorization: Bearer " .. apiKey,
			"Accept: application/json",
		},
	}, function(res)
		inFlight = false
		-- res.ok is transport success, not HTTP status: a 401 arrives with ok=true.
		if not res.ok then
			failState("Usage unavailable (network error)")
		elseif res.status ~= 200 then
			failState("Usage unavailable (HTTP " .. res.status .. ", check API key)")
		else
			parseUsage(res.body)
		end
	end)
end

-- Refetch on demand (panel Refresh button).
noctalia.state.watch(REFRESH_CMD, function()
	fetchUsage()
end)

noctalia.setUpdateInterval(math.max(60, tonumber(noctalia.getConfig("refresh_interval_sec")) or 1800) * 1000)

function update()
	fetchUsage()
end

-- Top-level init: prime the tick rate and do the first fetch immediately, so the
-- bar has data before the first scheduled tick.
failState("Loading\u{2026}")
fetchUsage()
