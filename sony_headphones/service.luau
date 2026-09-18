--!nonstrict
-- Service for Sony Headphones
-- Polls headphones via scripts/sony_ctl.py (MDR V2 over RFCOMM)

local SNAPSHOT_KEY = "sony_headphones_snapshot"
local COMMAND_KEY = "sony_headphones_command"

-- Single-quote a value for /bin/sh so spaces and shell metacharacters in
-- config values (e.g. a MAC or a path with spaces) stay literal.
local function shellQuote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local scriptPath
do
	local dir = noctalia.pluginDir()
	scriptPath = dir and (dir .. "/scripts/sony_ctl.py") or nil
end

local function getCliCmd(args)
	if not scriptPath then
		return nil
	end
	local cmd = "python3 " .. shellQuote(scriptPath)
	if args and args ~= "" then
		cmd = cmd .. " " .. args
	end
	local mac = noctalia.getConfig("device_mac")
	if mac and mac ~= "" then
		cmd = cmd .. " --mac " .. shellQuote(mac)
	end
	return cmd
end

local function updateSnapshot(data)
	if type(data) == "table" then
		noctalia.state.set(SNAPSHOT_KEY, data)
	end
end

-- RFCOMM sessions are short-lived and exclusive: overlapping polls can make
-- the headset stutter, so only one CLI run is in flight at a time. A command
-- that arrives mid-poll is coalesced into one extra poll afterwards.
local polling = false
local pollQueued = false
local pollStartedAt = 0
local POLL_TIMEOUT_MS = 8000

local runPoll

local function finishPoll()
	polling = false
	if pollQueued then
		pollQueued = false
		runPoll()
	end
end

runPoll = function()
	if polling then
		if noctalia.nowMs() - pollStartedAt < POLL_TIMEOUT_MS then
			pollQueued = true
			return
		end
		-- Callback never fired (process reaped): release the lock and retry.
		polling = false
		pollQueued = true
	end
	local cmd = getCliCmd("status")
	if not cmd then
		return
	end
	polling = true
	pollStartedAt = noctalia.nowMs()
	noctalia.runAsync(cmd, function(result)
		if result and result.stdout and result.stdout ~= "" then
			local ok, parsed = pcall(noctalia.json.decode, result.stdout)
			if ok and type(parsed) == "table" then
				updateSnapshot(parsed)
			end
		elseif result and result.stderr and result.stderr ~= "" then
			noctalia.log("[sony-headphones] status error: " .. tostring(result.stderr))
		end
		finishPoll()
	end)
end

local function notifyMode(mode)
	local modeLabel = noctalia.tr("panel.mode." .. mode)
	local curState = noctalia.state.get(SNAPSHOT_KEY)
	local devName = (curState and (curState.model_name or curState.device_name)) or "Sony Headphones"
	noctalia.notify(devName, noctalia.tr("notify.mode_changed", { mode = modeLabel }))
end

local function runCli(args, afterMode)
	local cmd = getCliCmd(args)
	if not cmd then
		return
	end
	noctalia.runAsync(cmd, function(result)
		if result and result.stdout then
			local ok, parsed = pcall(noctalia.json.decode, result.stdout)
			if ok and type(parsed) == "table" and parsed.mode and afterMode then
				notifyMode(parsed.mode)
			end
		end
		runPoll()
	end)
end

local lastNonce = nil
local function executeCommand(cmdObj)
	if type(cmdObj) ~= "table" or not cmdObj.action then
		return
	end
	-- noctalia.state survives a service reload, so a stale command object can
	-- be re-delivered. The panel stamps each command with a unique nonce.
	if cmdObj.nonce ~= nil then
		if cmdObj.nonce == lastNonce then
			return
		end
		lastNonce = cmdObj.nonce
	end

	if cmdObj.action == "set-noise" and cmdObj.value then
		runCli("set-anc " .. shellQuote(cmdObj.value), true)
	elseif cmdObj.action == "set-ambient" and cmdObj.value then
		runCli("set-ambient " .. shellQuote(cmdObj.value), false)
	elseif cmdObj.action == "cycle-noise" then
		runCli("cycle-anc", true)
	elseif cmdObj.action == "refresh" then
		runPoll()
	end
end

function onIpc(event, payload)
	if event == "cycle-noise" then
		runCli("cycle-anc", true)
	elseif event == "set-noise" and payload then
		runCli("set-anc " .. shellQuote(payload), true)
	elseif event == "set-ambient" and payload then
		runCli("set-ambient " .. shellQuote(payload), false)
	elseif event == "refresh" then
		runPoll()
	end
end

noctalia.state.watch(COMMAND_KEY, executeCommand)

-- Initial fast poll, then interval polling every 10 seconds
-- (RFCOMM sessions are short-lived; 4s risks audio stutter).
runPoll()
noctalia.setUpdateInterval(10000)

function update()
	runPoll()
end

function onConfigChanged()
	-- A changed device_mac takes effect on the next poll.
	runPoll()
end
