--!nonstrict
-- Always-running service: lets external callers (Firebot, KWin/KineticWE keybinds)
-- advance or randomize the wallpaper of the currently applied theme, or apply a
-- saved theme by id/title, over IPC without opening any panel.
--
--   noctalia msg plugin theblackdon/theme-switcher:wallpaper-ipc all random
--   noctalia msg plugin theblackdon/theme-switcher:wallpaper-ipc all next
--   noctalia msg plugin theblackdon/theme-switcher:wallpaper-ipc all apply "Rosé Pine"

local themes = require("./themes.luau")
local applyMod = require("./apply.luau")
local tr = noctalia.tr

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

local function applyTheme(query)
	local theme = themes.find(query)
	if theme == nil then
		noctalia.notifyError(tr("apply.err_title"), tr("ipc.not_found", { query = tostring(query or "") }))
		return
	end
	applyMod.apply(theme, function(ok)
		if ok then
			themes.setLastApplied(theme.id)
			noctalia.notify(tr("apply.ok_title"), tr("apply.ok_body", { title = theme.title }))
		else
			noctalia.notifyError(tr("apply.err_title"), tr("apply.err_body", { title = theme.title }))
		end
	end)
end

function onIpc(event, payload)
	if event == "random" then
		themes.randomizeWallpaper()
	elseif event == "next" then
		advance()
	elseif event == "apply" then
		applyTheme(payload)
	end
end
