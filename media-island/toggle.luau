--!nonstrict
-- Standalone Play/Pause control driven by the shared player state.

local playing = false

local function render()
  barWidget.setGlyph(playing and "player-pause" or "player-play")
  barWidget.setText("")
  barWidget.setTooltip(noctalia.tr(playing and "panel.pause" or "panel.play"))
end

local function sync(player)
  local nextPlaying = type(player) == "table" and player.playing == true
  if nextPlaying ~= playing then
    playing = nextPlaying
    render()
  end
end

function update()
  noctalia.setUpdateInterval(1000)
  render()
end

noctalia.state.watch("player", sync)
sync(noctalia.state.get("player"))
render()
