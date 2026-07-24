--!nonstrict
-- Minimal bar trigger: shows a small lyrics glyph next to the media widget.
-- Auto-hides when no music is playing. Click to toggle the lyrics panel.

local function readState()
  local content = noctalia.readFile("~/.cache/noctalia/lyrics/current.json")
  if not content then return nil end
  local state, _ = noctalia.json.decode(content)
  return state
end

local tickCount = 0

function update()
  noctalia.setUpdateInterval(100)
  tickCount = tickCount + 1
  noctalia.state.set("lyricsTick", tickCount)

  local state = readState()

  if not state or state.status == "Stopped" or state.status == "" then
    barWidget.setVisible(false)
    return
  end

  barWidget.setVisible(true)
  barWidget.setGlyph("music")
  barWidget.setText("")
  barWidget.setGlyphColor("primary")

  barWidget.setTooltip(state.current or "...")
end

function onClick()
  noctalia.togglePanel("noctalia/spotify-lyrics:lyrics-panel")
end
