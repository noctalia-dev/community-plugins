type Sound = {
    name: string,
    path: string,
    loaded: boolean,
}

local M = {}

local alarmSound: Sound = nil
local tickSounds: { Sound } = {}
local tockSounds: { Sound } = {}

local bypassNoctaliaSoundGlobals = false

local function playSound(sound: Sound)
    if bypassNoctaliaSoundGlobals then
        if noctalia.fileExists(sound.path) then
            local shellQuotedSoundPath = "'" .. sound.path:gsub("'", "'\\''") .. "'"
            noctalia.runAsync("ffplay -nodisp -autoexit -loglevel quiet " .. shellQuotedSoundPath)
        end
    elseif sound.loaded then
        noctalia.sound.play(sound.name)
    end
end

local LOAD_BATCH_SIZE = 8

--- Loads sound entries through noctalia.sound.load in sequential batches.
--- The host sound API rejects load requests when its queue is full, so entries
--- are submitted batchSize at a time; the next batch starts only after every
--- callback in the current batch has returned.
local function loadSounds(entries: { Sound }, batchSize: number)
    if batchSize < 1 then
        batchSize = 1
    end

    local function loadBatch(index: number)
        if index > #entries then
            return
        end

        local batchEnd = math.min(index + batchSize - 1, #entries)
        local pending = batchEnd - index + 1
        local completed = 0

        local function onBatchItemDone()
            completed += 1
            if completed >= pending then
                loadBatch(batchEnd + 1)
            end
        end

        for i = index, batchEnd do
            local sound = entries[i]
            local accepted = noctalia.sound.load(sound.name, sound.path, function(ok, err)
                sound.loaded = ok == true
                if not ok then
                    noctalia.notifyError("Couldn't load sound", sound.name .. ": " .. (err or ""))
                end
                onBatchItemDone()
            end)

            if not accepted then
                noctalia.notifyError("Couldn't queue sound", sound.name)
                onBatchItemDone()
            end
        end
    end

    loadBatch(1)
end

function M.init(opts)
    bypassNoctaliaSoundGlobals = opts.bypassNoctaliaSoundGlobals == true
    local useBundledAlarmSound = opts.useBundledAlarmSound == true
    local enableWorkTimerSound = opts.enableWorkTimerSound == true

    local pluginDir = noctalia.pluginDir()
    if not pluginDir then
        return
    end

    local resourcesDir = pluginDir .. "/resources/"
    alarmSound = {
        name = "alarm",
        path = resourcesDir .. "alarm.mp3",
        loaded = false,
    }

    for i = 1, 9 do
        if enableWorkTimerSound then
            local tickPath = resourcesDir .. "tick" .. i .. ".wav"
            if noctalia.fileExists(tickPath) then
                table.insert(tickSounds, {
                    name = "tick-" .. i,
                    path = tickPath,
                    loaded = false,
                })
            end

            local tockPath = resourcesDir .. "tock" .. i .. ".wav"
            if noctalia.fileExists(tockPath) then
                table.insert(tockSounds, {
                    name = "tock-" .. i,
                    path = tockPath,
                    loaded = false,
                })
            end
        end
    end

    local loadQueue: { Sound } = {}
    if useBundledAlarmSound then
        table.insert(loadQueue, alarmSound)
    end
    for _, sound in tickSounds do
        table.insert(loadQueue, sound)
    end
    for _, sound in tockSounds do
        table.insert(loadQueue, sound)
    end
    if #loadQueue > 0 then
        loadSounds(loadQueue, LOAD_BATCH_SIZE)
    end
end

function M.playTick()
    if #tickSounds == 0 then
        return
    end
    playSound(tickSounds[math.random(#tickSounds)])
end

function M.playTock()
    if #tockSounds == 0 then
        return
    end
    playSound(tockSounds[math.random(#tockSounds)])
end

function M.playAlarm()
    playSound(alarmSound)
end

return M
