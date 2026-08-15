--!nonstrict
-- Bar capsule. Reads whatever the poller published and draws one provider.
--
-- Per-instance settings, so adding the widget twice watches two providers.

local vendor = tostring(noctalia.getConfig("vendor") or "auto")
local style = tostring(noctalia.getConfig("style") or "pill")
local showName = noctalia.getConfig("showName") == true
local colorByUsage = noctalia.getConfig("colorByUsage") ~= false

local report = nil
local errorMsg = ""

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
    if seconds <= 0 then return "now" end
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
    local pattern = noctalia.timeFormat() or "HH:mm"
    if os.date("%Y-%m-%d", at) ~= os.date("%Y-%m-%d") then
        pattern = "ddd " .. pattern
    end
    return noctalia.formatTime(pattern, at)
end

local function entries()
    if type(report) ~= "table" or type(report.entries) ~= "table" then return {} end
    return report.entries
end

-- "auto" follows `[ui] primary` from the CLI's own config, then the first
-- provider that actually reported.
local function currentEntry()
    local all = entries()
    if vendor ~= "auto" then
        for _, entry in ipairs(all) do
            if entry.id == vendor then return entry end
        end
        return nil
    end

    local primary = type(report) == "table" and report.primary or nil
    if primary ~= nil then
        for _, entry in ipairs(all) do
            if entry.id == primary then return entry end
        end
    end
    for _, entry in ipairs(all) do
        if entry.status == "ready" then return entry end
    end
    return all[1]
end

local function headline(entry)
    if type(entry) ~= "table" or type(entry.metrics) ~= "table" then return nil end
    return entry.metrics[1]
end

-- The CLI already tiers every percentage; mirroring its thresholds here would
-- be a second source of truth.
local function severityRole(metric)
    if not colorByUsage then return "on_surface" end
    local severity = metric ~= nil and tostring(metric.severity or "") or ""
    if severity == "critical" then return "error" end
    if severity == "high" then return "secondary" end
    return "primary"
end

local function shortName(entry)
    local name = tostring(entry.display_name or entry.name or entry.id or "")
    -- "Claude · gmail" is the panel's business; the bar has room for the product.
    return (name:gsub("%s*·.*$", ""))
end

-- ── Rendering ─────────────────────────────────────────────────────────────────

local function tooltip(entry)
    if errorMsg ~= "" then return { { key = "AI Usage", value = errorMsg } } end
    if entry == nil then
        local waiting = vendor == "auto" and "Waiting for usage data"
            or ("`" .. vendor .. "` is not configured in ai-usagebar")
        return { { key = "AI Usage", value = waiting } }
    end
    if entry.status == "error" then
        return { { key = tostring(entry.display_name or entry.id), value = tostring(entry.error or "Unavailable") } }
    end

    local rows = {}
    if entry.plan ~= nil and tostring(entry.plan) ~= "" then
        rows[#rows + 1] = { key = "Plan", value = tostring(entry.plan) }
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
        rows[#rows + 1] = { key = "Updated", value = "showing last known data" }
    end
    if #rows == 0 then
        rows[#rows + 1] = { key = tostring(entry.display_name or entry.id), value = "No usage reported" }
    end
    return rows
end

local function render()
    local entry = currentEntry()
    local metric = headline(entry)
    local tint = severityRole(metric)
    local percent = metric ~= nil and tonumber(metric.percent) or nil
    local text = percent ~= nil and (string.format("%d%%", percent)) or "—"

    local children = { ui.glyph({ name = "brain", size = 13, color = tint }) }

    if showName and entry ~= nil then
        children[#children + 1] = ui.label({
            text = shortName(entry),
            fontSize = 11,
            color = "on_surface_variant",
            maxLines = 1,
        })
    end

    if style == "gauge" and percent ~= nil then
        children[#children + 1] = ui.progress({
            progress = percent / 100,
            fill = tint,
            track = "on_surface/0.16",
            radius = 6,
            width = 26,
            height = 5,
        })
    end

    children[#children + 1] = ui.label({
        text = text,
        fontSize = 11,
        fontWeight = "semibold",
        color = tint,
        maxLines = 1,
    })

    local broken = errorMsg ~= "" or (entry ~= nil and entry.status == "error") or entry == nil
    if broken then
        children[#children + 1] = ui.glyph({ name = "alert-circle", size = 12, color = "error" })
    elseif entry.stale == true then
        children[#children + 1] = ui.glyph({ name = "clock-exclamation", size = 12, color = "secondary" })
    end

    barWidget.render(ui.row({ gap = 5, align = "center" }, children))
    barWidget.setTooltip(tooltip(entry))
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

function onClick()
    local entry = currentEntry()
    -- One panel serves every capsule and is not told which one opened it.
    noctalia.state.set("selected", entry ~= nil and entry.id or vendor)
    noctalia.togglePanel("felipeartur/ai-usagebar:panel")
end

function onRightClick()
    noctalia.state.set("command", { action = "refresh", at = os.time() })
end

report = noctalia.state.get("report")
local existingError = noctalia.state.get("error")
if type(existingError) == "string" then errorMsg = existingError end

-- Live countdowns in the tooltip without waking the CLI.
noctalia.setUpdateInterval(30000)
render()

function update()
    render()
end
