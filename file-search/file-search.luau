--!nonstrict
-- file-search — bar widget that toggles the fuzzy search panel.
--
-- The panel publishes its open state on the "file_search_open" state key; the glyph lights up while it is open.
--
-- Click mapping:
--   Left click   — open/close the search panel
--   Right click  — open the search folder in the file manager

local PANEL_ID = "nightwatch75/file-search:panel"

local shared = require("./shared.luau")

local open = false

local function render()
    barWidget.setGlyph(noctalia.getConfig("glyph"))
    local root = shared.searchRoot()
    if open then
        barWidget.setGlyphColor("primary")
        barWidget.setTooltip(noctalia.tr("tooltip_open", { path = root }))
    else
        barWidget.setGlyphColor("on_surface")
        barWidget.setTooltip(noctalia.tr("tooltip_closed", { path = root }))
    end
end

noctalia.state.watch("file_search_open", function(value)
    open = value == true
    render()
end)

function update()
    render()
end

function onClick()
    noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
    shared.openPath(shared.searchRoot())
end

noctalia.setUpdateInterval(1000)
render()
