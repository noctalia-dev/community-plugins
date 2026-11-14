--!nonstrict
local opened = false
local query = ""
local render
local tr = noctalia.tr

-- Noctalia 5.3 applies scroll.height as Flex min/max limits, but ScrollView's
-- measureByLayout bypasses them. Both the script root and its scroll child
-- must use flexGrow so the host assigns an exact available height through the
-- entire parent chain. Verified against the v5.3.0 Flex/ScrollView C++ sources.
local PADDING = 18
local GAP = 12
local HEADER_HEIGHT = 44
local STATUS_HEIGHT = 88
local SEARCH_HEIGHT = 32
local HEADING_HEIGHT = 20
local FOOTER_HEIGHT = 24
local ERROR_HEIGHT = 104

local function refresh()
    noctalia.state.set("refresh", (noctalia.state.get("refresh") or 0) + 1)
end

local function action(kind, id)
    if noctalia.state.get("busy") == true then return end
    noctalia.state.set("action", {
        kind = kind, id = id,
        serial = (noctalia.state.get("action_serial") or 0) + 1,
    })
    noctalia.state.set("action_serial", (noctalia.state.get("action_serial") or 0) + 1)
end

local function label(text, props)
    props = props or {}
    props.text = text
    return ui.label(props)
end

local function metric(text, width, color)
    return label(text, { width = width, fontSize = 12, textAlign = "end", color = color or "on_surface_variant" })
end

render = function()
    if not opened then return end
    local data = noctalia.state.get("snapshot")
    local valid = type(data) == "table" and data.ok == true
    local status = valid and data.status or {}
    local current = status.profile or {}
    local busy = noctalia.state.get("busy") == true
    local changing = busy or status.state == "connecting" or status.state == "stopping" or status.state == "starting"
    local active = status.state == "running"
    local activeTun = active and status.tun == true
    local stateText = tr("status.off")
    local stateGlyph = "shield-off"
    if not valid then
        stateText, stateGlyph = tr("status.unavailable"), "alert-circle"
    elseif busy or status.state == "starting" then
        stateText, stateGlyph = tr("status.busy"), "loader"
    elseif status.state == "connecting" then
        stateText, stateGlyph = tr("status.connecting"), "loader"
    elseif status.state == "stopping" then
        stateText, stateGlyph = tr("status.stopping"), "loader"
    elseif activeTun then
        stateText, stateGlyph = tr("status.tun"), "shield-check"
    elseif active then
        stateText, stateGlyph = tr("status.proxy"), "shield-half"
    end
    local children = {
        ui.row({ key = "header", height = HEADER_HEIGHT, gap = 10, align = "center" }, {
            ui.glyph({ name = "shield", size = 24, color = "primary" }),
            ui.column({ flexGrow = 1, gap = 2 }, {
                label("Throne", { fontSize = 21, fontWeight = "bold" }),
                label(tr("panel.subtitle"), { fontSize = 12, color = "on_surface_variant" }),
            }),
            ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm", tooltip = tr("panel.refresh"), onClick = refresh, enabled = not busy }),
            ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", tooltip = tr("panel.close"), onClick = function() panel.close() end }),
        }),
        ui.row({ key = "status", height = STATUS_HEIGHT, gap = 12, padding = 14, radius = 16, fill = activeTun and "primary/0.12" or "surface", align = "center" }, {
            ui.glyph({ name = stateGlyph, size = 28, color = activeTun and "primary" or "on_surface_variant" }),
            ui.column({ gap = 4, flexGrow = 1 }, {
                label(stateText, { fontSize = 14, fontWeight = "semibold", color = activeTun and "primary" or "on_surface" }),
                label(current.name or tr("panel.choose"), { fontSize = 12, maxWidth = 420, maxLines = 1 }),
                label(tr("panel.route_prefix") .. ((status.route or {}).name or tr("panel.current_route")), { fontSize = 11, color = "on_surface_variant" }),
            }),
            ui.button({ text = active and tr("panel.disconnect") or tr("panel.last"), glyph = active and "power" or "player-play", variant = active and "secondary" or "primary", controlSize = "sm", enabled = valid and not changing and (active or (status.last_profile_id or -1) >= 0), onClick = function()
                if active then action("disconnect") else action("connect", "last") end
            end }),
        }),
    }
    local detail = noctalia.state.get("action_error")
    if not valid then
        detail = type(data) == "table" and data.error or tr("status.loading")
    elseif status.degraded ~= nil and status.degraded ~= false and status.degraded ~= "" then
        detail = tr("panel.degraded_prefix") .. tostring(status.degraded)
    elseif (not detail or detail == "") and (status.capabilities or {}).tun == false then
        detail = tr("panel.permissions")
    end
    local hasDetail = detail and detail ~= ""
    if hasDetail then
        table.insert(children, ui.column({ key = "error", height = ERROR_HEIGHT, padding = 12, radius = 12, fill = "error/0.1" }, {
            label(detail, { fontSize = 12, maxWidth = 670, maxLines = 5, color = "error" }),
        }))
    end
    table.insert(children, ui.input({ key = "search", height = SEARCH_HEIGHT, value = query, placeholder = tr("panel.search"), controlSize = "sm", onChange = function(value)
        query = value
        render()
    end }))
    table.insert(children, ui.row({ key = "headings", height = HEADING_HEIGHT, gap = 8, paddingH = 12, align = "center" }, {
        label(tr("panel.server"), { flexGrow = 1, fontSize = 11, color = "on_surface_variant" }),
        metric("Ping", 60), metric("↓ Mbps", 90), metric("↑ Mbps", 90),
    }))
    local rows = {}
    if valid then
        for _, item in ipairs(data.profiles or {}) do
            local row = item
            if query == "" or noctalia.fuzzyScore(query, row.name) ~= nil then
                local selected = active and current.id == row.id
                local tested = row.download_bps > 0
                local id = row.id
                table.insert(rows, ui.column({ key = "profile-" .. tostring(id), gap = 5, padding = 12, radius = 12, fill = selected and "primary/0.12" or "surface", border = selected and "primary/0.55" or "on_surface_variant/0.15", borderWidth = 1, onClick = function()
                    if not changing and not (selected and activeTun) then action("connect", id) end
                end }, {
                    ui.row({ gap = 8, align = "center" }, {
                        ui.glyph({ name = selected and "circle-check" or "circle", size = 17, color = selected and "primary" or "on_surface_variant" }),
                        label(row.name, { flexGrow = 1, maxWidth = 325, maxLines = 1, fontSize = 13, fontWeight = selected and "bold" or "medium" }),
                        metric(row.ping, 60),
                        metric(row.download, 90, tested and "primary" or "on_surface_variant"),
                        metric(row.upload, 90, row.upload_bps > 0 and "primary" or "on_surface_variant"),
                    }),
                    ui.row({ paddingH = 25, gap = 8 }, {
                        label("Σ ↓ " .. row.traffic_down_text .. "   ↑ " .. row.traffic_up_text, { fontSize = 10, color = "on_surface_variant", flexGrow = 1 }),
                        label(row.country .. " · " .. row.type .. " · #" .. tostring(id), { fontSize = 10, color = "on_surface_variant" }),
                    }),
                }))
            end
        end
    end
    if #rows == 0 then
        table.insert(rows, label(valid and tr("panel.empty") or tr("panel.waiting"), { fontSize = 13, color = "on_surface_variant" }))
    end
    -- Grow within the exact height allocated by the parent, never to the full
    -- content height. These new keys discard retained height limits from 2.0.1;
    -- they stay stable on subsequent refreshes to preserve the scroll offset.
    table.insert(children, ui.scroll({ key = "profiles-flex", flexGrow = 1, gap = 7, paddingV = 4, paddingH = 2 }, rows))
    table.insert(children, label(tr("panel.footer"), { key = "footer", height = FOOTER_HEIGHT, fontSize = 10, color = "on_surface_variant", maxLines = 2 }))
    panel.render(ui.column({ key = "throne-panel-flex", flexGrow = 1, padding = PADDING, gap = GAP }, children))
end

function onOpen(_context)
    opened = true
    query = ""
    noctalia.state.set("panel_open", true)
    render()
    refresh()
end

function onClose()
    opened = false
    noctalia.state.set("panel_open", false)
end

noctalia.state.watch("snapshot", function() render() end)
noctalia.state.watch("busy", function() render() end)
noctalia.state.watch("action_error", function() render() end)
noctalia.state.watch("close_request", function()
    if opened then panel.close() end
end)
