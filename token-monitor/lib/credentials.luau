local Model = require("./model.luau")
local Credentials = {}

local function absolute(path)
  return type(path) == "string" and #path <= 4096 and path:sub(1, 1) == "/" and not path:find("[%c]")
end
local function publicPath(path)
  if type(path) ~= "string" or #path > 4096 or path:find("[%c]") then return "" end
  return path
end
local function call(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, result = pcall(fn, ...)
  if ok then return result end
  return nil
end
function Credentials.loopback(url)
  if type(url) ~= "string" then return false end
  local authority = url:match("^https?://(.+)$")
  if not authority then return false end
  local host = authority:match("^(%[[^%]]+%]):?%d*$") or authority:match("^([^:]+):?%d*$")
  return host == "127.0.0.1" or host == "[::1]" or (host and host:lower() == "localhost") or false
end
function Credentials.scope(url, path, autoDiscover)
  return (url or "") .. "\n" .. path .. (path == "" and autoDiscover and "\nautomatic" or "")
end
function Credentials.path(env, path)
  return publicPath(call(env.expandPath, path) or path)
end
-- Each pass is bounded to two native locations and at most 32 immediate Distrobox homes.
-- Only native credentials JSON is eligible for automatic discovery.
function Credentials.resolve(env, options, current, done)
  local manual = options.credentialFile ~= ""
  local info = { credentialSource = manual and "manual" or "none", credentialPath = "",
    discovery = manual and "manual" or "searching" }
  if not manual and (not options.autoDiscover or not Credentials.loopback(options.url)) then
    info.discovery = options.autoDiscover and "remote" or "disabled"
    done(nil, info); return
  end
  local candidates, seen = {}, {}
  local function add(path)
    if absolute(path) then
      path = path:gsub("/+$", "")
      if not seen[path] then seen[path] = true; candidates[#candidates + 1] = path end
    end
  end
  local home
  if manual then
    local path = Credentials.path(env, options.credentialFile)
    info.credentialPath = path
    candidates[1] = path ~= "" and path or options.credentialFile
  else
    local xdg = call(env.getenv, "XDG_CONFIG_HOME")
    home = call(env.getenv, "HOME")
    if absolute(xdg) then add(xdg:gsub("/+$", "") .. "/Token Monitor/credentials.json") end
    if absolute(home) then add(home:gsub("/+$", "") .. "/.config/Token Monitor/credentials.json") end
  end
  local expandedContainers = false
  local failure = "not_found"
  local function note(code)
    if code == "invalid" or failure == "not_found" then failure = code end
  end
  local index = 0
  local nextCandidate
  nextCandidate = function()
    if not current() then return end
    index += 1
    local path = candidates[index]
    if not path and not manual and not expandedContainers then
      expandedContainers = true
      if absolute(home) then
        local directory = home:gsub("/+$", "") .. "/distrobox"
        local names = call(env.listDir, directory)
        if type(names) == "table" then
          -- Keep the lexically first 32 safe basenames without sorting an unbounded directory.
          local bounded = {}
          for _, name in ipairs(names) do
            if type(name) == "string" and #name > 0 and #name <= 255 and name ~= "." and name ~= ".."
                and not name:find("[/\\%c]") then
              local at = #bounded + 1
              for i, value in ipairs(bounded) do if name < value then at = i; break end end
              if at <= 32 then table.insert(bounded, at, name); if #bounded > 32 then table.remove(bounded) end end
            end
          end
          for _, name in ipairs(bounded) do add(directory .. "/" .. name .. "/.config/Token Monitor/credentials.json") end
        end
      end
      path = candidates[index]
    end
    if not path then info.discovery = failure; done(nil, info); return end
    local exists = call(env.exists, path)
    if not manual and exists == false then nextCandidate(); return end
    local completed = false
    local ok, accepted = pcall(env.read, path, function(contents)
      if completed or not current() then return end
      completed = true
      if contents == nil then
        if manual then done(nil, info, "credentials_unreadable"); return end
        note(exists == false and "not_found" or "unreadable")
      else
        local secret
        if manual then secret = Model.credential(contents, env.decode)
        elseif type(contents) == "string" and #contents <= 65536 then
          local document = call(env.decode, contents)
          if type(document) == "table" and type(document.credentials) == "table"
              and type(document.credentials.hub) == "table" then
            local candidate = document.credentials.hub.hostSecret
            if type(candidate) == "string" and candidate ~= "" and #candidate <= 4096
                and not candidate:find("[%c]") then secret = candidate end
          end
        end
        if secret then
          info.credentialSource, info.credentialPath = manual and "manual" or "automatic", publicPath(path)
          info.discovery = manual and "manual" or "found"
          done(secret, info); return
        end
        if manual then done(nil, info, "credentials_invalid"); return end
        note("invalid")
      end
      nextCandidate()
    end)
    if not ok or accepted ~= true then
      if completed or not current() then return end
      completed = true
      if manual then done(nil, info, "request_rejected"); return end
      note("unreadable"); nextCandidate()
    end
  end
  nextCandidate()
end
return Credentials
