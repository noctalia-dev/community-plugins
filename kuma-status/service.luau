--!nonstrict
-- kuma-status — singleton engine: all network, parsing and buffering.
-- The widget and the panel only render what this publishes.
--
--   publishes "kuma_status_data" = { nonce, ts, summary, dashboard?, certs?,
--       pages (each with .source), pageUrls, errors = { metrics?,
--       monitors?, pages = {[url]=msg} }, mode, tagMode, credWarn, baseUrl,
--       plainHttp, insecureTls, alertTs, certLimits, stale, mutedCount };
--       summary.color is "offline" without /metrics. stale: Kuma did not answer
--       and the values are those of the last answered cycle.
--   reads "kuma_status_request" = { nonce, action, value? } with action
--       "refresh", "tag_mode" ("first"|"all"|"flat"), "mute" (monitor id, toggles) or
--       "prune_muted"; a nonce already seen is ignored.
--
-- Sources per cycle (refresh_seconds):
--   /metrics        Basic, user "kuma", password = API key
--   /api/monitors   Bearer API key, only with kuma3_support
--   status pages    <origin>/api/status-page/<slug> and .../heartbeat/<slug>
-- Secrets: api_key_file and proxy_password_file hold a file PATH (absolute,
-- regular, 1 B to 64 KiB, no NUL), re-read every cycle, never kept in state or
-- logs. A file readable by group/other raises credWarn.
-- The API key goes to kuma_url only. The proxy user/password pair (Basic on
-- status pages) goes to the kuma_url host and proxy_hosts only.
-- Toasts: a monitor down for 2 cycles, then its recovery (see K.trackChanges).
-- notify_certs (off by default): one toast a day listing expired and red certificates.
-- Bodies over 1 MiB (4 MiB for status pages) are refused. insecure_tls skips
-- certificate checks on every request.
-- A 401/403 blocks a source until the secret or the settings change; a 404 on
-- /api/monitors turns Kuma 3 support off for the session; other failures retry
-- next cycle (after 10 s when Kuma did not answer). A failing source never
-- clears the others.
-- Host limits: a callback gets ~25 ms of CPU, so /metrics is parsed a slice per
-- tick; at most 8 http requests per plugin, so at most MAX_PARALLEL are in flight.
-- Monitors no status page covers get a 40-sample history buffer in memory.

local K = require("./kuma.luau")
local store = require("./pages_store.luau")

local MAX_CRED = 65536 -- noctalia rejects larger credential files
local STATE_KEY = "kuma_status_data"
local REQUEST_KEY = "kuma_status_request"
local BUFFER_CAP = 40
local RETRY_SECONDS = 10
local PARSE_LINES = 80      -- /metrics lines parsed per tick,
local PARSE_SECONDS = 0.005 -- or until this much time is used
local MAX_PARALLEL = 6      -- http requests in flight (the host refuses more than 8)

local gen = 0        -- bumps per cycle and on config change; stale callbacks drop themselves
local nonce = 0
local seenRequest = nil
local elapsed = 0
local inFlight = false -- a cycle is waiting for answers; the timer must not restart it
local lastGood = nil    -- { metrics, structure } of the last answered cycle, shown (stale) while Kuma is silent
local completion = nil  -- final merge + publish of a finished cycle, run by the next tick
local v3Off = false  -- /api/monitors answered 404: stop asking this session
local blocked = { metrics = false, monitors = false, pages = {} }
local reasons = { pages = {} } -- text shown for blocked sources
local buffer = {}
local track = K.newTrack()
local alertTs = nil -- when the last "down" toast went out, for the bar blink
local credWarn = false -- a credentials file is readable by group/other
local publish -- defined below; checkPermissions republishes through it
local function dataFile(name)
    local dir = noctalia.pluginDataDir()
    return dir and (dir .. "/" .. name) or nil
end

-- tag_mode.txt: "first" (monitor in its first tag), "all" or "flat" (no groups)
local tagMode = "first"
do
    local f = dataFile("tag_mode.txt")
    local saved = f and noctalia.readFile(f) or nil
    local word = saved ~= nil and saved:match("^%s*(%a+)") or nil
    if word == "all" or word == "flat" then tagMode = word end
end

-- muted.txt: ids of monitors the user silenced on this widget, one per line.
local muted = {}
do
    local f = dataFile("muted.txt")
    for id in (f and noctalia.readFile(f) or ""):gmatch("%d+") do muted[tonumber(id)] = true end
end
local function saveMuted()
    local f = dataFile("muted.txt")
    if f == nil then return end
    local ids = {}
    for id in pairs(muted) do ids[#ids + 1] = id end
    table.sort(ids)
    noctalia.writeFile(f, #ids > 0 and (table.concat(ids, "\n") .. "\n") or "")
end
local function applyMuted(metrics)
    for id, m in pairs(metrics or {}) do m.muted = muted[id] or nil end
end
local function mutedTotal()
    local n = 0
    for _ in pairs(muted) do n += 1 end
    return n
end
local last = nil -- inputs of the last publish, to rebuild the view without network

local function tr(key, args)
    return noctalia.tr(key, args)
end

-- Ordered tag names from the group_tags setting (blank entries dropped).
local function groupTagList()
    local setting = noctalia.getConfig("group_tags")
    local out = {}
    for _, t in ipairs(type(setting) == "table" and setting or {}) do
        if type(t) == "string" then
            t = t:match("^%s*(.-)%s*$")
            if t ~= "" then out[#out + 1] = t end
        end
    end
    return out
end

-- Lowercase hosts (host or host:port) from the proxy_hosts setting.
local function proxyHostSet()
    local setting = noctalia.getConfig("proxy_hosts")
    local out = {}
    for _, h in ipairs(type(setting) == "table" and setting or {}) do
        if type(h) == "string" then
            h = h:match("^%s*(.-)%s*$"):lower()
            if h ~= "" then out[h] = true end
        end
    end
    return out
end

local function interval()
    return math.min(3600, math.max(20, tonumber(noctalia.getConfig("refresh_seconds")) or 60))
end

local function readConfig()
    return {
        base = K.baseUrl(noctalia.getConfig("kuma_url") or ""),
        keyFile = noctalia.getConfig("api_key_file") or "",
        proxyUser = noctalia.getConfig("proxy_user") or "",
        proxyFile = noctalia.getConfig("proxy_password_file") or "",
        pages = store.load(),
        groupTags = groupTagList(),
        proxyHosts = proxyHostSet(),
        insecure = noctalia.getConfig("insecure_tls") == true,
        v3 = noctalia.getConfig("kuma3_support") == true,
        certLimits = K.certLimits(noctalia.getConfig("cert_red_days"), noctalia.getConfig("cert_yellow_days")),
        notifyCerts = noctalia.getConfig("notify_certs") == true,
        notify = noctalia.getConfig("notify_changes") or "toast_blink",
        interval = interval(),
    }
end

-- Reads a credential file: (value) or (nil, errorKey). "empty" means no path set.
local function readCredential(path)
    if path == "" then return nil, "empty" end
    if path:sub(1, 1) ~= "/" then return nil, "error.cred_path" end
    local info = noctalia.fileInfo(path)
    if info == nil or info.isDir then return nil, "error.cred_unreadable" end
    if info.size < 1 or info.size > MAX_CRED then return nil, "error.cred_invalid" end
    local text = noctalia.readFile(path)
    if text == nil then return nil, "error.cred_unreadable" end
    if text:find("\0", 1, true) then return nil, "error.cred_invalid" end
    text = (text:gsub("\r?\n$", ""))
    if text == "" then return nil, "error.cred_invalid" end
    return text, nil
end

-- Warn when a configured credentials file is readable by group or other.
local function checkPermissions(cfg)
    local warn, pending, started = false, 0, 0
    local function check(path)
        if path:sub(1, 1) ~= "/" then return end
        pending += 1
        started += 1
        noctalia.runAsync({ "stat", "-c", "%a", path }, function(r)
            local mode = r and r.exitCode == 0 and tostring(r.stdout or ""):match("%d+") or nil
            if mode ~= nil and #mode >= 2 and mode:sub(-2) ~= "00" then warn = true end
            pending -= 1
            if pending == 0 and warn ~= credWarn then
                credWarn = warn
                if last ~= nil then publish(table.unpack(last)) end
            end
        end)
    end
    check(cfg.keyFile)
    check(cfg.proxyFile)
    if started == 0 then credWarn = false end
end

local MAX_BODY = 1048576
local MAX_PAGE_BODY = 4194304

-- (body) or (nil, message, hard); hard marks a 401/403 that blocks the source.
local function classify(r, max)
    if not r.ok then return nil, tr(r.status == -1 and "error.busy" or "error.offline"), false end
    if #(r.body or "") > (max or MAX_BODY) then return nil, tr("error.too_large"), false end
    if r.status == 401 or r.status == 403 then return nil, tr("error.unauthorized"), true end
    if r.status == 404 then return nil, tr("error.not_found"), false end
    if r.status ~= 200 then return nil, tr("error.http", { status = r.status }), false end
    return r.body, nil, false
end

local MAX_NAMES = 5

-- cert_alert.txt: when the last certificate toast went out.
local lastCertAlert = tonumber((function()
    local f = dataFile("cert_alert.txt")
    return f and noctalia.readFile(f) or nil
end)())

-- Monitor names are server text: no markup characters in a notification.
local function plain(s)
    return (s:gsub("[<>&]", " "))
end

local function toast(titleKey, list)
    local shown = plain(table.concat(list, ", ", 1, math.min(#list, MAX_NAMES)))
    if #list > MAX_NAMES then shown = shown .. " " .. tr("tooltip_more", { count = #list - MAX_NAMES }) end
    noctalia.notify(tr(titleKey, { count = #list }), shown)
end

local function announceCerts(cfg, metrics)
    local now = os.time()
    local due = K.dueCerts(metrics, cfg.certLimits, lastCertAlert, now)
    if #due == 0 then return end
    local items = {}
    for i = 1, math.min(#due, MAX_NAMES) do
        local c = due[i]
        local when = c.level == "expired" and tr("panel.cert_expired_short") or tr("panel.cert_days_short", { days = c.days })
        items[i] = plain(c.name) .. " (" .. when .. ")"
    end
    local body = table.concat(items, ", ")
    if #due > MAX_NAMES then body = body .. " " .. tr("tooltip_more", { count = #due - MAX_NAMES }) end
    noctalia.notify(tr("notify.certs", { count = #due }), body)
    lastCertAlert = now
    local f = dataFile("cert_alert.txt")
    if f then noctalia.writeFile(f, tostring(now)) end
end

local function announce(cfg, metrics)
    if cfg.notifyCerts then announceCerts(cfg, metrics) end
    local ev = K.trackChanges(track, metrics, os.time())
    if cfg.notify == "off" then return end
    if #ev.down > 0 then
        toast("notify.down", ev.down)
        if cfg.notify == "toast_blink" then alertTs = os.time() end
    end
    if #ev.restored > 0 then toast("notify.restored", ev.restored) end
end

function publish(cfg, metrics, structure, beatsById, pages, errors)
    nonce += 1
    applyMuted(metrics)
    local summary = K.summarize(metrics or {})
    if metrics == nil then summary.color = "offline" end
    last = { cfg, metrics, structure, beatsById, pages, errors }
    local dashboard = nil
    if metrics ~= nil then
        dashboard = K.buildDashboard(metrics, structure, beatsById, buffer, { firstTagOnly = tagMode ~= "all", groupTags = cfg.groupTags, certLimits = cfg.certLimits })
        if tagMode == "flat" then dashboard = K.flattenDashboard(dashboard, metrics) end
    end
    -- from the configured URLs, so a page that failed still flags clear text
    local plain = cfg.base ~= nil and cfg.base:sub(1, 7) == "http://"
    for _, url in ipairs(cfg.pages) do
        if type(url) == "string" and url:lower():sub(1, 7) == "http://" then plain = true end
    end
    noctalia.state.set(STATE_KEY, {
        nonce = nonce,
        ts = os.time(),
        summary = summary,
        dashboard = dashboard,
        pages = pages,
        pageUrls = cfg.pages,
        errors = errors,
        mode = structure ~= nil and "hierarchy" or "tags",
        tagMode = tagMode,
        credWarn = credWarn,
        alertTs = alertTs,
        certs = metrics ~= nil and K.buildCertificates(metrics, cfg.certLimits) or nil,
        certLimits = cfg.certLimits,
        stale = metrics ~= nil and errors.metrics ~= nil,
        mutedCount = mutedTotal(),
        baseUrl = cfg.base or "",
        plainHttp = plain,
        insecureTls = cfg.insecure,
    })
end

local function refresh()
    gen += 1
    local mine = gen
    elapsed = 0
    local cfg = readConfig()
    local errors = { pages = {} }
    if cfg.base == nil then
        errors.metrics = tr("error.no_url")
        inFlight = false
        publish(cfg, nil, nil, {}, {}, errors)
        return
    end
    inFlight = true

    -- A blocked source stays blocked only while the refused secret is still in the file.
    local key, keyErr = readCredential(cfg.keyFile)
    local proxyPw, proxyErr = "", nil
    if cfg.proxyUser ~= "" and cfg.proxyFile ~= "" then
        proxyPw, proxyErr = readCredential(cfg.proxyFile)
    end
    local kumaHost = cfg.base:match("^%a+://([^/]+)")
    local function proxyAllowed(origin)
        local host = origin:match("^%a+://(.+)$")
        return host == kumaHost or cfg.proxyHosts[host] == true or cfg.proxyHosts[host:gsub(":%d+$", "")] == true
    end

    local metrics, structure = nil, nil
    local parser = nil     -- /metrics text still to parse, a few lines per tick
    local pageResults = {} -- [index] = StatusPage
    local pending = 1      -- guard: held until every request is issued

    local function complete()
        if mine ~= gen then return end
        inFlight = false
        local pages, beatsById = {}, {}
        for i = 1, #cfg.pages do
            local sp = pageResults[i]
            if sp ~= nil then
                pages[#pages + 1] = sp
                for _, g in ipairs(sp.groups) do
                    for _, m in ipairs(g.monitors) do
                        if beatsById[m.id] == nil and #m.beats > 0 then beatsById[m.id] = m.beats end
                    end
                end
            end
        end
        local failed = metrics == nil
        if failed and lastGood ~= nil then
            metrics, structure = lastGood.metrics, lastGood.structure
        elseif not failed then
            lastGood = { metrics = metrics, structure = structure }
        end
        applyMuted(metrics)
        if not failed then
            announce(cfg, metrics)
            for id, m in pairs(metrics) do
                if m.type ~= "group" and beatsById[id] == nil then
                    K.pushSample(buffer, id, m.status, BUFFER_CAP)
                end
            end
        end
        publish(cfg, metrics, structure, beatsById, pages, errors)
        if failed and (errors.metrics == tr("error.offline") or errors.metrics == tr("error.busy")) then
            elapsed = math.max(0, cfg.interval - RETRY_SECONDS) -- no answer: ask again soon
        end
    end

    local function finish()
        pending -= 1
        if pending > 0 or mine ~= gen then return end
        completion = function()
            if mine ~= gen then return true end
            if parser ~= nil then
                local ok, result = pcall(parser.step, PARSE_LINES, PARSE_SECONDS)
                if not ok then
                    parser = nil
                    errors.metrics = tr("error.bad_metrics") .. " [" .. tostring(result):gsub("^%[string \"[^\"]*\"%]:%d+: ", ""):sub(1, 100) .. "]"
                elseif result == nil then
                    return false
                else
                    parser = nil
                    metrics = result
                end
            end
            complete()
            return true
        end
    end

    local queue, active = {}, 0
    local pump
    pump = function()
        while active < MAX_PARALLEL and #queue > 0 and mine == gen do
            local job = table.remove(queue, 1)
            active += 1
            local sent = noctalia.http(job.req, function(r)
                active -= 1
                -- a throwing handler must not leave the cycle without its finish()
                if mine == gen then pcall(job.cb, r) end
                finish()
                pump()
            end)
            if not sent then
                active -= 1
                pcall(job.cb, { ok = false, status = -1, body = "" })
                finish()
            end
        end
    end

    local function request(req, cb)
        pending += 1
        if cfg.insecure then req.allow_insecure_tls = true end
        queue[#queue + 1] = { req = req, cb = cb }
    end

    -- /metrics
    if key == nil then
        errors.metrics = keyErr == "empty" and tr("error.no_key") or tr(keyErr)
    elseif blocked.metrics == key then
        errors.metrics = reasons.metrics
    else
        request({ url = cfg.base .. "/metrics", basic_username = "kuma", basic_password = key }, function(r)
            local body, msg, hard = classify(r)
            if body == nil then
                errors.metrics = msg
                if hard then
                    blocked.metrics = key
                    reasons.metrics = msg
                end
            elseif body:find("monitor_status", 1, true) == nil then
                -- a login page or wrong path also answers 200
                errors.metrics = tr("error.bad_metrics") .. " [HTTP " .. r.status .. ", " .. #body .. " B]"
            else
                parser = K.metricsParser(body)
            end
        end)
    end

    -- /api/monitors (Kuma 3)
    if cfg.v3 then
        if v3Off then
            errors.monitors = reasons.monitors
        elseif key ~= nil and blocked.monitors == key then
            errors.monitors = reasons.monitors
        elseif key ~= nil then
            request({ url = cfg.base .. "/api/monitors", headers = { "Authorization: Bearer " .. key } }, function(r)
                if r.ok and r.status == 404 then
                    v3Off = true
                    reasons.monitors = tr("error.v3_api_off")
                    errors.monitors = reasons.monitors
                    return
                end
                local body, msg, hard = classify(r)
                if body == nil then
                    errors.monitors = msg
                    if hard then
                        blocked.monitors = key
                        reasons.monitors = msg
                    end
                    return
                end
                local decoded = noctalia.json.decode(body)
                local parsed, res = pcall(K.parseMonitors, decoded)
                if type(decoded) == "table" and parsed then
                    structure = res
                else
                    errors.monitors = tr("error.bad_json")
                end
            end)
        end
    end

    -- status pages
    for i, url in ipairs(cfg.pages) do
        local origin, slug = K.statusPageUrl(url)
        if origin == nil then
            errors.pages[url] = tr("error.bad_url")
        elseif cfg.proxyUser ~= "" and proxyAllowed(origin) and proxyErr ~= nil then
            errors.pages[url] = tr(proxyErr)
        elseif blocked.pages[url] ~= nil and blocked.pages[url] == proxyPw then
            errors.pages[url] = reasons.pages[url]
        else
            local sendProxy = cfg.proxyUser ~= "" and proxyAllowed(origin)
            local got = { left = 2 }
            local function done()
                got.left -= 1
                if got.left > 0 then return end
                if got.err ~= nil then
                    errors.pages[url] = got.err
                    if got.hard then
                        blocked.pages[url] = proxyPw
                        reasons.pages[url] = got.err
                    end
                    return
                end
                local page = noctalia.json.decode(got.page)
                local hb = noctalia.json.decode(got.hb)
                local parsed, res = pcall(K.parseStatusPage, page, hb, origin, slug)
                if type(page) == "table" and type(hb) == "table" and parsed then
                    pageResults[i] = res
                    pageResults[i].source = url
                else
                    errors.pages[url] = tr("error.bad_json")
                end
            end
            local function pageRequest(path, field)
                local req = { url = origin .. path .. slug }
                if sendProxy then
                    req.basic_username = cfg.proxyUser
                    req.basic_password = proxyPw
                end
                request(req, function(r)
                    local body, msg, hard = classify(r, MAX_PAGE_BODY)
                    if body == nil then
                        if hard and not sendProxy and cfg.proxyUser ~= "" then msg = tr("error.unauthorized_host") end
                        got.err, got.hard = got.err or msg, got.hard or hard
                    else
                        got[field] = body
                    end
                    done()
                end)
            end
            pageRequest("/api/status-page/", "page")
            pageRequest("/api/status-page/heartbeat/", "hb")
        end
    end

    pump()
    finish()
end

local request0 = noctalia.state.get(REQUEST_KEY)
if type(request0) == "table" then seenRequest = request0.nonce end
noctalia.state.watch(REQUEST_KEY, function(req)
    if type(req) ~= "table" or req.nonce == seenRequest then return end
    seenRequest = req.nonce
    if req.action == "refresh" then
        refresh()
    elseif req.action == "mute" and type(req.value) == "number" and req.value % 1 == 0 then
        muted[req.value] = not muted[req.value] or nil
        saveMuted()
        if last ~= nil then publish(table.unpack(last)) end
    elseif req.action == "prune_muted" and last ~= nil then
        local metrics, structure = last[2], last[3]
        local removed = 0
        for id in pairs(muted) do
            if (metrics == nil or metrics[id] == nil) and (structure == nil or structure[id] == nil) then
                muted[id] = nil
                removed += 1
            end
        end
        saveMuted()
        noctalia.notify(tr("notify.pruned", { count = removed }), "")
        publish(table.unpack(last))
    elseif req.action == "tag_mode" and (req.value == "first" or req.value == "all" or req.value == "flat") then
        tagMode = req.value
        local f = dataFile("tag_mode.txt")
        if f then noctalia.writeFile(f, tagMode) end
        if last ~= nil then publish(table.unpack(last)) end
    end
end)

function update()
    elapsed += 1
    if completion ~= nil then
        if completion() then completion = nil end
        return
    end
    local every = interval()
    if not inFlight and elapsed >= every or inFlight and elapsed >= every * 3 + 30 then refresh() end
end

-- Settings changed: drop every block and ask again.
function onConfigChanged()
    blocked = { metrics = false, monitors = false, pages = {} }
    reasons = { pages = {} }
    v3Off = false
    lastGood = nil
    checkPermissions(readConfig())
    refresh()
end

function onExit()
    gen += 1
end

noctalia.setUpdateInterval(1000)
checkPermissions(readConfig())
refresh()
