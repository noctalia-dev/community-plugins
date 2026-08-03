-------------------------------------------------------------------------------
-- IP Monitor Desktop Widget for Noctalia
-- 
-- Monitors network IP addresses and displays details on the desktop.
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

local function copyNotifyAndLog(text, optionKey, logMessage)
    if text and text ~= "" then
        noctalia.copyToClipboard(text, "text/plain")
        noctalia.notify(noctalia.tr("name"), noctalia.tr(optionKey) .. ": " .. text)
        noctalia.log("ip-monitor: " .. logMessage .. ": " .. text)
    end
end

local function applyAction(action)
    if action == "copy_ip" then
        copyNotifyAndLog(currentIp, "settings.click.options.copy_ip", "copied IP to clipboard")
    elseif action == "copy_name" then
        copyNotifyAndLog(getDisplayName(), "settings.click.options.copy_name", "copied name to clipboard")
    end
end

-------------------------------------------------------------------------------
-- UI RENDERING
-------------------------------------------------------------------------------

--- Renders the desktop widget UI based on current state and user settings.
local function render()
    local hideOnEmpty = noctalia.getConfig("hide_on_empty")
    if hideOnEmpty == nil then hideOnEmpty = true end

    -- Omit rendering completely if no IP is present and hide_on_empty is active
    if hideOnEmpty and (not currentIp or currentIp == "") then
        desktopWidget.render(ui.row({}, {}))
        return
    end

    local ipFontSize = noctalia.getConfig("ip_font_size") or 32
    local detailsFontSize = noctalia.getConfig("details_font_size") or 16

    local displayName = getDisplayName()
    local topRowContent = utils.buildTopRow(currentIp, displayName, ipFontSize)

    local content = {}
    table.insert(content, ui.row({ gap = 8, align = "center", justify = "center" }, topRowContent))

    -- Add Details
    if currentTooltip then
        local hiddenConfig = noctalia.getConfig("hidden_fields")
        local hiddenFields = utils.parseHiddenFields(hiddenConfig)

        local colKeys = {}
        local colValues = {}
        local fields = { "iface", "ip", "network", "gateway", "mask", "broadcast" }
        for _, field in ipairs(fields) do
            if not hiddenFields[field] then
                local val = currentTooltip[field]
                if val and val ~= "" then
                    table.insert(colKeys, ui.label({ 
                        text = noctalia.tr("tooltip." .. field), 
                        fontSize = detailsFontSize,
                        color = noctalia.getConfig("details_key_color") or "primary"
                    }))
                    table.insert(colValues, ui.label({ 
                        text = val, 
                        fontSize = detailsFontSize,
                        color = noctalia.getConfig("details_value_color") or "on_surface"
                    }))
                end
            end
        end

        if #colKeys > 0 then
            table.insert(content, ui.row({ gap = 12, align = "center", justify = "center" }, {
                ui.column({ gap = 4, align = "start" }, colKeys),
                ui.column({ gap = 4, align = "start" }, colValues)
            }))
        end
    end

    desktopWidget.render(ui.column({ gap = 12, align = "center" }, content))
end

-------------------------------------------------------------------------------
-- LIFECYCLE HOOKS
-------------------------------------------------------------------------------

--- Handler for IPC messages dispatched to this widget.
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
