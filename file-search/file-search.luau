--!nonstrict
-- file-search — bar widget that toggles the fuzzy search panel.
--
-- The panel (panel.luau) publishes its open state on the shared
-- "file_search_open" state key; the glyph lights up while it is open.
--
-- Click mapping:
--   Left click   — open/close the search panel
--   Right click  — open the search folder in the file manager
--   Middle click — copy the search folder path to the clipboard

local PANEL_ID = "nightwatch75/file-search:panel"

local open = false

local function shellQuote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function searchRoot()
    local dir = noctalia.getConfig("search_folder")
    if dir == nil or dir == "" then
        dir = noctalia.getenv("HOME") or "/tmp"
    else
        dir = noctalia.expandPath(dir)
    end
    dir = dir:gsub("/+$", "")
    if dir == "" then
        dir = "/"
    end
    return dir
end

local function render()
    barWidget.setGlyph(noctalia.getConfig("glyph"))
    local root = searchRoot()
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
    noctalia.runAsync("xdg-open " .. shellQuote(searchRoot()) .. " >/dev/null 2>&1")
end

function onMiddleClick()
    noctalia.copyToClipboard(searchRoot(), "text/plain")
    noctalia.notify(noctalia.tr("title"), noctalia.tr("copied_path"))
end

noctalia.setUpdateInterval(1000)
render()
