--!nonstrict
-- JSON files in the plugin data dir. Written to a temp file and renamed over the
-- target, so a crash in between leaves the old file instead of a truncated one.

local M = {}

function M.writeJson(path, value)
	local text = noctalia.json.encode(value)
	if text == nil then
		return false
	end
	local tmp = path .. ".tmp"
	if not noctalia.writeFile(tmp, text) then
		return false
	end
	return noctalia.renameFile(tmp, path) == true
end

return M
