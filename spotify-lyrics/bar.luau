--!nonstrict
-- Minimal bar trigger: shows a small lyrics glyph next to the media widget.
-- Auto-hides when no music is playing. Click to toggle the lyrics panel.

local STATE_PATH = noctalia.expandPath("~/.cache/noctalia/lyrics/current.json")

local function readState()
  local content = noctalia.readFile(STATE_PATH)
  if not content or content == "" then return nil end
  local ok, state = pcall(function() return noctalia.json.decode(content) end)
  if ok and type(state) == "table" then return state end
  return nil
end

function update()
  noctalia.setUpdateInterval(100)

  local status = noctalia.state.get("lyricsStatus")
  local current = noctalia.state.get("lyricsCurrent")

  -- Fallback to direct file read if service has not published yet
  if not status or status == "" then
    local fileState = readState()
    if fileState then
      status = fileState.status or ""
      current = fileState.current or ""
    end
  end

  if not status or status == "Stopped" or status == "" then
    barWidget.setVisible(false)
    return
  end

  barWidget.setVisible(true)
  barWidget.setGlyph("music")
  barWidget.setText("")
  barWidget.setGlyphColor("primary")
  barWidget.setTooltip(current or "...")
end

function onClick()
  noctalia.togglePanel("goatnath/spotify-lyrics:lyrics-panel")
end
