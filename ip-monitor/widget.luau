-------------------------------------------------------------------------------
-- IP Monitor Widget for Noctalia
-- 
-- Monitors network IP addresses from network interfaces (with glob matching),
-- custom shell commands, or external IPC events.
-------------------------------------------------------------------------------

-- Current runtime state
local currentIp = ""
local currentIpcName = ""
local currentTooltip = nil

--- Calculates IPv4 subnet mask string (e.g. "255.255.255.0") from a CIDR prefix length (0-32).
-- @param prefix string|number CIDR prefix length
-- @return string The formatted subnet mask string
local function cidrToSubnetMask(prefix)
    local n = tonumber(prefix)
    if not n or n < 0 or n > 32 then return "" end

    local octets = {}
    for i = 1, 4 do
        if n >= 8 then
            table.insert(octets, 255)
            n = n - 8
        elseif n > 0 then
            local octet = 256 - (2 ^ (8 - n))
            table.insert(octets, math.floor(octet))
            n = 0
        else
            table.insert(octets, 0)
        end
    end
    return table.concat(octets, ".")
end

-------------------------------------------------------------------------------
-- HELPER FUNCTIONS
-------------------------------------------------------------------------------

--- Resolves the active display name according to the active mode and IPC state.
-- @return string The resolved display name to render or copy
local function getDisplayName()
    local mode = noctalia.getConfig("mode")
    if mode == "ipc" then
        if currentIpcName ~= "" then
            return currentIpcName
        end
    end
    return noctalia.getConfig("name") or ""
end

--- Converts a simple glob pattern (e.g. "wlan*", "eth0") into a standard Lua pattern.
-- @param glob string The glob pattern to convert
-- @return string The converted Lua pattern
local function globToPattern(glob)
    local pattern = glob:gsub("%.", "%%."):gsub("%*", ".*")
    return "^" .. pattern .. "$"
end

--- Calculates network address (e.g. "192.168.1.0/24") from IP, Subnet Mask, and CIDR prefix.
-- @param ipStr string IP address (e.g. "192.168.1.33")
-- @param maskStr string Subnet mask (e.g. "255.255.255.0")
-- @param cidrStr string CIDR prefix string (e.g. "24")
-- @return string The calculated network range string
local function calculateNetwork(ipStr, maskStr, cidrStr)
    local a, b, c, d = ipStr:match("(%d+)%.(%d+)%.(%d+)%.(%d+)")
    local m1, m2, m3, m4 = maskStr:match("(%d+)%.(%d+)%.(%d+)%.(%d+)")
    if not (a and b and c and d and m1 and m2 and m3 and m4) then return "" end

    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    m1, m2, m3, m4 = tonumber(m1), tonumber(m2), tonumber(m3), tonumber(m4)

    local function applyMask(ipPart, maskPart)
        return (maskPart == 255) and ipPart or (maskPart == 0 and 0 or (ipPart - (ipPart % (256 - maskPart))))
    end

    local net1 = applyMask(a, m1)
    local net2 = applyMask(b, m2)
    local net3 = applyMask(c, m3)
    local net4 = applyMask(d, m4)

    return string.format("%d.%d.%d.%d/%s", net1, net2, net3, net4, cidrStr)
end

--- Updates the widget hover tooltip from the currentTooltip table.
local function updateTooltip()
    if not currentTooltip then
        barWidget.setTooltip(nil)
        return
    end

    local rows = {}
    local fields = { "iface", "ip", "network", "gateway", "mask", "broadcast" }
    for _, field in ipairs(fields) do
        local val = currentTooltip[field]
        if val and val ~= "" then
            table.insert(rows, { key = noctalia.tr("tooltip." .. field), value = val })
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

    local content = {}
    local displayName = getDisplayName()

    -- 1. Icon / Glyph
    local glyph = noctalia.getConfig("glyph")
    if glyph and glyph ~= "" then
        table.insert(content, ui.glyph({
            name = glyph,
            color = noctalia.getConfig("glyph_color")
        }))
    end

    local hasIp = currentIp and currentIp ~= ""
    local hasName = displayName and displayName ~= ""

    local function addLabel(text, colorConfig)
        if text and text ~= "" then
            table.insert(content, ui.label({
                text = text,
                color = noctalia.getConfig(colorConfig)
            }))
        end
    end

    -- 2. IP Text Label
    if hasIp then
        addLabel(currentIp, "text_color")
    end

    -- 3. Separator Label (rendered only when both IP and Name exist)
    if hasIp and hasName then
        local sep = noctalia.getConfig("separator")
        if sep == nil then sep = "-" end
        addLabel(sep, "separator_color")
    end

    -- 4. Name Text Label
    if hasName then
        addLabel(displayName, "name_color")
    end

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
    applyClickAction("copy_ip")
end

--- Handler for right click action on the bar widget.
function onRightClick()
    applyClickAction("copy_name")
end

--- Handler for IPC messages dispatched to this widget.
-- @param event string The IPC event name
-- @param payload string The JSON payload string
function onIpc(event, payload)
    if event == "copy_ip" then
        applyClickAction("copy_ip")
        return
    elseif event == "copy_name" then
        applyClickAction("copy_name")
        return
    end

    if noctalia.getConfig("mode") ~= "ipc" then return end

    if event == "set" then
        local data = noctalia.json.decode(payload)
        if data then
            local targetId = data.id or "default"
            local myId = noctalia.getConfig("ipc_id") or "default"

            if targetId == myId then
                currentIp = data.ip or ""
                currentIpcName = data.name or ""

                -- Parse optional tooltip data from payload (supports nested object or top-level keys)
                local tt = (type(data.tooltip) == "table") and data.tooltip or {}
                currentTooltip = {
                    iface = tt.iface or data.iface or data.interface or nil,
                    ip = tt.ip or data.ip or nil,
                    network = tt.network or data.network or nil,
                    gateway = tt.gateway or data.gateway or data.default_route or nil,
                    mask = tt.mask or data.mask or nil,
                    broadcast = tt.broadcast or data.broadcast or nil
                }

                render()
            end
        end
    end
end

-------------------------------------------------------------------------------
-- IP DATA FETCHERS
-------------------------------------------------------------------------------

--- Fetches IPv4 address and detailed network interface metadata using `ip -4 -o addr show`.
local function fetchInterfaceIp()
    local ifaceSetting = noctalia.getConfig("iface") or ""
    if ifaceSetting == "" then return end

    local pattern = globToPattern(ifaceSetting)

    noctalia.runAsync("ip -4 -o addr show", function(result)
        if result.exitCode ~= 0 then
            noctalia.log("ip-monitor: failed to get ip addr: " .. result.stderr)
            return
        end

        local matchedIface = nil
        local foundIp = ""
        local foundCidr = ""
        local foundBrd = ""

        for line in result.stdout:gmatch("[^\r\n]+") do
            local ifaceName, inetInfo = line:match("%d+:%s+([^%s]+)%s+inet%s+([^%s]+)")
            if ifaceName and inetInfo and ifaceName:match(pattern) then
                local ipOnly, cidr = inetInfo:match("([^/]+)/(%d+)")
                if ipOnly then
                    matchedIface = ifaceName
                    foundIp = ipOnly
                    foundCidr = cidr or ""
                    foundBrd = line:match("%s+brd%s+([^%s]+)") or ""
                    break
                end
            end
        end

        if not matchedIface or foundIp == "" then
            currentIp = ""
            currentTooltip = nil
            render()
            return
        end

        -- Calculate Mask and Network Range
        local mask = cidrToSubnetMask(foundCidr)
        local network = ""
        if foundIp ~= "" and mask ~= "" and foundCidr ~= "" then
            network = calculateNetwork(foundIp, mask, foundCidr)
        end

        -- Fetch gateway via `ip route show dev <matchedIface>`
        noctalia.runAsync("ip route show dev " .. matchedIface, function(routeResult)
            local gateway = ""
            if routeResult.exitCode == 0 then
                for line in routeResult.stdout:gmatch("[^\r\n]+") do
                    local g = line:match("default via ([^%s]+)") or line:match("via ([^%s]+)")
                    if g then
                        gateway = g
                        break
                    end
                end
            end

            currentIp = foundIp
            currentTooltip = {
                iface = matchedIface,
                ip = foundIp,
                network = network,
                gateway = gateway,
                mask = mask,
                broadcast = foundBrd
            }
            render()
        end)
    end)
end

--- Fetches IP address by executing a custom shell command.
local function fetchCustomCommandIp()
    local cmd = noctalia.getConfig("custom_command") or ""
    if cmd == "" then return end

    noctalia.runAsync(cmd, function(result)
        if result.exitCode ~= 0 then
            noctalia.log("ip-monitor: custom command failed: " .. result.stderr)
            return
        end

        local newIp = noctalia.string.trim(result.stdout)
        currentIp = newIp
        currentTooltip = {
            ip = newIp
        }
        render()
    end)
end

-------------------------------------------------------------------------------
-- LIFECYCLE HOOKS
-------------------------------------------------------------------------------

--- Primary update entry point called periodically by Noctalia script runtime.
function update()
    local mode = noctalia.getConfig("mode")
    if mode == "interface" then
        fetchInterfaceIp()
    elseif mode == "custom_command" then
        fetchCustomCommandIp()
    end
end

--- Config change handler called automatically when user alters widget settings.
function onConfigChanged()
    local mode = noctalia.getConfig("mode")
    currentIp = ""
    currentIpcName = ""
    currentTooltip = nil<

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
