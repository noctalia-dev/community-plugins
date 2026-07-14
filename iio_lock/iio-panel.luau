 --!nonstrict
 local glyph_unlocked = barWidget.getConfig("unlocked")
 local glyph_locked   = barWidget.getConfig("locked")

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

noctalia.state.watch("iio-state", function (value)
    locked = value
    apply_lock_state()
    render()
end)

function onClick()
     noctalia.togglePanel("nikolaj-zwergius/iio_lock:panel")
end

render()

