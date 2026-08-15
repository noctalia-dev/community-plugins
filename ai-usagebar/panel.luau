--!nonstrict
-- Expanded panel for one provider.
--
-- It renders `sections[]` — the CLI's lossless view — so credit blocks and free
-- text that the `metrics[]` convenience view drops still show up.

local report = nil
local errorMsg = ""
local polling = false

-- Same parsing the capsule does; plugin_api 8 has no module system, so the four
-- helpers below are duplicated rather than required.
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

local function countdown(section)
    local at = parseIso(section and section.reset_at)
    if at == nil then return "" end
    return formatDuration(at - os.time())
end

local function resetClock(section)
    local at = parseIso(section and section.reset_at)
    if at == nil then return "" end
    local pattern = noctalia.timeFormat() or "HH:mm"
    if os.date("%Y-%m-%d", at) ~= os.date("%Y-%m-%d") then
        pattern = "ddd " .. pattern
    end
    return noctalia.formatTime(pattern, at)
end

local function severityRole(section)
    local severity = tostring(section and section.severity or "")
    if severity == "critical" then return "error" end
    if severity == "high" then return "secondary" end
    return "primary"
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
    -- Ahead of the clock is the reading worth flagging; under is the roomy side.
    if last:find("ahead") then return last, "secondary" end
    if last:find("under") then return last, "tertiary" end
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
    for _, entry in ipairs(entries()) do
        if entry.id == wanted then return entry end
    end
    return entries()[1]
end

local function updatedText(entry)
    local at = parseIso(entry and entry.fetched_at)
    if at == nil then return "" end
    local minutes = math.floor((os.time() - at) / 60)
    if minutes < 1 then return "Updated just now" end
    return "Updated " .. tostring(minutes) .. " min ago"
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
    local tint = severityRole(section)
    local value = tostring(section.value or ""):gsub(" of ", " / ")
    -- Only worth a column of its own when it says more than the percentage.
    local showValue = value ~= "" and value ~= string.format("%d%%", percent)

    local header = {
        ui.glyph({ name = metricIcon(section.label), size = 14, color = tint }),
        ui.label({ text = tostring(section.label or ""), fontSize = 11, color = "on_surface_variant" }),
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
        ui.progress({ progress = percent / 100, fill = tint, track = "on_surface/0.16", radius = 3, height = 5 }),
    }

    -- Two readings: quota spent above, window elapsed below. A shorter clock bar
    -- than fill bar is quota burning ahead of time.
    local elapsed = elapsedPercent(section.detail)
    if elapsed ~= nil then
        body[#body + 1] = ui.progress({
            progress = elapsed / 100,
            fill = "on_surface/0.45",
            track = "on_surface/0.10",
            radius = 2,
            height = 2,
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

-- ── Render ────────────────────────────────────────────────────────────────────

local function render()
    local entry = currentEntry()
    local title = "AI Usage"
    local subtitle = ""
    if entry ~= nil then
        title = tostring(entry.plan or entry.display_name or entry.id)
        subtitle = tostring(entry.display_name or entry.id)
        if subtitle == title then subtitle = "" end
    end

    local head = {
        ui.glyph({ name = "brain", size = 18, color = "primary" }),
        ui.column({ gap = 0, flexGrow = 1 }, {
            ui.label({ text = title, fontSize = 14, fontWeight = "bold", color = "on_surface" }),
            ui.label({ text = subtitle, fontSize = 11, color = "on_surface_variant", visible = subtitle ~= "" }),
        }),
        ui.button({
            glyph = "refresh",
            variant = "ghost",
            controlSize = "sm",
            enabled = not polling,
            tooltip = polling and "Reading…" or "Refresh now",
            onClick = "doRefresh",
        }),
    }

    local children = {
        ui.row({ gap = 8, align = "center" }, head),
        ui.separator({}),
    }

    local status = ""
    if errorMsg ~= "" then
        status = errorMsg
    elseif entry == nil then
        status = "Loading…"
    elseif entry.status == "error" then
        status = tostring(entry.error or "Unavailable")
    end
    if status ~= "" then
        children[#children + 1] = ui.label({
            text = status,
            fontSize = 11,
            color = errorMsg ~= "" and "error" or "on_surface_variant",
        })
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

    if entry ~= nil then
        local updated = updatedText(entry)
        if entry.stale == true and updated ~= "" then updated = updated .. " · stale" end
        children[#children + 1] = ui.separator({})
        children[#children + 1] = ui.row({ gap = 5, align = "center" }, {
            ui.glyph({ name = "clock", size = 12, color = "on_surface_variant" }),
            ui.label({ text = updated, fontSize = 11, color = entry.stale == true and "error" or "on_surface_variant" }),
            ui.spacer({ flexGrow = 1 }),
            ui.label({ text = tostring(entry.id or ""), fontSize = 11, color = "on_surface_variant" }),
        })
    end

    panel.render(ui.column({ gap = 10, padding = 14 }, children))
end

-- ── Wiring ────────────────────────────────────────────────────────────────────

function doRefresh()
    noctalia.state.set("command", { action = "refresh", at = os.time() })
end

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

function onOpen(_context)
    report = noctalia.state.get("report")
    local existingError = noctalia.state.get("error")
    errorMsg = type(existingError) == "string" and existingError or ""
    polling = noctalia.state.get("polling") == true
    -- Countdowns tick locally; the CLI is only woken by the poller's interval.
    panel.setWantsSecondTicks(true)
    render()
end

-- Panel second tick.
function update()
    render()
end

render()
