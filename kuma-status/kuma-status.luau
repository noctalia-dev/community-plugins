--!nonstrict
-- kuma-status — bar widget: overall state at a glance, click opens the panel.
--
-- Renders "kuma_status_data" (from service.luau): [bar_label] [glyph] and, with
-- bar_display "counts", "<up> ▲ <down> ▼". Glyph colors are theme roles.
-- After a down toast the glyph and the down count blink until the panel opens.
-- The tooltip lists the down monitors and the http / TLS warnings.
local PANEL_ID = "nightwatch75/kuma-status:panel"
local DATA_KEY = "kuma_status_data"
local MAX_DOWN_NAMES = 8
local GREEN, RED = "#98c379", "#e06c75"

local ROLE = {
    up = "primary",
    pending = "tertiary",
    down = "error",
    idle = "on_surface_variant",
    offline = "on_surface_variant",
}

local SEEN_KEY = "kuma_status_seen" -- set by the panel when it opens
local BLINK_SECONDS = 10

local data = noctalia.state.get(DATA_KEY)
local seen = noctalia.state.get(SEEN_KEY)

-- After a "down" toast, until the panel is opened or BLINK_SECONDS pass.
local function blinkOpacity()
    local at = data and data.alertTs
    if at == nil or (seen or 0) >= at then return 1 end
    local age = os.time() - at
    if age < 0 or age >= BLINK_SECONDS then return 1 end
    return os.time() % 2 == 0 and 1 or 0.25
end

local function tooltip(summary, errors)
    local rows = {}
    local stamp = data and data.ts and noctalia.formatTime("%H:%M", data.ts) or ""
    local reason = errors and errors.metrics
    rows[1] = { key = noctalia.tr("tooltip"), value = reason or stamp }
    if summary and summary.color ~= "offline" then
        for i = 1, math.min(MAX_DOWN_NAMES, #summary.downNames) do
            rows[#rows + 1] = { key = summary.downNames[i], value = noctalia.tr("tooltip_down") }
        end
        local more = #summary.downNames - MAX_DOWN_NAMES
        if more > 0 then
            rows[#rows + 1] = { key = noctalia.tr("tooltip_more", { count = more }), value = "" }
        end
    end
    if data and data.plainHttp then
        rows[#rows + 1] = { key = noctalia.tr("tooltip_warn_http"), value = "" }
    end
    if data and data.insecureTls then
        rows[#rows + 1] = { key = noctalia.tr("tooltip_warn_tls"), value = "" }
    end
    return rows
end

local function render()
    local summary = data and data.summary
    local color = summary and summary.color or "offline"
    local children = {}
    local blink = blinkOpacity()
    local label = noctalia.getConfig("bar_label")
    if label == nil then label = "Kuma" end
    if label ~= "" then
        children[#children + 1] = ui.label({ key = "bar-label", text = label, color = "on_surface" })
    end
    children[#children + 1] = ui.glyph({
        key = "bar-glyph", name = noctalia.getConfig("glyph") or "heartbeat", size = 16, color = ROLE[color] or ROLE.offline, opacity = blink,
    })
    if noctalia.getConfig("bar_display") == "counts" then
        if summary == nil or color == "offline" then
            children[#children + 1] = ui.label({ key = "bar-dash", text = "—", color = "on_surface_variant" })
        else
            children[#children + 1] = ui.label({ key = "bar-up", text = tostring(summary.up), color = "on_surface" })
            children[#children + 1] = ui.label({ key = "bar-up-arrow", text = "▲", color = GREEN })
            children[#children + 1] = ui.label({ key = "bar-down", text = tostring(summary.down), color = "on_surface", opacity = blink })
            children[#children + 1] = ui.label({ key = "bar-down-arrow", text = "▼", color = RED, opacity = blink })
        end
    end
    barWidget.render(ui.row({ gap = 4, align = "center" }, children))
    barWidget.setTooltip(tooltip(summary, data and data.errors))
end

noctalia.state.watch(DATA_KEY, function(value)
    data = value
    render()
end)

noctalia.state.watch(SEEN_KEY, function(value)
    seen = value
    render()
end)

function update()
    render()
end

function onClick()
    noctalia.togglePanel(PANEL_ID)
end

noctalia.setUpdateInterval(1000)
render()
