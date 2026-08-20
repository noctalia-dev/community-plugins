--!nonstrict
-- Expanded panel for one provider.
--
-- It renders `sections[]`, which is the CLI's lossless view, so credit blocks
-- and free text that the shorter `metrics[]` view drops still show up.

local report = nil
local polling = false

local shared = require("./shared.luau")
local GLYPHS, parseIso = shared.GLYPHS, shared.parseIso
local countdown, resetClock = shared.countdown, shared.resetClock
local ratio, headline, severityRole = shared.ratio, shared.headline, shared.severityRole
local NO_FAILURE, asFailure = shared.NO_FAILURE, shared.asFailure

local failure = NO_FAILURE

-- Read once: a session either has xdg-utils or it does not, and the panel
-- would otherwise stat PATH on every second tick it spends in a failure.
local HAS_OPENER = noctalia.commandExists("xdg-open")

-- The CLI reports a vendor it has no credential for as a `credentials error`.
-- Those are not listed, because they were never set up. A configured provider
-- that fails for any other reason keeps its row.
local function configured(entry)
    if entry.status ~= "error" then return true end
    return not tostring(entry.error or ""):lower():find("credentials error")
end

-- ── Detail line parsing ───────────────────────────────────────────────────────
-- "Resets in 1h 58m · 60% elapsed · 30pts ahead". The reset half is already in
-- `reset_at`; what is left is the pace pair.

local function elapsedPercent(detail)
    local value = tostring(detail or ""):match("(%d+)%%%s*elapsed")
    return value ~= nil and tonumber(value) or nil
end

local function pace(detail)
    local text = tostring(detail or "")
    if not text:find("·") then return "", "on_surface_variant" end
    local last = ""
    for part in text:gmatch("[^·]+") do last = part end
    last = noctalia.string.trim(last)
    if last:find("elapsed") then return "", "on_surface_variant" end
    -- Ahead of the clock is worth flagging. Under it means there is room left.
    if last:find("ahead") then return last, "tertiary" end
    if last:find("under") then return last, "on_surface_variant" end
    return last, "on_surface_variant"
end

-- Details that carry no reset at all, e.g. "62% of monthly limit consumed".
local function plainDetail(detail)
    local head = tostring(detail or ""):match("^[^·]*") or ""
    head = noctalia.string.trim(head)
    if head:lower():find("^resets?%s+in") then return "" end
    return head
end

-- ── Entry selection ───────────────────────────────────────────────────────────

local function entries()
    if type(report) ~= "table" or type(report.entries) ~= "table" then return {} end
    return report.entries
end

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

local function metricIcon(label)
    local text = tostring(label or ""):lower()
    if text:find("week") or text:find("month") then return "calendar" end
    if text:find("credit") or text:find("balance") or text:find("extra") then return "shopping-cart" end
    return "hourglass"
end

-- ── Cards ─────────────────────────────────────────────────────────────────────

-- A severity word, and only when the CLI raised one. Colour on its own leaves
-- the reading to anyone who can tell the two accents apart.
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
        ui.glyph({ name = metricIcon(section.label), size = 14, color = "on_surface_variant" }),
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
    -- Every card ends on the same right edge, so a column of them reads as one
    -- ruler instead of a ragged margin.
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

    -- Two readings: quota spent above, window elapsed below. A shorter clock bar
    -- than fill bar is quota burning ahead of time.
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

    -- One line under the bars carries the whole time story: what is left of the
    -- window, when it lands, how much of it is gone, and whether the spend is
    -- running ahead. Four separate lines said the same thing four times taller.
    local left = countdown(section)
    local clock = resetClock(section)
    local paceText, paceColor = pace(section.detail)
    local footer = {}
    if left ~= "" then
        footer[#footer + 1] = ui.glyph({ name = "clock", size = 12, color = "on_surface_variant" })
        footer[#footer + 1] = ui.label({ text = left, fontSize = 11, color = "on_surface_variant" })
        if clock ~= "" then
            -- Parenthesised and muted: it is the time the countdown beside it
            -- lands on, not a reading of its own. In the accent colour it was
            -- the loudest thing in the card after the percentage.
            footer[#footer + 1] = ui.label({
                text = "(" .. clock .. ")", fontSize = 11, color = "on_surface_variant",
            })
        end
    end
    if elapsed ~= nil then
        if #footer > 0 then
            footer[#footer + 1] = ui.label({ text = "·", fontSize = 11, color = "on_surface_variant" })
        end
        footer[#footer + 1] = ui.label({
            text = noctalia.tr("ui.elapsed", { percent = elapsed }),
            fontSize = 11, color = "on_surface_variant", maxLines = 1,
        })
    end
    if #footer > 0 or paceText ~= "" then
        footer[#footer + 1] = ui.spacer({ flexGrow = 1 })
        if paceText ~= "" then
            footer[#footer + 1] = ui.label({ text = paceText, fontSize = 11, fontWeight = "semibold", color = paceColor })
        end
        body[#body + 1] = ui.row({ gap = 5, align = "center" }, footer)
    end

    local rest = plainDetail(section.detail)
    if rest ~= "" then
        body[#body + 1] = ui.label({ text = rest, fontSize = 11, color = "on_surface_variant" })
    end

    return ui.column({ gap = 6, padding = 10, radius = 8, fill = "surface_variant" }, body)
end

local function blockCard(section)
    local body = {
        ui.row({ gap = 6, align = "center" }, {
            ui.glyph({ name = metricIcon(section.label), size = 14, color = "on_surface_variant" }),
            ui.label({ text = tostring(section.label or ""), fontSize = 12, fontWeight = "semibold",
                       color = "on_surface", maxLines = 1 }),
        }),
    }
    for _, line in ipairs(section.body or {}) do
        local text = noctalia.string.trim(tostring(line))
        -- A line the CLI left as a bare "balance:" reads as a row that failed
        -- to render. Nothing is a value, and it is spelled the same way here as
        -- it is everywhere else in the panel.
        if text:find(":$") then text = text .. " —" end
        body[#body + 1] = ui.label({
            text = text ~= "" and text or "—",
            fontSize = 11,
            color = "on_surface_variant",
        })
    end
    return ui.column({ gap = 4, padding = 10, radius = 8, fill = "surface_variant/0.45" }, body)
end

local function textRow(section)
    return ui.row({ gap = 6, align = "center" }, {
        ui.label({ text = tostring(section.label or ""), fontSize = 11, color = "on_surface_variant" }),
        ui.spacer({ flexGrow = 1 }),
        ui.label({ text = tostring(section.value or ""), fontSize = 11, color = "on_surface" }),
    })
end

-- ── Provider list ─────────────────────────────────────────────────────────────

local function providerRow(entry, selected)
    local metric = headline(entry)
    local percent = metric ~= nil and tonumber(metric.percent) or nil
    local broken = entry.status == "error"
    local tint = severityRole(metric, "on_surface")

    -- The reading keeps its own severity colour whether or not the row is
    -- selected. A selected row that recolours its number hides the one thing
    -- the list exists to compare.
    local right
    if broken then
        right = ui.row({ width = 34, justify = "end" }, {
            ui.glyph({ name = "alert-circle", size = 14, color = "error" }),
        })
    else
        right = ui.label({
            text = percent ~= nil and string.format("%d%%", percent) or "—",
            fontSize = 13, fontWeight = "bold", color = tint,
            width = 34, textAlign = "end",
        })
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
        -- Keyed, so the click handler survives the second tick the countdowns
        -- ride on rather than being rebuilt under the pointer once a second.
        key = "provider-" .. tostring(entry.id),
        gap = 8, align = "center", padding = 8, radius = 8,
        -- Selection is a tint, not a slab of accent: a filled `primary` row has
        -- to invert every colour inside it, and then it shouts over the reading.
        fill = selected and "primary/0.14" or "surface_variant/0.45",
        onClick = function()
            -- currentEntry() reads this back, so the panel and the capsule that
            -- opened it stay on the same provider.
            noctalia.state.set("selected", tostring(entry.id))
            render()
        end,
    }, {
        ui.glyph({ name = GLYPHS[tostring(entry.id)] or "brain", size = 16,
                   color = selected and "primary" or "on_surface_variant" }),
        ui.column({ gap = 3, flexGrow = 1 }, lines),
        right,
    })
end

-- ── Render ────────────────────────────────────────────────────────────────────

local function requestRefresh()
    noctalia.state.set("command", { action = "refresh", at = os.time() })
end

-- The failure and the suggested fix read first; the CLI's own words come last
-- and smallest, where a bug report can still quote them.
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

    -- The shell's own button, so a retry here looks like every other retry in
    -- Noctalia and follows the user's theme without being told to.
    local actions = {
        ui.button({
            text = noctalia.tr("ui.retry"), glyph = "refresh",
            variant = "outline", controlSize = "sm",
            enabled = not polling,
            onClick = requestRefresh,
        }),
    }

    -- Retrying is pointless until the CLI exists, so that one failure gets the
    -- install page as well. The URL is a literal, so there is nothing to quote,
    -- and the button is only offered where something can open it. It reads as a
    -- label with the address in its tooltip: a raw URL is not a button caption.
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

-- A muted stand-in at the shape of what is coming, so a cold read is not a
-- spinner parked where the content is about to land. One shape serves both
-- panes: it is a placeholder, and two kinds of placeholder is one too many.
local function skeleton(key)
    return ui.column({
        key = "skeleton-" .. key,
        gap = 6, padding = 10, radius = 8, fill = "surface_variant/0.45",
    }, {
        ui.box({ width = 96, height = 10, radius = 3, fill = "on_surface/0.10" }),
        ui.box({ height = 4, radius = 2, fill = "on_surface/0.06" }),
    })
end

local function listPane(entry)
    local rows = {}
    for _, candidate in ipairs(entries()) do
      if configured(candidate) then
        rows[#rows + 1] = providerRow(candidate, entry ~= nil and candidate.id == entry.id)
      end
    end
    if #rows == 0 then
        for index = 1, 3 do rows[index] = skeleton("row-" .. index) end
    end

    return ui.column({ gap = 10, padding = 14, width = 250 }, {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = "brain", size = 18, color = "primary" }),
            -- The accent belongs to the selection and the bars. A title that
            -- takes it too leaves the panel with no quiet level to fall back to.
            ui.label({ text = noctalia.tr("ui.title"), fontSize = 15, fontWeight = "bold", color = "on_surface" }),
            ui.spacer({ flexGrow = 1 }),
            -- One slot for the read: the button becomes the spinner while the
            -- CLI answers, rather than a second glyph appearing beside it and
            -- pushing the header around once a cycle.
            ui.button({
                glyph = polling and "loader-2" or "refresh",
                variant = "ghost", controlSize = "sm",
                tooltip = noctalia.tr("ui.refresh"),
                enabled = not polling,
                onClick = requestRefresh,
            }),
        }),
        ui.scroll({ gap = 6, flexGrow = 1 }, rows),
    })
end

local function detailPane(entry)
    local title = noctalia.tr("ui.title")
    local subtitle = ""
    if entry ~= nil then
        title = tostring(entry.plan or entry.display_name or entry.id)
        subtitle = tostring(entry.display_name or entry.id)
        if subtitle == title then subtitle = "" end
    end

    -- No entry yet means the skeletons below are the whole pane. A title here
    -- would only repeat the one the list pane is already showing.
    local children = {}
    if entry ~= nil then
        -- The row keeps the title block honest about its height. A bare
        -- ui.column dropped into a column takes the pane's free space for
        -- itself, which parks the title at the top of a hundred pixels of
        -- nothing and pushes the rest of the header down. Wrapped, the block is
        -- only as tall as the two labels in it.
        children[#children + 1] = ui.row({ gap = 8, align = "center" }, {
            ui.column({ gap = 0, flexGrow = 1 }, {
                ui.label({ text = title, fontSize = 15, fontWeight = "bold",
                           color = "on_surface", maxLines = 1 }),
                ui.label({ text = subtitle, fontSize = 11, color = "on_surface_variant",
                           maxLines = 1, visible = subtitle ~= "" }),
            }),
        })
    end

    -- What the entry says about itself, in words rather than a colour. The
    -- provider id and a "ready" status are the plugin talking to itself: the id
    -- is the row that was just clicked, and a healthy read is the default.
    if entry ~= nil then
        local chips = {}
        local function separate()
            if #chips > 0 then
                chips[#chips + 1] = ui.label({ text = "·", fontSize = 10, color = "on_surface_variant" })
            end
        end
        if entry.status ~= "ready" then
            chips[#chips + 1] = ui.label({
                text = tostring(entry.status or ""), fontSize = 10, color = "error", maxLines = 1,
            })
        end
        if entry.stale == true then
            separate()
            chips[#chips + 1] = ui.label({ text = noctalia.tr("ui.stale"), fontSize = 10, color = "tertiary" })
        end
        local fetched = parseIso(entry.fetched_at)
        if fetched ~= nil then
            separate()
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
            cards[#cards + 1] = textRow(section)
        end
    end
    if #cards > 0 then
        children[#children + 1] = ui.scroll({ gap = 8, flexGrow = 1 }, cards)
    elseif entry ~= nil then
        -- A provider with nothing to draw says so. Half an empty panel is not
        -- an answer to the question the panel was opened to answer.
        children[#children + 1] = ui.row({ gap = 6, align = "center" }, {
            ui.glyph({ name = "info-circle", size = 14, color = "on_surface_variant" }),
            ui.label({ text = noctalia.tr("ui.no_usage"), fontSize = 11, color = "on_surface_variant" }),
        })
        children[#children + 1] = ui.spacer({ flexGrow = 1 })
    else
        children[#children + 1] = ui.column({ gap = 8, flexGrow = 1 }, {
            skeleton("card-1"), skeleton("card-2"),
        })
    end

    return ui.column({ gap = 10, padding = 14, flexGrow = 1 }, children)
end

function render()
    local entry = currentEntry()
    -- A failure replaces the report. The numbers are from a read that is no
    -- longer happening, and leaving them up puts a provider list and a
    -- percentage next to an alert saying neither can be trusted.
    if failure.code ~= "" then
        -- The panel keeps the fixed size the manifest gives it, and a failure
        -- has nowhere near 720x400 of things to say. The block stays bounded to
        -- a readable width and sits in the middle of the panel, where an empty
        -- surround reads as composition instead of a half-drawn frame.
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

    -- Both panes have to be told to fill the panel, or their ui.scroll children
    -- ask for their natural height instead of the height they were given: the
    -- cards then overflow the panel and the free space is handed to whatever
    -- else in the column will take it, which pushes the header away from them.
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

function onOpen(_context)
    -- Every open asks for fresh numbers. The CLI answers from its own cache
    -- when it has one, and the poller drops requests that arrive too close
    -- together, so reopening the panel repeatedly is cheap.
    noctalia.state.set("command", { action = "refresh", at = os.time() })
    report = noctalia.state.get("report")
    failure = asFailure(noctalia.state.get("error"))
    polling = noctalia.state.get("polling") == true
    -- Countdowns tick locally; the CLI is only woken by the poller's interval.
    panel.setWantsSecondTicks(true)
    render()
end

-- Panel second tick, for the countdowns.
function update()
    render()
end

render()
