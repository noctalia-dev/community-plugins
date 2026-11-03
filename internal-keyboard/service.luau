--!nonstrict
-- Internal Keyboard - headless service.
--
-- All switching lives in /usr/local/bin/internal-keyboard (installed by
-- setup.sh): it flips /run/internal-keyboard/disabled and re-announces the
-- keyboard to udev, so libinput stops or resumes delivering its events.
--
-- The UI only talks to this service through the plugin state:
--   "status"  <- { state, device, nodes, available }
--   "command" <- { action = "toggle" | "on" | "off" | "refresh" }
--
-- sudo -n never prompts: setup.sh grants NOPASSWD for the subcommands of that
-- one root-owned script.

local DEFAULT_BACKEND = "/usr/local/bin/internal-keyboard"
local MIN_INTERVAL = 500

local function log(message)
    noctalia.log(`internal-keyboard: {message}`)
end

local function trim(text)
    local value = tostring(text or "")
    value = value:gsub("^%s+", "")
    return (value:gsub("%s+$", ""))
end

local backend = noctalia.getConfig("backend") or DEFAULT_BACKEND
local interval = tonumber(noctalia.getConfig("poll_interval")) or 2000
if interval < MIN_INTERVAL then
    interval = MIN_INTERVAL
end
local show_osd = noctalia.getConfig("show_osd") ~= false
-- Empty means "keep whatever setup.sh selected".
local device_setting = trim(noctalia.getConfig("device") or "")

-- A missing backend would otherwise log on every poll; report each distinct
-- failure once and stay quiet until it changes.
local last_failure = nil

local function report_failure(message)
    if message == last_failure then
        return
    end
    last_failure = message
    log(message)
end

local function empty_status()
    return { state = "unknown", device = "", nodes = "", available = false }
end

local function parse(output)
    local status = empty_status()
    for line in (output or ""):gmatch("[^\r\n]+") do
        local key, value = line:match("^(%w+)=(.*)$")
        if key == "state" then
            status.state = value
        elseif key == "device" then
            status.device = value
        elseif key == "nodes" then
            status.nodes = value
        elseif key == "available" then
            status.available = value == "1"
        end
    end
    return status
end

local function unchanged(a, b)
    return a.state == b.state
        and a.device == b.device
        and a.nodes == b.nodes
        and a.available == b.available
end

-- Same shape as the volume and brightness popups: the keyboard glyph plus the
-- new state, muted while the keyboard is off.
local function announce(status)
    local off = status.state == "off"
    noctalia.osd.show(
        off and "keyboard-off" or "keyboard",
        noctalia.tr(off and "shortcut.state.off" or "shortcut.state.on"),
        { inactive = off }
    )
end

local status = empty_status()
local primed = false
local reconciled = false
local busy = false

-- Declared before use; both are defined further down because they call each
-- other's neighbours (refresh -> reconcile, reconcile -> call).
local call
local reconcile

local function publish(next)
    local previous = status
    if unchanged(next, previous) then
        return
    end
    status = next
    log(`state {next.state} (device="{next.device}", available={tostring(next.available)})`)
    noctalia.state.set("status", next)

    -- Skip the first publish so loading the plugin does not raise a popup; after
    -- that every real on/off flip gets one, including flips made in a TTY.
    if primed and show_osd and next.state ~= previous.state then
        announce(next)
    end
    primed = true
end

local function refresh()
    if busy then
        return
    end
    busy = true
    noctalia.runAsync({ backend, "status" }, function(result)
        busy = false
        if result.exitCode ~= 0 then
            report_failure(string.format("status failed: %s", trim(result.stderr)))
            publish(empty_status())
            return
        end
        last_failure = nil
        local next = parse(result.stdout)
        publish(next)
        reconcile(next)
    end)
end

local function warn_missing_backend()
    local hint = string.format(noctalia.tr("notify.setup.hint"), noctalia.pluginDir() or ".")
    noctalia.notifyError(noctalia.tr("notify.setup.title"), hint)
end

-- $1 = action, rest = extra arguments for the backend.
call = function(action, ...)
    if busy then
        return
    end
    if not noctalia.fileExists(backend) then
        warn_missing_backend()
        return
    end
    local argv = { "sudo", "-n", backend, action }
    for _, argument in ipairs({ ... }) do
        argv[#argv + 1] = argument
    end
    busy = true
    noctalia.runAsync(argv, function(result)
        busy = false
        if result.exitCode ~= 0 then
            local detail = trim(result.stderr)
            if detail == "" then
                detail = noctalia.tr("notify.failed.hint")
            end
            report_failure(string.format("%s failed: %s", action, detail))
            local title = action == "select" and noctalia.tr("notify.select.title")
                or noctalia.tr("notify.failed.title")
            noctalia.notifyError(title, detail)
        end
        refresh()
    end)
end

-- The device setting wins over whatever setup.sh chose. The service restarts on
-- every settings change, so checking once per load is enough.
reconcile = function(current)
    if reconciled then
        return
    end
    reconciled = true
    if device_setting == "" or current.device == device_setting then
        return
    end
    if not noctalia.fileExists(backend) then
        warn_missing_backend()
        return
    end
    call("select", device_setting)
end

noctalia.setUpdateInterval(interval)

-- The host calls this global once per update interval; without it the service
-- never polls, and the tile keeps showing whatever state it had at load.
function update()
    refresh()
end

noctalia.state.watch("command", function(command)
    if type(command) ~= "table" then
        return
    end
    local action = command.action
    if action == "on" or action == "off" or action == "toggle" then
        call(action)
    elseif action == "refresh" then
        refresh()
    end
end)

noctalia.state.set("status", status)
refresh()

-- Scripted use (the keybind command is shown in the README):
--   noctalia msg plugin goldesquemoon/internal-keyboard:service all toggle
function onIpc(event)
    if event == "toggle" or event == "on" or event == "off" then
        call(event)
    elseif event == "refresh" then
        refresh()
    end
end
