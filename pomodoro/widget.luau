function onClick()
    noctalia.togglePanel("thepunkoff/pomodoro:panel")
end

local isUpdating = false
noctalia.state.watch("pomodoro.nextCommand", function(command)
    if command == "toggle" then
        isUpdating = true 
    elseif command == "resetAll" then
        isUpdating = false
        barWidget.setGlyph("brain")
        barWidget.setGlyphColor("default")
        barWidget.setColor("default")
        barWidget.setText("")
    end
end)

--- main
barWidget.setGlyph("brain")

noctalia.state.watch("pomodoro.state", function(state)
    if not isUpdating then
        return
    end

    local stageIcon = if state.sessionPtr.stage == 1 then "brain" else "coffee"
    barWidget.setGlyph(stageIcon)

    if state.isRunning then
        barWidget.setGlyphColor("primary")
        barWidget.setColor("primary")
    else
        barWidget.setGlyphColor("default")
        barWidget.setColor("default")
    end

    local hours = math.floor(state.secondsLeft / 3600)
    local mins = math.floor((state.secondsLeft % 3600) / 60)
    local secs = state.secondsLeft % 60

    local time = if secs < 3600 then string.format("%02d:%02d", mins, secs) else string.format("%d:%02d:%02d", hours, mins, secs)
    barWidget.setText(time)
end)
