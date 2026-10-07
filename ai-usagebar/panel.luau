--!nonstrict
-- Expanded panel for one provider. It renders `sections[]`, the CLI's lossless
-- view, so the credit blocks and free text that `metrics[]` drops still show up.

local report = nil
local polling = false
local refreshQueued = false

local shared = require("./shared.luau")
local providerGlyph, parseIso = shared.providerGlyph, shared.parseIso
local countdown, resetClock = shared.countdown, shared.resetClock
local ratio, headline, severityRole = shared.ratio, shared.headline, shared.severityRole
local modelHeadlines, isCritical, dualMetrics = shared.modelHeadlines, shared.isCritical, shared.dualMetrics
local modelGlyph = shared.modelGlyph
local modelDisplayName = shared.modelDisplayName
local elapsedPercent, pace = shared.elapsedPercent, shared.pace
local requestRefresh = shared.requestRefresh
local providerWarning, unavailable, readFailure = shared.warning, shared.unavailable, shared.readFailure
local saysError, transportError = shared.saysError, shared.transportError
local NO_FAILURE, asFailure = shared.NO_FAILURE, shared.asFailure

local failure = NO_FAILURE

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
-- `muted` is for the second case, where the card is already titled.
local function metricRows(section, title, muted)
    local percent = tonumber(section.percent) or 0
    local tint = severityRole(section, "on_surface")
    local fill = severityRole(section, "primary")
    local value = tostring(section.value or ""):gsub(" of ", " / ")
    local showValue = value ~= "" and value ~= string.format("%d%%", percent)

    local left = countdown(section)
    local clock = resetClock(section)
    local paceText, _, paceWord = pace(section.detail)

    local resetStr = ""
    if left ~= "" then
        resetStr = left
        if clock ~= "" then resetStr = resetStr .. " (" .. clock .. ")" end
    end

    local displayTitle = tostring(title or "")

    -- Title on the left; severity and percentage on the right.
    local rightMeta = {}
    local word = severityWord(section)
    if word ~= nil then
        local sevRole = isCritical(section) and "error" or severityRole(section, "secondary")
        rightMeta[#rightMeta + 1] = ui.row({
            paddingH = 6, paddingV = 2, radius = 5, align = "center",
            fill = sevRole .. "/0.15",
        }, {
            ui.label({ text = word, fontSize = 10, fontWeight = "bold", color = sevRole }),
        })
    end

    rightMeta[#rightMeta + 1] = ui.row({
        paddingH = 6, paddingV = 2, radius = 5, align = "center", justify = "center",
        fill = tint .. "/0.10",
    }, {
        ui.label({ text = string.format("%d%%", percent), fontSize = 12,
                   fontWeight = "bold", color = tint, textAlign = "center" }),
    })

    local topRow = ui.row({ gap = 8, align = "center" }, {
        ui.label({
            text = displayTitle,
            fontSize = muted and 12 or 13,
            fontWeight = "semibold",
            color = "on_surface",
            maxLines = 1,
        }),
        ui.spacer({ flexGrow = 1 }),
        ui.row({ gap = 5, align = "center", justify = "end" }, rightMeta),
    })

    -- Usage bar.
    local progressBar = ui.progress({
        progress = ratio(percent),
        fill = fill,
        track = "on_surface/0.10",
        radius = 2,
        height = 5,
    })

    -- Reset on the left, pace on the right.
    local bottomRowElements = {}
    if resetStr ~= "" then
        bottomRowElements[#bottomRowElements + 1] = ui.row({ gap = 4, align = "center",
            paddingH = 5, paddingV = 2, radius = 5, fill = "on_surface/0.06" }, {
            ui.glyph({ name = "clock", size = 10, color = "on_surface_variant" }),
            ui.label({ text = resetStr, fontSize = 11, color = "on_surface_variant",
                       maxLines = 2, maxWidth = paceText ~= "" and 230 or 340 }),
        })
    end

    local subRight = {}
    if paceText ~= "" then
        local paceColor = paceWord == "ahead" and "secondary"
            or paceWord == "behind" and "error"
            or "on_surface_variant"
        local paceIcon = paceWord == "ahead" and "trending-up"
            or paceWord == "behind" and "trending-down"
            or "check"
        subRight[#subRight + 1] = ui.row({ gap = 3, align = "center" }, {
            ui.glyph({ name = paceIcon, size = 10, color = paceColor }),
            ui.label({ text = paceText, fontSize = 10, fontWeight = "medium", color = paceColor, maxLines = 1 }),
        })
    end

    local body = { topRow, progressBar }

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

local CARD = { gap = 6, padding = 10, radius = 9, fill = "surface_variant/0.34",
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
            ui.row({
                width = 20, height = 20, radius = 5,
                fill = "primary/0.14", align = "center", justify = "center",
            }, {
                ui.glyph({ name = glyph or modelGlyph(name), size = 12, color = "primary" }),
            }),
            ui.label({ text = glyph and name or modelDisplayName(name), fontSize = 12, fontWeight = "bold",
                       color = "on_surface", maxLines = 1 }),
        })
    end
    for index, reading in ipairs(readings) do
        if index > 1 then
            body[#body + 1] = ui.box({ height = 1, fill = "outline/0.14" })
        end
        for _, node in ipairs(metricRows(reading.section, reading.title, titled)) do
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
            ui.label({ text = label, fontSize = 11, fontWeight = "bold",
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
    return ui.column(cardStyle(4,
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
local function groupReadings(items, windowed)
    local order, byName = {}, {}
    for _, item in ipairs(items) do
        if item.section.type == "metric" then
            local label = tostring(item.section.label or "")
            local name = windowed and label or ""
            if byName[name] == nil then
                byName[name] = {}
                order[#order + 1] = name
            end
            local readings = byName[name]
            readings[#readings + 1] = {
                section = item.section,
                title = windowed and item.window or label,
            }
        end
    end
    return order, byName
end

-- While a provider is down its numbers record when it was last read, so they
-- are set in text rather than drawn as bars a glance would read as live.
local function recordCard(entry, items, windowed)
    local order, byName = groupReadings(items, windowed)
    if #order == 0 then return nil end

    local body = {
        ui.label({ text = recordAge(entry), fontSize = 11, fontWeight = "semibold",
                   color = "on_surface", maxLines = 1 }),
    }
    for _, name in ipairs(order) do
        local parts = {}
        for _, reading in ipairs(byName[name]) do
            local value = tostring(reading.section.value or "")
            if value == "" then
                value = string.format("%d%%", tonumber(reading.section.percent) or 0)
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
    return ui.column(cardStyle(4), body)
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
            name = providerGlyph(entry.id),
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
        minHeight = 32,
        paddingV = 6,
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
    for _, m in ipairs(entry.metrics or {}) do
        if m.label and m.percent then
            metricStrs[#metricStrs + 1] = tostring(m.label) .. " " .. tostring(m.percent) .. "%"
        end
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
        return ui.label({ text = noctalia.tr("ui.waiting"), fontSize = 11,
            color = "on_surface_variant", maxLines = 1 })
    end

    local models = modelHeadlines(entry)
    if #models == 0 then
        models = { { displayName = "", glyph = providerGlyph(entry.id), metrics = entry.metrics } }
    end
    local notices = {}
    for _, model in ipairs(models) do
        local short, weekly = dualMetrics(model.metrics)
        local affected = {}
        for index, metric in ipairs(model.metrics or {}) do
            local percent = type(metric) == "table" and tonumber(metric.percent) or nil
            if percent ~= nil and percent > 50 then
                local window = metric == short and "5h" or metric == weekly and "7d" or ""
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
            notices[#notices + 1] = affected[1]
        end
    end

    if #notices > 0 then
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
                .. tostring(item.percent) .. "%"
            local severity = tostring(metric.severity or "")
            local detail = blocked and noctalia.tr("ui.quota_exhausted")
                or (severity == "high" or severity == "critical")
                    and noctalia.tr("ui.severity." .. severity)
                or tostring(item.percent) .. "%"
            local left = blocked and shared.fixedCountdown(metric) or ""
            if left ~= "" then detail = detail .. " · " .. noctalia.tr("ui.quota_reset", { time = left }) end
            pills[#pills + 1] = ui.row({ gap = 3, align = "center", paddingH = 6,
                paddingV = 2, radius = 5, fill = role .. "/0.10",
                border = role .. "/0.20", borderWidth = 1 }, {
                ui.glyph({ name = item.model.glyph, size = 10, color = role }),
                ui.label({ text = text, tooltip = detail, fontSize = 10,
                    fontWeight = "bold", color = role, maxLines = 1 }),
            })
        end
        return ui.row({ gap = 4, align = "center" }, pills)
    end
    return ui.glyph({ name = "circle-check", size = 13, color = "primary" })
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
    local metricCount = 0
    for _, section in ipairs(sections) do
        if type(section) == "table" then
            local text = section.type == "text"
            if text and noctalia.string.trim(tostring(section.value or "")) == "" then
                heading = tostring(section.label or "")
                windowed = windowed or heading ~= ""
            elseif section.type ~= "spacer" then
                items[#items + 1] = { section = section, window = heading }
                if section.type == "metric" then metricCount = metricCount + 1 end
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
        local order, byName = groupReadings(items, windowed)
        for _, name in ipairs(order) do
            local cardName, glyph = name, nil
            local readings = byName[name]
            if not windowed and entry ~= nil then
                cardName = tostring(entry.display_name or entry.id)
                glyph = providerGlyph(entry.id)
                for _, reading in ipairs(readings) do
                    local label = tostring(reading.title):lower()
                    if label:match("5h$") then
                        reading.title = "Session"
                    elseif label:match("weekly$") then
                        reading.title = "Weekly"
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

    -- Keep the same card width in both modes. The scrollbar lives in the
    -- reserved right gutter, while the provider header remains fixed above.
    if #cards > 0 then
        local needsScroll = #cards >= 3 or metricCount >= 3
            or (windowed and #cards >= 2)
        for _, item in ipairs(items) do
            if item.section.type == "block" and type(item.section.body) == "table"
                and #item.section.body >= 4 then
                needsScroll = true
            end
        end
        local props = { gap = 8, paddingLeft = 2, paddingRight = 16,
            paddingV = 4, align = "stretch" }
        if needsScroll then
            props.flexGrow = 1
            children[#children + 1] = ui.scroll(props, cards)
        else
            children[#children + 1] = ui.column(props, cards)
        end
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

function render()
    local entry = currentEntry()
    -- A failure with nothing behind it is the whole panel; with a report behind
    -- it, a banner over readings that are still the best answer available. A
    -- report whose every row was dropped still counts as one: the panel it draws
    -- is empty, not absent.
    if failure.code ~= "" and report == nil then
        -- The panel keeps its manifest size, and a failure has nowhere near
        -- 720x400 to say. Bounded and centred, the empty surround reads as
        -- composition rather than a half-drawn frame.
        panel.render(ui.column({ flexGrow = 1, padding = 14, align = "center", justify = "center" }, {
            ui.column({ gap = 10, width = 320 }, {
                ui.row({ gap = 8, align = "center" }, {
                    ui.glyph({ name = "brain", size = 18, color = "primary" }),
                    ui.label({ text = noctalia.tr("ui.title"), fontSize = 15,
                               fontWeight = "bold", color = "on_surface" }),
                }),
                errorBlock(),
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
    local providerActions = {}
    local updatedRow = nil

    local fetched = parseIso(entry and entry.fetched_at)
    if fetched ~= nil then
        updatedRow = ui.row({ gap = 3, align = "center", paddingH = 6,
                              paddingV = 2, radius = 5, fill = "on_surface/0.06" }, {
            ui.glyph({ name = "clock", size = 10, color = "on_surface_variant" }),
            ui.label({
                text = noctalia.tr("ui.updated") .. " " .. noctalia.formatTime(noctalia.timeFormat(), fetched),
                fontSize = 11,
                color = "on_surface_variant",
                tooltip = updatedText(entry),
            }),
        })
    end

    if entry ~= nil then
        providerActions[#providerActions + 1] = ui.button({
            glyph = "copy",
            variant = "outline", border = "outline", borderWidth = 1,
            controlSize = "sm",
            tooltip = "Copy usage summary",
            onClick = function() copySummary(entry) end,
        })
        local dashUrl = shared.providerDashboard(entry.id)
        if dashUrl ~= nil then
            providerActions[#providerActions + 1] = ui.button({
                glyph = "external-link",
                variant = "outline", border = "outline", borderWidth = 1,
                controlSize = "sm",
                tooltip = "Open dashboard",
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
        variant = "outline", border = "outline", borderWidth = 1, controlSize = "sm",
        tooltip = noctalia.tr(polling and "ui.refreshing"
            or refreshQueued and "ui.refresh_queued" or "ui.refresh"),
        enabled = not polling,
        onClick = requestRefresh,
    })
    headerActions[#headerActions + 1] = ui.button({
        glyph = "settings",
        variant = "outline", border = "outline", borderWidth = 1, controlSize = "sm",
        tooltip = noctalia.tr("ui.settings"),
        onClick = function() noctalia.openSettings() end,
    })
    headerActions[#headerActions + 1] = ui.button({
        glyph = "x",
        variant = "outline", border = "outline", borderWidth = 1, controlSize = "sm",
        tooltip = "Close",
        onClick = function()
            if type(panel.close) == "function" then panel.close() end
        end,
    })

    local topChildren = {
        ui.row({ gap = 8, align = "center" }, {
            ui.row({
                width = 24, height = 24, radius = 6,
                fill = "primary/0.14", align = "center", justify = "center",
            }, {
                ui.glyph({ name = "brain", size = 14, color = "primary" }),
            }),
            ui.label({ text = noctalia.tr("ui.title"), fontSize = 14, fontWeight = "bold", color = "on_surface" }),
            ui.spacer({ flexGrow = 1 }),
            ui.row({ gap = 4, align = "center" }, headerActions),
        }),
    }

    if #tabs > 0 then
        topChildren[#topChildren + 1] = ui.row({ key = "tabs-dock", gap = 6,
            align = "center", justify = "center" }, tabs)
    end

    local status = statusIndicator(entry)
    if updatedRow ~= nil or status ~= nil or #providerActions > 0 then
        local providerMeta = {}
        if updatedRow ~= nil then providerMeta[#providerMeta + 1] = updatedRow end
        if status ~= nil then providerMeta[#providerMeta + 1] = status end
        providerMeta[#providerMeta + 1] = ui.spacer({ flexGrow = 1 })
        if #providerActions > 0 then
            providerMeta[#providerMeta + 1] = ui.row({ gap = 4, align = "center" }, providerActions)
        end
        topChildren[#topChildren + 1] = ui.row({ key = "meta-row", gap = 4, align = "center" }, providerMeta)
    end

    panel.render(ui.column({ gap = 6, paddingH = 10, paddingV = 8, flexGrow = 1, align = "stretch" }, {
        ui.column({ gap = 6 }, topChildren),
        ui.separator({ orientation = "horizontal", color = "outline", opacity = 0.15 }),
        detailPane(entry),
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

function onOpen(context)
    if type(context) == "string" and context ~= "" then
        noctalia.state.set("selected", context)
    end
    -- Every open asks for fresh numbers. The CLI answers from its cache when it
    -- has one, and the poller drops requests that arrive too close together.
    requestRefresh()
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
        requestRefresh()
    elseif lower == "up" or lower == "down" or lower == "left" or lower == "right" then
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
