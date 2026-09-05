--!nonstrict
-- Service for OPPO / OnePlus / realme Pods
-- Controls and polls earbuds via scripts/oppo_ctl.py

local SNAPSHOT_KEY = "oppo_pods_snapshot"
local COMMAND_KEY = "oppo_pods_command"

local scriptPath = noctalia.pluginDir() .. "/scripts/oppo_ctl.py"

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

local function pollStatus()
	local cmd = getCliCmd("status")
	noctalia.runAsync(cmd, function(result)
		if result and result.stdout and result.stdout ~= "" then
			local ok, parsed = pcall(function()
				return noctalia.json.decode(result.stdout)
			end)
			if ok and parsed then
				updateSnapshot(parsed)
			end
		end
	end)
end

local function notifyMode(mode)
	local modeKey = "panel.mode." .. mode
	local modeLabel = noctalia.tr(modeKey)
	local curState = noctalia.state.get(SNAPSHOT_KEY)
	local devName = (curState and (curState.model_name or curState.device_name)) or "OPPO Pods"
	noctalia.notify(devName, string.format(noctalia.tr("notify.mode_changed"), modeLabel), "headphones")
end

local function executeCommand(cmdObj)
	if type(cmdObj) ~= "table" or not cmdObj.action then
		return
	end

	if cmdObj.action == "set-noise" and cmdObj.value then
		local cmd = getCliCmd("set-anc " .. tostring(cmdObj.value))
		noctalia.runAsync(cmd, function(result)
			if result and result.stdout then
				local ok, parsed = pcall(function() return noctalia.json.decode(result.stdout) end)
				if ok and parsed and parsed.mode then
					notifyMode(parsed.mode)
				end
			end
			pollStatus()
		end)
	elseif cmdObj.action == "cycle-noise" then
		local cmd = getCliCmd("cycle-anc")
		noctalia.runAsync(cmd, function(result)
			if result and result.stdout then
				local ok, parsed = pcall(function() return noctalia.json.decode(result.stdout) end)
				if ok and parsed and parsed.mode then
					notifyMode(parsed.mode)
				end
			end
			pollStatus()
		end)
	elseif cmdObj.action == "refresh" then
		pollStatus()
	end
end

-- Handle IPC events dispatched to this service (e.g. from right-click action or keybindings)
function onIpc(event, payload)
	if event == "cycle-noise" then
		local cmd = getCliCmd("cycle-anc")
		noctalia.runAsync(cmd, function(result)
			if result and result.stdout then
				local ok, parsed = pcall(function() return noctalia.json.decode(result.stdout) end)
				if ok and parsed and parsed.mode then
					notifyMode(parsed.mode)
				end
			end
			pollStatus()
		end)
	elseif event == "set-noise" and payload then
		local cmd = getCliCmd("set-anc " .. tostring(payload))
		noctalia.runAsync(cmd, function(result)
			if result and result.stdout then
				local ok, parsed = pcall(function() return noctalia.json.decode(result.stdout) end)
				if ok and parsed and parsed.mode then
					notifyMode(parsed.mode)
				end
			end
			pollStatus()
		end)
	elseif event == "refresh" then
		pollStatus()
	end
end

noctalia.state.watch(COMMAND_KEY, executeCommand)

-- Initial fast poll, then interval polling every 4 seconds
pollStatus()
noctalia.setUpdateInterval(4000)

function update()
	pollStatus()
end
