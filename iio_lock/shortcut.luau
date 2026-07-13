local locked = noctalia.state.get("iio-state")
local glyph_unlocked = barWidget.getConfig("unlocked")
local glyph_locked = barWidget.getConfig("locked")

local function render()
    shortcut.setLabel(if locked then "Locked" else "Unlocked")
    if locked then
    shortcut.setIcon(glyph_locked)
    else
    shortcut.setIcon(glyph_unlocked)
    end
    shortcut.setActive(locked)

noctalia.state.watch("iio-state", function (value)
    locked = value
    render()
end)

end

-- Initial state at load.
render()

function onClick()
  locked = not locked
  noctalia.state.set("iio-state", locked)

  render()
end