--!nonstrict
-- Network Toolkit — Top bar status widget
local state = noctalia.state.get("network_state") or {}
local cmdSeq = 0

local function signalGlyph(val)
    local s = tonumber(val) or 0
    return (s >= 88 and "wifi") or (s >= 63 and "wifi-3") or (s >= 38 and "wifi-2") or (s >= 13 and "wifi-1") or "wifi-0"
end

local function sendCommand(domain, action, payload)
    cmdSeq += 1
    noctalia.state.set("network_command", { domain = domain, action = action, payload = payload, nonce = os.time() .. "_" .. cmdSeq })
end

local function buildTooltip()
    local net, hs, dns, bt = state.net or {}, state.hotspot or {}, state.dns or {}, state.bluetooth or {}
    local rows = {}
    local function add(k, v) table.insert(rows, { key = k, value = v }) end

    if hs.active and net.wifiConnected then
        add("Wi-Fi", net.ssid ~= "" and net.ssid or noctalia.tr("status.wifi"))
        if net.signal and net.signal > 0 then add("Signal", tostring(net.signal) .. "%") end
        add("Hotspot", hs.ssid or "Hotspot"); add("Clients", tostring(hs.clientCount or 0))
        if net.ipAddress and net.ipAddress ~= "" then add("IP", net.ipAddress) end
    elseif hs.active then
        add("Hotspot", hs.ssid or "Hotspot"); add("Clients", tostring(hs.clientCount or 0))
    elseif net.ethernetConnected then
        add(noctalia.tr("tooltip.network"), net.interface ~= "" and net.interface or noctalia.tr("status.ethernet"))
        if net.ipAddress and net.ipAddress ~= "" then add("IP", net.ipAddress) end
        add(noctalia.tr("tooltip.band"), "Ethernet")
    elseif net.wifiConnected then
        add("SSID", net.ssid ~= "" and net.ssid or noctalia.tr("status.wifi"))
        if net.signal and net.signal > 0 then add("Signal", tostring(net.signal) .. "%") end
        add(noctalia.tr("tooltip.band"), (net.band and net.band ~= "") and net.band or "—")
        if net.ipAddress and net.ipAddress ~= "" then add("IP", net.ipAddress) end
    else
        add(noctalia.tr("tooltip.network"), noctalia.tr("status.disconnected"))
        add(noctalia.tr("tooltip.band"), "—")
    end

    add(noctalia.tr("tooltip.speed"), (net.speedFormatted and net.speedFormatted ~= "") and net.speedFormatted or "0 B/s ↓  0 B/s ↑")
    add(noctalia.tr("tooltip.dns"), (dns.activeProvider and dns.activeProvider ~= "default") and (dns.current and dns.current.label or dns.activeProvider) or noctalia.tr("panel.system_default"))

    local btStr = noctalia.tr("panel.bt_off")
    if bt.enabled then
        local cList = {}
        if bt.pairedDevices then
            for _, d in ipairs(bt.pairedDevices) do if d.connected then table.insert(cList, d.name or d.address) end end
        end
        btStr = #cList > 0 and table.concat(cList, ", ") or "On (No devices)"
    end
    add(noctalia.tr("tooltip.bluetooth"), btStr)
    add(noctalia.tr("tooltip.left_click"), noctalia.tr("tooltip.action_switch"))
    add(noctalia.tr("tooltip.right_click"), noctalia.tr("tooltip.action_toggle"))
    return rows
end

local function render()
    local color = noctalia.getConfig("color") or "on_surface_variant"
    local textColor = noctalia.getConfig("text_color") or color
    if textColor == "" then textColor = color end
    local mode = noctalia.getConfig("widget_display_mode") or "network"
    local hs, net, dns, bt = state.hotspot or {}, state.net or {}, state.dns or {}, state.bluetooth or {}

    local container = barWidget.isVertical() and ui.column or ui.row

    local isCustomDns = (dns.activeProvider and dns.activeProvider ~= "default")
    local dnsText = isCustomDns and (dns.current and dns.current.label or dns.activeProvider) or noctalia.tr("panel.system_default")
    local dnsGlyph = isCustomDns and "shield" or "shield-off"

    local function makeBlock(gName, text, gColor, showHsDot, showDnsDot)
        local dotList = {}
        if showHsDot then table.insert(dotList, ui.glyph({ name = "circle-filled", size = 9, color = "error" })) end
        if showDnsDot then table.insert(dotList, ui.glyph({ name = "circle-filled", size = 9, color = "#65ab74" })) end

        local icon = (#dotList > 0)
            and ui.row({ align = "start", gap = -6 }, { ui.glyph({ name = gName, size = 16, color = gColor or color }), ui.row({ gap = -3, align = "center" }, dotList) })
            or ui.glyph({ name = gName, size = 16, color = gColor or color })

        local items = { icon }
        if text and text ~= "" then table.insert(items, ui.label({ text = text, fontSize = 14, color = textColor })) end
        return ui.row({ gap = 5, align = "center" }, items)
    end

    local netText = net.ethernetConnected and (net.interface ~= "" and net.interface or noctalia.tr("status.ethernet")) or (net.wifiConnected and (net.ssid ~= "" and net.ssid or noctalia.tr("status.wifi")) or "")
    local hsDevs = "(" .. tostring(hs.clientCount or 0) .. "/" .. tostring(hs.maxConnections or 8) .. ")"
    local netHsText = hs.active and (netText ~= "" and (netText .. " " .. hsDevs) or hsDevs) or netText
    local netGlyph = net.ethernetConnected and "ethernet" or (net.wifiConnected and signalGlyph(net.bars or net.signal or 0) or "wifi-0")

    local btText = noctalia.tr("panel.off")
    if bt.enabled then
        local first = nil
        if bt.pairedDevices then
            for _, d in ipairs(bt.pairedDevices) do if d.connected then first = d.name or d.address; break end end
        end
        btText = first or noctalia.tr("panel.bluetooth")
    end
    local btGlyph = bt.enabled and "bluetooth" or "bluetooth-off"

    local dotsMode = noctalia.getConfig("widget_indicator_dots") or "hotspot_dns"
    local allowHsDot = (dotsMode == "hotspot_dns" or dotsMode == "hotspot")
    local allowDnsDot = (dotsMode == "hotspot_dns" or dotsMode == "dns")

    local children = {}
    local bNet = makeBlock(netGlyph, (mode:find("hotspot") and netHsText or netText), color, allowHsDot and hs.active or false, (not mode:find("dns")) and allowDnsDot and isCustomDns or false)
    local bBt = makeBlock(btGlyph, btText, nil, mode == "bluetooth" and allowHsDot and hs.active or false, mode == "bluetooth" and allowDnsDot and isCustomDns or false)
    local bDns = makeBlock(dnsGlyph, dnsText, nil, mode == "dns" and allowHsDot and hs.active or false, allowDnsDot and isCustomDns or false)

    if mode == "bluetooth" then table.insert(children, bBt)
    elseif mode == "dns" then table.insert(children, bDns)
    elseif mode == "network_hotspot" then table.insert(children, bNet)
    elseif mode == "network_bluetooth" then table.insert(children, bNet); table.insert(children, bBt)
    elseif mode == "network_dns" then table.insert(children, bNet); table.insert(children, bDns)
    elseif mode == "bluetooth_dns" then table.insert(children, bBt); table.insert(children, bDns)
    elseif mode == "network_bluetooth_dns" or mode == "network_hotspot_bluetooth_dns" then table.insert(children, bNet); table.insert(children, bBt); table.insert(children, bDns)
    else table.insert(children, bNet) end

    barWidget.render(container({ gap = 7, align = "center" }, children))
    barWidget.setTooltip(buildTooltip())
end

noctalia.state.watch("network_state", function(s) if type(s) == "table" then state = s; render() end end)
function update() state = noctalia.state.get("network_state") or state; render() end
noctalia.setUpdateInterval(1000)

function onClick() noctalia.togglePanel("autumn/network-toolkit:panel") end
function onRightClick()
    local op = noctalia.getConfig("widget_right_click") or "toggle_wifi"
    if op == "toggle_hs" then sendCommand("hotspot", "toggle")
    elseif op == "toggle_bt" then sendCommand("bluetooth", "toggle")
    else sendCommand("wifi", "toggle") end
end
function onConfigChanged() render() end
render()