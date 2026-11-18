-- Shared helpers for the OpenCode Monitor plugin.
-- Kept dependency-free so every entry can require it.

local M = {}

M.SNAPSHOT_KEY = "opencode_monitor"
M.REFRESH_KEY = "opencode_monitor_refresh"

local CACHE_LIMIT = 512
local homeCache = nil
local shortPathCache = {}
local shortPathCacheSize = 0
local REDACT_CACHE_LIMIT = 256
local redactCache = {}
local redactCacheSize = 0

local MAX_RESPONSE_BYTES = 2 * 1024 * 1024
local MAX_SERVICE_FILE_BYTES = 65536
local MAX_SESSION_ID_LENGTH = 128
local REDACT_INPUT_LIMIT = 4096
local REDACT_MAX_SPANS = 24
local REDACT_MARKER = "[redacted]"

M.MAX_RESPONSE_BYTES = MAX_RESPONSE_BYTES
M.MAX_SERVICE_FILE_BYTES = MAX_SERVICE_FILE_BYTES
M.MAX_SESSION_ID_LENGTH = MAX_SESSION_ID_LENGTH

-- Control bytes (except tab/newline/carriage return) and C1 controls. Server
-- supplied strings must not be able to inject terminal/ANSI control sequences.
local CONTROL_PATTERN = "[%z"
  .. string.char(1) .. "-" .. string.char(8)
  .. string.char(11) .. string.char(12)
  .. string.char(14) .. "-" .. string.char(31)
  .. string.char(127)
  .. "]"
local C1_CONTROL_PATTERN = string.char(194)
  .. "[" .. string.char(128) .. "-" .. string.char(159) .. "]"

-- ---------------------------------------------------------------- strings

function M.trim(value)
  if value == nil then
    return ""
  end
  local text = tostring(value)
  -- Bound untrusted strings before repeated pattern work. The 25 ms callback
  -- budget must not depend on a server-provided title or directory length.
  if #text > 1024 then
    text = text:sub(1, 1024)
  end
  local first = text:sub(1, 1)
  local last = text:sub(-1)
  if first ~= "" and not first:match("%s") and not last:match("%s") then
    return text
  end
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.compact(value)
  local text = M.trim(value)
  if text == "" then
    return ""
  end
  if not text:find(CONTROL_PATTERN)
    and not text:find(C1_CONTROL_PATTERN)
    and not text:find("%s%s")
    and not text:find("[\t\n\r\v\f]")
  then
    return text
  end
  text = text:gsub(CONTROL_PATTERN, "")
  text = text:gsub(C1_CONTROL_PATTERN, "")
  return (text:gsub("%s+", " "))
end

-- Truncate without splitting a UTF-8 codepoint.
local function utf8Prefix(text, maxBytes)
  if #text <= maxBytes then
    return text
  end
  local cut = maxBytes
  while cut > 0 do
    local following = string.byte(text, cut + 1)
    if following == nil or following < 0x80 or following >= 0xC0 then
      break
    end
    cut = cut - 1
  end
  if cut < 1 then
    return ""
  end
  return text:sub(1, cut)
end

function M.cut(value, maxChars)
  if value == nil then
    return ""
  end
  local text = tostring(value)
  -- Metadata is truncated without the full redaction pass to stay inside the
  -- 25 ms update budget, but control characters are still stripped so a
  -- server-provided title cannot inject terminal/ANSI sequences.
  if text:find(CONTROL_PATTERN) or text:find(C1_CONTROL_PATTERN) then
    text = text:gsub(CONTROL_PATTERN, ""):gsub(C1_CONTROL_PATTERN, "")
  end
  local limit = tonumber(maxChars) or 80
  if #text <= limit then
    return text
  end
  return utf8Prefix(text, limit)
end

function M.shorten(value, maxChars)
  local text = M.compact(value)
  local limit = tonumber(maxChars) or 80
  if #text <= limit then
    return text
  end
  if limit <= 3 then
    return utf8Prefix(text, limit)
  end
  return utf8Prefix(text, limit - 3) .. "..."
end

-- ---------------------------------------------------------------- redaction

local function ciPattern(word)
  local parts = {}
  for index = 1, #word do
    local ch = word:sub(index, index)
    local lower = ch:lower()
    local upper = ch:upper()
    if lower ~= upper then
      parts[#parts + 1] = "[" .. upper .. lower .. "]"
    elseif ch == "-" then
      parts[#parts + 1] = "%-"
    else
      parts[#parts + 1] = ch
    end
  end
  return table.concat(parts)
end

local SECRET_KEYS = {
  "authorization",
  "client_secret",
  "access_token",
  "refresh_token",
  "api_key",
  "apikey",
  "api-key",
  "password",
  "passwd",
  "cookie",
  "set-cookie",
  "secret",
  "token",
  "pwd",
}

local SECRET_KEY_PATTERNS = {}
for _, key in ipairs(SECRET_KEYS) do
  SECRET_KEY_PATTERNS[#SECRET_KEY_PATTERNS + 1] = ciPattern(key)
end

local AUTHORIZATION_PATTERN = ciPattern("authorization")
local SET_COOKIE_PATTERN = ciPattern("set-cookie")
local COOKIE_PATTERN = ciPattern("cookie")
local BEARER_PATTERN = "%f[%w][Bb][Ee][Aa][Rr][Ee][Rr]%s+[^%s,;\"']+"

local TOKEN_PATTERNS = {
  "%f[%w]sk%-[%w_%-]+",
  "%f[%w]gh[pousr]_[%w_]+",
  "%f[%w]github_pat_[%w_]+",
  "%f[%w]xox[abprs]%-[%w%-]+",
  "%f[%w]AKIA" .. string.rep("[%u%d]", 16),
  "%f[%w]AIza[%w_%-]+",
  "%f[%w]eyJ[%w_%-]+%.[%w_%-]+%.[%w_%-]+=*",
}

local PEM_PRIVATE_PATTERN =
  "%-%-%-%-%-BEGIN [^\r\n]-PRIVATE KEY%-%-%-%-%-.-%-%-%-%-%-END [^\r\n]-PRIVATE KEY%-%-%-%-%-"
local PEM_PRIVATE_ORPHAN_PATTERN =
  "%-%-%-%-%-BEGIN [^\r\n]-PRIVATE KEY%-%-%-%-%-.*"

local URL_PATTERN = "(%f[%w][Hh][Tt][Tt][Pp][Ss]?://[^%s\"'<>%)%]]+)"
local URL_USERINFO_PATTERN = "(%f[%w][A-Za-z][A-Za-z0-9+.-]*://)[^/@%s]+@"

-- Replace password/token/secret-style key/value pairs. Quoted values may
-- contain escaped quotes; unquoted values end at whitespace or a separator.
local function redactKeyValues(text, keyPattern)
  local pieces = {}
  local cursor = 1
  local search = 1
  local spans = 0
  local capped = false
  local pattern = keyPattern .. "%s*[\"']?%s*[:=]%s*"

  while true do
    if spans >= REDACT_MAX_SPANS then
      capped = true
      break
    end
    local _, endPos = text:find(pattern, search)
    if not endPos then
      break
    end
    local valueStart = endPos + 1
    local valueEnd = valueStart - 1
    local first = text:sub(valueStart, valueStart)
    if first == "\"" or first == "'" then
      local quote = first
      local index = valueStart + 1
      local closed = false
      while index <= #text do
        local ch = text:sub(index, index)
        if ch == "\\" then
          index = index + 2
        elseif ch == quote then
          -- Include the closing quote in the replaced span so no stray quote
          -- is left behind (e.g. password: "hunter2" -> password: [redacted]).
          valueEnd = index
          closed = true
          break
        else
          index = index + 1
        end
      end
      if not closed then
        valueEnd = #text
      end
    else
      local index = valueStart
      while index <= #text do
        local ch = text:sub(index, index)
        if ch == " " or ch == "\t" or ch == "," or ch == ";" then
          break
        end
        index = index + 1
      end
      valueEnd = index - 1
    end

    if valueEnd >= valueStart then
      local value = text:sub(valueStart, valueEnd)
      if value ~= REDACT_MARKER and value ~= "" then
        pieces[#pieces + 1] = text:sub(cursor, valueStart - 1)
        pieces[#pieces + 1] = REDACT_MARKER
        cursor = valueEnd + 1
        spans = spans + 1
      end
      search = valueEnd + 1
    else
      search = endPos + 1
    end
  end

  if cursor == 1 then
    return text
  end
  pieces[#pieces + 1] = capped and REDACT_MARKER or text:sub(cursor)
  return table.concat(pieces)
end

-- Redact compacted, bounded text. Secrets are replaced before shortening so a
-- truncated preview can never contain the beginning of a credential.
local function cacheRedact(key, result)
  if redactCacheSize >= REDACT_CACHE_LIMIT then
    redactCache = {}
    redactCacheSize = 0
  end
  redactCache[key] = result
  redactCacheSize = redactCacheSize + 1
  return result
end

function M.redact(value, maxChars)
  local text = tostring(value or "")
  if #text > REDACT_INPUT_LIMIT then
    text = utf8Prefix(text, REDACT_INPUT_LIMIT)
  end
  text = M.compact(text)
  if text == "" then
    return ""
  end
  local limit = maxChars or 200
  -- URL credentials and query values must be removed regardless of whether the
  -- text matches a secret keyword, otherwise a plain URL bypasses the fast path.
  if text:find("://", 1, true) then
    text = text:gsub(URL_PATTERN, function(url)
      return (url:gsub("[?#].*$", ""))
    end)
    text = text:gsub(URL_USERINFO_PATTERN, "%1" .. REDACT_MARKER .. "@")
  end
  local cacheKey = tostring(limit) .. "|" .. text
  local cached = redactCache[cacheKey]
  if cached ~= nil then
    return cached
  end
  local lower = text:lower()
  local suspicious = lower:find("bearer", 1, true)
    or lower:find("basic ", 1, true)
    or lower:find("authorization", 1, true)
    or lower:find("cookie", 1, true)
    or lower:find("password", 1, true)
    or lower:find("passwd", 1, true)
    or lower:find("pwd", 1, true)
    or lower:find("token", 1, true)
    or lower:find("secret", 1, true)
    or lower:find("api_key", 1, true)
    or lower:find("api-key", 1, true)
    or lower:find("-----begin", 1, true)
    or lower:find("private key", 1, true)
    or lower:find("akia", 1, true)
    or lower:find("ghp_", 1, true)
    or lower:find("gho_", 1, true)
    or lower:find("github_pat_", 1, true)
    or lower:find("sk-", 1, true)
    or lower:find("xox", 1, true)
  if not suspicious then
    local result = M.shorten(text, limit)
    if #text <= 2048 then
      return cacheRedact(cacheKey, result)
    end
    return result
  end

  text = text:gsub(PEM_PRIVATE_PATTERN, "[redacted private key]")
  text = text:gsub(PEM_PRIVATE_ORPHAN_PATTERN, "[redacted private key]")
  text = text:gsub(
    "(" .. AUTHORIZATION_PATTERN .. ")(%s*[:=]%s*)([^,;]+)",
    "%1%2" .. REDACT_MARKER
  )
  text = text:gsub(
    "(" .. SET_COOKIE_PATTERN .. ")(%s*[:=]%s*)([^,;]+)",
    "%1%2" .. REDACT_MARKER
  )
  text = text:gsub(
    "(" .. COOKIE_PATTERN .. ")(%s*[:=]%s*)([^,;]+)",
    "%1%2" .. REDACT_MARKER
  )
  text = text:gsub(BEARER_PATTERN, "Bearer " .. REDACT_MARKER)

  for _, keyPattern in ipairs(SECRET_KEY_PATTERNS) do
    text = redactKeyValues(text, keyPattern)
  end
  for _, pattern in ipairs(TOKEN_PATTERNS) do
    text = text:gsub(pattern, REDACT_MARKER)
  end

  local result = M.shorten(text, limit)
  if #text <= 2048 then
    return cacheRedact(cacheKey, result)
  end
  return result
end

function M.boundedString(value, maxChars)
  if type(value) ~= "string" then
    return ""
  end
  return M.redact(value, maxChars or 120)
end

function M.shortPath(path, maxChars)
  local text = M.trim(path)
  if text == "" then
    return ""
  end
  local limit = maxChars or 56
  local key = tostring(limit) .. "|" .. text
  local cached = shortPathCache[key]
  if cached ~= nil then
    return cached
  end
  if homeCache == nil then
    homeCache = M.trim(noctalia.getenv("HOME") or "")
  end
  local display = text
  if homeCache ~= "" and (text == homeCache or text:sub(1, #homeCache + 1) == homeCache .. "/") then
    display = "~" .. text:sub(#homeCache + 1)
  end
  local result = M.shorten(display, limit)
  if shortPathCacheSize >= CACHE_LIMIT then
    shortPathCache = {}
    shortPathCacheSize = 0
  end
  shortPathCache[key] = result
  shortPathCacheSize = shortPathCacheSize + 1
  return result
end

-- ---------------------------------------------------------------- security

local LOOPBACK_HOSTS = {
  ["127.0.0.1"] = true,
  ["localhost"] = true,
  ["[::1]"] = true,
}

-- Accept only http:// loopback base URLs with no credentials, query, fragment,
-- or path. Return the normalized base URL plus a display-only scheme/host/port.
function M.sanitizeServiceURL(raw)
  if type(raw) ~= "string" or raw == "" then
    return nil, nil, "OpenCode service URL is missing"
  end
  if #raw > 512 then
    return nil, nil, "OpenCode service URL is too long"
  end
  if raw:find("[%z\1-\31\127]") or raw:find("%s") then
    return nil, nil, "OpenCode service URL contains invalid characters"
  end
  local scheme, rest = raw:match("^([A-Za-z][A-Za-z0-9+.-]*)://(.*)$")
  if not scheme or scheme:lower() ~= "http" then
    return nil, nil, "OpenCode service URL must use http://"
  end
  if rest == "" then
    return nil, nil, "OpenCode service URL is missing a host"
  end
  if rest:find("?", 1, true) or rest:find("#", 1, true) then
    return nil, nil, "OpenCode service URL must not contain a query or fragment"
  end

  local slash = rest:find("/", 1, true)
  local authority = slash and rest:sub(1, slash - 1) or rest
  local path = slash and rest:sub(slash) or ""
  if authority == "" then
    return nil, nil, "OpenCode service URL is missing a host"
  end
  if authority:find("@", 1, true) then
    return nil, nil, "OpenCode service URL must not contain credentials"
  end

  local host
  local portText
  if authority:sub(1, 1) == "[" then
    local closing = authority:find("]", 2, true)
    if not closing then
      return nil, nil, "OpenCode service URL has an invalid host"
    end
    host = authority:sub(1, closing)
    local tail = authority:sub(closing + 1)
    if tail ~= "" then
      if tail:sub(1, 1) ~= ":" then
        return nil, nil, "OpenCode service URL has an invalid host"
      end
      portText = tail:sub(2)
    end
  else
    local colon = authority:find(":", 1, true)
    if colon then
      host = authority:sub(1, colon - 1)
      portText = authority:sub(colon + 1)
    else
      host = authority
    end
  end

  local normalizedHost = host and host:lower() or ""
  if not LOOPBACK_HOSTS[normalizedHost] then
    return nil, nil, "OpenCode service URL must point to 127.0.0.1, localhost, or [::1]"
  end

  local port = 80
  if portText ~= nil then
    if portText == "" or portText:find("%D") then
      return nil, nil, "OpenCode service URL has an invalid port"
    end
    port = tonumber(portText)
    if not port or port < 1 or port > 65535 then
      return nil, nil, "OpenCode service URL has an invalid port"
    end
    port = math.floor(port)
  end

  if path ~= "" and path ~= "/" then
    return nil, nil, "OpenCode service URL must not include a path"
  end

  local authorityText = normalizedHost
  if port ~= 80 then
    authorityText = authorityText .. ":" .. tostring(port)
  end
  local normalized = "http://" .. authorityText
  return normalized, normalized, nil
end

-- Session IDs are admitted only when path-safe, so no request path can be
-- redirected to another endpoint or contain traversal/query syntax.
function M.isSafeSessionID(id)
  return type(id) == "string"
    and #id > 0
    and #id <= MAX_SESSION_ID_LENGTH
    and id:match("^[A-Za-z0-9_-]+$") ~= nil
end

function M.encodePathSegment(id)
  local text = tostring(id or "")
  return (text:gsub("[^A-Za-z0-9._~-]", function(ch)
    return string.format("%%%02X", string.byte(ch))
  end))
end

-- ---------------------------------------------------------------- numbers

function M.intSetting(key, default, minValue, maxValue)
  local value = tonumber(noctalia.getConfig(key))
  if value == nil then
    value = default
  end
  value = math.floor(value)
  if minValue and value < minValue then
    value = minValue
  end
  if maxValue and value > maxValue then
    value = maxValue
  end
  return value
end

function M.boolSetting(key, default)
  local value = noctalia.getConfig(key)
  if type(value) == "boolean" then
    return value
  end
  if value == "true" or value == 1 or value == "1" then
    return true
  end
  if value == "false" or value == 0 or value == "0" then
    return false
  end
  return default
end

function M.stringSetting(key, default)
  local value = noctalia.getConfig(key)
  if value == nil then
    return default
  end
  return tostring(value)
end

function M.formatDuration(seconds)
  local value = tonumber(seconds) or 0
  if value < 0 then
    value = 0
  end
  value = math.floor(value)
  if value < 60 then
    return string.format("%ds", value)
  end
  if value < 3600 then
    return string.format("%dm", math.floor(value / 60))
  end
  if value < 86400 then
    local hours = math.floor(value / 3600)
    local mins = math.floor((value % 3600) / 60)
    if mins > 0 then
      return string.format("%dh %dm", hours, mins)
    end
    return string.format("%dh", hours)
  end
  local days = math.floor(value / 86400)
  local hours = math.floor((value % 86400) / 3600)
  if hours > 0 and days < 7 then
    return string.format("%dd %dh", days, hours)
  end
  return string.format("%dd", days)
end

function M.relativeTime(timestampMs, nowMs)
  local stamp = tonumber(timestampMs)
  if not stamp or stamp <= 0 then
    return ""
  end
  local now = tonumber(nowMs) or noctalia.nowMs()
  local diff = (now - stamp) / 1000
  if diff < 0 then
    diff = 0
  end
  if diff < 10 then
    return "just now"
  end
  return M.formatDuration(diff) .. " ago"
end

function M.formatTokens(value)
  local count = tonumber(value) or 0
  if count >= 1000000 then
    return string.format("%.1fM", count / 1000000)
  end
  if count >= 1000 then
    return string.format("%.1fk", count / 1000)
  end
  return string.format("%d", math.floor(count))
end

function M.formatCost(value)
  local cost = tonumber(value) or 0
  if cost <= 0 then
    return "$0.00"
  end
  if cost < 0.01 then
    return "<$0.01"
  end
  if cost < 1 then
    return string.format("$%.3f", cost)
  end
  return string.format("$%.2f", cost)
end

-- ---------------------------------------------------------------- JSON/API

function M.decode(value)
  if type(value) == "table" then
    return value
  end
  if type(value) ~= "string" or value == "" then
    return nil
  end
  local ok, decoded = pcall(noctalia.json.decode, value)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

-- Read the local per-user OpenCode v2 service registration.
function M.findService()
  local stateHome = M.trim(noctalia.getenv("XDG_STATE_HOME") or "")
  if stateHome == "" then
    local home = M.trim(noctalia.getenv("HOME") or "")
    if home == "" then
      return nil, "HOME is not set"
    end
    stateHome = home .. "/.local/state"
  end
  local path = stateHome .. "/opencode/service.json"

  -- The host follows symlinks and exposes only size/mtime/isDir, so validate
  -- type and size here; owner/mode/symlink checks remain a host limitation.
  local infoOk, info = pcall(noctalia.fileInfo, path)
  if not infoOk or type(info) ~= "table" then
    return nil, "OpenCode service file not found"
  end
  if info.isDir == true then
    return nil, "OpenCode service file is not a regular file"
  end
  local size = tonumber(info.size) or 0
  if size <= 0 then
    return nil, "OpenCode service file is empty"
  end
  if size > MAX_SERVICE_FILE_BYTES then
    return nil, "OpenCode service file is too large"
  end

  local readOk, content = pcall(noctalia.readFile, path)
  if not readOk or type(content) ~= "string" or content == "" then
    return nil, "Cannot read OpenCode service file"
  end
  if #content > MAX_SERVICE_FILE_BYTES then
    return nil, "OpenCode service file is too large"
  end

  local data = M.decode(content)
  if not data then
    return nil, "Invalid OpenCode service file"
  end
  local url, displayURL, urlError = M.sanitizeServiceURL(data.url)
  if not url then
    return nil, urlError or "Invalid OpenCode service URL"
  end
  if type(data.password) ~= "string" or data.password == "" then
    return nil, "OpenCode service password is missing"
  end

  local version = data.version
  if type(version) == "number" then
    version = tostring(version)
  end
  if type(version) ~= "string" then
    version = nil
  end
  local pid = data.pid
  if type(pid) ~= "number" and type(pid) ~= "string" then
    pid = nil
  end
  local id = data.id
  if type(id) ~= "string" then
    id = nil
  end

  return {
    url = url,
    displayURL = displayURL,
    username = "opencode",
    password = data.password,
    version = version,
    pid = pid,
    id = id,
  }
end

function M.serverKey(server)
  if not server then
    return ""
  end
  return tostring(server.url or "")
    .. "|"
    .. tostring(server.id or "")
    .. "|"
    .. tostring(server.pid or "")
end

-- Authenticated JSON GET against the local service. callback(data, error).
function M.apiGet(server, path, callback)
  local finished = false
  local function finish(data, err)
    if finished then
      return
    end
    finished = true
    callback(data, err)
  end

  if not server or not server.url then
    finish(nil, "No OpenCode server configured")
    return
  end
  if type(path) ~= "string" or path:sub(1, 1) ~= "/" then
    finish(nil, "Invalid OpenCode API path")
    return
  end

  local ok, err = pcall(function()
    local baseURL, _, urlError = M.sanitizeServiceURL(server.url)
    if not baseURL then
      finish(nil, urlError or "Invalid OpenCode server URL")
      return
    end
    local request = {
      url = baseURL .. path,
      method = "GET",
      headers = { ["Accept"] = "application/json" },
      follow_redirects = false,
      basic_username = server.username or "opencode",
      basic_password = server.password or "",
    }
    local started = noctalia.http(request, function(response)
      if response == nil then
        finish(nil, "No response")
        return
      end
      local status = tonumber(response.status) or 0
      local body = type(response.body) == "string" and response.body or ""
      if response.ok == false or status < 200 or status >= 300 then
        -- Never echo an error body: it can contain echoed headers, paths, or
        -- secrets. Status-only diagnostics keep the snapshot safe.
        finish(nil, string.format("HTTP %s", tostring(response.status or "?")))
        return
      end
      -- The host buffers the whole body; the plugin can only refuse to parse
      -- oversized payloads before JSON decode.
      if #body > MAX_RESPONSE_BYTES then
        finish(nil, "Response too large")
        return
      end
      if body == "" then
        finish({}, nil)
        return
      end
      local data = M.decode(body)
      if data == nil then
        finish(nil, "Invalid JSON response")
        return
      end
      finish(data, nil)
    end)
    if started == false then
      finish(nil, "Request could not start")
    end
  end)
  if not ok then
    finish(nil, "Request failed: " .. M.redact(tostring(err), 140))
  end
end

-- ---------------------------------------------------------------- activity

local TOOL_LABELS = {
  shell = "Running command",
  bash = "Running command",
  exec = "Running command",
  read = "Reading file",
  write = "Writing file",
  edit = "Editing file",
  patch = "Editing file",
  apply_patch = "Applying patch",
  glob = "Finding files",
  grep = "Searching code",
  list = "Listing files",
  ls = "Listing files",
  webfetch = "Fetching page",
  websearch = "Searching the web",
  task = "Running subagent",
  subagent = "Running subagent",
  todowrite = "Updating tasks",
  todo = "Updating tasks",
  skill = "Loading skill",
  question = "Asking a question",
  lsp = "Checking code",
  diagnostics = "Checking code",
}

local TOOL_GLYPHS = {
  shell = "terminal-2",
  bash = "terminal-2",
  exec = "terminal-2",
  read = "file-text",
  write = "file-pencil",
  edit = "file-pencil",
  patch = "file-pencil",
  apply_patch = "file-pencil",
  glob = "files",
  grep = "search",
  list = "list",
  ls = "list",
  webfetch = "world",
  websearch = "world-search",
  task = "users",
  subagent = "users",
  todowrite = "checklist",
  todo = "checklist",
  skill = "sparkles",
  question = "help-circle",
  lsp = "code",
  diagnostics = "code",
}

local function timeField(timeValue, key)
  if type(timeValue) == "number" then
    return timeValue
  end
  if type(timeValue) == "table" then
    local value = timeValue[key]
    if type(value) == "number" then
      return value
    end
  end
  return nil
end

M.timeField = timeField

local function toolDetail(name, input)
  if type(input) ~= "table" then
    return ""
  end

  if name == "todowrite" or name == "todo" then
    local todos = input.todos
    if type(todos) == "table" then
      local total = math.min(#todos, 200)
      local done = 0
      for index = 1, total do
        local todo = todos[index]
        if type(todo) == "table" and (todo.status == "completed" or todo.status == "done") then
          done = done + 1
        end
      end
      if total > 0 then
        return string.format("%d/%d tasks", done, total)
      end
    end
  end

  local candidateKeys = {
    "description",
    "command",
    "filePath",
    "file_path",
    "path",
    "pattern",
    "query",
    "url",
    "agent",
    "prompt",
    "name",
    "task",
  }
  for _, key in ipairs(candidateKeys) do
    local candidate = input[key]
    if type(candidate) == "string" then
      local detail = M.redact(candidate, 110)
      if detail ~= "" then
        return detail
      end
    end
  end
  return ""
end

-- Read the newest assistant message and describe what is happening right now.
function M.extractActivity(message)
  if type(message) ~= "table" or message.type ~= "assistant" then
    return nil
  end
  local content = message.content
  if type(content) ~= "table" then
    return nil
  end
  local firstIndex = #content - 49
  if firstIndex < 1 then
    firstIndex = 1
  end

  local function fromTool(tool)
    local state = type(tool.state) == "table" and tool.state or {}
    local name = "tool"
    if type(tool.name) == "string"
      and #tool.name <= 32
      and tool.name:match("^[A-Za-z0-9_-]+$")
    then
      name = tool.name
    end
    local status = state.status
    if type(status) ~= "string"
      or #status > 32
      or status:match("^[A-Za-z0-9_-]+$") == nil
    then
      status = nil
    end
    return {
      kind = "tool",
      name = name,
      label = TOOL_LABELS[name] or ("Using " .. name),
      glyph = TOOL_GLYPHS[name] or "tool",
      detail = toolDetail(name, state.input),
      status = status,
      since = timeField(tool.time, "ran") or timeField(tool.time, "created") or timeField(message.time, "created"),
    }
  end

  -- A tool that is still executing is the most useful thing to show.
  for index = #content, firstIndex, -1 do
    local item = content[index]
    if type(item) == "table" and item.type == "tool" then
      local status = type(item.state) == "table" and item.state.status or nil
      if status == "running" or status == "streaming" then
        return fromTool(item)
      end
    end
  end

  -- Otherwise show the newest reasoning/text chunk.
  for index = #content, firstIndex, -1 do
    local item = content[index]
    if type(item) == "table" then
      if item.type == "reasoning" and type(item.text) == "string" then
        local detail = M.redact(item.text, 110)
        if detail ~= "" then
          return {
            kind = "reasoning",
            name = "reasoning",
            label = "Thinking",
            glyph = "brain",
            detail = detail,
            since = timeField(item.time, "created") or timeField(message.time, "created"),
          }
        end
      end
      if item.type == "text" and type(item.text) == "string" then
        local detail = M.redact(item.text, 110)
        if detail ~= "" then
          return {
            kind = "text",
            name = "text",
            label = "Writing response",
            glyph = "message-2",
            detail = detail,
            since = timeField(item.time, "created") or timeField(message.time, "created"),
          }
        end
      end
    end
  end

  if message.error then
    local err = message.error
    local text = type(err) == "table" and (err.message or err.name) or err
    if type(text) ~= "string" or text == "" then
      text = "Error"
    end
    local detail = M.redact(text, 110)
    if detail == "" then
      detail = "Error"
    end
    return {
      kind = "error",
      name = "error",
      label = "Error",
      glyph = "alert-triangle",
      detail = detail,
      since = timeField(message.time, "created"),
    }
  end

  if type(message.time) == "table" and message.time.completed == nil then
    return {
      kind = "working",
      name = "working",
      label = "Working",
      glyph = "loader",
      detail = "",
      since = timeField(message.time, "created") or timeField(message.time, "streamed"),
    }
  end

  return nil
end

-- ---------------------------------------------------------------- waits

function M.permissionWait(requests)
  if type(requests) ~= "table" or #requests == 0 then
    return nil
  end
  local first = type(requests[1]) == "table" and requests[1] or {}
  local title = M.boundedString(first.message, 130)
  if title == "" then
    title = "Permission required"
  end
  local detail = ""
  local action = M.boundedString(first.action, 130)
  local resources = first.resources
  if type(resources) == "table" and #resources > 0 then
    local resource = M.boundedString(resources[1], 130)
    if action ~= "" then
      detail = action .. ": " .. resource
    else
      detail = resource
    end
  elseif action ~= "" then
    detail = action
  end
  local source = first.source
  if detail == "" and type(source) == "table" and source.type ~= nil then
    local sourceType = M.boundedString(source.type, 60)
    if sourceType ~= "" then
      detail = "Requested by " .. sourceType
    end
  end
  return {
    kind = "permission",
    title = M.shorten(title, 130),
    detail = M.shorten(detail, 130),
    count = #requests,
    glyph = "shield-exclamation",
  }
end

function M.formWait(forms)
  if type(forms) ~= "table" or #forms == 0 then
    return nil
  end
  local first = type(forms[1]) == "table" and forms[1] or {}
  local title = M.boundedString(first.title, 130)
  if title == "" then
    title = "Input required"
  end
  local labels = {}
  local fields = first.fields
  if type(fields) == "table" then
    for index = 1, math.min(#fields, 4) do
      local field = fields[index]
      if type(field) == "table" then
        local label = M.boundedString(field.title, 60)
        if label == "" then
          label = M.boundedString(field.key, 60)
        end
        if label ~= "" then
          labels[#labels + 1] = label
        end
      end
    end
  end
  return {
    kind = "form",
    title = M.shorten(title, 130),
    detail = M.shorten(table.concat(labels, " · "), 130),
    count = #forms,
    glyph = "help-circle",
  }
end

-- ---------------------------------------------------------------- status

local STATUS = {
  waiting_permission = {
    label = "Needs permission",
    glyph = "shield-exclamation",
    color = "error",
    rank = 1,
  },
  waiting_input = {
    label = "Needs input",
    glyph = "help-circle",
    color = "secondary",
    rank = 2,
  },
  running = {
    label = "Working",
    glyph = "loader",
    color = "primary",
    rank = 3,
  },
  failed = {
    label = "Failed",
    glyph = "alert-triangle",
    color = "error",
    rank = 4,
  },
  done = {
    label = "Done",
    glyph = "circle-check",
    color = "on_surface_variant",
    rank = 5,
  },
  idle = {
    label = "Idle",
    glyph = "clock",
    color = "on_surface_variant",
    rank = 6,
  },
}

function M.statusMeta(status)
  return STATUS[status] or STATUS.idle
end

return M
