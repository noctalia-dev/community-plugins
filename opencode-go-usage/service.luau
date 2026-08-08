--!nonstrict
-- OpenCode Go Usage backend.
--
-- OpenQuota's OpenCode integration is local-only: it estimates quota usage
-- from the local OpenCode database and never reads credential files.

local CACHE_FILE = "snapshot.json"
local SESSION_CAP_USD = 12
local WEEKLY_CAP_USD = 30
local MONTHLY_CAP_USD = 60
local SESSION_SECONDS = 5 * 60 * 60
local WEEK_SECONDS = 7 * 24 * 60 * 60

local EMPTY_GO = { status = "idle", entries = {}, error = "" }

local function emptyTotals()
	return { tin = 0, tout = 0, tcr = 0, tcw = 0, cost = 0, sessions = 0 }
end

local EMPTY_LOCAL = {
	status = "idle",
	days = {},
	models = {},
	totals = emptyTotals(),
	error = "",
}

local snapshot = {
	capturedAt = 0,
	isFetching = false,
	go = EMPTY_GO,
	localData = EMPTY_LOCAL,
}

local function configBool(key, fallback)
	local value = noctalia.getConfig(key)
	if type(value) == "boolean" then
		return value
	end
	return fallback
end

local function configNumber(key, fallback)
	local value = noctalia.getConfig(key)
	if type(value) == "number" then
		return value
	end
	return fallback
end

local function cachePath()
	local dir = noctalia.pluginDataDir()
	return dir and dir .. "/" .. CACHE_FILE or nil
end

local function loadCached()
	local path = cachePath()
	if not path then
		return
	end
	local contents = noctalia.readFile(path)
	if not contents then
		return
	end
	local decoded = noctalia.json.decode(contents)
	if type(decoded) ~= "table" then
		return
	end
	local go = type(decoded.go) == "table" and decoded.go or EMPTY_GO
	local localData = type(decoded.localData) == "table" and decoded.localData or EMPTY_LOCAL
	go.entries = type(go.entries) == "table" and go.entries or {}
	go.error = type(go.error) == "string" and go.error or ""
	localData.days = type(localData.days) == "table" and localData.days or {}
	localData.models = type(localData.models) == "table" and localData.models or {}
	localData.totals = type(localData.totals) == "table" and localData.totals or emptyTotals()
	localData.error = type(localData.error) == "string" and localData.error or ""
	snapshot = {
		capturedAt = tonumber(decoded.capturedAt) or 0,
		isFetching = false,
		go = go,
		localData = localData,
	}
end

local function publish()
	noctalia.state.set("opencode_usage.snapshot", snapshot)
	local path = cachePath()
	if path then
		local encoded = noctalia.json.encode(snapshot, false)
		if encoded then
			noctalia.writeFile(path, encoded)
		end
	end
end

local function localQuery(now)
	local clock = os.date("*t", now)
	local dayStart = os.time({ year = clock.year, month = clock.month, day = clock.day, hour = 0 })
	local mondayStart = dayStart - ((clock.wday + 5) % 7) * 86400
	local monthStart = os.time({ year = clock.year, month = clock.month, day = 1, hour = 0 })
	local nextMonth = os.time({ year = clock.year, month = clock.month + 1, day = 1, hour = 0 })
	local nowMs = now * 1000
	local sessionStartMs = nowMs - SESSION_SECONDS * 1000
	local function providerFilter(alias)
		return "COALESCE(json_extract(" .. alias .. ".model, '$.providerID'), "
			.. "json_extract(" .. alias .. ".model, '$.providerId'), "
			.. "json_extract(" .. alias .. ".model, '$.provider_id')) = 'opencode-go'"
	end
	return string.format([[
SELECT 'day' k, strftime('%%Y-%%m-%%d', s.time_created/1000, 'unixepoch') label,
  SUM(s.tokens_input) tin, SUM(s.tokens_output) tout,
  SUM(s.tokens_cache_read) tcr, SUM(s.tokens_cache_write) tcw,
  ROUND(SUM(s.cost), 4) c, COUNT(*) cnt, 0 extra
FROM session s WHERE s.time_archived IS NULL GROUP BY label
UNION ALL
SELECT 'model', json_extract(s.model, '$.id'), SUM(s.tokens_input), SUM(s.tokens_output),
  SUM(s.tokens_cache_read), SUM(s.tokens_cache_write), ROUND(SUM(s.cost), 4), COUNT(*), 0
FROM session s WHERE s.time_archived IS NULL
  AND json_extract(s.model, '$.id') IS NOT NULL AND json_extract(s.model, '$.id') != ''
GROUP BY s.model
UNION ALL
SELECT 'total', '', SUM(s.tokens_input), SUM(s.tokens_output),
  SUM(s.tokens_cache_read), SUM(s.tokens_cache_write), ROUND(SUM(s.cost), 4), COUNT(*), 0
FROM session s WHERE s.time_archived IS NULL
UNION ALL
SELECT 'quota_session', '', 0, 0, 0, 0, ROUND(SUM(s.cost), 4), COUNT(*),
  CAST(MIN(s.time_created) / 1000 AS INTEGER)
FROM session s WHERE s.time_archived IS NULL AND s.time_created >= %d
  AND s.time_created <= %d AND %s
UNION ALL
SELECT 'quota_weekly', '', 0, 0, 0, 0, ROUND(SUM(s.cost), 4), COUNT(*), %d
FROM session s WHERE s.time_archived IS NULL AND s.time_created >= %d
  AND s.time_created < %d AND %s
UNION ALL
SELECT 'quota_monthly', '', 0, 0, 0, 0, ROUND(SUM(s.cost), 4), COUNT(*), %d
FROM session s WHERE s.time_archived IS NULL AND s.time_created >= %d
  AND s.time_created < %d AND %s
]], sessionStartMs, nowMs, providerFilter("s"), mondayStart + WEEK_SECONDS,
		mondayStart * 1000, (mondayStart + WEEK_SECONDS) * 1000, providerFilter("s"),
		nextMonth, monthStart * 1000, nextMonth * 1000, providerFilter("s"))
end

local function estimatedEntry(name, used, cap, resetAt)
	return {
		name = name,
		percentUsed = math.clamp((used / cap) * 100, 0, 100),
		resetAt = resetAt,
		estimated = true,
		usedUsd = used,
		limitUsd = cap,
	}
end

local function setGoFromRows(rows, now)
	if not configBool("show_limits", true) then
		snapshot.go = { status = "disabled", entries = {}, error = "" }
		return
	end
	local entries = {}
	for _, row in ipairs(rows) do
		local used = tonumber(row.c) or 0
		local reset = tonumber(row.extra) or now
		if row.k == "quota_session" and row.c ~= nil then
			local first = reset > 0 and reset or now
			table.insert(entries, estimatedEntry("Rolling (5h)", used, SESSION_CAP_USD, first + SESSION_SECONDS))
		elseif row.k == "quota_weekly" and row.c ~= nil then
			table.insert(entries, estimatedEntry("Weekly", used, WEEKLY_CAP_USD, reset))
		elseif row.k == "quota_monthly" and row.c ~= nil then
			table.insert(entries, estimatedEntry("Monthly", used, MONTHLY_CAP_USD, reset))
		end
	end
	if #entries > 0 then
		snapshot.go = {
			status = "ok",
			entries = entries,
			error = noctalia.tr("status.go_estimated"),
			estimated = true,
		}
	else
		snapshot.go = { status = "unconfigured", entries = {}, error = noctalia.tr("status.go_unconfigured") }
	end
end

local function fetchLocal(done)
	local showUsage = configBool("show_usage", true)
	local showLimits = configBool("show_limits", true)
	if not showUsage and not showLimits then
		snapshot.localData = { status = "disabled", days = {}, models = {}, totals = emptyTotals(), error = "" }
		snapshot.go = { status = "disabled", entries = {}, error = "" }
		done()
		return
	end
	if not noctalia.commandExists("opencode") then
		snapshot.localData = { status = "unavailable", days = {}, models = {}, totals = emptyTotals(), error = noctalia.tr("status.usage_unavailable") }
		snapshot.go = { status = "unavailable", entries = {}, error = noctalia.tr("status.usage_unavailable") }
		done()
		return
	end
	local now = os.time()
	noctalia.runAsync('opencode db "' .. localQuery(now) .. '" --format json', function(result)
		if result == nil or result.exitCode ~= 0 then
			local errorText = result and noctalia.string.trim(result.stderr) or ""
			snapshot.localData = { status = "error", days = {}, models = {}, totals = emptyTotals(), error = errorText ~= "" and errorText or noctalia.tr("status.usage_failed") }
			snapshot.go = { status = "error", entries = {}, error = noctalia.tr("status.usage_failed") }
			done()
			return
		end
		local rows = noctalia.json.decode(result.stdout)
		if type(rows) ~= "table" then
			snapshot.localData = { status = "error", days = {}, models = {}, totals = emptyTotals(), error = noctalia.tr("status.usage_parse_failed") }
			done()
			return
		end
		setGoFromRows(rows, now)
		if not showUsage then
			snapshot.localData = { status = "disabled", days = {}, models = {}, totals = emptyTotals(), error = "" }
			done()
			return
		end
		local days, models, totals = {}, {}, emptyTotals()
		for _, row in ipairs(rows) do
			local data = { tin = tonumber(row.tin) or 0, tout = tonumber(row.tout) or 0, tcr = tonumber(row.tcr) or 0, tcw = tonumber(row.tcw) or 0, cost = tonumber(row.c) or 0, sessions = tonumber(row.cnt) or 0 }
			if row.k == "day" then
				data.label = tostring(row.label or "")
				table.insert(days, data)
			elseif row.k == "model" then
				data.name = tostring(row.label or "?")
				table.insert(models, data)
			elseif row.k == "total" then
				totals = data
			end
		end
		table.sort(days, function(a, b) return a.label > b.label end)
		snapshot.localData = { status = "ok", days = days, models = models, totals = totals, error = "" }
		done()
	end, 30000)
end

local refreshPending = false
local refreshAgain = false

local function refresh()
	if refreshPending then
		refreshAgain = true
		return
	end
	refreshPending, refreshAgain = true, false
	snapshot.isFetching = true
	publish()
	fetchLocal(function()
		snapshot.isFetching = false
		publish()
		refreshPending = false
		if refreshAgain then
			refreshAgain = false
			refresh()
		end
	end)
end

noctalia.state.watch("opencode_usage.refresh_requested", function(requested)
	if requested then
		noctalia.state.set("opencode_usage.refresh_requested", false)
		refresh()
	end
end)

loadCached()
publish()
noctalia.setUpdateInterval(math.floor(math.clamp(configNumber("refresh_minutes", 5), 1, 120)) * 60 * 1000)
refresh()

function update()
	refresh()
end

function onConfigChanged()
	noctalia.setUpdateInterval(math.floor(math.clamp(configNumber("refresh_minutes", 5), 1, 120)) * 60 * 1000)
	refresh()
end

function onIpc(event, _payload)
	if event == "refresh" then
		refresh()
	end
end
