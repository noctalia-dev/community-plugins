--!nonstrict
-- Service for Nothing/CMF earbuds (hardware-verified on a Nothing Ear (2))
-- Drives scripts/nothing_ear_ctl.py: a stateless CLI, no background daemon.
-- Polling is gated so we don't hold a Bluetooth connection open or reconnect
-- on a timer when nobody is looking — see README for the reasoning.

local shared = require("./shared.luau")

local STATUS_KEY = shared.STATUS_KEY
local COMMAND_KEY = shared.COMMAND_KEY
local DEVICES_KEY = shared.DEVICES_KEY
local DESKTOP_ACTIVE_KEY = shared.DESKTOP_ACTIVE_KEY
local DEVICE_FILE_NAME = "device.json"

local POLL_INTERVAL_MS = 4000
-- Spatial audio and codec writes replay the companion app's connect
-- session first (about 1.5 s), on top of waiting for a poll in flight.
local CLI_TIMEOUT_MS = 10000
-- Those two can also wait up to 4 s for a poll in flight and read the
-- setting back twice; 10 s could kill the helper before it saved its frames.
local SLOW_WRITE_TIMEOUT_MS = 20000
-- `bluetoothctl connect` for a device picked in the panel.
local CONNECT_TIMEOUT_MS = 20000
local SCAN_TIMEOUT_MS = 6000
local MONO_DEBOUNCE_POLLS = 2

local panelOpen = false
local desktopActive = noctalia.state.get(DESKTOP_ACTIVE_KEY) == true
local handledNonce = nil
local pollFailures = 0
local POLL_FAILURE_THRESHOLD = 2
-- The helper's full error from the last failed poll ({error, stage, message,
-- errno, ...}). Only its code goes into the published status for the panel's
-- hint; the rest goes into Copy details.
local lastError = nil
local DIAG_TIMEOUT_MS = 30000

-- A codec switch makes the headphones restart. Failed polls in that window
-- are expected, so they don't flip the panel to "not connected".
local RESTART_GRACE_MS = 30000
local restartUntil = 0
local restartSawFailure = false

-- Code of the last setting change that failed, shown in the panel until
-- the next one succeeds. Polls don't clear it: they say nothing about writes.
local writeError = nil

-- Dragging a custom EQ slider sends a value per step. Only one write runs at
-- a time; whatever arrives meanwhile is kept, and only the latest is sent.
local customEqBusy = false
local customEqQueued = nil

-- Writes still running. Polls wait for them rather than make them queue
-- for the Bluetooth lock. `writing` holds the value being written per
-- setting (spatial, codec), so the panel can show it straight away.
local writesInFlight = 0
local writing = {}
-- Finished writes per setting, so the panel knows when the one it asked for
-- is over even if it never saw `writing` for it.
local writesDone = {}

-- The codec asked for, checked against what the headphones report once
-- they're back from the restart (or the restart window ran out without one).
local codecWanted = nil

-- A device picked in the panel that BlueZ is being asked to connect.
local connecting = false

-- With "hide when disconnected" on and no earbuds picked yet, look for newly
-- paired ones every this many update ticks.
local SCAN_EVERY_N_TICKS = 5

local function restarting()
	return noctalia.nowMs() < restartUntil
end

-- When nothing else needs live status (no panel/bar/widget) but the mono
-- setting is on, poll anyway so single-bud detection keeps working — just
-- slower than the foreground 4s cadence, since it's the only reason we're
-- holding a Bluetooth connection open at all.
local MONO_ONLY_POLL_EVERY_N_TICKS = 3
local tickCount = 0

-- Mono state lives at the PipeWire layer (mono_switch.py), not in a
-- Noctalia setting: monoActive/monoActivatedByAuto just mirror what that
-- script last reported so the panel toggle and the auto-detect debounce
-- don't have to shell out on every render.
local monoActive = false
local monoActivatedByAuto = false
local monoTriggerPolls = 0
local monoClearPolls = 0
-- Set when the user flips mono by hand, so auto-detect doesn't immediately
-- undo it; cleared once the buds leave the single-bud state.
local monoAutoSuppressed = false

local function ctlPath()
	return noctalia.pluginDir() .. "/scripts/nothing_ear_ctl.py"
end

local function monoCtlPath()
	return noctalia.pluginDir() .. "/scripts/mono_switch.py"
end

-- Plugins can't write their own `[[setting]]` values (no setConfig in the
-- host API), so a device picked in the panel or found by auto-scan is
-- persisted here instead, in pluginDataDir(). The `device_mac` setting stays
-- available as an explicit manual override and wins when the user sets it.
local function deviceFilePath()
	local dir = noctalia.pluginDataDir()
	if dir == nil then
		return nil
	end
	return dir .. "/" .. DEVICE_FILE_NAME
end

local function loadOverrideMac()
	local path = deviceFilePath()
	if path == nil then
		return nil
	end
	local raw = noctalia.readFile(path)
	if type(raw) ~= "string" or raw == "" then
		return nil
	end
	local ok, parsed = pcall(function()
		return noctalia.json.decode(raw)
	end)
	if ok and type(parsed) == "table" and type(parsed.mac) == "string" and parsed.mac ~= "" then
		return parsed.mac
	end
	return nil
end

local function saveOverrideMac(mac)
	local path = deviceFilePath()
	if path == nil then
		return
	end
	if mac == nil or mac == "" then
		noctalia.writeFile(path, "")
	else
		noctalia.writeFile(path, noctalia.json.encode({ mac = mac }))
	end
end

local overrideMac = loadOverrideMac()

local function deviceMac()
	local mac = noctalia.getConfig("device_mac")
	if type(mac) == "string" and mac ~= "" then
		return mac
	end
	if overrideMac ~= nil and overrideMac ~= "" then
		return overrideMac
	end
	return ""
end

local function showInBar()
	return noctalia.getConfig("show_in_bar") ~= false
end

local function monoAutoSetting()
	return noctalia.getConfig("mono_on_single_bud") == true
end

local function publish(data)
	if type(data) == "table" then
		data.mono_active = monoActive
		data.mono_auto = monoAutoSetting() and not (data.model or {}).battery_single
		data.mono_by_auto = monoActive and monoActivatedByAuto
		data.restarting = restarting()
		data.write_error = writeError
		data.connecting = connecting or nil
		data.device = deviceMac()
		local inFlight = {}
		for k, v in pairs(writing) do
			inFlight[k] = v
		end
		data.writing = inFlight
		local done = {}
		for k, v in pairs(writesDone) do
			done[k] = v
		end
		data.writes_done = done
		noctalia.state.set(STATUS_KEY, data)
	end
end

local function republishMono()
	local current = noctalia.state.get(STATUS_KEY)
	if type(current) == "table" then
		publish(current)
	end
end

-- The helper always prints JSON, even for errors; no JSON means it didn't
-- run at all (python3 missing, an import error, killed by the timeout).
-- Keep the last stderr line so Copy details still has something to show.
local function helperFailure(result)
	local stderr = (result and result.stderr) or ""
	local tail = stderr:match("([^\n]+)\n*$") or ""
	return {
		ok = false,
		connected = false,
		error = "helper_failed",
		stage = "launch",
		message = tail ~= "" and tail or "no output from the helper (timed out or failed to start)",
		exit_code = result and result.exitCode or nil,
	}
end

local function runCtl(args, callback, timeoutMs)
	local mac = deviceMac()
	if mac == "" then
		callback(nil)
		return
	end
	local argv = { "python3", ctlPath() }
	for _, a in ipairs(args) do
		table.insert(argv, a)
	end
	table.insert(argv, "--mac")
	table.insert(argv, mac)

	noctalia.runAsync(argv, function(result)
		local ok, parsed = false, nil
		if result ~= nil and result.stdout ~= nil and result.stdout ~= "" then
			ok, parsed = pcall(function()
				return noctalia.json.decode(result.stdout)
			end)
		end
		if ok and type(parsed) == "table" then
			callback(parsed)
		else
			callback(helperFailure(result))
		end
	end, timeoutMs or CLI_TIMEOUT_MS)
end

-- BlueZ's own idea of whether the device is connected: true, false, or nil
-- when bluetoothctl can't say. Only the device-level "Connected:" line
-- counts (BlueZ 5.88 also lists BREDR./LE.Connected).
local function linkConnected(mac, callback)
	noctalia.runAsync({ "bluetoothctl", "info", mac }, function(result)
		local state = nil
		for line in ((result and result.stdout) or ""):gmatch("[^\n]+") do
			local value = line:match("^%s*Connected:%s*(%a+)%s*$")
			if value ~= nil then
				state = value == "yes"
			end
		end
		callback(state)
	end, 5000)
end

-- mono_switch.py never touches Bluetooth (it only shells out to `pactl`),
-- so unlike runCtl it doesn't need a MAC to work and can run concurrently
-- with a BT poll without fighting over the RFCOMM channel lock.
local function runMono(args, callback)
	local argv = { "python3", monoCtlPath() }
	for _, a in ipairs(args) do
		table.insert(argv, a)
	end
	local mac = deviceMac()
	if mac ~= "" then
		table.insert(argv, "--mac")
		table.insert(argv, mac)
	end
	noctalia.runAsync(argv, function(result)
		if result == nil or result.stdout == nil or result.stdout == "" then
			callback(nil)
			return
		end
		local ok, parsed = pcall(function()
			return noctalia.json.decode(result.stdout)
		end)
		if ok and type(parsed) == "table" then
			callback(parsed)
		else
			callback(nil)
		end
	end, CLI_TIMEOUT_MS)
end

local function setMono(enabled, viaAuto)
	runMono({ enabled and "mono-on" or "mono-off" }, function(parsed)
		if parsed ~= nil and parsed.ok then
			local wasActive = monoActive
			monoActive = parsed.active == true
			monoActivatedByAuto = monoActive and viaAuto == true
			-- Auto mono happens with no panel open, so say so when it flips.
			if viaAuto and monoActive ~= wasActive then
				if monoActive then
					noctalia.notify(noctalia.tr("notify.mono_on_title"), noctalia.tr("notify.mono_on_body"))
				else
					noctalia.notify(noctalia.tr("notify.mono_off_title"), noctalia.tr("notify.mono_off_body"))
				end
			end
		end
		republishMono()
	end)
end

-- battery entries are nil for a bud that's in its case (see PROTOCOL.md);
-- "exactly one of left/right present" is the v1 approximation for "one bud
-- is out, one is cased" until in-ear detection is wired in.
local function singleBudOut(battery)
	if type(battery) ~= "table" then
		return false
	end
	-- type() check rather than ~= nil: a JSON null may decode to a sentinel
	-- rather than nil, which would make every bud look present.
	return (type(battery.left) == "table") ~= (type(battery.right) == "table")
end

local function evaluateMonoAuto(battery, model)
	if not monoAutoSetting() then
		monoTriggerPolls = 0
		monoClearPolls = 0
		return
	end
	if not (model or {}).battery_single and not (battery and type(battery.single) == "table") and singleBudOut(battery) then
		monoClearPolls = 0
		monoTriggerPolls += 1
		if monoTriggerPolls >= MONO_DEBOUNCE_POLLS and not monoActive and not monoAutoSuppressed then
			setMono(true, true)
		end
	else
		monoTriggerPolls = 0
		monoAutoSuppressed = false
		monoClearPolls += 1
		if monoClearPolls >= MONO_DEBOUNCE_POLLS and monoActive and monoActivatedByAuto then
			setMono(false, true)
		end
	end
end

local function markDisconnected(code)
	monoTriggerPolls = 0
	monoClearPolls = 0
	if monoActive and monoActivatedByAuto then
		setMono(false, true)
	end
	publish({ connected = false, error = code })
end

local function pollStatus()
	runCtl({ "status" }, function(parsed)
		if parsed ~= nil and parsed.connected == true then
			pollFailures = 0
			lastError = nil
			if codecWanted ~= nil and (restartSawFailure or not restarting()) then
				if parsed.codec ~= nil and parsed.codec ~= codecWanted then
					writeError = "not_applied"
				end
				codecWanted = nil
			end
			if restartSawFailure then
				-- back from the restart
				restartUntil = 0
				restartSawFailure = false
			end
			if not monoActive then
				evaluateMonoAuto(parsed.battery, parsed.model)
				publish(parsed)
				return
			end
			-- Picking another output from the audio menu bypasses the mono
			-- sink; mono-status notices, cleans up and reports it as off.
			runMono({ "mono-status" }, function(mono)
				if mono ~= nil and mono.ok and mono.active ~= true then
					monoActive = false
					monoActivatedByAuto = false
					-- don't switch it straight back on behind the user's back
					monoAutoSuppressed = true
				end
				evaluateMonoAuto(parsed.battery, parsed.model)
				publish(parsed)
			end)
			return
		end
		if deviceMac() == "" then
			pollFailures = 0
			lastError = nil
			if monoActive and monoActivatedByAuto then
				setMono(false, true)
			end
			publish({ connected = false, unconfigured = true })
			return
		end
		-- The advisory BT lock held by a command still in flight (e.g. right
		-- after set-anc) isn't a disconnect, and mustn't replace a real error.
		if parsed ~= nil and parsed.error == "busy" then
			return
		end
		if connecting then
			return
		end
		if restarting() then
			restartSawFailure = true
			return
		end
		if parsed ~= nil then
			lastError = parsed
		end
		-- Only report "not connected" after two failures in a row, so one
		-- dropped poll doesn't flash the panel to "not connected"; BlueZ itself
		-- saying the link is down (or Bluetooth is off) is no dropped poll.
		pollFailures += 1
		local fromBlueZ = parsed ~= nil and (parsed.error == "not_connected" or parsed.error == "bt_off")
		if pollFailures >= POLL_FAILURE_THRESHOLD or fromBlueZ then
			markDisconnected(lastError and lastError.error or nil)
		end
	end)
end

local function refreshFromCache()
	runCtl({ "cached" }, function(parsed)
		if parsed ~= nil and parsed.ok ~= false then
			publish(parsed)
		end
	end)
end

local function noteWrite(parsed)
	if parsed ~= nil and parsed.ok then
		writeError = nil
	else
		writeError = (parsed and parsed.error) or "helper_failed"
	end
end

local function applyResultThenRefresh(parsed)
	noteWrite(parsed)
	if parsed ~= nil and parsed.ok then
		-- merge whatever the write handler already learned (fast optimistic update)
		local current = noctalia.state.get(STATUS_KEY) or {}
		for k, v in pairs(parsed) do
			if k ~= "ok" then
				current[k] = v
			end
		end
		publish(current)
	else
		republishMono()
	end
	pollStatus()
end

-- A setting change: counted so polls hold off meanwhile; with `key`, the
-- value being written is published so the panel shows it at once.
local function runWrite(args, callback, key, value, timeoutMs)
	writesInFlight += 1
	if key ~= nil then
		writing[key] = value
		republishMono()
	end
	runCtl(args, function(parsed)
		writesInFlight = writesInFlight - 1
		if key ~= nil then
			writing[key] = nil
			writesDone[key] = (writesDone[key] or 0) + 1
		end
		callback(parsed)
	end, timeoutMs)
end

local function setAnc(mode, strength)
	local args = { "set-anc", mode }
	if strength ~= nil and strength ~= "" then
		table.insert(args, "--strength")
		table.insert(args, strength)
	end
	runWrite(args, applyResultThenRefresh)
end

local function setEq(preset)
	runWrite({ "set-eq", tostring(preset) }, applyResultThenRefresh)
end

-- level 0 is off; the buds keep the last level for when it's turned back on.
local function setBass(level)
	runWrite({ "set-bass", tostring(level) }, applyResultThenRefresh)
end

local function setBassEnabled(enabled)
	local bass = (noctalia.state.get(STATUS_KEY) or {}).bass or {}
	setBass(enabled and math.max(1, bass.level or 1) or 0)
end

local function modelPresets()
	local model = (noctalia.state.get(STATUS_KEY) or {}).model or {}
	return model.eq_presets
end

local function setLatency(enabled)
	runWrite({ "set-latency", enabled and "1" or "0" }, applyResultThenRefresh)
end

local function setPersonalAnc(enabled)
	runWrite({ "set-personal-anc", enabled and "1" or "0" }, applyResultThenRefresh)
end

local function setSoundProfile(enabled)
	runWrite({ "set-sound-profile", enabled and "1" or "0" }, applyResultThenRefresh)
end

local function setSpatial(mode)
	if type(mode) == "string" and mode ~= "" then
		runWrite({ "set-spatial", mode }, applyResultThenRefresh, "spatial", mode, SLOW_WRITE_TIMEOUT_MS)
	end
end

-- The headphones restart to apply this; hold the panel on "restarting"
-- rather than "not connected" until they answer again.
local function setCodec(codec)
	if type(codec) ~= "string" or codec == "" then
		return
	end
	runWrite({ "set-codec", codec }, function(parsed)
		noteWrite(parsed)
		if parsed ~= nil and parsed.ok then
			restartUntil = noctalia.nowMs() + RESTART_GRACE_MS
			restartSawFailure = false
			codecWanted = codec
		end
		republishMono()
		pollStatus()
	end, "codec", codec, SLOW_WRITE_TIMEOUT_MS)
end

-- curve is "bass,mid,treble", each -6 to 6.
local function setCustomEq(curve)
	if type(curve) ~= "string" or not curve:match("^%-?%d+,%-?%d+,%-?%d+$") then
		return
	end
	if customEqBusy then
		customEqQueued = curve
		return
	end
	customEqBusy = true
	runWrite({ "set-custom-eq", curve }, function(parsed)
		customEqBusy = false
		local nextCurve = customEqQueued
		customEqQueued = nil
		if nextCurve ~= nil and nextCurve ~= curve then
			noteWrite(parsed)
			setCustomEq(nextCurve)
		else
			applyResultThenRefresh(parsed)
		end
	end)
end

local function cycleAnc()
	runWrite({ "cycle-anc" }, applyResultThenRefresh)
end

-- `bluetoothctl connect`, with "Connecting…" in the panel meanwhile.
local function connectDevice(mac)
	connecting = true
	publish({ connected = false })
	noctalia.runAsync({ "bluetoothctl", "connect", mac }, function()
		connecting = false
		republishMono()
		-- one failed read is enough to say it didn't work
		pollFailures = POLL_FAILURE_THRESHOLD - 1
		pollStatus()
	end, CONNECT_TIMEOUT_MS)
end

-- The Connect button on "not connected".
local function connectPicked()
	local mac = deviceMac()
	if mac == "" or connecting then
		return
	end
	linkConnected(mac, function(isConnected)
		if isConnected == true then
			pollStatus()
		else
			connectDevice(mac)
		end
	end)
end

-- With `connectNow` (a pick in the panel), a device BlueZ reports as
-- disconnected is also connected, as people expect from clicking it.
local function selectDevice(mac, connectNow)
	if type(mac) ~= "string" or mac == "" then
		return
	end
	overrideMac = mac
	saveOverrideMac(mac)
	if not connectNow then
		pollStatus()
		return
	end
	linkConnected(mac, function(isConnected)
		if isConnected ~= false or deviceMac() ~= mac then
			pollStatus()
			return
		end
		connectDevice(mac)
	end)
end

-- Lists already-paired Bluetooth devices (no pairing/connecting happens here)
-- so the panel can offer a pick list instead of the user copying a MAC
-- address out of system Bluetooth settings. When `auto` is true and nothing
-- is configured yet, a single unambiguous "Nothing Ear"-like match is
-- selected automatically; with two+ matches (e.g. an Ear 2 and an Ear 3 both
-- paired) it's left for the user to pick, since there's no safe way to guess
-- which one they mean.
local function scanDevices(auto)
	noctalia.runAsync({ "python3", ctlPath(), "scan" }, function(result)
		if result == nil or result.exitCode ~= 0 or result.stdout == nil or result.stdout == "" then
			noctalia.state.set(DEVICES_KEY, { ok = false, devices = {} })
			return
		end
		local ok, parsed = pcall(function()
			return noctalia.json.decode(result.stdout)
		end)
		local devices = (ok and type(parsed) == "table" and parsed.devices) or {}
		noctalia.state.set(DEVICES_KEY, { ok = ok and parsed.ok == true, devices = devices })

		if auto and deviceMac() == "" then
			local onlyMatch = nil
			local matchCount = 0
			for _, d in ipairs(devices) do
				if d.likely then
					matchCount += 1
					onlyMatch = d
				end
			end
			if matchCount == 1 then
				selectDevice(onlyMatch.mac)
			end
		end
	end, SCAN_TIMEOUT_MS)
end

local function forgetDevice()
	overrideMac = nil
	saveOverrideMac(nil)
	pollStatus()
	scanDevices(false)
end

-- Builds a bug-report-ready text (environment, what BlueZ knows, the last
-- poll's error and a fresh step-by-step attempt) and puts it on the
-- clipboard. Works without a configured device: the helper guesses one.
local function copyDetails()
	local argv = { "python3", ctlPath(), "diag" }
	local mac = deviceMac()
	if mac ~= "" then
		table.insert(argv, "--mac")
		table.insert(argv, mac)
	end
	if lastError ~= nil then
		table.insert(argv, "--last-error")
		table.insert(argv, noctalia.json.encode(lastError))
	end
	noctalia.notify(noctalia.tr("panel.title"), noctalia.tr("notify.details_collecting"))
	noctalia.runAsync(argv, function(result)
		local ok, parsed = false, nil
		if result ~= nil and result.stdout ~= nil and result.stdout ~= "" then
			ok, parsed = pcall(function()
				return noctalia.json.decode(result.stdout)
			end)
		end
		local text
		if ok and type(parsed) == "table" and type(parsed.text) == "string" then
			text = parsed.text
		else
			-- The helper itself couldn't run; report that much.
			local failure = helperFailure(result)
			text = "Nothing Ear diagnostics\n```text\nhelper failed: "
				.. tostring(failure.message)
				.. " (exit "
				.. tostring(failure.exit_code)
				.. ")\n```\n"
		end
		noctalia.copyToClipboard(text, "text/plain")
		noctalia.notify(noctalia.tr("notify.details_copied_title"), noctalia.tr("notify.details_copied_body"))
	end, DIAG_TIMEOUT_MS)
end

local function executeCommand(cmdObj)
	if type(cmdObj) ~= "table" or not cmdObj.action then
		return
	end
	if cmdObj.nonce ~= nil then
		if cmdObj.nonce == handledNonce then
			return
		end
		handledNonce = cmdObj.nonce
	end

	if cmdObj.action == "set-anc" then
		setAnc(cmdObj.value, cmdObj.strength)
	elseif cmdObj.action == "set-eq" then
		setEq(cmdObj.value)
	elseif cmdObj.action == "set-bass" then
		local n = tonumber(cmdObj.value)
		if n ~= nil and n >= 0 and n <= 5 then
			setBass(n)
		end
	elseif cmdObj.action == "set-bass-enabled" then
		setBassEnabled(shared.toBool(cmdObj.value))
	elseif cmdObj.action == "set-latency" then
		setLatency(shared.toBool(cmdObj.value))
	elseif cmdObj.action == "set-mono" then
		monoAutoSuppressed = true
		setMono(shared.toBool(cmdObj.value), false)
	elseif cmdObj.action == "set-personal-anc" then
		setPersonalAnc(shared.toBool(cmdObj.value))
	elseif cmdObj.action == "set-sound-profile" then
		setSoundProfile(shared.toBool(cmdObj.value))
	elseif cmdObj.action == "set-spatial" then
		setSpatial(cmdObj.value)
	elseif cmdObj.action == "set-codec" then
		setCodec(cmdObj.value)
	elseif cmdObj.action == "set-custom-eq" then
		setCustomEq(cmdObj.value)
	elseif cmdObj.action == "cycle-anc" then
		cycleAnc()
	elseif cmdObj.action == "refresh" then
		pollStatus()
	elseif cmdObj.action == "scan-devices" then
		scanDevices(false)
	elseif cmdObj.action == "select-device" then
		selectDevice(cmdObj.value, true)
	elseif cmdObj.action == "connect-device" then
		connectPicked()
	elseif cmdObj.action == "forget-device" then
		forgetDevice()
	elseif cmdObj.action == "copy-details" then
		copyDetails()
	elseif cmdObj.action == "panel_open" then
		panelOpen = true
		if deviceMac() == "" then
			scanDevices(true)
		else
			pollStatus()
		end
	elseif cmdObj.action == "panel_close" then
		panelOpen = false
	end
end

-- External automation entry point: `noctalia msg plugin <id>:service all <event> [payload]`.
-- This is what lets someone outside this plugin (a window-rule script, a
-- Hyprland/niri event hook, another shortcut) drive the earbuds without going
-- through the panel — e.g. "Discord opens -> set ANC to noise cancellation".
-- `set-anc` payload is `<mode>` or `<mode>:<strength>` (mode one of
-- anc/transparency/off, strength one of high/mid/low/adaptive, only
-- meaningful for anc). `set-eq` payload is a preset index from the model's
-- preset list (shared.EQ_PRESETS on an Ear (2)). `set-bass` payload is a
-- bass boost level 1-5, or 0 for off. `set-latency`,
-- `set-mono`, `set-personal-anc` and `set-sound-profile` payloads are
-- "0"/"1"/"true"/"false". `set-spatial` payload is a mode name from the
-- model's list (concert/cinema/off on a CMF Headphone Pro). `set-codec`
-- payload is aac or ldac; it restarts the headphones without asking.
-- `set-custom-eq` payload is "bass,mid,treble" in dB, each -6 to 6; it
-- edits the custom curve without selecting the custom preset.
function onIpc(event, payload)
	if event == "cycle-anc" then
		cycleAnc()
	elseif event == "refresh" then
		pollStatus()
	elseif event == "set-anc" then
		local text = type(payload) == "string" and payload or ""
		local mode, strength = text:match("^([^:]+):?(.*)$")
		if mode == "anc" or mode == "transparency" or mode == "off" then
			setAnc(mode, strength ~= "" and strength or nil)
		end
	elseif event == "set-eq" then
		local n = tonumber(payload)
		if n ~= nil and shared.isEqPreset(n, modelPresets()) then
			setEq(n)
		end
	elseif event == "set-bass" then
		local n = tonumber(payload)
		if n ~= nil and n >= 0 and n <= 5 then
			setBass(n)
		end
	elseif event == "set-latency" then
		local text = type(payload) == "string" and payload:lower() or ""
		setLatency(text == "1" or text == "true" or text == "on")
	elseif event == "set-mono" then
		local text = type(payload) == "string" and payload:lower() or ""
		monoAutoSuppressed = true
		setMono(text == "1" or text == "true" or text == "on", false)
	elseif event == "set-personal-anc" then
		local text = type(payload) == "string" and payload:lower() or ""
		setPersonalAnc(text == "1" or text == "true" or text == "on")
	elseif event == "set-sound-profile" then
		local text = type(payload) == "string" and payload:lower() or ""
		setSoundProfile(text == "1" or text == "true" or text == "on")
	elseif event == "set-spatial" then
		setSpatial(payload)
	elseif event == "set-codec" then
		setCodec(type(payload) == "string" and payload:lower() or nil)
	elseif event == "set-custom-eq" then
		setCustomEq(payload)
	elseif event == "scan-devices" then
		scanDevices(false)
	elseif event == "select-device" then
		selectDevice(payload)
	elseif event == "connect" then
		connectPicked()
	elseif event == "forget-device" then
		forgetDevice()
	elseif event == "copy-details" then
		copyDetails()
	end
end

noctalia.state.watch(COMMAND_KEY, executeCommand)

-- The desktop widget script (desktop-widget.luau) sets this true on load and
-- false in its onExit, so polling picks up/drops it the moment the widget is
-- added to or removed from the desktop — no separate "enable polling" setting.
noctalia.state.watch(DESKTOP_ACTIVE_KEY, function(value)
	desktopActive = value == true
	if desktopActive then
		pollStatus()
	end
end)

-- Reconcile mono on every (re)load: if the plugin crashed or was reloaded
-- while mono was active, this is the only place that can notice and revert
-- it — otherwise the user's audio is stuck mono with no service left
-- watching for the buds going back in. Auto-detect will re-trigger it
-- within a couple of polls if the single-bud condition still holds.
setMono(false, false)

-- Seed from disk cache immediately (cheap, no Bluetooth I/O) so a widget
-- rendered before the first poll isn't blank; only actually connect if the
-- bar or desktop widget is configured to show live stats.
refreshFromCache()
if deviceMac() == "" then
	-- Nothing configured yet (fresh install, or device_mac cleared): try to
	-- find it automatically instead of sitting on "not configured" until
	-- someone opens the panel.
	scanDevices(true)
elseif showInBar() or desktopActive or monoAutoSetting() then
	pollStatus()
end

noctalia.setUpdateInterval(POLL_INTERVAL_MS)

-- BlueZ announces connects and disconnects on D-Bus, so the bar icon (and
-- "hide when disconnected") follows them at once instead of a poll or two
-- later. The loop restarts the monitor if bluetoothd restarts; the polls in
-- update() stay as the fallback, and the only way without gdbus.
local LINK_WATCH = "while :; do gdbus monitor --system --dest org.bluez 2>/dev/null"
	.. " | grep --line-buffered \"org.bluez.Device1', {[^}]*'Connected'\"; sleep 5; done"

-- After a connect, headphones can take a few seconds before their control
-- channel answers: keep polling a little while until a read gets through.
local RECONNECT_POLL_MS = 1500
local RECONNECT_POLLS = 10
local reconnectGen = 0

local function pollUntilConnected(gen, left)
	if gen ~= reconnectGen or left <= 0 then
		return
	end
	local current = noctalia.state.get(STATUS_KEY) or {}
	if current.connected == true and not restarting() then
		return
	end
	if writesInFlight == 0 and not connecting then
		pollStatus()
	end
	noctalia.runAsync({ "sleep", tostring(RECONNECT_POLL_MS / 1000) }, function()
		pollUntilConnected(gen, left - 1)
	end, RECONNECT_POLL_MS + 5000)
end

-- One line per Device1 "Connected" change, e.g.
-- /org/bluez/hci0/dev_2C_BE_EE_00_11_22: org.freedesktop.DBus.Properties.PropertiesChanged ('org.bluez.Device1', {'Connected': <false>}, @as [])
local function onLinkEvent(line)
	local dev, value = line:match("^/org/bluez/hci%d+/dev_([%x_]+): .-'Connected': <(%a+)>")
	if dev == nil or (dev:gsub("_", ":")):upper() ~= deviceMac():upper() then
		return
	end
	reconnectGen += 1
	if value == "true" then
		if restarting() then
			-- back from a codec switch's restart: the next good read ends it
			restartSawFailure = true
		end
		pollUntilConnected(reconnectGen, RECONNECT_POLLS)
	elseif value == "false" and not restarting() and writing.codec == nil and not connecting then
		-- a codec switch's restart (the headphones can drop before the write
		-- returns) and our own connect attempt have their own handling
		pollFailures = POLL_FAILURE_THRESHOLD
		lastError = nil
		markDisconnected("not_connected")
	end
end

if noctalia.commandExists("gdbus") then
	noctalia.runStream(LINK_WATCH, onLinkEvent)
end

local function hideWhenDisconnected()
	return noctalia.getConfig("hide_when_disconnected") == true
end

-- With nothing showing live status, the bar icon still has to follow
-- connects and disconnects: ask BlueZ (no Bluetooth traffic), and only read
-- the device when that changed.
local linkBusy = false
local function checkLink()
	local mac = deviceMac()
	if linkBusy or mac == "" then
		return
	end
	linkBusy = true
	linkConnected(mac, function(isConnected)
		linkBusy = false
		local current = noctalia.state.get(STATUS_KEY) or {}
		if isConnected ~= nil and isConnected ~= (current.connected == true) then
			pollStatus()
		end
	end)
end

function update()
	tickCount += 1
	-- The bar icon is hidden while nothing is picked, so nobody would open
	-- the panel to scan; look for newly paired earbuds now and then.
	if deviceMac() == "" and hideWhenDisconnected() and tickCount % SCAN_EVERY_N_TICKS == 0 then
		scanDevices(true)
		return
	end
	if writesInFlight > 0 or connecting then
		return
	end
	if panelOpen or showInBar() or desktopActive then
		pollStatus()
	elseif monoAutoSetting() and tickCount % MONO_ONLY_POLL_EVERY_N_TICKS == 0 then
		pollStatus()
	else
		checkLink()
	end
end

function onConfigChanged()
	-- If the user turns the auto setting off while mono is active because of
	-- it, revert immediately rather than leaving it stuck on until the buds
	-- change state again. A mono toggle the user set manually is left alone.
	if not monoAutoSetting() and monoActive and monoActivatedByAuto then
		setMono(false, true)
	end
	-- the panel's mono caption depends on the auto setting
	republishMono()
	if deviceMac() == "" then
		scanDevices(true)
	elseif showInBar() or desktopActive or monoAutoSetting() then
		pollStatus()
	end
end
