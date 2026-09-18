--!nonstrict
-- The media-state service publishes the active MPRIS playback state so every
-- island control stays in sync without its own polling loop.

local playing = false

local function render()
    barWidget.setGlyph(playing and "media-pause" or "media-play")
    barWidget.setText("")
    barWidget.setTooltip({
        { key = "Media", value = playing and "Pause" or "Play" },
    })
end

function update()
    noctalia.setUpdateInterval(1000)
    render()
end

noctalia.state.watch("player", function(player)
    local nextPlaying = type(player) == "table" and player.playing == true
    if nextPlaying ~= playing then
        playing = nextPlaying
        render()
    end
end)
