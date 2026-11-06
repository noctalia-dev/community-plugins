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
local CLI_TIMEOUT_MS = 8000
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
		data.mono_auto = monoAutoSetting()
		data.mono_by_auto = monoActive and monoActivatedByAuto
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

local function runCtl(args, callback)
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
	end, CLI_TIMEOUT_MS)
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

local function evaluateMonoAuto(battery)
	if not monoAutoSetting() then
		monoTriggerPolls = 0
		monoClearPolls = 0
		return
	end
	if singleBudOut(battery) then
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

local function pollStatus()
	runCtl({ "status" }, function(parsed)
		if parsed ~= nil and parsed.connected == true then
			pollFailures = 0
			lastError = nil
			if not monoActive then
				evaluateMonoAuto(parsed.battery)
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
				evaluateMonoAuto(parsed.battery)
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
		if parsed ~= nil then
			lastError = parsed
		end
		-- Only report "not connected" after two failures in a row, so one
		-- dropped poll doesn't flash the panel to "not connected".
		pollFailures += 1
		if pollFailures >= POLL_FAILURE_THRESHOLD then
			monoTriggerPolls = 0
			monoClearPolls = 0
			if monoActive and monoActivatedByAuto then
				setMono(false, true)
			end
			publish({ connected = false, error = lastError and lastError.error or nil })
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

local function applyResultThenRefresh(parsed)
	if parsed ~= nil and parsed.ok then
		-- merge whatever the write handler already learned (fast optimistic update)
		local current = noctalia.state.get(STATUS_KEY) or {}
		for k, v in pairs(parsed) do
			if k ~= "ok" then
				current[k] = v
			end
		end
		publish(current)
	end
	pollStatus()
end

local function setAnc(mode, strength)
	local args = { "set-anc", mode }
	if strength ~= nil and strength ~= "" then
		table.insert(args, "--strength")
		table.insert(args, strength)
	end
	runCtl(args, applyResultThenRefresh)
end

local function setEq(preset)
	runCtl({ "set-eq", tostring(preset) }, applyResultThenRefresh)
end

-- level 0 is off; the buds keep the last level for when it's turned back on.
local function setBass(level)
	runCtl({ "set-bass", tostring(level) }, applyResultThenRefresh)
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
	runCtl({ "set-latency", enabled and "1" or "0" }, applyResultThenRefresh)
end

local function setPersonalAnc(enabled)
	runCtl({ "set-personal-anc", enabled and "1" or "0" }, applyResultThenRefresh)
end

local function setSoundProfile(enabled)
	runCtl({ "set-sound-profile", enabled and "1" or "0" }, applyResultThenRefresh)
end

local function cycleAnc()
	runCtl({ "cycle-anc" }, applyResultThenRefresh)
end

local function selectDevice(mac)
	if type(mac) ~= "string" or mac == "" then
		return
	end
	overrideMac = mac
	saveOverrideMac(mac)
	pollStatus()
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
	elseif cmdObj.action == "cycle-anc" then
		cycleAnc()
	elseif cmdObj.action == "refresh" then
		pollStatus()
	elseif cmdObj.action == "scan-devices" then
		scanDevices(false)
	elseif cmdObj.action == "select-device" then
		selectDevice(cmdObj.value)
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
-- "0"/"1"/"true"/"false".
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
	elseif event == "scan-devices" then
		scanDevices(false)
	elseif event == "select-device" then
		selectDevice(payload)
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

function update()
	tickCount += 1
	if panelOpen or showInBar() or desktopActive then
		pollStatus()
	elseif monoAutoSetting() and tickCount % MONO_ONLY_POLL_EVERY_N_TICKS == 0 then
		pollStatus()
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
