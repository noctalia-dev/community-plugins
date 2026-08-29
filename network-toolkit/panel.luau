--!nonstrict
-- Network Toolkit panel UI
local state = noctalia.state.get("network_state") or {}
local customDnsInput, passwordInput, selectedSsid = "", "", nil
local showPassword, showWifiQr, qrLoading, showHsQr = false, false, false, false
local qrImagePath, qrHsPath = "/tmp/network-toolkit-wifi-qr.png", "/tmp/network-toolkit-hotspot-qr.png"
local hoveredId, cmdSeq, animFrame = nil, 0, 0
local activeLeftCard, activeRightCard = "wifi", "bluetooth"
local dismissedPairingAddresses, removedDevices, deviceActionOverrides = {}, {}, {}
local btConnecting, wifiConnectingSsid = {}, nil

local LOADER = { "loader", "loader-2", "loader-3", "loader-quarter" }

local function signalGlyph(val)
    local s = tonumber(val) or 0
    return (s >= 88 and "wifi") or (s >= 63 and "wifi-3") or (s >= 38 and "wifi-2") or (s >= 13 and "wifi-1") or "wifi-0"
end

local function sendCommand(domain, action, payload)
    cmdSeq += 1
    noctalia.state.set("network_command", { domain = domain, action = action, payload = payload, nonce = os.time() .. "_" .. cmdSeq })
end

local function generateWifiQr(ssid, security, renderFn)
    if not ssid or ssid == "" then return end
    qrLoading = true; renderFn()
    local safe = ssid:gsub("'", "'\\''")
    noctalia.runAsync(string.format("nmcli -s -g 802-11-wireless-security.psk connection show '%s' 2>/dev/null || nmcli -s -g 802-11-wireless-security.psk connection show id '%s' 2>/dev/null", safe, safe), function(res)
        local psk = (res.stdout or ""):gsub("%s+", "")
        local sec = (security == "Open" or (psk == "" and security ~= "WPA2" and security ~= "WPA")) and "nopass" or "WPA"
        noctalia.runAsync(string.format("qrencode -s 6 -m 2 -o '%s' 'WIFI:T:%s;S:%s;P:%s;;' 2>/dev/null", qrImagePath, sec, safe, psk:gsub("'", "'\\''")), function()
            qrLoading = false; renderFn()
        end, 4000)
    end, 4000)
end

local function generateHsQr(renderFn)
    local s = (state.hotspot and state.hotspot.ssid ~= "") and state.hotspot.ssid or (noctalia.getConfig("hotspot_ssid") or "Noctalia-Hotspot")
    local p = noctalia.getConfig("hotspot_password") or "noctaliapass"
    if p == "" or #p < 8 then p = "noctaliapass" end
    noctalia.runAsync(string.format("qrencode -s 6 -m 2 -o '%s' 'WIFI:T:WPA;S:%s;P:%s;;' 2>/dev/null", qrHsPath, s:gsub("'", "'\\''"), p:gsub("'", "'\\''")), function() renderFn() end, 4000)
end

local render

local function setHover(id, hState)
    local target = (hState == "true") and id or nil
    if hoveredId ~= target then hoveredId = target; if render then render() end end
end

local function hintRow(text, glyph, color)
    return ui.row({ align = "center", gap = 6, paddingV = 3, paddingH = 2 }, {
        ui.glyph({ name = glyph or "info-circle", size = 14, color = color or "on_surface_variant" }),
        ui.label({ text = text, fontSize = 11, color = color or "on_surface_variant" })
    })
end

local function renderDeviceRow(key, label, sublabel, glyphName, glyphColor, isHovered, isSelected, rightExtras, onClick)
    local leftItems = { ui.glyph({ name = glyphName, size = 18, color = glyphColor or "on_surface_variant" }) }
    if sublabel and sublabel ~= "" then
        table.insert(leftItems, ui.column({ gap = 0, paddingB = 2 }, {
            ui.label({ text = label, fontSize = 13, fontWeight = isSelected and "bold" or "normal", color = "on_surface" }),
            ui.label({ text = sublabel, fontSize = 11, color = "on_surface_variant" }),
        }))
    else
        table.insert(leftItems, ui.label({ text = label, fontSize = 13, fontWeight = isSelected and "bold" or "normal", color = "on_surface" }))
    end
    return ui.row({
        key = "row-" .. key, align = "center", justify = "space_between",
        fill = isSelected and "primary_container" or "surface",
        border = (isHovered or isSelected) and "primary" or "surface",
        borderWidth = 1, radius = 8, height = 45, paddingV = 8, paddingH = 12,
        onHover = function(s) setHover(key, s) end
    }, {
        ui.row({ align = "center", gap = 10, flexGrow = 1, onClick = onClick }, leftItems),
        ui.row({ align = "center", gap = 8 }, rightExtras or {})
    })
end

local function smallBtn(glyph, variant, onClick)
    return ui.button({ glyph = glyph, glyphSize = 14, width = 28, height = 28, variant = variant or "ghost", contentAlign = "center", onClick = onClick })
end

render = function()
    state = noctalia.state.get("network_state") or state
    local hs, net, dns, bt = state.hotspot or {}, state.net or {}, state.dns or {}, state.bluetooth or {}
    local hsActive = (hs.active == true) or (net.hotspotActive == true)
    local isConn = net.wifiConnected or net.ethernetConnected
    local connTitle = net.ethernetConnected and (net.interface ~= "" and net.interface or noctalia.tr("status.ethernet"))
        or (net.wifiConnected and (net.ssid ~= "" and net.ssid or noctalia.tr("status.wifi"))
        or (hsActive and (hs.ssid or noctalia.tr("status.hotspot_active")) or noctalia.tr("status.disconnected")))

    local connIp = (isConn and net.ipAddress ~= "") and (" (" .. net.ipAddress .. ")") or ""
    local connDetails = isConn and (connTitle .. connIp .. " • " .. tostring(net.signal or 0) .. "% • " .. (net.band ~= "" and net.band or "—") .. (hsActive and (" • Hotspot (" .. tostring(hs.clientCount or 0) .. ")") or ""))
        or (hsActive and (connTitle .. " • " .. tostring(hs.clientCount or 0) .. " Clients • Hotspot") or (connTitle .. " • —"))

    local spinner = LOADER[(animFrame % #LOADER) + 1]
    local isCustomDns = (dns.activeProvider ~= nil and dns.activeProvider ~= "default")
    local dnsLabel = isCustomDns and (dns.current and dns.current.label or dns.activeProvider) or noctalia.tr("panel.system_default")

    local subInfo = {
        ui.row({ align = "center", gap = 6 }, {
            ui.glyph({ name = isCustomDns and "shield" or "shield-off", size = 15, color = isCustomDns and "primary" or "on_surface_variant" }),
            ui.label({ text = noctalia.tr("panel.dns_prefix"), fontSize = 12, fontWeight = "bold", color = "on_surface_variant" }),
            ui.label({ text = dnsLabel, fontSize = 12, color = "on_surface" }),
        })
    }
    if bt.pairedDevices then
        for _, d in ipairs(bt.pairedDevices) do
            if d.connected then
                table.insert(subInfo, ui.row({ align = "center", gap = 6 }, {
                    ui.glyph({ name = d.icon or "bluetooth", size = 15, color = "primary" }),
                    ui.label({ text = noctalia.tr("panel.bt_prefix"), fontSize = 12, fontWeight = "bold", color = "on_surface_variant" }),
                    ui.label({ text = d.name or d.address, fontSize = 12, color = "on_surface" }),
                    smallBtn("bluetooth-off", "ghost", function() sendCommand("bluetooth", "disconnect", { address = d.address }) end)
                }))
            end
        end
    end

    local connCard = ui.column({ gap = 6, fill = "surface_variant", radius = 12, paddingV = 8, paddingH = 10 }, {
        ui.label({ text = noctalia.tr("panel.current_connection"), fontSize = 13, fontWeight = "bold", color = "on_surface" }),
        ui.row({ align = "center", justify = "space_between" }, {
            ui.label({ text = connDetails, fontSize = 12, fontWeight = "bold", color = "on_surface" }),
            ui.button({
                glyph = isConn and "plug-off" or (hsActive and "broadcast-off" or "plug"), glyphSize = 16,
                variant = (isConn or hsActive) and "destructive" or "primary", contentAlign = "center",
                onClick = function()
                    if isConn then net.wifiConnected, net.ssid, net.ipAddress = false, "", ""; render(); sendCommand("wifi", "disconnect")
                    elseif hsActive then hs.active = not hs.active; render(); sendCommand("hotspot", "toggle")
                    else sendCommand("wifi", "auto_connect") end
                end
            })
        }),
        ui.row({ align = "center", justify = "space_between", gap = 12 }, subInfo)
    })

    local leftControls = {}
    if net.refreshing and activeLeftCard == "wifi" then table.insert(leftControls, ui.glyph({ name = spinner, size = 16, color = "primary" })) end
    if activeLeftCard == "wifi" then table.insert(leftControls, ui.button({ glyph = "refresh", glyphSize = 16, variant = "ghost", contentAlign = "center", onClick = function() sendCommand("wifi", "scan") end })) end
    if hs.active and activeLeftCard == "hotspot" then
        table.insert(leftControls, smallBtn("qrcode", showHsQr and "primary" or "ghost", function()
            showHsQr = not showHsQr; if showHsQr then generateHsQr(render) end; render()
        end))
    end
    table.insert(leftControls, ui.button({
        glyph = hs.active and "broadcast" or "broadcast-off", glyphSize = 16,
        variant = (activeLeftCard == "hotspot") and "primary" or "ghost", contentAlign = "center",
        onClick = function() if activeLeftCard == "wifi" then activeLeftCard = "hotspot"; render() else sendCommand("hotspot", "toggle") end end,
        onRightClick = function() sendCommand("hotspot", "toggle") end
    }))
    table.insert(leftControls, ui.button({
        glyph = net.wifiEnabled and "wifi" or "wifi-off", glyphSize = 18,
        variant = (activeLeftCard == "wifi") and "primary" or "ghost", contentAlign = "center",
        onClick = function()
            if activeLeftCard == "hotspot" then activeLeftCard = "wifi"; render()
            else
                net.wifiEnabled = not net.wifiEnabled
                if not net.wifiEnabled then net.wifiConnected, net.ssid, net.ipAddress, net.availableNetworks = false, "", "", {} end
                render(); sendCommand("wifi", "toggle")
            end
        end,
        onRightClick = function()
            net.wifiEnabled = not net.wifiEnabled
            if not net.wifiEnabled then net.wifiConnected, net.ssid, net.ipAddress, net.availableNetworks = false, "", "", {} end
            render(); sendCommand("wifi", "toggle")
        end
    }))

    local leftHeader = ui.row({ align = "center", justify = "space_between" }, {
        ui.label({ text = (activeLeftCard == "wifi") and noctalia.tr("panel.wifi") or noctalia.tr("panel.hotspot"), fontSize = 13, fontWeight = "bold", color = "on_surface" }),
        ui.row({ align = "center", gap = 6 }, leftControls)
    })

    local leftCard
    if activeLeftCard == "wifi" then
        if not net.wifiEnabled then
            leftCard = ui.column({ flexGrow = 1, fill = "surface_variant", radius = 12, paddingV = 8, paddingH = 10, gap = 4 }, { leftHeader, hintRow(noctalia.tr("panel.wifi_off"), "wifi-off") })
        else
            local wifiList = {}
            local networks = net.availableNetworks or {}
            local activeNet, savedNets, otherNets, seen = nil, {}, {}, {}

            for _, n in ipairs(networks) do
                if n.active or (net.wifiConnected and net.ssid ~= "" and n.ssid == net.ssid) then
                    if not activeNet then activeNet = n end; seen[n.ssid] = true
                elseif n.saved then
                    if n.signal > 0 and not seen[n.ssid] then table.insert(savedNets, n); seen[n.ssid] = true end
                elseif not seen[n.ssid] then table.insert(otherNets, n); seen[n.ssid] = true end
            end

            if activeNet or net.wifiConnected then
                local sName = activeNet and activeNet.ssid or net.ssid
                local sGlyph = signalGlyph(activeNet and (activeNet.bars or activeNet.signal) or (net.bars or net.signal or 0))
                local aKey = "active-" .. sName
                local rBtns = {}
                if net.signal > 0 then table.insert(rBtns, ui.label({ text = tostring(net.signal) .. "%", fontSize = 11, color = "on_surface_variant" })) end
                if activeNet and activeNet.security and activeNet.security ~= "Open" then table.insert(rBtns, ui.glyph({ name = "lock", size = 14, color = "on_surface_variant" })) end
                table.insert(rBtns, smallBtn("qrcode", showWifiQr and "primary" or "ghost", function() showWifiQr = not showWifiQr; if showWifiQr then generateWifiQr(sName, activeNet and activeNet.security or "WPA", render) end; render() end))
                table.insert(rBtns, ui.glyph({ name = "check", size = 16, color = "primary" }))
                table.insert(wifiList, renderDeviceRow(aKey, sName, nil, sGlyph, "primary", hoveredId == aKey, false, rBtns, function() if activeNet then sendCommand("wifi", "connect", { ssid = activeNet.ssid }) end end))

                if showWifiQr then
                    local qrContent = {}
                    if qrLoading then
                        table.insert(qrContent, ui.row({ align = "center", justify = "center", height = 130 }, { ui.glyph({ name = spinner, size = 18, color = "primary" }), ui.label({ text = noctalia.tr("panel.generating_qr"), fontSize = 12, color = "on_surface_variant" }) }))
                    elseif noctalia.fileExists and noctalia.fileExists(qrImagePath) then
                        table.insert(qrContent, ui.column({ align = "center", gap = 6, paddingV = 8 }, { ui.image({ path = qrImagePath, width = 140, height = 140, radius = 8 }), ui.label({ text = noctalia.tr("panel.scan_to_connect"), fontSize = 11, color = "on_surface_variant" }) }))
                    end
                    table.insert(wifiList, ui.column({ key = "qr-box", fill = "surface", radius = 8, border = "primary", borderWidth = 1, paddingV = 6, paddingH = 8, align = "center" }, qrContent))
                end
            end

            if #savedNets > 0 then
                table.insert(wifiList, ui.label({ text = noctalia.tr("panel.saved_networks"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }))
                for _, n in ipairs(savedNets) do
                    local k, isC = "saved-" .. n.ssid, (wifiConnectingSsid == n.ssid)
                    local extras = {}
                    if n.signal > 0 then table.insert(extras, ui.label({ text = tostring(n.signal) .. "%", fontSize = 11, color = "on_surface_variant" })) end
                    if n.security ~= "Open" then table.insert(extras, ui.glyph({ name = "lock", size = 14, color = "on_surface_variant" })) end
                    if isC then table.insert(extras, ui.glyph({ name = spinner, size = 14, color = "primary" })) end
                    table.insert(extras, smallBtn("trash", "ghost", function() sendCommand("wifi", "forget", { ssid = n.ssid }) end))
                    table.insert(wifiList, renderDeviceRow(k, n.ssid, isC and noctalia.tr("panel.connecting") or nil, signalGlyph(n.signal or 0), isC and "primary" or "on_surface_variant", hoveredId == k, false, extras, function()
                        wifiConnectingSsid = n.ssid; render(); sendCommand("wifi", "connect", { ssid = n.ssid })
                    end))
                end
            end

            if #otherNets > 0 then
                table.insert(wifiList, ui.label({ text = noctalia.tr("panel.available_networks"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }))
                for _, n in ipairs(otherNets) do
                    local k, isSel = "avail-" .. n.ssid, (selectedSsid == n.ssid)
                    local extras = {}
                    if n.signal > 0 then table.insert(extras, ui.label({ text = tostring(n.signal) .. "%", fontSize = 11, color = "on_surface_variant" })) end
                    if n.security ~= "Open" then table.insert(extras, ui.glyph({ name = "lock", size = 14, color = "on_surface_variant" })) end
                    table.insert(wifiList, renderDeviceRow(k, n.ssid, nil, signalGlyph(n.signal or 0), "on_surface_variant", hoveredId == k, isSel, extras, function()
                        if n.security == "Open" then sendCommand("wifi", "connect", { ssid = n.ssid })
                        else selectedSsid = (selectedSsid == n.ssid) and nil or n.ssid; passwordInput = ""; showPassword = false; render() end
                    end))

                    if isSel then
                        local function submitPwd() if passwordInput ~= "" then sendCommand("wifi", "connect", { ssid = n.ssid, password = passwordInput }); selectedSsid, passwordInput, showPassword = nil, "", false; render() end end
                        table.insert(wifiList, ui.column({ key = "pwd-" .. k, gap = 4, fill = "surface", radius = 8, paddingV = 8, paddingH = 10 }, {
                            ui.label({ text = noctalia.tr("panel.password_for") .. " " .. n.ssid, fontSize = 11, color = "on_surface_variant" }),
                            ui.row({ align = "center", gap = 6 }, {
                                ui.input({ placeholder = noctalia.tr("panel.password_placeholder"), value = passwordInput, password = not showPassword, fontSize = 11, flexGrow = 1, onChange = function(v) passwordInput = v end, onSubmit = submitPwd }),
                                smallBtn(showPassword and "eye-off" or "eye", "ghost", function() showPassword = not showPassword; render() end),
                                ui.button({ text = noctalia.tr("panel.connect"), variant = "primary", fontSize = 11, onClick = submitPwd })
                            })
                        }))
                    end
                end
            elseif not net.wifiConnected and not activeNet and #savedNets == 0 then
                table.insert(wifiList, hintRow(net.refreshing and noctalia.tr("panel.scanning") or noctalia.tr("panel.no_networks"), net.refreshing and spinner or "info-circle"))
            end
            leftCard = ui.column({ flexGrow = 1, fill = "surface_variant", radius = 12, paddingV = 8, paddingH = 10, gap = 4 }, { leftHeader, ui.scroll({ flexGrow = 1, gap = 4 }, wifiList) })
        end
    else
        local cList = hs.clients or {}
        local bandText = (hs.band == "a" or hs.band == "5GHz" or hs.band == "5 GHz") and "5 GHz" or "2.4 GHz"
        if hs.channel and hs.channel > 0 then bandText = bandText .. " (Ch " .. tostring(hs.channel) .. ")" end
        local scrollEl = {}
        if showHsQr and hs.active and noctalia.fileExists and noctalia.fileExists(qrHsPath) then
            table.insert(scrollEl, ui.column({ fill = "surface", radius = 8, paddingV = 6, paddingH = 8, align = "center", gap = 4 }, {
                ui.image({ path = qrHsPath, width = 130, height = 130, radius = 6 }),
                ui.label({ text = noctalia.tr("panel.scan_to_connect"), fontSize = 10, color = "on_surface_variant" })
            }))
        end
        if hs.active then
            table.insert(scrollEl, ui.label({ text = noctalia.tr("panel.connected_devices_ratio", { count = tostring(#cList), max = tostring(hs.maxConnections or 8) }), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }))
            if #cList == 0 then table.insert(scrollEl, ui.label({ text = noctalia.tr("panel.no_devices"), fontSize = 11, color = "on_surface_variant" }))
            else
                for _, c in ipairs(cList) do
                    table.insert(scrollEl, ui.row({ align = "center", justify = "start", fill = "surface", radius = 8, height = 44, paddingV = 6, paddingH = 10, gap = 10 }, {
                        ui.glyph({ name = "device-mobile", size = 16, color = "primary" }),
                        ui.column({ gap = 1 }, {
                            ui.label({ text = (c.name and c.name ~= "") and c.name or c.ip, fontSize = 12, fontWeight = "bold", color = "on_surface" }),
                            ui.label({ text = c.ip .. " • " .. c.mac, fontSize = 10, color = "on_surface_variant" })
                        })
                    }))
                end
            end
        end
        leftCard = ui.column({ flexGrow = 1, fill = "surface_variant", radius = 12, paddingV = 8, paddingH = 10, gap = 4 }, {
            leftHeader,
            hintRow(hs.active and ((hs.ssid or "Noctalia-Hotspot") .. " • " .. bandText) or noctalia.tr("panel.hotspot_inactive_tip"), hs.active and "broadcast" or "broadcast-off", hs.active and "primary" or "on_surface_variant"),
            ui.scroll({ flexGrow = 1, gap = 4 }, scrollEl)
        })
    end

    -- Right Card (Bluetooth / DNS)
    local rightControls = {}
    if bt.scanning and activeRightCard == "bluetooth" then table.insert(rightControls, ui.glyph({ name = spinner, size = 16, color = "primary" })) end
    if bt.enabled and activeRightCard == "bluetooth" then table.insert(rightControls, ui.button({ glyph = "refresh", glyphSize = 16, variant = "ghost", contentAlign = "center", onClick = function() sendCommand("bluetooth", "scan") end })) end
    table.insert(rightControls, ui.button({
        glyph = isCustomDns and "shield" or "shield-off", glyphSize = 16, variant = (activeRightCard == "dns") and "primary" or "ghost", contentAlign = "center",
        onClick = function() if activeRightCard == "bluetooth" then activeRightCard = "dns"; render() else sendCommand("dns", "toggle") end end,
        onRightClick = function() sendCommand("dns", "toggle") end
    }))
    table.insert(rightControls, ui.button({
        glyph = bt.enabled and "bluetooth" or "bluetooth-off", glyphSize = 18, variant = (activeRightCard == "bluetooth") and "primary" or "ghost", contentAlign = "center",
        onClick = function()
            if activeRightCard == "dns" then activeRightCard = "bluetooth"; render()
            else if state.bluetooth then state.bluetooth.enabled = not state.bluetooth.enabled end; render(); sendCommand("bluetooth", "toggle") end
        end,
        onRightClick = function() if state.bluetooth then state.bluetooth.enabled = not state.bluetooth.enabled end; render(); sendCommand("bluetooth", "toggle") end
    }))

    local rightHeader = ui.row({ align = "center", justify = "space_between" }, {
        ui.label({ text = (activeRightCard == "bluetooth") and noctalia.tr("panel.bluetooth") or noctalia.tr("panel.dns_service"), fontSize = 13, fontWeight = "bold", color = "on_surface" }),
        ui.row({ align = "center", gap = 6 }, rightControls)
    })

    local rightCard
    if activeRightCard == "bluetooth" then
        local btList = {}
        if not bt.enabled then
            table.insert(btList, hintRow(noctalia.tr("panel.bt_off"), "bluetooth-off"))
        else
            table.insert(btList, ui.row({
                key = "row-bt-disc", align = "center", justify = "space_between", paddingV = 4, paddingH = 4,
                onClick = function() if state.bluetooth then state.bluetooth.discoverable = not state.bluetooth.discoverable end; render(); sendCommand("bluetooth", "discoverable") end
            }, {
                ui.label({ text = noctalia.tr("panel.discoverable"), fontSize = 13, fontWeight = "bold", color = "on_surface" }),
                ui.glyph({ name = bt.discoverable and "toggle-right-filled" or "toggle-left-filled", size = 30, color = bt.discoverable and "primary" or "on_surface_variant" })
            }))

            local now = os.time()
            for _, req in ipairs(bt.pairingRequests or {}) do
                local addr = req.address or ""
                local exp = dismissedPairingAddresses[addr]
                if not exp or now > exp then
                    table.insert(btList, ui.column({ key = "pair-req-" .. addr, gap = 8, fill = "surface", radius = 8, paddingV = 8, paddingH = 10 }, {
                        ui.row({ align = "center", gap = 8 }, {
                            ui.glyph({ name = req.icon or "bluetooth", size = 18, color = "primary" }),
                            ui.column({ gap = 2 }, {
                                ui.label({ text = noctalia.tr("panel.pairing_request_msg", { name = req.name or addr }), fontSize = 12, fontWeight = "bold", color = "on_surface" }),
                                req.passkey and ui.label({ text = noctalia.tr("panel.pairing_passkey", { key = tostring(req.passkey) }), fontSize = 11, fontWeight = "bold", color = "primary" }) or nil
                            })
                        }),
                        ui.row({ align = "center", justify = "space_between", gap = 8 }, {
                            ui.button({ text = noctalia.tr("panel.accept"), variant = "primary", fontSize = 11, flexGrow = 1, contentAlign = "center", onClick = function() dismissedPairingAddresses[addr] = os.time() + 10; if state.bluetooth then state.bluetooth.pairingRequests = {} end; render(); sendCommand("bluetooth", "accept_pair", { address = addr }) end }),
                            ui.button({ text = noctalia.tr("panel.reject"), variant = "destructive", fontSize = 11, flexGrow = 1, contentAlign = "center", onClick = function() dismissedPairingAddresses[addr] = os.time() + 10; if state.bluetooth then state.bluetooth.pairingRequests = {} end; render(); sendCommand("bluetooth", "reject_pair", { address = addr }) end })
                        })
                    }))
                end
            end

            local connP, otherP = {}, {}
            for _, d in ipairs(bt.pairedDevices or {}) do
                local la = (d.address or ""):lower()
                local exp = removedDevices[la]
                if not exp or now > exp then
                    if d.connected then table.insert(connP, d) else table.insert(otherP, d) end
                end
            end

            local function renderBtDevice(d, isConnectedSec)
                local k, la = "bt-" .. d.address, (d.address or ""):lower()
                local isAuto = (d.autoReconnect == true or d.trusted == true)
                local isC = (btConnecting[la] and (now < btConnecting[la])) or (d.connecting == true)
                local btns = {}

                if isConnectedSec then
                    btConnecting[la] = nil
                    table.insert(btns, ui.glyph({ name = "check", size = 14, color = "primary" }))
                    table.insert(btns, smallBtn("bluetooth-off", "ghost", function()
                        deviceActionOverrides[la] = { connected = false, expires = os.time() + 4 }
                        d.connected = false; render(); sendCommand("bluetooth", "disconnect", { address = d.address })
                    end))
                else
                    if isC then table.insert(btns, ui.glyph({ name = spinner, size = 14, color = "primary" }))
                    else
                        table.insert(btns, smallBtn("bluetooth-connected", "ghost", function()
                            btConnecting[la] = os.time() + 4; d.connecting = true; render(); sendCommand("bluetooth", "connect", { address = d.address })
                        end))
                    end
                end

                table.insert(btns, smallBtn(isAuto and "repeat" or "repeat-off", isAuto and "primary" or "ghost", function()
                    local nextTr = not d.trusted
                    deviceActionOverrides[la] = { trusted = nextTr, expires = os.time() + 4 }
                    d.trusted, d.autoReconnect = nextTr, nextTr; render(); sendCommand("bluetooth", "toggle_autoreconnect", { address = d.address })
                end))

                table.insert(btns, smallBtn("trash", "ghost", function()
                    removedDevices[la] = os.time() + 10; btConnecting[la], deviceActionOverrides[la] = nil, nil
                    if state.bluetooth and state.bluetooth.pairedDevices then
                        local p = {}
                        for _, dev in ipairs(state.bluetooth.pairedDevices) do if (dev.address or ""):lower() ~= la then table.insert(p, dev) end end
                        state.bluetooth.pairedDevices = p
                    end
                    render(); sendCommand("bluetooth", "remove", { address = d.address })
                end))

                return renderDeviceRow(k, d.name, (not isConnectedSec and isC) and noctalia.tr("panel.connecting") or nil, d.icon or "bluetooth", (isConnectedSec or isC) and "primary" or "on_surface_variant", hoveredId == k, false, btns, function()
                    if isConnectedSec then
                        deviceActionOverrides[la] = { connected = false, expires = os.time() + 4 }
                        d.connected = false; render(); sendCommand("bluetooth", "disconnect", { address = d.address })
                    elseif not isC then
                        btConnecting[la] = os.time() + 4; d.connecting = true; render(); sendCommand("bluetooth", "connect", { address = d.address })
                    end
                end)
            end

            if #connP > 0 then
                table.insert(btList, ui.label({ text = noctalia.tr("panel.connected_devices"), fontSize = 11, fontWeight = "bold", color = "primary" }))
                for _, d in ipairs(connP) do table.insert(btList, renderBtDevice(d, true)) end
            end
            if #otherP > 0 then
                table.insert(btList, ui.label({ text = noctalia.tr("panel.paired_devices"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }))
                for _, d in ipairs(otherP) do table.insert(btList, renderBtDevice(d, false)) end
            end

            local avail = bt.availableDevices or {}
            if #avail > 0 then
                table.insert(btList, ui.label({ text = noctalia.tr("panel.available_devices"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }))
                for _, d in ipairs(avail) do
                    local k = "bt-" .. d.address
                    local btns = { smallBtn("bluetooth-connected", "ghost", function() sendCommand("bluetooth", "pair", { address = d.address }) end) }
                    table.insert(btList, renderDeviceRow(k, d.name, nil, d.icon or "bluetooth", "on_surface_variant", hoveredId == k, false, btns, function() sendCommand("bluetooth", "pair", { address = d.address }) end))
                end
            elseif #connP == 0 and #otherP == 0 then
                table.insert(btList, hintRow(bt.scanning and noctalia.tr("panel.bt_scanning") or noctalia.tr("panel.no_bt_devices"), bt.scanning and spinner or "info-circle"))
            end
        end
        rightCard = ui.column({ flexGrow = 1, fill = "surface_variant", radius = 12, paddingV = 8, paddingH = 10, gap = 4 }, { rightHeader, ui.scroll({ flexGrow = 1, gap = 4 }, btList) })
    else
        local dnsList = {}
        local actId = dns.activeProvider or "default"
        for _, p in ipairs(dns.presets or {}) do
            table.insert(dnsList, ui.button({
                key = "dns-" .. p.id, text = p.label or p.id, glyph = p.glyph or "shield", glyphSize = 14,
                variant = (p.id == actId) and "primary" or "ghost", contentAlign = "start", fontSize = 12,
                onClick = function() sendCommand("dns", "apply", p.id) end
            }))
        end
        local function applyCust()
            if customDnsInput ~= "" then sendCommand("dns", "apply", { provider = "custom", servers = customDnsInput }); customDnsInput = ""; render() end
        end
        table.insert(dnsList, ui.row({ align = "center", gap = 6, paddingV = 1 }, {
            ui.input({ placeholder = noctalia.tr("panel.custom_dns_placeholder"), value = customDnsInput, fontSize = 11, flexGrow = 1, onChange = function(v) customDnsInput = v end, onSubmit = applyCust }),
            ui.button({ text = noctalia.tr("panel.apply"), variant = "primary", fontSize = 11, onClick = applyCust })
        }))
        rightCard = ui.column({ flexGrow = 1, fill = "surface_variant", radius = 12, paddingV = 7, paddingH = 9, gap = 3 }, { rightHeader, ui.scroll({ flexGrow = 1, gap = 2 }, dnsList) })
    end

    -- Root layout
    panel.render(ui.column({ flexGrow = 1, gap = 6 }, {
        ui.row({ align = "center", justify = "space_between" }, {
            ui.row({ align = "center", gap = 6 }, { ui.glyph({ name = "world", size = 18, color = "primary" }), ui.label({ text = noctalia.tr("title"), fontSize = 14, fontWeight = "bold", color = "primary" }) }),
            ui.row({ align = "center", gap = 4 }, {
                ui.button({ glyph = "refresh", variant = "ghost", contentAlign = "center", onClick = function() sendCommand("system", "refresh") end }),
                ui.button({ glyph = "x", variant = "ghost", contentAlign = "center", onClick = function() panel.close() end })
            })
        }),
        connCard,
        ui.row({ flexGrow = 1, gap = 6, align = "stretch" }, {
            ui.column({ flexGrow = 1, width = "50%" }, { leftCard }),
            ui.column({ flexGrow = 1, width = "50%" }, { rightCard }),
        })
    }))
end

local lastHsPoll = 0
function onOpen(_context)
    state = noctalia.state.get("network_state") or state
    selectedSsid, passwordInput, showPassword, showWifiQr, showHsQr, hoveredId = nil, "", false, false, false, nil
    activeLeftCard, activeRightCard = "wifi", "bluetooth"
    render()
    if not state.net or not state.net.availableNetworks or #state.net.availableNetworks == 0 then sendCommand("wifi", "scan") end
    if state.hotspot and state.hotspot.active then sendCommand("hotspot", "refresh") end
    if state.bluetooth and state.bluetooth.enabled then sendCommand("bluetooth", "refresh") end
end

function update()
    local now = os.time()
    local isRef = state.net and state.net.refreshing
    local isBtScan = state.bluetooth and state.bluetooth.scanning
    if isRef or isBtScan or qrLoading or next(btConnecting) ~= nil or (wifiConnectingSsid ~= nil) then
        animFrame += 1; render()
    end

    local pairRaw = noctalia.readFile("/tmp/noctalia_bt_pairing.json")
    if pairRaw and pairRaw ~= "" then
        local a, n, pk = pairRaw:match('"address":"([^"]+)"'), pairRaw:match('"name":"([^"]+)"') or "Bluetooth Device", pairRaw:match('"passkey":"([^"]*)"') or ""
        local ts = tonumber(pairRaw:match('"timestamp":(%d+)')) or now
        if a and (now - ts) < 20 then
            local exp = dismissedPairingAddresses[a]
            if not exp or now > exp then
                if not state.bluetooth then state.bluetooth = {} end
                local cur = state.bluetooth.pairingRequests or {}
                local exists = false
                for _, r in ipairs(cur) do if r.address == a and r.passkey == pk then exists = true; break end end
                if not exists then state.bluetooth.pairingRequests = { { address = a, name = n, passkey = pk, timestamp = ts } }; render() end
            end
        end
    end

    if activeLeftCard == "hotspot" and state.hotspot and state.hotspot.active and (now - lastHsPoll >= 1) then
        lastHsPoll = now; sendCommand("hotspot", "refresh")
    end
end

noctalia.setUpdateInterval(500)

noctalia.state.watch("network_state", function(newState)
    if type(newState) == "table" then
        state = newState
        local now = os.time()
        if state.bluetooth and state.bluetooth.pairedDevices then
            local filtered = {}
            for _, d in ipairs(state.bluetooth.pairedDevices) do
                local la = (d.address or ""):lower()
                local exp = removedDevices[la]
                if not exp or now > exp then
                    local ov = deviceActionOverrides[la]
                    if ov and now < ov.expires then
                        if ov.connected ~= nil then d.connected = ov.connected end
                        if ov.trusted ~= nil then d.trusted, d.autoReconnect = ov.trusted, ov.trusted end
                    end
                    table.insert(filtered, d)
                end
            end
            state.bluetooth.pairedDevices = filtered
        end
        render()
    end
end)

function onConfigChanged() render() end
render()
