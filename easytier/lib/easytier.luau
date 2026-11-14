--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- lib/easytier.luau —— fetching, shaping and formatting EasyTier runtime data
--
-- All data comes from the JSON output of easytier-cli (-o json), invoked as a subprocess
-- (noctalia.runAsync, argv array form, never through a shell):
--   node          local node: virtual IP, hostname, peer_id, STUN public address, listeners, config text
--   peer          peers: cost (Local / p2p / relay), latency, loss, rx/tx bytes, tunnel protocol, NAT type
--   route         routing table: next hop, hop count, path latency
--   connector     connectors: reachability status of every --peer address
--   proxy         TCP / KCP proxy
--   port-forward  port forwarding
--
-- bar.luau (bar widget) and panel.luau (detail panel) share this one implementation:
--   * config reads: noctalia.getConfig takes one argument and has no default, so it is handled here once
--   * concurrent fetching: several subcommands start at once, all assembled into one snapshot on return
--   * derived metrics: direct / relay counts, best / average / worst latency, loss surface, rx/tx traffic
--   * formatting: bytes, percentages, NAT type, virtual IP, instance ID
--
-- Read-only: never writes EasyTier config files, never changes runtime state, stays no process resident.
-- ══════════════════════════════════════════════════════════════════════════

local M = {}

M.VERSION = "1.0.0"

-- Timeout of a single easytier-cli call (the host clamps timeoutMs to [50, 60000])
M.TIMEOUT_MS = 8000

-- The bar widget needs only these (cheapest); the full fetch is left until the panel opens
M.FAST_SUBS = { "node", "peer" }
M.FULL_SUBS = { "node", "peer", "route", "connector", "proxy", "port-forward" }

-- Subcommand → snapshot field name (port-forward reads .cfgs)
local SUB_FIELDS = {
    ["node"] = "node",
    ["peer"] = "peers",
    ["route"] = "routes",
    ["connector"] = "connectors",
    ["proxy"] = "proxies",
    ["port-forward"] = "forwards",
}

-- ── Settings access ────────────────────────────────────────────────────────

local function raw(key)
    local ok, value = pcall(noctalia.getConfig, key)
    if not ok then
        return nil
    end
    return value
end

--- String setting; an empty string counts as unset and falls back to default
function M.text(key, default)
    local value = raw(key)
    if type(value) ~= "string" or value == "" then
        return default
    end
    return value
end

--- Boolean setting; accepts string/number forms too
function M.flag(key, default)
    local value = raw(key)
    if type(value) == "boolean" then
        return value
    end
    if type(value) == "number" then
        return value ~= 0
    end
    if type(value) == "string" then
        if value == "true" or value == "1" then
            return true
        end
        if value == "false" or value == "0" then
            return false
        end
    end
    return default
end

--- Numeric setting; accepts numbers written as strings
function M.number(key, default)
    local value = raw(key)
    if type(value) == "number" then
        return value
    end
    local parsed = tonumber(value)
    if parsed ~= nil then
        return parsed
    end
    return default
end

function M.clamp(value, low, high)
    if value < low then
        return low
    end
    if value > high then
        return high
    end
    return value
end

--- Translation; falls back to the Chinese default when the key is missing
function M.tr(key, fallback)
    local ok, value = pcall(noctalia.tr, key)
    if ok and type(value) == "string" and value ~= "" and value ~= key then
        return value
    end
    return fallback or key
end

--- Current settings (re-read every round, so changes need no plugin reload; plugin.toml default only covers the first)
function M.cfg()
    local warn = M.number("warn_latency_ms", 150)
    local crit = M.number("crit_latency_ms", 400)
    if crit <= warn then
        crit = warn + 1
    end
    return {
        cli = M.text("cli_path", ""),
        portal = M.text("rpc_portal", ""),
        instanceName = M.text("instance_name", ""),
        instanceId = M.text("instance_id", ""),
        refresh = M.clamp(M.number("refresh_seconds", 10), 2, 600),
        warnLatency = warn,
        critLatency = crit,
        relayWarn = M.flag("relay_warn", true),
        lossCrit = M.clamp(M.number("loss_crit_percent", 10), 1, 100),
        lossWarn = M.clamp(M.number("loss_warn_percent", 2), 1, 100),
        extras = M.flag("fetch_extras", true),
        maxPeers = M.clamp(M.number("max_peers", 64), 4, 512),
        serverPrefix = M.text("server_prefix", "PublicServer"),
        notify = M.flag("notify_state_change", false),
    }
end

-- ── Numbers and units ──────────────────────────────────────────────────────

--- Extract a number from an EasyTier field: "29.40" → 29.4; "-" → nil
function M.num(value)
    if type(value) == "number" then
        return value
    end
    if type(value) ~= "string" then
        return nil
    end
    local head = value:match("^%s*([%-%+]?[%d%.]+)")
    if head == nil then
        return nil
    end
    return tonumber(head)
end

local BYTE_MULT = {
    B = 1,
    b = 1,
    K = 1024,
    kB = 1024,
    KB = 1024,
    kb = 1024,
    KiB = 1024,
    M = 1024 * 1024,
    MB = 1024 * 1024,
    MiB = 1024 * 1024,
    G = 1024 * 1024 * 1024,
    GB = 1024 * 1024 * 1024,
    GiB = 1024 * 1024 * 1024,
    T = 1024 * 1024 * 1024 * 1024,
    TB = 1024 * 1024 * 1024 * 1024,
    TiB = 1024 * 1024 * 1024 * 1024,
}

--- "100.47 kB" → 102881; returns nil when unparsable
function M.parseBytes(value)
    if type(value) == "number" then
        return value
    end
    if type(value) ~= "string" then
        return nil
    end
    local number_, unit = value:match("^%s*([%d%.]+)%s*(%a*)%s*$")
    if number_ == nil then
        return nil
    end
    local n = tonumber(number_)
    if n == nil then
        return nil
    end
    if unit == "" then
        return n
    end
    local mult = BYTE_MULT[unit] or BYTE_MULT[unit:upper()]
    if mult == nil then
        -- Unknown unit (e.g. "B/s"): treat it as a byte count, at least no information is lost
        return n
    end
    return n * mult
end

local BYTE_UNITS = { "B", "K", "M", "G", "T", "P" }

--- Byte count → human readable (base 1024, must stay short on the bar: 9.8K / 100K / 5.9M)
function M.bytes(value)
    if type(value) ~= "number" or value < 0 then
        return "--"
    end
    local scaled = value
    local index = 1
    while scaled >= 1024 and index < #BYTE_UNITS do
        scaled = scaled / 1024
        index += 1
    end
    if index == 1 then
        return string.format("%d%s", scaled, BYTE_UNITS[index])
    end
    if scaled < 10 then
        return string.format("%.1f%s", scaled, BYTE_UNITS[index])
    end
    return string.format("%d%s", scaled, BYTE_UNITS[index])
end

--- Latency text: 29ms ("-" when there is no data)
function M.ms(value)
    if type(value) ~= "number" then
        return "-"
    end
    if value >= 1000 then
        return string.format("%.2fs", value / 1000)
    end
    if value >= 100 then
        return string.format("%dms", math.floor(value + 0.5))
    end
    return string.format("%.1fms", value)
end

--- Packet loss text: one decimal place
function M.percentText(value)
    if type(value) ~= "number" then
        return "-"
    end
    if value == 0 then
        return "0%"
    end
    if value < 1 then
        return string.format("%.1f%%", value)
    end
    return string.format("%.1f%%", value)
end

--- 32-bit integer → dotted decimal (node.ip_list.public_ipv4.addr is an integer form)
function M.ipFromInt(value)
    if type(value) ~= "number" or value < 0 or value > 4294967295 then
        return nil
    end
    local n = math.floor(value)
    return string.format("%d.%d.%d.%d", math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

--- "172.24.1.1/16" → "172.24.1.1"
function M.stripCidr(value)
    if type(value) ~= "string" then
        return nil
    end
    local trimmed = value:match("^%s*(.-)%s*$")
    if trimmed == "" then
        return nil
    end
    return (trimmed:match("^([^/]+)") or trimmed)
end

-- ── NAT types ──────────────────────────────────────────────────────────────
-- node.stun_info.udp_nat_type is an enum number; nat_type in the peer table is the string
-- form of the same enum (measured 6 ↔ "Symmetric"), so the two tables line up.

local NAT_NAMES = {
    [0] = "Unknown",
    [1] = "OpenInternet",
    [2] = "NoPAT",
    [3] = "FullCone",
    [4] = "Restricted",
    [5] = "PortRestricted",
    [6] = "Symmetric",
    [7] = "SymUdpFirewall",
    [8] = "SymmetricEasyInc",
    [9] = "SymmetricEasyDec",
}

function M.natName(value)
    if type(value) == "string" then
        if value == "" or value == "-" then
            return nil
        end
        return value
    end
    if type(value) == "number" then
        return NAT_NAMES[value] or ("#" .. tostring(value))
    end
    return nil
end

-- ── Command building and fetching ──────────────────────────────────────────

--- easytier-cli executable: use the configured one when set, otherwise leave it to PATH
function M.cliPath(cfg)
    if cfg and cfg.cli ~= "" then
        return cfg.cli
    end
    return "easytier-cli"
end

--- Whether cli is available (check the file for an absolute path, PATH otherwise)
function M.cliAvailable(cfg)
    local path = M.cliPath(cfg)
    local ok, result
    if path:find("/", 1, true) then
        ok, result = pcall(noctalia.fileExists, path)
    else
        ok, result = pcall(noctalia.commandExists, path)
    end
    return ok and result == true
end

--- Build the argv of one subcommand (argv form skips the shell, so spaces in instance names are safe)
function M.argv(cfg, sub)
    local argv = { M.cliPath(cfg) }
    if cfg.portal ~= "" then
        table.insert(argv, "-p")
        table.insert(argv, cfg.portal)
    end
    if cfg.instanceName ~= "" then
        table.insert(argv, "-n")
        table.insert(argv, cfg.instanceName)
    end
    if cfg.instanceId ~= "" then
        table.insert(argv, "-i")
        table.insert(argv, cfg.instanceId)
    end
    table.insert(argv, "-o")
    table.insert(argv, "json")
    table.insert(argv, sub)
    return argv
end

local function once(fn)
    local done = false
    return function(...)
        if done then
            return
        end
        done = true
        return fn(...)
    end
end

--- Result of one command → decoded value; on failure returns (nil, reason)
local function decodeResult(res)
    if type(res) ~= "table" then
        return nil, "nofork"
    end
    if res.timedOut then
        return nil, "timeout"
    end
    if res.exitCode ~= 0 then
        local why = tostring(res.stderr or ""):gsub("%s+$", "")
        if why == "" then
            return nil, "exit"
        end
        return nil, "rpc"
    end
    local out = tostring(res.stdout or "")
    if out:match("^%s*$") then
        return nil, "empty"
    end
    local value = noctalia.json.decode(out)
    if value == nil then
        return nil, "json"
    end
    return value
end

--- Fetch several subcommands concurrently, then call back with the snapshot once all return.
---   snap = { at, failed = { [sub] = reason }, node, peers, routes, connectors, proxies, forwards }
--- A single subcommand failing does not affect the whole: a missing `node` means core is not running / RPC is unreachable.
function M.fetch(cfg, subs, cb)
    subs = subs or M.FAST_SUBS
    local snap = { at = os.time(), failed = {}, started = os.time() }
    local pending = #subs
    if pending == 0 then
        cb(snap)
        return
    end

    local function done()
        pending -= 1
        if pending == 0 then
            cb(snap)
        end
    end

    for _, sub in ipairs(subs) do
        local handle = once(function(res)
            local value, why = decodeResult(res)
            if value == nil then
                snap.failed[sub] = why or "error"
            else
                local field = SUB_FIELDS[sub]
                if field == nil then
                    snap.failed[sub] = "unknown"
                elseif sub == "port-forward" then
                    -- The port-forward outer layer is { cfgs = [...] }
                    snap.forwards = (type(value) == "table" and value.cfgs) or {}
                elseif sub == "node" then
                    -- node occasionally returns an array wrapping one entry; normalise it to an object
                    if type(value) == "table" and value[1] ~= nil then
                        value = value[1]
                    end
                    snap.node = value
                else
                    snap[field] = value
                end
            end
            done()
        end)

        local argv = M.argv(cfg, sub)
        local ok, started = pcall(noctalia.runAsync, argv, handle, M.TIMEOUT_MS)
        if not ok or started ~= true then
            -- Failing to start means the command is missing / rejected: count it as one failure so pending never hangs
            handle(nil)
        end
    end
end

-- ── Derived metrics ────────────────────────────────────────────────────────

--- cost classification: local (this machine) / p2p (direct) / relay (relayed) / other
function M.costOf(peer)
    local cost = tostring((peer and peer.cost) or "")
    local low = cost:lower()
    if low == "" then
        return "other"
    end
    if low:find("local", 1, true) then
        return "local"
    end
    if low:find("relay", 1, true) then
        return "relay"
    end
    if low:find("p2p", 1, true) then
        return "p2p"
    end
    return "other"
end

--- Summarise one snapshot: node counts, latency distribution, loss surface, rx/tx traffic
function M.derive(snap, cfg)
    local prefixes = M.prefixes(cfg)
    local critLatency = (cfg and cfg.critLatency) or math.huge
    local lossCrit = (cfg and cfg.lossCrit) or math.huge
    local d = {
        total = 0,
        direct = 0,
        relay = 0,
        other = 0,
        servers = 0,
        serversUp = 0,
        serversDown = 0,
        best = nil,
        worst = nil,
        sum = 0,
        counted = 0,
        avg = nil,
        lossy = 0,
        lossMax = 0,
        lossSum = 0,
        rx = 0,
        tx = 0,
        own = nil,
        ready = false,
    }

    for _, peer in ipairs((snap and snap.peers) or {}) do
        local cost = M.costOf(peer)
        if cost == "local" then
            d.own = peer
        else
            d.total += 1
            if cost == "p2p" then
                d.direct += 1
            elseif cost == "relay" then
                d.relay += 1
            else
                d.other += 1
            end
            local latency = M.num(peer.lat_ms)
            if latency ~= nil then
                if d.best == nil or latency < d.best then
                    d.best = latency
                end
                if d.worst == nil or latency > d.worst then
                    d.worst = latency
                end
                d.sum += latency
                d.counted += 1
            end
            local loss = M.num(peer.loss_rate)
            if loss ~= nil and loss > 0 then
                d.lossy += 1
                d.lossSum += loss
                if loss > d.lossMax then
                    d.lossMax = loss
                end
            end

            -- Server nodes (public shared nodes) are accounted separately: the mesh counts as broken only when all are down
            if M.isServer(peer.hostname, prefixes) then
                d.servers += 1
                local down = (latency ~= nil and latency >= critLatency)
                    or (loss ~= nil and loss >= lossCrit)
                if down then
                    d.serversDown += 1
                else
                    d.serversUp += 1
                end
            end
        end
        d.rx += M.parseBytes(peer.rx_bytes) or 0
        d.tx += M.parseBytes(peer.tx_bytes) or 0
    end

    if d.counted > 0 then
        d.avg = d.sum / d.counted
    end
    d.ready = d.total > 0
    return d
end

--- Status grading: off (core not running) / ok / warn / crit
---   Red is reserved for "no server node is available": public servers are the cross-network fallback path,
---   so as long as one is available the mesh is intact and poor latency/loss only degrades to "high" (user requirement).
---   Each server's availability uses the critical threshold: latency ≥ crit_latency_ms or loss ≥ loss_crit_percent.
function M.level(cfg, snap, derived)
    if snap == nil then
        return "loading"
    end
    if snap.node == nil then
        return "off"
    end
    local d = derived or M.derive(snap, cfg)
    if d.servers > 0 and d.serversDown >= d.servers then
        return "crit"
    end
    -- Some servers unavailable but not all down → yellow warning, never red
    if d.servers > 0 and d.serversDown > 0 then
        return "warn"
    end
    if d.best ~= nil and d.best >= cfg.warnLatency then
        return "warn"
    end
    if d.avg ~= nil and d.avg >= cfg.warnLatency then
        return "warn"
    end
    -- Loss is judged by the worst node: loss on a single node may mean one link is dropping,
    -- but only above the threshold does it degrade —— an occasional 1% jitter is not worth yellowing the whole bar.
    if d.lossMax >= cfg.lossWarn then
        return "warn"
    end
    if cfg.relayWarn and d.relay > 0 then
        return "warn"
    end
    return "ok"
end

--- Availability summary of server nodes (public shared nodes): bar hint and panel share one wording
function M.serversText(d)
    if d == nil or (d.servers or 0) == 0 then
        return M.tr("tt_servers_none", "none")
    end
    local down = d.serversDown or 0
    if down >= d.servers then
        return string.format(M.tr("tt_servers_down", "all %d unreachable"), d.servers)
    end
    if down > 0 then
        return string.format(M.tr("tt_servers_partial", "%d/%d healthy (%d unreachable)"), d.serversUp or (d.servers - down), d.servers, down)
    end
    return string.format(M.tr("tt_servers_ok", "all %d healthy"), d.servers)
end

-- The theme exposes only four usable roles: primary / secondary / tertiary / error
local LEVEL_ROLE = {
    loading = "on_surface_variant",
    off = "error",
    ok = "primary",
    warn = "tertiary",
    crit = "error",
}

function M.roleOf(level)
    return LEVEL_ROLE[level] or "primary"
end

--- Row data of one peer (shared by the panel and the bar)
function M.row(peer, cfg)
    local cost = M.costOf(peer)
    local latency = M.num(peer.lat_ms)
    local loss = M.num(peer.loss_rate)
    local level = "ok"
    if latency ~= nil and latency >= cfg.critLatency then
        level = "crit"
    elseif loss ~= nil and loss >= cfg.lossCrit then
        level = "crit"
    elseif latency ~= nil and latency >= cfg.warnLatency then
        level = "warn"
    elseif (loss ~= nil and loss >= cfg.lossWarn) or cost == "relay" then
        level = "warn"
    end
    return {
        peer = peer,
        hostname = tostring(peer.hostname or "?"),
        ip = M.stripCidr(peer.ipv4),
        cidr = peer.ipv4,
        cost = cost,
        costText = tostring(peer.cost or "-"),
        latency = latency,
        loss = loss,
        level = level,
        proto = tostring(peer.tunnel_proto or "-"),
        nat = M.natName(peer.nat_type),
        version = tostring(peer.version or "-"),
        id = tostring(peer.id or ""),
        rx = M.parseBytes(peer.rx_bytes),
        tx = M.parseBytes(peer.tx_bytes),
    }
end

local COST_ORDER = { ["local"] = 0, p2p = 1, relay = 2, other = 3 }

--- Row list for the panel: direct links first, relays after, same tier by ascending latency
function M.rows(snap, cfg)
    local out = {}
    for _, peer in ipairs((snap and snap.peers) or {}) do
        local row = M.row(peer, cfg)
        if row.cost ~= "local" then
            table.insert(out, row)
        end
    end
    table.sort(out, function(a, b)
        local oa = COST_ORDER[a.cost] or 9
        local ob = COST_ORDER[b.cost] or 9
        if oa ~= ob then
            return oa < ob
        end
        local la = a.latency or math.huge
        local lb = b.latency or math.huge
        if la ~= lb then
            return la < lb
        end
        return a.hostname < b.hostname
    end)
    return out
end

--- Hostname prefix list (plugin.toml server_prefix, comma separated; both ASCII and CJK commas understood)
function M.prefixes(cfg)
    local out = {}
    for piece in tostring((cfg and cfg.serverPrefix) or ""):gmatch("[^,，]+") do
        local trimmed = piece:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            table.insert(out, trimmed:lower())
        end
    end
    return out
end

--- Whether it counts as a "server node": public shared nodes (EasyTier's official PublicServer_* naming)
--- Note: not the cost = relay kind of relay-mode node; the two are unrelated
function M.isServer(hostname, prefixes)
    local name = tostring(hostname or ""):lower()
    if name == "" then
        return false
    end
    for _, prefix in ipairs(prefixes or {}) do
        if name:find(prefix, 1, true) ~= nil then
            return true
        end
    end
    return false
end

--- Split node rows into two groups: ordinary devices and server nodes (public shared nodes).
--- The panel uses this to give servers their own section, collapsed by default.
--- @return table ordinary node rows, table server node rows
function M.splitRows(rows, cfg)
    local prefixes = M.prefixes(cfg)
    local normal, servers = {}, {}
    for _, row in ipairs(rows or {}) do
        if M.isServer(row.hostname, prefixes) then
            table.insert(servers, row)
        else
            table.insert(normal, row)
        end
    end
    return normal, servers
end

--- Local node information (top card of the panel)
function M.nodeInfo(snap)
    local node = snap and snap.node
    if type(node) ~= "table" then
        return nil
    end
    local stun = type(node.stun_info) == "table" and node.stun_info or {}
    local publicIp = nil
    if type(stun.public_ip) == "table" and stun.public_ip[1] ~= nil then
        publicIp = tostring(stun.public_ip[1])
    elseif type(node.ip_list) == "table" and type(node.ip_list.public_ipv4) == "table" then
        publicIp = M.ipFromInt(node.ip_list.public_ipv4.addr)
    end

    local udpNat = M.natName(stun.udp_nat_type)
    local tcpNat = M.natName(stun.tcp_nat_type)

    -- Among listeners, ring:// is an internal loopback and not an externally reachable service
    local listeners = {}
    for _, entry in ipairs((type(node.listeners) == "table" and node.listeners) or {}) do
        local text = tostring(entry)
        if not text:find("^ring://") then
            table.insert(listeners, text)
        end
    end

    local proxyCidrs = {}
    for _, cidr in ipairs((type(node.proxy_cidrs) == "table" and node.proxy_cidrs) or {}) do
        table.insert(proxyCidrs, tostring(cidr))
    end

    return {
        hostname = tostring(node.hostname or "?"),
        ip = M.stripCidr(node.ipv4_addr),
        cidr = node.ipv4_addr,
        peerId = tostring(node.peer_id or ""),
        instId = tostring(node.inst_id or ""),
        version = tostring(node.version or ""),
        nat = udpNat or tcpNat,
        udpNat = udpNat,
        tcpNat = tcpNat,
        publicIp = publicIp,
        listeners = listeners,
        proxyCidrs = proxyCidrs,
        network = M.networkName(snap),
        publicPortRange = (type(stun.min_port) == "number" and type(stun.max_port) == "number")
                and string.format("%d-%d", stun.min_port, stun.max_port)
            or nil,
    }
end

--- The network name comes from the TOML text of node.config (there is no dedicated field)
function M.networkName(snap)
    local text = snap and snap.node and snap.node.config
    if type(text) ~= "string" then
        return nil
    end
    return text:match('network_name%s*=%s*"([^"]*)"')
end

--- Abbreviated instance ID: first 8 characters + last 4
function M.shortId(value)
    if type(value) ~= "string" or value == "" then
        return nil
    end
    if #value <= 14 then
        return value
    end
    return string.format("%s…%s", value:sub(1, 8), value:sub(-4))
end

--- Addresses in connectors: { { url = { url = "tcp://…" }, status = 0 }, … } → { {url, ok} }
function M.connectorRows(snap)
    local out = {}
    for _, entry in ipairs((snap and snap.connectors) or {}) do
        local url = nil
        if type(entry) == "table" then
            if type(entry.url) == "table" then
                url = entry.url.url or entry.url.Url
            elseif type(entry.url) == "string" then
                url = entry.url
            end
        end
        if url ~= nil then
            table.insert(out, {
                url = tostring(url),
                status = tonumber(entry.status) or 0,
            })
        end
    end
    return out
end

--- Running status wording (shared by bar and panel)
function M.statusText(cfg, snap)
    if snap == nil then
        return M.tr("status_loading", "reading…")
    end
    if snap.node ~= nil then
        return M.tr("status_running", "running")
    end
    if not M.cliAvailable(cfg) then
        return M.tr("status_no_cli", "easytier-cli not found")
    end
    if snap.failed.node == "nofork" then
        return M.tr("status_nofork", "cannot start easytier-cli")
    end
    if snap.failed.node == "timeout" then
        return M.tr("status_timeout", "RPC timeout")
    end
    return M.tr("status_stopped", "not running")
end

return M
