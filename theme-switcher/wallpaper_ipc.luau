--!nonstrict
-- Always-running service: lets external callers (Firebot, KWin/KineticWE keybinds)
-- advance or randomize the wallpaper of the currently applied theme over IPC,
-- without requiring the wallpapers panel to be open.
--
--   noctalia msg plugin theblackdon/theme-switcher:wallpaper-ipc all random
--   noctalia msg plugin theblackdon/theme-switcher:wallpaper-ipc all next

local themes = require("./themes.luau")

local function advance()
	local theme = themes.byId(themes.lastAppliedId())
	if theme == nil then
		return
	end
	local wps = themes.wallpapersOf(theme)
	if #wps == 0 then
		return
	end
	local idx = (theme.wallpaperIndex or 0) + 1
	if idx >= #wps then
		idx = 0
	end
	theme.wallpaperIndex = idx
	themes.upsert(theme)
	local wp = themes.currentWallpaper(theme)
	if wp ~= "" then
		noctalia.setWallpaper(wp)
	end
end

function onIpc(event)
	if event == "random" then
		themes.randomizeWallpaper()
	elseif event == "next" then
		advance()
	end
end
