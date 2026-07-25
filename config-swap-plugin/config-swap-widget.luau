--!nonstrict
-- Daily Wallpaper service for Noctalia 5.
-- Fetches one Bing or NASA image per day, caches it locally, and applies it via
-- the native Noctalia wallpaper API.

function update()
  noctalia.setUpdateInterval(1000)
  barWidget.setGlyph("file")
end

function onClick()
  noctalia.togglePanel("tadomika_ari/config-swap:panel")
end