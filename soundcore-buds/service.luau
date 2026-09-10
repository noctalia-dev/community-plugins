--!nonstrict
-- Soundcore backend: single owner of every openscq30 subprocess. Tested
-- against SoundcoreD1202C (R60i NC), openscq30 2.11.0.

local SNAPSHOT_KEY = "sankity/soundcore-buds:snapshot"
local COMMAND_KEY = "sankity/soundcore-buds:command"

local NOISE_OFF = 0
local NOISE_ANC = 1
local NOISE_TRANSPARENCY = 2
local NOISE_ADAPTIVE = 3
local NOISE_UNKNOWN = -1
local LEVEL_UNKNOWN = -1

local MAX_ERROR_CHARS = 140
local ELIDED_ERROR_CHARS = 137
local SETTLE_HOLD_MS = 4000
local ACTION_STATUS_MS = 2200
local QUERY_TIMEOUT_MS = 25000
local SET_TIMEOUT_MS = 25000
local FIND_TIMEOUT_MS = 60000

local TOUCH_IDS = {
	"leftSinglePress",
	"rightSinglePress",
	"leftDoublePress",
	"rightDoublePress",
	"leftTriplePress",
	"rightTriplePress",
	"leftLongPress",
	"rightLongPress",
}

local TOUCH_LABEL_KEYS = {
	leftSinglePress = "panel.touch.left_single",
	rightSinglePress = "panel.touch.right_single",
	leftDoublePress = "panel.touch.left_double",
	rightDoublePress = "panel.touch.right_double",
	leftTriplePress = "panel.touch.left_triple",
	rightTriplePress = "panel.touch.right_triple",
	leftLongPress = "panel.touch.left_hold",
	rightLongPress = "panel.touch.right_hold",
}

local SELECT_IDS = {
	"transparencyMode",
	"multiSceneNoiseCanceling",
	"autoPowerOff",
	"limitHighVolumeRefreshRate",
}

local SELECT_LABEL_KEYS = {
	transparencyMode = "panel.sound.transparency_mode",
	multiSceneNoiseCanceling = "panel.sound.multiscene",
	autoPowerOff = "panel.device.auto_off",
	limitHighVolumeRefreshRate = "panel.device.limit_rate",
}

local TOGGLE_IDS = {
	"windNoiseSuppression",
	"dualConnections",
	"lowBatteryPrompt",
	"limitHighVolume",
	"realTimeAdaptiveNoiseCanceling",
}

local TOGGLE_LABEL_KEYS = {
	windNoiseSuppression = "panel.sound.wind",
	dualConnections = "panel.device.dual",
	lowBatteryPrompt = "panel.device.low_batt",
	limitHighVolume = "panel.device.limit",
	realTimeAdaptiveNoiseCanceling = "panel.device.rt_anc",
}

local INT_IDS = {
	"limitHighVolumeDbLimit",
}

local INT_LABEL_KEYS = {
	limitHighVolumeDbLimit = "panel.device.limit_db",
}


local INFO_IDS = {
	"firmwareVersionLeft",
	"firmwareVersionRight",
	"serialNumber",
	"adaptiveNoiseCanceling",
	"dualConnectionsDevices",
}

local function trim(s)
	return noctalia.string.trim(tostring(s or ""))
end

local function intOr(value, fallback)
	local n = tonumber(value)
	if n == nil then
		return fallback
	end
	return math.floor(n)
end

-- Clamp into [lo, hi]; shared by the ANC slider and the int setting.
local function clampInt(value, lo, hi)
	local n = intOr(value, lo)
	if n < lo then
		return lo
	elseif n > hi then
		return hi
	end
	return n
end

local function contains(list, value, key)
	for _, item in ipairs(list or {}) do
		if (key and item[key] or item) == value then
			return true
		end
	end
	return false
end

-- Battery may arrive as a number (i32) or a "10/10" fraction string.
local function fifths(value)
	if type(value) == "number" then
		local n = math.floor(value + 0.5)
		if n >= 0 and n <= 100 then
			return n
		end
		return LEVEL_UNKNOWN
	end
	local text = trim(value)
	if text == "" then
		return LEVEL_UNKNOWN
	end
	local slash = string.find(text, "/", 1, true)
	if slash then
		local num = tonumber(trim(string.sub(text, 1, slash - 1)))
		local den = tonumber(trim(string.sub(text, slash + 1)))
		if num ~= nil and den ~= nil and den > 0 then
			return math.floor((100 * num / den) + 0.5)
		end
		return LEVEL_UNKNOWN
	end
	local n = tonumber(text)
	if n ~= nil and n >= 0 and n <= 100 then
		return math.floor(n + 0.5)
	end
	return LEVEL_UNKNOWN
end

local function yes(value)
	local t = string.lower(trim(value))
	return t == "yes" or t == "true" or t == "1" or t == "charging"
end

local function normalizeName(value)
	local t = string.lower(tostring(value or ""))
	t = string.gsub(t, "soundcore", " ")
	t = string.gsub(t, "[^%w]+", " ")
	return trim(t)
end

local function modelAliases(displayName)
	local aliases = {}
	for part in string.gmatch(tostring(displayName or "") .. "/", "([^/]+)/") do
		local raw = trim(part)
		if raw ~= "" then
			table.insert(aliases, raw)
			local stripped = trim(string.gsub(raw, "^[Ss]oundcore%s+", ""))
			if stripped ~= "" and stripped ~= raw then
				table.insert(aliases, stripped)
			end
		end
	end
	return aliases
end

local function matchScore(deviceName, modelName)
	local device = normalizeName(deviceName)
	if device == "" then
		return 0
	end
	local best = 0
	for _, alias in ipairs(modelAliases(modelName)) do
		local a = normalizeName(alias)
		if a ~= "" then
			if device == a then
				return 1000 + #a
			end
			if string.find(device, a, 1, true) or string.find(a, device, 1, true) then
				if #a > best then
					best = #a
				end
			end
		end
	end
	return best
end

local function elideError(text)
	local value = string.gsub(trim(text), "%s+", " ")
	if #value > MAX_ERROR_CHARS then
		return string.sub(value, 1, ELIDED_ERROR_CHARS) .. "…"
	end
	return value
end

local function defaultPod()
	return { level = LEVEL_UNKNOWN, charging = false }
end

local function defaultSnapshot()
	return {
		backendOk = true,
		connected = false,
		deviceName = "",
		modelName = "",
		modelId = "",
		mac = "",
		isHeadset = false,
		supportsNoiseOff = false,
		supportsNoiseControl = false,
		supportsTransparency = false,
		supportsAnc = false,
		supportsAdaptive = false,
		supportsManualAnc = false,
		manualAnc = LEVEL_UNKNOWN,
		manualAncMin = 1,
		manualAncMax = 5,
		noiseMode = NOISE_UNKNOWN,
		noiseModeName = "",
		topMode = NOISE_UNKNOWN,
		noiseCancelMode = "",
		subModeName = "",
		cancelModes = {},
		left = defaultPod(),
		right = defaultPod(),
		caseBattery = defaultPod(),
		headset = defaultPod(),
		leftText = "--",
		rightText = "--",
		caseText = "--",
		headsetText = "--",
		headsetMeta = "",
		leftMeta = "",
		rightMeta = "",
		primaryText = "",
		primaryState = "normal",
		hasBattery = false,
		availableModes = {},
		touch = { available = false, reset = false, supportsTone = false, tone = false, controls = {} },
		findingSide = "",
		sound = { selects = {}, toggles = {}, limitDb = LEVEL_UNKNOWN, limitDbMin = 75, limitDbMax = 100 },
		stale = false,
		info = { fwL = "", fwR = "", serial = "", adaptive = "", dualDevices = {} },
		lastError = "",
		actionStatus = "",
		busy = false,
	}
end

local snapshot = defaultSnapshot()

local pendingField = ""
local pendingValue = nil
local queued = nil
local commandRunning = false
local queryRunning = false
local queryStartedAt = 0
local commandStartedAt = 0
local actionStatus = ""
local actionStatusDeadline = 0
local settleDeadline = 0
-- GATT needs quiet time after transient errors; hammering wedges it longer.
local COOLDOWN_MS = 30000
local cooldownUntil = 0

local function isTransientError(text)
	local t = string.lower(tostring(text or ""))
	return string.find(t, "uuid already registered", 1, true) ~= nil
		or string.find(t, "timed out", 1, true) ~= nil
		or string.find(t, "connection reset", 1, true) ~= nil
end

-- "Device is gone" signals. Narrowly scoped: a match still needs
-- bluetoothctl confirmation before failGone.
local GONE_MARKERS = {
	"device not found",
	"no such device",
	"not connected",
	"failed to connect",
	"host is down",
	"no route to host",
}

local function isGoneError(text)
	local t = string.lower(tostring(text or ""))
	for _, m in ipairs(GONE_MARKERS) do
		if string.find(t, m, 1, true) ~= nil then
			return true
		end
	end
	return false
end

-- Capability cache: list-settings is re-read when the MAC changes or when
-- quarantine expiry / a topology flip flags it dirty.
local capsCache = { mac = "", caps = nil, touchSpecs = nil, modelId = "", modelName = "" }

-- Quarantined setting ids: rejected while a bud sits in the case. Dropped
-- from the bulk query for QUARANTINE_MS; expiry re-reads list-settings.
local QUARANTINE_MS = 5 * 60 * 1000
local quarantined = {} -- id -> expiry ms
local capsDirty = false
local lastTopo = ""

-- Extracts the rejected setting id from "Model does not use setting id X".
local function badSettingId(text)
	local raw = string.match(tostring(text or ""), "[Dd]oes not use setting id ([%w_%-]+)")
	if raw == nil then
		return nil
	end
	local lowered = string.lower(raw)
	for id, _ in pairs(capsCache.presentIds or {}) do
		if string.lower(id) == lowered then
			return id
		end
	end
	return nil
end

local function quarantineNote()
	local names = {}
	for id, _ in pairs(quarantined) do
		table.insert(names, id)
	end
	if #names == 0 then
		return ""
	end
	table.sort(names)
	return " (not reporting: " .. table.concat(names, ", ") .. ")"
end

-- In-case tracking needs history, so it lives in service memory.
local inCase = { left = false, right = false }

local function updateInCase(twsConnected, host, leftCharging, rightCharging)
	local left = inCase.left
	local right = inCase.right
	if leftCharging then
		left = true
	end
	if rightCharging then
		right = true
	end
	local bothWereIn = left and right
	if twsConnected then
		left = leftCharging
		right = rightCharging
	elseif bothWereIn and not leftCharging and not rightCharging then
		left = true
		right = true
	else
		host = string.lower(trim(host))
		if host == "left" and not leftCharging and (rightCharging or right) then
			left = false
			right = true
		elseif host == "right" and not rightCharging and (leftCharging or left) then
			right = false
			left = true
		end
	end
	inCase = { left = left, right = right }
end

local function nowMs()
	return noctalia.nowMs()
end

local function configuredBin()
	local p = noctalia.getConfig("openscq30_path")
	if p == nil or p == "" then
		return "openscq30"
	end
	return p
end
local bin = configuredBin()

local function pollIntervalMs()
	local s = intOr(noctalia.getConfig("poll_interval"), 4)
	if s < 2 then
		s = 2
	elseif s > 15 then
		s = 15
	end
	return s * 1000
end

local function noiseModeName(mode)
	if mode == NOISE_OFF then
		return noctalia.tr("panel.mode.off")
	elseif mode == NOISE_ANC then
		return noctalia.tr("panel.mode.anc")
	elseif mode == NOISE_TRANSPARENCY then
		return noctalia.tr("panel.mode.transparency")
	elseif mode == NOISE_ADAPTIVE then
		return noctalia.tr("panel.mode.adaptive")
	end
	return noctalia.tr("panel.mode.unknown")
end

local function cancelModeLabel(c)
	if c == "Adaptive" then
		return noctalia.tr("panel.mode.adaptive")
	elseif c == "Manual" then
		return noctalia.tr("panel.cancel.manual")
	elseif c == "MultiScene" then
		return noctalia.tr("panel.cancel.multiscene")
	end
	return c
end

local function levelText(level)
	if level == nil or level == LEVEL_UNKNOWN then
		return "--"
	end
	return tostring(level) .. "%"
end

local function podMeta(pod, caseFlag)
	if pod.level == LEVEL_UNKNOWN then
		return ""
	end
	if pod.charging then
		return noctalia.tr("panel.charging")
	end
	if caseFlag then
		return noctalia.tr("panel.in_case")
	end
	if snapshot.connected then
		return noctalia.tr("panel.in_ear")
	end
	return ""
end

local function availableModes()
	if not snapshot.supportsNoiseControl then
		return {}
	end
	local modes = {}
	if snapshot.supportsNoiseOff then
		table.insert(modes, NOISE_OFF)
	end
	if snapshot.supportsTransparency then
		table.insert(modes, NOISE_TRANSPARENCY)
	end
	if snapshot.supportsAdaptive then
		table.insert(modes, NOISE_ADAPTIVE)
	end
	if snapshot.supportsAnc then
		table.insert(modes, NOISE_ANC)
	end
	return modes
end

local function applyOptimistic(field, value)
	if field == "noiseMode" then
		snapshot.noiseMode = value
		snapshot.topMode = (value == NOISE_ADAPTIVE) and NOISE_ANC or value
	elseif field == "manualAnc" then
		snapshot.manualAnc = value
		snapshot.noiseMode = NOISE_ANC
		snapshot.topMode = NOISE_ANC
		snapshot.noiseCancelMode = "Manual"
	elseif field == "noiseCancelMode" then
		snapshot.noiseCancelMode = value
		snapshot.topMode = NOISE_ANC
	elseif field == "touchTone" then
		snapshot.touch.tone = value
	elseif string.sub(field, 1, 6) == "touch:" then
		local id = string.sub(field, 7)
		for _, control in ipairs(snapshot.touch.controls) do
			if control.id == id then
				control.value = value
				break
			end
		end
	elseif snapshot.sound.selects[field] ~= nil then
		snapshot.sound.selects[field].value = value
	elseif snapshot.sound.toggles[field] ~= nil then
		snapshot.sound.toggles[field] = value
	elseif field == "limitHighVolumeDbLimit" then
		snapshot.sound.limitDb = value
	end
end

local function clearPending()
	pendingField = ""
	pendingValue = nil
	settleDeadline = 0
end

local function publish()
	snapshot.busy = commandRunning or queryRunning
	snapshot.actionStatus = actionStatus

	snapshot.hasBattery = snapshot.connected
		and (snapshot.left.level ~= LEVEL_UNKNOWN
			or snapshot.right.level ~= LEVEL_UNKNOWN
			or snapshot.caseBattery.level ~= LEVEL_UNKNOWN
			or snapshot.headset.level ~= LEVEL_UNKNOWN)

	snapshot.noiseModeName = noiseModeName(snapshot.noiseMode)
	snapshot.subModeName = ""
	if snapshot.topMode == NOISE_ANC and snapshot.noiseCancelMode ~= "" then
		snapshot.subModeName = cancelModeLabel(snapshot.noiseCancelMode)
	end
	snapshot.leftText = levelText(snapshot.left.level)
	snapshot.rightText = levelText(snapshot.right.level)
	snapshot.caseText = levelText(snapshot.caseBattery.level)
	snapshot.headsetText = levelText(snapshot.headset.level)
	snapshot.headsetMeta = snapshot.headset.charging and noctalia.tr("panel.charging") or ""

	-- Charging alone is unreliable (buds rest in the case unplugged).
	snapshot.leftMeta = podMeta(snapshot.left, inCase.left)
	snapshot.rightMeta = podMeta(snapshot.right, inCase.right)

	local modes = {}
	for _, mode in ipairs(availableModes()) do
		table.insert(modes, { value = mode, label = noiseModeName(mode) })
	end
	snapshot.availableModes = modes
	snapshot.cancelModes = {}
	for _, c in ipairs((capsCache.caps or {}).cancelOptions or {}) do
		table.insert(snapshot.cancelModes, { value = c, label = cancelModeLabel(c) })
	end

	local l = snapshot.left.level
	local r = snapshot.right.level
	local primaryLevel = LEVEL_UNKNOWN
	local primaryCharging = false
	if snapshot.isHeadset and snapshot.headset.level ~= LEVEL_UNKNOWN then
		snapshot.primaryText = snapshot.headsetText
		primaryLevel = snapshot.headset.level
		primaryCharging = snapshot.headset.charging
	elseif l == LEVEL_UNKNOWN and r == LEVEL_UNKNOWN then
		snapshot.primaryText = snapshot.caseBattery.level ~= LEVEL_UNKNOWN and snapshot.caseText or "--"
		primaryLevel = snapshot.caseBattery.level
		primaryCharging = snapshot.caseBattery.charging
	elseif l == LEVEL_UNKNOWN then
		snapshot.primaryText = levelText(r)
		primaryLevel = r
		primaryCharging = snapshot.right.charging
	elseif r == LEVEL_UNKNOWN then
		snapshot.primaryText = levelText(l)
		primaryLevel = l
		primaryCharging = snapshot.left.charging
	elseif l <= r then
		snapshot.primaryText = levelText(l)
		primaryLevel = l
		primaryCharging = snapshot.left.charging
	else
		snapshot.primaryText = levelText(r)
		primaryLevel = r
		primaryCharging = snapshot.right.charging
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

-- Holds a written value until the daemon echoes it back, so an in-flight
-- write cannot snap the control back.
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

local function parseModels(stdout)
	local models = {}
	for line in string.gmatch(tostring(stdout or "") .. "\n", "([^\n]*)\n") do
		local t = trim(line)
		if t ~= "" and not string.find(t, "^SoundcoreDevelopment") then
			local id, name = string.match(t, "^(%S+)%s+(.-)%s*$")
			if id and name and string.find(id, "^Soundcore") then
				table.insert(models, { id = id, name = name })
			end
		end
	end
	return models
end

-- `paired-devices list` prints: header + "<model_id>\t<mac>\t<demo>".
local function parsePaired(stdout)
	local rows = {}
	local first = true
	for line in string.gmatch(tostring(stdout or "") .. "\n", "([^\n]*)\n") do
		if first then
			first = false
		else
			local t = trim(line)
			if t ~= "" then
				local parts = {}
				for p in string.gmatch(t, "([^\t]+)") do
					table.insert(parts, trim(p))
				end
				if #parts < 2 then
					parts = {}
					for p in string.gmatch(t, "(%S+)") do
						table.insert(parts, p)
					end
				end
				if #parts >= 2 and string.find(parts[1], "^Soundcore") then
					table.insert(rows, { id = parts[1], mac = parts[2] })
				end
			end
		end
	end
	return rows
end

local function modelNameFor(models, id)
	for _, m in ipairs(models) do
		if m.id == id then
			return m.name
		end
	end
	return id
end

local function parseBtInfo(stdout)
	local out = { connected = false, name = "" }
	for line in string.gmatch(tostring(stdout or "") .. "\n", "([^\n]*)\n") do
		local t = trim(line)
		local conn = string.match(t, "^Connected:%s*(%S+)")
		if conn and string.lower(conn) == "yes" then
			out.connected = true
		end
		local name = string.match(t, "^Name:%s*(.-)%s*$")
		if name and name ~= "" and out.name == "" then
			out.name = name
		end
	end
	return out
end

local function parseBtDevices(stdout)
	local devices = {}
	for line in string.gmatch(tostring(stdout or "") .. "\n", "([^\n]*)\n") do
		local mac, name = string.match(trim(line), "^Device%s+(%S+)%s+(.-)%s*$")
		if mac and name then
			table.insert(devices, { mac = mac, name = name })
		end
	end
	return devices
end

local function settingMap(rows)
	local out = {}
	if type(rows) ~= "table" then
		return out
	end
	for _, row in ipairs(rows) do
		if type(row) == "table" and row.settingId ~= nil then
			local v = row.value
			if type(v) == "table" then
				out[row.settingId] = v.value
			else
				out[row.settingId] = v
			end
		end
	end
	return out
end

local function selectOptions(spec)
	local setting = (spec or {}).setting or {}
	local opts = {}
	for _, item in ipairs(setting.options or {}) do
		table.insert(opts, tostring(item))
	end
	return opts
end

local function hasOption(opts, want)
	for _, o in ipairs(opts) do
		if o == want then
			return true
		end
	end
	return false
end

local function capsFromListSettings(decoded)
	local caps = {
		supportsNoiseOff = false,
		supportsTransparency = false,
		supportsAnc = false,
		supportsAdaptive = false,
		supportsMultiScene = false,
		supportsManualAnc = false,
		cancelOptions = {},
		manualAncMin = 1,
		manualAncMax = 5,
	}
	if type(decoded) ~= "table" then
		return caps
	end
	local ambient = selectOptions(decoded.ambientSoundMode)
	if #ambient > 0 then
		caps.supportsNoiseOff = hasOption(ambient, "Normal")
		caps.supportsTransparency = hasOption(ambient, "Transparency")
		caps.supportsAnc = hasOption(ambient, "NoiseCanceling")
		local cancel = selectOptions(decoded.noiseCancelingMode)
		caps.supportsAdaptive = hasOption(cancel, "Adaptive")
		caps.supportsMultiScene = hasOption(cancel, "MultiScene")
		caps.cancelOptions = cancel
	end
	local manual = (decoded.manualNoiseCanceling or {}).setting or {}
	if decoded.manualNoiseCanceling ~= nil then
		caps.supportsManualAnc = true
		local lo = intOr(manual.start, 1)
		local hi = intOr(manual["end"], 5)
		if hi >= lo then
			caps.manualAncMin = lo
			caps.manualAncMax = hi
		end
	end
	return caps
end

local function humanizeId(value)
	local text = string.gsub(tostring(value or ""), "(%l)(%u)", "%1 %2")
	text = string.gsub(text, "_", " ")
	text = trim(text)
	if text == "" then
		return "Off"
	end
	return string.upper(string.sub(text, 1, 1)) .. string.sub(text, 2)
end

local function touchOptionsFor(spec)
	local setting = (spec or {}).setting or {}
	local options = setting.options or {}
	local labels = setting.localizedOptions or {}
	local rows = { { id = "", label = nil } }
	for i, oid in ipairs(options) do
		local label = labels[i]
		if label == nil or label == "" then
			label = humanizeId(oid)
		end
		table.insert(rows, { id = tostring(oid), label = tostring(label) })
	end
	return rows
end

local function touchSpecsFromListSettings(decoded)
	local specs = { controls = {}, supportsReset = false, supportsTone = false }
	if type(decoded) ~= "table" then
		return specs
	end
	for _, id in ipairs(TOUCH_IDS) do
		if decoded[id] ~= nil then
			table.insert(specs.controls, { id = id, options = touchOptionsFor(decoded[id]) })
		end
	end
	specs.supportsReset = decoded.resetButtonsToDefault ~= nil
	specs.supportsTone = decoded.touchTone ~= nil
	return specs
end

local OPTION_LABEL_OVERRIDES = { RnB = "R&B" }

local function optionLabel(oid)
	local override = OPTION_LABEL_OVERRIDES[oid]
	if override ~= nil then
		return override
	end
	return humanizeId(oid)
end

local function soundSpecsFromListSettings(decoded)
	local specs = { selects = {}, toggles = {}, ints = {}, dualOptions = {} }
	if type(decoded) ~= "table" then
		return specs
	end
	for _, id in ipairs(SELECT_IDS) do
		local opts = selectOptions(decoded[id])
		if #opts > 0 then
			local rows = {}
			for _, oid in ipairs(opts) do
				table.insert(rows, { id = oid, label = optionLabel(oid) })
			end
			specs.selects[id] = { options = rows }
		end
	end
	for _, id in ipairs(TOGGLE_IDS) do
		if decoded[id] ~= nil then
			specs.toggles[id] = true
		end
	end
	for _, id in ipairs(INT_IDS) do
		local setting = ((decoded[id] or {}).setting or {})
		local lo = intOr(setting.start, 0)
		local hi = intOr(setting["end"], 100)
		local step = intOr(setting.step, 1)
		if step < 1 then
			step = 1
		end
		if hi >= lo then
			specs.ints[id] = { min = lo, max = hi, step = step }
		end
	end
	specs.dualOptions = selectOptions(decoded.dualConnectionsDevices)
	return specs
end

local function touchValueById(controls, id)
	for _, c in ipairs(controls or {}) do
		if c.id == id then
			return tostring(c.value or "")
		end
	end
	return ""
end

local function withTouchValue(controls, id, value)
	local nextControls = {}
	for _, c in ipairs(controls or {}) do
		if c.id == id then
			table.insert(nextControls, { id = c.id, label = c.label, value = tostring(value or ""), options = c.options })
		else
			table.insert(nextControls, c)
		end
	end
	return nextControls
end

-- Display labels resolve here (not in the cache) so a language switch
-- applies on the next poll.
local function touchPayload(specs, s)
	local out = { available = false, reset = false, supportsTone = false, tone = false, controls = {} }
	if specs == nil then
		return out
	end
	out.reset = specs.supportsReset
	out.supportsTone = specs.supportsTone
	out.tone = yes(s.touchTone)
	for _, spec in ipairs(specs.controls) do
		local raw = s[spec.id]
		local value = (raw == nil) and "" or tostring(raw)
		local options = {}
		for _, opt in ipairs(spec.options) do
			local label = opt.label
			if label == nil then
				label = noctalia.tr("panel.touch.off")
			end
			table.insert(options, { id = opt.id, label = label })
		end
		table.insert(out.controls, {
			id = spec.id,
			label = noctalia.tr(TOUCH_LABEL_KEYS[spec.id] or spec.id),
			value = value,
			options = options,
		})
	end
	if #out.controls > 0 then
		out.available = true
	end
	return out
end

local function topModeFrom(ambient)
	ambient = tostring(ambient or "")
	if ambient == "Normal" then
		return NOISE_OFF
	elseif ambient == "Transparency" then
		return NOISE_TRANSPARENCY
	elseif ambient == "NoiseCanceling" then
		return NOISE_ANC
	end
	return NOISE_UNKNOWN
end

local function noiseFrom(ambient, cancel)
	ambient = tostring(ambient or "")
	cancel = tostring(cancel or "")
	if ambient == "Normal" then
		return NOISE_OFF
	elseif ambient == "Transparency" then
		return NOISE_TRANSPARENCY
	elseif ambient == "NoiseCanceling" and cancel == "Adaptive" then
		return NOISE_ADAPTIVE
	elseif ambient == "NoiseCanceling" then
		return NOISE_ANC
	end
	return NOISE_UNKNOWN
end

local function failGone(err)
	snapshot.connected = false
	snapshot.stale = false
	snapshot.lastError = err or ""
	snapshot.left = defaultPod()
	snapshot.right = defaultPod()
	snapshot.caseBattery = defaultPod()
	snapshot.headset = defaultPod()
	-- A leftover busy cooldown would keep the icon lingering.
	cooldownUntil = 0
	-- Fresh transport deserves fresh capabilities on reconnect.
	capsDirty = true
	inCase = { left = false, right = false }
	clearPending()
	publish()
end

-- Transport is up but the control channel is busy: keep last-known data
-- dimmed instead of vanishing.
local function failBusy(err)
	snapshot.stale = true
	local hint = noctalia.tr("errors.control_busy")
	local raw = elideError(err)
	if raw ~= "" then
		hint = hint .. " (" .. raw .. ")"
	end
	hint = hint .. quarantineNote()
	snapshot.lastError = hint
	cooldownUntil = nowMs() + COOLDOWN_MS
	clearPending()
	publish()
end

-- Only these are queried (and only when the device reports them).
local QUERY_IDS = {
	"ambientSoundMode", "noiseCancelingMode", "manualNoiseCanceling",
	"batteryLevel", "isCharging", "batteryLevelLeft", "batteryLevelRight",
	"caseBatteryLevel", "isChargingLeft", "isChargingRight",
	"twsStatus", "hostDevice", "touchTone",
	"leftSinglePress", "rightSinglePress", "leftDoublePress", "rightDoublePress",
	"leftTriplePress", "rightTriplePress", "leftLongPress", "rightLongPress",
	"transparencyMode", "multiSceneNoiseCanceling",
	"autoPowerOff", "limitHighVolumeRefreshRate",
	"windNoiseSuppression", "dualConnections", "lowBatteryPrompt",
	"limitHighVolume", "realTimeAdaptiveNoiseCanceling",
	"limitHighVolumeDbLimit",
	"firmwareVersion", "firmwareVersionLeft", "firmwareVersionRight",
	"serialNumber", "adaptiveNoiseCanceling", "dualConnectionsDevices",
}

-- Drops expired ids and flags a re-read for the next poll.
local function pruneQuarantine()
	local now = nowMs()
	local expired = false
	for id, untilMs in pairs(quarantined) do
		if now >= untilMs then
			quarantined[id] = nil
			expired = true
		end
	end
	if expired then
		capsDirty = true
	end
end

local function stepQuery(chosen)
	local presentIds = capsCache.presentIds or {}
	local function request()
		local args = { bin, "device", "--mac-address", chosen.mac, "setting", "--json" }
		for _, id in ipairs(QUERY_IDS) do
			-- Unknown ids fail the whole call; quarantined ones are skipped.
			if presentIds[id] and quarantined[id] == nil then
				table.insert(args, "--get")
				table.insert(args, id)
			end
		end
		noctalia.runAsync(args, function(result)
			queryRunning = false
			if result.exitCode ~= 0 then
				local raw = result.stderr ~= "" and result.stderr or result.stdout
				local badId = badSettingId(raw)
				if badId ~= nil and presentIds[badId] then
					-- Each retry removes one id, so this terminates.
					presentIds[badId] = nil
					quarantined[badId] = nowMs() + QUARANTINE_MS
					queryRunning = true
					queryStartedAt = nowMs()
					request()
					return
				end
				if isGoneError(raw) then
				-- Substring alone never hides the widget: confirm first.
				local msg = elideError(raw)
				local mac = chosen.mac
				queryRunning = true
				queryStartedAt = nowMs()
				noctalia.runAsync({ "bluetoothctl", "info", mac }, function(ir)
					queryRunning = false
					if ir.exitCode ~= 0 or not parseBtInfo(ir.stdout).connected then
						failGone(msg)
					else
						failBusy(raw)
					end
				end, 8000)
			elseif isTransientError(raw) then
				failBusy(elideError(raw))
			else
				-- A real disconnect is still caught by the chain below.
				failBusy(elideError(raw))
			end
			return
		end
		local decoded = noctalia.json.decode(result.stdout or "")
		if type(decoded) ~= "table" then
			failBusy("Could not parse openscq30 output")
			return
		end
		local s = settingMap(decoded)
		-- A topology flip (bud in/out) re-probes on the next poll.
		local topo = tostring(s.twsStatus or "") .. "|" .. tostring(s.hostDevice or "")
		if lastTopo ~= "" and topo ~= lastTopo then
			quarantined = {}
			capsDirty = true
		end
		lastTopo = topo
		local caps = capsCache.caps or capsFromListSettings({})
		snapshot.connected = true
		snapshot.deviceName = chosen.btName or ""
		snapshot.modelName = chosen.modelName or ""
		snapshot.modelId = chosen.modelId or ""
		snapshot.mac = chosen.mac or ""
		local singleLevel = fifths(s.batteryLevel)
		local singleChg = yes(s.isCharging)
		if singleLevel == LEVEL_UNKNOWN then
			singleChg = false
		end
		local hasDual = s.batteryLevelLeft ~= nil or s.batteryLevelRight ~= nil
		snapshot.isHeadset = singleLevel ~= LEVEL_UNKNOWN and not hasDual
		snapshot.headset = { level = singleLevel, charging = singleChg }
		snapshot.supportsNoiseOff = caps.supportsNoiseOff
		snapshot.supportsTransparency = caps.supportsTransparency
		snapshot.supportsAnc = caps.supportsAnc
		snapshot.supportsAdaptive = caps.supportsAdaptive
		snapshot.supportsManualAnc = caps.supportsManualAnc
		snapshot.supportsMultiScene = caps.supportsMultiScene
		snapshot.supportsNoiseControl = caps.supportsAnc or caps.supportsTransparency
		snapshot.manualAncMin = caps.manualAncMin
		snapshot.manualAncMax = caps.manualAncMax
		snapshot.lastError = ""
		snapshot.stale = false

		local leftLevel = fifths(s.batteryLevelLeft)
		local rightLevel = fifths(s.batteryLevelRight)
		local caseLevel = fifths(s.caseBatteryLevel)
		local leftChg = yes(s.isChargingLeft)
		local rightChg = yes(s.isChargingRight)
		if leftLevel == LEVEL_UNKNOWN then
			leftChg = false
		end
		if rightLevel == LEVEL_UNKNOWN then
			rightChg = false
		end
		snapshot.left = { level = leftLevel, charging = leftChg }
		snapshot.right = { level = rightLevel, charging = rightChg }
		snapshot.caseBattery = { level = caseLevel, charging = leftChg or rightChg }
		updateInCase(
			string.lower(trim(s.twsStatus)) == "connected",
			s.hostDevice,
			leftChg,
			rightChg
		)

		snapshot.noiseMode = settle("noiseMode", noiseFrom(s.ambientSoundMode, s.noiseCancelingMode))
		snapshot.topMode = settle("topMode", topModeFrom(s.ambientSoundMode))
		snapshot.noiseCancelMode = settle("noiseCancelMode", tostring(s.noiseCancelingMode or ""))
		local manual = intOr(s.manualNoiseCanceling, LEVEL_UNKNOWN)
		if manual ~= LEVEL_UNKNOWN then
			if manual < caps.manualAncMin then
				manual = caps.manualAncMin
			elseif manual > caps.manualAncMax then
				manual = caps.manualAncMax
			end
		end
		snapshot.manualAnc = settle("manualAnc", manual)

		local reportedTouch = touchPayload(capsCache.touchSpecs, s)
		if pendingField ~= "" and string.sub(pendingField, 1, 6) == "touch:" then
			local tid = string.sub(pendingField, 7)
			if touchValueById(reportedTouch.controls, tid) == pendingValue then
				clearPending()
				snapshot.touch = reportedTouch
			else
				snapshot.touch = reportedTouch
				snapshot.touch.controls = withTouchValue(reportedTouch.controls, tid, pendingValue)
			end
		else
			snapshot.touch = reportedTouch
		end
		snapshot.touch.tone = settle("touchTone", snapshot.touch.tone)

		local snd = { selects = {}, toggles = {}, limitDb = LEVEL_UNKNOWN, limitDbMin = 75, limitDbMax = 100, limitDbStep = 5 }
		local sspecs = capsCache.soundSpecs
		if sspecs ~= nil then
			for id, spec in pairs(sspecs.selects) do
				snd.selects[id] = {
					value = settle(id, tostring(s[id] or "")),
					options = spec.options,
				}
			end
			for id, _ in pairs(sspecs.toggles) do
				snd.toggles[id] = settle(id, yes(s[id]))
			end
			local lim = sspecs.ints["limitHighVolumeDbLimit"]
			if lim ~= nil then
				snd.limitDbMin = lim.min
				snd.limitDbMax = lim.max
				snd.limitDbStep = lim.step
				local n = intOr(s.limitHighVolumeDbLimit, LEVEL_UNKNOWN)
				if n ~= LEVEL_UNKNOWN then
					if n < lim.min then
						n = lim.min
					elseif n > lim.max then
						n = lim.max
					end
				end
				snd.limitDb = settle("limitHighVolumeDbLimit", n)
			end
		end
		snapshot.sound = snd

		local devList = {}
		local dualRaw = s.dualConnectionsDevices
		if type(dualRaw) == "table" then
			for _, m in ipairs(dualRaw) do
				table.insert(devList, tostring(m))
			end
		elseif dualRaw ~= nil and tostring(dualRaw) ~= "" then
			table.insert(devList, tostring(dualRaw))
		elseif sspecs ~= nil then
			for _, m in ipairs(sspecs.dualOptions) do
				table.insert(devList, m)
			end
		end
		local fwL, fwR = tostring(s.firmwareVersionLeft or ""), tostring(s.firmwareVersionRight or "")
		if fwL == "" and fwR == "" then
			fwL = tostring(s.firmwareVersion or "")
		end
		snapshot.info = {
			fwL = fwL,
			fwR = fwR,
			serial = tostring(s.serialNumber or ""),
			adaptive = tostring(s.adaptiveNoiseCanceling or ""),
			dualDevices = devList,
		}
		publish()
		end, QUERY_TIMEOUT_MS)
	end
	request()
end

local function stepCaps(chosen)
	pruneQuarantine()
	local known = capsCache.mac == chosen.mac and capsCache.caps ~= nil
	if known and not capsDirty then
		stepQuery(chosen)
		return
	end
	noctalia.runAsync(
		{ bin, "device", "--mac-address", chosen.mac, "list-settings", "--json", "--no-categories" },
		function(result)
			if result.exitCode ~= 0 then
				queryRunning = false
				local raw = elideError(result.stderr ~= "" and result.stderr or result.stdout)
				if known then
					-- Keep the old capabilities and stay stale-visible.
					failBusy(raw)
					return
				end
				failGone(raw)
				return
			end
			local decoded = noctalia.json.decode(result.stdout or "")
			local presentIds = {}
			if type(decoded) == "table" then
				for id, _ in pairs(decoded) do
					presentIds[id] = true
				end
			end
			capsCache = {
				mac = chosen.mac,
				presentIds = presentIds,
				caps = capsFromListSettings(decoded),
				touchSpecs = touchSpecsFromListSettings(decoded),
				soundSpecs = soundSpecsFromListSettings(decoded),
				modelId = chosen.modelId,
				modelName = chosen.modelName,
			}
			quarantined = {}
			capsDirty = false
			stepQuery(chosen)
		end,
		QUERY_TIMEOUT_MS
	)
end

local function checkPairedAt(models, paired, index)
	if index > #paired then
		noctalia.runAsync({ "bluetoothctl", "devices" }, function(result)
			if result.exitCode ~= 0 then
				queryRunning = false
				failGone("")
				return
			end
			local best = nil
			local bestScore = 0
			for _, d in ipairs(parseBtDevices(result.stdout)) do
				for _, m in ipairs(models) do
					local score = matchScore(d.name, m.name)
					if score > bestScore then
						bestScore = score
						best = { mac = d.mac, btName = d.name, modelId = m.id, modelName = m.name }
					end
				end
			end
			if best == nil or bestScore <= 0 then
				queryRunning = false
				failGone("")
				return
			end
			local target = best
			noctalia.runAsync({ "bluetoothctl", "info", target.mac }, function(ir)
				if ir.exitCode ~= 0 or not parseBtInfo(ir.stdout).connected then
					queryRunning = false
					failGone("")
					return
				end
				-- Found via scan, not paired-devices: register first.
				noctalia.runAsync({ bin, "paired-devices", "add",
					"--mac-address", target.mac, "--model", target.modelId },
					function()
						stepCaps(target)
					end, 8000)
			end, 8000)
		end, 8000)
		return
	end
	local row = paired[index]
	noctalia.runAsync({ "bluetoothctl", "info", row.mac }, function(result)
		if result.exitCode == 0 then
			local info = parseBtInfo(result.stdout)
			if info.connected then
				stepCaps({
					mac = row.mac,
					btName = info.name ~= "" and info.name or modelNameFor(models, row.id),
					modelId = row.id,
					modelName = modelNameFor(models, row.id),
				})
				return
			end
		end
		checkPairedAt(models, paired, index + 1)
	end, 8000)
end

-- Full discovery chain. Only runs when transport is believed up.
local function refreshFull()
	if nowMs() < cooldownUntil then
		return
	end
	if not noctalia.commandExists("openscq30") and (bin == "openscq30") then
		snapshot.backendOk = false
		failGone(noctalia.tr("errors.not_installed"))
		return
	end
	snapshot.backendOk = true
	queryRunning = true
	queryStartedAt = nowMs()
	noctalia.runAsync({ bin, "list-models" }, function(mr)
		if mr.exitCode ~= 0 then
			queryRunning = false
			failGone(elideError(mr.stderr ~= "" and mr.stderr or mr.stdout))
			return
		end
		local models = parseModels(mr.stdout)
		if #models == 0 then
			queryRunning = false
			failGone(elideError(mr.stderr))
			return
		end
		noctalia.runAsync({ bin, "paired-devices", "list" }, function(pr)
			if pr.exitCode ~= 0 then
				queryRunning = false
				failGone(elideError(pr.stderr ~= "" and pr.stderr or pr.stdout))
				return
			end
			checkPairedAt(models, parsePaired(pr.stdout), 1)
		end, 8000)
	end, 8000)
end

local function refresh()
	if queryRunning or commandRunning then
		return
	end
	-- A locating tone would only make the snapshot flap.
	if snapshot.findingSide ~= "" then
		return
	end
	-- Cheap transport check first, but only when trouble is suspected;
	-- healthy polls go straight to the full chain.
	if snapshot.connected == true and snapshot.mac ~= "" then
		if nowMs() >= cooldownUntil and snapshot.stale ~= true and snapshot.lastError == "" then
			refreshFull()
			return
		end
		local mac = snapshot.mac
		queryRunning = true
		queryStartedAt = nowMs()
		noctalia.runAsync({ "bluetoothctl", "info", mac }, function(ir)
			if ir.exitCode ~= 0 or not parseBtInfo(ir.stdout).connected then
				queryRunning = false
				failGone("")
				return
			end
			queryRunning = false
			refreshFull()
		end, 8000)
		return
	end
	refreshFull()
end

local function uuidBusy(result)
	return isTransientError(tostring(result.stderr or "") .. (result.stdout or ""))
end

-- Shared by the initial send and the busy retry.
local function setsArgs(sets)
	local args = { bin, "device", "--mac-address", snapshot.mac, "setting" }
	for _, item in ipairs(sets) do
		table.insert(args, "--set")
		table.insert(args, item)
	end
	return args
end

-- Busy cooldown plus a status line. Queue draining stays with the caller.
local function noteSetsRejected(output)
	if isTransientError(output) then
		cooldownUntil = nowMs() + COOLDOWN_MS
	end
	actionStatus = elideError(output)
	if actionStatus == "" then
		actionStatus = noctalia.tr("errors.ctl_rejected")
	end
	actionStatusDeadline = nowMs() + ACTION_STATUS_MS
end

-- Single-slot coalescing for slider drags. Returns true when it took over.
local function drainSetsQueue()
	if queued == nil then
		return false
	end
	local nextCmd = queued
	queued = nil
	sendSets(nextCmd.sets, nextCmd.field, nextCmd.optimistic, 1)
	return true
end

local function sendSets(sets, field, optimistic, attempt)
	if #sets == 0 then
		return
	end
	if commandRunning then
		queued = { sets = sets, field = field, optimistic = optimistic }
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
	commandStartedAt = nowMs()
	publish()

	local args = setsArgs(sets)
	noctalia.runAsync(args, function(result)
		commandRunning = false
		if result.exitCode ~= 0 and uuidBusy(result) and (attempt or 1) < 3 then
			commandRunning = true
			commandStartedAt = nowMs()
			noctalia.runAsync(setsArgs(sets), function(r2)
				commandRunning = false
				if r2.exitCode ~= 0 then
					clearPending()
					queryRunning = false
					noteSetsRejected(r2.stderr)
					refresh()
				end
				if not drainSetsQueue() then
					publish()
				end
			end, SET_TIMEOUT_MS)
			return
		end
		if result.exitCode ~= 0 then
			clearPending()
			noteSetsRejected(result.stderr)
		end
		if not drainSetsQueue() then
			publish()
			queryRunning = false
			refresh()
		end
	end, SET_TIMEOUT_MS)
end

local function modeSets(mode)
	if mode == NOISE_OFF and snapshot.supportsNoiseOff then
		return { "ambientSoundMode=Normal" }
	elseif mode == NOISE_TRANSPARENCY and snapshot.supportsTransparency then
		return { "ambientSoundMode=Transparency" }
	elseif mode == NOISE_ADAPTIVE and snapshot.supportsAdaptive then
		return { "ambientSoundMode=NoiseCanceling", "noiseCancelingMode=Adaptive" }
	elseif mode == NOISE_ANC and snapshot.supportsAnc then
		return { "ambientSoundMode=NoiseCanceling" }
	end
	return {}
end

local function setNoiseMode(mode)
	if not snapshot.connected then
		return
	end
	local sets = modeSets(mode)
	if #sets == 0 then
		return
	end
	sendSets(sets, "noiseMode", mode, 1)
end

local function setCancelMode(cancel)
	if not snapshot.connected then
		return
	end
	if not contains((capsCache.caps or {}).cancelOptions, cancel) then
		return
	end
	sendSets({ "noiseCancelingMode=" .. cancel }, "noiseCancelMode", cancel, 1)
end

local function cycleNoiseMode()
	if not snapshot.connected then
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
	setNoiseMode(at == 0 and modes[1] or modes[(at % #modes) + 1])
end

local function setAncLevel(level)
	if not snapshot.connected or not snapshot.supportsManualAnc then
		return
	end
	local lo = snapshot.manualAncMin
	local hi = snapshot.manualAncMax
	local n = clampInt(level, lo, hi)
	local sets = { "ambientSoundMode=NoiseCanceling" }
	if contains((capsCache.caps or {}).cancelOptions, "Manual") then
		table.insert(sets, "noiseCancelingMode=Manual")
	end
	table.insert(sets, "manualNoiseCanceling=" .. tostring(n))
	sendSets(sets, "manualAnc", n, 1)
end

local function touchSpecById(id)
	if capsCache.touchSpecs == nil then
		return nil
	end
	for _, spec in ipairs(capsCache.touchSpecs.controls) do
		if spec.id == id then
			return spec
		end
	end
	return nil
end

local function setTouch(id, value)
	if not snapshot.connected or snapshot.touch.available ~= true then
		return
	end
	local spec = touchSpecById(id)
	if spec == nil then
		return
	end
	local nextValue = tostring(value or "")
	if not contains(spec.options, nextValue, "id") then
		return
	end
	sendSets({ id .. "=" .. nextValue }, "touch:" .. id, nextValue, 1)
end

local function resetTouch()
	if not snapshot.connected or snapshot.touch.reset ~= true then
		return
	end
	sendSets({ "resetButtonsToDefault=" }, "touch:reset", "", 1)
end

local function setTouchTone(enabled)
	if not snapshot.connected or snapshot.touch.supportsTone ~= true then
		return
	end
	sendSets({ "touchTone=" .. (enabled and "true" or "false") }, "touchTone", enabled, 1)
end

local function setSelect(id, value)
	if not snapshot.connected then
		return
	end
	local specs = capsCache.soundSpecs
	local spec = specs and specs.selects[id] or nil
	if spec == nil then
		return
	end
	local v = tostring(value or "")
	if not contains(spec.options, v, "id") then
		return
	end
	sendSets({ id .. "=" .. v }, id, v, 1)
end

local function setToggle(id, enabled)
	if not snapshot.connected then
		return
	end
	if capsCache.soundSpecs == nil or not capsCache.soundSpecs.toggles[id] then
		return
	end
	sendSets({ id .. "=" .. (enabled and "true" or "false") }, id, enabled, 1)
end

local function setInt(id, value)
	if not snapshot.connected then
		return
	end
	local specs = capsCache.soundSpecs
	local spec = specs and specs.ints[id] or nil
	if spec == nil then
		return
	end
	local n = clampInt(value, spec.min, spec.max)
	sendSets({ id .. "=" .. tostring(n) }, id, n, 1)
end

local findRunning = false
local queuedFind = ""

local function findScript()
	local dir = noctalia.pluginDir()
	if dir == nil or dir == "" then
		return nil
	end
	return dir .. "/helpers/find.sh"
end

local function failFind(message)
	findRunning = false
	snapshot.findingSide = ""
	actionStatus = message
	actionStatusDeadline = nowMs() + ACTION_STATUS_MS
	publish()
end

local function startFind(side)
	local script = findScript()
	if script == nil then
		failFind("Could not locate helpers/find.sh")
		return
	end
	findRunning = true
	snapshot.findingSide = side
	publish()
	local accepted = noctalia.runAsync({ "bash", script, side, snapshot.mac }, function(result)
		findRunning = false
		snapshot.findingSide = ""
		if result.exitCode ~= 0 and queuedFind == "" then
			local msg = elideError(result.stderr)
			if msg == "" then
				msg = noctalia.tr("errors.find_failed")
			end
			actionStatus = msg
			actionStatusDeadline = nowMs() + ACTION_STATUS_MS
		end
		if queuedFind ~= "" then
			local nextSide = queuedFind
			queuedFind = ""
			startFind(nextSide)
		else
			publish()
		end
	end, FIND_TIMEOUT_MS)
	if not accepted then
		failFind(noctalia.tr("errors.find_failed"))
	end
end

local function stopFind(hold)
	local script = findScript()
	if script == nil then
		return
	end
	local args = { "bash", script, "stop" }
	if hold then
		table.insert(args, "--hold")
	end
	-- Fire and forget.
	noctalia.runAsync(args, function(_result)
		if not findRunning and queuedFind == "" and snapshot.findingSide ~= "" then
			snapshot.findingSide = ""
			publish()
		end
	end, 15000)
end

local function find(side)
	if side ~= "left" and side ~= "right" then
		return
	end
	if not snapshot.connected or snapshot.mac == "" then
		return
	end
	if findRunning or snapshot.findingSide ~= "" then
		-- Switch sides without resuming playback in between.
		queuedFind = side
		stopFind(true)
		return
	end
	startFind(side)
end

-- Command verbs from the panel/widget. Handlers validate their own payload.
local COMMANDS = {
	["refresh"] = function(_value)
		if not queryRunning then
			refresh()
		end
	end,
	["cycle-noise"] = function(_value)
		cycleNoiseMode()
	end,
	["set-noise"] = function(value)
		setNoiseMode(intOr(value, NOISE_UNKNOWN))
	end,
	["set-cancel-mode"] = function(value)
		setCancelMode(tostring(value or ""))
	end,
	["set-anc-level"] = function(value)
		setAncLevel(intOr(value, snapshot.manualAncMin))
	end,
	["set-touch"] = function(value)
		if type(value) == "table" then
			setTouch(tostring(value.id or ""), value.value)
		end
	end,
	["touch-reset"] = function(_value)
		resetTouch()
	end,
	["touch-tone"] = function(value)
		setTouchTone(value == true)
	end,
	["set-select"] = function(value)
		if type(value) == "table" then
			setSelect(tostring(value.id or ""), value.value)
		end
	end,
	["set-toggle"] = function(value)
		if type(value) == "table" then
			setToggle(tostring(value.id or ""), value.enabled == true)
		end
	end,
	["set-int"] = function(value)
		if type(value) == "table" then
			setInt(tostring(value.id or ""), tonumber(value.value))
		end
	end,
	["find"] = function(value)
		find(tostring(value or ""))
	end,
	["stop-find"] = function(_value)
		queuedFind = ""
		stopFind(false)
	end,
}

local function executeCommand(cmd)
	if type(cmd) ~= "table" or type(cmd.action) ~= "string" then
		return
	end
	local handler = COMMANDS[cmd.action]
	if handler ~= nil then
		handler(cmd.value)
	end
end

-- IPC entry: only the documented verbs are reachable from outside. Control
-- verbs (set-*/touch-*) stay on the panel's state channel so a stray
-- `noctalia msg` cannot wipe buds buttons or force settings with nil.
local IPC_VERBS = {
	["refresh"] = true,
	["cycle-noise"] = true,
	["find-left"] = true,
	["find-right"] = true,
	["stop-find"] = true,
}

function onIpc(event, _payload)
	if IPC_VERBS[event] ~= true then
		return
	end
	local verb, arg = event, nil
	if event == "find-left" then
		verb, arg = "find", "left"
	elseif event == "find-right" then
		verb, arg = "find", "right"
	end
	local handler = COMMANDS[verb]
	if handler ~= nil then
		handler(arg)
	end
end

function onConfigChanged()
	bin = configuredBin()
	noctalia.setUpdateInterval(pollIntervalMs())
	if not queryRunning then
		refresh()
	end
end

noctalia.state.watch(COMMAND_KEY, executeCommand)

noctalia.setUpdateInterval(pollIntervalMs())

function update()
	local now = nowMs()
	if queryRunning and now - queryStartedAt > 60000 then
		queryRunning = false
		noctalia.log("soundcore: query watchdog reset a stuck poll")
	end
	if commandRunning and now - commandStartedAt > 60000 then
		commandRunning = false
		queued = nil
		noctalia.log("soundcore: command watchdog reset a stuck command")
	end
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
	if force and not queryRunning and not commandRunning then
		refresh()
	elseif clearedStatus then
		publish()
	elseif not queryRunning and not commandRunning then
		refresh()
	end
end

refresh()
