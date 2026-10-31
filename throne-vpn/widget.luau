--!nonstrict
local tr = noctalia.tr
local function render()
    local data = noctalia.state.get("snapshot")
    local busy = noctalia.state.get("busy") == true
    local glyph, color, title = "shield-off", "on_surface_variant", tr("widget.off")
    if type(data) ~= "table" then
        glyph, title = "loader", tr("widget.loading")
    elseif not data.ok then
        glyph, color, title = "alert-circle", "error", "Throne · " .. (data.error or tr("widget.unavailable"))
    else
        local status = data.status or {}
        local profile = status.profile or {}
        if busy or status.state == "connecting" or status.state == "stopping" or status.state == "starting" then
            glyph, color, title = "loader", "primary", tr("widget.busy")
        elseif status.state == "running" then
            if status.degraded ~= nil and status.degraded ~= false and status.degraded ~= "" then
                glyph, color, title = "shield-exclamation", "error", tr("widget.degraded")
            elseif status.tun then
                glyph, color, title = "shield-check", "primary", "VPN · " .. (profile.name or "Throne")
            else
                glyph, color, title = "shield-half", "secondary", tr("widget.proxy_prefix") .. (profile.name or "Throne")
            end
            for _, row in ipairs(data.profiles or {}) do
                if row.id == profile.id then
                    title = title .. "\n" .. row.ping .. " · ↓ " .. row.download .. " · ↑ " .. row.upload
                    break
                end
            end
        end
    end
    barWidget.setGlyph(glyph)
    barWidget.setGlyphColor(color)
    barWidget.setText("")
    barWidget.setTooltip(title .. "\n" .. tr("widget.controls"))
end

function onClick()
    noctalia.togglePanel("lonefrogg/throne-vpn:panel")
end

function onRightClick()
    -- A close request never toggles a closed panel back open, even when the
    -- compositor has already dismissed it on the pointer-down outside event.
    noctalia.state.set("close_request", (noctalia.state.get("close_request") or 0) + 1)
end

noctalia.state.watch("snapshot", function() render() end)
noctalia.state.watch("busy", function() render() end)
render()
