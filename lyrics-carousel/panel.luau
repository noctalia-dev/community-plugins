--!nonstrict
-- Panel: the full carousel, the header and the footer.
--
-- A display surface, not a settings form: the settings are declared in the
-- manifest, so Noctalia draws them in Settings → Plugins and this panel only
-- has to show the lyrics.

local render = require("./lib/render.luau")
local model = require("./lib/lyrics.luau")
local state = require("./lib/state.luau")

local settings = state.read(noctalia)
local opened = false

local function draw()
  local track = noctalia.state.get("track")
  local lyrics = noctalia.state.get("lyrics")
  local loading = noctalia.state.get("loading") == true

  panel.render(render.surface({
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
    mode = "panel",
    title = track and track.title or nil,
    artist = track and track.artist or nil,
  }))
end

function onOpen()
  opened = true
  settings = state.read(noctalia)
  -- The karaoke needs the fine tick only while the panel is on screen.
  noctalia.setUpdateInterval(33)
  draw()
end

function onClose()
  opened = false
  noctalia.setUpdateInterval(1000)
end

function update()
  if opened then
    draw()
  end
end

function onConfigChanged()
  settings = state.read(noctalia)
  if opened then
    draw()
  end
end

function onIpc(event, payload)
  if event == "refresh" and opened then
    settings = state.read(noctalia)
    draw()
  end
end
