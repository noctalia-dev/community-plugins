--!nonstrict
-- Control Center shortcut tile for Wallpaper Deck

function render()
  return ui.button({
    text = "Wallpapers",
    glyph = "cards",
    variant = "secondary",
    controlSize = "md",
    onClick = function()
      noctalia.togglePanel("ishan0121/wallpaper-deck:picker")
    end,
  })
end
