-- Read-only Hub detail views. Paging bounds materialized native UI children.
local view = require("./view.luau")
local HeatmapView = require("./heatmap_view.luau")
local Heatmap = require("./heatmap.luau")
local M = {}
local function tr(key, values) return noctalia.tr("analytics." .. key, values) end
local function label(text, color, size, lines)
    return ui.label({ text = text, color = color or "on_surface_variant", fontSize = size or 11,
        baseline = "textFixedHeight", maxLines = lines or 1 })
end
local function note(text, color) return label(text, color or "on_surface_variant/0.7", 10, 2) end
local function cell(child) return ui.column({ width = 148, align = "end" }, { child }) end
local function pair(name, value, strong)
    return ui.row({ align = "center", gap = 12 }, {
        ui.column({ flexGrow = 1 }, { ui.label({ text = name, maxWidth = 288, maxLines = 3, baseline = "textFixedHeight",
            color = strong and "on_surface" or "on_surface_variant", fontSize = strong and 12 or 11 }) }),
        cell(ui.label({ text = value, maxWidth = 148, maxLines = 2, textAlign = "end",
            baseline = "textFixedHeight", color = strong and "on_surface" or "on_surface_variant", fontSize = strong and 12 or 11 })),
    })
end
local function card(ctx, key, children)
    return ui.column({ key = key, width = ctx.width or 480, padding = 16,
        fill = "surface_variant/0.25", radius = 12, border = "on_surface/0.06", borderWidth = 1,
        gap = 8 }, children)
end
local function money(value) return view.money(value) end
local function number(value) return view.number(value) end
local function metric(name, value) return pair(tr(name), number(value)) end
local function headline(name, value, detail, width)
    return ui.column({ width = width or 144, gap = 4, tooltip = detail }, {
        label(name, "on_surface_variant", 10),
        ui.label({ text = value, color = "on_surface", fontSize = 23, fontWeight = "semibold",
            baseline = "textFixedHeight", maxLines = 1 }),
    })
end
local function summary(ctx, tokens, cost, count)
    return card(ctx, "analytics-header", {
        ui.row({ gap = 8 }, {
            headline(tr("tokens"), view.compact(tokens), number(tokens)),
            headline(tr("cost"), money(cost)),
            headline(tr("model_count"), number(count)),
        }),
    })
end
local function disclosure(expanded, text, callback)
    return ui.button({ glyph = expanded and "chevron-up" or "chevron-down", tooltip = text,
        width = 28, height = 28, glyphSize = 14, variant = "ghost", controlSize = "sm", onClick = callback })
end
local function amountStack(tokens, cost)
    return ui.column({ width = 112, align = "end", gap = 3, tooltip = tr("tokens") .. ": " .. number(tokens) }, {
        label(view.compact(tokens), "on_surface", 13), label(money(cost), "on_surface_variant", 10),
    })
end
local function unpriced(rows, count)
    if type(count) == "number" and count > 0 then
        rows[#rows + 1] = note(tr("unpriced", { count = number(count) }), "secondary")
    end
end
local function pagination(count, ctx)
    local size = math.max(1, math.min(10, math.floor(tonumber(ctx.pageSize) or 6)))
    local pages = math.max(1, math.ceil(count / size))
    local page = math.max(1, math.min(pages, math.floor(tonumber(ctx.page) or 1)))
    return page, pages, (page - 1) * size + 1, math.min(count, page * size)
end
local function result(children, count, ctx)
    local page, pages = pagination(count, ctx)
    return { children = children, count = count, page = page, pages = pages }
end
local function unavailable(ctx, key)
    return result({ card(ctx, "analytics-empty", { note(tr(key)) }) }, 0, ctx)
end
local function period(dashboard, ctx)
    local analytics = dashboard.analytics or {}
    return (analytics.periods or {})[ctx.period or "today"], analytics
end
local function warnings(children, ctx, data, sessions)
    if sessions and (data.sessionOmitted or 0) > 0 then
        children[#children + 1] = card(ctx, "omitted", { note(tr("sessions_omitted", { count = data.sessionOmitted }), "secondary") })
    end
    if (sessions and data.sessionTruncated) or (not sessions and data.modelsTruncated) then
        children[#children + 1] = card(ctx, "truncated", { note(tr("local_truncated"), "secondary") })
    end
end
local function components(rows, data)
    local fields = { { "input", "inputTokens" }, { "output", "outputTokens" },
        { "cache_read", "cacheReadTokens" }, { "cache_write", "cacheWriteTokens" }, { "reasoning", "reasoningTokens" } }
    for _, field in ipairs(fields) do
        if data[field[2]] ~= nil then rows[#rows + 1] = metric(field[1], data[field[2]]) end
    end
end
local function models(dashboard, ctx)
    local data = period(dashboard, ctx)
    if not data or not data.available then return unavailable(ctx, "stats_unavailable") end
    local items = data.models or {}
    local totals = data.totals or {}
    local children = { summary(ctx, totals.tokens, totals.cost, data.modelCount or #items) }
    if type(totals.unpricedTokens) == "number" and totals.unpricedTokens > 0 then
        children[#children + 1] = note(tr("unpriced", { count = number(totals.unpricedTokens) }), "secondary")
    end
    warnings(children, ctx, data, false)
    local _, _, first, last = pagination(#items, ctx)
    if #items == 0 then children[#children + 1] = card(ctx, "models-empty", { note(tr("models_empty")) }) end
    for index = first, last do
        local item = items[index]
        local key = type(item.key) == "string" and item.key ~= "" and item.key or (item.name or tostring(index))
        local expanded = ctx.expandedModel == key
        local ratio = type(totals.tokens) == "number" and totals.tokens > 0 and type(item.tokens) == "number"
            and math.max(0, math.min(1, item.tokens / totals.tokens)) or nil
        local rows = {
            ui.row({ align = "center", gap = 8 }, {
                label(string.format("%02d", index), "on_surface_variant/0.6", 10),
                ui.column({ flexGrow = 1, gap = 3 }, {
                    ui.label({ text = item.name, maxWidth = 252, maxLines = 1, fontSize = 12,
                        fontWeight = "medium", color = "on_surface", baseline = "textFixedHeight" }),
                    label(ratio and (number(ratio * 100) .. "% " .. tr("token_share")) or tr("share_unavailable"), nil, 10),
                }),
                amountStack(item.tokens, item.cost),
                disclosure(expanded, tr(expanded and "less" or "model_details"), function()
                    if ctx.onExpandModel then ctx.onExpandModel(key) end
                end),
            }),
        }
        if ratio then
            local track = { ui.box({ width = ((ctx.width or 480) - 32) * ratio, height = 3, fill = "primary", radius = 2 }) }
            rows[#rows + 1] = ui.row({ height = 3, fill = "on_surface/0.06", radius = 2 }, track)
        end
        if expanded then
            local detailRows = {}
            components(detailRows, item)
            rows[#rows + 1] = ui.column({ key = "model-components-" .. key, gap = 6 }, detailRows)
        end
        unpriced(rows, item.unpricedTokens)
        children[#children + 1] = card(ctx, "model-" .. key, rows)
    end
    return result(children, #items, ctx)
end
local function sessionDetails(rows, item, showNames)
    if showNames and item.sessionId and item.sessionId ~= "" then rows[#rows + 1] = note(tr("session_id") .. ": " .. item.sessionId) end
    rows[#rows + 1] = pair(tr("started"), view.timestamp(item.startedAt))
    rows[#rows + 1] = metric("messages", item.messageCount)
    if type(item.contextWindow) == "number" and item.contextWindow > 0 then
        if item.contextTokens ~= nil then rows[#rows + 1] = metric("context_tokens", item.contextTokens) end
        rows[#rows + 1] = metric("context_window", item.contextWindow)
    else rows[#rows + 1] = note(tr("context_unavailable")) end
    components(rows, item)
    if item.archived == true then rows[#rows + 1] = note(tr("archived")) end
    if item.turnEnded == true then rows[#rows + 1] = note(tr("turn_ended")) end
    local distribution = item.models or {}
    for index = 1, math.min(8, #distribution) do
        local model = distribution[index]
        rows[#rows + 1] = pair(model.name, number(model.tokens))
        rows[#rows + 1] = pair(tr("cost"), money(model.cost))
    end
    if #distribution > 8 then rows[#rows + 1] = note(tr("more_models", { count = #distribution - 8 })) end
end
local function sessions(dashboard, ctx)
    if ctx.period == "allTime" then return unavailable(ctx, "all_time_sessions") end
    local data = period(dashboard, ctx)
    if not data or not data.available or data.sessionsAvailable == false then return unavailable(ctx, "sessions_unavailable") end
    local items = data.sessions or {}
    local children = { note(tr("session_period")) }
    warnings(children, ctx, data, true)
    local _, _, first, last = pagination(#items, ctx)
    if #items == 0 then children[#children + 1] = card(ctx, "sessions-empty", { note(tr("sessions_empty")) }) end
    for index = first, last do
        local item = items[index]
        local key = type(item.key) == "string" and item.key ~= "" and item.key or ("index-" .. tostring(index))
        local title = tr("private_session", { index = index })
        if ctx.showNames then
            title = item.title and item.title ~= "" and item.title or tr("client_session", { client = item.client or tr("unknown_client") })
        end
        local expanded = ctx.expandedSession == key
        local meta = view.timestamp(item.lastUsedAt)
        if ctx.showNames and item.projectLabel and item.projectLabel ~= "" then meta = meta .. " · " .. item.projectLabel end
        local rows = {
            ui.row({ align = "center", gap = 8 }, {
                ui.column({ flexGrow = 1, gap = 4, tooltip = meta }, {
                    ui.label({ text = title, maxWidth = 288, maxLines = 1, fontSize = 12, fontWeight = "medium",
                        color = "on_surface", baseline = "textFixedHeight" }),
                    ui.label({ text = meta, maxWidth = 288, maxLines = 1, fontSize = 10,
                        color = "on_surface_variant/0.7", baseline = "textFixedHeight" }),
                }),
                amountStack(item.totalTokens, item.costUsd),
                disclosure(expanded, tr(expanded and "less" or "details"), function()
                    if ctx.onExpandSession then ctx.onExpandSession(key) end
                end),
            }),
        }
        if expanded then sessionDetails(rows, item, ctx.showNames) end
        unpriced(rows, item.unpricedTokens)
        children[#children + 1] = card(ctx, "session-" .. key, rows)
    end
    return result(children, #items, ctx)
end
local function historyRows(dashboard, ctx)
    local history = dashboard.history or {}
    local mode = ctx.historyMode == "monthly" and "monthly" or "daily"
    local rows = history[mode] or {}
    -- Sort a reference copy; never mutate the shared dashboard snapshot.
    local sorted = {}
    for _, row in ipairs(rows) do sorted[#sorted + 1] = row end
    local field = mode == "daily" and "date" or "month"
    table.sort(sorted, function(a, b) return (a[field] or "") > (b[field] or "") end)
    return sorted, field, history, mode
end
local function historyNote(children, ctx, history, mode)
    local rows = { note(tr("bucket_boundary")) }
    if history.cached then rows[#rows + 1] = note(tr("history_cached"), "secondary") end
    if history.status == "error" then rows[#rows + 1] = note(tr("history_error"), "error") end
    if history[mode .. "Truncated"] then rows[#rows + 1] = note(tr("local_truncated"), "secondary") end
    children[#children + 1] = ui.column({ key = "history-boundary", width = ctx.width or 480, gap = 4 }, rows)
end
local function attribution(rows, bucket, field, heading, countField, truncatedField)
    local items = bucket[field] or {}
    rows[#rows + 1] = label(tr(heading), "on_surface", 12)
    if #items == 0 then rows[#rows + 1] = note(tr("attribution_empty")) end
    for index = 1, math.min(8, #items) do
        local item = items[index]
        rows[#rows + 1] = ui.row({ gap = 8, align = "center" }, {
            ui.column({ flexGrow = 1 }, { label(item.name, "on_surface", 11) }),
            amountStack(item.tokens, item.cost),
        })
    end
    local total = math.max(#items, bucket[countField] or 0)
    local shown = math.min(8, #items)
    if total > shown then rows[#rows + 1] = note(tr("more_attribution", { count = total - shown })) end
    if bucket[truncatedField] then rows[#rows + 1] = note(tr("source_attribution_truncated"), "secondary") end
end
local function bucketCard(ctx, row, field, index, activity, selected)
    -- The field owns bucket identity: a selected day stays daily in monthly mode.
    local key = (field == "month" and "monthly:" or "daily:") .. row[field]
    local expanded = ctx.expandedBucket == key
    local meta = {}
    if activity then
        if row.messages ~= nil then meta[#meta + 1] = number(row.messages) .. " " .. tr("messages") end
        if row.activeTimeMs ~= nil then meta[#meta + 1] = view.duration(row.activeTimeMs) end
        meta[#meta + 1] = number(row.perModelCount or #(row.perModel or {})) .. " " .. tr("model_count")
    end
    local titles = { label((selected and tr("selected_day") .. " · " or "") .. row[field], "on_surface", 12) }
    if #meta > 0 then titles[#titles + 1] = note(table.concat(meta, " · ")) end
    local rows = {
        ui.row({ align = "center", gap = 8 }, {
            ui.column({ flexGrow = 1, gap = 4 }, titles),
            amountStack(row.tokens, row.cost),
            disclosure(expanded, tr(expanded and "less" or "bucket_details"), function()
                if ctx.onExpandBucket then ctx.onExpandBucket(key) end
            end),
        }),
    }
    unpriced(rows, row.unpricedTokens)
    if expanded then
        attribution(rows, row, "perModel", "model_breakdown", "perModelCount", "perModelTruncated")
        attribution(rows, row, "perClient", "client_breakdown", "perClientCount", "perClientTruncated")
    end
    return card(ctx, (selected and "selected-bucket-" or "bucket-") .. key, rows)
end
local function activity(dashboard, ctx)
    local rows, field, history, mode = historyRows(dashboard, ctx)
    local daily = history.daily or {}
    local selected, newest
    local today = Heatmap.parseDate(ctx.today)
    local firstOrdinal = today and today.ordinal - today.weekday + 1 - ((ctx.heatmapWeeks == 13 and 13 or 26) - 1) * 7
    for _, row in ipairs(daily) do
        local date = Heatmap.parseDate(row.date)
        if date and today and date.ordinal >= firstOrdinal and date.ordinal <= today.ordinal then
            if row.date == ctx.selectedDay then selected = row end
            -- Match Heatmap.build: the last duplicate date owns its bucket.
            if not newest or row.date >= newest.date then newest = row end
        end
    end
    if not ctx.selectedDay then selected = newest end
    local heatCtx = {}
    for key, value in pairs(ctx) do heatCtx[key] = value end
    heatCtx.selectedDay = ctx.selectedDay or (selected and selected.date)
    local children = { HeatmapView.render(daily, heatCtx) }
    historyNote(children, ctx, history, mode)
    if mode == "monthly" then children[#children + 1] = note(tr("daily_heatmap_monthly_list")) end
    if selected then
        children[#children + 1] = bucketCard(ctx, selected, "date", 0, true, true)
    elseif ctx.selectedDay then
        children[#children + 1] = card(ctx, "selected-day-missing", {
            label(tr("selected_day") .. " · " .. ctx.selectedDay, "on_surface", 12), note(tr("day_unavailable")),
        })
    end
    local _, _, first, last = pagination(#rows, ctx)
    if #rows == 0 then children[#children + 1] = card(ctx, "history-empty", { note(tr("history_empty")) }) end
    children[#children + 1] = ui.row({ key = "history-list-header", width = ctx.width or 480, align = "center", gap = 4 }, {
        ui.column({ flexGrow = 1 }, { label(tr("history_heading"), "on_surface_variant", 11) }),
        ui.row({ fill = mode == "daily" and "primary/0.10" or "on_surface/0", radius = 6 }, {
            ui.button({ text = noctalia.tr("period.daily"), fontSize = 10, variant = "ghost", controlSize = "sm", height = 28,
                onClick = function() if ctx.onHistoryDaily then ctx.onHistoryDaily() end end }),
        }),
        ui.row({ fill = mode == "monthly" and "primary/0.10" or "on_surface/0", radius = 6 }, {
            ui.button({ text = noctalia.tr("period.monthly"), fontSize = 10, variant = "ghost", controlSize = "sm", height = 28,
                onClick = function() if ctx.onHistoryMonthly then ctx.onHistoryMonthly() end end }),
        }),
    })
    for index = first, last do children[#children + 1] = bucketCard(ctx, rows[index], field, index, true) end
    return result(children, #rows, ctx)
end
local function trends(dashboard, ctx)
    local rows, field, history, mode = historyRows(dashboard, ctx)
    local children = {}
    local metricName = ctx.trendMetric == "cost" and "cost" or "tokens"
    local points, peak = {}, 0
    -- Use the latest recorded buckets in chronological order; do not fill gaps.
    for index = math.min(30, #rows), 1, -1 do
        local row = rows[index]
        local value = row[metricName]
        if type(value) == "number" and value == value and value >= 0 and value < math.huge then
            points[#points + 1] = { value = value, date = row[field] }
            peak = math.max(peak, value)
        end
    end
    local graphRows = {}
    if #points > 0 then
        graphRows[#graphRows + 1] = ui.row({ gap = 8 }, {
            headline(tr(metricName == "cost" and "peak_cost" or "peak_tokens"), metricName == "cost" and money(peak) or view.compact(peak), number(peak), 220),
            headline(tr("recorded_buckets"), number(#points), nil, 220),
        })
        if #points > 1 then
            -- Native ui.graph is a scrolling monitor spline: it needs four
            -- samples, hides leading samples and extrapolates the end. Exact
            -- historical buckets use bars so every reported point stays visible.
            local bars = {}
            local barWidth = math.min(28, math.max(2, math.floor(((ctx.width or 480) - 32) / #points) - 4))
            for _, point in ipairs(points) do
                local ratio = peak > 0 and point.value / peak or 0
                bars[#bars + 1] = ui.column({ key = "trend-point-" .. point.date, flexGrow = 1,
                    height = 100, align = "center", justify = "end", gap = 2,
                    tooltip = point.date .. " · " .. (metricName == "cost" and money(point.value) or number(point.value)) }, {
                    ui.spacer({ flexGrow = 1 }),
                    ui.box({ key = "trend-value-" .. point.date, width = barWidth, height = ratio * 96, fill = "primary/0.85", radius = 3 }),
                    ui.box({ width = barWidth, height = 1, fill = "on_surface/0.18" }),
                })
            end
            graphRows[#graphRows + 1] = ui.row({ width = (ctx.width or 480) - 32, height = 100, gap = 4, align = "end" }, bars)
        else graphRows[#graphRows + 1] = note(tr("single_point")) end
        graphRows[#graphRows + 1] = pair(points[1].date, points[#points].date)
        graphRows[#graphRows + 1] = note(tr(mode == "daily" and "recorded_days" or "recorded_months"))
    else graphRows[#graphRows + 1] = note(tr("history_empty")) end
    children[#children + 1] = card(ctx, "trend-graph", graphRows)
    historyNote(children, ctx, history, mode)
    local _, _, first, last = pagination(#rows, ctx)
    for index = first, last do children[#children + 1] = bucketCard(ctx, rows[index], field, index, false) end
    return result(children, #rows, ctx)
end
function M.render(tab, dashboard, ctx)
    if tab == "models" then return models(dashboard, ctx) end
    if tab == "sessions" then return sessions(dashboard, ctx) end
    if tab == "activity" then return activity(dashboard, ctx) end
    if tab == "trends" then return trends(dashboard, ctx) end
    return result({}, 0, ctx)
end
return M
