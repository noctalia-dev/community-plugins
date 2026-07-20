noctalia.setUpdateInterval(1000)

-- Helper functions
function tr(key)
	return noctalia.tr(key)
end

function cfg(key)
	return noctalia.getConfig(key)
end

function getState(key)
	return noctalia.state.get(key)
end

function setState(key, val)
	noctalia.state.set(key, val)
end

function watchState(key, cb)
	noctalia.state.watch(key, cb)
end

function killWithPidFile(file)
	if noctalia.fileExists(file) then
		local content = noctalia.readFile(file) or ""
		local pid = noctalia.string.trim(content)

		if type(pid) == "string" and pid ~= "" then
			noctalia.runAsync(`pkill -9 -P {pid} && kill -9 {pid}`)
		end
		noctalia.removeFile(file)
	end
end

-- Vars
local branch = cfg("branch")
local updateCheckInterval = cfg("update_check_interval")
local updateCheckDurationThreshold = cfg("update_check_duration_threshold")
local systemStatsCheckInterval = cfg("system_stats_check_interval")
local systemStatsCheckDurationThreshold = cfg("system_stats_check_duration_threshold")
local stateDir = noctalia.pluginDataDir() or "/tmp/nix-monitor"
local remoteHashFile = stateDir .. "/remoteHash"
local storeSizeFile = stateDir .. "/storeSize"
local closureSizeFile = stateDir .. "/closureSize"
local remotePidFile = stateDir .. "/remoteHash.pid"
local storePidFile = stateDir .. "/storeSize.pid"
local closurePidFile = stateDir .. "/closureSize.pid"
local showUpdateAvailableNotification = true

local localHashCmd = "nixos-version --hash 2> /dev/null | cut -c -7"
local remoteHashCmd = "git ls-remote https://github.com/NixOS/nixpkgs " .. branch .. " 2>/dev/null | cut -c 1-7"
local nixosGenerationsCmd = "nixos-rebuild list-generations | tail -n +2 | wc -l"
local nixosCurrentGenCmd = "nixos-rebuild list-generations | grep True | awk '{print $1}'"
local hmGenerationsCmd = "home-manager generations | wc -l"
local hmCurrentGenCmd = "home-manager generations | grep '(current)' | awk '{print $5}'"
local storeSizeCmd = "du -s --block-size=1 /nix/store | awk '{printf \"%.2f GiB\", $1/1073741824}'"
local closureSizeCmd = "nix path-info --closure-size --human-readable /run/current-system | awk '{print $2, $3}'"

-- State inits
setState("lastLocalCheckTime", os.time())
setState("lastRemoteCheckRunTime", os.time())
setState("lastRemoteCheckTime", os.time())
setState("lastRemoteCheckTimeStr", "n/a")
setState("localHash", "n/a")
setState("remoteHash", "n/a")
setState("isRemoteCheckRunning", false)
setState("isUpdateAvailable", false)
setState("lastGenerationsCheckTime", 0)
setState("isSystemStatsCheckRunning", false)
setState("lastSystemStatsCheckTime", os.time())
setState("lastSystemStatsCheckRunTime", os.time())
setState("hasHomeManager", noctalia.commandExists("home-manager"))
setState("nixosGenerations", "•••")
setState("nixosCurrentGen", "•••")
setState("hmGenerations", "•••")
setState("hmCurrentGen", "•••")
setState("storeSize", "•••")
setState("closureSize", "•••")

noctalia.mkdirAll(stateDir)
noctalia.writeFile(remoteHashFile, "")

-- Local check
function checkLocalHash()
	setState("lastLocalCheckTime", os.time())
	noctalia.runAsync(localHashCmd, function(res)
		if res.exitCode == 0 then
			setState("localHash", noctalia.string.trim(res.stdout))
		end
	end)
end

-- Remote check
--
-- Currently it is writing to a file because when I use the runAsync with
-- the callback, it is timed out
function checkRemoteHash(delay: number?)
	local _delay = delay or 0

	if getState("isRemoteCheckRunning") then
		return
	end

	setState("isRemoteCheckRunning", true)
	setState("lastRemoteCheckRunTime", os.time())

	if cfg("show_update_check_notification") then
		noctalia.notify(tr("notification.checking_update"))
	end

	noctalia.writeFile(remoteHashFile, "")
	noctalia.runAsync(`sleep {_delay} && {remoteHashCmd} > {remoteHashFile} & echo $! > {remotePidFile}`)
end

-- Check if the remoteHash check command is finished by reading the file
function checkRemoteStatus()
	local remoteHashFileContent = noctalia.readFile(remoteHashFile) or ""
	local remoteHash = noctalia.string.trim(remoteHashFileContent)

	if type(remoteHash) == "string" and remoteHash ~= "" then
		setState("isRemoteCheckRunning", false)
		setState("remoteHash", remoteHash)
		onRemoteHashCheckCompleted()
	end
end

function onRemoteHashCheckCompleted()
	if cfg("show_update_check_notification") then
		noctalia.notify(tr("notification.update_check_completed"))
	end

	setState("lastRemoteCheckTime", os.time())

	local date = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
	setState("lastRemoteCheckTimeStr", date)

	noctalia.removeFile(remotePidFile)
end

function cancelRemoteCheck()
	setState("isRemoteCheckRunning", false)
	killWithPidFile(remotePidFile)
end

-- Generation check
function checkGenerations()
	setState("lastGenerationsCheckTime", os.time())

	noctalia.runAsync(nixosGenerationsCmd, function(result)
		setState("nixosGenerations", noctalia.string.trim(result.stdout))
	end)

	noctalia.runAsync(nixosCurrentGenCmd, function(result)
		setState("nixosCurrentGen", noctalia.string.trim(result.stdout))
	end)

	if getState("hasHomeManager") then
		noctalia.runAsync(hmGenerationsCmd, function(result)
			setState("hmGenerations", noctalia.string.trim(result.stdout))
		end)

		noctalia.runAsync(hmCurrentGenCmd, function(result)
			setState("hmCurrentGen", noctalia.string.trim(result.stdout))
		end)
	end
end

-- System stats check
function checkSystemStats()
	if getState("isSystemStatsCheckRunning") then
		return
	end

	setState("isSystemStatsCheckRunning", true)
	setState("lastSystemStatsCheckRunTime", os.time())

	-- Sleep 0 to trigger noctalia calling /bin/sh
	noctalia.runAsync(`sleep 0 && {storeSizeCmd} > {storeSizeFile} & echo $! > {storePidFile}`)
	noctalia.runAsync(`sleep 0 && {closureSizeCmd} > {closureSizeFile} & echo $! > {closurePidFile}`)
end

function checkSystemStatsFile()
	local storeSizeFileContent = noctalia.readFile(storeSizeFile) or ""
	local storeSize = noctalia.string.trim(storeSizeFileContent)
	local closureSizeFileContent = noctalia.readFile(closureSizeFile) or ""
	local closureSize = noctalia.string.trim(closureSizeFileContent)

	if typeof(storeSize) == "string" and storeSize ~= "" then
		setState("storeSize", storeSize)
	end

	if typeof(closureSize) == "string" and closureSize ~= "" then
		setState("closureSize", closureSize)
	end

	local success = typeof(storeSize) == "string"
		and storeSize ~= ""
		and typeof(closureSize) == "string"
		and closureSize ~= ""

	if success then
		setState("isSystemStatsCheckRunning", false)
		setState("lastSystemStatsCheckTime", os.time())
		noctalia.removeFile(storePidFile)
		noctalia.removeFile(closurePidFile)
	end
end

function cancelSystemCheck()
	setState("isSystemStatsCheckRunning", false)
	killWithPidFile(storePidFile)
	killWithPidFile(closurePidFile)
end

-- Init
checkLocalHash()
checkRemoteHash(10)
checkSystemStats()

-- Command watcher
watchState("command", function(command)
	if command == "check" then
		checkLocalHash()
		cancelRemoteCheck()
		checkRemoteHash()
		checkGenerations()
		checkSystemStats()
	end

	if command == "cancel" then
		cancelRemoteCheck()
		cancelSystemCheck()
	end
end)

--
-- Hooks
--

function update()
	-- Check local hash every 10 seconds
	if os.time() - getState("lastLocalCheckTime") >= 10 then
		checkLocalHash()
	end

	-- Remote check
	if (os.time() - getState("lastRemoteCheckTime")) >= 60 * updateCheckInterval then
		checkRemoteHash()
	end

	if getState("isRemoteCheckRunning") then
		checkRemoteStatus()

		-- Remote check timeout
		if (os.time() - getState("lastRemoteCheckRunTime")) >= 60 * updateCheckDurationThreshold then
			cancelRemoteCheck()
		end
	end

	if
		getState("localHash") ~= getState("remoteHash")
		and getState("localHash") ~= "n/a"
		and getState("remoteHash") ~= "n/a"
	then
		setState("isUpdateAvailable", true)

		if cfg("show_update_available_notification") and showUpdateAvailableNotification then
			noctalia.notify(tr("notification.update_is_available"))
			showUpdateAvailableNotification = false
		end
	else
		setState("isUpdateAvailable", false)
		showUpdateAvailableNotification = true
	end

	-- Generations check
	if (os.time() - getState("lastGenerationsCheckTime")) >= 10 then
		checkGenerations()
	end

	-- System stats check
	if (os.time() - getState("lastSystemStatsCheckTime")) >= 60 * systemStatsCheckInterval then
		checkSystemStats()
	end

	if getState("isSystemStatsCheckRunning") then
		checkSystemStatsFile()

		-- System stats check timeout
		if (os.time() - getState("lastSystemStatsCheckRunTime")) >= 60 * systemStatsCheckDurationThreshold then
			cancelSystemCheck()
		end
	end
end

function onExit(signal)
	cancelRemoteCheck()
	cancelSystemCheck()
end
