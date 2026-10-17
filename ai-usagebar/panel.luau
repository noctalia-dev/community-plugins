--!nonstrict
-- Expanded panel for one provider. It renders `sections[]`, the CLI's lossless
-- view, so the credit blocks and free text that `metrics[]` drops still show up.

local report = nil
local polling = false
local refreshQueued = false
local showSetup = false
local showActions = false
local showEnabled = false
local showDisabled = false
local expandedDiagnosticKey = nil
local catalog = nil
local catalogLoading = false
local catalogError = false

local shared = require("./shared.luau")
local providerGlyph, parseIso = shared.providerGlyph, shared.parseIso
local countdown, resetClock = shared.countdown, shared.resetClock
local ratio, headline, severityRole = shared.ratio, shared.headline, shared.severityRole
local modelHeadlines, isCritical, dualMetrics = shared.modelHeadlines, shared.isCritical, shared.dualMetrics
local modelGlyph = shared.modelGlyph
local modelDisplayName = shared.modelDisplayName
local pace = shared.pace
local requestRefresh = shared.requestRefresh
local providerWarning, unavailable, readFailure = shared.warning, shared.unavailable, shared.readFailure
local saysError, transportError = shared.saysError, shared.transportError
local NO_FAILURE, asFailure = shared.NO_FAILURE, shared.asFailure

local failure = NO_FAILURE

local function displayMode()
    return noctalia.getConfig("usage_display") == "remaining" and "remaining" or "used"
end

local function percentText(metric)
    local percent = shared.displayPercent(metric, displayMode())
    if percent == nil then return "—" end
    local text = string.format("%d%%", percent)
    if displayMode() == "remaining" then text = text .. " " .. noctalia.tr("ui.remaining") end
    return text
end

-- The plan each provider last reported on. A plan carries the limits every
-- percentage is measured against, so a reading taken under the old one says
-- nothing about the new one.
local lastPlan = {}

-- A vendor the user never set up is not listed. The CLI prefixes every such
-- message with `credentials error:`, but that bucket also holds providers that
-- are set up and merely unreachable, so the row is dropped only when the CLI
-- says there is no key at all.
local function configured(entry)
    if entry.status ~= "error" then return true end
    local message = tostring(entry.error or ""):lower()
    return not (message:find("^credentials error:") and message:find("no api key", 1, true))
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

-- ── Entry selection ───────────────────────────────────────────────────────────

local function entries() return shared.entries(report) end

local function currentEntry()
    local wanted = noctalia.state.get("selected")
    local first = nil
    for _, entry in ipairs(entries()) do
        if configured(entry) then
            if entry.id == wanted then return entry end
            if first == nil then first = entry end
        end
    end
    return first
end

local function updatedText(entry)
    local at = parseIso(entry and entry.fetched_at)
    if at == nil then return "" end
    local minutes = math.floor((os.time() - at) / 60)
    if minutes < 1 then return noctalia.tr("ui.updated_now") end
    return noctalia.tr("ui.updated_ago", { minutes = minutes })
end

-- ── Cards ─────────────────────────────────────────────────────────────────────

local function severityWord(section)
    local severity = tostring(section and section.severity or "")
    if severity ~= "high" and severity ~= "critical" then return nil end
    return noctalia.tr("ui.severity." .. severity)
end

-- One reading, without the card around it. `title` names it: the metric's own
-- label, or the window's name inside a card that stacks a model's readings.
local function metricRows(section, title)
    local percent = shared.displayPercent(section, displayMode())
    local usedPercent = tonumber(section.percent) or 0
    local tint = severityRole(section, "on_surface")
    local fill = severityRole(section, "primary")
    local value = tostring(section.value or ""):gsub(" of ", " / ")
    local showValue = value ~= "" and value ~= string.format("%d%%", usedPercent)
    if showValue and displayMode() == "remaining" then value = value .. " " .. noctalia.tr("ui.used") end

    local left = countdown(section)
    local clock = resetClock(section)
    local paceText, _, paceWord = pace(section.detail)

    local elapsed = shared.elapsedPercent(section.detail)
    local remaining = displayMode() == "remaining"
    local timePercent = elapsed ~= nil and elapsed >= 0 and elapsed <= 100
        and (remaining and (100 - elapsed) or elapsed) or nil
    local timeTooltip = timePercent ~= nil and noctalia.tr(
        remaining and "ui.time_remaining" or "ui.elapsed", { percent = timePercent }) or nil
    local resetStr = left

    local displayTitle = tostring(title or "")

    -- Title on the left; severity and percentage on the right.
    local rightMeta = {}
    local word = severityWord(section)
    if word ~= nil then
        rightMeta[#rightMeta + 1] = ui.label({ text = word, fontSize = 10,
            color = isCritical(section) and "error" or severityRole(section, "secondary") })
    end
    rightMeta[#rightMeta + 1] = ui.label({ text = percentText(section), fontSize = 12,
        fontWeight = "bold", color = tint, textAlign = "center" })

    local topRow = ui.row({ gap = 8, align = "center" }, {
        ui.column({ tooltip = timeTooltip }, {
            ui.label({
                text = displayTitle,
                fontSize = 12,
                fontWeight = "semibold",
                color = "on_surface",
                maxLines = 1,
            }),
        }),
        ui.spacer({ flexGrow = 1 }),
        ui.row({ gap = 5, align = "center", justify = "end" }, rightMeta),
    })

    -- Usage bar.
    local progressBar = percent ~= nil and ui.progress({
        progress = ratio(percent),
        fill = fill,
        track = "on_surface/0.10",
        radius = 2,
        height = 5,
    })

    -- Reset on the left, pace on the right.
    local bottomRowElements = {}
    if resetStr ~= "" then
        bottomRowElements[#bottomRowElements + 1] = ui.row({ gap = 4, align = "center", tooltip = clock ~= "" and clock or nil }, {
            ui.glyph({ name = "clock", size = 10, color = "on_surface_variant" }),
            ui.label({ text = resetStr, fontSize = 11, color = "on_surface_variant",
                       maxLines = 1, maxWidth = paceText ~= "" and 190 or 340 }),
        })
    end

    local subRight = {}
    if paceText ~= "" then
        local paceColor = paceWord == "ahead" and "secondary"
            or "on_surface_variant"
        local paceIcon = paceWord == "ahead" and "trending-up"
            or paceWord == "behind" and "trending-down"
            or "check"
        subRight[#subRight + 1] = ui.row({ gap = 3, align = "center" }, {
            ui.glyph({ name = paceIcon, size = 10, color = paceColor }),
            ui.label({ text = paceText, fontSize = 10, fontWeight = "medium", color = paceColor, maxLines = 1 }),
        })
    end

    local body = { topRow }
    if progressBar then body[#body + 1] = progressBar end
    if progressBar and timePercent ~= nil then
        body[#body + 1] = ui.progress({ progress = ratio(timePercent), height = 2,
            radius = 1, fill = "on_surface_variant/0.45", track = "on_surface/0.06" })
    end

    if showValue then
        body[#body + 1] = ui.label({ text = value, fontSize = 11,
                                    color = "on_surface_variant", maxLines = 2 })
    end

    if #bottomRowElements > 0 or #subRight > 0 then
        body[#body + 1] = ui.row({ gap = 6, align = "center" }, {
            ui.row({ gap = 4, align = "center" }, bottomRowElements),
            ui.spacer({ flexGrow = 1 }),
            ui.row({ gap = 4, align = "center", justify = "end" }, subRight),
        })
    end

    local rest = plainDetail(section.detail)
    if rest ~= "" then
        body[#body + 1] = ui.label({ text = rest, fontSize = 10, color = "on_surface_variant" })
    end

    return body
end

local CARD = { gap = 3, padding = 10, radius = 9, fill = "surface_variant/0.34",
               border = "outline/0.08", borderWidth = 1 }

local function cardStyle(gap, fill, border)
    return { gap = gap, padding = CARD.padding, radius = CARD.radius,
             fill = fill or CARD.fill, border = border or CARD.border,
             borderWidth = CARD.borderWidth }
end

local function stackCard(name, readings, glyph)
    local titled = name ~= ""
    local body = {}
    if titled then
        body[#body + 1] = ui.row({ gap = 6, align = "center" }, {
            ui.glyph({ name = glyph or modelGlyph(name), size = 13, color = "on_surface_variant" }),
            ui.label({ text = glyph and name or modelDisplayName(name), fontSize = 12, fontWeight = "bold",
                       color = "on_surface", maxLines = 1 }),
        })
    end
    for index, reading in ipairs(readings) do
        if index > 1 then
            body[#body + 1] = ui.box({ height = 1, fill = "outline/0.14" })
        end
        for _, node in ipairs(metricRows(reading.section, reading.title)) do
            body[#body + 1] = node
        end
    end
    return ui.column(CARD, body)
end

local function blockCard(section)
    local label = tostring(section.label or "")
    local isResetCredits = label == "Reset credits"
    local isUnavailable = label == "Unavailable"
    local isCredits = label == "Credits"

    local iconName = isResetCredits and "ticket"
        or isUnavailable and "circle-off"
        or isCredits and "coin"
        or "info-circle"
    local iconColor = isResetCredits and "primary"
        or isUnavailable and "error"
        or isCredits and "secondary"
        or "on_surface_variant"

    local body = {
        ui.row({ gap = 6, align = "center" }, {
            ui.glyph({ name = iconName, size = 13, color = iconColor }),
            ui.label({ text = label, fontSize = 12, fontWeight = "bold",
                       color = isUnavailable and "error" or "on_surface", maxLines = 1 }),
        }),
    }
    local lines = type(section.body) == "table" and section.body or {}
    for _, line in ipairs(lines) do
        local text = noctalia.string.trim(tostring(line))
        -- A bare "balance:" would read as a row that failed to render.
        if text:find(":$") then text = text .. " —" end
        local kind, expiry = text:match("^(.-)%s+·%s+(.+)$")
        if isResetCredits and kind and expiry then
            body[#body + 1] = ui.column({ gap = 1 }, {
                ui.label({ text = kind, fontSize = 11, fontWeight = "medium", color = "on_surface", maxLines = 2 }),
                ui.label({ text = expiry, fontSize = 10, color = "on_surface_variant", maxLines = 2 }),
            })
        else
            body[#body + 1] = ui.label({
                text = text ~= "" and text or "—",
                fontSize = 11,
                color = "on_surface_variant",
                maxLines = isResetCredits and 3 or 1,
            })
        end
    end
    return ui.column(cardStyle(CARD.gap,
        isUnavailable and "error/0.06" or nil,
        isUnavailable and "error/0.18" or nil), body)
end

-- A `text` section the CLI uses for a warning. The `credentials error:` prefix
-- and the repeated provider name are the CLI talking to a log, not to a panel
-- that already names the provider in its title.
local function noteCard(text, failureLabel)
    local clean = noctalia.string.trim(tostring(text or ""))
    clean = clean:gsub("^[Cc]redentials error:%s*", "")
    local content = {
        ui.label({ text = clean, fontSize = 11, color = "on_surface_variant",
                   flexGrow = 1, maxLines = 3 }),
    }
    if failureLabel ~= nil and failureLabel ~= "" then
        table.insert(content, 1, ui.label({
            text = failureLabel,
            fontSize = 12,
            fontWeight = "bold",
            color = "error",
        }))
    end
    return ui.row({ gap = 8, align = "start", padding = CARD.padding, radius = CARD.radius,
                    fill = failureLabel and "error/0.07" or "secondary/0.07",
                    border = failureLabel and "error/0.16" or "outline/0.06",
                    borderWidth = CARD.borderWidth }, {
        ui.glyph({ name = "alert-triangle", size = 14, color = failureLabel and "error" or "secondary" }),
        ui.column({ gap = 3, flexGrow = 1 }, content),
    })
end

-- `updatedText` heads a live report ("Updated 3 min ago"); a record is dated, not
-- updated, and reads wrong with that word in front of it.
local function recordAge(entry)
    local at = parseIso(entry and entry.fetched_at)
    if at == nil then return noctalia.tr("ui.last_reading_now") end
    local minutes = math.floor((os.time() - at) / 60)
    if minutes < 1 then return noctalia.tr("ui.last_reading_now") end
    return noctalia.tr("ui.last_reading", { minutes = minutes })
end

-- Every reading a provider sent, grouped into the subjects it is read by:
-- Windowed reports group by model; other reports keep their readings in one
-- provider card. The card and the record share this grouping.
local function groupReadings(items, windowed, entry)
    local order, byName, pools = {}, {}, {}
    for _, item in ipairs(items) do
        if item.section.type == "metric" then
            local label = tostring(item.section.label or "")
            local geminiPool = windowed and entry ~= nil
                and shared.baseProvider(entry.id) == "antigravity"
                and item.section.model_pool == true
                and (label == "Gemini" or label:match("^Gemini%s") ~= nil)
            local name = geminiPool and "Gemini" or windowed and label or ""
            if byName[name] == nil then
                byName[name] = {}
                order[#order + 1] = name
            end
            local readings = byName[name]
            if geminiPool then
                pools[name] = pools[name] or {}
                readings = pools[name]
            end
            readings[#readings + 1] = {
                section = item.section,
                title = geminiPool and (label .. (item.window ~= "" and " · " .. item.window or ""))
                    or windowed and item.window or label,
            }
        end
    end
    -- Shared windows lead the family card even if the CLI sends a model pool first.
    for name, readings in pairs(pools) do
        for _, reading in ipairs(readings) do
            byName[name][#byName[name] + 1] = reading
        end
    end
    return order, byName
end

-- While a provider is down its numbers record when it was last read, so they
-- are set in text rather than drawn as bars a glance would read as live.
local function recordCard(entry, items, windowed)
    local order, byName = groupReadings(items, windowed, entry)
    if #order == 0 then return nil end

    local body = {
        ui.label({ text = recordAge(entry), fontSize = 12, fontWeight = "semibold",
                   color = "on_surface", maxLines = 1 }),
    }
    for _, name in ipairs(order) do
        local parts = {}
        for _, reading in ipairs(byName[name]) do
            local value = tostring(reading.section.value or "")
            if value == "" or value == string.format("%d%%", tonumber(reading.section.percent) or 0) then
                value = percentText(reading.section)
            elseif displayMode() == "remaining" then
                value = value .. " " .. noctalia.tr("ui.used")
            end
            parts[#parts + 1] = noctalia.string.trim(reading.title .. " " .. value)
        end
        local line = table.concat(parts, " · ")
        if name ~= "" then
            body[#body + 1] = ui.row({ gap = 6, align = "center" }, {
                ui.label({ text = modelDisplayName(name), fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
                ui.spacer({ flexGrow = 1 }),
                ui.label({ text = line, fontSize = 11, color = "on_surface", maxLines = 1 }),
            })
        else
            body[#body + 1] = ui.label({ text = line, fontSize = 11, color = "on_surface",
                                        maxLines = 1 })
        end
    end
    return ui.column(CARD, body)
end

-- Everything in a report that is not a reading: credit blocks, headings,
-- warnings, free text. A provider that is down loses its gauges, not the rest of
-- what the CLI said, so both passes draw these the same way. `warned` says the
-- warning already stands at the top, so it is not said twice.
-- A credits block with zero balance and no usage is skipped: showing an empty
-- card for a user who does not purchase or use credits is noise.
local function isEmptyCredits(section)
    if section.type ~= "block" then return false end
    local label = tostring(section.label or ""):lower()
    if not label:find("credit", 1, true) then return false end

    local lines = type(section.body) == "table" and section.body or {}
    if #lines == 0 then return true end

    local hasPositive = false
    for _, line in ipairs(lines) do
        local text = tostring(line):lower()
        local balanceVal = text:match("balance:%s*(.*)")
        if balanceVal ~= nil then
            local num = tonumber(balanceVal:match("[%d%.]+"))
            if num ~= nil and num > 0 then
                hasPositive = true
                break
            end
        else
            for numStr in text:gmatch("[%d%.]+") do
                local n = tonumber(numStr)
                if n ~= nil and n > 0 then
                    hasPositive = true
                    break
                end
            end
        end
    end
    return not hasPositive
end

local function otherCard(section, warned)
    if section.type == "block" then
        if isEmptyCredits(section) then return nil end
        return blockCard(section)
    end

    if section.type == "text" then
        local label = tostring(section.label or "")
        local value = tostring(section.value or "")
        if transportError(label) or transportError(value) then return nil end
        if label:lower() == "warning" or saysError(value) then
            if warned then return nil end
            return noteCard(value)
        end
        if label:lower() == "source" then
            return nil
        end
        local limit, percent = section.limit_cents, section.percent
        if not warned and type(limit) == "number" and limit > 0 and limit < math.huge
            and type(percent) == "number" and percent == percent and math.abs(percent) < math.huge then
            return ui.column(CARD, {
                ui.row({ gap = 6, align = "center" }, {
                    ui.label({ text = label, fontSize = 12, fontWeight = "semibold", color = "on_surface", maxLines = 1 }),
                    ui.spacer({ flexGrow = 1 }),
                    ui.label({ text = value, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
                }),
                ui.progress({ progress = ratio(percent), height = 5, radius = 2,
                    fill = severityRole(section, "primary"), track = "on_surface/0.10" }),
            })
        end
        local props = cardStyle(6)
        props.align = "center"
        return ui.row(props, {
            ui.label({ text = label, fontSize = 10, color = "on_surface_variant" }),
            ui.spacer({ flexGrow = 1 }),
            ui.label({ text = value, fontSize = 10, fontWeight = "medium", color = "on_surface", maxLines = 1 }),
        })
    end

    if section.type == "title" then
        return ui.label({
            text = tostring(section.value or section.label or ""),
            fontSize = 12, fontWeight = "semibold", color = "on_surface",
        })
    end

    -- Keep schema additions visible instead of silently losing report data.
    return ui.label({
        text = tostring(section.value or section.label or section.type or "—"),
        fontSize = 11, color = "on_surface_variant",
    })
end

-- ── Provider list ─────────────────────────────────────────────────────────────

local function providerRow(entry, selected, compact)
    local displayName = tostring(entry.display_name or entry.name or entry.id or "")
    local broken = entry.status == "error" or unavailable(entry)

    local children = {
        ui.glyph({
            name = providerGlyph(entry.id, entry.brand),
            size = compact and 16 or 15,
            color = selected and "primary" or "on_surface",
        }),
    }

    if not compact then
        children[#children + 1] = ui.label({
            text = displayName,
            fontSize = 12,
            fontWeight = selected and "bold" or "medium",
            color = selected and "primary" or "on_surface",
            maxLines = 1,
        })
    end

    if broken then
        children[#children + 1] = ui.glyph({
            name = "alert-circle",
            size = 12,
            color = "error",
        })
    end

    return ui.row({
        key = "provider-" .. tostring(entry.id),
        gap = 6,
        align = "center",
        justify = "center",
        tooltip = compact and displayName or nil,
        paddingH = 10,
        minHeight = 30,
        paddingV = 4,
        radius = 8,
        flexGrow = 1,
        fill = selected and "primary/0.14" or "surface_variant/0.22",
        border = selected and "primary/0.45" or "outline/0.08",
        borderWidth = 1,
        onClick = function()
            noctalia.state.set("selected", tostring(entry.id))
            render()
        end,
    }, children)
end

-- ── Render ────────────────────────────────────────────────────────────────────

-- The CLI's own words come last and smallest, where a bug report can quote them.
local function errorBlock()
    local key = "ui.error." .. failure.code
    local children = {
        ui.row({ gap = 6, align = "center" }, {
            ui.glyph({ name = "alert-circle", size = 18, color = "error" }),
            ui.label({ text = noctalia.tr(key), fontSize = 12, fontWeight = "bold", color = "error" }),
        }),
        ui.label({ text = noctalia.tr(key .. "_hint"), fontSize = 11, color = "on_surface_variant" }),
    }

    if failure.detail ~= "" then
        children[#children + 1] = ui.label({
            text = failure.detail, fontSize = 11, color = "on_surface_variant", maxLines = 3,
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
            fontSize = 11, color = "on_surface", maxLines = 2,
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


local function copySummary(entry)
    if entry == nil then return end
    local parts = { tostring(entry.display_name or entry.id) }
    local sub = tostring(entry.plan or "")
    if sub ~= "" and sub ~= parts[1] then
        parts[#parts + 1] = "(" .. sub .. ")"
    end
    local metricStrs = {}
    local metrics = type(entry.metrics) == "table" and entry.metrics or {}
    for _, m in ipairs(metrics) do
        if type(m) == "table" and m.label and shared.displayPercent(m, displayMode()) ~= nil then
            metricStrs[#metricStrs + 1] = tostring(m.label) .. " " .. percentText(m)
        end
    end
    if #metricStrs == 0 then
        local balance = shared.balanceText(entry)
        if balance ~= nil then metricStrs[#metricStrs + 1] = balance end
    end
    if #metricStrs > 0 then
        parts[#parts + 1] = "· " .. table.concat(metricStrs, " · ")
    end
    local text = table.concat(parts, " ")
    if type(noctalia.copyToClipboard) == "function" then
        noctalia.copyToClipboard(text, "text/plain")
    end
end

local function statusIndicator(entry)
    if failure.code ~= "" then
        return ui.row({ gap = 4, align = "center" }, {
            ui.glyph({ name = "clock-exclamation", size = 12, color = "secondary" }),
            ui.label({ text = noctalia.tr("ui.stale_hint"), fontSize = 11,
                color = "on_surface_variant", maxLines = 1 }),
            ui.button({ text = noctalia.tr("ui.retry"), glyph = "refresh",
                variant = "ghost", controlSize = "sm", enabled = not polling,
                onClick = requestRefresh }),
        })
    end
    if entry == nil then return nil end
    if entry.stale == true then
        return ui.row({ gap = 4, align = "center" }, {
            ui.glyph({ name = "clock-exclamation", size = 12, color = "secondary" }),
            ui.label({ text = noctalia.tr("ui.stale_hint"), fontSize = 11,
                color = "on_surface_variant", maxLines = 1 }),
        })
    end
    if unavailable(entry) then
        return ui.label({ text = noctalia.tr("ui.unavailable"), fontSize = 11,
            color = "error", maxLines = 1 })
    end

    if type(entry.metrics) ~= "table" or #entry.metrics == 0 then
        return ui.label({ text = shared.balanceText(entry) or noctalia.tr("ui.waiting"), fontSize = 11,
            color = "on_surface_variant", maxLines = 1 })
    end

    local models = modelHeadlines(entry)
    if #models == 0 then
        models = { { displayName = "", glyph = providerGlyph(entry.id, entry.brand), metrics = entry.metrics } }
    end
    local notices = {}
    for _, model in ipairs(models) do
        local short, weekly = dualMetrics(model.metrics)
        local affected = {}
        for index, metric in ipairs(model.metrics or {}) do
            local percent = type(metric) == "table" and tonumber(metric.percent) or nil
            if percent ~= nil and percent > 50 then
                local window = tostring(metric.label or "")
                local seconds = tonumber(metric.window_secs)
                local label = window:lower()
                if shared.baseProvider(entry.id) == "antigravity" then
                    window = metric == short and "5h" or metric == weekly and "7d" or ""
                elseif seconds == 18000 or (seconds == nil and (label:match("5h$") or label == "session")) then
                    window = "5h"
                elseif seconds == 604800 or (seconds == nil and (label:match("weekly$") or label:match("7d$"))) then
                    window = "7d"
                end
                affected[#affected + 1] = { metric = metric, percent = percent,
                    window = window, index = index }
            end
        end
        table.sort(affected, function(a, b)
            local aBlocked, bBlocked = a.percent >= 100, b.percent >= 100
            if aBlocked ~= bBlocked then return aBlocked end
            if aBlocked and bBlocked then
                local aReset = parseIso(a.metric.reset_at) or 0
                local bReset = parseIso(b.metric.reset_at) or 0
                if aReset ~= bReset then return aReset > bReset end
            end
            if a.percent ~= b.percent then return a.percent > b.percent end
            if a.window ~= b.window then return a.window == "7d" end
            return a.index < b.index
        end)
        if affected[1] ~= nil then
            affected[1].model = model
            affected[1].modelIndex = #notices + 1
            notices[#notices + 1] = affected[1]
        end
    end

    if #notices > 0 then
        table.sort(notices, function(a, b)
            local aBlocked, bBlocked = a.percent >= 100, b.percent >= 100
            if aBlocked ~= bBlocked then return aBlocked end
            if aBlocked then
                local aReset = parseIso(a.metric.reset_at) or 0
                local bReset = parseIso(b.metric.reset_at) or 0
                if aReset ~= bReset then return aReset > bReset end
            end
            if a.percent ~= b.percent then return a.percent > b.percent end
            return a.modelIndex < b.modelIndex
        end)
        local pills = {}
        for index = 1, math.min(#notices, 2) do
            local item = notices[index]
            local metric = item.metric
            local blocked = item.percent >= 100
            local role = blocked and "error" or severityRole(metric, "primary")
            local modelName = tostring(item.model.displayName or "")
            if modelName == "Claude & GPT OSS" then modelName = "OSS" end
            local text = (modelName ~= "" and modelName .. " " or "")
                .. (item.window ~= "" and item.window .. " " or "")
                .. percentText(metric)
            local severity = tostring(metric.severity or "")
            local detail = blocked and noctalia.tr("ui.quota_exhausted")
                or (severity == "high" or severity == "critical")
                    and noctalia.tr("ui.severity." .. severity)
                or percentText(metric)
            local left = blocked and shared.fixedCountdown(metric) or ""
            if left ~= "" then detail = detail .. " · " .. noctalia.tr("ui.quota_reset", { time = left }) end
            pills[#pills + 1] = ui.row({ gap = 3, align = "center", paddingH = 6,
                paddingV = 2, radius = 5, fill = role .. "/0.10",
                border = role .. "/0.20", borderWidth = 1, tooltip = detail }, {
                ui.glyph({ name = item.model.glyph, size = 10, color = role }),
                ui.label({ text = text, fontSize = 10,
                    fontWeight = "bold", color = role, maxLines = 1 }),
            })
        end
        return ui.row({ gap = 4, align = "center" }, pills)
    end
    return nil
end

local function detailPane(entry)
    local children = {}

    local cards = {}
    local sections = entry ~= nil and type(entry.sections) == "table" and entry.sections or {}

    -- Pass one: pair every reading with the heading over it, and drop the padding
    -- the CLI puts between sections -- the column sets its own gap, and a spacer
    -- left by a consumed heading would double it.
    local windowed = false
    local heading = ""
    local items = {}
    for _, section in ipairs(sections) do
        if type(section) == "table" then
            local text = section.type == "text"
            if text and noctalia.string.trim(tostring(section.value or "")) == "" then
                heading = tostring(section.label or "")
                windowed = windowed or heading ~= ""
            elseif section.type ~= "spacer" then
                items[#items + 1] = { section = section, window = heading }
            end
        end
    end

    -- A provider that is down draws no gauges: a bar reads as a live reading, and
    -- nothing is reading. The warning takes their place, and the last numbers
    -- follow as a record, unless a plan change made them meaningless.
    local warning = entry ~= nil and providerWarning(entry) or ""
    if warning ~= "" then
        local failureLabel = readFailure(entry) and noctalia.tr("ui.error.failed") or nil
        cards[#cards + 1] = noteCard(warning, failureLabel)
        local id = tostring(entry.id or "")
        local previous = lastPlan[id]
        local current = tostring(entry.plan or "")
        -- Only a plan the CLI names on both sides is evidence of a change: an
        -- entry that fell over and stopped naming one says nothing.
        if previous ~= nil and previous ~= "" and current ~= "" and previous ~= current then
            cards[#cards + 1] = ui.label({ text = noctalia.tr("ui.plan_changed"), fontSize = 11,
                                           color = "on_surface_variant", maxLines = 2 })
        else
            local record = recordCard(entry, items, windowed)
            if record ~= nil then cards[#cards + 1] = record end
        end
    else
        -- Pass two: every reading a provider sends, in the cards it is read by.
        local order, byName = groupReadings(items, windowed, entry)
        for _, name in ipairs(order) do
            local cardName, glyph = name, nil
            local readings = byName[name]
            if not windowed and entry ~= nil then
                cardName = ""
                for _, reading in ipairs(readings) do
                    local label = tostring(reading.title):lower()
                    if label:match("5h$") then
                        reading.title = noctalia.tr("ui.session")
                    elseif label:match("weekly$") then
                        reading.title = noctalia.tr("ui.weekly")
                    end
                end
            end
            cards[#cards + 1] = stackCard(cardName, readings, glyph)
        end
    end

    -- The rest is the same either way: losing the gauges is no reason to lose
    -- what else the CLI said.
    for _, item in ipairs(items) do
        if item.section.type ~= "metric" then
            local card = otherCard(item.section, warning ~= "")
            if card ~= nil then cards[#cards + 1] = card end
        end
    end

    -- Keep the same card width in both modes and the provider header fixed above.
    if #cards > 0 then
        children[#children + 1] = ui.scroll({ gap = 8,
            paddingV = 2, align = "stretch", flexGrow = 1 }, cards)
    elseif entry ~= nil then
        children[#children + 1] = ui.row({ gap = 6, align = "center" }, {
            ui.glyph({ name = "info-circle", size = 14, color = "on_surface_variant" }),
            ui.label({ text = noctalia.tr("ui.no_usage"), fontSize = 11, color = "on_surface_variant" }),
        })
        children[#children + 1] = ui.spacer({ flexGrow = 1 })
    end

    return ui.column({ gap = 6, paddingH = 0, paddingV = 0, flexGrow = 1,
                       align = "stretch" }, children)
end

local function requestCatalog()
    noctalia.state.set("command", { action = "catalog", at = noctalia.nowMs() })
end

local function setupButton()
    return ui.button({
        text = noctalia.tr(showSetup and "ui.back_to_usage" or "ui.provider_setup"),
        glyph = showSetup and "arrow-left" or "list-details",
        variant = "outline", controlSize = "sm",
        onClick = function()
            showSetup = not showSetup
            if showSetup then
                expandedDiagnosticKey = nil
                showActions = false
                showEnabled, showDisabled = false, false
                requestCatalog()
            end
            render()
        end,
    })
end


local function recovery(entry, cause, missingCredential)
    local text = cause:lower()
    if readFailure(entry) then return "ui.diagnostics_update_cli" end
    if shared.terminalAuth(entry) or text:match("http%s*:?%s*40[13]") then
        return "ui.diagnostics_login"
    end
    if text:find("429", 1, true) or text:find("rate limit", 1, true)
        or text:find("timeout", 1, true) or text:find("timed out", 1, true)
        or text:find("temporar", 1, true) or text:match("http%s*:?%s*5%d%d") then
        return "ui.diagnostics_retry"
    end
    if text:find("authentication failed", 1, true) or text:find("auth failed", 1, true)
        or (text:find("authentication error", 1, true)
            and (text:find("expired", 1, true) or text:find("invalid", 1, true)
                or text:find("reject", 1, true) or text:find("unauthorized", 1, true))) then
        return "ui.diagnostics_login"
    end
    if shared.baseProvider(entry.id) == "antigravity" then return "ui.diagnostics_local_app" end
    if text:find("no api key", 1, true) or missingCredential then return "ui.diagnostics_configure" end
    return "ui.diagnostics_check_cli"
end

local function setupPane()
    local expandedFound = false
    -- Technical causes expand inside the scrolling diagnostics, away from controls.
    local function diagnosticCard(name, cause, impact, guidance, details, identity)
        local key = tostring(identity or "global") .. "\0" .. name .. "\0" .. cause .. "\0" .. tostring(details or "")
        local expanded = details ~= nil and expandedDiagnosticKey == key
        if expanded then expandedFound = true end
        local children = {
            ui.label({ text = name, fontSize = 12, fontWeight = "semibold", color = "on_surface", maxLines = 2 }),
            ui.label({ text = cause, fontSize = 11, color = "on_surface_variant", maxLines = 4 }),
            ui.label({ text = noctalia.tr(impact), fontSize = 11, color = "on_surface_variant", maxLines = 2 }),
            ui.label({ text = noctalia.tr(guidance), fontSize = 11, color = "on_surface", maxLines = 3 }),
        }
        if details ~= nil and details ~= "" and details ~= cause then
            children[#children + 1] = ui.button({ text = noctalia.tr("ui.details"),
                glyph = expanded and "chevron-up" or "chevron-down", variant = "outline", controlSize = "sm",
                onClick = function()
                    if expanded then expandedDiagnosticKey = nil else expandedDiagnosticKey = key end
                    render()
                end })
            if expanded then
                children[#children + 1] = ui.label({ text = details, fontSize = 11,
                    color = "on_surface_variant", maxLines = 0 })
            end
        end
        return ui.column({ gap = 4, padding = 8, radius = 8,
            fill = "error/0.06", border = "error/0.12", borderWidth = 1 }, children)
    end
    local rows = { ui.label({ text = noctalia.tr("ui.setup_hint"), fontSize = 12,
        color = "on_surface_variant", maxLines = 2 }) }
    local problems, failedDefaults, failedProviders, readyProviders, disabledProviders = 0, {}, {}, {}, {}
    local missingCredentials = {}
    local validCatalog = not catalogError and not catalogLoading
        and type(catalog) == "table" and type(catalog.vendors) == "table"
    local vendors = validCatalog and catalog.vendors or {}
    for _, vendor in ipairs(vendors) do
        if type(vendor) == "table" then
            local id = shared.baseProvider(vendor.id)
            if vendor.enabled == false then disabledProviders[id] = true end
            missingCredentials[id] = vendor.enabled == true and vendor.needs_credential == true
                and vendor.configured == false and id ~= "antigravity"
        end
    end
    local recoverUsage = failure.code ~= "" or report == nil or (type(report) == "table" and report.stale == true)
    if failure.code ~= "" then
        rows[#rows + 1] = diagnosticCard(noctalia.tr("ui.error." .. failure.code),
            failure.detail ~= "" and failure.detail or noctalia.tr("ui.error." .. failure.code .. "_hint"),
            report ~= nil and "ui.diagnostics_old_usage" or "ui.diagnostics_no_usage",
            failure.code == "not_installed" and "ui.error.not_installed_hint" or "ui.diagnostics_retry")
        problems = problems + 1
    elseif report == nil or report.stale == true then
        rows[#rows + 1] = diagnosticCard(noctalia.tr("ui.diagnostics_usage_status"),
            noctalia.tr(report == nil and "ui.waiting" or "ui.stale_hint"),
            report == nil and "ui.diagnostics_no_usage" or "ui.diagnostics_old_usage", "ui.diagnostics_retry")
        problems = problems + 1
    end
    local rawEntries = type(report) == "table" and type(report.entries) == "table" and report.entries or {}
    for _, entry in ipairs(rawEntries) do
        local base = type(entry) == "table" and shared.baseProvider(entry.id) or ""
        if type(entry) == "table" and not unavailable(entry) and not shared.terminalAuth(entry)
            and entry.stale ~= true and entry.status == "ready" then
            readyProviders[base] = true
        end
        if type(entry) == "table" and not disabledProviders[base] and (entry.status == "error" or unavailable(entry)
            or shared.terminalAuth(entry) or entry.stale == true) then
            local cause = providerWarning(entry)
            if cause == "" then
                local sections = type(entry.sections) == "table" and entry.sections or {}
                for _, section in ipairs(sections) do
                    if type(section) == "table" and section.type == "text"
                        and (tostring(section.label or ""):lower() == "unavailable"
                            or transportError(section.label) or transportError(section.value)) then
                        cause = tostring(section.value or section.label or "")
                        if cause ~= "" then break end
                    end
                end
            end
            if cause == "" then cause = noctalia.tr(entry.stale == true and "ui.stale_hint" or "ui.unavailable") end
            local historical = failure.code ~= "" or report.stale == true
            local guidance = historical and "ui.diagnostics_recheck" or recovery(entry, cause, missingCredentials[base])
            local configuring = guidance == "ui.diagnostics_configure"
            rows[#rows + 1] = diagnosticCard(tostring(entry.display_name or entry.name or entry.id or ""),
                configuring and noctalia.tr("ui.setup_required") or cause,
                (historical or entry.stale == true) and "ui.diagnostics_old_usage" or "ui.diagnostics_no_usage",
                guidance, configuring and cause or nil, "entry:" .. tostring(entry.id or ""))
            problems = problems + 1
            recoverUsage = true
            failedProviders[base] = true
            -- Keep named failures separate from the default provider catalog facts.
            local id = tostring(entry.id or "")
            if not id:find("@", 1, true) then failedDefaults[id] = true end
        end
    end
    if catalogLoading then
        rows[#rows + 1] = ui.label({ text = noctalia.tr("ui.setup_loading"), fontSize = 12, color = "on_surface_variant" })
    end
    local enabled, disabled = {}, {}
    if not validCatalog then
        rows[#rows + 1] = ui.label({ text = noctalia.tr("ui.setup_unavailable"), fontSize = 12,
            color = "on_surface_variant", maxLines = 3 })
    elseif #vendors == 0 then
        rows[#rows + 1] = ui.label({ text = noctalia.tr("ui.setup_empty"), fontSize = 12, color = "on_surface_variant" })
    end
    for _, vendor in ipairs(vendors) do
        if type(vendor) == "table" then
            local missing = vendor.enabled == true and vendor.needs_credential == true and vendor.configured == false
                and shared.baseProvider(vendor.id) ~= "antigravity"
            if missing and not readyProviders[shared.baseProvider(vendor.id)]
                and not failedProviders[shared.baseProvider(vendor.id)] then
                rows[#rows + 1] = diagnosticCard(tostring(vendor.name or vendor.id or ""),
                    noctalia.tr("ui.setup_required"), "ui.diagnostics_no_usage", "ui.diagnostics_configure",
                    nil, "catalog:" .. tostring(vendor.id or ""))
                problems = problems + 1
                recoverUsage = true
            elseif not failedDefaults[tostring(vendor.id or "")] then
                local group = vendor.enabled == true and enabled or disabled
                group[#group + 1] = vendor
            end
        end
    end
    if not expandedFound then expandedDiagnosticKey = nil end
    if validCatalog and report ~= nil and problems == 0 and not catalogLoading then
        rows[#rows + 1] = ui.label({ text = noctalia.tr("ui.diagnostics_no_problems"), fontSize = 12, color = "on_surface_variant" })
    end
    local controls = { ui.button({ text = noctalia.tr("ui.diagnostics_refresh_status"), glyph = "refresh",
        variant = "outline", controlSize = "sm", enabled = not catalogLoading, onClick = requestCatalog }) }
    if recoverUsage then
        controls[#controls + 1] = ui.button({ text = noctalia.tr("ui.diagnostics_refresh_usage"), glyph = "refresh",
            variant = "outline", controlSize = "sm", enabled = not polling, onClick = requestRefresh })
    end
    local function group(vendors, key, expanded, toggle)
        if #vendors == 0 then return end
        rows[#rows + 1] = ui.button({ text = noctalia.tr(key, { count = #vendors }),
            glyph = expanded and "chevron-up" or "chevron-down", variant = "outline", controlSize = "sm", onClick = toggle })
        if not expanded then return end
        for _, vendor in ipairs(vendors) do
            local status = vendor.enabled ~= true and "ui.setup_disabled"
                or vendor.needs_credential == false and "ui.setup_no_credential"
                or vendor.configured == true and "ui.setup_credentials_found" or "ui.setup_required"
            rows[#rows + 1] = ui.row({ gap = 8, paddingV = 6, align = "center" }, {
                ui.glyph({ name = providerGlyph(vendor.id), size = 15, color = "on_surface" }),
                ui.label({ text = tostring(vendor.name or vendor.id or ""), fontSize = 12, color = "on_surface", maxLines = 2 }),
                ui.spacer({ flexGrow = 1 }),
                ui.label({ text = noctalia.tr(status), fontSize = 11, color = "on_surface_variant", maxLines = 2 }),
            })
        end
    end
    group(enabled, "ui.diagnostics_enabled", showEnabled, function() showEnabled = not showEnabled; render() end)
    group(disabled, "ui.diagnostics_disabled", showDisabled, function() showDisabled = not showDisabled; render() end)
    return ui.column({ gap = 8, flexGrow = 1, align = "stretch" }, {
        ui.row({ gap = 8, align = "center" }, controls),
        ui.scroll({ gap = 8, flexGrow = 1, align = "stretch" }, rows),
    })
end

function render()
    if showSetup then
        panel.render(ui.column({ key = "diagnostics", gap = 8, padding = 10, flexGrow = 1, align = "stretch" }, {
            ui.row({ gap = 8, align = "center" }, {
                ui.label({ text = noctalia.tr("ui.provider_setup"), fontSize = 14,
                    fontWeight = "bold", color = "on_surface" }),
                ui.spacer({ flexGrow = 1 }),
                setupButton(),
            }),
            ui.separator({ orientation = "horizontal", color = "outline", opacity = 0.15 }),
            setupPane(),
        }))
        return
    end
    local entry = currentEntry()
    -- A failure with nothing behind it is the whole panel; with a report behind
    -- it, a banner over readings that are still the best answer available. A
    -- report whose every row was dropped still counts as one: the panel it draws
    -- is empty, not absent.
    if failure.code ~= "" and report == nil then
        -- The panel keeps its manifest size, and a failure has nowhere near
        -- 720x400 to say. Bounded and centred, the empty surround reads as
        -- composition rather than a half-drawn frame.
        panel.render(ui.column({ key = "error", flexGrow = 1, padding = 14, align = "center", justify = "center" }, {
            ui.column({ gap = 10, width = 320 }, {
                ui.row({ gap = 8, align = "center" }, {
                    ui.glyph({ name = "brain", size = 18, color = "primary" }),
                    ui.label({ text = noctalia.tr("ui.title"), fontSize = 15,
                               fontWeight = "bold", color = "on_surface" }),
                }),
                errorBlock(),
                setupButton(),
            }),
        }))
        return
    end

    local candidates = {}
    for _, candidate in ipairs(entries()) do
        if configured(candidate) then
            candidates[#candidates + 1] = candidate
        end
    end

    local compactTabs = #candidates > 3

    local tabs = {}
    for _, candidate in ipairs(candidates) do
        tabs[#tabs + 1] = providerRow(candidate, entry ~= nil and candidate.id == entry.id, compactTabs)
    end

    local headerActions = {}
    local providerActions = { setupButton() }
    local updatedRow = nil

    local fetched = parseIso(entry and entry.fetched_at)
    if fetched ~= nil then
        updatedRow = ui.row({ gap = 3, align = "center", tooltip = updatedText(entry) }, {
            ui.glyph({ name = "clock", size = 10, color = "on_surface_variant" }),
            ui.label({
                text = noctalia.tr("ui.updated") .. " " .. noctalia.formatTime(noctalia.timeFormat(), fetched),
                fontSize = 11,
                color = "on_surface_variant",
            }),
        })
    end

    if entry ~= nil then
        providerActions[#providerActions + 1] = ui.button({
            glyph = "copy",
            variant = "outline",
            controlSize = "sm",
            tooltip = noctalia.tr("ui.copy_summary"),
            onClick = function() copySummary(entry) end,
        })
        local dashUrl = shared.providerDashboard(entry.id)
        if dashUrl ~= nil then
            providerActions[#providerActions + 1] = ui.button({
                glyph = "external-link",
                variant = "outline",
                controlSize = "sm",
                tooltip = noctalia.tr("ui.open_dashboard"),
                onClick = function()
                    if type(noctalia.runAsync) == "function" then
                        noctalia.runAsync("xdg-open '" .. dashUrl .. "'")
                    end
                end,
            })
        end
    end

    headerActions[#headerActions + 1] = ui.button({
        glyph = polling and "loader-2" or refreshQueued and "clock" or "refresh",
        variant = "outline", controlSize = "sm",
        tooltip = noctalia.tr(polling and "ui.refreshing"
            or refreshQueued and "ui.refresh_queued" or "ui.refresh"),
        enabled = not polling,
        onClick = requestRefresh,
    })
    providerActions[#providerActions + 1] = ui.button({
        glyph = "settings",
        variant = "outline", controlSize = "sm",
        tooltip = noctalia.tr("ui.settings"),
        onClick = function() noctalia.openSettings() end,
    })
    headerActions[#headerActions + 1] = ui.button({
        glyph = "dots",
        variant = "outline", controlSize = "sm",
        tooltip = noctalia.tr("ui.more_actions"),
        onClick = function() showActions = not showActions; render() end,
    })
    headerActions[#headerActions + 1] = ui.button({
        glyph = "x",
        variant = "outline", controlSize = "sm",
        tooltip = noctalia.tr("ui.close"),
        onClick = function()
            if type(panel.close) == "function" then panel.close() end
        end,
    })

    local topChildren = {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = "brain", size = 18, color = "primary" }),
            ui.label({ text = noctalia.tr("ui.title"), fontSize = 14, fontWeight = "bold", color = "on_surface" }),
            ui.spacer({ flexGrow = 1 }),
            ui.row({ gap = 4, align = "center" }, headerActions),
        }),
    }

    if showActions then
        topChildren[#topChildren + 1] = ui.row({ gap = 4, align = "center", justify = "end" }, providerActions)
    end

    if #tabs > 0 then
        topChildren[#topChildren + 1] = ui.row({ key = "tabs-dock", gap = 6,
            align = "center", justify = "center" }, tabs)
    end

    local footer = nil
    local status = statusIndicator(entry)
    if updatedRow ~= nil or status ~= nil then
        local providerMeta = {}
        if updatedRow ~= nil then providerMeta[#providerMeta + 1] = updatedRow end
        if status ~= nil then providerMeta[#providerMeta + 1] = status end
        providerMeta[#providerMeta + 1] = ui.spacer({ flexGrow = 1 })
        footer = ui.row({ key = "meta-row", gap = 4, align = "center" }, providerMeta)
    end

    -- Distinct screens must not reuse controls with different retained layout props.
    panel.render(ui.column({ key = "usage", gap = 6, paddingH = 10, paddingV = 8, flexGrow = 1, align = "stretch" }, {
        ui.column({ gap = 6 }, topChildren),
        ui.separator({ orientation = "horizontal", color = "outline", opacity = 0.15 }),
        detailPane(entry),
        footer,
    }))
end

-- ── Wiring ────────────────────────────────────────────────────────────────────

-- Rebuilt from the report rather than added to, so the map holds one key per
-- provider on screen instead of every id the panel has seen since it opened.
local function rememberPlans()
    local seen = {}
    for _, entry in ipairs(entries()) do
        if type(entry) == "table" then
            local id = tostring(entry.id or "")
            -- A provider that is down is serving what it cached, so the plan to
            -- keep is the one it last reported for real.
            if unavailable(entry) then
                seen[id] = lastPlan[id]
            else
                seen[id] = tostring(entry.plan or "")
            end
        end
    end
    lastPlan = seen
end

noctalia.state.watch("report", function(value)
    if type(value) == "table" then
        report = value
        failure = NO_FAILURE
        rememberPlans()
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

noctalia.state.watch("catalog", function(value)
    catalog = value
    if showSetup then render() end
end)

noctalia.state.watch("catalog_loading", function(value)
    catalogLoading = value == true
    if showSetup then render() end
end)

noctalia.state.watch("catalog_error", function(value)
    catalogError = value == true
    if showSetup then render() end
end)

function onOpen(context)
    expandedDiagnosticKey = nil
    showEnabled, showDisabled = false, false
    showActions = false
    showSetup = context == "setup"
    catalog = noctalia.state.get("catalog")
    catalogLoading = noctalia.state.get("catalog_loading") == true
    catalogError = noctalia.state.get("catalog_error") == true
    if not showSetup and type(context) == "string" and context ~= "" then
        noctalia.state.set("selected", context)
    end
    -- Every open asks for fresh numbers. The CLI answers from its cache when it
    -- has one, and the poller drops requests that arrive too close together.
    if showSetup then requestCatalog() else requestRefresh() end
    report = noctalia.state.get("report")
    rememberPlans()
    failure = asFailure(noctalia.state.get("error"))
    polling = noctalia.state.get("polling") == true
    refreshQueued = noctalia.state.get("refresh_queued") == true
    -- Countdowns tick locally; the CLI is only woken by the poller's interval.
    panel.setWantsSecondTicks(true)
    render()
end

-- Panel second tick, for the countdowns.
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
        if showSetup then requestCatalog() else requestRefresh() end
    elseif not showSetup and (lower == "up" or lower == "down" or lower == "left" or lower == "right") then
        local list = {}
        local currentIndex = 1
        local current = currentEntry()
        for _, candidate in ipairs(entries()) do
            if configured(candidate) then
                list[#list + 1] = candidate
                if current ~= nil and candidate.id == current.id then
                    currentIndex = #list
                end
            end
        end
        if #list > 1 then
            local nextIndex = (lower == "up" or lower == "left") and ((currentIndex - 2 + #list) % #list + 1)
                                                                 or ((currentIndex % #list) + 1)
            noctalia.state.set("selected", list[nextIndex].id)
            render()
        end
    end
end

render()
