--!nonstrict
-- file-search — bar widget that toggles the fuzzy search panel.
--
-- The panel (panel.luau) publishes its open state on the shared
-- "file_search_open" state key; the glyph lights up while it is open.
--
-- Click mapping:
--   Left click   — open/close the search panel
--   Right click  — open the search folder in the file manager
--
-- Middle click is deliberately not handled: every bar widget carries a built-in
-- `middle = settings-open-widget` binding, and a bound gesture is masked off the
-- widget's own input area, so an onMiddleClick here would never be called. The
-- manifest could reclaim it with `[widget.actions] middle = "none"` (plugin API
-- 14) — this plugin stays at the upstream behaviour instead.

local PANEL_ID = "nightwatch75/file-search:panel"

-- Only for searchRoot() and openPath(): the widget shows the folder in its
-- tooltip and opens it on a right click, and both have to mean exactly what
-- they mean in the panel (plugin_api >= 22 for the relative import).
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

-- Periodic re-render keeps the glyph and tooltip in sync with settings changes.
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
