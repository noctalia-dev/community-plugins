-- Shared stubs for plugin tests. Concatenated with the entry under test
-- (the system luau binary has no loadfile), then assertions run.
ACTIVE_PROFILE = ACTIVE_PROFILE or "r60i"

local captured = { state = {}, toasts = {} }
local watchers = {}

local TOUCH_ACTIONS = { "VolumeUp", "VolumeDown", "PlayPause", "NextTrack" }

local LIST_SETTINGS = {
	ambientSoundMode = { setting = { options = { "NoiseCanceling", "Transparency", "Normal" } } },
	noiseCancelingMode = { setting = { options = { "Manual", "Adaptive", "MultiScene" } } },
	manualNoiseCanceling = { setting = { start = 1, ["end"] = 5 } },
	resetButtonsToDefault = { setting = {} },
	touchTone = { setting = {} },
	batteryLevelLeft = { setting = {} },
	batteryLevelRight = { setting = {} },
	caseBatteryLevel = { setting = {} },
	isChargingLeft = { setting = {} },
	isChargingRight = { setting = {} },
	twsStatus = { setting = {} },
	hostDevice = { setting = {} },
	transparencyMode = { setting = { options = { "FullyTransparent", "VocalMode" } } },
	multiSceneNoiseCanceling = { setting = { options = { "Transport", "Outdoor", "Indoor" } } },
	autoPowerOff = { setting = { options = { "disabled", "10m", "30m" } } },
	limitHighVolumeRefreshRate = { setting = { options = { "RealTime", "10s", "1m" } } },
	windNoiseSuppression = { setting = {} },
	dualConnections = { setting = {} },
	lowBatteryPrompt = { setting = {} },
	limitHighVolume = { setting = {} },
	realTimeAdaptiveNoiseCanceling = { setting = {} },
	limitHighVolumeDbLimit = { setting = { start = 75, ["end"] = 100, step = 5 } },
	firmwareVersionLeft = { setting = {} },
	firmwareVersionRight = { setting = {} },
	serialNumber = { setting = {} },
	adaptiveNoiseCanceling = { setting = {} },
	dualConnectionsDevices = { setting = {} },
	leftSinglePress = { setting = { options = TOUCH_ACTIONS, localizedOptions = { "Volume Up", "Volume Down", "Play/Pause", "Next" } } },
	rightSinglePress = { setting = { options = TOUCH_ACTIONS, localizedOptions = { "Volume Up", "Volume Down", "Play/Pause", "Next" } } },
	leftDoublePress = { setting = { options = TOUCH_ACTIONS } },
	rightDoublePress = { setting = { options = TOUCH_ACTIONS } },
	leftTriplePress = { setting = { options = TOUCH_ACTIONS } },
	rightTriplePress = { setting = { options = TOUCH_ACTIONS } },
	leftLongPress = { setting = { options = TOUCH_ACTIONS } },
	rightLongPress = { setting = { options = TOUCH_ACTIONS } },
}
local GET_VALUES = {
	ambientSoundMode = "NoiseCanceling",
	noiseCancelingMode = "Adaptive",
	manualNoiseCanceling = 5,
	batteryLevelLeft = "10/10",
	batteryLevelRight = "9/10",
	caseBatteryLevel = "8/10",
	isChargingLeft = "No",
	isChargingRight = "Yes",
	twsStatus = "Connected",
	hostDevice = "Left",
	touchTone = "Yes",
	transparencyMode = "FullyTransparent",
	multiSceneNoiseCanceling = "Outdoor",
	autoPowerOff = "30m",
	limitHighVolumeRefreshRate = "RealTime",
	windNoiseSuppression = "true",
	dualConnections = "true",
	lowBatteryPrompt = "true",
	limitHighVolume = "false",
	realTimeAdaptiveNoiseCanceling = "false",
	limitHighVolumeDbLimit = 100,
	firmwareVersionLeft = "04.89",
	firmwareVersionRight = "04.89",
	serialNumber = "ABC123",
	adaptiveNoiseCanceling = "Weak",
	dualConnectionsDevices = "AA:BB:CC:DD:EE:FF",
	leftSinglePress = "PlayPause",
	rightSinglePress = "VolumeUp",
	leftDoublePress = "NextTrack",
	rightDoublePress = "VolumeDown",
	leftTriplePress = "",
	rightTriplePress = "",
	leftLongPress = "PlayPause",
	rightLongPress = "PlayPause",
}
local GET_ORDER = {
	"ambientSoundMode", "noiseCancelingMode", "manualNoiseCanceling",
	"batteryLevelLeft", "batteryLevelRight", "caseBatteryLevel",
	"isChargingLeft", "isChargingRight", "twsStatus", "hostDevice",
	"touchTone",
"transparencyMode", "multiSceneNoiseCanceling",
"autoPowerOff", "limitHighVolumeRefreshRate",
	"windNoiseSuppression", "dualConnections", "lowBatteryPrompt",
	"limitHighVolume", "realTimeAdaptiveNoiseCanceling", "limitHighVolumeDbLimit",
	"firmwareVersionLeft", "firmwareVersionRight", "serialNumber",
	"adaptiveNoiseCanceling", "dualConnectionsDevices",
	"leftSinglePress", "rightSinglePress", "leftDoublePress", "rightDoublePress",
	"leftTriplePress", "rightTriplePress", "leftLongPress", "rightLongPress",
}

local deviceState = {
	ambient = "NoiseCanceling",
	cancel = "Adaptive",
	manual = 5,
}

-- Life Q30 (A3028, over-ear) fixture: single battery, no touch/case/TWS,
-- Transport/Indoor/Outdoor cancel modes. See OpenSCQ30 a3028.rs.
local Q30_LIST_SETTINGS = {
	ambientSoundMode = { setting = { options = { "NoiseCanceling", "Transparency", "Normal" } } },
	noiseCancelingMode = { setting = { options = { "Transport", "Indoor", "Outdoor" } } },
	batteryLevel = { setting = {} },
	isCharging = { setting = {} },
	autoPowerOff = { setting = { options = { "disabled", "30m", "60m" } } },
	serialNumber = { setting = {} },
}
local Q30_GET_VALUES = {
	ambientSoundMode = "NoiseCanceling",
	noiseCancelingMode = "Outdoor",
	batteryLevel = "4/10",
	isCharging = "No",
	autoPowerOff = "30m",
	serialNumber = "Q30SN001",
}
local Q30_GET_ORDER = {
	"ambientSoundMode", "noiseCancelingMode", "batteryLevel",
	"isCharging", "autoPowerOff", "serialNumber",
}
local PAIRED_ID, PAIRED_MAC, PAIRED_NAME =
	"SoundcoreD1202C", "34:09:C9:6E:F6:D6", "soundcore R60i NC"
if ACTIVE_PROFILE == "q30" then
	LIST_SETTINGS = Q30_LIST_SETTINGS
	GET_VALUES = Q30_GET_VALUES
	GET_ORDER = Q30_GET_ORDER
	deviceState.ambient = "NoiseCanceling"
	deviceState.cancel = "Outdoor"
	PAIRED_ID, PAIRED_MAC, PAIRED_NAME = "SoundcoreA3028", "11:22:33:44:55:66", "Soundcore Q30"
end

local function canned(argv)
	local cmd = table.concat(argv, " ")
	if string.find(cmd, "list%-models", 1) then
		return { exitCode = 0, stdout = "SoundcoreD1202C\tSoundcore R60i NC\nSoundcoreA3028\tSoundcore Q30\n", stderr = "" }
	elseif string.find(cmd, "paired%-devices", 1) then
		if PAIRED_EMPTY then
			return { exitCode = 0, stdout = "Device Model\tMAC Address\tDemo Mode\n", stderr = "" }
		end
		return { exitCode = 0, stdout = "Device Model\tMAC Address\tDemo Mode\n" .. PAIRED_ID .. "\t" .. PAIRED_MAC .. "\tNo\n", stderr = "" }
	elseif argv[1] == "bluetoothctl" and argv[2] == "info" then
		INFO_CALLS = (INFO_CALLS or 0) + 1
		if BT_DOWN then
			return { exitCode = 0, stdout = "Device " .. PAIRED_MAC .. " (public)\n\tName: " .. PAIRED_NAME .. "\n\tConnected: no\n", stderr = "" }
		end
		return { exitCode = 0, stdout = "Device " .. PAIRED_MAC .. " (public)\n\tName: " .. PAIRED_NAME .. "\n\tConnected: yes\n", stderr = "" }
	elseif argv[1] == "bluetoothctl" then
		if PAIRED_EMPTY then
			return { exitCode = 0, stdout = "", stderr = "" }
		end
		return { exitCode = 0, stdout = "Device " .. PAIRED_MAC .. " " .. PAIRED_NAME .. "\n", stderr = "" }
	elseif string.find(cmd, "list%-settings", 1) then
		LIST_CALLS = (LIST_CALLS or 0) + 1
		return { exitCode = 0, stdout = "__LIST_SETTINGS__", stderr = "" }
	elseif string.find(cmd, "setting", 1) then
		if string.find(cmd, "%-%-set", 1) then
			for kv in string.gmatch(cmd, "%-%-set ([^ ]+)") do
				local k, v = string.match(kv, "^([^=]+)=(.*)$")
				if k == "ambientSoundMode" then deviceState.ambient = v
				elseif k == "noiseCancelingMode" then deviceState.cancel = v
				elseif k == "manualNoiseCanceling" then deviceState.manual = tonumber(v) or deviceState.manual
				elseif k == "touchTone" then GET_VALUES.touchTone = (v == "true") and "Yes" or "No"
				elseif k == "resetButtonsToDefault" then
					for _, id in ipairs({ "leftSinglePress", "rightSinglePress", "leftDoublePress", "rightDoublePress", "leftTriplePress", "rightTriplePress", "leftLongPress", "rightLongPress" }) do
						GET_VALUES[id] = "PlayPause"
					end
				elseif k == "testAutoToggle" then GET_VALUES[k] = (v == "true")
				elseif k == "testAutoRange" then GET_VALUES[k] = tonumber(v) or v
				elseif k ~= nil then GET_VALUES[k] = v end
			end
			GET_VALUES.ambientSoundMode = deviceState.ambient
			GET_VALUES.noiseCancelingMode = deviceState.cancel
			GET_VALUES.manualNoiseCanceling = deviceState.manual
			return { exitCode = 0, stdout = "[]", stderr = "" }
		end
		local reqIds = {}
		for i, a in ipairs(argv) do
			if a == "--get" and argv[i + 1] ~= nil then reqIds[argv[i + 1]] = true end
		end
		LAST_GET_IDS = reqIds
		if FAIL_BAD_ID_QUERY then
			for _, a in ipairs(argv) do
				if a == "batteryLevelLeft" then
					return { exitCode = 1, stdout = "", stderr = "SoundcoreD1202C does not use setting id batteryLevelLeft." }
				end
			end
		end
		if FAIL_GONE_QUERY then
			return { exitCode = 1, stdout = "", stderr = "Error: connection: device not found" }
		end
		if FAIL_UNKNOWN_QUERY then
			return { exitCode = 1, stdout = "", stderr = "Error: something completely unexpected" }
		end
		if FAIL_GENERIC_QUERY then
			return { exitCode = 1, stdout = "", stderr = "Error: disconnected" }
		end
		if FAIL_NEXT_QUERY then
			return { exitCode = 1, stdout = "", stderr = "connection: connect timed out" }
		end
		return { exitCode = 0, stdout = "__GET_VALUES__", stderr = "" }
	end
	return { exitCode = 1, stdout = "", stderr = "unexpected: " .. cmd }
end

-- Deferred find callbacks: the real find.sh runs ~20s, so tests can hold
-- the completion callback and drive queue/stop transitions deterministically.
DEFER_FIND = false
DEFERRED_CB = nil
NOW_MS = 1000
FAIL_NEXT_QUERY = false
FAIL_GONE_QUERY = false
FAIL_UNKNOWN_QUERY = false
FAIL_GENERIC_QUERY = false
FAIL_BAD_ID_QUERY = false
LIST_OMIT_LEFT = false
LAST_GET_IDS = nil
LIST_CALLS = 0
INFO_CALLS = 0
BT_DOWN = false
PAIRED_EMPTY = false
DEFER_QUERY = false
DEFERRED_QUERY_CB = nil

noctalia = {
	string = {
		trim = function(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end,
	},
	json = {
		decode = function(s)
			if s == "__LIST_SETTINGS__" then
				if LIST_OMIT_LEFT then
					local copy = {}
					for k, v in pairs(LIST_SETTINGS) do
						if k ~= "batteryLevelLeft" then copy[k] = v end
					end
					return copy
				end
				return LIST_SETTINGS
			end
			if s == "__GET_VALUES__" then
				local rows = {}
				for _, id in ipairs(GET_ORDER) do
					-- Like the real daemon: only requested ids are returned.
					if LAST_GET_IDS == nil or LAST_GET_IDS[id] then
						table.insert(rows, { settingId = id, value = { value = GET_VALUES[id] } })
					end
				end
				return rows
			end
			if s == "[]" then return {} end
			error("json.decode got unexpected input: " .. tostring(s):sub(1, 60))
		end,
		encode = function() return "{}" end,
	},
	state = {
		set = function(k, v) captured.state[k] = v; if watchers[k] then watchers[k](v) end end,
		get = function(k) return captured.state[k] end,
		watch = function(k, fn) watchers[k] = fn end,
	},
	getConfig = function(k)
		if k == "poll_interval" then return 4 end
		if k == "hide_when_disconnected" then return true end
		if k == "openscq30_path" then return "" end
		if k == "icon" then return "Auto" end
		return nil
	end,
	setUpdateInterval = function() end,
	nowMs = function() return NOW_MS end,
	getenv = function() return nil end,
	pluginDir = function() return "/home/sanki/Documents/project/noctalia-dev/soundcore-buds" end,
	commandExists = function(n) return n == "openscq30" or n == "bluetoothctl" end,
	runAsync = function(argv, cb)
		local cmd = table.concat(argv, " ")
		if string.find(cmd, "find.sh", 1, true) then
			if string.find(cmd, " stop", 1, true) then
				captured.stopCalls = captured.stopCalls or {}
				table.insert(captured.stopCalls, cmd)
				cb({ exitCode = 0, stdout = "", stderr = "" })
				return true
			end
			captured.findCalls = captured.findCalls or {}
			table.insert(captured.findCalls, cmd)
			if DEFER_FIND then
				DEFERRED_CB = cb
				return true
			end
			cb({ exitCode = 0, stdout = "", stderr = "" })
			return true
		end
		if DEFER_QUERY and string.find(cmd, "%-%-get", 1) then
			DEFERRED_QUERY_CB = cb
			return true
		end
		local r = canned(argv); cb(r); return true
	end,
	tr = function(k) return k end,
	isDarkMode = function() return true end,
	log = function(m) captured.logs = captured.logs or {}; table.insert(captured.logs, m) end,
}

local function mkui()
	local ui = {}
	for _, name in ipairs({ "column", "row", "scroll", "label", "markdown", "glyph", "image", "box", "separator", "spacer", "progress", "button", "graph", "toggle", "slider", "select", "input" }) do
		ui[name] = function(props, children) return { _kind = name, props = props, children = children } end
	end
	return ui
end
ui = mkui()

barWidget = {
	setVisible = function(v) captured.visible = v end,
	isVertical = function() return false end,
	render = function(t) captured.widgetTree = t end,
	setTooltip = function(t) captured.tooltip = t end,
}
panel = {
	render = function(t) captured.panelTree = t end,
	close = function() end,
}
