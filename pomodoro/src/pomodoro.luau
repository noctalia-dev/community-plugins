local config = (function()
    return {
        workDuration = noctalia.getConfig("work-duration") or 25,
        shortBreakDuration = noctalia.getConfig("short-break-duration") or 5,
        longBreakDuration = noctalia.getConfig("long-break-duration") or 15,
        sessionsBeforeLongBreak = noctalia.getConfig("sessions-before-long-break") or 4,
        autoStartBreaks = noctalia.getConfig("auto-start-breaks") == true,
        autoStartWork = noctalia.getConfig("auto-start-work") == true,
        useBundledAlarmSound = noctalia.getConfig("use-bundled-alarm-sound") == true,
        enableWorkTimerSound = noctalia.getConfig("enable-work-timer-sound") == true,
        bypassNoctaliaSoundGlobals = noctalia.getConfig("bypass-noctalia-sound-globals") == true,
    }
end)()
noctalia.state.set("pomodoro.config", config)

local sessionData = {}
for i = 1, config.sessionsBeforeLongBreak do
    local breakDuration = if i < config.sessionsBeforeLongBreak then config.shortBreakDuration else config.longBreakDuration
    table.insert(sessionData, { config.workDuration * 60, breakDuration * 60 })
end
noctalia.state.set("pomodoro.sessionData", sessionData)

local sounds = require("./src/sounds.luau")
sounds.init({
    bypassNoctaliaSoundGlobals = config.bypassNoctaliaSoundGlobals,
    useBundledAlarmSound = config.useBundledAlarmSound,
    enableWorkTimerSound = config.enableWorkTimerSound,
})

local isRunning = false
local sessionPtr = { session = 1, stage = 1 }
local isDirty = false
local secondsLeft = 0
local tickAnchorSecond = nil
local lastProcessedSecond = nil

local function resetTickClock()
    tickAnchorSecond = nil
    lastProcessedSecond = nil
end

local function getStateSnapshot()
    return {
        isRunning = isRunning,
        secondsLeft = secondsLeft,
        sessionPtr = sessionPtr,
        isDirty = isDirty,
    }
end

local function getStageTotalSeconds()
    local sessionNumber = sessionPtr.session
    local session = sessionData[sessionNumber]
    local stageNumber = sessionPtr.stage
    return session[stageNumber]
end

--- main
secondsLeft = getStageTotalSeconds()

noctalia.state.watch("pomodoro.nextCommand", function(command)
    if command == "toggle" then
        isDirty = true
        isRunning = not isRunning
        resetTickClock()
    elseif command == "skip" then
        isRunning = false
        resetTickClock()
        if sessionPtr.stage == 1 then
            sessionPtr.stage = 2
        elseif sessionPtr.session < #sessionData then
            sessionPtr.session += 1
            sessionPtr.stage = 1
        elseif sessionPtr.session == #sessionData then
            sessionPtr = { session = 1, stage = 1 }
        end
        secondsLeft = getStageTotalSeconds()
    elseif command == "reset" then
        isRunning = false
        resetTickClock()
        secondsLeft = getStageTotalSeconds()
    elseif command == "resetAll" then
        isRunning = false
        resetTickClock()
        sessionPtr = { session = 1, stage = 1 }
        secondsLeft = getStageTotalSeconds()
        isDirty = false
    end

    local state = getStateSnapshot()
    noctalia.state.set("pomodoro.state", state)
end)

local state = getStateSnapshot()
noctalia.state.set("pomodoro.state", state)

noctalia.setUpdateInterval(250)
function update()
    if not isRunning then
        return
    end

    local second = math.floor(noctalia.nowMs() / 1000)
    if tickAnchorSecond == nil then
        tickAnchorSecond = second
        lastProcessedSecond = second
        return
    end

    if second <= lastProcessedSecond then
        return
    end

    local stateChanged = false
    for s = lastProcessedSecond + 1, second do
        if s > tickAnchorSecond and secondsLeft > 0 then
            secondsLeft -= 1

            local offset = s - tickAnchorSecond
            if offset > 0 and config.enableWorkTimerSound and sessionPtr.stage == 1 then
                if offset % 2 == 1 then
                    sounds.playTick()
                else
                    sounds.playTock()
                end
            end
            stateChanged = true
        end
    end
    lastProcessedSecond = second

    if stateChanged then
        noctalia.state.set("pomodoro.state", getStateSnapshot())
    end
end

local function notifyStageFinished(state, sessionData)
    local sessionNumber = state.sessionPtr.session
    local stageNumber = state.sessionPtr.stage
    local body =
        if stageNumber == 1 then
            noctalia.tr("notification.work-complete")
        elseif sessionNumber < #sessionData then
            noctalia.tr("notification.short-break-complete")
        else
            noctalia.tr("notification.long-break-complete")

    if config.useBundledAlarmSound then
        sounds.playAlarm()
    end

    noctalia.notify("Pomodoro Timer", body)
end

noctalia.state.watch("pomodoro.state", function(state)
    if state.secondsLeft == 0 then
        notifyStageFinished(state, sessionData)
        noctalia.state.set("pomodoro.nextCommand", "skip")
        if (config.autoStartWork and state.sessionPtr.stage == 2) or (config.autoStartBreaks and state.sessionPtr.stage == 1) then
            noctalia.state.set("pomodoro.nextCommand", "toggle")
        end
    end
end)
