--!nonstrict
-- Spotify Lyrics Headless Service
-- Reads state written by the Python daemon and publishes to noctalia.state
-- so bar widgets, panels, and desktop widgets update reactively across any compositor.

local STATE_PATH = noctalia.expandPath("~/.cache/noctalia/lyrics/current.json")
local tickCount = 0

local function readState()
  local content = noctalia.readFile(STATE_PATH)
  if not content or content == "" then return nil end
  local ok, state = pcall(function() return noctalia.json.decode(content) end)
  if ok and type(state) == "table" then return state end
  return nil
end

function update()
  noctalia.setUpdateInterval(100)
  tickCount = tickCount + 1

  local state = readState()

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

  noctalia.state.set("lyricsTick", tickCount)
end
