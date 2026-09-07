--!nonstrict
-- service.luau
-- Background headless service for Typing Sounds

local soundPaths = {}     -- [keycode_str] -> absolute path to .wav
local lastKeyTime = {}
local DEBOUNCE_SEC = 0.04 -- 40ms debounce to prevent duplicate events across virtual devices

-- Read configuration
local enabled = noctalia.getConfig("enabled") ~= false
local volumePct = tonumber(noctalia.getConfig("volume")) or 100
local soundPack = noctalia.getConfig("sound_pack") or "nk-cream"
local mouseEnabled = noctalia.getConfig("mouse_enabled") == true

-- Calculate volume factor for pw-play (100% -> 1.0, 200% -> 2.0)
local volumeFactor = string.format("%.2f", math.clamp(volumePct, 0, 200) / 100)

local function loadSoundPack(packName)
    soundPaths = {}

    local configPath = "soundpacks/" .. packName .. "/config.json"
    local rawConfig = noctalia.readFile(configPath)
    if not rawConfig then
        noctalia.notifyError("Typing Sounds", "Could not load soundpack config: " .. packName)
        return
    end

    local cfg, err = noctalia.json.decode(rawConfig)
    if not cfg or not cfg.defines then
        noctalia.notifyError("Typing Sounds", "Invalid soundpack config: " .. tostring(err))
        return
    end

    local pluginDir = noctalia.pluginDir() or "."
    for keycode, filename in pairs(cfg.defines) do
        if filename and filename ~= "" then
            soundPaths[tostring(keycode)] = pluginDir .. "/soundpacks/" .. packName .. "/" .. filename
        end
    end
end

local function triggerKeySound(keycode)
    if not enabled then
        return
    end

    local keyStr = tostring(keycode)
    local now = os.clock()
    if lastKeyTime[keyStr] and (now - lastKeyTime[keyStr]) < DEBOUNCE_SEC then
        return
    end
    lastKeyTime[keyStr] = now

    local filePath = soundPaths[keyStr] or soundPaths["57"] or soundPaths["28"]
    if filePath then
        local quoted = "'" .. filePath:gsub("'", "'\\''") .. "'"
        noctalia.runAsync("pw-play --volume " .. volumeFactor .. " " .. quoted)
    end
end

local function triggerMouseSound()
    if mouseEnabled then
        triggerKeySound("30")
    end
end

local function has(line, needle)
    return line:find(needle, 1, true) ~= nil
end

-- Process evtest events
local function onEvtestLine(line)
    if not has(line, "EV_KEY") or has(line, "BTN_TOOL_") then
        return
    end

    if has(line, "value 1") then
        local codeStr = line:match("code%s+(%d+)")
        if codeStr then
            local code = tonumber(codeStr)
            if code and code >= 272 and code <= 287 then
                triggerMouseSound()
            elseif code then
                triggerKeySound(code)
            end
        end
    end
end

local function isAllowedInputPatternByte(byte)
    return (byte >= 48 and byte <= 57) -- 0-9
        or (byte >= 65 and byte <= 90) -- A-Z
        or (byte >= 97 and byte <= 122) -- a-z
        or byte == 47 -- /
        or byte == 46 -- .
        or byte == 95 -- _
        or byte == 45 -- -
        or byte == 58 -- :
        or byte == 43 -- +
        or byte == 42 -- *
        or byte == 63 -- ?
        or byte == 91 -- [
        or byte == 93 -- ]
end

local function isSupportedInputPattern(pattern)
    return pattern:match("^/dev/input/event") ~= nil
        or pattern:match("^/dev/input/by%-id/") ~= nil
        or pattern:match("^/dev/input/by%-path/") ~= nil
end

local function validateInputPattern(pattern)
    if type(pattern) ~= "string" or pattern == "" then
        return false
    end
    if pattern:find("..", 1, true) ~= nil or not isSupportedInputPattern(pattern) then
        return false
    end
    for i = 1, #pattern do
        if not isAllowedInputPatternByte(pattern:byte(i)) then
            return false
        end
    end
    return true
end

-- Start evtest stream (bongocat style)
local function startInputReader()
    local devices = noctalia.getConfig("input_devices")
    if devices == nil or #devices == 0 then
        devices = {
            "/dev/input/by-id/*kbd*",
            "/dev/input/by-id/*Keyboard*",
            "/dev/input/by-path/*kbd*"
        }
    end

    if type(devices) ~= "table" then
        noctalia.notifyError("Typing Sounds", "Invalid input_devices (expected a list of /dev/input paths or globs)")
        return
    end

    local patterns = {}
    local seen = {}
    for _, pattern in ipairs(devices) do
        if not validateInputPattern(pattern) then
            noctalia.notifyError("Typing Sounds", "Invalid input_devices entry: " .. tostring(pattern))
            return
        end
        if seen[pattern] == nil then
            seen[pattern] = true
            table.insert(patterns, pattern)
        end
    end

    if #patterns == 0 then
        return
    end

    local executable = noctalia.getConfig("executable_path")
    if executable == nil or executable == "" then
        executable = "evtest"
    end

    if not noctalia.commandExists(executable) then
        noctalia.notifyError("Typing Sounds", "The evtest binary is missing (" .. executable .. "). Please install evtest.")
        return
    end

    local quotedExecutable = "'" .. executable:gsub("'", "'\\''") .. "'"
    local command = "seen=''; for device in " .. table.concat(patterns, " ")
        .. '; do [ -e "$device" ] || continue; '
        .. 'case "$device" in *-event-*|*-event-kbd) ;; *) continue ;; esac; '
        .. 'target=$(realpath "$device" 2>/dev/null); '
        .. 'case "$target" in /dev/input/event*) '
        .. 'case " $seen " in *" $target "*) ;; *) seen="$seen $target"; '
        .. quotedExecutable .. ' "$target" 2>/dev/null & ;; esac;; esac; done; wait'

    local started = noctalia.runStream(command, onEvtestLine)
    if not started then
        noctalia.notifyError("Typing Sounds", "Unable to start evtest input reader stream")
    end
end

-- IPC Handler: noctalia msg plugin <id> <event>
function onIpc(event, _payload)
    if event == "toggle" then
        enabled = not enabled
    elseif event == "enable" then
        enabled = true
    elseif event == "disable" then
        enabled = false
    end
end

-- Cleanup when entry exits
function onExit(_signal, _reason)
    soundPaths = {}
    lastKeyTime = {}
end

-- Initialize
loadSoundPack(soundPack)
startInputReader()
