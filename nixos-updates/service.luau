--!nonstrict
-- Update check backend. Runs scripts/check.sh, which asks `nix flake update`
-- for the lock file it would write (into the plugin data directory, flake.lock
-- stays untouched), evaluates the package list with the current and the new
-- lock, and lists pending Flatpak updates. The service compares the results
-- and publishes one snapshot for widget and panel.
--
-- Nothing is installed or switched here; the update command from the
-- settings does that in a terminal, under the user's eyes.

local diff = require("./lib/diff.luau")

local RESULT_KEY = "nixos_updates"
local SYSTEM_KEY = "nixos_updates_system"
local COMMAND_KEY = "nixos_updates_command"
-- A check that has not finished after this long is given up (the stream has
-- no exit callback, so a killed script would otherwise block every check).
-- Longer than check.sh can run (63 minutes at most) (its nix and flatpak calls have time limits, 52
-- minutes in all), so no two runs overlap; plugins cannot stop a stream
-- themselves.
local STALE_RUN_S = 70 * 60
-- The same for the download estimate (estimate.sh: 10.5 minutes at most).
local STALE_ESTIMATE_S = 15 * 60
-- Wait this long after flake.lock or a Flatpak installation changed before
-- checking again, so an update in progress can finish.
local SETTLE_S = 20
-- After a failed check (no network yet, for instance) try again this soon
-- instead of showing the error until the next regular check.
local RETRY_S = 15 * 60

local result = {}
local running = false
local runStarted = 0
-- Each run's stream callback carries its id; lines from a run that was given
-- up are ignored, so a late "done" cannot overwrite a newer result.
local runId = 0
local estimating = false
local estimateStarted = 0
local estimateId = 0
local step = ""
local errors = {}
local changedAt = 0

local function config(key, fallback)
	local value = noctalia.getConfig(key)
	if value == nil then
		return fallback
	end
	return value
end

local function dataDir()
	return noctalia.pluginDataDir()
end

local function resultFile()
	local dir = dataDir()
	return dir ~= nil and (dir .. "/result.json") or nil
end

local function flakeDir()
	local dir = noctalia.string.trim(tostring(config("flake_dir", "")))
	if dir == "" then
		return ""
	end
	return (noctalia.expandPath(dir):gsub("/+$", ""))
end

local function homeConfiguration()
	return noctalia.string.trim(tostring(config("home_configuration", "")))
end

-- Only ever the path: the token stays in its file, and settings may be exported.
local function tokenFile()
	local path = noctalia.string.trim(tostring(config("github_token_file", "")))
	return path ~= "" and noctalia.expandPath(path) or ""
end

-- Nix reads the directory as a flake reference: anything but an absolute path
-- without ? and # would mean another flake (a registry name, a URL parameter).
local function validFlakeDir(dir)
	return dir:sub(1, 1) == "/" and dir:find("[%?#%c]") == nil
end

local function readJson(path)
	if not noctalia.fileExists(path) then
		return nil
	end
	return noctalia.json.decode(noctalia.readFile(path) or "")
end

local function mtime(path)
	-- Whole seconds: the fraction does not survive the way through result.json,
	-- and every restart would look like a change.
	local info = noctalia.fileInfo(path)
	return info ~= nil and math.floor(info.mtime) or 0
end

-- Files that change when the user updates: the flake's lock and Flatpak's
-- per-installation change marker.
local function stamps()
	return {
		lock = flakeDir() ~= "" and mtime(flakeDir() .. "/flake.lock") or 0,
		flatpakSystem = mtime("/var/lib/flatpak/.changed"),
		flatpakUser = mtime(noctalia.expandPath("~/.local/share/flatpak/.changed")),
	}
end

local function publish()
	result.running = running
	result.estimating = estimating
	result.step = step
	result.count = diff.pendingCount(result)
	result.hasUpdateCommand = noctalia.string.trim(tostring(config("update_command", ""))) ~= ""
	result.hasCleanupButton = config("cleanup_button", true) == true
	noctalia.state.set(RESULT_KEY, result)
end

local function save()
	local path = resultFile()
	if path ~= nil then
		noctalia.writeFile(path, noctalia.json.encode(result))
	end
end

-- Keys of everything pending, to notify only about updates not seen before.
local function updateKeys(r)
	local keys = {}
	for _, row in ipairs(r.inputs or {}) do
		table.insert(keys, "input:" .. row.name .. ":" .. row.newRev)
	end
	for _, row in ipairs(r.packages or {}) do
		table.insert(keys, "pkg:" .. row.name .. ":" .. row.new)
	end
	for _, row in ipairs(r.flatpak or {}) do
		table.insert(keys, "flatpak:" .. row.installation .. ":" .. row.app .. ":" .. row.branch .. ":" .. row.new)
	end
	return keys
end

local function notifyNew(previous)
	local known = {}
	for _, key in ipairs(previous or {}) do
		known[key] = true
	end
	local fresh = false
	for _, key in ipairs(result.keys) do
		if not known[key] then
			fresh = true
		end
	end
	if fresh and result.count > 0 and config("notify", true) == true then
		noctalia.notify(noctalia.tr("notify.title"), noctalia.trp("notify.body", result.count))
	end
end

local function stepError(name, message)
	if name == "lock" and message == "no-lock" then
		return noctalia.tr("errors.no_lock", { dir = flakeDir() })
	elseif name == "lock" and (message == "rate-limit" or message == "stale" or message == "bad-token") then
		return noctalia.tr("errors.lock_" .. message:gsub("%-", "_"))
	elseif name == "size" and message == "no-lock" then
		return noctalia.tr("errors.estimate_no_lock")
	elseif name == "token" then
		return noctalia.tr("errors.token_" .. message:gsub("%-", "_"), { path = tokenFile() })
	end
	return noctalia.tr("errors.step_failed", { step = noctalia.tr("steps." .. name), message = message })
end

-- Replaces the result with what this run found. What a failed step could not
-- find keeps its last known list: a network hiccup must not empty the panel or
-- announce the same updates again afterwards.
local function collect()
	local dir = dataDir()
	local previous = result
	local previousKeys = result.keys
	local sameFlake = previous.flakeDir == flakeDir()
	local fresh = {
		checkedAt = os.time(),
		flakeDir = flakeDir(),
		errors = errors,
		stamps = stamps(),
	}

	local failed = {}
	for _, e in ipairs(errors) do
		failed[e.step] = true
	end

	if flakeDir() ~= "" and not failed.lock then
		local oldLock = readJson(flakeDir() .. "/flake.lock")
		local newLock = readJson(dir .. "/new.lock")
		local rows = diff.inputs(oldLock, newLock, config("ignored_inputs", {}))
		if rows ~= nil then
			fresh.inputs = rows
		end
		if config("check_packages", true) == true and not failed["eval-old"] and not failed["eval-new"] then
			local oldPkgs = readJson(dir .. "/packages-old.json")
			local newPkgs = readJson(dir .. "/packages-new.json")
			-- A standalone Home Manager configuration counts as more packages;
			-- if it failed, both sides go without it.
			if homeConfiguration() ~= "" and not failed.home and oldPkgs ~= nil and newPkgs ~= nil then
				oldPkgs = diff.concat(oldPkgs, readJson(dir .. "/home-old.json"))
				newPkgs = diff.concat(newPkgs, readJson(dir .. "/home-new.json"))
			end
			if oldPkgs ~= nil and newPkgs ~= nil then
				fresh.packages = diff.packages(oldPkgs, newPkgs)
			end
		end
	end
	-- An estimate is made on request for one updated lock; it stays as long as
	-- the check finds the same one.
	if previous.estimate ~= nil and sameFlake then
		local made = noctalia.readFile(dir .. "/estimate.lock")
		if made ~= nil and made == noctalia.readFile(dir .. "/new.lock") then
			fresh.estimate = previous.estimate
		end
	end
	if sameFlake and failed.lock then
		fresh.inputs = previous.inputs
		fresh.estimate = previous.estimate
	end
	-- How long the last estimate took stays, as the expected duration.
	fresh.estimateMs = previous.estimateMs
	if config("check_packages", true) == true and sameFlake and (failed.lock or failed["eval-old"] or failed["eval-new"]) then
		fresh.packages = previous.packages
	end

	if config("check_flatpak", true) == true and noctalia.commandExists("flatpak") and not failed.flatpak then
		fresh.flatpak = diff.flatpak(
			noctalia.readFile(dir .. "/flatpak-installed.tsv") or "",
			noctalia.readFile(dir .. "/flatpak-updates.tsv") or ""
		)
	elseif failed.flatpak then
		fresh.flatpak = previous.flatpak
	end

	result = fresh
	result.count = diff.pendingCount(result)
	result.keys = updateKeys(result)
	notifyNew(previousKeys)
	save()
end

-- Whatever goes wrong while reading the results must not leave the service
-- "running" for an hour.
local function finish()
	local ok, err = pcall(collect)
	if not ok then
		noctalia.log("collecting the results failed: " .. tostring(err))
		table.insert(errors, { step = "", message = noctalia.tr("errors.bad_result") })
		result.errors = errors
		result.checkedAt = os.time()
		result.stamps = stamps()
	end
	running = false
	step = ""
	publish()
end

local quote = diff.quote

local function check()
	if running or estimating then
		return
	end
	local dir = dataDir()
	local pluginDir = noctalia.pluginDir()
	if dir == nil or pluginDir == nil then
		return
	end
	errors = {}
	local flake = flakeDir()
	if flake ~= "" and not validFlakeDir(flake) then
		table.insert(errors, { step = "lock", message = noctalia.tr("errors.bad_flake_dir", { dir = flake }) })
		flake = ""
	elseif flake ~= "" and not noctalia.fileExists(flake .. "/flake.nix") then
		table.insert(errors, { step = "lock", message = noctalia.tr("errors.no_flake", { dir = flake }) })
		flake = ""
	elseif flake ~= "" and not noctalia.commandExists("nix") then
		table.insert(errors, { step = "lock", message = noctalia.tr("errors.no_nix") })
		flake = ""
	end
	local command = table.concat({
		"sh",
		quote(pluginDir .. "/scripts/check.sh"),
		quote(dir),
		quote(flake),
		quote(noctalia.string.trim(tostring(config("nixos_configuration", "")))),
		config("check_packages", true) == true and "1" or "0",
		config("check_flatpak", true) == true and "1" or "0",
		quote(tokenFile()),
		quote(homeConfiguration()),
	}, " ")

	running = true
	runStarted = os.time()
	runId += 1
	local id = runId
	step = ""
	publish()
	local accepted = noctalia.runStream(command, function(line)
		if id ~= runId or not running then
			return
		end
		local kind, rest = line:match("^(%S+)%s*(.*)$")
		if kind == "step" then
			step = rest
			publish()
		elseif kind == "fail" then
			local name, message = rest:match("^(%S+)%s*(.*)$")
			table.insert(errors, { step = name or "", message = stepError(name or "", noctalia.string.trim(message or "")) })
		elseif kind == "done" then
			finish()
		end
	end)
	if not accepted then
		running = false
		table.insert(errors, { step = "", message = noctalia.tr("errors.not_started") })
		result.errors = errors
		publish()
	end
end

-- On request only (button, IPC): asks nix build --dry-run what the system from
-- the last check's updated lock would download and build. Needs that lock, so
-- not before a check, and not while one runs.
local function estimate()
	local dir = dataDir()
	local pluginDir = noctalia.pluginDir()
	local flake = flakeDir()
	if running or estimating or dir == nil or pluginDir == nil or flake == "" or not validFlakeDir(flake) then
		return
	end
	if not noctalia.fileExists(dir .. "/new.lock") then
		return
	end
	estimating = true
	estimateStarted = os.time()
	result.estimateStartedMs = noctalia.nowMs()
	estimateId += 1
	local id = estimateId
	result.estimateError = nil
	publish()
	local message = nil
	local command = table.concat({
		"sh",
		quote(pluginDir .. "/scripts/estimate.sh"),
		quote(dir),
		quote(flake),
		quote(noctalia.string.trim(tostring(config("nixos_configuration", "")))),
	}, " ")
	local accepted = noctalia.runStream(command, function(line)
		if id ~= estimateId or not estimating then
			return
		end
		local kind, rest = line:match("^(%S+)%s*(.*)$")
		if kind == "fail" then
			local name, text = rest:match("^(%S+)%s*(.*)$")
			message = stepError(name or "size", noctalia.string.trim(text or ""))
		elseif kind == "done" then
			estimating = false
			-- How long it took, as the expected duration of the next one.
			if message == nil then
				result.estimateMs = noctalia.nowMs() - (tonumber(result.estimateStartedMs) or noctalia.nowMs())
			end
			local ok, value = pcall(diff.dryRun, noctalia.readFile(dir .. "/dry-run.txt") or "")
			result.estimate = ok and value or nil
			result.estimateError = message
			if message == nil and result.estimate == nil then
				result.estimateError = noctalia.tr("errors.bad_result")
			end
			save()
			publish()
		end
	end)
	if not accepted then
		estimating = false
		result.estimateError = noctalia.tr("errors.not_started")
		publish()
	end
end

-- Runs a command in a terminal, where the user sees it and can answer a
-- password prompt.
local function runInTerminal(cmd)
	local terminal = noctalia.string.trim(tostring(config("terminal", "")))
	if terminal == "" then
		noctalia.runInTerminal(cmd)
		return
	end
	-- Not runInTerminal: that would open Noctalia's terminal around this one.
	noctalia.runAsync(diff.terminalCommand(terminal, cmd))
end

-- The update command from the settings; without one, the settings, so the
-- user can set one.
local function runUpdate()
	local cmd = noctalia.string.trim(tostring(config("update_command", "")))
	if cmd == "" then
		noctalia.openSettings()
		return
	end
	runInTerminal(cmd)
end

-- The plugin's own cleanup script, the same on every system (see its header).
-- Nothing to check afterwards: it removes only what nothing uses, the pending
-- updates stay the same.
local function runCleanup()
	local pluginDir = noctalia.pluginDir()
	if pluginDir ~= nil and config("cleanup_button", true) == true then
		runInTerminal("sh " .. quote(pluginDir .. "/scripts/cleanup.sh"))
	end
end

local function offline()
	return noctalia.getSetting("shell.offline_mode") == true
end

noctalia.state.watch(COMMAND_KEY, function(cmd)
	if type(cmd) ~= "table" then
		return
	end
	if cmd.action == "check" then
		check()
	elseif cmd.action == "update" then
		runUpdate()
	elseif cmd.action == "estimate" then
		estimate()
	elseif cmd.action == "cleanup" then
		runCleanup()
	end
end)

function onIpc(event, _payload)
	if event == "check" then
		check()
	elseif event == "update" then
		runUpdate()
	elseif event == "estimate" then
		estimate()
	elseif event == "cleanup" then
		runCleanup()
	end
end

-- Checked once a minute: due by interval, or something was updated since the
-- last check (then wait SETTLE_S for it to finish).
noctalia.setUpdateInterval(60 * 1000)

-- Restart and storage facts for the panel, cheap enough for every tick: the
-- running and the current system's kernel, initrd and modules (NixOS keeps both
-- under /run), free space of the store's file system, system generations.
local BOOTED, CURRENT = "/run/booted-system/", "/run/current-system/"
local function refreshSystem()
	local generations = 0
	local names = noctalia.listDir("/nix/var/nix/profiles")
	for _, name in ipairs(type(names) == "table" and names or {}) do
		if tostring(name):match("^system%-%d+%-link$") then
			generations += 1
		end
	end
	noctalia.runAsync({ "df", "-B1", "--output=avail,size", "/nix/store" }, function(df)
		local free, size = tostring(df.stdout or ""):match("\n%s*(%d+)%s+(%d+)")
		local links = {
			BOOTED .. "kernel", CURRENT .. "kernel",
			BOOTED .. "initrd", CURRENT .. "initrd",
			BOOTED .. "kernel-modules", CURRENT .. "kernel-modules",
		}
		table.insert(links, 1, "-f")
		table.insert(links, 1, "readlink")
		noctalia.runAsync(links, function(r)
			local reboot = nil
			if r.exitCode == 0 then
				local paths = {}
				for line in tostring(r.stdout or ""):gmatch("[^\n]+") do
					table.insert(paths, line)
				end
				reboot = diff.reboot(paths)
			end
			noctalia.state.set(SYSTEM_KEY, {
				free = tonumber(free),
				size = tonumber(size),
				generations = generations,
				reboot = reboot,
			})
		end)
	end)
end

function update()
	refreshSystem()
	local now = os.time()
	if estimating and now - estimateStarted > STALE_ESTIMATE_S then
		estimating = false
		estimateId += 1
		publish()
	end
	if running then
		if now - runStarted > STALE_RUN_S then
			running = false
			runId += 1
			publish()
		end
		return
	end
	if offline() then
		return
	end
	local last = tonumber(result.checkedAt) or 0
	local interval = math.max(tonumber(config("check_interval_hours", 6)) or 6, 1) * 3600
	if type(result.errors) == "table" and #result.errors > 0 then
		interval = math.min(interval, RETRY_S)
	end
	local old = result.stamps or {}
	local current = stamps()
	local touched = old.lock ~= current.lock or old.flatpakSystem ~= current.flatpakSystem or old.flatpakUser ~= current.flatpakUser
	if touched and last > 0 then
		if changedAt == 0 then
			changedAt = now
		end
		if now - changedAt < SETTLE_S then
			return
		end
	end
	if now - last >= interval or (touched and last > 0) then
		changedAt = 0
		check()
	end
end

-- Show the last result right away; the first check waits for the first tick,
-- so the network is up after a login.
local saved = resultFile() ~= nil and readJson(resultFile()) or nil
if type(saved) == "table" then
	result = saved
end
publish()
refreshSystem()
