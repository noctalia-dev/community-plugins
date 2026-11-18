--!nonstrict
-- Keychron mouse battery backend. Reads Keychron mice from UPower on a timer,
-- publishes a snapshot for the widget and panel, and sends low/critical
-- notifications once per discharge (re-armed after charging or climbing back
-- above the threshold).
--
-- Mice on a receiver or cable show up in UPower through the keychron-battery
-- kernel module (power_supply "keychron_mouse"); Bluetooth mice through the
-- standard BLE battery service.

local SNAPSHOT_KEY = "keychron_snapshot"
local COMMAND_KEY = "keychron_command"
local HYSTERESIS = 5

-- While no battery level comes in, read UPower at least this often so the bar
-- recovers soon after the mouse or receiver is back.
local MISSING_POLL_S = 30

local running = false
local lastRun = 0
-- True while the last reading had no Keychron mouse with a battery level.
local missing = false
-- Per device id: "normal" | "low" | "critical".
local alertState = {}

local function intConfig(key, fallback)
	return tonumber(noctalia.getConfig(key)) or fallback
end

local function displayName(model)
	-- The kernel module reports a generic model name; prefer the configured one.
	local configured = noctalia.getConfig("mouse_name")
	if configured ~= nil and configured ~= "" then
		return configured
	end
	if model ~= "" then
		return model
	end
	return noctalia.tr("kind.mouse")
end

local function checkAlerts(device)
	local low = intConfig("low_threshold", 20)
	local critical = intConfig("critical_threshold", 10)
	local level = device.level
	if type(level) ~= "number" then
		return
	end
	local previous = alertState[device.id] or "normal"
	local state = previous
	if device.charging or level > low + HYSTERESIS then
		state = "normal"
	elseif level <= critical then
		state = "critical"
	elseif level <= low and previous == "normal" then
		state = "low"
	end
	alertState[device.id] = state
	if state == previous or state == "normal" or noctalia.getConfig("notify") == false then
		return
	end
	local subst = { name = device.displayName, level = tostring(level) }
	if state == "critical" then
		noctalia.notifyError(noctalia.tr("notify.critical_title", subst), noctalia.tr("notify.critical_body", subst))
	else
		noctalia.notify(noctalia.tr("notify.low_title", subst), noctalia.tr("notify.low_body", subst))
	end
end

-- One `upower --dump` block -> device table, or nil when it is not a Keychron mouse.
local function parseBlock(block)
	local path = block:match("^%s*Device:%s*(%S+)")
	if path == nil then
		return nil
	end
	local props = {}
	local isMouse = false
	for line in block:gmatch("[^\n]+") do
		local key, value = line:match("^%s*([%w%-%s]-):%s*(.-)%s*$")
		if key ~= nil then
			props[key] = value
		elseif noctalia.string.trim(line) == "mouse" then
			isMouse = true
		end
	end
	local nativePath = props["native-path"] or ""
	local ident = ((props.vendor or "") .. " " .. (props.model or "") .. " " .. nativePath):lower()
	if not ident:find("keychron", 1, true) then
		return nil
	end
	-- UPower lists the kernel module's battery under kind "keyboard", so match it
	-- by its power_supply name; Bluetooth mice come with kind "mouse".
	if not isMouse and not nativePath:find("keychron_mouse", 1, true) then
		return nil
	end
	local level = tonumber((props.percentage or ""):match("[%d%.]+"))
	if level ~= nil then
		level = math.floor(level + 0.5)
	end
	local state = props.state or ""
	local device = {
		id = path,
		model = props.model or "",
		connection = nativePath:find("keychron_mouse", 1, true) and "receiver" or "bluetooth",
		level = level,
		-- UPower also reports "fully-charged" for a mouse at 100% on the receiver,
		-- so only "charging" means it is on the cable.
		charging = state == "charging",
		available = level ~= nil and (props.present or "yes") ~= "no",
	}
	device.displayName = displayName(device.model)
	return device
end

local function publish(devices, err)
	missing = true
	for _, d in ipairs(devices) do
		if type(d.level) == "number" then
			missing = false
		end
	end
	noctalia.state.set(SNAPSHOT_KEY, { devices = devices, error = err or "", updatedAt = noctalia.nowMs() })
end

local function poll()
	if running then
		return
	end
	running = true
	lastRun = noctalia.nowMs()
	noctalia.runAsync({ "upower", "--dump" }, function(result)
		running = false
		if result.exitCode ~= 0 then
			publish({}, noctalia.tr("errors.upower"))
			return
		end
		local devices = {}
		local out = (result.stdout or "") .. "\n\n"
		for block in out:gmatch("(.-)\n%s*\n") do
			local device = parseBlock(block)
			if device ~= nil then
				checkAlerts(device)
				table.insert(devices, device)
			end
		end
		publish(devices, nil)
	end, 10000)
end

noctalia.state.watch(COMMAND_KEY, function(cmd)
	if type(cmd) == "table" and cmd.action == "refresh" then
		poll()
	end
end)

function onIpc(event, _payload)
	if event == "refresh" then
		poll()
	end
end

-- Tick every few seconds and read UPower once the configured interval passed,
-- so a changed poll_interval takes effect without a restart.
noctalia.setUpdateInterval(5000)

function update()
	local interval = intConfig("poll_interval", 60)
	if missing then
		interval = math.min(interval, MISSING_POLL_S)
	end
	if noctalia.nowMs() - lastRun >= interval * 1000 then
		poll()
	end
end

poll()
