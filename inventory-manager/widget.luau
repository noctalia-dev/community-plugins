--!nonstrict
-- widget.luau
-- Bar widget showing inventory status

local totalProducts = 0
local lowStockCount = 0

local function render()
    local children = {}
    local glyphName = noctalia.getConfig("glyph") or "package"
    local showBadge = noctalia.getConfig("show_low_stock_badge")
    if lowStockCount > 0 and showBadge then
        table.insert(children, ui.row({
            fill = "#c62828",
            radius = 8,
            paddingH = 5,
            paddingV = 1,
            align = "center",
            justify = "center"
        }, {
            ui.label({ text = tostring(lowStockCount), fontSize = 10, fontWeight = "bold", color = "#ffffff" })
        }))
        table.insert(children, ui.glyph({ name = glyphName, size = 14, color = "#c62828" }))
    elseif totalProducts > 0 then
        table.insert(children, ui.glyph({ name = glyphName, size = 14, color = "#2e7d32" }))
    else
        table.insert(children, ui.glyph({ name = glyphName, size = 14, color = "on_surface" }))
    end
    local container = barWidget.isVertical() and ui.column or ui.row
    barWidget.render(container({ gap = 4, align = "center" }, children))

    -- Tooltip using translations
    if totalProducts == 0 then
        barWidget.setTooltip(noctalia.tr("widget.tooltip_empty"))
    elseif lowStockCount > 0 then
        barWidget.setTooltip(string.format(noctalia.tr("widget.tooltip_low"), lowStockCount))
    else
        barWidget.setTooltip(noctalia.tr("widget.tooltip_ok"))
    end
end

-- Watch for updates
noctalia.state.watch("inventory.total", function(value)
    totalProducts = value or 0
    render()
end)

noctalia.state.watch("inventory.low_stock_count", function(value)
    lowStockCount = value or 0
    render()
end)

-- Also watch for product changes
noctalia.state.watch("inventory.products", function(value)
    render()
end)

-- Initial render
render()

function update()
    noctalia.setUpdateInterval(5000)
    render()
end

function onConfigChanged()
    render()
end

function onClick()
    noctalia.togglePanel("nilsonlinux/inventory-manager:inventory-panel")
end

function onRightClick()
    noctalia.state.set("inventory.cmd", { op = "refresh" })
    noctalia.notify(noctalia.tr("panel.title"), noctalia.tr("widget.refreshing"))
end
