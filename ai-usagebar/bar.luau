--!nonstrict
-- Bar capsule. Draws what the poller published: one provider, or the busiest few
-- when `provider_limit` is raised. Settings are per-instance, so a second capsule
-- can follow a second provider.

local vendor = tostring(noctalia.getConfig("vendor") or "auto")
local account = noctalia.string.trim(tostring(noctalia.getConfig("account") or ""))
local extras = tostring(noctalia.getConfig("extras") or "countdown")
-- Named after the core `sysmon` widget's own keys, so a reading in this capsule
-- is configured the same way as the CPU one beside it.
local visualization = tostring(noctalia.getConfig("visualization") or "none")
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
local modelHeadlines, isCritical = shared.modelHeadlines, shared.isCritical
local pace, SEVERITY_RANK = shared.pace, shared.SEVERITY_RANK
local NO_FAILURE, asFailure = shared.NO_FAILURE, shared.asFailure
local unavailable, warning = shared.unavailable, shared.warning

local failure = NO_FAILURE

-- ── Report helpers ────────────────────────────────────────────────────────────

local function entries() return shared.entries(report) end

local function wantedEntryId()
    if vendor == "auto" or account == "" then return vendor end
    return vendor .. "@" .. account
end

local function rank(entry)
    local metric = headline(entry)
    if metric == nil then return -1, -1 end
    return SEVERITY_RANK[tostring(metric.severity or "")] or 0, tonumber(metric.percent) or 0
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
                if unavailable(entry) then return {}, 0 end
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
        if entry.status ~= "error" and not unavailable(entry) then
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
    for _, entry in ipairs(entries()) do
        if entry.id == wanted and unavailable(entry) then return entry end
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

-- Quota above, window elapsed below: a fill longer than the clock bar is spend
-- running ahead of time.
local function bars(percent, elapsed, tint, width)
    local stack = {
        ui.progress({ progress = ratio(percent), fill = tint, track = "on_surface/0.12",
                      radius = 3, width = width, height = 5 }),
    }
    if elapsed ~= nil then
        stack[#stack + 1] = ui.progress({ progress = ratio(elapsed), fill = "on_surface/0.45",
                                          track = "on_surface/0.10", radius = 2, width = width, height = 3 })
    end
    return ui.column({ gap = 1, align = "center" }, stack)
end

local function chip(entry, flagged)
    local metric = headline(entry)
    local tint = severityRole(metric, "on_surface")
    local percent = metric ~= nil and tonumber(metric.percent) or nil
    local text = percent ~= nil and string.format("%d%%", percent) or "—"
    local fill = severityRole(metric, "primary")
    -- The mark says which provider, never how full it is; severity rides on the
    -- reading and the gauge. A failed read is the one thing that colours it, and
    -- colours rather than appends: a glyph that exists only while the read fails
    -- would shove the neighbouring widget once per cycle. The tooltip still
    -- spells the failure out.
    local submodels = modelHeadlines(entry)
    local hasSubmodels = #submodels > 1

    local glyph = (showGlyph and not hasSubmodels)
        and ui.glyph({ name = providerGlyph(entry.id), size = 14,
                       color = flagged and "error" or "on_surface" }) or nil
    local pct = nil
    if showValue then
        if hasSubmodels then
            local parts = {}
            for _, item in ipairs(submodels) do
                local shownMetric = item.blockingMetric or item.metric
                local mTint = isCritical(shownMetric) and "error"
                    or severityRole(shownMetric, "on_surface")
                local mPct = tonumber(shownMetric.percent) or 0
                local rowChildren = {
                    ui.glyph({
                        name = item.glyph or providerGlyph(entry.id),
                        size = 13,
                        color = "on_surface",
                    }),
                    ui.label({
                        text = string.format("%d%%", mPct),
                        fontSize = 11,
                        fontWeight = "semibold",
                        color = mTint,
                        maxLines = 1,
                    }),
                }
                if extras == "countdown" or extras == "both" then
                    local left = fixedCountdown(shownMetric)
                    if left ~= "" then
                        rowChildren[#rowChildren + 1] = ui.label({
                            text = left,
                            fontSize = 10,
                            color = "on_surface_variant",
                            maxLines = 1,
                        })
                    end
                end
                if #parts > 0 then
                    parts[#parts + 1] = ui.label({
                        text = "·",
                        fontSize = 11,
                        color = "on_surface_variant",
                    })
                end
                parts[#parts + 1] = ui.row({ gap = 3, align = "center" }, rowChildren)
            end
            pct = ui.row({ gap = 7, align = "center" }, parts)
        else
            pct = ui.label({
                text = text,
                fontSize = 11,
                fontWeight = "semibold",
                color = tint,
                maxLines = 1,
            })
        end
    end
    local name = showName and ui.label({ text = shortName(entry), fontSize = 11,
                                         color = "on_surface_variant", maxLines = 1 }) or nil

    local nodes = {}
    local function add(node) if node ~= nil then nodes[#nodes + 1] = node end end

    if not glyphAfter then add(glyph) end
    add(name)
    if percent ~= nil and visualization == "gauge" then
        add(bars(percent, elapsedPercent(metric and metric.detail), fill, 30))
    end
    add(pct)
    if glyphAfter then add(glyph) end

    if (extras == "countdown" or extras == "both") and not hasSubmodels then
        local left = fixedCountdown(metric)
        if left ~= "" then
            add(ui.label({ text = left, fontSize = 10, color = "on_surface_variant", maxLines = 1 }))
        end
    end
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
    return ui.row({ gap = 5, align = "center" }, nodes)
end

local function formatDualMetric(m1, m2)
    m1 = type(m1) == "table" and m1 or nil
    m2 = type(m2) == "table" and m2 or nil
    if m1 == nil and m2 == nil then return "" end

    local p1 = m1 and (m1.percent ~= nil and tonumber(m1.percent) or tostring(m1.value or ""))
    local p2 = m2 and (m2.percent ~= nil and tonumber(m2.percent) or tostring(m2.value or ""))

    local str1 = type(p1) == "number" and string.format("%d%%", p1) or tostring(p1 or ""):gsub(" of ", " / ")
    local str2 = type(p2) == "number" and string.format("%d%%", p2) or (p2 ~= nil and tostring(p2):gsub(" of ", " / ") or nil)

    -- If one window is exhausted, its reset is the real unlock time. Showing
    -- the shorter session reset would promise availability while the weekly
    -- limit still blocks the model.
    local blocking = isCritical(m1) and m1 or (isCritical(m2) and m2 or nil)
    local left = blocking ~= nil and fixedCountdown(blocking) or ""
    if left == "" and m1 ~= nil then left = fixedCountdown(m1) end
    if left == "" and m2 ~= nil then left = fixedCountdown(m2) end

    local val = str1
    if str2 ~= nil and str2 ~= "" then
        val = val .. " / " .. str2
    end
    if left ~= "" then
        val = val .. " · " .. left
    end
    return val
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
            return { { key = tostring(down.display_name or down.id), value = warning(down) } }
        end
        local waiting = vendor == "auto" and noctalia.tr("ui.waiting")
            or noctalia.tr("ui.not_configured", { vendor = wantedEntryId() })
        return { { key = noctalia.tr("ui.title"), value = waiting } }
    end

    local rows = {}
    for _, entry in ipairs(picked) do
        local title = tostring(entry.display_name or entry.id)
        if entry.status == "error" then
            rows[#rows + 1] = { key = title, value = tostring(entry.error or noctalia.tr("ui.unavailable")) }
        else
            local submodels = modelHeadlines(entry)
            if #submodels > 1 then
                for _, item in ipairs(submodels) do
                    local mMetrics = type(item.metrics) == "table" and item.metrics or { item.metric }
                    local val = formatDualMetric(mMetrics[1], mMetrics[2])
                    if val ~= "" then
                        rows[#rows + 1] = { key = item.displayName or item.model, value = val }
                    end
                end
            else
                local metrics = type(entry.metrics) == "table" and entry.metrics or {}
                local val = formatDualMetric(metrics[1], metrics[2])
                if val ~= "" then
                    rows[#rows + 1] = { key = title, value = val }
                elseif entry.plan ~= nil and tostring(entry.plan) ~= "" then
                    rows[#rows + 1] = { key = title, value = tostring(entry.plan) }
                end
            end
            if entry.stale == true then
                rows[#rows + 1] = { key = noctalia.tr("ui.updated"), value = noctalia.tr("ui.stale_hint") }
            end
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
    local picked, hidden = shown()
    -- A failed read does not erase the last one: the numbers stay, flagged,
    -- until a good report replaces them. Erasing them blanked the capsule over a
    -- transient spawn failure.
    local flagged = failure.code ~= "" and #picked > 0

    local children = {}
    for _, entry in ipairs(picked) do
        -- Two providers run together on a gap alone: the countdown of the first
        -- reads as part of the second. A dot, not a rule -- a vertical
        -- `ui.separator` in a row came out two pixels wide by one tall.
        if #children > 0 then
            children[#children + 1] = ui.label({ text = "·", fontSize = 11,
                                                 color = "on_surface_variant" })
        end
        children[#children + 1] = chip(entry, flagged)
    end

    if #children == 0 then
        -- One glyph, coloured by the state. A second icon beside it would read as
        -- a second problem.
        children[1] = ui.glyph({
            name = "brain", size = 14,
            color = failure.code ~= "" and "error" or "on_surface_variant",
        })
    elseif hidden > 0 then
        children[#children + 1] = ui.label({ text = "+" .. tostring(hidden), fontSize = 10,
                                             color = "on_surface_variant", maxLines = 1 })
    end

    barWidget.render(ui.row({ gap = 7, align = "center" }, children))
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


report = noctalia.state.get("report")
failure = asFailure(noctalia.state.get("error"))

-- Live countdowns without waking the CLI.
noctalia.setUpdateInterval(30000)
render()

function update()
    render()
end
