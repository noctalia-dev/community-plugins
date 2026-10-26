--!nonstrict
-- Helpers the panel and the lifecycle service both need. pathEnv() lives here
-- so the uninstall hook passes the same paths the panel does; a second copy
-- would drift the next time a compositor is added.

local M = {}

function M.shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

function M.trim(s)
  return noctalia.string.trim(tostring(s or ""))
end

function M.configString(key, fallback)
  local value = noctalia.getConfig(key)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return fallback
end

-- The path settings reach the engine as env vars rather than flags, so a
-- keybind can export the same names with the shell stopped. Only the ones set
-- are sent; an empty one leaves the engine on its XDG default.
local PATH_SETTINGS = {
  install_dir = "CURMGR_INSTALL_DIR",
  niri_config = "CURMGR_NIRI_CONFIG",
  hyprland_config = "CURMGR_HYPRLAND_CONFIG",
  sway_config = "CURMGR_SWAY_CONFIG",
  mango_config = "CURMGR_MANGO_CONFIG",
  umbriel_config = "CURMGR_UMBRIEL_CONFIG",
}

function M.pathEnv()
  local env = ""
  for key, var in pairs(PATH_SETTINGS) do
    local value = M.trim(M.configString(key, ""))
    if value ~= "" then
      env ..= `{var}={M.shellQuote(noctalia.expandPath(value))} `
    end
  end
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
  if #dirs > 0 then
    env ..= `CURMGR_ICON_DIRS={M.shellQuote(table.concat(dirs, ":"))} `
  end
  return env
end

return M
