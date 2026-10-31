--!nonstrict
-- WayVibes — supervisor service.
-- Thin integration managing the external wayvibes daemon, detecting input
-- devices, scanning soundpack libraries, and coordinating state.

local function shellQuote(str)
    return "'" .. tostring(str):gsub("'", "'\\''") .. "'"
end

local function binPath()
    local p = noctalia.getConfig("executable_path")
    if p and p ~= "" then
        return p
    end
    return "wayvibes"
end

local function dataDir()
    return noctalia.pluginDataDir() or ""
end

local function stateFilePath()
    return dataDir() .. "/state.json"
end

local currentPackName = ""
local currentPackPath = ""
local currentVolume = 3
local isPlaying = false
local currentDevice = ""

local function readSavedState()
    local path = stateFilePath()
    if not noctalia.fileExists(path) then
        return nil
    end
    local raw = noctalia.readFile(path)
    if not raw or raw == "" then
        return nil
    end
    local packPath = raw:match('"path"%s*:%s*"([^"]+)"')
    local packName = raw:match('"name"%s*:%s*"([^"]+)"')
    local vol = tonumber(raw:match('"volume"%s*:%s*(%d+)'))
    return {
        path = packPath,
        name = packName,
        volume = vol,
    }
end

local function saveState(packName, packPath, volume)
    local path = stateFilePath()
    local content = string.format('{\n  "name": "%s",\n  "path": "%s",\n  "volume": %d\n}\n', packName, packPath, volume)
    noctalia.writeFile(path, content)
end

local function getDevicePath()
    local home = os.getenv("HOME") or ""
    local devFile = home .. "/.config/wayvibes/input_device_path"
    if noctalia.fileExists(devFile) then
        local raw = noctalia.readFile(devFile)
        if raw then
            local trimmed = raw:match("^%s*(.-)%s*$")
            if trimmed and trimmed ~= "" then
                return trimmed
            end
        end
    end
    return ""
end

local function loadDevices(cb)
    local cmd = shellQuote(binPath()) .. " --list-devices"
    noctalia.runAsync(cmd, function(res)
        local devices = {}
        if res and res.exitCode == 0 and res.stdout then
            for line in res.stdout:gmatch("[^\r\n]+") do
                local p, n = line:match("^([^\t]+)\t(.*)$")
                if p then
                    table.insert(devices, { path = p, name = n ~= "" and n or p })
                end
            end
        end
        noctalia.state.set("wayvibes_devices", devices)
        if cb then
            cb(devices)
        end
    end)
end

local function scanSoundpacks()
    local home = os.getenv("HOME") or ""
    local searchDirs = {}

    local customDir = noctalia.getConfig("soundpacks_dir")
    if customDir and customDir ~= "" then
        table.insert(searchDirs, customDir)
    end

    table.insert(searchDirs, home .. "/.local/share/soundpacks")
    table.insert(searchDirs, home .. "/wayvibes/soundpacks")
    table.insert(searchDirs, home .. "/wayvibes")

    local foundPacks = {}
    local seen = {}

    for _, dir in ipairs(searchDirs) do
        local expanded = dir
        if expanded:sub(1, 1) == "~" then
            expanded = home .. expanded:sub(2)
        end

        if noctalia.fileExists(expanded) then
            local entries = noctalia.listDir(expanded) or {}
            for _, entry in ipairs(entries) do
                local sub = expanded .. "/" .. entry
                local cfg = sub .. "/config.json"
                if noctalia.fileExists(cfg) and not seen[entry] then
                    seen[entry] = true
                    local friendlyName = entry
                    local content = noctalia.readFile(cfg)
                    if content then
                        local n = content:match('"name"%s*:%s*"([^"]+)"')
                        if n and n ~= "" then
                            friendlyName = n
                        end
                    end
                    table.insert(foundPacks, {
                        name = friendlyName,
                        folder = entry,
                        path = sub,
                    })
                end
            end
        end
    end

    table.sort(foundPacks, function(a, b)
        return a.name:lower() < b.name:lower()
    end)

    noctalia.state.set("wayvibes_packs", foundPacks)
    return foundPacks
end

local function stopPlayback()
    noctalia.runAsync("pkill -x wayvibes", function() end)
    isPlaying = false
    currentPackName = ""
    currentPackPath = ""
    noctalia.state.set("wayvibes_playing", false)
    noctalia.state.set("wayvibes_pack", "")
end

local function startPlayback(packName, packPath, volume)
    local dev = getDevicePath()
    currentDevice = dev
    noctalia.state.set("wayvibes_device", dev)

    if dev == "" then
        noctalia.notifyError("WayVibes", noctalia.tr("no_device_warning"))
        stopPlayback()
        return
    end

    local vol = volume or tonumber(noctalia.getConfig("default_volume")) or 3
    local cmd = "pkill -x wayvibes; " .. shellQuote(binPath()) .. " " .. shellQuote(packPath .. "/") .. " -v " .. tostring(vol) .. " -bg"

    noctalia.runAsync(cmd, function(res)
        -- Verify that wayvibes process is actually running
        noctalia.runAsync("sleep 0.3 && pgrep -x wayvibes", function(chk)
            if chk and chk.exitCode == 0 then
                isPlaying = true
                currentPackName = packName
                currentPackPath = packPath
                currentVolume = vol
                noctalia.state.set("wayvibes_playing", true)
                noctalia.state.set("wayvibes_pack", currentPackName)
                noctalia.state.set("wayvibes_volume", currentVolume)
                saveState(currentPackName, currentPackPath, currentVolume)
            else
                stopPlayback()
                noctalia.notifyError("WayVibes", "Failed to start wayvibes. Ensure input device permissions.")
            end
        end)
    end)
end

local function setDevice(devicePath)
    local home = os.getenv("HOME") or ""
    local cfgPath = home .. "/.config/wayvibes/input_device_path"
    local cmd = shellQuote(binPath()) .. " --write-file " .. shellQuote(cfgPath) .. " " .. shellQuote(devicePath)
    noctalia.runAsync(cmd, function(res)
        if res and res.exitCode == 0 then
            currentDevice = devicePath
            noctalia.state.set("wayvibes_device", currentDevice)
            noctalia.notify("WayVibes", noctalia.tr("device_saved"))
            if isPlaying and currentPackPath ~= "" then
                startPlayback(currentPackName, currentPackPath, currentVolume)
            end
        else
            noctalia.notifyError("WayVibes", "Failed to set input device.")
        end
    end)
end

-- Initialization
local function init()
    currentDevice = getDevicePath()
    noctalia.state.set("wayvibes_device", currentDevice)

    loadDevices(function(devs)
        -- If no device path is set but keyboards are detected, auto-select the first keyboard
        if currentDevice == "" and #devs > 0 then
            setDevice(devs[1].path)
        end
    end)

    scanSoundpacks()
    currentVolume = tonumber(noctalia.getConfig("default_volume")) or 3
    noctalia.state.set("wayvibes_volume", currentVolume)
    noctalia.state.set("wayvibes_ready", true)

    if noctalia.getConfig("auto_start") == true then
        local saved = readSavedState()
        if saved and saved.path and noctalia.fileExists(saved.path) then
            startPlayback(saved.name or "Mechanical", saved.path, saved.volume or currentVolume)
        end
    end
end

init()

noctalia.state.watch("wayvibes_cmd", function(payload)
    if type(payload) ~= "table" then
        return
    end

    if payload.action == "play" and payload.packPath then
        startPlayback(payload.packName or "Soundpack", payload.packPath, payload.volume or currentVolume)
    elseif payload.action == "stop" then
        stopPlayback()
    elseif payload.action == "volume" and payload.volume then
        currentVolume = tonumber(payload.volume) or currentVolume
        if isPlaying and currentPackPath ~= "" then
            startPlayback(currentPackName, currentPackPath, currentVolume)
        end
    elseif payload.action == "select_device" and payload.devicePath then
        setDevice(payload.devicePath)
    elseif payload.action == "scan" then
        scanSoundpacks()
        loadDevices()
    end
end)
