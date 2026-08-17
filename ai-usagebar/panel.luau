--!nonstrict
-- Expanded panel for one provider.
--
-- It renders `sections[]`, which is the CLI's lossless view, so credit blocks
-- and free text that the shorter `metrics[]` view drops still show up.

local report = nil
local polling = false

-- The poller names the failure, so the panel only has a code to translate.
-- Anything else in that state slot reads as no failure at all.
local NO_FAILURE = { code = "", detail = "" }

local function asFailure(value)
    return type(value) == "table" and value or NO_FAILURE
end

local failure = NO_FAILURE

-- Read once: a session either has xdg-utils or it does not, and the panel
-- would otherwise stat PATH on every second tick it spends in a failure.
local HAS_OPENER = noctalia.commandExists("xdg-open")

-- Same parsing the capsule does. There is no require() below API 22, so the
-- four helpers below are copied instead of shared.
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

local function countdown(section)
    local at = parseIso(section and section.reset_at)
    if at == nil then return "" end
    return formatDuration(at - os.time())
end

local function resetClock(section)
    local at = parseIso(section and section.reset_at)
    if at == nil then return "" end
    local clock = noctalia.formatTime(noctalia.timeFormat(), at)
    if os.date("%Y-%m-%d", at) == os.date("%Y-%m-%d") then return clock end
    -- A weekday alone is ambiguous once the window is more than a week out.
    if at - os.time() > 6 * 86400 then return os.date("%d %b", at) .. " " .. clock end
    return os.date("%a", at) .. " " .. clock
end

-- Text stays on the surface colour until the CLI calls the window high or
-- critical. The accent colour is used on the bar fill only.
local function textRole(section)
    local severity = tostring(section and section.severity or "")
    if severity == "critical" then return "error" end
    if severity == "high" then return "tertiary" end
    return "on_surface"
end

local function barRole(section)
    local severity = tostring(section and section.severity or "")
    if severity == "critical" then return "error" end
    if severity == "high" then return "tertiary" end
    return "primary"
end

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

local function ratio(percent)
    local value = (tonumber(percent) or 0) / 100
    if value < 0 then return 0 end
    if value > 1 then return 1 end
    return value
end

local function metricIcon(label)
    local text = tostring(label or ""):lower()
    if text:find("week") or text:find("month") then return "calendar" end
    if text:find("credit") or text:find("balance") or text:find("extra") then return "shopping-cart" end
    return "hourglass"
end

-- ── Cards ─────────────────────────────────────────────────────────────────────

local function metricCard(section)
    local percent = tonumber(section.percent) or 0
    local tint = textRole(section)
    local fill = barRole(section)
    local value = tostring(section.value or ""):gsub(" of ", " / ")
    -- Only worth a column of its own when it says more than the percentage.
    local showValue = value ~= "" and value ~= string.format("%d%%", percent)

    local header = {
        ui.glyph({ name = metricIcon(section.label), size = 14, color = tint }),
        ui.label({ text = tostring(section.label or ""), fontSize = 11, color = "on_surface_variant" }),
        ui.label({
            text = tostring(section.severity or ""),
            fontSize = 9, fontWeight = "semibold", color = tint,
            visible = tostring(section.severity or "") ~= "",
        }),
        ui.spacer({ flexGrow = 1 }),
    }
    if showValue then
        header[#header + 1] = ui.label({ text = value, fontSize = 11, color = "on_surface_variant" })
    end
    header[#header + 1] = ui.label({
        text = string.format("%d%%", percent),
        fontSize = 15,
        fontWeight = "bold",
        color = tint,
    })

    local body = {
        ui.row({ gap = 6, align = "center" }, header),
        ui.progress({ progress = ratio(percent), fill = fill, track = "on_surface/0.16", radius = 3, height = 5 }),
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
            height = 2,
        })
        body[#body + 1] = ui.label({
            text = noctalia.tr("ui.elapsed", { percent = elapsed }),
            fontSize = 10, color = "on_surface_variant",
        })
    end

    local left = countdown(section)
    local clock = resetClock(section)
    local paceText, paceColor = pace(section.detail)
    if left ~= "" or paceText ~= "" then
        local footer = {}
        if left ~= "" then
            footer[#footer + 1] = ui.glyph({ name = "clock", size = 12, color = "on_surface_variant" })
            footer[#footer + 1] = ui.label({ text = left, fontSize = 11, color = "on_surface_variant" })
            if clock ~= "" then
                footer[#footer + 1] = ui.label({ text = clock, fontSize = 11, fontWeight = "bold", color = "primary" })
            end
        end
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
            ui.glyph({ name = metricIcon(section.label), size = 14, color = "primary" }),
            ui.label({ text = tostring(section.label or ""), fontWeight = "bold", color = "on_surface" }),
        }),
    }
    for _, line in ipairs(section.body or {}) do
        local text = noctalia.string.trim(tostring(line))
        body[#body + 1] = ui.label({
            text = text ~= "" and text or "—",
            fontSize = 11,
            color = "on_surface_variant",
        })
    end
    return ui.column({ gap = 4, padding = 10, radius = 8, fill = "surface_variant" }, body)
end

local function textRow(section)
    return ui.row({ gap = 6, align = "center" }, {
        ui.label({ text = tostring(section.label or ""), fontSize = 11, color = "on_surface_variant" }),
        ui.spacer({ flexGrow = 1 }),
        ui.label({ text = tostring(section.value or ""), fontSize = 11, color = "on_surface" }),
    })
end

-- ── Provider list ─────────────────────────────────────────────────────────────

-- Same map the capsule uses; no require() below API 22, so it is duplicated.
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

local function headline(entry)
    if type(entry) ~= "table" or type(entry.metrics) ~= "table" then return nil end
    return entry.metrics[1]
end

local function providerRow(entry, selected)
    local metric = headline(entry)
    local percent = metric ~= nil and tonumber(metric.percent) or nil
    local broken = entry.status == "error"
    local tint = selected and "on_primary" or textRole(metric)
    local fill = selected and "on_primary" or barRole(metric)
    local muted = selected and "on_primary" or "on_surface_variant"

    local right
    if broken then
        right = ui.glyph({ name = "alert-circle", size = 14, color = selected and "on_primary" or "error" })
    else
        right = ui.label({
            text = percent ~= nil and string.format("%d%%", percent) or "—",
            fontSize = 13, fontWeight = "bold", color = tint,
        })
    end

    local lines = {
        ui.label({
            text = tostring(entry.display_name or entry.id),
            fontSize = 12, fontWeight = "semibold",
            color = selected and "on_primary" or "on_surface", maxLines = 1,
        }),
    }
    if percent ~= nil and not broken then
        lines[#lines + 1] = ui.progress({
            progress = ratio(percent),
            fill = fill,
            track = selected and "on_primary/0.25" or "on_surface/0.16",
            radius = 2, height = 3,
        })
    end
    lines[#lines + 1] = ui.label({
        text = broken and noctalia.tr("ui.unavailable") or tostring(entry.plan or entry.id or ""),
        fontSize = 10, color = muted, maxLines = 1,
    })

    return ui.row({
        gap = 8, align = "center", padding = 8, radius = 8,
        fill = selected and "primary" or "surface_variant",
        onClick = function()
            -- currentEntry() reads this back, so the panel and the capsule that
            -- opened it stay on the same provider.
            noctalia.state.set("selected", tostring(entry.id))
            render()
        end,
    }, {
        ui.glyph({ name = GLYPHS[tostring(entry.id)] or "brain", size = 16, color = tint }),
        ui.column({ gap = 3, flexGrow = 1 }, lines),
        right,
    })
end

-- ── Render ────────────────────────────────────────────────────────────────────

local function actionRow(glyph, text, onClick)
    return ui.row({
        gap = 5, align = "center", padding = 6, radius = 6,
        fill = "surface_variant", onClick = onClick,
    }, {
        ui.glyph({ name = glyph, size = 12, color = "primary" }),
        ui.label({ text = text, fontSize = 11, color = "primary" }),
    })
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

    children[#children + 1] = actionRow("refresh", noctalia.tr("ui.retry"), function()
        noctalia.state.set("command", { action = "refresh", at = os.time() })
    end)

    -- Retrying is pointless until the CLI exists, so that one failure gets the
    -- install page as well. The URL is a literal, so there is nothing to quote,
    -- and the row is only offered where something can open it.
    if failure.code == "not_installed" and HAS_OPENER then
        children[#children + 1] = actionRow("external-link", "github.com/akitaonrails/ai-usagebar", function()
            noctalia.runAsync("xdg-open https://github.com/akitaonrails/ai-usagebar")
        end)
    end

    return ui.column({ gap = 6 }, children)
end

local function listPane(entry)
    local rows = {}
    for _, candidate in ipairs(entries()) do
      if configured(candidate) then
        rows[#rows + 1] = providerRow(candidate, entry ~= nil and candidate.id == entry.id)
      end
    end
    if #rows == 0 then
        rows[1] = ui.label({ text = noctalia.tr("ui.loading"), fontSize = 11, color = "on_surface_variant" })
    end

    return ui.column({ gap = 10, padding = 14, width = 250 }, {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = "brain", size = 18, color = "primary" }),
            ui.label({ text = noctalia.tr("ui.title"), fontSize = 15, fontWeight = "bold", color = "primary" }),
            ui.spacer({ flexGrow = 1 }),
            -- The panel refreshes when it opens, so the header only has to
            -- show whether that read is still running.
            ui.glyph({ name = "loader-2", size = 16, color = "primary", visible = polling }),
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

    local children = {
        ui.row({ gap = 8, align = "center" }, {
            ui.column({ gap = 0, flexGrow = 1 }, {
                ui.label({ text = title, fontSize = 15, fontWeight = "bold", color = "on_surface" }),
                ui.label({ text = subtitle, fontSize = 11, color = "on_surface_variant", visible = subtitle ~= "" }),
            }),
        }),
    }

    -- The entry's own fields, spelled out rather than implied by a colour.
    if entry ~= nil then
        local chips = {
            ui.label({ text = tostring(entry.id or ""), fontSize = 10, color = "on_surface_variant" }),
            ui.label({ text = "·", fontSize = 10, color = "on_surface_variant" }),
            ui.label({
                text = tostring(entry.status or ""),
                fontSize = 10,
                color = entry.status == "ready" and "on_surface_variant" or "error",
            }),
        }
        if entry.stale == true then
            chips[#chips + 1] = ui.label({ text = "·", fontSize = 10, color = "on_surface_variant" })
            chips[#chips + 1] = ui.label({ text = noctalia.tr("ui.stale"), fontSize = 10, color = "tertiary" })
        end
        local fetched = parseIso(entry.fetched_at)
        if fetched ~= nil then
            chips[#chips + 1] = ui.spacer({ flexGrow = 1 })
            chips[#chips + 1] = ui.glyph({ name = "clock", size = 11, color = "on_surface_variant" })
            chips[#chips + 1] = ui.label({
                text = updatedText(entry) .. " · " .. noctalia.formatTime(noctalia.timeFormat(), fetched),
                fontSize = 10, color = "on_surface_variant",
            })
        end
        children[#children + 1] = ui.row({ gap = 4, align = "center" }, chips)
    end

    local status = entry == nil and noctalia.tr("ui.loading")
        or entry.status == "error" and tostring(entry.error or noctalia.tr("ui.unavailable"))
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
    else
        children[#children + 1] = ui.spacer({ flexGrow = 1 })
    end

    return ui.column({ gap = 10, padding = 14, flexGrow = 1 }, children)
end

function render()
    local entry = currentEntry()
    -- A failure replaces the report rather than sitting above it. The numbers
    -- are from a read that is no longer happening, and leaving them up puts a
    -- provider list and a percentage next to an alert saying neither can be
    -- trusted.
    if failure.code ~= "" then
        -- The panel keeps the fixed size the manifest gives it, so the block
        -- is width-bounded rather than stretched across 720px of button.
        panel.render(ui.column({ gap = 10, padding = 14, width = 320 }, {
            ui.row({ gap = 8, align = "center" }, {
                ui.glyph({ name = "brain", size = 18, color = "primary" }),
                ui.label({ text = noctalia.tr("ui.title"), fontSize = 15, fontWeight = "bold", color = "primary" }),
            }),
            errorBlock(),
        }))
        return
    end

    panel.render(ui.row({ gap = 0 }, {
        listPane(entry),
        -- ui.separator is horizontal only; a one-pixel column is the divider.
        ui.column({ width = 1, fill = "on_surface/0.12" }, {}),
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
