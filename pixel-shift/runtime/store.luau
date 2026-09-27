--!nonstrict
-- Persistence in the plugin data dir: JSON documents and binary blobs,
-- written atomically (temp file + rename), plus rendered lab images.

local M = {}

function M.dir(): string?
	local d = noctalia.pluginDataDir()
	return d
end

local function path(name: string): string?
	local d = M.dir()
	return if d then d .. "/" .. name else nil
end

function M.read(name: string): string?
	local p = path(name)
	if not p then
		return nil
	end
	local s = noctalia.readFile(p)
	return s
end

function M.write(name: string, data: string): boolean
	local p = path(name)
	if not p or not noctalia.writeFile(p .. ".tmp", data) then
		return false
	end
	local ok = noctalia.renameFile(p .. ".tmp", p)
	return ok
end

function M.readJson(name: string)
	local s = M.read(name)
	if not s then
		return nil
	end
	local v = noctalia.json.decode(s)
	return v
end

function M.writeJson(name: string, value): boolean
	local s = noctalia.json.encode(value, true)
	return s ~= nil and M.write(name, s)
end

function M.remove(name: string)
	local p = path(name)
	if p then
		noctalia.removeFile(p)
	end
end

-- A new file name per render so ui.image never shows a cached old image;
-- the previous render of the same slot is deleted.
local renders = {}
local counter = 0
function M.writeImage(slot: string, bytes: string): string?
	local d = M.dir()
	if not d then
		return nil
	end
	noctalia.mkdirAll(d .. "/render")
	counter += 1
	local name = `{d}/render/{slot}-{os.time()}-{counter}.bmp`
	if not noctalia.writeFile(name, bytes) then
		return nil
	end
	-- keep the previous render too: the panel may still show it while the
	-- new model is on its way
	local list = renders[slot] or {}
	renders[slot] = list
	table.insert(list, name)
	while #list > 2 do
		noctalia.removeFile(table.remove(list, 1))
	end
	return name
end

function M.cleanRenders()
	local d = M.dir()
	if not d then
		return
	end
	local files = noctalia.listDir(d .. "/render")
	for _, f in ipairs(files or {}) do
		noctalia.removeFile(if string.sub(f, 1, 1) == "/" then f else d .. "/render/" .. f)
	end
end

return M
