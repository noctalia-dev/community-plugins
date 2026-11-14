--!nonstrict
-- Desktop widget: the carousel on the wallpaper.
--
-- The host owns the position and the size, so this entry only renders the
-- same surface as the panel and lets the settings decide what it shows.

local render = require("./lib/render.luau")
local model = require("./lib/lyrics.luau")
local state = require("./lib/state.luau")

-- The desktop widget is a picture, not a control: 30 frames per second only
-- while something is playing, and one redraw per second otherwise.
noctalia.setUpdateInterval(33)

local settings = state.read(noctalia)

local function draw()
  local track = noctalia.state.get("track")
  local lyrics = noctalia.state.get("lyrics")
  local loading = noctalia.state.get("loading") == true

  desktopWidget.render(render.surface({
    ui = ui,
    model = model,
    tr = function(key)
      return noctalia.tr(key)
    end,
    lines = type(lyrics) == "table" and lyrics.lines or nil,
    position = state.position(track, noctalia.nowMs()),
    duration = tonumber(track and track.duration) or 0,
    cfg = state.karaoke(settings, noctalia.state.get("brain")),
    state = state.stateOf(track, lyrics, loading),
    mode = "desktop",
    title = track and track.title or nil,
    artist = track and track.artist or nil,
  }))
end

function update()
  draw()
end

function onConfigChanged()
  settings = state.read(noctalia)
  draw()
end

function onIpc(event, payload)
  if event == "refresh" then
    draw()
  end
end

function onExit(signal, reason)
  -- Nothing to release: the tree is owned by the host.
end

draw()
