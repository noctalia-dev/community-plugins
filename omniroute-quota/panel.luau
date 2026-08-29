local DATA_KEY = "omniroute_quota.data"
local STATUS_KEY = "omniroute_quota.status"
local ERROR_KEY = "omniroute_quota.error"
local SERVICE = "teagar/omniroute-quota:service"

local data = nil
local status = "loading"
local error_message = ""

local function dispatch_refresh()
    noctalia.runAsync("noctalia msg plugin '" .. SERVICE .. "' all refresh")
end

local function remaining_color(value)
    local remaining = tonumber(value) or 0
    if remaining <= 10 then return "error" end
    if remaining <= 30 then return "secondary" end
    return "primary"
end

local function reset_countdown(epoch)
    local target = tonumber(epoch)
    if not target then return noctalia.tr("panel.reset_unknown") end
    local seconds = math.max(0, target - os.time())
    if seconds == 0 then return noctalia.tr("panel.resetting") end
    local minutes = math.ceil(seconds / 60)
    local days = math.floor(minutes / 1440)
    local hours = math.floor((minutes % 1440) / 60)
    local mins = minutes % 60
    if days > 0 then
        return noctalia.tr("panel.resets_days", { days = days, hours = hours })
    end
    if hours > 0 then
        return noctalia.tr("panel.resets_hours", { hours = hours, minutes = mins })
    end
    return noctalia.tr("panel.resets_minutes", { minutes = mins })
end

local function compact_number(value)
    local amount = tonumber(value) or 0
    if amount >= 1000000 then return string.format("%.1fM", amount / 1000000) end
    if amount >= 1000 then return string.format("%.1fK", amount / 1000) end
    return tostring(math.floor(amount + 0.5))
end

local function quota_card(window)
    local remaining = tonumber(window.remainingPercent) or 0
    local color = remaining_color(remaining)
    return ui.column({ gap = 6, padding = 10, radius = 8, fill = "surface_variant/0.45", border = "outline/0.16", borderWidth = 1 }, {
        ui.row({ align = "center", gap = 8 }, {
            ui.label({ text = tostring(window.label or window.key), fontSize = 12, fontWeight = "semibold", color = "on_surface" }),
            ui.spacer({ flexGrow = 1 }),
            ui.label({ text = string.format("%d%% %s", math.floor(remaining + 0.5), noctalia.tr("panel.remaining")), fontSize = 13, fontWeight = "bold", color = color }),
        }),
        ui.progress({ progress = math.max(0, math.min(1, remaining / 100)), fill = color, track = "on_surface/0.14", radius = 3, height = 6 }),
        ui.row({ align = "center", gap = 5 }, {
            ui.glyph({ name = "clock", size = 12, color = "on_surface_variant" }),
            ui.label({ text = reset_countdown(window.resetEpoch), fontSize = 11, color = "on_surface_variant" }),
            ui.spacer({ flexGrow = 1 }),
            ui.label({ text = string.format("%d%% %s", math.floor((tonumber(window.usedPercent) or 0) + 0.5), noctalia.tr("panel.used")), fontSize = 10, color = "on_surface_variant" }),
        }),
    })
end

local function account_card(account)
    local children = {
        ui.row({ align = "center", gap = 8 }, {
            ui.glyph({ name = account.error and "alert-circle" or "brand-openai", size = 18, color = account.error and "error" or "primary" }),
            ui.column({ gap = 1, flexGrow = 1 }, {
                ui.label({ text = tostring(account.name or "Codex"), fontSize = 13, fontWeight = "bold", color = "on_surface", maxLines = 1 }),
                ui.label({ text = "Codex " .. tostring(account.plan or ""), fontSize = 10, color = "on_surface_variant" }),
            }),
            ui.label({ text = account.active and noctalia.tr("panel.active") or noctalia.tr("panel.inactive"), fontSize = 9, fontWeight = "semibold", color = account.active and "primary" or "on_surface_variant" }),
        }),
    }

    if account.error then
        children[#children + 1] = ui.label({ text = tostring(account.error), fontSize = 11, color = "error", maxLines = 3 })
    else
        for _, window in ipairs(account.windows or {}) do
            children[#children + 1] = quota_card(window)
        end
    end

    local usage = type(account.localUsage) == "table" and account.localUsage.week or {}
    local tokens = (tonumber(usage.inputTokens) or 0) + (tonumber(usage.outputTokens) or 0)
    children[#children + 1] = ui.separator({ opacity = 0.25 })
    children[#children + 1] = ui.row({ align = "center", gap = 6 }, {
        ui.label({ text = noctalia.tr("panel.local_usage"), fontSize = 10, color = "on_surface_variant" }),
        ui.spacer({ flexGrow = 1 }),
        ui.label({ text = tostring(usage.requests or 0) .. " req · " .. compact_number(tokens) .. " tokens", fontSize = 10, color = "on_surface" }),
    })

    return ui.column({ gap = 9, padding = 12, radius = 10, fill = "surface/0.72", border = "outline/0.18", borderWidth = 1 }, children)
end

function render()
    local rows = {
        ui.row({ align = "center", gap = 8 }, {
            ui.glyph({ name = "route", size = 22, color = "primary" }),
            ui.column({ gap = 0, flexGrow = 1 }, {
                ui.label({ text = noctalia.tr("panel.title"), fontSize = 17, fontWeight = "bold", color = "on_surface" }),
                ui.label({ text = status == "loading" and noctalia.tr("panel.refreshing") or noctalia.tr("panel.subtitle"), fontSize = 10, color = "on_surface_variant" }),
            }),
            ui.button({ glyph = status == "loading" and "loader-2" or "refresh", variant = "ghost", enabled = status ~= "loading", tooltip = noctalia.tr("panel.refresh"), onClick = dispatch_refresh }),
        }),
        ui.separator({}),
    }

    if error_message ~= "" then
        rows[#rows + 1] = ui.column({ gap = 6, padding = 10, radius = 8, fill = "error/0.12", border = "error", borderWidth = 1 }, {
            ui.label({ text = noctalia.tr("panel.error"), fontSize = 12, fontWeight = "bold", color = "error" }),
            ui.label({ text = error_message, fontSize = 10, color = "on_surface_variant", maxLines = 4 }),
        })
    end

    local cards = {}
    local accounts = type(data) == "table" and data.accounts or {}
    for _, account in ipairs(accounts or {}) do cards[#cards + 1] = account_card(account) end
    if #cards == 0 and status ~= "loading" then
        cards[1] = ui.label({ text = noctalia.tr("panel.no_accounts"), fontSize = 12, color = "on_surface_variant" })
    end
    rows[#rows + 1] = ui.scroll({ flexGrow = 1, gap = 10, align = "stretch" }, cards)

    panel.render(ui.column({ padding = 12, gap = 10, flexGrow = 1, align = "stretch" }, rows))
end

noctalia.state.watch(DATA_KEY, function(value) data = value render() end)
noctalia.state.watch(STATUS_KEY, function(value) status = tostring(value or "loading") render() end)
noctalia.state.watch(ERROR_KEY, function(value) error_message = tostring(value or "") render() end)

function onOpen(_context)
    panel.setWantsSecondTicks(true)
    dispatch_refresh()
    data = noctalia.state.get(DATA_KEY)
    status = tostring(noctalia.state.get(STATUS_KEY) or "loading")
    error_message = tostring(noctalia.state.get(ERROR_KEY) or "")
    render()
end

function update()
    render()
end

function onClose()
    panel.setWantsSecondTicks(false)
end

render()
