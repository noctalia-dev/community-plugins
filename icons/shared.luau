--!nonstrict
-- Helpers the panel and the lifecycle service both need, so the uninstall
-- hook runs the engine exactly the way the panel does.

local M = {}

function M.shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

function M.trim(s)
  return noctalia.string.trim(tostring(s or ""))
end

-- Extra theme folders reach the engine as an env var, not a flag, so a
-- keybind can export the same name with the shell stopped.
function M.pathEnv()
  local dirs = {}
  local list = noctalia.getConfig("icon_dirs")
  if type(list) == "table" then
    for _, dir in ipairs(list) do
      local d = M.trim(dir)
      if d ~= "" then
        table.insert(dirs, noctalia.expandPath(d))
      end
    end
  end
  if #dirs == 0 then
    return ""
  end
  return `ICONMGR_ICON_DIRS={M.shellQuote(table.concat(dirs, ":"))} `
end

-- The engine ships inside the plugin, so nothing has to be on PATH.
function M.engine(path)
  return `{M.pathEnv()}python3 -B {M.shellQuote(path)}`
end

return M
