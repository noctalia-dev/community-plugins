--!nonstrict
-- Mic Denoise - headless service (single owner of all logic).
--
-- Published state   noctalia.state["status"]  -> { enabled, available, default, raw }
-- Command channel   noctalia.state["command"] -> { action = "on" | "off" | "toggle"
--                                                        | "refresh" | "set-mic", mic = ... }
--
-- The tile and the bar widget are thin clients: they render
-- "status" and write "command". Switching off moves the default source (and every
-- capture stream) back to the physical microphone, which leaves the RNNoise
-- filter-chain without a consumer, so PipeWire suspends the whole graph and no DSP
-- work happens.
--
-- Choosing a microphone rewrites the filter-chain capture target and reloads
-- PipeWire once, because the capture target is read at module load.

local SOURCE = tostring(noctalia.getConfig("source") or "rnnoise_source")
local MIC = tostring(noctalia.getConfig("hardware_source") or "")
local INTERVAL = tonumber(noctalia.getConfig("poll_interval")) or 5000
if INTERVAL < 500 then
    INTERVAL = 500
end

-- A hung pactl must never wedge the service in a permanent "busy" state.
local CMD_TIMEOUT_MS = 8000
-- set-mic restarts PipeWire and waits for the socket to come back.
local SET_MIC_TIMEOUT_MS = 60000

local PLUGIN_DIR = noctalia.pluginDir() or "."
local SCRIPT = PLUGIN_DIR .. "/assets/mic-denoise.sh"
local DATA_DIR = noctalia.pluginDataDir() or ""
local CONF_PATH = noctalia.expandPath("~/.config/pipewire/pipewire.conf.d/50-mic-denoise.conf")

local status = nil
local busy = false
local pending = nil -- { kind = "status" } | { kind = "action", action = ... } | { kind = "setmic", mic = ... }
local lastError = nil
local configState = "pending" -- pending | present | written | failed

local function log(msg)
    noctalia.log(`mic-denoise: {msg}`)
end

-- Microphone from the "hardware_source" setting; empty means "let the backend
-- decide" (last used input, or the first one available).
local micPref = MIC

local function reportError(detail)
    if detail == nil or detail == "" then
        detail = noctalia.tr("notify.failed.body")
    end
    if detail == lastError then
        return
    end
    lastError = detail
    log(detail)
    noctalia.notifyError(noctalia.tr("notify.failed.title"), detail)
end

local function clearError()
    lastError = nil
end

local function parseStatus(out)
    local st = { enabled = false, available = false, default = "", raw = "", hint = "" }
    for line in (out or ""):gmatch("[^\r\n]+") do
        local key, value = line:match("^([%w_]+)=(.*)$")
        if key == "enabled" then
            st.enabled = value == "1"
        elseif key == "available" then
            st.available = value == "1"
        elseif key == "default" then
            st.default = value
        elseif key == "raw" then
            st.raw = value
        elseif key == "hint" then
            st.hint = value
        end
    end
    return st
end

local function publish(st)
    local prev = status
    status = st
    if
        prev
        and prev.enabled == st.enabled
        and prev.available == st.available
        and prev.default == st.default
        and prev.raw == st.raw
    then
        return
    end
    noctalia.state.set("status", st)
end

-- "available=0" alone is not actionable: say why once per distinct reason.
local lastHint = nil

local function notifyHint(st)
    if st.available then
        lastHint = nil
        return
    end
    if st.hint == "" or st.hint == lastHint then
        return
    end
    lastHint = st.hint
    if st.hint == "ladspa-missing" then
        noctalia.notify(noctalia.tr("notify.ladspa.title"), noctalia.tr("notify.ladspa.body"))
    else
        noctalia.notify(noctalia.tr("notify.not-ready.title"), noctalia.tr("notify.not-ready.body"))
    end
end

-- The snippet is machine specific: the capture side is pinned to a physical
-- microphone so pointing the default source at the virtual one cannot loop.
-- Generated once from the bundled template, only rewritten on an explicit
-- microphone change (see the set-mic command).
local function ensurePipewireConfig(st)
    if configState == "present" or configState == "written" then
        return
    end
    if noctalia.fileExists(CONF_PATH) then
        configState = "present"
        return
    end
    if st.raw == "" then
        return -- no microphone known yet; retry on a later poll
    end

    local template, readErr = noctalia.readFile(PLUGIN_DIR .. "/assets/50-mic-denoise.conf.in")
    if not template then
        configState = "failed"
        log(`template unreadable: {tostring(readErr)}`)
        return
    end

    local content = template:gsub("@SOURCE@", function()
        return SOURCE
    end)
    content = content:gsub('node%.target%s*=%s*"@TARGET@"', function()
        return 'node.target  = "' .. st.raw .. '"'
    end)

    if content:find("@SOURCE@", 1, true) or content:find("@TARGET@", 1, true) then
        configState = "failed"
        log(`unresolved placeholder in template; refusing to write {CONF_PATH}`)
        return
    end

    noctalia.mkdirAll(CONF_PATH:match("^(.*)/[^/]+$") or ".")
    local ok, writeErr = noctalia.writeFile(CONF_PATH, content)
    if not ok then
        configState = "failed"
        log(`could not write {CONF_PATH}: {tostring(writeErr)}`)
        return
    end

    configState = "written"
    noctalia.notify(noctalia.tr("notify.config-installed.title"), noctalia.tr("notify.config-installed.body"))
end

function dispatch()
    if busy or pending == nil then
        return
    end
    local item = pending
    pending = nil

    local argv
    local timeout = CMD_TIMEOUT_MS
    if item.kind == "status" then
        argv = { "sh", SCRIPT, "status", SOURCE, micPref, DATA_DIR }
    elseif item.kind == "action" then
        argv = { "sh", SCRIPT, item.action, SOURCE, micPref, DATA_DIR }
    else -- setmic
        local want = (status and status.enabled) and "1" or "0"
        argv = { "sh", SCRIPT, "set-mic", SOURCE, item.mic, DATA_DIR, CONF_PATH, want }
        timeout = SET_MIC_TIMEOUT_MS
    end

    busy = true
    local started = noctalia.runAsync(argv, function(res)
        busy = false
        if res.timedOut then
            reportError(noctalia.tr("notify.timeout.body"))
        elseif res.exitCode ~= 0 then
            reportError((res.stderr or ""):gsub("%s+$", ""))
        else
            clearError()
            if item.kind == "status" then
                local st = parseStatus(res.stdout)
                ensurePipewireConfig(st)
                publish(st)
                notifyHint(st)
            elseif item.kind == "setmic" then
                -- keep micPref in sync with what the backend actually pinned
                micPref = item.mic
                -- The backend repoints the live filter-chain stream and only
                -- restarts PipeWire when that is not possible.
                local restarted = tostring(res.stdout or ""):match("reloaded=(%d)") == "1"
                noctalia.notify(
                    noctalia.tr("notify.mic-changed.title"),
                    noctalia.tr(restarted and "notify.mic-changed.body-restarted" or "notify.mic-changed.body")
                )
            end
        end
        -- Any switch or microphone change ends with a fresh status so the UI
        -- reflects reality instead of an optimistic guess.
        if item.kind ~= "status" and pending == nil then
            pending = { kind = "status" }
        end
        dispatch()
    end, timeout)

    if not started then
        busy = false
        reportError(noctalia.tr("notify.spawn-failed.body"))
    end
end

local function request(item)
    -- A periodic status refresh must never swallow a queued user action: while a
    -- command is still running, keep the action and let the next tick refresh.
    if item.kind == "status" and pending ~= nil and pending.kind ~= "status" then
        return
    end
    pending = item -- otherwise the latest request wins
    dispatch()
end

-- `on` and `off` are idempotent in the backend, so they are safe to expose.
noctalia.state.watch("command", function(command)
    if type(command) ~= "table" then
        return
    end
    local action = command.action
    if action == "on" or action == "off" or action == "toggle" then
        request({ kind = "action", action = action })
    elseif action == "set-mic" then
        request({ kind = "setmic", mic = tostring(command.mic or "") })
    elseif action == "refresh" then
        request({ kind = "status" })
    end
end)

function update()
    request({ kind = "status" })
end

-- Editing the "Microphone" setting rewrites the filter-chain capture target and
-- reloads PipeWire once (the target is read at module load).
function onConfigChanged()
    local nextMic = tostring(noctalia.getConfig("hardware_source") or "")
    if nextMic ~= micPref then
        micPref = nextMic
        request({ kind = "setmic", mic = nextMic })
    end
end

noctalia.setUpdateInterval(INTERVAL)
request({ kind = "status" })

-- Leave no dangling state behind: hand the microphone back when the plugin is
-- switched off. The command is detached so it survives this runtime.
function onExit(_signal, reason)
    if reason ~= "disable" and reason ~= "uninstall" then
        return
    end
    if not status or not status.enabled then
        return
    end
    if reason == "disable" then
        -- The backend also moves capture streams back; on uninstall the plugin
        -- directory may already be going away, so only restore the default then.
        noctalia.runAsync({ "sh", SCRIPT, "off", SOURCE, micPref, DATA_DIR })
    elseif status.raw ~= "" then
        noctalia.runAsync({ "pactl", "set-default-source", status.raw })
    end
end

-- Manual trigger, handy for keybinds and for testing the state channel:
--   noctalia msg plugin goldesquemoon/mic-denoise:state all toggle
function onIpc(event, payload)
    if event == "on" or event == "off" or event == "toggle" then
        request({ kind = "action", action = event })
    elseif event == "set-mic" then
        request({ kind = "setmic", mic = tostring(payload or "") })
    elseif event == "refresh" then
        request({ kind = "status" })
    end
end
