--!nonstrict
-- 9Router Monitor — Popup Panel.
-- Comprehensive interactive dashboard interface:
--   • Activity Tab:
--       - Hero status banner (Active in-flight model, Idle, or Session Expired)
--       - 9Router Overview stats (Total Requests, Input Tokens, Cached Tokens, Output Tokens, Est. Cost)
--         with period selector (Today, 24h, 7d, 30d, 60d)
--       - Live Active In-flight requests
--       - Recent requests list with In/Out/Cached token metrics and cost
--   • Models Tab:
--       - Model usage breakdown across periods (Today, 24h, 7d, 30d, 60d)
--       - Total summary bar & individual model tokens (prompt, completion, cached, cost)
--   • Quota Tracker Tab:
--       - Summarized quotas (6 standard quotas for Antigravity: Gemini Flash/Pro, Claude Sonnet/Opus,
--         GPT-OSS 120B, Gemini 3.1 Flash Image, Gemini Weekly, Claude & GPT Weekly)
--       - Other providers quota pools
--       - Colored dot indicators (green >= 50%, yellow 20-49%, red < 20%) and matching progress bars
--       - Human-readable reset countdown (e.g. "in 3h 14m")

local status = {
    auth = "unknown",
    busy = false,
    display_model = "",
    last_model = "",
    last_provider = "",
    last_fetch_text = "",
    base_url = "http://localhost:20128",
    active_requests = {},
    recent_requests = {},
    quotas = {},
    models_usage = { ["today"] = {}, ["24h"] = {}, ["7d"] = {}, ["30d"] = {}, ["60d"] = {} },
    period_totals = { ["today"] = {}, ["24h"] = {}, ["7d"] = {}, ["30d"] = {}, ["60d"] = {} },
    error_text = "",
    login_error = "",
    logging_in = false,
    remember_password = true,
}

local selected_tab = "activity"             -- "activity" | "models" | "quotas"
local selected_overview_period = "today"    -- "today" | "24h" | "7d" | "30d" | "60d"
local selected_models_period = "today"      -- "today" | "24h" | "7d" | "30d" | "60d"

-- ── Formatting helpers ──────────────────────────────────────────────────────

local function format_commas(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local k
    while true do
        s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
        if k == 0 then break end
    end
    return s
end

local function format_tokens(n)
    local num = tonumber(n) or 0
    if num >= 1000000 then
        return string.format("%.1fM", num / 1000000)
    elseif num >= 1000 then
        return string.format("%.1fk", num / 1000)
    else
        return tostring(math.floor(num))
    end
end

local function format_cost(c)
    local cost = tonumber(c) or 0.0
    if cost <= 0 then
        return "$0.00"
    elseif cost < 0.01 then
        return string.format("$%.4f", cost)
    elseif cost < 1.0 then
        return string.format("$%.3f", cost)
    else
        return string.format("$%.2f", cost)
    end
end

local function format_ago(iso)
    if type(iso) ~= "string" or iso == "" then return "" end
    local y, mo, d, h, mi, s = iso:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
    if not y then return "" end

    local then_ts = os.time({
        year = tonumber(y) or 1970,
        month = tonumber(mo) or 1,
        day = tonumber(d) or 1,
        hour = tonumber(h) or 0,
        min = tonumber(mi) or 0,
        sec = tonumber(s) or 0,
    })

    local now_utc = os.time(os.date("!*t") :: any)
    local diff = math.max(0, now_utc - then_ts)

    if diff < 10 then
        return noctalia.tr("time.just_now")
    elseif diff < 60 then
        return noctalia.tr("time.seconds_ago", { count = tostring(diff) })
    elseif diff < 3600 then
        return noctalia.tr("time.minutes_ago", { count = tostring(math.floor(diff / 60)) })
    elseif diff < 86400 then
        return noctalia.tr("time.hours_ago", { count = tostring(math.floor(diff / 3600)) })
    else
        return noctalia.tr("time.days_ago", { count = tostring(math.floor(diff / 86400)) })
    end
end

local function format_countdown(iso_str)
    if type(iso_str) ~= "string" or iso_str == "" then
        return ""
    end

    local y, mo, d, h, mi, s = iso_str:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
    if not y then
        return iso_str
    end

    local reset_ts = os.time({
        year = tonumber(y) or 1970,
        month = tonumber(mo) or 1,
        day = tonumber(d) or 1,
        hour = tonumber(h) or 0,
        min = tonumber(mi) or 0,
        sec = tonumber(s) or 0,
    })

    local now_utc = os.time(os.date("!*t") :: any)
    local diff = reset_ts - now_utc

    if diff <= 0 then
        return "now"
    end

    local days = math.floor(diff / 86400)
    local hours = math.floor((diff % 86400) / 3600)
    local mins = math.floor((diff % 3600) / 60)

    if days > 0 then
        return string.format("in %dd %dh", days, hours)
    elseif hours > 0 then
        return string.format("in %dh %dm", hours, mins)
    else
        return string.format("in %dm", math.max(1, mins))
    end
end

-- ── Action dispatchers ──────────────────────────────────────────────────────

local function refresh_data()
    noctalia.state.set("9router.command", { action = "refresh" })
    if selected_tab == "quotas" then
        noctalia.state.set("9router.command", { action = "refresh_quotas" })
    end
end

local function logout()
    noctalia.state.set("9router.command", { action = "logout" })
end

local function open_dashboard()
    local base = status.base_url or "http://localhost:20128"
    noctalia.runAsync({ "xdg-open", base .. "/dashboard/usage" })
end

-- ── Tab Bar Navigation ──────────────────────────────────────────────────────

local render

local function set_tab(t)
    if t == "activity" or t == "models" or t == "quotas" then
        if selected_tab ~= t then
            selected_tab = t
            noctalia.state.set("9router.active_tab", t)
            if t == "quotas" then
                noctalia.state.set("9router.command", { action = "refresh_quotas" })
            end
            render()
        end
    end
end

local function render_tabs()
    return ui.row({ key = "panel-tabs", align = "center", justify = "space_between", gap = 8 }, {
        ui.row({ align = "center", gap = 4 }, {
            ui.button({
                text = noctalia.tr("tab.activity"),
                glyph = "activity",
                glyphSize = 13,
                variant = (selected_tab == "activity") and "primary" or "ghost",
                onClick = function()
                    set_tab("activity")
                end,
            }),
            ui.button({
                text = noctalia.tr("tab.models"),
                glyph = "cpu",
                glyphSize = 13,
                variant = (selected_tab == "models") and "primary" or "ghost",
                onClick = function()
                    set_tab("models")
                end,
            }),
            ui.button({
                text = noctalia.tr("tab.quotas"),
                glyph = "chart-donut",
                glyphSize = 13,
                variant = (selected_tab == "quotas") and "primary" or "ghost",
                onClick = function()
                    set_tab("quotas")
                end,
            }),
        }),
        ui.button({
            glyph = "refresh",
            variant = "ghost",
            glyphSize = 14,
            onClick = refresh_data,
        }),
    })
end

-- ── Tab 1: Activity View ────────────────────────────────────────────────────

local function render_activity_view()
    local auth = status.auth or "unknown"
    local busy = status.busy == true
    local active_list = status.active_requests or {}
    local recent_list = status.recent_requests or {}

    local disp_model = ""
    if status.display_model and status.display_model ~= "" then
        disp_model = status.display_model
    elseif status.last_model and status.last_model ~= "" then
        disp_model = status.last_model
    end

    local items = {}

    -- 1. Hero Connection Card
    local meta_text = noctalia.tr("status.idle")
    local meta_color = "secondary"

    if auth == "expired" then
        meta_text = noctalia.tr("status.session_expired")
        meta_color = "error"
    elseif busy then
        meta_text = noctalia.tr("status.request_in_flight")
        meta_color = "primary"
    elseif auth == "offline" then
        meta_text = noctalia.tr("status.offline")
        meta_color = "on_surface_variant"
    elseif auth == "unknown" then
        meta_text = noctalia.tr("status.connecting")
        meta_color = "on_surface_variant"
    end

    local hero_detail = if disp_model ~= "" then disp_model else noctalia.tr("status.no_requests")

    local hero_children = {
        ui.row({ align = "center", gap = 6 }, {
            ui.glyph({ name = busy and "bolt" or (auth == "expired" and "lock" or "activity"), size = 13, color = meta_color }),
            ui.label({ text = meta_text, fontSize = 11, fontWeight = "heavy", color = meta_color }),
        }),
        ui.label({ text = hero_detail, fontSize = 15, fontWeight = "bold", color = "on_surface" }),
    }
    if status.last_provider and status.last_provider ~= "" then
        table.insert(hero_children, ui.label({ text = status.last_provider, fontSize = 12, color = "on_surface_variant" }))
    end

    table.insert(items, ui.column({
        key = "activity-hero",
        fill = "surface_variant/0.4",
        border = meta_color .. "/0.3",
        borderWidth = 1,
        radius = 10,
        padding = 12,
        gap = 4,
    }, hero_children))

    table.insert(items, ui.separator({ key = "activity-sep-1" }))

    -- Authentication banner when expired
    if auth == "expired" then
        table.insert(items, ui.row({
            key = "activity-auth-expired",
            fill = "error/0.12",
            border = "error/0.4",
            borderWidth = 1,
            radius = 8,
            padding = 10,
            align = "center",
            justify = "space_between",
            gap = 8,
        }, {
            ui.row({ align = "center", gap = 8, flexGrow = 1 }, {
                ui.glyph({ name = "lock", size = 16, color = "error" }),
                ui.label({ text = noctalia.tr("panel.login_description"), fontSize = 11, color = "on_surface", flexGrow = 1 }),
            }),
            ui.button({
                text = "Settings",
                variant = "primary",
                onClick = function()
                    noctalia.openSettings()
                end,
            }),
        }))
    end

    -- 2. 9Router Overview Stats Card (today, 24h, 7d, 30d, 60d)
    local p_totals = (status.period_totals and status.period_totals[selected_overview_period]) or {}
    local tot_reqs = p_totals.requests or 0
    local tot_cost = p_totals.cost or 0
    local tot_prompt = p_totals.prompt_tokens or 0
    local tot_comp = p_totals.completion_tokens or 0
    local tot_cached = p_totals.cached_tokens or 0

    local overview_periods = { "today", "24h", "7d", "30d", "60d" }
    local overview_period_buttons = {}
    for _, p in ipairs(overview_periods) do
        table.insert(overview_period_buttons, ui.button({
            text = noctalia.tr("period." .. p),
            variant = (selected_overview_period == p) and "primary" or "ghost",
            onClick = function()
                selected_overview_period = p
                render()
            end,
        }))
    end

    local overview_header = ui.row({ align = "center", justify = "space_between", gap = 8 }, {
        ui.label({ text = noctalia.tr("panel.overview"), fontWeight = "bold", fontSize = 12, color = "on_surface_variant" }),
        ui.row({ align = "center", gap = 2 }, overview_period_buttons),
    })

    local cost_banner = ui.row({
        fill = "surface_variant/0.25",
        radius = 8,
        paddingH = 10,
        paddingV = 8,
        align = "center",
        justify = "space_between",
    }, {
        ui.column({ gap = 2 }, {
            ui.label({ text = noctalia.tr("panel.est_cost"), fontSize = 11, fontWeight = "bold", color = "on_surface" }),
            ui.label({ text = noctalia.tr("panel.est_cost_sub"), fontSize = 10, color = "on_surface_variant" }),
        }),
        ui.label({ text = "~" .. format_cost(tot_cost), fontSize = 16, fontWeight = "heavy", color = "primary" }),
    })

    local stat_box = function(label, value, color)
        return ui.column({
            fill = "surface_variant/0.25",
            radius = 8,
            paddingH = 10,
            paddingV = 8,
            gap = 3,
            flexGrow = 1,
        }, {
            ui.label({ text = label, fontSize = 11, color = "on_surface_variant" }),
            ui.label({ text = value, fontSize = 13, fontWeight = "bold", color = color or "on_surface" }),
        })
    end

    local stats_grid = ui.column({ gap = 6 }, {
        cost_banner,
        ui.row({ gap = 6 }, {
            stat_box(noctalia.tr("panel.total_requests"), format_commas(tot_reqs), "on_surface"),
            stat_box(noctalia.tr("panel.total_input_tokens"), format_commas(tot_prompt), "primary"),
        }),
        ui.row({ gap = 6 }, {
            stat_box(noctalia.tr("panel.cached_tokens_label"), format_commas(tot_cached), "primary"),
            stat_box(noctalia.tr("panel.output_tokens"), format_commas(tot_comp), "secondary"),
        }),
    })

    table.insert(items, ui.column({
        key = "activity-overview",
        gap = 6,
    }, {
        overview_header,
        stats_grid,
    }))

    table.insert(items, ui.separator({ key = "activity-sep-2" }))

    -- 3. Active Requests (when traffic flows)
    if #active_list > 0 then
        local active_cards = {}
        table.insert(active_cards, ui.label({ text = noctalia.tr("panel.active_now"), fontWeight = "bold", fontSize = 12, color = "primary" }))

        for _, req in ipairs(active_list) do
            local count_str = if req.count and req.count > 1 then (" ×" .. tostring(req.count)) else ""
            local sub_parts = {}
            if req.provider and req.provider ~= "" then table.insert(sub_parts, req.provider) end
            if req.account and req.account ~= "" then table.insert(sub_parts, req.account) end
            local sub_str = table.concat(sub_parts, " · ")

            local card_text_col = {
                ui.label({ text = (req.model or "unknown") .. count_str, fontWeight = "bold", fontSize = 13, color = "on_surface" }),
            }
            if sub_str ~= "" then
                table.insert(card_text_col, ui.label({ text = sub_str, fontSize = 11, color = "on_surface_variant" }))
            end

            table.insert(active_cards, ui.row({
                fill = "primary/0.1",
                border = "primary/0.4",
                borderWidth = 1,
                radius = 8,
                padding = 8,
                align = "center",
                gap = 8,
            }, {
                ui.glyph({ name = "circle-filled", size = 10, color = "primary" }),
                ui.column({ flexGrow = 1, gap = 2 }, card_text_col),
            }))
        end

        table.insert(items, ui.column({ key = "activity-active", gap = 6 }, active_cards))
    end

    -- 4. Recent Requests List (with In/Out tokens and cost)
    local recent_cards = {
        ui.row({ align = "center", justify = "space_between" }, {
            ui.label({ text = noctalia.tr("panel.recent_requests"), fontWeight = "bold", fontSize = 12, color = "on_surface_variant" }),
            if #recent_list > 0 then
                ui.label({ text = tostring(#recent_list) .. " recent", fontSize = 11, color = "on_surface_variant" })
            else
                nil,
        })
    }

    if #recent_list == 0 then
        table.insert(recent_cards, ui.label({
            text = noctalia.tr("panel.no_recent"),
            fontSize = 12,
            color = "on_surface_variant",
        }))
    else
        for _, req in ipairs(recent_list) do
            local is_ok = (req.status == "ok" or req.status == "success" or req.status == "" or req.status == nil)
            local status_color = if is_ok then "primary" else "error"
            local ago_str = format_ago(req.timestamp)

            local pt = tonumber(req.prompt_tokens) or 0
            local ct = tonumber(req.completion_tokens) or 0
            local cached = tonumber(req.cached_tokens) or 0
            local cost = tonumber(req.cost) or 0

            local line1_right = ago_str

            local line1 = ui.row({ align = "center", justify = "space_between", gap = 6 }, {
                ui.row({ align = "center", gap = 6, flexGrow = 1 }, {
                    ui.glyph({ name = "circle-filled", size = 8, color = status_color }),
                    ui.label({ text = tostring(req.model or "unknown"), fontWeight = "bold", fontSize = 12, color = "on_surface" }),
                    if req.provider and req.provider ~= "" then
                        ui.label({ text = "· " .. tostring(req.provider), fontSize = 11, color = "on_surface_variant" })
                    else
                        nil,
                }),
                ui.label({ text = line1_right, fontSize = 11, color = "on_surface_variant" }),
            })

            local metrics_children = {
                ui.row({ align = "center", gap = 2 }, {
                    ui.label({ text = "↑", fontSize = 11, color = "primary", fontWeight = "bold" }),
                    ui.label({ text = format_tokens(pt) .. " in", fontSize = 11, color = "on_surface" }),
                }),
                ui.row({ align = "center", gap = 2 }, {
                    ui.label({ text = "↓", fontSize = 11, color = "secondary", fontWeight = "bold" }),
                    ui.label({ text = format_tokens(ct) .. " out", fontSize = 11, color = "on_surface" }),
                }),
            }
            if cached > 0 then
                table.insert(metrics_children, ui.row({ align = "center", gap = 2 }, {
                    ui.glyph({ name = "bolt", size = 11, color = "primary" }),
                    ui.label({ text = format_tokens(cached) .. " cached", fontSize = 11, color = "primary" }),
                }))
            end

            local metrics_row = ui.row({ align = "center", justify = "space_between", gap = 8 }, {
                ui.row({ align = "center", gap = 8 }, metrics_children),
                if cost > 0 then
                    ui.label({ text = format_cost(cost), fontSize = 11, fontWeight = "bold", color = "on_surface" })
                else
                    nil,
            })

            table.insert(recent_cards, ui.column({
                fill = "surface_variant/0.25",
                radius = 8,
                padding = 8,
                gap = 4,
            }, { line1, metrics_row }))
        end
    end

    table.insert(items, ui.column({ key = "activity-recent", gap = 6 }, recent_cards))

    -- 5. Footer Actions
    local footer_buttons = {
        ui.button({
            text = noctalia.tr("panel.open_dashboard"),
            variant = "default",
            onClick = open_dashboard,
        }),
        ui.button({
            text = noctalia.tr("panel.refresh"),
            variant = "ghost",
            glyph = "refresh",
            onClick = refresh_data,
        }),
    }

    if auth == "ok" or auth == "expired" then
        table.insert(footer_buttons, ui.button({
            text = noctalia.tr("panel.logout"),
            variant = "ghost",
            onClick = logout,
        }))
    end

    table.insert(items, ui.row({ key = "activity-footer", gap = 8, align = "center" }, footer_buttons))

    if status.last_fetch_text and status.last_fetch_text ~= "" then
        table.insert(items, ui.label({
            text = noctalia.tr("panel.updated_at", { time = status.last_fetch_text, url = status.base_url or "" }),
            fontSize = 11,
            color = "on_surface_variant",
        }))
    end

    return items
end

-- ── Tab 2: Models View (Model Usage) ────────────────────────────────────────

local function render_models_view()
    local items = {}
    local models_map = status.models_usage or {}
    local period_models = models_map[selected_models_period] or {}
    local p_totals = (status.period_totals and status.period_totals[selected_models_period]) or {}

    local models_periods = { "today", "24h", "7d", "30d", "60d" }
    local period_buttons = {}
    for _, p in ipairs(models_periods) do
        table.insert(period_buttons, ui.button({
            text = noctalia.tr("period." .. p),
            variant = (selected_models_period == p) and "primary" or "ghost",
            onClick = function()
                selected_models_period = p
                render()
            end,
        }))
    end

    local period_header_row = ui.row({ align = "center", justify = "space_between", gap = 8 }, {
        ui.label({ text = noctalia.tr("panel.models_usage"), fontWeight = "bold", fontSize = 12, color = "on_surface_variant" }),
        ui.row({ align = "center", gap = 2 }, period_buttons),
    })

    local model_section_children = { period_header_row }

    local tot_reqs = p_totals.requests or 0
    local tot_cost = format_cost(p_totals.cost or 0)
    local tot_prompt = format_tokens(p_totals.prompt_tokens or 0)
    local tot_comp = format_tokens(p_totals.completion_tokens or 0)
    local tot_cached = format_tokens(p_totals.cached_tokens or 0)

    if tot_reqs > 0 then
        local summary_parts = {
            ui.label({ text = string.format("Total: %s (%s reqs)", tot_cost, tostring(tot_reqs)), fontWeight = "bold", fontSize = 11, color = "on_surface" }),
            ui.row({ align = "center", gap = 6 }, {
                ui.label({ text = "↑ " .. tot_prompt, fontSize = 11, color = "primary" }),
                ui.label({ text = "↓ " .. tot_comp, fontSize = 11, color = "secondary" }),
            }),
        }
        if (p_totals.cached_tokens or 0) > 0 then
            table.insert(summary_parts[2].children or summary_parts, ui.label({ text = "⚡ " .. tot_cached, fontSize = 11, color = "primary" }))
        end
        table.insert(model_section_children, ui.row({
            fill = "surface_variant/0.3",
            radius = 6,
            paddingH = 8,
            paddingV = 4,
            align = "center",
            justify = "space_between",
        }, summary_parts))
    end

    if #period_models == 0 then
        table.insert(model_section_children, ui.label({
            text = noctalia.tr("panel.no_models_period"),
            fontSize = 12,
            color = "on_surface_variant",
        }))
    else
        for _, m in ipairs(period_models) do
            local pt = m.prompt_tokens or 0
            local ct = m.completion_tokens or 0
            local cached = m.cached_tokens or 0
            local cost_str = format_cost(m.cost or 0)
            local req_str = tostring(m.requests or 0) .. " reqs"
            local ago_str = format_ago(m.last_used)

            local line1_right = req_str
            if ago_str ~= "" then
                line1_right = line1_right .. " · " .. ago_str
            end

            local header_row = ui.row({ align = "center", justify = "space_between", gap = 6 }, {
                ui.row({ align = "center", gap = 6, flexGrow = 1 }, {
                    ui.glyph({ name = "circle-filled", size = 8, color = "primary" }),
                    ui.label({ text = tostring(m.model or "unknown"), fontWeight = "bold", fontSize = 12, color = "on_surface" }),
                    if m.provider and m.provider ~= "" then
                        ui.label({ text = "· " .. tostring(m.provider), fontSize = 11, color = "on_surface_variant" })
                    else
                        nil,
                }),
                ui.label({ text = line1_right, fontSize = 11, color = "on_surface_variant" }),
            })

            local metrics_children = {
                ui.row({ align = "center", gap = 2 }, {
                    ui.label({ text = "↑", fontSize = 11, color = "primary", fontWeight = "bold" }),
                    ui.label({ text = format_tokens(pt), fontSize = 11, color = "on_surface" }),
                }),
                ui.row({ align = "center", gap = 2 }, {
                    ui.label({ text = "↓", fontSize = 11, color = "secondary", fontWeight = "bold" }),
                    ui.label({ text = format_tokens(ct), fontSize = 11, color = "on_surface" }),
                }),
            }
            if cached > 0 then
                table.insert(metrics_children, ui.row({ align = "center", gap = 2 }, {
                    ui.glyph({ name = "bolt", size = 11, color = "primary" }),
                    ui.label({ text = format_tokens(cached) .. " cached", fontSize = 11, color = "primary" }),
                }))
            end

            local metrics_row = ui.row({ align = "center", justify = "space_between", gap = 8 }, {
                ui.row({ align = "center", gap = 8 }, metrics_children),
                ui.label({ text = cost_str, fontSize = 11, fontWeight = "bold", color = (m.cost and m.cost > 0) and "on_surface" or "on_surface_variant" }),
            })

            table.insert(model_section_children, ui.column({
                fill = "surface_variant/0.25",
                radius = 8,
                padding = 8,
                gap = 4,
            }, { header_row, metrics_row }))
        end
    end

    table.insert(items, ui.column({ key = "models-content", gap = 6 }, model_section_children))

    -- Footer Actions
    local footer_buttons = {
        ui.button({
            text = noctalia.tr("panel.open_dashboard"),
            variant = "default",
            onClick = open_dashboard,
        }),
        ui.button({
            text = noctalia.tr("panel.refresh"),
            variant = "ghost",
            glyph = "refresh",
            onClick = refresh_data,
        }),
    }

    table.insert(items, ui.row({ key = "models-footer", gap = 8, align = "center" }, footer_buttons))

    return items
end

-- ── Tab 3: Quotas View ──────────────────────────────────────────────────────

local function render_quotas_view()
    local qlist = status.quotas or {}
    local items = {}

    table.insert(items, ui.row({ key = "quotas-header", align = "center", justify = "space_between" }, {
        ui.label({ text = noctalia.tr("panel.quota_tracker"), fontWeight = "bold", fontSize = 13, color = "on_surface" }),
        ui.button({
            text = noctalia.tr("panel.refresh"),
            glyph = "refresh",
            glyphSize = 12,
            variant = "ghost",
            onClick = function()
                noctalia.state.set("9router.command", { action = "refresh_quotas" })
            end,
        }),
    }))

    if #qlist == 0 then
        table.insert(items, ui.column({
            key = "quotas-empty",
            fill = "surface_variant/0.3",
            radius = 10,
            padding = 16,
            align = "center",
            gap = 6,
        }, {
            ui.glyph({ name = "chart-donut", size = 28, color = "on_surface_variant" }),
            ui.label({ text = noctalia.tr("panel.no_quotas"), fontSize = 12, color = "on_surface_variant" }),
        }))
    else
        for idx, prov in ipairs(qlist) do
            local card_children = {}

            -- Provider Header
            local header_items = {
                ui.glyph({ name = "server", size = 14, color = "primary" }),
                ui.label({ text = prov.name or prov.provider, fontWeight = "bold", fontSize = 13, color = "on_surface" }),
            }
            if prov.plan and prov.plan ~= "" then
                table.insert(header_items, ui.label({
                    text = string.upper(prov.plan),
                    fontSize = 9,
                    fontWeight = "bold",
                    color = "primary",
                }))
            end

            table.insert(card_children, ui.row({ align = "center", gap = 6 }, header_items))

            -- Quota rows for this provider
            local sub_quotas = prov.quotas or {}
            if #sub_quotas == 0 then
                table.insert(card_children, ui.label({
                    text = noctalia.tr("panel.no_quotas"),
                    fontSize = 11,
                    color = "on_surface_variant",
                }))
            else
                for _, q in ipairs(sub_quotas) do
                    local rem_pct = math.min(100, math.max(0, q.remaining_percentage or 100))
                    local dot_color = "primary"
                    if rem_pct < 20 then
                        dot_color = "error"
                    elseif rem_pct < 50 then
                        dot_color = "secondary"
                    end

                    local reset_label = ""
                    if q.reset_at and q.reset_at ~= "" then
                        reset_label = format_countdown(q.reset_at)
                    end

                    local quota_row_parts = {
                        ui.row({ align = "center", gap = 5 }, {
                            ui.glyph({ name = "circle-filled", size = 7, color = dot_color }),
                            ui.label({ text = q.display_name or q.id, fontSize = 11, fontWeight = "bold", color = "on_surface" }),
                        }),
                    }

                    local right_meta = {}
                    if q.unlimited then
                        table.insert(right_meta, ui.label({
                            text = noctalia.tr("panel.unlimited"),
                            fontSize = 10,
                            color = "primary",
                        }))
                    else
                        table.insert(right_meta, ui.label({
                            text = string.format("%.0f%%", rem_pct),
                            fontSize = 11,
                            fontWeight = "bold",
                            color = dot_color,
                        }))
                    end

                    if reset_label ~= "" then
                        table.insert(right_meta, ui.label({
                            text = "· " .. reset_label,
                            fontSize = 10,
                            color = "on_surface_variant",
                        }))
                    end

                    table.insert(quota_row_parts, ui.row({ align = "center", gap = 4 }, right_meta))

                    local quota_item_col = {
                        ui.row({ align = "center", justify = "space_between" }, quota_row_parts),
                    }

                    if not q.unlimited then
                        table.insert(quota_item_col, ui.row({
                            fill = "surface_variant/0.5",
                            radius = 3,
                            height = 5,
                        }, {
                            ui.row({
                                fill = dot_color,
                                radius = 3,
                                height = 5,
                                flexGrow = math.max(1, math.floor(rem_pct)),
                            }),
                            ui.row({
                                height = 5,
                                flexGrow = math.max(0, 100 - math.floor(rem_pct)),
                            }),
                        }))
                    end

                    table.insert(card_children, ui.column({ gap = 4 }, quota_item_col))
                end
            end

            table.insert(items, ui.column({
                key = "quotas-prov-" .. (prov.provider or tostring(idx)),
                fill = "surface_variant/0.25",
                radius = 8,
                padding = 10,
                gap = 8,
            }, card_children))
        end
    end

    -- Footer Actions
    table.insert(items, ui.row({ key = "quotas-footer", gap = 8, align = "center" }, {
        ui.button({
            text = noctalia.tr("panel.open_dashboard"),
            variant = "default",
            onClick = open_dashboard,
        }),
        ui.button({
            text = noctalia.tr("panel.refresh"),
            variant = "ghost",
            glyph = "refresh",
            onClick = refresh_data,
        }),
    }))

    return items
end

-- ── Main Render ─────────────────────────────────────────────────────────────

function render()
    local content = {}

    -- 1. Header (Title + Settings button + Close button)
    table.insert(content, ui.row({ key = "panel-header", align = "center", justify = "space_between", gap = 8 }, {
        ui.row({ align = "center", gap = 8 }, {
            ui.glyph({ name = "route", size = 20, color = "primary" }),
            ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold", color = "on_surface" }),
        }),
        ui.row({ align = "center", gap = 4 }, {
            ui.button({
                glyph = "settings",
                variant = "ghost",
                glyphSize = 15,
                tooltip = "Settings",
                onClick = function()
                    noctalia.openSettings()
                end,
            }),
            ui.button({
                glyph = "x",
                variant = "ghost",
                glyphSize = 16,
                onClick = function()
                    panel.close()
                end,
            }),
        }),
    }))

    -- 2. Navigation Tabs (Activity, Models, Quotas)
    table.insert(content, render_tabs())

    -- 3. Body View
    local view_items
    if selected_tab == "quotas" then
        view_items = render_quotas_view()
    elseif selected_tab == "models" then
        view_items = render_models_view()
    else
        view_items = render_activity_view()
    end

    table.insert(content, ui.scroll({
        key = "scroll-" .. selected_tab,
        flexGrow = 1,
        gap = 10,
        align = "stretch",
    }, view_items))

    panel.render(ui.column({
        flexGrow = 1,
        gap = 10,
        align = "stretch",
    }, content))
end

-- ── State Watcher ───────────────────────────────────────────────────────────

local function on_status_changed(new_status)
    if type(new_status) == "table" then
        status = new_status
        render()
    end
end

noctalia.state.watch("9router.status", on_status_changed)

noctalia.state.watch("9router.active_tab", function(new_tab)
    if type(new_tab) == "string" and (new_tab == "activity" or new_tab == "models" or new_tab == "quotas") then
        if selected_tab ~= new_tab then
            selected_tab = new_tab
            render()
        end
    end
end)

function onIpc(event, payload)
    local ev = tostring(event or ""):lower():match("^%s*(.-)%s*$")
    if ev == "set-tab" or ev == "tab" then
        local t = tostring(payload or ""):lower():match("^%s*(.-)%s*$")
        set_tab(t)
    elseif ev == "next-tab" or ev == "cycle-tab" then
        if selected_tab == "activity" then
            set_tab("models")
        elseif selected_tab == "models" then
            set_tab("quotas")
        else
            set_tab("activity")
        end
    elseif ev == "prev-tab" then
        if selected_tab == "activity" then
            set_tab("quotas")
        elseif selected_tab == "quotas" then
            set_tab("models")
        else
            set_tab("activity")
        end
    elseif ev == "activity" or ev == "models" or ev == "quotas" then
        set_tab(ev)
    elseif ev == "refresh" then
        refresh_data()
    elseif ev == "open-dashboard" then
        open_dashboard()
    elseif ev == "logout" then
        logout()
    end
end

function onOpen(_context)
    local cur = noctalia.state.get("9router.status")
    if type(cur) == "table" then
        status = cur
    end
    local saved_tab = noctalia.state.get("9router.active_tab")
    if type(saved_tab) == "string" and (saved_tab == "activity" or saved_tab == "models" or saved_tab == "quotas") then
        selected_tab = saved_tab
    end
    noctalia.state.set("9router.command", { action = "refresh_quotas" })
    render()
end

function onClose()
end
