--!nonstrict
-- Opens the panel from the launcher, without any setup: "/hyprland", or
-- words like "hyprland", "monitor" or "keyboard" in the normal search.

local KEYWORDS = {
  "hyprland settings", "hyprland einstellungen", "display monitor screen bildschirm",
  "keyboard layout tastatur", "touchpad mouse maus", "gaps blur animations",
}

function onQuery(text)
  local query = noctalia.string.trim(text or ""):lower()
  local best = nil
  if query == "" then
    best = 1
  else
    for _, words in ipairs(KEYWORDS) do
      local score = noctalia.fuzzyScore(query, words)
      if score ~= nil and (best == nil or score > best) then best = score end
    end
  end
  if best == nil then
    launcher.setResults(text, {})
    return
  end
  launcher.setResults(text, { {
    id = "open", title = noctalia.tr("launcher.title"), subtitle = noctalia.tr("launcher.subtitle"),
    glyph = "adjustments", score = best,
  } })
end

function onActivate(_id)
  noctalia.togglePanel("michael-retunzew/hyprland-settings:panel")
end
