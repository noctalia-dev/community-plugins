--!nonstrict
-- Apply a saved theme to the shell: set the wallpaper first (a wallpaper-source
-- palette regenerates from it), then the palette source + selection, then the
-- theme templates.

local M = {}
local themes = require("./themes.luau")

-- The shell CLI. Prefer the canonical `noctalia`, fall back to this build's
-- `noctalia-kwe` binary name.
local BIN = "noctalia-kwe"
if noctalia.commandExists("noctalia") then
	BIN = "noctalia"
end

M.BIN = BIN

local function run(cmd, onDone, timeout)
	noctalia.runAsync(cmd, function(result)
		if onDone ~= nil then
			onDone(result)
		end
	end, timeout)
end

-- Apply a theme. onDone(success: boolean). Always applies the shell's
-- configured templates after switching the palette.
function M.apply(theme, onDone)
	if type(theme) ~= "table" then
		if onDone ~= nil then
			onDone(false)
		end
		return
	end

	-- 1) Wallpaper first (drives the palette when the source is "wallpaper").
	local wp = themes.currentWallpaper(theme)
	if wp ~= "" then
		noctalia.setWallpaper(wp)
	end

	-- 2) Palette source + selection. The argv-table form keeps values with
	-- spaces (e.g. "Rosé Pine") as one argument.
	local source = theme.source or "builtin"
	local value = theme.palette or ""
	if source == "wallpaper" then
		value = theme.wallpaperScheme or "m3-content"
	end
	if value == "" then
		if onDone ~= nil then
			onDone(false)
		end
		return
	end

	run({ BIN, "msg", "color-scheme-set", source, value }, function(result)
		if result == nil or result.exitCode ~= 0 then
			if onDone ~= nil then
				onDone(false)
			end
			return
		end

		-- 3) Re-render/apply configured templates for the new palette.
		run({ BIN, "msg", "templates-apply" }, function(applyResult)
			if onDone ~= nil then
				onDone(applyResult == nil or applyResult.exitCode == 0)
			end
		end, 30000)
	end, 15000)
end

return M
