--!nonstrict
-- bluetooth service & pairing agent
local BT = {}
local btctlOk = noctalia.commandExists("bluetoothctl")
local refreshExpire = 0
local btPowerLock, discLock = 0, 0
local autoConnectOnPower = true

local CACHE_FILE = "/tmp/noctalia_bt_cache.json"
local AUTOCONNECT_FILE = "/tmp/noctalia_bt_autoconnect.json"
local autoConnectMap = {}

local state = {
    available = btctlOk, enabled = true, discoverable = false, scanning = false,
    pairedDevices = {}, availableDevices = {}, pairingRequests = {}, connectedAddrs = {},
    connectingAddrs = {}, alias = "", error = ""
}

local function saveCache()
    pcall(noctalia.writeFile, CACHE_FILE, string.format('{"enabled":%s,"discoverable":%s,"alias":"%s"}',
        tostring(state.enabled), tostring(state.discoverable), state.alias:gsub('"', '\\"')))
end

local function loadCache()
    local ok, c = pcall(noctalia.readFile, CACHE_FILE)
    if ok and type(c) == "string" and c ~= "" then
        state.enabled = (c:match('"enabled"%s*:%s*true') ~= nil)
        state.discoverable = (c:match('"discoverable"%s*:%s*true') ~= nil)
        state.alias = c:match('"alias"%s*:%s*"([^"]*)"') or state.alias
    else
        state.enabled = true
    end
end

local function loadAutoConnect()
    local ok, c = pcall(noctalia.readFile, AUTOCONNECT_FILE)
    if ok and type(c) == "string" and c ~= "" then
        autoConnectMap = {}
        for mac, val in c:gmatch('"([%x:]+)"%s*:%s*(%a+)') do
            autoConnectMap[mac:lower()] = (val == "true")
        end
    else
        autoConnectMap = {}
    end
end

local function saveAutoConnect()
    local entries = {}
    for mac, val in pairs(autoConnectMap) do
        table.insert(entries, string.format('"%s":%s', mac:lower(), tostring(val)))
    end
    pcall(noctalia.writeFile, AUTOCONNECT_FILE, "{" .. table.concat(entries, ",") .. "}")
end

local function btTypeGlyph(name)
    local l = (name or ""):lower()
    if l:find("headset") or l:find("wh%-") or l:find("wf%-") or l:find("quietcomfort") or l:find("airpod") or l:find("buds") or l:find("freebuds") or l:find("earphone") or l:find("tune") then return "headphones"
    elseif l:find("speaker") or l:find("soundlink") or l:find("flip") or l:find("charge") or l:find("boom") or l:find("go") or l:find("echo") then return "speaker"
    elseif l:find("mouse") or l:find("trackpad") then return "mouse"
    elseif l:find("keyboard") or l:find("keychron") or l:find("k%d%d%d") then return "keyboard"
    elseif l:find("controller") or l:find("gamepad") or l:find("xbox") or l:find("dualsense") or l:find("dualshock") then return "device-gamepad"
    elseif l:find("phone") or l:find("pixel") or l:find("iphone") or l:find("galaxy") or l:find("oneplus") or l:find("redmi") or l:find("xiaomi") or l:find("nothing") then return "device-mobile"
    elseif l:find("tv") or l:find("display") or l:find("smart screen") then return "device-tv"
    elseif l:find("watch") or l:find("band") or l:find("fitbit") or l:find("garmin") then return "device-watch"
    end
    return "bluetooth"
end

local function ensureAgent()
    local pDir = (type(noctalia.pluginDir) == "function" and noctalia.pluginDir()) or (type(noctalia.pluginDir) == "string" and noctalia.pluginDir) or "/media/SSD/code/github/community-plugins/network-toolkit"
    local bin = pDir .. "/scripts/bluetooth_helper"
    noctalia.runAsync(string.format("pidof bluetooth_helper >/dev/null 2>&1 || (nohup '%s' >/dev/null 2>&1 &)", bin), function() end, 2000)
end

function BT.init()
    state.available = btctlOk
    if not state.available then state.error = noctalia.tr("errors.bluetoothctl_not_found") end
    loadCache()
    loadAutoConnect()
    saveCache()
    autoConnectOnPower = true
    ensureAgent()
    noctalia.runAsync("for f in /sys/class/bluetooth/hci*/device/power/control; do [ -w \"$f\" ] && echo on > \"$f\" 2>/dev/null || true; done; rfkill unblock bluetooth 2>/dev/null || true", function() end, 1500)
    return state.available
end

function BT.getStatus() return state end

local BATCH = [[
echo "=SHOW="; bluetoothctl show 2>/dev/null
echo "=PAIRED="; bluetoothctl devices Paired 2>/dev/null
echo "=CONN="; bluetoothctl devices Connected 2>/dev/null
echo "=ALL="; bluetoothctl devices 2>/dev/null
echo "=AGENT="; cat /tmp/noctalia_bt_pairing.json 2>/dev/null || true
]]

function BT.refresh(callback)
    if not state.available or os.time() < refreshExpire then if callback then callback(state) end; return end
    refreshExpire = os.time() + 4
    ensureAgent()

    noctalia.runAsync(BATCH, function(res)
        refreshExpire = 0
        local out = (res and res.stdout) or ""
        out = out:gsub("\27%[[%d;]*[a-zA-Z]", "")
        out = out:gsub("\r", "")

        local showSec  = out:match("=SHOW=%s*\n?(.-)\n?=PAIRED=") or ""
        local pairSec  = out:match("=PAIRED=%s*\n?(.-)\n?=CONN=") or out:match("=PAIRED=%s*\n?(.-)\n?=ALL=") or ""
        local connSec  = out:match("=CONN=%s*\n?(.-)\n?=ALL=") or ""
        local allSec   = out:match("=ALL=%s*\n?(.-)\n?=AGENT=") or ""
        local agentSec = out:match("=AGENT=%s*\n?(.*)") or ""

        if out:find("[Pp]owered:%s*[yY][eE][sS]") or out:find("[Pp]owerState:%s*[oO][nN]") then
            state.enabled = true
        elseif out:find("[Pp]owered:%s*[nN][oO]") or out:find("[Pp]owerState:%s*[oO][fF][fF]") then
            if os.time() >= btPowerLock then state.enabled = false end
        end

        if out:find("[Dd]iscoverable:%s*[yY][eE][sS]") then
            if os.time() >= discLock then state.discoverable = true end
        elseif out:find("[Dd]iscoverable:%s*[nN][oO]") then
            if os.time() >= discLock then state.discoverable = false end
        end

        local alias = showSec:match("Alias:%s*(.-)\n") or showSec:match("Name:%s*(.-)\n")
        if alias then state.alias = alias:match("^%s*(.-)%s*$") or state.alias end

        if not state.enabled then
            state.pairedDevices, state.availableDevices, state.pairingRequests, state.connectedAddrs = {}, {}, {}, {}
            saveCache()
            if callback then callback(state) end
            return
        end

        local devConn = {}
        for line in connSec:gmatch("[^\r\n]+") do
            local a = line:match("Device%s+([%x:]+)")
            if a then devConn[a:lower()] = true end
        end
        state.connectedAddrs = devConn

        local nameMap = {}
        for line in allSec:gmatch("[^\r\n]+") do
            local a, n = line:match("Device%s+([%x:]+)%s*(.*)")
            if a and a:find(":") then
                n = (n and n:match("^%s*(.-)%s*$")) or ""
                if n ~= "" then nameMap[a:lower()] = n end
            end
        end

        local paired, pairedMap = {}, {}
        for line in pairSec:gmatch("[^\r\n]+") do
            local a, n = line:match("Device%s+([%x:]+)%s*(.*)")
            if a and a:find(":") then
                local la = a:lower()
                pairedMap[la] = true
                n = (n and n:match("^%s*(.-)%s*$")) or ""
                local dName = (n ~= "" and n) or nameMap[la] or a
                local isC = (devConn[la] == true)
                local isAuto = (autoConnectMap[la] == true)
                table.insert(paired, {
                    address = a, name = dName, connected = isC,
                    connecting = (state.connectingAddrs[la] == true),
                    trusted = isAuto, autoReconnect = isAuto,
                    icon = btTypeGlyph(dName)
                })

                -- Auto-connect on startup if enabled
                if isAuto and not isC and autoConnectOnPower and state.connectingAddrs[la] ~= true then
                    noctalia.runAsync(string.format("timeout 4 bluetoothctl connect %s 2>/dev/null || true", a), function()
                        BT.refresh(function() end)
                    end, 5000)
                end
            end
        end
        autoConnectOnPower = false
        state.pairedDevices = paired

        -- grab pairing requests from agent
        local reqs = {}
        local rawAgent = agentSec
        local okF, fileContent = pcall(noctalia.readFile, "/tmp/noctalia_bt_pairing.json")
        if okF and type(fileContent) == "string" and fileContent ~= "" then rawAgent = fileContent end
        if rawAgent and rawAgent ~= "" then
            local a = rawAgent:match('"address":%s*"([^"]+)"')
            local rawN = rawAgent:match('"name":%s*"([^"]+)"')
            local la = a and a:lower()
            local n = (la and nameMap[la]) or ((rawN and not rawN:find("^Device %x%x:")) and rawN) or (a or "Bluetooth Device")
            local pk = rawAgent:match('"passkey":%s*"([^"]*)"') or ""
            local ts = tonumber(rawAgent:match('"timestamp":%s*(%d+)')) or os.time()
            if a and (os.time() - ts) <= 30 then
                table.insert(reqs, { address = a, name = n, passkey = pk, timestamp = ts, icon = btTypeGlyph(n) })
            end
        end
        state.pairingRequests = reqs

        -- Available
        local avail = {}
        for line in allSec:gmatch("[^\r\n]+") do
            local a, n = line:match("Device%s+([%x:]+)%s*(.*)")
            if a and a:find(":") then
                local la = a:lower()
                if not pairedMap[la] then
                    n = (n and n:match("^%s*(.-)%s*$")) or ""
                    local dName = (n ~= "" and n) or a
                    table.insert(avail, { address = a, name = dName, icon = btTypeGlyph(dName), connected = (devConn[la] == true) })
                end
            end
        end
        state.availableDevices = avail
        saveCache()

        if callback then callback(state) end
    end, 4000)
end

function BT.scan(callback)
    if not state.available or not state.enabled then BT.refresh(callback); return end
    state.scanning = true
    if callback then callback(state) end
    noctalia.runAsync("timeout 4 bluetoothctl scan on 2>/dev/null || true", function()
        state.scanning = false
        BT.refresh(callback)
    end, 6000)
end

function BT.toggle(enable, callback)
    btPowerLock = os.time() + 3
    state.enabled = enable
    if enable then autoConnectOnPower = true end
    if not enable then state.pairedDevices, state.availableDevices, state.pairingRequests, state.connectedAddrs = {}, {}, {}, {} end
    if callback then callback(state) end
    local cmd = enable and "rfkill unblock bluetooth 2>/dev/null; bluetoothctl power on 2>/dev/null" or "bluetoothctl power off 2>/dev/null"
    noctalia.runAsync(cmd, function()
        BT.refresh(function(s) if enable and callback then BT.scan(callback) elseif callback then callback(s) end end)
    end, 3000)
end

local function validMac(a)
    return type(a) == "string" and a:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil
end

function BT.connect(addr, callback)
    if not validMac(addr) then if callback then callback(state) end; return end
    local la = addr:lower()
    local dName = addr
    if state.pairedDevices then
        for _, d in ipairs(state.pairedDevices) do
            if (d.address or ""):lower() == la then
                d.connecting = true
                dName = d.name or d.address
                break
            end
        end
    end
    state.connectingAddrs[la] = true
    if callback then callback(state) end

    local cmd = string.format("timeout 8 bluetoothctl connect %s 2>&1; sleep 0.5; bluetoothctl info %s 2>/dev/null", addr, addr)
    noctalia.runAsync(cmd, function(res)
        local out = string.lower((res and res.stdout) or "")
        local isConnected = (out:find("connected:%s*yes") ~= nil) or (out:find("connection successful") ~= nil) or (out:find("successful") ~= nil)
        local needsRepair = out:find("not authorized") or out:find("authentication failed") or out:find("authentication canceled") or out:find("not permitted")

        if needsRepair then
            -- If remote device is unpaired, prompt fresh pair
            noctalia.runAsync("noctalia msg panel-open autumn/network-toolkit:panel", function() end, 1500)
            local repairCmd = string.format("bluetoothctl remove %s 2>/dev/null; sleep 0.2; bluetoothctl pair %s 2>/dev/null; sleep 1; (bluetoothctl info %s 2>/dev/null | grep -q 'Connected: yes') || bluetoothctl connect %s 2>/dev/null", addr, addr, addr, addr)
            noctalia.runAsync(repairCmd, function()
                state.connectingAddrs[la] = nil
                BT.refresh(callback)
            end, 15000)
        else
            state.connectingAddrs[la] = nil
            if not isConnected and not needsRepair then
                noctalia.notifyError(noctalia.tr("title"), string.format("Failed to connect to %s", dName))
            end
            BT.refresh(callback)
        end
    end, 10000)
end

function BT.disconnect(addr, callback)
    if not validMac(addr) then if callback then callback(state) end; return end
    local la = addr:lower()
    state.connectedAddrs[addr], state.connectedAddrs[la] = nil, nil
    if state.pairedDevices then
        for _, d in ipairs(state.pairedDevices) do if (d.address or ""):lower() == la then d.connected = false; break end end
    end
    if callback then callback(state) end
    noctalia.runAsync("bluetoothctl disconnect " .. addr .. " 2>/dev/null", function() BT.refresh(callback) end, 3000)
end

function BT.pair(addr, callback)
    if not validMac(addr) then if callback then callback(state) end; return end
    local la = addr:lower()
    state.connectingAddrs[la] = true
    if callback then callback(state) end
    noctalia.runAsync("noctalia msg panel-open autumn/network-toolkit:panel", function() end, 1500)
    local cmd = string.format("bluetoothctl pair %s 2>/dev/null; sleep 1; (bluetoothctl info %s 2>/dev/null | grep -q 'Connected: yes') || bluetoothctl connect %s 2>/dev/null", addr, addr, addr)
    noctalia.runAsync(cmd, function()
        state.connectingAddrs[la] = nil
        BT.refresh(callback)
    end, 14000)
end

function BT.toggleAutoReconnect(addr, callback)
    if not validMac(addr) then if callback then callback(state) end; return end
    local la = addr:lower()
    local nextAuto = not (autoConnectMap[la] == true)
    autoConnectMap[la] = nextAuto
    saveAutoConnect()

    local isConnected = false
    if state.pairedDevices then
        for _, d in ipairs(state.pairedDevices) do
            if (d.address or ""):lower() == la then
                d.trusted = nextAuto
                d.autoReconnect = nextAuto
                isConnected = (d.connected == true)
                break
            end
        end
    end
    if nextAuto and not isConnected then
        state.connectingAddrs[la] = true
    end
    if callback then callback(state) end

    if nextAuto then
        local cmd = string.format("bluetoothctl trust %s 2>/dev/null; sleep 0.2; (bluetoothctl info %s 2>/dev/null | grep -q 'Connected: yes') || timeout 4 bluetoothctl connect %s 2>/dev/null || true", addr, addr, addr)
        noctalia.runAsync(cmd, function()
            state.connectingAddrs[la] = nil
            BT.refresh(callback)
        end, 6000)
    else
        local cmd = string.format("bluetoothctl untrust %s 2>/dev/null", addr)
        noctalia.runAsync(cmd, function()
            state.connectingAddrs[la] = nil
            BT.refresh(callback)
        end, 3000)
    end
end

function BT.acceptPair(addr, callback)
    if not validMac(addr) then if callback then callback(state) end; return end
    local la = addr:lower()
    state.pairingRequests = {}
    state.connectingAddrs[la] = true
    if callback then callback(state) end
    -- Write action file synchronously so C helper reads it immediately
    pcall(noctalia.writeFile, "/tmp/noctalia_bt_pairing_action", "accept")
    local cmd = string.format("sleep 1; (bluetoothctl info %s 2>/dev/null | grep -q 'Connected: yes') || bluetoothctl connect %s 2>/dev/null || true", addr, addr)
    noctalia.runAsync(cmd, function()
        state.connectingAddrs[la] = nil
        BT.refresh(callback)
    end, 4000)
end

function BT.rejectPair(addr, callback)
    if not validMac(addr) then if callback then callback(state) end; return end
    state.pairingRequests = {}
    if callback then callback(state) end
    pcall(noctalia.writeFile, "/tmp/noctalia_bt_pairing_action", "reject")
    local cmd = string.format("echo -n 'reject' > /tmp/noctalia_bt_pairing_action; rm -f /tmp/noctalia_bt_pairing.json; bluetoothctl cancel-pairing %s 2>/dev/null || true", addr)
    noctalia.runAsync(cmd, function() BT.refresh(callback) end, 2000)
end

function BT.remove(addr, callback)
    if not validMac(addr) then if callback then callback(state) end; return end
    local la = addr:lower()
    state.connectedAddrs[addr], state.connectedAddrs[la] = nil, nil
    if state.pairedDevices then
        local p = {}
        for _, d in ipairs(state.pairedDevices) do if (d.address or ""):lower() ~= la then table.insert(p, d) end end
        state.pairedDevices = p
    end
    state.pairingRequests = {}
    if callback then callback(state) end
    noctalia.runAsync(string.format("rm -f /tmp/noctalia_bt_pairing.json; bluetoothctl disconnect %s 2>/dev/null || true; bluetoothctl untrust %s 2>/dev/null || true; bluetoothctl remove %s 2>/dev/null", addr, addr, addr), function() BT.refresh(callback) end, 3000)
end

function BT.setDiscoverable(enable, callback)
    discLock = os.time() + 3
    state.discoverable = enable
    if callback then callback(state) end
    noctalia.runAsync("bluetoothctl discoverable " .. (enable and "on" or "off") .. " 2>/dev/null", function() BT.refresh(callback) end, 3000)
end
BT.toggleDiscoverable = BT.setDiscoverable

return BT
