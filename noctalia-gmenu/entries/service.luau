--!nonstrict
-- service.luau - companion daemon lifecycle + bridge for amancode22/noctalia-gmenu
--
-- Spawns the Python daemon (which owns all D-Bus and Wayland work) with
-- noctalia.runStream and consumes its JSON lines. Menu trees are published
-- on the plugin state channel for the bar widget and the popup panel.
-- Commands reach the daemon over a loopback HTTP server whose ephemeral
-- port arrives in the hello line.

local dataDir = noctalia.pluginDataDir()
local pluginDir = noctalia.pluginDir()

local daemonHandle = nil
local lastPingMs = 0
local lastSpawnMs = 0
local pendingChunks = nil      -- { id, part, chunks, body }
local features = {}
local port = nil
local killed = false

-- ---------------------------------------------------------------- helpers

local function shq(path)
    return "'" .. tostring(path):gsub("'", "'\\''") .. "'"
end

local function log(msg)
    noctalia.log("[global-menu] " .. msg)
end

-- publish a plain-data snapshot for the other entries
local function publish(menu)
    noctalia.state.set("menu", menu)
end

local function onLine(line)
    if line == nil or line == "" then return end
    local ok, msg = pcall(function() return noctalia.json.decode(line) end)
    if not ok or type(msg) ~= "table" then
        log("unparseable daemon line: " .. tostring(line):sub(1, 120))
        return
    end

    local kind = msg.type
    if kind == "hello" then
        port = tonumber(msg.port)
        features = msg.features or {}
        lastPingMs = noctalia.nowMs()
        noctalia.state.set("port", port)
        noctalia.state.set("features", features)
        log(("daemon up (port %s, toplevels=%s, fullscreen=%s, wtype=%s, registrar=%s, shortcuts=%d)")
            :format(tostring(port),
                    tostring(features.toplevels == true),
                    tostring(features.fullscreen == true),
                    tostring(features.wtype == true),
                    tostring(features.registrar == true),
                    tonumber(features.shortcuts or 0)))
        -- push the plugin settings so the daemon gates match the UI
        local cfg = noctalia.json.encode({
            cmd = "config",
            shortcutMenus = noctalia.getConfig("shortcut_menus") == true,
            fallbackMenus = noctalia.getConfig("fallback_menus") == true,
        })
        noctalia.http({
            url = "http://127.0.0.1:" .. tostring(port) .. "/cmd",
            method = "POST",
            headers = { "Content-Type: application/json" },
            body = cfg,
        }, function() end)
    elseif kind == "menu" then
        lastPingMs = noctalia.nowMs()
        if msg.body ~= nil then
            -- chunked tree: reassemble before publishing
            if msg.chunk == 0 or pendingChunks == nil or
                    pendingChunks.id ~= msg.id then
                pendingChunks = { id = msg.id, chunks = msg.chunks or 1,
                                  body = {}, part = 0 }
            end
            table.insert(pendingChunks.body, msg.body)
            pendingChunks.part = pendingChunks.part + 1
            if pendingChunks.part >= pendingChunks.chunks then
                local menu = {
                    app = msg.app, title = msg.title,
                    appName = msg.appName,
                    source = msg.source, id = msg.id,
                }
                pendingChunks.menu = menu
                local raw = table.concat(pendingChunks.body, "")
                pendingChunks = nil
                local okTree, tree = pcall(function()
                    return noctalia.json.decode(raw)
                end)
                if okTree and tree ~= nil then
                    menu.tree = tree
                    publish(menu)
                end
            end
        else
            pendingChunks = nil
            publish({
                app = msg.app, title = msg.title,
                appName = msg.appName,
                source = msg.source, tree = msg.tree or {}, id = msg.id,
            })
        end
    elseif kind == "ping" then
        lastPingMs = noctalia.nowMs()
    elseif kind == "window" then
        -- live state of the focused window (maximized/minimized/fullscreen);
        -- nil when no window is focused
        noctalia.state.set("window", msg.state)
    elseif kind == "fatal" then
        noctalia.notifyError("Global Menu", tostring(msg.error or "daemon failed"))
        log("fatal: " .. tostring(msg.error))
    end
end

-- ----------------------------------------------------------------- daemon

local function spawnDaemon()
    if killed then return end
    local nowMs = noctalia.nowMs()
    if nowMs - lastSpawnMs < 10000 then return end
    lastSpawnMs = nowMs

    local script = pluginDir .. "/daemon/globalmenu_daemon.py"
    local cmd = string.format(
        "python3 %s --data %s --shortcuts %s --plugin %s",
        shq(script), shq(dataDir),
        shq(pluginDir .. "/daemon/shortcuts/apps"),
        shq("amancode22/noctalia-gmenu"))
    local ok = noctalia.runStream(cmd, onLine)
    if not ok then
        log("could not start the daemon; is python3-dbus installed?")
        noctalia.notifyError("Global Menu",
            "Could not start the menu daemon (needs python3-dbus, python3-gi)")
    else
        log("daemon stream started")
    end
end

local function killDaemon()
    killed = true
    local raw = noctalia.readFile(dataDir .. "/daemon.pid")
    if raw == nil then return end
    local pid = tonumber(tostring(raw):match("^%s*(%d+)"))
    if pid == nil or pid <= 1 then return end
    -- never signal a pid that has been reused by an unrelated process
    local cmdline = noctalia.readFile("/proc/" .. tostring(pid) .. "/cmdline")
    if cmdline == nil or
            string.find(tostring(cmdline), "globalmenu_daemon.py", 1, true) == nil then
        log("ignoring stale daemon.pid " .. tostring(pid))
        return
    end
    -- TERM first; a daemon with a wedged main loop cannot handle it, so
    -- escalate to KILL after three seconds
    local script = string.format(
        "kill -TERM %d 2>/dev/null; " ..
        "for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do " ..
        "kill -0 %d 2>/dev/null || exit 0; sleep 0.2; done; " ..
        "kill -KILL %d 2>/dev/null",
        pid, pid, pid)
    noctalia.runAsync({ "sh", "-c", script })
    log("stopped daemon pid " .. tostring(pid))
end

-- ---------------------------------------------------------------- lifecycle

spawnDaemon()

noctalia.setUpdateInterval(6000)

function update()
    if killed then return end
    local nowMs = noctalia.nowMs()
    if lastPingMs == 0 then
        -- hello not arrived yet; give the first spawn a generous window
        if nowMs - lastSpawnMs > 20000 then spawnDaemon() end
        return
    end
    if nowMs - lastPingMs > 15000 then
        log("daemon heartbeat lost; restarting it")
        killDaemon()
        killed = false
        lastPingMs = 0
        port = nil
        noctalia.state.set("port", nil)
        -- a moment for the old process to die before starting a new one
        lastSpawnMs = 0
        spawnDaemon()
    end
end

function onConfigChanged()
    if port == nil then return end
    local cfg = noctalia.json.encode({
        cmd = "config",
        shortcutMenus = noctalia.getConfig("shortcut_menus") == true,
        fallbackMenus = noctalia.getConfig("fallback_menus") == true,
    })
    noctalia.http({
        url = "http://127.0.0.1:" .. tostring(port) .. "/cmd",
        method = "POST",
        headers = { "Content-Type: application/json" },
        body = cfg,
    }, function() end)
end

function onIpc(event, payload)
    if event == "refresh" then
        if port ~= nil then
            noctalia.http({
                url = "http://127.0.0.1:" .. tostring(port) .. "/cmd",
                method = "POST",
                headers = { "Content-Type: application/json" },
                body = '{"cmd":"refresh"}',
            }, function() end)
        end
    elseif event == "reload-shortcuts" then
        if port ~= nil then
            noctalia.http({
                url = "http://127.0.0.1:" .. tostring(port) .. "/cmd",
                method = "POST",
                headers = { "Content-Type: application/json" },
                body = '{"cmd":"reloadShortcuts"}',
            }, function() end)
        end
    end
end

function onExit(_signal, reason)
    if reason == "disable" or reason == "uninstall" or reason == "shutdown" then
        killDaemon()
    elseif reason == "reload" then
        -- the runtime restarts us; stop the daemon so only one owns the bus
        killDaemon()
        killed = false
    end
end
