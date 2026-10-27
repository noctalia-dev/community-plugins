--!nonstrict
-- OmaVibes — supervisor service.
-- Compiles wayvibes on first run, unpacks bundled soundpacks, manages the
-- background audio process, and coordinates state across entries.

local function shellQuote(str)
    return "'" .. tostring(str):gsub("'", "'\\''") .. "'"
end

local function pluginDir()
    return noctalia.pluginDir() or ""
end

local function dataDir()
    return noctalia.pluginDataDir() or ""
end

local function helperBin()
    return pluginDir() .. "/bin/wayvibes"
end

local function stateFilePath()
    return dataDir() .. "/state.json"
end

local currentPack = ""
local currentVolume = 3
local isPlaying = false

local function readSavedState()
    local path = stateFilePath()
    if not noctalia.fileExists(path) then
        return nil
    end
    local raw = noctalia.readFile(path)
    if not raw or raw == "" then
        return nil
    end
    -- Simple extraction for pack and volume
    local pack = raw:match('"pack"%s*:%s*"([^"]+)"')
    local vol = tonumber(raw:match('"volume"%s*:%s*(%d+)'))
    return {
        pack = pack,
        volume = vol,
    }
end

local function saveState(pack, volume)
    local path = stateFilePath()
    local content = string.format('{\n  "pack": "%s",\n  "volume": %d\n}\n', pack, volume)
    noctalia.writeFile(path, content)
end

local function stopPlayback()
    noctalia.runAsync("pkill -x wayvibes", function() end)
    isPlaying = false
    currentPack = ""
    noctalia.state.set("omavibes_playing", false)
    noctalia.state.set("omavibes_pack", "")
end

local function startPlayback(packFolder, volume)
    stopPlayback()

    local packsDir = dataDir() .. "/packs"
    local customDir = (os.getenv("HOME") or "") .. "/wayvibes/" .. packFolder
    local packPath = packsDir .. "/" .. packFolder

    if noctalia.fileExists(customDir) then
        packPath = customDir
    end

    local vol = volume or tonumber(noctalia.getConfig("default_volume")) or 3
    local cmd = shellQuote(helperBin()) .. " " .. shellQuote(packPath .. "/") .. " -v " .. tostring(vol) .. " -bg"

    noctalia.runAsync(cmd, function(res)
        if res and res.exitCode == 0 then
            isPlaying = true
            currentPack = packFolder
            currentVolume = vol
            noctalia.state.set("omavibes_playing", true)
            noctalia.state.set("omavibes_pack", currentPack)
            noctalia.state.set("omavibes_volume", currentVolume)
            saveState(currentPack, currentVolume)
        else
            noctalia.notifyError("OmaVibes", "Could not start audio playback.")
        end
    end)
end

-- Ensure bundled soundpacks archive is extracted
local function ensurePacks(thenDo)
    local targetDir = dataDir() .. "/packs"
    if noctalia.fileExists(targetDir .. "/topre") then
        thenDo()
        return
    end

    local archive = pluginDir() .. "/packs.tar.zst"
    if not noctalia.fileExists(archive) then
        archive = pluginDir() .. "/packs.tar.gz"
    end

    if not noctalia.fileExists(archive) then
        noctalia.log("omavibes: soundpacks archive not found")
        thenDo()
        return
    end

    noctalia.log("omavibes: extracting bundled soundpacks to " .. targetDir)
    local cmd = "mkdir -p " .. shellQuote(targetDir) .. " && tar -xf " .. shellQuote(archive) .. " -C " .. shellQuote(dataDir())
    noctalia.runAsync(cmd, function(res)
        if res and res.exitCode == 0 then
            thenDo()
        else
            noctalia.log("omavibes: extraction failed")
        end
    end)
end

-- Ensure native wayvibes binary is compiled
local function ensureBinary(thenDo)
    local bin = helperBin()
    if noctalia.fileExists(bin) then
        thenDo()
        return
    end

    local nativeDir = pluginDir() .. "/native"
    local binDir = pluginDir() .. "/bin"
    noctalia.log("omavibes: compiling native wayvibes daemon (make -C native)")

    local cmd = "mkdir -p " .. shellQuote(binDir) .. " && make -C " .. shellQuote(nativeDir) .. " && cp " .. shellQuote(nativeDir .. "/wayvibes") .. " " .. shellQuote(bin)
    noctalia.runAsync(cmd, function(res)
        if res and res.exitCode == 0 then
            thenDo()
        else
            noctalia.notifyError("OmaVibes", "Failed to compile wayvibes runtime. Check dependencies.")
        end
    end)
end

-- Setup and IPC listeners
ensureBinary(function()
    ensurePacks(function()
        local defVol = tonumber(noctalia.getConfig("default_volume")) or 3
        currentVolume = defVol
        noctalia.state.set("omavibes_ready", true)

        local autoStart = noctalia.getConfig("auto_start") == true
        if autoStart then
            local saved = readSavedState()
            if saved and saved.pack and saved.pack ~= "" then
                startPlayback(saved.pack, saved.volume or defVol)
            end
        end
    end)
end)

noctalia.state.watch("omavibes_cmd", function(payload)
    if type(payload) ~= "table" then
        return
    end
    if payload.action == "play" and payload.pack then
        startPlayback(payload.pack, payload.volume or currentVolume)
    elseif payload.action == "stop" then
        stopPlayback()
    elseif payload.action == "volume" and payload.volume then
        currentVolume = tonumber(payload.volume) or currentVolume
        if isPlaying and currentPack ~= "" then
            startPlayback(currentPack, currentVolume)
        end
    end
end)
