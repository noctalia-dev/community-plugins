--!nonstrict
-- Bluetooth device management and BlueZ agent interface
local BT = {}
local btctlOk = noctalia.commandExists("bluetoothctl")
local refreshing = false
local pendingActions = {}
local btPowerLock, discLock = 0, 0

local state = {
    available = btctlOk, enabled = false, discoverable = false, scanning = false,
    pairedDevices = {}, availableDevices = {}, pairingRequests = {}, connectedAddrs = {},
    connectingAddrs = {}, alias = "", error = ""
}

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
    local bin = noctalia.pluginDir() .. "/scripts/bluetooth_helper"
    noctalia.runAsync(string.format("pgrep -f bluetooth_helper >/dev/null 2>&1 || (setsid '%s' >/dev/null 2>&1 &)", bin), function() end, 2000)
end

function BT.init()
    state.available = btctlOk
    if not state.available then state.error = noctalia.tr("errors.bluetoothctl_not_found") end
    ensureAgent()
    return state.available
end

function BT.getStatus() return state end

local BATCH = [[
echo "=SHOW="; bluetoothctl show 2>/dev/null
echo "=PAIRED="; bluetoothctl devices Paired 2>/dev/null
echo "=ALL="; bluetoothctl devices 2>/dev/null
echo "=INFOS="; bluetoothctl devices Paired 2>/dev/null | awk '{print $2}' | while read -r mac; do
    echo "---DEV $mac---"; bluetoothctl info "$mac" 2>/dev/null
done
echo "=AGENT="; cat /tmp/noctalia_bt_pairing.json 2>/dev/null || true
]]

function BT.refresh(callback)
    if not state.available or refreshing then if callback then callback(state) end; return end
    refreshing = true
    ensureAgent()

    noctalia.runAsync(BATCH, function(res)
        refreshing = false
        local out = res.stdout or ""
        local showSec  = out:match("=SHOW=(.-)=PAIRED=") or ""
        local pairSec  = out:match("=PAIRED=(.-)=ALL=") or ""
        local allSec   = out:match("=ALL=(.-)=INFOS=") or ""
        local infoSec  = out:match("=INFOS=(.-)=AGENT=") or ""
        local agentSec = out:match("=AGENT=(.*)") or ""

        if os.time() >= btPowerLock then state.enabled = (showSec:find("Powered:%s*yes") ~= nil) end
        if os.time() >= discLock then state.discoverable = (showSec:find("Discoverable:%s*yes") ~= nil) end
        local alias = showSec:match("Alias:%s*(.-)\n") or showSec:match("Name:%s*(.-)\n")
        state.alias = alias and alias:match("^%s*(.-)%s*$") or ""

        if not state.enabled then
            state.pairedDevices, state.availableDevices, state.pairingRequests, state.connectedAddrs = {}, {}, {}, {}
            if callback then callback(state) end
            return
        end

        local devConn, devTrust, devName = {}, {}, {}
        local curDev = nil
        for line in infoSec:gmatch("[^\r\n]+") do
            local h = line:match("%-%-%-DEV%s+(%S+)%-%-%-")
            if h then curDev = h
            elseif curDev then
                if line:find("Connected:%s*yes") then devConn[curDev] = true end
                if line:find("Trusted:%s*yes") then devTrust[curDev] = true end
                local al = line:match("Alias:%s*(.+)") or line:match("Name:%s*(.+)")
                if al and not devName[curDev] then devName[curDev] = al:match("^%s*(.-)%s*$") end
            end
        end
        state.connectedAddrs = devConn

        local nameMap, paired, pairedMap = {}, {}, {}
        for line in allSec:gmatch("[^\r\n]+") do
            local a, n = line:match("^Device%s+(%S+)%s+(.+)$")
            if a and n then nameMap[a] = n end
        end

        local now = os.time()
        for line in pairSec:gmatch("[^\r\n]+") do
            local a, n = line:match("^Device%s+(%S+)%s+(.+)$")
            if a and n then
                pairedMap[a] = true
                local dName = devName[a] or n
                local la = a:lower()
                local isC = (devConn[a] == true)
                local isPending = pendingActions[la]
                if isPending then
                    if now < isPending.expires then
                        if isC == isPending.connected then pendingActions[la] = nil
                        else isC = isPending.connected end
                    else pendingActions[la] = nil end
                end
                table.insert(paired, {
                    address = a, name = dName, connected = isC,
                    connecting = (state.connectingAddrs[la] == true),
                    trusted = (devTrust[a] == true), autoReconnect = (devTrust[a] == true),
                    icon = btTypeGlyph(dName)
                })
            end
        end
        state.pairedDevices = paired

        -- grabs pairing requests from native agent
        local reqs = {}
        if agentSec and agentSec ~= "" then
            local a = agentSec:match('"address":%s*"([^"]+)"')
            local n = agentSec:match('"name":%s*"([^"]+)"') or a
            local pk = agentSec:match('"passkey":%s*"([^"]*)"') or ""
            local ts = tonumber(agentSec:match('"timestamp":%s*(%d+)')) or now
            if a and (now - ts) <= 20 then
                table.insert(reqs, { address = a, name = n, passkey = pk, timestamp = ts, icon = btTypeGlyph(n) })
            end
        end
        state.pairingRequests = reqs

        -- Available
        local avail = {}
        for a, n in pairs(nameMap) do
            if not pairedMap[a] and n ~= "" and a:find(":") then
                table.insert(avail, { address = a, name = n, icon = btTypeGlyph(n), connected = (devConn[a] == true) })
            end
        end
        state.availableDevices = avail

        if callback then callback(state) end
    end, 6000)
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
    if not enable then state.pairedDevices, state.availableDevices, state.pairingRequests, state.connectedAddrs = {}, {}, {}, {} end
    if callback then callback(state) end
    local cmd = enable and "rfkill unblock bluetooth 2>/dev/null; bluetoothctl power on 2>/dev/null" or "bluetoothctl power off 2>/dev/null"
    noctalia.runAsync(cmd, function()
        BT.refresh(function(s) if enable and callback then BT.scan(callback) elseif callback then callback(s) end end)
    end, 3000)
end

function BT.connect(addr, callback)
    local la = (addr or ""):lower()
    state.connectingAddrs[la] = true
    if state.pairedDevices then
        for _, d in ipairs(state.pairedDevices) do if (d.address or ""):lower() == la then d.connecting = true; break end end
    end
    if callback then callback(state) end

    local cmd = string.format("timeout 4 bluetoothctl connect %s 2>&1 || (bluetoothctl disconnect %s 2>/dev/null; true)", addr, addr)
    noctalia.runAsync(cmd, function()
        state.connectingAddrs[la] = nil
        pendingActions[la] = nil
        BT.refresh(function(s)
            local isConn = s.connectedAddrs and (s.connectedAddrs[addr] or s.connectedAddrs[la])
            if not isConn then
                noctalia.runAsync(string.format("bluetoothctl disconnect %s 2>/dev/null", addr), function() end, 1000)
                if noctalia.notifyError then pcall(noctalia.notifyError, noctalia.tr("title"), "Connection failed")
                else pcall(noctalia.notify, noctalia.tr("title"), "Connection failed") end
            end
            if callback then callback(s) end
        end)
    end, 5000)
end

function BT.disconnect(addr, callback)
    local la = (addr or ""):lower()
    pendingActions[la] = { connected = false, expires = os.time() + 4 }
    state.connectedAddrs[addr], state.connectedAddrs[la] = nil, nil
    if state.pairedDevices then
        for _, d in ipairs(state.pairedDevices) do if (d.address or ""):lower() == la then d.connected = false; break end end
    end
    if callback then callback(state) end
    noctalia.runAsync("bluetoothctl disconnect " .. addr .. " 2>/dev/null", function() BT.refresh(callback) end, 3000)
end

function BT.pair(addr, callback)
    noctalia.runAsync(string.format("bluetoothctl pair %s 2>/dev/null; bluetoothctl connect %s 2>/dev/null", addr, addr), function() BT.refresh(callback) end, 12000)
end

function BT.toggleAutoReconnect(addr, callback)
    local isTr = false
    if state.pairedDevices then
        for _, d in ipairs(state.pairedDevices) do
            if d.address == addr then d.trusted = not d.trusted; d.autoReconnect = d.trusted; isTr = d.trusted; break end
        end
    end
    if callback then callback(state) end
    noctalia.runAsync(string.format("bluetoothctl %s %s 2>/dev/null", isTr and "trust" or "untrust", addr), function() BT.refresh(callback) end, 3000)
end

function BT.acceptPair(addr, callback)
    state.pairingRequests = {}
    if callback then callback(state) end
    pcall(noctalia.writeFile, "/tmp/noctalia_bt_pairing_action", "accept")
    local cmd = string.format("echo -n 'accept' > /tmp/noctalia_bt_pairing_action; rm -f /tmp/noctalia_bt_pairing.json; sleep 0.2; bluetoothctl connect %s 2>/dev/null", addr)
    noctalia.runAsync(cmd, function() BT.refresh(callback) end, 10000)
end

function BT.rejectPair(addr, callback)
    state.pairingRequests = {}
    if callback then callback(state) end
    pcall(noctalia.writeFile, "/tmp/noctalia_bt_pairing_action", "reject")
    local cmd = string.format("echo -n 'reject' > /tmp/noctalia_bt_pairing_action; rm -f /tmp/noctalia_bt_pairing.json; bluetoothctl cancel-pairing %s 2>/dev/null || true", addr)
    noctalia.runAsync(cmd, function() BT.refresh(callback) end, 2000)
end

function BT.remove(addr, callback)
    local la = (addr or ""):lower()
    pendingActions[la] = nil
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
