--[[
Reaction bar tile.

Left click shows the sticker, right click dismisses it. Both actions go through
the shared sticker module (lib/sticker.luau), which runs in process: it either
spawns the transparent overlay or toggles the panel fallback. Either way a
second click while the sticker is on screen restarts it instead of closing it.

The `visible` state tints the glyph: the panel sets it while it is open, and
the overlay path sets it for the overlay's lifetime.
]]

local Sticker = require("./lib/sticker.luau")

local function tint(visible)
  barWidget.setGlyphColor(visible and "primary" or "on_surface_variant")
end

barWidget.setGlyph("mood-smile")
barWidget.setTooltip(noctalia.tr("widget.tooltip"))
tint(Sticker.isVisible())

function onClick()
  Sticker.show()
end

function onRightClick()
  Sticker.hide()
end

noctalia.state.watch("visible", function(value)
  tint(value == true)
end)
