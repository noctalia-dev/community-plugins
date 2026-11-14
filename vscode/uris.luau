--!nonstrict
-- Pure URI helpers for VS Code recents. No noctalia.* here.
local uris = {}

function uris.decode(s)
  return (tostring(s):gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

-- Encode a path the way VS Code writes it: keep A-Za-z0-9 - . _ ~ and "/".
local function encodePath(path)
  return (path:gsub("[^%w%-%._~/]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function stripTrailingSlash(s)
  if #s > 1 and s:sub(-1) == "/" then
    return s:sub(1, -2)
  end
  return s
end

local function classify(authority)
  local kind, rest = authority:match("^([^+]+)%+(.*)$")
  if not kind then
    return "other", nil
  end
  local k = kind:lower()
  if k == "ssh-remote" then
    return "ssh", rest
  elseif k == "dev-container" or k == "attached-container" then
    return "container", nil
  elseif k == "wsl" then
    return "wsl", nil
  elseif k == "tunnel" then
    return "tunnel", rest
  end
  return "other", nil
end

function uris.parse(raw)
  if type(raw) ~= "string" then
    return nil
  end
  local scheme, rest = raw:match("^(%a[%w+.-]*):(.*)$")
  if not scheme then
    return nil
  end
  scheme = scheme:lower()
  if scheme ~= "file" and scheme ~= "vscode-remote" then
    return nil
  end
  rest = rest:gsub("[?#].*$", "")
  local authority, rawPath = rest:match("^//([^/]*)(.*)$")
  if not authority then
    authority, rawPath = "", rest
  end
  if rawPath == "" then
    rawPath = "/"
  end
  rawPath = stripTrailingSlash(rawPath)
  local decodedAuthority = uris.decode(authority)
  local uri = {
    raw = raw,
    scheme = scheme,
    path = uris.decode(rawPath):gsub("^/(%a:)", "%1"),
    key = scheme .. "://" .. decodedAuthority:lower() .. rawPath,
  }
  if scheme == "vscode-remote" then
    uri.remote, uri.host = classify(decodedAuthority)
  end
  return uri
end

function uris.fromPath(path)
  local clean = stripTrailingSlash(path)
  local enc = encodePath(clean)
  return {
    raw = "file://" .. enc,
    scheme = "file",
    path = clean,
    key = "file://" .. enc,
  }
end

function uris.shortenHome(path, home)
  if home == nil or home == "" then
    return path
  end
  if path == home then
    return "~"
  end
  local prefix = stripTrailingSlash(home) .. "/"
  if path:sub(1, #prefix) == prefix then
    return "~/" .. path:sub(#prefix + 1)
  end
  return path
end

function uris.title(uri, kind)
  local path = stripTrailingSlash(uri.path)
  if path == "/" then
    return "/"
  end
  local name = path:match("([^/]*)$")
  if kind == "workspace" then
    name = name:gsub("%.code%-workspace$", "")
  end
  if name == "" then
    return path
  end
  return name
end

function uris.subtitle(uri, home)
  if uri.host then
    return uri.host .. ":" .. uri.path
  end
  if uri.scheme == "file" then
    return uris.shortenHome(uri.path, home)
  end
  return uri.path
end

function uris.isGitUrl(text)
  if type(text) ~= "string" or text:find("%s") then
    return false
  end
  if text:match("^https?://%S") or text:match("^ssh://%S") or text:match("^git://%S") then
    return true
  end
  return text:match("^[%w._-]+@[^:/]+:%S") ~= nil
end

function uris.cloneName(url)
  if not uris.isGitUrl(url) then
    return nil
  end
  local path = url:match("^%a+://[^/]+/(.*)$") or url:match("^[%w._-]+@[^:/]+:(.*)$")
  if not path then
    return nil
  end
  path = path:gsub("/+$", "")
  local name = path:match("([^/]*)$")
  name = name:gsub("%.git$", "")
  if name == "" or name == "." or name == ".." or name:find("[^%w._-]") then
    return nil
  end
  return name
end

return uris
