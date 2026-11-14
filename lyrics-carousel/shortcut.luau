--!nonstrict
-- Control-center tile: the per-track karaoke break.
--
-- This is the "brain" of the old panel: one press paints the current song
-- without the fill, and the service gives the fill back when the track
-- changes. It writes plugin state, so the bar, the panel and the desktop
-- widget all follow the same switch.

local function brainOn()
  return noctalia.state.get("brain") ~= false
end

local function render()
  local on = brainOn()
  shortcut.setLabel(on and noctalia.tr("shortcut.glow_on") or noctalia.tr("shortcut.glow_off"))
  shortcut.setIcon("music")
  shortcut.setActive(on)
end

function onClick()
  noctalia.state.set("brain", not brainOn())
  render()
end

function onIpc(event, payload)
  if event == "brain" then
    noctalia.state.set("brain", not brainOn())
    render()
  end
end

function onConfigChanged()
  render()
end

noctalia.state.watch("brain", function()
  render()
end)

render()
