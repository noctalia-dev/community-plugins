-- Pure display policy. Values in the normalized model are always REMAINING.
local M = {}
M.defaults = {
    auto_refresh = true, refresh_on_open = false,
    bar_provider = "codex", bar_style = "full", bar_account_index = 1,
    bar_window = "first", bar_show_icon = true, panel_provider = "all",
    panel_density = "compact", accounts_per_page = 4, show_account_names = true,
    show_progress = true, show_reset_time = true, show_collection_time = false,
    warning_threshold = 20, percentage_mode = "remaining",
    initial_view = "quotas", usage_period = "today", history_granularity = "daily", details_per_page = 6,
    heatmap_weeks = "half", heatmap_metric = "tokens",
}
local choices = {
    bar_provider = { codex = true, deepseek = true, antigravity = true },
    bar_style = { full = true, value = true, icon = true },
    bar_window = { first = true, session = true, weekly = true, lowest = true },
    panel_provider = { all = true, codex = true, deepseek = true, antigravity = true },
    panel_density = { compact = true, comfortable = true },
    percentage_mode = { remaining = true, used = true },
    initial_view = { quotas = true, models = true, sessions = true, activity = true, trends = true },
    usage_period = { today = true, month = true, allTime = true },
    history_granularity = { daily = true, monthly = true },
    heatmap_weeks = { quarter = true, half = true },
    heatmap_metric = { tokens = true, cost = true, messages = true },
}
local ranges = { bar_account_index = { 1, 128 }, accounts_per_page = { 1, 8 }, warning_threshold = { 0, 100 }, details_per_page = { 2, 10 } }

function M.finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

function M.settings(read)
    local settings = {}
    for key, default in pairs(M.defaults) do
        local value = read(key)
        if choices[key] then
            settings[key] = choices[key][value] and value or default
        elseif ranges[key] then
            settings[key] = M.finite(value) and math.clamp(math.floor(value), ranges[key][1], ranges[key][2]) or default
        else
            if type(value) == "boolean" then settings[key] = value else settings[key] = default end
        end
    end
    return settings
end

function M.remaining(window)
    if window and window.metric == "percent" and M.finite(window.value) then
        return math.clamp(window.value, 0, 100)
    end
    return nil
end

function M.percentage(window, mode)
    local remaining = M.remaining(window)
    if remaining == nil then return nil end
    return mode == "used" and 100 - remaining or remaining
end

function M.low(window, threshold)
    local remaining = M.remaining(window)
    return remaining ~= nil and remaining <= threshold
end

function M.account(providers, providerId, index)
    local count, selected = 0, nil
    for _, provider in ipairs(providers) do
        if provider.provider == providerId then
            count = count + 1
            if count == index then selected = provider end
        end
    end
    return selected, count
end

function M.pinned(providers, key)
    if type(key) ~= "string" or key == "" then return nil end
    local found = nil
    for _, provider in ipairs(providers) do
        if provider.key == key then
            if found then return nil end -- duplicate identity is ambiguous
            found = provider
        end
    end
    return found
end

function M.window(provider, selection)
    if not provider then return nil end
    local windows = provider.windows or {}
    if selection == "first" then return windows[1] end
    local lowest, lowestValue = nil, math.huge
    for _, window in ipairs(windows) do
        if selection == "lowest" then
            local remaining = M.remaining(window)
            if remaining ~= nil and remaining < lowestValue then lowest, lowestValue = window, remaining end
        elseif window.kind == selection then
            return window
        end
    end
    return lowest
end

function M.filtered(providers, providerId, pinnedKey)
    local result = {}
    for index, provider in ipairs(providers) do
        if providerId == "all" or provider.provider == providerId then
            result[#result + 1] = { provider = provider, index = index }
        end
    end
    if pinnedKey and pinnedKey ~= "" then
        table.sort(result, function(a, b)
            local ap, bp = a.provider.key == pinnedKey, b.provider.key == pinnedKey
            if ap ~= bp then return ap end
            return a.index < b.index
        end)
    end
    return result
end

function M.pagination(count, requestedPage, pageSize)
    local pages = math.max(1, math.ceil(count / pageSize))
    local page = math.clamp(requestedPage, 1, pages)
    return page, pages, (page - 1) * pageSize + 1, math.min(page * pageSize, count)
end

function M.summary(filtered, threshold)
    local result = { accounts = #filtered, low = 0, stale = 0 }
    for _, item in ipairs(filtered) do
        if item.provider.stale then result.stale = result.stale + 1 end
        for _, window in ipairs(item.provider.windows or {}) do
            if M.low(window, threshold) then result.low = result.low + 1 end
        end
    end
    return result
end

function M.accountLabel(provider, showNames, fallback)
    if showNames and type(provider.accountLabel) == "string" and provider.accountLabel ~= "" then
        return provider.accountLabel
    end
    return fallback
end

return M
