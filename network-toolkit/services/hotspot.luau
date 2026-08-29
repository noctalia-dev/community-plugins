--!nonstrict
-- Hotspot management with concurrent Wi-Fi station and AP support
local Hotspot = {}
local nmcliOk, ipOk, iwOk = noctalia.commandExists("nmcli"), noctalia.commandExists("ip"), noctalia.commandExists("iw")
local refreshing = false
local hsPowerLock = 0
local SCRIPT = noctalia.pluginDir() .. "/scripts/hotspot_helper.sh"

local state = {
    active = false, busy = false, available = nmcliOk and ipOk,
    ssid = "Noctalia-Hotspot", connName = "Noctalia-Hotspot",
    interface = "wlan0-ap", baseInterface = "wlan0",
    clients = {}, clientCount = 0, maxConnections = 8,
    concurrentSupported = false, maxChannels = 1, channel = 6, band = "bg", error = ""
}

local function getCfg()
    local s = noctalia.getConfig("hotspot_ssid") or "Noctalia-Hotspot"
    local p = noctalia.getConfig("hotspot_password") or "noctaliapass"
    return (s == "" and "Noctalia-Hotspot" or s), (p == "" or #p < 8) and "noctaliapass" or p
end

function Hotspot.init()
    state.available = nmcliOk and ipOk
    if not state.available then state.error = noctalia.tr("errors.missing_command") end
    state.ssid = getCfg()
    state.maxConnections = tonumber(noctalia.getConfig("hotspot_max_connections")) or 8
    return state.available
end

function Hotspot.getStatus() return state end

local BATCH_CMD = [[
echo "=A="; nmcli -t -f TYPE,STATE,DEVICE,NAME connection show --active 2>/dev/null
echo "=D="; nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null
echo "=I="; iw dev 2>/dev/null
echo "=N="; ip neighbor show 2>/dev/null
echo "=S="; iw dev 2>/dev/null | awk '/Interface.*-ap/{print $2}' | while read -r i; do iw dev "$i" station dump 2>/dev/null; done
echo "=L="; cat /var/lib/misc/dnsmasq.leases /var/lib/NetworkManager/dnsmasq*.leases 2>/dev/null || true
]]

function Hotspot.refresh(callback)
    if not state.available or refreshing then if callback then callback(state) end; return end
    refreshing = true
    local cfgSsid = getCfg()
    state.maxConnections = tonumber(noctalia.getConfig("hotspot_max_connections")) or 8

    noctalia.runAsync(BATCH_CMD, function(res)
        refreshing = false
        local out = res.stdout or ""
        local actSec  = out:match("=A=(.-)=D=") or ""
        local devSec  = out:match("=D=(.-)=I=") or ""
        local iwSec   = out:match("=I=(.-)=N=") or ""
        local nbrSec  = out:match("=N=(.-)=S=") or ""
        local staSec  = out:match("=S=(.-)=L=") or ""
        local lseSec  = out:match("=L=(.*)") or ""

        local isActive, apDev, connName = false, "", ""
        for line in actSec:gmatch("[^\r\n]+") do
            local _, devState, d, name = line:match("^([^:]+):([^:]+):([^:]+):(.*)$")
            if name and devState == "activated" and (name:lower():find("hotspot") or name == cfgSsid or name == "Noctalia-Hotspot") then
                isActive, apDev, connName = true, d, name
                break
            end
        end

        local baseDev = ""
        for line in devSec:gmatch("[^\r\n]+") do
            local d, typ, s = line:match("^([^:]+):([^:]+):([^:]+)")
            if typ == "wifi" and d ~= apDev and not d:find("%-ap$") and not d:find("^p2p%-") then
                if baseDev == "" or s == "connected" then baseDev = d end
            end
        end
        if baseDev == "" then
            for line in iwSec:gmatch("[^\r\n]+") do
                local ifn = line:match("Interface%s+([%w%-_]+)")
                if ifn and not ifn:find("%-ap$") and not ifn:find("^p2p%-") then baseDev = ifn; break end
            end
        end
        state.baseInterface = baseDev ~= "" and baseDev or "wlan0"

        if apDev == "" then
            for line in iwSec:gmatch("[^\r\n]+") do
                local ifn = line:match("Interface%s+([%w%-_]+)")
                if ifn and ifn:find("%-ap$") then apDev = ifn; break end
            end
        end
        state.interface = apDev ~= "" and apDev or (state.baseInterface .. "-ap")
        if os.time() >= hsPowerLock then state.active = isActive end
        state.connName = connName ~= "" and connName or "Noctalia-Hotspot"

        -- find connected devices & ips
        local clients = {}
        for line in staSec:gmatch("[^\r\n]+") do
            local mac = line:match("Station%s+([%x:]+)%s+%(on")
            if mac then clients[mac:lower()] = { mac = mac:lower(), ip = "", name = "" } end
        end
        for line in lseSec:gmatch("[^\r\n]+") do
            local _, mac, ip, name = line:match("^(%d+)%s+([%x:]+)%s+([%d%.]+)%s+(%S+)")
            if mac and ip and clients[mac:lower()] then
                clients[mac:lower()].ip = ip
                if name and name ~= "*" then clients[mac:lower()].name = name end
            end
        end
        for line in nbrSec:gmatch("[^\r\n]+") do
            local ip, dev, mac = line:match("^([%d%.]+)%s+dev%s+([%w%-_]+)%s+lladdr%s+([%x:]+)")
            if ip and dev and mac and dev:find("%-ap$") and clients[mac:lower()] and clients[mac:lower()].ip == "" then
                clients[mac:lower()].ip = ip
            end
        end

        local cList = {}
        for _, c in pairs(clients) do table.insert(cList, c) end
        table.sort(cList, function(a, b) return a.mac < b.mac end)
        state.clients, state.clientCount = cList, #cList

        if callback then callback(state) end
    end, 4000)
end

function Hotspot.detectCapabilities(callback)
    noctalia.runAsync("iw phy 2>/dev/null; echo '=D='; nmcli -t -f DEVICE,TYPE device 2>/dev/null", function(res)
        local out = res.stdout or ""
        local phySec = out:match("(.-)=D=") or out
        local ap = phySec:find("AP") ~= nil
        local sta = phySec:find("managed") ~= nil
        state.concurrentSupported = ap and sta
        if callback then callback({ baseIface = state.baseInterface, concurrent = state.concurrentSupported, maxChannels = 1 }) end
    end, 3000)
end

function Hotspot.toggle(enable, callback)
    if not state.available or state.busy then if callback then callback(state) end; return end
    local ssid, pass = getCfg()
    local sSsid, sPass = ssid:gsub("'", "'\\''"), pass:gsub("'", "'\\''")
    hsPowerLock = os.time() + 4
    state.active, state.busy = enable, true
    if callback then callback(state) end

    if not enable then
        local target = state.interface ~= "" and state.interface or (state.baseInterface .. "-ap")
        local downCmd = string.format("nmcli connection down 'Noctalia-Hotspot' 2>/dev/null || nmcli connection down '%s' 2>/dev/null || nmcli device disconnect '%s' 2>/dev/null || true", sSsid, target)
        noctalia.runAsync(downCmd, function()
            state.busy, state.active = false, false
            Hotspot.refresh(callback)
        end, 4000)
        return
    end

    local upCmd = string.format([[
BASE='%s'; AP='%s'
[ ! -d "/sys/class/net/${AP}" ] && bash '%s' "$BASE" "$AP" >/dev/null 2>&1 || true
CHAN=$(iw dev "$BASE" info 2>/dev/null | awk '/channel/ {print $2; exit}')
[ -z "$CHAN" ] && CHAN=6
[ "$CHAN" -gt 14 ] && BAND="a" || BAND="bg"

UUID=$(nmcli -t -f UUID,NAME connection show 2>/dev/null | awk -F: '$2=="Noctalia-Hotspot" || $2=="'%s'" {print $1; exit}')
if [ -n "$UUID" ]; then
    nmcli connection modify "$UUID" connection.id "Noctalia-Hotspot" connection.interface-name "$AP" 802-11-wireless.ssid '%s' 802-11-wireless.mode ap 802-11-wireless.band "$BAND" 802-11-wireless.channel "$CHAN" 802-11-wireless-security.key-mgmt wpa-psk 802-11-wireless-security.psk '%s' ipv4.method shared ipv6.method disabled connection.autoconnect no 2>/dev/null || true
else
    nmcli connection add type wifi ifname "$AP" con-name 'Noctalia-Hotspot' ssid '%s' 802-11-wireless.mode ap 802-11-wireless.band "$BAND" 802-11-wireless.channel "$CHAN" wifi-sec.key-mgmt wpa-psk wifi-sec.psk '%s' ipv4.method shared ipv6.method disabled connection.autoconnect no 2>/dev/null || true
fi
nmcli connection up 'Noctalia-Hotspot' 2>/dev/null || (sleep 0.5 && nmcli connection up 'Noctalia-Hotspot' 2>/dev/null)
]], state.baseInterface, state.interface, SCRIPT, sSsid, sSsid, sPass, sSsid, sPass)

    noctalia.runAsync(upCmd, function()
        state.busy = false
        Hotspot.refresh(callback)
    end, 8000)
end

function Hotspot.updateConfig(callback)
    local ssid, pass = getCfg()
    state.ssid = ssid
    local sSsid, sPass = ssid:gsub("'", "'\\''"), pass:gsub("'", "'\\''")
    local cmd = string.format("nmcli connection modify 'Noctalia-Hotspot' 802-11-wireless.ssid '%s' 802-11-wireless-security.psk '%s' 2>/dev/null || true; [ '%s' = '1' ] && nmcli connection up 'Noctalia-Hotspot' 2>/dev/null || true", sSsid, sPass, state.active and "1" or "0")
    noctalia.runAsync(cmd, function() Hotspot.refresh(callback) end, 4000)
end

return Hotspot