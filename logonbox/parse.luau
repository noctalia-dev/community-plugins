--!nonstrict
-- Pure parsing of LogonBox CLI output. No noctalia calls.
-- Uses only syntax valid in both Luau and Lua 5.x so the specs run under plain Lua.

local M = {}

local DETAIL_MAX = 160

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function firstLine(s)
  local line = s:match("^([^\n]*)")
  return trim(line or "")
end

local function percentDecode(s)
  return (s:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

-- "https://user%40example.com@vpn.example.com:8443/app" -> "vpn.example.com", "user@example.com"
function M.uri(uri)
  if type(uri) ~= "string" then
    return nil
  end
  local rest = uri:match("^%a[%w+.-]*://(.*)$")
  if not rest then
    return nil
  end
  local authority = rest:match("^([^/?#]*)")
  local user, hostport = nil, authority
  local at = authority:match("^.*()@")
  if at then
    user = authority:sub(1, at - 1)
    hostport = authority:sub(at + 1)
  end
  local host = hostport:match("^%[([^%]]+)%]") or hostport:match("^([^:]*)")
  if host == nil or host == "" then
    return nil
  end
  local account = nil
  if user ~= nil and user ~= "" then
    account = percentDecode(user)
  end
  return host, account
end

local function splitList(value)
  local list = {}
  for raw in value:gmatch("[^,]+") do
    local item = trim(raw)
    if item ~= "" then
      list[#list + 1] = item
    end
  end
  return list
end

local function newConnection(id)
  return { id = id, name = "", host = "", account = nil, status = "", authorized = false, dns = {} }
end

-- `show` text -> { Connection }, or nil, "unparsed".
function M.show(text)
  if type(text) ~= "string" then
    return nil, "unparsed"
  end
  if trim(text) == "" then
    return {}
  end
  local rows = {}
  local current = nil
  for line in text:gmatch("[^\n]+") do
    local key, value = line:match("^%s*([^:]-):%s*(.-)%s*$")
    if key == "Connection" then
      local id = tonumber(value)
      if id ~= nil then
        current = newConnection(id)
        rows[#rows + 1] = current
      else
        current = nil
      end
    elseif current ~= nil and key ~= nil then
      if key == "Name" then
        current.name = value
      elseif key == "Uri" then
        local host, account = M.uri(value)
        current.host = host or ""
        current.account = account
      elseif key == "Status" then
        current.status = value
      elseif key == "Authorized" then
        current.authorized = (value == "Yes")
      elseif key == "DNS" then
        current.dns = splitList(value)
      end
    end
  end
  if #rows == 0 then
    return nil, "unparsed"
  end
  return rows
end

local function combined(result)
  local out = result.stdout or ""
  local err = result.stderr or ""
  if err ~= "" then
    out = out .. "\n" .. err
  end
  return out
end

-- One run of text between spaces, quotes, brackets and separators (so "[fe80::1]"
-- and "(vpn.example.com)" are checked from the inside) that names a place anywhere
-- in it ("host=vpn.example.com", "endpoint:vpn.example.com:51820" count too): a URL,
-- an e-mail or user@host (also percent-encoded, "%40"), an IPv4 or IPv6 address, or
-- a dotted host name whose last label is two or more letters ("vpn.example.com",
-- but not "e.g" or "3.0.7"). A clock time ("12:30:45") is not an address.
local function looksPrivate(run)
  if run:find("@", 1, true) or run:find("%40", 1, true) or run:find("://", 1, true) then
    return true
  end
  if run:find("%d+%.%d+%.%d+%.%d+") then
    return true
  end
  if run:find("%x*::%x*") or run:find("%x+:%x+:%x+:%x+") then
    return true
  end
  for candidate in run:gmatch("[%w-]+%.[%w.-]+") do
    local host = candidate:gsub("%.+$", "")
    if host:find("%.%a%a+$") then
      return true
    end
  end
  return false
end

-- Every URL, e-mail, host and IP in text replaced by "…".
local function scrubText(text)
  return (text:gsub("[^%s\"'()<>,;%[%]]+", function(run)
    if looksPrivate(run) then
      return "…"
    end
    return run
  end))
end

-- Cuts text to at most max bytes without splitting a UTF-8 character.
local function cutBytes(text, max)
  if #text <= max then
    return text
  end
  local cut = text:sub(1, max)
  local i = #cut
  while i > 0 and cut:byte(i) >= 128 and cut:byte(i) < 192 do
    i = i - 1
  end
  if i > 0 and cut:byte(i) >= 192 then
    local lead = cut:byte(i)
    local need = 2
    if lead >= 240 then
      need = 4
    elseif lead >= 224 then
      need = 3
    end
    if #cut - i + 1 < need then
      cut = cut:sub(1, i - 1)
    end
  end
  return cut
end

-- nil when nothing readable is left.
local function readable(text)
  text = trim(text)
  if not text:gsub("…", ""):find("%w") then
    return nil
  end
  return text
end

-- CLI detail text with every URL, e-mail, host and IP replaced by "…"; nil when
-- nothing readable is left. The detail goes into the panel and a notification.
function M.scrubDetail(detail)
  if type(detail) ~= "string" then
    return nil
  end
  return readable(scrubText(detail))
end

local function cleanDetail(raw)
  local detail = firstLine(raw)
  detail = detail:gsub("^[%w_.$]+Exception:%s*", "")
  -- Scrubbed before the cut, so a host is never cut to a fragment that passes.
  detail = trim(scrubText(detail))
  return readable(cutBytes(detail, DETAIL_MAX))
end

local function hasLine(text, wanted)
  for line in text:gmatch("[^\n]+") do
    if trim(line) == wanted then
      return true
    end
  end
  return false
end

local function stderrDetail(result)
  local err = result.stderr or ""
  if trim(err) == "" then
    err = result.stdout or ""
  end
  return cleanDetail(trim(err))
end

function M.connectOutcome(result)
  local text = combined(result)
  -- A device sign-in waits for input, so it times out: the sign-in text wins.
  if text:find("Open the URL below", 1, true) or text:find("User Code:", 1, true) then
    return { ok = false, kind = "signin" }
  end
  if result.timedOut then
    return { ok = false, kind = "timeout" }
  end
  if hasLine(text, "Ready") then
    return { ok = true, kind = "ok" }
  end
  local failed = text:match("Failed to connect%.[ \t]*([^\n]*)")
  if failed ~= nil then
    return { ok = false, kind = "failed", detail = cleanDetail(failed) }
  end
  if text:find("Connection failed.", 1, true) then
    return { ok = false, kind = "failed" }
  end
  if text:find("Open the URL below", 1, true) or text:find("User Code:", 1, true) then
    return { ok = false, kind = "signin" }
  end
  if (result.exitCode or 0) ~= 0 then
    return { ok = false, kind = "failed", detail = stderrDetail(result) }
  end
  return { ok = false, kind = "failed" }
end

function M.disconnectOutcome(result)
  if result.timedOut then
    return { ok = false, kind = "timeout" }
  end
  local text = combined(result)
  if text:find("is not connected", 1, true) then
    return { ok = true, kind = "already" }
  end
  if hasLine(text, "Disconnect") then
    return { ok = true, kind = "ok" }
  end
  if (result.exitCode or 0) ~= 0 then
    return { ok = false, kind = "failed", detail = stderrDetail(result) }
  end
  return { ok = false, kind = "failed" }
end

-- One line of `gdbus monitor` -> transition | refresh | nil.
function M.monitorLine(line)
  if type(line) ~= "string" then
    return nil
  end
  local id, name = line:match("^/com/logonbox/vpn/(%d+): com%.logonbox%.vpn%.Connection%.(%a+)")
  if id ~= nil then
    if name == "Connecting" then
      return { kind = "transition", id = tonumber(id), to = "connecting" }
    elseif name == "Disconnecting" then
      return { kind = "transition", id = tonumber(id), to = "disconnecting" }
    end
    return { kind = "refresh" }
  end
  if line:find(": com.logonbox.vpn.", 1, true) then
    return { kind = "refresh" }
  end
  if line:find("^The name com%.logonbox%.vpn") and line:find("owne") then
    return { kind = "refresh" }
  end
  return nil
end

-- gdbus NameHasOwner reply: "(true,)" / "(false,)".
function M.nameOwner(stdout)
  if type(stdout) ~= "string" then
    return nil
  end
  if stdout:find("^%s*%(true,?%)") then
    return true
  end
  if stdout:find("^%s*%(false,?%)") then
    return false
  end
  return nil
end

return M
