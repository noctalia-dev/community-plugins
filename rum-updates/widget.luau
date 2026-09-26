--!nonstrict

local hideWhenEmpty = noctalia.getConfig("hide_when_empty") == true
local notify = noctalia.getConfig("notify") == true
local glyph = noctalia.getConfig("glyph") or "package"
local terminalApplication = noctalia.string.trim(noctalia.getConfig("terminal_application") or "")
local clickAction = noctalia.getConfig("click_action") or "run_updater"
if clickAction ~= "run_updater" then
    clickAction = "open_software_center"
end

local stateUpdates = noctalia.state.get("updates")
if type(stateUpdates) ~= "table" then
    stateUpdates = {}
end

local stateError = noctalia.state.get("update_error")
if type(stateError) ~= "string" or stateError == "" then
    stateError = nil
end

local previousCount = #stateUpdates
local hasReceivedUpdateState = false
local count = #stateUpdates
local updateError = stateError
local isChecking = noctalia.state.get("update_checking") == true

local function checkNowRow()
    local hint = noctalia.tr("tooltip.check_now_hint")
    if isChecking then
        hint = noctalia.tr("tooltip.checking")
    end

    return {
        key = noctalia.tr("tooltip.check_now"),
        value = hint,
    }
end

local function renderTooltip()
    if updateError ~= nil then
        barWidget.setTooltip({
            {
                key = noctalia.tr("tooltip.error"),
                value = updateError,
            },
            checkNowRow(),
        })
        return
    end

    local rows = {
        {
            key = noctalia.tr("tooltip.package_updates"),
            value = tostring(count),
        },
    }

    for _, update in ipairs(stateUpdates) do
        local name = string.format("%s.%s", update.name, update.arch)
        local change = string.format(
            "%s → %s",
            update.current_version,
            update.version
        )
        table.insert(rows, { key = name, value = change })
        table.insert(rows, {
            key = "",
            value = noctalia.tr("tooltip.repository", { repo = update.repo }),
        })
    end

    table.insert(rows, checkNowRow())
    barWidget.setTooltip(rows)
end

local function render()
    local visible = updateError ~= nil or not hideWhenEmpty or count > 0
    local text = noctalia.tr("bar.text.error")

    if updateError == nil then
        if count == 1 then
            text = noctalia.tr("bar.text.single")
        else
            text = noctalia.tr("bar.text.plural", { count = count })
        end
    end

    local container = barWidget.isVertical() and ui.column or ui.row
    barWidget.render(container({
        gap = 6,
        align = "center",
        visible = visible,
    }, {
        ui.glyph({ name = glyph, size = 14 }),
        ui.label({ text = text }),
    }))

    renderTooltip()
end

noctalia.state.watch("updates", function(value)
    if type(value) ~= "table" then
        value = {}
    end

    local nextCount = #value
    if hasReceivedUpdateState and notify and nextCount > previousCount then
        noctalia.notify(
            noctalia.tr("bar.notify.new_updates.title"),
            noctalia.tr("bar.notify.new_updates.description", { count = nextCount })
        )
    end

    stateUpdates = value
    count = nextCount
    previousCount = nextCount
    hasReceivedUpdateState = true
    render()
end)

noctalia.state.watch("update_error", function(value)
    if type(value) ~= "string" or value == "" then
        updateError = nil
    else
        updateError = value
    end
    render()
end)

noctalia.state.watch("update_checking", function(value)
    isChecking = value == true
    renderTooltip()
end)

local function shellQuote(value)
    local quoted = value:gsub("'", "'\\''")
    return `'{quoted}'`
end

local function runUpdater()
    if not noctalia.commandExists("rum") then
        noctalia.notifyError("RUM Updates", noctalia.tr("bar.notify.missing_rum"))
        return
    end

    local command = "sudo rum system-upgrade"
    if terminalApplication == "" then
        if noctalia.runInTerminal(command) then
            return
        end
    else
        local executable = noctalia.expandPath(terminalApplication)
        if not noctalia.commandExists(executable) then
            noctalia.notifyError("RUM Updates", noctalia.tr("bar.notify.terminal_launch_failed"))
            return
        end

        local terminalName = executable:match("([^/]+)$") or executable
        local separator = "-e"
        if terminalName == "gnome-terminal" or terminalName == "kgx" or terminalName == "ptyxis" then
            separator = "--"
        end

        local launchCommand = `{shellQuote(executable)} {separator} sh -lc {shellQuote(command)}`
        if noctalia.runAsync(launchCommand) then
            return
        end
    end

    noctalia.notifyError("RUM Updates", noctalia.tr("bar.notify.terminal_launch_failed"))
end

function onClick()
    if clickAction == "run_updater" then
        runUpdater()
        return
    end

    if not noctalia.commandExists("rakuos-software") then
        noctalia.notifyError(
            "RUM Updates",
            noctalia.tr("bar.notify.missing_software_center")
        )
        return
    end
    noctalia.runAsync("rakuos-software")
end

function onRightClick()
    if isChecking then
        return
    end

    local started = noctalia.runAsync(
        "noctalia msg plugin etrigan63/rum-updates:update_poller all refresh"
    )
    if not started then
        noctalia.notifyError(
            "RUM Updates",
            noctalia.tr("bar.notify.refresh_failed")
        )
    end
end

render()
