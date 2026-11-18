-------------------------------------------------------------------------------
-- IP Monitor Shared Utilities
-------------------------------------------------------------------------------
local utils = {}

--- Calculates IPv4 subnet mask string (e.g. "255.255.255.0") from a CIDR prefix length (0-32).
function utils.cidrToSubnetMask(prefix)
    local n = tonumber(prefix)
    if not n or n < 0 or n > 32 then return "" end

    local mask32 = (n == 0) and 0 or bit32.lshift(0xFFFFFFFF, 32 - n)
    local o1 = bit32.rshift(mask32, 24)
    local o2 = bit32.band(bit32.rshift(mask32, 16), 0xFF)
    local o3 = bit32.band(bit32.rshift(mask32, 8), 0xFF)
    local o4 = bit32.band(mask32, 0xFF)

    return string.format("%d.%d.%d.%d", o1, o2, o3, o4)
end

--- Converts a simple glob pattern (e.g. "wlan*", "eth0") into a standard Lua pattern.
function utils.globToPattern(glob)
    local escaped = glob:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")
    local pattern = escaped:gsub("%%%*", ".*")
    return "^" .. pattern .. "$"
end

--- Calculates network address (e.g. "192.168.1.0/24") from IP, Subnet Mask, and CIDR prefix.
function utils.calculateNetwork(ipStr, maskStr, cidrStr)
    local a, b, c, d = ipStr:match("(%d+)%.(%d+)%.(%d+)%.(%d+)")
    local m1, m2, m3, m4 = maskStr:match("(%d+)%.(%d+)%.(%d+)%.(%d+)")
    if not (a and b and c and d and m1 and m2 and m3 and m4) then return "" end

    local net1 = bit32.band(tonumber(a), tonumber(m1))
    local net2 = bit32.band(tonumber(b), tonumber(m2))
    local net3 = bit32.band(tonumber(c), tonumber(m3))
    local net4 = bit32.band(tonumber(d), tonumber(m4))

    return string.format("%d.%d.%d.%d/%s", net1, net2, net3, net4, cidrStr)
end

--- Fetches IPv4 address and detailed network interface metadata.
function utils.fetchInterfaceIp(ifaceSetting, callback)
    if not ifaceSetting or ifaceSetting == "" then
        callback("", nil)
        return
    end

    local pattern = utils.globToPattern(ifaceSetting)

    noctalia.runAsync("ip -4 -o addr show", function(result)
        if result.exitCode ~= 0 then
            noctalia.log("ip-monitor: failed to get ip addr: " .. result.stderr)
            callback("", nil)
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
            callback("", nil)
            return
        end

        -- Calculate Mask and Network Range
        local mask = utils.cidrToSubnetMask(foundCidr)
        local network = ""
        if foundIp ~= "" and mask ~= "" and foundCidr ~= "" then
            network = utils.calculateNetwork(foundIp, mask, foundCidr)
        end

        -- Fetch gateway
        noctalia.runAsync("ip route show", function(routeResult)
            local gateway = ""
            if routeResult.exitCode == 0 then
                -- 1. Try finding default route for matched interface
                for line in routeResult.stdout:gmatch("[^\r\n]+") do
                    local lineDev = line:match("%sdev%s+([^%s]+)")
                    if lineDev == matchedIface then
                        local g = line:match("default via ([^%s]+)")
                        if g then
                            gateway = g
                            break
                        end
                    end
                end
                -- 2. Fallback: find any route with via for matched interface
                if gateway == "" then
                    for line in routeResult.stdout:gmatch("[^\r\n]+") do
                        local lineDev = line:match("%sdev%s+([^%s]+)")
                        if lineDev == matchedIface then
                            local g = line:match("via ([^%s]+)")
                            if g then
                                gateway = g
                                break
                            end
                        end
                    end
                end
            end

            local tooltip = {
                iface = matchedIface,
                ip = foundIp,
                network = network,
                gateway = gateway,
                mask = mask,
                broadcast = foundBrd
            }
            callback(foundIp, tooltip)
        end)
    end)
end

--- Fetches IP address by executing a custom shell command.
function utils.fetchCustomCommandIp(cmd, callback)
    if not cmd or cmd == "" then
        callback("", nil)
        return
    end

    noctalia.runAsync(cmd, function(result)
        if result.exitCode ~= 0 then
            noctalia.log("ip-monitor: custom command failed: " .. result.stderr)
            callback("", nil)
            return
        end

        local newIp = noctalia.string.trim(result.stdout)
        local tooltip = { ip = newIp }
        callback(newIp, tooltip)
    end)
end

--- Parses an IPC payload and extracts data if it matches the configured ID.
function utils.handleIpcPayload(payload, myId)
    local ok, data = pcall(noctalia.json.decode, payload)
    if not ok or type(data) ~= "table" then return nil end

    local targetId = data.id or "default"
    if targetId ~= myId then return nil end

    local tt = (type(data.tooltip) == "table") and data.tooltip or {}
    local tooltip = {
        iface = tt.iface or data.iface or data.interface or nil,
        ip = tt.ip or data.ip or nil,
        network = tt.network or data.network or nil,
        gateway = tt.gateway or data.gateway or data.default_route or nil,
        mask = tt.mask or data.mask or nil,
        broadcast = tt.broadcast or data.broadcast or nil
    }

    return {
        ip = data.ip or "",
        name = data.name or "",
        tooltip = tooltip
    }
end

--- Parses a comma-separated string of hidden fields into a Set for O(1) lookups.
-- Also maps some common aliases (e.g., "net" to "network").
function utils.parseHiddenFields(configStr)
    local hidden = {}
    if type(configStr) ~= "string" or configStr == "" then
        return hidden
    end

    local aliases = {
        ["net"] = "network",
        ["gw"] = "gateway",
        ["def"] = "gateway",
        ["route"] = "gateway"
    }

    for field in configStr:gmatch("[^,]+") do
        local cleanField = field:match("^%s*(.-)%s*$"):lower()
        if cleanField ~= "" then
            local actualField = aliases[cleanField] or cleanField
            hidden[actualField] = true
        end
    end
    return hidden
end

--- Resolves the active display name according to the active mode and IPC state.
function utils.getDisplayName(mode, currentIpcName, staticName)
    if mode == "ipc" and currentIpcName and currentIpcName ~= "" then
        return currentIpcName
    end
    return staticName or ""
end

--- Builds the top row UI components (Glyph, IP Label, Separator, Name Label).
-- @param currentIp string The IP address string
-- @param displayName string The resolved display name
-- @param fontSize integer|nil Optional font size for desktop widget
-- @return table List of UI component elements
function utils.buildTopRow(currentIp, displayName, fontSize)
    local content = {}

    local glyph = noctalia.getConfig("glyph")
    if glyph and glyph ~= "" then
        local glyphOpts = {
            name = glyph,
            color = noctalia.getConfig("glyph_color")
        }
        if fontSize then
            glyphOpts.size = fontSize
        end
        table.insert(content, ui.glyph(glyphOpts))
    end

    local hasIp = currentIp and currentIp ~= ""
    local hasName = displayName and displayName ~= ""

    local function addLabel(text, colorKey)
        if text and text ~= "" then
            local labelOpts = {
                text = text,
                color = noctalia.getConfig(colorKey)
            }
            if fontSize then
                labelOpts.fontSize = fontSize
            end
            table.insert(content, ui.label(labelOpts))
        end
    end

    if hasIp then
        addLabel(currentIp, "text_color")
    end

    if hasIp and hasName then
        local sep = noctalia.getConfig("separator")
        if sep == nil then sep = "-" end
        addLabel(sep, "separator_color")
    end

    if hasName then
        addLabel(displayName, "name_color")
    end

    return content
end

return utils
