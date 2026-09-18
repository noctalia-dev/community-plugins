--!nonstrict
-- Claude Cockpit — helpers shared by service.luau, sessions.luau and
-- panel.luau (require("./shared.luau"), plugin_api >= 22).
--
-- Two families of helper live here: the usage formatters/pacing model (a
-- trimmed port of jrohland/claudecode's shared.luau — MIT, see README Notes
-- — with the multi-profile/CCS projection stripped out since this plugin
-- only ever reads the default ~/.claude account) and the process-spawning
-- helpers (shellQuote, launchTerminal, openEditor) the sessions/CLAUDE.md
-- tabs use.

local M = {}

function M.tr(key, args)
    return noctalia.tr(key, args)
end

-- ── process spawning ─────────────────────────────────────────────────────

function M.shellQuote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

function M.trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Noctalia's own terminal discovery ($TERMINAL, then the usual emulators) is
-- used unless a terminal is configured. A configured one is wired up the
-- same way the host does it: `<term> -e/-- sh -lc <cmd>`, with the
-- separator the few GTK terminals need instead of -e. Ported 1:1 from
-- topgrade-wrapper/service.luau.
function M.launchTerminal(cmd)
    local term = M.trim(noctalia.getConfig("terminal") or "")
    if term == "" then
        return noctalia.runInTerminal(cmd)
    end
    local first = term:match("^%S+") or term
    local bin = first:match("([^/]+)$") or first
    local separator = (bin == "gnome-terminal" or bin == "kgx" or bin == "ptyxis") and "--" or "-e"
    return noctalia.runAsync(term .. " " .. separator .. " sh -lc " .. M.shellQuote(cmd))
end

-- Resolve which editor binary to open a CLAUDE.md with: the configured
-- override, or the first of `code`/`zed` that is actually installed. No
-- $EDITOR/$VISUAL fallback on purpose — that is almost always a terminal
-- editor (vim, nano), and opening one through runAsync with no tty attached
-- would just spawn a process that immediately fails.
function M.resolveEditor()
    local configured = M.trim(noctalia.getConfig("editor_command") or "")
    if configured ~= "" then
        return configured
    end
    if noctalia.commandExists("code") then
        return "code"
    end
    if noctalia.commandExists("zed") then
        return "zed"
    end
    return nil
end

-- Opens `path` in the resolved editor, as a direct argv exec (plugin_api >=
-- 24) — a GUI editor, never inside a terminal. Reports why it could not
-- launch, once, through noctalia.notifyError, instead of failing silently.
function M.openInEditor(path)
    local bin = M.resolveEditor()
    if bin == nil then
        noctalia.notifyError(M.tr("title"), M.tr("err_no_editor"))
        return false
    end
    -- A configured value may itself carry arguments ("code --new-window");
    -- only the first word is the binary noctalia.commandExists checked.
    local args = {}
    for word in bin:gmatch("%S+") do
        table.insert(args, word)
    end
    table.insert(args, path)
    local ok = noctalia.runAsync(args)
    if not ok then
        noctalia.notifyError(M.tr("title"), M.tr("err_editor_failed"))
    end
    return ok
end

-- ── usage formatters (trimmed port of jrohland/claudecode's shared.luau) ──

function M.formatTokens(n)
    n = tonumber(n) or 0
    if n >= 1000000000 then
        return string.format("%.1fB", n / 1000000000)
    end
    if n >= 1000000 then
        return string.format("%.1fM", n / 1000000)
    end
    if n >= 1000 then
        return string.format("%.1fK", n / 1000)
    end
    return tostring(math.floor(n + 0.5))
end

-- prefix/suffix for each currency the "currency" setting offers; keys match
-- both the setting's option values and get-claude-usage's currency_rates keys (uppercased).
M.CURRENCY_SYMBOLS = {
    usd = { prefix = "$", suffix = "" },
    eur = { prefix = "", suffix = " €" },
    gbp = { prefix = "£", suffix = "" },
    jpy = { prefix = "¥", suffix = "" },
    cny = { prefix = "CN¥", suffix = "" },
    chf = { prefix = "", suffix = " CHF" },
    aud = { prefix = "A$", suffix = "" },
    cad = { prefix = "C$", suffix = "" },
    inr = { prefix = "₹", suffix = "" },
}

function M.currencyMode()
    local c = noctalia.getConfig("currency")
    if type(c) == "string" and M.CURRENCY_SYMBOLS[c] then
        return c
    end
    return M.tr("currency.auto_default")
end

-- `rates` is the whole currency_rates object (USD -> currency code -> rate);
-- looked up by the configured currency, USD needs none.
function M.formatCost(usd, rates)
    usd = tonumber(usd) or 0
    local mode = M.currencyMode()
    -- Falls back to USD, symbol included, when no rate is available yet —
    -- never the target currency's symbol around a still-USD amount.
    local sym = M.CURRENCY_SYMBOLS.usd
    local n = usd
    if mode ~= "usd" and type(rates) == "table" then
        local rate = tonumber(rates[mode:upper()])
        if rate and rate > 0 then
            n = usd * rate
            sym = M.CURRENCY_SYMBOLS[mode] or M.CURRENCY_SYMBOLS.usd
        end
    end
    if n >= 1000 then
        return `{sym.prefix}{string.format("%.1f", n / 1000)}K{sym.suffix}`
    end
    if n >= 100 then
        return `{sym.prefix}{math.floor(n + 0.5)}{sym.suffix}`
    end
    if n >= 10 then
        return `{sym.prefix}{string.format("%.1f", n)}{sym.suffix}`
    end
    return `{sym.prefix}{string.format("%.2f", n)}{sym.suffix}`
end

function M.shortModelName(name)
    if type(name) ~= "string" or #name == 0 then
        return tostring(name)
    end
    return name:sub(1, 1):upper() .. name:sub(2)
end

function M.round(x)
    return math.floor((tonumber(x) or 0) + 0.5)
end

-- Words that name a plan, in the form they should be shown.
local PLAN_WORDS = {
    free = "Free", pro = "Pro", max = "Max", team = "Team",
    enterprise = "Enterprise", business = "Business",
}

local function titleCase(word)
    if word:match("^%d") then
        return word
    end
    return word:sub(1, 1):upper() .. word:sub(2)
end

-- "team" + "default_claude_max_5x" → "Claude Team 5x". See
-- jrohland/claudecode/shared.luau for the full derivation this ports.
function M.planName(subscription, tier)
    local function clean(v)
        if type(v) ~= "string" then
            return nil
        end
        v = v:lower()
        if v == "" or v == "unknown" then
            return nil
        end
        return v
    end

    subscription, tier = clean(subscription), clean(tier)
    if not subscription and not tier then
        return "Claude Code"
    end

    local rest = tier or ""
    rest = rest:gsub("^default_", ""):gsub("^t%d+_", ""):gsub("^claude_", "")

    local words, multiplier, family = {}, nil, nil
    for word in rest:gmatch("[^_]+") do
        if word:match("^%d+x$") then
            multiplier = word
        else
            if PLAN_WORDS[word] and not family then
                family = word
            end
            table.insert(words, word)
        end
    end

    local plan = PLAN_WORDS[subscription or ""] or (family and PLAN_WORDS[family])
    if not plan then
        if #words > 0 then
            local shown = {}
            for _, w in words do
                table.insert(shown, titleCase(w))
            end
            plan = table.concat(shown, " ")
        elseif subscription then
            plan = titleCase(subscription)
        end
    end

    local parts = { "Claude" }
    if plan and plan ~= "" then
        table.insert(parts, plan)
    end
    if multiplier then
        table.insert(parts, multiplier)
    end
    return table.concat(parts, " ")
end

-- Seconds the local clock is ahead of UTC (DST-aware for the current instant).
function M.tzOffset()
    local now = os.time()
    return os.difftime(now, os.time(os.date("!*t", now)))
end

function M.resetEpoch(iso)
    if type(iso) ~= "string" or iso == "" then
        return nil
    end
    local y, mo, d, h, mi, s = iso:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not y then
        return nil
    end
    local asLocal = os.time({
        year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
    })
    if not asLocal then
        return nil
    end
    return asLocal + M.tzOffset()
end

function M.formatCountdown(iso)
    local epoch = M.resetEpoch(iso)
    if not epoch then
        return nil
    end
    local secs = epoch - os.time()
    if secs <= 0 then
        return M.tr("resetting")
    end
    local d = secs // 86400
    local h = (secs % 86400) // 3600
    local m = (secs % 3600) // 60
    if d > 0 then
        return `{d}d {h}h {m}m`
    end
    if h > 0 then
        return `{h}h {m}m`
    end
    return `{m}m`
end

-- Same countdown, narrowed for somewhere with a column to fit: once a window
-- is days out the minutes are noise, and the bar tooltip's value column is
-- not wide enough to spend eight characters on them.
function M.formatCountdownShort(iso)
    local epoch = M.resetEpoch(iso)
    if not epoch then
        return nil
    end
    local secs = epoch - os.time()
    if secs <= 0 then
        return M.tr("resetting")
    end
    local d = secs // 86400
    if d > 0 then
        return `{d}d {(secs % 86400) // 3600}h`
    end
    local h = secs // 3600
    if h > 0 then
        return `{h}h {(secs % 3600) // 60}m`
    end
    return `{secs // 60}m`
end

-- 1-based index into the Mon..Sun daily arrays for today (Lua wday: Sun=1).
function M.todayIndex()
    local t = os.date("*t")
    return (t.wday == 1) and 7 or (t.wday - 1)
end

M.FIVE_HOUR_SECS = 5 * 3600
M.SEVEN_DAY_SECS = 7 * 86400
M.PACE_MARGIN = 5

M.SEVERITY = { unknown = 0, under = 0, on = 0, over = 1, over_quota = 2 }

-- Are we burning quota faster than the clock? Windows are treated as
-- fixed-length and elapsed time is derived from the reset timestamp — an
-- approximation of Anthropic's rolling limits, good enough as a cue.
function M.pace(util, resetIso, durationSecs)
    util = tonumber(util) or 0
    local epoch = M.resetEpoch(resetIso)
    if not epoch then
        if util >= 100 then
            return { timeFrac = 1, delta = util, status = "over_quota" }
        end
        return { status = "unknown" }
    end
    local remaining = epoch - os.time()
    local timeFrac = (durationSecs - remaining) / durationSecs
    if timeFrac < 0 then
        timeFrac = 0
    elseif timeFrac > 1 then
        timeFrac = 1
    end
    local delta = util - timeFrac * 100
    local status
    if util >= 100 then
        status = "over_quota"
    elseif delta >= M.PACE_MARGIN then
        status = "over"
    elseif delta <= -M.PACE_MARGIN then
        status = "under"
    else
        status = "on"
    end
    return { timeFrac = timeFrac, delta = delta, status = status }
end

function M.paceLabel(p)
    if p.status == "over_quota" then
        return M.tr("pace.over_quota")
    end
    if p.status == "over" then
        return `{M.round(p.delta)}% {M.tr("pace.over")}`
    end
    if p.status == "under" then
        return `{M.round(-p.delta)}% {M.tr("pace.under")}`
    end
    if p.status == "on" then
        return M.tr("pace.on")
    end
    return nil
end

function M.paceColor(status, calm)
    if status == "over_quota" then
        return "error"
    end
    if status == "over" then
        return "tertiary"
    end
    return calm
end

M.SEVERITY_RANK = { normal = 0, high = 1, critical = 2 }

local function severityStatus(severity)
    if severity == "critical" then
        return "over_quota"
    end
    if severity == "high" then
        return "over"
    end
    return nil
end

local function windowLabel(row)
    local model = row.model
    if type(model) == "string" and model ~= "" then
        return M.tr("window.scoped", { model = model })
    end
    if row.kind == "session" then
        return M.tr("window.session")
    end
    if row.group == "weekly" then
        return M.tr("window.weekly")
    end
    return M.tr("window.other")
end

-- → { { id, label, percent, resetIso, durationSecs, isActive, pace, status }, … }
function M.windows(usage)
    if type(usage) ~= "table" then
        return {}
    end

    local rows = {}
    if type(usage.limits) == "table" and #usage.limits > 0 then
        for _, row in usage.limits do
            if type(row) == "table" then
                local secs = (row.kind == "session") and M.FIVE_HOUR_SECS or M.SEVEN_DAY_SECS
                table.insert(rows, {
                    kind = row.kind, model = row.model, group = row.group,
                    percent = tonumber(row.percent) or 0,
                    resetIso = row.resets_at, durationSecs = secs,
                    severity = row.severity, isActive = row.is_active == true,
                })
            end
        end
    else
        rows = {
            { kind = "session", group = "session", percent = tonumber(usage.five_hour_util) or 0,
              resetIso = usage.five_hour_reset, durationSecs = M.FIVE_HOUR_SECS, isActive = false },
            { kind = "weekly_all", group = "weekly", percent = tonumber(usage.seven_day_util) or 0,
              resetIso = usage.seven_day_reset, durationSecs = M.SEVEN_DAY_SECS, isActive = false },
        }
    end

    for i, row in rows do
        row.id = `{row.kind or "window"}:{row.model or ""}:{i}`
        row.label = windowLabel(row)
        row.pace = M.pace(row.percent, row.resetIso, row.durationSecs)
        local vendor = severityStatus(row.severity)
        if vendor and (M.SEVERITY[vendor] or 0) > (M.SEVERITY[row.pace.status] or 0) then
            row.status = vendor
        else
            row.status = row.pace.status
        end
    end
    return rows
end

function M.formatResetClock(iso, withDay)
    local epoch = M.resetEpoch(iso)
    if not epoch then
        return nil
    end
    local fmt = "%H:%M"
    local ok, shellFmt = pcall(noctalia.timeFormat)
    if ok and type(shellFmt) == "string" then
        local inner = shellFmt:match("{:(.-)}")
        if inner and inner ~= "" then
            fmt = inner
        end
    end
    if withDay and epoch - os.time() >= 86400 then
        return os.date(`%a {fmt}`, epoch)
    end
    return os.date(fmt, epoch)
end

-- Sorted { {name, tokens}, … } from a week_models map, desc.
function M.modelList(weekModels)
    local list = {}
    if type(weekModels) ~= "table" then
        return list
    end
    for name, tok in weekModels do
        table.insert(list, { name = name, tokens = tonumber(tok) or 0 })
    end
    table.sort(list, function(a, b)
        return a.tokens > b.tokens
    end)
    return list
end

-- Ask the service for an out-of-band fetch (it watches refresh_nonce).
function M.requestUsageRefresh()
    local nonce = noctalia.state.get("refresh_nonce")
    noctalia.state.set("refresh_nonce", (tonumber(nonce) or 0) + 1)
end

return M
