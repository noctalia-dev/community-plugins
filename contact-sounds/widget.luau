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

-- Contacts are owned by the service and published through noctalia.state
-- ("contacts.data"); the app-managed settings.toml config is only seeded on
-- first run, so counting getConfig("contacts") shows a stale, partial list.
-- Prefer the published state, falling back to config before the service has
-- published (e.g. while the plugin is still starting).
local function readContacts()
    local d = noctalia.state.get("contacts.data")
    if type(d) == "table" and type(d.contacts) == "table" then
        return d.contacts
    end
    return noctalia.getConfig("contacts") or {}
end

local function refresh()
    local contacts = readContacts()
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

noctalia.state.watch("contacts.data", function(d)
    if type(d) == "table" then
        refresh()
    end
end)