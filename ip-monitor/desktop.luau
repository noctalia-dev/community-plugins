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

--- Resolves the active display name according to the active mode and IPC state.
local function getDisplayName()
    local mode = noctalia.getConfig("mode")
    if mode == "ipc" then
        if currentIpcName ~= "" then
            return currentIpcName
        end
    end
    return noctalia.getConfig("name") or ""
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
    local hasIp = currentIp and currentIp ~= ""
    local hasName = displayName and displayName ~= ""

    local topRowContent = {}

    -- 1. Icon / Glyph
    local glyph = noctalia.getConfig("glyph")
    if glyph and glyph ~= "" then
        table.insert(topRowContent, ui.glyph({
            name = glyph,
            size = ipFontSize,
            color = noctalia.getConfig("glyph_color")
        }))
    end

    -- 2. IP Text Label
    if hasIp then
        table.insert(topRowContent, ui.label({
            text = currentIp,
            fontSize = ipFontSize,
            color = noctalia.getConfig("text_color")
        }))
    end

    -- 3. Separator Label
    if hasIp and hasName then
        local sep = noctalia.getConfig("separator")
        if sep == nil then sep = "-" end
        table.insert(topRowContent, ui.label({
            text = sep,
            fontSize = ipFontSize,
            color = noctalia.getConfig("separator_color")
        }))
    end

    -- 4. Name Text Label
    if hasName then
        table.insert(topRowContent, ui.label({
            text = displayName,
            fontSize = ipFontSize,
            color = noctalia.getConfig("name_color")
        }))
    end

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
        local interval = noctalia.getConfig("refresh_interval") or 10
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
