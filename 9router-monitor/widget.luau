--!nonstrict
-- 9Router Monitor — Bar Widget Pill.
-- Displays the 9Router status in the bar:
--   • Idle: shows "last: <model>" (or glyph-only) in neutral color
--   • Busy (traffic in flight): lights up in primary accent with active model
--   • Expired: shows "login needed" in error color
--   • Offline: shows "offline"
-- Gestures:
--   • Left click: toggles the 9Router popup panel
--   • Right click: opens the 9Router web dashboard in browser
--   • Middle click: triggers immediate refresh

noctalia.setUpdateInterval(1000)

local current_status = {
    auth = "unknown",
    busy = false,
    display_model = "",
    last_model = "",
    last_provider = "",
    last_fetch_text = "",
    base_url = "http://localhost:20128",
    show_model_label = true,
}

local function clean_short_model(model_name)
    if type(model_name) ~= "string" or model_name == "" then
        return ""
    end
    -- Strip provider prefixes like "kr/", "openrouter/", etc.
    local slash = model_name:match(".*/(.*)")
    if slash and slash ~= "" then
        return slash
    end
    return model_name
end

local function apply_display(s)
    if type(s) == "table" then
        current_status = s
    end

    local show_label = current_status.show_model_label
    if show_label == nil then
        local cfg = noctalia.getConfig("show_model_label")
        show_label = (cfg ~= false)
    end

    local auth = current_status.auth or "unknown"
    local busy = current_status.busy == true
    local raw_model = ""
    if current_status.display_model and current_status.display_model ~= "" then
        raw_model = current_status.display_model
    elseif current_status.last_model and current_status.last_model ~= "" then
        raw_model = current_status.last_model
    end
    local disp_model = clean_short_model(raw_model)

    local glyph = "route"
    local glyph_color = "on_surface_variant"
    local text = ""
    local text_color = "on_surface"

    if auth == "expired" then
        glyph = "lock"
        glyph_color = "error"
        text = noctalia.tr("status.login_needed")
        text_color = "error"
    elseif busy then
        glyph = "bolt"
        glyph_color = "primary"
        text = if disp_model ~= "" then disp_model else noctalia.tr("status.working")
        text_color = "primary"
    elseif auth == "ok" then
        glyph = "route"
        glyph_color = "on_surface_variant"
        if disp_model ~= "" then
            text = "last: " .. disp_model
        else
            text = noctalia.tr("status.no_requests")
        end
        text_color = "on_surface"
    elseif auth == "offline" then
        glyph = "cloud-off"
        glyph_color = "on_surface_variant"
        text = noctalia.tr("status.offline")
        text_color = "on_surface_variant"
    else
        -- Booting / unknown
        glyph = "route"
        glyph_color = "on_surface_variant"
        text = "…"
        text_color = "on_surface_variant"
    end

    barWidget.setGlyph(glyph)
    barWidget.setGlyphColor(glyph_color)

    if show_label then
        barWidget.setText(text)
        barWidget.setColor(text_color)
    else
        barWidget.setText("")
    end

    -- Rich multi-row tooltip
    local rows = {}
    if auth == "expired" then
        table.insert(rows, { noctalia.tr("panel.title"), noctalia.tr("tooltip.expired") })
    elseif busy then
        table.insert(rows, { noctalia.tr("tooltip.in_flight"), raw_model })
        if current_status.last_provider and current_status.last_provider ~= "" then
            table.insert(rows, { "Provider", current_status.last_provider })
        end
    elseif auth == "ok" then
        if raw_model ~= "" then
            table.insert(rows, { noctalia.tr("tooltip.last_model"), raw_model })
            if current_status.last_provider and current_status.last_provider ~= "" then
                table.insert(rows, { "Provider", current_status.last_provider })
            end
        else
            table.insert(rows, { noctalia.tr("panel.title"), noctalia.tr("status.no_requests") })
        end
    else
        table.insert(rows, { noctalia.tr("panel.title"), noctalia.tr("tooltip.offline") })
    end

    if current_status.last_fetch_text and current_status.last_fetch_text ~= "" then
        table.insert(rows, { "Updated", current_status.last_fetch_text })
    end

    barWidget.setTooltip(rows)
end

function onClick()
    noctalia.togglePanel("bardiz12/9router-monitor:panel")
end

function onRightClick()
    local base = current_status.base_url or "http://localhost:20128"
    noctalia.runAsync({ "xdg-open", base .. "/dashboard/usage" })
end

function onMiddleClick()
    noctalia.state.set("9router.command", { action = "refresh" })
end

-- Subscribe to shared state updates
apply_display(noctalia.state.get("9router.status"))
noctalia.state.watch("9router.status", apply_display)

function update()
    apply_display(current_status)
end
