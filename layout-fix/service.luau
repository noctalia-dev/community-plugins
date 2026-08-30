--!nonstrict
-- Layout Fix: keeps the correction daemon running and nothing else.
--
-- There is no widget and no panel on purpose: the plugin's whole job is to
-- install the daemon, keep it alive, make sure the right dictionaries are
-- around, and otherwise stay out of the way. Everything user-facing lives
-- in Settings (the manifest's own settings UI) and in the compositor's
-- keybindings.
--
-- Why a daemon at all: reading the keyboard needs /dev/input, which the
-- plugin runtime cannot touch. The daemon (scripts/layout-fix, plain
-- Python, no third-party modules) is copied into the plugin's data
-- directory - a stable path that survives plugin updates - and launched
-- detached from there.
--
-- IPC (bind these in your compositor):
--   noctalia msg plugin umedbazarov/layout-fix:service all fix
--   noctalia msg plugin umedbazarov/layout-fix:service all undo
--   noctalia msg plugin umedbazarov/layout-fix:service all auto

local PLUGIN_ID = "umedbazarov/layout-fix"
local CHECK_INTERVAL_TICKS = 15 -- seconds between "is the daemon alive?" probes
local STARTUP_DELAY_TICKS = 5

local started = false
local startupTicks = 0
local sinceCheck = 0
local daemonPath = nil
local installedOnce = false
local dictionaryChecked = false
local lastStatus = ""

local function cfg(key, fallback)
    -- getConfig returns nil until the setting is materialized in
    -- settings.toml; the manifest default is NOT substituted by the runtime.
    local value = noctalia.getConfig(key)
    if value == nil then
        return fallback
    end
    return value
end

local function tr(key, args)
    return noctalia.tr(key, args)
end

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function scriptPath()
    return (noctalia.pluginDir() or ".") .. "/scripts/layout-fix"
end

local function installedPath()
    local dir = noctalia.pluginDataDir()
    return dir ~= nil and (dir .. "/layout-fix") or nil
end

-- ── Daemon lifecycle ─────────────────────────────────────────────────────────

local function install(done)
    local target = installedPath()
    if target == nil then
        done(false)
        return
    end
    daemonPath = target
    local cmd = "cp -f " .. shellQuote(scriptPath()) .. " " .. shellQuote(target)
        .. " && chmod +x " .. shellQuote(target)
    local ok = noctalia.runAsync(cmd, function(result)
        installedOnce = (result.exitCode or 1) == 0
        if not installedOnce then
            noctalia.log("layout-fix: could not install the daemon: " .. tostring(result.stderr))
        end
        done(installedOnce)
    end)
    if not ok then
        done(false)
    end
end

-- The daemon answers `status` over its own socket; a failure means it is
-- not running (or not reachable), which is the only thing we act on.
local function probe(callback)
    if daemonPath == nil then
        callback(false, "")
        return
    end
    local started = noctalia.runAsync(shellQuote(daemonPath) .. " status 2>/dev/null", function(result)
        local out = (result.stdout or ""):gsub("%s+$", "")
        callback((result.exitCode or 1) == 0 and out ~= "", out)
    end, 5000)
    if not started then
        callback(false, "")
    end
end

local function launch()
    if daemonPath == nil then
        return
    end
    -- Detached: the daemon must outlive this callback (and a shell reload).
    noctalia.runAsync("setsid " .. shellQuote(daemonPath) .. " daemon >/dev/null 2>&1 &",
        function() end)
    noctalia.log("layout-fix: daemon started")
end

local function applyAutoSetting()
    if daemonPath == nil then
        return
    end
    local wanted = cfg("auto", true) == true and "on" or "off"
    noctalia.runAsync(shellQuote(daemonPath) .. " auto " .. wanted .. " >/dev/null 2>&1",
        function() end)
end

-- ── The keybinding hint ──────────────────────────────────────────────────────

-- Nothing about this plugin is visible: no widget, no panel, and the manual
-- actions exist only as IPC. So a person who installs it has no way of
-- learning that `fix` and `undo` are there unless they are told once.
local function hintPath()
    local dir = noctalia.pluginDataDir()
    return dir ~= nil and (dir .. "/hint-shown") or nil
end

local function markHintShown()
    local path = hintPath()
    if path ~= nil then
        noctalia.writeFile(path, "1\n")
    end
end

-- Someone whose config already spawns this plugin's IPC has clearly found
-- the keybindings, and a notification would only be noise. The marker is
-- written either way, so the search runs once per installation.
local function hintIfUnbound()
    local path = hintPath()
    if path == nil or noctalia.fileExists(path) then
        return
    end
    if cfg("hotkey_hint", true) ~= true then
        return
    end
    local cmd = "grep -rlF " .. shellQuote(PLUGIN_ID .. ":service")
        .. " \"$HOME\"/.config/niri \"$HOME\"/.config/hypr \"$HOME\"/.config/sway"
        .. " 2>/dev/null | head -1"
    local started = noctalia.runAsync(cmd, function(result)
        if trim(result.stdout or "") == "" then
            noctalia.notify(tr("title"), tr("notify_hotkey_hint"))
        end
        markHintShown()
    end, 10000)
    if not started then
        -- No shell to ask with: better one hint than none, and the marker
        -- still keeps it to one.
        noctalia.notify(tr("title"), tr("notify_hotkey_hint"))
        markHintShown()
    end
end

-- ── Keyboard access and dictionaries ─────────────────────────────────────────

-- Reading /dev/input needs group membership, which no plugin can grant.
-- Telling the user exactly what to run is the most that can be done here.
local function checkAccess()
    noctalia.runAsync("test -r \"$(ls /dev/input/by-path/*event-kbd 2>/dev/null | head -1)\" && echo yes || echo no",
        function(result)
            if (result.stdout or ""):find("no") then
                noctalia.notifyError(tr("title"), tr("err_no_input_access"))
            end
        end, 5000)
end

-- The daemon knows which layouts the compositor has and which dictionary
-- each one wants, so the languages are never hard-coded here.
local function languagesWanted(callback)
    if daemonPath == nil then
        callback({})
        return
    end
    noctalia.runAsync(shellQuote(daemonPath) .. " dicts 2>/dev/null", function(result)
        local wanted = {}
        for language in (result.stdout or ""):gmatch("%S+") do
            table.insert(wanted, language)
        end
        callback(wanted)
    end, 10000)
end

-- Arch package names: hunspell-ru, hunspell-en_us, hunspell-de … The
-- English dictionary is the one exception to "hunspell-<language>".
local function packageFor(language)
    if language == "en" then
        return "hunspell-en_us"
    end
    return "hunspell-" .. language
end

local function installDictionaries(missing)
    -- One pkexec call, and only when the user asked for it in settings.
    local packages = {}
    for _, language in ipairs(missing) do
        table.insert(packages, packageFor(language))
    end
    local cmd = "pkexec pacman -S --needed --noconfirm " .. table.concat(packages, " ")
    noctalia.runAsync(cmd, function(result)
        if (result.exitCode or 1) == 0 then
            noctalia.notify(tr("title"), tr("notify_dicts_installed"))
            if daemonPath ~= nil then
                -- The daemon opens hunspell once at startup.
                noctalia.runAsync(shellQuote(daemonPath) .. " reset >/dev/null 2>&1", function() end)
            end
        elseif (result.exitCode or 1) ~= 126 then -- 126 = password dialog dismissed
            noctalia.notifyError(tr("title"), tr("err_dicts_install"))
        end
    end, 180000)
end

local function checkDictionaries()
    local mode = cfg("dictionaries", "notify")
    if mode == "ignore" then
        return
    end
    languagesWanted(function(wanted)
        if #wanted == 0 then
            return
        end
        noctalia.runAsync("echo | hunspell -D 2>&1", function(result)
            local have = result.stdout or ""
            local missing = {}
            for _, language in ipairs(wanted) do
                -- A dictionary counts as present when its name starts with
                -- the language code: ru matches ru_RU, en matches en_US.
                if have:find("/" .. language .. "_", 1, true) == nil
                    and have:find("/" .. language .. "\n", 1, true) == nil then
                    table.insert(missing, language)
                end
            end
            if #missing == 0 then
                return
            end
            table.sort(missing)
            local list = table.concat(missing, ", ")
            if mode == "install" and noctalia.commandExists("pkexec") then
                installDictionaries(missing)
            else
                noctalia.notify(tr("title"), tr("notify_dicts_missing", { list = list }))
            end
        end, 10000)
    end)
end

-- ── Lifecycle ────────────────────────────────────────────────────────────────

function onIpc(event, _payload)
    if daemonPath == nil then
        return
    end
    if event == "fix" or event == "undo" or event == "status" or event == "reset" then
        noctalia.runAsync(shellQuote(daemonPath) .. " " .. event, function(result)
            lastStatus = (result.stdout or ""):gsub("%s+$", "")
            if event == "status" then
                noctalia.log("layout-fix: " .. lastStatus)
            end
        end, 20000)
    elseif event == "auto" then
        noctalia.runAsync(shellQuote(daemonPath) .. " auto toggle", function(result)
            noctalia.notify(tr("title"), (result.stdout or ""):gsub("%s+$", ""))
        end, 10000)
    end
end

function onConfigChanged()
    applyAutoSetting()
    dictionaryChecked = false
end

function update()
    if not started then
        startupTicks += 1
        if startupTicks < STARTUP_DELAY_TICKS then
            return
        end
        started = true
        install(function(ok)
            if not ok then
                return
            end
            probe(function(alive)
                if not alive then
                    launch()
                end
                applyAutoSetting()
                checkAccess()
                hintIfUnbound()
            end)
        end)
        return
    end

    sinceCheck += 1
    if sinceCheck < CHECK_INTERVAL_TICKS then
        return
    end
    sinceCheck = 0
    if not dictionaryChecked then
        dictionaryChecked = true
        checkDictionaries()
    end
    probe(function(alive)
        if not alive and installedOnce then
            noctalia.log("layout-fix: daemon is gone, restarting")
            launch()
            applyAutoSetting()
        end
    end)
end

function onExit(_signal)
    -- Leaving a keyboard watcher running after the plugin is disabled would
    -- be exactly the wrong default for something that reads every keystroke.
    if daemonPath ~= nil then
        noctalia.runAsync("pkill -f " .. shellQuote(daemonPath .. " daemon"), function() end)
    end
end

noctalia.setUpdateInterval(1000)
