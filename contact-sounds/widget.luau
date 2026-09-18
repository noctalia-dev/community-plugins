--!nonstrict
-- widget.luau
-- Bar widget: bell icon that opens the contact sounds panel

local contactCount = 0

local function render()
    if noctalia.getConfig("show_widget") == false then
        barWidget.setVisible(false)
        return
    end
    barWidget.setVisible(true)
    local glyphName = noctalia.getConfig("glyph") or "bell-ringing"
    local children = {}
    if contactCount > 0 then
        table.insert(children, ui.glyph({ name = glyphName, size = 18, color = "primary" }))
    else
        table.insert(children, ui.glyph({ name = glyphName, size = 18, color = "on_surface" }))
    end
    local container = barWidget.isVertical() and ui.column or ui.row
    barWidget.render(container({ gap = 4, align = "center" }, children))

    if contactCount == 0 then
        barWidget.setTooltip(noctalia.tr("widget.tooltip_empty"))
    else
        barWidget.setTooltip(string.format(noctalia.tr("widget.tooltip_ok"), contactCount))
    end
end

local function refresh()
    local contacts = noctalia.getConfig("contacts") or {}
    contactCount = 0
    for _ in pairs(contacts) do
        contactCount = contactCount + 1
    end
    render()
end

refresh()

function update()
    noctalia.setUpdateInterval(10000)
    refresh()
end

function onConfigChanged()
    refresh()
end

function onClick()
    noctalia.togglePanel("nilsonlinux/contact-sounds:Panel")
end

function onRightClick()
    noctalia.togglePanel("nilsonlinux/contact-sounds:Panel")
end