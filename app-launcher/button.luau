--!nonstrict
-- Bar button: toggles the launcher panel.

local PANEL = "xrtsx/app-launcher:launcher"
local PANELS = {
    small = "xrtsx/app-launcher:launcher",
    medium = "xrtsx/app-launcher:launcher_medium",
    large = "xrtsx/app-launcher:launcher_large",
    xl = "xrtsx/app-launcher:launcher_xl",
}

local function render()
    barWidget.setGlyph("apps")
    barWidget.setTooltip("App Launcher")
end

function update()
    noctalia.setUpdateInterval(60000)
    render()
end

function onClick()
    noctalia.togglePanel(PANELS[noctalia.getConfig("panel_size")] or PANEL)
end

render()
