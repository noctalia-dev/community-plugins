--!nonstrict
-- OmaVibes — bar widget entry point.
-- Toggles the OmaVibes panel and reflects current typing audio state.

local PANEL_ID = "viksit-garg/omavibes:panel"
local isPlaying = false
local currentPack = ""

local function render()
    local glyph = noctalia.getConfig("glyph") or "keyboard"
    barWidget.setGlyph(glyph)
    barWidget.setGlyphColor(isPlaying and "primary" or "on_surface_variant")

    if isPlaying and currentPack ~= "" then
        barWidget.setTooltip({
            { key = noctalia.tr("title"), value = currentPack },
            { key = "Status", value = "Active" },
            { key = "Click", value = noctalia.tr("tooltip") },
        })
    else
        barWidget.setTooltip({
            { key = noctalia.tr("title"), value = noctalia.tr("tooltip_off") },
            { key = "Click", value = noctalia.tr("tooltip") },
        })
    end
end

noctalia.state.watch("omavibes_playing", function(val)
    isPlaying = (val == true)
    render()
end)

noctalia.state.watch("omavibes_pack", function(val)
    currentPack = tostring(val or "")
    render()
end)

function onClick()
    noctalia.togglePanel(PANEL_ID)
end

function update()
    render()
end

noctalia.setUpdateInterval(2000)
render()
