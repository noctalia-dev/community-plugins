--!nonstrict
-- XWayland Indicator bar widget

local snapshot = { available = false, focused_window = nil, xwayland_windows = {} }

local function addWidgetTips()
    if #snapshot.xwayland_windows > 0 then
        local tooltip = {
            { noctalia.tr("tooltip.xwayland_windows") .. ":", tostring(#snapshot.xwayland_windows) },
        }
        for i, window in ipairs(snapshot.xwayland_windows) do
            table.insert(tooltip, { tostring(i) .. ":" .. (window.app_id or "Unknown"), window.title or "Unknown" })
        end
        barWidget.setTooltip(tooltip)
    else
        barWidget.setTooltip(noctalia.tr("tooltip.no_xwayland_windows"))
    end
end

local function render()
    -- The plugin only means anything on an Umbriel session: take no bar space
    -- anywhere else instead of showing a dead icon.
    if snapshot.available ~= true then
        barWidget.setVisible(false)
        return
    end

    if noctalia.getConfig("indicate_focused_only") then
        local focused_window = snapshot.focused_window
        if focused_window == nil then
            barWidget.setVisible(false)
            return
        end
        if focused_window.xwayland == true then
            barWidget.setVisible(true)
            barWidget.setGlyph(noctalia.getConfig("xwayland_glyph"))
            addWidgetTips()
            return
        end
    else
        if #snapshot.xwayland_windows > 0 then
            barWidget.setVisible(true)
            barWidget.setGlyph(noctalia.getConfig("xwayland_glyph"))
            addWidgetTips()
            return
        end
    end
    if noctalia.getConfig("hide_on_wayland") then
        barWidget.setVisible(false)
        return
    end
    barWidget.setVisible(true)
    barWidget.setGlyph(noctalia.getConfig("wayland_glyph"))
    addWidgetTips()
end

function update()
    render()
end

noctalia.state.watch("umbriel.state", function(value)
    if type(value) == "table" then
        snapshot = value
        render()
    end
end)

snapshot = noctalia.state.get("umbriel.state") or snapshot
render()
