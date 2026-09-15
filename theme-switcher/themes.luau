--!nonstrict
-- Persistent theme store. The single source of truth is a JSON file in the
-- plugin data dir; a copy is mirrored into noctalia.state so every entry of
-- this plugin (widget, shortcut, carousel, editor) stays in sync.

local M = {}

local function storePath()
	local dir = noctalia.pluginDataDir()
	if dir == nil or dir == "" then
		return nil
	end
	return dir .. "/themes.json"
end

local function fromState()
	local themes = noctalia.state.get("themes")
	if type(themes) ~= "table" then
		return nil
	end
	return {
		themes = themes,
		lastAppliedId = noctalia.state.get("lastAppliedId") or "",
	}
end

local function readDisk()
	local themes, lastAppliedId = {}, ""
	local path = storePath()
	if path ~= nil then
		local body = noctalia.readFile(path)
		if body ~= nil and body ~= "" then
			local obj = noctalia.json.decode(body)
			if type(obj) == "table" then
				if type(obj.themes) == "table" then
					themes = obj.themes
				end
				if type(obj.lastAppliedId) == "string" then
					lastAppliedId = obj.lastAppliedId
				end
			end
		end
	end
	return { themes = themes, lastAppliedId = lastAppliedId }
end

-- Returns the current { themes = {...}, lastAppliedId = string }. Prefers the
-- shared state so edits made in one entry are immediately visible to the rest.
function M.load()
	local state = fromState()
	if state ~= nil then
		return state
	end
	local disk = readDisk()
	noctalia.state.set("themes", disk.themes)
	noctalia.state.set("lastAppliedId", disk.lastAppliedId)
	return disk
end

function M.list()
	return M.load().themes
end

function M.lastAppliedId()
	return M.load().lastAppliedId
end

function M.byId(id)
	for _, theme in ipairs(M.list()) do
		if theme.id == id then
			return theme
		end
	end
	return nil
end

function M.slug(title)
	local base = tostring(title or ""):lower():gsub("[^%w]+", "-"):gsub("^[%-]+", ""):gsub("[%-]+$", "")
	if base == "" then
		base = "theme"
	end
	base = string.sub(base, 1, 48)
	local slug = base
	local n = 1
	while M.byId(slug) ~= nil do
		n = n + 1
		slug = base .. "-" .. n
	end
	return slug
end

local function persist(state)
	local path = storePath()
	if path ~= nil then
		noctalia.mkdirAll(noctalia.pluginDataDir())
		local body = noctalia.json.encode(
			{ version = 1, themes = state.themes, lastAppliedId = state.lastAppliedId },
			true
		)
		if body ~= nil then
			noctalia.writeFile(path, body)
		end
	end
	noctalia.state.set("themes", state.themes)
	noctalia.state.set("lastAppliedId", state.lastAppliedId)
end

function M.upsert(theme)
	local state = M.load()
	local found = false
	for i, existing in ipairs(state.themes) do
		if existing.id == theme.id then
			state.themes[i] = theme
			found = true
			break
		end
	end
	if not found then
		table.insert(state.themes, theme)
	end
	persist(state)
end

function M.remove(id)
	local state = M.load()
	for i, existing in ipairs(state.themes) do
		if existing.id == id then
			table.remove(state.themes, i)
			break
		end
	end
	persist(state)
end

function M.setLastApplied(id)
	local state = M.load()
	state.lastAppliedId = id
	persist(state)
end

-- The wallpaper list for a theme. Falls back to the legacy single wallpaperPath.
function M.wallpapersOf(theme)
	if type(theme) ~= "table" then
		return {}
	end
	if type(theme.wallpapers) == "table" and #theme.wallpapers > 0 then
		return theme.wallpapers
	end
	if type(theme.wallpaperPath) == "string" and theme.wallpaperPath ~= "" then
		return { theme.wallpaperPath }
	end
	return {}
end

-- The active wallpaper for a theme (respects wallpaperIndex, falls back to index 0).
function M.currentWallpaper(theme)
	local wps = M.wallpapersOf(theme)
	if #wps == 0 then
		return ""
	end
	local idx = theme.wallpaperIndex or 0
	if idx < 0 or idx >= #wps then
		idx = 0
	end
	return wps[idx + 1]
end

-- Pick a random wallpaper from the applied theme and apply it (no palette change).
-- Returns "ok", path on success; "none" if no theme is applied; "empty" if it has
-- no wallpapers. Never applies the current wallpaper again when alternatives exist.
function M.randomizeWallpaper()
	local theme = M.byId(M.lastAppliedId())
	if theme == nil then
		return "none"
	end
	local wps = M.wallpapersOf(theme)
	if #wps == 0 then
		return "empty"
	end

	local current = theme.wallpaperIndex or 0
	local idx = current
	if #wps > 1 then
		local candidates = {}
		for i, _ in ipairs(wps) do
			if (i - 1) ~= current then
				table.insert(candidates, i - 1)
			end
		end
		math.randomseed(noctalia.nowMs())
		idx = candidates[math.random(#candidates)] or current
	end

	theme.wallpaperIndex = idx
	M.upsert(theme)
	local wp = M.currentWallpaper(theme)
	if wp ~= "" then
		noctalia.setWallpaper(wp)
	end
	return "ok", wp
end

return M
