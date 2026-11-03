--!nonstrict
-- Screen Mirror - headless service.
--
-- Bridges the plugin settings to the `niri-mirror` daemon and back:
--   settings  -> ~/.config/niri-mirror/config.json  (daemon reads it)
--   command   <- state file -> noctalia.state "status" -> tile / widget
--
-- The daemon does the real work (niri event stream, wl-mirror lifecycle), so
-- this service never touches wl-mirror or outputs: it writes the settings,
-- asks the daemon to reload, and mirrors the daemon's state file into
-- noctalia.state.
--
-- status = { installed, running, enabled, source, targets, outputs, focused, error }

local CONFIG_FILE = "~/.config/niri-mirror/config.json"
local CONFIG_DIR = "~/.config/niri-mirror"

-- First existing path wins; the plugin ships no daemon of its own.
local DAEMON_CANDIDATES = {
    "~/.local/bin/niri-mirror",
    "/usr/local/bin/niri-mirror",
    "/usr/bin/niri-mirror",
}

local MIN_INTERVAL = 500
local interval = tonumber(noctalia.getConfig("poll_interval")) or 2000
if interval < MIN_INTERVAL then
    interval = MIN_INTERVAL
end
-- A state file older than this means the daemon is gone (or never started).
local STALE_AFTER = math.ceil(interval / 1000) * 3 + 15

local function log(message)
    noctalia.log(`screen-mirror: {message}`)
end

local function trim(text)
    local value = tostring(text or "")
    value = value:gsub("^%s+", "")
    return (value:gsub("%s+$", ""))
end

local function setting(key, default)
    local value = noctalia.getConfig(key)
    if value == nil then
        return default
    end
    return value
end

-- ── daemon discovery ────────────────────────────────────────────────────────

local daemonPath = nil

local function resolveDaemon()
    if daemonPath and noctalia.fileExists(daemonPath) then
        return daemonPath
    end
    daemonPath = nil
    for _, candidate in ipairs(DAEMON_CANDIDATES) do
        local full = noctalia.expandPath(candidate)
        if noctalia.fileExists(full) then
            daemonPath = full
            return daemonPath
        end
    end
    return nil
end

local function runDaemon(args, onDone)
    local bin = resolveDaemon()
    if not bin then
        return false
    end
    local argv = { bin }
    for _, arg in ipairs(args) do
        table.insert(argv, arg)
    end
    return noctalia.runAsync(argv, onDone)
end

-- ── settings -> config.json ─────────────────────────────────────────────────

local function jsonString(text)
    local escaped = tostring(text or ""):gsub("\\", "\\\\"):gsub('"', '\\"')
    escaped = escaped:gsub("[\r\n\t]", " ")
    return escaped
end

local function contains(list, value)
    for _, item in ipairs(list) do
        if item == value then
            return true
        end
    end
    return false
end

-- string_list (or a comma separated string) -> plain list of names.
local function listSetting(key)
    local value = noctalia.getConfig(key)
    local list = {}
    if type(value) == "table" then
        for _, item in ipairs(value) do
            item = trim(item)
            if item ~= "" then
                table.insert(list, item)
            end
        end
    elseif type(value) == "string" then
        for item in (value .. ","):gmatch("([^,]*),") do
            item = trim(item)
            if item ~= "" then
                table.insert(list, item)
            end
        end
    end
    return list
end

local function jsonList(values)
    local items = {}
    if type(values) == "table" then
        for _, value in ipairs(values) do
            local text = trim(value)
            if text ~= "" then
                table.insert(items, '"' .. jsonString(text) .. '"')
            end
        end
    elseif type(values) == "string" then
        for value in (values .. ","):gmatch("([^,]*),") do
            local text = trim(value)
            if text ~= "" then
                table.insert(items, '"' .. jsonString(text) .. '"')
            end
        end
    end
    return "[" .. table.concat(items, ", ") .. "]"
end

local function writeConfig()
    local enabledOnStart = setting("enabled_on_start", true) ~= false
    local showOsd = setting("show_osd", true) ~= false
    local scaling = trim(setting("scaling", "fit"))

    local source = trim(setting("source_output", ""))
    local excluded = listSetting("excluded_outputs")

    local lines = {
        '  "enabled_on_start": ' .. tostring(enabledOnStart),
        '  "show_osd": ' .. tostring(showOsd),
        '  "feedback": "' .. (showOsd and "auto" or "never") .. '"',
        '  "source_output": "' .. (source == "" and "auto" or jsonString(source)) .. '"',
        '  "excluded_outputs": ' .. jsonList(excluded),
        '  "scaling": "' .. jsonString(scaling) .. '"',
    }
    local content = "{\n" .. table.concat(lines, ",\n") .. "\n}\n"

    noctalia.mkdirAll(noctalia.expandPath(CONFIG_DIR))
    local ok, err = noctalia.writeFile(noctalia.expandPath(CONFIG_FILE), content)
    if not ok then
        log(`could not write {CONFIG_FILE}: {tostring(err)}`)
    end
    return ok
end

-- ── daemon state file -> status ─────────────────────────────────────────────

local function statePath()
    local runtime = noctalia.getenv("XDG_RUNTIME_DIR") or "/tmp"
    return runtime .. "/niri-mirror/state"
end

local function readState()
    local text = noctalia.readFile(statePath())
    if not text then
        return nil
    end
    local parsed = {
        enabled = false,
        source = "",
        focused = "",
        outputs = "",
        targets = "",
        mirroring = "",
        updated = 0,
    }
    for line in text:gmatch("[^\r\n]+") do
        local key, value = line:match("^([%w_]+)=(.*)$")
        if key == "enabled" then
            parsed.enabled = value == "1"
        elseif key == "updated" then
            parsed.updated = tonumber(value) or 0
        elseif key == "source" or key == "focused" or key == "outputs"
            or key == "targets" or key == "mirroring" then
            parsed[key] = value
        end
    end
    return parsed
end

local status = {
    installed = false,
    running = false,
    enabled = false,
    source = "",
    targets = "",
    outputs = "",
    focused = "",
    error = "",
}

local function publish(next)
    local changed = false
    for key, value in pairs(next) do
        if status[key] ~= value then
            changed = true
            break
        end
    end
    if not changed then
        return
    end
    status = next
    noctalia.state.set("status", next)
end

local function unavailable(reason)
    return {
        installed = false,
        running = false,
        enabled = false,
        source = "",
        targets = "",
        outputs = "",
        focused = "",
        error = reason,
    }
end

-- ── sync: settings -> daemon ────────────────────────────────────────────────

local lastSyncMs = -1e9
local lastEnsureMs = -1e9
local lastReportedError = nil

local function reportOnce(message)
    if message == lastReportedError then
        return
    end
    lastReportedError = message
    noctalia.notifyError(noctalia.tr("notify.failed.title"), message)
end

local function sync(force)
    writeConfig()
    local bin = resolveDaemon()
    if not bin then
        publish(unavailable(noctalia.tr("notify.missing.body")))
        reportOnce(noctalia.tr("notify.missing.body"))
        return
    end
    local now = noctalia.nowMs()
    if not force and (now - lastSyncMs) < 1500 then
        return
    end
    lastSyncMs = now
    -- `ensure` starts the daemon when it is missing (respecting
    -- enabled_on_start), `reload` pushes the freshly written config into an
    -- already running one. Sequential, so the second waits for the socket.
    local command = string.format("'%s' ensure; '%s' reload", bin, bin)
    noctalia.runAsync({ "sh", "-c", command }, function(result)
        if result.exitCode ~= 0 then
            local detail = trim(result.stderr)
            log(`sync failed: {detail}`)
            reportOnce(detail ~= "" and detail or noctalia.tr("notify.failed.body"))
        else
            lastReportedError = nil
        end
        poll()
    end)
end

local function ensureDaemon()
    local now = noctalia.nowMs()
    if (now - lastEnsureMs) < 10000 then
        return
    end
    lastEnsureMs = now
    runDaemon({ "ensure" }, function(result)
        if result.exitCode ~= 0 then
            log(`ensure failed: {trim(result.stderr)}`)
        end
    end)
end

-- ── poll: daemon -> status ──────────────────────────────────────────────────

function poll()
    local bin = resolveDaemon()
    if not bin then
        publish(unavailable(noctalia.tr("notify.missing.body")))
        return
    end
    local state = readState()
    if not state or (os.time() - state.updated) > STALE_AFTER then
        publish({
            installed = true,
            running = false,
            enabled = false,
            source = "",
            targets = "",
            outputs = "",
            focused = "",
            error = noctalia.tr("widget.tooltip.stopped"),
        })
        ensureDaemon()
        return
    end
    publish({
        installed = true,
        running = true,
        enabled = state.enabled,
        source = state.source,
        targets = state.targets,
        outputs = state.outputs,
        focused = state.focused,
        error = "",
    })
end

local function runAction(action, onDone)
    if not resolveDaemon() then
        publish(unavailable(noctalia.tr("notify.missing.body")))
        reportOnce(noctalia.tr("notify.missing.body"))
        return
    end
    runDaemon({ action }, function(result)
        if result.exitCode ~= 0 then
            local detail = trim(result.stderr)
            log(`${action} failed: {detail}`)
            reportOnce(detail ~= "" and detail or noctalia.tr("notify.failed.body"))
        end
        poll()
        if onDone then
            onDone()
        end
    end)
end

-- ── wiring ─────────────────────────────────────────────────────────────────

noctalia.setUpdateInterval(interval)
noctalia.state.set("status", status)

noctalia.state.watch("command", function(command)
    if type(command) ~= "table" then
        return
    end
    local action = command.action
    if action == "on" or action == "off" or action == "toggle" then
        runAction(action)
    elseif action == "refresh" then
        poll()
    elseif action == "sync" then
        sync(true)
    end
end)

-- Manual trigger, useful for keybinds and for testing the state channel:
--   noctalia msg plugin goldesquemoon/screen-mirror:state all toggle
function onIpc(event)
    if event == "on" or event == "off" or event == "toggle" then
        runAction(event)
    elseif event == "refresh" then
        poll()
    elseif event == "sync" or event == "reload" then
        sync(true)
    end
end

-- Settings edited in the plugin settings page.
function onConfigChanged()
    sync(true)
end

-- Plugin (re)enabled, e.g. after login: push the settings and check the daemon.
function onEnable()
    sync(true)
end

-- Monitor plugged in / unplugged. The daemon reacts on its own; this refreshes
-- the tile and revives a daemon that died while the output set was changing.
function onOutputsChanged()
    poll()
end

function update()
    poll()
end

sync(true)
