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
    local elapsed = elapsedPercent(section.detail)
    local paceText, _, paceWord = pace(section.detail)

    local resetStr = ""
    if left ~= "" then
        resetStr = left
        if clock ~= "" then resetStr = resetStr .. " (" .. clock .. ")" end
    end

    local titleParts = {
        ui.label({
            text = tostring(title or ""),
            fontSize = muted and 12 or 13,
            fontWeight = "semibold",
            color = "on_surface",
            maxLines = 1,
        }),
    }

    if resetStr ~= "" then
        titleParts[#titleParts + 1] = ui.label({ text = "·", fontSize = 11, color = "on_surface_variant" })
        titleParts[#titleParts + 1] = ui.row({ gap = 3, align = "center" }, {
            ui.glyph({ name = "clock", size = 10, color = "on_surface_variant" }),
            ui.label({ text = resetStr, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
        })
    end

    if elapsed ~= nil then
        titleParts[#titleParts + 1] = ui.label({ text = "·", fontSize = 11, color = "on_surface_variant" })
        titleParts[#titleParts + 1] = ui.label({
            text = noctalia.tr("ui.elapsed", { percent = elapsed }),
            fontSize = 11, color = "on_surface_variant", maxLines = 1,
        })
    end

    local rightMeta = {}

    if paceText ~= "" then
        if paceWord == "ahead" then
            rightMeta[#rightMeta + 1] = ui.row({
                gap = 3, align = "center", paddingH = 5, paddingV = 1, radius = 5,
                fill = "secondary/0.14",
            }, {
                ui.glyph({ name = "trending-up", size = 10, color = "secondary" }),
                ui.label({ text = paceText, fontSize = 10, fontWeight = "semibold", color = "secondary", maxLines = 1 }),
            })
        else
            rightMeta[#rightMeta + 1] = ui.row({
                gap = 3, align = "center", paddingH = 5, paddingV = 1, radius = 5,
                fill = "surface_variant/0.50",
            }, {
                ui.glyph({ name = "trending-down", size = 10, color = "on_surface_variant" }),
                ui.label({ text = paceText, fontSize = 10, fontWeight = "medium", color = "on_surface_variant", maxLines = 1 }),
            })
        end
    end

    local word = severityWord(section)
    if word ~= nil then
        local sevRole = isCritical(section) and "error" or severityRole(section, "secondary")
        rightMeta[#rightMeta + 1] = ui.row({
            paddingH = 5, paddingV = 1, radius = 5,
            fill = sevRole .. "/0.14",
        }, {
            ui.label({ text = word, fontSize = 10, fontWeight = "bold", color = sevRole }),
        })
    end

    if showValue then
        rightMeta[#rightMeta + 1] = ui.label({ text = value, fontSize = 11, color = "on_surface_variant", maxLines = 1 })
    end

    rightMeta[#rightMeta + 1] = ui.label({
        text = string.format("%d%%", percent),
        fontSize = 13,
        fontWeight = "bold",
        color = tint,
        textAlign = "end",
    })

    local progressBar = ui.progress({
        progress = ratio(percent),
        fill = fill,
        track = "on_surface/0.10",
        radius = 2,
        height = 5,
    })

    local body = {
        ui.row({ gap = 6, align = "center" }, {
            ui.row({ gap = 4, align = "center" }, titleParts),
            ui.spacer({ flexGrow = 1 }),
            ui.row({ gap = 4, align = "center", justify = "end" }, rightMeta),
        }),
        progressBar,
    }

    local rest = plainDetail(section.detail)
    if rest ~= "" then
        body[#body + 1] = ui.label({ text = rest, fontSize = 10, color = "on_surface_variant" })
    end

    return body
end

local CARD = { gap = 6, padding = 10, radius = 10, fill = "surface_variant/0.40",
               border = "outline/0.08", borderWidth = 1 }

local function stackCard(name, readings)
    local titled = name ~= ""
    local body = {}
    if titled then
        body[#body + 1] = ui.row({ gap = 6, align = "center" }, {
            ui.row({
                width = 22, height = 22, radius = 6,
                fill = "primary/0.14", align = "center", justify = "center",
            }, {
                ui.glyph({ name = modelGlyph(name), size = 13, color = "primary" }),
            }),
            ui.label({ text = modelDisplayName(name), fontSize = 12, fontWeight = "bold",
                       color = "on_surface", maxLines = 1 }),
        })
    end
    for index, reading in ipairs(readings) do
        if index > 1 then
            body[#body + 1] = ui.spacer({ height = 2 })
            body[#body + 1] = ui.box({ height = 1, fill = "outline/0.14" })
            body[#body + 1] = ui.spacer({ height = 2 })
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
            ui.label({ text = label, fontSize = 12, fontWeight = "bold",
                       color = "on_surface", maxLines = 1 }),
        }),
    }
    local lines = type(section.body) == "table" and section.body or {}
    for _, line in ipairs(lines) do
        local text = noctalia.string.trim(tostring(line))
        -- A bare "balance:" would read as a row that failed to render.
        if text:find(":$") then text = text .. " —" end
        local kind, expiry = text:match("^(.-)%s+·%s+(.+)$")
        if isResetCredits and kind and expiry then
            body[#body + 1] = ui.column({ gap = 2 }, {
                ui.label({ text = kind, fontSize = 12, fontWeight = "medium", color = "on_surface", maxLines = 2 }),
                ui.label({ text = expiry, fontSize = 11, color = "on_surface_variant", maxLines = 2 }),
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
    return ui.column({ gap = 6, padding = 12, radius = 12, fill = "surface_variant/0.30",
                       border = "outline/0.08", borderWidth = 1 }, body)
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
    return ui.row({ gap = 8, align = "start", padding = 12, radius = 10,
                    fill = failureLabel and "error/0.08" or "secondary/0.08",
                    border = failureLabel and "error/0.25" or "outline/0.08",
                    borderWidth = 1 }, {
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
-- Antigravity by model, with the window heading each reading; everyone else
-- under one subject the header already names. The card and the record share this
-- grouping so the two cannot disagree about what belongs together.
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
    return ui.column({ gap = 4, padding = 12, radius = 14, fill = "surface_variant/0.40",
                       border = "outline/0.08", borderWidth = 1 }, body)
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
        return ui.row({
            gap = 6, align = "center", paddingH = 8, paddingV = 4, radius = 6,
            fill = "surface_variant/0.25",
        }, {
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

local function providerRow(entry, selected)
    local displayName = tostring(entry.display_name or entry.name or entry.id or "")
    local broken = entry.status == "error" or unavailable(entry)

    local children = {
        ui.glyph({
            name = providerGlyph(entry.id),
            size = 15,
            color = selected and "primary" or "on_surface",
        }),
        ui.label({
            text = displayName,
            fontSize = 12,
            fontWeight = selected and "bold" or "medium",
            color = selected and "primary" or "on_surface",
            maxLines = 1,
        }),
    }

    if broken then
        children[#children + 1] = ui.glyph({
            name = "alert-circle",
            size = 13,
            color = "error",
        })
    end

    return ui.row({
        key = "provider-" .. tostring(entry.id),
        gap = 8,
        align = "center",
        justify = "center",
        paddingH = 14,
        paddingV = 8,
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
        if type(noctalia.notify) == "function" then
            noctalia.notify(tostring(entry.display_name or entry.id), text)
        end
    end
end

local function detailPane(entry)
    local title = noctalia.tr("ui.title")
    local subtitle = ""
    if entry ~= nil then
        -- The provider names the pane, the plan qualifies it, the same order the
        -- list uses. The CLI keeps them apart: `display_name` vs `plan`.
        title = tostring(entry.display_name or entry.id)
        subtitle = tostring(entry.plan or "")
        if subtitle == title then subtitle = "" end
    end

    -- With no entry the pane stays empty rather than repeating the list's title.
    local children = {}
    if entry ~= nil then
        local copyBtn = ui.button({
            glyph = "copy",
            variant = "ghost",
            controlSize = "sm",
            onClick = function() copySummary(entry) end,
        })

        local dashUrl = shared.providerDashboard(entry.id)
        local dashBtn = dashUrl ~= nil and ui.button({
            glyph = "external-link",
            variant = "ghost",
            controlSize = "sm",
            onClick = function()
                if type(noctalia.runAsync) == "function" then
                    noctalia.runAsync("xdg-open '" .. dashUrl .. "'")
                end
            end,
        }) or nil

        local actionButtons = { copyBtn }
        if dashBtn ~= nil then actionButtons[#actionButtons + 1] = dashBtn end

        local metaParts = {}
        if not unavailable(entry) then
            if entry.stale == true then
                metaParts[#metaParts + 1] = ui.label({ text = noctalia.tr("ui.stale"), fontSize = 11, color = "secondary" })
                metaParts[#metaParts + 1] = ui.label({ text = "·", fontSize = 11, color = "on_surface_variant" })
            end
            local fetched = parseIso(entry.fetched_at)
            if fetched ~= nil then
                metaParts[#metaParts + 1] = ui.glyph({ name = "clock", size = 11, color = "on_surface_variant" })
                metaParts[#metaParts + 1] = ui.label({
                    text = updatedText(entry) .. " · " .. noctalia.formatTime(noctalia.timeFormat(), fetched),
                    fontSize = 11, color = "on_surface_variant",
                })
            end
        end

        local subRow = {
            ui.row({ gap = 4, align = "center" }, metaParts),
            ui.spacer({ flexGrow = 1 }),
            ui.row({ gap = 2, align = "center" }, actionButtons),
        }
        children[#children + 1] = ui.row({ gap = 6, align = "center" }, subRow)
    end

    -- The read failed, but cached numbers remain the useful answer. Mark their
    -- age quietly instead of making a transient network failure the headline.
    if failure.code ~= "" then
        children[#children + 1] = ui.row({ gap = 6, align = "center" }, {
            ui.glyph({ name = "clock-exclamation", size = 13, color = "secondary" }),
            ui.label({ text = noctalia.tr("ui.stale_hint"), fontSize = 11,
                       color = "on_surface_variant", flexGrow = 1, maxLines = 1 }),
            ui.button({
                text = noctalia.tr("ui.retry"), glyph = "refresh",
                variant = "ghost", controlSize = "sm",
                enabled = not polling,
                onClick = requestRefresh,
            }),
        })
    end

    -- Only exhausted quotas need a notice above the detailed windows.
    if entry ~= nil and not unavailable(entry) then
        local models = modelHeadlines(entry)
        if #models == 0 then
            models = { { displayName = title, metric = headline(entry) } }
        end
        local summary = {}
        for _, model in ipairs(models) do
            local metric = model.blockingMetric or model.metric
            if (tonumber(metric and metric.percent) or 0) >= 100 then
                local left = shared.fixedCountdown(metric)
                local details = {
                    ui.label({ text = model.displayName .. " · " .. noctalia.tr("ui.quota_exhausted"),
                               fontSize = 11, color = "error", maxLines = 1 }),
                }
                if left ~= "" then
                    details[#details + 1] = ui.label({
                        text = noctalia.tr("ui.quota_reset", { time = left }),
                        fontSize = 11, color = "on_surface_variant", maxLines = 1,
                    })
                end
                summary[#summary + 1] = ui.row({ gap = 8, padding = 8, radius = 10,
                    fill = "surface_variant/0.40", border = "error/0.40",
                    borderWidth = 1, align = "center" }, {
                    ui.glyph({ name = "clock-exclamation", size = 16, color = "error" }),
                    ui.column({ gap = 2, flexGrow = 1 }, details),
                })
            end
        end
        if #summary > 0 then children[#children + 1] = ui.column({ gap = 6 }, summary) end
    end

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
        local order, byName = groupReadings(items, windowed)
        for _, name in ipairs(order) do cards[#cards + 1] = stackCard(name, byName[name]) end
    end

    -- The rest is the same either way: losing the gauges is no reason to lose
    -- what else the CLI said.
    for _, item in ipairs(items) do
        if item.section.type ~= "metric" then
            local card = otherCard(item.section, warning ~= "")
            if card ~= nil then cards[#cards + 1] = card end
        end
    end

    -- A section list that lost every card to a heading would otherwise scroll an
    -- empty column.
    if #cards > 0 then
        children[#children + 1] = ui.scroll({ gap = 10, flexGrow = 1 }, cards)
    elseif entry ~= nil then
        children[#children + 1] = ui.row({ gap = 6, align = "center" }, {
            ui.glyph({ name = "info-circle", size = 14, color = "on_surface_variant" }),
            ui.label({ text = noctalia.tr("ui.no_usage"), fontSize = 11, color = "on_surface_variant" }),
        })
        children[#children + 1] = ui.spacer({ flexGrow = 1 })
    end

    return ui.column({ gap = 8, padding = 14, flexGrow = 1 }, children)
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

    local tabs = {}
    for _, candidate in ipairs(entries()) do
        if configured(candidate) then
            tabs[#tabs + 1] = providerRow(candidate, entry ~= nil and candidate.id == entry.id)
        end
    end

    local topChildren = {
        ui.row({ gap = 8, align = "center" }, {
            ui.row({
                width = 28, height = 28, radius = 7,
                fill = "primary/0.14", align = "center", justify = "center",
            }, {
                ui.glyph({ name = "brain", size = 16, color = "primary" }),
            }),
            ui.label({ text = noctalia.tr("ui.title"), fontSize = 15, fontWeight = "bold", color = "on_surface" }),
            ui.spacer({ flexGrow = 1 }),
            ui.button({
                glyph = polling and "loader-2" or refreshQueued and "clock" or "refresh",
                variant = "ghost", controlSize = "sm",
                tooltip = noctalia.tr(polling and "ui.refreshing"
                    or refreshQueued and "ui.refresh_queued" or "ui.refresh"),
                enabled = not polling,
                onClick = requestRefresh,
            }),
            ui.button({
                glyph = "settings",
                variant = "ghost", controlSize = "sm",
                tooltip = noctalia.tr("ui.settings"),
                onClick = function() noctalia.openSettings() end,
            }),
            ui.button({
                glyph = "x",
                variant = "ghost", controlSize = "sm",
                onClick = function()
                    if type(panel.close) == "function" then panel.close() end
                end,
            }),
        }),
    }

    if #tabs > 0 then
        if #tabs <= 3 then
            topChildren[#topChildren + 1] = ui.row({ gap = 6, align = "center" }, tabs)
        else
            for i = 1, #tabs, 2 do
                local chunk = { tabs[i] }
                if tabs[i + 1] ~= nil then chunk[#chunk + 1] = tabs[i + 1] end
                topChildren[#topChildren + 1] = ui.row({ gap = 6, align = "center" }, chunk)
            end
        end
    end

    panel.render(ui.column({ gap = 8, padding = 12, flexGrow = 1, align = "stretch" }, {
        ui.column({ gap = 8 }, topChildren),
        ui.separator({ orientation = "horizontal", color = "outline", opacity = 0.20 }),
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

function onOpen(_context)
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
