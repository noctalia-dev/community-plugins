--!nonstrict

-- Visibility settings
local hideStopped = noctalia.getConfig("hide_stopped")

-- Glyph settings
local playingGlyph = noctalia.getConfig("playing_glyph")
local pausedGlyph = noctalia.getConfig("paused_glyph")
local stoppedGlyph = noctalia.getConfig("stopped_glyph")

-- Color settings
local playingColor = noctalia.getConfig("playing_color")
local pausedColor = noctalia.getConfig("paused_color")
local stoppedColor = noctalia.getConfig("stopped_color")

-- Initial state
local snapshot = {
  hasError = false,
  hasPlayer = false,
  status = "",
}

-- Update the bar widget
local function render()
  if snapshot.hasError or not snapshot.hasPlayer then
    barWidget.setVisible(false)
    return
  end

  if hideStopped and snapshot.status == "Stopped" then
    barWidget.setVisible(false)
    return
  end

  local glyph
  local color

  if snapshot.status == "Playing" then
    glyph = playingGlyph
    color = playingColor
  elseif snapshot.status == "Paused" then
    glyph = pausedGlyph
    color = pausedColor
  elseif snapshot.status == "Stopped" then
    glyph = stoppedGlyph
    color = stoppedColor
  end

  -- Hide if the status is unknown or the glyph is empty
  if not glyph or glyph == "" then
    barWidget.setVisible(false)
    return
  end

  barWidget.setVisible(true)
  barWidget.render(
    ui.glyph({
      name = glyph,
      color = color,
    })
  )
end

-- Render on media player state changes
noctalia.state.watch("media-player-icon", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

-- Initial render
snapshot = noctalia.state.get("media-player-icon") or snapshot
render()
