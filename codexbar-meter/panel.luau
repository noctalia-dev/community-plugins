--!nonstrict
-- CodexBar provider usage panel.
--
-- The panel intentionally renders the provider array instead of naming a
-- fixed pair. CodexBar can add providers and provider-specific quota windows;
-- the standard usedPercent/reset envelope is enough for a useful generic card.

local providers = {}
local errorMsg = ""
local panelOpen = false
local refreshIntervalSec = tonumber(noctalia.getConfig("refreshIntervalSec")) or 60

local PROVIDER_META = {
    codex = { label = "Codex", glyph = "brand-openai", color = "primary", source = "OpenAI" },
    openai = { label = "OpenAI", glyph = "brand-openai", color = "primary", source = "OpenAI" },
    claude = { label = "Claude", glyph = "message-chatbot", color = "tertiary", source = "Anthropic" },
}

local FALLBACK_COLORS = { "secondary", "tertiary", "primary" }

local function providerId(provider)
    return tostring(provider and (provider.provider or provider.id) or "unknown")
end

local function titleFromId(value)
    local text = string.gsub(tostring(value or "unknown"), "[_%-]+", " ")
    text = string.gsub(text, "(%a)([%w]*)", function(first, rest)
        return string.upper(first) .. string.lower(rest)
    end)
    return text
end

local function providerAccount(provider)
    if type(provider) ~= "table" then return "" end
    if provider.account ~= nil and tostring(provider.account) ~= "" then
        return tostring(provider.account)
    end
    local usage = provider.usage
    local identity = type(usage) == "table" and usage.identity or nil
    if type(identity) == "table" then
        if identity.accountEmail ~= nil and tostring(identity.accountEmail) ~= "" then
            return tostring(identity.accountEmail)
        end
        if identity.accountOrganization ~= nil and tostring(identity.accountOrganization) ~= "" then
            return tostring(identity.accountOrganization)
        end
    end
    return ""
end

local function metaFor(provider, index)
    local id = providerId(provider)
    local known = PROVIDER_META[string.lower(id)]
    if known ~= nil then return known end
    local colorIndex = ((index - 1) % #FALLBACK_COLORS) + 1
    return {
        label = titleFromId(id),
        glyph = "chart-donut-3",
        color = FALLBACK_COLORS[colorIndex],
        source = "CodexBar",
    }
end

local function providerLabel(provider, index)
    local meta = metaFor(provider, index)
    return meta.label
end

local function providerError(provider)
    if type(provider) ~= "table" or provider.error == nil then return "" end
    if type(provider.error) == "string" then return provider.error end
    if type(provider.error) == "table" then
        return tostring(provider.error.message or provider.error.description or provider.error.kind or "Provider unavailable")
    end
    return "Provider unavailable"
end

local function parseIso(value)
    if type(value) ~= "string" then return nil end
    local y, mo, d, h, mi, s = value:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
    if y == nil then return nil end

    local localGuess = os.time({
        year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
    })
    local utcAsLocal = os.time(os.date("!*t", localGuess))
    return localGuess + (localGuess - utcAsLocal)
end

local function windowLabel(window, fallback)
    if type(window) ~= "table" then return fallback or "Usage window" end
    local named = window.title or window.name or window.label
    if named ~= nil and tostring(named) ~= "" then return tostring(named) end
    local minutes = tonumber(window.windowMinutes) or 0
    if minutes == 300 then return "5-hour session" end
    if minutes == 1440 then return "24-hour window" end
    if minutes == 10080 then return "Weekly window" end
    if minutes == 43200 then return "30-day window" end
    if minutes >= 1440 then return string.format("%d-day window", math.floor(minutes / 1440)) end
    if minutes >= 60 then return string.format("%d-hour window", math.floor(minutes / 60)) end
    if minutes > 0 then return string.format("%d-minute window", minutes) end
    return fallback or "Usage window"
end

local function remainingPercent(window)
    if type(window) ~= "table" or window.usedPercent == nil then return nil end
    local used = tonumber(window.usedPercent)
    if used == nil then return nil end
    return math.max(0, math.min(100, 100 - used))
end

local function percentText(value)
    if value == nil then return "—" end
    return string.format("%d%%", math.floor(value + 0.5))
end

local function relativeReset(window)
    if type(window) ~= "table" then return "Reset unavailable" end
    local epoch = parseIso(window.resetsAt)
    if epoch == nil then return window.resetDescription or "Reset unavailable" end

    local seconds = epoch - os.time()
    if seconds <= 0 then return "Resetting now" end
    local days = math.floor(seconds / 86400)
    local hours = math.floor((seconds % 86400) / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    if days > 0 then return string.format("in %dd %dh", days, hours) end
    if hours > 0 then return string.format("in %dh %dm", hours, minutes) end
    return string.format("in %dm", math.max(1, minutes))
end

local function resetAt(window)
    if type(window) ~= "table" then return "—" end
    local epoch = parseIso(window.resetsAt)
    if epoch ~= nil then return noctalia.formatTime("%a %I:%M %p", epoch) end
    return window.resetDescription or "—"
end

local function updatedAge(provider)
    local usage = type(provider) == "table" and provider.usage or nil
    local credits = type(provider) == "table" and provider.credits or nil
    local value = type(usage) == "table" and usage.updatedAt or nil
    if value == nil and type(credits) == "table" then value = credits.updatedAt end
    if value == nil and type(provider) == "table" then value = provider.updatedAt end

    local epoch = parseIso(value)
    if epoch == nil then return "not yet" end
    local seconds = math.max(0, os.time() - epoch)
    if seconds < 10 then return "just now" end
    if seconds < 60 then return string.format("%ds ago", seconds) end
    if seconds < 3600 then return string.format("%dm ago", math.floor(seconds / 60)) end
    return string.format("%dh ago", math.floor(seconds / 3600))
end

local function addWindow(windows, title, window, rank, color)
    if type(window) ~= "table" or tonumber(window.usedPercent) == nil then return end
    for _, item in ipairs(windows) do
        if item.window == window then return end
    end
    windows[#windows + 1] = {
        title = title or windowLabel(window),
        window = window,
        rank = rank or 99,
        color = color,
    }
end

local function windowsFor(provider)
    local result = {}
    local usage = type(provider) == "table" and provider.usage or nil
    if type(usage) ~= "table" then return result end
    local color = metaFor(provider, 1).color

    addWindow(result, windowLabel(usage.primary, "Session"), usage.primary, 1, color)
    addWindow(result, windowLabel(usage.secondary, "Weekly"), usage.secondary, 2, color)
    addWindow(result, windowLabel(usage.tertiary, "Monthly"), usage.tertiary, 3, color)

    if type(usage.extraRateWindows) == "table" then
        for index, extra in ipairs(usage.extraRateWindows) do
            if type(extra) == "table" then
                addWindow(result, extra.title or extra.name or "Additional window", extra.window or extra, 10 + index, "secondary")
            end
        end
    end

    if type(usage.windows) == "table" then
        for index, item in ipairs(usage.windows) do
            if type(item) == "table" then
                addWindow(result, item.title or item.name or "Usage window", item.window or item, 20 + index, color)
            end
        end
    end

    for key, value in pairs(usage) do
        if type(value) == "table" and tonumber(value.usedPercent) ~= nil then
            addWindow(result, windowLabel(value, titleFromId(key)), value, 40, color)
        end
    end

    table.sort(result, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.title < b.title
    end)
    return result
end

local function creditsFor(provider)
    if type(provider) ~= "table" then return nil end
    if type(provider.credits) == "table" then return provider.credits end
    if type(provider.usage) == "table" and type(provider.usage.credits) == "table" then
        return provider.usage.credits
    end
    return nil
end

local function paceFor(provider)
    local pace = type(provider) == "table" and provider.pace or nil
    if type(pace) ~= "table" then return nil end
    for _, key in ipairs({ "primary", "secondary", "tertiary" }) do
        if type(pace[key]) == "table" and pace[key].summary ~= nil then return pace[key] end
    end
    for _, value in pairs(pace) do
        if type(value) == "table" and value.summary ~= nil then return value end
    end
    return nil
end

local function paceColor(pace)
    if pace == nil then return "on_surface_variant" end
    local stage = string.lower(tostring(pace.stage or ""))
    local summary = string.lower(tostring(pace.summary or ""))
    if string.find(stage, "risk") or string.find(stage, "exhaust") or string.find(stage, "deficit") or string.find(summary, "deficit") then
        return "error"
    end
    if string.find(stage, "ahead") or string.find(stage, "reserve") or string.find(summary, "reserve") then
        return "secondary"
    end
    return "on_surface_variant"
end

local function windowRow(item)
    local window = item.window
    local remaining = remainingPercent(window) or 0
    local used = tonumber(window.usedPercent) or 0
    local color = item.color or "secondary"

    return ui.column({ key = item.title, gap = 5 }, {
        ui.row({ align = "center", justify = "space_between" }, {
            ui.row({ align = "center", gap = 7 }, {
                ui.glyph({ name = "chart-donut-3", size = 14, color = color }),
                ui.label({ text = item.title, fontSize = 13, fontWeight = "semibold", color = "on_surface", maxLines = 1 }),
            }),
            ui.label({ text = percentText(remaining) .. " left", fontSize = 13, fontWeight = "bold", color = color }),
        }),
        ui.progress({
            progress = remaining / 100,
            fill = color,
            track = "on_surface/0.14",
            radius = 8,
            height = 8,
        }),
        ui.row({ align = "center", justify = "space_between" }, {
            ui.label({ text = string.format("%d%% used", math.floor(used + 0.5)), fontSize = 11, color = "on_surface_variant" }),
            ui.label({ text = "Resets " .. relativeReset(window), fontSize = 11, color = "on_surface_variant" }),
        }),
    })
end

local function providerCard(provider, index)
    local meta = metaFor(provider, index)
    local windows = windowsFor(provider)
    local children = {}
    local source = tostring(provider.source or meta.source or "CodexBar")
    local account = providerAccount(provider)
    if account ~= "" then source = source .. " · " .. account end

    children[#children + 1] = ui.row({ align = "center", justify = "space_between" }, {
        ui.row({ align = "center", gap = 9 }, {
            ui.row({ align = "center", justify = "center", width = 34, height = 34, fill = meta.color .. "/0.16", radius = 10 }, {
                ui.glyph({ name = meta.glyph, size = 18, color = meta.color }),
            }),
            ui.column({ gap = 1 }, {
                ui.label({ text = providerLabel(provider, index), fontSize = 15, fontWeight = "semibold", color = "on_surface", maxLines = 1 }),
                ui.label({ text = source, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
            }),
        }),
        ui.label({ text = updatedAge(provider), fontSize = 11, color = "on_surface_variant" }),
    })

    children[#children + 1] = ui.separator({ spacing = 2, color = "outline", opacity = 0.18 })

    local issue = providerError(provider)
    if issue ~= "" then
        children[#children + 1] = ui.row({ fill = "error/0.10", radius = 9, padding = 10, align = "center", gap = 8 }, {
            ui.glyph({ name = "alert-circle", size = 14, color = "error" }),
            ui.label({ text = issue, fontSize = 12, color = "error", maxLines = 2 }),
        })
    end

    if #windows == 0 then
        children[#children + 1] = ui.row({ fill = "on_surface/0.05", radius = 9, padding = 10, align = "center", gap = 8 }, {
            ui.glyph({ name = "info-circle", size = 14, color = "on_surface_variant" }),
            ui.label({ text = "No active usage window reported", fontSize = 12, color = "on_surface_variant" }),
        })
    else
        for _, item in ipairs(windows) do children[#children + 1] = windowRow(item) end
    end

    local pace = paceFor(provider)
    if pace ~= nil and pace.summary ~= nil then
        local paceAccent = paceColor(pace)
        children[#children + 1] = ui.row({ fill = paceAccent .. "/0.10", radius = 8, paddingH = 9, paddingV = 6, align = "center", gap = 7 }, {
            ui.glyph({ name = "activity", size = 13, color = paceAccent }),
            ui.label({ text = tostring(pace.summary), fontSize = 11, color = paceAccent, maxLines = 2 }),
        })
    end

    local credits = creditsFor(provider)
    if credits ~= nil and credits.remaining ~= nil then
        children[#children + 1] = ui.row({ align = "center", justify = "space_between" }, {
            ui.row({ align = "center", gap = 7 }, {
                ui.glyph({ name = "coins", size = 14, color = "on_surface_variant" }),
                ui.label({ text = "Credits", fontSize = 12, color = "on_surface_variant" }),
            }),
            ui.label({ text = tostring(credits.remaining) .. " available", fontSize = 12, color = "on_surface" }),
        })
    end

    local status = provider.status
    if type(status) == "table" and status.description ~= nil and tostring(status.indicator or "none") ~= "none" then
        children[#children + 1] = ui.row({ fill = "on_surface/0.05", radius = 8, padding = 8, align = "center", gap = 7 }, {
            ui.glyph({ name = "info-circle", size = 13, color = "on_surface_variant" }),
            ui.label({ text = tostring(status.description), fontSize = 11, color = "on_surface_variant", maxLines = 2 }),
        })
    end

    if provider.stale == true then
        children[#children + 1] = ui.row({ fill = "tertiary/0.10", radius = 8, padding = 8, align = "center", gap = 7 }, {
            ui.glyph({ name = "clock", size = 13, color = "tertiary" }),
            ui.label({ text = "Showing cached provider data", fontSize = 11, color = "tertiary", maxLines = 2 }),
        })
    end

    return ui.column({ key = "provider-card-" .. tostring(index), fill = "surface_variant/0.58", radius = 14, padding = 11, gap = 8 }, children)
end

local function panelStatus()
    if errorMsg ~= "" then
        return #providers > 0 and "STALE" or "OFFLINE", "alert-circle", "error"
    end
    for _, provider in ipairs(providers) do
        if provider.stale == true then return "STALE", "clock", "tertiary" end
    end
    if #providers == 0 then return "WAITING", "loader-2", "on_surface_variant" end
    return "LIVE", "circle-filled", "primary"
end

local function render()
    if not panelOpen then return end

    local statusLabel, statusGlyph, statusColor = panelStatus()

    local header = ui.row({ align = "center", justify = "space_between" }, {
        ui.row({ align = "center", gap = 10 }, {
            ui.row({ align = "center", justify = "center", width = 36, height = 36, fill = "primary/0.15", radius = 11 }, {
                ui.glyph({ name = "chart-donut-3", size = 19, color = "primary" }),
            }),
            ui.column({ gap = 1 }, {
                ui.label({ text = "CodexBar Meter", fontSize = 17, fontWeight = "bold", color = "on_surface" }),
                ui.label({ text = "Enabled provider limits", fontSize = 11, color = "on_surface_variant" }),
            }),
        }),
        ui.row({ align = "center", gap = 2 }, {
            ui.button({ glyph = "refresh", variant = "ghost", tooltip = "Refresh now", onClick = "onRefresh" }),
            ui.button({ glyph = "x", variant = "ghost", tooltip = "Close", onClick = "onCloseClicked" }),
        }),
    })

    local children = { header }
    children[#children + 1] = ui.row({ align = "center", justify = "space_between", fill = statusColor .. "/0.08", radius = 8, paddingH = 9, paddingV = 6 }, {
        ui.row({ align = "center", gap = 6 }, {
            ui.glyph({ name = statusGlyph, size = 8, color = statusColor }),
            ui.label({ text = statusLabel, fontSize = 10, fontWeight = "bold", color = statusColor }),
        }),
        ui.label({ text = "Updates every " .. tostring(refreshIntervalSec) .. " seconds", fontSize = 11, color = "on_surface_variant" }),
    })
    children[#children + 1] = ui.separator({ spacing = 2, color = "outline", opacity = 0.20 })

    if errorMsg ~= "" and #providers > 0 then
        children[#children + 1] = ui.row({ fill = "error/0.10", radius = 8, padding = 8, align = "center", gap = 7 }, {
            ui.glyph({ name = "alert-circle", size = 13, color = "error" }),
            ui.label({ text = errorMsg .. " · showing last known data", fontSize = 11, color = "error", maxLines = 2 }),
        })
    end

    local content = {}
    if #providers == 0 then
        content[#content + 1] = ui.column({ align = "center", paddingV = 40, gap = 10 }, {
            ui.glyph({ name = errorMsg ~= "" and "alert-circle" or "loader-2", size = 28, color = errorMsg ~= "" and "error" or "primary" }),
            ui.label({ text = errorMsg ~= "" and errorMsg or "Waiting for CodexBar…", fontSize = 13, color = errorMsg ~= "" and "error" or "on_surface_variant" }),
        })
    else
        for index, provider in ipairs(providers) do
            content[#content + 1] = providerCard(provider, index)
        end
    end

    -- The root column and this scroll child both need flexGrow. This bounds
    -- arbitrary provider counts instead of allowing the panel to clip.
    children[#children + 1] = ui.scroll({ key = "usage-providers", flexGrow = 1, gap = 10 }, content)
    panel.render(ui.column({ flexGrow = 1, padding = 14, gap = 8 }, children))
end

noctalia.state.watch("providers", function(value)
    if type(value) == "table" then
        providers = value
        render()
    end
end)

noctalia.state.watch("error", function(value)
    if type(value) == "string" then
        errorMsg = value
        render()
    end
end)

function onOpen(_context)
    panelOpen = true
    local existing = noctalia.state.get("providers")
    if type(existing) == "table" then providers = existing end
    local existingError = noctalia.state.get("error")
    if type(existingError) == "string" then errorMsg = existingError end
    render()
end

function onClose()
    panelOpen = false
end

function onCloseClicked()
    panel.close()
end

function onRefresh()
    noctalia.state.set("command", { action = "refresh" })
end
