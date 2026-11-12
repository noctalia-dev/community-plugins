--!nonstrict
-- kuma-status — pure data functions (no noctalia.* access): parsing of /metrics,
-- /api/monitors (Kuma 3) and status-page JSON, URL validation, grouping.
-- Monitor names and URLs are untrusted: all UI text passes through safeText.
--
--   Metric     = { id, name, type, url?, link?, status, ping?, uptime1d?, certDays?, tags, muted? }
--   Structure  = { id, name, type, parent?, children, tags, active }
--   StatusPage = { slug, title, url, groups = { { name, monitors = { { id, name, beats } } } } }
-- Status codes: 0 down, 1 up, 2 pending, 3 maintenance.

local K = {}

local MAX_NAME = 80
local BEATS = 40
local MAX_MONITORS = 500 -- per status page
local MAX_LINK = 2000

-- /metrics labels that are not tags.
local RESERVED = {
    monitor_id = true, monitor_name = true, monitor_type = true, monitor_url = true,
    monitor_hostname = true, monitor_port = true, window = true,
}

-- Controls become spaces, invalid UTF-8 becomes "?", bidi and zero-width marks
-- are dropped, then the text is cut to `max` characters.
function K.safeText(s: string, max: number): string
    s = tostring(s or ""):gsub("[\0-\31\127]", " ")
    if utf8.len(s) == nil then
        s = s:gsub("[\128-\255]", "?")
    end
    s = s:gsub("\226\128[\139-\143\170-\174]", ""):gsub("\226\129[\166-\169]", "")
    if utf8.len(s) > max then
        s = s:sub(1, utf8.offset(s, max + 1) - 1)
    end
    return s
end

-- URL for display: no user:password@, no query or fragment.
local function displayUrl(url: string): string
    url = url:gsub("^(%a+://)[^/@]*@", "%1"):gsub("[?#].*$", "?\u{2026}")
    return K.safeText(url, 200)
end

-- True for an http(s) URL without spaces, safe as one xdg-open argument.
function K.openable(url: any): boolean
    return type(url) == "string" and url:match("^https?://[^%s]+$") ~= nil
end

-- One series line, name{k="v",...} value, scanned by character because label
-- values may hold escaped quotes.
local function parseSeries(l: string)
    local brace = l:find("{", 1, true)
    if brace == nil then return nil end
    local metric = l:sub(1, brace - 1)
    local labels = {}
    local i, n = brace + 1, #l
    while i <= n do
        local c = l:sub(i, i)
        if c == "}" then break end
        if c == "," or c == " " then
            i += 1
        else
            local eq = l:find("=", i, true)
            if eq == nil or l:sub(eq + 1, eq + 1) ~= '"' then return nil end
            local key = l:sub(i, eq - 1)
            local buf = {}
            i = eq + 2
            while i <= n and l:sub(i, i) ~= '"' do
                local ch = l:sub(i, i)
                if ch == "\\" then
                    i += 1
                    ch = l:sub(i, i)
                    if ch == "n" then ch = "\n" end
                end
                buf[#buf + 1] = ch
                i += 1
            end
            if i > n then return nil end
            labels[key] = table.concat(buf)
            i += 1
        end
    end
    local value = tonumber(l:sub(i + 1):match("^%s*(%S+)"))
    if value == nil or value ~= value then return nil end
    return metric, labels, value
end

-- Unused series are skipped by prefix and labels are parsed once per monitor.
-- Lines with a backslash use parseSeries.
local USED = {
    monitor_status = true, monitor_response_time = true,
    monitor_uptime_ratio = true, monitor_cert_days_remaining = true,
}

local function labelsOf(l)
    if l:find("\\", 1, true) == nil then
        local labels = {}
        for k, v in l:gmatch('([%w_]+)="([^"]*)"') do labels[k] = v end
        return labels
    end
    local _, labels = parseSeries(l)
    return labels
end

local function parseLine(byId, l)
    if l:sub(1, 8) ~= "monitor_" then return false end
    local metric = l:match("^([%w_]+){")
    if metric ~= nil and USED[metric] and (metric ~= "monitor_uptime_ratio" or l:find('window="1d"', 1, true)) then
        local id = tonumber(l:match('monitor_id="(%d+)"'))
        local value = tonumber(l:match("}%s+(%S+)%s*$"))
        if id ~= nil and value ~= nil and value == value then
            local m = byId[id]
            if m == nil then
                local labels = labelsOf(l)
                if labels ~= nil then
                    local tags = {}
                    for key in pairs(labels) do
                        if not RESERVED[key] then tags[#tags + 1] = K.safeText(key, MAX_NAME) end
                    end
                    table.sort(tags)
                    local url = labels.monitor_url
                    if url == nil or url == "" or url == "null" then
                        url = nil
                        local host = labels.monitor_hostname
                        if host ~= nil and host ~= "" and host ~= "null" then
                            url = host
                            local port = labels.monitor_port
                            if port ~= nil and port ~= "" and port ~= "null" then url = host .. ":" .. port end
                        end
                    end
                    m = {
                        id = id,
                        name = K.safeText(labels.monitor_name or "", MAX_NAME),
                        type = K.safeText(labels.monitor_type or "", 40),
                        url = url and displayUrl(url) or nil,
                        link = url and utf8.len(url) ~= nil and #url <= MAX_LINK and K.safeText(url, MAX_LINK) or nil,
                        tags = tags,
                    }
                    byId[id] = m
                end
            end
            if m ~= nil then
                if metric == "monitor_status" then
                    m.status = value
                elseif metric == "monitor_response_time" then
                    if value >= 0 then m.ping = value end
                elseif metric == "monitor_uptime_ratio" then
                    m.uptime1d = value
                else
                    m.certDays = value
                end
            end
        end
    end
    return true
end

-- Parses /metrics in slices: step(n, seconds) parses at most n monitor_ lines, and stops
-- early after `seconds` of os.clock when the sandbox has it. Returns nil until
-- the text is done, then the monitors by id.
function K.metricsParser(text: string)
    local byId = {}
    local nextLine = (text or ""):gmatch("[^\n]+")
    local P = {}
    function P.step(n: number, seconds: number?)
        local clock = seconds ~= nil and type(os) == "table" and os.clock or nil
        local started = clock and clock()
        local used = 0
        while used < n do
            local l = nextLine()
            if l == nil then
                -- a monitor without a status series is noise
                for id, m in pairs(byId) do
                    if m.status == nil then byId[id] = nil end
                end
                return byId
            end
            if parseLine(byId, l) then used += 1 end
            if clock and clock() - started >= seconds then break end
        end
        return nil
    end
    return P
end

-- Input is the decoded body of GET /api/monitors: { monitors = { ... } }.
function K.parseMonitors(decoded: any)
    local out = {}
    local list = type(decoded) == "table" and decoded.monitors or {}
    for _, x in ipairs(list) do
        local id = tonumber(x.id)
        if id ~= nil then
            local children, tags = {}, {}
            for _, c in ipairs(x.childrenIDs or {}) do
                if tonumber(c) ~= nil then children[#children + 1] = tonumber(c) end
            end
            for _, t in ipairs(x.tags or {}) do
                if type(t) == "table" and t.name ~= nil then tags[#tags + 1] = K.safeText(t.name, MAX_NAME) end
            end
            out[id] = {
                id = id,
                name = K.safeText(x.name or "", MAX_NAME),
                type = K.safeText(x.type or "", 40),
                parent = tonumber(x.parent),
                children = children,
                tags = tags,
                active = x.active == true,
            }
        end
    end
    return out
end

-- scheme, host (lowercase, no credentials) and path of an http(s) URL, or nil.
local function splitUrl(url)
    if type(url) ~= "string" or url:find("%s") then return nil end
    local scheme, rest = url:match("^(%a+)://(.*)$")
    if scheme == nil then return nil end
    scheme = scheme:lower()
    if scheme ~= "http" and scheme ~= "https" then return nil end
    local host, path = rest:match("^([^/]*)(.*)$")
    if host == "" or not host:match("^[%w%.%-%[%]:]+$") then return nil end
    host = host:lower()
    return scheme, host, (path:gsub("/+$", ""))
end

function K.baseUrl(url: string): string?
    local scheme, host, path = splitUrl(url)
    if scheme == nil or path:find("[?#]") then return nil end
    return scheme .. "://" .. host .. path
end

function K.statusPageUrl(url: string)
    local scheme, host, path = splitUrl(url)
    if scheme == nil then return nil end
    local slug = path:match("^/status/([%w_%-]+)$")
    if slug == nil then return nil end
    return scheme .. "://" .. host, slug:lower()
end

function K.parseStatusPage(page: any, heartbeats: any, origin: string, slug: string)
    local cfg = type(page) == "table" and page.config or {}
    local lists = type(heartbeats) == "table" and heartbeats.heartbeatList or {}
    local sp = {
        slug = slug,
        title = K.safeText(cfg.title or slug, MAX_NAME),
        description = K.safeText(cfg.description or "", 160):match("^%s*(.-)%s*$"),
        url = origin .. "/status/" .. slug,
        groups = {},
    }
    local total = 0
    for _, g in ipairs(type(page) == "table" and page.publicGroupList or {}) do
        local group = { name = K.safeText(g.name or "", MAX_NAME), monitors = {} }
        for _, mon in ipairs(g.monitorList or {}) do
            local id = tonumber(mon.id)
            if id ~= nil and total < MAX_MONITORS then
                total += 1
                local src = lists[tostring(id)] or lists[id] or {}
                local beats = {}
                for i = math.max(1, #src - BEATS + 1), #src do
                    local st = tonumber(type(src[i]) == "table" and src[i].status)
                    if st ~= nil then beats[#beats + 1] = st end
                end
                group.monitors[#group.monitors + 1] = {
                    id = id, name = K.safeText(mon.name or "", MAX_NAME), beats = beats,
                }
            end
        end
        sp.groups[#sp.groups + 1] = group
    end
    return sp
end

-- Certificate limits from the settings, whole days: red up to `red`, yellow up
-- to `yellow` (always above red).
local function whole(v, default, lo, hi)
    v = tonumber(v)
    if v == nil then return default end
    return math.min(hi, math.max(lo, math.floor(v)))
end

function K.certLimits(red, yellow)
    red = whole(red, 7, 1, 365)
    return { red = red, yellow = math.max(red + 1, whole(yellow, 30, 2, 730)) }
end

-- Expiry level for the days left: expired (<0), red, yellow, green.
function K.certLevel(days, limits)
    limits = limits or K.certLimits()
    if days < 0 then return "expired" end
    if days <= limits.red then return "red" end
    if days <= limits.yellow then return "yellow" end
    return "green"
end

-- Expired and red certificates ({ name, days, level }, shortest first) when the
-- last alert (`last`, seconds, nil = never) is at least a day old, else {}.
function K.dueCerts(metrics, limits, last, now)
    local out = {}
    if last ~= nil and now - last < 86400 then return out end
    for _, g in ipairs(K.buildCertificates(metrics, limits).groups) do
        if g.level == "expired" or g.level == "red" then
            for _, r in ipairs(g.rows) do out[#out + 1] = { name = r.name, days = r.certDays, level = r.level } end
        end
    end
    return out
end

-- Certificates tab: monitors with a certificate expiry, shortest first, grouped
-- by level (empty levels omitted).
function K.buildCertificates(metrics, limits)
    local all = {}
    for id, m in pairs(metrics) do
        if m.type ~= "group" and not m.muted and m.certDays ~= nil then
            local days = math.floor(m.certDays)
            all[#all + 1] = { id = id, name = m.name, url = m.url, link = m.link, certDays = days, level = K.certLevel(days, limits) }
        end
    end
    table.sort(all, function(a, b)
        if a.certDays ~= b.certDays then return a.certDays < b.certDays end
        if a.name:lower() ~= b.name:lower() then return a.name:lower() < b.name:lower() end
        return a.id < b.id
    end)
    local groups, byLevel = {}, {}
    for _, row in ipairs(all) do
        local g = byLevel[row.level]
        if g == nil then
            g = { key = row.level, level = row.level, rows = {} }
            byLevel[row.level] = g
            groups[#groups + 1] = g
        end
        g.rows[#g.rows + 1] = row
    end
    return { groups = groups, total = #all }
end

-- State-change alerts. A monitor must be down for NOTIFY_CYCLES cycles in a row
-- to alert, the same monitor alerts at most once per NOTIFY_COOLDOWN seconds,
-- and a recovery is announced only for a monitor that was announced down.
-- The first cycle is a baseline: monitors already down are silent.
K.NOTIFY_CYCLES = 2
K.NOTIFY_COOLDOWN = 600

function K.newTrack()
    return { started = false, mon = {} }
end

-- Returns { down = { names }, restored = { names } } for this cycle.
function K.trackChanges(track, metrics, now)
    local ev = { down = {}, restored = {} }
    local seen = {}
    for id, m in pairs(metrics) do
        if m.type ~= "group" and not m.muted then
            seen[id] = true
            local t = track.mon[id]
            if t == nil then
                t = { count = 0, notified = false }
                track.mon[id] = t
            end
            if m.status == 0 then
                if not track.started then
                    t.count = K.NOTIFY_CYCLES
                else
                    t.count += 1
                    if t.count == K.NOTIFY_CYCLES and (t.last == nil or now - t.last >= K.NOTIFY_COOLDOWN) then
                        t.notified, t.last = true, now
                        ev.down[#ev.down + 1] = m.name
                    end
                end
            elseif m.status == 1 or m.status == 3 then
                if t.notified then ev.restored[#ev.restored + 1] = m.name end
                t.notified, t.count = false, 0
            end
        end
    end
    for id in pairs(track.mon) do
        if not seen[id] then track.mon[id] = nil end
    end
    track.started = true
    table.sort(ev.down)
    table.sort(ev.restored)
    return ev
end

-- Keeps the last `cap` statuses of a monitor no status page covers, oldest first.
function K.pushSample(buffer, id: number, status: number, cap: number)
    local b = buffer[id]
    if b == nil then
        b = {}
        buffer[id] = b
    end
    b[#b + 1] = status
    while #b > cap do table.remove(b, 1) end
end

-- Overall state for the bar. Groups are not counted; maintenance counts as
-- neither up nor down; no series at all is "idle".
function K.summarize(metrics)
    local s = { up = 0, down = 0, pending = 0, color = "idle", downNames = {} }
    local seen = 0
    for _, m in pairs(metrics) do
        if m.type ~= "group" and not m.muted then
            seen += 1
            if m.status == 1 then
                s.up += 1
            elseif m.status == 0 then
                s.down += 1
                s.downNames[#s.downNames + 1] = m.name
            elseif m.status == 2 then
                s.pending += 1
            end
        end
    end
    table.sort(s.downNames)
    if s.down > 0 then
        s.color = "down"
    elseif s.pending > 0 then
        s.color = "pending"
    elseif seen > 0 then
        s.color = "up"
    end
    return s
end

local function byName(a, b)
    local x, y = a.name:lower(), b.name:lower()
    if x ~= y then return x < y end
    return a.id < b.id
end

-- A monitor known only from the structure (Kuma 3) is paused: no series.
local function makeRow(id, m, struct, beats, buffer, limits)
    local b = beats[id]
    if b == nil or #b == 0 then b = buffer[id] or {} end
    if m ~= nil then
        return {
            id = id, name = m.name, status = m.status, ping = m.ping, beats = b, paused = false, muted = m.muted, url = m.url, link = m.link,
            certDays = m.certDays, certLevel = m.certDays ~= nil and K.certLevel(math.floor(m.certDays), limits) or nil,
        }
    end
    return { id = id, name = struct.name, status = -1, beats = b, paused = true }
end

local function makeGroup(id, name, rows, metrics)
    table.sort(rows, byName)
    local g = { id = id, name = name, up = 0, down = 0, total = 0, rows = rows }
    local sum, n = 0, 0
    for _, r in ipairs(rows) do
        if not r.paused and not r.muted then
            g.total += 1
            if r.status == 1 or r.status == 3 then g.up += 1 end
            if r.status == 0 then g.down += 1 end
            local u = metrics[r.id] and metrics[r.id].uptime1d
            if u ~= nil then
                sum += u
                n += 1
            end
        end
    end
    if n > 0 then g.uptime1d = sum / n end
    return g
end

-- One unnamed group with every monitor of the dashboard, once, by name.
function K.flattenDashboard(dash, metrics)
    local rows, seen = {}, {}
    for _, g in ipairs(dash.groups) do
        for _, r in ipairs(g.rows) do
            if not seen[r.id] then
                seen[r.id] = true
                rows[#rows + 1] = r
            end
        end
    end
    return { mode = dash.mode, flat = true, groups = { makeGroup(nil, "", rows, metrics) } }
end

-- Groups for the Dashboard. With a Kuma 3 structure: the group monitors (nested
-- ones named "Parent / Child"). Without: one group per tag, an unnamed one last.
-- opts.firstTagOnly: a monitor only in its first tag. opts.groupTags: only these
-- tags make groups, in this order; a monitor goes to the first one it has.
-- opts.certLimits: see K.certLimits.
function K.buildDashboard(metrics, structure, beats, buffer, opts)
    local groups = {}
    local limits = opts and opts.certLimits or nil
    if structure ~= nil then
        local function fullName(id)
            local st, parts, guard = structure[id], {}, 0
            while st ~= nil and guard < 20 do
                table.insert(parts, 1, st.name)
                st = st.parent and structure[st.parent] or nil
                guard += 1
            end
            return table.concat(parts, " / ")
        end
        local placed, loose, named = {}, {}, {}
        for id, st in pairs(structure) do
            if st.type == "group" then
                local rows = {}
                for _, c in ipairs(st.children) do
                    local cs = structure[c]
                    if cs ~= nil and cs.type ~= "group" then
                        rows[#rows + 1] = makeRow(c, metrics[c], cs, beats, buffer, limits)
                        placed[c] = true
                    end
                end
                named[#named + 1] = { name = fullName(id), id = id, rows = rows }
            end
        end
        table.sort(named, function(a, b) return a.name:lower() < b.name:lower() end)
        for _, g in ipairs(named) do groups[#groups + 1] = makeGroup(g.id, g.name, g.rows, metrics) end
        for id, st in pairs(structure) do
            if st.type ~= "group" and not placed[id] then
                loose[#loose + 1] = makeRow(id, metrics[id], st, beats, buffer, limits)
            end
        end
        for id, m in pairs(metrics) do
            if m.type ~= "group" and structure[id] == nil then
                loose[#loose + 1] = makeRow(id, m, nil, beats, buffer, limits)
            end
        end
        if #loose > 0 then groups[#groups + 1] = makeGroup(nil, "", loose, metrics) end
        return { mode = "hierarchy", groups = groups }
    end
    local byTag, untagged, names = {}, {}, {}
    local firstOnly = opts ~= nil and opts.firstTagOnly == true
    local groupTags = opts and opts.groupTags or nil
    local rank = {}
    if groupTags ~= nil then
        for i, t in ipairs(groupTags) do
            if rank[t:lower()] == nil then rank[t:lower()] = i end
        end
    end
    local listed = next(rank) ~= nil
    local function put(name, r)
        if byTag[name] == nil then
            byTag[name] = {}
            names[#names + 1] = name
        end
        table.insert(byTag[name], r)
    end
    for id, m in pairs(metrics) do
        if m.type ~= "group" then
            local r = makeRow(id, m, nil, beats, buffer, limits)
            if listed then
                local picked = {}
                for _, t in ipairs(m.tags) do
                    local i = rank[t:lower()]
                    if i ~= nil then picked[#picked + 1] = i end
                end
                table.sort(picked)
                if #picked == 0 then
                    untagged[#untagged + 1] = r
                else
                    for n, i in ipairs(picked) do
                        if n == 1 or not firstOnly then put(groupTags[i], r) end
                    end
                end
            else
                if #m.tags == 0 then
                    untagged[#untagged + 1] = r
                end
                for i, t in ipairs(m.tags) do
                    if i == 1 or not firstOnly then put(t, r) end
                end
            end
        end
    end
    if listed then
        local ordered, seen = {}, {}
        for _, t in ipairs(groupTags) do
            if byTag[t] ~= nil and not seen[t] then
                seen[t] = true
                ordered[#ordered + 1] = t
            end
        end
        names = ordered
    else
        table.sort(names, function(a, b) return a:lower() < b:lower() end)
    end
    for _, t in ipairs(names) do groups[#groups + 1] = makeGroup(nil, t, byTag[t], metrics) end
    if #untagged > 0 then groups[#groups + 1] = makeGroup(nil, "", untagged, metrics) end
    return { mode = "tags", groups = groups }
end

return K
