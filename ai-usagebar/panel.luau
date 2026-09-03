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
local elapsedPercent, pace = shared.elapsedPercent, shared.pace
local requestRefresh = shared.requestRefresh
local providerWarning, unavailable = shared.warning, shared.unavailable
local saysError = shared.saysError
local NO_FAILURE, asFailure = shared.NO_FAILURE, shared.asFailure

local failure = NO_FAILURE

-- The plan each provider last reported on. A plan carries the limits every
-- percentage is measured against, so a reading taken under the old one says
-- nothing about the new one.
local lastPlan = {}

-- Read once: the panel would otherwise stat PATH on every second tick it spends
-- in a failure.
local HAS_OPENER = noctalia.commandExists("xdg-open")

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
    -- Only worth a column of its own when it says more than the percentage.
    local showValue = value ~= "" and value ~= string.format("%d%%", percent)

    local header = {
        ui.label({
            text = tostring(title or ""),
            fontSize = muted and 11 or 12,
            fontWeight = muted and "normal" or "semibold",
            color = muted and "on_surface_variant" or "on_surface",
            maxLines = 1,
        }),
        ui.spacer({ flexGrow = 1 }),
    }
    local word = severityWord(section)
    if word ~= nil then
        header[#header + 1] = ui.label({ text = word, fontSize = 10, fontWeight = "semibold", color = tint })
    end
    if showValue then
        header[#header + 1] = ui.label({ text = value, fontSize = 11, color = "on_surface_variant", maxLines = 1 })
    end
    -- Fixed width, so a column of cards ends on one right edge.
    header[#header + 1] = ui.label({
        text = string.format("%d%%", percent),
        fontSize = 15,
        fontWeight = "bold",
        color = tint,
        width = 46,
        textAlign = "end",
    })

    local body = {
        ui.row({ gap = 6, align = "center" }, header),
        ui.progress({ progress = ratio(percent), fill = fill, track = "on_surface/0.16", radius = 3, height = 6 }),
    }

    local elapsed = elapsedPercent(section.detail)
    if elapsed ~= nil then
        body[#body + 1] = ui.progress({
            progress = ratio(elapsed),
            fill = "on_surface/0.45",
            track = "on_surface/0.10",
            radius = 2,
            height = 3,
        })
    end

    local left = countdown(section)
    local clock = resetClock(section)
    -- Ahead of the clock is worth flagging; under it means there is room left.
    local paceText, _, paceWord = pace(section.detail)
    local paceColor = paceWord == "ahead" and "secondary" or "on_surface_variant"
    local timing = {}
    if left ~= "" then
        timing[#timing + 1] = ui.glyph({ name = "clock", size = 12, color = "on_surface_variant" })
        timing[#timing + 1] = ui.label({ text = left, fontSize = 11, color = "on_surface_variant" })
        if clock ~= "" then
            -- Where the countdown beside it lands, not a reading of its own.
            timing[#timing + 1] = ui.label({
                text = "(" .. clock .. ")", fontSize = 11, color = "on_surface_variant",
            })
        end
    end
    local context = {}
    if elapsed ~= nil then
        context[#context + 1] = ui.label({
            text = noctalia.tr("ui.elapsed", { percent = elapsed }),
            fontSize = 10, color = "on_surface_variant", maxLines = 1,
        })
    end
    if paceText ~= "" then
        context[#context + 1] = ui.spacer({ flexGrow = 1 })
        context[#context + 1] = ui.label({
            text = paceText, fontSize = 10, fontWeight = "semibold", color = paceColor, maxLines = 1,
        })
    end
    if #timing > 0 then
        body[#body + 1] = ui.row({ gap = 5, align = "center" }, timing)
    end
    if #context > 0 then
        body[#body + 1] = ui.row({ gap = 5, align = "center" }, context)
    end

    local rest = plainDetail(section.detail)
    if rest ~= "" then
        body[#body + 1] = ui.label({ text = rest, fontSize = 11, color = "on_surface_variant" })
    end

    return body
end

local CARD = { gap = 6, padding = 10, radius = 8, fill = "surface_variant/0.45",
               border = "outline/0.12", borderWidth = 1 }

-- A provider's readings share one card, so the session and the week are read
-- together. `name` titles it only where the readings need telling apart by
-- something the panel has not already said: Antigravity reports two models, one
-- reading per window each. Elsewhere the header names the subject.
local function stackCard(name, readings)
    local titled = name ~= ""
    local body = {}
    if titled then
        body[#body + 1] = ui.label({ text = name, fontSize = 12, fontWeight = "semibold",
                                     color = "on_surface", maxLines = 1 })
    end
    for index, reading in ipairs(readings) do
        -- Two readings in one card run together without a line between them,
        -- whether or not a title stands over both.
        if index > 1 then
            body[#body + 1] = ui.spacer({ height = 4 })
            body[#body + 1] = ui.box({ height = 1, fill = "outline/0.18" })
            body[#body + 1] = ui.spacer({ height = 4 })
        end
        for _, node in ipairs(metricRows(reading.section, reading.title, titled)) do
            body[#body + 1] = node
        end
    end
    return ui.column(CARD, body)
end

local function blockCard(section)
    local body = {
        ui.label({ text = tostring(section.label or ""), fontSize = 12, fontWeight = "semibold",
                   color = "on_surface", maxLines = 1 }),
    }
    local lines = type(section.body) == "table" and section.body or {}
    for _, line in ipairs(lines) do
        local text = noctalia.string.trim(tostring(line))
        -- A bare "balance:" would read as a row that failed to render.
        if text:find(":$") then text = text .. " —" end
        body[#body + 1] = ui.label({
            text = text ~= "" and text or "—",
            fontSize = 11,
            color = "on_surface_variant",
            maxLines = 1,
        })
    end
    return ui.column({ gap = 4, padding = 10, radius = 8, fill = "surface_variant/0.45",
                       border = "outline/0.18", borderWidth = 1 }, body)
end

-- A `text` section the CLI uses for a warning. The `credentials error:` prefix
-- and the repeated provider name are the CLI talking to a log, not to a panel
-- that already names the provider in its title.
local function noteCard(text)
    local clean = noctalia.string.trim(tostring(text or ""))
    clean = clean:gsub("^[Cc]redentials error:%s*", "")
    return ui.row({ gap = 8, align = "start", padding = 10, radius = 8,
                    fill = "surface_variant/0.45", border = "outline/0.18", borderWidth = 1 }, {
        ui.glyph({ name = "alert-triangle", size = 14, color = "secondary" }),
        ui.label({ text = clean, fontSize = 11, color = "on_surface_variant",
                   flexGrow = 1, maxLines = 3 }),
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
                ui.label({ text = name, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
                ui.spacer({ flexGrow = 1 }),
                ui.label({ text = line, fontSize = 11, color = "on_surface", maxLines = 1 }),
            })
        else
            body[#body + 1] = ui.label({ text = line, fontSize = 11, color = "on_surface",
                                        maxLines = 1 })
        end
    end
    return ui.column({ gap = 4, padding = 10, radius = 8, fill = "surface_variant/0.45",
                       border = "outline/0.18", borderWidth = 1 }, body)
end

-- Everything in a report that is not a reading: credit blocks, headings,
-- warnings, free text. A provider that is down loses its gauges, not the rest of
-- what the CLI said, so both passes draw these the same way. `warned` says the
-- warning already stands at the top, so it is not said twice.
local function otherCard(section, warned)
    if section.type == "block" then return blockCard(section) end

    if section.type == "text" then
        local label = tostring(section.label or "")
        local value = tostring(section.value or "")
        if label:lower() == "warning" or saysError(value) then
            if warned then return nil end
            return noteCard(value)
        end
        return ui.row({ gap = 6, align = "center" }, {
            ui.label({ text = label, fontSize = 11, color = "on_surface_variant" }),
            ui.spacer({ flexGrow = 1 }),
            ui.label({ text = value, fontSize = 11, color = "on_surface", maxLines = 1 }),
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
    local metric = headline(entry)
    local percent = metric ~= nil and tonumber(metric.percent) or nil
    -- Down is down whether the CLI failed the provider outright or kept serving
    -- what it cached: either way the row stops drawing a gauge for it.
    local broken = entry.status == "error" or unavailable(entry)
    local tint = severityRole(metric, "on_surface")

    -- The reading keeps its severity colour whether or not the row is selected:
    -- recolouring it hides the one thing the list exists to compare.
    local right
    if broken then
        right = ui.row({ width = 48, justify = "end" }, {
            ui.glyph({ name = "alert-circle", size = 14, color = "error" }),
        })
    else
        local rightChildren = {
            ui.label({
                text = percent ~= nil and string.format("%d%%", percent) or "—",
                fontSize = 13, fontWeight = "bold", color = tint,
                width = 34, textAlign = "end",
            }),
        }
        if entry.stale == true then
            rightChildren[#rightChildren + 1] = ui.glyph({
                name = "clock-exclamation", size = 12, color = "secondary",
            })
        end
        right = ui.row({ gap = 3, width = 48, justify = "end", align = "center" }, rightChildren)
    end

    local lines = {
        ui.label({
            text = tostring(entry.display_name or entry.id),
            fontSize = 12, fontWeight = "semibold",
            color = selected and "primary" or "on_surface", maxLines = 1,
        }),
    }
    if percent ~= nil and not broken then
        lines[#lines + 1] = ui.progress({
            progress = ratio(percent),
            fill = severityRole(metric, "primary"),
            track = "on_surface/0.16",
            radius = 2, height = 3,
        })
    end
    lines[#lines + 1] = ui.label({
        text = broken and noctalia.tr("ui.unavailable") or tostring(entry.plan or entry.id or ""),
        fontSize = 10, color = "on_surface_variant", maxLines = 1,
    })

    return ui.row({
        -- Keyed, so the click handler survives the second tick the countdowns ride
        -- on instead of being rebuilt under the pointer.
        key = "provider-" .. tostring(entry.id),
        gap = 8, align = "center", padding = 8, radius = 8,
        -- A tint, not a slab: a filled `primary` row inverts every colour in it.
        fill = selected and "primary/0.10" or "surface_variant/0.30",
        border = selected and "primary/0.55" or "outline/0.12",
        borderWidth = 1,
        onClick = function()
            noctalia.state.set("selected", tostring(entry.id))
            render()
        end,
    }, {
        ui.glyph({ name = providerGlyph(entry.id), size = 16,
                   color = selected and "primary" or "on_surface" }),
        ui.column({ gap = 3, flexGrow = 1 }, lines),
        right,
    })
end

-- ── Render ────────────────────────────────────────────────────────────────────

-- The CLI's own words come last and smallest, where a bug report can quote them.
local function errorBlock()
    local key = "ui.error." .. failure.code
    local children = {
        ui.row({ gap = 6, align = "center" }, {
            ui.glyph({ name = "alert-circle", size = 14, color = "error" }),
            ui.label({ text = noctalia.tr(key), fontSize = 12, fontWeight = "bold", color = "error" }),
        }),
        ui.label({ text = noctalia.tr(key .. "_hint"), fontSize = 11, color = "on_surface_variant" }),
    }

    if failure.detail ~= "" then
        children[#children + 1] = ui.label({
            text = failure.detail, fontSize = 10, color = "on_surface_variant", maxLines = 3,
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

    -- Retrying is pointless until the CLI exists, so that failure gets the
    -- install page too, offered only where something can open it. The address
    -- lives in the tooltip: a raw URL is not a button caption.
    if failure.code == "not_installed" and HAS_OPENER then
        actions[#actions + 1] = ui.button({
            text = noctalia.tr("ui.install"), glyph = "external-link",
            variant = "ghost", controlSize = "sm",
            tooltip = "github.com/akitaonrails/ai-usagebar",
            onClick = function()
                noctalia.runAsync("xdg-open https://github.com/akitaonrails/ai-usagebar")
            end,
        })
    end
    children[#children + 1] = ui.row({ gap = 6, align = "center" }, actions)

    return ui.column({ gap = 8 }, children)
end

local function listPane(entry)
    local rows = {}
    for _, candidate in ipairs(entries()) do
      if configured(candidate) then
        rows[#rows + 1] = providerRow(candidate, entry ~= nil and candidate.id == entry.id)
      end
    end
    return ui.column({ gap = 10, padding = 14, width = 250 }, {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = "brain", size = 18, color = "primary" }),
            -- The accent belongs to the selection and the bars; a title taking
            -- it too would leave the panel with no quiet level.
            ui.label({ text = noctalia.tr("ui.title"), fontSize = 15, fontWeight = "bold", color = "on_surface" }),
            ui.spacer({ flexGrow = 1 }),
            -- One slot for the read: the button becomes the spinner, instead of
            -- a second glyph pushing the header around.
            ui.button({
                glyph = polling and "loader-2" or refreshQueued and "clock" or "refresh",
                variant = "ghost", controlSize = "sm",
                tooltip = noctalia.tr(polling and "ui.refreshing"
                    or refreshQueued and "ui.refresh_queued" or "ui.refresh"),
                enabled = not polling,
                onClick = requestRefresh,
            }),
            -- The capsule answers a middle click with this too, but the panel is
            -- where that decision is made.
            ui.button({
                glyph = "settings",
                variant = "ghost", controlSize = "sm",
                tooltip = noctalia.tr("ui.settings"),
                onClick = function() noctalia.openSettings() end,
            }),
        }),
        ui.scroll({ gap = 6, flexGrow = 1 }, rows),
    })
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
        -- Wrapped in a row so the title block is as tall as its two labels: a
        -- bare column claims the pane's free space and parks the title above it.
        children[#children + 1] = ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = providerGlyph(entry.id), size = 18, color = "on_surface" }),
            ui.column({ gap = 0, flexGrow = 1 }, {
                ui.label({ text = title, fontSize = 15, fontWeight = "bold",
                           color = "on_surface", maxLines = 1 }),
                ui.label({ text = subtitle, fontSize = 11, color = "on_surface_variant",
                           maxLines = 1, visible = subtitle ~= "" }),
            }),
        })
    end

    -- The id and a "ready" status are skipped: the id is the row just clicked,
    -- and a healthy read is the default. A provider that is down is skipped
    -- altogether: its record below dates the same fetch, in the right tense.
    if entry ~= nil and not unavailable(entry) then
        local chips = {}
        if entry.stale == true then
            chips[#chips + 1] = ui.label({ text = noctalia.tr("ui.stale"), fontSize = 10, color = "secondary" })
        end
        local fetched = parseIso(entry.fetched_at)
        if fetched ~= nil then
            if #chips > 0 then
                chips[#chips + 1] = ui.label({ text = "·", fontSize = 10, color = "on_surface_variant" })
            end
            chips[#chips + 1] = ui.glyph({ name = "clock", size = 11, color = "on_surface_variant" })
            chips[#chips + 1] = ui.label({
                text = updatedText(entry) .. " · " .. noctalia.formatTime(noctalia.timeFormat(), fetched),
                fontSize = 10, color = "on_surface_variant",
            })
        end
        if #chips > 0 then
            children[#children + 1] = ui.row({ gap = 4, align = "center" }, chips)
        end
    end

    -- The read failed, but the numbers below it are only older than the panel
    -- would like. Said once, at the top, rather than by dropping every card.
    if failure.code ~= "" then
        children[#children + 1] = ui.row({ gap = 6, align = "center" }, {
            ui.glyph({ name = "alert-circle", size = 13, color = "error" }),
            ui.label({ text = noctalia.tr("ui.error." .. failure.code), fontSize = 11,
                       color = "error", flexGrow = 1, maxLines = 1 }),
            ui.button({
                text = noctalia.tr("ui.retry"), glyph = "refresh",
                variant = "ghost", controlSize = "sm",
                enabled = not polling,
                onClick = requestRefresh,
            }),
        })
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
        cards[#cards + 1] = noteCard(warning)
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
        -- 24, not the column's usual 8: the CLI used to pad its own sections and
        -- dropping that padding would have pulled every provider's cards together.
        children[#children + 1] = ui.scroll({ gap = 24, flexGrow = 1 }, cards)
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

    -- Both panes must be told to fill the panel, or their ui.scroll children ask
    -- for their natural height and the cards overflow.
    panel.render(ui.row({ gap = 0, flexGrow = 1, align = "stretch" }, {
        listPane(entry),
        ui.separator({ orientation = "vertical", color = "outline", opacity = 0.28 }),
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

render()
