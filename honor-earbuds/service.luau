--!nonstrict
-- Background service for Honor Choice Earbuds X5

local SNAPSHOT_KEY = "honor_earbuds_snapshot"
local COMMAND_KEY = "honor_earbuds_command"

local scriptPath = noctalia.pluginDir() .. "/scripts/honor_ctl.py"

local wasConnected = false
local hasNotifiedBattery = false

local function isNotifyEnabled()
	return noctalia.getConfig("notify_on_connect") ~= false
end

function onConfigChanged()
	-- Config reloaded
end

local function getCliCmd(args)
	local mac = noctalia.getConfig("device_mac")
	local cmd = "python3 " .. scriptPath .. " " .. args
	if mac and mac ~= "" then
		cmd = cmd .. " --mac " .. mac
	end
	return cmd
end

local function notifyBattery(data)
	local parts = {}
	if data.battery_left ~= nil and data.battery_left >= 0 then
		local chg = data.charging_left and " ⚡" or ""
		table.insert(parts, string.format("%s: %d%%%s", noctalia.tr("panel.left"), data.battery_left, chg))
	end
	if data.battery_right ~= nil and data.battery_right >= 0 then
		local chg = data.charging_right and " ⚡" or ""
		table.insert(parts, string.format("%s: %d%%%s", noctalia.tr("panel.right"), data.battery_right, chg))
	end
	if data.battery_case ~= nil and data.battery_case >= 0 then
		local chg = data.charging_case and " ⚡" or ""
		table.insert(parts, string.format("%s: %d%%%s", noctalia.tr("panel.case"), data.battery_case, chg))
	end
	local body = #parts > 0 and table.concat(parts, "  •  ") or noctalia.tr("panel.status.connected")
	local title = data.model_name or noctalia.tr("panel.title")
	pcall(function()
		noctalia.notify(title, body)
	end)
end

local function updateSnapshot(data)
	if type(data) ~= "table" then
		return
	end
	local isConnected = data.connected == true

	if not isConnected then
		wasConnected = false
		hasNotifiedBattery = false
	else
		if isNotifyEnabled() and not hasNotifiedBattery then
			if (data.battery_left ~= nil and data.battery_left >= 0) or wasConnected == true then
				notifyBattery(data)
				hasNotifiedBattery = true
			end
		end
		wasConnected = true
	end

	noctalia.state.set(SNAPSHOT_KEY, data)
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
	local devName = (curState and curState.model_name) or "Honor Earbuds"
	noctalia.notify(devName, string.format(noctalia.tr("notify.mode_changed"), modeLabel))
end

local function handleNoiseAction(action, arg)
	local cmd = getCliCmd(action .. (arg and (" " .. tostring(arg)) or ""))
	noctalia.runAsync(cmd, function(result)
		if result and result.stdout and result.stdout ~= "" then
			local ok, parsed = pcall(function() return noctalia.json.decode(result.stdout) end)
			if ok and parsed then
				updateSnapshot(parsed)
				if parsed.noise_mode then
					notifyMode(parsed.noise_mode)
				end
				return
			end
		end
		pollStatus()
	end)
end

-- Listen to commands from panel.luau
noctalia.state.watch(COMMAND_KEY, function(cmdObj)
	if type(cmdObj) ~= "table" or not cmdObj.action then
		return
	end
	if cmdObj.action == "set-noise" and cmdObj.value then
		handleNoiseAction("set-anc", cmdObj.value)
	elseif cmdObj.action == "cycle-noise" then
		handleNoiseAction("cycle-anc")
	elseif cmdObj.action == "refresh" then
		pollStatus()
	end
end)

-- Handle IPC events
function onIpc(event, payload)
	if event == "cycle-noise" then
		handleNoiseAction("cycle-anc")
	elseif event == "set-noise" and payload then
		handleNoiseAction("set-anc", payload)
	elseif event == "notify-battery" then
		local cur = noctalia.state.get(SNAPSHOT_KEY)
		if cur and cur.connected then
			notifyBattery(cur)
		else
			pollStatus()
		end
	elseif event == "refresh" then
		pollStatus()
	end
end

noctalia.setUpdateInterval(2500)

function update()
	pollStatus()
end

pollStatus()
