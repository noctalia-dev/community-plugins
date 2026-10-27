--!nonstrict
-- AI Triage dashboard: Side-by-side 3-column view of Rolling 5h Sessions,
-- Weekly 7d Quotas, and Reset Credits / Stagger Strategy.

local report = nil
local polling = false
local refreshQueued = false

local shared = require("./shared.luau")
local parseIso = shared.parseIso
local countdown = shared.countdown
local ratio = shared.ratio
local severityRole = shared.severityRole
local isSessionStarted = shared.isSessionStarted
local calculateModelTriageScore = shared.calculateModelTriageScore
local calculateActiveHours = shared.calculateActiveHours
local getScheduleConfig = shared.getScheduleConfig
local getModelGearing = shared.getModelGearing
local elapsedPercent = shared.elapsedPercent
local requestRefresh = shared.requestRefresh
local unavailable = shared.unavailable
local NO_FAILURE, asFailure = shared.NO_FAILURE, shared.asFailure
local kickstartTarget = shared.kickstartTarget
local collectModelItems = shared.collectModelItems
local collectResetCredits = shared.collectResetCredits
local providerDashboard = shared.providerDashboard
local getTypography = shared.getTypography

local failure = NO_FAILURE

local CARD = {
    gap = 8,
    padding = 12,
    radius = 11,
    fill = "surface_container/0.88",
    border = "outline_variant/0.20",
    borderWidth = 1,
}

local function cardStyle(gap, fill, border, padding)
    return {
        gap = gap or CARD.gap,
        padding = padding or CARD.padding,
        radius = CARD.radius,
        fill = fill or CARD.fill,
        border = border or CARD.border,
        borderWidth = CARD.borderWidth,
    }
end

local function entries()
    return shared.entries(report)
end

local function panelCandidates()
    if type(report) ~= "table" or type(report.entries) ~= "table" then return {} end
    local list = {}
    for _, entry in ipairs(report.entries) do
        -- A provider included by the CLI remains visible after authentication
        -- failures. Only the user's explicit visibility filters hide it.
        if type(entry) == "table" then
            local id = entry.id
            local name = entry.display_name or entry.name or entry.id
            if not shared.isModelHidden(id, name) then
                list[#list + 1] = entry
            end
        end
    end
    return list
end

-- ── Detail line parsing ───────────────────────────────────────────────────────
-- "Resets in 1h 58m · 60% elapsed · 30pts ahead". The reset half is already in
-- `reset_at`; what is left is the pace, and some details carry no reset at all.
local function plainDetail(detail)
    local head = tostring(detail or ""):match("^[^·]*") or ""
    head = noctalia.string.trim(head)
    if head:lower():find("^resets?%s+in") then return "" end
    return head
end

-- ── Error Block ───────────────────────────────────────────────────────────────
-- The CLI's own words come last and smallest, where a bug report can quote them.
local function errorBlock(typo)
    local fs = typo and typo.fontSize or function(s) return s end
    local gs = typo and typo.glyphSize or function(s) return s end
    local key = "ui.error." .. failure.code
    local children = {
        ui.row({ gap = 6, align = "center" }, {
            ui.glyph({ name = "alert-circle", size = gs(18), color = "error" }),
            ui.label({ text = noctalia.tr(key), fontSize = fs(12), fontWeight = "bold", color = "error" }),
        }),
        ui.label({ text = noctalia.tr(key .. "_hint"), fontSize = fs(11), color = "on_surface_variant" }),
    }

    if failure.detail ~= "" then
        children[#children + 1] = ui.label({
            text = failure.detail, fontSize = fs(11), color = "on_surface_variant", maxLines = 3,
        })
    end

    local actions = {
        ui.button({
            text = noctalia.tr("ui.retry"), glyph = "refresh",
            variant = "outline", controlSize = "sm",
            enabled = not polling,
            onClick = requestRefresh,
        }),
    }

    if failure.code == "not_installed" then
        children[#children + 1] = ui.label({
            text = "https://github.com/akitaonrails/ai-usagebar",
            fontSize = fs(11), color = "on_surface", maxLines = 2,
        })
        actions[#actions + 1] = ui.button({
            text = noctalia.tr("ui.install"), glyph = "brand-github",
            variant = "outline", controlSize = "sm",
            onClick = function()
                if type(noctalia.runAsync) == "function" then
                    noctalia.runAsync("xdg-open 'https://github.com/akitaonrails/ai-usagebar'")
                end
            end,
        })
    end
    children[#children + 1] = ui.row({ gap = 6, align = "center" }, actions)

    return ui.column({ gap = 8, padding = 12, radius = 14,
                       fill = "error/0.06", border = "error/0.12", borderWidth = 1 }, children)
end

-- ── Presentation & Triage Formatting ──────────────────────────────────────────

local function formatResetTime(metric, windowLabel, isStarted)
    local isWeekly = windowLabel == "7d"
    if isWeekly and shared.weeklyResetStatus(metric) == "pending" then return "Pending confirmation" end
    local active = isWeekly or isStarted or isSessionStarted(metric)
    if not active then
        return ""
    end
    local at = parseIso(metric and metric.reset_at)
    if at == nil then
        return countdown(metric)
    end
    if not isWeekly and at <= os.time() then
        return ""
    end
    local clock = noctalia.formatTime(noctalia.timeFormat(), at)
    if isWeekly then
        local weekday = os.date("%a", at)
        local day = os.date("%d", at)
        local month = os.date("%b", at)
        local activeHours = calculateActiveHours(os.time(), at)
        local activeStr = ""
        if activeHours and activeHours > 0 and activeHours <= 24.0 and (at - os.time()) <= 86400 * 2 then
            activeStr = string.format(" (~%.1fh active)", activeHours)
        end
        return string.format("%s, %s %s %s%s", weekday, month, day, clock, activeStr)
    else
        if os.date("%Y-%m-%d", at) == os.date("%Y-%m-%d") then
            return clock
        else
            local weekday = os.date("%a", at)
            return string.format("%s %s", weekday, clock)
        end
    end
end

local function countdownColor(metric, isStarted)
    local active = isStarted or isSessionStarted(metric)
    if not active then
        return "on_surface_variant"
    end
    local at = parseIso(metric and metric.reset_at)
    local window = tonumber(metric and metric.window_secs) or 18000
    if at == nil or at <= os.time() then
        return "on_surface_variant"
    end

    local remaining = math.max(0, at - os.time())
    local r = remaining / window

    if r > 0.60 then
        return "#4ade80" -- Verde (>60%)
    elseif r > 0.30 then
        return "#38bdf8" -- Azul (30%-60%)
    elseif r > 0.12 then
        return "#facc15" -- Amarelo (12%-30%)
    elseif r > 0.04 then
        return "#fb923c" -- Laranxa (4%-12%)
    else
        return "#f87171" -- Vermello (<4%)
    end
end

local function calculateElapsed(metric, windowLabel, isStarted)
    if metric == nil then return nil end
    local isWeekly = windowLabel == "7d"
    local active = isWeekly or isStarted or isSessionStarted(metric)
    if not active then
        return nil
    end
    local fromDetail = elapsedPercent(metric.detail)
    if fromDetail ~= nil then
        return math.min(100, math.max(0, fromDetail))
    end
    local at = parseIso(metric.reset_at)
    local window = tonumber(metric.window_secs)
        or (isWeekly and 604800 or 18000)
    if at ~= nil and window > 0 and at > os.time() then
        local remaining = math.max(0, at - os.time())
        local elapsed = math.max(0, window - remaining)
        return math.min(100, math.max(0, math.floor((elapsed / window) * 100)))
    end
    return nil
end

local function formatSeconds(seconds)
    if seconds <= 0 then return "now" end
    local minutes = math.floor(seconds / 60)
    local days = math.floor(minutes / 1440)
    local hours = math.floor((minutes % 1440) / 60)
    local rest = minutes % 60
    if days > 0 then return string.format("%dd %dh", days, hours) end
    if hours > 0 then return string.format("%dh %dm", hours, rest) end
    return string.format("%dm", rest)
end

local function assessTriage(metric, percent, elapsedPct, windowLabel, item, staggerPlan, isStarted)
    if metric == nil or percent == nil then return nil end
    local isWeekly = windowLabel == "7d"
    local remainingQuota = 100 - percent
    local at = parseIso(metric.reset_at)
    local remainingSecs = (at and at > os.time()) and (at - os.time()) or 0
    local paceDiff = (elapsedPct or 0) - percent

    local wMetric = item and item.weeklyMetric
    local wPct = wMetric and tonumber(wMetric.percent) or 0
    local isWeeklyExhausted = (wMetric ~= nil and wPct >= 100)
    local baseId = item and ((item.entry and item.entry.id) or item.providerId)

    -- Reset credit advice: a claim only pays with enough active hours left before the renewal
    local advice = staggerPlan and staggerPlan.creditAdvice and baseId and staggerPlan.creditAdvice[baseId]

    if isWeekly and shared.weeklyResetStatus(metric, item and item.entry) ~= "announced" then
        return { status = "unconfirmed", label = "Check", glyph = "clock",
            color = "on_surface_variant", bg = "on_surface/0.06", border = "outline_variant/0.20",
            summary = shared.weeklyResetTooltip(metric, item and item.entry) }
    end

    if isWeekly and advice and advice.status == "claim" then
        return {
            status = "claim_reset",
            label = "Claim Reset",
            glyph = "ticket",
            color = "#c084fc",
            bg = "tertiary/0.22",
            border = "tertiary/0.55",
            cardBorder = "tertiary/0.55",
            summary = advice.summary,
        }
    end

    if percent >= 100 or isWeeklyExhausted then
        local summary = isWeeklyExhausted and "Weekly quota depleted" or "Quota depleted"
        if isWeekly and advice then
            summary = summary .. " · " .. advice.summary
        end
        return {
            status = "exhausted",
            label = "Exhausted",
            glyph = "circle-x",
            color = "#f87171",
            bg = "error/0.18",
            border = "error/0.45",
            cardBorder = "error/0.45",
            summary = summary,
        }
    end

    if isWeekly and advice and staggerPlan.fastTrack and staggerPlan.fastTrack[baseId] then
        local isLeader = staggerPlan.hasCollision and staggerPlan.advanceProviderId == baseId
        local urgency = advice.urgency
        local summary = advice.summary
        if urgency then
            summary = string.format("Claim before %s · ~%.1fh needed / %.1fh available · up to ~%d%% extra quota%s",
                os.date("%b %d %H:%M %Z", urgency.deadlineAt), urgency.neededHours, urgency.availableHours,
                math.floor(advice.cycleGain + 0.5), urgency.feasible and "" or " · 95% may be unreachable in this window")
        end
        return {
            status = "fast_track",
            label = "Fast-track",
            glyph = "flame",
            color = "#38bdf8",
            bg = "primary/0.20",
            border = "primary/0.50",
            cardBorder = "primary/0.50",
            summary = (isLeader and "Advance reset: " or "Reset credit: ") .. summary,
        }
    end

    local gearing = getModelGearing(item and (item.providerId or (item.entry and item.entry.id)), item and item.name) or 10.0
    local oneSessionPct = 100.0 / gearing
    local sessionsNeeded = remainingQuota / oneSessionPct

    local shouldThrottle = false
    local throttleSummary = nil
    if percent >= 75 and remainingSecs > (isWeekly and 172800 or 3600) then
        shouldThrottle = true
    elseif paceDiff <= -15 and percent >= 60 and remainingSecs > (isWeekly and 86400 or 3600) then
        shouldThrottle = true
    elseif isWeekly and gearing <= 3.5 and percent >= 45 and remainingSecs > 172800 then
        shouldThrottle = true
        throttleSummary = string.format("Conserve · High weekly impact (~%d sess/wk, 1 session = ~%d%% week)", math.floor(gearing + 0.5), math.floor(oneSessionPct + 0.5))
    end

    if shouldThrottle then
        return {
            status = "conserve",
            label = "Conserve",
            glyph = "alert-triangle",
            color = "#f87171",
            bg = "error/0.18",
            border = "error/0.45",
            cardBorder = "error/0.45",
            summary = throttleSummary or string.format("Heavy use · %d%% free remaining", remainingQuota),
        }
    end

    local shouldBurn = false
    local burnSummary = nil
    if not isWeekly then
        local H_s_active = calculateActiveHours(os.time(), os.time() + remainingSecs)
        if (H_s_active <= 1.50 or remainingSecs <= 5400) and remainingQuota >= 25 and remainingSecs > 0 then
            shouldBurn = true
            burnSummary = string.format("Session expires soon (~%.1fh active) · %d%% free to use", H_s_active, remainingQuota)
        elseif remainingSecs <= 9000 and remainingQuota >= 45 and remainingSecs > 0 then
            shouldBurn = true
        elseif paceDiff >= 20 and remainingQuota >= 40 and isSessionStarted(metric) then
            shouldBurn = true
        end
    else
        local H_w_active = calculateActiveHours(os.time(), at)
        local C_max = (H_w_active * 20.0) / gearing
        local dutyCycle = remainingQuota / math.max(1.0, C_max)

        if (H_w_active <= 3.0 or remainingSecs <= 10800) and remainingQuota > 0 and remainingSecs > 0 then
            shouldBurn = true
            burnSummary = string.format("Weekly reset in ~%.1fh! Burn remaining %d%% before reset", math.max(0.1, remainingSecs / 3600), remainingQuota)
        elseif (H_w_active <= 14.0 or remainingSecs <= 86400) and remainingQuota >= 5 and remainingSecs > 0 then
            shouldBurn = true
            burnSummary = string.format("Weekly reset soon (~%.1fh active left) · %d%% quota will expire", H_w_active, remainingQuota)
        elseif dutyCycle >= 0.85 and remainingQuota >= 20 and remainingSecs > 0 then
            shouldBurn = true
            burnSummary = string.format("Session bottleneck: need ~%d sessions for %d%% weekly quota (~%ds/w)", math.floor(sessionsNeeded + 0.5), remainingQuota, math.floor(gearing + 0.5))
        elseif remainingSecs <= 172800 and remainingQuota >= 25 and remainingSecs > 0 then
            shouldBurn = true
        elseif remainingSecs <= 259200 and remainingQuota >= 35 and remainingSecs > 0 then
            shouldBurn = true
        elseif paceDiff >= 20 and remainingQuota >= 40 then
            shouldBurn = true
        end
    end

    if shouldBurn then
        return {
            status = "use_now",
            label = "Use now",
            glyph = "flame",
            color = "#fb923c",
            bg = "primary/0.18",
            border = "primary/0.45",
            cardBorder = "primary/0.45",
            summary = burnSummary or string.format("%d%% free to use · %dpts under", remainingQuota, paceDiff),
        }
    end

    local active = isWeekly or isStarted or isSessionStarted(metric)
    if not isWeekly and not active and percent == 0 then
        return {
            status = "fresh",
            label = "Fresh",
            glyph = "star",
            color = "#38bdf8",
            bg = "tertiary/0.14",
            border = "tertiary/0.35",
            cardBorder = nil,
            summary = "100% free · session not started",
        }
    end

    return {
        status = "balanced",
        label = "Balanced",
        glyph = "circle-check",
        color = "#4ade80",
        bg = "secondary/0.14",
        border = "secondary/0.35",
        cardBorder = nil,
        summary = string.format("%d%% free · %s", remainingQuota,
            paceDiff >= 0 and string.format("%dpts under", paceDiff) or string.format("%dpts ahead", -paceDiff)),
    }
end

-- ── Kickstart Controller ──────────────────────────────────────────────────────

local kickstarting = {}
local kickstartedAt = {}

local function getKickstartedAt(target)
    if not target then return nil end
    local ts = kickstartedAt[target]
    if ts == nil and type(noctalia) == "table" and type(noctalia.state) == "table" and type(noctalia.state.get) == "function" then
        local st = noctalia.state.get("kickstarted_at")
        if type(st) == "table" and type(st[target]) == "number" then
            kickstartedAt[target] = st[target]
            ts = st[target]
        end
    end
    return ts
end

local function setKickstartedAt(target, ts)
    if not target then return end
    kickstartedAt[target] = ts
    if type(noctalia) == "table" and type(noctalia.state) == "table" then
        local st = {}
        if type(noctalia.state.get) == "function" then
            local current = noctalia.state.get("kickstarted_at")
            if type(current) == "table" then
                for k, v in pairs(current) do st[k] = v end
            end
        end
        st[target] = ts
        if type(noctalia.state.set) == "function" then
            noctalia.state.set("kickstarted_at", st)
        end
    end
end

local function kickstartWindow(target)
    if target == nil or kickstarting[target] then return end
    kickstarting[target] = true
    if type(render) == "function" then
        render()
    end
    if type(noctalia.runAsync) == "function" then
        local cmd = string.format('export PATH="$HOME/.local/bin:$PATH"; if [ -x "$HOME/.local/bin/ai-kickstart" ]; then exec "$HOME/.local/bin/ai-kickstart" %s; else exec ai-kickstart %s; fi', target, target)
        local launched = noctalia.runAsync(cmd, function(result)
            kickstarting[target] = nil
            local ok = result == nil or result == true or result.exitCode == 0
            if ok then
                setKickstartedAt(target, os.time())
                requestRefresh()
            else
                local err = (type(result) == "table" and type(result.stderr) == "string" and result.stderr ~= "")
                    and result.stderr
                    or ("Failed to start 5h session for " .. tostring(target) .. ". Check backend CLI.")
                if type(noctalia.notifyError) == "function" then
                    noctalia.notifyError("AI Kickstart", err)
                end
            end
            if type(render) == "function" then
                render()
            end
        end, 30000)
        if launched == false then
            kickstarting[target] = nil
            if type(noctalia.notifyError) == "function" then
                noctalia.notifyError("AI Kickstart", "Host refused to execute ai-kickstart.")
            end
            if type(render) == "function" then
                render()
            end
        end
    else
        kickstarting[target] = nil
    end
end

-- ── Card Renderers ────────────────────────────────────────────────────────────

local function renderMetricCard(item, metric, windowLabel, staggerPlan, typo)
    local fs = typo and typo.fontSize or function(s) return s end
    local gs = typo and typo.glyphSize or function(s) return s end
    local factor = typo and typo.factor or 1.0
    local isWeekly = windowLabel == "7d"
    local isLongName = #item.name > 12

    local iconBoxSize = math.floor(24 * factor + 0.5)
    local titleChildren = {
        ui.row({
            width = iconBoxSize, height = iconBoxSize, radius = 6,
            fill = "primary/0.14", align = "center", justify = "center",
        }, {
            ui.glyph({ name = item.glyph, size = gs(14), color = "primary" }),
        }),
        ui.label({
            text = item.name,
            fontSize = isLongName and fs(14) or fs(15),
            fontWeight = "bold",
            color = "on_surface",
            maxLines = 1,
            maxWidth = math.floor(165 * factor + 0.5),
        }),
    }
    if item.badge then
        titleChildren[#titleChildren + 1] = ui.row({
            paddingH = 4, paddingV = 1, radius = 4, fill = "primary/0.10",
        }, {
            ui.label({ text = item.badge, fontSize = fs(10), fontWeight = "medium", color = "primary" }),
        })
    end

    if unavailable(item.entry) then
        local issue = shared.diagnostic(item.entry)
        local children = {
            ui.row({ gap = 6, align = "center" }, titleChildren),
            ui.label({ text = noctalia.tr(issue.titleKey), fontSize = fs(13),
                fontWeight = "semibold", color = "error", maxLines = 2 }),
            ui.label({ text = noctalia.tr(issue.actionKey, issue.actionArgs), fontSize = fs(12),
                color = "on_surface", maxLines = 3 }),
        }
        if issue.command then
            children[#children + 1] = ui.label({ text = issue.command, fontSize = fs(11),
                fontFamily = "monospace", color = "on_surface", maxLines = 2 })
        end
        if issue.detail ~= "" then
            children[#children + 1] = ui.label({ text = issue.detail, fontSize = fs(10),
                color = "on_surface_variant", maxLines = 3, tooltip = issue.detail })
        end
        local actions = {}
        if issue.command and type(noctalia.copyToClipboard) == "function" then
            actions[#actions + 1] = ui.button({ text = noctalia.tr("ui.diagnostic.copy_command"),
                glyph = "copy", variant = "outline", controlSize = "sm",
                onClick = function() noctalia.copyToClipboard(issue.command) end })
        end
        if issue.retryable then
            actions[#actions + 1] = ui.button({ text = noctalia.tr("ui.refresh"),
                glyph = "refresh", variant = "outline", controlSize = "sm",
                enabled = not polling, onClick = requestRefresh })
        end
        if #actions > 0 then children[#children + 1] = ui.row({ gap = 6 }, actions) end
        return ui.column(cardStyle(6, "error/0.06", "error/0.25", 10), children)
    end

    if metric == nil then
        return ui.column({
            gap = 6,
            paddingH = 10,
            paddingV = 8,
            radius = CARD.radius,
            fill = CARD.fill,
            border = CARD.border,
            borderWidth = CARD.borderWidth,
        }, {
            ui.row({ gap = 4, align = "center" }, {
                ui.row({ gap = 4, align = "center" }, titleChildren),
                ui.spacer({ flexGrow = 1 }),
                ui.label({ text = "—", fontSize = fs(14), color = "on_surface_variant" }),
            }),
            ui.column({ gap = 1, align = "stretch" }, {
                ui.progress({ progress = 0, fill = "on_surface/0.10", track = "on_surface/0.05", radius = 4, height = 8 }),
                ui.row({ height = 5 }),
            }),
            ui.row({ gap = 8, align = "center", justify = "center" }, {
                ui.row({ gap = 5, align = "center", paddingH = 8, paddingV = 2, radius = 5, fill = "on_surface/0.06" }, {
                    ui.glyph({ name = "slash", size = gs(12), color = "on_surface_variant" }),
                    ui.label({ text = "Not reported", fontSize = fs(12), color = "on_surface_variant" }),
                }),
            }),
        })
    end

    local percent = tonumber(metric.percent) or 0
    local tint = severityRole(metric, "on_surface")
    local fill = severityRole(metric, "primary")
    local value = tostring(metric.value or ""):gsub(" of ", " / ")
    local showValue = value ~= "" and value ~= string.format("%d%%", percent)

    local ksTarget = not isWeekly and kickstartTarget(item) or nil
    local ksTs = getKickstartedAt(ksTarget)
    local justKickstarted = ksTarget ~= nil and ksTs ~= nil
        and (os.time() - ksTs) < 18000

    local isStarted = isWeekly or isSessionStarted(metric) or justKickstarted
    local resetTimeText = formatResetTime(metric, windowLabel, isStarted)
    local leftDuration = ""
    if isStarted then
        leftDuration = countdown(metric)
        if (leftDuration == "now" or leftDuration == noctalia.tr("ui.now"))
            and not isWeekly and not isStarted then
            leftDuration = ""
        end
    end
    local resetTooltip = leftDuration ~= "" and ("Renews in " .. leftDuration) or nil
    if isWeekly then resetTooltip = shared.weeklyResetTooltip(metric, item and item.entry) end

    local elapsedPct = calculateElapsed(metric, windowLabel, isStarted)
    local triage = assessTriage(metric, percent, elapsedPct, windowLabel, item, staggerPlan, isStarted)

    if triage ~= nil then
        titleChildren[#titleChildren + 1] = ui.row({
            gap = 2, align = "center",
            paddingH = 4, paddingV = 1, radius = 4,
            fill = triage.bg, border = triage.border, borderWidth = 1,
            tooltip = triage.summary,
        }, {
            ui.glyph({ name = triage.glyph, size = gs(10), color = triage.color }),
            ui.label({ text = triage.label, fontSize = fs(10), fontWeight = "bold", color = triage.color }),
        })
    end

    local rightMeta = {}
    if leftDuration ~= "" then
        local fgColor = countdownColor(metric, isStarted)
        rightMeta[#rightMeta + 1] = ui.row({
            gap = 3, align = "center",
            paddingH = 3, paddingV = 1,
        }, {
            ui.glyph({ name = "clock", size = gs(12), color = fgColor }),
            ui.label({
                text = leftDuration,
                fontSize = fs(13),
                fontWeight = "medium",
                color = fgColor,
                maxLines = 1,
            }),
        })
    end

    rightMeta[#rightMeta + 1] = ui.row({
        paddingH = 6, paddingV = 2, radius = 5, align = "center", justify = "center",
        fill = tint .. "/0.15",
    }, {
        ui.label({ text = string.format("%d%%", percent), fontSize = fs(15),
                   fontWeight = "bold", color = tint, textAlign = "center" }),
    })

    local cardPaddingH = 10
    local cardPaddingV = 8
    local cardGap = 6

    local actionBtn = nil
    if isWeekly and triage and triage.status == "claim_reset" then
        local dashUrl = providerDashboard(item.providerId or (item.entry and item.entry.id))
        if dashUrl then
            actionBtn = ui.button({
                text = "Claim",
                glyph = "external-link",
                variant = "primary",
                controlSize = "sm",
                tooltip = "Open dashboard to claim weekly reset",
                onClick = function()
                    if type(noctalia.runAsync) == "function" then
                        noctalia.runAsync("xdg-open '" .. dashUrl .. "'")
                    end
                end,
            })
        end
    end

    local topRowChildren = {
        ui.row({ gap = 4, align = "center" }, titleChildren),
        ui.spacer({ flexGrow = 1 }),
    }
    if actionBtn ~= nil then
        topRowChildren[#topRowChildren + 1] = actionBtn
    end
    topRowChildren[#topRowChildren + 1] = ui.row({ gap = 5, align = "center", justify = "end" }, rightMeta)

    local topRow = ui.row({ gap = 4, align = "center" }, topRowChildren)

    local progressBar = ui.progress({
        progress = ratio(percent),
        fill = fill,
        track = "on_surface/0.10",
        radius = 4,
        height = 8,
    })

    local effectiveElapsed = elapsedPct
    if not isWeekly and not isStarted then
        effectiveElapsed = 0
    end

    local markerChildren = {}
    local markerTip = "Session not started · 0% elapsed · 0% quota used"
    local markerColor = "#38bdf8"

    if effectiveElapsed ~= nil then
        local leftFlex = math.max(1, effectiveElapsed)
        local rightFlex = math.max(1, 100 - effectiveElapsed)
        local paceDiff = effectiveElapsed - percent
        local paceStatus = paceDiff >= 0
            and string.format("+%d%% quota free", paceDiff)
            or string.format("%d%% over pace", -paceDiff)
        markerTip = string.format("Time: %d%% elapsed · Quota: %d%% used (%s)",
            effectiveElapsed, percent, paceStatus)
        markerColor = paceDiff >= 0 and "#38bdf8" or "#fb923c"

        if effectiveElapsed > 1 then
            markerChildren[#markerChildren + 1] = ui.spacer({ flexGrow = leftFlex })
        end
        markerChildren[#markerChildren + 1] = ui.box({
            width = 4,
            height = 5,
            radius = 1.5,
            fill = markerColor,
        })
        if effectiveElapsed < 99 then
            markerChildren[#markerChildren + 1] = ui.spacer({ flexGrow = rightFlex })
        end
    else
        markerChildren[#markerChildren + 1] = ui.spacer({ flexGrow = 1 })
    end

    local markerRow = ui.row({
        height = 5,
        align = "center",
        paddingH = 0,
        tooltip = markerTip,
    }, markerChildren)

    local progressElement = ui.column({ gap = 1, align = "stretch" }, {
        progressBar,
        markerRow,
    })

    local body = { topRow, progressElement }

    local bottomRowElements = {}

    -- Element 1: Clock pill (Always rendered to guarantee vertical symmetry)
    if isWeekly or isStarted then
        bottomRowElements[#bottomRowElements + 1] = ui.row({
            gap = 5, align = "center", justify = "center",
            paddingH = 8,
            paddingV = 2,
            radius = 5,
            fill = "on_surface/0.08",
            tooltip = resetTooltip or (isWeekly and "Weekly quota reset schedule" or "5h rolling window reset time"),
        }, {
            ui.glyph({ name = "clock", size = gs(13), color = "on_surface_variant" }),
            ui.label({
                text = resetTimeText ~= "" and resetTimeText or "--:--",
                fontSize = fs(13),
                fontWeight = "medium",
                color = "on_surface",
                textAlign = "center",
                maxLines = 1,
            }),
        })
    else
        -- Unstarted 5h session: Red indicator with "--:--"
        bottomRowElements[#bottomRowElements + 1] = ui.row({
            gap = 5, align = "center", justify = "center",
            paddingH = 8,
            paddingV = 2,
            radius = 5,
            fill = "error/0.10",
            border = "error/0.25",
            borderWidth = 1,
            tooltip = "Session not started · Rolling 5h timer begins on first prompt",
        }, {
            ui.glyph({ name = "clock", size = gs(13), color = "error" }),
            ui.label({
                text = "--:--",
                fontSize = fs(13),
                fontWeight = "bold",
                color = "error",
                textAlign = "center",
                maxLines = 1,
            }),
        })
    end

    -- Element 2: Complementary status or action element (Always rendered)
    if isWeekly then
        local gearing, isCalibrated = getModelGearing(item and (item.providerId or (item.entry and item.entry.id)), item and item.name, item)
        if gearing then
            local oneSessionPct = math.floor((100.0 / gearing) + 0.5)
            local tipText = string.format("Gearing: ~%d full 5h sessions per week (1 session burns ~%d%% weekly quota%s)",
                math.floor(gearing + 0.5), oneSessionPct, isCalibrated and " · calibrated from observed usage" or "")
            bottomRowElements[#bottomRowElements + 1] = ui.row({
                gap = 4, align = "center", justify = "center",
                paddingH = 7,
                paddingV = 2,
                radius = 5,
                fill = isCalibrated and "primary/0.14" or "secondary/0.10",
                tooltip = tipText,
            }, {
                ui.glyph({ name = isCalibrated and "sparkles" or "gauge", size = gs(12), color = isCalibrated and "primary" or "secondary" }),
                ui.label({
                    text = string.format("~%ds/w", math.floor(gearing + 0.5)),
                    fontSize = fs(12),
                    fontWeight = "medium",
                    color = isCalibrated and "primary" or "secondary",
                }),
            })
        end
    else
        -- 5h Session card complementary action / status
        local isWeeklyExhausted = (item and item.weeklyMetric ~= nil and (tonumber(item.weeklyMetric.percent) or 0) >= 100)
        local canKickstart = ksTarget ~= nil and not justKickstarted
            and not isStarted and percent == 0
            and not isWeeklyExhausted
            and not unavailable(item and item.entry)

        if canKickstart then
            local isBusy = kickstarting[ksTarget] == true
            bottomRowElements[#bottomRowElements + 1] = ui.button({
                glyph = isBusy and "loader-2" or "bolt",
                text = isBusy and "Starting..." or "Start 5h",
                variant = "outline",
                controlSize = "sm",
                enabled = not isBusy,
                tooltip = "Send 1-token prompt to trigger 5h rolling window now",
                onClick = function()
                    kickstartWindow(ksTarget)
                end,
            })
        elseif isWeeklyExhausted then
            bottomRowElements[#bottomRowElements + 1] = ui.row({
                gap = 4, align = "center", justify = "center",
                paddingH = 7,
                paddingV = 2,
                radius = 5,
                fill = "error/0.12",
                border = "error/0.25",
                borderWidth = 1,
                tooltip = "Weekly quota is 100% exhausted. Sessions cannot be started until weekly reset.",
            }, {
                ui.glyph({ name = "alert-circle", size = gs(12), color = "error" }),
                ui.label({
                    text = "7d exhausted",
                    fontSize = fs(12),
                    fontWeight = "medium",
                    color = "error",
                }),
            })
        elseif isStarted then
            bottomRowElements[#bottomRowElements + 1] = ui.row({
                gap = 4, align = "center", justify = "center",
                paddingH = 7,
                paddingV = 2,
                radius = 5,
                fill = "primary/0.10",
                tooltip = "5-hour rolling session window currently active",
            }, {
                ui.glyph({ name = "bolt", size = gs(12), color = "primary" }),
                ui.label({
                    text = "5h rolling",
                    fontSize = fs(12),
                    fontWeight = "medium",
                    color = "primary",
                }),
            })
        else
            bottomRowElements[#bottomRowElements + 1] = ui.row({
                gap = 4, align = "center", justify = "center",
                paddingH = 7,
                paddingV = 2,
                radius = 5,
                fill = "on_surface/0.08",
                tooltip = "Session window not currently active",
            }, {
                ui.glyph({ name = "clock-pause", size = gs(12), color = "on_surface_variant" }),
                ui.label({
                    text = "Unstarted",
                    fontSize = fs(12),
                    fontWeight = "medium",
                    color = "on_surface_variant",
                }),
            })
        end
    end

    body[#body + 1] = ui.row({ gap = 8, align = "center", justify = "center" }, bottomRowElements)

    if showValue then
        body[#body + 1] = ui.row({ align = "center", justify = "center" }, {
            ui.label({ text = value, fontSize = fs(14), color = "on_surface_variant", maxLines = 1 }),
        })
    end

    local rest = plainDetail(metric.detail)
    if rest ~= "" then
        body[#body + 1] = ui.label({ text = rest, fontSize = fs(13), color = "on_surface_variant" })
    end

    return ui.column({
        gap = cardGap,
        paddingH = cardPaddingH,
        paddingV = cardPaddingV,
        radius = CARD.radius,
        fill = CARD.fill,
        border = (triage and triage.cardBorder) or CARD.border,
        borderWidth = (triage and triage.cardBorder) and 1 or CARD.borderWidth,
    }, body)
end

local function creditCountdownColor(credit)
    local expiresAt = credit and credit.expiresAt
    if expiresAt == nil or expiresAt == math.huge then
        return "on_surface_variant"
    end
    local remaining = math.max(0, expiresAt - os.time())
    local window = 30 * 86400
    local r = remaining / window

    if r > 0.60 then
        return "#4ade80"
    elseif r > 0.30 then
        return "#38bdf8"
    elseif r > 0.12 then
        return "#facc15"
    elseif r > 0.04 then
        return "#fb923c"
    else
        return "#f87171"
    end
end

local function renderCreditCard(credit, typo)
    local fs = typo and typo.fontSize or function(s) return s end
    local gs = typo and typo.glyphSize or function(s) return s end
    local factor = typo and typo.factor or 1.0
    local fgColor = creditCountdownColor(credit)
    local roleBadge = nil
    if credit.role == "claim" then
        roleBadge = ui.row({
            paddingH = 5, paddingV = 1.5, radius = 4,
            fill = "tertiary/0.20", border = "tertiary/0.50", borderWidth = 1,
        }, {
            ui.label({ text = "CLAIM NOW", fontSize = fs(9), fontWeight = "bold", color = "#c084fc" }),
        })
    elseif credit.role == "advance" then
        roleBadge = ui.row({
            paddingH = 5, paddingV = 1.5, radius = 4,
            fill = "primary/0.20", border = "primary/0.50", borderWidth = 1,
        }, {
            ui.label({ text = "ADVANCE", fontSize = fs(9), fontWeight = "bold", color = "#38bdf8" }),
        })
    elseif credit.role == "defer" then
        roleBadge = ui.row({
            paddingH = 5, paddingV = 1.5, radius = 4,
            fill = "outline_variant/0.15", border = "outline_variant/0.30", borderWidth = 1,
        }, {
            ui.label({ text = "DEFER", fontSize = fs(9), fontWeight = "medium", color = "on_surface_variant" }),
        })
    end

    local dashUrl = providerDashboard(credit.providerId)
    local openBtn = dashUrl and ui.button({
        glyph = "external-link",
        variant = "ghost",
        controlSize = "sm",
        tooltip = "Open dashboard to manage reset",
        onClick = function()
            if type(noctalia.runAsync) == "function" then
                noctalia.runAsync("xdg-open '" .. dashUrl .. "'")
            end
        end,
    }) or nil

    local iconBoxSize = math.floor(24 * factor + 0.5)
    local creditRow = {
        ui.row({
            width = iconBoxSize, height = iconBoxSize, radius = 6,
            fill = "primary/0.14", align = "center", justify = "center",
        }, {
            ui.glyph({ name = credit.glyph, size = gs(14), color = "primary" }),
        }),
        ui.label({
            text = credit.providerName,
            fontSize = fs(14),
            fontWeight = "bold",
            color = "on_surface",
            maxLines = 1,
        }),
    }
    if roleBadge ~= nil then
        creditRow[#creditRow + 1] = roleBadge
    end
    creditRow[#creditRow + 1] = ui.spacer({ flexGrow = 1 })
    if openBtn ~= nil then
        creditRow[#creditRow + 1] = openBtn
    end

    local body = {
        ui.row({ gap = 6, align = "center", tooltip = credit.fullTitle }, creditRow),
        ui.row({
            gap = 5, align = "center",
            paddingH = 2,
        }, {
            ui.glyph({ name = "clock", size = gs(13), color = fgColor }),
            ui.label({
                text = credit.expiry,
                fontSize = fs(13),
                fontWeight = "medium",
                color = fgColor,
                maxLines = 1,
            }),
        }),
    }
    if credit.advice ~= nil then
        body[#body + 1] = ui.label({
            text = credit.advice,
            fontSize = fs(11),
            color = credit.role == "claim" and "on_surface" or "on_surface_variant",
            maxLines = 2,
        })
    end
    return ui.column(cardStyle(4, nil, nil, 8), body)
end

-- ── 3-Column Layout ───────────────────────────────────────────────────────────

local function renderColumns(candidates, typo)
    local fs = typo and typo.fontSize or function(s) return s end
    local gs = typo and typo.glyphSize or function(s) return s end
    local factor = typo and typo.factor or 1.0

    local headerActions = {}
    headerActions[#headerActions + 1] = ui.button({
        glyph = polling and "loader-2" or refreshQueued and "clock" or "refresh",
        variant = "outline", controlSize = "sm",
        tooltip = noctalia.tr(polling and "ui.refreshing"
            or refreshQueued and "ui.refresh_queued" or "ui.refresh"),
        enabled = not polling,
        onClick = requestRefresh,
    })
    headerActions[#headerActions + 1] = ui.button({
        glyph = "settings",
        variant = "outline", controlSize = "sm",
        tooltip = noctalia.tr("ui.settings"),
        onClick = function() noctalia.openSettings() end,
    })
    headerActions[#headerActions + 1] = ui.button({
        glyph = "x",
        variant = "outline", controlSize = "sm",
        tooltip = "Close",
        onClick = function()
            if type(panel.close) == "function" then panel.close() end
        end,
    })

    local latestFetched = nil
    for _, candidate in ipairs(candidates) do
        local at = parseIso(candidate and candidate.fetched_at)
        if at ~= nil and (latestFetched == nil or at > latestFetched) then
            latestFetched = at
        end
    end

    local updatedRow = nil
    if latestFetched ~= nil then
        local minutes = math.floor((os.time() - latestFetched) / 60)
        local timeTip = minutes < 1 and noctalia.tr("ui.updated_now") or noctalia.tr("ui.updated_ago", { minutes = minutes })
        updatedRow = ui.row({ gap = 4, align = "center", paddingH = 7,
                              paddingV = 3, radius = 6, fill = "on_surface/0.08",
                              tooltip = timeTip }, {
            ui.glyph({ name = "clock", size = gs(14), color = "on_surface_variant" }),
            ui.label({
                text = noctalia.tr("ui.updated") .. " " .. noctalia.formatTime(noctalia.timeFormat(), latestFetched),
                fontSize = fs(14),
                color = "on_surface_variant",
            }),
        })
    end

    local titleBoxSize = math.floor(32 * factor + 0.5)
    local topRowChildren = {
        ui.row({
            width = titleBoxSize, height = titleBoxSize, radius = 8,
            fill = "primary/0.14", align = "center", justify = "center",
        }, {
            ui.glyph({ name = "scale", size = gs(20), color = "primary" }),
        }),
        ui.label({ text = noctalia.tr("ui.title"), fontSize = fs(19), fontWeight = "bold", color = "on_surface" }),
    }
    if updatedRow ~= nil then
        topRowChildren[#topRowChildren + 1] = updatedRow
    end
    topRowChildren[#topRowChildren + 1] = ui.spacer({ flexGrow = 1 })
    topRowChildren[#topRowChildren + 1] = ui.row({ gap = 4, align = "center" }, headerActions)

    local modelItems = collectModelItems(candidates)
    local healthy = {}
    for _, entry in ipairs(candidates) do
        if not unavailable(entry) then healthy[#healthy + 1] = entry end
    end
    local staggerPlan, providerStats = shared.analyzeResetCredits(healthy)
    local resetCredits = collectResetCredits(healthy, staggerPlan)

    local scheduleConfig = getScheduleConfig()

    -- Sort models by triage score (considering session & weekly pacing, schedule-aware active hours, and staggering)
    table.sort(modelItems, function(a, b)
        local aFailed, bFailed = unavailable(a.entry), unavailable(b.entry)
        if aFailed ~= bFailed then return not aFailed end
        local aScore = calculateModelTriageScore(a, staggerPlan, os.time(), scheduleConfig, true)
        local bScore = calculateModelTriageScore(b, staggerPlan, os.time(), scheduleConfig, true)
        if math.abs(aScore - bScore) > 0.01 then
            return aScore > bScore
        end
        local aSPct = a.sessionMetric and tonumber(a.sessionMetric.percent) or 0
        local bSPct = b.sessionMetric and tonumber(b.sessionMetric.percent) or 0
        if aSPct ~= bSPct then
            return aSPct < bSPct
        end
        local aWPct = a.weeklyMetric and tonumber(a.weeklyMetric.percent) or 0
        local bWPct = b.weeklyMetric and tonumber(b.weeklyMetric.percent) or 0
        if aWPct ~= bWPct then
            return aWPct < bWPct
        end
        return (a.name or "") < (b.name or "")
    end)

    -- Both columns follow the same triage order:
    -- the session card sits next to the weekly card for the same provider/model
    local sessionCards = {}
    local weeklyCards = {}
    for _, item in ipairs(modelItems) do
        local sCard = renderMetricCard(item, item.sessionMetric, "5h", staggerPlan, typo)
        if sCard ~= nil then
            sessionCards[#sessionCards + 1] = sCard
        end
        local wCard = renderMetricCard(item, item.weeklyMetric, "7d", staggerPlan, typo)
        if wCard ~= nil then
            weeklyCards[#weeklyCards + 1] = wCard
        end
    end

    local creditCards = {}
    for _, credit in ipairs(resetCredits) do
        creditCards[#creditCards + 1] = renderCreditCard(credit, typo)
    end

    local weeklySchedules = {}
    local seenWeekly = {}
    for _, item in ipairs(modelItems) do
        local wM = item.weeklyMetric
        local baseId = item.providerId or (item.entry and item.entry.id)
        if wM and not unavailable(item.entry) and not seenWeekly[baseId] then
            seenWeekly[baseId] = true
            local at = parseIso(wM.reset_at)
            local resetStatus = shared.weeklyResetStatus(wM, item.entry)
            local remSecs = at and math.max(0, at - os.time()) or math.huge
            local wPct = tonumber(wM.percent) or 0
            local wFree = math.max(0, 100 - wPct)
            weeklySchedules[#weeklySchedules + 1] = {
                baseId = baseId,
                name = item.name or (item.entry and item.entry.display_name) or baseId,
                glyph = item.glyph or shared.providerGlyph(baseId),
                resetAt = at,
                remainingSecs = remSecs,
                percent = wPct,
                free = wFree,
                status = resetStatus,
                tooltip = shared.weeklyResetTooltip(wM, item.entry),
                change = shared.weeklyResetChange(wM),
            }
        end
    end
    table.sort(weeklySchedules, function(a, b) return a.remainingSecs < b.remainingSecs end)

    if staggerPlan and staggerPlan.hasCollision then
        local advanceName = staggerPlan.advanceName or "Claude"
        local deferName = staggerPlan.deferName or "Codex"
        local expiryDay = staggerPlan.expiresAt and os.date("%b %d", staggerPlan.expiresAt) or "?"
        local leader = providerStats and providerStats[staggerPlan.advanceProviderId]
        local leaderAdvice = leader and leader.advice
        local advanceStep
        if leaderAdvice == nil then
            advanceStep = string.format("1. Advance %s: burn its weekly quota early and claim the reset once it runs out.", advanceName)
        elseif leaderAdvice.status == "claim" then
            advanceStep = string.format("1. Claim %s's reset now: ~%d%% of a week back.", advanceName, math.floor(leaderAdvice.nowGain + 0.5))
        elseif leaderAdvice.status == "advance" then
            advanceStep = string.format("1. Advance %s now: burn the remaining %d%%, then claim · worth ~%d%% of a week.",
                advanceName, math.floor(100 - leader.weeklyPercent + 0.5), math.floor(leaderAdvice.cycleGain + 0.5))
        elseif not leaderAdvice.lastChance then
            advanceStep = string.format("1. Advance %s after its renewal in %s: burn the new week early, then claim before %s.",
                advanceName, formatSeconds(leader.weeklyRemainingSecs), expiryDay)
        else
            advanceStep = string.format("1. %s: %s", advanceName, leaderAdvice.summary)
        end
        local deferStats = providerStats and providerStats[staggerPlan.deferProviderId]
        local deferStep
        local deferColor = "outline_variant"
        local deferTextColor = "on_surface_variant"
        if deferStats and deferStats.advice and deferStats.advice.lastChance then
            deferStep = string.format("2. Sprint %s as well: credit expires this cycle (~%s), burn before renewal.", deferName, expiryDay)
            deferColor = "#38bdf8"
            deferTextColor = "on_surface"
        else
            deferStep = string.format("2. Defer %s: keep its reset credit for its next cycle after renewal.", deferName)
        end
        local stratCard = ui.column(cardStyle(4, nil, nil, 8), {
            ui.row({ gap = 6, align = "center" }, {
                ui.glyph({ name = "calendar-clock", size = gs(15), color = "primary" }),
                ui.label({
                    text = string.format("Manual Credits Strategy (Collision in %.0fd)", staggerPlan.daysUntilExpiry or 12),
                    fontSize = fs(13), fontWeight = "bold", color = "primary",
                }),
            }),
            ui.label({
                text = string.format("%s & %s manual credits expire together (~%s). Staggering strategy:", advanceName, deferName, expiryDay),
                fontSize = fs(11), color = "on_surface_variant",
            }),
            ui.row({ gap = 6, align = "start" }, {
                ui.glyph({ name = "arrow-right", size = gs(12), color = "#38bdf8" }),
                ui.label({
                    text = advanceStep,
                    fontSize = fs(11), fontWeight = "semibold", color = "on_surface", flexGrow = 1,
                }),
            }),
            ui.row({ gap = 6, align = "start" }, {
                ui.glyph({ name = "arrow-right", size = gs(12), color = deferColor }),
                ui.label({
                    text = deferStep,
                    fontSize = fs(11), color = deferTextColor, flexGrow = 1,
                }),
            }),
        })
        table.insert(creditCards, 1, stratCard)
    end

    if #weeklySchedules > 0 then
        local scheduleRows = {}
        local remColWidth = math.floor(60 * factor + 0.5)
        local dayColWidth = math.floor(32 * factor + 0.5)
        local timeColWidth = math.floor(40 * factor + 0.5)
        for _, ws in ipairs(weeklySchedules) do
            local remSecs = ws.remainingSecs ~= math.huge and math.max(0, ws.remainingSecs or 0) or 0
            local remDays = math.floor(remSecs / 86400)
            local remHours = math.floor((remSecs % 86400) / 3600)
            local remStr = string.format("%dd %02dh", remDays, remHours)
            if ws.status == "pending" then remStr = "Check"
            elseif ws.status == "stale" then remStr = "~" .. remStr end
            local dayStr = ws.status ~= "pending" and ws.resetAt and os.date("%a", ws.resetAt) or "---"
            local timeStr = ws.status ~= "pending" and ws.resetAt and noctalia.formatTime(noctalia.timeFormat(), ws.resetAt) or "--:--"
            if timeStr:match("^%d:%d%d") then
                timeStr = "0" .. timeStr
            end
            scheduleRows[#scheduleRows + 1] = ui.row({ gap = 6, align = "center", tooltip = ws.tooltip }, {
                ui.glyph({ name = ws.glyph, size = gs(13), color = "secondary" }),
                ui.label({ text = ws.name, fontSize = fs(12), fontWeight = "semibold", color = "on_surface", maxLines = 1 }),
                ui.spacer({ flexGrow = 1 }),
                ui.row({ width = remColWidth, minWidth = remColWidth, justify = "start" }, {
                    ui.label({
                        text = remStr,
                        fontFamily = "monospace",
                        fontSize = fs(11),
                        color = "on_surface_variant",
                    }),
                }),
                ui.row({ width = dayColWidth, minWidth = dayColWidth, justify = "start" }, {
                    ui.label({
                        text = dayStr,
                        fontSize = fs(11),
                        color = "on_surface_variant",
                    }),
                }),
                ui.row({ width = timeColWidth, minWidth = timeColWidth, justify = "start" }, {
                    ui.label({
                        text = timeStr,
                        fontFamily = "monospace",
                        fontSize = fs(11),
                        color = "on_surface_variant",
                    }),
                }),
            })
        end
        local scheduleCard = ui.column(cardStyle(5, nil, nil, 8), {
            ui.row({ gap = 6, align = "center" }, {
                ui.glyph({ name = "calendar", size = gs(14), color = "secondary" }),
                ui.label({
                    text = "Weekly Reset Schedule",
                    fontSize = fs(13), fontWeight = "bold", color = "secondary",
                }),
            }),
            ui.column({ gap = 4, align = "stretch" }, scheduleRows),
        })
        table.insert(creditCards, 1, scheduleCard)
    end

    for baseId, isClaim in pairs(staggerPlan and staggerPlan.optimalClaimProviders or {}) do
        if isClaim then
            local stats = providerStats and providerStats[baseId]
            local pName = stats and stats.name or baseId
            local dashUrl = providerDashboard(baseId)
            local claimCardChildren = {
                ui.row({ gap = 6, align = "center" }, {
                    ui.glyph({ name = "sparkles", size = gs(16), color = "#c084fc" }),
                    ui.label({
                        text = "Optimal Reset Window!",
                        fontSize = fs(13), fontWeight = "bold", color = "#c084fc",
                    }),
                }),
                ui.label({
                    text = string.format("%s · %s", pName, stats and stats.advice and stats.advice.summary or "claim the reset now"),
                    fontSize = fs(11), color = "on_surface",
                }),
            }
            if dashUrl ~= nil then
                claimCardChildren[#claimCardChildren + 1] = ui.button({
                    text = "Open Dashboard",
                    glyph = "external-link",
                    variant = "primary",
                    controlSize = "sm",
                    onClick = function()
                        if type(noctalia.runAsync) == "function" then
                            noctalia.runAsync("xdg-open '" .. dashUrl .. "'")
                        end
                    end,
                })
            end
            local claimCard = ui.column(cardStyle(4, nil, nil, 8), claimCardChildren)
            table.insert(creditCards, 1, claimCard)
        end
    end

    -- Urgent weekly reset alerts: prominently displayed at the top of Column 3
    for _, ws in ipairs(weeklySchedules) do
        if ws.status == "announced" and ws.remainingSecs <= 48 * 3600 and ws.free >= 10 then
            local remHours = math.max(0.1, ws.remainingSecs / 3600)
            local timeStr = remHours < 24 and string.format("%.1fh", remHours) or string.format("%.1fd", remHours / 24)
            local dateStr = ws.resetAt and string.format("%s %s", os.date("%a", ws.resetAt), noctalia.formatTime(noctalia.timeFormat(), ws.resetAt)) or ""
            local alertCard = ui.column(cardStyle(4, "error/0.08", "error/0.30", 8), {
                ui.row({ gap = 6, align = "center" }, {
                    ui.glyph({ name = "flame", size = gs(15), color = "#fb923c" }),
                    ui.label({
                        text = "Weekly Reset Imminent!",
                        fontSize = fs(13), fontWeight = "bold", color = "#fb923c",
                    }),
                }),
                ui.label({
                    text = string.format("%s resets in %s (%s) · %d%% unused quota will expire!",
                        ws.name, timeStr, dateStr, ws.free),
                    fontSize = fs(11), color = "on_surface",
                }),
            })
            table.insert(creditCards, 1, alertCard)
        end
    end

    -- Keep this first-day informational notice below the daily routing advice.
    -- It describes a past observation, independently of stale quota/sprint advice.
    local changeRows = {}
    for _, ws in ipairs(weeklySchedules) do
        local event = ws.change
        if event then
            local function date(at)
                return tonumber(at) and os.date("%d %b %H:%M %Z", at) or "Unknown"
            end
            changeRows[#changeRows + 1] = ui.column({ gap = 2, tooltip = ws.tooltip }, {
                ui.label({ text = ws.name .. (event.kind == "early_renewal"
                    and " · Early renewal observed" or " · Renewal not confirmed"),
                    fontSize = fs(11), fontWeight = "semibold", color = "on_surface" }),
                ui.label({ text = "Before: " .. date(event.previous_reset_at),
                    fontSize = fs(11), color = "on_surface_variant" }),
                ui.label({ text = "Now announced: " .. date(ws.resetAt or event.reset_at),
                    fontSize = fs(11), color = "on_surface_variant" }),
            })
        end
    end
    if #changeRows > 0 then
        creditCards[#creditCards + 1] = ui.column(cardStyle(6, "primary/0.08", "primary/0.25", 8), {
            ui.row({ gap = 6, align = "center" }, {
                ui.glyph({ name = "calendar-clock", size = gs(14), color = "primary" }),
                ui.label({ text = "Weekly reset changed", fontSize = fs(13),
                    fontWeight = "bold", color = "primary" }),
            }),
            ui.column({ gap = 6, align = "stretch" }, changeRows),
        })
    end

    if #creditCards == 0 then
        creditCards[#creditCards + 1] = ui.column(cardStyle(6, nil, nil, 10), {
            ui.row({ gap = 8, align = "center" }, {
                ui.glyph({ name = "info-circle", size = gs(18), color = "on_surface_variant" }),
                ui.label({ text = "No pending reset credits", fontSize = fs(16), color = "on_surface_variant" }),
            }),
        })
    end
    if #sessionCards == 0 then
        sessionCards[#sessionCards + 1] = ui.column(cardStyle(6, nil, nil, 10), {
            ui.row({ gap = 8, align = "center" }, {
                ui.glyph({ name = "info-circle", size = gs(18), color = "on_surface_variant" }),
                ui.label({ text = "No active session metrics", fontSize = fs(15), color = "on_surface_variant" }),
            }),
        })
    end
    if #weeklyCards == 0 then
        weeklyCards[#weeklyCards + 1] = ui.column(cardStyle(6, nil, nil, 10), {
            ui.row({ gap = 8, align = "center" }, {
                ui.glyph({ name = "info-circle", size = gs(18), color = "on_surface_variant" }),
                ui.label({ text = "No active weekly metrics", fontSize = fs(15), color = "on_surface_variant" }),
            }),
        })
    end

    local colHeaderBoxSize = math.floor(30 * factor + 0.5)
    local col1 = ui.column({
        key = "col-session",
        gap = 6,
        flexGrow = 1.15,
        align = "stretch",
        paddingH = 4,
        paddingV = 2,
    }, {
        ui.row({ gap = 8, align = "center", paddingH = 4, paddingV = 2 }, {
            ui.row({
                width = colHeaderBoxSize, height = colHeaderBoxSize, radius = 7,
                fill = "primary/0.14", align = "center", justify = "center",
            }, {
                ui.glyph({ name = "clock", size = gs(18), color = "primary" }),
            }),
            ui.label({ text = "Session (5h)", fontSize = fs(18), fontWeight = "bold", color = "on_surface" }),
        }),
        ui.separator({ orientation = "horizontal", color = "outline_variant", opacity = 0.16 }),
        ui.scroll({ flexGrow = 1, gap = 6, align = "stretch" }, sessionCards),
    })

    local col2 = ui.column({
        key = "col-weekly",
        gap = 6,
        flexGrow = 1.15,
        align = "stretch",
        paddingH = 4,
        paddingV = 2,
    }, {
        ui.row({ gap = 8, align = "center", paddingH = 4, paddingV = 2 }, {
            ui.row({
                width = colHeaderBoxSize, height = colHeaderBoxSize, radius = 7,
                fill = "secondary/0.14", align = "center", justify = "center",
            }, {
                ui.glyph({ name = "calendar", size = gs(18), color = "secondary" }),
            }),
            ui.label({ text = "Weekly (7d)", fontSize = fs(18), fontWeight = "bold", color = "on_surface" }),
        }),
        ui.separator({ orientation = "horizontal", color = "outline_variant", opacity = 0.16 }),
        ui.scroll({ flexGrow = 1, gap = 6, align = "stretch" }, weeklyCards),
    })

    local col3 = ui.column({
        key = "col-credits",
        gap = 6,
        flexGrow = 0.90,
        align = "stretch",
        paddingH = 4,
        paddingV = 2,
    }, {
        ui.row({ gap = 8, align = "center", paddingH = 4, paddingV = 2 }, {
            ui.row({
                width = colHeaderBoxSize, height = colHeaderBoxSize, radius = 7,
                fill = "primary/0.14", align = "center", justify = "center",
            }, {
                ui.glyph({ name = "calendar-clock", size = gs(18), color = "primary" }),
            }),
            ui.label({ text = "Resets & Credits", fontSize = fs(18), fontWeight = "bold", color = "on_surface" }),
        }),
        ui.separator({ orientation = "horizontal", color = "outline_variant", opacity = 0.16 }),
        ui.scroll({ flexGrow = 1, gap = 6, align = "stretch" }, creditCards),
    })

    local columns = {
        col1,
        ui.box({ width = 1, fill = "outline_variant/0.20" }),
        col2,
        ui.box({ width = 1, fill = "outline_variant/0.20" }),
        col3,
    }

    local mainChildren = {
        ui.row({ gap = 8, align = "center" }, topRowChildren),
        ui.separator({ orientation = "horizontal", color = "outline_variant", opacity = 0.20 }),
        ui.row({ gap = 12, flexGrow = 1, align = "stretch" }, columns),
    }
    -- Keep a failed overall refresh visible even when an earlier report exists.
    if failure.code ~= "" then table.insert(mainChildren, 3, errorBlock(typo)) end

    panel.render(ui.column({
        gap = 8,
        paddingH = 16,
        paddingV = 10,
        flexGrow = 1,
        align = "stretch",
        fill = "surface/0.95",
        radius = 16,
        border = "outline_variant/0.25",
        borderWidth = 1,
    }, mainChildren))
end

function render()
    local typo = getTypography()
    local fs = typo.fontSize
    local gs = typo.glyphSize
    local candidates = panelCandidates()
    if failure.code ~= "" and #candidates == 0 then
        panel.render(ui.column({ flexGrow = 1, padding = 14, align = "center", justify = "center" }, {
            ui.column({ gap = 10, width = 320 }, {
                ui.row({ gap = 8, align = "center" }, {
                    ui.glyph({ name = "scale", size = gs(18), color = "primary" }),
                    ui.label({ text = noctalia.tr("ui.title"), fontSize = fs(15),
                               fontWeight = "bold", color = "on_surface" }),
                }),
                errorBlock(typo),
            }),
        }))
        return
    end

    if #candidates > 0 then
        renderColumns(candidates, typo)
    else
        panel.render(ui.column({ flexGrow = 1, padding = 14, align = "center", justify = "center" }, {
            ui.column({ gap = 10, width = 320 }, {
                ui.row({ gap = 8, align = "center" }, {
                    ui.glyph({ name = "scale", size = gs(18), color = "primary" }),
                    ui.label({ text = noctalia.tr("ui.title"), fontSize = fs(15),
                               fontWeight = "bold", color = "on_surface" }),
                }),
                ui.label({
                    text = noctalia.tr("ui.no_providers") or "No providers configured or reachable.",
                    fontSize = fs(13),
                    color = "on_surface_variant",
                }),
            }),
        }))
    end
end

-- ── Lifecycle & Event Wiring ──────────────────────────────────────────────────

noctalia.state.watch("report", function(value)
    if type(value) == "table" then
        report = value
        failure = NO_FAILURE
        render()
    end
end)

noctalia.state.watch("error", function(value)
    failure = asFailure(value)
    render()
end)

noctalia.state.watch("polling", function(value)
    polling = value == true
    render()
end)

noctalia.state.watch("refresh_queued", function(value)
    refreshQueued = value == true
    render()
end)

function onOpen(context)
    if type(context) == "string" and context ~= "" then
        noctalia.state.set("selected", context)
    end
    requestRefresh()
    report = noctalia.state.get("report")
    failure = asFailure(noctalia.state.get("error"))
    polling = noctalia.state.get("polling") == true
    refreshQueued = noctalia.state.get("refresh_queued") == true
    panel.setWantsSecondTicks(true)
    render()
end

function update()
    render()
end

function onClose()
    panel.setWantsSecondTicks(false)
end

function onKey(chord, pressed)
    if not pressed then return end
    local lower = tostring(chord or ""):lower()
    if lower == "escape" then
        if type(panel.close) == "function" then panel.close() end
    elseif lower == "r" then
        requestRefresh()
    end
end

render()
