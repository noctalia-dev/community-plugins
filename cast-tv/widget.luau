--!strict

local lastActive = false

local function refreshIcon()
  noctalia.processMatches(function(matched: boolean)
    if matched ~= lastActive then
      lastActive = matched
      barWidget.setGlyph(matched and "cast" or "cast-off")
      barWidget.setGlyphColor(matched and "primary" or "on_surface")
    end
  end, "fluxcast", "--wfd-peer")
end

barWidget.setGlyph("cast-off")
barWidget.setTooltip("Cast to TV")
noctalia.setUpdateInterval(2000)

function update()
  refreshIcon()
end

function onClick()
  noctalia.togglePanel("andresparrab/cast-tv:picker")
end
