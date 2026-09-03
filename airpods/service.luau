--!nonstrict
-- AirPods backend. The service is the single owner of the librepods state file
-- and of every librepods-ctl subprocess. The widget and panel read the published
-- snapshot and send commands through the shared state channel, so the control
-- verbs are never spawned from the UI VMs.

local SNAPSHOT_KEY = "airpods_snapshot"
local COMMAND_KEY = "airpods_command"

local NOISE_OFF = 0
local NOISE_ANC = 1
local NOISE_TRANSPARENCY = 2
local NOISE_ADAPTIVE = 3

local LID_OPEN = 0
local LID_CLOSED = 1
local LID_UNKNOWN = 2

local EAR_PAUSE_ONE_OUT = 0
local EAR_PAUSE_BOTH_OUT = 1
local EAR_DISABLED = 2

local SUPPORTED_SCHEMA = 1
local LEVEL_UNKNOWN = -1
local NOISE_UNKNOWN = -1
local EAR_BEHAVIOR_COUNT = 3

local MAX_ERROR_CHARS = 140
local ELIDED_ERROR_CHARS = 137

local SETTLE_HOLD_MS = 4000
local ACTION_STATUS_MS = 2200
local POLL_INTERVAL_MS = 2000

local function intOr(value, fallback)
	local n = tonumber(value)
	if n == nil then
		return fallback
	end
	return n
end

local function boolOr(value, fallback)
	if value == nil then
		return fallback
	end
	return value == true
end

local function defaultPod()
	return { level = LEVEL_UNKNOWN, charging = false, inEar = false }
end

local function podFrom(raw)
	local pod = defaultPod()
	if type(raw) ~= "table" then
		return pod
	end
	-- available:false means the daemon stopped hearing from this pod, so its
	-- charging and in_ear fields are stale too.
	if raw.available ~= true then
		return pod
	end
	pod.level = intOr(raw.level, LEVEL_UNKNOWN)
	pod.charging = raw.charging == true
	pod.inEar = raw.in_ear == true
	return pod
end

-- Port of Model.parseStatus from the Omarchy widget. The daemon publishes one
-- line of JSON at $XDG_STATE_HOME/librepods/status.json and removes the file
-- when it stops.
local function parseStatus(raw)
	local status = {
		ok = false,
		lastError = "",
		schemaTooNew = false,
		connected = false,
		deviceName = "",
		modelName = "",
		isProSeries = false,
		isHeadset = false,
		supportsNoiseOff = true,
		supportsNoiseControl = true,
		supportsAdaptive = false,
		supportsConversationalAwareness = false,
		supportsOneBudANC = false,
		noiseMode = NOISE_UNKNOWN,
		adaptiveNoiseLevel = 0,
		oneBudANC = false,
		conversationalAwareness = false,
		earDetectionBehavior = EAR_PAUSE_ONE_OUT,
		lidState = LID_UNKNOWN,
		left = defaultPod(),
		right = defaultPod(),
		caseBattery = { level = LEVEL_UNKNOWN, charging = false },
		headset = { level = LEVEL_UNKNOWN, charging = false },
	}

	local text = noctalia.string.trim(tostring(raw or ""))
	if text == "" then
		status.lastError = "The librepods status file is empty"
		return status
	end

	local parsed = noctalia.json.decode(text)
	if type(parsed) ~= "table" then
		status.lastError = "Could not read the librepods status file"
		return status
	end
	if parsed.schema_version == nil then
		status.lastError = "The librepods status file carried no schema_version"
		return status
	end

	local schemaVersion = intOr(parsed.schema_version, 0)
	if schemaVersion > SUPPORTED_SCHEMA then
		status.schemaTooNew = true
		status.lastError = "librepods speaks status schema " .. tostring(schemaVersion)
			.. ", this plugin reads " .. tostring(SUPPORTED_SCHEMA)
		return status
	end

	status.ok = true
	status.connected = parsed.connected == true
	status.deviceName = tostring(parsed.device_name or "")
	status.modelName = tostring(parsed.model_name or "")
	status.isProSeries = parsed.is_pro_series == true
	status.isHeadset = parsed.is_headset == true
	status.supportsNoiseOff = parsed.supports_noise_off ~= false
	status.supportsNoiseControl = boolOr(parsed.supports_noise_control, true)
	status.supportsAdaptive = boolOr(parsed.supports_adaptive, status.isProSeries)
	status.supportsConversationalAwareness = boolOr(parsed.supports_conversational_awareness, status.isProSeries)
	status.supportsOneBudANC = boolOr(parsed.supports_one_bud_anc, status.isProSeries)
	status.noiseMode = intOr(parsed.noise_mode, NOISE_UNKNOWN)
	status.adaptiveNoiseLevel = intOr(parsed.adaptive_noise_level, 0)
	status.oneBudANC = parsed.one_bud_anc_mode == true
	status.conversationalAwareness = parsed.conversational_awareness == true
	status.earDetectionBehavior = intOr(parsed.ear_detection_behavior, EAR_PAUSE_ONE_OUT)
	status.lidState = intOr(parsed.lid_state, LID_UNKNOWN)
	status.left = podFrom(parsed.left)
	status.right = podFrom(parsed.right)
	local caseRaw = podFrom(parsed["case"])
	status.caseBattery = { level = caseRaw.level, charging = caseRaw.charging }
	local headsetRaw = podFrom(parsed.headset)
	status.headset = { level = headsetRaw.level, charging = headsetRaw.charging }
	return status
end

local function elideError(text)
	local value = noctalia.string.trim(tostring(text or "")):gsub("%s+", " ")
	if #value > MAX_ERROR_CHARS then
		return value:sub(1, ELIDED_ERROR_CHARS) .. "…"
	end
	return value
end

local function defaultSnapshot()
	return {
		daemonReachable = false,
		connected = false,
		deviceName = "",
		modelName = "",
		isProSeries = false,
		isHeadset = false,
		supportsNoiseOff = true,
		supportsNoiseControl = true,
		supportsAdaptive = false,
		supportsConversationalAwareness = false,
		supportsOneBudANC = false,
		noiseMode = NOISE_UNKNOWN,
		noiseModeName = "",
		adaptiveNoiseLevel = 0,
		oneBudANC = false,
		conversationalAwareness = false,
		earDetectionBehavior = EAR_PAUSE_ONE_OUT,
		earDetectionName = "",
		lidState = LID_UNKNOWN,
		lidText = "",
		left = defaultPod(),
		right = defaultPod(),
		caseBattery = { level = LEVEL_UNKNOWN, charging = false },
		headset = { level = LEVEL_UNKNOWN, charging = false },
		leftText = "--",
		rightText = "--",
		caseText = "--",
		headsetText = "--",
		leftMeta = "",
		rightMeta = "",
		caseMeta = "",
		headsetMeta = "",
		primaryText = "",
		primaryState = "normal",
		schemaUnsupported = false,
		lastError = "",
		actionStatus = "",
		busy = false,
		hasAirPods = false,
		hasBattery = false,
		availableModes = {},
		earOptions = {},
	}
end

local snapshot = defaultSnapshot()

local pendingField = ""
local pendingValue = nil
local queued = nil
local commandRunning = false
local actionStatus = ""
local actionStatusDeadline = 0
local settleDeadline = 0
-- Last raw line read from the status file, so an unchanged file does not
-- re-publish the snapshot and re-render the UI every poll.
local lastRaw = nil

local function nowMs()
	return noctalia.nowMs()
end

local home = noctalia.getenv("HOME") or ""
local stateHome = noctalia.getenv("XDG_STATE_HOME")
if stateHome == nil or stateHome == "" then
	stateHome = home .. "/.local/state"
end
local statusPath = stateHome .. "/librepods/status.json"

local function configuredCtlPath()
	local p = noctalia.getConfig("ctl_path")
	if p == nil or p == "" then
		return "librepods-ctl"
	end
	return p
end
local ctlPath = configuredCtlPath()

local function noiseModeName(mode)
	if mode == NOISE_OFF then return noctalia.tr("panel.mode.off") end
	if mode == NOISE_ANC then return noctalia.tr("panel.mode.anc") end
	if mode == NOISE_TRANSPARENCY then return noctalia.tr("panel.mode.transparency") end
	if mode == NOISE_ADAPTIVE then return noctalia.tr("panel.mode.adaptive") end
	return noctalia.tr("panel.mode.unknown")
end

local function earDetectionName(behavior, isHeadset)
	if behavior == EAR_DISABLED then
		return noctalia.tr("panel.ear.off")
	end
	if isHeadset then
		return noctalia.tr("panel.ear.headset_on")
	end
	if behavior == EAR_PAUSE_ONE_OUT then
		return noctalia.tr("panel.ear.one")
	end
	if behavior == EAR_PAUSE_BOTH_OUT then
		return noctalia.tr("panel.ear.both")
	end
	return ""
end

local function lidText(lid)
	if lid == LID_OPEN then return noctalia.tr("panel.lid_open") end
	if lid == LID_CLOSED then return noctalia.tr("panel.lid_closed") end
	return ""
end

local function levelText(level)
	if level == nil or level == LEVEL_UNKNOWN then return "--" end
	return tostring(math.floor((tonumber(level) or 0) + 0.5)) .. "%"
end

local function podMeta(pod)
	if pod.charging then return noctalia.tr("panel.charging") end
	if pod.inEar then return noctalia.tr("panel.in_ear") end
	return ""
end

-- The one list both the cycle and the panel rows are built from, in the order
-- the panel draws them.
local function availableModes()
	if not snapshot.supportsNoiseControl then
		return {}
	end
	local modes = {}
	if snapshot.supportsNoiseOff then
		table.insert(modes, NOISE_OFF)
	end
	table.insert(modes, NOISE_TRANSPARENCY)
	if snapshot.supportsAdaptive then
		table.insert(modes, NOISE_ADAPTIVE)
	end
	table.insert(modes, NOISE_ANC)
	return modes
end

local function noiseModeVerb(mode)
	local verbs = {
		[NOISE_OFF] = "noise:off",
		[NOISE_ANC] = "noise:anc",
		[NOISE_TRANSPARENCY] = "noise:transparency",
		[NOISE_ADAPTIVE] = "noise:adaptive",
	}
	return verbs[mode] or ""
end

local function earDetectionVerb(behavior)
	local verbs = {
		[EAR_PAUSE_ONE_OUT] = "ear:one",
		[EAR_PAUSE_BOTH_OUT] = "ear:both",
		[EAR_DISABLED] = "ear:off",
	}
	return verbs[behavior] or ""
end

local function applyOptimistic(field, value)
	if field == "noiseMode" then
		snapshot.noiseMode = value
	elseif field == "adaptiveNoiseLevel" then
		snapshot.adaptiveNoiseLevel = value
	elseif field == "oneBudANC" then
		snapshot.oneBudANC = value
	elseif field == "conversationalAwareness" then
		snapshot.conversationalAwareness = value
	elseif field == "earDetectionBehavior" then
		snapshot.earDetectionBehavior = value
	end
end

local function clearPending()
	pendingField = ""
	pendingValue = nil
	settleDeadline = 0
end

-- Compute display fields and the derived flags, then publish the snapshot. The
-- widget and panel treat this table as read-only and never re-derive it.
local function publish()
	snapshot.busy = commandRunning
	snapshot.actionStatus = actionStatus

	snapshot.hasAirPods = snapshot.daemonReachable and snapshot.connected
	if snapshot.daemonReachable then
		if snapshot.isHeadset then
			snapshot.hasBattery = snapshot.headset.level ~= LEVEL_UNKNOWN
		else
			snapshot.hasBattery = snapshot.left.level ~= LEVEL_UNKNOWN
				or snapshot.right.level ~= LEVEL_UNKNOWN
				or snapshot.caseBattery.level ~= LEVEL_UNKNOWN
		end
	else
		snapshot.hasBattery = false
	end

	snapshot.noiseModeName = noiseModeName(snapshot.noiseMode)
	snapshot.earDetectionName = earDetectionName(snapshot.earDetectionBehavior, snapshot.isHeadset)
	snapshot.lidText = lidText(snapshot.lidState)
	snapshot.leftText = levelText(snapshot.left.level)
	snapshot.rightText = levelText(snapshot.right.level)
	snapshot.caseText = levelText(snapshot.caseBattery.level)
	snapshot.headsetText = levelText(snapshot.headset.level)
	snapshot.leftMeta = podMeta(snapshot.left)
	snapshot.rightMeta = podMeta(snapshot.right)
	snapshot.caseMeta = snapshot.lidText
	snapshot.headsetMeta = podMeta(snapshot.headset)

	local modes = {}
	for _, mode in ipairs(availableModes()) do
		table.insert(modes, { value = mode, label = noiseModeName(mode) })
	end
	snapshot.availableModes = modes
	if snapshot.isHeadset then
		snapshot.earOptions = {
			{ value = EAR_PAUSE_ONE_OUT, label = earDetectionName(EAR_PAUSE_ONE_OUT, true) },
			{ value = EAR_DISABLED, label = earDetectionName(EAR_DISABLED, true) },
		}
	else
		snapshot.earOptions = {
			{ value = EAR_PAUSE_ONE_OUT, label = earDetectionName(EAR_PAUSE_ONE_OUT, false) },
			{ value = EAR_PAUSE_BOTH_OUT, label = earDetectionName(EAR_PAUSE_BOTH_OUT, false) },
			{ value = EAR_DISABLED, label = earDetectionName(EAR_DISABLED, false) },
		}
	end

	local primaryLevel = LEVEL_UNKNOWN
	local primaryCharging = false
	if snapshot.isHeadset then
		snapshot.primaryText = snapshot.headsetText
		primaryLevel = snapshot.headset.level
		primaryCharging = snapshot.headset.charging
	else
		local l = snapshot.left.level
		local r = snapshot.right.level
		local lc = snapshot.left.charging
		local rc = snapshot.right.charging
		if l == LEVEL_UNKNOWN and r == LEVEL_UNKNOWN then
			-- Pods unknown; fall back to the case so the bar still shows something.
			snapshot.primaryText = snapshot.caseBattery.level ~= LEVEL_UNKNOWN and snapshot.caseText or "--"
			primaryLevel = snapshot.caseBattery.level
			primaryCharging = snapshot.caseBattery.charging
		elseif l == LEVEL_UNKNOWN then
			snapshot.primaryText = levelText(r)
			primaryLevel = r
			primaryCharging = rc
		elseif r == LEVEL_UNKNOWN then
			snapshot.primaryText = levelText(l)
			primaryLevel = l
			primaryCharging = lc
		elseif l <= r then
			snapshot.primaryText = levelText(l)
			primaryLevel = l
			primaryCharging = lc
		else
			snapshot.primaryText = levelText(r)
			primaryLevel = r
			primaryCharging = rc
		end
	end

	if primaryCharging then
		snapshot.primaryState = "charging"
	elseif primaryLevel ~= LEVEL_UNKNOWN and primaryLevel <= 20 then
		snapshot.primaryState = "low"
	else
		snapshot.primaryState = "normal"
	end

	noctalia.state.set(SNAPSHOT_KEY, snapshot)
end

-- Held over incoming reads until the daemon agrees, so a write already in
-- flight when the click landed cannot snap the control back.
local function settle(field, reported)
	if pendingField ~= field then
		return reported
	end
	if reported == pendingValue then
		clearPending()
		return reported
	end
	return pendingValue
end

local function applyStatus(status)
	snapshot.connected = status.connected
	snapshot.deviceName = status.deviceName
	snapshot.modelName = status.modelName
	snapshot.isProSeries = status.isProSeries
	snapshot.isHeadset = status.isHeadset
	snapshot.supportsNoiseOff = status.supportsNoiseOff
	snapshot.supportsNoiseControl = status.supportsNoiseControl
	snapshot.supportsAdaptive = status.supportsAdaptive
	snapshot.supportsConversationalAwareness = status.supportsConversationalAwareness
	snapshot.supportsOneBudANC = status.supportsOneBudANC
	snapshot.left = status.left
	snapshot.right = status.right
	snapshot.caseBattery = status.caseBattery
	snapshot.headset = status.headset
	snapshot.lidState = status.lidState

	snapshot.noiseMode = settle("noiseMode", status.noiseMode)
	snapshot.adaptiveNoiseLevel = settle("adaptiveNoiseLevel", status.adaptiveNoiseLevel)
	snapshot.oneBudANC = settle("oneBudANC", status.oneBudANC)
	snapshot.conversationalAwareness = settle("conversationalAwareness", status.conversationalAwareness)
	snapshot.earDetectionBehavior = settle("earDetectionBehavior", status.earDetectionBehavior)

	publish()
end

local function applyLine(raw)
	local status = parseStatus(raw)
	if not status.ok then
		-- A line we cannot read still proves the daemon is running and writing.
		snapshot.daemonReachable = true
		snapshot.connected = false
		snapshot.schemaUnsupported = status.schemaTooNew
		snapshot.lastError = status.lastError
		publish()
		return
	end
	snapshot.daemonReachable = true
	snapshot.schemaUnsupported = false
	snapshot.lastError = ""
	applyStatus(status)
end

-- The daemon removes the file when it stops, so an absent file is a stopped daemon.
local function stateGone()
	snapshot.daemonReachable = false
	snapshot.connected = false
	snapshot.schemaUnsupported = false
	snapshot.lastError = ""
	clearPending()
	publish()
end

local function readStatusFile(force)
	local raw = noctalia.readFile(statusPath)
	if raw == nil then
		if lastRaw ~= nil then
			lastRaw = nil
			stateGone()
		end
		return
	end
	if not force and raw == lastRaw then
		return
	end
	lastRaw = raw
	applyLine(raw)
end

local function refresh()
	readStatusFile(true)
end

-- Single slot: a verb sent while another is in flight replaces the queued one
-- rather than being dropped, which is what a slider drag produces.
local function sendVerb(verb, field, optimistic)
	if verb == "" then
		return
	end
	if commandRunning then
		queued = { verb = verb, field = field, optimistic = optimistic }
		pendingField = field
		pendingValue = optimistic
		applyOptimistic(field, optimistic)
		settleDeadline = nowMs() + SETTLE_HOLD_MS
		publish()
		return
	end
	pendingField = field
	pendingValue = optimistic
	applyOptimistic(field, optimistic)
	settleDeadline = nowMs() + SETTLE_HOLD_MS
	commandRunning = true
	publish()

	noctalia.runAsync({ ctlPath, verb }, function(result)
		commandRunning = false
		if result.exitCode ~= 0 then
			-- Clearing the hold also stops the deadline that would have re-read,
			-- so refresh here to snap back to the daemon's own value.
			clearPending()
			refresh()
			local msg = elideError(result.stderr)
			if msg == "" then
				msg = noctalia.tr("errors.ctl_rejected")
			end
			actionStatus = msg
			actionStatusDeadline = nowMs() + ACTION_STATUS_MS
		end
		if queued ~= nil then
			local nextCmd = queued
			queued = nil
			sendVerb(nextCmd.verb, nextCmd.field, nextCmd.optimistic)
		else
			publish()
		end
	end, 10000)
end

local function setNoiseMode(mode)
	local modes = availableModes()
	for _, m in ipairs(modes) do
		if m == mode then
			sendVerb(noiseModeVerb(mode), "noiseMode", mode)
			return
		end
	end
end

local function cycleNoiseMode()
	if not snapshot.hasAirPods then
		return
	end
	local modes = availableModes()
	if #modes == 0 then
		return
	end
	local at = 0
	for i, m in ipairs(modes) do
		if m == snapshot.noiseMode then
			at = i
			break
		end
	end
	-- An unknown current mode has no next one, so start at the head instead of past it.
	setNoiseMode(at == 0 and modes[1] or modes[(at % #modes) + 1])
end

local function setAdaptiveNoiseLevel(level)
	local clamped = math.max(0, math.min(100, math.floor((tonumber(level) or 0) + 0.5)))
	sendVerb("adaptive:" .. tostring(clamped), "adaptiveNoiseLevel", clamped)
end

local function setConversationalAwareness(enabled)
	sendVerb(enabled and "ca:on" or "ca:off", "conversationalAwareness", enabled)
end

local function setOneBudANC(enabled)
	sendVerb(enabled and "onebud:on" or "onebud:off", "oneBudANC", enabled)
end

local function setEarDetectionBehavior(behavior)
	sendVerb(earDetectionVerb(behavior), "earDetectionBehavior", behavior)
end

local function cycleEarDetection()
	setEarDetectionBehavior((snapshot.earDetectionBehavior + 1) % EAR_BEHAVIOR_COUNT)
end

local function executeCommand(cmd)
	if type(cmd) ~= "table" or type(cmd.action) ~= "string" then
		return
	end
	local action = cmd.action
	if action == "refresh" then
		refresh()
	elseif action == "cycle-noise" then
		cycleNoiseMode()
	elseif action == "set-noise" then
		setNoiseMode(tonumber(cmd.value))
	elseif action == "set-adaptive" then
		setAdaptiveNoiseLevel(tonumber(cmd.value))
	elseif action == "set-ca" then
		setConversationalAwareness(cmd.value == true)
	elseif action == "set-onebud" then
		setOneBudANC(cmd.value == true)
	elseif action == "set-ear" then
		setEarDetectionBehavior(tonumber(cmd.value))
	elseif action == "cycle-ear" then
		cycleEarDetection()
	end
end

function onIpc(event, payload)
	if event == "cycle-noise" then
		cycleNoiseMode()
	elseif event == "refresh" then
		refresh()
	end
end

noctalia.state.watch(COMMAND_KEY, executeCommand)

noctalia.setUpdateInterval(POLL_INTERVAL_MS)

function update()
	local now = nowMs()
	-- Bounds the optimistic hold, and re-reads because a verb that changed nothing
	-- leaves the daemon's file untouched, so no state change fires to correct the display.
	local force = false
	if pendingField ~= "" and now > settleDeadline then
		clearPending()
		force = true
	end
	local clearedStatus = false
	if actionStatus ~= "" and now > actionStatusDeadline then
		actionStatus = ""
		clearedStatus = true
	end
	readStatusFile(force)
	if clearedStatus and not force then
		publish()
	end
end

readStatusFile(false)
