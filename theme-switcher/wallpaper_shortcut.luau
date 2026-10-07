--!nonstrict
-- Control center shortcut tile that opens the wallpapers panel for the currently
-- applied theme. Also triggerable via IPC so it can be bound to a key:
--   noctalia msg plugin theblackdon/theme-switcher:wallpaper all open

local function render()
	shortcut.setLabel(noctalia.tr("wallpapers.shortcut"))
	shortcut.setIcon("photo")
end

local function openPanel()
	noctalia.togglePanel("theblackdon/theme-switcher:wallpapers")
end

render()

function onClick()
	openPanel()
end

function onIpc()
	openPanel()
end
