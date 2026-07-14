 --!nonstrict
 -- Config
 local glyph_unlocked = noctalia.getConfig("unlocked")
 local glyph_locked   = noctalia.getConfig("locked")

 -- State
 local locked = false
 local glyph  = glyph_unlocked

local function render()
  barWidget.setGlyph(glyph)
end

local function apply_lock_state()
    if locked then
        glyph = glyph_locked
    else
        glyph = glyph_unlocked
    end
end

function onClick()
    locked = not locked
    noctalia.state.set("iio-state",locked)
    render()
end

noctalia.state.watch("iio-state", function (value)
    locked = value
    apply_lock_state()
    render()
end)

function onRightClick()
     noctalia.togglePanel("nikolaj-zwergius/iio_lock:panel")
end

render()
