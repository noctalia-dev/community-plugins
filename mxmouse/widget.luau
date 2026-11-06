--!nonstrict

local hideWhenOff = noctalia.getConfig("hide_when_off") ~= false

local function render(metaOn, errorMessage, running)
    barWidget.setGlyph("keyboard")

    if errorMessage then
        barWidget.setVisible(true)
        barWidget.setText("?")
        barWidget.setTooltip(errorMessage)
        return
    end

    if hideWhenOff and not metaOn then
        barWidget.setVisible(false)
        return
    end

    barWidget.setVisible(true)
    barWidget.setText(if metaOn then "META" else "")
    barWidget.setTooltip(if not running
        then "nnmxd is not running"
        else if metaOn then "Modifier is latched" else "No modifier is latched")
end

local function refresh()
    local runtimeDir = noctalia.getenv("XDG_RUNTIME_DIR")
    if type(runtimeDir) ~= "string" or runtimeDir == "" then
        render(false, "XDG_RUNTIME_DIR is not set; nnmxd status is unavailable.", false)
        return
    end

    local statusPath = runtimeDir .. "/mxmouse/status.json"
    if not noctalia.fileExists(statusPath) then
        render(false, "nnmxd status is unavailable. Check that the service is installed and running.", false)
        return
    end

    local contents, readError = noctalia.readFile(statusPath)
    if type(contents) ~= "string" then
        render(false, `Could not read nnmxd status: {tostring(readError)}`, false)
        return
    end

    local ok, status = pcall(noctalia.json.decode, contents)
    if not ok or type(status) ~= "table" or type(status.metaOn) ~= "boolean" then
        render(false, "Could not parse nnmxd modifier status.", false)
        return
    end

    render(status.metaOn, nil, status.running == true)
end

function update()
    noctalia.setUpdateInterval(1000)
    hideWhenOff = noctalia.getConfig("hide_when_off") ~= false
    refresh()
end

function onClick()
    noctalia.togglePanel("ffngs/mxmouse:manager")
end

refresh()
