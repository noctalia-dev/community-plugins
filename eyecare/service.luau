--!nonstrict

local isSystemIdle = false
local activeTime = 0
local idleTime = 0
local breakTimer = 0
local breakElapsed = 0
local inBreak = false
local lastLineWasActiveChanged = false

-- Get setting values
local function getSettings()
    return {
        active_duration_minutes = tonumber(noctalia.getConfig("active_duration_minutes")) or 20,
        break_duration_seconds = tonumber(noctalia.getConfig("break_duration_seconds")) or 20,
        enable_sound = noctalia.getConfig("enable_sound") ~= false,
        enable_notifications = noctalia.getConfig("enable_notifications") ~= false
    }
end

local settings = getSettings()

-- Support onConfigChanged to update settings in-place
function onConfigChanged()
    settings = getSettings()
    noctalia.log("eyecare: settings updated")
    updateState()
end

-- Get Noctalia global sound volume (normalized between 0.0 and 1.0)
local function getSoundVolume()
    local rawVol = noctalia.getConfig("sound_volume")
    if rawVol == nil then rawVol = noctalia.getConfig("soundVolume") end
    if rawVol == nil then rawVol = noctalia.getConfig("audio.sound_volume") end
    if rawVol == nil and noctalia.sound and type(noctalia.sound.getVolume) == "function" then
        rawVol = noctalia.sound.getVolume()
    end
    local vol = tonumber(rawVol)
    if vol == nil then
        return 1.0
    end
    if vol > 1.0 then
        vol = vol / 100.0
    end
    return math.clamp(vol, 0.0, 1.0)
end

-- Check whether sound cues are permitted by both plugin and Noctalia global configuration
local function isSoundAllowed()
    if not settings.enable_sound then
        return false
    end

    -- Check Noctalia global sound configuration options
    local enableSounds = noctalia.getConfig("enable_sounds")
    if enableSounds == false then
        return false
    end

    local soundEnabled = noctalia.getConfig("sound_enabled")
    if soundEnabled == false then
        return false
    end

    local audioEnableSounds = noctalia.getConfig("audio.enable_sounds")
    if audioEnableSounds == false then
        return false
    end

    if noctalia.sound and type(noctalia.sound.isEnabled) == "function" then
        if not noctalia.sound.isEnabled() then
            return false
        end
    end

    if getSoundVolume() <= 0 then
        return false
    end

    return true
end

-- Play a notification sound using Noctalia runtime sound API if available, falling back to system players with volume scaling
local function playSound(soundName)
    if not isSoundAllowed() then
        return
    end

    local vol = getSoundVolume()

    if noctalia.sound and type(noctalia.sound.play) == "function" then
        noctalia.sound.play(soundName, vol)
        return
    elseif type(noctalia.playSound) == "function" then
        noctalia.playSound(soundName, vol)
        return
    end

    local path = "/usr/share/sounds/freedesktop/stereo/" .. soundName .. ".oga"
    local paVol = math.floor(vol * 65536)
    local pwVol = string.format("%.2f", vol)
    
    noctalia.runAsync(string.format("canberra-gtk-play -i %s || paplay --volume=%d %s || pw-play --volume=%s %s || aplay %s || true", soundName, paVol, path, pwVol, path, path))
end

local lastLoggedIdle = nil

-- Update in-memory state shared with widget
local function updateState()
    if isSystemIdle ~= lastLoggedIdle then
        lastLoggedIdle = isSystemIdle
        noctalia.log("eyecare: system idle state changed to " .. tostring(isSystemIdle))
    end

    noctalia.state.set("eyecare-in-break", inBreak)
    noctalia.state.set("eyecare-active-time", activeTime)
    noctalia.state.set("eyecare-break-timer", breakTimer)
    noctalia.state.set("eyecare-break-elapsed", breakElapsed)
    noctalia.state.set("eyecare-idle-time", idleTime)
    noctalia.state.set("eyecare-is-system-idle", isSystemIdle)
    noctalia.state.set("eyecare-active-duration-minutes", settings.active_duration_minutes)
    noctalia.state.set("eyecare-break-duration-seconds", settings.break_duration_seconds)
end

local wasSystemIdle = false

-- Tick cycle actions (every 1 second)
function update()
    noctalia.setUpdateInterval(1000)

    -- Detect transition from idle to active (unlock/wake up)
    local transitionedToActive = (wasSystemIdle and not isSystemIdle)
    wasSystemIdle = isSystemIdle

    if inBreak then
        breakTimer = breakTimer + 1
        breakElapsed = breakTimer  -- Keep breakElapsed in sync for backward compatibility
        
        if transitionedToActive then
            local grace_threshold = math.min(10, settings.break_duration_seconds)
            if breakTimer >= grace_threshold then
                -- User was away for at least the grace threshold and now returned,
                -- so consider the break completed/accepted.
                inBreak = false
                breakTimer = 0
                breakElapsed = 0
                activeTime = 0
            else
                -- User returned almost immediately, abort/cancel the break
                inBreak = false
                breakTimer = 0
                breakElapsed = 0
                activeTime = 0
            end
        elseif breakTimer >= settings.break_duration_seconds then
            -- Break completed successfully
            inBreak = false
            breakTimer = 0
            breakElapsed = 0
            activeTime = 0
            
            if settings.enable_notifications then
                noctalia.notify(
                    noctalia.tr("notifications.eyecare-break-finished-title"),
                    noctalia.tr("notifications.eyecare-break-finished-body")
                )
            end
            if settings.enable_sound then
                playSound("complete")
            end
        end
    else
        -- Not in break
        if isSystemIdle then
            idleTime = idleTime + 1
            -- Natural break detection (user rested without prompting)
            if idleTime >= settings.break_duration_seconds then
                activeTime = 0
            end
        else
            idleTime = 0
            activeTime = activeTime + 1
            if activeTime >= settings.active_duration_minutes * 60 then
                -- Trigger Break Reminder
                inBreak = true
                breakTimer = 0
                breakElapsed = 0
                activeTime = 0
                
                if settings.enable_notifications then
                    noctalia.notify(
                        noctalia.tr("notifications.eyecare-break-title"),
                        noctalia.tr("notifications.eyecare-break-body", { seconds = settings.break_duration_seconds })
                    )
                end
                if settings.enable_sound then
                    playSound("message")
                end
            end
        end
    end

    updateState()
end

-- Helper functions for timer state transitions
local function triggerBreak()
    inBreak = true
    breakTimer = 0
    breakElapsed = 0
    activeTime = 0
    
    if settings.enable_notifications then
        noctalia.notify(
            noctalia.tr("notifications.eyecare-break-title"),
            noctalia.tr("notifications.eyecare-break-body", { seconds = settings.break_duration_seconds })
        )
    end
    if settings.enable_sound then
        playSound("message")
    end
end

local function abortBreak()
    inBreak = false
    breakTimer = 0
    breakElapsed = 0
    activeTime = 0
end

local function resetTimer()
    inBreak = false
    breakTimer = 0
    breakElapsed = 0
    activeTime = 0
    idleTime = 0
end

-- Listen to compositor IPC commands
function onIpc(event, payload)
    if event == "idled" then
        isSystemIdle = true
    elseif event == "active" then
        isSystemIdle = false
    elseif event == "trigger-break" then
        triggerBreak()
    elseif event == "finish-break" or event == "abort-break" then
        abortBreak()
    elseif event == "reset" then
        resetTimer()
    end
    updateState()
end

-- Watch widget-triggered requests in-process
noctalia.state.watch("eyecare-request", function(req)
    if req == "trigger-break" then
        triggerBreak()
        noctalia.state.set("eyecare-request", nil)
    elseif req == "abort-break" then
        abortBreak()
        noctalia.state.set("eyecare-request", nil)
    elseif req == "reset" then
        resetTimer()
        noctalia.state.set("eyecare-request", nil)
    end
    updateState()
end)

-- Initialize automatic DBus monitor stream hooks (zero-config fallback)
if noctalia.commandExists("dbus-monitor") then
    noctalia.log("eyecare: dbus-monitor found, starting automatic screensaver & lock streams")
    
    local sessionLoop = 'P=$PPID; while kill -0 "$P" 2>/dev/null; do dbus-monitor --session "interface=\'org.freedesktop.ScreenSaver\'" 2>/dev/null; sleep 3; done'
    noctalia.runStream(sessionLoop, function(line)
        if string.find(line, "ActiveChanged") then
            lastLineWasActiveChanged = true
        elseif lastLineWasActiveChanged then
            lastLineWasActiveChanged = false
            if string.find(line, "true") then
                isSystemIdle = true
                updateState()
            elseif string.find(line, "false") then
                isSystemIdle = false
                updateState()
            end
        end
    end)

    local systemLoop = 'P=$PPID; while kill -0 "$P" 2>/dev/null; do dbus-monitor --system "interface=\'org.freedesktop.login1.Session\'" 2>/dev/null; sleep 3; done'
    noctalia.runStream(systemLoop, function(line)
        if string.find(line, "member=Lock") then
            isSystemIdle = true
            updateState()
        elseif string.find(line, "member=Unlock") then
            isSystemIdle = false
            updateState()
        end
    end)
else
    noctalia.log("eyecare: dbus-monitor not found on system path")
end

-- Initialize the shared state
updateState()
