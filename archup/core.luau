--!nonstrict
-- Shared update-check logic for the archup desktop widget. Each check queries
-- checkupdates and yay -Qua asynchronously with callbacks.
-- shortcut: each widget instance runs its own check per cycle, move to a
-- [[service]] entry if a second consumer appears.

local M = {}

local AUTO_CHECK_SECONDS = 30 * 60
local CHECK_STALL_SECONDS = 120
local COMMAND_TIMEOUT_MS = 60000

M.repoPending = nil -- official repo updates count
M.aurPending = nil  -- AUR updates count
M.repoList = nil    -- pending repo packages { name }
M.aurList = nil     -- pending AUR packages { name, age, secs }
M.repoError = false
M.aurError = false
M.lastCheckAt = nil
M.lastUpdatedAt = nil
M.checking = false

local checkStartedAt = nil
local dataDir = nil
local entryTag = nil
local statePath = nil

local rawRepos = nil
local rawAurs = nil

function M.init(entryName)
	dataDir = noctalia.pluginDataDir()
	entryTag = entryName
	statePath = dataDir .. "/state.json"
	-- Clean up any legacy check files left by previous versions
	for _, name in ipairs(noctalia.listDir(dataDir) or {}) do
		if string.match(name, "^check%.") then
			noctalia.removeFile(dataDir .. "/" .. name)
		end
	end
end

function M.loadState()
	local t = noctalia.json.decode(noctalia.readFile(statePath) or "")
	if t then
		M.repoPending = tonumber(t.repo)
		M.aurPending = tonumber(t.aur)
		M.repoList = t.repoList
		M.aurList = t.aurList
		M.lastCheckAt = tonumber(t.lastCheckAt)
		rawRepos = t.repoList
		rawAurs = t.aurList
	end
end

local function saveState()
	noctalia.writeFile(statePath, noctalia.json.encode({
		repo = M.repoPending,
		aur = M.aurPending,
		repoList = M.repoList,
		aurList = M.aurList,
		lastCheckAt = M.lastCheckAt,
	}))
end

-- "12m", "3h 12m", "2d 4h", "just now"; nil when unknown.
function M.humanize(seconds)
	if seconds == nil or seconds < 0 then
		return nil
	end
	if seconds < 60 then
		return "just now"
	end
	local m = math.floor(seconds / 60)
	if m < 60 then
		return string.format("%dm", m)
	end
	local h = math.floor(m / 60)
	m = m % 60
	if h < 24 then
		return string.format("%dh %dm", h, m)
	end
	local d = math.floor(h / 24)
	h = h % 24
	return string.format("%dd %dh", d, h)
end

-- Full "time since" string for a unix timestamp: "just now", "12m ago".
function M.ago(ts)
	if ts == nil then
		return nil
	end
	local h = M.humanize(os.time() - ts)
	if h == nil then
		return "?"
	end
	if h == "just now" then
		return "just now"
	end
	return h .. " ago"
end

-- "3d23h" / "15h48m" / "45s" (yay's age bracket) -> seconds.
local function parseAge(s)
	if s == nil then
		return nil
	end
	local d = string.match(s, "(%d+)d")
	local h = string.match(s, "(%d+)h")
	local m = string.match(s, "(%d+)m")
	local sec = string.match(s, "(%d+)s")
	return (tonumber(d) or 0) * 86400 + (tonumber(h) or 0) * 3600 + (tonumber(m) or 0) * 60 + (tonumber(sec) or 0)
end

-- "[2026-11-19T10:42:00+0530] [ALPM] transaction completed" -> unix seconds.
-- Luau's os.time(table) reads the fields as UTC, so undo the log's offset.
local function parseLogStamp(line)
	local y, mo, d, h, mi, s, tz = string.match(
		line,
		"^%[(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)([+-]%d%d%d%d)"
	)
	if not y then
		return nil
	end
	local utc = os.time({
		year = tonumber(y),
		month = tonumber(mo),
		day = tonumber(d),
		hour = tonumber(h),
		min = tonumber(mi),
		sec = tonumber(s),
	})
	local offset = tonumber(string.sub(tz, 2, 3)) * 3600 + tonumber(string.sub(tz, 4, 5)) * 60
	if string.sub(tz, 1, 1) == "-" then
		offset = -offset
	end
	return utc - offset
end

function M.refreshLastUpdated(render)
	noctalia.runAsync("grep 'transaction completed' /var/log/pacman.log | tail -n 1", function(res)
		local t = parseLogStamp(res.stdout)
		if t then
			M.lastUpdatedAt = t
		end
		render()
	end)
end

function M.check(render)
	if M.checking then
		return
	end
	M.checking = true
	checkStartedAt = os.time()
	noctalia.setUpdateInterval(5000)
	render()

	local repoDone = false
	local aurDone = false

	local function finalizeCheck()
		M.checking = false
		M.lastCheckAt = os.time()

		-- Show up to 10 packages total across both lists
		local repos = rawRepos or {}
		local aurs = rawAurs or {}
		local maxRepo = math.min(#repos, 5)
		local maxAur = math.min(#aurs, 5)
		if #repos < 5 then
			maxAur = math.min(#aurs, 10 - #repos)
		elseif #aurs < 5 then
			maxRepo = math.min(#repos, 10 - #aurs)
		end

		local trimmedRepos = {}
		for i = 1, maxRepo do
			table.insert(trimmedRepos, repos[i])
		end
		local trimmedAurs = {}
		for i = 1, maxAur do
			table.insert(trimmedAurs, aurs[i])
		end

		if not M.repoError then
			M.repoList = trimmedRepos
		end
		if not M.aurError then
			M.aurList = trimmedAurs
		end

		saveState()
		M.refreshLastUpdated(render)
		render()
	end

	local function onRepoResult(res)
		repoDone = true
		if type(res) == "table" and not res.timedOut and (res.exitCode == 0 or res.exitCode == 2) then
			M.repoError = false
			local repos = {}
			if res.exitCode == 0 and res.stdout then
				for line in string.gmatch(res.stdout, "[^\r\n]+") do
					local name = string.match(line, "^(%S+)")
					if name then
						table.insert(repos, { name = name })
					end
				end
			end
			rawRepos = repos
			M.repoPending = #repos
		else
			M.repoError = true
		end

		if aurDone then
			finalizeCheck()
		else
			render()
		end
	end

	local function onAurResult(res)
		aurDone = true
		if type(res) == "table" and not res.timedOut then
			local aurs = {}
			if res.stdout and #res.stdout > 0 then
				for line in string.gmatch(res.stdout, "[^\r\n]+") do
					local name = string.match(line, "^(%S+)")
					local age = string.match(line, "%[([^%]]+)%]")
					if name then
						table.insert(aurs, { name = name, age = age, secs = parseAge(age) })
					end
				end
			end

			-- yay exits 0 on updates, or 1 when no updates are available
			if res.exitCode == 0 or (res.exitCode == 1 and #aurs == 0) then
				M.aurError = false
				table.sort(aurs, function(a, b)
					return (a.secs or math.huge) < (b.secs or math.huge)
				end)
				rawAurs = aurs
				M.aurPending = #aurs
			else
				M.aurError = true
			end
		else
			M.aurError = true
		end

		if repoDone then
			finalizeCheck()
		else
			render()
		end
	end

	local repoStarted = noctalia.runAsync("checkupdates", onRepoResult, COMMAND_TIMEOUT_MS)
	if not repoStarted then
		onRepoResult({ exitCode = 1 })
	end

	local aurStarted = noctalia.runAsync("yay -Qua", onAurResult, COMMAND_TIMEOUT_MS)
	if not aurStarted then
		onAurResult({ exitCode = 1 })
	end
end

-- Body of the entry's update(): poll stall timeout, auto-refresh, re-render.
function M.tick(render)
	if M.checking then
		if checkStartedAt and os.time() - checkStartedAt > CHECK_STALL_SECONDS then
			M.checking = false
		end
	elseif M.lastCheckAt == nil or os.time() - M.lastCheckAt >= AUTO_CHECK_SECONDS then
		M.check(render)
	end
	render()
end

-- Self-checks, run at load.
assert(parseLogStamp("[1970-01-01T01:00:00+0100]") == 0)
assert(parseAge("1d2h") == 93600 and parseAge("45s") == 45)
assert(M.humanize(3600) == "1h 0m")

return M
