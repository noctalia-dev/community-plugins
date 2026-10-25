local view = require("./lib/view.luau")
local policy = require("./lib/presentation.luau")
local AnalyticsView = require("./lib/analytics_view.luau")
local ConnectionView = require("./lib/connection_view.luau")
local dashboard = view.dashboard(noctalia.state.get("dashboard"))
local settings = policy.settings(noctalia.getConfig)
local panelOpen, page, refreshCounter = false, 1, 0
local providerFilter = settings.panel_provider
local expandedAccount, expandedSession, expandedBucket = nil, nil, nil
local expandedModel, selectedDay = nil, nil
local pinned = noctalia.state.get("pinned_account") or { key = "", ready = false }
local activeView = settings.initial_view
local usagePeriod, historyMode, trendMetric = settings.usage_period, settings.history_granularity, "tokens"
local heatmapWeeks = settings.heatmap_weeks == "quarter" and 13 or 26
local heatmapMetric = settings.heatmap_metric
local visiblePages, pinCounter = 1, 0
local connectionOpen, connectionCounter = false, 0

-- The 580px manifest panel uses a single 480px content grid. Noctalia's
-- ScrollView adds 4px on each side and a 14px scrollbar gutter; reserve that
-- space even on short pages so every section keeps the same edges.
local GRID_WIDTH, VIEWPORT_WIDTH = 480, 502

local function label(text, color, size, weight)
    return ui.label({ text = text, color = color or "on_surface_variant", fontSize = size or 11,
        fontWeight = weight or "normal", baseline = "textFixedHeight", maxLines = 1 })
end

local function badge(text, color, glyph, width)
    return ui.row({ width = width, height = 24, gap = 4, paddingH = 8, radius = 8,
        fill = color .. "/0.10", align = "center", justify = "center" }, {
        ui.glyph({ name = glyph, size = 12, color = color }), label(text, color, 10, "semibold"),
    })
end

local function gridSection(child, key)
    return ui.column({ key = key, width = VIEWPORT_WIDTH, paddingH = 4, align = "start" }, {
        ui.column({ width = GRID_WIDTH }, { child }),
    })
end

local function valueCell(child)
    return ui.column({ width = 148, align = "end" }, { child })
end

local function quotaWindow(window, index)
    local low = policy.low(window, settings.warning_threshold)
    local color = low and "error" or "primary"
    local percentage = policy.percentage(window, settings.percentage_mode)
    local resetText = ""
    if settings.show_reset_time and window.resetsAt and window.resetsAt ~= "" then
        resetText = noctalia.tr("panel.resets", { time = view.reset(window.resetsAt) })
    end
    local rows = {
        ui.row({ align = "center", gap = 12, height = settings.panel_density == "compact" and 28 or 34 }, {
            ui.column({ flexGrow = 1 }, { label(view.windowLabel(window), "on_surface", 12, "semibold") }),
            valueCell(label(view.value(window, settings.percentage_mode), low and "error" or "on_surface",
                settings.panel_density == "compact" and 23 or 28, "bold")),
        }),
        ui.row({ align = "center", gap = 12, height = 16, tooltip = settings.show_reset_time and view.timestamp(window.resetsAt) or "" }, {
            ui.column({ flexGrow = 1 }, { label(resetText, nil, 10) }),
            valueCell(label(view.metricLabel(window, settings.percentage_mode), low and "error" or "on_surface_variant", 10)),
        }),
    }
    if settings.show_progress and window.showMeter ~= false and percentage ~= nil then
        rows[#rows + 1] = ui.progress({ progress = percentage / 100, fill = color,
            track = "on_surface/0.08", radius = 3, height = settings.panel_density == "compact" and 4 or 6 })
    end
    if low then
        rows[#rows + 1] = label(noctalia.tr("quota.low", { value = view.number(policy.remaining(window)) }), "error", 10)
    end
    if window.used ~= nil and window.limit ~= nil then
        rows[#rows + 1] = label(noctalia.tr("quota.used_of", { used = view.number(window.used), limit = view.number(window.limit) }), nil, 10)
    end
    if window.detail and window.detail ~= "" then
        rows[#rows + 1] = ui.label({ text = window.detail, color = "on_surface_variant", fontSize = 10, maxLines = 2 })
    end
    return ui.column({ key = "window-" .. tostring(index), gap = 4 }, rows)
end

local function accountCard(provider, index)
    local compact = settings.panel_density == "compact"
    local accountName = policy.accountLabel(provider, settings.show_account_names,
        noctalia.tr(settings.show_account_names and "common.unnamed_account" or "common.private_account", { index = index }))
    local statusColor = provider.status ~= "ok" and "error" or (provider.stale and "secondary" or "primary")
    local statusText = provider.status ~= "ok" and view.status(provider)
        or noctalia.tr(provider.stale and "common.stale" or "provider_status.ok")
    local rows = {
        ui.row({ align = "center", gap = 12, height = 36 }, {
            ui.row({ width = 36, height = 36, fill = "primary/0.10", radius = 8, align = "center", justify = "center" }, {
                view.providerIcon(provider.provider, 20, "primary", provider.adapterId),
            }),
            ui.column({ gap = 4, flexGrow = 1 }, {
                label(provider.name, "on_surface", 14, "bold"), label(accountName, nil, 11),
            }),
            badge(statusText, statusColor, provider.status ~= "ok" and "alert-circle" or (provider.stale and "history" or "check"), 112),
            ui.button({ width = 28, height = 28, glyph = pinned.key ~= "" and provider.key == pinned.key and "pinned-filled" or "pin",
                variant = "ghost", controlSize = "sm", selected = pinned.key ~= "" and provider.key == pinned.key,
                enabled = provider.key ~= nil and provider.key ~= "" and pinned.ready, tooltip = noctalia.tr("pin.toggle"),
                onClick = function() onPinAccount(tostring(index)) end }),
        }),
    }
    -- A provider error and a stale timestamp remain independent of quota exhaustion.
    if provider.stale and provider.status ~= "ok" then
        rows[#rows + 1] = label(noctalia.tr("common.stale"), "secondary", 10)
    end
    local windows = provider.windows or {}
    local identity = provider.key ~= "" and provider.key or tostring(index)
    local limit = expandedAccount == identity and #windows or (compact and 2 or 3)
    local hasDetails = provider.balance ~= nil or provider.resetCredits ~= nil or provider.planLabel ~= nil and provider.planLabel ~= ""
    if #windows == 0 then
        rows[#rows + 1] = label(noctalia.tr("panel.no_windows"), nil, 12)
    else
        rows[#rows + 1] = ui.separator({ color = "on_surface/0.08" })
        for windowIndex = 1, math.min(limit, #windows) do
            if windowIndex > 1 then rows[#rows + 1] = ui.separator({ color = "on_surface/0.06" }) end
            rows[#rows + 1] = quotaWindow(windows[windowIndex], windowIndex)
        end
    end
    if expandedAccount == identity and hasDetails then
        local function detail(name, value)
            rows[#rows + 1] = ui.row({ align = "center", gap = 12 }, {
                ui.column({ flexGrow = 1 }, { label(noctalia.tr("balance." .. view.fieldKey(name)), nil, 11) }),
                valueCell(label(tostring(value), "on_surface", 11)),
            })
        end
        if provider.planLabel and provider.planLabel ~= "" then detail("plan", provider.planLabel) end
        local balance = provider.balance
        if balance then
            for _, key in ipairs({ "amount", "todaySpend", "weekSpend", "monthSpend", "allTimeSpend", "giftBalance", "cashBalance", "planUsed", "planLimit" }) do
                if balance[key] ~= nil then detail(key, view.number(balance[key]) .. ((key == "planUsed" or key == "planLimit") and "" or (" " .. (balance.currency or "")))) end
            end
            if balance.requestCount ~= nil then detail("requestCount", view.number(balance.requestCount)) end
            if balance.planPercent ~= nil then detail("planPercent", view.number(balance.planPercent) .. "%") end
            if balance.planStatus and balance.planStatus ~= "" then detail("planStatus", balance.planStatus) end
            if balance.expiresAt and balance.expiresAt ~= "" then detail("expiresAt", view.timestamp(balance.expiresAt)) end
            if balance.monthSinceTracking then rows[#rows + 1] = label(noctalia.tr("balance.partial_month"), "secondary", 10) end
        end
        if provider.resetCredits and provider.resetCredits.nextExpiresAt and provider.resetCredits.nextExpiresAt ~= "" then
            detail("credits_expire", view.timestamp(provider.resetCredits.nextExpiresAt))
        end
    end
    if #windows > (compact and 2 or 3) or hasDetails then
        rows[#rows + 1] = ui.button({ text = noctalia.tr(hasDetails and (expandedAccount == identity and "actions.less_details" or "actions.more_details") or (expandedAccount == identity and "actions.less_windows" or "actions.more_windows"), { count = #windows }),
            glyph = expandedAccount == identity and "chevron-up" or "chevron-down", variant = "ghost", controlSize = "sm",
            onClick = function() onExpandAccount(tostring(index)) end })
    end
    if provider.stale or settings.show_collection_time then
        rows[#rows + 1] = ui.row({ tooltip = view.timestamp(provider.updatedAt), align = "center" }, {
            label(noctalia.tr("panel.collected", { time = view.age(provider.updatedAt) }), provider.stale and "secondary" or "on_surface_variant", 10),
        })
    end
    if provider.resetCredits and provider.resetCredits.availableCount ~= nil then
        rows[#rows + 1] = label(noctalia.tr("quota.reset_credits", { count = provider.resetCredits.availableCount }), nil, 10)
    end
    return ui.column({ key = "account-" .. tostring(index), width = GRID_WIDTH,
        fill = "surface_variant/0.25", border = "on_surface/0.06",
        borderWidth = 1, radius = 12, padding = 16, gap = compact and 8 or 12 }, rows)
end

local function choicesRow(options, selected, width, navigation)
    width = width or GRID_WIDTH
    local children = {}
    local itemWidth = (width - (#options - 1) * 4) / #options
    for _, item in ipairs(options) do
        local active = selected == item[1]
        children[#children + 1] = ui.column({ key = "choice-" .. item[1], width = itemWidth,
            fill = active and "primary/0.08" or "on_surface/0", radius = 7, gap = 2 }, {
            ui.button({ key = "button-" .. item[1], width = itemWidth, height = navigation and 34 or 28, text = item[2],
                variant = "ghost", contentAlign = "center", fontSize = 11,
                controlSize = "sm", onClick = item[3] }),
            ui.box({ height = navigation and 2 or 0, fill = active and "primary" or "on_surface/0", radius = 1 }),
        })
    end
    return ui.row({ width = width, gap = 4, align = "center" }, children)
end

local function render()
    if not panelOpen then return end
    local providers = dashboard.providers or {}
    local filtered = policy.filtered(providers, providerFilter, pinned.key)
    local statusKey = dashboard.status == "ready" and "ready" or (dashboard.status == "error" and "error" or "loading")
    local children = {
        gridSection(ui.row({ align = "center", gap = 8, height = 48 }, {
            ui.column({ flexGrow = 1, gap = 4 }, {
                label(noctalia.tr("app.title"), "on_surface", 22, "bold"),
                label(noctalia.tr("app.subtitle"), "on_surface_variant", 10),
            }),
            ui.button({ key = "connection", width = 32, height = 32, glyph = "plug-connected", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("connection.open"), onClick = "onConnection" }),
            ui.button({ key = "settings", width = 32, height = 32, glyph = "settings", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("actions.settings"), onClick = "onSettings" }),
            ui.button({ key = "refresh", width = 32, height = 32, glyph = "refresh", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("actions.refresh"), onClick = "onRefresh" }),
            ui.button({ key = "close", width = 32, height = 32, glyph = "x", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("actions.close"), onClick = "onCloseClicked" }),
        }), "title-actions"),
    }
    if connectionOpen then
        children[#children + 1] = ui.column({ key = "connection-viewport", width = VIEWPORT_WIDTH, flexGrow = 1 }, {
            ui.scroll({ key = "connection-content", align = "start", gap = 12, flexGrow = 1 }, ConnectionView.render(dashboard, GRID_WIDTH)),
        })
        children[#children + 1] = gridSection(ConnectionView.actions(dashboard, GRID_WIDTH), "connection-controls")
        panel.render(ui.column({ padding = 16, gap = 10, align = "center", flexGrow = 1 }, children))
        return
    end
    children[#children + 1] = gridSection(choicesRow({
            { "quotas", noctalia.tr("tabs.quotas"), "onViewQuotas" },
            { "models", noctalia.tr("tabs.models"), "onViewModels" },
            { "sessions", noctalia.tr("tabs.sessions"), "onViewSessions" },
            { "activity", noctalia.tr("tabs.activity"), "onViewActivity" },
            { "trends", noctalia.tr("tabs.trends"), "onViewTrends" },
        }, activeView, GRID_WIDTH, true), "view-tabs")
    if dashboard.status == "error" then
        children[#children + 1] = gridSection(ui.label({ text = view.error(dashboard.error), color = "error", fontSize = 11, maxLines = 2 }), "hub-warning")
    end
    if dashboard.cacheWarning then children[#children + 1] = gridSection(label(noctalia.tr("common.cache_warning"), "secondary", 10), "cache-warning") end
    if pinned.error == "write_failed" or pinned.error == "cache_invalid" then
        children[#children + 1] = gridSection(label(noctalia.tr("pin.save_error"), "secondary", 10), "pin-warning")
    end
    local cards = {}
    if activeView == "quotas" then
        local summary = policy.summary(filtered, settings.warning_threshold)
        local metrics = {}
        for _, metric in ipairs({ { "accounts", summary.accounts, "on_surface" },
            { "low_windows", summary.low, summary.low > 0 and "error" or "on_surface" },
            { "stale_accounts", summary.stale, summary.stale > 0 and "secondary" or "on_surface" } }) do
            metrics[#metrics + 1] = ui.column({ width = 152, gap = 4, paddingV = 8 }, {
                label(tostring(metric[2]), metric[3], 24, "bold"), label(noctalia.tr("panel." .. metric[1]), nil, 10),
            })
        end
        children[#children + 1] = gridSection(ui.row({ gap = 12 }, metrics), "quota-summary")
        local filters = {
            { "all", noctalia.tr("panel.all"), "onProviderAll" }, { "codex", "Codex", "onProviderCodex" },
            { "deepseek", "DeepSeek", "onProviderDeepseek" }, { "antigravity", "Antigravity", "onProviderAntigravity" },
        }
        for _, item in ipairs(filters) do item[2] = item[2] .. "  " .. tostring(#policy.filtered(providers, item[1])) end
        children[#children + 1] = gridSection(choicesRow(filters, providerFilter), "provider-filter")
        local first, last
        page, visiblePages, first, last = policy.pagination(#filtered, page, settings.accounts_per_page)
        if #filtered == 0 then
            local emptyKey = dashboard.status == "loading" and "waiting" or (dashboard.status == "error" and "unavailable" or (#providers > 0 and "filtered_empty" or "empty"))
            cards[1] = ui.column({ width = GRID_WIDTH, align = "center", gap = 16, paddingV = 48 }, {
                ui.glyph({ name = dashboard.status == "loading" and "loader-2" or "chart-donut-3", size = 36, color = "primary" }),
                label(noctalia.tr("panel." .. emptyKey), nil, 12),
            })
        else
            for index = first, last do cards[#cards + 1] = accountCard(filtered[index].provider, filtered[index].index) end
        end
        if pinned.key ~= "" and not policy.pinned(providers, pinned.key) then
            table.insert(cards, 1, ui.column({ width = GRID_WIDTH, gap = 8, padding = 12, fill = "secondary/0.08", radius = 8 }, {
                label(noctalia.tr("pin.missing"), "secondary", 11),
                ui.button({ text = noctalia.tr("pin.clear"), variant = "ghost", controlSize = "sm", onClick = "onClearPin" }),
            }))
        end
    else
        if activeView == "models" or activeView == "sessions" then
            local periods = {
                { "today", noctalia.tr("period.today"), "onPeriodToday" },
                { "month", noctalia.tr("period.month"), "onPeriodMonth" },
            }
            if activeView == "models" then periods[#periods + 1] = { "allTime", noctalia.tr("period.all_time"), "onPeriodAllTime" } end
            children[#children + 1] = gridSection(choicesRow(periods, usagePeriod), "usage-period")
        elseif activeView == "activity" then
            children[#children + 1] = gridSection(ui.row({ width = GRID_WIDTH, gap = 12 }, {
                choicesRow({
                    { "tokens", noctalia.tr("period.tokens"), "onHeatmapTokens" },
                    { "cost", noctalia.tr("period.cost"), "onHeatmapCost" },
                    { "messages", noctalia.tr("analytics.messages"), "onHeatmapMessages" },
                }, heatmapMetric, 300),
                choicesRow({
                    { "13", noctalia.tr("heatmap.weeks_13"), "onHeatmap13Weeks" },
                    { "26", noctalia.tr("heatmap.weeks_26"), "onHeatmap26Weeks" },
                }, tostring(heatmapWeeks), 168),
            }), "heatmap-controls")
        else
            children[#children + 1] = gridSection(ui.row({ width = GRID_WIDTH, gap = 12 }, {
                choicesRow({
                { "daily", noctalia.tr("period.daily"), "onHistoryDaily" },
                { "monthly", noctalia.tr("period.monthly"), "onHistoryMonthly" },
                }, historyMode, 234),
                choicesRow({
                    { "tokens", noctalia.tr("period.tokens"), "onTrendTokens" },
                    { "cost", noctalia.tr("period.cost"), "onTrendCost" },
                }, trendMetric, 234),
            }), "trend-controls")
        end
        local content = AnalyticsView.render(activeView, dashboard, {
            width = GRID_WIDTH, page = page, pageSize = settings.details_per_page,
            period = usagePeriod, historyMode = historyMode, trendMetric = trendMetric,
            showNames = settings.show_account_names, density = settings.panel_density,
            expandedSession = expandedSession, onExpandSession = onExpandSession,
            expandedBucket = expandedBucket, onExpandBucket = onExpandBucket,
            expandedModel = expandedModel, onExpandModel = onExpandModel,
            heatmapWeeks = heatmapWeeks, heatmapMetric = heatmapMetric, today = os.date("%Y-%m-%d"),
            selectedDay = selectedDay, onSelectDay = onSelectDay,
            onHistoryDaily = onHistoryDaily, onHistoryMonthly = onHistoryMonthly,
        })
        cards, page, visiblePages = content.children, content.page, content.pages
    end
    -- Keep persistent controls under semantic keys. Replacing an ancestor
    -- remounts native Ghost buttons and restarts their default-fill animation.
    -- Index keys would also remount filters when an error banner is inserted.
    children[#children + 1] = ui.column({ key = "content-viewport", width = VIEWPORT_WIDTH, flexGrow = 1 }, {
        ui.scroll({ key = "content-" .. activeView .. "-" .. providerFilter .. "-" .. usagePeriod .. "-" .. historyMode .. "-" .. tostring(page),
            align = "start", flexGrow = 1, gap = 10 }, cards),
    })
    if visiblePages > 1 then
        children[#children + 1] = gridSection(ui.row({ align = "center", justify = "space_between", gap = 8 }, {
            ui.button({ width = 32, height = 32, glyph = "chevron-left", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("actions.previous"), enabled = page > 1, onClick = "onPrevious" }),
            label(noctalia.tr("panel.page", { page = page, pages = visiblePages }), nil, 10),
            ui.button({ width = 32, height = 32, glyph = "chevron-right", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("actions.next"), enabled = page < visiblePages, onClick = "onNext" }),
        }), "pagination")
    end
    local receipt = activeView == "activity" or activeView == "trends"
    local lastSuccess = receipt and dashboard.history and dashboard.history.lastSuccess or dashboard.lastSuccess
    local freshness = dashboard.analytics and dashboard.analytics.freshness
    local footer = {
        ui.row({ align = "center", gap = 6, tooltip = noctalia.tr("dashboard_status." .. statusKey) .. " · " .. noctalia.tr("panel.read_only") }, {
            ui.box({ width = 5, height = 5, radius = 3, fill = statusKey == "error" and "error" or "primary" }),
            label(noctalia.tr("panel.received", { time = view.received(lastSuccess) }), nil, 10),
            ui.spacer({ flexGrow = 1 }),
            label(dashboard.cached and noctalia.tr("common.cached") or "", "secondary", 10),
        }),
    }
    if activeView ~= "quotas" and freshness and freshness.available and freshness.sourceCount > 0 then
        footer[#footer + 1] = label(noctalia.tr("panel.source_age", {
            count = freshness.sourceCount, stale = freshness.staleCount, age = view.age(freshness.oldestUpdatedAt),
        }), freshness.staleCount > 0 and "secondary" or "on_surface_variant", 10)
    end
    children[#children + 1] = gridSection(ui.column({ gap = 4, paddingV = 4 }, footer), "receipt")
    panel.render(ui.column({ padding = 16, gap = 10, align = "center", flexGrow = 1 }, children))
end

noctalia.state.watch("dashboard", function(value)
    dashboard = view.dashboard(value)
    render()
end)

function onRefresh()
    refreshCounter = refreshCounter + 1
    noctalia.state.set("refresh_requested", tostring(os.time()) .. ":panel:" .. tostring(refreshCounter))
end

noctalia.state.watch("pinned_account", function(value)
    pinned = value or { key = "", ready = false }
    render()
end)

function onOpen(_context)
    settings = policy.settings(noctalia.getConfig)
    dashboard = view.dashboard(noctalia.state.get("dashboard"))
    providerFilter, page, expandedAccount = settings.panel_provider, 1, nil
    activeView, usagePeriod, historyMode = settings.initial_view, settings.usage_period, settings.history_granularity
    expandedSession, expandedModel, expandedBucket, selectedDay = nil, nil, nil, nil
    heatmapWeeks, heatmapMetric = settings.heatmap_weeks == "quarter" and 13 or 26, settings.heatmap_metric
    connectionOpen = (dashboard.lastSuccess or 0) == 0
        and not (dashboard.history and (dashboard.history.lastSuccess or 0) > 0)
    panelOpen = true
    if settings.refresh_on_open then onRefresh() end
    render()
end

function onClose() panelOpen = false end
function onCloseClicked() panel.close() end
function onSettings() noctalia.openSettings() end
function onConnection() connectionOpen = true; render() end
function onConnectionBack()
    if (dashboard.lastSuccess or 0) > 0 or (dashboard.history and (dashboard.history.lastSuccess or 0) > 0) then
        connectionOpen = false
        render()
    end
end
function onTestConnection()
    connectionCounter += 1
    noctalia.state.set("connection_test_requested", tostring(os.time()) .. ":panel:" .. tostring(connectionCounter))
end

local function setProvider(value)
    providerFilter, page, expandedAccount = value, 1, nil
    render()
end
function onProviderAll() setProvider("all") end
function onProviderCodex() setProvider("codex") end
function onProviderDeepseek() setProvider("deepseek") end
function onProviderAntigravity() setProvider("antigravity") end
function onPrevious() page, expandedAccount = math.max(1, page - 1), nil; render() end
function onNext() page, expandedAccount = math.min(visiblePages, page + 1), nil; render() end
function onExpandAccount(value)
    local index = tonumber(value)
    if index and index >= 1 and index <= #(dashboard.providers or {}) then
        local provider = dashboard.providers[index]
        local identity = provider.key ~= "" and provider.key or tostring(index)
        expandedAccount = expandedAccount ~= identity and identity or nil
        render()
    end
end

local function setView(value)
    activeView, page, expandedSession, expandedBucket = value, 1, nil, nil
    render()
end
function onViewQuotas() setView("quotas") end
function onViewModels() setView("models") end
function onViewSessions() setView("sessions") end
function onViewActivity() setView("activity") end
function onViewTrends() setView("trends") end
local function setPeriod(value) usagePeriod, page, expandedSession = value, 1, nil; render() end
function onPeriodToday() setPeriod("today") end
function onPeriodMonth() setPeriod("month") end
function onPeriodAllTime() setPeriod("allTime") end
function onHistoryDaily() historyMode, page = "daily", 1; render() end
function onHistoryMonthly() historyMode, page = "monthly", 1; render() end
function onTrendTokens() trendMetric = "tokens"; render() end
function onTrendCost() trendMetric = "cost"; render() end
function onExpandSession(key) expandedSession = expandedSession ~= key and key or nil; render() end
function onExpandBucket(key) expandedBucket = expandedBucket ~= key and key or nil; render() end
function onExpandModel(key) expandedModel = expandedModel ~= key and key or nil; render() end
function onSelectDay(date) selectedDay, expandedBucket = date, "daily:" .. date; render() end
function onHeatmapTokens() heatmapMetric = "tokens"; render() end
function onHeatmapCost() heatmapMetric = "cost"; render() end
function onHeatmapMessages() heatmapMetric = "messages"; render() end
function onHeatmap13Weeks() heatmapWeeks, selectedDay, expandedBucket = 13, nil, nil; render() end
function onHeatmap26Weeks() heatmapWeeks, selectedDay, expandedBucket = 26, nil, nil; render() end

-- A small read-only navigation entry also allows opening a specific view.
function onIpc(event, payload)
    if event == "view" and ({ quotas = true, models = true, sessions = true, activity = true, trends = true })[payload] then
        connectionOpen = false
        setView(payload)
    elseif event == "connection" then onConnection() end
end
local function requestPin(key)
    pinCounter = pinCounter + 1
    noctalia.state.set("pin_requested", { key = key, scope = pinned.scope, nonce = pinCounter })
end
function onPinAccount(value)
    local index = tonumber(value)
    local account = index and (dashboard.providers or {})[index]
    if account and account.key and account.key ~= "" then requestPin(pinned.key == account.key and "" or account.key) end
end
function onClearPin() requestPin("") end

local lastMinute = -1
function update()
    local minute = math.floor(os.time() / 60)
    if panelOpen and minute ~= lastMinute then lastMinute = minute; render() end
end
panel.setWantsSecondTicks(true)
