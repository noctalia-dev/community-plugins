--!nonstrict
-- Bar widget: battery of a Keychron mouse (M3 mini 4K) on its 4K Link
-- receiver. Runs keychron-query.py off-thread; the helper prints
-- "<percent> <state>" plus key=value receiver lines, or exits non-zero
-- (2 no receiver, 3 no permission, 4 mouse off/asleep).
--
-- The mouse falls asleep within minutes, so a missing answer keeps the last
-- reading on screen (dimmed, with its age in the tooltip) for keep_last
-- minutes instead of making the widget flicker. Setup problems (no udev
-- permission, helper crash) always stay visible.

local common = require("./common.luau")

local helper = (noctalia.pluginDir() or ".") .. "/keychron-query.py"
local STATE_FILE = "mouse"
local ERRORS = { [2] = "mouse.errors.no_receiver", [3] = "mouse.errors.no_permission", [4] = "mouse.errors.no_answer" }
local SETUP_ERRORS = { ["mouse.errors.no_permission"] = true, ["mouse.errors.helper"] = true }

local running = false
local lastRun = -math.huge
local level = nil
local charging = false
local seenAt = nil -- os.time() of the last successful reading
local fresh = false -- the last query answered
local errorKey = nil
local receiver = {}

local saved = common.loadState(STATE_FILE)
if saved and tonumber(saved.level) and tonumber(saved.seen_at) then
	level = tonumber(saved.level)
	charging = saved.charging == "1"
	seenAt = tonumber(saved.seen_at)
end

local function settings()
	return {
		pollInterval = common.int(noctalia.getConfig("poll_interval"), 60),
		lowThreshold = common.int(noctalia.getConfig("low_threshold"), 20),
		keepLast = common.int(noctalia.getConfig("keep_last"), 60),
		hideWhenUnavailable = common.bool(noctalia.getConfig("hide_when_unavailable"), true),
		notifyLow = common.bool(noctalia.getConfig("notify_low"), true),
		notifyFull = common.bool(noctalia.getConfig("notify_full"), false),
		batteryGlyph = common.bool(noctalia.getConfig("battery_glyph"), false),
		iconOnly = common.bool(noctalia.getConfig("icon_only"), false),
	}
end

local function deviceName()
	return noctalia.tr("mouse.name")
end

local function keepLast(cfg)
	return seenAt ~= nil and os.time() - seenAt <= cfg.keepLast * 60
end

local function render()
	local cfg = settings()
	if errorKey and SETUP_ERRORS[errorKey] then
		barWidget.setVisible(true)
		barWidget.setGlyph("alert-triangle")
		barWidget.setText(cfg.iconOnly and "" or "!")
		common.setRole("error")
		barWidget.setTooltip(noctalia.tr(errorKey))
		return
	end

	local showLevel = level ~= nil and (fresh or keepLast(cfg))
	if not showLevel then
		barWidget.setVisible(not cfg.hideWhenUnavailable)
		common.present(cfg, "mouse", nil, false, "--")
		common.setRole("")
		barWidget.setTooltip(noctalia.tr(errorKey or "mouse.errors.no_answer"))
		return
	end

	barWidget.setVisible(true)
	local isCharging = charging and fresh
	common.present(cfg, "mouse", level, isCharging, `{level}%`)

	local isLow = level <= cfg.lowThreshold and not isCharging
	if isLow then
		common.setRole("error")
	elseif not fresh then
		common.setRole("on_surface_variant")
	else
		common.setRole("")
	end

	local status
	if fresh then
		status = noctalia.tr(charging and "common.charging" or "common.discharging")
	else
		status = noctalia.tr("common.last_seen", { age = common.formatAge(seenAt) })
	end
	local rows = { { key = deviceName(), value = `{level}% · {status}` } }
	if not fresh then
		table.insert(rows, { key = noctalia.tr("mouse.state"), value = noctalia.tr(errorKey or "mouse.errors.no_answer") })
	end
	if receiver.receiver then
		local fw = receiver.receiver_fw and ` · {noctalia.tr("mouse.firmware")} {receiver.receiver_fw}` or ""
		table.insert(rows, { key = noctalia.tr("mouse.receiver"), value = receiver.receiver .. fw })
	end
	barWidget.setTooltip(rows)
end

local function onResult(result)
	running = false
	local out = result.stdout or ""
	local pct, state = out:match("^(%d+)%s+(%d+)")
	if result.exitCode == 0 and pct ~= nil then
		level = tonumber(pct)
		charging = tonumber(state) ~= 0
		seenAt = os.time()
		fresh = true
		errorKey = nil
		receiver = {}
		for key, value in out:gmatch("\n([%w_]+)=([^\n]*)") do
			receiver[key] = value
		end
		common.saveState(STATE_FILE, { level = level, charging = charging and 1 or 0, seen_at = seenAt })
		common.checkAlerts(settings(), "mouse", deviceName(), level, charging)
	else
		fresh = false
		errorKey = ERRORS[result.exitCode] or "mouse.errors.helper"
		if result.exitCode == 2 then
			-- Receiver unplugged: the old reading says nothing anymore.
			level = nil
		end
		if errorKey == "mouse.errors.helper" then
			noctalia.log(`keychron-query failed ({result.exitCode}): {result.stderr}`)
		end
	end
	render()
end

local function poll()
	if running then
		return
	end
	running = true
	lastRun = noctalia.nowMs()
	noctalia.runAsync({ "python3", "-I", helper }, onResult, 5000)
end

-- Poll faster while charging or low, so the full / low state shows up soon.
local function interval()
	local cfg = settings()
	local base = cfg.pollInterval
	local low = level ~= nil and level <= cfg.lowThreshold
	if fresh and (charging or low) then
		return math.max(10, base // 4)
	end
	return base
end

-- Tick every few seconds and query once the interval passed, so a changed
-- poll_interval takes effect without a reload. The tick also ages the
-- "last seen" tooltip and drops a stale reading after keep_last minutes.
noctalia.setUpdateInterval(5000)

function update()
	if noctalia.nowMs() - lastRun >= interval() * 1000 then
		poll()
	elseif not fresh then
		render()
	end
end

function onClick()
	poll()
end

function onIpc(event, _payload)
	if event == "refresh" then
		poll()
	end
end

render()
poll()
