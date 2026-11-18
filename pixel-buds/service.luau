--!nonstrict
-- Pixel Buds backend. The service is the single owner of every pbpctrl and
-- bluetoothctl subprocess. The widget and panel read the published snapshot and
-- send commands through the shared state channel, so nothing is spawned from
-- the UI VMs.
--
-- pbpctrl opens a fresh RFCOMM connection per call and the buds accept one at a
-- time, so every subprocess runs through a single serial queue.
--
-- Buds that advertise the Maestro service get the full feature set through
-- pbpctrl. Other Pixel Buds (A-Series and the like) only get the single
-- battery percentage BlueZ exposes, since nothing else on Linux can talk to them.

local SNAPSHOT_KEY = "pixelbuds_snapshot"
local COMMAND_KEY = "pixelbuds_command"

local LEVEL_UNKNOWN = -1
local LOW_LEVEL = 20

local MODEL_PRO = "pro"
local MODEL_PRO2 = "pro2"
local MODEL_OTHER = "other"

-- The classes pbpctrl itself looks for.
local PIXEL_BUDS_CLASSES = {
	["0x00240404"] = MODEL_PRO,
	["0x00244404"] = MODEL_PRO2,
}

local MAESTRO_UUID = "25e97ff7-24ce-4c4c-8951-f764a708f7b5"

-- The order the panel draws the modes and the right-click cycle walks them.
local ANC_MODES = { "off", "aware", "active" }

local EQ_MIN = -6
local EQ_MAX = 6
local EQ_BANDS = 5

local PBPCTRL_TIMEOUT_MS = 15000
local BLUETOOTHCTL_TIMEOUT_MS = 5000
local ACTION_STATUS_MS = 3000
-- Settings change rarely and only from this panel or the phone app, so they
-- are re-read on panel open and every few polls rather than every poll.
local SETTINGS_EVERY_N_POLLS = 6

local MAX_ERROR_CHARS = 140

local function defaultBud()
	return { level = LEVEL_UNKNOWN, charging = false, inCase = nil }
end

local function defaultSnapshot()
	return {
		pbpctrlFound = true,
		deviceFound = false,
		connected = false,
		reachable = false,
		address = "",
		deviceName = "",
		model = MODEL_OTHER,
		-- "full" talks Maestro through pbpctrl; "basic" only reads BlueZ's battery.
		mode = "full",
		supportsAdaptive = false,
		combined = defaultBud(),
		combinedText = "--",
		left = defaultBud(),
		right = defaultBud(),
		caseBattery = defaultBud(),
		leftText = "--",
		rightText = "--",
		caseText = "--",
		leftMeta = "",
		rightMeta = "",
		caseMeta = "",
		primaryText = "",
		primaryState = "normal",
		anc = "unknown",
		ancName = "",
		ancModes = {},
		ohd = nil,
		multipoint = nil,
		speechDetection = nil,
		eq = nil,
		busy = false,
		actionStatus = "",
		lastError = "",
		hasBuds = false,
	}
end

local snapshot = defaultSnapshot()

local function nowMs()
	return noctalia.nowMs()
end

---------------------------------------------------------------------------
-- Configuration
---------------------------------------------------------------------------

local function resolvePbpctrl()
	local p = noctalia.getConfig("pbpctrl_path")
	if p ~= nil and p ~= "" then
		return p
	end
	if noctalia.commandExists("pbpctrl") then
		return "pbpctrl"
	end
	-- `cargo install` puts it here, and ~/.cargo/bin is often missing from the
	-- PATH the compositor hands the shell.
	local home = noctalia.getenv("HOME") or ""
	local cargoBin = home .. "/.cargo/bin/pbpctrl"
	if home ~= "" and noctalia.fileExists(cargoBin) then
		return cargoBin
	end
	return nil
end

local pbpctrlPath = resolvePbpctrl()
snapshot.pbpctrlFound = pbpctrlPath ~= nil

local configuredAddress = noctalia.string.trim(tostring(noctalia.getConfig("device") or "")):upper()

local pollIntervalMs = math.max(2, tonumber(noctalia.getConfig("poll_interval")) or 5) * 1000

---------------------------------------------------------------------------
-- Output parsing
---------------------------------------------------------------------------

-- pbpctrl logs through tracing to stdout, so warnings such as a retried RFCOMM
-- connect land between the real output lines. Strip colour codes and drop any
-- line that starts with a log timestamp.
local function cleanLines(text)
	local lines = {}
	for line in (tostring(text or "") .. "\n"):gmatch("(.-)\r?\n") do
		line = line:gsub("\27%[[%d;]*m", "")
		if not line:match("^%d%d%d%d%-%d%d%-%d%dT") then
			table.insert(lines, line)
		end
	end
	return lines
end

local function lastValue(text)
	local lines = cleanLines(text)
	for i = #lines, 1, -1 do
		local v = noctalia.string.trim(lines[i])
		if v ~= "" then
			return v
		end
	end
	return ""
end

local function parseBattery(value)
	local bud = defaultBud()
	local lvl, state = value:match("^(%d+)%%%s*%((.-)%)")
	if lvl ~= nil then
		bud.level = tonumber(lvl)
		bud.charging = state == "charging"
	end
	return bud
end

-- `pbpctrl show runtime`:
--   battery:
--     case:      53% (not charging)
--     left bud:  100% (charging)
--   placement:
--     left bud:  in case
local function parseRuntime(text)
	local result = { left = defaultBud(), right = defaultBud(), caseBattery = defaultBud() }
	local section = ""
	for _, line in ipairs(cleanLines(text)) do
		local header = line:match("^(%a+):%s*$")
		if header ~= nil then
			section = header
		else
			local key, value = line:match("^%s+(%a[%a ]-):%s+(.-)%s*$")
			if key ~= nil then
				local target = nil
				if key == "case" then
					target = "caseBattery"
				elseif key == "left bud" then
					target = "left"
				elseif key == "right bud" then
					target = "right"
				end
				if target ~= nil and section == "battery" then
					local bud = parseBattery(value)
					result[target].level = bud.level
					result[target].charging = bud.charging
				elseif target ~= nil and section == "placement" then
					if value == "in case" then
						result[target].inCase = true
					elseif value == "out of case" then
						result[target].inCase = false
					end
				end
			end
		end
	end
	return result
end

local function parseBool(text)
	local v = lastValue(text)
	if v == "true" then
		return true
	end
	if v == "false" then
		return false
	end
	return nil
end

-- `pbpctrl get eq`: [-2.00, 0.00, 2.00, 3.00, 5.00]
local function parseEq(text)
	local v = lastValue(text)
	if v:sub(1, 1) ~= "[" then
		return nil
	end
	local bands = {}
	for num in v:gmatch("-?%d+%.?%d*") do
		table.insert(bands, tonumber(num))
	end
	if #bands ~= EQ_BANDS then
		return nil
	end
	return bands
end

local function parseAnc(text)
	local v = lastValue(text)
	if v == "off" or v == "active" or v == "aware" or v == "adaptive" then
		return v
	end
	return "unknown"
end

local function elideError(text)
	local lines = cleanLines(text)
	local msg = ""
	for _, line in ipairs(lines) do
		local t = noctalia.string.trim(line)
		if t ~= "" then
			msg = t
		end
	end
	msg = msg:gsub("^Error:%s*", ""):gsub("%s+", " ")
	if #msg > MAX_ERROR_CHARS then
		return msg:sub(1, MAX_ERROR_CHARS - 1) .. "…"
	end
	return msg
end

---------------------------------------------------------------------------
-- Snapshot publishing
---------------------------------------------------------------------------

local function levelText(level)
	if level == nil or level == LEVEL_UNKNOWN then
		return "--"
	end
	return tostring(level) .. "%"
end

local function budMeta(bud, isCase)
	if bud.charging then
		return noctalia.tr("panel.charging")
	end
	if not isCase and bud.inCase == true then
		return noctalia.tr("panel.in_case")
	end
	if not isCase and bud.inCase == false then
		return noctalia.tr("panel.out_of_case")
	end
	return ""
end

local function ancName(mode)
	if mode == "off" or mode == "active" or mode == "aware" or mode == "adaptive" then
		return noctalia.tr("panel.anc." .. mode)
	end
	return noctalia.tr("panel.anc.unknown")
end

local function availableAncModes()
	local modes = {}
	for _, m in ipairs(ANC_MODES) do
		table.insert(modes, m)
	end
	-- Adaptive is a Pro 2 mode. Also offer it when buds of an unexpected class
	-- report it, so the selected row is never missing.
	if snapshot.supportsAdaptive or snapshot.anc == "adaptive" then
		table.insert(modes, "adaptive")
	end
	return modes
end

local actionStatus = ""
local actionStatusDeadline = 0
local running = false

local function publish()
	snapshot.busy = running
	snapshot.actionStatus = actionStatus
	snapshot.hasBuds = snapshot.connected and snapshot.reachable

	snapshot.leftText = levelText(snapshot.left.level)
	snapshot.rightText = levelText(snapshot.right.level)
	snapshot.caseText = levelText(snapshot.caseBattery.level)
	snapshot.leftMeta = budMeta(snapshot.left, false)
	snapshot.rightMeta = budMeta(snapshot.right, false)
	snapshot.caseMeta = budMeta(snapshot.caseBattery, true)
	snapshot.combinedText = levelText(snapshot.combined.level)
	snapshot.ancName = ancName(snapshot.anc)

	local modes = {}
	for _, m in ipairs(availableAncModes()) do
		table.insert(modes, { value = m, label = ancName(m) })
	end
	snapshot.ancModes = modes

	-- The bar shows the emptier bud that is out of the case, since that is the
	-- one about to run out; buds in the case are charging anyway.
	local primary = nil
	for _, bud in ipairs({ snapshot.left, snapshot.right }) do
		if bud.level ~= LEVEL_UNKNOWN and bud.inCase ~= true then
			if primary == nil or bud.level < primary.level then
				primary = bud
			end
		end
	end
	if primary == nil then
		for _, bud in ipairs({ snapshot.left, snapshot.right }) do
			if bud.level ~= LEVEL_UNKNOWN and (primary == nil or bud.level < primary.level) then
				primary = bud
			end
		end
	end
	if primary == nil and snapshot.caseBattery.level ~= LEVEL_UNKNOWN then
		primary = snapshot.caseBattery
	end
	if primary == nil and snapshot.combined.level ~= LEVEL_UNKNOWN then
		primary = snapshot.combined
	end

	if primary == nil then
		snapshot.primaryText = ""
		snapshot.primaryState = "normal"
	else
		snapshot.primaryText = levelText(primary.level)
		if primary.charging then
			snapshot.primaryState = "charging"
		elseif primary.level <= LOW_LEVEL then
			snapshot.primaryState = "low"
		else
			snapshot.primaryState = "normal"
		end
	end

	noctalia.state.set(SNAPSHOT_KEY, snapshot)
end

local function setActionStatus(msg)
	actionStatus = msg
	actionStatusDeadline = nowMs() + ACTION_STATUS_MS
end

local function markDisconnected()
	snapshot.connected = false
	snapshot.reachable = false
	snapshot.left = defaultBud()
	snapshot.right = defaultBud()
	snapshot.caseBattery = defaultBud()
	snapshot.combined = defaultBud()
	snapshot.anc = "unknown"
end

---------------------------------------------------------------------------
-- Serial job queue
---------------------------------------------------------------------------

-- Writes go to the front so a click is not stuck behind a poll. A write keyed
-- to a field replaces any queued write to the same field, which is what a
-- slider drag produces.
local queue = {}

-- Bumped on every write. A read that started before the latest write to its
-- field carries stale data and is ignored.
local fieldVersion = {}

local runNext

local function enqueue(job, front)
	-- A read already waiting will publish the same data, so do not queue it twice.
	if job.writeKey == nil and job.kind ~= "discover" then
		for _, queued in ipairs(queue) do
			if queued.kind == job.kind then
				return
			end
		end
	end
	if job.writeKey ~= nil then
		for i, queued in ipairs(queue) do
			if queued.writeKey == job.writeKey then
				queue[i] = job
				runNext()
				return
			end
		end
	end
	if front then
		local at = 1
		-- Keep earlier writes ahead of this one so they apply in click order.
		while queue[at] ~= nil and queue[at].writeKey ~= nil do
			at += 1
		end
		table.insert(queue, at, job)
	else
		table.insert(queue, job)
	end
	runNext()
end

local function queuedReads(kind)
	for _, job in ipairs(queue) do
		if job.kind == kind then
			return true
		end
	end
	return false
end

runNext = function()
	if running or #queue == 0 then
		return
	end
	local job = table.remove(queue, 1)
	if job.prepare ~= nil then
		job.prepare()
	end
	running = true
	local startVersion = job.field ~= nil and (fieldVersion[job.field] or 0) or nil
	noctalia.runAsync(job.argv, function(result)
		running = false
		local fresh = job.field == nil or (fieldVersion[job.field] or 0) == startVersion
		job.done(result, fresh)
		publish()
		runNext()
	end, job.timeout or PBPCTRL_TIMEOUT_MS)
end

local function pbpctrlArgv(...)
	local argv = { pbpctrlPath }
	if snapshot.address ~= "" then
		table.insert(argv, "-d")
		table.insert(argv, snapshot.address)
	end
	for _, a in ipairs({ ... }) do
		table.insert(argv, a)
	end
	return argv
end

---------------------------------------------------------------------------
-- Reads
---------------------------------------------------------------------------

local function pbpctrlFailed(result)
	-- A failed read while BlueZ says the buds are connected usually means they
	-- are asleep in the closed case; keep the connection flag, drop the data.
	snapshot.reachable = false
	snapshot.lastError = elideError(result.stderr ~= "" and result.stderr or result.stdout)
end

local function readRuntime()
	enqueue({
		kind = "runtime",
		argv = pbpctrlArgv("show", "runtime"),
		done = function(result)
			if result.exitCode ~= 0 then
				pbpctrlFailed(result)
				return
			end
			local rt = parseRuntime(result.stdout)
			snapshot.left = rt.left
			snapshot.right = rt.right
			snapshot.caseBattery = rt.caseBattery
			snapshot.reachable = true
			snapshot.lastError = ""
		end,
	})
end

local function readAnc()
	enqueue({
		kind = "anc",
		field = "anc",
		argv = pbpctrlArgv("get", "anc"),
		done = function(result, fresh)
			if result.exitCode == 0 and fresh then
				snapshot.anc = parseAnc(result.stdout)
			end
		end,
	})
end

local function readBoolSetting(kind, field, setting)
	enqueue({
		kind = kind,
		field = field,
		argv = pbpctrlArgv("get", setting),
		done = function(result, fresh)
			if result.exitCode == 0 and fresh then
				snapshot[field] = parseBool(result.stdout)
			end
		end,
	})
end

local function readSettings()
	if queuedReads("settings-eq") then
		return
	end
	readBoolSetting("settings-ohd", "ohd", "ohd")
	readBoolSetting("settings-multipoint", "multipoint", "multipoint")
	readBoolSetting("settings-speech", "speechDetection", "speech-detection")
	enqueue({
		kind = "settings-eq",
		field = "eq",
		argv = pbpctrlArgv("get", "eq"),
		done = function(result, fresh)
			if result.exitCode == 0 and fresh then
				snapshot.eq = parseEq(result.stdout)
			end
		end,
	})
end

-- `bluetoothctl info <addr>` lists Name, Alias, Class, Connected, one UUID
-- line per service and, when BlueZ has a battery provider for the device,
-- "Battery Percentage: 0x64 (100)", all as "\tKey: value" lines.
local function parseInfo(text)
	local info = { uuids = {} }
	for line in (tostring(text or "") .. "\n"):gmatch("(.-)\r?\n") do
		local key, value = line:match("^%s+(%a[%a ]-):%s*(.-)%s*$")
		if key == "UUID" then
			local uuid = value:match("%((%x+%-%x+%-%x+%-%x+%-%x+)%)")
			if uuid ~= nil then
				info.uuids[uuid:lower()] = true
			end
		elseif key ~= nil and info[key] == nil then
			info[key] = value
		end
	end
	return info
end

local function modelOf(info)
	local class = (info.Class or ""):match("^(0x%x+)")
	if class ~= nil and PIXEL_BUDS_CLASSES[class:lower()] ~= nil then
		return PIXEL_BUDS_CLASSES[class:lower()]
	end
	return MODEL_OTHER
end

-- Pro models match by class, the rest by Google's Bluetooth vendor id (0x00E0)
-- on an audio device, and finally by the default name.
local function isPixelBuds(info)
	if modelOf(info) ~= MODEL_OTHER then
		return true
	end
	local google = (info.Modalias or ""):lower():match("^bluetooth:v00e0p") ~= nil
	local audio = (info.Icon or ""):match("^audio%-") ~= nil
	if google and audio then
		return true
	end
	local name = (info.Name or ""):lower()
	return name:find("pixel buds", 1, true) ~= nil
end

local function batteryPercentage(info)
	local pct = (info["Battery Percentage"] or ""):match("%((%d+)%)")
	return pct ~= nil and tonumber(pct) or LEVEL_UNKNOWN
end

local pollCount = 0
local afterConnect

local function applyInfo(info)
	local wasConnected = snapshot.connected
	snapshot.deviceFound = true
	snapshot.deviceName = info.Alias or info.Name or ""
	snapshot.model = modelOf(info)
	snapshot.supportsAdaptive = snapshot.model == MODEL_PRO2
	-- The class already proves a Pro; the UUID check catches Maestro buds of a
	-- class pbpctrl does not know yet. BlueZ can list no UUIDs before the first
	-- service discovery, so the class wins over a missing UUID.
	local maestro = snapshot.model ~= MODEL_OTHER or info.uuids[MAESTRO_UUID] == true
	snapshot.mode = maestro and "full" or "basic"
	if info.Connected ~= "yes" then
		markDisconnected()
		return
	end
	snapshot.connected = true
	if snapshot.mode == "basic" then
		snapshot.combined = { level = batteryPercentage(info), charging = false, inCase = nil }
		snapshot.reachable = true
		return
	end
	if pbpctrlPath == nil then
		snapshot.reachable = false
		return
	end
	readRuntime()
	readAnc()
	if not wasConnected then
		afterConnect()
	end
end

local function pollDevice()
	enqueue({
		kind = "info",
		argv = { "bluetoothctl", "info", snapshot.address },
		timeout = BLUETOOTHCTL_TIMEOUT_MS,
		done = function(result)
			if result.exitCode ~= 0 then
				-- Unpaired or removed: look for it again next poll.
				if configuredAddress == "" then
					snapshot.address = ""
				end
				snapshot.deviceFound = false
				markDisconnected()
				return
			end
			applyInfo(parseInfo(result.stdout))
		end,
	})
end

-- Walk the paired devices and keep the first Pixel Buds by Bluetooth class,
-- which survives the user renaming the buds.
local function discover()
	enqueue({
		kind = "discover",
		argv = { "bluetoothctl", "devices" },
		timeout = BLUETOOTHCTL_TIMEOUT_MS,
		done = function(result)
			local addresses = {}
			for addr in tostring(result.stdout or ""):gmatch("Device%s+(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)") do
				table.insert(addresses, addr)
			end
			if #addresses == 0 then
				snapshot.deviceFound = false
				markDisconnected()
				return
			end
			local function check(i)
				if i > #addresses then
					snapshot.deviceFound = false
					markDisconnected()
					return
				end
				enqueue({
					kind = "discover",
					argv = { "bluetoothctl", "info", addresses[i] },
					timeout = BLUETOOTHCTL_TIMEOUT_MS,
					done = function(r)
						local info = parseInfo(r.stdout)
						if r.exitCode == 0 and isPixelBuds(info) then
							snapshot.address = addresses[i]
							applyInfo(info)
						else
							check(i + 1)
						end
					end,
				})
			end
			check(1)
		end,
	})
end

local function poll()
	-- Skip a tick rather than pile up behind a slow (retrying) pbpctrl.
	if running or #queue > 0 then
		return
	end
	pollCount += 1
	if snapshot.address == "" then
		discover()
	else
		pollDevice()
	end
	if snapshot.connected and snapshot.mode == "full" and pbpctrlPath ~= nil
		and pollCount % SETTINGS_EVERY_N_POLLS == 0 then
		readSettings()
	end
end

afterConnect = function()
	if snapshot.mode == "full" and pbpctrlPath ~= nil then
		readSettings()
	end
end

local function refresh()
	if snapshot.address == "" then
		discover()
		return
	end
	pollDevice()
	if snapshot.connected and snapshot.mode == "full" and pbpctrlPath ~= nil then
		readSettings()
	end
end

---------------------------------------------------------------------------
-- Writes
---------------------------------------------------------------------------

local function write(field, optimistic, previous, args, label)
	if not snapshot.hasBuds or snapshot.mode ~= "full" then
		return
	end
	fieldVersion[field] = (fieldVersion[field] or 0) + 1
	snapshot[field] = optimistic
	publish()
	enqueue({
		writeKey = field,
		argv = pbpctrlArgv(table.unpack(args)),
		done = function(result)
			if result.exitCode ~= 0 then
				-- Roll back and re-read so the control shows the buds' own value.
				snapshot[field] = previous
				fieldVersion[field] = (fieldVersion[field] or 0) + 1
				local msg = elideError(result.stderr ~= "" and result.stderr or result.stdout)
				if msg == "" then
					msg = noctalia.tr("errors.write_failed") .. ": " .. label
				end
				setActionStatus(msg)
				if field == "anc" then
					readAnc()
				end
			end
		end,
	}, true)
end

local function setAnc(mode)
	for _, m in ipairs(availableAncModes()) do
		if m == mode then
			write("anc", mode, snapshot.anc, { "set", "anc", mode }, noctalia.tr("panel.noise_control"))
			return
		end
	end
end

local function cycleAnc()
	if not snapshot.hasBuds then
		return
	end
	local modes = availableAncModes()
	local at = 0
	for i, m in ipairs(modes) do
		if m == snapshot.anc then
			at = i
			break
		end
	end
	setAnc(at == 0 and modes[1] or modes[(at % #modes) + 1])
end

local function setBool(field, setting, value, label)
	write(field, value == true, snapshot[field], { "set", setting, value == true and "true" or "false" }, label)
end

local function formatBand(v)
	return string.format("%.2f", v)
end

local function setEqBand(band, value)
	if type(snapshot.eq) ~= "table" then
		return
	end
	local i = tonumber(band)
	local v = tonumber(value)
	if i == nil or v == nil or i < 1 or i > EQ_BANDS then
		return
	end
	local bands = table.clone(snapshot.eq)
	bands[i] = math.max(EQ_MIN, math.min(EQ_MAX, v))
	-- "--" keeps clap from reading a negative gain as a flag.
	local args = { "set", "eq", "--" }
	for _, b in ipairs(bands) do
		table.insert(args, formatBand(b))
	end
	write("eq", bands, snapshot.eq, args, noctalia.tr("panel.eq"))
end

local function resetEq()
	if type(snapshot.eq) ~= "table" then
		return
	end
	local flat = { 0, 0, 0, 0, 0 }
	local args = { "set", "eq", "--" }
	for _, b in ipairs(flat) do
		table.insert(args, formatBand(b))
	end
	write("eq", flat, snapshot.eq, args, noctalia.tr("panel.eq"))
end

---------------------------------------------------------------------------
-- Entry points
---------------------------------------------------------------------------

local function executeCommand(cmd)
	if type(cmd) ~= "table" or type(cmd.action) ~= "string" then
		return
	end
	local action = cmd.action
	if action == "refresh" then
		refresh()
	elseif action == "cycle-anc" then
		cycleAnc()
	elseif action == "set-anc" then
		setAnc(tostring(cmd.value))
	elseif action == "set-ohd" then
		setBool("ohd", "ohd", cmd.value, noctalia.tr("panel.ohd"))
	elseif action == "set-multipoint" then
		setBool("multipoint", "multipoint", cmd.value, noctalia.tr("panel.multipoint"))
	elseif action == "set-speech" then
		setBool("speechDetection", "speech-detection", cmd.value, noctalia.tr("panel.speech_detection"))
	elseif action == "set-eq" and type(cmd.value) == "table" then
		setEqBand(cmd.value.band, cmd.value.value)
	elseif action == "reset-eq" then
		resetEq()
	end
end

function onIpc(event, _payload)
	if event == "cycle-anc" then
		cycleAnc()
	elseif event == "refresh" then
		refresh()
	elseif event == "anc-off" or event == "anc-aware" or event == "anc-active" then
		setAnc(event:sub(5))
	end
end

noctalia.state.watch(COMMAND_KEY, executeCommand)

noctalia.setUpdateInterval(pollIntervalMs)

function update()
	if actionStatus ~= "" and nowMs() > actionStatusDeadline then
		actionStatus = ""
		publish()
	end
	poll()
end

if configuredAddress ~= "" then
	snapshot.address = configuredAddress
end
publish()
poll()
