--!nonstrict
-- Bar widget: the active line, with the karaoke fill.
--
-- It owns no data: the service publishes the track and the lyrics and this
-- entry only draws them, so the search happens once no matter how many
-- surfaces are on screen.

local render = require("./lib/render.luau")
local model = require("./lib/lyrics.luau")
local state = require("./lib/state.luau")

-- 30 frames per second is what the karaoke needs to look smooth.
noctalia.setUpdateInterval(33)

-- Settings are read once and again when the user changes one: reading twenty
-- of them thirty times per second would be pointless work.
local settings = state.read(noctalia)

local function draw()
  local track = noctalia.state.get("track")
  local lyrics = noctalia.state.get("lyrics")
  local loading = noctalia.state.get("loading") == true

  if type(track) ~= "table" then
    -- Nothing playing: a music note instead of an empty slot, so the widget
    -- still shows where it is.
    barWidget.render(ui.row({ key = "widget", gap = 0, align = "center" }, {
      ui.glyph({ key = "widget-glyph", name = "music", size = 14, color = "on_surface_variant" }),
    }))
    barWidget.setTooltip(state.tooltip(track, noctalia.tr))
    return
  end

  barWidget.render(render.surface({
    ui = ui,
    model = model,
    tr = function(key)
      return noctalia.tr(key)
    end,
    lines = type(lyrics) == "table" and lyrics.lines or nil,
    position = state.position(track, noctalia.nowMs()),
    duration = tonumber(track.duration) or 0,
    cfg = state.karaoke(settings, noctalia.state.get("brain")),
    state = state.stateOf(track, lyrics, loading),
    mode = "widget",
    title = track.title,
    artist = track.artist,
  }))
  barWidget.setTooltip(state.tooltip(track, noctalia.tr))
end

function update()
  draw()
end

function onClick()
  noctalia.openPanel("faminec/lyrics-carousel:panel")
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

draw()
