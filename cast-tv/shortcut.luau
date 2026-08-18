--!strict

shortcut.setLabel("Cast to TV")
shortcut.setIcon("cast-off")
noctalia.setUpdateInterval(2000)

local lastActive = false

function update()
  noctalia.processMatches(function(matched: boolean)
    if matched ~= lastActive then
      lastActive = matched
      shortcut.setActive(matched)
      shortcut.setIcon(matched and "cast" or "cast-off")
    end
  end, "fluxcast", "--wfd-peer")
end

function onClick()
  noctalia.togglePanel("andresparrab/cast-tv:picker")
end
