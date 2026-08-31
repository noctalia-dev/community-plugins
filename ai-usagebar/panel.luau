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
local NO_FAILURE, asFailure = shared.NO_FAILURE, shared.asFailure

local failure = NO_FAILURE

-- The plan each provider was on when it last reported for real. A plan carries
-- the limits every percentage is measured against, so a reading taken under the
-- old one says nothing about the new one and is not worth keeping on screen.
local lastPlan = {}

-- Read once: a session either has xdg-utils or it does not, and the panel would
-- otherwise stat PATH on every second tick it spends in a failure.
local HAS_OPENER = noctalia.commandExists("xdg-open")

-- A vendor the user never set up is not listed. The CLI prefixes every such
-- message with `credentials error:`, but that bucket also holds providers that
-- ARE set up and merely unreachable right now -- "credentials error:
-- Antigravity: no local server found ... open Antigravity" -- so the row is only
-- dropped when the CLI says there is no key at all. Anything else keeps its row
-- and shows the CLI's own words, which say what to do about it.
local function configured(entry)
    if entry.status ~= "error" then return true end
    local message = tostring(entry.error or ""):lower()
    return not (message:find("^credentials error:") and message:find("no api key", 1, true))
end

-- ── Detail line parsing ───────────────────────────────────────────────────────
-- "Resets in 1h 58m · 60% elapsed · 30pts ahead". The reset half is already in
-- `reset_at`; what is left is the pace.

-- Details that carry no reset at all, e.g. "62% of monthly limit consumed".
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
-- label on a card of its own, or the window's name inside a card that stacks a
-- model's readings. `muted` is for the second case, where the card is already
-- titled and the window is the subordinate line.
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
            -- Parenthesised and muted: it is where the countdown beside it lands,
            -- not a reading of its own.
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

-- A provider's readings share one card. Antigravity reports every model once per
-- window, so `name` titles the model and each reading is headed by its window;
-- Claude and Codex name their windows in the readings themselves and get an
-- untitled card. Either way the session and the week are read together instead of
-- being split across the column.
-- A provider's readings share one card, so the session and the week are read
-- together. `name` titles it only where the readings need telling apart by
-- something the panel does not already say: Antigravity's plan spans two models
-- and reports each of them once per window. Claude and Codex report one subject,
-- already named in the panel's header, so their windows head themselves.
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
        -- A bare "balance:" from the CLI would read as a row that failed to
        -- render, so nothing gets spelled the way it is everywhere else.
        if text:find(":$") then text = text .. " —" end
        body[#body + 1] = ui.label({
            text = text ~= "" and text or "—",
            fontSize = 11,
            color = "on_surface_variant",
            maxLines = 1,
        })
    end
    return ui.column({ gap = 4, padding = 10, radius = 8, fill = "surface_variant/0.38",
                       border = "outline/0.18", borderWidth = 1 }, body)
end

-- A `text` section the CLI uses for a warning, e.g. Antigravity reporting that
-- its local server is down while still serving cached numbers. The `credentials
-- error:` prefix and the repeated provider name are the CLI talking to a log,
-- not to a panel that already names the provider in its title.
local function noteCard(text)
    local clean = noctalia.string.trim(tostring(text or ""))
    clean = clean:gsub("^[Cc]redentials error:%s*", "")
    return ui.row({ gap = 8, align = "start", padding = 10, radius = 8,
                    fill = "surface_variant/0.38", border = "outline/0.18", borderWidth = 1 }, {
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

-- While a provider is down its numbers are a record of when it was last read,
-- not a gauge of anything now, so they are set in text instead of drawn as bars
-- a glance would read as live.
local function recordCard(entry, items, windowed)
    local order, byName = {}, {}
    for _, item in ipairs(items) do
        if item.kind == "metric" then
            local label = tostring(item.section.label or "")
            local name = windowed and label or ""
            if byName[name] == nil then
                byName[name] = {}
                order[#order + 1] = name
            end
            local readings = byName[name]
            local title = windowed and item.window or label
            local value = tostring(item.section.value or "")
            if value == "" then value = string.format("%d%%", tonumber(item.section.percent) or 0) end
            readings[#readings + 1] = noctalia.string.trim(title .. " " .. value)
        end
    end
    if #order == 0 then return nil end

    local body = {
        ui.label({ text = recordAge(entry), fontSize = 11, fontWeight = "semibold",
                   color = "on_surface", maxLines = 1 }),
    }
    for _, name in ipairs(order) do
        local line = table.concat(byName[name], " · ")
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
    return ui.column({ gap = 4, padding = 10, radius = 8, fill = "surface_variant/0.38",
                       border = "outline/0.18", borderWidth = 1 }, body)
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

    -- Retrying is pointless until the CLI exists, so that failure gets the install
    -- page too. The URL is a literal, and the button is only offered where
    -- something can open it. The address lives in the tooltip: a raw URL is not a
    -- button caption.
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
            -- The accent belongs to the selection and the bars. A title that took
            -- it too would leave the panel with no quiet level.
            ui.label({ text = noctalia.tr("ui.title"), fontSize = 15, fontWeight = "bold", color = "on_surface" }),
            ui.spacer({ flexGrow = 1 }),
            -- One slot for the read: the button becomes the spinner while the CLI
            -- answers, instead of a second glyph pushing the header around.
            ui.button({
                glyph = polling and "loader-2" or refreshQueued and "clock" or "refresh",
                variant = "ghost", controlSize = "sm",
                tooltip = noctalia.tr(polling and "ui.refreshing"
                    or refreshQueued and "ui.refresh_queued" or "ui.refresh"),
                enabled = not polling,
                onClick = requestRefresh,
            }),
            -- The capsule answers a middle click with this too, but the panel is
            -- where someone decides the capsule should follow another provider.
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
        -- The provider names the pane, the plan qualifies it -- the same order the
        -- row in the list uses. The CLI keeps them apart: `display_name` is
        -- "Codex", `plan` is "ChatGPT Free".
        title = tostring(entry.display_name or entry.id)
        subtitle = tostring(entry.plan or "")
        if subtitle == title then subtitle = "" end
    end

    -- With no entry the pane stays empty rather than repeating the list's title.
    local children = {}
    if entry ~= nil then
        -- The row keeps the title block honest about its height: a bare ui.column
        -- dropped into a column claims the pane's free space, parking the title at
        -- the top of a hundred pixels of nothing. Wrapped, it is as tall as the two
        -- labels in it.
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

    -- The id and a "ready" status are skipped: the id is the row that was just
    -- clicked, and a healthy read is the default.
    if entry ~= nil then
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

    -- The read failed, but the numbers below it did not: they are simply older
    -- than the panel would like. Said once, at the top, rather than by dropping
    -- every card underneath.
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
    local content = 0
    local function push(card)
        cards[#cards + 1] = card
        content = content + 1
    end
    local sections = entry ~= nil and type(entry.sections) == "table" and entry.sections or {}

    -- Pass one: pair every reading with the heading standing over it, and drop the
    -- padding the CLI puts between sections -- the column sets its own gap, and a
    -- spacer left behind by a consumed heading would double it. Providers that
    -- send no headings come out of this with the list they always had.
    local windowed = false
    local heading = ""
    local items = {}
    for _, section in ipairs(sections) do
        if type(section) == "table" then
            local text = section.type == "text"
            if text and noctalia.string.trim(tostring(section.value or "")) == "" then
                heading = tostring(section.label or "")
                windowed = windowed or heading ~= ""
            elseif section.type == "metric" then
                items[#items + 1] = { kind = "metric", section = section, window = heading }
            elseif section.type ~= "spacer" then
                items[#items + 1] = { kind = "other", section = section }
            end
        end
    end

    -- A provider that is down draws no gauges: a bar reads as a live reading, and
    -- nothing is reading. The warning takes their place, and the numbers it was
    -- last seen with follow it as a record -- unless the plan has changed since,
    -- in which case they were measured against limits that no longer apply.
    local warning = entry ~= nil and providerWarning(entry) or ""
    if warning ~= "" then
        push(noteCard(warning))
        local id = tostring(entry.id or "")
        local previous = lastPlan[id]
        if previous ~= nil and previous ~= tostring(entry.plan or "") then
            push(ui.label({ text = noctalia.tr("ui.plan_changed"), fontSize = 11,
                            color = "on_surface_variant", maxLines = 2 }))
        else
            local record = recordCard(entry, items, windowed)
            if record ~= nil then push(record) end
        end
        for _, item in ipairs(items) do
            local section = item.section
            if item.kind ~= "metric" and section.type == "block" then push(blockCard(section)) end
        end
        children[#children + 1] = ui.scroll({ gap = 24, flexGrow = 1 }, cards)
        return ui.column({ gap = 8, padding = 14, flexGrow = 1 }, children)
    end

    -- Pass two. Every reading a provider sends goes in one card. Antigravity names
    -- each model once per window, so its readings are keyed by model and the window
    -- heads the line; the rest report one subject and their own labels already name
    -- the windows.
    local order, byName = {}, {}
    for _, item in ipairs(items) do
        if item.kind == "metric" then
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
    for _, name in ipairs(order) do push(stackCard(name, byName[name])) end

    for _, item in ipairs(items) do
        local section = item.section
        if item.kind == "metric" then
            -- already drawn above
        elseif section.type == "block" then
            push(blockCard(section))
        elseif section.type == "text" then
            local label = tostring(section.label or "")
            local value = tostring(section.value or "")
            if label:lower() == "warning" or value:lower():find("error:") ~= nil then
                push(noteCard(value))
            else
                push(ui.row({ gap = 6, align = "center" }, {
                    ui.label({ text = label, fontSize = 11, color = "on_surface_variant" }),
                    ui.spacer({ flexGrow = 1 }),
                    ui.label({ text = value, fontSize = 11, color = "on_surface", maxLines = 1 }),
                }))
            end
        elseif section.type == "title" then
            push(ui.label({
                text = tostring(section.value or section.label or ""),
                fontSize = 12, fontWeight = "semibold", color = "on_surface",
            }))
        else
            -- Keep schema additions visible instead of silently losing report data.
            push(ui.label({
                text = tostring(section.value or section.label or section.type or "—"),
                fontSize = 11, color = "on_surface_variant",
            }))
        end
    end
    -- A section list that lost every card to a heading would otherwise scroll an
    -- empty column instead of saying there is nothing to show.
    if content > 0 then
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
    -- A failure with nothing behind it is the whole panel. With a report behind
    -- it, it is a banner over readings that are still the best answer available:
    -- a spawn that failed once should not blank a panel the user just opened.
    if failure.code ~= "" and entry == nil then
        -- The panel keeps the fixed size the manifest gives it, and a failure has
        -- nowhere near 720x400 to say. Bounded to a readable width and centred, the
        -- empty surround reads as composition rather than a half-drawn frame.
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

    -- Both panes have to be told to fill the panel, or their ui.scroll children ask
    -- for their natural height: the cards overflow, and the free space goes to
    -- whatever else in the column will take it.
    panel.render(ui.row({ gap = 0, flexGrow = 1, align = "stretch" }, {
        listPane(entry),
        ui.separator({ orientation = "vertical", color = "outline", opacity = 0.28 }),
        detailPane(entry),
    }))
end

-- ── Wiring ────────────────────────────────────────────────────────────────────

local function rememberPlans()
    for _, entry in ipairs(entries()) do
        if type(entry) == "table" and not unavailable(entry) then
            lastPlan[tostring(entry.id or "")] = tostring(entry.plan or "")
        end
    end
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
    -- Every open asks for fresh numbers. The CLI answers from its own cache when it
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
