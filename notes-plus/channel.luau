-- Channel between the editor and the bridge: a JSON file inside the notes
-- directory, so it works across plugins and across repos. Written atomically
-- (temp + rename) like the official's .pinned.json handling.

local M = {}

function M.currentPath(notesDir)
  return notesDir .. "/.current.json"
end

function M.write(notesDir, payload)
  if notesDir == nil or notesDir == "" then
    return false
  end
  local noctalia = _G.noctalia
  local encoded = noctalia.json.encode({
    name = payload.name or "",
    content = payload.content or "",
    open = payload.open == true,
    at = payload.at or "",
  })
  if encoded == nil then
    return false
  end
  local tmp = notesDir .. "/.current.json.tmp"
  local ok = noctalia.writeFile(tmp, encoded)
  if not ok then
    return false
  end
  local renamed = noctalia.renameFile(tmp, notesDir .. "/.current.json")
  if not renamed then
    noctalia.removeFile(tmp)
    return false
  end
  return true
end

function M.read(notesDir)
  if notesDir == nil or notesDir == "" then
    return nil
  end
  local noctalia = _G.noctalia
  local raw = noctalia.readFile(notesDir .. "/.current.json")
  if raw == nil or raw == "" then
    return nil
  end
  local ok, decoded = pcall(noctalia.json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  if type(decoded.name) ~= "string" then
    return nil
  end
  return {
    name = decoded.name,
    content = decoded.content or "",
    open = decoded.open == true,
  }
end

return M
