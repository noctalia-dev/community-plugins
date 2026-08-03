-------------------------------------------------------------------------------
-- IP Monitor Widget for Noctalia
-- 
-- Monitors network IP addresses from network interfaces (with glob matching),
-- custom shell commands, or external IPC events.
-------------------------------------------------------------------------------

local utils = require("./utils.luau")

-- Current runtime state
local currentIp = ""
local currentIpcName = ""
local currentTooltip = nil

-------------------------------------------------------------------------------
-- HELPER FUNCTIONS
-------------------------------------------------------------------------------

--- Resolves the active display name according to active mode and IPC state.
local function getDisplayName()
    return utils.getDisplayName(noctalia.getConfig("mode"), currentIpcName, noctalia.getConfig("name"))
end

--- Updates the widget hover tooltip from the currentTooltip table.
local function updateTooltip()
    if not currentTooltip then
        barWidget.setTooltip(nil)
        return
    end

    local hiddenConfig = noctalia.getConfig("hidden_fields")
    local hiddenFields = utils.parseHiddenFields(hiddenConfig)

    local rows = {}
    local fields = { "iface", "ip", "network", "gateway", "mask", "broadcast" }
    for _, field in ipairs(fields) do
        if not hiddenFields[field] then
            local val = currentTooltip[field]
            if val and val ~= "" then
                table.insert(rows, { key = noctalia.tr("tooltip." .. field), value = val })
            end
        end
    end

    if #rows > 0 then
        barWidget.setTooltip(rows)
    else
        barWidget.setTooltip(nil)
    end
end

-------------------------------------------------------------------------------
-- UI RENDERING
-------------------------------------------------------------------------------

--- Renders the bar widget UI based on current state and user settings.
local function render()
    local hideOnEmpty = noctalia.getConfig("hide_on_empty")
    if hideOnEmpty == nil then hideOnEmpty = true end

    -- Omit widget rendering completely if no IP is present and hide_on_empty is active
    if hideOnEmpty and (not currentIp or currentIp == "") then
        barWidget.setTooltip(nil)
        barWidget.render(ui.row({}, {}))
        return
    end

    -- Update widget hover tooltip
    updateTooltip()

    local displayName = getDisplayName()
    local content = utils.buildTopRow(currentIp, displayName)

    -- Layout container according to bar orientation (Vertical -> column, Horizontal -> row)
    local container = barWidget.isVertical() and ui.column or ui.row
    barWidget.render(container({ gap = 6, align = "center" }, content))
end

-------------------------------------------------------------------------------
-- ACTIONS & HANDLERS
-------------------------------------------------------------------------------

local function copyNotifyAndLog(text, optionKey, logMessage)
    if text and text ~= "" then
        noctalia.copyToClipboard(text, "text/plain")
        noctalia.notify(noctalia.tr("name"), noctalia.tr(optionKey) .. ": " .. text)
        noctalia.log("ip-monitor: " .. logMessage .. ": " .. text)
    end
end

--- Executes click / IPC actions (e.g. copy IP or copy Name to clipboard).
-- @param action string The action identifier ("copy_ip" or "copy_name")
local function applyClickAction(action)
    if action == "copy_ip" then
        copyNotifyAndLog(currentIp, "settings.click.options.copy_ip", "copied IP to clipboard")
    elseif action == "copy_name" then
        copyNotifyAndLog(getDisplayName(), "settings.click.options.copy_name", "copied name to clipboard")
    end
end

--- Handler for left click action on the bar widget.
function onClick()
    local action = noctalia.getConfig("left_click_action") or "copy_ip"
    if action ~= "none" then
        applyClickAction(action)
    end
end

--- Handler for right click action on the bar widget.
function onRightClick()
    local action = noctalia.getConfig("right_click_action") or "copy_name"
    if action ~= "none" then
        applyClickAction(action)
    end
end

--- Handler for IPC messages dispatched to this widget.
-- @param event string The IPC event name
-- @param payload string The JSON payload string
function onIpc(event, payload)
    if noctalia.getConfig("mode") ~= "ipc" then return end

    if event == "set" then
        local myId = noctalia.getConfig("ipc_id") or "default"
        local data = utils.handleIpcPayload(payload, myId)
        if data then
            currentIp = data.ip
            currentIpcName = data.name
            currentTooltip = data.tooltip
            render()
        end
    end
end

-------------------------------------------------------------------------------
-- LIFECYCLE HOOKS
-------------------------------------------------------------------------------

--- Primary update entry point called periodically by Noctalia script runtime.
function update()
    local mode = noctalia.getConfig("mode")
    if mode == "interface" then
        utils.fetchInterfaceIp(noctalia.getConfig("iface"), function(ip, tooltip)
            currentIp = ip
            currentTooltip = tooltip
            render()
        end)
    elseif mode == "custom_command" then
        utils.fetchCustomCommandIp(noctalia.getConfig("custom_command"), function(ip, tooltip)
            currentIp = ip
            currentTooltip = tooltip
            render()
        end)
    end
end

--- Config change handler called automatically when user alters widget settings.
function onConfigChanged()
    local mode = noctalia.getConfig("mode")
    currentIp = ""
    currentIpcName = ""
    currentTooltip = nil

    if mode == "interface" or mode == "custom_command" then
        local interval = noctalia.getConfig("refresh_interval") or 60
        noctalia.setUpdateInterval(interval * 1000)
        update()
    else
        -- IPC mode doesn't need periodic updates
        noctalia.setUpdateInterval(0)
        render()
    end
end

-- Initial setup upon loading widget
onConfigChanged()
