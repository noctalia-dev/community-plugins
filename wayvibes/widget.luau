--!nonstrict
-- WayVibes — bar widget entry point.
-- Toggles the WayVibes panel and displays active typing audio status.

local PANEL_ID = "viksit-garg/wayvibes:panel"
-- Newly added widgets must reflect service state published before they existed.
local isPlaying = noctalia.state.get("wayvibes_playing") == true
local currentPack = tostring(noctalia.state.get("wayvibes_pack") or "")
local currentVolume = tonumber(noctalia.state.get("wayvibes_volume")) or 3

local function render()
    local glyph = noctalia.getConfig("glyph") or "keyboard"
    barWidget.setGlyph(glyph)
    barWidget.setGlyphColor(isPlaying and "primary" or "on_surface_variant")

    if isPlaying and currentPack ~= "" then
        barWidget.setTooltip({
            { key = noctalia.tr("title"), value = currentPack },
            { key = "Volume", value = tostring(currentVolume) .. "/10" },
            { key = "Click", value = noctalia.tr("tooltip") },
        })
    else
        barWidget.setTooltip({
            { key = noctalia.tr("title"), value = noctalia.tr("tooltip_off") },
            { key = "Click", value = noctalia.tr("tooltip") },
        })
    end
end

noctalia.state.watch("wayvibes_playing", function(val)
    isPlaying = (val == true)
    render()
end)

noctalia.state.watch("wayvibes_pack", function(val)
    currentPack = tostring(val or "")
    render()
end)

noctalia.state.watch("wayvibes_volume", function(val)
    if val then
        currentVolume = tonumber(val) or currentVolume
        render()
    end
end)

function onClick()
    noctalia.togglePanel(PANEL_ID)
end

function update()
    render()
end

noctalia.setUpdateInterval(2000)
render()
