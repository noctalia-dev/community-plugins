--!nonstrict
-- kuma-status — panel with three tabs: Dashboard, Status pages and Certificates.
--
-- Renders "kuma_status_data" (from service.luau). Writes only requests to the
-- service ("kuma_status_request": refresh, tag_mode, mute, prune_muted; nonce
-- seeded from the clock) and the pages added here (pages_store.luau). Its own
-- choices (tab, collapsed groups and pages, hidden certificate lines) are small
-- files in the plugin data folder.
-- All tabs stay mounted; the inactive ones are hidden with `visible = false`.
-- Collapsed groups drop their rows.
-- A monitor name opens its Kuma page; right click opens a menu for the checked
-- URL. onActivate must name a global, so the target lives in menuUrl.
-- Only URLs passing K.openable reach xdg-open.

local R = require("./rows.luau")
local K = require("./kuma.luau")
local store = require("./pages_store.luau")

local DATA_KEY = "kuma_status_data"
local REQUEST_KEY = "kuma_status_request"

local data = nil
local tab = "dashboard"
local statusFilter = "all" -- "all" | "notok" | "down", dashboard rows only
local removedPages = {}   -- url -> true: hidden until the service republishes the list
local collapsed = {}      -- group key -> bool; nil means "the groups_on_open default"
local defaultCollapsed = false -- groups_on_open = "collapsed"
local rememberGroups = false   -- groups_on_open = "last"
local isOpen = false
local requestNonce = math.floor(noctalia.nowMs())
local addText, addRev, addError = "", 0, false
local menuUrl = nil
local hideCerts = false -- Dashboard: no certificate lines, compact rows
local certAsc = true -- Certificates tab: shortest expiry first

local function tr(key, args)
    return noctalia.tr(key, args)
end

local function sendRequest(action, value)
    requestNonce += 1
    noctalia.state.set(REQUEST_KEY, { nonce = requestNonce, action = action, value = value })
end

local function requestRefresh()
    sendRequest("refresh")
end

local function dataFile(name)
    local dir = noctalia.pluginDataDir()
    return dir and (dir .. "/" .. name) or nil
end

-- last_tab.txt: the tab to reopen with start_tab = "last".

local function startTab()
    local setting = noctalia.getConfig("start_tab")
    if setting == "pages" or setting == "certs" then return setting end
    if setting == "last" then
        local f = dataFile("last_tab.txt")
        local saved = f and noctalia.readFile(f) or nil
        if saved ~= nil and saved:match("^%s*pages") then return "pages" end
        if saved ~= nil and saved:match("^%s*certs") then return "certs" end
    end
    return "dashboard"
end

local function setTab(name)
    tab = name
    local f = dataFile("last_tab.txt")
    if f then noctalia.writeFile(f, name) end
end

local function openUrl(url)
    if not K.openable(url) then return end
    if not noctalia.commandExists("xdg-open") then
        noctalia.notifyError(tr("title"), tr("panel.no_xdg_open"))
        return
    end
    noctalia.runAsync({ "xdg-open", url })
end

local function openMonitor(id)
    local base = data and data.baseUrl or ""
    if base == "" or tonumber(id) == nil then return end
    openUrl(base .. "/dashboard/" .. math.floor(tonumber(id)))
end

-- Items about the checked URL are disabled when the check has none.
local function openRowMenu(row)
    menuUrl = row.link
    local base = data and data.baseUrl or ""
    panel.openContextMenu({
        onActivate = "onRowMenu",
        context = tostring(row.id),
        items = {
            { id = "kuma", label = tr("panel.menu_kuma"), enabled = base ~= "" },
            { id = "open", label = tr("panel.menu_open"), enabled = K.openable(menuUrl) },
            { id = "copy", label = tr("panel.menu_copy"), enabled = menuUrl ~= nil },
        },
    })
end

function onRowMenu(actionId, context)
    if actionId == "kuma" then
        openMonitor(tonumber(context))
    elseif actionId == "open" then
        openUrl(menuUrl)
    elseif actionId == "copy" and menuUrl ~= nil then
        noctalia.copyToClipboard(menuUrl, "text/plain")
    end
end

local render

local function setHideCerts(value)
    hideCerts = value
    local f = dataFile("hide_certs.txt")
    if f then noctalia.writeFile(f, value and "1" or "0") end
    render()
end

local function isCollapsed(key)
    local v = collapsed[key]
    if v == nil then return defaultCollapsed end
    return v
end

-- collapsed_groups.txt: collapsed group keys, one per line.
local function loadCollapsed()
    local f = dataFile("collapsed_groups.txt")
    local text = f and noctalia.readFile(f) or nil
    for line in (text or ""):gmatch("[^\n]+") do collapsed[line] = true end
end

local function saveCollapsed()
    local f = dataFile("collapsed_groups.txt")
    if not rememberGroups or f == nil then return end
    local keys = {}
    for key, v in pairs(collapsed) do
        if v then keys[#keys + 1] = key end
    end
    table.sort(keys)
    noctalia.writeFile(f, #keys > 0 and (table.concat(keys, "\n") .. "\n") or "")
end

local function toggleGroup(key)
    collapsed[key] = not isCollapsed(key)
    saveCollapsed()
    render()
end

-- which = "certs", "pages" or "dashboard"; keys are prefixed "certs:" and "page:".
local function setAllCollapsed(which, value)
    if which == "certs" then
        for _, g in ipairs(data and data.certs and data.certs.groups or {}) do
            collapsed["certs:" .. g.key] = value
        end
    elseif which == "pages" then
        for _, url in ipairs(store.load()) do collapsed["page:" .. url] = value end
    else
        for _, g in ipairs(data and data.dashboard and data.dashboard.groups or {}) do
            collapsed[R.groupKey(g)] = value
        end
    end
    saveCollapsed()
    render()
end

local FILTERS = {
    { id = "all", glyph = "list", color = "primary", tip = "panel.tip_filter_all", match = function() return true end },
    { id = "notok", glyph = "alert-triangle", color = R.COLORS[2], tip = "panel.tip_filter_notok", match = function(s) return s == 0 or s == 2 end },
    { id = "down", glyph = "circle-x", color = R.COLORS[0], tip = "panel.tip_filter_down", match = function(s) return s == 0 end },
}

local function filterMatch()
    for _, f in ipairs(FILTERS) do
        if f.id == statusFilter then return f.match end
    end
    return FILTERS[1].match
end

local function filterChips()
    local chips = {}
    for i, f in ipairs(FILTERS) do
        local on = statusFilter == f.id
        chips[i] = ui.row({
            key = "flt-" .. f.id, align = "center", paddingH = 8, paddingV = 4, radius = 6, tooltip = tr(f.tip),
            fill = on and "surface_container" or "surface",
            onClick = function() statusFilter = f.id; render() end,
        }, { ui.glyph({ name = f.glyph, size = 16, color = on and f.color or "on_surface_variant" }) })
    end
    return chips
end

local function muteMonitor(id)
    sendRequest("mute", id)
end

local function dashboardView()
    local children = {}
    local dash = data and data.dashboard
    if dash == nil then
        children[1] = ui.label({ key = "empty", text = tr("panel.empty"), color = "on_surface_variant" })
    elseif #dash.groups == 0 then
        children[1] = ui.label({ key = "dash-empty", text = tr("panel.empty_groups"), color = "on_surface_variant" })
    else
        local match = filterMatch()
        for _, g in ipairs(dash.groups) do
            local key = R.groupKey(g)
            local rows = {}
            for _, row in ipairs(g.rows) do
                if match(row.muted and -1 or row.status) then rows[#rows + 1] = row end
            end
            if #rows > 0 then
                if not dash.flat then children[#children + 1] = R.groupHeader(g, isCollapsed(key), toggleGroup) end
                if dash.flat or not isCollapsed(key) then
                    for _, row in ipairs(rows) do
                        children[#children + 1] = R.monitorRow(row, openMonitor, openRowMenu, muteMonitor, hideCerts)
                    end
                end
            end
        end
    end
    return children
end

-- The public heartbeat list has no ping.
local function pageRow(m, open)
    local status = m.beats[#m.beats]
    return R.monitorRow({ id = m.id, name = m.name, status = status or -1, beats = m.beats, paused = false, noPing = true }, open, nil)
end

local function addPage()
    local text = (addText or ""):match("^%s*(.-)%s*$")
    local origin, slug = K.statusPageUrl(text)
    if origin == nil then
        addError = true
        render()
        return
    end
    local url = origin .. "/status/" .. slug
    local list = store.load()
    local present = false
    for _, u in ipairs(list) do
        if u == url then present = true end
    end
    removedPages[url] = nil
    if not present then
        list[#list + 1] = url
        store.save(list)
    end
    addText, addError = "", false
    addRev += 1
    requestRefresh()
    render()
end

local function removePage(url)
    removedPages[url] = true
    local kept = {}
    for _, u in ipairs(store.load()) do
        if u ~= url then kept[#kept + 1] = u end
    end
    store.save(kept)
    requestRefresh()
    render()
end

local function addView()
    local out = {
        ui.row({ key = "add-row", gap = 6, align = "center" }, {
            ui.column({ key = "add-wrap-" .. addRev, flexGrow = 1 }, {
                ui.input({
                    key = "add-input", placeholder = tr("panel.add_placeholder"), submitOnEnter = true,
                    onChange = function(v) addText = v end,
                    onSubmit = function(v) addText = v; addPage() end,
                }),
            }),
            ui.button({ key = "btn-add-page", glyph = "plus", variant = "ghost", tooltip = tr("panel.tip_add"), onClick = addPage }),
            ui.button({ key = "btn-pages-expand-all", glyph = "chevrons-down", variant = "ghost", tooltip = tr("panel.tip_expand_all"), onClick = function() setAllCollapsed("pages", false) end }),
            ui.button({ key = "btn-pages-collapse-all", glyph = "chevrons-up", variant = "ghost", tooltip = tr("panel.tip_collapse_all"), onClick = function() setAllCollapsed("pages", true) end }),
        }),
    }
    if addError then
        out[#out + 1] = ui.label({ key = "add-err", text = tr("panel.add_bad_url"), color = "error" })
    end
    return out
end

local function pagesView()
    local out = {}
    local urls = {}
    for _, u in ipairs(data and data.pageUrls or {}) do
        if not removedPages[u] then urls[#urls + 1] = u end
    end
    if #urls == 0 then
        out[1] = ui.label({ key = "pages-empty", text = tr("panel.pages_empty"), color = "on_surface_variant" })
        return out
    end
    local bySource = {}
    for _, sp in ipairs(data.pages or {}) do bySource[sp.source] = sp end
    local pageErrors = data.errors and data.errors.pages or {}
    for i, url in ipairs(urls) do
        local sp = bySource[url]
        local key = "page:" .. url
        local closed = isCollapsed(key)
        local arrow = ui.label({ key = "page-arrow-" .. i, text = closed and "▶" or "▼", width = 14, color = "on_surface_variant" })
        local removeBtn = ui.button({ key = "btn-del-page-" .. i, glyph = "trash", variant = "ghost", tooltip = tr("panel.tip_remove_page"), onClick = function() removePage(url) end })
        if sp == nil then
            out[#out + 1] = ui.column({ key = "page-" .. i, gap = 2 }, {
                ui.row({ key = "page-head-" .. i, gap = 6, align = "center" }, {
                    ui.row({ key = "page-toggle-" .. i, gap = 6, align = "center", flexGrow = 1, onClick = function() toggleGroup(key) end }, {
                        arrow,
                        ui.label({ key = "page-url-" .. i, text = url, flexGrow = 1, fontWeight = "semibold", maxLines = 1 }),
                    }),
                    removeBtn,
                }),
                ui.label({ key = "page-err-" .. i, text = pageErrors[url] or tr("panel.page_no_data"), color = "error" }),
            })
        else
            local function open() openUrl(sp.url) end
            local children = {
                ui.row({ key = "page-head-" .. i, gap = 6, align = "center" }, {
                    ui.row({ key = "page-toggle-" .. i, gap = 6, align = "center", onClick = function() toggleGroup(key) end }, {
                        arrow,
                        ui.label({ key = "page-title-" .. i, text = sp.title, maxLines = 1, fontWeight = "bold" }),
                    }),
                    ui.row({
                        key = "page-link-" .. i, flexGrow = 1, justify = "end", tooltip = tr("panel.tip_copy_url"),
                        onClick = function() noctalia.copyToClipboard(sp.url, "text/plain") end,
                    }, {
                        ui.label({ key = "page-link-text-" .. i, text = sp.url, fontSize = 11, maxLines = 1, color = "on_surface_variant" }),
                    }),
                    ui.button({ key = "btn-open-page-" .. i, glyph = "external-link", variant = "ghost", tooltip = tr("panel.tip_open_page"), onClick = open }),
                    removeBtn,
                }),
            }
            if sp.description ~= "" then
                children[2] = ui.label({ key = "page-desc-" .. i, text = sp.description, fontSize = 11, maxLines = 1, color = "on_surface_variant" })
            end
            for j, g in ipairs(closed and {} or sp.groups) do
                if #sp.groups > 1 then
                    children[#children + 1] = ui.label({ key = "page-group-" .. i .. "-" .. j, text = g.name, fontWeight = "semibold", color = "on_surface_variant" })
                end
                for _, m in ipairs(g.monitors) do
                    children[#children + 1] = pageRow(m, open)
                end
            end
            out[#out + 1] = ui.column({ key = "page-" .. i, gap = 4 }, children)
        end
    end
    return out
end

local CERT_W = 440

local function certGroupName(level)
    local lim = data and data.certLimits or K.certLimits()
    if level == "expired" then return tr("panel.certs_expired") end
    if level == "red" then return tr("panel.certs_red", { days = lim.red }) end
    if level == "yellow" then return tr("panel.certs_yellow", { from = lim.red + 1, to = lim.yellow }) end
    return tr("panel.certs_green", { days = lim.yellow })
end

local function certRow(c)
    local color = R.levelColor(c.level)
    local days = c.level == "expired" and tr("panel.cert_expired_short") or tr("panel.cert_days_short", { days = c.certDays })
    return ui.row({ key = "crow-" .. c.id, gap = 8, align = "center", tooltip = c.name }, {
        ui.glyph({ key = "cglyph-" .. c.id, name = "certificate", size = 14, color = color }),
        ui.button({
            key = "curl-" .. c.id, text = c.url or c.name, variant = "ghost", contentAlign = "start", width = CERT_W,
            onClick = function() openMonitor(c.id) end,
            onRightClick = function() openRowMenu({ id = c.id, link = c.link }) end,
        }),
        ui.label({ key = "cdays-" .. c.id, text = days, width = 90, textAlign = "end", color = "on_surface_variant" }),
    })
end

local function certsView()
    local out = {}
    local certs = data and data.certs
    if certs == nil or certs.total == 0 then
        out[1] = ui.label({ key = "certs-empty", text = tr("panel.certs_empty"), color = "on_surface_variant" })
        return out
    end
    local groups = certs.groups
    local first, last, step = 1, #groups, 1
    if not certAsc then first, last, step = #groups, 1, -1 end
    for gi = first, last, step do
        local g = groups[gi]
        local key = "certs:" .. g.key
        local closed = isCollapsed(key)
        out[#out + 1] = ui.row({ key = "cgh-" .. g.key, gap = 8, align = "center", paddingV = 6, onClick = function() toggleGroup(key) end }, {
            ui.label({ text = closed and "▶" or "▼", width = 14, color = "on_surface_variant" }),
            ui.label({ key = "cert-group-" .. g.key, text = certGroupName(g.level), fontSize = 17, fontWeight = "bold", color = R.levelColor(g.level), flexGrow = 1, maxLines = 1 }),
            ui.label({ text = tostring(#g.rows), color = "on_surface_variant" }),
        })
        if not closed then
            local rf, rl, rs = 1, #g.rows, 1
            if not certAsc then rf, rl, rs = #g.rows, 1, -1 end
            for ri = rf, rl, rs do
                out[#out + 1] = certRow(g.rows[ri])
            end
        end
    end
    return out
end

local function notices()
    local out = {}
    local errors = data and data.errors or {}
    if errors.metrics then out[#out + 1] = ui.label({ key = "err-metrics", text = errors.metrics, color = "error" }) end
    if errors.monitors then out[#out + 1] = ui.label({ key = "err-monitors", text = errors.monitors, color = "error" }) end
    if data and data.credWarn then
        out[#out + 1] = ui.label({ key = "warn-cred", text = tr("panel.warn_cred_perms"), color = "tertiary" })
    end
    if data and data.insecureTls then
        out[#out + 1] = ui.label({ key = "warn-tls", text = tr("panel.warn_insecure_tls"), color = "tertiary" })
    end
    if data and data.plainHttp then
        out[#out + 1] = ui.label({ key = "warn-http", text = tr("panel.warn_http"), color = "tertiary" })
    end
    return out
end

function render()
    local mode = data and (data.dashboard and data.dashboard.mode or data.mode)
    local stamp = data and data.ts and tr("panel.updated", { time = noctalia.formatTime("%H:%M", data.ts) }) or nil
    local dashChildren = {}
    if mode then
        -- the button shows the current view; Kuma 2: first tag, all tags, flat. Kuma 3: groups, flat
        local view = data and data.tagMode or "first"
        local hier = mode == "hierarchy"
        local text, glyph, tip, nextView
        if view == "flat" then
            text, glyph, tip, nextView = tr("panel.tag_flat"), "list", tr("panel.tip_tag_flat"), "first"
        elseif hier then
            text, glyph, tip, nextView = tr("panel.mode_hierarchy"), "folders", tr("panel.tip_mode_hierarchy"), "flat"
        elseif view == "all" then
            text, glyph, tip, nextView = tr("panel.tag_all"), "tags", tr("panel.tip_tag_all"), "flat"
        else
            text, glyph, tip, nextView = tr("panel.tag_first"), "tag", tr("panel.tip_tag_first"), "all"
        end
        local lead = ui.button({
            key = "btn-tag-mode", glyph = glyph, variant = "ghost", text = text, tooltip = tip,
            onClick = function() sendRequest("tag_mode", nextView) end,
        })
        local leftChildren = { lead }
        for _, chip in ipairs(filterChips()) do leftChildren[#leftChildren + 1] = chip end
        local left = ui.row({ gap = 4, align = "center", flexGrow = 1 }, leftChildren)
        dashChildren[1] = ui.row({ key = "view-row", gap = 4, align = "center" }, {
            left,
            ui.button({
                key = "btn-hide-certs", glyph = "certificate", variant = hideCerts and "primary" or "ghost",
                tooltip = tr(hideCerts and "panel.tip_show_certs" or "panel.tip_hide_certs"),
                onClick = function() setHideCerts(not hideCerts) end,
            }),
            ui.button({ key = "btn-prune-muted", visible = data ~= nil and (data.mutedCount or 0) > 0, glyph = "eraser", variant = "ghost", tooltip = tr("panel.tip_prune_muted"), onClick = function() sendRequest("prune_muted") end }),
            ui.button({ key = "btn-expand-all", glyph = "chevrons-down", variant = "ghost", tooltip = tr("panel.tip_expand_all"), onClick = function() setAllCollapsed("dashboard", false) end }),
            ui.button({ key = "btn-collapse-all", glyph = "chevrons-up", variant = "ghost", tooltip = tr("panel.tip_collapse_all"), onClick = function() setAllCollapsed("dashboard", true) end }),
        })
    end
    dashChildren[#dashChildren + 1] = ui.scroll({ key = "scroll-dash", flexGrow = 1, gap = hideCerts and 0 or 4 }, dashboardView())
    local pagesChildren = addView()
    pagesChildren[#pagesChildren + 1] = ui.scroll({ key = "scroll-pages", flexGrow = 1, gap = 8 }, pagesView())
    panel.render(ui.column({ flexGrow = 1, gap = 8, align = "stretch" }, {
        ui.row({ key = "header", gap = 6, align = "center" }, {
            ui.label({ key = "title", text = tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
            ui.button({ key = "btn-settings", glyph = "settings", variant = "ghost", tooltip = tr("panel.tip_settings"), onClick = function() noctalia.openSettings() end }),
            ui.button({ key = "btn-close", glyph = "close", variant = "ghost", tooltip = tr("panel.tip_close"), onClick = function() panel.close() end }),
        }),
        ui.row({ key = "tabs", gap = 6, align = "center" }, {
            ui.button({ key = "btn-tab-dashboard", glyph = "layout-dashboard", text = tr("panel.tab_dashboard"), variant = tab == "dashboard" and "primary" or "ghost", onClick = function() setTab("dashboard"); render() end }),
            ui.button({ key = "btn-tab-pages", glyph = "world-www", text = tr("panel.tab_pages"), variant = tab == "pages" and "primary" or "ghost", onClick = function() setTab("pages"); render() end }),
            ui.button({ key = "btn-tab-certs", glyph = "certificate", text = tr("panel.tab_certs"), variant = tab == "certs" and "primary" or "ghost", onClick = function() setTab("certs"); render() end }),
            ui.button({ key = "btn-stale", visible = data ~= nil and data.stale == true, glyph = "alert-triangle", variant = "ghost", tooltip = tr("panel.tip_stale", { reason = data and data.errors and data.errors.metrics or "" }), onClick = requestRefresh }),
            ui.label({ key = "kuma-url", text = data and data.baseUrl or "", flexGrow = 1, textAlign = "end", maxLines = 1, fontSize = 12, color = "on_surface_variant" }),
            ui.button({ key = "btn-refresh", glyph = "refresh", variant = "ghost", tooltip = tr("panel.tip_refresh") .. (stamp and (" · " .. stamp) or ""), onClick = requestRefresh }),
        }),
        ui.column({ key = "notices", gap = 2 }, notices()),
        ui.column({ key = "tab-dashboard", visible = tab == "dashboard", flexGrow = 1, gap = 6 }, dashChildren),
        ui.column({ key = "tab-pages", visible = tab == "pages", flexGrow = 1, gap = 6 }, pagesChildren),
        ui.column({ key = "tab-certs", visible = tab == "certs", flexGrow = 1, gap = 6 }, {
            ui.row({ key = "certs-bar", gap = 4, align = "center" }, {
                ui.label({ key = "certs-hint", text = certAsc and tr("panel.certs_hint_asc") or tr("panel.certs_hint_desc"), flexGrow = 1, color = "on_surface_variant" }),
                ui.button({ key = "btn-cert-expand-all", glyph = "chevrons-down", variant = "ghost", tooltip = tr("panel.tip_expand_all"), onClick = function() setAllCollapsed("certs", false) end }),
                ui.button({ key = "btn-cert-collapse-all", glyph = "chevrons-up", variant = "ghost", tooltip = tr("panel.tip_collapse_all"), onClick = function() setAllCollapsed("certs", true) end }),
                ui.button({
                    key = "btn-cert-sort", glyph = certAsc and "sort-ascending" or "sort-descending", variant = "ghost",
                    tooltip = certAsc and tr("panel.tip_sort_asc") or tr("panel.tip_sort_desc"),
                    onClick = function() certAsc = not certAsc; render() end,
                }),
            }),
            ui.scroll({ key = "scroll-certs", flexGrow = 1, gap = 4 }, certsView()),
        }),
    }))
end

noctalia.state.watch(DATA_KEY, function(value)
    data = value
    if isOpen then render() end
end)

function onOpen(_context)
    isOpen = true
    local hf = dataFile("hide_certs.txt")
    hideCerts = hf ~= nil and (noctalia.readFile(hf) or ""):match("^%s*1") ~= nil
    noctalia.state.set("kuma_status_seen", os.time())
    data = noctalia.state.get(DATA_KEY)
    local mode = noctalia.getConfig("groups_on_open")
    defaultCollapsed = mode == "collapsed"
    rememberGroups = mode == "last"
    collapsed = {}
    if rememberGroups then loadCollapsed() end
    tab = startTab()
    requestRefresh()
    render()
end

function onClose()
    isOpen = false
end
