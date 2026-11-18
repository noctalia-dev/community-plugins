--!nonstrict
-- Shared helpers: locate the nwg-displays config directory, list profiles,
-- read the active one, and apply one through `nwg-displays-apply`.

local tr = noctalia.tr

local M = {}

local APPLY_COMMAND = "nwg-displays-apply"

local function configHome()
  local xdg = noctalia.getenv("XDG_CONFIG_HOME")
  if xdg ~= nil and xdg ~= "" then
    return xdg
  end
  return noctalia.expandPath("~/.config")
end

function M.profilesDir()
  return configHome() .. "/nwg-displays/profiles"
end

function M.activeProfileFile()
  return configHome() .. "/nwg-displays/active_profile.json"
end

function M.listProfiles()
  local entries, err = noctalia.listDir(M.profilesDir())
  if entries == nil then
    return nil, err
  end

  local names = {}
  for _, entry in ipairs(entries) do
    local name = string.match(entry, "^(.+)%.json$")
    if name ~= nil and name ~= "" and name:sub(1, 1) ~= "." then
      table.insert(names, name)
    end
  end

  table.sort(names, function(a, b)
    local la, lb = a:lower(), b:lower()
    if la ~= lb then
      return la < lb
    end
    return a < b
  end)

  return names
end

function M.readActiveProfile()
  local raw = noctalia.readFile(M.activeProfileFile())
  if raw == nil then
    return nil
  end

  local data = noctalia.json.decode(raw)
  if type(data) ~= "table" then
    return nil
  end

  local name = data.active_profile
  if type(name) ~= "string" or name == "" then
    return nil
  end
  return name
end

function M.apply(name, cb)
  -- argv form: no shell parses the profile name. On success the new name goes
  -- out on the state channel so the widget updates without rereading the file.
  local accepted = noctalia.runAsync({ APPLY_COMMAND, "-p", name }, function(result)
    if result.exitCode == 0 then
      noctalia.state.set("active_profile", name)
      if cb ~= nil then
        cb(true, nil)
      end
      return
    end

    local err = noctalia.string.trim(result.stderr or "")
    if err == "" then
      err = noctalia.string.trim(result.stdout or "")
    end
    if err == "" then
      err = "exit code " .. result.exitCode
    end

    if cb ~= nil then
      cb(false, err)
    end
  end)

  if not accepted and cb ~= nil then
    cb(false, tr("notify.start_failed"))
  end
end

return M
