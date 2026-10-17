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

local quotaWindow = tostring(noctalia.getConfig("quota_window") or "auto")
if quotaWindow ~= "session" and quotaWindow ~= "weekly" and quotaWindow ~= "monthly" then quotaWindow = "auto" end
local usageDisplay = tostring(noctalia.getConfig("usage_display") or "used")
if usageDisplay ~= "remaining" then usageDisplay = "used" end
local autoProviders = noctalia.getConfig("auto_providers")

local report = nil

local shared = require("./shared.luau")
local providerGlyph, baseProvider = shared.providerGlyph, shared.baseProvider
local fixedCountdown = shared.fixedCountdown
local ratio, headline = shared.ratio, shared.headline
local modelHeadlines, isCritical, dualMetrics = shared.modelHeadlines, shared.isCritical, shared.dualMetrics
local pace, SEVERITY_RANK = shared.pace, shared.SEVERITY_RANK
local NO_FAILURE, asFailure = shared.NO_FAILURE, shared.asFailure
local unavailable = shared.unavailable

local failure = NO_FAILURE
local scrollOffset = 0
local scrollTargetId = nil

-- ── Report helpers ────────────────────────────────────────────────────────────

local function entries()
    local all = shared.entries(report)
    if vendor ~= "auto" or autoProviders == nil
        or (type(autoProviders) == "table" and next(autoProviders) == nil) then return all end
    local filtered = {}
    for _, entry in ipairs(all) do
        if type(autoProviders) == "table" then
            for _, id in ipairs(autoProviders) do
                if type(id) == "string" and (entry.id == id or baseProvider(entry.id) == id) then
                    filtered[#filtered + 1] = entry
                    break
                end
            end
        end
    end
    return filtered
end

-- Model pools stay in the panel and tooltip; the bar follows shared family quotas.
local function barEntry(entry)
    if baseProvider(entry.id) ~= "antigravity" then return entry end
    local visible = {}
    for key, value in pairs(entry) do visible[key] = value end
    visible.metrics = {}
    for _, metric in ipairs(type(entry.metrics) == "table" and entry.metrics or {}) do
        if type(metric) == "table" and metric.model_pool ~= true then
            visible.metrics[#visible.metrics + 1] = metric
        end
    end
    return visible
end

local function capsuleMetric(entry) return shared.capsuleMetric(barEntry(entry), quotaWindow) end
local function gaugeMetrics(metrics, selected)
    if quotaWindow ~= "auto" then return selected, nil end
    return dualMetrics(metrics)
end

local function wantedEntryId()
    if vendor == "auto" or account == "" then return vendor end
    return vendor .. "@" .. account
end

local function rank(entry)
    local metric = headline(barEntry(entry))
    if metric == nil then return -1, -1 end
    return SEVERITY_RANK[tostring(metric.severity or "")] or 0, tonumber(metric.percent) or -1
end

-- A pinned vendor shows only itself. "auto" ranks by severity then percentage,
-- so the provider closest to running out is the one on the bar. `primary` breaks
-- ties.
local function shown()
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

-- The pinned entry when the report carries it and its source is down. `shown()`
-- withholds its numbers; the tooltip is still the place that says why.
local function pinnedDown()
    if vendor == "auto" then return nil end
    local wanted = wantedEntryId()
    local all = type(report) == "table" and type(report.entries) == "table" and report.entries or {}
    for _, entry in ipairs(all) do
        if type(entry) == "table" and entry.id == wanted and unavailable(entry) then return entry end
    end
    return nil
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
local function bars(mShort, mWeekly, width)
    if mShort == nil and mWeekly == nil then return nil end

    local pShort = shared.displayPercent(mShort, usageDisplay)
    local pWeekly = shared.displayPercent(mWeekly, usageDisplay)

    if pShort == nil and pWeekly == nil then return nil end

    local fShort = mShort and metricFill(mShort) or "primary"
    local fWeekly = mWeekly and metricFill(mWeekly) or "primary"

    -- Upper / bigger bar (height 6): 5h limit (or the single available metric)
    local topProgress = pShort ~= nil and pShort or (pWeekly or 0)
    local topFill = pShort ~= nil and fShort or fWeekly

    local stack = {
        ui.progress({
            progress = ratio(topProgress),
            fill = topFill,
            track = "on_surface/0.14",
            radius = 3,
            width = width,
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
            width = width,
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

local function withCountdown(value, metric, isVert)
    if isVert or (extras ~= "countdown" and extras ~= "both") then return value end
    local left = fixedCountdown(metric)
    if left == "" then return value end
    local countdown = ui.label({ text = left, fontSize = 12, color = "on_surface_variant", maxLines = 1 })
    if value == nil then return countdown end
    -- Keep the smaller reset beside the value's lower edge, not floating at its centre.
    return ui.row({ gap = 3, align = "end" }, { value, countdown })
end

local function chip(entry, flagged, isVert)
    entry = barEntry(entry)
    if shared.readFailure(entry) then
        local nodes = { ui.label({ text = "—", color = "on_surface_variant" }) }
        if showGlyph then
            table.insert(nodes, glyphAfter and #nodes + 1 or 1,
                ui.glyph({ name = providerGlyph(entry.id, entry.brand), color = "error" }))
        end
        if isVert then
            return ui.column({ gap = 2, align = "center" }, nodes)
        end
        return ui.row({ gap = 4, align = "center" }, nodes)
    end
    local metric = capsuleMetric(entry)
    -- Balance-only providers carry no percentage; the capsule shows their
    -- amount where a quota vendor shows its percentage.
    local balance = metric == nil and shared.balanceText(entry) or nil
    local tint = severityRole(metric, "on_surface")
    local percent = shared.displayPercent(metric, usageDisplay)
    local text = metric ~= nil and shared.metricText(metric, usageDisplay) or (balance or "—")
    local fill = severityRole(metric, "primary")
    -- The mark says which provider, never how full it is; severity rides on the
    -- reading and the gauge. A failed read is the one thing that colours it, and
    -- colours rather than appends: a glyph that exists only while the read fails
    -- would shove the neighbouring widget once per cycle. The tooltip still
    -- spells the failure out.
    local submodels = modelHeadlines(entry)
    local hasSubmodels = #submodels > 0

    local glyph = (showGlyph and not hasSubmodels)
        and ui.glyph({ name = providerGlyph(entry.id, entry.brand),
                       color = flagged and "error" or "on_surface" }) or nil
    local pct = nil
    if showValue or hasSubmodels then
        if hasSubmodels then
            local parts = {}
            for _, item in ipairs(submodels) do
                local shownMetric = quotaWindow == "auto" and (item.blockingMetric or item.metric)
                    or shared.capsuleMetric({ metrics = item.metrics }, quotaWindow)
                local mTint = colorByUsage and isCritical(shownMetric) and "error"
                    or severityRole(shownMetric, "on_surface")
                local mFill = isCritical(shownMetric) and "error"
                    or severityRole(shownMetric, "primary")
                local rowChildren = {}
                local modelGlyph = showGlyph and ui.glyph({
                        name = item.glyph or providerGlyph(entry.id, entry.brand),
                        color = flagged and "error" or "on_surface",
                    }) or nil
                if modelGlyph and not glyphAfter then rowChildren[#rowChildren + 1] = modelGlyph end
                if showName and not isVert then
                    rowChildren[#rowChildren + 1] = ui.label({
                        text = item.displayName or item.model,
                        color = "on_surface_variant", maxLines = 1, maxWidth = 140,
                    })
                end

                local mMetrics = type(item.metrics) == "table" and item.metrics or { item.metric }
                local mShort, mWeekly = gaugeMetrics(mMetrics, shownMetric)
                local barNode = bars(mShort, mWeekly, 22)

                if visualization == "gauge" and not isVert and barNode ~= nil then
                    rowChildren[#rowChildren + 1] = barNode
                end
                local value = showValue and ui.label({
                    text = shared.metricText(shownMetric, usageDisplay),
                    color = mTint,
                    maxLines = 1,
                }) or nil
                local reading = withCountdown(value, shownMetric, isVert)
                if reading ~= nil then rowChildren[#rowChildren + 1] = reading end
                if modelGlyph and glyphAfter then rowChildren[#rowChildren + 1] = modelGlyph end
                if #parts > 0 and #rowChildren > 0 then
                    parts[#parts + 1] = isVert
                        and ui.box({ width = 10, height = 1, fill = "on_surface_variant", opacity = 0.25 })
                        or ui.label({
                            text = "·",
                            color = "on_surface_variant",
                        })
                end
                if #rowChildren > 0 then
                    parts[#parts + 1] = isVert
                        and ui.column({ gap = 2, align = "center" }, rowChildren)
                        or ui.row({ gap = 4, align = "center" }, rowChildren)
                end
            end
            pct = isVert
                and ui.column({ gap = 3, align = "center" }, parts)
                or ui.row({ gap = 8, align = "center" }, parts)
        else
            pct = ui.label({
                text = text,
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
        if entry.stale == true then
            vertNodes[#vertNodes + 1] = ui.glyph({ name = "clock-exclamation", size = 11, color = "secondary" })
        end
        return ui.column({ gap = 2, align = "center" }, vertNodes)
    end

    local name = showName and not hasSubmodels and ui.label({ text = shortName(entry),
                                         color = "on_surface_variant", maxLines = 1, maxWidth = 140 }) or nil

    local nodes = {}
    local function add(node) if node ~= nil then nodes[#nodes + 1] = node end end

    if not glyphAfter then add(glyph) end
    add(name)
    if visualization == "gauge" and not hasSubmodels then
        local mShort, mWeekly = gaugeMetrics(entry.metrics, metric)
        local barNode = bars(mShort, mWeekly, 32)
        if barNode == nil and percent ~= nil then
            barNode = bars(metric, nil, 32)
        end
        add(barNode)
    end
    add(hasSubmodels and pct or withCountdown(pct, metric, false))
    if glyphAfter then add(glyph) end

    if extras == "pace" or extras == "both" then
        local _, points, word = pace(metric and metric.detail)
        if points ~= nil then
            local ahead = word == "ahead"
            local role = ahead and "secondary" or "on_surface_variant"
            add(ui.row({ gap = 0, align = "center" }, {
                ui.glyph({ name = ahead and "arrow-up" or "arrow-down", size = 10, color = role }),
                ui.label({ text = tostring(points), fontSize = 10, color = role, maxLines = 1 }),
            }))
        end
    end

    if entry.stale == true then
        add(ui.glyph({ name = "clock-exclamation", size = 11, color = "secondary" }))
    end
    return ui.row({ gap = 4, align = "center" }, nodes)
end

local MAX_TOOLTIP_ROWS = 10
local WINDOW_TAG = { session = "5h", weekly = "7d", monthly = "30d" }

local function windowTitle(title, metric, fallback)
    local tag = WINDOW_TAG[shared.metricWindow(metric)] or fallback
    if tag == nil or tag == "" then return title end
    return title .. " " .. tag
end

local function formatMetric(metric)
    if metric == nil then return "" end
    local value = shared.metricText(metric, usageDisplay)
    if quotaWindow ~= "auto" then
        value = tostring(metric.label or quotaWindow) .. ": " .. value
    end
    local left = fixedCountdown(metric)
    if left ~= "" then value = value .. " · " .. left end
    return value
end

-- Native structured tooltips elide long fields, but do not cap their height.
-- Giving each quota window its own row keeps both percentages and reset times
-- within the peer column width budget while bounding total tooltip height.
local function tooltipSummary(picked, hidden)
    local more = { key = noctalia.tr("ui.title"), value = noctalia.tr("ui.tooltip_more") }
    if failure.code ~= "" then
        return { { key = noctalia.tr("ui.title"), value = noctalia.tr("ui.error." .. failure.code) }, more }
    end
    if #picked == 0 then
        local down = pinnedDown()
        if down ~= nil then
            return { { key = tostring(down.display_name or down.id), value = noctalia.tr("ui.unavailable") }, more }
        end
        local waiting = noctalia.tr("ui.waiting")
        if vendor ~= "auto" then
            waiting = noctalia.tr("ui.not_configured", { vendor = wantedEntryId() })
        elseif autoProviders ~= nil and (type(autoProviders) ~= "table" or next(autoProviders) ~= nil) then
            waiting = noctalia.tr("ui.no_matching_providers")
        end
        return { { key = noctalia.tr("ui.title"), value = waiting } }
    end

    local readings = {}
    local hasQuota, needsPanel = false, false
    local function finishReading(rowKey, value, entry)
        if entry.stale == true then
            value = value .. " · " .. noctalia.tr("ui.stale")
            needsPanel = true
        end
        readings[#readings + 1] = { key = rowKey, value = value }
    end
    local function addReading(title, metrics, selected, entry)
        local first, second = gaugeMetrics(metrics, selected)
        if #metrics > 0 then hasQuota = true end
        if first ~= nil and second ~= nil then
            finishReading(windowTitle(title, first, "5h"), formatMetric(first), entry)
            finishReading(windowTitle(title, second, "7d"), formatMetric(second), entry)
            return
        end
        local value = formatMetric(first or second)
        if #metrics > 0 and value == "" and quotaWindow ~= "auto" then
            value = noctalia.tr("ui.window_unavailable")
        end
        if value == "" then value = shared.balanceText(entry) or noctalia.tr("ui.no_usage") end
        finishReading(title, value, entry)
    end
    for _, entry in ipairs(picked) do
        local title = tostring(entry.display_name or entry.id)
        if entry.status == "error" or shared.readFailure(entry) then
            readings[#readings + 1] = { key = title, value = noctalia.tr("ui.unavailable") }
            needsPanel = true
        else
            local models = modelHeadlines(entry)
            if #models > 0 then
                for _, item in ipairs(models) do
                    local metrics = item.metrics
                    local modelTitle = item.displayName or item.model
                    if tostring(entry.id):find("@", 1, true) then modelTitle = title .. " · " .. modelTitle end
                    addReading(modelTitle, metrics, shared.capsuleMetric({ metrics = metrics }, quotaWindow), entry)
                end
            else
                local metrics = type(entry.metrics) == "table" and entry.metrics or {}
                addReading(title, metrics, capsuleMetric(entry), entry)
            end
        end
    end
    local footer = {}
    if hasQuota then
        footer[#footer + 1] = { key = noctalia.tr("ui." .. usageDisplay), value = noctalia.tr("settings.quota_window.option." .. quotaWindow) }
    end
    if hidden > 0 then
        footer[#footer + 1] = { key = noctalia.tr("ui.hidden_label"), value = noctalia.tr("ui.hidden_value", { count = hidden }) }
    end
    local omitted = #readings + #footer > MAX_TOOLTIP_ROWS
    local budget = MAX_TOOLTIP_ROWS - #footer - ((omitted or needsPanel) and 1 or 0)
    local rows = {}
    for i = 1, math.min(budget, #readings) do rows[#rows + 1] = readings[i] end
    for _, row in ipairs(footer) do rows[#rows + 1] = row end
    if omitted or needsPanel then rows[#rows + 1] = more end
    return rows
end

local function tooltip(picked, hidden)
    local rows = tooltipSummary(picked, hidden)
    for _, row in ipairs(rows) do
        row.key = noctalia.string.trim(tostring(row.key):gsub("%s+", " "))
        row.value = noctalia.string.trim(tostring(row.value):gsub("%s+", " "))
    end
    return rows
end

local function render()
    local isVert = type(barWidget.isVertical) == "function" and barWidget.isVertical() or false
    local picked, hidden = shown()
    -- A failed read does not erase the last one: the numbers stay, flagged,
    -- until a good report replaces them. Erasing them blanked the capsule over a
    -- transient spawn failure.
    local flagged = failure.code ~= "" and #picked > 0

    local children = {}
    for _, entry in ipairs(picked) do
        -- A divider separates providers; dots join models within one provider.
        if #children > 0 then
            children[#children + 1] = isVert
                and ui.box({ width = 12, height = 1, fill = "on_surface_variant", opacity = 0.3 })
                or ui.box({ width = 1, height = 14, fill = "on_surface_variant", opacity = 0.3 })
        end
        children[#children + 1] = chip(entry, flagged, isVert)
    end

    if #children == 0 then
        -- One glyph, coloured by the state. A second icon beside it would read as
        -- a second problem.
        children[1] = ui.glyph({
            name = "brain",
            color = failure.code ~= "" and "error" or "on_surface_variant",
        })
    elseif hidden > 0 then
        children[#children + 1] = ui.label({ text = "+" .. tostring(hidden), fontSize = 10,
                                             color = "on_surface_variant", maxLines = 1 })
    end

    if isVert then
        barWidget.render(ui.column({ gap = 5, align = "center" }, children))
    else
        barWidget.render(ui.row({ gap = 8, align = "center" }, children))
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
    noctalia.state.set("selected", picked[1] ~= nil and picked[1].id or wantedEntryId())
    noctalia.togglePanel("felipeartur/ai-usagebar:panel")
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
