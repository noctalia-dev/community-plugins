--!nonstrict
-- Bar capsule. Reads whatever the poller published and draws one provider, or
-- the busiest few when `provider_limit` is raised.
--
-- Per-instance settings, so two capsules can follow two different providers.

local vendor = tostring(noctalia.getConfig("vendor") or "auto")
local style = tostring(noctalia.getConfig("style") or "pill")
local extras = tostring(noctalia.getConfig("extras") or "countdown")
local limit = math.max(1, math.min(4, tonumber(noctalia.getConfig("provider_limit")) or 1))
local showName = noctalia.getConfig("show_name") == true
local colorByUsage = noctalia.getConfig("color_by_usage") ~= false

local report = nil
local errorMsg = ""
local polling = false

-- Tabler has no Anthropic mark, so providers without a brand glyph get a
-- semantic one. Same approach the other CLI-backed meters in this repo take.
local GLYPHS = {
    anthropic = "asterisk-simple",
    anthropic_api = "asterisk-simple",
    openai = "brand-openai",
    zai = "bolt",
    openrouter = "route",
    deepseek = "fish",
    kimi = "moon",
    moonshot = "moon",
    kilo = "robot",
    novita = "cloud",
    grok = "brand-x",
    supergrok = "brand-x",
    antigravity = "sparkles",
    cursor = "cursor-text",
    minimax = "wave-square",
    kiro = "ghost",
    copilot = "brand-github-copilot",
    gemini = "brand-google",
}

-- ── Report helpers ────────────────────────────────────────────────────────────

-- "2026-08-15T11:29:59.872624Z" -> unix seconds. The stamps are UTC, so the
-- naive os.time() reading (which assumes local time) is corrected by the local
-- offset measured at that same instant.
local function parseIso(value)
    if type(value) ~= "string" then return nil end
    local y, mo, d, h, mi, s = value:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
    if y == nil then return nil end
    local asLocal = os.time({
        year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
    })
    local utcAsLocal = os.time(os.date("!*t", asLocal))
    return asLocal + (asLocal - utcAsLocal)
end

local function formatDuration(seconds)
    if seconds <= 0 then return noctalia.tr("ui.now") end
    local minutes = math.floor(seconds / 60)
    local days = math.floor(minutes / 1440)
    local hours = math.floor((minutes % 1440) / 60)
    local rest = minutes % 60
    if days > 0 then return string.format("%dd %dh", days, hours) end
    if hours > 0 then return string.format("%dh %dm", hours, rest) end
    return string.format("%dm", rest)
end

local function countdown(metric)
    local at = parseIso(metric and metric.reset_at)
    if at == nil then return "" end
    return formatDuration(at - os.time())
end

-- The clock time the countdown lands on: "14:20", or "Sat 14:20" past midnight.
local function resetClock(metric)
    local at = parseIso(metric and metric.reset_at)
    if at == nil then return "" end
    local clock = noctalia.formatTime(noctalia.timeFormat(), at)
    -- The weekday is prepended here rather than folded into the pattern: the
    -- host's format grammar passes unknown text through verbatim, so a "ddd"
    -- prefix would render as the literal word.
    if os.date("%Y-%m-%d", at) ~= os.date("%Y-%m-%d") then
        return os.date("%a", at) .. " " .. clock
    end
    return clock
end

-- "Resets in 4h 01m · 19% elapsed · 2pts ahead" says how much of the window is
-- gone and how far the spend is from that line.
local function elapsedPercent(metric)
    local value = tostring(metric and metric.detail or ""):match("(%d+)%%%s*elapsed")
    return value ~= nil and tonumber(value) or nil
end

-- Returns points and direction: 2, "ahead" is burning faster than the clock.
local function pace(metric)
    local points, word = tostring(metric and metric.detail or ""):match("(%d+)pts%s+(%a+)")
    if points == nil then return nil, nil end
    return tonumber(points), word
end

local function entries()
    if type(report) ~= "table" or type(report.entries) ~= "table" then return {} end
    return report.entries
end

local function headline(entry)
    if type(entry) ~= "table" or type(entry.metrics) ~= "table" then return nil end
    return entry.metrics[1]
end

local SEVERITY_RANK = { critical = 3, high = 2, medium = 1, low = 0 }

local function rank(entry)
    local metric = headline(entry)
    if metric == nil then return -1, -1 end
    return SEVERITY_RANK[tostring(metric.severity or "")] or 0, tonumber(metric.percent) or 0
end

-- A pinned vendor shows only itself. "auto" shows the busiest providers, so
-- the one closest to running out is the one on the bar. `primary` breaks ties.
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
    -- Someone who asked for one provider does not need a count of the others,
    -- so the "+N" only appears once the capsule carries more than one.
    if limit == 1 then return picked, 0 end
    return picked, #ready - #picked
end

-- The CLI already tiers every percentage, and copying its thresholds here
-- would be a second source of truth. Text stays in the bar's own colour until
-- the reading is high or critical, and the accent colour is used on the bar
-- fill only.
local function textRole(metric)
    if not colorByUsage then return "on_surface" end
    local severity = metric ~= nil and tostring(metric.severity or "") or ""
    if severity == "critical" then return "error" end
    if severity == "high" then return "tertiary" end
    return "on_surface"
end

local function barRole(metric)
    if not colorByUsage then return "primary" end
    local severity = metric ~= nil and tostring(metric.severity or "") or ""
    if severity == "critical" then return "error" end
    if severity == "high" then return "tertiary" end
    return "primary"
end

local function shortName(entry)
    local name = tostring(entry.display_name or entry.name or entry.id or "")
    -- "Claude · gmail" is the panel's business; the bar has room for the product.
    return (name:gsub("%s*·.*$", ""))
end

-- ── Rendering ─────────────────────────────────────────────────────────────────

-- A provider can report more than it was given, so the reading is clamped
-- before it becomes a bar width.
local function ratio(percent)
    local value = (tonumber(percent) or 0) / 100
    if value < 0 then return 0 end
    if value > 1 then return 1 end
    return value
end

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

local function paceNodes(metric)
    if extras ~= "pace" and extras ~= "both" then return nil end
    local points, word = pace(metric)
    if points == nil then return nil end
    local ahead = word == "ahead"
    return ui.row({ gap = 0, align = "center" }, {
        ui.glyph({ name = ahead and "arrow-up" or "arrow-down", size = 10,
                   color = ahead and "tertiary" or "on_surface_variant" }),
        ui.label({ text = tostring(points), fontSize = 10,
                   color = ahead and "tertiary" or "on_surface_variant", maxLines = 1 }),
    })
end

local function countdownNode(metric)
    if extras ~= "countdown" and extras ~= "both" then return nil end
    local left = countdown(metric)
    if left == "" then return nil end
    return ui.label({ text = left, fontSize = 10, color = "on_surface_variant", maxLines = 1 })
end

-- One provider's chip. The style decides the shape, and the extras are
-- appended to whatever it produced.
local function chip(entry)
    local metric = headline(entry)
    local tint = textRole(metric)
    local fill = barRole(metric)
    local percent = metric ~= nil and tonumber(metric.percent) or nil
    local text = percent ~= nil and string.format("%d%%", percent) or "—"
    local glyph = ui.glyph({ name = GLYPHS[tostring(entry.id)] or "brain", size = 13, color = tint })
    local pct = ui.label({ text = text, fontSize = 11, fontWeight = "semibold", color = tint, maxLines = 1 })
    local name = showName and ui.label({ text = shortName(entry), fontSize = 11,
                                         color = "on_surface_variant", maxLines = 1 }) or nil

    local nodes = {}
    local function add(node) if node ~= nil then nodes[#nodes + 1] = node end end

    if style == "meter" and percent ~= nil then
        -- Five ticks instead of digits: the reading at a glance, no numbers.
        local ticks = {}
        for i = 0, 4 do
            ticks[#ticks + 1] = ui.box({
                width = 3, height = 11, radius = 1,
                fill = percent > i * 20 and fill or "on_surface/0.22",
            })
        end
        add(glyph); add(name)
        add(ui.row({ gap = 2, align = "center" }, ticks))
    elseif style == "label" and percent ~= nil then
        -- Name and number stacked over the bar, for a bar with room to spare.
        add(glyph)
        add(ui.column({ gap = 1, align = "center" }, {
            ui.row({ gap = 3, align = "center" }, {
                ui.label({ text = shortName(entry), fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
                pct,
            }),
            bars(percent, elapsedPercent(metric), fill, 44),
        }))
    elseif style == "gauge" and percent ~= nil then
        add(glyph); add(name)
        add(bars(percent, elapsedPercent(metric), fill, 26))
        add(pct)
    else
        add(glyph); add(name); add(pct)
    end

    add(countdownNode(metric))
    add(paceNodes(metric))

    if entry.stale == true then
        add(ui.glyph({ name = "clock-exclamation", size = 11, color = "tertiary" }))
    end
    return ui.row({ gap = 4, align = "center" }, nodes)
end

local function tooltip(picked, hidden)
    if errorMsg ~= "" then return { { key = noctalia.tr("ui.title"), value = errorMsg } } end
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

    local children = {}
    for _, entry in ipairs(picked) do
        children[#children + 1] = chip(entry)
    end

    if polling then
        children[#children + 1] = ui.glyph({ name = "loader-2", size = 11, color = "on_surface_variant" })
    end

    if #children == 0 then
        children[1] = ui.row({ gap = 4, align = "center" }, {
            ui.glyph({ name = "brain", size = 13, color = "on_surface_variant" }),
            ui.glyph({ name = "alert-circle", size = 12, color = "error" }),
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
        errorMsg = ""
        render()
    end
end)

noctalia.state.watch("error", function(value)
    if type(value) == "string" then
        errorMsg = value
        render()
    end
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

function onRightClick()
    noctalia.state.set("command", { action = "refresh", at = os.time() })
end

report = noctalia.state.get("report")
local existingError = noctalia.state.get("error")
if type(existingError) == "string" then errorMsg = existingError end

-- Live countdowns without waking the CLI.
noctalia.setUpdateInterval(30000)
render()

function update()
    render()
end
