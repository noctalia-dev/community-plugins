local config = (function()
    return {
        workDuration = noctalia.getConfig("work-duration"),
        shortBreakDuration = noctalia.getConfig("short-break-duration"),
        longBreakDuration = noctalia.getConfig("long-break-duration"),
        sessionsBeforeLongBreak = noctalia.getConfig("sessions-before-long-break"),
        autoStartBreaks = noctalia.getConfig("auto-start-breaks"),
        autoStartWork = noctalia.getConfig("auto-start-work"),
    }
end)()
noctalia.state.set("pomodoro.config", config)

local sessionData = {}
for i = 1, config.sessionsBeforeLongBreak do
    breakDuration = if i < config.sessionsBeforeLongBreak then config.shortBreakDuration else config.longBreakDuration
    table.insert(sessionData, { config.workDuration * 60, breakDuration * 60 })
end
noctalia.state.set("pomodoro.sessionData", sessionData)

local isRunning = false
local sessionPtr = { session = 1, stage = 1 }
local isDirty = false
local secondsLeft = 0

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
    elseif command == "skip" then
        isRunning = false
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
        secondsLeft = getStageTotalSeconds()
    elseif command == "resetAll" then
        isRunning = false
        sessionPtr = { session = 1, stage = 1 }
        secondsLeft = getStageTotalSeconds()
        isDirty = false
    end

    local state = getStateSnapshot()
    noctalia.state.set("pomodoro.state", state)
end)

local state = getStateSnapshot()
noctalia.state.set("pomodoro.state", state)

noctalia.setUpdateInterval(1000)
function update()
    if isRunning then
        secondsLeft -= 1
        local state = getStateSnapshot()
        noctalia.state.set("pomodoro.state", state)
    end
end
