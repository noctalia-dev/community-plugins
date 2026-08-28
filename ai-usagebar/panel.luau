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
local NO_FAILURE, asFailure = shared.NO_FAILURE, shared.asFailure

local failure = NO_FAILURE

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

local function metricCard(section)
    local percent = tonumber(section.percent) or 0
    local tint = severityRole(section, "on_surface")
    local fill = severityRole(section, "primary")
    local value = tostring(section.value or ""):gsub(" of ", " / ")
    -- Only worth a column of its own when it says more than the percentage.
    local showValue = value ~= "" and value ~= string.format("%d%%", percent)

    local header = {
        ui.label({ text = tostring(section.label or ""), fontSize = 12, fontWeight = "semibold",
                   color = "on_surface", maxLines = 1 }),
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

    return ui.column({ gap = 6, padding = 10, radius = 8, fill = "surface_variant/0.45",
                       border = "outline/0.12", borderWidth = 1 }, body)
end

local function blockCard(section)
    local body = {
        ui.label({ text = tostring(section.label or ""), fontSize = 12, fontWeight = "semibold",
                   color = "on_surface", maxLines = 1 }),
    }
    for _, line in ipairs(section.body or {}) do
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

-- ── Provider list ─────────────────────────────────────────────────────────────

local function providerRow(entry, selected)
    local metric = headline(entry)
    local percent = metric ~= nil and tonumber(metric.percent) or nil
    local broken = entry.status == "error"
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

    local status = entry ~= nil and entry.status == "error"
        and tostring(entry.error or noctalia.tr("ui.unavailable")) or nil
    if status then
        children[#children + 1] = ui.label({ text = status, fontSize = 11, color = "on_surface_variant" })
    end

    local cards = {}
    for _, section in ipairs((entry ~= nil and entry.sections) or {}) do
        if section.type == "metric" then
            cards[#cards + 1] = metricCard(section)
        elseif section.type == "block" then
            cards[#cards + 1] = blockCard(section)
        elseif section.type == "text" then
            cards[#cards + 1] = ui.row({ gap = 6, align = "center" }, {
                ui.label({ text = tostring(section.label or ""), fontSize = 11,
                           color = "on_surface_variant" }),
                ui.spacer({ flexGrow = 1 }),
                ui.label({ text = tostring(section.value or ""), fontSize = 11,
                           color = "on_surface", maxLines = 1 }),
            })
        elseif section.type == "spacer" then
            cards[#cards + 1] = ui.spacer({ height = tonumber(section.height) or 8 })
        elseif section.type == "title" then
            cards[#cards + 1] = ui.label({
                text = tostring(section.value or section.label or ""),
                fontSize = 12, fontWeight = "semibold", color = "on_surface",
            })
        else
            -- Keep schema additions visible instead of silently losing report data.
            cards[#cards + 1] = ui.label({
                text = tostring(section.value or section.label or section.type or "—"),
                fontSize = 11, color = "on_surface_variant",
            })
        end
    end
    if #cards > 0 then
        children[#children + 1] = ui.scroll({ gap = 8, flexGrow = 1 }, cards)
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
    -- A failure replaces the report: those numbers came from a read that is no
    -- longer happening.
    if failure.code ~= "" then
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

noctalia.state.watch("refresh_queued", function(value)
    refreshQueued = value == true
    render()
end)

function onOpen(_context)
    -- Every open asks for fresh numbers. The CLI answers from its own cache when it
    -- has one, and the poller drops requests that arrive too close together.
    requestRefresh()
    report = noctalia.state.get("report")
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
