 --!nonstrict

local locked = noctalia.state.get("iio-state")
local glyph_unlocked = barWidget.getConfig("unlocked")
local glyph_locked = barWidget.getConfig("locked")
local locked_text = noctalia.tr("widget.locked")
local unlocked_text = noctalia.tr("widget.unlocked")

local function render()
    shortcut.setLabel(if locked then locked_text else unlocked_text)
    if locked then
    shortcut.setIcon(glyph_locked)
    else
    shortcut.setIcon(glyph_unlocked)
    end
    shortcut.setActive(locked)
end

noctalia.state.watch("iio-state", function (value)
        locked = value
        render()
    end)

function onClick()
  locked = not locked
  noctalia.state.set("iio-state", locked)
  render()
end


-- Initial state at load.
render()