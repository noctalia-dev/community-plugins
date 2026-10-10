--!nonstrict
-- Claude Cockpit — bar widget: toggles the panel. Two display modes
-- (display_mode setting, activity by default):
--
--   classic   glyph + an optional "sNN% wMM%" usage badge (session/weekly
--             rate windows) tinted and arrow-flagged the same way
--             jrohland/claudecode's pill is.
--   activity  glyph + one dot per live Claude Code session (red = needs
--             you, accent = working, grey = idle) + two fill rings for the
--             5-hour and 7-day windows, each followed by its "sNN%"/"wNN%"
--             (which of the two: usage_percent_display, as in classic). Stamps "live_wanted_at" every tick
--             so the service keeps polling live sessions (see service.luau).
--
-- Noctalia's ui.* has no arc, so a ring is a tiny SVG written once per
-- (percent, colors) into the plugin data dir and shown with ui.image;
-- colors come from noctalia.getColor (plugin_api 31) so rings follow the
-- theme. Once an instance has rendered a ui tree, the imperative
-- setText/setGlyph calls have no visible effect, so classic is then drawn
-- declaratively too.
--
-- Left click is a [widget.actions] default in plugin.toml, not wired here,
-- so the user can remap the gesture.

local shared = require("./shared.luau")

local open = false
local usage = noctalia.state.get("usage")
local status = noctalia.state.get("status")
local liveGroups = nil
local usedTree = false

local MAX_DOTS = 8
local RING_SIZE = 16
local ringDir = (function()
    local dir = noctalia.pluginDataDir()
    return dir and (dir .. "/rings") or nil
end)()

local function displayMode()
    return noctalia.getConfig("display_mode") == "classic" and "classic" or "activity"
end

local function usageText()
    local mode = noctalia.getConfig("usage_percent_display") or "both"
    if mode == "none" then
        return ""
    end
    if type(status) == "table" and status.available == false then
        return ""
    end
    if type(usage) ~= "table" then
        return ""
    end
    local session = shared.round(tonumber(usage.five_hour_util) or 0)
    local weekly = shared.round(tonumber(usage.seven_day_util) or 0)
    if mode == "session" then
        return `s{session}%`
    end
    if mode == "weekly" then
        return `w{weekly}%`
    end
    return `s{session}% w{weekly}%`
end

-- Worst pace status among the window(s) usage_percent_display shows, via
-- the same shared.pace/paceColor/SEVERITY the panel's Usage tab uses.
local function worstPaceStatus()
    if type(usage) ~= "table" then
        return "unknown"
    end
    local mode = noctalia.getConfig("usage_percent_display") or "both"
    if mode == "none" then
        return "unknown"
    end
    local pFive = shared.pace(usage.five_hour_util, usage.five_hour_reset, shared.FIVE_HOUR_SECS)
    local pSeven = shared.pace(usage.seven_day_util, usage.seven_day_reset, shared.SEVEN_DAY_SECS)
    local shown = (mode == "session") and { pFive } or (mode == "weekly") and { pSeven } or { pFive, pSeven }
    local worst = "unknown"
    for _, p in shown do
        if shared.SEVERITY[p.status] > shared.SEVERITY[worst] then
            worst = p.status
        end
    end
    return worst
end

-- Key/value rows (same shape jrohland/claudecode's pill tooltip uses) so
-- the shell lays them out as a two-column grid.
local function usageTooltip()
    if type(status) == "table" and status.available == false then
        return status.message ~= "" and status.message or noctalia.tr("unavailable")
    end
    if type(usage) ~= "table" then
        return noctalia.tr("loading")
    end

    local rows = {}
    local function row(key, value)
        table.insert(rows, { key = key, value = value })
    end

    row(noctalia.tr("plan"), shared.planName(usage.subscription_type, usage.rate_limit_tier))

    for _, w in shared.windows(usage) do
        local value = `{shared.round(w.percent)}%`
        local countdown = shared.formatCountdownShort(w.resetIso)
        if countdown then
            local clock = shared.formatResetClock(w.resetIso)
            value = clock and `{value}  ·  {countdown} ({clock})` or `{value}  ·  {countdown}`
        end
        row(w.label, value)
    end

    local todayTokens = (type(usage.daily) == "table" and usage.daily[shared.todayIndex()]) or 0
    local rate = usage.currency_rates
    row(noctalia.tr("today"), `{shared.formatTokens(todayTokens)}  ({shared.formatCost(usage.today_cost, rate)})`)
    row(noctalia.tr("week"), `{shared.formatTokens(usage.week_tokens)}  ({shared.formatCost(usage.week_cost, rate)})`)

    return rows
end

-- Path of a ring SVG for `percent` in the given palette roles, written on
-- first use. nil when the data dir or a color is unavailable.
-- shortcut: one file per (percent, fill, track) is never pruned — at most
-- 101 per theme color, a few KB in all; prune by theme if that ever grows.
local function ringImage(percent, fillRole)
    local fill = noctalia.getColor(fillRole)
    local track = noctalia.getColor("on_surface")
    if ringDir == nil or type(fill) ~= "string" or type(track) ~= "string" then
        return nil
    end
    local pct = math.max(0, math.min(100, shared.round(percent)))
    local path = `{ringDir}/ring-{pct}-{(fill:gsub("#", ""))}-{(track:gsub("#", ""))}.svg`
    if not noctalia.fileExists(path) then
        noctalia.mkdirAll(ringDir)
        local r = 14
        local c = 2 * math.pi * r
        local arc = ""
        if pct > 0 then
            arc = string.format(
                '<circle cx="18" cy="18" r="%d" fill="none" stroke="%s" stroke-width="6" stroke-linecap="round" stroke-dasharray="%.2f %.2f" transform="rotate(-90 18 18)"/>',
                r, fill, c * pct / 100, c)
        end
        noctalia.writeFile(path, string.format(
            '<svg xmlns="http://www.w3.org/2000/svg" width="36" height="36" viewBox="0 0 36 36"><circle cx="18" cy="18" r="%d" fill="none" stroke="%s" stroke-opacity="0.25" stroke-width="6"/>%s</svg>',
            r, track, arc))
    end
    return path
end

-- The 5-hour and the plan-wide 7-day window, as shared.windows() rows.
local function sessionAndWeek()
    local session, week = nil, nil
    for _, w in shared.windows(usage) do
        if w.kind == "session" and session == nil then
            session = w
        elseif w.group == "weekly" and (w.model == nil or w.model == "") and week == nil then
            week = w
        end
    end
    return session, week
end

local DOT_COLOR = { waiting = "error", busy = "primary", idle = "on_surface_variant" }

local function renderActivity()
    local vertical = barWidget.isVertical()
    -- A session waiting for the user swaps the glyph for a red bell.
    local waiting = type(liveGroups) == "table" and #(liveGroups.waiting or {}) > 0
    local children = {
        ui.glyph({
            name = waiting and "bell-ringing" or noctalia.getConfig("glyph") or "robot",
            size = 16,
            color = waiting and "error" or open and "primary" or "on_surface",
        }),
    }
    local shown = 0
    local total = 0
    for _, group in ipairs({ "waiting", "busy", "idle" }) do
        local list = type(liveGroups) == "table" and liveGroups[group] or {}
        for _ in ipairs(list) do
            total += 1
            if shown < MAX_DOTS then
                shown += 1
                table.insert(children, ui.box({ width = 8, height = 8, radius = 4, fill = DOT_COLOR[group] }))
            end
        end
    end
    if total > shown then
        table.insert(children, ui.label({ text = `+{total - shown}`, fontSize = 10, color = "on_surface_variant" }))
    end
    if type(status) ~= "table" or status.available ~= false then
        local session, week = sessionAndWeek()
        local shownMode = noctalia.getConfig("usage_percent_display") or "both"
        if shownMode ~= "session" and shownMode ~= "both" then
            session = nil
        end
        if shownMode ~= "weekly" and shownMode ~= "both" then
            week = nil
        end
        -- Same "sNN%" / "wNN%" text and pace tint as classic mode, after each ring.
        for _, pair in ipairs({ { w = session, prefix = "s" }, { w = week, prefix = "w" } }) do
            local w = pair.w
            local img = w and ringImage(w.percent, shared.paceColor(w.status, "primary"))
            if img then
                table.insert(children, ui.image({ path = img, width = RING_SIZE, height = RING_SIZE }))
                table.insert(children, ui.label({
                    text = `{pair.prefix}{shared.round(w.percent)}%`,
                    color = shared.paceColor(w.status, "on_surface"),
                }))
            end
        end
    end
    local container = vertical and ui.column or ui.row
    return container({ gap = 4, align = "center" }, children)
end

-- Tooltip rows for the live sessions, prepended in activity mode.
local function liveTooltipRows()
    if type(liveGroups) ~= "table" then
        return {}
    end
    local rows = {}
    for _, group in ipairs({ "waiting", "busy", "idle" }) do
        for _, s in ipairs(liveGroups[group] or {}) do
            local value = noctalia.tr("live_" .. (group == "waiting" and "needs_you" or group == "busy" and "working" or "idle"))
            if group == "waiting" and s.waitingFor ~= "" then
                value = `{value} · {s.waitingFor}`
            end
            table.insert(rows, { key = s.name, value = value })
        end
    end
    return rows
end

local function render()
    if displayMode() == "activity" then
        usedTree = true
        barWidget.render(renderActivity())
        local tip = usageTooltip()
        if type(tip) == "table" then
            local rows = liveTooltipRows()
            for _, row in ipairs(tip) do
                table.insert(rows, row)
            end
            tip = rows
        end
        barWidget.setTooltip(tip)
        return
    end

    if usedTree then
        local text = usageText()
        barWidget.render(ui.row({ gap = 4, align = "center" }, {
            ui.glyph({ name = noctalia.getConfig("glyph") or "robot", size = 16, color = open and "primary" or "on_surface" }),
            text ~= "" and ui.label({ text = text, color = shared.paceColor(worstPaceStatus(), "on_surface") }) or nil,
        }))
        barWidget.setTooltip(usageTooltip())
        return
    end

    barWidget.setGlyph(noctalia.getConfig("glyph"))
    barWidget.setGlyphColor(open and "primary" or "on_surface")

    local text = usageText()
    local worst = worstPaceStatus()
    if text ~= "" and (worst == "over" or worst == "over_quota") then
        text = `{text} ↑`
    end
    barWidget.setText(text)
    barWidget.setColor(shared.paceColor(worst, "on_surface"))
    barWidget.setTooltip(usageTooltip())
end

noctalia.state.watch("claude_cockpit_open", function(value)
    open = value == true
    render()
end)

noctalia.state.watch("usage", function(value)
    usage = value
    render()
end)

noctalia.state.watch("status", function(value)
    status = value
    render()
end)

noctalia.state.watch("live", function(value)
    if type(value) == "table" and type(value.groups) == "table" then
        liveGroups = value.groups
        render()
    end
end)

-- Activity mode keeps the service's live poll alive (it stops after a few
-- seconds without a stamp); classic mode costs nothing per tick.
function update()
    if displayMode() == "activity" then
        noctalia.state.set("live_wanted_at", os.time())
    end
end

function onConfigChanged()
    render()
end

noctalia.setUpdateInterval(2000)
if displayMode() == "activity" then
    noctalia.state.set("live_nonce", (tonumber(noctalia.state.get("live_nonce")) or 0) + 1)
end
liveGroups = type(noctalia.state.get("live")) == "table" and noctalia.state.get("live").groups or nil
render()
