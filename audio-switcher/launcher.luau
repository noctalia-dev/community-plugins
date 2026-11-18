--!nonstrict

local PANEL_ID = "blackbartblues/audio-switcher:audio-switcher"
local RESULT_ID = "open-panel"

local function resultFor(query)
  local title = noctalia.tr("launcher.open")
  local subtitle = noctalia.tr("launcher.description")
  local trimmed = noctalia.string.trim(tostring(query or ""))
  local score = 0

  if trimmed ~= "" then
    score = noctalia.fuzzyScore(trimmed, title .. " " .. subtitle)
    if score == nil then return nil end
  end

  return {
    id = RESULT_ID,
    title = title,
    subtitle = subtitle,
    glyph = "switch-horizontal",
    score = score,
  }
end

function onQuery(query)
  local result = resultFor(query)
  launcher.setResults(query, result and { result } or {})
end

function onActivate(id)
  if id == RESULT_ID then noctalia.togglePanel(PANEL_ID) end
end
