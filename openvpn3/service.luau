--!nonstrict
-- Owns all OpenVPN 3 access and shares one status with every UI entry.
--
-- Profiles live in openvpn3's own configuration manager (imported through the
-- panel), so nothing here depends on where the .ovpn files are stored.
-- Sessions, statistics and interactive prompts (credentials, challenges,
-- private-key passphrases, web login) go through the openvpn3 D-Bus API via
-- busctl, which needs no terminal.

local SESS = "net.openvpn.v3.sessions"
local SESS_ROOT = "/net/openvpn/v3/sessions"
local CFG = "net.openvpn.v3.configuration"
local PROPS = "org.freedesktop.DBus.Properties"

-- Session status minor codes, from openvpn3's own StatusMinor enum
-- (constants.py of the installed client; 4-7 and 14-15 also seen on a live one).
local MINOR_STATE = {
  [1] = "failed", [4] = "attention", [5] = "connecting", [6] = "connecting", [7] = "connected",
  [8] = "disconnected", [9] = "disconnected", [10] = "failed", [11] = "failed",
  [12] = "connecting", [13] = "paused", [14] = "paused", [15] = "connecting",
  [16] = "disconnected", [17] = "connecting", [18] = "disconnected", [19] = "disconnected",
  [20] = "attention", [21] = "attention", [22] = "attention", [27] = "connecting",
  [28] = "failed", [29] = "failed",
}

local status = {
  state = "checking",
  available = false,
  busy = false,
  busyProfile = "",
  message = "",
  sessions = {},
  profiles = {},
  pending = nil,
  notice = nil,
}

local function nowSeconds()
  return noctalia.nowMs() / 1000
end

local function nonce()
  return noctalia.nowMs()
end

local AUTOCONNECT_TAG = "noctalia-autoconnect"
local lastStates = {} -- session path -> { state, config } for notifications
local refreshStartedMs = 0
local workingSinceMs = 0
local refreshErrored = false
local logs = {} -- session path -> { lines, started, dirty } from `openvpn3 log`
local sessionsLoaded = false
local autoconnectDone = false
local samples = {} -- session path -> { time, bytesIn, bytesOut } for speed estimates
local attempt = nil -- the connection currently being established
local working = 0 -- in-flight management actions (import, remove, options...)
local refreshing = false
local lastPublished = ""

local refreshSessions
local maybeAutoconnect

local function overridesKey(overrides)
  local keys = {}
  for k in pairs(overrides or {}) do
    table.insert(keys, k)
  end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    table.insert(parts, k .. "=" .. tostring(overrides[k]))
  end
  return table.concat(parts, ",")
end

local function publish()
  local parts = {
    status.state, tostring(status.available), tostring(status.busy), status.busyProfile,
    status.message,
  }
  for _, s in ipairs(status.sessions) do
    table.insert(parts, table.concat({
      s.path, s.config, s.device, s.remote, s.state, s.message,
      tostring(s.bytesIn), tostring(s.bytesOut), tostring(math.floor((s.created or 0) / 5)), tostring(math.floor((s.rateIn or -1) / 256)), tostring(math.floor((s.rateOut or -1) / 256)),
    }, "~"))
  end
  for _, p in ipairs(status.profiles) do
    table.insert(parts, table.concat({
      p.path, p.name, tostring(p.valid), tostring(p.dco), tostring(p.autoconnect), p.lastUsed, overridesKey(p.overrides),
    }, "~"))
  end
  if type(status.pending) == "table" then
    local pending = status.pending
    table.insert(parts, "pending:" .. pending.kind .. pending.profile .. tostring(#pending.fields) .. (pending.url or "") .. (pending.error or ""))
  end
  if status.notice ~= nil then
    table.insert(parts, "notice:" .. tostring(status.notice.nonce))
  end
  local key = table.concat(parts, "|")
  if key == lastPublished then
    return
  end
  lastPublished = key
  noctalia.state.set("openvpn3.status", {
    state = status.state,
    available = status.available,
    busy = status.busy,
    busyProfile = status.busyProfile,
    message = status.message,
    sessions = status.sessions,
    profiles = status.profiles,
    pending = status.pending,
    notice = status.notice,
  })
end

-- Pass `pending = false` to clear the prompt: a nil value would be skipped by pairs().
local function patch(values)
  for k, v in pairs(values) do
    if k == "pending" and type(v) ~= "table" then
      status.pending = nil
    else
      status[k] = v
    end
  end
  publish()
end

local function setBusy()
  patch({ busy = working > 0 or attempt ~= nil })
end

local function expandHome(path)
  local home = noctalia.getenv("HOME") or ""
  if path == "~" then
    return home
  elseif string.sub(path, 1, 2) == "~/" then
    return home .. string.sub(path, 2)
  end
  return path
end

local function trim(text)
  return (string.gsub(string.gsub(text or "", "^%s+", ""), "%s+$", ""))
end

local function lastLine(text)
  local last = ""
  for line in string.gmatch(text or "", "[^\n]+") do
    if string.match(line, "%S") then
      last = line
    end
  end
  return trim(last)
end

-- "Call failed: GDBus.Error:net.openvpn.v3.error.ready: Missing user credentials"
-- -> "Missing user credentials"
local function errorText(result)
  local text = lastLine(result.stderr)
  if text == "" then
    text = lastLine(result.stdout)
  end
  local detail = string.match(text, "GDBus%.Error:[^:]+:%s*(.+)$")
  if detail ~= nil then
    text = detail
  end
  text = string.gsub(text, "^.-net%.openvpn%.v3%.[%w%-]+:%s*", "")
  if text == "" then
    text = noctalia.tr("error.command-failed")
  end
  return trim(text)
end

local function fail(text)
  patch({ message = text })
  noctalia.notifyError(noctalia.tr("title"), text)
end

-- busctl wrapper. cb(ok, decoded, result); decoded is the parsed --json body.
local function bus(args, cb, timeoutMs)
  local argv = { "busctl", "--system", "--json=short" }
  for _, a in ipairs(args) do
    table.insert(argv, a)
  end
  local accepted = noctalia.runAsync(argv, function(result)
    local decoded = nil
    if result.exitCode == 0 then
      decoded = noctalia.json.decode(result.stdout or "")
    end
    cb(result.exitCode == 0, decoded, result)
  end, timeoutMs or 8000)
  if not accepted then
    cb(false, nil, { exitCode = -1, stdout = "", stderr = "" })
  end
end

local function sessionCall(path, method, extra, cb)
  local args = { "call", SESS, path, SESS, method }
  for _, a in ipairs(extra or {}) do
    table.insert(args, a)
  end
  bus(args, cb)
end

local function getAll(service, path, iface, cb)
  bus({ "call", service, path, PROPS, "GetAll", "s", iface }, function(ok, decoded)
    local props = nil
    if ok and type(decoded) == "table" and type(decoded.data) == "table" then
      props = decoded.data[1]
    end
    cb(if type(props) == "table" then props else nil)
  end)
end

local function prop(props, key)
  local entry = props[key]
  return if type(entry) == "table" then entry.data else nil
end

-- ---------------------------------------------------------------------------
-- Profiles (openvpn3 configuration manager)
-- ---------------------------------------------------------------------------

local function formatStamp(ts)
  local n = tonumber(ts)
  if n == nil or n <= 0 then
    return ""
  end
  return os.date("%Y-%m-%d %H:%M", n)
end

local function refreshProfiles()
  noctalia.runAsync({ "openvpn3", "configs-list", "--json" }, function(result)
    local decoded = noctalia.json.decode(result.stdout or "")
    if result.exitCode ~= 0 or type(decoded) ~= "table" then
      return
    end
    local profiles = {}
    for path, entry in pairs(decoded) do
      if type(entry) == "table" and type(entry.name) == "string" then
        table.insert(profiles, {
          path = path,
          name = entry.name,
          valid = entry.valid ~= false,
          invalidReason = trim(entry.invalid_reason or ""),
          dco = entry.dco == true,
          overrides = {},
          autoconnect = false,
          lastUsed = formatStamp(entry.lastused_tstamp),
        })
      end
    end
    table.sort(profiles, function(a, b)
      return string.lower(a.name) < string.lower(b.name)
    end)
    -- Overrides (persistent tunnel) are only exposed through the config object.
    local function readOverrides(index)
      local profile = profiles[index]
      if profile == nil then
        patch({ profiles = profiles })
        maybeAutoconnect()
        return
      end
      getAll(CFG, profile.path, CFG, function(props)
        if props ~= nil then
          local tags = prop(props, "tags")
          if type(tags) == "table" then
            for _, tag in ipairs(tags) do
              if tag == AUTOCONNECT_TAG then
                profile.autoconnect = true
              end
            end
          end
          local overrides = prop(props, "overrides")
          if type(overrides) == "table" then
            for key, entry in pairs(overrides) do
              if type(entry) == "table" then
                profile.overrides[key] = entry.data
              end
            end
          end
        end
        readOverrides(index + 1)
      end)
    end
    readOverrides(1)
  end, 10000)
end

-- ---------------------------------------------------------------------------
-- Sessions
-- ---------------------------------------------------------------------------

local function parseSession(path, props)
  local st = prop(props, "status")
  local minor = if type(st) == "table" then tonumber(st[2]) or 0 else 0
  local message = if type(st) == "table" then tostring(st[3] or "") else ""
  local remote = prop(props, "connected_to")
  local remoteText = ""
  if type(remote) == "table" and tostring(remote[2] or "") ~= "" then
    remoteText = `{remote[1]}:{remote[2]}:{remote[3]}`
  end
  local stats = prop(props, "statistics")
  local config = tostring(prop(props, "config_name") or "")
  config = string.gsub(string.gsub(config, "^.*/", ""), "%.ovpn$", "")
  return {
    path = path,
    config = config,
    configPath = tostring(prop(props, "config_path") or ""),
    device = tostring(prop(props, "device_name") or ""),
    remote = remoteText,
    serverName = tostring(prop(props, "session_name") or ""),
    state = MINOR_STATE[minor] or "connecting",
    minor = minor,
    message = message,
    created = tonumber(prop(props, "session_created")) or 0,
    bytesIn = if type(stats) == "table" and stats.BYTES_IN ~= nil then tonumber(stats.BYTES_IN) else -1,
    bytesOut = if type(stats) == "table" and stats.BYTES_OUT ~= nil then tonumber(stats.BYTES_OUT) else -1,
  }
end

-- Tell the user about connection changes, whoever started the session.
local function notifyTransitions(sessions)
  local enabled = noctalia.getConfig("notifications") ~= false
  local seen = {}
  for _, s in ipairs(sessions) do
    seen[s.path] = true
    local prev = lastStates[s.path]
    if enabled and sessionsLoaded and (prev == nil or prev.state ~= s.state) then
      local title = noctalia.tr("title")
      local ownAttempt = attempt ~= nil and attempt.session == s.path
      if s.state == "connected" then
        if prev ~= nil and prev.state == "paused" then
          noctalia.notify(title, `{noctalia.tr("notify.resumed")}: {s.config}`)
        else
          noctalia.notify(title, `{noctalia.tr("notify.connected")}: {s.config}` .. (if s.remote ~= "" then ` ({s.remote})` else ""))
        end
      elseif s.state == "connecting" and prev ~= nil and prev.state == "connected" then
        noctalia.notify(title, `{noctalia.tr("notify.reconnecting")}: {s.config}`)
      elseif s.state == "paused" and prev ~= nil and prev.state == "connected" then
        noctalia.notify(title, `{noctalia.tr("notify.paused")}: {s.config}`)
      elseif s.state == "failed" and not ownAttempt then
        noctalia.notifyError(title, `{noctalia.tr("notify.failed")}: {s.config}` .. (if s.message ~= "" then ` - {s.message}` else ""))
      end
    end
    lastStates[s.path] = { state = s.state, config = s.config }
  end
  for path, prev in pairs(lastStates) do
    if not seen[path] then
      lastStates[path] = nil
      if enabled and sessionsLoaded and (prev.state == "connected" or prev.state == "paused") then
        noctalia.notify(noctalia.tr("title"), `{noctalia.tr("notify.disconnected")}: {prev.config}`)
      end
    end
  end
end

local function overallState(sessions)
  for _, wanted in ipairs({ "connected", "connecting", "attention", "paused" }) do
    for _, s in ipairs(sessions) do
      if s.state == wanted then
        return wanted
      end
    end
  end
  return "disconnected"
end

local function findSession(path)
  for _, s in ipairs(status.sessions) do
    if s.path == path then
      return s
    end
  end
  return nil
end

local function disconnectPaths(paths, index, done)
  local path = paths[index]
  if path == nil then
    done()
    return
  end
  sessionCall(path, "Disconnect", nil, function()
    disconnectPaths(paths, index + 1, done)
  end)
end

-- ---------------------------------------------------------------------------
-- Connection log (`openvpn3 log`), streamed per session
-- ---------------------------------------------------------------------------

local LOG_MAX = 200

local function publishLog(path)
  local entry = logs[path]
  if entry == nil then
    return
  end
  entry.dirty = false
  noctalia.state.set("openvpn3.log", { path = path, lines = entry.lines, nonce = nonce() })
end

-- Log events are only delivered live, so the stream starts as early as possible
-- (when a session is created, or when the log is first opened). The stream is
-- capped by `timeout` because runStream offers no way to stop it.
local function startLog(path)
  if not string.match(path, "^/net/openvpn/v3/sessions/[%w_]+$") then
    return
  end
  local entry = logs[path]
  if entry == nil then
    entry = { lines = {}, started = 0, dirty = false }
    logs[path] = entry
  end
  if os.time() - entry.started < 290 then
    return
  end
  entry.started = os.time()
  noctalia.runStream(`timeout 300 openvpn3 log --session-path '{path}' --log-level 5 2>&1`, function(line)
    local text = trim(line)
    if text == "" then
      return
    end
    table.insert(entry.lines, text)
    while #entry.lines > LOG_MAX do
      table.remove(entry.lines, 1)
    end
    entry.dirty = true
  end)
end

-- ---------------------------------------------------------------------------
-- Connection attempts, including interactive prompts
-- ---------------------------------------------------------------------------

local function endAttempt()
  attempt = nil
  noctalia.setUpdateInterval((noctalia.getConfig("poll_seconds") or 5) * 1000)
  patch({ pending = false, busyProfile = "" })
  setBusy()
end

local function abortAttempt(text, sessionPath)
  local failedProfile = if attempt ~= nil then attempt.profile else ""
  endAttempt()
  local finish = function()
    if text ~= nil and text ~= "" then
      fail(if failedProfile ~= "" then `{failedProfile}: {text}` else text)
    end
    refreshSessions()
  end
  if sessionPath ~= nil then
    sessionCall(sessionPath, "Disconnect", nil, finish)
  else
    finish()
  end
end

-- Reads every pending input request of a session into a flat field list.
local function collectFields(sessionPath, cb)
  sessionCall(sessionPath, "UserInputQueueGetTypeGroup", nil, function(ok, decoded)
    local fields = {}
    local pairsList = if ok and type(decoded) == "table" and type(decoded.data) == "table" then decoded.data[1] else nil
    if type(pairsList) ~= "table" or #pairsList == 0 then
      cb(fields)
      return
    end
    local function nextPair(index)
      local pair = pairsList[index]
      if pair == nil then
        cb(fields)
        return
      end
      local t, g = tostring(pair[1]), tostring(pair[2])
      sessionCall(sessionPath, "UserInputQueueCheck", { "uu", t, g }, function(ok2, ids)
        local idList = if ok2 and type(ids) == "table" and type(ids.data) == "table" then ids.data[1] else nil
        local function nextId(i)
          local id = if type(idList) == "table" then idList[i] else nil
          if id == nil then
            nextPair(index + 1)
            return
          end
          sessionCall(sessionPath, "UserInputQueueFetch", { "uuu", t, g, tostring(id) }, function(ok3, fetched)
            local d = if ok3 and type(fetched) == "table" then fetched.data else nil
            if type(d) == "table" then
              table.insert(fields, {
                type = d[1], group = d[2], id = d[3],
                name = tostring(d[4] or ""),
                label = tostring(d[5] or d[4] or ""),
                hidden = d[6] == true,
              })
            end
            nextId(i + 1)
          end)
        end
        nextId(1)
      end)
    end
    nextPair(1)
  end)
end

local function requestInput(fields, errorMessage)
  if attempt == nil then
    return
  end
  attempt.phase = "input"
  noctalia.notify(noctalia.tr("title"), `{noctalia.tr("panel.auth-needed")}: {attempt.profile}`)
  patch({
    pending = { kind = "credentials", profile = attempt.profile, fields = fields, error = errorMessage or "" },
    busy = true,
  })
end

local function startConnect(sessionPath)
  local cur = attempt
  sessionCall(sessionPath, "Connect", nil, function(ok, _decoded, result)
    if cur == nil or attempt ~= cur then
      return
    end
    if not ok then
      abortAttempt(errorText(result), sessionPath)
      return
    end
    cur.connectCalled = true
    cur.phase = "connecting"
    cur.deadline = os.time() + (noctalia.getConfig("connect_timeout") or 45)
    patch({ pending = false })
  end)
end

-- Ready succeeds once every required credential has been provided.
local function readyThenConnect(sessionPath)
  local cur = attempt
  sessionCall(sessionPath, "Ready", nil, function(ok, _decoded, result)
    if cur == nil or attempt ~= cur then
      return
    end
    if ok then
      if cur.connectCalled then
        -- Answer to a challenge raised mid-connection: the session is already running.
        cur.phase = "connecting"
        cur.deadline = os.time() + (noctalia.getConfig("connect_timeout") or 45)
        patch({ pending = false })
      else
        startConnect(sessionPath)
      end
      return
    end
    collectFields(sessionPath, function(fields)
      if attempt ~= cur then
        return
      end
      if #fields > 0 then
        requestInput(fields, nil)
      else
        abortAttempt(errorText(result), sessionPath)
      end
    end)
  end)
end

local function beginSession(profile, sessionPath)
  attempt.session = sessionPath
  startLog(sessionPath)
  -- Mirror the profile's data channel offload flag onto the new session.
  bus({ "set-property", SESS, sessionPath, SESS, "dco", "b", if profile.dco then "true" else "false" }, function()
    readyThenConnect(sessionPath)
  end)
end

local function findProfile(name)
  for _, p in ipairs(status.profiles) do
    if p.name == name then
      return p
    end
  end
  return nil
end

local function connect(name, path)
  if attempt ~= nil or working > 0 then
    return
  end
  if not noctalia.commandExists("openvpn3") then
    fail(noctalia.tr("error.cli-missing"))
    return
  end
  local profile = nil
  if path ~= nil and path ~= "" then
    for _, p in ipairs(status.profiles) do
      if p.path == path then
        profile = p
      end
    end
  end
  if profile == nil and name ~= nil and name ~= "" then
    profile = findProfile(name)
  end
  if profile == nil then
    local wanted = noctalia.getConfig("default_profile") or ""
    profile = if wanted ~= "" then findProfile(wanted) else nil
  end
  if profile == nil then
    for _, p in ipairs(status.profiles) do
      if p.valid then
        profile = p
        break
      end
    end
  end
  if profile == nil then
    fail(noctalia.tr("error.no-profile"))
    return
  end
  if not profile.valid then
    fail(`{profile.name}: {profile.invalidReason}`)
    return
  end

  attempt = {
    profile = profile.name,
    session = "",
    phase = "starting",
    deadline = os.time() + (noctalia.getConfig("connect_timeout") or 45) + 10,
  }
  noctalia.setUpdateInterval(1000)
  patch({ busy = true, busyProfile = profile.name, message = "", state = "connecting" })

  local stale = {}
  if noctalia.getConfig("single_session") ~= false then
    for _, s in ipairs(status.sessions) do
      table.insert(stale, s.path)
    end
  end
  disconnectPaths(stale, 1, function()
    local cur = attempt
    sessionCall(SESS_ROOT, "NewTunnel", { "o", profile.path }, function(ok, decoded, result)
      if cur == nil or attempt ~= cur then
        -- Cancelled while the tunnel was being created: don't leave it behind.
        if type(decoded) == "table" and type(decoded.data) == "table" and type(decoded.data[1]) == "string" then
          sessionCall(decoded.data[1], "Disconnect", nil, function() end)
        end
        return
      end
      local path = if ok and type(decoded) == "table" and type(decoded.data) == "table" then decoded.data[1] else nil
      if type(path) ~= "string" then
        abortAttempt(errorText(result), nil)
        return
      end
      beginSession(profile, path)
    end)
  end)
end

-- values: array of strings aligned with status.pending.fields
local function submitInput(values)
  if attempt == nil or status.pending == nil or attempt.session == "" then
    return
  end
  local fields = status.pending.fields
  local sessionPath = attempt.session
  local cur = attempt
  attempt.phase = "starting"
  attempt.deadline = os.time() + (noctalia.getConfig("connect_timeout") or 45) + 10
  patch({ pending = false })
  local function provide(index)
    local field = fields[index]
    if field == nil then
      readyThenConnect(sessionPath)
      return
    end
    local value = if type(values) == "table" then tostring(values[index] or "") else ""
    sessionCall(sessionPath, "UserInputProvide", { "uuus", tostring(field.type), tostring(field.group), tostring(field.id), value }, function(ok, _decoded, result)
      if attempt ~= cur then
        return
      end
      if not ok then
        abortAttempt(errorText(result), sessionPath)
        return
      end
      provide(index + 1)
    end)
  end
  provide(1)
end

local function cancelAttempt()
  if attempt == nil then
    -- Nothing in flight (e.g. the service was reloaded): drop a stale prompt and
    -- tear down any session still waiting for input.
    patch({ pending = false, busyProfile = "" })
    setBusy()
    for _, s in ipairs(status.sessions) do
      if s.state == "attention" or (s.state == "connecting" and s.minor == 4) then
        sessionCall(s.path, "Disconnect", nil, function()
          refreshSessions()
        end)
      end
    end
    return
  end
  local sessionPath = if attempt.session ~= "" then attempt.session else nil
  endAttempt()
  if sessionPath ~= nil then
    sessionCall(sessionPath, "Disconnect", nil, function()
      refreshSessions()
    end)
  end
end

-- Runs once per refresh while an attempt is in progress.
local function checkAttempt()
  local cur = attempt
  if cur == nil or cur.session == "" then
    return
  end
  -- Watchdog for every phase except waiting on the user.
  if cur.phase ~= "input" and os.time() > cur.deadline then
    abortAttempt(noctalia.tr("error.timeout"), cur.session)
    return
  end
  if cur.phase == "starting" then
    return
  end
  local session = findSession(cur.session)
  if session == nil then
    abortAttempt(noctalia.tr("error.session-ended"), nil)
    return
  end
  if session.state == "connected" then
    endAttempt()
    patch({ message = "" })
    return
  end
  if cur.phase == "input" then
    return
  end
  if session.state == "failed" or session.state == "disconnected" then
    local text = session.message
    if text == "" then
      text = noctalia.tr("error.connection-failed")
    end
    abortAttempt(text, cur.session)
    return
  end

  -- Web login: the status message carries the URL to open.
  local url = string.match(session.message, "(https?://[^%s]+)")
  if url ~= nil then
    if cur.openedUrl ~= url then
      cur.openedUrl = url
      noctalia.runAsync({ "xdg-open", url })
    end
    cur.deadline = os.time() + (noctalia.getConfig("connect_timeout") or 45)
    patch({ pending = { kind = "url", profile = cur.profile, fields = {}, url = url, error = "" } })
    return
  end

  -- A challenge or credential request can arrive mid-connection.
  if cur.phase == "connecting" and session.state == "attention" and not cur.collecting then
    cur.collecting = true
    collectFields(cur.session, function(fields)
      cur.collecting = false
      if attempt == cur and #fields > 0 and status.pending == nil then
        requestInput(fields, nil)
      end
    end)
  end

  if status.pending ~= nil and status.pending.kind == "url" then
    patch({ pending = false })
  end
end

-- ---------------------------------------------------------------------------
-- Session list refresh
-- ---------------------------------------------------------------------------

refreshSessions = function()
  if refreshing then
    return
  end
  if not noctalia.commandExists("openvpn3") or not noctalia.commandExists("busctl") then
    patch({ state = "unavailable", available = false, message = noctalia.tr("error.cli-missing"), sessions = {} })
    return
  end
  refreshing = true
  refreshStartedMs = noctalia.nowMs()
  bus({ "call", SESS, SESS_ROOT, SESS, "FetchAvailableSessions" }, function(ok, decoded, result)
    if not ok then
      refreshing = false
      refreshErrored = true
      patch({ state = "error", available = true, message = errorText(result) })
      return
    end
    local paths = if type(decoded) == "table" and type(decoded.data) == "table" and type(decoded.data[1]) == "table" then decoded.data[1] else {}
    local sessions = {}
    local function nextPath(index)
      local path = paths[index]
      if path == nil then
        refreshing = false
        local now = nowSeconds()
        local seen = {}
        for _, session in ipairs(sessions) do
          seen[session.path] = true
          local previous = samples[session.path]
          session.rateIn, session.rateOut = -1, -1
          if previous ~= nil and now > previous.time and session.bytesIn >= previous.bytesIn and session.bytesOut >= previous.bytesOut and previous.bytesIn >= 0 then
            session.rateIn = (session.bytesIn - previous.bytesIn) / (now - previous.time)
            session.rateOut = (session.bytesOut - previous.bytesOut) / (now - previous.time)
          end
          samples[session.path] = { time = now, bytesIn = session.bytesIn, bytesOut = session.bytesOut }
        end
        for path in pairs(samples) do
          if not seen[path] then
            samples[path] = nil
          end
        end
        for path in pairs(logs) do
          if not seen[path] then
            logs[path] = nil
          end
        end
        local state = overallState(sessions)
        if attempt ~= nil and attempt.session == "" then
          state = "connecting"
        end
        notifyTransitions(sessions)
        patch({ sessions = sessions, available = true, state = state })
        if refreshErrored then
          refreshErrored = false
          patch({ message = "" })
        end
        sessionsLoaded = true
        checkAttempt()
        maybeAutoconnect()
        return
      end
      getAll(SESS, path, SESS, function(props)
        if props ~= nil then
          table.insert(sessions, parseSession(path, props))
        end
        nextPath(index + 1)
      end)
    end
    nextPath(1)
  end)
end

-- Once per service start: connect the profile chosen in the settings, unless a
-- session is already up.
maybeAutoconnect = function()
  if autoconnectDone or not sessionsLoaded or #status.profiles == 0 or attempt ~= nil then
    return
  end
  autoconnectDone = true
  for _, s in ipairs(status.sessions) do
    if s.state ~= "disconnected" then
      return
    end
  end
  for _, p in ipairs(status.profiles) do
    if p.autoconnect and p.valid then
      connect(p.name, p.path)
      return
    end
  end
end

local function refreshAll()
  refreshProfiles()
  refreshSessions()
end

-- ---------------------------------------------------------------------------
-- Management actions
-- ---------------------------------------------------------------------------

local function finishAction(failure, notice)
  working = math.max(0, working - 1)
  if failure ~= nil then
    fail(failure)
  else
    patch({ message = "", notice = notice })
    if notice ~= nil and notice.kind == "saved" then
      noctalia.notify(noctalia.tr("title"), noctalia.tr("panel.saved"))
    end
  end
  setBusy()
  refreshAll()
end

local function runManaged(argv, notice, timeoutMs)
  working += 1
  workingSinceMs = noctalia.nowMs()
  patch({ busy = true })
  local accepted = noctalia.runAsync(argv, function(result)
    finishAction(if result.exitCode ~= 0 then errorText(result) else nil, notice)
  end, timeoutMs or 20000)
  if not accepted then
    finishAction(noctalia.tr("error.command-failed"), nil)
  end
end

local function importProfile(file, url, name)
  name = trim(name or "")
  url = trim(url or "")
  if string.sub(name, 1, 1) == "-" or string.sub(trim(file or ""), 1, 1) == "-" then
    fail(noctalia.tr("error.bad-value"))
    return
  end
  if url ~= "" then
    if not string.match(url, "^https?://") then
      fail(noctalia.tr("error.bad-url"))
      return
    end
    if name == "" then
      name = string.gsub(string.gsub(string.gsub(url, "[?#].*$", ""), "^.*/", ""), "%.[%w]+$", "")
      if name == "" then
        name = "profile"
      end
    end
    -- Download to a temp file, import, always clean up. Arguments are passed as
    -- positional parameters so nothing is interpolated into the script.
    local script = 'tmp=$(mktemp --suffix=.ovpn) || exit 1; '
      .. 'curl -fsSL --max-time 30 -o "$tmp" -- "$1" && openvpn3 config-import --config "$tmp" --name "$2" --persistent; '
      .. 'rc=$?; rm -f "$tmp"; exit $rc'
    runManaged({ "sh", "-c", script, "sh", url, name }, { kind = "imported", name = name, nonce = nonce() }, 60000)
    return
  end
  file = expandHome(trim(file or ""))
  if file == "" then
    fail(noctalia.tr("error.no-file"))
    return
  end
  if name == "" then
    name = string.gsub(string.gsub(file, "^.*/", ""), "%.[%w]+$", "")
  end
  runManaged(
    { "openvpn3", "config-import", "--config", file, "--name", name, "--persistent" },
    { kind = "imported", name = name, nonce = nonce() }
  )
end

local function removeProfile(path)
  for _, s in ipairs(status.sessions) do
    if s.configPath == path then
      disconnectPaths({ s.path }, 1, function() end)
    end
  end
  runManaged({ "openvpn3", "config-remove", "--path", path, "--force" }, { kind = "removed", nonce = nonce() })
end

-- Per-profile options. Everything except dco and the rename is an openvpn3
-- "override" stored on the profile; an empty value removes the override.
local OPTION_KINDS = {
  ["server-override"] = "s", ["port-override"] = "s", ["ipv6"] = "s",
  ["allow-compression"] = "s", ["automatic-restart"] = "s", ["tls-version-min"] = "s",
  ["tls-cert-profile"] = "s", ["dns-scope"] = "s", ["log-level"] = "s", ["proxy-host"] = "s",
  ["proxy-port"] = "s", ["proxy-username"] = "s", ["proxy-password"] = "s",
  ["auth-fail-retry"] = "b", ["persist-tun"] = "b", ["enable-legacy-algorithms"] = "b",
  ["dns-fallback-google"] = "b", ["dns-setup-disabled"] = "b", ["dns-sync-lookup"] = "b",
  ["proxy-auth-cleartext"] = "b", ["dco"] = "b", ["autoconnect"] = "b",
}

local function setOptions(path, options, rename)
  local argv = { "openvpn3", "config-manage", "--path", path }
  local keys = {}
  for key in pairs(options or {}) do
    if OPTION_KINDS[key] ~= nil then
      table.insert(keys, key)
    end
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local value = options[key]
    if key == "autoconnect" then
      local on = value == true or value == "true"
      table.insert(argv, if on then "--tag" else "--remove-tag")
      table.insert(argv, AUTOCONNECT_TAG)
      if on then
        -- Only one profile connects at startup: clear the tag everywhere else.
        for _, other in ipairs(status.profiles) do
          if other.autoconnect and other.path ~= path then
            noctalia.runAsync({ "openvpn3", "config-manage", "--path", other.path, "--remove-tag", AUTOCONNECT_TAG })
          end
        end
      end
    elseif OPTION_KINDS[key] == "b" then
      table.insert(argv, `--{key}`)
      table.insert(argv, if value == true or value == "true" then "true" else "false")
    elseif value == nil or value == "" or value == false then
      if key ~= "proxy-password" then
        table.insert(argv, "--unset-override")
        table.insert(argv, key)
      end
    else
      value = tostring(value)
      if string.sub(value, 1, 1) == "-" then
        fail(noctalia.tr("error.bad-value"))
        return
      end
      table.insert(argv, `--{key}`)
      table.insert(argv, value)
    end
  end
  rename = trim(rename or "")
  if string.sub(rename, 1, 1) == "-" then
    fail(noctalia.tr("error.bad-value"))
    return
  end
  if rename ~= "" then
    table.insert(argv, "--rename")
    table.insert(argv, rename)
  end
  if #argv == 4 then
    return
  end
  runManaged(argv, { kind = "saved", nonce = nonce() })
end

-- Lists a directory for the in-panel file browser: sub-folders and profile files.
local function listDir(dir)
  local home = noctalia.getenv("HOME") or "/"
  dir = expandHome(trim(dir or ""))
  if dir == "" then
    dir = home .. "/Downloads"
  end
  -- find would treat a leading "-" as an expression (e.g. -delete); only absolute paths are listed.
  if string.sub(dir, 1, 1) ~= "/" then
    dir = home
  end
  if string.sub(dir, -1) == "/" and #dir > 1 then
    dir = string.sub(dir, 1, -2)
  end
  noctalia.runAsync({
    "find", dir, "-maxdepth", "1", "-mindepth", "1",
    "(", "-type", "d", "-o", "-type", "f", "-name", "*.ovpn", "-o", "-type", "f", "-name", "*.conf", ")",
    "-printf", "%y\t%f\n",
  }, function(result)
    if result.exitCode ~= 0 and (result.stdout or "") == "" then
      -- Unreadable or missing: fall back to the home directory once.
      if dir ~= home then
        listDir(home)
      end
      return
    end
    local entries = {}
    for line in string.gmatch(result.stdout or "", "[^\n]+") do
      local kind, name = string.match(line, "^(%a)\t(.+)$")
      if kind ~= nil and string.sub(name, 1, 1) ~= "." then
        table.insert(entries, { name = name, isDir = kind == "d" })
      end
    end
    table.sort(entries, function(a, b)
      if a.isDir ~= b.isDir then
        return a.isDir
      end
      return string.lower(a.name) < string.lower(b.name)
    end)
    while #entries > 200 do
      table.remove(entries)
    end
    local parent = string.match(dir, "^(.*)/[^/]+$")
    if parent == nil or parent == "" then
      parent = "/"
    end
    noctalia.state.set("openvpn3.dir", {
      dir = dir, parent = if dir == "/" then "" else parent, entries = entries, nonce = nonce(),
    })
  end, 8000)
end

local function manageSession(path, method, extra)
  if path == nil or path == "" or working > 0 then
    return
  end
  working += 1
  workingSinceMs = noctalia.nowMs()
  patch({ busy = true })
  sessionCall(path, method, extra, function(ok, _decoded, result)
    finishAction(if ok then nil else errorText(result), nil)
  end)
end

local function disconnect(path)
  if working > 0 then
    return
  end
  local paths = {}
  if path ~= nil and path ~= "" then
    table.insert(paths, path)
  else
    for _, s in ipairs(status.sessions) do
      table.insert(paths, s.path)
    end
  end
  if #paths == 0 then
    return
  end
  working += 1
  workingSinceMs = noctalia.nowMs()
  patch({ busy = true, message = "" })
  disconnectPaths(paths, 1, function()
    finishAction(nil, nil)
  end)
end

local function toggle()
  for _, s in ipairs(status.sessions) do
    if s.state ~= "disconnected" then
      disconnect(nil)
      return
    end
  end
  connect(nil)
end

local function handle(command)
  local action = if type(command) == "table" then command.action else command
  if type(command) ~= "table" then
    command = {}
  end
  if action == "toggle" then
    toggle()
  elseif action == "refresh" then
    refreshAll()
  elseif action == "connect" then
    connect(command.profile, command.path)
  elseif action == "disconnect" then
    disconnect(command.path)
  elseif action == "restart" then
    manageSession(command.path, "Restart", nil)
  elseif action == "pause" then
    manageSession(command.path, "Pause", { "s", "noctalia" })
  elseif action == "resume" then
    manageSession(command.path, "Resume", nil)
  elseif action == "submit-auth" then
    submitInput(command.values)
  elseif action == "cancel-auth" then
    cancelAttempt()
  elseif action == "import" then
    importProfile(command.file, command.url, command.name)
  elseif action == "remove" then
    removeProfile(command.path)
  elseif action == "set-options" then
    setOptions(command.path, command.options, command.rename)
  elseif action == "list-dir" then
    listDir(command.dir)
  elseif action == "log" then
    if type(command.path) == "string" then
      startLog(command.path)
      publishLog(command.path)
    end
  end
end

noctalia.setUpdateInterval((noctalia.getConfig("poll_seconds") or 5) * 1000)
noctalia.state.watch("openvpn3.command", handle)

function update()
  local now = noctalia.nowMs()
  -- A callback that never fires (killed process, interrupted shell) would leave
  -- these flags set forever and the panel looking dead.
  if refreshing and now - refreshStartedMs > 20000 then
    refreshing = false
  end
  if working > 0 and now - workingSinceMs > 30000 then
    working = 0
    setBusy()
  end
  for path, entry in pairs(logs) do
    if entry.dirty then
      publishLog(path)
    end
  end
  refreshSessions()
end

-- `noctalia msg plugin vinioli/openvpn3:service all <action> [payload]`
-- The payload is either a profile name (connect) or a JSON object with the
-- command fields, which makes every action scriptable for testing.
function onIpc(event, payload)
  local command = { action = event }
  if type(payload) == "string" and string.sub(payload, 1, 1) == "{" then
    local decoded = noctalia.json.decode(payload)
    if type(decoded) == "table" then
      command = decoded
      command.action = event
    end
  elseif event == "connect" then
    command.profile = payload
  end
  handle(command)
end

refreshAll()
