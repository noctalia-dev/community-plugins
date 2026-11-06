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

local function getHomeDir()
    local h = noctalia.getenv("HOME")
    if h and h ~= "" then
        return h
    end
    return ""
end

local function getWayvibesConfigDir()
    local xdg = noctalia.getenv("XDG_CONFIG_HOME")
    if xdg and xdg ~= "" then
        return xdg .. "/wayvibes"
    end
    local home = getHomeDir()
    return home .. "/.config/wayvibes"
end

local function formatDeviceDisplay(record)
    if not record or record == "" then
        return ""
    end
    if record:sub(1, 5) == "NAME:" then
        return record:sub(6)
    elseif record:sub(1, 5) == "PATH:" then
        return record:sub(6)
    end
    return record
end

local currentPackName = ""
local currentPackPath = ""
local currentVolume = 3
local isPlaying = false
local currentDevice = ""
local availableDevices = {}

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

-- Read and interpret upstream wayvibes configuration ($XDG_CONFIG_HOME/wayvibes/input_device
-- or fallback ~/.config/wayvibes/input_device). Also migrates legacy files if needed.
local function parseDeviceRecord(raw)
    local line = (raw or ""):match("^[^\r\n]+") or ""
    local kind = line:sub(1, 5)
    if (kind == "NAME:" or kind == "PATH:") and line:sub(6):find("%S") then
        return line
    end
    return ""
end

local function getSavedDeviceConfig()
    local dir = getWayvibesConfigDir()
    local newFile = dir .. "/input_device"
    local oldNameFile = dir .. "/input_device_name"
    local oldPathFile = dir .. "/input_device_path"

    -- Preserve legacy files unless their replacement was successfully saved.
    if not noctalia.fileExists(newFile) then
        for _, legacy in ipairs({ { oldNameFile, "NAME:" }, { oldPathFile, "PATH:" } }) do
            if noctalia.fileExists(legacy[1]) then
                local raw = noctalia.readFile(legacy[1])
                local line = (raw or ""):match("^[^\r\n]+") or ""
                if line:find("%S") then
                    local record = legacy[2] .. line
                    local ready = noctalia.mkdirAll(dir)
                    if ready and noctalia.writeFile(newFile, record .. "\n") then
                        noctalia.removeFile(legacy[1])
                        return record
                    end
                    return ""
                end
            end
        end
    end

    if noctalia.fileExists(newFile) then
        return parseDeviceRecord(noctalia.readFile(newFile))
    end
    return ""
end

-- Discover keyboard-capable input devices by reading /proc/bus/input/devices directly,
-- matching upstream's KEY_A capability check, with fallback to /dev/input/by-id.
local function loadDevices(cb)
    local devices = {}
    local seen = {}

    local procPath = "/proc/bus/input/devices"
    if noctalia.fileExists(procPath) then
        local raw = noctalia.readFile(procPath)
        if raw and raw ~= "" then
            for block in (raw .. "\n\n"):gmatch("(.-)\n\n") do
                local name = block:match('N: Name="([^"]+)"')
                local handlers = block:match("H: Handlers=([^\r\n]+)") or ""
                local evStr = block:match("B: EV=([0-9a-fA-F]+)") or ""
                local ev = tonumber(evStr, 16) or 0

                local eventNum = handlers:match("event(%d+)")
                -- /proc bitmaps list the least-significant word last. Only read
                -- its low 32 bits so 64-bit words cannot lose precision in Luau.
                local keyBits = block:match("B: KEY=([^\r\n]+)") or ""
                local lowWord = keyBits:match("(%x+)%s*$") or ""
                local lowKeys = tonumber(lowWord:sub(-8), 16) or 0
                local hasKey = (ev % 4 >= 2)
                local hasA = (math.floor(lowKeys / 1073741824) % 2 == 1)

                if name and eventNum and hasKey and hasA then
                    local devPath = "/dev/input/event" .. eventNum
                    if not seen[devPath] then
                        seen[devPath] = true
                        table.insert(devices, {
                            name = name,
                            path = devPath,
                            configName = name,
                        })
                    end
                end
            end
        end
    end

    -- Fallback: if /proc yielded no devices, check /dev/input/by-id
    if #devices == 0 and noctalia.fileExists("/dev/input/by-id") then
        local entries = noctalia.listDir("/dev/input/by-id") or {}
        for _, entry in ipairs(entries) do
            if entry:match("%-event%-kbd$") then
                local fullPath = "/dev/input/by-id/" .. entry
                local cleanName = entry:gsub("^usb%-", ""):gsub("%-event%-kbd$", ""):gsub("_", " ")
                if not seen[fullPath] then
                    seen[fullPath] = true
                    table.insert(devices, {
                        name = cleanName,
                        path = fullPath,
                    })
                end
            end
        end
    end

    availableDevices = devices
    noctalia.state.set("wayvibes_devices", devices)
    if cb then
        cb(devices)
    end
    return devices
end

local function scanSoundpacks()
    local home = getHomeDir()
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
    if not noctalia.commandExists(binPath()) then
        noctalia.notifyError("WayVibes", noctalia.tr("daemon_missing"))
        return
    end

    local devRecord = getSavedDeviceConfig()
    currentDevice = formatDeviceDisplay(devRecord)
    noctalia.state.set("wayvibes_device", currentDevice)

    if devRecord == "" then
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
                noctalia.notifyError("WayVibes", "Failed to start wayvibes. Check keyboard permissions, the soundpack, and your audio session.")
            end
        end)
    end)
end

-- Save device selection directly to upstream wayvibes configuration file ($XDG_CONFIG_HOME/wayvibes/input_device)
local function setDevice(devicePath, deviceName)
    local dir = getWayvibesConfigDir()
    noctalia.mkdirAll(dir)
    local cfgPath = dir .. "/input_device"

    -- Only real, unique kernel names can be resolved by upstream. Fallback
    -- labels and duplicate names must be saved by path instead.
    local selected
    for _, device in ipairs(availableDevices) do
        if device.path == devicePath or (devicePath == "" and device.name == deviceName) then
            selected = device
            break
        end
    end
    local exactName = selected and selected.configName
    local nameCount = 0
    if exactName then
        for _, device in ipairs(availableDevices) do
            if device.configName == exactName then
                nameCount = nameCount + 1
            end
        end
    end

    local record = ""
    if exactName and nameCount == 1 then
        record = "NAME:" .. exactName
    elseif devicePath and devicePath ~= "" then
        record = "PATH:" .. devicePath
    else
        noctalia.notifyError("WayVibes", "No input device specified.")
        return
    end

    local ok = noctalia.writeFile(cfgPath, record .. "\n")
    if ok then
        currentDevice = formatDeviceDisplay(record)
        noctalia.state.set("wayvibes_device", currentDevice)
        noctalia.notify("WayVibes", noctalia.tr("device_saved"))
        if isPlaying and currentPackPath ~= "" then
            startPlayback(currentPackName, currentPackPath, currentVolume)
        end
    else
        noctalia.notifyError("WayVibes", "Failed to write input device configuration.")
    end
end

-- Initialization
local function init()
    local configured = getSavedDeviceConfig()
    currentDevice = formatDeviceDisplay(configured)
    noctalia.state.set("wayvibes_device", currentDevice)

    loadDevices(function(devs)
        -- If no device is configured but keyboards are detected, auto-select the first keyboard
        if currentDevice == "" and #devs > 0 then
            setDevice(devs[1].path, devs[1].name)
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
    elseif payload.action == "select_device" and (payload.devicePath or payload.deviceName) then
        setDevice(payload.devicePath or "", payload.deviceName or "")
    elseif payload.action == "scan" then
        scanSoundpacks()
        loadDevices()
    end
end)
