--!nonstrict
-- Persistent DNS configuration service
local DNS = {}
local nmcliOk = noctalia.commandExists("nmcli")
local FILE = "/var/tmp/noctalia_dns.json"

local BUILTIN = {
    { id = "default",    label = "System Default (ISP)", ip = "",                          glyph = "shield" },
    { id = "cloudflare", label = "Cloudflare",           ip = "1.1.1.1 1.0.0.1",           glyph = "cloud" },
    { id = "google",     label = "Google",               ip = "8.8.8.8 8.8.4.4",           glyph = "brand-google" },
    { id = "quad9",      label = "Quad9",                ip = "9.9.9.9 149.112.112.112",   glyph = "lock" },
    { id = "adguard",    label = "AdGuard",              ip = "94.140.14.14 94.140.15.15", glyph = "shield-check" },
}

local current = BUILTIN[1]
local changing, refreshing = false, false

local function validIp(ip)
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    return a and #a <= 3 and #b <= 3 and #c <= 3 and #d <= 3 and tonumber(a) <= 255 and tonumber(b) <= 255 and tonumber(c) <= 255 and tonumber(d) <= 255
end

local function validSpec(spec)
    local n = 0
    for tok in spec:gmatch("%S+") do
        n += 1
        if n > 2 or not validIp(tok) then return false end
    end
    return n > 0
end

function DNS.getPresets()
    local list = {}
    for _, p in ipairs(BUILTIN) do table.insert(list, p) end
    for i = 1, 3 do
        local val = noctalia.getConfig("custom_dns_" .. i)
        if type(val) == "string" and val ~= "" then
            local name, ip = val:match("^([^=]+)=(.*)$")
            name = name and name:match("^%s*(.-)%s*$") or val:match("^%s*(.-)%s*$")
            ip = ip and ip:match("^%s*(.-)%s*$") or name
            if validSpec(ip) then table.insert(list, { id = "custom_" .. i, label = name, ip = ip, glyph = "server" }) end
        end
    end
    return list
end

local function findEntry(id, customIp)
    if id == "custom" and type(customIp) == "string" and customIp ~= "" then
        local ip = customIp:match("^%s*(.-)%s*$")
        return { id = "custom", label = "Custom (" .. ip .. ")", ip = ip, glyph = "server" }
    end
    for _, p in ipairs(DNS.getPresets()) do if p.id == id then return p end end
    return BUILTIN[1]
end

local function readSaved()
    local ok, c = pcall(noctalia.readFile, FILE)
    if ok and type(c) == "string" and c ~= "" then
        local p, s, l = c:match('"provider"%s*:%s*"([^"]+)"'), c:match('"servers"%s*:%s*"([^"]*)"'), c:match('"label"%s*:%s*"([^"]*)"')
        if p then return { provider = p, servers = s or "", label = l } end
    end
    return nil
end

local function writeSaved(p, s, l)
    pcall(noctalia.writeFile, FILE, string.format('{"provider":"%s","servers":"%s","label":"%s"}', p, s, l or ""))
end

local function applyInternal(entry, callback)
    local isDef = (entry.id == "default" or entry.ip == "")
    local safeIp = isDef and "" or entry.ip:gsub("[^%d%. ]", "")
    local script = string.format([[
nmcli -t -f UUID,TYPE,DEVICE connection show --active 2>/dev/null | while IFS=: read -r u t d; do
    [ -z "$u" ] || [ "$d" = "lo" ] && continue
    case "$d" in *-ap|p2p-dev-*) continue ;; esac
    [ "$(nmcli -g ipv4.method connection show uuid "$u" 2>/dev/null)" = "shared" ] && continue
    if [ "%s" = "1" ]; then
        nmcli connection modify "$u" ipv4.dns "" ipv4.ignore-auto-dns no 2>/dev/null || true
    else
        nmcli connection modify "$u" ipv4.dns "%s" ipv4.ignore-auto-dns yes 2>/dev/null || true
    fi
    nmcli device reapply "$d" 2>/dev/null || true
done
]], isDef and "1" or "0", safeIp)

    noctalia.runAsync(script, function(res) if callback then callback(res.exitCode == 0) end end, 6000)
end

function DNS.getStatus()
    return { available = nmcliOk, activeProvider = current.id, current = current, currentServers = current.ip, changing = changing, presets = DNS.getPresets() }
end

function DNS.init()
    if not nmcliOk then return false end
    local s = readSaved()
    if s and s.provider and s.provider ~= "default" then
        current = findEntry(s.provider, s.servers)
        applyInternal(current, nil)
    else
        current = BUILTIN[1]
    end
    return true
end

function DNS.refresh(callback)
    if not nmcliOk or refreshing then if callback then callback(DNS.getStatus()) end; return end
    refreshing = true
    local s = readSaved()
    current = (s and s.provider and s.provider ~= "default") and findEntry(s.provider, s.servers) or BUILTIN[1]
    noctalia.runAsync("nmcli -t -f TYPE,DEVICE,UUID connection show --active 2>/dev/null", function()
        refreshing = false
        if callback then callback(DNS.getStatus()) end
    end, 4000)
end

function DNS.apply(providerId, customServers, callback)
    local target = findEntry(providerId, customServers)
    current, changing = target, true
    writeSaved(target.id, target.ip, target.label)
    applyInternal(target, function(ok)
        changing = false
        if ok then noctalia.notify(noctalia.tr("title"), noctalia.tr("notifications.dns_switched", { provider = target.label }))
        else noctalia.notifyError(noctalia.tr("title"), noctalia.tr("notifications.dns_switch_failed")) end
        DNS.refresh(callback)
    end)
end

function DNS.enforce(callback)
    local s = readSaved()
    if s and s.provider and s.provider ~= "default" then
        current = findEntry(s.provider, s.servers)
        applyInternal(current, callback)
    elseif current and current.id ~= "default" then
        applyInternal(current, callback)
    elseif callback then callback(true) end
end

return DNS
