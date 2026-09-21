--!nonstrict
-- Control-center [[shortcut]] entry: a quick-toggle tile.
--
--   shortcut.setLabel(text)
--   shortcut.setIcon(on [, off])   -- one glyph, or distinct on/off glyphs
--   shortcut.setActive(bool)       -- toggle/highlight state
--   shortcut.setEnabled(bool)
--   onClick() / onRightClick()
--
-- State is shared via noctalia.state, so the plugin's other entries (widget,
-- service) could react to the toggle.

local on = noctalia.state.get("toggle") == true

local function render()
  shortcut.setLabel(if on then "Example On" else "Example Off")
  shortcut.setIcon("puzzle")
  shortcut.setActive(on)
  shortcut.setEnabled(true)
end

-- Initial state at load.
render()

function onClick()
  on = not on
  noctalia.state.set("toggle", on)
  render()
end
