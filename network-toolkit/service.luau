--!nonstrict
-- Network Toolkit — Background service and event coordinator
local net     = require("./services/net.luau")
local hotspot = require("./services/hotspot.luau")
local dns     = require("./services/dns.luau")
local bt      = require("./services/bluetooth.luau")

net.init(); hotspot.init(); dns.init(); bt.init()

local isFirstSync = true
local lastNet, lastEth, lastPairKey = "", false, nil

local function publishAll()
    local n, b = net.getStatus(), bt.getStatus()

    if n.wifiConnected and n.ssid ~= "" and n.ssid ~= lastNet then
        lastNet = n.ssid
        dns.enforce()
        if not isFirstSync then
            noctalia.notify(noctalia.tr("title"), noctalia.tr("notifications.connected_to", { ssid = n.ssid }))
        end
    elseif n.ethernetConnected and not lastEth then
        lastEth = true
        dns.enforce()
        if not isFirstSync then
            noctalia.notify(noctalia.tr("title"), "Connected to Ethernet")
        end
    end
    if not n.wifiConnected then lastNet = "" end
    if not n.ethernetConnected then lastEth = false end
    isFirstSync = false

    if b.pairingRequests and #b.pairingRequests > 0 then
        local r = b.pairingRequests[1]
        local key = (r.address or "") .. ":" .. (r.passkey or "") .. ":" .. (r.timestamp or 0)
        if key ~= lastPairKey then
            lastPairKey = key
            local msg = (r.passkey and r.passkey ~= "") and string.format("%s requested to pair (Passkey: %s)", r.name or r.address, r.passkey) or string.format("%s requested to pair", r.name or r.address)
            noctalia.notify(noctalia.tr("title"), msg)
        end
    else lastPairKey = nil end

    noctalia.state.set("network_state", { nonce = os.time(), net = n, hotspot = hotspot.getStatus(), dns = dns.getStatus(), bluetooth = b })
end

noctalia.state.watch("network_command", function(cmd)
    if type(cmd) ~= "table" then return end
    local d, a, p = cmd.domain, cmd.action, cmd.payload or {}

    if d == "hotspot" then
        if a == "toggle" then hotspot.toggle(not hotspot.getStatus().active, function() publishAll(); net.refresh(publishAll) end)
        elseif a == "refresh" then hotspot.refresh(publishAll) end
    elseif d == "wifi" then
        if a == "toggle" then net.toggleWifi(not net.getStatus().wifiEnabled, publishAll)
        elseif a == "disconnect" then net.disconnect(publishAll)
        elseif a == "auto_connect" then net.autoConnect(publishAll)
        elseif a == "connect" then
            net.connectWifi(p.ssid or "", p.password or "", function(_s, ok, msg, wasHs)
                if not ok then
                    local l = (msg or ""):lower()
                    local isPwd = l:find("secret") or l:find("password") or l:find("802-11-wireless-security")
                    noctalia.notifyError(noctalia.tr("title"), noctalia.tr(isPwd and "notifications.incorrect_password" or "notifications.connect_failed", { ssid = p.ssid or "" }))
                else
                    noctalia.notify(noctalia.tr("title"), noctalia.tr("notifications.connected_to", { ssid = p.ssid or "" }))
                end
                if wasHs then hotspot.toggle(true, publishAll) end
                publishAll()
            end)
        elseif a == "forget" then net.forgetWifi(p.ssid or "", publishAll)
        elseif a == "scan" then net.scan(publishAll) end
    elseif d == "dns" then
        if a == "apply" then
            local prov = (type(p) == "table") and (p.provider or "custom") or (p or "default")
            local srv = (type(p) == "table") and (p.servers or "") or ""
            publishAll(); dns.apply(prov, srv, publishAll)
        elseif a == "toggle" then
            local nextProv = (dns.getStatus().activeProvider == "default") and "cloudflare" or "default"
            dns.apply(nextProv, "", publishAll)
            publishAll()
        end
    elseif d == "bluetooth" then
        local addr = p.address or ""
        if a == "toggle" then bt.toggle(not bt.getStatus().enabled, publishAll)
        elseif a == "scan" then bt.scan(publishAll)
        elseif a == "connect" then bt.connect(addr, publishAll)
        elseif a == "disconnect" then bt.disconnect(addr, publishAll)
        elseif a == "pair" then bt.pair(addr, publishAll)
        elseif a == "accept_pair" then bt.acceptPair(addr, publishAll)
        elseif a == "reject_pair" then bt.rejectPair(addr, publishAll)
        elseif a == "toggle_autoreconnect" then bt.toggleAutoReconnect(addr, publishAll)
        elseif a == "remove" then bt.remove(addr, publishAll)
        elseif a == "discoverable" then bt.toggleDiscoverable(not bt.getStatus().discoverable, publishAll)
        elseif a == "refresh" then bt.refresh(publishAll) end
    elseif d == "system" and a == "refresh" then
        net.scan(publishAll); hotspot.refresh(publishAll); dns.refresh(publishAll); bt.scan(publishAll)
    end
end)

function update()
    net.refresh(publishAll); hotspot.refresh(publishAll); dns.refresh(publishAll); bt.refresh(publishAll)
    local pSec = tonumber(noctalia.getConfig("refreshinterval")) or 5
    if pSec < 2 then pSec = 2 elseif pSec > 60 then pSec = 60 end
    noctalia.setUpdateInterval((hotspot.getStatus().active and 1500 or (pSec * 1000)))
end

function onConfigChanged()
    hotspot.updateConfig(publishAll)
    update()
end

noctalia.setUpdateInterval(5000)
publishAll()
update()
