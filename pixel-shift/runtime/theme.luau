--!nonstrict
-- The theme's primary colour, used for the lab's hotspot glow. Hosts with
-- plugin API 31+ expose noctalia.getColor. Older hosts (Noctalia 5.1 is API
-- 30) do not, so the engine asks the noctalia CLI for the active scheme:
-- wallpaper schemes are regenerated with `noctalia theme`, custom palettes are
-- read from their JSON file. Built-in schemes fall back to the lab default.

local util = require("../core/util.luau")
local tasks = require("./tasks.luau")

local M = {}
local cached, cachedAt, cachedFor = nil, 0, nil

local function run(argv)
	return tasks.await(function(done)
		if not noctalia.runAsync(argv, done, 3000) then
			done(nil)
		end
	end)
end

local function primaryFromJson(text: string?, dark: boolean): string?
	if type(text) ~= "string" then
		return nil
	end
	local v = noctalia.json.decode(text)
	if type(v) ~= "table" then
		return nil
	end
	local mode = if dark then v.dark else v.light
	if type(mode) == "table" then
		v = mode
	end
	local c = v.primary or v.mPrimary
	return if type(c) == "string" then c else nil
end

-- Must run inside a task. Returns "#rrggbb" or nil (caller falls back).
function M.resolve(output: string?): string?
	if noctalia.getColor then
		return noctalia.getColor("primary")
	end
	if cached and cachedFor == output and os.time() - cachedAt < 60 then
		return cached
	end
	local res = run({ "noctalia", "msg", "color-scheme-get" })
	if not res or res.exitCode ~= 0 then
		return cached
	end
	local source, name = string.match(res.stdout, "^(%S+)%s+(.-)%s*$")
	local dark = noctalia.isDarkMode()
	local primary = nil
	if source == "wallpaper" and output then
		local wallpaper = noctalia.wallpaperPath(output)
		if wallpaper then
			local r = run({ "noctalia", "theme", wallpaper, "--scheme", name, if dark then "--dark" else "--light" })
			if r and r.exitCode == 0 then
				primary = primaryFromJson(r.stdout, dark)
			end
		end
	elseif source == "custom" and name then
		primary = primaryFromJson(noctalia.readFile(util.configDir(noctalia.getenv) .. "/palettes/" .. name .. ".json"), dark)
	end
	if primary then
		cached, cachedAt, cachedFor = primary, os.time(), output
	end
	return primary or cached
end

return M
