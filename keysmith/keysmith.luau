--!nonstrict
-- keysmith — bar widget that toggles the generator panel.
--
-- The panel (panel.luau) publishes its open state on the shared
-- "keysmith_open" state key; the glyph lights up while it is open.

local PANEL_ID = "nightwatch75/keysmith:panel"

local open = false

local function render()
    barWidget.setGlyph(noctalia.getConfig("glyph"))
    barWidget.setGlyphColor(open and "primary" or "on_surface")
    barWidget.setTooltip(noctalia.tr("tooltip"))
end

noctalia.state.watch("keysmith_open", function(value)
    open = value == true
    render()
end)

-- Periodic re-render keeps the glyph in sync with settings changes.
function update()
    render()
end

function onClick()
    noctalia.togglePanel(PANEL_ID)
end

noctalia.setUpdateInterval(1000)
render()
