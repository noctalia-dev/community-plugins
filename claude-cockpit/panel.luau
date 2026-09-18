--!nonstrict
-- Claude Cockpit — the attached panel, three tabs over one shared header:
--
--   Usage     jrohland/claudecode's panel.luau, trimmed port (MIT, see
--             README Notes) — a thin client of service.luau's "usage"/
--             "status" state.
--   Sessions  every local session, grouped by project. Click to resume in
--             a terminal, eye toggles a preview, trash deletes after an
--             inline confirm. Fetched on-demand via sessions.luau, never
--             polled.
--   CLAUDE.md Global file + one row per known project, each opening in an
--             external editor. Reuses the Sessions tab's project list.
--
-- No rename: Claude Code has no command to rename a session after it is
-- created, so the label is the AI title (or the opening prompt, cut short).

local shared = require("./shared.luau")
local sessions = require("./sessions.luau")

local function tr(key, args)
    return noctalia.tr(key, args)
end

-- Read out of the plugin's own manifest, so the header version cannot drift
-- from what is actually installed. Empty when unreadable.
local pluginVersion = (function()
    local text = noctalia.readFile("plugin.toml")
    if type(text) ~= "string" then
        return ""
    end
    return ("\n" .. text):match('\nversion%s*=%s*"([^"]+)"') or ""
end)()

local TABS = { "usage", "sessions", "claudemd" }
local TAB_LABEL_KEY = { usage = "tab_usage", sessions = "tab_sessions", claudemd = "tab_claudemd" }

local isOpen = false
local activeTab = "usage"
local hoveredDay = nil -- 1..7 while the pointer is over a daily usage bar

local usage = noctalia.state.get("usage")
local status = noctalia.state.get("status")

-- Sessions/CLAUDE.md share one fetch: both tabs need the same project list.
local sessionsState = { loading = false, error = nil, projects = nil }
-- CLAUDE.md tab only: every real CLAUDE.md found under $HOME (see
-- sessions.findClaudeMdFiles), on top of the project list above.
local mdState = { loading = false, error = nil, paths = nil }
local searchText = ""
local expandedGroups = {} -- cwd -> bool, seeded on first load (see loadSessions)
local expandedSessionId = nil -- one preview open at a time
local confirmingDeleteId = nil

local render

-- ── small ui.* helpers (same shapes as jrohland/claudecode's panel.luau) ──

local function muted(text, size)
    return ui.label({ text = text, fontSize = size or 12, color = "on_surface_variant" })
end

local function heading(text)
    return ui.label({ text = text, fontSize = 14, fontWeight = "medium" })
end

local function card(children)
    return ui.column({ gap = 8, padding = 14, fill = "surface_variant/0.45", radius = 12, align = "stretch" }, children)
end

-- ── sessions/CLAUDE.md data loading ─────────────────────────────────────────

local function loadSessions(force)
    if sessionsState.loading then
        return
    end
    if sessionsState.projects ~= nil and not force then
        return
    end
    sessionsState.loading = true
    sessionsState.error = nil
    render()
    sessions.refresh(function(projects, err)
        sessionsState.loading = false
        if err ~= nil then
            sessionsState.error = err
        else
            sessionsState.error = nil
            sessionsState.projects = projects
            -- Seed a default closed state for a project seen for the first
            -- time; a project the user has already toggled keeps its choice
            -- across refreshes.
            for _, group in ipairs(projects) do
                if expandedGroups[group.cwd] == nil then
                    expandedGroups[group.cwd] = false
                end
            end
        end
        render()
    end)
end

local function loadClaudeMd(force)
    if mdState.loading then
        return
    end
    if mdState.paths ~= nil and not force then
        return
    end
    mdState.loading = true
    mdState.error = nil
    render()
    sessions.findClaudeMdFiles(function(paths, err)
        mdState.loading = false
        if err ~= nil then
            mdState.error = err
        else
            mdState.error = nil
            mdState.paths = paths
        end
        render()
    end)
end

local function setActiveTab(id)
    activeTab = id
    if id == "sessions" or id == "claudemd" then
        loadSessions(false)
    end
    if id == "claudemd" then
        loadClaudeMd(false)
    end
    render()
end

-- ── header + tab bar ─────────────────────────────────────────────────────

local function headerRow()
    local usageLoading = type(status) == "table" and status.state == "loading"
    local loading
    if activeTab == "usage" then
        loading = usageLoading
    elseif activeTab == "sessions" then
        loading = sessionsState.loading
    else
        loading = sessionsState.loading or mdState.loading
    end

    local onRefresh = shared.requestUsageRefresh
    if activeTab == "sessions" then
        onRefresh = function()
            loadSessions(true)
        end
    elseif activeTab == "claudemd" then
        onRefresh = function()
            loadSessions(true)
            loadClaudeMd(true)
        end
    end

    return ui.row({ gap = 10, align = "center" }, {
        ui.glyph({ name = "robot", size = 20, color = "primary" }),
        ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
        ui.label({ text = pluginVersion, fontSize = 10, color = "on_surface_variant" }),
        ui.button({
            glyph = loading and "loader-2" or "refresh",
            variant = "ghost", controlSize = "sm",
            enabled = not loading,
            tooltip = tr(loading and "refreshing" or "refresh"),
            onClick = onRefresh,
        }),
        ui.button({
            glyph = "settings", variant = "ghost", controlSize = "sm",
            tooltip = tr("settings_tooltip"),
            onClick = function() noctalia.openSettings() end,
        }),
        ui.button({
            glyph = "x", variant = "ghost", controlSize = "sm",
            tooltip = tr("close"),
            onClick = function() panel.close() end,
        }),
    })
end

local function tabSelector()
    local buttons = {}
    for _, id in ipairs(TABS) do
        table.insert(buttons, ui.button({
            key = "tab-" .. id,
            text = tr(TAB_LABEL_KEY[id]),
            variant = "ghost", controlSize = "sm", flexGrow = 1,
            selected = (activeTab == id),
            onClick = function() setActiveTab(id) end,
        }))
    end
    return ui.row({ gap = 4, align = "center" }, buttons)
end

-- ── Usage tab (trimmed port of jrohland/claudecode's panel.luau) ──────────

local function rateCard(w)
    local util = w.percent
    local p = w.pace
    local fill = shared.paceColor(w.status, "primary")

    local rows = {
        ui.row({ align = "center", justify = "space_between" }, {
            heading(w.label),
            ui.label({ text = `{shared.round(util)}% {tr("used")}`, fontSize = 14, color = fill }),
        }),
        ui.progress({
            progress = math.max(0, math.min(1, util / 100)),
            fill = fill, track = "on_surface/0.14", radius = 4, height = 8,
        }),
    }
    if p.timeFrac ~= nil then
        table.insert(rows, ui.progress({
            progress = p.timeFrac,
            fill = "on_surface/0.45", track = "on_surface/0.10", radius = 2, height = 3,
        }))
    end

    local caption = shared.paceLabel(p)
    local cd = shared.formatCountdown(w.resetIso)
    if cd then
        local clock = shared.formatResetClock(w.resetIso, true)
        local resets = `{tr("resets_in")} {cd}`
        if clock then
            resets = `{resets} ({clock})`
        end
        caption = caption and `{caption} · {resets}` or resets
    end
    if caption then
        table.insert(rows, muted(caption, 11))
    end
    return card(rows)
end

local function metricCol(label, tokens, cost, rate)
    return ui.column({ gap = 2, align = "center", flexGrow = 1 }, {
        muted(label, 12),
        ui.label({ text = shared.formatTokens(tokens), fontSize = 16, fontWeight = "bold", color = "primary" }),
        ui.label({ text = shared.formatCost(cost, rate), fontSize = 11, color = "on_surface_variant" }),
    })
end

local function tokensCard(u, todayTokens)
    local rate = u.currency_rates
    return card({
        heading(tr("token_consumption")),
        ui.row({ gap = 8, align = "start" }, {
            metricCol(tr("today"), todayTokens, u.today_cost, rate),
            metricCol(tr("week"), u.week_tokens, u.week_cost, rate),
            metricCol(tr("month"), u.month_tokens, u.month_cost, rate),
        }),
    })
end

local function dailyChart(daily, dailyCosts, rate)
    if type(daily) ~= "table" then
        daily = {}
    end
    if type(dailyCosts) ~= "table" then
        dailyCosts = {}
    end
    local maxVal = 1
    for _, v in daily do
        maxVal = math.max(maxVal, tonumber(v) or 0)
    end

    local labels = {}
    for w in (tr("days")):gmatch("[^,]+") do
        table.insert(labels, w)
    end

    local todayIdx = shared.todayIndex()
    local barH = 64
    local cols = {}
    for i = 1, 7 do
        local v = tonumber(daily[i]) or 0
        local h = (v > 0) and math.max(3, math.floor(v / maxVal * barH)) or 0
        local isToday = (i == todayIdx)
        local isHover = (i == hoveredDay)
        local fill = isToday and "primary" or "on_surface/0.14"
        if isHover then
            fill = isToday and "primary/0.75" or "on_surface/0.35"
        end

        table.insert(cols, ui.column({
            key = `day-{i}`, flexGrow = 1, gap = 4, align = "center",
            onHover = function(state)
                if state == "true" then
                    hoveredDay = i
                elseif hoveredDay == i then
                    hoveredDay = nil
                else
                    return
                end
                render()
            end,
        }, {
            ui.column({ height = barH, justify = "end", align = "center" }, {
                ui.box({ width = isHover and 22 or 18, height = h, radius = 3, fill = fill }),
            }),
            ui.label({
                text = labels[i] or tostring(i), fontSize = 10,
                color = (isToday or isHover) and "primary" or "on_surface_variant",
            }),
        }))
    end

    local detail = ""
    if hoveredDay then
        detail = tr("day_detail", {
            day = labels[hoveredDay] or tostring(hoveredDay),
            tokens = shared.formatTokens(daily[hoveredDay]),
            cost = shared.formatCost(dailyCosts[hoveredDay], rate),
        })
    end

    return card({
        ui.row({ align = "center", justify = "space_between" }, {
            heading(tr("daily_activity")),
            ui.label({ text = detail, fontSize = 11, color = "primary", maxLines = 1 }),
        }),
        ui.row({ gap = 6, align = "end" }, cols),
    })
end

local function modelsCard(weekModels, weekTokens)
    local list = shared.modelList(weekModels)
    if #list == 0 then
        return nil
    end
    weekTokens = tonumber(weekTokens) or 0

    local rows = { heading(tr("models_this_week")) }
    for _, m in list do
        local share = (weekTokens > 0) and math.min(1, m.tokens / weekTokens) or 0
        table.insert(rows, ui.column({ gap = 2, align = "stretch" }, {
            ui.row({ align = "center", justify = "space_between" }, {
                ui.label({ text = shared.shortModelName(m.name), fontSize = 12 }),
                muted(`{shared.formatTokens(m.tokens)} · {shared.round(share * 100)}%`, 12),
            }),
            ui.progress({ progress = share, fill = "primary", track = "on_surface/0.14", height = 5, radius = 2 }),
        }))
    end
    return card(rows)
end

local function allTimeRow(u)
    local parts = {}
    local first = u.first_session
    if type(first) == "string" and first ~= "" and first ~= "unknown" then
        table.insert(parts, `{tr("since")} {first}`)
    end
    local s = tonumber(u.alltime_sessions) or 0
    local m = tonumber(u.alltime_messages) or 0
    if s > 0 then
        table.insert(parts, `{s} {tr("sessions")}`)
    end
    if m > 0 then
        table.insert(parts, `{m} {tr("msgs")}`)
    end
    if #parts == 0 then
        return nil
    end
    return ui.row({ gap = 6, align = "center", paddingH = 2 }, {
        ui.glyph({ name = "calendar", size = 14, color = "on_surface_variant" }),
        muted(table.concat(parts, " · "), 11),
    })
end

local function usageNotice(glyph, text)
    return ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
        card({
            ui.row({ gap = 8, align = "center" }, {
                ui.glyph({ name = glyph, size = 20, color = "on_surface_variant" }),
                ui.label({ text = text, color = "on_surface_variant", flexGrow = 1, maxLines = 3 }),
            }),
        }),
    })
end

local function renderUsageTab()
    if type(status) == "table" and status.available == false then
        return usageNotice("robot-off", status.message ~= "" and status.message or tr("unavailable"))
    end
    if type(usage) ~= "table" then
        return usageNotice("robot", tr("loading"))
    end

    local plan = shared.planName(usage.subscription_type, usage.rate_limit_tier)
    local todayTokens = (type(usage.daily) == "table" and usage.daily[shared.todayIndex()]) or 0

    local cards = { muted(plan, 11) }
    for _, w in shared.windows(usage) do
        table.insert(cards, rateCard(w))
    end
    table.insert(cards, tokensCard(usage, todayTokens))
    table.insert(cards, dailyChart(usage.daily, usage.daily_costs, usage.currency_rates))
    local models = modelsCard(usage.week_models, usage.week_tokens)
    if models then
        table.insert(cards, models)
    end
    local footer = allTimeRow(usage)
    if footer then
        table.insert(cards, footer)
    end

    return ui.scroll({ key = "usage-scroll", flexGrow = 1, gap = 10, align = "stretch" }, cards)
end

-- ── Sessions tab ─────────────────────────────────────────────────────────

local function relativeTime(epochSecs)
    local diff = os.time() - (tonumber(epochSecs) or 0)
    if diff < 60 then
        return tr("time_just_now")
    end
    if diff < 3600 then
        return tr("time_minutes_ago", { n = math.floor(diff / 60) })
    end
    if diff < 86400 then
        return tr("time_hours_ago", { n = math.floor(diff / 3600) })
    end
    return tr("time_days_ago", { n = math.floor(diff / 86400) })
end

local function matchesSearch(session, cwd, needle)
    return session.label:lower():find(needle, 1, true) ~= nil
        or session.firstPrompt:lower():find(needle, 1, true) ~= nil
        or cwd:lower():find(needle, 1, true) ~= nil
end

-- The opening prompt in full, untruncated — the label already shows the
-- AI title (or a truncated version of this same text).
local function previewText(session)
    if session.firstPrompt ~= "" then
        return session.firstPrompt
    end
    return tr("no_preview")
end

local function resumeSession(session)
    local cmd = "cd " .. shared.shellQuote(session.cwd) .. " && exec claude --resume " .. shared.shellQuote(session.id)
    if not shared.launchTerminal(cmd) then
        noctalia.notifyError(tr("title"), tr("err_no_terminal"))
    end
end

local function togglePreview(id)
    if expandedSessionId == id then
        expandedSessionId = nil
    else
        expandedSessionId = id
    end
    render()
end

local function requestDelete(id)
    confirmingDeleteId = id
    render()
end

local function cancelDelete()
    confirmingDeleteId = nil
    render()
end

local function confirmDelete(session)
    sessions.deleteSession(session, function(ok)
        confirmingDeleteId = nil
        if not ok then
            noctalia.notifyError(tr("title"), tr("err_delete_failed"))
        end
        loadSessions(true)
    end)
end

local function toggleGroup(cwd)
    expandedGroups[cwd] = not expandedGroups[cwd]
    render()
end

local function setAllGroups(open)
    if sessionsState.projects == nil then
        return
    end
    for _, group in ipairs(sessionsState.projects) do
        expandedGroups[group.cwd] = open
    end
    render()
end

-- Rough gauge, not a guarantee: Sonnet-class extended-context ceiling.
-- Accounts without that beta cap out lower, so the exact count is always
-- shown as text next to the bar too.
local CONTEXT_WINDOW = 1000000

-- "claude-sonnet-5" -> "Sonnet", "claude-haiku-4-5-20251001" -> "Haiku".
local function shortModelId(model)
    local family = model:match("^claude%-(%a+)")
    return family and shared.shortModelName(family) or model
end

-- Model + a thin bar for how full the context window was on the last turn;
-- nil for a session with no assistant turn yet.
local function contextRow(session)
    if session.model == "" or session.contextTokens <= 0 then
        return nil
    end
    local frac = math.min(1, session.contextTokens / CONTEXT_WINDOW)
    local fill = "on_surface_variant"
    if frac >= 0.9 then
        fill = "error"
    elseif frac >= 0.7 then
        fill = "tertiary"
    end
    return ui.row({ gap = 6, align = "center" }, {
        muted(shortModelId(session.model), 10),
        ui.progress({ progress = frac, fill = fill, track = "on_surface/0.14", height = 4, radius = 2, flexGrow = 1 }),
        muted(shared.formatTokens(session.contextTokens), 10),
    })
end

local function sessionRow(session)
    local id = session.id
    local previewOpen = expandedSessionId == id
    local metaBits = { relativeTime(session.mtime) }
    if session.gitBranch then
        table.insert(metaBits, session.gitBranch)
    end

    local infoChildren = { muted(table.concat(metaBits, " · "), 10) }
    local ctxRow = contextRow(session)
    if ctxRow then
        table.insert(infoChildren, ctxRow)
    end

    local rowButtons = {
        ui.button({
            text = session.label, variant = "ghost", contentAlign = "start", flexGrow = 1,
            controlSize = "sm", tooltip = tr("tip_resume"),
            onClick = function() resumeSession(session) end,
        }),
    }

    -- Only a real cwd has a CLAUDE.md path worth opening — "unknown project"
    -- sessions (no recorded cwd) skip this button entirely.
    if session.cwd:sub(1, 1) == "/" then
        local claudeMdPath = session.cwd .. "/CLAUDE.md"
        local exists = noctalia.fileExists(claudeMdPath)
        table.insert(rowButtons, ui.button({
            glyph = "brain", variant = "ghost", controlSize = "sm",
            tooltip = tr(exists and "tip_open_editor" or "tip_create_editor"),
            onClick = function() shared.openInEditor(claudeMdPath) end,
        }))
    end

    table.insert(rowButtons, ui.button({
        -- Glyph flips eye/eye-off with the toggle state.
        glyph = previewOpen and "eye-off" or "eye", variant = "ghost", controlSize = "sm",
        tooltip = tr(previewOpen and "tip_hide_preview" or "tip_preview"),
        onClick = function() togglePreview(id) end,
    }))
    table.insert(rowButtons, ui.button({
        glyph = "trash", variant = "ghost", controlSize = "sm", tooltip = tr("tip_delete_session"),
        onClick = function() requestDelete(id) end,
    }))

    local blocks = {
        ui.column({ key = "sess-" .. id, gap = 2, align = "stretch" }, {
            ui.row({ gap = 6, align = "center" }, rowButtons),
            table.unpack(infoChildren),
        }),
    }

    if confirmingDeleteId == id then
        table.insert(blocks, ui.row({ key = "confirm-del-" .. id, gap = 8, align = "center" }, {
            ui.label({ text = tr("delete_session_confirm"), fontSize = 12, color = "on_surface", flexGrow = 1 }),
            ui.button({ text = tr("yes"), variant = "destructive", controlSize = "sm", onClick = function() confirmDelete(session) end }),
            ui.button({ text = tr("no"), variant = "ghost", controlSize = "sm", onClick = function() cancelDelete() end }),
        }))
    end

    if previewOpen then
        table.insert(blocks, ui.label({
            key = "preview-" .. id,
            text = previewText(session),
            fontSize = 11, color = "on_surface_variant", maxLines = 6,
        }))
    end

    local key = "sess-wrap-" .. id
        .. (previewOpen and "-prev" or "")
        .. (confirmingDeleteId == id and "-del" or "")
    return ui.column({ key = key, gap = 4, align = "stretch", paddingL = 20 }, blocks)
end

local function groupHeader(group, count)
    local expanded = expandedGroups[group.cwd] == true
    local basename = group.cwd:match("([^/]+)/?$") or group.cwd
    return ui.row({
        key = "grp-" .. group.cwd, gap = 8, align = "center",
        onClick = function() toggleGroup(group.cwd) end,
    }, {
        ui.glyph({ name = expanded and "chevron-down" or "chevron-right", size = 14, color = "on_surface_variant" }),
        ui.glyph({ name = "folder", size = 14, color = "on_surface_variant" }),
        ui.button({
            text = basename, variant = "ghost", contentAlign = "start", flexGrow = 1,
            controlSize = "sm", fontSize = 13, tooltip = group.cwd,
            onClick = function() toggleGroup(group.cwd) end,
        }),
        muted(tostring(count), 11),
    })
end

local function renderSessionsTab()
    loadSessions(false)

    local rows = {
        ui.row({ gap = 6, align = "center" }, {
            ui.input({
                key = "sess-search",
                value = searchText,
                placeholder = tr("search_placeholder"),
                flexGrow = 1,
                onChange = function(value)
                    searchText = value
                    render()
                end,
            }),
            ui.button({
                glyph = "chevrons-down", variant = "ghost", controlSize = "sm",
                tooltip = tr("tip_expand_all"),
                onClick = function() setAllGroups(true) end,
            }),
            ui.button({
                glyph = "chevrons-up", variant = "ghost", controlSize = "sm",
                tooltip = tr("tip_collapse_all"),
                onClick = function() setAllGroups(false) end,
            }),
        }),
    }

    if sessionsState.error ~= nil then
        table.insert(rows, ui.label({ text = sessionsState.error, color = "error" }))
    elseif sessionsState.projects == nil then
        table.insert(rows, muted(tr("loading")))
    else
        local needle = shared.trim(searchText):lower()
        local any = false
        for _, group in ipairs(sessionsState.projects) do
            local matches = {}
            for _, session in ipairs(group.sessions) do
                if needle == "" or matchesSearch(session, group.cwd, needle) then
                    table.insert(matches, session)
                end
            end
            if #matches > 0 then
                any = true
                table.insert(rows, groupHeader(group, #matches))
                if expandedGroups[group.cwd] == true then
                    for _, session in ipairs(matches) do
                        table.insert(rows, sessionRow(session))
                    end
                end
            end
        end
        if not any then
            table.insert(rows, muted(tr("no_sessions")))
        end
    end

    return ui.scroll({ key = "sessions-scroll", flexGrow = 1, gap = 6, align = "stretch" }, rows)
end

-- ── CLAUDE.md tab ────────────────────────────────────────────────────────

local function claudeMdRow(label, path)
    local exists = noctalia.fileExists(path)
    return ui.row({ key = "md-" .. path, gap = 8, align = "center" }, {
        ui.glyph({ name = exists and "check" or "x", size = 14, color = exists and "on_surface_variant" or "error" }),
        ui.column({ gap = 0, flexGrow = 1 }, {
            ui.label({ text = label, fontSize = 13 }),
            muted(path, 10),
        }),
        ui.button({
            glyph = "external-link", variant = "ghost",
            tooltip = tr(exists and "tip_open_editor" or "tip_create_editor"),
            onClick = function() shared.openInEditor(path) end,
        }),
    })
end

-- Union of the $HOME scan results and every session-linked project that has
-- no file yet, so a "create" row stays available for those too.
local function renderClaudeMdTab()
    loadSessions(false)
    loadClaudeMd(false)

    local rows = { claudeMdRow(tr("global_claude_md"), sessions.GLOBAL_CLAUDE_MD) }

    if mdState.error ~= nil then
        table.insert(rows, ui.label({ text = mdState.error, color = "error" }))
    elseif sessionsState.error ~= nil then
        table.insert(rows, ui.label({ text = sessionsState.error, color = "error" }))
    elseif mdState.paths == nil or sessionsState.projects == nil then
        table.insert(rows, muted(tr("loading")))
    else
        local seen = { [sessions.GLOBAL_CLAUDE_MD] = true }

        local found = { table.unpack(mdState.paths) }
        table.sort(found)
        for _, path in ipairs(found) do
            if not seen[path] then
                seen[path] = true
                local label = path:match("([^/]+)/CLAUDE%.md$") or path
                table.insert(rows, claudeMdRow(label, path))
            end
        end

        for _, group in ipairs(sessionsState.projects) do
            -- Only a group whose cwd is a real path gets a row: the "unknown
            -- project" fallback label is not a path an editor could open.
            if group.cwd:sub(1, 1) == "/" and not seen[group.claudeMdPath] then
                seen[group.claudeMdPath] = true
                local basename = group.cwd:match("([^/]+)/?$") or group.cwd
                table.insert(rows, claudeMdRow(basename, group.claudeMdPath))
            end
        end
    end

    return ui.scroll({ key = "claudemd-scroll", flexGrow = 1, gap = 8, align = "stretch" }, rows)
end

-- ── render / wiring ──────────────────────────────────────────────────────

render = function()
    if not isOpen then
        return
    end

    local body
    if activeTab == "usage" then
        body = renderUsageTab()
    elseif activeTab == "sessions" then
        body = renderSessionsTab()
    else
        body = renderClaudeMdTab()
    end

    panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
        headerRow(),
        tabSelector(),
        body,
    }))
end

noctalia.state.watch("usage", function(value)
    usage = value
    render()
end)

noctalia.state.watch("status", function(value)
    status = value
    render()
end)

function onOpen(_context)
    isOpen = true
    hoveredDay = nil
    usage = noctalia.state.get("usage")
    status = noctalia.state.get("status")
    panel.setWantsSecondTicks(true)
    noctalia.state.set("claude_cockpit_open", true)
    if activeTab == "sessions" or activeTab == "claudemd" then
        loadSessions(false)
    end
    if activeTab == "claudemd" then
        loadClaudeMd(false)
    end
    render()
end

function onClose()
    isOpen = false
    confirmingDeleteId = nil
    panel.setWantsSecondTicks(false)
    noctalia.state.set("claude_cockpit_open", false)
end

function update()
    render()
end
