local view = require("./lib/view.luau")
local policy = require("./lib/presentation.luau")
local dashboard = view.dashboard(noctalia.state.get("dashboard"))
local settings = policy.settings(noctalia.getConfig)
local pinned = noctalia.state.get("pinned_account") or { key = "", ready = false }
local refreshCounter = 0

local function render()
    local account, count = policy.account(dashboard.providers or {}, settings.bar_provider, settings.bar_account_index)
    if pinned.key and pinned.key ~= "" then
        account = policy.pinned(dashboard.providers or {}, pinned.key)
        if account then
            local _, matchedCount = policy.account(dashboard.providers or {}, account.provider, 1)
            count = matchedCount
        end
    end
    local quota = policy.window(account, settings.bar_window)
    local name = account and account.name or view.providerName(settings.bar_provider)
    local providerId = account and account.provider or settings.bar_provider
    local low = policy.low(quota, settings.warning_threshold)
    local failed = dashboard.status == "error" or (account ~= nil and account.status ~= "ok") or (pinned.key ~= "" and account == nil)
    local stale = dashboard.cached == true or dashboard.cacheWarning == true or (account ~= nil and account.stale == true)
    local color = (failed or low) and "error" or (stale and "secondary" or "primary")
    local children = {}
    if settings.bar_show_icon or settings.bar_style == "icon" then
        children[#children + 1] = view.providerIcon(providerId, 15, color, account and account.adapterId)
    end
    if settings.bar_style ~= "icon" then
        local text = view.quotaText(quota, settings.percentage_mode)
        if settings.bar_style == "full" then text = name .. " · " .. text end
        children[#children + 1] = ui.label({ text = text, maxLines = 1, color = (failed or low) and "error" or nil })
    end
    local marker = failed and "alert-circle" or (stale and "history" or (low and "alert-triangle" or nil))
    if marker then
        children[#children + 1] = ui.glyph({ name = marker, size = 12, color = color })
    elseif dashboard.status == "loading" then
        children[#children + 1] = ui.glyph({ name = "loader-2", size = 12, color = "on_surface_variant" })
    end
    local layout = barWidget.isVertical() and ui.column or ui.row
    barWidget.render(layout({ align = "center", gap = 6 }, children))
    local tooltip = { { key = noctalia.tr("app.title"), value = noctalia.tr("bar.scope") } }
    if account then
        local identity = policy.accountLabel(account, settings.show_account_names,
            noctalia.tr(settings.show_account_names and "common.unnamed_account" or "common.private_account", { index = settings.bar_account_index }))
        if not settings.show_account_names and pinned.key ~= "" then identity = noctalia.tr("pin.account") end
        tooltip[#tooltip + 1] = { key = name, value = identity }
        tooltip[#tooltip + 1] = { key = noctalia.tr("common.status"), value = view.status(account) }
        local windowLabel = quota and view.windowLabel(quota) or noctalia.tr("settings.bar_window.options." .. settings.bar_window)
        tooltip[#tooltip + 1] = { key = windowLabel, value = view.quotaText(quota, settings.percentage_mode) }
        if low then tooltip[#tooltip + 1] = { key = noctalia.tr("common.warning"), value = noctalia.tr("quota.low", { value = view.number(policy.remaining(quota)) }) } end
        if account.stale then tooltip[#tooltip + 1] = { key = noctalia.tr("common.data"), value = noctalia.tr("common.stale") .. " · " .. view.age(account.updatedAt) } end
        if settings.show_reset_time and quota and quota.resetsAt and quota.resetsAt ~= "" then
            tooltip[#tooltip + 1] = { key = noctalia.tr("common.resets"), value = view.reset(quota.resetsAt) .. " · " .. view.timestamp(quota.resetsAt) }
        end
        if settings.show_collection_time then
            tooltip[#tooltip + 1] = { key = noctalia.tr("common.collected"), value = view.timestamp(account.updatedAt) }
        end
    else
        tooltip[#tooltip + 1] = { key = name, value = pinned.key ~= "" and noctalia.tr("pin.missing") or noctalia.tr("bar.no_account", { index = settings.bar_account_index }) }
    end
    tooltip[#tooltip + 1] = { key = noctalia.tr("common.accounts"), value = tostring(count) }
    if dashboard.cached then tooltip[#tooltip + 1] = { key = noctalia.tr("common.data"), value = noctalia.tr("common.cached") } end
    if dashboard.status == "error" then tooltip[#tooltip + 1] = { key = noctalia.tr("common.error"), value = view.error(dashboard.error) } end
    if dashboard.cacheWarning then tooltip[#tooltip + 1] = { key = noctalia.tr("common.warning"), value = noctalia.tr("common.cache_warning") } end
    tooltip[#tooltip + 1] = { key = noctalia.tr("common.received"), value = view.received(dashboard.lastSuccess) }
    tooltip[#tooltip + 1] = { key = noctalia.tr("bar.actions"), value = noctalia.tr("bar.gestures") }
    barWidget.setTooltip(tooltip)
end

noctalia.state.watch("dashboard", function(value)
    dashboard = view.dashboard(value)
    render()
end)
noctalia.state.watch("pinned_account", function(value)
    pinned = value or { key = "", ready = false }
    render()
end)

function onClick() noctalia.togglePanel("shangshui0302/token-monitor:panel") end
function onRightClick()
    refreshCounter = refreshCounter + 1
    noctalia.state.set("refresh_requested", tostring(os.time()) .. ":bar:" .. tostring(refreshCounter))
end
function onConfigChanged()
    settings = policy.settings(noctalia.getConfig)
    render()
end
render()
