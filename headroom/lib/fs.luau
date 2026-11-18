--!nonstrict
-- File writes shared by the service (cache) and the theme (generated SVGs).

local M = {}

-- Writes through a temp file and a rename, so a reader in another entry (or
-- after a crash) never sees half a file.
function M.writeAtomic(path: string, content: string): boolean
  local tmp = `{path}.{math.floor(noctalia.nowMs())}.tmp`
  if not noctalia.writeFile(tmp, content) then
    return false
  end
  if not noctalia.renameFile(tmp, path) then
    noctalia.removeFile(tmp)
    return false
  end
  return true
end

return M
