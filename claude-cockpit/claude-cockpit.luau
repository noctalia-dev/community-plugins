--!nonstrict
-- Claude Cockpit — bar widget: toggles the panel, and shows an optional
-- "sNN% wMM%" usage badge (session/weekly rate windows) tinted and
-- arrow-flagged the same way jrohland/claudecode's pill is. No ring — that
-- needs plugin_api 26 (noctalia.getSetting) for a number the panel's Usage
-- tab already shows one click away.
--
-- Left click is a [widget.actions] default in plugin.toml, not wired here,
-- so the user can remap the gesture.

local shared = require("./shared.luau")

local open = false
local usage = noctalia.state.get("usage")
local status = noctalia.state.get("status")

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

local function render()
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

render()
