--!nonstrict
-- Bar capsule. Draws what the poller published: one provider, or the busiest few
-- when `provider_limit` is raised. Settings are per-instance, so a second capsule
-- can follow a second provider.

local vendor = tostring(noctalia.getConfig("vendor") or "auto")
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
local polling = false

local shared = require("./shared.luau")
local providerGlyph = shared.providerGlyph
local countdown, resetClock = shared.countdown, shared.resetClock
local ratio, headline, elapsedPercent = shared.ratio, shared.headline, shared.elapsedPercent
local pace, SEVERITY_RANK = shared.pace, shared.SEVERITY_RANK
local NO_FAILURE, asFailure = shared.NO_FAILURE, shared.asFailure

local failure = NO_FAILURE

-- ── Report helpers ────────────────────────────────────────────────────────────

local function entries() return shared.entries(report) end

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
        for _, entry in ipairs(all) do
            if entry.id == vendor then return { entry }, 0 end
        end
        return {}, 0
    end

    local ready = {}
    for _, entry in ipairs(all) do
        if entry.status ~= "error" then ready[#ready + 1] = entry end
    end
    local primary = type(report) == "table" and report.primary or nil
    table.sort(ready, function(a, b)
        local aRank, aPct = rank(a)
        local bRank, bPct = rank(b)
        if aRank ~= bRank then return aRank > bRank end
        if aPct ~= bPct then return aPct > bPct end
        if a.id == primary then return true end
        if b.id == primary then return false end
        return tostring(a.id) < tostring(b.id)
    end)

    local picked = {}
    for i = 1, math.min(limit, #ready) do picked[i] = ready[i] end
    if #picked == 0 then return {}, 0 end
    if limit == 1 then return picked, 0 end
    return picked, #ready - #picked
end

-- `calm` is the colour when the CLI has raised nothing, and every colour when
-- the tint is switched off.
local function severityRole(metric, calm)
    if not colorByUsage then return calm end
    return shared.severityRole(metric, calm)
end

local function shortName(entry)
    local name = tostring(entry.display_name or entry.name or entry.id or "")
    -- "Claude · gmail" is the panel's business; the bar only has room for the
    -- product name.
    return (name:gsub("%s*·.*$", ""))
end

-- ── Rendering ─────────────────────────────────────────────────────────────────

-- Quota above, window elapsed below: a fill longer than the clock bar is spend
-- running ahead of time.
local function bars(percent, elapsed, tint, width)
    local stack = {
        ui.progress({ progress = ratio(percent), fill = tint, track = "on_surface/0.16",
                      radius = 3, width = width, height = 4 }),
    }
    if elapsed ~= nil then
        stack[#stack + 1] = ui.progress({ progress = ratio(elapsed), fill = "on_surface/0.45",
                                          track = "on_surface/0.10", radius = 1, width = width, height = 2 })
    end
    return ui.column({ gap = 1, align = "center" }, stack)
end

local function chip(entry)
    local metric = headline(entry)
    local tint = severityRole(metric, "on_surface")
    local percent = metric ~= nil and tonumber(metric.percent) or nil
    local text = percent ~= nil and string.format("%d%%", percent) or "—"
    local fill = severityRole(metric, "primary")
    -- The mark says which provider, never how full it is. Severity rides on the
    -- reading and the gauge, the same split the panel uses.
    local glyph = showGlyph
        and ui.glyph({ name = providerGlyph(entry.id), size = 13, color = "on_surface" }) or nil
    -- Fixed width, right-aligned: the capsule is the same size at 9% as at 100%
    -- and stops nudging its neighbours once per read.
    local pct = showValue and ui.label({ text = text, fontSize = 11, fontWeight = "semibold",
                                         color = tint, maxLines = 1, width = 30, textAlign = "end" }) or nil
    local name = showName and ui.label({ text = shortName(entry), fontSize = 11,
                                         color = "on_surface_variant", maxLines = 1 }) or nil

    local nodes = {}
    local function add(node) if node ~= nil then nodes[#nodes + 1] = node end end

    if not glyphAfter then add(glyph) end
    add(name)
    if percent ~= nil and visualization == "gauge" then
        add(bars(percent, elapsedPercent(metric and metric.detail), fill, 26))
    end
    add(pct)
    if glyphAfter then add(glyph) end

    if extras == "countdown" or extras == "both" then
        local left = countdown(metric)
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
    return ui.row({ gap = 4, align = "center" }, nodes)
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
        local waiting = vendor == "auto" and noctalia.tr("ui.waiting")
            or noctalia.tr("ui.not_configured", { vendor = vendor })
        return { { key = noctalia.tr("ui.title"), value = waiting } }
    end

    local rows = {}
    for _, entry in ipairs(picked) do
        local title = tostring(entry.display_name or entry.id)
        if entry.status == "error" then
            rows[#rows + 1] = { key = title, value = tostring(entry.error or noctalia.tr("ui.unavailable")) }
        else
            if entry.plan ~= nil and tostring(entry.plan) ~= "" then
                rows[#rows + 1] = { key = title, value = tostring(entry.plan) }
            end
            for _, metric in ipairs(entry.metrics or {}) do
                local value = tostring(metric.value or ""):gsub(" of ", " / ")
                local left = countdown(metric)
                if left ~= "" then
                    local clock = resetClock(metric)
                    value = value .. " · " .. left .. (clock ~= "" and (" (" .. clock .. ")") or "")
                end
                rows[#rows + 1] = { key = tostring(metric.label or ""), value = value }
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
    -- A failure drops the reading, so the capsule cannot show a live percentage
    -- while the panel behind it says the CLI is unreachable. Empty already draws
    -- the alert glyph.
    if failure.code ~= "" then picked, hidden = {}, 0 end

    local children = {}
    for _, entry in ipairs(picked) do
        -- Two providers in one capsule run together on a gap alone, and the
        -- countdown of the first reads as part of the second. A dot, not a rule:
        -- a vertical `ui.separator` in a row gets no height of its own and came
        -- out two pixels wide by one tall. The panel divides its chips the same
        -- way.
        if #children > 0 then
            children[#children + 1] = ui.label({ text = "·", fontSize = 11,
                                                 color = "on_surface_variant" })
        end
        children[#children + 1] = chip(entry)
    end

    if #children == 0 then
        -- One glyph, coloured by the state. A second icon beside it would read as
        -- a second problem.
        children[1] = ui.glyph({
            name = "brain", size = 13,
            color = failure.code ~= "" and "error" or "on_surface_variant",
        })
    elseif hidden > 0 then
        children[#children + 1] = ui.label({ text = "+" .. tostring(hidden), fontSize = 10,
                                             color = "on_surface_variant", maxLines = 1 })
    end

    barWidget.render(ui.row({ gap = 6, align = "center" }, children))
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

noctalia.state.watch("polling", function(value)
    polling = value == true
    render()
end)

function onClick()
    local picked = shown()
    -- One panel serves every capsule and is not told which one opened it.
    noctalia.state.set("selected", picked[1] ~= nil and picked[1].id or vendor)
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
