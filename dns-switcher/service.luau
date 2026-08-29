--!nonstrict
-- dns-switcher — singleton DNS engine (detection + apply).
--
-- Runs once regardless of how many bars show the widget. The widget and the
-- panel are pure renderers wired through the plugin's shared state:
--   engine publishes  "dns_state"     = { nonce, current?, servers, conName,
--                                         changing, error?, list }
--   UI entries send   "apply_request" = { nonce, id, label?, ip? }
--
-- Detection reads the active connection's ipv4.dns / ipv4.ignore-auto-dns
-- profile settings (manual DNS is matched against the providers, otherwise
-- shown as "Custom"); without a manual DNS the state is the ISP default.
-- Applying runs `nmcli con mod <uuid> … && nmcli device reapply <dev>` —
-- reapply pushes the change onto the live connection without reactivating
-- it, so the network never drops. The privilege command is empty by default:
-- NetworkManager's polkit policy lets active local sessions modify system
-- connections on most desktop distros. When set, it is prefixed onto each
-- of those two nmcli calls individually (never onto a wrapping shell), so a
-- sudoers NOPASSWD rule naming the nmcli binary itself is enough — see
-- apply() below and the README's Privileges section.
--
-- Since 0.2.0 every command here is an argument vector rather than a shell
-- line (plugin_api >= 24), so there is no shell to quote for anywhere in this
-- plugin. The detection and apply pipelines that used to be one `sh -c` script
-- each are now chains of individual nmcli calls parsed in Luau.

local STATE_KEY = "dns_state"       -- published here, read by widget + panel
local REQUEST_KEY = "apply_request" -- sent by widget/panel, consumed here

local BUILTIN = {
    { id = "google",     label = "Google",     ip = "8.8.8.8 8.8.4.4",               glyph = "brand-google" },
    { id = "cloudflare", label = "Cloudflare", ip = "1.1.1.1 1.0.0.1",               glyph = "cloud" },
    { id = "opendns",    label = "OpenDNS",    ip = "208.67.222.222 208.67.220.220", glyph = "world" },
    { id = "adguard",    label = "AdGuard",    ip = "94.140.14.14 94.140.15.15",     glyph = "shield-check" },
    { id = "quad9",      label = "Quad9",      ip = "9.9.9.9 149.112.112.112",       glyph = "lock" },
}
local GLYPH_DEFAULT = "router" -- ISP / connection default
local GLYPH_UNKNOWN = "globe"  -- unrecognized manual DNS
local GLYPH_CUSTOM = "server"  -- user-defined servers

local current = nil -- provider entry detected as active; nil = still checking
local lastSeen = "" -- runtime resolver IPs from the last successful poll
local conName = ""  -- active connection name, shown in the panel footer
local errMsg = nil  -- sticky error label (no nmcli / no connection)
local pollTicks = 0
local changing = false
local checkInFlight = false
local nmcliMissing = false
local stateNonce = 0

local function cfg(key)
    return noctalia.getConfig(key)
end

local function tr(key, args)
    return noctalia.tr(key, args)
end

local function trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function pollSeconds()
    return math.max(2, tonumber(cfg("poll_seconds")) or 10)
end

local function isValidIp(ip)
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if a == nil then
        return false
    end
    for _, part in ipairs({ a, b, c, d }) do
        if #part > 3 or tonumber(part) > 255 then
            return false
        end
    end
    return true
end

-- One or two space-separated IPv4 addresses, same shape nmcli accepts.
local function validDnsSpec(spec)
    local count = 0
    for token in spec:gmatch("%S+") do
        count += 1
        if count > 2 or not isValidIp(token) then
            return false
        end
    end
    return count > 0
end

-- Custom servers: five separate `Name = 1.2.3.4 5.6.7.8` string settings rather
-- than one list, so a wrong address can be corrected in the field instead of
-- deleted and retyped -- Noctalia's list editor has no per-row edit. Slot order
-- is panel order. The keys are listed as literals so `noctalia plugins lint` can
-- still match them against the manifest.
local CUSTOM_KEYS = { "custom_1", "custom_2", "custom_3", "custom_4", "custom_5" }

-- The raw slots are the cache signature, so an invalid entry is logged when a
-- slot actually changes rather than on every poll.
local customCacheSig = nil
local customCacheList = {}
local function customProviders()
    local rows = {}
    for _, key in ipairs(CUSTOM_KEYS) do
        local row = cfg(key)
        if type(row) == "string" and trim(row) ~= "" then
            table.insert(rows, row)
        end
    end
    local sig = table.concat(rows, "\n")
    if sig == customCacheSig then
        return customCacheList
    end
    customCacheSig = sig
    customCacheList = {}
    for _, row in ipairs(rows) do
        -- The name is everything before the first '='; the rest is the address
        -- list. A name may therefore not contain '=' itself — such a row fails
        -- the address check below and is skipped with a log line.
        local name, spec = row:match("^([^=]*)=(.*)$")
        local cleanName = trim(name or "")
        local cleanSpec = trim(spec or "")
        if cleanName ~= "" and validDnsSpec(cleanSpec) then
            table.insert(customCacheList, { id = "custom:" .. cleanName, label = cleanName, ip = cleanSpec, glyph = GLYPH_CUSTOM })
        elseif trim(row) ~= "" then
            noctalia.log("dns-switcher: ignoring invalid custom server row '" .. row .. "'")
        end
    end
    return customCacheList
end

local function enabledBuiltins()
    local raw = cfg("providers")
    if type(raw) ~= "string" then
        return BUILTIN
    end
    -- Cleared setting = no built-ins: only custom servers and the ISP default.
    if trim(raw) == "" then
        return {}
    end
    local wanted = {}
    for id in raw:gmatch("[^,%s]+") do
        wanted[id:lower()] = true
    end
    local list = {}
    for _, provider in ipairs(BUILTIN) do
        if wanted[provider.id] then
            table.insert(list, provider)
        end
    end
    return list
end

local function defaultEntry()
    return { id = "default", label = tr("status_default"), ip = "", glyph = GLYPH_DEFAULT }
end

-- Panel order: enabled built-ins, then custom servers, then the ISP default.
local function providerList()
    local list = {}
    for _, provider in ipairs(enabledBuiltins()) do
        table.insert(list, provider)
    end
    for _, provider in ipairs(customProviders()) do
        table.insert(list, provider)
    end
    table.insert(list, defaultEntry())
    return list
end

local function publish()
    stateNonce += 1
    noctalia.state.set(STATE_KEY, {
        nonce = stateNonce,
        current = current,
        servers = lastSeen,
        conName = conName,
        changing = changing,
        error = errMsg,
        list = providerList(),
    })
end

-- Every command below is an argument vector, never a shell line: plugin_api
-- >= 24 lets noctalia.runAsync take the argv directly and exec it, so nothing
-- this plugin runs is ever parsed by a shell. That is what the privileged path
-- is really about — a sudoers NOPASSWD rule naming /usr/bin/nmcli authorizes
-- the binary, and there is now no `sh -c` anywhere for it to fail to cover.
-- `env LC_ALL=C` replaces what the old shell line set: nmcli's field values are
-- locale-independent, but its stderr is not, and apply() below reads it.
local function nmcli(...)
    return { "env", "LC_ALL=C", "nmcli", ... }
end

-- One row of `nmcli -t -f TYPE,DEVICE,UUID,NAME connection show --active`.
-- TYPE, DEVICE and UUID never contain a colon; NAME can, so it takes the rest
-- of the line — the same split the previous `cut -d: -f4-` did.
local function parseConnectionRow(line)
    local kind, device, uuid, name = line:match("^([^:]*):([^:]*):([^:]*):(.*)$")
    if uuid == nil or uuid == "" then
        return nil
    end
    return { kind = kind, device = device, uuid = uuid, name = name }
end

-- The connection to act on: prefer wifi/ethernet, else the first non-loopback
-- entry. Was a grep/head pipeline inside the detect script; in Luau it is the
-- one rule both detection and apply() go through, so the two can no longer
-- disagree about which connection is "the" one.
local function pickConnection(stdout)
    local fallback = nil
    for line in stdout:gmatch("[^\n]+") do
        local row = parseConnectionRow(line)
        if row ~= nil then
            if row.kind == "802-11-wireless" or row.kind == "802-3-ethernet" then
                return row
            end
            if fallback == nil and row.kind ~= "loopback" then
                fallback = row
            end
        end
    end
    return fallback
end

-- `cfg` is the profile's ipv4.dns, `auto` its ipv4.ignore-auto-dns, `run` the
-- device's live IP4.DNS. Split out of the old KEY=value echo protocol: the
-- three now arrive as the plain stdout of three nmcli calls.
local function updateDnsState(con, cfgDns, auto, run)
    if con == nil then
        current = nil
        errMsg = tr("err_no_connection")
        return
    end
    errMsg = nil
    conName = con.name or ""

    local runtime = {}
    for token in (run or ""):gmatch("%d+%.%d+%.%d+%.%d+") do
        if isValidIp(token) then
            table.insert(runtime, token)
        end
    end
    lastSeen = table.concat(runtime, " ")

    -- Manual DNS lives in the profile (ipv4.dns + ignore-auto-dns yes);
    -- anything else is the connection default, whatever the LAN hands out.
    local manual = (trim(auto or "") == "yes")
    local cfgIps = {}
    for token in (cfgDns or ""):gmatch("%d+%.%d+%.%d+%.%d+") do
        if isValidIp(token) then
            table.insert(cfgIps, token)
        end
    end
    if not manual or #cfgIps == 0 then
        current = defaultEntry()
        return
    end

    -- Customs take precedence over built-ins, so a custom entry that reuses
    -- a public IP (e.g. a forwarder) keeps its own label.
    local lookup = {}
    for _, provider in ipairs(BUILTIN) do
        for ip in provider.ip:gmatch("%S+") do
            lookup[ip] = provider
        end
    end
    for _, provider in ipairs(customProviders()) do
        for ip in provider.ip:gmatch("%S+") do
            lookup[ip] = provider
        end
    end
    for _, ip in ipairs(cfgIps) do
        if lookup[ip] ~= nil then
            current = lookup[ip]
            return
        end
    end
    current = {
        id = "unknown",
        label = tr("status_custom", { ip = cfgIps[1] }),
        ip = table.concat(cfgIps, " "),
        glyph = GLYPH_UNKNOWN,
    }
end

-- Run one nmcli query and hand its stdout on, or nil when it could not be
-- asked. Every detection step below has the same shape, and none of them is
-- fatal on its own: a missing answer just leaves that field empty.
local function query(argv, done)
    local ok = noctalia.runAsync(argv, function(result)
        if result.exitCode == 0 and not result.timedOut then
            done(result.stdout or "")
        else
            done(nil)
        end
    end, 4000)
    if not ok then
        done(nil)
    end
end

-- Detection, as three chained nmcli calls: the active connections, then the
-- chosen one's profile DNS settings, then the DNS its device is actually
-- using. It was one shell script with an echo protocol between the two halves;
-- chained argv calls cost two extra round trips on a poll that runs every
-- pollSeconds() and buys the shell being gone from the plugin entirely.
--
-- `checkInFlight` spans the whole chain, so a poll tick landing mid-chain is
-- dropped rather than starting a second one.
local function pollNow()
    if checkInFlight or changing or nmcliMissing then
        return
    end
    checkInFlight = true
    local function finish()
        checkInFlight = false
        publish()
    end
    query(nmcli("-t", "-f", "TYPE,DEVICE,UUID,NAME", "connection", "show", "--active"), function(active)
        if active == nil then
            -- nmcli itself did not answer; keep whatever was last detected
            -- rather than claiming there is no connection.
            if current == nil then
                errMsg = tr("status_no_nmcli")
            end
            finish()
            return
        end
        local con = pickConnection(active)
        if con == nil then
            updateDnsState(nil)
            finish()
            return
        end
        query(nmcli("-g", "ipv4.dns,ipv4.ignore-auto-dns", "connection", "show", "uuid", con.uuid), function(profile)
            -- Two -g fields, one value per line and in the order asked for.
            local cfgDns, auto = (profile or ""):match("^([^\n]*)\n([^\n]*)")
            query(nmcli("-g", "IP4.DNS", "device", "show", con.device), function(run)
                updateDnsState(con, cfgDns, auto, run)
                finish()
            end)
        end)
    end)
end

local function apply(provider)
    if changing then
        return
    end
    -- No "already active" short-circuit: `current` is only ever refreshed by
    -- the async poll, so it can be stale by up to a full pollSeconds() window
    -- (shorter but still nonzero right after another apply/cycle). Skipping
    -- here on a stale match would silently drop a legitimate request instead
    -- of just doing one harmless idempotent nmcli round trip.
    if provider.ip ~= "" and not validDnsSpec(provider.ip) then
        noctalia.notifyError(tr("title"), tr("err_invalid_ip", { ip = provider.ip }))
        return
    end

    -- The DNS list reaches nmcli as one argv element, so it is never split,
    -- globbed or re-parsed on the way. validDnsSpec above already limits it to
    -- one or two dotted quads; this is the value nmcli stores verbatim.
    local mods
    if provider.ip == "" then
        mods = { "ipv4.dns", "", "ipv4.ignore-auto-dns", "no" }
    else
        mods = { "ipv4.dns", provider.ip, "ipv4.ignore-auto-dns", "yes" }
    end

    -- The privilege command becomes the leading argv elements of each mutating
    -- call, split on whitespace: "sudo", "pkexec", "sudo -n" all work; a path
    -- with spaces in it does not, and a wrapper script is the answer there.
    -- Prefixed onto each nmcli invocation individually, never onto a wrapping
    -- shell — the README's sudoers example authorizes the nmcli binary itself
    -- (NOPASSWD: /usr/bin/nmcli), which would never cover a shell run under
    -- sudo. Discovering the device/uuid stays unprivileged either way (it is a
    -- plain read), so only the two mutating calls carry it.
    local priv = cfg("privilege_command")
    if type(priv) ~= "string" then
        priv = ""
    end
    local privArgv = {}
    for word in priv:gmatch("%S+") do
        table.insert(privArgv, word)
    end

    -- `env LC_ALL=C` goes in FRONT of the privilege command, not between it and
    -- nmcli: sudo and pkexec match their policy against the program they are
    -- asked to run, so `sudo env … nmcli` is a request to run /usr/bin/env and
    -- the README's `NOPASSWD: /usr/bin/nmcli` rule would stop matching. This
    -- way the privileged program stays nmcli itself. The locale still reaches
    -- it under sudo, whose default sudoers keeps LC_* (`env_keep`); pkexec
    -- scrubs the environment and nmcli's stderr comes back localized there,
    -- which only costs the message match below its shortcut — the raw stderr
    -- is still shown.
    local function privileged(...)
        local argv = { "env", "LC_ALL=C" }
        for _, word in ipairs(privArgv) do
            table.insert(argv, word)
        end
        table.insert(argv, "nmcli")
        for _, word in ipairs({ ... }) do
            table.insert(argv, word)
        end
        return argv
    end

    local function failed(result)
        changing = false
        if result == nil then
            noctalia.notifyError(tr("title"), tr("err_spawn"))
        elseif result.timedOut then
            noctalia.notifyError(tr("title"), tr("err_timeout"))
        elseif result.exitCode == 126 then
            noctalia.notifyError(tr("title"), tr("err_auth_dismissed"))
        else
            local detail = trim(result.stderr or "")
            if #detail > 200 then
                detail = detail:sub(1, 200) .. "…"
            end
            local body = tr("err_apply_failed")
            if detail:lower():find("not authorized") or detail:lower():find("insufficient") then
                body = tr("err_not_authorized")
            elseif detail ~= "" then
                body = body .. "\n" .. detail
            end
            noctalia.notifyError(tr("title"), body)
        end
        publish()
        pollNow()
    end

    changing = true
    publish()

    -- Three steps where there used to be one shell line: find the connection,
    -- write the profile, push it onto the live device. The 60s budget is on
    -- each of the two privileged calls, so a polkit password prompt has the
    -- same room to be answered as before.
    local ok = noctalia.runAsync(
        nmcli("-t", "-f", "TYPE,DEVICE,UUID,NAME", "connection", "show", "--active"),
        function(listed)
            if listed.exitCode ~= 0 or listed.timedOut then
                failed(listed)
                return
            end
            local con = pickConnection(listed.stdout or "")
            if con == nil then
                changing = false
                noctalia.notifyError(tr("title"), tr("err_no_connection"))
                publish()
                pollNow()
                return
            end
            local modArgv = privileged("con", "mod", con.uuid)
            for _, word in ipairs(mods) do
                table.insert(modArgv, word)
            end
            local modOk = noctalia.runAsync(modArgv, function(modded)
                if modded.exitCode ~= 0 or modded.timedOut then
                    failed(modded)
                    return
                end
                -- reapply pushes the profile onto the live connection without
                -- reactivating it, so the network never drops.
                local reapplyOk = noctalia.runAsync(
                    privileged("device", "reapply", con.device),
                    function(reapplied)
                        if reapplied.exitCode ~= 0 or reapplied.timedOut then
                            failed(reapplied)
                            return
                        end
                        changing = false
                        noctalia.notify(tr("title"), tr("applied", { name = provider.label }))
                        publish()
                        pollNow()
                    end, 60000
                )
                if not reapplyOk then
                    failed(nil)
                end
            end, 60000)
            if not modOk then
                failed(nil)
            end
        end, 4000
    )
    if not ok then
        failed(nil)
    end
end

-- Resolves an apply request against the current provider list (so config
-- edits win over stale request payloads), falling back to the request's own
-- label/ip for entries that just left the list.
local function applyById(id, label, ip)
    for _, entry in ipairs(providerList()) do
        if entry.id == id then
            apply(entry)
            return true
        end
    end
    if id == "default" or (type(ip) == "string" and validDnsSpec(ip)) then
        apply({ id = id, label = label or id, ip = id == "default" and "" or ip })
        return true
    end
    return false
end

-- Steps the active provider to its neighbour in providerList() (wrapping at
-- either end). Backs the bar widget's scroll_up/scroll_down gesture default;
-- with no detected current provider yet, "next" starts at the first entry
-- rather than doing nothing.
local function cycleTo(direction)
    local list = providerList()
    if #list == 0 then
        return
    end
    local index = 1
    if current ~= nil then
        for i, entry in ipairs(list) do
            if entry.id == current.id then
                index = i
                break
            end
        end
        index = index + (direction == "prev" and -1 or 1)
        if index < 1 then
            index = #list
        elseif index > #list then
            index = 1
        end
    end
    apply(list[index])
end

-- Apply requests from the widget/panel. The nonce is monotonic across
-- writers (each seeds from the last request) and guards against replaying a
-- stale request after a hot reload of this script.
local handledNonce = 0
do
    local pendingReq = noctalia.state.get(REQUEST_KEY)
    if type(pendingReq) == "table" and type(pendingReq.nonce) == "number" then
        handledNonce = pendingReq.nonce
    end
end
noctalia.state.watch(REQUEST_KEY, function(req)
    if type(req) ~= "table" or type(req.nonce) ~= "number" or req.nonce <= handledNonce then
        return
    end
    handledNonce = req.nonce
    if nmcliMissing then
        return
    end
    applyById(req.id, req.label, req.ip)
end)

-- Scriptable switching:
--   noctalia msg plugin nightwatch75/dns-switcher:service all apply <id>
-- where <id> is a provider id ("google", "default", "custom:<name>"…);
-- "poll" forces an immediate re-detection; "cycle next"/"cycle prev" steps to
-- the neighbouring provider in the panel's own order (this is what the bar
-- widget's scroll_up/scroll_down gesture defaults send, [widget.actions] in
-- plugin.toml).
function onIpc(event, payload)
    if nmcliMissing then
        return
    end
    if event == "poll" then
        pollNow()
    elseif event == "apply" then
        local id = type(payload) == "string" and trim(payload) or ""
        if not applyById(id) then
            noctalia.notifyError(tr("title"), tr("err_unknown_provider", { id = id }))
        end
    elseif event == "cycle" then
        local direction = type(payload) == "string" and trim(payload) or "next"
        cycleTo(direction)
    end
end

-- plugin_api >= 17. A hot reload (editing this file) tears this VM down and a
-- fresh one starts moments later, which republishes its own state on load —
-- nothing to do for "reload". On disable/uninstall/shutdown mid-apply,
-- though, nothing ever republishes again: without this, every widget/panel
-- instance reading the shared state would stay frozen on "changing" forever.
-- The in-flight nmcli command is not ours to cancel either way — runAsync
-- hands back no killable handle, and it is idempotent (con mod + reapply), so
-- letting it finish in the background is harmless. This only stops
-- describing it as in progress. The DNS choice itself is never touched here:
-- it lives in the NetworkManager connection profile, independent of whether
-- this plugin is enabled at all.
function onExit(_signal, reason)
    if reason == "reload" then
        return
    end
    if changing then
        changing = false
        publish()
    end
end

function onConfigChanged()
    -- Settings edits reshape the provider list and may relabel the current
    -- entry; re-publish and re-check right away.
    publish()
    pollNow()
end

function update()
    if nmcliMissing then
        return
    end
    pollTicks += 1
    if pollTicks >= pollSeconds() then
        pollTicks = 0
        pollNow()
    end
end

noctalia.setUpdateInterval(1000)
if not noctalia.commandExists("nmcli") then
    nmcliMissing = true
    errMsg = tr("status_no_nmcli")
    current = nil
    publish()
    noctalia.notifyError(tr("title"), tr("err_no_nmcli"))
else
    publish()
    pollNow()
end
