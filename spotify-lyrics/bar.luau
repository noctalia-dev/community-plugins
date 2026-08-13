--!nonstrict
-- Minimal bar trigger: shows a small lyrics glyph next to the media widget.
-- Auto-hides when no music is playing. Click to toggle the lyrics panel.
--
-- Also acts as the data bridge: reads the daemon's JSON file and publishes
-- all lyrics fields into noctalia.state so the panel can reactively consume
-- them without polling the filesystem itself.

local STATE_PATH = noctalia.expandPath("~/.cache/noctalia/lyrics/current.json")

local function readState()
  local content = noctalia.readFile(STATE_PATH)
  if not content then return nil end
  local state, _ = noctalia.json.decode(content)
  return state
end

local tickCount = 0

function update()
  noctalia.setUpdateInterval(100)
  tickCount = tickCount + 1

  local state = readState()

  -- Publish every field the panel/widget needs into noctalia.state.
  -- Each .set() call notifies any panel that called .get() on the same key,
  -- which is what makes the panel re-render reactively.
  if state then
    noctalia.state.set("lyricsStatus",   state.status   or "")
    noctalia.state.set("lyricsTitle",    state.title    or "")
    noctalia.state.set("lyricsArtist",   state.artist   or "")
    noctalia.state.set("lyricsPrevPrev", state.prev_prev or "")
    noctalia.state.set("lyricsPrev",     state.prev     or "")
    noctalia.state.set("lyricsCurrent",  state.current  or "")
    noctalia.state.set("lyricsNext",     state.next     or "")
    noctalia.state.set("lyricsNextNext", state.next_next or "")
    noctalia.state.set("lyricsArtPath",  state.art_path or "")
  else
    noctalia.state.set("lyricsStatus", "")
  end

  -- Bump tick last so the panel can also use it as a generic change signal
  noctalia.state.set("lyricsTick", tickCount)

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
  noctalia.togglePanel("goatnath/spotify-lyrics:lyrics-panel")
end
