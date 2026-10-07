--!nonstrict
-- Bar widget: click opens the compact (laptop-tier) picker panel.

function onClick()
  noctalia.togglePanel("liamwh/emoji-picker:compact")
end

barWidget.setGlyph("mood-smile")
