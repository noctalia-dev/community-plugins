--!strict
-- Spotify Ambient: per-output blurred artwork wallpapers + dynamic Noctalia palette.
-- Targets Noctalia 5.5+ image-theme CLI / plugin API 44 (palette format 2).

local pluginDir = noctalia.pluginDir()
local dataDir = noctalia.pluginDataDir()
if not pluginDir or not dataDir then
    error("spotify-ambient: could not resolve plugin directories")
end

local helper = pluginDir .. "/ambient.py"
local statePath = dataDir .. "/state.json"
local cacheDir = dataDir .. "/wallpapers"
local paletteLockPath = dataDir .. "/palette.lock"

local function configHome()
    local root = noctalia.getenv("NOCTALIA_CONFIG_HOME")
    if not root or root == "" then
        root = noctalia.getenv("XDG_CONFIG_HOME")
    end
    if not root or root == "" then
        root = noctalia.getenv("HOME")
        if not root or root == "" then root = noctalia.expandPath("~") end
        root = root .. "/.config"
    end
    root = string.gsub(root, "/+$", "")
    return root .. "/noctalia"
end

local paletteDir = configHome() .. "/palettes"
local POLL_MS = 5000
local PLAYER = "spotify"
local PALETTE_PREFIX = "SpotifyAmbientDynamic"

local activeKey = ""
local busy = false
local paletteBusy = false
local pendingPalette = nil
local pendingTrack = nil
local sessionCaptureBusy = false
local restoreBusy = false
local restoreAfterPalette = false
local deferredRestoreCallbacks = {}
local restoreSession
local stopped = false

-- Snapshot of Noctalia state immediately before the plugin takes control.
-- These values survive pauses/reloads and are never replaced by our own values.
local originalWallpapers = {}
local originalScheme = nil
local sessionActive = false

-- Exact values last applied by this plugin. Used to avoid undoing manual changes.
local appliedWallpapers = {}
local appliedScheme = nil

local paletteName = nil
local palettePath = nil
local paletteTrackKey = nil
local ownedPalettePaths = {}
local paletteOwned = false
local paletteApplied = false

local function log(message)
    noctalia.log("[spotify-ambient] " .. message)
end

local function processFailure(stage, result)
    if type(result) ~= "table" then
        return stage .. ": process returned no result object"
    end

    local parts = { stage .. " (exitCode=" .. tostring(result.exitCode) .. ")" }
    local foundOutput = false
    for _, field in ipairs({ "stderr", "stdout", "error", "message", "signal" }) do
        local value = result[field]
        if type(value) == "string" and noctalia.string.trim(value) ~= "" then
            local cleaned = noctalia.string.trim(value)
            if #cleaned > 900 then cleaned = string.sub(cleaned, 1, 900) .. "…[truncated]" end
            table.insert(parts, field .. "=" .. cleaned)
            foundOutput = true
        end
    end
    if not foundOutput then
        table.insert(parts, "no stdout/stderr was captured; run the diagnostic report for environment details")
    end
    return table.concat(parts, " | ")
end

local function saveState()
    local payload = {
        originalWallpapers = originalWallpapers,
        originalScheme = originalScheme,
        sessionActive = sessionActive,
        appliedWallpapers = appliedWallpapers,
        appliedScheme = appliedScheme,
        paletteName = paletteName,
        palettePath = palettePath,
        paletteTrackKey = paletteTrackKey,
        ownedPalettePaths = ownedPalettePaths,
        paletteOwned = paletteOwned,
        paletteApplied = paletteApplied,
        version = 3,
    }
    local encoded, encodeErr = noctalia.json.encode(payload)
    if not encoded then
        log("Could not encode plugin state: " .. tostring(encodeErr))
        return
    end
    local ok, err = noctalia.writeFile(statePath, encoded)
    if not ok then log("Could not persist plugin state: " .. tostring(err)) end
end

local function isOwnedPalettePath(path)
    if type(path) ~= "string" then return false end
    local directoryPrefix = paletteDir .. "/"
    if string.sub(path, 1, #directoryPrefix) ~= directoryPrefix then return false end
    local filename = string.sub(path, #directoryPrefix + 1)
    if filename == "" or string.find(filename, "/", 1, true)
        or string.find(filename, "\\", 1, true) then
        return false
    end
    if string.sub(filename, -5) ~= ".json" then return false end
    local stem = string.sub(filename, 1, #filename - 5)
    local token = string.sub(stem, #PALETTE_PREFIX + 2)
    return string.sub(stem, 1, #PALETTE_PREFIX + 1) == PALETTE_PREFIX .. "-"
        and token ~= "" and string.match(token, "^[%w_%-]+$") ~= nil
end

local function loadState()
    local raw = noctalia.readFile(statePath)
    if not raw then return end
    local decoded, decodeErr = noctalia.json.decode(raw)
    if type(decoded) ~= "table" then
        log("Ignoring invalid state file: " .. tostring(decodeErr))
        return
    end

    -- Migrate v2 state written by earlier builds.
    if type(decoded.originalWallpapers) == "table" then
        originalWallpapers = decoded.originalWallpapers
    elseif type(decoded.originals) == "table" then
        originalWallpapers = decoded.originals
    end
    if type(decoded.originalScheme) == "table"
        and type(decoded.originalScheme.source) == "string"
        and type(decoded.originalScheme.name) == "string" then
        originalScheme = decoded.originalScheme
    end
    sessionActive = decoded.sessionActive == true
    if type(decoded.appliedWallpapers) == "table" then appliedWallpapers = decoded.appliedWallpapers end
    if type(decoded.appliedScheme) == "table"
        and type(decoded.appliedScheme.source) == "string"
        and type(decoded.appliedScheme.name) == "string" then
        appliedScheme = decoded.appliedScheme
    end
    if type(decoded.paletteName) == "string" then paletteName = decoded.paletteName end
    if type(decoded.palettePath) == "string" and isOwnedPalettePath(decoded.palettePath) then
        palettePath = decoded.palettePath
    end
    if type(decoded.paletteTrackKey) == "string" then paletteTrackKey = decoded.paletteTrackKey end
    if type(decoded.ownedPalettePaths) == "table" then
        local validatedOwnedPaths = {}
        for path, owned in pairs(decoded.ownedPalettePaths) do
            if owned == true and isOwnedPalettePath(path) then
                validatedOwnedPaths[path] = true
            end
        end
        ownedPalettePaths = validatedOwnedPaths
    end
    paletteOwned = decoded.paletteOwned == true and palettePath ~= nil
    if paletteOwned then ownedPalettePaths[palettePath] = true end
    paletteApplied = decoded.paletteApplied == true

    -- Old builds did not store the wallpaper path that they applied. We can
    -- safely keep their original paths, but must not claim an unknown current
    -- wallpaper is ours. A later playback transition will recapture if needed.
    if decoded.version ~= 3 then
        -- Migrate v2 backups. Older builds saved the original wallpaper but
        -- did not save the ambient path they had applied. Recognize our own
        -- cache directory so pause/disable can still restore the true original.
        appliedWallpapers = {}
        for _, output in ipairs(noctalia.outputs()) do
            local currentPath = noctalia.wallpaperPath(output.name)
            if type(currentPath) == "string"
                and string.sub(currentPath, 1, #cacheDir + 1) == cacheDir .. "/" then
                appliedWallpapers[output.name] = currentPath
            end
        end
        -- v2's paletteApplied flag can be stale (for example, after the old
        -- plugin restored a fallback scheme). Do not treat that remembered
        -- palette name as proof that it is currently selected. The first v3
        -- palette application will establish a fresh appliedScheme value.
        appliedScheme = nil
        paletteApplied = false
        sessionActive = next(originalWallpapers) ~= nil and originalScheme ~= nil
        saveState()
    end
end

local function parseScheme(stdout)
    local source, name = string.match(noctalia.string.trim(stdout or ""), "^(%S+)%s+(.+)$")
    if not source or not name then return nil end
    return { source = source, name = noctalia.string.trim(name) }
end

local function sameScheme(a, b)
    return type(a) == "table" and type(b) == "table"
        and a.source == b.source and a.name == b.name
end

local function isOurScheme(scheme)
    if scheme == nil or scheme.source ~= "custom" or type(scheme.name) ~= "string" then return false end
    return scheme.name == PALETTE_PREFIX
        or string.sub(scheme.name, 1, #PALETTE_PREFIX + 1) == PALETTE_PREFIX .. "-"
end

local function readCurrentScheme(callback)
    if not noctalia.commandExists("noctalia") then
        callback(nil, "noctalia CLI was not found on PATH")
        return
    end
    local accepted = noctalia.runAsync({ "noctalia", "msg", "color-scheme-get" }, function(result)
        if result.exitCode ~= 0 then
            callback(nil, processFailure("color-scheme-get", result))
            return
        end
        local scheme = parseScheme(result.stdout)
        if not scheme then
            callback(nil, "could not parse color-scheme-get output")
            return
        end
        callback(scheme, nil)
    end)
    if not accepted then callback(nil, "could not start color-scheme-get") end
end

local function getWallpaperPath(connector, callback)
    -- Prefer IPC: wallpaper-get returns the effective per-output path persisted
    -- by Noctalia. Fall back to the API 25 accessor if IPC is unavailable.
    local accepted = noctalia.runAsync({ "noctalia", "msg", "wallpaper-get", connector }, function(result)
        if result.exitCode == 0 then
            local value = noctalia.string.trim(result.stdout or "")
            if value ~= "" then
                callback(value, nil)
                return
            end
        end

        local path = noctalia.wallpaperPath(connector)
        if type(path) == "string" and path ~= "" then
            callback(path, nil)
        else
            callback(nil, processFailure("wallpaper-get " .. connector, result))
        end
    end)

    if not accepted then
        local path = noctalia.wallpaperPath(connector)
        if type(path) == "string" and path ~= "" then
            callback(path, nil)
        else
            callback(nil, "could not query wallpaper path for " .. connector)
        end
    end
end

local function isOurWallpaper(path)
    return type(path) == "string"
        and string.sub(path, 1, #cacheDir + 1) == cacheDir .. "/"
end

local function setWallpaperPath(connector, path, callback)
    -- IPC persists the exact per-output path in Noctalia settings, including
    -- special values such as color:#RRGGBB. It also handles paths with spaces.
    local accepted = noctalia.runAsync({ "noctalia", "msg", "wallpaper-set", connector, path }, function(result)
        if result.exitCode == 0 then
            callback(true, nil)
        else
            callback(false, processFailure("wallpaper-set " .. connector, result))
        end
    end)
    if not accepted then callback(false, "could not start wallpaper-set") end
end

local function captureSession(callback)
    if sessionActive then callback(true); return end
    if sessionCaptureBusy then callback(false); return end
    sessionCaptureBusy = true

    local outputs = noctalia.outputs()
    if #outputs == 0 then
        sessionCaptureBusy = false
        log("Cannot snapshot original state: Noctalia reports no connected outputs")
        callback(false)
        return
    end

    local capturedWallpapers = {}
    local capturedScheme = nil
    local pending = #outputs + 1
    local failed = false
    local failureMessages = {}

    local function finishOne()
        pending -= 1
        if pending ~= 0 then return end
        sessionCaptureBusy = false
        if failed or not capturedScheme then
            log("Snapshot incomplete; refusing to replace the user's wallpaper/theme: " ..
                table.concat(failureMessages, "; "))
            callback(false)
            return
        end

        originalWallpapers = capturedWallpapers
        -- Preserve a valid pre-existing snapshot during migration. In particular,
        -- v0.3.4 may have retained originalScheme while losing its wallpaper map.
        -- The current scheme can already be a temporary fallback selected by the
        -- older service, so do not replace the saved pre-playback scheme here.
        originalScheme = originalScheme or capturedScheme
        appliedWallpapers = {}
        appliedScheme = nil
        sessionActive = true
        paletteApplied = false
        saveState()

        for connector, path in pairs(originalWallpapers) do
            log("Saved original wallpaper for " .. connector .. ": " .. path)
        end
        log("Saved original color scheme: " .. originalScheme.source .. " " .. originalScheme.name)
        callback(true)
    end

    readCurrentScheme(function(scheme, err)
        if scheme then
            capturedScheme = scheme
        else
            failed = true
            table.insert(failureMessages, "color scheme: " .. tostring(err))
        end
        finishOne()
    end)

    for _, output in ipairs(outputs) do
        getWallpaperPath(output.name, function(path, err)
            if path then
                capturedWallpapers[output.name] = path
            else
                failed = true
                table.insert(failureMessages, output.name .. ": " .. tostring(err))
            end
            finishOne()
        end)
    end
end

local function ensurePalettePath(trackKey)
    local requestedTrackKey = tostring(trackKey or "unknown")
    if paletteName and palettePath and paletteOwned and paletteTrackKey == requestedTrackKey then
        return true
    end

    local ok, err = noctalia.mkdirAll(paletteDir)
    if not ok then
        log("Could not create Noctalia palette directory: " .. tostring(err))
        return false
    end

    local token = string.gsub(string.sub(requestedTrackKey, -22), "[^%w%-_]", "")
    if token == "" then token = string.gsub(string.sub(requestedTrackKey, 1, 22), "[^%w%-_]", "") end
    if token == "" then token = "unknown" end

    local base = PALETTE_PREFIX .. "-" .. token
    local candidate = base
    local suffix = 2
    while noctalia.fileExists(paletteDir .. "/" .. candidate .. ".json") do
        local candidatePath = paletteDir .. "/" .. candidate .. ".json"
        if ownedPalettePaths[candidatePath] == true then break end
        candidate = base .. "-" .. tostring(suffix)
        suffix += 1
        if suffix > 100 then
            log("Could not find a free custom palette filename")
            return false
        end
    end

    paletteName = candidate
    palettePath = paletteDir .. "/" .. candidate .. ".json"
    paletteTrackKey = requestedTrackKey
    paletteOwned = true
    paletteApplied = false
    ownedPalettePaths[palettePath] = true
    saveState()
    return true
end

-- If the user manually changes the wallpaper while playback is active, treat
-- that as the new restore target for this output rather than undoing it later.
local function refreshOriginalWallpapers(callback)
    local outputs = noctalia.outputs()
    if #outputs == 0 then callback(true); return end
    local pending = #outputs
    local failed = false
    local function finishOne()
        pending -= 1
        if pending == 0 then
            saveState()
            callback(not failed)
        end
    end

    for _, output in ipairs(outputs) do
        getWallpaperPath(output.name, function(current, err)
            if not current then
                failed = true
                log("Could not inspect wallpaper for " .. output.name .. ": " .. tostring(err))
            elseif originalWallpapers[output.name] == nil then
                originalWallpapers[output.name] = current
                log("Saved wallpaper for newly connected output " .. output.name .. ": " .. current)
            elseif appliedWallpapers[output.name] ~= nil and current ~= appliedWallpapers[output.name] then
                originalWallpapers[output.name] = current
                appliedWallpapers[output.name] = nil
                log("Detected a manual wallpaper change on " .. output.name .. "; updated restore target")
            elseif appliedWallpapers[output.name] == nil and current ~= originalWallpapers[output.name] then
                originalWallpapers[output.name] = current
                log("Detected a wallpaper change before ambient apply on " .. output.name .. "; updated restore target")
            end
            finishOne()
        end)
    end
end

-- A manually selected theme during playback becomes the next restore target.
local function captureThemeBeforeApply(trackKey, callback)
    readCurrentScheme(function(current, err)
        if not current then
            log("Not changing the theme: " .. tostring(err))
            callback(false)
            return
        end
        -- Before our first palette is applied, current is simply the captured
        -- pre-playback scheme (or a legacy fallback). Only treat a non-plugin
        -- scheme as a manual change after we have applied a palette ourselves.
        if appliedScheme ~= nil and not isOurScheme(current)
            and not sameScheme(current, originalScheme) then
            originalScheme = current
            saveState()
        end
        if not ensurePalettePath(trackKey) then
            callback(false)
            return
        end
        callback(true)
    end)
end

local applyPalette

local function finishPaletteJob()
    paletteBusy = false

    -- A pause/stop may have requested restoration while the palette subprocess
    -- was running. Restore only after its callback has completed, so a late
    -- color-scheme-set cannot race behind the restoration.
    if restoreAfterPalette then
        restoreAfterPalette = false
        pendingPalette = nil
        local callbacks = deferredRestoreCallbacks
        deferredRestoreCallbacks = {}
        restoreSession(function(ok)
            for _, callback in ipairs(callbacks) do callback(ok) end
        end)
        return
    end

    local nextJob = pendingPalette
    pendingPalette = nil
    if nextJob and not stopped then applyPalette(nextJob.artUri, nextJob.trackKey) end
end

applyPalette = function(artUri, trackKey)
    if stopped then return end
    if paletteBusy then
        pendingPalette = { artUri = artUri, trackKey = trackKey }
        return
    end
    paletteBusy = true

    if not ensurePalettePath(trackKey) then
        finishPaletteJob()
        return
    end

    captureThemeBeforeApply(trackKey, function(ready)
        if not ready or stopped or activeKey ~= trackKey then
            finishPaletteJob()
            return
        end

        local accepted = noctalia.runAsync({
            "python3", helper, "palette-apply", artUri, palettePath, paletteName, paletteLockPath,
        }, function(result)
            if result.exitCode == 0 then
                appliedScheme = { source = "custom", name = paletteName }
                paletteApplied = true
                saveState()
                log("Applied dynamic palette " .. paletteName)
            else
                log("ERROR: " .. processFailure("palette generation/application for track " .. trackKey, result))
                if activeKey == trackKey then activeKey = "" end
            end
            finishPaletteJob()
        end)
        if not accepted then
            log("Could not start palette generator")
            if activeKey == trackKey then activeKey = "" end
            finishPaletteJob()
        end
    end)
end

local function renderForOutput(artUri, output, trackKey)
    local outPath = cacheDir .. "/" .. trackKey .. "-" ..
        string.gsub(output.name, "[^%w%-_]", "_") .. ".jpg"
    local argv = {
        "python3", helper, "render", artUri,
        tostring(math.floor(output.width)), tostring(math.floor(output.height)), outPath,
    }
    local accepted = noctalia.runAsync(argv, function(result)
        if result.exitCode == 0 and noctalia.fileExists(outPath) then
            if not stopped and activeKey == trackKey then
                local callOk, callResult = pcall(noctalia.setWallpaper, output.name, outPath)
                if not callOk or callResult == false then
                    log("ERROR: setWallpaper failed on " .. output.name .. ": " .. tostring(callResult) ..
                        "; retrying on the next playback poll")
                    if activeKey == trackKey then activeKey = "" end
                    return
                end
                appliedWallpapers[output.name] = outPath
                saveState()
                log("Applied ambient wallpaper on " .. output.name)
            end
        else
            local detail = processFailure("wallpaper render for " .. output.name, result)
            if result and result.exitCode == 0 and not noctalia.fileExists(outPath) then
                detail = detail .. " | expected output file was not created: " .. outPath
            end
            log("ERROR: " .. detail .. "; retrying on the next playback poll")
            if not stopped and activeKey == trackKey then activeKey = "" end
        end
    end)
    if not accepted then
        log("ERROR: could not start wallpaper renderer for " .. output.name .. "; retrying on the next playback poll")
        if activeKey == trackKey then activeKey = "" end
    end
end

local function applyTrack(artUri, trackKey)
    if stopped or not sessionActive or activeKey ~= trackKey then return end
    noctalia.mkdirAll(cacheDir)
    for _, output in ipairs(noctalia.outputs()) do
        if output.width > 0 and output.height > 0 then
            renderForOutput(artUri, output, trackKey)
        end
    end
    applyPalette(artUri, trackKey)
end

local function shellQuote(value)
    return "'" .. string.gsub(tostring(value), "'", "'\\''") .. "'"
end

local function cleanupSessionState()
    originalWallpapers = {}
    originalScheme = nil
    appliedWallpapers = {}
    appliedScheme = nil
    sessionActive = false
    paletteApplied = false
    activeKey = ""
    saveState()
end

local handlePlayingTrack

restoreSession = function(callback)
    if paletteBusy then
        restoreAfterPalette = true
        pendingPalette = nil
        if callback then table.insert(deferredRestoreCallbacks, callback) end
        return
    end
    if restoreBusy then
        if callback then callback(false) end
        return
    end
    if not sessionActive then
        if callback then callback(true) end
        return
    end
    restoreBusy = true

    local tasks = 0
    local failed = false
    local function addTask() tasks += 1 end
    local function finishTask(ok, description)
        if not ok then
            failed = true
            log("Restore failed for " .. description)
        end
        tasks -= 1
        if tasks == 0 then
            restoreBusy = false
            if not failed then
                log("Original wallpaper and color scheme restored")
                cleanupSessionState()
            else
                log("Keeping the saved snapshot so restoration can be retried")
            end
            if callback then callback(not failed) end
            if pendingTrack and not stopped and not failed then
                local nextTrack = pendingTrack
                pendingTrack = nil
                handlePlayingTrack(nextTrack.artUri, nextTrack.trackKey)
            end
        end
    end

    for connector, originalPath in pairs(originalWallpapers) do
        addTask()
        getWallpaperPath(connector, function(currentPath, err)
            if not currentPath then
                log("Could not read current wallpaper for " .. connector .. ": " .. tostring(err))
                finishTask(false, "wallpaper " .. connector)
                return
            end

            local ourPath = appliedWallpapers[connector]
            local isAppliedByUs = (ourPath ~= nil and currentPath == ourPath)
                or (ourPath == nil and isOurWallpaper(currentPath))
            if isAppliedByUs then
                setWallpaperPath(connector, originalPath, function(ok, setErr)
                    if ok then
                        log("Restored wallpaper on " .. connector .. ": " .. originalPath)
                    else
                        log("wallpaper-set error on " .. connector .. ": " .. tostring(setErr))
                    end
                    finishTask(ok, "wallpaper " .. connector)
                end)
            elseif currentPath == originalPath then
                finishTask(true, "wallpaper " .. connector .. " (already original)")
            else
                -- The user changed the wallpaper outside this plugin. Respect it.
                log("Leaving manually changed wallpaper untouched on " .. connector)
                finishTask(true, "wallpaper " .. connector .. " (manual change preserved)")
            end
        end)
    end

    addTask()
    readCurrentScheme(function(currentScheme, err)
        if not currentScheme then
            log("Could not read active color scheme during restore: " .. tostring(err))
            finishTask(false, "color scheme")
            return
        end

        local isAppliedByUs = (appliedScheme ~= nil and sameScheme(currentScheme, appliedScheme))
            or (appliedScheme == nil and isOurScheme(currentScheme))
        if isAppliedByUs and originalScheme then
            local accepted = noctalia.runAsync({
                "noctalia", "msg", "color-scheme-set", originalScheme.source, originalScheme.name,
            }, function(result)
                if result.exitCode == 0 then
                    finishTask(true, "color scheme")
                else
                    log("ERROR: " .. processFailure("restore color-scheme-set", result))
                    finishTask(false, "color scheme")
                end
            end)
            if not accepted then finishTask(false, "color scheme") end
        elseif originalScheme and sameScheme(currentScheme, originalScheme) then
            finishTask(true, "color scheme (already original)")
        else
            -- Preserve a theme the user selected manually while Spotify played.
            log("Leaving manually changed color scheme untouched")
            finishTask(true, "color scheme (manual change preserved)")
        end
    end)
end

local function restoreOnExit()
    -- The callback-less subprocess is detached so it can finish after onExit
    -- destroys this service's Luau VM. Restore only values still owned by us.
    local commandParts = {}
    for connector, originalPath in pairs(originalWallpapers) do
        local expected = appliedWallpapers[connector]
        if type(originalPath) == "string" and originalPath ~= "" then
            local condition
            if expected then
                condition = '[ "$current" = ' .. shellQuote(expected) .. ' ]'
            else
                condition = 'case "$current" in ' .. shellQuote(cacheDir) .. '/?*) true ;; *) false ;; esac'
            end
            local snippet = 'current="$(noctalia msg wallpaper-get ' .. shellQuote(connector) ..
                ' 2>/dev/null)"; if ' .. condition .. '; then noctalia msg wallpaper-set ' ..
                shellQuote(connector) .. " " .. shellQuote(originalPath) .. '; fi; '
            table.insert(commandParts, snippet)
        end
    end

    local cleanupParts = {}
    local ownedSchemePatterns = {}
    for path, owned in pairs(ownedPalettePaths) do
        if owned == true and isOwnedPalettePath(path) then
            table.insert(cleanupParts, "rm -f -- " .. shellQuote(path))
            local filename = string.match(path, "([^/]+)%.json$")
            if filename then table.insert(ownedSchemePatterns, shellQuote("custom " .. filename)) end
        end
    end
    if palettePath and paletteOwned and isOwnedPalettePath(palettePath)
        and ownedPalettePaths[palettePath] ~= true then
        table.insert(cleanupParts, "rm -f -- " .. shellQuote(palettePath))
        local filename = string.match(palettePath, "([^/]+)%.json$")
        if filename then table.insert(ownedSchemePatterns, shellQuote("custom " .. filename)) end
    end
    local cleanupCommand = table.concat(cleanupParts, "; ")
    local ownedSchemePattern = table.concat(ownedSchemePatterns, "|")
    -- An empty cleanup list must still produce a valid shell command. In
    -- particular, "then ; fi" is a syntax error and would abort all restoration.
    local cleanupAction = cleanupCommand ~= "" and cleanupCommand or ":"

    if originalScheme then
        local originalCommand = "noctalia msg color-scheme-set " ..
            shellQuote(originalScheme.source) .. " " .. shellQuote(originalScheme.name)
        local restoreSchemePatterns = {}
        if type(appliedScheme) == "table" and appliedScheme.source == "custom"
            and type(appliedScheme.name) == "string" then
            table.insert(restoreSchemePatterns, shellQuote("custom " .. appliedScheme.name))
        end
        -- The helper applies the theme before its completion callback can update
        -- appliedScheme. Include the in-flight target so shutdown still restores
        -- the original theme if that apply completed just before onExit.
        if paletteBusy and type(paletteName) == "string" then
            local inFlightScheme = "custom " .. paletteName
            local quotedInFlight = shellQuote(inFlightScheme)
            if not table.find(restoreSchemePatterns, quotedInFlight) then
                table.insert(restoreSchemePatterns, quotedInFlight)
            end
        end
        local restoreSchemePattern = table.concat(restoreSchemePatterns, "|")

        local snippet
        if restoreSchemePattern ~= "" then
            -- Restore only a scheme known to have been applied by this plugin.
            -- Other plugin-created palettes remain untouched if selected manually.
            local preserveOtherOwned = ownedSchemePattern ~= ""
                and "case \"$current\" in " .. ownedSchemePattern .. ") : ;; *) " .. cleanupAction .. " ;; esac; "
                or cleanupAction .. "; "
            snippet = 'current="$(noctalia msg color-scheme-get 2>/dev/null)"; case "$current" in ' ..
                restoreSchemePattern .. ') if ' .. originalCommand .. ' >/dev/null 2>&1; then ' ..
                cleanupAction .. '; fi ;; *) ' .. preserveOtherOwned .. 'esac; '
        elseif ownedSchemePattern ~= "" then
            -- Without an exact applied value, never remove a palette that is
            -- currently selected by the user.
            snippet = 'current="$(noctalia msg color-scheme-get 2>/dev/null)"; case "$current" in ' ..
                ownedSchemePattern .. ') : ;; *) ' .. cleanupAction .. ' ;; esac; '
        else
            snippet = cleanupAction .. "; "
        end
        table.insert(commandParts, snippet)
    elseif cleanupCommand ~= "" then
        if ownedSchemePattern ~= "" then
            local snippet = 'current="$(noctalia msg color-scheme-get 2>/dev/null)"; case "$current" in ' ..
                ownedSchemePattern .. ') : ;; *) ' .. cleanupCommand .. ' ;; esac; '
            table.insert(commandParts, snippet)
        else
            table.insert(commandParts, cleanupCommand .. "; ")
        end
    end

    if #commandParts == 0 then return end
    -- The detached cleanup waits for any palette generation/application job
    -- to release the same advisory lock before inspecting or restoring the theme.
    local cleanupScript = table.concat(commandParts)
    local command = "flock --exclusive --wait 180 " .. shellQuote(paletteLockPath) ..
        " /bin/sh -c " .. shellQuote(cleanupScript)
    local accepted = noctalia.runAsync(command)
    if not accepted then log("Could not start detached wallpaper/theme restoration") end
end

handlePlayingTrack = function(artUri, trackKey)
    if stopped then return end
    -- A restore can complete between polls; reassert the desired track key
    -- after cleanup clears the previous session's active key.
    activeKey = trackKey
    if restoreBusy then
        pendingTrack = { artUri = artUri, trackKey = trackKey }
        return
    end
    if sessionActive then
        refreshOriginalWallpapers(function(ok)
            if ok and not stopped and activeKey == trackKey then
                applyTrack(artUri, trackKey)
            elseif not ok and activeKey == trackKey then
                activeKey = ""
            end
        end)
        return
    end

    if sessionCaptureBusy then
        pendingTrack = { artUri = artUri, trackKey = trackKey }
        return
    end

    captureSession(function(ok)
        if not ok then
            activeKey = ""
            return
        end
        local nextTrack = pendingTrack or { artUri = artUri, trackKey = trackKey }
        pendingTrack = nil
        if not stopped and activeKey == nextTrack.trackKey then
            applyTrack(nextTrack.artUri, nextTrack.trackKey)
        end
    end)
end

local function restoreForUnavailableSpotify(reason)
    activeKey = ""
    pendingTrack = nil
    if sessionActive then
        restoreSession(function(ok)
            if ok then
                log(reason .. "; restored the saved wallpaper and color scheme")
            else
                log(reason .. "; restoration will be retried while Spotify remains unavailable")
            end
        end)
    else
        log(reason .. "; no active Spotify session snapshot needs restoration")
    end
end

local function spotifyPlayerIsRegistered(callback)
    if not noctalia.commandExists("playerctl") then
        callback(false, "playerctl is missing")
        return
    end

    -- Check the MPRIS registry separately from metadata. This detects Spotify
    -- being closed or not yet started after boot, rather than treating it as a
    -- paused player. Exact matching avoids confusing Spotify with other players.
    local accepted = noctalia.runAsync({ "playerctl", "-l" }, function(result)
        if result.exitCode ~= 0 then
            callback(false, processFailure("playerctl -l", result))
            return
        end

        local found = false
        for line in string.gmatch(result.stdout or "", "[^\r\n]+") do
            if noctalia.string.trim(line) == PLAYER then
                found = true
                break
            end
        end
        if found then
            callback(true, nil)
        else
            callback(false, PLAYER .. " is not registered with MPRIS")
        end
    end)
    if not accepted then callback(false, "could not start playerctl -l") end
end

function updatePlayback()
    if busy or stopped then return end
    busy = true

    spotifyPlayerIsRegistered(function(available, availabilityError)
        if stopped then busy = false; return end
        if not available then
            busy = false
            restoreForUnavailableSpotify("Spotify player unavailable: " .. tostring(availabilityError))
            return
        end

        local accepted = noctalia.runAsync({
            "playerctl", "-p", PLAYER, "metadata", "--format",
            "{{status}}\t{{mpris:trackid}}\t{{mpris:artUrl}}",
        }, function(result)
            busy = false
            if stopped then return end

            if result.exitCode ~= 0 then
                restoreForUnavailableSpotify(processFailure("Spotify metadata query", result))
                return
            end

            local status, trackId, artUri = string.match(
                result.stdout or "", "^([^\t]*)\t([^\t]*)\t([^\r\n]*)"
            )
            if status ~= "Playing" or not artUri or artUri == "" then
                restoreForUnavailableSpotify("Spotify is paused or stopped")
                return
            end

            local key = string.gsub(trackId or "", "[^%w%-_]", "")
            if key == "" then key = string.gsub(string.sub(artUri, -48), "[^%w%-_]", "") end
            if key == "" or key == activeKey then return end

            activeKey = key
            handlePlayingTrack(artUri, key)
        end)
        if not accepted then
            busy = false
            restoreForUnavailableSpotify("Could not query Spotify metadata")
        end
    end)
end

loadState()
noctalia.mkdirAll(cacheDir)
noctalia.setUpdateInterval(POLL_MS)
updatePlayback()

function update()
    updatePlayback()
end

function onOutputsChanged()
    if sessionActive then
        activeKey = ""
        updatePlayback()
    end
end

function onExit(signal, reason)
    stopped = true
    if reason == "disable" or reason == "uninstall" then
        restoreOnExit()
    else
        -- Reload/shutdown retains the session snapshot and applied values.
        saveState()
    end
end
