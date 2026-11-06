--!nonstrict
-- Bar capsule. Draws what the poller published: one provider, or the busiest few
-- when `provider_limit` is raised. Settings are per-instance, so a second capsule
-- can follow a second provider.

local vendor = tostring(noctalia.getConfig("vendor") or "auto")
local account = noctalia.string.trim(tostring(noctalia.getConfig("account") or ""))
local extras = tostring(noctalia.getConfig("extras") or "countdown")
-- Named after the core `sysmon` widget's own keys, so a reading in this capsule
-- is configured the same way as the CPU one beside it.
local visualization = tostring(noctalia.getConfig("visualization") or "gauge")
local showValue = noctalia.getConfig("show_value") ~= false
local showGlyph = noctalia.getConfig("show_glyph") ~= false
local glyphAfter = tostring(noctalia.getConfig("glyph_position") or "before") == "after"
local limit = math.max(1, math.min(4, tonumber(noctalia.getConfig("provider_limit")) or 1))
local showName = noctalia.getConfig("show_name") == true
local colorByUsage = noctalia.getConfig("color_by_usage") ~= false

local report = nil

local shared = require("./shared.luau")
local providerGlyph, baseProvider = shared.providerGlyph, shared.baseProvider
local fixedCountdown = shared.fixedCountdown
local ratio, headline, elapsedPercent = shared.ratio, shared.headline, shared.elapsedPercent
local modelHeadlines, isCritical, dualMetrics = shared.modelHeadlines, shared.isCritical, shared.dualMetrics
local pace, SEVERITY_RANK = shared.pace, shared.SEVERITY_RANK
local NO_FAILURE, asFailure = shared.NO_FAILURE, shared.asFailure
local unavailable = shared.unavailable
local getTypography = shared.getTypography

local function getBarTypography()
    local barSetting = noctalia.getConfig("bar_font_scale")
    if barSetting == nil or barSetting == "" or barSetting == "inherit" then
        barSetting = noctalia.getConfig("font_scale")
    end
    return getTypography(barSetting)
end

local failure = NO_FAILURE
local scrollOffset = 0
local scrollTargetId = nil

-- ── Report helpers ────────────────────────────────────────────────────────────

local function entries() return shared.entries(report) end

local function wantedEntryId()
    if vendor == "auto" or account == "" then return vendor end
    return vendor .. "@" .. account
end

local function matchesAntigravity(entry)
    return baseProvider(entry.id) == "antigravity"
        and (account == "" or entry.id == "antigravity@" .. account)
end

local function isModelVendor()
    return vendor == "gemini" or vendor == "claude-oss" or vendor == "claude_oss"
end

local function rank(entry)
    local metric = headline(entry)
    if metric == nil then return -1, -1 end
    return SEVERITY_RANK[tostring(metric.severity or "")] or 0, tonumber(metric.percent) or 0
end

local function isPinnedHidden()
    if vendor == "auto" then return false end
    local wanted = wantedEntryId()
    local base = baseProvider(wanted)
    if shared.isModelHidden(wanted, wanted) or shared.isModelHidden(base, base) then
        return true
    end
    if (wanted == "claude-oss" or wanted == "claude_oss" or vendor == "claude-oss" or vendor == "claude_oss")
        and shared.isModelHidden("antigravity", "Claude & GPT OSS") then
        return true
    end
    if (wanted == "gemini" or vendor == "gemini")
        and shared.isModelHidden("antigravity", "Gemini") then
        return true
    end
    return false
end

-- A pinned vendor shows only itself. "auto" ranks by severity then percentage,
-- so the provider closest to running out is the one on the bar. `primary` breaks
-- ties.
local function shown()
    if isPinnedHidden() then return {}, 0 end
    local all = entries()
    if vendor ~= "auto" then
        local wanted = wantedEntryId()
        for _, entry in ipairs(all) do
            -- A pinned provider that stopped reporting leaves the capsule empty
            -- rather than holding a number nothing is refreshing.
            if entry.id == wanted then
                if unavailable(entry) and not shared.readFailure(entry) then return {}, 0 end
                return { entry }, 0
            end
        end
        if isModelVendor() then
            for _, entry in ipairs(all) do
                if matchesAntigravity(entry) then
                    if unavailable(entry) and not shared.readFailure(entry) then return {}, 0 end
                    return { entry }, 0
                end
            end
        end
        -- A statusline account can replace the default provider entry entirely.
        if account == "" then
            for _, entry in ipairs(all) do
                if baseProvider(entry.id) == vendor then return { entry }, 0 end
            end
        end
        return {}, 0
    end

    local ready = {}
    for _, entry in ipairs(all) do
        -- A provider whose service is down drops out on the first report that
        -- says so, rather than sitting there with a frozen reading. Not counted
        -- as hidden either: hidden means the panel has more to show.
        if (entry.status ~= "error" and not unavailable(entry)) or shared.readFailure(entry) then
            ready[#ready + 1] = entry
        end
    end
    local primary = type(report) == "table" and report.primary or nil
    -- The CLI names its primary either as a provider or as one of its accounts,
    -- so an entry answers to the whole id and to the part before the "@".
    local function isPrimary(entry)
        return primary ~= nil
            and (tostring(entry.id) == primary or baseProvider(entry.id) == primary)
    end
    table.sort(ready, function(a, b)
        local aRank, aPct = rank(a)
        local bRank, bPct = rank(b)
        if aRank ~= bRank then return aRank > bRank end
        if aPct ~= bPct then return aPct > bPct end
        local aPrimary = isPrimary(a)
        local bPrimary = isPrimary(b)
        if aPrimary ~= bPrimary then return aPrimary end
        return tostring(a.id) < tostring(b.id)
    end)

    if scrollTargetId ~= nil then
        local found = false
        for index, entry in ipairs(ready) do
            if entry.id == scrollTargetId then
                scrollOffset = index - 1
                found = true
                break
            end
        end
        if not found then scrollTargetId = nil end
    end

    if scrollOffset > 0 and #ready > 1 then
        local offset = scrollOffset % #ready
        local rotated = {}
        for i = 1, #ready do
            local idx = ((i - 1 + offset) % #ready) + 1
            rotated[i] = ready[idx]
        end
        ready = rotated
    end

    local picked = {}
    for i = 1, math.min(limit, #ready) do picked[i] = ready[i] end
    if #picked == 0 then return {}, 0 end
    if limit == 1 then return picked, 0 end
    return picked, #ready - #picked
end

local function rawReportEntries()
    if type(report) ~= "table" or type(report.entries) ~= "table" then return {} end
    return report.entries
end

-- The pinned entry when the report carries it and its source is down. `shown()`
-- withholds its numbers; the tooltip is still the place that says why.
local function pinnedDown()
    if vendor == "auto" or isPinnedHidden() then return nil end
    local wanted = wantedEntryId()
    for _, entry in ipairs(rawReportEntries()) do
        if entry.id == wanted and unavailable(entry) then return entry end
        if isModelVendor() and matchesAntigravity(entry) and unavailable(entry) then
            return entry
        end
    end
    if account == "" then
        for _, entry in ipairs(rawReportEntries()) do
            if baseProvider(entry.id) == vendor and unavailable(entry)
                and not shared.isModelHidden(entry.id, entry.display_name or entry.id) then
                return entry
            end
        end
    end
    return nil
end

local function failedEntries()
    local failed = {}
    for _, entry in ipairs(rawReportEntries()) do
        if type(entry) == "table" and unavailable(entry)
            and not shared.isModelHidden(entry.id, entry.display_name or entry.name or entry.id) then
            failed[#failed + 1] = entry
        end
    end
    return failed
end

local function appendDiagnostic(rows, entry)
    local issue = shared.diagnostic(entry)
    if not issue then return end
    rows[#rows + 1] = { key = tostring(entry.display_name or entry.id), value = noctalia.tr(issue.titleKey) }
    local action = noctalia.tr(issue.actionKey, issue.actionArgs)
    if issue.command then action = action .. " " .. issue.command end
    rows[#rows + 1] = { key = noctalia.tr("ui.diagnostic.recommended_action"), value = action }
    if issue.detail ~= "" then
        rows[#rows + 1] = { key = noctalia.tr("ui.details"), value = issue.detail }
    end
end

-- `calm` is the colour when the CLI has raised nothing, and every colour when
-- the tint is switched off.
local function severityRole(metric, calm)
    if not colorByUsage then return calm end
    return shared.severityRole(metric, calm)
end

-- A capsule pinned to a named account keeps the account in its name: two
-- capsules on two accounts are the same product, and the suffix is what tells
-- them apart. Fixed for that capsule, so it costs no width between reads.
local function shortName(entry)
    if vendor == "gemini" then return "Gemini" end
    if vendor == "claude-oss" or vendor == "claude_oss" then return "Claude & GPT OSS" end
    local name = tostring(entry.display_name or entry.name or entry.id or "")
    if vendor ~= "auto" and account ~= "" then return name end
    -- Anywhere else it is the panel's business: under "auto" a name that gains
    -- an account on one read and loses it on the next would resize the capsule.
    return (name:gsub("%s*·.*$", ""))
end

-- ── Rendering ─────────────────────────────────────────────────────────────────

local function metricFill(metric)
    if not colorByUsage then return "primary" end
    if isCritical(metric) then return "error" end
    return severityRole(metric, "primary")
end

-- Upper and bigger bar (height 6, radius 3): 5h limit (session window)
-- Lower and thinner bar (height 3, radius 2): weekly limit (7-day rate limit)
local function bars(mShort, mWeekly, width, typo)
    if mShort == nil and mWeekly == nil then return nil end

    local pShort = mShort and tonumber(mShort.percent)
    local pWeekly = mWeekly and tonumber(mWeekly.percent)

    if pShort == nil and pWeekly == nil then return nil end

    local fShort = mShort and metricFill(mShort) or "primary"
    local fWeekly = mWeekly and metricFill(mWeekly) or "primary"

    local factor = typo and typo.factor or 1.0
    local w = math.floor(width * factor + 0.5)

    -- Upper / bigger bar (height 6): 5h limit (or the single available metric)
    local topProgress = pShort ~= nil and pShort or (pWeekly or 0)
    local topFill = pShort ~= nil and fShort or fWeekly

    local stack = {
        ui.progress({
            progress = ratio(topProgress),
            fill = topFill,
            track = "on_surface/0.14",
            radius = 3,
            width = w,
            height = 6,
        }),
    }

    -- Lower / thinner bar (height 3): weekly limit
    if pWeekly ~= nil and pShort ~= nil then
        stack[#stack + 1] = ui.progress({
            progress = ratio(pWeekly),
            fill = fWeekly,
            track = "on_surface/0.10",
            radius = 2,
            width = w,
            height = 3,
        })
    end

    return ui.column({ gap = 2, align = "center" }, stack)
end

-- Compact vertical gauge: a track column holding a level box pinned to the bottom.
-- Ideal for vertical bars and docks.
local function miniGauge(percent, tint)
    local level = type(percent) == "number" and math.max(0, math.min(100, percent)) / 100 or 0
    local h = 14
    local w = 6
    local filled = level <= 0 and 1 or math.max(2, math.floor(h * level + 0.5))
    return ui.column({
        key = "mini-gauge",
        width = w,
        height = h,
        minWidth = w,
        minHeight = h,
        radius = 2,
        fill = "on_surface/0.16",
        justify = "end",
        align = "stretch",
    }, {
        ui.box({
            key = "level",
            width = w,
            height = filled,
            radius = 2,
            fill = tint,
        }),
    })
end

local function chip(entry, flagged, isVert, typo)
    local fs = typo and typo.fontSize or function(s) return s end
    local gs = typo and typo.glyphSize or function(s) return s end
    if shared.readFailure(entry) then
        local nodes = { ui.label({ text = "—", fontSize = fs(11), color = "on_surface_variant" }) }
        if showGlyph then
            table.insert(nodes, glyphAfter and #nodes + 1 or 1,
                ui.glyph({ name = providerGlyph(entry.id), size = gs(14), color = "error" }))
        end
        if isVert then
            return ui.column({ gap = 2, align = "center" }, nodes)
        end
        return ui.row({ gap = 5, align = "center" }, nodes)
    end
    local metric = headline(entry)
    -- Balance-only providers carry no percentage; the capsule shows their
    -- amount where a quota vendor shows its percentage.
    local balance = metric == nil and shared.balanceText(entry) or nil
    local tint = severityRole(metric, "on_surface")
    local percent = metric ~= nil and tonumber(metric.percent) or nil
    local text = shared.metricText(metric) or balance or "—"
    local fill = severityRole(metric, "primary")
    -- The mark says which provider, never how full it is; severity rides on the
    -- reading and the gauge. A failed read is the one thing that colours it, and
    -- colours rather than appends: a glyph that exists only while the read fails
    -- would shove the neighbouring widget once per cycle. The tooltip still
    -- spells the failure out.
    local submodels = modelHeadlines(entry)
    if vendor == "gemini" then
        local filtered = {}
        for _, m in ipairs(submodels) do
            if m.model:lower():find("gemini") then filtered[#filtered + 1] = m end
        end
        submodels = filtered
    elseif vendor == "claude-oss" or vendor == "claude_oss" then
        local filtered = {}
        for _, m in ipairs(submodels) do
            if m.model:lower():find("claude") or m.model:lower():find("oss") then
                filtered[#filtered + 1] = m
            end
        end
        submodels = filtered
    end
    local hasSubmodels = #submodels > 0

    local glyph = (showGlyph and not hasSubmodels)
        and ui.glyph({ name = providerGlyph(entry.id), size = gs(14),
                       color = flagged and "error" or "on_surface" }) or nil
    local pct = nil
    if showValue or hasSubmodels then
        if hasSubmodels then
            local parts = {}
            for _, item in ipairs(submodels) do
                local shownMetric = item.blockingMetric or item.metric
                local mTint = colorByUsage and isCritical(shownMetric) and "error"
                    or severityRole(shownMetric, "on_surface")
                local mPct = tonumber(shownMetric.percent) or 0
                local mFill = isCritical(shownMetric) and "error"
                    or severityRole(shownMetric, "primary")
                local rowChildren = {}
                local modelGlyph = showGlyph and ui.glyph({
                        name = item.glyph or providerGlyph(entry.id),
                        size = gs(13),
                        color = "on_surface",
                    }) or nil
                if modelGlyph and not glyphAfter then rowChildren[#rowChildren + 1] = modelGlyph end

                local mMetrics = type(item.metrics) == "table" and item.metrics or { item.metric }
                local mShort, mWeekly = dualMetrics(mMetrics)
                local barNode = bars(mShort, mWeekly, 22, typo)

                if visualization == "gauge" and not isVert and not glyphAfter and barNode ~= nil then
                    rowChildren[#rowChildren + 1] = barNode
                end
                if showValue then
                    rowChildren[#rowChildren + 1] = ui.label({
                        text = string.format("%d%%", mPct),
                        fontSize = fs(11),
                        fontWeight = "semibold",
                        color = mTint,
                        maxLines = 1,
                    })
                end
                if visualization == "gauge" and not isVert and glyphAfter and barNode ~= nil then
                    rowChildren[#rowChildren + 1] = barNode
                end
                if (extras == "countdown" or extras == "both") and not isVert then
                    local left = fixedCountdown(shownMetric)
                    if left ~= "" then
                        rowChildren[#rowChildren + 1] = ui.label({
                            text = left,
                            fontSize = fs(10),
                            color = "on_surface_variant",
                            maxLines = 1,
                        })
                    end
                end
                if modelGlyph and glyphAfter then rowChildren[#rowChildren + 1] = modelGlyph end
                if #parts > 0 and #rowChildren > 0 then
                    parts[#parts + 1] = isVert
                        and ui.box({ width = 10, height = 1, fill = "on_surface_variant", opacity = 0.25 })
                        or ui.label({
                            text = "·",
                            fontSize = fs(11),
                            color = "on_surface_variant",
                        })
                end
                if #rowChildren > 0 then
                    parts[#parts + 1] = isVert
                        and ui.column({ gap = 2, align = "center" }, rowChildren)
                        or ui.row({ gap = 3, align = "center" }, rowChildren)
                end
            end
            pct = isVert
                and ui.column({ gap = 3, align = "center" }, parts)
                or ui.row({ gap = 7, align = "center" }, parts)
        else
            pct = ui.label({
                text = text,
                fontSize = fs(11),
                fontWeight = "semibold",
                color = tint,
                maxLines = 1,
            })
        end
    end

    if isVert then
        local vertNodes = {}
        if not glyphAfter and glyph ~= nil then vertNodes[#vertNodes + 1] = glyph end
        if percent ~= nil and visualization == "gauge" and not hasSubmodels then
            vertNodes[#vertNodes + 1] = miniGauge(percent, fill)
        end
        if pct ~= nil then vertNodes[#vertNodes + 1] = pct end
        if glyphAfter and glyph ~= nil then vertNodes[#vertNodes + 1] = glyph end
        return ui.column({ gap = 2, align = "center" }, vertNodes)
    end

    local name = showName and ui.label({ text = shortName(entry), fontSize = fs(11),
                                         color = "on_surface_variant", maxLines = 1 }) or nil

    local nodes = {}
    local function add(node) if node ~= nil then nodes[#nodes + 1] = node end end

    if not glyphAfter then add(glyph) end
    add(name)
    if visualization == "gauge" and not hasSubmodels then
        local mShort, mWeekly = dualMetrics(entry.metrics)
        local barNode = bars(mShort, mWeekly, 32, typo)
        if barNode == nil and percent ~= nil then
            barNode = bars({ percent = percent, severity = metric and metric.severity }, nil, 32, typo)
        end
        add(barNode)
    end
    add(pct)
    if glyphAfter then add(glyph) end

    if (extras == "countdown" or extras == "both") and not hasSubmodels then
        local left = fixedCountdown(metric)
        if left ~= "" then
            add(ui.label({ text = left, fontSize = fs(10), color = "on_surface_variant", maxLines = 1 }))
        end
    end
    if extras == "pace" or extras == "both" then
        local _, points, word = pace(metric and metric.detail)
        if points ~= nil then
            local ahead = word == "ahead"
            local role = ahead and "secondary" or "on_surface_variant"
            add(ui.row({ gap = 0, align = "center" }, {
                ui.glyph({ name = ahead and "arrow-up" or "arrow-down", size = gs(10), color = role }),
                ui.label({ text = tostring(points), fontSize = fs(10), color = role, maxLines = 1 }),
            }))
        end
    end

    if entry.stale == true then
        add(ui.glyph({ name = "clock-exclamation", size = gs(11), color = "secondary" }))
    end
    return ui.row({ gap = 5, align = "center" }, nodes)
end

local function formatDualMetric(m1, m2)
    m1 = type(m1) == "table" and m1 or nil
    m2 = type(m2) == "table" and m2 or nil
    if m1 == nil and m2 == nil then return "" end

    local str1 = shared.metricText(m1)
    local str2 = shared.metricText(m2)

    -- If one window is exhausted, its reset is the real unlock time. Showing
    -- the shorter session reset would promise availability while the weekly
    -- limit still blocks the model.
    local blocking = shared.blockingMetric(m1 and { m1, m2 } or { m2 })
    local c1 = m1 ~= nil and fixedCountdown(m1) or ""
    local c2 = m2 ~= nil and fixedCountdown(m2) or ""

    local left = ""
    local p1Num = tonumber(m1 and m1.percent) or 0
    local p2Num = tonumber(m2 and m2.percent) or 0
    if blocking ~= nil and (p2Num >= 100 or p1Num < 100) then
        left = fixedCountdown(blocking)
    elseif c1 ~= "" and c2 ~= "" then
        left = string.format("%s · 7d: %s", c1, c2)
    elseif c1 ~= "" then
        left = c1
    elseif c2 ~= "" then
        left = c2
    end

    local val = str1 or str2 or ""
    if str1 ~= nil and str2 ~= nil and str2 ~= "" then
        val = val .. " / " .. str2
    end
    return val, left
end

local function tooltip(picked, hidden)
    if failure.code ~= "" then
        local key = "ui.error." .. failure.code
        local rows = { { key = noctalia.tr(key), value = noctalia.tr(key .. "_hint") } }
        if failure.detail ~= "" then
            rows[2] = { key = noctalia.tr("ui.details"), value = failure.detail }
        end
        return rows
    end
    if #picked == 0 then
        -- A pinned provider the report still lists is configured; its source is
        -- what is down. Calling that "not configured" would blame the user's
        -- config for a failure the CLI already worded.
        local down = pinnedDown()
        if down ~= nil then
            local rows = {}
            appendDiagnostic(rows, down)
            return rows
        end
        if vendor == "auto" then
            local rows = {}
            for _, entry in ipairs(failedEntries()) do appendDiagnostic(rows, entry) end
            if #rows > 0 then return rows end
        end
        local waiting = vendor == "auto" and noctalia.tr("ui.waiting")
            or noctalia.tr("ui.not_configured", { vendor = wantedEntryId() })
        return { { key = noctalia.tr("ui.title"), value = waiting } }
    end

    local rows = {}
    for _, entry in ipairs(picked) do
        local title = tostring(entry.display_name or entry.id)
        if entry.status == "error" then
            appendDiagnostic(rows, entry)
        else
            local submodels = modelHeadlines(entry)
            if vendor == "gemini" then
                local filtered = {}
                for _, m in ipairs(submodels) do
                    if m.model:lower():find("gemini") then filtered[#filtered + 1] = m end
                end
                submodels = filtered
            elseif vendor == "claude-oss" or vendor == "claude_oss" then
                local filtered = {}
                for _, m in ipairs(submodels) do
                    if m.model:lower():find("claude") or m.model:lower():find("oss") then
                        filtered[#filtered + 1] = m
                    end
                end
                submodels = filtered
            end
            if #submodels > 0 then
                for _, item in ipairs(submodels) do
                    local mMetrics = type(item.metrics) == "table" and item.metrics or { item.metric }
                    local mShort, mWeekly = dualMetrics(mMetrics)
                    local val, left = formatDualMetric(mShort, mWeekly)
                    if val ~= "" then
                        rows[#rows + 1] = { key = item.displayName or item.model, value = val }
                        if left ~= "" then
                            rows[#rows + 1] = { key = "Reset", value = left }
                        end
                    end
                end
            else
                local metrics = type(entry.metrics) == "table" and entry.metrics or {}
                local mShort, mWeekly = dualMetrics(metrics)
                local val, left = formatDualMetric(mShort, mWeekly)
                if val ~= "" then
                    rows[#rows + 1] = { key = title, value = val }
                    if left ~= "" then
                        rows[#rows + 1] = { key = "Reset", value = left }
                    end
                else
                    -- A balance-only provider carries no metric: the tooltip shows
                    -- the same balance the capsule does, ahead of the plan name.
                    local balance = shared.balanceText(entry)
                    if balance ~= nil then
                        rows[#rows + 1] = { key = title, value = balance }
                    elseif entry.plan ~= nil and tostring(entry.plan) ~= "" then
                        rows[#rows + 1] = { key = title, value = tostring(entry.plan) }
                    end
                end
            end
            if entry.stale == true then
                rows[#rows + 1] = { key = noctalia.tr("ui.updated"), value = noctalia.tr("ui.stale_hint") }
            end
        end
    end
    if vendor == "auto" then
        for _, entry in ipairs(failedEntries()) do
            if not shared.readFailure(entry) then appendDiagnostic(rows, entry) end
        end
    end
    if hidden > 0 then
        rows[#rows + 1] = { key = noctalia.tr("ui.hidden_label"), value = noctalia.tr("ui.hidden_value", { count = hidden }) }
    end
    if #rows == 0 then
        rows[#rows + 1] = { key = noctalia.tr("ui.title"), value = noctalia.tr("ui.no_usage") }
    end
    return rows
end

local function render()
    if isPinnedHidden() then
        if type(barWidget.setVisible) == "function" then
            barWidget.setVisible(false)
        end
        return
    end

    if type(barWidget.setVisible) == "function" then
        barWidget.setVisible(true)
    end

    local isVert = type(barWidget.isVertical) == "function" and barWidget.isVertical() or false
    local picked, hidden = shown()
    -- A failed read does not erase the last one: the numbers stay, flagged,
    -- until a good report replaces them. Erasing them blanked the capsule over a
    -- transient spawn failure.
    local flagged = failure.code ~= "" and #picked > 0
    local typo = getBarTypography()
    local fs = typo.fontSize
    local gs = typo.glyphSize

    local children = {}
    for _, entry in ipairs(picked) do
        -- Two providers run together on a gap alone: the countdown of the first
        -- reads as part of the second. A dot, not a rule -- a vertical
        -- `ui.separator` in a row came out two pixels wide by one tall.
        if #children > 0 then
            children[#children + 1] = isVert
                and ui.box({ width = 12, height = 1, fill = "on_surface_variant", opacity = 0.3 })
                or ui.label({ text = "·", fontSize = fs(11), color = "on_surface_variant" })
        end
        children[#children + 1] = chip(entry, flagged, isVert, typo)
    end

    if #children == 0 then
        -- One glyph, coloured by the state. A pinned provider that is down or
        -- waiting uses its own glyph so the capsule remains identifiable.
        local down = pinnedDown()
        if down == nil and vendor == "auto" then down = failedEntries()[1] end
        local glyphName = (down ~= nil and providerGlyph(down.id))
            or (vendor ~= "auto" and providerGlyph(wantedEntryId()))
            or "scale"
        children[1] = ui.glyph({
            name = glyphName, size = gs(14),
            color = (failure.code ~= "" or down ~= nil) and "error" or "on_surface_variant",
        })
    elseif hidden > 0 then
        children[#children + 1] = ui.label({ text = "+" .. tostring(hidden), fontSize = fs(10),
                                             color = "on_surface_variant", maxLines = 1 })
    end

    if isVert then
        barWidget.render(ui.column({ gap = 5, align = "center" }, children))
    else
        barWidget.render(ui.row({ gap = 7, align = "center" }, children))
    end
    barWidget.setTooltip(tooltip(picked, hidden))
end

-- ── Wiring ────────────────────────────────────────────────────────────────────

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

function onClick()
    local picked = shown()
    -- One panel serves every capsule and is not told which one opened it.
    local targetId = picked[1] ~= nil and picked[1].id or wantedEntryId()
    if vendor == "gemini" then
        targetId = "gemini"
    elseif vendor == "claude-oss" or vendor == "claude_oss" then
        targetId = "claude-oss"
    end
    noctalia.state.set("selected", targetId)
    noctalia.togglePanel("miguelfm/ai-triage:panel")
end

function onScroll(_axis, steps, _startsGesture)
    if vendor ~= "auto" then return end
    local ready = {}
    for _, entry in ipairs(entries()) do
        if (entry.status ~= "error" and not unavailable(entry)) or shared.readFailure(entry) then
            ready[#ready + 1] = entry
        end
    end
    if #ready <= 1 then return end

    if steps > 0 then
        scrollTargetId = nil
        scrollOffset = (scrollOffset + 1) % #ready
    elseif steps < 0 then
        scrollTargetId = nil
        scrollOffset = (scrollOffset - 1 + #ready) % #ready
    end
    local picked = shown()
    scrollTargetId = picked[1] ~= nil and picked[1].id or nil
    render()
end

report = noctalia.state.get("report")
failure = asFailure(noctalia.state.get("error"))

-- Live countdowns without waking the CLI.
noctalia.setUpdateInterval(30000)
render()

function update()
    render()
end
