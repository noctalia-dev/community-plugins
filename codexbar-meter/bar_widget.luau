--!nonstrict
-- CodexBar provider usage bar widget.
--
-- CodexBar owns provider discovery, authentication, and quota fetching. This
-- widget only normalizes the shared JSON envelope and keeps the bar bounded:
-- the first configured providers are shown in the capsule, while the tooltip
-- and attached panel expose the complete response.

local codexbarPath = noctalia.getConfig("codexbarPath") or "codexbar"
local refreshIntervalSec = tonumber(noctalia.getConfig("refreshIntervalSec")) or 60
local barProviderLimit = tonumber(noctalia.getConfig("barProviderLimit")) or 2

local providers = {}
local errorMsg = ""
local requestInFlight = false

-- Noctalia v5 panel surfaces have fixed manifest dimensions. Keep the
-- regular `panel` id as the compatibility/default entry, then choose a
-- nearby fixed tier when opening so the surface follows the current data
-- without relying on an unsupported runtime resize API.
local PANEL_IDS = {
    compact = "salemsayed/codexbar-meter:panel-compact",
    standard = "salemsayed/codexbar-meter:panel",
    tall = "salemsayed/codexbar-meter:panel-tall",
}

local PROVIDER_META = {
    codex = { label = "Codex", glyph = "brand-openai", color = "primary" },
    openai = { label = "OpenAI", glyph = "brand-openai", color = "primary" },
    azureopenai = { label = "Azure OpenAI", glyph = "brand-openai", color = "primary" },
    claude = { label = "Claude", glyph = "message-chatbot", color = "tertiary" },
    gemini = { label = "Gemini", glyph = "brand-google", color = "secondary" },
    copilot = { label = "Copilot", glyph = "brand-github", color = "secondary" },
    cursor = { label = "Cursor", glyph = "cursor-text", color = "secondary" },
    opencode = { label = "OpenCode", glyph = "code", color = "secondary" },
    opencodego = { label = "OpenCode Go", glyph = "code", color = "secondary" },
    qwencloud = { label = "Qwen Cloud", glyph = "cloud", color = "secondary" },
    alibaba = { label = "Alibaba", glyph = "cloud", color = "secondary" },
    alibabatokenplan = { label = "Alibaba Token Plan", glyph = "cloud", color = "secondary" },
    antigravity = { label = "Antigravity", glyph = "sparkles", color = "tertiary" },
    kilo = { label = "Kilo", glyph = "robot", color = "secondary" },
    ollama = { label = "Ollama", glyph = "server", color = "secondary" },
    openrouter = { label = "OpenRouter", glyph = "route", color = "secondary" },
}

local FALLBACK_COLORS = { "secondary", "tertiary", "primary" }

local function shellQuote(value)
    return "'" .. string.gsub(tostring(value), "'", "'\\''") .. "'"
end

local function commandPath()
    local path = tostring(codexbarPath)
    if string.sub(path, 1, 1) == "~" then
        path = noctalia.expandPath(path)
    end
    return path
end

local function providerId(provider)
    return tostring(provider and (provider.provider or provider.id) or "unknown")
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

local function titleFromId(value)
    local text = string.gsub(tostring(value or "unknown"), "[_%-]+", " ")
    text = string.gsub(text, "(%a)([%w]*)", function(first, rest)
        return string.upper(first) .. string.lower(rest)
    end)
    return text
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
    }
end

local function providerLabel(provider, index)
    local meta = metaFor(provider, index)
    local account = providerAccount(provider)
    if account ~= "" then
        return meta.label .. " · " .. account
    end
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

local function windowLabel(window, fallback)
    if type(window) ~= "table" then return fallback or "Limit" end
    local named = window.title or window.name or window.label
    if named ~= nil and tostring(named) ~= "" then return tostring(named) end
    local minutes = tonumber(window.windowMinutes) or 0
    if minutes == 300 then return "5h" end
    if minutes == 1440 then return "24h" end
    if minutes == 10080 then return "7d" end
    if minutes == 43200 then return "30d" end
    if minutes >= 1440 then return string.format("%dd", math.floor(minutes / 1440)) end
    if minutes >= 60 then return string.format("%dh", math.floor(minutes / 60)) end
    if minutes > 0 then return string.format("%dm", minutes) end
    return fallback or "limit"
end

local function remainingPercent(window)
    if type(window) ~= "table" or window.usedPercent == nil then return nil end
    local used = tonumber(window.usedPercent)
    if used == nil then return nil end
    return math.max(0, math.min(100, 100 - used))
end

local function addWindow(windows, title, window, rank)
    if type(window) ~= "table" or tonumber(window.usedPercent) == nil then return end
    for _, item in ipairs(windows) do
        if item.window == window then return end
    end
    windows[#windows + 1] = {
        title = title or windowLabel(window),
        window = window,
        rank = rank or 99,
    }
end

local function windowsFor(provider)
    local result = {}
    local usage = type(provider) == "table" and provider.usage or nil
    if type(usage) ~= "table" then return result end

    addWindow(result, windowLabel(usage.primary, "Session"), usage.primary, 1)
    addWindow(result, windowLabel(usage.secondary, "Weekly"), usage.secondary, 2)
    addWindow(result, windowLabel(usage.tertiary, "Monthly"), usage.tertiary, 3)

    if type(usage.extraRateWindows) == "table" then
        for index, extra in ipairs(usage.extraRateWindows) do
            if type(extra) == "table" then
                addWindow(result, extra.title or extra.name or "Additional window", extra.window or extra, 10 + index)
            end
        end
    end

    if type(usage.windows) == "table" then
        for index, item in ipairs(usage.windows) do
            if type(item) == "table" then
                addWindow(result, item.title or item.name or "Usage window", item.window or item, 20 + index)
            end
        end
    end

    -- Future providers may add another named rate window. Pick up any table
    -- that carries the standard usedPercent field without treating identity,
    -- status, or provider-specific metadata as a quota row.
    for key, value in pairs(usage) do
        if type(value) == "table" and tonumber(value.usedPercent) ~= nil then
            addWindow(result, windowLabel(value, titleFromId(key)), value, 40)
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

local function summaryFor(provider)
    local windows = windowsFor(provider)
    if #windows > 0 then
        local window = windows[1].window
        return {
            window = window,
            label = windows[1].title .. " " .. string.format("%d%%", math.floor((remainingPercent(window) or 0) + 0.5)),
            remaining = remainingPercent(window),
        }
    end

    local credits = creditsFor(provider)
    if credits ~= nil and credits.remaining ~= nil then
        local creditPercent = tonumber(credits.remainingPercent)
        return {
            label = tostring(credits.remaining),
            remaining = creditPercent,
            credits = true,
        }
    end
    return { label = "—", remaining = nil }
end

local function providerByIndex(index)
    return providers[index]
end

local function selectedEntries()
    local entries = {}
    local healthy = {}
    for index, provider in ipairs(providers) do
        local entry = { provider = provider, index = index, summary = summaryFor(provider) }
        entries[#entries + 1] = entry
        if providerError(provider) == "" then healthy[#healthy + 1] = entry end
    end

    local pool = #healthy > 0 and healthy or entries
    local limit = math.max(1, math.min(4, math.floor(barProviderLimit)))
    local selected = {}
    for index = 1, math.min(limit, #pool) do
        selected[#selected + 1] = pool[index]
    end
    return selected
end

local function percentText(value)
    if value == nil then return "—" end
    return string.format("%d%%", math.floor(value + 0.5))
end

local function providerSegment(entry)
    local provider = entry.provider
    local meta = metaFor(provider, entry.index)
    local summary = entry.summary
    local children = {
        ui.glyph({ name = meta.glyph, size = 13, color = meta.color }),
    }

    if summary.window ~= nil then
        children[#children + 1] = ui.progress({
            progress = (summary.remaining or 0) / 100,
            fill = meta.color,
            track = "on_surface/0.16",
            radius = 6,
            width = 26,
            height = 5,
        })
    end

    children[#children + 1] = ui.label({
        text = summary.window ~= nil and (windowLabel(summary.window) .. " " .. percentText(summary.remaining)) or summary.label,
        fontSize = 11,
        fontWeight = "semibold",
        color = "on_surface",
        maxLines = 1,
    })

    return ui.row({ key = "provider-" .. tostring(entry.index), align = "center", gap = 5 }, children)
end

local function tooltipFor(provider, index)
    local meta = metaFor(provider, index)
    local issue = providerError(provider)
    if issue ~= "" then
        return { key = providerLabel(provider, index), value = "Unavailable · " .. issue }
    end

    local windows = windowsFor(provider)
    local lines = {}
    for _, item in ipairs(windows) do
        lines[#lines + 1] = item.title .. ": " .. percentText(remainingPercent(item.window)) .. " left"
    end

    local credits = creditsFor(provider)
    if credits ~= nil and credits.remaining ~= nil then
        lines[#lines + 1] = "Credits: " .. tostring(credits.remaining)
    end
    if #lines == 0 then lines[#lines + 1] = "No usage window reported" end
    if provider.stale == true then lines[#lines + 1] = "Showing last known data" end

    return { key = meta.label, value = table.concat(lines, "\n") }
end

local function hasProviderErrors()
    for _, provider in ipairs(providers) do
        if providerError(provider) ~= "" then return true end
    end
    return false
end

local function hasProviderStatus(provider)
    local status = type(provider) == "table" and provider.status or nil
    return type(status) == "table"
        and status.description ~= nil
        and tostring(status.indicator or "none") ~= "none"
end

local function hasPaceSummary(provider)
    local pace = type(provider) == "table" and provider.pace or nil
    if type(pace) ~= "table" then return false end
    for _, key in ipairs({ "primary", "secondary", "tertiary" }) do
        if type(pace[key]) == "table" and pace[key].summary ~= nil then return true end
    end
    for _, value in pairs(pace) do
        if type(value) == "table" and value.summary ~= nil then return true end
    end
    return false
end

local function estimatedProviderHeight(provider)
    -- Approximate the panel card from semantic content, not provider names.
    -- This deliberately errs upward; the scroll view remains the safety net
    -- for providers with unusually verbose or future-specific payloads.
    local height = 104
    height = height + (#windowsFor(provider) * 82)
    if providerError(provider) ~= "" then height = height + 44 end
    if hasPaceSummary(provider) then height = height + 34 end
    if provider.stale == true then height = height + 34 end

    local credits = creditsFor(provider)
    if credits ~= nil and credits.remaining ~= nil then height = height + 30 end
    if hasProviderStatus(provider) then height = height + 34 end
    return height
end

local function panelEntryIdForCurrentData()
    if #providers == 0 then return PANEL_IDS.compact end

    local estimate = 130
    for index, provider in ipairs(providers) do
        estimate = estimate + estimatedProviderHeight(provider)
        if index > 1 then estimate = estimate + 10 end
    end

    if estimate <= 420 then return PANEL_IDS.compact end
    if estimate <= 600 then return PANEL_IDS.standard end
    return PANEL_IDS.tall
end

local function render()
    local selected = selectedEntries()
    local rows = {}

    if #selected == 0 then
        rows[#rows + 1] = ui.row({ align = "center", gap = 5 }, {
            ui.glyph({ name = "chart-donut-3", size = 13, color = "primary" }),
            ui.label({ text = "AI —", fontSize = 11, fontWeight = "semibold", color = "on_surface" }),
        })
    else
        for index, entry in ipairs(selected) do
            if index > 1 then
                rows[#rows + 1] = ui.box({ width = 1, height = 15, fill = "outline/0.35" })
            end
            rows[#rows + 1] = providerSegment(entry)
        end
        if #providers > #selected then
            rows[#rows + 1] = ui.label({
                text = "+" .. tostring(#providers - #selected),
                fontSize = 10,
                color = "on_surface_variant",
            })
        end
    end

    if errorMsg ~= "" or hasProviderErrors() then
        rows[#rows + 1] = ui.glyph({ name = "alert-circle", size = 12, color = "error" })
    end

    barWidget.render(ui.row({ gap = 7, align = "center" }, rows))

    local tooltip = {}
    for index, provider in ipairs(providers) do
        tooltip[#tooltip + 1] = tooltipFor(provider, index)
    end
    if #tooltip == 0 then
        tooltip[#tooltip + 1] = { key = "CodexBar", value = "Waiting for provider data" }
    end
    if errorMsg ~= "" then
        tooltip[#tooltip + 1] = { key = "Status", value = errorMsg }
    end
    barWidget.setTooltip(tooltip)
end

local function decodeProviders(stdout)
    local decoded = noctalia.json.decode(stdout or "")
    if type(decoded) ~= "table" then return nil end
    if type(decoded.providers) == "table" then return decoded.providers end
    if decoded.provider ~= nil or decoded.error ~= nil then return { decoded } end

    local result = {}
    for _, provider in ipairs(decoded) do
        if type(provider) == "table" then result[#result + 1] = provider end
    end
    return result
end

local function refresh()
    if requestInFlight then return end
    requestInFlight = true

    local command = "timeout 30s " .. shellQuote(commandPath())
        .. " usage --format json --json-only"

    noctalia.runAsync(command, function(result)
        requestInFlight = false
        local decoded = result ~= nil and decodeProviders(result.stdout) or nil

        -- CodexBar may return a non-zero exit code for a partial provider
        -- response. Keep healthy rows and let each errored row explain itself.
        if decoded ~= nil and #decoded > 0 then
            providers = decoded
            errorMsg = ""
            noctalia.state.set("providers", providers)
            noctalia.state.set("error", "")
            noctalia.state.set("lastRefresh", os.time())
            render()
            return
        end

        errorMsg = result ~= nil and result.exitCode ~= 0
            and "CodexBar could not refresh"
            or "CodexBar returned no provider data"
        noctalia.state.set("error", errorMsg)
        render()
    end, 30000)
end

noctalia.state.watch("command", function(value)
    if type(value) == "table" and value.action == "refresh" then refresh() end
end)

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

function update()
    noctalia.setUpdateInterval(refreshIntervalSec * 1000)
    refresh()
end

function onClick()
    noctalia.togglePanel(panelEntryIdForCurrentData())
end

function onRightClick()
    refresh()
end

function onIpc(event, _payload)
    if event == "refresh" then refresh() end
end

local existing = noctalia.state.get("providers")
if type(existing) == "table" then providers = existing end
local existingError = noctalia.state.get("error")
if type(existingError) == "string" then errorMsg = existingError end

noctalia.setUpdateInterval(refreshIntervalSec * 1000)
render()
refresh()
