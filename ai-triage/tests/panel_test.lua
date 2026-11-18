-- Host harness for malformed collection handling in panel.luau.

local function read(path)
    local file = assert(io.open(path, "r"))
    local source = file:read("*a")
    file:close()
    return source
end

local function loadPanel(entry, failure, config)
    local watchers = {}
    local isReport = type(entry) == "table" and type(entry.entries) == "table"
    local report = isReport and entry or entry ~= nil and { entries = { entry } } or nil
    local first = report ~= nil and report.entries[1] or nil
    local opened, copied, notifications = {}, {}, {}
    local values = {
        report = report,
        error = failure or { code = "", detail = "" },
        selected = isReport and entry.selected or first ~= nil and first.id or nil,
    }
    local cfg = config or {}
    local noctalia = {
        getConfig = function(key) return cfg[key] end,
        state = {
            get = function(key) return values[key] end,
            set = function(key, value) values[key] = value end,
            watch = function(key, fn) watchers[key] = fn end,
        },
        commandExists = function() return false end,
        nowMs = function() return 1000 end,
        tr = function(key, args)
            if key == "ui.quota_reset" and args then return key .. ": " .. args.time end
            return key
        end,
        string = {
            trim = function(value) return tostring(value):match("^%s*(.-)%s*$") end,
        },
        formatTime = function() return "12:00" end,
        timeFormat = function() return "%H:%M" end,
        runAsync = function(command)
            opened[#opened + 1] = command
            return true
        end,
        copyToClipboard = function(text, mime)
            copied[#copied + 1] = { text = text, mime = mime }
        end,
        notify = function() notifications[#notifications + 1] = true end,
    }
    local ui = setmetatable({}, {
        __index = function(_, kind)
            return function(props, children)
                return { kind = kind, props = props or {}, children = children or {} }
            end
        end,
    })
    local drawn = nil
    local panel = {
        render = function(tree) drawn = tree end,
        setWantsSecondTicks = function() end,
    }
    local sharedEnv = setmetatable({ noctalia = noctalia }, { __index = _G })
    local shared = assert(load(read("shared.luau"), "shared", "t", sharedEnv))()
    local env = setmetatable({
        noctalia = noctalia,
        ui = ui,
        panel = panel,
        require = function(path)
            assert(path == "./shared.luau")
            return shared
        end,
    }, { __index = _G })
    assert(load(read("panel.luau"), "panel", "t", env))()
    env.onOpen()
    local function publish(nextEntry)
        values.report = { entries = { nextEntry } }
        values.selected = nextEntry.id
        watchers.report(values.report)
        return drawn
    end
    return drawn, publish, env, opened, copied, notifications
end

local function collect(node, kind, found)
    found = found or {}
    if type(node) ~= "table" then return found end
    if node.kind == kind then found[#found + 1] = node end
    for _, child in ipairs(node.children or {}) do collect(child, kind, found) end
    for _, child in ipairs(node) do collect(child, kind, found) end
    return found
end

local function labels(node)
    local out = {}
    for _, label in ipairs(collect(node, "label")) do out[#out + 1] = tostring(label.props.text or "") end
    return out
end

local function has(list, wanted)
    for _, value in ipairs(list) do if value == wanted then return true end end
    return false
end

local malformedSections = {
    id = "openai",
    display_name = "Codex",
    plan = "Plan",
    status = "ready",
    metrics = {},
    sections = 42,
}
local sectionsOk = pcall(loadPanel, malformedSections)
assert(sectionsOk, "malformed sections should render as no usage")

local malformedSectionEntry = {
    id = "openai",
    display_name = "Codex",
    plan = "Plan",
    status = "ready",
    metrics = {},
    sections = { 42 },
}
local sectionEntryOk = pcall(loadPanel, malformedSectionEntry)
assert(sectionEntryOk, "malformed section entries should be ignored")

local malformedBody = {
    id = "openai",
    display_name = "Codex",
    plan = "Plan",
    status = "ready",
    metrics = {},
    sections = { { type = "block", label = "Credits", body = 42 } },
}
local bodyOk = pcall(loadPanel, malformedBody)
assert(bodyOk, "malformed block body should render as an empty block")

local malformedMetricsOk = pcall(loadPanel, {
    id = "openai", display_name = "Codex", status = "ready",
    metrics = { 42, { label = "Weekly", percent = 70, window_secs = 604800 } },
    sections = {},
})
assert(malformedMetricsOk, "status pills should ignore non-table metrics")

local rejectedProvider = {
    id = "anthropic",
    display_name = "Claude",
    plan = "Claude Pro",
    status = "ready",
    metrics = {},
    sections = {
        { type = "text", label = "HTTP 403", value = "authentication rejected" },
    },
}
local rejectedLabels = labels(loadPanel(rejectedProvider))
assert(has(rejectedLabels, "Claude") and has(rejectedLabels, "ui.diagnostic.cause.authentication"),
       "an authentication failure must keep its provider and cause visible")
assert(has(rejectedLabels, "claude auth login"), "Claude must show the command that restores sign-in")

local diagnosticCases = {
    { "credentials error: no access token; run `claude` to log in", "signed_out", "login" },
    { "HTTP 429: Rate limited", "rate_limited", "rate_limited" },
    { "HTTP 503: authentication service unavailable", "server", "server" },
    { "HTTP 403: forbidden", "permission", "permission" },
    { "network transport error: DNS lookup failed", "network", "network" },
    { "network transport error: request timed out", "timeout", "timeout" },
}
for _, case in ipairs(diagnosticCases) do
    local diagnosticTree = loadPanel({ id = "anthropic", display_name = "Claude", status = "error",
        error = case[1], metrics = { { label = "Weekly", percent = 95, window_secs = 604800 } } })
    local texts = labels(diagnosticTree)
    assert(has(texts, "Claude") and has(texts, "ui.diagnostic.cause." .. case[2]), "failed provider must explain its cause")
    assert(has(texts, "ui.diagnostic.action." .. case[3]) and has(texts, case[1]), "recommendation and CLI detail must be visible")
    assert(not has(texts, "95%"), "old quota must not appear current after the read fails")
    if case[2] ~= "signed_out" then
        assert(not has(texts, "claude auth login"), "transient and permission failures must not suggest logging in again")
    end
end

local signedOut = { id = "anthropic", display_name = "Claude", status = "error",
    error = "credentials error: no access token", metrics = {} }
local loginTree, publishLogin, _, loginOpened, loginCopied = loadPanel(signedOut)
assert(#loginOpened == 0, "rendering a sign-in hint must not run a command")
for _, button in ipairs(collect(loginTree, "button")) do
    if button.props.text == "ui.diagnostic.copy_command" then button.props.onClick() break end
end
assert(#loginCopied == 1 and loginCopied[1].text == "claude auth login", "the copy action must supply the recommended command")
local recoveredLabels = labels(publishLogin({ id = "anthropic", display_name = "Claude", status = "ready",
    metrics = { { label = "Session", percent = 10, window_secs = 18000 } } }))
assert(not has(recoveredLabels, "claude auth login") and not has(recoveredLabels, "ui.diagnostic.cause.signed_out"),
    "a successful read must remove the old sign-in warning")
assert(not has(labels(loadPanel(signedOut, nil, { hidden_services = "anthropic" })), "Claude"),
    "explicitly hidden providers must remain hidden even after authentication failure")

local globalErrorLabels = labels(loadPanel({ id = "openai", display_name = "Codex", status = "ready",
    metrics = { { label = "Session", percent = 20, window_secs = 18000 } } },
    { code = "timed_out", detail = "quota command exceeded its deadline" }))
assert(has(globalErrorLabels, "ui.error.timed_out") and has(globalErrorLabels, "quota command exceeded its deadline"),
    "a failed refresh must remain visible alongside the earlier report")
assert(has(labels(loadPanel({ entries = {} }, { code = "timed_out", detail = "empty previous report" })),
    "ui.error.timed_out"), "an empty earlier report must not conceal a failed refresh")

local normalReport = {
    entries = {
        {
            id = "google",
            display_name = "Gemini",
            plan = "Advanced",
            status = "ready",
            metrics = {
                { label = "Session", percent = 20, window_secs = 18000 },
                { label = "Weekly", percent = 50, window_secs = 604800 },
            },
            sections = {
                { type = "text", label = "Reset", value = "Reset in 5d" },
            },
        },
    },
}
local renderedTree = loadPanel(normalReport)
local scrollElements = collect(renderedTree, "scroll")
assert(#scrollElements >= 3, "expected at least 3 ui.scroll elements for the 3 columns, found " .. tostring(#scrollElements))

-- Typography scaling verification in panel
local renderedHuge = loadPanel(normalReport, nil, { font_scale = "huge" })
local hugeLabels = collect(renderedHuge, "label")
local foundTitleHuge = false
for _, l in ipairs(hugeLabels) do
    if l.props.text == "ui.title" or l.props.text == "AI Triage" then
        assert(l.props.fontSize == 25, "Huge preset title fontSize must be 25, got " .. tostring(l.props.fontSize))
        foundTitleHuge = true
    end
end
assert(foundTitleHuge, "AI Triage title label must be present in huge panel")

local renderedCompact = loadPanel(normalReport, nil, { font_scale = "compact" })
local compactLabels = collect(renderedCompact, "label")
local foundTitleCompact = false
for _, l in ipairs(compactLabels) do
    if l.props.text == "ui.title" or l.props.text == "AI Triage" then
        assert(l.props.fontSize == 16, "Compact preset title fontSize must be 16, got " .. tostring(l.props.fontSize))
        foundTitleCompact = true
    end
end
assert(foundTitleCompact, "AI Triage title label must be present in compact panel")

-- Session estimates are rounded only at presentation; percentages use precise ratios.
local function quotaEntry(id, name, session, weekly)
    return {
        id = id, display_name = name, status = "ready", sections = {},
        metrics = {
            { label = "Session", percent = session, window_secs = 18000,
              reset_at = "2030-01-01T05:00:00Z" },
            { label = "Weekly", percent = weekly, window_secs = 604800,
              reset_at = "2030-01-07T00:00:00Z" },
        },
    }
end
local function hasTooltip(tree, text)
    for _, row in ipairs(collect(tree, "row")) do
        if row.props.tooltip == text then return true end
    end
    return false
end
for _, case in ipairs({
    { "openai", "Codex", "~6s/w", 16 },
    { "claude-oss", "Claude & GPT OSS", "~3s/w", 40 },
    { "anthropic", "Claude", "~7s/w", 14 },
    { "gemini", "Gemini", "~8s/w", 13 },
}) do
    local tree = loadPanel(quotaEntry(case[1], case[2], 0, 0))
    assert(has(labels(tree), case[3]), "session badge must display a whole number for " .. case[1])
    local roundedSessions = case[3]:match("~(%d+)s/w")
    assert(hasTooltip(tree, "Gearing: ~" .. roundedSessions .. " full 5h sessions per week (1 session burns ~" .. case[4] .. "% weekly quota)"),
        "tooltip must round session estimates while preserving precise weekly burn for " .. case[1])
end
local _, publishQuota = loadPanel(quotaEntry("openai", "Codex", 0, 0))
local calibratedTree = publishQuota(quotaEntry("openai", "Codex", 31, 5)) -- K = 6.2
assert(has(labels(calibratedTree), "~6s/w"), "calibrated ratios must also display whole numbers")
assert(hasTooltip(calibratedTree, "Gearing: ~6 full 5h sessions per week (1 session burns ~16% weekly quota · calibrated from observed usage)"),
    "calibration must retain 6.2 internally: rounding it to 6 would incorrectly display 17% weekly burn")

-- Reset credits: no claim right before the weekly renewal, a claim once a spent week has days left.
local function isoIn(seconds) return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + math.floor(seconds)) end
local function mentions(list, needle)
    for _, value in ipairs(list) do if value:find(needle, 1, true) then return true end end
    return false
end
local function creditEntry(id, name, weekly, renewHours, credits)
    local list, lines = {}, {}
    for i, hours in ipairs(credits) do
        list[i] = { title = "Reset " .. i, expires_at = isoIn(hours * 3600) }
        lines[i] = "Reset " .. i .. " · expires in " .. math.floor(hours / 24) .. "d"
    end
    return {
        id = id, display_name = name, status = "ready",
        metrics = {
            { label = "Session", percent = 19, window_secs = 18000, reset_at = isoIn(4.7 * 3600) },
            { label = "Weekly", percent = weekly, window_secs = 604800, reset_at = isoIn(renewHours * 3600) },
        },
        reset_credits = { available = #credits, credits = list },
        sections = { { type = "block", label = "Reset credits", body = lines } },
    }
end
local calendarConfig = { schedule_aware_triage = false }

-- Claude at 97% renewing in 5h, colliding with Codex credits: hold, advance from the renewal
local nearRenewalReport = { entries = {
    creditEntry("anthropic", "Claude", 97, 5.2, { 236 }),
    creditEntry("openai", "Codex", 15, 132, { 238, 405, 600 }),
} }
local holdLabels = labels(loadPanel(nearRenewalReport, nil, calendarConfig))
assert(not has(holdLabels, "Optimal Reset Window!") and not has(holdLabels, "CLAIM NOW") and not has(holdLabels, "Claim Reset"),
    "a reset 5h before the weekly renewal must not be recommended")
assert(not mentions(holdLabels, "Advance reset:"), "no fast-track when the week ends in 5h")
assert(mentions(holdLabels, "1. Advance Claude after its renewal in 5h"), "the advance must start from the renewal")
assert(mentions(holdLabels, "Keep the reset: renews in 5h"), "the Claude credit must say why it is kept")

-- A spent week with four days left: claim now
local spentLabels = labels(loadPanel({ entries = { creditEntry("anthropic", "Claude", 100, 96, { 236 }) } }, nil, calendarConfig))
assert(has(spentLabels, "Optimal Reset Window!") and has(spentLabels, "CLAIM NOW") and has(spentLabels, "Claim Reset"),
    "a spent week with days left must recommend the claim")
assert(mentions(spentLabels, "claim now: ~100% of a week back"), "the claim must state what it buys back")

-- Credit pacing names its real deadline and exposes the available-time estimate.
local datedCredit = creditEntry("openai", "Codex", 60, 168, { 24 })
local datedTree, _, datedEnv = loadPanel(datedCredit, nil, calendarConfig)
local datedShared = datedEnv.require("./shared.luau")
local expiry = datedShared.parseIso(datedCredit.reset_credits.credits[1].expires_at)
local deadlineTip = false
for _, row in ipairs(collect(datedTree, "row")) do
    local tip = row.props.tooltip or ""
    if tip:find("Claim before " .. os.date("%b %d %H:%M %Z", expiry), 1, true)
        and tip:find("h needed /", 1, true) and tip:find("h available", 1, true) then deadlineTip = true end
end
assert(deadlineTip and has(labels(datedTree), "Fast-track"),
    "fast-track must explain the real credit deadline and required/available time")
local shortTree = loadPanel(creditEntry("openai", "Codex", 10, 168, { 5.5 }), nil, calendarConfig)
local limitedTime = false
for _, row in ipairs(collect(shortTree, "row")) do
    if tostring(row.props.tooltip or ""):find("95% may be unreachable", 1, true) then limitedTime = true end
end
assert(limitedTime, "an infeasible 95% target must not be presented as assured")

-- Weekly Reset Schedule visibility in Column 3
assert(has(holdLabels, "Weekly Reset Schedule"), "Column 3 must display the Weekly Reset Schedule")
assert(has(holdLabels, "0d 05h") and has(holdLabels, "5d 12h"), "Column 3 schedule rows must display remaining time as Xd Yh in its own cell")
assert(has(holdLabels, "12:00"), "Column 3 schedule rows must display reset clock in its own monospace cell")
assert(not mentions(holdLabels, " : "), "Column 3 schedule rows must not contain ' : '")

-- Imminent weekly renewal alert in Column 3 when unspent quota is at risk
local imminentReport = { entries = {
    creditEntry("openai", "Codex", 60, 2.5, { 238 }),
} }
local imminentLabels = labels(loadPanel(imminentReport, nil, calendarConfig))
assert(has(imminentLabels, "Weekly Reset Imminent!"), "imminent weekly renewal with free quota must trigger Column 3 alert")
assert(mentions(imminentLabels, "resets in 2.5h"), "alert must display remaining hours")
-- Service & Model Filtering in Panel (hide_claude_oss)
local panelAgyReport = {
    entries = {
        {
            id = "antigravity",
            display_name = "Antigravity",
            status = "ready",
            metrics = {
                { label = "Gemini", percent = 20, window_secs = 18000, reset_at = isoIn(4 * 3600) },
                { label = "Claude & GPT OSS", percent = 70, window_secs = 18000, reset_at = isoIn(3 * 3600) },
                { label = "Gemini", percent = 45, window_secs = 604800, reset_at = isoIn(96 * 3600) },
                { label = "Claude & GPT OSS", percent = 85, window_secs = 604800, reset_at = isoIn(80 * 3600) },
            },
        },
        creditEntry("anthropic", "Claude", 30, 100, {}),
    },
}

-- 1. Default (hide_claude_oss = false): Both Gemini and Claude & GPT OSS are rendered
local defaultPanelLabels = labels(loadPanel(panelAgyReport, nil, { hide_claude_oss = false }))
assert(has(defaultPanelLabels, "Gemini"), "Gemini should be rendered in panel by default")
assert(has(defaultPanelLabels, "Claude & GPT OSS"), "Claude & GPT OSS should be rendered in panel by default")
assert(has(defaultPanelLabels, "Claude"), "Anthropic Claude should be rendered in panel by default")

-- 2. hide_claude_oss = true: Only Gemini and Anthropic Claude are rendered, Claude & GPT OSS is hidden
local filteredPanelLabels = labels(loadPanel(panelAgyReport, nil, { hide_claude_oss = true }))
assert(has(filteredPanelLabels, "Gemini"), "Gemini must remain visible in panel when Claude OSS is hidden")
assert(not has(filteredPanelLabels, "Claude & GPT OSS"), "Claude & GPT OSS must NOT be rendered anywhere in panel when hidden")
assert(has(filteredPanelLabels, "Claude"), "Anthropic Claude Pro must NOT be hidden in panel")

-- Unexpected changes remain visible for 24h, with explicit before/after dates.
local resetEntry = creditEntry("openai", "Codex", 50, 2.5, {})
local weekly = resetEntry.metrics[2]
weekly.reset_observation = { at = os.time(), source = "ai-usagebar", event = {
    kind = "early_renewal", at = os.time(), previous_reset_at = os.time() + 3600,
    reset_at = os.time() + 7200,
} }
local resetTree = loadPanel(resetEntry)
local resetLabels = labels(resetTree)
assert(has(resetLabels, "Weekly reset changed") and has(resetLabels, "Codex · Early renewal observed")
    and mentions(resetLabels, "Before:") and mentions(resetLabels, "Now announced:"),
    "a recent unexpected renewal must show a compact before/after notice")
local tips = {}
for _, row in ipairs(collect(resetTree, "row")) do tips[#tips + 1] = row.props.tooltip or "" end
assert(mentions(tips, "Early renewal detected") and mentions(tips, "Next weekly reset announced"),
    "both the clock and schedule must explain provider dates on hover")
local event = weekly.reset_observation.event
event.kind = "schedule_changed"
assert(has(labels(loadPanel(resetEntry)), "Codex · Renewal not confirmed"),
    "a date-only change must not claim a renewal")
event.at = os.time() - 86401
assert(not has(labels(loadPanel(resetEntry)), "Weekly reset changed"), "the notice must disappear after 24h")
event.detected_at = os.time()
assert(has(labels(loadPanel(resetEntry)), "Weekly reset changed"), "the notice starts at detection, not old reading time")
event.expected = true
assert(not has(labels(loadPanel(resetEntry)), "Weekly reset changed"), "scheduled rollovers must not create unexpected-change alerts")
event.expected, event.floating = false, true
assert(not has(labels(loadPanel(resetEntry)), "Weekly reset changed"), "idle floating timers must not create unexpected-change alerts")
event.floating, event.kind = false, "renewal"
assert(not has(labels(loadPanel(resetEntry)), "Weekly reset changed"), "normal renewals must stay quiet")

weekly.reset_at = isoIn(-60)
local pendingLabels = labels(loadPanel(resetEntry))
assert(has(pendingLabels, "Check") and has(pendingLabels, "Pending confirmation"),
    "expired schedules need a compact confirmation state")
assert(not has(pendingLabels, "0d 00h") and not has(pendingLabels, "7d 00h"),
    "an expired weekly deadline must not turn into a new countdown")
assert(not has(pendingLabels, "Weekly Reset Imminent!"), "unconfirmed renewals must not generate sprint alerts")
weekly.reset_at = nil
assert(has(labels(loadPanel(resetEntry)), "Pending confirmation"), "missing dates need confirmation too")
weekly.reset_at = isoIn(2.5 * 3600)
weekly.reset_observation.at = os.time() - 1800
local staleLabels = labels(loadPanel(resetEntry))
assert(has(staleLabels, "~0d 02h"), "old countdowns need a discreet approximation marker")
assert(not has(staleLabels, "Weekly Reset Imminent!"), "old readings must not create urgency")

io.write("ok: panel rendering, typography, and rounded session estimates with precise calibration\n")
