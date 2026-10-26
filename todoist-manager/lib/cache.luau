--!nonstrict
-- lib/cache.luau (Phase 1)
-- Optional on-disk snapshot so the panel can paint before the first network
-- round-trip. Lives in pluginDataDir() (survives plugin updates; pluginDir()
-- is a runtime copy that gets rewritten). Never stores the token.
--
-- Writes are atomic: encode -> write "<file>.tmp" -> renameFile over the
-- target, so a crash mid-write cannot leave a truncated snapshot to parse.
local M = {}

M.SCHEMA = 1
local FILE = "snapshot.json"
local TMP = "snapshot.json.tmp"

local function filePath(name)
	local dir = noctalia.pluginDataDir()
	if type(dir) ~= "string" or dir == "" then
		return nil
	end
	return dir .. "/" .. name
end

-- Returns the stored snapshot table, or nil when absent / unreadable /
-- written by an older schema.
function M.load()
	local path = filePath(FILE)
	if path == nil or not noctalia.fileExists(path) then
		return nil
	end
	local raw = noctalia.readFile(path)
	if type(raw) ~= "string" or raw == "" then
		return nil
	end
	local data = noctalia.json.decode(raw)
	if type(data) ~= "table" or data.schema ~= M.SCHEMA then
		return nil
	end
	return data
end

-- snap must be plain data (state-channel rules apply on the way in).
function M.save(snap)
	local path = filePath(FILE)
	local tmp = filePath(TMP)
	if path == nil or tmp == nil then
		return false
	end
	local encoded = noctalia.json.encode(snap)
	if type(encoded) ~= "string" then
		return false
	end
	if not noctalia.writeFile(tmp, encoded) then
		return false
	end
	if not noctalia.renameFile(tmp, path) then
		return false
	end
	-- Task titles live in here, so keep the file private. The directory is 700
	-- already; this is belt and braces for the file itself.
	noctalia.runAsync({ "chmod", "600", path })
	return true
end

function M.clear()
	local path = filePath(FILE)
	if path ~= nil and noctalia.fileExists(path) then
		noctalia.removeFile(path)
	end
end

return M
