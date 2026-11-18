--!nonstrict
-- Palette discovery: built-in names, wallpaper generator schemes, community
-- catalog (HTTP with offline fallback), and custom palette folders.

local M = {}

-- The 10 built-in palettes shipped by the shell (ThemeConfig::kBuiltinPaletteNames).
M.BUILTIN = {
	"Ayu",
	"Catppuccin",
	"Dracula",
	"Eldritch",
	"Gruvbox",
	"Kanagawa",
	"Noctalia",
	"Nord",
	"Rosé Pine",
	"Tokyo-Night",
}

-- The 10 wallpaper generator schemes (ThemeConfig::wallpaper_scheme choices).
M.SCHEMES = {
	"m3-tonal-spot",
	"m3-content",
	"m3-fruit-salad",
	"m3-rainbow",
	"m3-monochrome",
	"vibrant",
	"faithful",
	"soft",
	"dysfunctional",
	"muted",
}

-- Palette sources, in the order shown in the editor.
M.SOURCES = { "builtin", "wallpaper", "community", "custom" }

local CATALOG_URL = "https://api.noctalia.dev/palettes"

local function cachePath()
	local dir = noctalia.pluginDataDir()
	if dir == nil or dir == "" then
		return nil
	end
	return dir .. "/community-catalog.json"
end

-- The catalog response is either a bare array of palette entries or an object
-- with a "palettes" array. Each entry is either a plain name string or an
-- object with at least a "name" field.
local function parseCatalog(body)
	if body == nil or body == "" then
		return {}
	end
	local root = noctalia.json.decode(body)
	if root == nil or type(root) ~= "table" then
		return {}
	end
	local list = root
	if type(root.palettes) == "table" then
		list = root.palettes
	end
	local names = {}
	if type(list) == "table" then
		for _, item in ipairs(list) do
			local name
			if type(item) == "string" then
				name = item
			elseif type(item) == "table" and type(item.name) == "string" then
				name = item.name
			end
			if name ~= nil and name ~= "" then
				table.insert(names, name)
			end
		end
	end
	table.sort(names)
	return names
end

-- Fetch the community palette names. Tries the network, then the plugin's own
-- cached copy, then the shell's own community-palette catalog cache.
function M.listCommunity(onDone)
	if type(onDone) ~= "function" then
		return
	end
	local own = cachePath()

	noctalia.http({ url = CATALOG_URL }, function(res)
		if res ~= nil and res.ok and res.status == 200 and res.body ~= nil and res.body ~= "" then
			local names = parseCatalog(res.body)
			if #names > 0 then
				if own ~= nil then
					noctalia.writeFile(own, res.body)
				end
				onDone(names)
				return
			end
		end

		-- Fall back to the plugin's cached copy.
		if own ~= nil then
			local body = noctalia.readFile(own)
			if body ~= nil and body ~= "" then
				local names = parseCatalog(body)
				if #names > 0 then
					onDone(names)
					return
				end
			end
		end

		-- Fall back to the shell's community-palette catalog cache.
		local shellCache = noctalia.expandPath(
			"~/.local/state/noctalia/community-palettes/.catalog/palettes.json"
		)
		local body = noctalia.readFile(shellCache)
		if body ~= nil and body ~= "" then
			local names = parseCatalog(body)
			if #names > 0 then
				onDone(names)
				return
			end
		end

		onDone({})
	end)
end

-- Custom palettes: every <name>.json under ~/.config/noctalia/palettes.
function M.listCustom()
	local dir = noctalia.expandPath("~/.config/noctalia/palettes")
	local names = {}
	local entries = noctalia.listDir(dir)
	if entries ~= nil then
		for _, name in ipairs(entries) do
			if string.sub(name, -5) == ".json" then
				table.insert(names, string.sub(name, 1, -6))
			end
		end
	end
	table.sort(names)
	return names
end

return M
