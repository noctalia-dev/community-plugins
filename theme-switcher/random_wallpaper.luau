--!nonstrict
-- Control center shortcut tile: apply a random wallpaper from the currently
-- applied theme (without re-applying the palette).

local themes = require("./themes.luau")
local tr = noctalia.tr

local function render()
	shortcut.setLabel(tr("random.shortcut"))
	shortcut.setIcon("arrows-shuffle")
end

local function randomize()
	themes.randomizeWallpaper()
end

render()

function onClick()
	randomize()
end
