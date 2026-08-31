--!nonstrict
-- Network status, Wi-Fi scanning, and connection management
local Net = {}
local nmcliOk = noctalia.commandExists("nmcli")
local CACHE_FILE = "/tmp/noctalia_net_cache.json"
local refreshing = false
local wifiPowerLock = 0
local connectingSsid = nil
local lastConnectedSsid = ""

local state = {
    available = nmcliOk, wifiEnabled = true, wifiConnected = false, ethernetConnected = false,
    hotspotActive = false, ssid = "", signal = 0, band = "—", ipAddress = "", interface = "",
    speedFormatted = "0 B/s ↓  0 B/s ↑", availableNetworks = {}, refreshing = false, error = ""
}

local function saveCache()
    pcall(noctalia.writeFile, CACHE_FILE, string.format('{"ssid":"%s","interface":"%s","ipAddress":"%s","band":"%s","wifiConnected":%s,"ethernetConnected":%s,"signal":%d}',
        state.ssid:gsub('"', '\\"'), state.interface:gsub('"', '\\"'), state.ipAddress:gsub('"', '\\"'),
        state.band:gsub('"', '\\"'), tostring(state.wifiConnected), tostring(state.ethernetConnected), state.signal))
end

local function loadCache()
    local ok, c = pcall(noctalia.readFile, CACHE_FILE)
    if ok and type(c) == "string" and c ~= "" then
        state.ssid = c:match('"ssid"%s*:%s*"([^"]*)"') or state.ssid
        state.interface = c:match('"interface"%s*:%s*"([^"]*)"') or state.interface
        state.ipAddress = c:match('"ipAddress"%s*:%s*"([^"]*)"') or state.ipAddress
        state.band = c:match('"band"%s*:%s*"([^"]*)"') or state.band
        state.wifiConnected = (c:match('"wifiConnected"%s*:%s*true') ~= nil)
        state.ethernetConnected = (c:match('"ethernetConnected"%s*:%s*true') ~= nil)
        state.signal = tonumber(c:match('"signal"%s*:%s*(%d+)')) or state.signal
        if state.wifiConnected and state.ssid ~= "" then lastConnectedSsid = state.ssid end
    end
end

function Net.init()
    state.available = nmcliOk
    if not state.available then state.error = noctalia.tr("errors.nmcli_not_found") end
    loadCache()
    return state.available
end

function Net.getStatus() return state end

function Net.signalGlyph(val)
    local s = tonumber(val) or 0
    return (s >= 88 and "wifi") or (s >= 63 and "wifi-3") or (s >= 38 and "wifi-2") or (s >= 13 and "wifi-1") or "wifi-0"
end

local BATCH = [[
echo "=D="; nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device 2>/dev/null
echo "=A="; nmcli -t -f TYPE,STATE,DEVICE,NAME connection show --active 2>/dev/null
echo "=S="; nmcli -t -f NAME,TYPE connection show 2>/dev/null
echo "=I="; ip -4 addr show 2>/dev/null
echo "=W="; nmcli -t -f IN-USE,SSID,SIGNAL,SECURITY,FREQ device wifi list 2>/dev/null
]]

function Net.refresh(callback)
    if not state.available or refreshing then if callback then callback(state) end; return end
    refreshing, state.refreshing = true, true

    noctalia.runAsync(BATCH, function(res)
        refreshing, state.refreshing = false, false
        local out = res.stdout or ""
        local devSec = out:match("=D=(.-)=A=") or ""
        local actSec = out:match("=A=(.-)=S=") or ""
        local savSec = out:match("=S=(.-)=I=") or ""
        local ipSec  = out:match("=I=(.-)=W=") or ""
        local wifSec = out:match("=W=(.*)") or ""

        local wifiConn, ethConn, hsAct = false, false, false
        local connSsid, wifiIf, ethIf = "", "", ""
        local hsSsid = noctalia.getConfig("hotspot_ssid") or "Noctalia-Hotspot"

        local isHsName = function(n, d)
            if not n then return false end
            local ln = n:lower()
            return ln:find("hotspot") ~= nil or n == hsSsid or n == "Noctalia-Hotspot" or (d ~= nil and d:find("%-ap$") ~= nil)
        end

        for line in actSec:gmatch("[^\r\n]+") do
            local typ, st, dev, name = line:match("^([^:]+):([^:]+):([^:]+):(.*)$")
            if name and dev then
                if isHsName(name, dev) then
                    hsAct = true
                elseif (st == "activated" or st == "connected") and (typ == "802-11-wireless" or typ == "wifi") then
                    wifiConn, connSsid, wifiIf = true, name, dev
                elseif (st == "activated" or st == "connected") and (typ == "802-3-ethernet" or typ == "ethernet") then
                    ethConn, ethIf = true, dev
                end
            end
        end

        local wEnabled = true
        for line in devSec:gmatch("[^\r\n]+") do
            local d, typ, s, c = line:match("^([^:]+):([^:]+):([^:]+):?(.*)$")
            if typ == "wifi" and not d:find("%-ap$") and not d:find("^p2p%-") then
                if s == "unavailable" or s == "unmanaged" then wEnabled = false end
                if s == "connected" and c and c ~= "" and not isHsName(c, d) then
                    wifiConn, connSsid, wifiIf = true, c, d
                end
            elseif typ == "ethernet" and s == "connected" then
                ethConn, ethIf = true, d
            end
        end

        local curIp = ""
        local activeIf = ethConn and ethIf or (wifiConn and wifiIf or "")
        if activeIf ~= "" then
            local blk = ipSec:match("%d+:%s+" .. activeIf .. ":(.-)%d+:%s+") or ipSec:match("%d+:%s+" .. activeIf .. ":(.*)")
            if blk then curIp = blk:match("inet%s+([%d%.]+)/") or "" end
        end
        if curIp == "" then curIp = ipSec:match("inet%s+([%d%.]+)/%d+%s+brd[%s%d%.]+scope global") or "" end

        local savedMap = {}
        for line in savSec:gmatch("[^\r\n]+") do
            local name, typ = line:match("^([^:]+):([^:]+)$")
            if name and (typ == "802-11-wireless" or typ == "wifi") and not isHsName(name) then
                if name ~= connectingSsid then savedMap[name] = true end
            end
        end

        local networks, seen = {}, {}
        for line in wifSec:gmatch("[^\r\n]+") do
            local _, ssid, sig, sec, freq = line:match("^([^:]*):([^:]*):([^:]*):([^:]*):(.*)$")
            if ssid and ssid ~= "" and not seen[ssid] and not isHsName(ssid) then
                seen[ssid] = true
                local isAct = (wifiConn and connSsid ~= "" and ssid == connSsid)
                local sigN = tonumber(sig) or 0
                if isAct then
                    local fNum = tonumber((freq or ""):match("(%d+)")) or 0
                    state.band = (fNum >= 4900) and "5 GHz" or "2.4 GHz"
                    if sigN > 0 then state.signal = sigN end
                end
                table.insert(networks, { ssid = ssid, signal = sigN, security = (sec ~= "--" and sec ~= "") and sec or "Open", active = isAct, saved = (savedMap[ssid] == true) })
            end
        end

        if wifiConn and connSsid ~= "" and not seen[connSsid] then
            table.insert(networks, 1, { ssid = connSsid, signal = state.signal > 0 and state.signal or 60, security = "WPA2", active = true, saved = true })
        end

        -- lock stops toggle double-clicking while nmcli is working
        if os.time() >= wifiPowerLock then state.wifiEnabled = wEnabled end
        state.wifiConnected, state.ethernetConnected = wifiConn, ethConn
        state.hotspotActive, state.ssid, state.interface, state.ipAddress = hsAct, (wifiConn and connSsid or ""), activeIf, curIp
        if wifiConn and connSsid ~= "" then lastConnectedSsid = connSsid end
        if #networks > 0 then state.availableNetworks = networks end
        saveCache()
        if callback then callback(state) end
    end, 5000)
end

function Net.scan(callback) Net.refresh(callback) end

function Net.toggleWifi(enable, callback)
    wifiPowerLock = os.time() + 3
    state.wifiEnabled = enable
    if not enable then state.wifiConnected, state.ssid, state.ipAddress, state.signal, state.availableNetworks = false, "", "", 0, {} end
    saveCache()
    if callback then callback(state) end
    noctalia.runAsync("nmcli radio wifi " .. (enable and "on" or "off"), function() Net.refresh(callback) end, 3000)
end

function Net.connectWifi(ssid, password, callback)
    local safe = ssid:gsub("'", "'\\''")
    local hasPwd = (type(password) == "string" and password ~= "")
    local prevSsid = (state.wifiConnected and state.ssid ~= "" and state.ssid ~= ssid) and state.ssid
        or (lastConnectedSsid ~= "" and lastConnectedSsid ~= ssid and lastConnectedSsid or nil)
    connectingSsid = hasPwd and ssid or nil

    local wifiCmd = hasPwd
        and string.format("nmcli --wait 8 device wifi connect '%s' password '%s'", safe, password:gsub("'", "'\\''"))
        or string.format("nmcli --wait 8 connection up id '%s' 2>/dev/null || nmcli --wait 8 device wifi connect '%s'", safe, safe)
    local wasHs = state.hotspotActive
    local fullCmd = wasHs and ("nmcli connection down 'Noctalia-Hotspot' 2>/dev/null || true; sleep 0.2; " .. wifiCmd) or wifiCmd

    noctalia.runAsync(fullCmd, function(res)
        connectingSsid = nil
        local ok = (res.exitCode == 0)
        if not ok then
            local restoreCmd = hasPwd and string.format("nmcli connection delete id '%s' 2>/dev/null || nmcli connection delete '%s' 2>/dev/null; ", safe, safe) or ""
            if prevSsid then
                local pSafe = prevSsid:gsub("'", "'\\''")
                restoreCmd = restoreCmd .. string.format("nmcli connection up id '%s' 2>/dev/null || nmcli device wifi connect '%s' 2>/dev/null || nmcli device autoconnect 2>/dev/null || true", pSafe, pSafe)
            else
                restoreCmd = restoreCmd .. "nmcli device autoconnect 2>/dev/null || true"
            end
            noctalia.runAsync(restoreCmd, function()
                Net.refresh(function(s) if callback then callback(s, false, res.stdout or res.stderr or "", wasHs) end end)
            end, 4000)
        else
            Net.refresh(function(s) if callback then callback(s, true, res.stdout or res.stderr or "", wasHs) end end)
        end
    end, 10000)
end

function Net.disconnect(callback)
    local iface = (state.interface ~= "" and state.interface or "wlan0"):gsub("[^%w%-_.]", "")
    state.wifiConnected, state.ethernetConnected, state.ssid, state.ipAddress = false, false, "", ""
    saveCache()
    if callback then callback(state) end
    noctalia.runAsync(string.format("nmcli device disconnect '%s' 2>/dev/null", iface), function() Net.refresh(callback) end, 4000)
end

function Net.autoConnect(callback)
    local cmd = "ETH=$(nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | awk -F: '$2==\"ethernet\" && $3!=\"unavailable\" && $3!=\"unmanaged\" {print $1; exit}'); [ -n \"$ETH\" ] && (nmcli device connect \"$ETH\" 2>/dev/null || nmcli connection up id \"$ETH\" 2>/dev/null) || nmcli device autoconnect 2>/dev/null || nmcli networking on 2>/dev/null || true"
    noctalia.runAsync(cmd, function() Net.refresh(callback) end, 5000)
end

function Net.forgetWifi(ssid, callback)
    noctalia.runAsync(string.format("nmcli connection delete id '%s' 2>/dev/null", ssid:gsub("'", "'\\''")), function() Net.refresh(callback) end, 4000)
end

return Net