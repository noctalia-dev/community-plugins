--!nonstrict
-- Claude Cockpit — the attached panel, five tabs over one shared header:
--
--   Live      every RUNNING session, grouped by attention (needs you /
--             working / idle): status, waiting reason, model, context, cost,
--             branch, last prompt. A reader of the service's "live" state:
--             while the panel is open on this tab it stamps
--             "live_wanted_at" every tick, which keeps the service polling.
--             Click a card to focus its terminal (niri/Hyprland/Umbriel).
--   Usage     jrohland/claudecode's panel.luau, trimmed port (MIT, see
--             README Notes) — a thin client of service.luau's "usage"/
--             "status" state.
--   Sessions  every local session, grouped by project, sortable by date,
--             name or session count, filterable to empty ones (no prompt
--             ever sent), moved ones ("relocated": the folder was renamed,
--             resume runs from the real one) or orphan ones ("orphan": no
--             folder at all, "misplaced": transcript in a project dir that
--             matches no folder); a glyph per status gives the reason.
--             Up/Down select a row, Enter opens it; a glyph marks the
--             running ones (the service's "live" state). Click to resume in
--             a terminal (refused for orphan/misplaced), copy puts the resume
--             command on the clipboard, pencil renames (custom title, not
--             for a running or orphan session), eye toggles a preview, trash deletes
--             after an inline confirm. "Orphans" scans for leftovers of
--             deleted sessions and removes them after an inline confirm.
--             Fetched on-demand via sessions.luau, never polled.
--   CLAUDE.md Global file + one row per known project, each opening in an
--             external editor. Reuses the Sessions tab's project list.
--   Skills    installed Claude Code plugins (skills and mods) grouped by
--             marketplace, plus bare ~/.claude/skills folders. Update and
--             uninstall per row (uninstall behind an inline confirm), refresh/
--             remove per marketplace, an install box at the bottom. Fetched
--             on-demand via skills.luau, never polled.

local shared = require("./shared.luau")
local sessions = require("./sessions.luau")
local skills = require("./skills.luau")
local live = require("./live.luau")

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

local TABS = { "live", "usage", "sessions", "claudemd", "skills" }
local TAB_LABEL_KEY = {
    live = "tab_live", usage = "tab_usage", sessions = "tab_sessions", claudemd = "tab_claudemd", skills = "tab_skills",
}
local TAB_GLYPH = { live = "activity", usage = "chart-bar", sessions = "history", claudemd = "file-text", skills = "puzzle" }

local isOpen = false
local activeTab = "live"
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
local GROUP_PAGE = 20 -- session rows drawn per project, and added per "show more"
local groupShown = {} -- cwd -> how many rows that project draws

local function groupLimit(cwd)
    return groupShown[cwd] or GROUP_PAGE
end
local expandedSessionId = nil -- one preview open at a time
local confirmingDeleteId = nil
local confirmingClean = false -- inline confirm strip for "delete all empty sessions"
-- Sessions tab ordering/filter. Date sorts newest first, name A-Z, count
-- (sessions per folder, folders only) most first, until the active button is
-- clicked again.
local sortBy = "date" -- "date" | "name" | "count"
local sortAsc = false
local emptyOnly = false -- only sessions that never got a prompt
local statusFilter = nil -- nil | "moved" (relocated) | "orphan" (orphan + misplaced)
local renamingId = nil -- session with the inline rename strip open
local repairingId = nil -- session with the inline repair strip open
local renamingSession = nil -- its session record, for the Return key
local renameDraft = ""
local renameRev = 0 -- bumped on each open to reseed the uncontrolled input
local orphanState = { scanning = false, list = nil, confirming = false, showing = false }

-- Keyboard selection on the Sessions tab: Up/Down walk `navItems` (the rows
-- the last render drew: project headers and sessions), Enter runs the
-- selected one. `revealKey` on the scroll keeps it in view (plugin_api >= 33).
local navItems = {}
local sel = 1
-- capture_keys filters key repeat (one press, one release), so a held arrow is
-- repeated from the frame tick. It stops at the list end instead of wrapping.
local KEY_STEPS = { up = -1, down = 1 }
local REPEAT_DELAY_MS = 350
local REPEAT_STEP_MS = 60
local heldStep = 0
local repeatInMs = 0

-- Live tab: filled from the service's "live" state (see service.luau).
local liveState = { error = nil, groups = nil }

-- Skills tab: one fetch for plugins + marketplaces + local skill folders.
local skillsState = { loading = false, error = nil, groups = nil, localSkills = nil }
local skillBusy = {} -- action key -> true while its `claude plugin` run is in flight
local confirmingSkillKey = nil -- "plugin:<id>" / "market:<name>" / "local:<name>"
local installText = ""
local installRev = 0 -- bumped to clear the uncontrolled install input

local render

-- ── small ui.* helpers (same shapes as jrohland/claudecode's panel.luau) ──

-- Children list without the nil holes an optional element would leave.
local function compact(...)
    local out = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if v ~= nil then
            table.insert(out, v)
        end
    end
    return out
end

local function muted(text, size)
    return ui.label({ text = text, fontSize = size or 12, color = "on_surface_variant" })
end

local function heading(text)
    return ui.label({ text = text, fontSize = 14, fontWeight = "medium" })
end

local function card(children)
    return ui.column({ gap = 8, padding = 14, fill = "surface_container/0.45", radius = 12, align = "stretch" }, children)
end

-- The Usage tab packs everything into one screen: tighter padding, and an
-- optional flexGrow so two cards can share a row.
local function compactCard(children, flexGrow)
    return ui.column({
        gap = 6, padding = 10, fill = "surface_container/0.45", radius = 12, align = "stretch", flexGrow = flexGrow,
    }, children)
end

-- ── sessions/CLAUDE.md data loading ─────────────────────────────────────────

-- utf8.offset is only safe on valid UTF-8; invalid text is left as is.
local function capDraft(value)
    local n = utf8.len(value)
    if n ~= nil and n > 120 then
        return value:sub(1, utf8.offset(value, 121) - 1)
    end
    return value
end

local reloadQueued = false -- a forced reload asked for while a scan was running

local function loadSessions(force)
    if sessionsState.loading then
        -- The running scan may have read the sessions before a delete: scan
        -- again once it finishes instead of dropping the request.
        if force then
            reloadQueued = true
        end
        return
    end
    if sessionsState.projects ~= nil and not force then
        return
    end
    sessionsState.loading = true
    sessionsState.error = nil
    if force then
        repairingId = nil
        orphanState = { scanning = false, list = nil, confirming = false, showing = false }
    end
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
        if reloadQueued then
            reloadQueued = false
            loadSessions(true)
        end
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

-- Keeps the service polling and asks it for a fresh run right now.
local function loadLive()
    noctalia.state.set("live_wanted_at", os.time())
    noctalia.state.set("live_nonce", (tonumber(noctalia.state.get("live_nonce")) or 0) + 1)
end

local function applyLive(value)
    if type(value) ~= "table" then
        return
    end
    liveState.error = value.error
    if type(value.groups) == "table" then
        liveState.groups = value.groups
    end
end
applyLive(noctalia.state.get("live"))

local function loadSkills(force)
    if skillsState.loading then
        return
    end
    if skillsState.groups ~= nil and not force then
        return
    end
    if not skills.available() then
        skillsState.error = tr("err_no_claude")
        return
    end
    skillsState.loading = true
    skillsState.error = nil
    render()
    skills.refresh(function(data, err)
        skillsState.loading = false
        skillsState.error = err
        if data ~= nil then
            skillsState.groups = skills.groupByMarketplace(data.plugins, data.marketplaces)
            skillsState.localSkills = data.localSkills
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
    if id == "skills" then
        loadSkills(false)
    end
    if id == "live" or id == "sessions" then
        loadLive()
    end
    render()
end

-- ── header + tab bar ─────────────────────────────────────────────────────

local function headerRow()
    local usageLoading = type(status) == "table" and status.state == "loading"
    local loading
    if activeTab == "usage" then
        loading = usageLoading
    elseif activeTab == "live" then
        loading = liveState.groups == nil and liveState.error == nil
    elseif activeTab == "sessions" then
        loading = sessionsState.loading
    elseif activeTab == "skills" then
        loading = skillsState.loading
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
    elseif activeTab == "skills" then
        onRefresh = function()
            loadSkills(true)
        end
    elseif activeTab == "live" then
        onRefresh = loadLive
    end

    return ui.row({ gap = 10, align = "center" }, {
        ui.glyph({ name = "robot", size = 20, color = "primary" }),
        ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold" }),
        ui.label({ text = pluginVersion, fontSize = 10, color = "on_surface_variant" }),
        ui.label({ key = "hdr-spacer", text = "", flexGrow = 1 }),
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
            glyph = TAB_GLYPH[id],
            text = tr(TAB_LABEL_KEY[id]),
            variant = "ghost", controlSize = "sm", flexGrow = 1,
            selected = (activeTab == id),
            onClick = function() setActiveTab(id) end,
        }))
    end
    return ui.row({ gap = 4, align = "center" }, buttons)
end

-- ── Usage tab (trimmed port of jrohland/claudecode's panel.luau) ──────────

-- The plan-wide weekly window (not a per-model one).
local function isWeekly(w)
    return w.group == "weekly" and (type(w.model) ~= "string" or w.model == "")
end

local function windowGlyph(w)
    if w.kind == "session" then
        return "clock"
    end
    return isWeekly(w) and "calendar-stats" or "cpu"
end

-- Title colour per window, all from the theme: session, weekly, anything else.
local function windowColor(w)
    if w.kind == "session" then
        return "primary"
    end
    return isWeekly(w) and "tertiary" or "secondary"
end

-- Big coloured card title, same look as the limit windows' titles.
local function sectionTitle(text, color, glyph)
    return ui.row({ gap = 6, align = "center" }, {
        ui.glyph({ name = glyph, size = 18, color = color }),
        ui.label({ text = text, fontSize = 17, fontWeight = "bold", color = color }),
    })
end

-- One window: a big coloured title with the percent at the far end, the
-- pace/reset text under it, then the two bars.
local function rateRow(w)
    local util = w.percent
    local p = w.pace
    local fill = shared.paceColor(w.status, "primary")

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

    local rows = {
        ui.row({ align = "center", justify = "space_between" }, {
            sectionTitle(w.label, windowColor(w), windowGlyph(w)),
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
    if caption then
        table.insert(rows, 2, muted(caption, 11))
    end
    return ui.column({ gap = 4, align = "stretch" }, rows)
end

local function metricCol(label, tokens, cost, rate)
    return ui.column({ gap = 1, align = "center", flexGrow = 1 }, {
        muted(label, 11),
        ui.label({ text = shared.formatTokens(tokens), fontSize = 16, fontWeight = "bold", color = "primary" }),
        ui.label({ text = shared.formatCost(cost, rate), fontSize = 11, color = "on_surface_variant" }),
    })
end

-- Heading at the left, the three periods in one row beside it.
local function tokensCard(u, todayTokens)
    local rate = u.currency_rates
    return compactCard({
        ui.row({ gap = 8, align = "center" }, {
            sectionTitle(tr("token_consumption"), "secondary", "coins"),
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
    local barH = 52
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
            key = `day-{i}`, flexGrow = 1, gap = 3, align = "center",
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
                ui.box({ width = isHover and 34 or 30, height = h, radius = 3, fill = fill }),
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

    return compactCard({
        ui.row({ align = "center", justify = "space_between" }, {
            sectionTitle(tr("daily_activity"), "tertiary", "chart-bar"),
            ui.label({ text = detail, fontSize = 11, color = "primary", maxLines = 1 }),
        }),
        ui.row({ gap = 4, align = "end" }, cols),
    })
end

local function modelsCard(weekModels, weekTokens)
    local list = shared.modelList(weekModels)
    if #list == 0 then
        return nil
    end
    weekTokens = tonumber(weekTokens) or 0

    local rows = { sectionTitle(tr("models_this_week"), "primary", "robot") }
    for _, m in list do
        local share = (weekTokens > 0) and math.min(1, m.tokens / weekTokens) or 0
        table.insert(rows, ui.column({ gap = 2, align = "stretch" }, {
            ui.row({ align = "center", justify = "space_between" }, {
                ui.label({ text = shared.shortModelName(m.name), fontSize = 12 }),
                muted(`{shared.round(share * 100)}% · {shared.formatTokens(m.tokens)}`, 11),
            }),
            ui.progress({ progress = share, fill = "primary", track = "on_surface/0.14", height = 5, radius = 2 }),
        }))
    end
    return compactCard(rows)
end

local function allTimeRow(u, plan)
    local parts = {}
    if type(plan) == "string" and plan ~= "" then
        table.insert(parts, plan)
    end
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

    local cards = {}
    local rates = {}
    for _, w in shared.windows(usage) do
        table.insert(rates, rateRow(w))
    end
    table.insert(cards, compactCard(rates))
    table.insert(cards, tokensCard(usage, todayTokens))
    local daily = dailyChart(usage.daily, usage.daily_costs, usage.currency_rates)
    local models = modelsCard(usage.week_models, usage.week_tokens)
    if models then
        table.insert(cards, models)
    end
    table.insert(cards, daily)
    -- The plan name moves to the footer line, next to the all-time totals.
    local footer = allTimeRow(usage, plan)
    if footer then
        table.insert(cards, footer)
    end

    return ui.scroll({ key = "usage-scroll", flexGrow = 1, gap = 8, align = "stretch" }, cards)
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
        or session.cwd:lower():find(needle, 1, true) ~= nil -- the old folder of a relocated session
end

-- The opening prompt in full, untruncated — the label already shows the
-- AI title (or a truncated version of this same text).
local function previewText(session)
    if session.firstPrompt ~= "" then
        return session.firstPrompt
    end
    return tr("no_preview")
end

-- Ids of the sessions running right now, from the service's "live" state.
local function liveIds()
    local ids = {}
    for _, g in ipairs(live.GROUPS) do
        for _, s in ipairs((liveState.groups or {})[g] or {}) do
            ids[s.id] = true
        end
    end
    return ids
end

local function resumeSession(session)
    if session.status == "orphan" or session.status == "misplaced" or session.status == "unknown" then
        noctalia.notifyError(tr("title"), tr("err_resume_refused", { reason = tr("resume_reason_" .. session.status) }))
        return
    end
    if session.empty then
        return -- `claude --resume` finds nothing and the terminal closes at once
    end
    local cmd = "cd " .. shared.shellQuote(session.runCwd) .. " && exec claude --resume " .. shared.shellQuote(session.id)
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
    -- Decided before the delete: the reload afterwards drops the session.
    local last = sessions.isLastInProject(sessionsState.projects or {}, session)
    sessions.deleteSession(session, function(ok)
        confirmingDeleteId = nil
        if not ok then
            noctalia.notifyError(tr("title"), tr("err_delete_failed"))
        elseif last and sessions.memoryKept(session) then
            -- The project vanishes from the list, but its memory/ stays on disk.
            noctalia.notify(tr("title"), tr("memory_kept", { dir = session.projectDir }))
        end
        loadSessions(true)
    end)
end

-- Only a real cwd and a plain hex id: the text gets pasted into a shell.
local function copyResume(session)
    local text = "cd " .. shared.shellQuote(session.runCwd) .. " && claude --resume " .. session.id
    if noctalia.copyToClipboard(text, "text/plain") then
        noctalia.notify(tr("title"), tr("copied_resume"))
    end
end

local function openRename(session)
    renamingId = session.id
    renamingSession = session
    renameDraft = ""
    renameRev += 1
    render()
end

local function closeRename()
    renamingId = nil
    renamingSession = nil
    render()
end

local function confirmRename(session)
    if shared.trim(renameDraft) == "" then
        return
    end
    sessions.renameSession(session, renameDraft, function(ok)
        renamingId = nil
        renamingSession = nil
        if not ok then
            noctalia.notifyError(tr("title"), tr("err_rename_failed"))
        end
        loadSessions(true)
    end)
end

local REPAIR_ERRORS = {
    not_absolute = "err_repair_not_absolute", exists = "err_repair_exists",
    move = "err_repair_move", unsafe = "err_repair_unsafe", same_dir = "err_repair_same_dir",
    mkdir = "err_repair_mkdir", sidecar = "err_repair_sidecar",
    status = "err_repair_status", cwd_missing = "err_repair_cwd_missing",
}

local function openRepair(session)
    repairingId = session.id
    render()
end

local function closeRepair()
    repairingId = nil
    render()
end

local function confirmRepair(session)
    sessions.repairSession(session, function(ok, code)
        repairingId = nil
        if ok then
            noctalia.notify(tr("title"), tr("repair_done"))
        elseif REPAIR_ERRORS[code] then
            noctalia.notifyError(tr("title"), tr("err_repair_failed", { reason = tr(REPAIR_ERRORS[code]) }))
        else
            noctalia.notifyError(tr("title"), tr("err_repair_generic"))
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

-- Theme roles have no yellow; a hex that reads on dark and light themes.
local YELLOW = "#e8b923"

-- Row glyph per status; "ok" has none.
local STATUS_MARK = {
    relocated = { glyph = "folder-symlink", color = YELLOW },
    orphan = { glyph = "folder-off", color = "error" },
    misplaced = { glyph = "alert-triangle", color = "tertiary" },
    unknown = { glyph = "help-circle", color = "on_surface_variant" },
}

-- ui.button cannot colour its glyph, so the row actions are clickable rows.
-- Hover fill is driven by onHover; render() runs only when the hovered key changes.
local hoveredIcon = nil
local HOVER_FILL = "on_surface/0.08"
-- The host keeps the last fill when the prop is absent, so "no fill" must be sent explicitly.
local NO_FILL = "#00000000"

local function onIconHover(key)
    return function(state)
        local nextKey = hoveredIcon
        if state == "true" then
            nextKey = key
        elseif hoveredIcon == key then
            nextKey = nil
        end
        if nextKey ~= hoveredIcon then
            hoveredIcon = nextKey
            render()
        end
    end
end

local function iconButton(key, glyph, color, tooltip, onClick)
    return ui.row({
        key = key, tooltip = tooltip, onClick = onClick, onHover = onIconHover(key),
        align = "center", justify = "center", padding = 8, radius = 6,
        fill = hoveredIcon == key and HOVER_FILL or NO_FILL,
    }, {
        ui.glyph({ name = glyph, size = 16, color = color }),
    })
end

local function sessionWrapKey(session)
    return "sess-wrap-" .. session.id
        .. (expandedSessionId == session.id and "-prev" or "")
        .. (confirmingDeleteId == session.id and "-del" or "")
        .. (renamingId == session.id and "-ren" or "")
        .. (repairingId == session.id and "-rep" or "")
end

local function sessionRow(session, selected, isLive)
    local id = session.id
    local previewOpen = expandedSessionId == id
    local metaBits = { os.date("%Y-%m-%d %H:%M", session.mtime), relativeTime(session.mtime) }
    if session.empty then
        table.insert(metaBits, tr("session_empty"))
    end
    if session.gitBranch then
        table.insert(metaBits, session.gitBranch)
    end

    local infoChildren = { muted(table.concat(metaBits, " · "), 10) }
    local ctxRow = contextRow(session)
    if ctxRow then
        table.insert(infoChildren, ctxRow)
    end

    local rowButtons = {}
    if isLive then
        table.insert(rowButtons, ui.glyph({ name = "activity", size = 14, color = YELLOW }))
    end
    local mark = STATUS_MARK[session.status]
    if mark then
        local tip = tr("status_misplaced")
        if session.status == "relocated" then
            tip = tr("status_relocated", { path = session.resolvedCwd })
        elseif session.status == "orphan" then
            tip = tr(session.hasMemory and "status_orphan_memory" or "status_orphan")
        elseif session.status == "unknown" then
            tip = tr("status_unknown")
        end
        table.insert(rowButtons, ui.row({ key = "status-" .. id, tooltip = tip }, {
            ui.glyph({ name = mark.glyph, size = 14, color = mark.color }),
        }))
    end
    table.insert(rowButtons, ui.button({
        key = "resume-" .. id,
        text = session.label, variant = "ghost", contentAlign = "start", flexGrow = 1,
        controlSize = "sm", tooltip = tr(session.empty and "tip_resume_empty" or "tip_resume"), selected = selected,
        onClick = function() resumeSession(session) end,
    }))

    -- Only a real cwd has a CLAUDE.md path worth opening — "unknown project"
    -- sessions (no recorded cwd) skip both buttons. Copy only where the
    -- command works; no CLAUDE.md where no folder is known to exist.
    local resumable = session.status == "ok" or session.status == "relocated"
    if resumable and session.cwd:sub(1, 1) == "/" and session.cwdKnown and session.runCwd:sub(1, 1) == "/" and id:match("^[%x-]+$") then
        table.insert(rowButtons, iconButton(
            "copy-" .. id, "copy", "on_surface_variant", tr("tip_copy_resume"),
            function() copyResume(session) end
        ))
    end
    if session.runCwd:sub(1, 1) == "/" and session.status ~= "orphan" and session.status ~= "unknown" then
        local claudeMdPath = session.runCwd .. "/CLAUDE.md"
        local exists = noctalia.fileExists(claudeMdPath)
        table.insert(rowButtons, iconButton(
            "md-" .. id, "brain", "tertiary", tr(exists and "tip_open_editor" or "tip_create_editor"),
            function() shared.openInEditor(claudeMdPath) end
        ))
    end

    table.insert(rowButtons, iconButton(
        -- Glyph flips eye/eye-off with the toggle state.
        "prev-" .. id, previewOpen and "eye-off" or "eye", "secondary",
        tr(previewOpen and "tip_hide_preview" or "tip_preview"),
        function() togglePreview(id) end
    ))
    -- A running session would write over the custom title on its next turn;
    -- an orphan cannot resume, so a name on it is pointless.
    if not isLive and session.status ~= "orphan" then
        table.insert(rowButtons, iconButton(
            "ren-" .. id, "pencil", "primary", tr("tip_rename_session"),
            function() openRename(session) end
        ))
    end
    if session.status == "misplaced" and not isLive then
        table.insert(rowButtons, iconButton(
            "repair-" .. id, "arrows-exchange", "tertiary", tr("tip_repair_session"),
            function() openRepair(session) end
        ))
    end
    table.insert(rowButtons, iconButton(
        "del-" .. id, "trash", "error", tr("tip_delete_session"),
        function() requestDelete(id) end
    ))

    local blocks = {
        ui.column({ key = "sess-" .. id, gap = 2, align = "stretch" }, {
            ui.row({ gap = 6, align = "center" }, rowButtons),
            table.unpack(infoChildren),
        }),
    }

    if confirmingDeleteId == id then
        table.insert(blocks, ui.row({ key = "confirm-del-" .. id, gap = 8, align = "center" }, {
            ui.label({ text = tr("delete_session_confirm"), fontSize = 12, color = "on_surface", flexGrow = 1 }),
            ui.button({ key = "del-ok-" .. id, text = tr("yes"), variant = "destructive", controlSize = "sm", onClick = function() confirmDelete(session) end }),
            ui.button({ text = tr("no"), variant = "ghost", controlSize = "sm", onClick = function() cancelDelete() end }),
        }))
    end

    if repairingId == id then
        table.insert(blocks, ui.row({ key = "confirm-repair-" .. id, gap = 8, align = "center" }, {
            ui.label({
                text = tr("repair_confirm", { cwd = session.cwd }),
                fontSize = 12, color = "on_surface", flexGrow = 1,
            }),
            ui.button({ key = "repair-ok-" .. id, text = tr("repair_yes"), variant = "primary", controlSize = "sm", onClick = function() confirmRepair(session) end }),
            ui.button({ key = "repair-no-" .. id, text = tr("no"), variant = "ghost", controlSize = "sm", onClick = closeRepair }),
        }))
    end

    if renamingId == id then
        table.insert(blocks, ui.row({ key = "rename-" .. id, gap = 8, align = "center" }, {
            ui.input({
                key = "ren-input-" .. id .. "-" .. renameRev,
                value = renameDraft,
                placeholder = tr("rename_placeholder"),
                flexGrow = 1,
                onChange = function(value)
                    renameDraft = capDraft(value)
                    render()
                end,
            }),
            ui.button({
                key = "ren-ok-" .. id, text = tr("rename_save"), variant = "primary", controlSize = "sm",
                enabled = shared.trim(renameDraft) ~= "",
                onClick = function() confirmRename(session) end,
            }),
            ui.button({ key = "ren-no-" .. id, text = tr("no"), variant = "ghost", controlSize = "sm", onClick = closeRename }),
        }))
    end

    if previewOpen then
        table.insert(blocks, ui.label({
            key = "preview-" .. id,
            text = previewText(session),
            fontSize = 11, color = "on_surface_variant", maxLines = 6,
        }))
    end

    return ui.column({ key = sessionWrapKey(session), gap = 4, align = "stretch" }, blocks)
end

local function groupHeader(group, count, selected, hasLive)
    local expanded = expandedGroups[group.cwd] == true
    local basename = group.cwd:match("([^/]+)/?$") or group.cwd
    return ui.row({
        key = "grp-" .. group.cwd, gap = 8, align = "center",
        onClick = function() toggleGroup(group.cwd) end,
    }, compact(
        ui.glyph({ name = expanded and "chevron-down" or "chevron-right", size = 14, color = "on_surface_variant" }),
        ui.glyph({ name = "folder", size = 14, color = "on_surface_variant" }),
        hasLive and ui.glyph({ name = "activity", size = 14, color = YELLOW }) or nil,
        ui.button({
            text = basename, variant = "ghost", contentAlign = "start", flexGrow = 1,
            controlSize = "sm", fontSize = 13, tooltip = group.cwd, selected = selected,
            onClick = function() toggleGroup(group.cwd) end,
        }),
        muted(tostring(count), 11)
    ))
end

-- Comparator for the active sort; `valueOf` maps a record to its sort value.
local function byActiveSort(valueOf)
    return function(a, b)
        local x, y = valueOf(a), valueOf(b)
        if x == y then
            return false
        end
        if sortAsc then
            return x < y
        end
        return x > y
    end
end

local function sortSessions(list)
    table.sort(list, byActiveSort(function(session)
        return sortBy == "name" and session.label:lower() or session.mtime
    end))
end

local function sortGroups(list)
    table.sort(list, byActiveSort(function(group)
        if sortBy == "count" then
            return #group.matches
        end
        return sortBy == "name" and (group.cwd:match("([^/]+)/?$") or group.cwd):lower() or group.lastActivity
    end))
end

local function setSort(key)
    if sortBy == key then
        sortAsc = not sortAsc
    else
        sortBy = key
        sortAsc = key == "name"
    end
    sel = 1
    render()
end

local function countSessions(pred)
    local n = 0
    for _, group in ipairs(sessionsState.projects or {}) do
        for _, session in ipairs(group.sessions) do
            if pred(session) then
                n += 1
            end
        end
    end
    return n
end

local function isEmpty(session)
    return session.empty
end

local function isMoved(session)
    return session.status == "relocated"
end

local function isOrphan(session)
    return session.status == "orphan" or session.status == "misplaced"
end

local STATUS_FILTERS = { moved = isMoved, orphan = isOrphan }

-- Moved and Orphan show a glyph and the count only, so the toolbar keeps its width.
-- A clickable row, so the glyph can be coloured; the selected fill is the
-- host's selected ghost button look (primary fill, on_primary text).
local function statusFilterButton(name, glyph, glyphColor, test)
    local key = "sort-" .. name
    local selected = statusFilter == name
    return ui.row({
        key = key, tooltip = tr("tip_filter_" .. name), gap = 6, align = "center", padding = 8, radius = 6,
        fill = selected and "primary" or (hoveredIcon == key and HOVER_FILL or NO_FILL),
        onHover = onIconHover(key),
        onClick = function()
            statusFilter = (statusFilter ~= name) and name or nil
            sel = 1
            render()
        end,
    }, {
        ui.glyph({ name = glyph, size = 16, color = selected and glyphColor == "on_surface" and "on_primary" or glyphColor }),
        ui.label({ text = tostring(countSessions(test)), fontSize = 13, color = selected and "on_primary" or "on_surface" }),
    })
end

local function checkOrphans()
    orphanState = { scanning = true, list = nil, confirming = false, showing = false }
    render()
    local ids = {}
    for id in pairs(liveIds()) do
        table.insert(ids, id)
    end
    sessions.checkOrphans(ids, function(list, err)
        if not isOpen then
            return
        end
        orphanState = { scanning = false, list = list, confirming = list ~= nil and #list > 0, showing = false }
        if err ~= nil then
            noctalia.notifyError(tr("title"), err)
        elseif #list == 0 then
            noctalia.notify(tr("title"), tr("orphans_none"))
        end
        render()
    end)
end

local function removeOrphans()
    local list = orphanState.list or {}
    orphanState = { scanning = false, list = nil, confirming = false, showing = false }
    sessions.removeOrphans(list, function(ok)
        if not ok then
            noctalia.notifyError(tr("title"), tr("err_orphans_failed"))
        end
        loadSessions(true)
    end)
end

local function orphansMb(list)
    local bytes = 0
    for _, o in ipairs(list) do
        bytes += tonumber(o.bytes) or 0
    end
    return string.format("%.1f", bytes / 1048576)
end

local function formatSize(bytes)
    if bytes < 1024 then
        return string.format("%d B", bytes)
    end
    if bytes < 1048576 then
        return string.format("%.1f KB", bytes / 1024)
    end
    return string.format("%.1f MB", bytes / 1048576)
end

local ORPHAN_PAGE = 20 -- detail rows drawn first, and added per "show more"
local ORPHAN_KINDS = { ["session-env"] = "session_env", ["file-history"] = "file_history", project = "project" }
local ORPHAN_REASONS = { no_transcript = true, project_empty = true }

-- Detail rows for the confirm strip, biggest first, from the list in memory.
local function orphanDetails(list)
    local sorted = {}
    for _, o in ipairs(list) do
        table.insert(sorted, o)
    end
    table.sort(sorted, function(a, b)
        local x, y = tonumber(a.bytes) or 0, tonumber(b.bytes) or 0
        if x ~= y then
            return x > y
        end
        return tostring(a.path) < tostring(b.path)
    end)
    local rows = {}
    local drawn = math.min(#sorted, orphanState.shown or ORPHAN_PAGE)
    for i = 1, drawn do
        local o = sorted[i]
        local path = tostring(o.path)
        local name = path:match("([^/]+)$") or path
        if name:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") then
            name = name:sub(1, 8) .. "…"
        end
        local kind = ORPHAN_KINDS[o.kind]
        local cells = {
            muted(kind and tr("orphan_kind_" .. kind) or tostring(o.kind), 10),
            ui.label({ text = name, fontSize = 12, color = "on_surface", flexGrow = 1 }),
            muted(formatSize(tonumber(o.bytes) or 0), 11),
        }
        if (tonumber(o.mtime) or 0) > 0 then
            table.insert(cells, muted(relativeTime(o.mtime), 11))
        end
        local lines = { ui.row({ gap = 8, align = "center", tooltip = path }, cells) }
        if ORPHAN_REASONS[o.reason] then
            table.insert(lines, muted(tr("orphan_reason_" .. o.reason), 11))
        end
        table.insert(rows, ui.column({ key = "orph-row-" .. path, gap = 2 }, lines))
    end
    if drawn < #sorted then
        local remaining = #sorted - drawn
        -- Not in navItems: the whole orphan strip is mouse-only.
        table.insert(rows, ui.button({
            key = "orph-more",
            text = tr("show_more", { n = math.min(remaining, ORPHAN_PAGE), total = remaining }),
            variant = "ghost", controlSize = "sm",
            onClick = function()
                orphanState.shown = drawn + ORPHAN_PAGE
                render()
            end,
        }))
    end
    return rows
end

-- Empty sessions that are safe to delete: one that is running right now has
-- no prompt yet either, and deleting it would pull the file from under it.
local function deletableEmpty()
    local running = liveIds()
    local list = {}
    for _, group in ipairs(sessionsState.projects or {}) do
        for _, session in ipairs(group.sessions) do
            if session.empty and not running[session.id] then
                table.insert(list, session)
            end
        end
    end
    return list
end

local function cleanEmpty()
    confirmingClean = false
    local list = deletableEmpty()
    if #list == 0 then
        render()
        return
    end
    sessions.deleteSessions(list, function(failed)
        if failed > 0 then
            noctalia.notifyError(tr("title"), tr("err_delete_failed"))
        end
        loadSessions(true)
    end)
end

local function sortButton(key, labelKey)
    local arrow = ""
    if sortBy == key then
        arrow = sortAsc and " ↑" or " ↓"
    end
    return ui.button({
        key = "sort-" .. key, text = tr(labelKey) .. arrow, variant = "ghost", controlSize = "sm",
        selected = sortBy == key, tooltip = tr("tip_sort_" .. key),
        onClick = function() setSort(key) end,
    })
end

-- Runs the selected row: a project header toggles, a session resumes.
local function activateSelected()
    local item = navItems[sel]
    if item ~= nil then
        item.act()
    end
end

local function moveSelection(step, wrap)
    local count = #navItems
    if count == 0 then
        return false
    end
    local target = sel + step
    if target < 1 or target > count then
        if not wrap then
            return false
        end
        target = target < 1 and count or 1
    end
    if target == sel then
        return false
    end
    sel = target
    return true
end

local function stopKeyRepeat()
    heldStep = 0
    panel.setNeedsFrameTick(false)
end

local function sessionsBody(top, scroll)
    return ui.column({ key = "sessions-body", flexGrow = 1, gap = 6, align = "stretch" }, {
        ui.column({ key = "sessions-top", gap = 6, align = "stretch" }, top),
        scroll,
    })
end

local function renderSessionsTab()
    loadSessions(false)

    -- Pinned above the scroll: only one-line strips, the tall orphan list stays in the scroll.
    local top = {
        ui.row({ key = "sess-tools", gap = 6, align = "center" }, {
            ui.input({
                key = "sess-search",
                value = searchText,
                placeholder = tr("search_placeholder"),
                flexGrow = 1,
                onChange = function(value)
                    searchText = value
                    sel = 1
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
        ui.row({ key = "sess-sort", gap = 6, align = "center" }, {
            sortButton("date", "sort_date"),
            sortButton("name", "sort_name"),
            sortButton("count", "sort_count"),
            ui.button({
                key = "sort-empty", text = tr("filter_empty", { n = countSessions(isEmpty) }),
                variant = "ghost", controlSize = "sm", selected = emptyOnly, tooltip = tr("tip_filter_empty"),
                onClick = function()
                    emptyOnly = not emptyOnly
                    sel = 1
                    render()
                end,
            }),
            statusFilterButton("moved", "folder-symlink", YELLOW, isMoved),
            statusFilterButton("orphan", "folder-off", "error", isOrphan),
            ui.label({ key = "sort-spacer", text = "", flexGrow = 1 }),
            ui.button({
                key = "sess-refresh", glyph = sessionsState.loading and "loader-2" or "refresh",
                variant = "ghost", controlSize = "sm", enabled = not sessionsState.loading,
                tooltip = tr(sessionsState.loading and "refreshing" or "refresh"),
                onClick = function()
                    loadSessions(true)
                    loadLive()
                end,
            }),
            ui.button({
                key = "sess-clean", glyph = "trash-x", variant = "ghost", controlSize = "sm",
                enabled = #deletableEmpty() > 0, tooltip = tr("tip_clean_empty"),
                onClick = function()
                    confirmingClean = true
                    render()
                end,
            }),
            ui.button({
                key = "sess-orphans", text = tr("orphans_button"),
                glyph = orphanState.scanning and "loader-2" or "search",
                variant = "ghost", controlSize = "sm", enabled = not orphanState.scanning,
                tooltip = tr("tip_orphans"),
                onClick = checkOrphans,
            }),
        }),
    }
    local rows = {}
    if orphanState.confirming then
        local list = orphanState.list or {}
        table.insert(top, ui.row({ key = "confirm-orphans", gap = 8, align = "center" }, {
            ui.label({
                text = tr("orphans_confirm", { n = #list, mb = orphansMb(list) }),
                fontSize = 12, color = "on_surface", flexGrow = 1,
            }),
            ui.button({
                key = "orphans-toggle", text = tr(orphanState.showing and "orphans_hide" or "orphans_show"),
                variant = "ghost", controlSize = "sm",
                onClick = function()
                    orphanState.showing = not orphanState.showing
                    orphanState.shown = nil
                    render()
                end,
            }),
            ui.button({ key = "orphans-ok", text = tr("yes"), variant = "destructive", controlSize = "sm", onClick = removeOrphans }),
            ui.button({
                text = tr("no"), variant = "ghost", controlSize = "sm",
                onClick = function()
                    orphanState = { scanning = false, list = nil, confirming = false, showing = false }
                    render()
                end,
            }),
        }))
        table.insert(top, muted(tr("orphans_rule"), 11))
        if orphanState.showing then
            table.insert(rows, ui.scroll({ key = "orph-list", height = 220, gap = 6, align = "stretch" }, orphanDetails(list)))
        end
    end
    if confirmingClean then
        table.insert(top, ui.row({ key = "confirm-clean", gap = 8, align = "center" }, {
            ui.label({ text = tr("clean_empty_confirm", { n = #deletableEmpty() }), fontSize = 12, color = "on_surface", flexGrow = 1 }),
            ui.button({ text = tr("yes"), variant = "destructive", controlSize = "sm", onClick = cleanEmpty }),
            ui.button({
                text = tr("no"), variant = "ghost", controlSize = "sm",
                onClick = function()
                    confirmingClean = false
                    render()
                end,
            }),
        }))
    end

    navItems = {}
    if sessionsState.error ~= nil then
        table.insert(rows, ui.label({ text = sessionsState.error, color = "error" }))
    elseif sessionsState.projects == nil then
        table.insert(rows, muted(tr("loading")))
    else
        local needle = shared.trim(searchText):lower()
        local shown = {}
        for _, group in ipairs(sessionsState.projects) do
            local matches = {}
            for _, session in ipairs(group.sessions) do
                if (needle == "" or matchesSearch(session, group.cwd, needle)) and (not emptyOnly or session.empty)
                    and (statusFilter == nil or STATUS_FILTERS[statusFilter](session)) then
                    table.insert(matches, session)
                end
            end
            if #matches > 0 then
                sortSessions(matches)
                table.insert(shown, { group = group, matches = matches, lastActivity = group.lastActivity, cwd = group.cwd })
            end
        end
        sortGroups(shown)
        -- Clamp after the filter shrank the list, then draw with the final sel.
        local total = 0
        for _, entry in ipairs(shown) do
            local drawn = expandedGroups[entry.cwd] == true and math.min(#entry.matches, groupLimit(entry.cwd)) or 0
            -- +1 for the project row, +1 for its "Show N more" row when it has one.
            total += 1 + drawn + ((drawn > 0 and drawn < #entry.matches) and 1 or 0)
        end
        sel = math.max(1, math.min(sel, total))
        local revealKey = nil
        local running = liveIds()
        local function track(key, act)
            table.insert(navItems, { key = key, act = act })
            if #navItems == sel then
                revealKey = key
            end
            return #navItems == sel
        end
        for _, entry in ipairs(shown) do
            local group = entry.group
            local hasLive = false
            for _, session in ipairs(group.sessions) do
                hasLive = hasLive or running[session.id] == true
            end
            table.insert(rows, groupHeader(group, #entry.matches, track("grp-" .. group.cwd, function() toggleGroup(group.cwd) end), hasLive))
            if expandedGroups[group.cwd] == true then
                -- Only the first few rows are built: a callback that draws a
                -- few hundred sessions in one go exceeds the host's CPU
                -- budget and gets the panel disabled.
                local limit = groupLimit(group.cwd)
                local drawn = math.min(#entry.matches, limit)
                for i = 1, drawn do
                    local session = entry.matches[i]
                    table.insert(rows, sessionRow(session, track(sessionWrapKey(session), function() resumeSession(session) end), running[session.id] == true))
                end
                if drawn < #entry.matches then
                    local remaining = #entry.matches - drawn
                    local function showMore()
                        groupShown[group.cwd] = limit + GROUP_PAGE
                        render()
                    end
                    -- A navigation row like the others, so ↑ / ↓ reach it and
                    -- Return draws the next page; the selection then lands on
                    -- the first new session.
                    table.insert(rows, ui.button({
                        key = "more-" .. group.cwd,
                        text = tr("show_more", { n = math.min(remaining, GROUP_PAGE), total = remaining }),
                        variant = "ghost", controlSize = "sm",
                        selected = track("more-" .. group.cwd, showMore),
                        onClick = showMore,
                    }))
                end
            end
        end
        if #shown == 0 then
            table.insert(rows, muted(tr("no_sessions")))
        end
        return sessionsBody(top, ui.scroll({ key = "sessions-scroll", flexGrow = 1, gap = 6, align = "stretch", revealKey = revealKey }, rows))
    end

    return sessionsBody(top, ui.scroll({ key = "sessions-scroll", flexGrow = 1, gap = 6, align = "stretch" }, rows))
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

-- ── Live tab ─────────────────────────────────────────────────────────────

local LIVE_STYLE = {
    waiting = { glyph = "bell-ringing", color = "error", label = "live_needs_you" },
    busy = { glyph = "loader-2", color = "primary", label = "live_working" },
    idle = { glyph = "player-pause", color = "on_surface_variant", label = "live_idle" },
}

-- "3s" / "6m" / "2h" / "1d": compact age of the current status.
local function shortAge(epochSecs)
    local d = math.max(0, os.time() - (tonumber(epochSecs) or 0))
    if d < 60 then
        return `{d}s`
    elseif d < 3600 then
        return `{math.floor(d / 60)}m`
    elseif d < 86400 then
        return `{math.floor(d / 3600)}h`
    end
    return `{math.floor(d / 86400)}d`
end

local function homePath(path)
    local home = noctalia.expandPath("~")
    if path:sub(1, #home + 1) == home .. "/" then
        return "~" .. path:sub(#home + 1)
    end
    return path
end

local function chip(glyph, text, color, extra)
    local children = {
        ui.glyph({ name = glyph, size = 11, color = color or "on_surface_variant" }),
        ui.label({ text = text, fontSize = 10, color = color or "on_surface_variant", maxLines = 1 }),
    }
    if extra then
        table.insert(children, extra)
    end
    return ui.row({ gap = 4, align = "center", paddingH = 6, paddingV = 2, radius = 6, fill = "on_surface/0.08" }, children)
end

local function liveCost(usd)
    if usd == nil then
        return nil
    end
    return shared.formatCost(usd, type(usage) == "table" and usage.currency_rates or nil)
end

local function focusSession(session)
    live.focus(session, function(ok)
        if not ok then
            noctalia.notifyError(tr("title"), tr("err_focus_failed"))
        end
    end)
end

local function liveCard(s)
    local style = LIVE_STYLE[s.status]
    local waiting = s.status == "waiting"

    local where = { ui.glyph({ name = "folder", size = 12, color = "on_surface_variant" }), muted(homePath(s.cwd), 11) }
    if s.gitBranch ~= "" then
        table.insert(where, ui.glyph({ name = "git-branch", size = 12, color = "on_surface_variant" }))
        table.insert(where, muted(s.gitBranch, 11))
    end

    local body = {
        ui.row({ gap = 6, align = "center" }, compact(
            ui.label({ text = s.name, fontSize = 13, fontWeight = "bold", flexGrow = 1, maxLines = 1 }),
            s.webUrl and ui.button({
                glyph = "world", variant = "ghost", controlSize = "sm", tooltip = tr("tip_open_web"),
                onClick = function() skills.openUrl(s.webUrl) end,
            }) or nil,
            ui.button({
                glyph = "terminal-2", variant = "ghost", controlSize = "sm", tooltip = tr("tip_focus_terminal"),
                onClick = function() focusSession(s) end,
            }),
            ui.label({ text = shortAge(s.since), fontSize = 11, color = style.color })
        )),
        ui.row({ gap = 4, align = "center" }, where),
    }
    if waiting then
        table.insert(body, ui.row({ gap = 6, align = "center" }, {
            ui.glyph({ name = "alert-circle", size = 13, color = "error" }),
            ui.label({ text = s.waitingFor ~= "" and s.waitingFor or tr("live_waiting"), fontSize = 12, color = "error", maxLines = 1 }),
        }))
    end
    if s.lastPrompt ~= "" then
        table.insert(body, ui.row({ gap = 6, align = "center" }, {
            ui.glyph({ name = "message", size = 12, color = "on_surface_variant" }),
            ui.label({ text = s.lastPrompt, fontSize = 11, color = "on_surface_variant", maxLines = 1, flexGrow = 1 }),
        }))
    end

    local chips = {}
    if s.model ~= "" then
        table.insert(chips, chip("cpu", shortModelId(s.model)))
    end
    if s.permissionMode ~= "" then
        table.insert(chips, chip("shield", s.permissionMode))
    end
    if s.contextTokens > 0 then
        local frac = math.min(1, s.contextTokens / CONTEXT_WINDOW)
        table.insert(chips, chip("stack-2", shared.formatTokens(s.contextTokens), nil,
            ui.progress({ progress = frac, fill = frac >= 0.9 and "error" or frac >= 0.7 and "tertiary" or "primary",
                track = "on_surface/0.14", width = 28, height = 4, radius = 2 })))
    end
    local cost = liveCost(s.costUSD)
    if cost then
        table.insert(chips, chip("coin", cost))
    end
    if #chips > 0 then
        table.insert(body, ui.row({ gap = 4, align = "center" }, chips))
    end

    return ui.row({
        key = "live-" .. s.id, gap = 10, align = "start", padding = 10, radius = 12,
        fill = waiting and "error/0.08" or "surface_container/0.45",
        border = waiting and "error/0.6" or nil, borderWidth = waiting and 1 or nil,
        tooltip = tr("tip_focus_terminal"),
        onClick = function() focusSession(s) end,
    }, {
        ui.column({ width = 32, height = 32, radius = 8, fill = style.color .. "/0.15", align = "center", justify = "center" }, {
            ui.glyph({ name = style.glyph, size = 16, color = style.color }),
        }),
        ui.column({ gap = 4, flexGrow = 1, align = "stretch" }, body),
    })
end

local function liveCounter(group, n)
    local style = LIVE_STYLE[group]
    return ui.row({ gap = 4, align = "center", paddingH = 8, paddingV = 2, radius = 8, fill = style.color .. "/0.15" }, {
        ui.glyph({ name = style.glyph, size = 12, color = style.color }),
        ui.label({ text = tostring(n), fontSize = 11, fontWeight = "bold", color = style.color }),
    })
end

local function renderLiveTab()
    if liveState.groups == nil then
        local text = liveState.error or tr("loading")
        return ui.column({ flexGrow = 1 }, { ui.label({ text = text, color = liveState.error and "error" or "on_surface_variant" }) })
    end

    local g = liveState.groups
    local summary = { ui.label({
        text = tr("live_summary", { cost = liveCost(g.costUSD) or "–", n = g.count }),
        fontSize = 12, color = "on_surface_variant", flexGrow = 1, maxLines = 1,
    }) }
    for _, group in ipairs(live.GROUPS) do
        table.insert(summary, liveCounter(group, #g[group]))
    end

    local rows = { ui.row({ key = "live-summary", gap = 6, align = "center" }, summary) }
    if liveState.error then
        table.insert(rows, ui.label({ text = liveState.error, color = "error" }))
    end
    if g.count == 0 then
        table.insert(rows, muted(tr("live_none")))
    end
    for _, group in ipairs(live.GROUPS) do
        if #g[group] > 0 then
            local style = LIVE_STYLE[group]
            table.insert(rows, ui.row({ key = "live-hdr-" .. group, gap = 6, align = "center" }, {
                ui.label({ text = tr(style.label), fontSize = 11, fontWeight = "bold", color = style.color }),
                muted(tostring(#g[group]), 11),
            }))
            for _, s in ipairs(g[group]) do
                table.insert(rows, liveCard(s))
            end
        end
    end
    return ui.scroll({ key = "live-scroll", flexGrow = 1, gap = 8, align = "stretch" }, rows)
end

-- ── Skills tab ───────────────────────────────────────────────────────────

-- Runs one skills.* action under `key`: glyph spins while busy, the outcome
-- goes to a notification, the lists reload afterwards.
local function runSkillAction(key, label, action, arg, after)
    skillBusy[key] = true
    confirmingSkillKey = nil
    render()
    action(arg, function(ok, message)
        skillBusy[key] = nil
        if ok then
            noctalia.notify(tr("title"), tr("skill_action_done", { name = label }) .. (after and (" " .. after) or ""))
        else
            noctalia.notifyError(tr("title"), message ~= "" and message or tr("skill_action_failed", { name = label }))
        end
        loadSkills(true)
    end)
end

local function glyphButton(key, glyph, tooltip, onClick)
    local busy = skillBusy[key] == true
    return ui.button({
        glyph = busy and "loader-2" or glyph, variant = "ghost", controlSize = "sm",
        enabled = not busy, tooltip = tooltip,
        onClick = onClick,
    })
end

local function askConfirm(key)
    confirmingSkillKey = key
    render()
end

local function confirmStrip(key, text, yesText, onYes)
    return ui.row({ key = "confirm-" .. key, gap = 8, align = "center" }, {
        ui.label({ text = text, fontSize = 12, color = "on_surface", flexGrow = 1, maxLines = 2 }),
        ui.button({ text = yesText, variant = "destructive", controlSize = "sm", onClick = onYes }),
        ui.button({ text = tr("no"), variant = "ghost", controlSize = "sm", onClick = function() askConfirm(nil) end }),
    })
end

-- Brand glyph for a GitHub link, a generic one for anything else.
local function linkButton(url)
    if url == nil then
        return nil
    end
    return ui.button({
        glyph = url:match("^https://github%.com/") and "brand-github" or "external-link",
        variant = "ghost", controlSize = "sm", tooltip = url,
        onClick = function() skills.openUrl(url) end,
    })
end

local function pluginRow(p, rows)
    local key = "plugin:" .. p.id
    local meta = p.version
    if p.newVersion then
        meta = meta .. " → " .. p.newVersion
    end
    if not p.enabled then
        meta = meta .. " · " .. tr("plugin_disabled")
    end
    table.insert(rows, ui.row({ key = "row-" .. key, gap = 8, align = "center" }, compact(
        ui.glyph({ name = "puzzle", size = 14, color = p.enabled and "primary" or "on_surface_variant" }),
        ui.column({ gap = 0, flexGrow = 1 }, {
            ui.label({ text = p.name, fontSize = 13, maxLines = 1 }),
            muted(meta, 10),
        }),
        linkButton(p.url),
        glyphButton("toggle:" .. p.id, p.enabled and "toggle-right" or "toggle-left",
            tr(p.enabled and "tip_disable_plugin" or "tip_enable_plugin"), function()
                runSkillAction("toggle:" .. p.id, p.name, skills.setEnabled, p, tr("restart_hint"))
            end),
        glyphButton("update:" .. p.id, p.newVersion and "circle-arrow-up" or "download",
            tr(p.newVersion and "tip_update_available" or "tip_update_plugin"), function()
            runSkillAction("update:" .. p.id, p.name, skills.updatePlugin, p, tr("restart_hint"))
        end),
        glyphButton(key, "trash", tr("tip_uninstall"), function() askConfirm(key) end)
    )))
    if confirmingSkillKey == key then
        table.insert(rows, confirmStrip(key, tr("uninstall_confirm", { name = p.name }), tr("uninstall"), function()
            runSkillAction(key, p.name, skills.uninstallPlugin, p, tr("restart_hint"))
        end))
    end
end

local function marketplaceHeader(g, rows)
    local key = "market:" .. g.name
    table.insert(rows, ui.row({ key = "row-" .. key, gap = 8, align = "center" }, compact(
        ui.glyph({ name = "building-store", size = 14, color = "on_surface_variant" }),
        ui.column({ gap = 0, flexGrow = 1 }, {
            ui.label({ text = g.name, fontSize = 13, fontWeight = "medium", maxLines = 1 }),
            muted(g.source or "", 10),
        }),
        linkButton(g.url),
        glyphButton("mupdate:" .. g.name, "refresh", tr("tip_update_marketplace"), function()
            runSkillAction("mupdate:" .. g.name, g.name, skills.updateMarketplace, g.name)
        end),
        glyphButton(key, "trash", tr("tip_remove_marketplace"), function() askConfirm(key) end)
    )))
    if confirmingSkillKey == key then
        -- `marketplace remove` also uninstalls every plugin from it, data included.
        local text = #g.plugins > 0
            and tr("remove_marketplace_confirm_plugins", { name = g.name, n = #g.plugins })
            or tr("remove_marketplace_confirm", { name = g.name })
        table.insert(rows, confirmStrip(key, text, tr("remove"), function()
            runSkillAction(key, g.name, skills.removeMarketplace, g.name)
        end))
    end
end

local function localSkillRow(skill, rows)
    local name = skill.name
    local key = "local:" .. name
    table.insert(rows, ui.row({ key = "row-" .. key, gap = 8, align = "center" }, compact(
        ui.glyph({ name = "file-text", size = 14, color = "primary" }),
        ui.label({ text = name, fontSize = 13, flexGrow = 1, maxLines = 1 }),
        linkButton(skill.url),
        glyphButton(key, "trash", tr("tip_uninstall"), function() askConfirm(key) end)
    )))
    if confirmingSkillKey == key then
        table.insert(rows, confirmStrip(key, tr("uninstall_confirm", { name = name }), tr("uninstall"), function()
            runSkillAction(key, name, skills.removeLocalSkill, name)
        end))
    end
end

local function submitInstall()
    local text = shared.trim(installText)
    if skills.classifySource(text) == nil then
        noctalia.notifyError(tr("title"), tr("err_bad_source"))
        return
    end
    installText = ""
    installRev += 1
    runSkillAction("install", text, skills.install, text)
end

local function installBox()
    local busy = skillBusy["install"] == true
    return card({
        heading(tr("install_heading")),
        ui.row({ gap = 6, align = "center" }, {
            ui.input({
                key = "skill-install-" .. installRev,
                value = installText,
                placeholder = tr("install_placeholder"),
                flexGrow = 1,
                onChange = function(value) installText = value end,
                onSubmit = function(value)
                    installText = value
                    submitInstall()
                end,
            }),
            ui.button({
                glyph = busy and "loader-2" or "plus", variant = "ghost", controlSize = "sm",
                enabled = not busy, tooltip = tr("tip_install"),
                onClick = function() submitInstall() end,
            }),
        }),
        muted(tr("install_hint"), 10),
    })
end

local function renderSkillsTab()
    loadSkills(false)

    local checking = skillBusy["check"] == true
    local rows = {
        ui.row({ key = "skills-tools", gap = 8, align = "center" }, {
            ui.label({ text = tr("updates_hint"), fontSize = 11, color = "on_surface_variant", flexGrow = 1, maxLines = 2 }),
            ui.button({
                glyph = checking and "loader-2" or "cloud-search",
                text = tr("check_updates"), variant = "ghost", controlSize = "sm",
                enabled = not checking, tooltip = tr("tip_check_updates"),
                onClick = function() runSkillAction("check", tr("check_updates"), skills.checkUpdates, nil) end,
            }),
        }),
    }
    if skillsState.error ~= nil then
        table.insert(rows, ui.label({ text = skillsState.error, color = "error" }))
    elseif skillsState.groups == nil then
        table.insert(rows, muted(tr("loading")))
    else
        for _, g in ipairs(skillsState.groups) do
            marketplaceHeader(g, rows)
            for _, p in ipairs(g.plugins) do
                pluginRow(p, rows)
            end
        end
        if #skillsState.localSkills > 0 then
            table.insert(rows, ui.row({ key = "local-hdr", gap = 8, align = "center" }, {
                ui.glyph({ name = "folder", size = 14, color = "on_surface_variant" }),
                ui.label({ text = tr("local_skills"), fontSize = 13, fontWeight = "medium", flexGrow = 1 }),
                muted(skills.LOCAL_SKILLS_DIR, 10),
            }))
            for _, skill in ipairs(skillsState.localSkills) do
                localSkillRow(skill, rows)
            end
        end
        if #skillsState.groups == 0 and #skillsState.localSkills == 0 then
            table.insert(rows, muted(tr("no_plugins")))
        end
    end

    return ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, {
        ui.scroll({ key = "skills-scroll", flexGrow = 1, gap = 8, align = "stretch" }, rows),
        installBox(),
    })
end

-- ── render / wiring ──────────────────────────────────────────────────────

render = function()
    if not isOpen then
        return
    end

    local body
    if activeTab == "live" then
        body = renderLiveTab()
    elseif activeTab == "usage" then
        body = renderUsageTab()
    elseif activeTab == "sessions" then
        body = renderSessionsTab()
    elseif activeTab == "skills" then
        body = renderSkillsTab()
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

noctalia.state.watch("live", function(value)
    applyLive(value)
    render()
end)

noctalia.state.watch("status", function(value)
    status = value
    render()
end)

function onOpen(_context)
    isOpen = true
    sel = 1
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
    if activeTab == "skills" then
        loadSkills(false)
    end
    if activeTab == "live" or activeTab == "sessions" then
        loadLive()
    end
    render()
end

function onClose()
    isOpen = false
    stopKeyRepeat() -- a key held while the panel closes never reports its release
    confirmingDeleteId = nil
    confirmingClean = false
    renamingId = nil
    renamingSession = nil
    repairingId = nil
    orphanState.confirming = false
    confirmingSkillKey = nil
    panel.setWantsSecondTicks(false)
    noctalia.state.set("claude_cockpit_open", false)
end

function update()
    if activeTab == "live" or activeTab == "sessions" then
        noctalia.state.set("live_wanted_at", os.time())
    end
    render()
end

-- The chords listed under capture_keys in plugin.toml. They arrive here even
-- while the filter input has focus; typing still goes to the input. Return is
-- captured too, with the keypad Enter (not the input's onSubmit): the input is rarely the focused
-- control after a click on a row. Sessions tab only.
function onKey(chord, pressed)
    if activeTab ~= "sessions" then
        return
    end
    if chord == "Return" or chord == "KP_Enter" then
        if pressed then
            if renamingSession ~= nil then
                confirmRename(renamingSession)
            else
                activateSelected()
            end
        end
        return
    end
    local step = KEY_STEPS[chord]
    if step == nil then
        return
    end
    if not pressed then
        if heldStep == step then
            stopKeyRepeat()
        end
        return
    end
    heldStep = step
    repeatInMs = REPEAT_DELAY_MS
    panel.setNeedsFrameTick(true)
    if moveSelection(step, true) then
        render()
    end
end

function onFrameTick(deltaMs)
    if heldStep == 0 then
        return
    end
    repeatInMs -= deltaMs
    if repeatInMs <= 0 then
        repeatInMs = REPEAT_STEP_MS
        if moveSelection(heldStep, false) then
            render()
        else
            stopKeyRepeat()
        end
    end
end
