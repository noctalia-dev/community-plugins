--!nonstrict
-- Service for OPPO / OnePlus / realme Pods
-- Controls and polls earbuds via scripts/oppo_ctl.py

local SNAPSHOT_KEY = "oppo_pods_snapshot"
local COMMAND_KEY = "oppo_pods_command"

local scriptPath = noctalia.pluginDir() .. "/scripts/oppo_ctl.py"

local NEXT_MODE = { anc = "transparency", transparency = "off", off = "anc" }
local ANC_LEVELS = { mild = true, moderate = true, max = true, smart = true }

local function getCliCmd(args)
	local mac = noctalia.getConfig("device_mac")
	local cmd = "python3 " .. scriptPath .. " " .. args
	if mac and mac ~= "" then
		cmd = cmd .. " --mac " .. mac
	end
	return cmd
end

local function updateSnapshot(data)
	if type(data) == "table" then
		noctalia.state.set(SNAPSHOT_KEY, data)
	end
end

-- Show a change right away; the follow-up status poll corrects it if the earbuds refused.
local function patchSnapshot(fields)
	local snapshot = noctalia.state.get(SNAPSHOT_KEY)
	if type(snapshot) ~= "table" then
		return
	end
	local copy = table.clone(snapshot)
	for key, value in fields do
		copy[key] = value
	end
	noctalia.state.set(SNAPSHOT_KEY, copy)
end

-- The earbuds accept a single RFCOMM client, so script runs are serialized.
-- Only the latest pending command is kept: rapid clicks collapse into the final choice.
local busy = false
local queued = nil

local function run(args, onDone)
	busy = true
	noctalia.runAsync(getCliCmd(args), function(result)
		busy = false
		local ok, parsed = pcall(noctalia.json.decode, result and result.stdout or "")
		if ok and type(parsed) == "table" then
			onDone(parsed)
		end
		if queued then
			local job = queued
			queued = nil
			run(job.args, job.onDone)
		end
	end)
end

local function pollStatus()
	if busy then
		return
	end
	run("status", function(parsed)
		-- A poll that started before a queued command would revert its optimistic update.
		if not queued then
			updateSnapshot(parsed)
		end
	end)
end

local function runCommand(args, onDone)
	local job = {
		args = args,
		onDone = function(parsed)
			onDone(parsed)
			queued = queued or { args = "status", onDone = updateSnapshot }
		end,
	}
	if busy then
		queued = job
	else
		run(job.args, job.onDone)
	end
end

local function notifyMode(mode, level)
	local modeLabel = noctalia.tr("panel.mode." .. mode)
	if level then
		modeLabel = modeLabel .. " · " .. noctalia.tr("panel.level." .. level)
	end
	local curState = noctalia.state.get(SNAPSHOT_KEY)
	local devName = (curState and (curState.model_name or curState.device_name)) or "OPPO Pods"
	noctalia.notify(devName, string.format(noctalia.tr("notify.mode_changed"), modeLabel), "headphones")
end

local function setNoise(value)
	local level = ANC_LEVELS[value] and value or nil
	patchSnapshot({ noise_mode = level and "anc" or value, noise_level = level })
	runCommand("set-anc " .. value, function(parsed)
		if parsed.mode then
			notifyMode(parsed.mode, parsed.level)
		end
	end)
end

local function setGame(enabled)
	patchSnapshot({ game_mode = enabled })
	runCommand("set-game " .. (enabled and "on" or "off"), function() end)
end

local function handle(action, value)
	if action == "set-noise" and (NEXT_MODE[value] or ANC_LEVELS[value]) then
		setNoise(value)
	elseif action == "cycle-noise" then
		local snapshot = noctalia.state.get(SNAPSHOT_KEY) or {}
		setNoise(NEXT_MODE[snapshot.noise_mode] or "anc")
	elseif action == "set-game" then
		setGame(value == true or value == "on" or value == "true")
	elseif action == "toggle-game" then
		local snapshot = noctalia.state.get(SNAPSHOT_KEY) or {}
		setGame(snapshot.game_mode ~= true)
	elseif action == "refresh" then
		pollStatus()
	end
end

noctalia.state.watch(COMMAND_KEY, function(cmdObj)
	if type(cmdObj) == "table" and cmdObj.action then
		handle(cmdObj.action, cmdObj.value)
	end
end)

-- Handle IPC events dispatched to this service (e.g. from right-click action or keybindings)
function onIpc(event, payload)
	handle(event, payload)
end

-- Initial fast poll, then interval polling every 4 seconds
pollStatus()
noctalia.setUpdateInterval(4000)

function update()
	pollStatus()
end
