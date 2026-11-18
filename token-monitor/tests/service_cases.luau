local Service = require("../lib/service.luau")
local total = 0
local function test(name, fn) fn(); total += 1; print("PASS " .. name) end
local function fixture()
  return { limits = { providers = {{ provider = "codex", accountKey = "account-a", status = "ok", windows = {{ remainingPercent = 0 }} }} },
    periods = {today = {totalTokens = 10, costUsd = 0, models = {A = 10}, sessions = {}}} }
end
local function rig(deferred)
  local r = { reads = {}, requests = {}, writes = {}, jobs = {}, diagnostics = {}, clock = 1000, writeOk = true,
    variables = {}, files = {}, names = {},
    documents = { stats = fixture(), history = {daily = {}, monthly = {}, summary = {totalTokens = 10}} } }
  local function clone(value)
    if type(value) ~= "table" then return value end
    local copy = {}; for key, item in pairs(value) do copy[key] = clone(item) end; return copy
  end
  r.engine = Service.new({
    now = function() return r.clock end, decode = function(value)
      if r.decodeError then error(r.decodeError) end
      return r.documents[value]
    end,
    encode = function(value)
      if r.encodeError then error(r.encodeError) end
      r.encoded = clone(value); return "encoded"
    end,
    reportProcessingError = function(kind, phase, category)
      r.diagnostics[#r.diagnostics + 1] = {kind = kind, phase = phase, category = category}
    end,
    read = function(path, callback) table.insert(r.reads, {path = path, callback = callback}); return true end,
    write = function(path, contents) table.insert(r.writes, {path, contents, record = clone(r.encoded)}); return r.writeOk end,
    http = function(request, callback) table.insert(r.requests, {request = request, callback = callback}); return not r.reject end,
    cachePath = function() return "/private-cache/snapshot.json" end,
    getenv = function(name) return r.variables[name] end,
    listDir = function(_path) return r.names end,
    exists = function(path) return r.files[path] ~= nil end,
    defer = deferred and function(callback) table.insert(r.jobs, callback) end or nil,
    publish = function(state) r.state = clone(state) end,
  })
  function r.configure(url, path, auto) r.engine.configure({url = url or "http://localhost:17321", credentialFile = path or "", autoDiscover = auto == true}) end
  function r.cache(contents) r.reads[1].callback(contents) end
  function r.reply(kind, status, body, ok)
    for index = #r.requests, 1, -1 do
      local request = r.requests[index]
      if request.request.url:match("/api/" .. kind .. "$") then
        request.callback({status = status, body = body or kind, ok = ok ~= false}); return
      end
    end
    error("missing request " .. kind)
  end
  function r.drain()
    local count = 0
    while #r.jobs > 0 do
      count += 1; assert(count < 5000)
      table.remove(r.jobs, 1)()
    end
    return count
  end
  return r
end

test("two bounded independent reads and safe schema2 recovery", function()
  local r = rig(); r.configure(); r.cache(nil)
  assert(#r.requests == 2 and not r.engine.refresh())
  r.reply("stats", 200)
  assert(r.state.status == "ready" and r.state.providers[1].windows[1].value == 0)
  assert(r.state.analytics.periods.today.totals.tokens == 10)
  assert(r.encoded.schema == 2 and r.encoded.scope == "http://localhost:17321\n")
  assert(r.encoded.data.limits.providers[1].accountKey == nil)
  r.reply("history", 200)
  assert(r.state.history.status == "ready" and r.encoded.history.summary.totalTokens == 10)
  r.engine.refresh(); r.reply("stats", 503); r.reply("history", 503)
  assert(r.state.error == "http" and r.state.cached and #r.state.providers == 1)
  assert(r.state.history.cached and r.state.history.summary.totalTokens == 10)
  r.clock = 1100; r.engine.refresh(); r.reply("stats", 200); r.reply("history", 200)
  assert(r.state.status == "ready" and not r.state.cached and r.state.lastSuccess == 1100)
end)

test("history failure does not erase quota/analytics or block the next stats read", function()
  local r = rig(); r.configure(); r.cache(nil); r.reply("stats", 200)
  assert(r.engine.refresh() and #r.requests == 3)
  r.reply("history", 500)
  assert(r.state.status == "loading" and r.state.history.error == "http")
  r.reply("stats", 200)
  assert(r.state.status == "ready" and #r.state.providers == 1 and r.state.analytics.status == "ready")
end)

test("credential read is shared and failures never send a request", function()
  local r = rig(); r.configure(nil, "/key"); r.cache(nil)
  assert(r.reads[2].path == "/key" and #r.requests == 0)
  r.reads[2].callback("test-secret")
  assert(#r.requests == 2 and r.requests[1].request.headers[2] == "Authorization: Bearer test-secret")
  assert(r.requests[2].request.follow_redirects == false)
  r.reply("stats", 401); r.reply("history", 401)
  assert(r.state.error == "unauthorized" and r.state.secret == nil)
  r.engine.refresh(); r.reads[3].callback(nil)
  assert(r.state.error == "credentials_unreadable" and #r.requests == 2)
end)

test("source change discards old HTTP, history and queued normalization", function()
  local r = rig(true); r.configure(); r.cache(nil); r.drain()
  local oldStats, oldHistory = r.requests[1].callback, r.requests[2].callback
  oldStats({ok = true, status = 200, body = "stats"})
  r.configure("http://second:17321"); r.reads[2].callback(nil)
  oldHistory({ok = true, status = 200, body = "history"})
  r.drain()
  assert(#r.state.providers == 0 and r.state.lastSuccess == 0 and r.state.history.lastSuccess == 0)
  r.reply("stats", 200); r.reply("history", 200)
  assert(r.state.status == "loading")
  assert(r.drain() > 5 and r.state.status == "ready" and r.state.history.status == "ready")
end)

test("late cache cannot overwrite a manually refreshed snapshot", function()
  local r = rig(); r.configure(); local late = r.reads[1].callback
  r.engine.refresh(); r.reply("stats", 200)
  r.documents.old = {schema = 1, scope = "http://localhost:17321\n", lastSuccess = 1, data = fixture()}
  late("old")
  assert(r.state.lastSuccess == 1000 and not r.state.cached and #r.requests == 2)
end)

test("legacy quota cache stays scoped and valid while offline", function()
  local r = rig(); r.configure()
  r.documents.old = {schema = 1, scope = "http://localhost:17321\n", lastSuccess = 900, data = fixture()}
  r.cache("old"); r.reply("stats", 0, "", false)
  assert(r.state.cached and r.state.lastSuccess == 900 and r.state.error == "network")
  local other = rig(); other.configure("http://other:17321"); other.documents.old = r.documents.old; other.cache("old")
  assert(#other.state.providers == 0)
end)

test("schema2 caches restore bounded analytics/history without unknown fields", function()
  local first = rig(); first.configure(); first.cache(nil); first.reply("stats", 200); first.reply("history", 200)
  local second = rig(); second.configure(); second.documents.old = first.encoded
  second.documents.old.analytics.periods.today.prompt = "private"
  second.cache("old")
  assert(second.state.cached and second.state.analytics.periods.today.totals.tokens == 10)
  assert(second.state.analytics.periods.today.prompt == nil and second.state.history.cached)
  assert(second.state.providers[1].key == first.state.providers[1].key)
end)

test("malformed and oversized responses, queue rejection and failed writes are visible", function()
  local r = rig(); r.configure(); r.cache(nil); r.reply("stats", 200, "invalid"); r.reply("history", 200, "invalid")
  assert(r.state.error == "invalid_response" and r.state.history.error == "invalid_response")
  r.reject = true; r.engine.refresh(); assert(r.state.error == "request_rejected")
  r.reject = false; r.writeOk = false; r.engine.refresh(); r.reply("stats", 200)
  assert(r.state.status == "ready" and r.state.cacheWarning)
  r.reply("history", 200, string.rep("x", 4 * 1024 * 1024 + 1))
  assert(r.state.history.error == "too_large" and r.state.status == "ready")
end)
test("a delayed old cache projection cannot replace a newer history snapshot", function()
  local r = rig(true); r.configure(); r.cache(nil); r.drain()
  r.reply("stats", 200)
  -- Stop after encoding stats, while its write is still queued.
  while not r.encoded do table.remove(r.jobs, 1)() end
  local oldWrite = table.remove(r.jobs, 1)
  r.reply("history", 200)
  r.drain()
  assert(r.writes[#r.writes].record.history.summary.totalTokens == 10)
  local writes = #r.writes
  oldWrite()
  assert(#r.writes == writes and r.writes[#r.writes].record.history.summary.totalTokens == 10)
end)

test("cache writes require an explicit true result", function()
  local r = rig(); r.configure(); r.cache(nil); r.writeOk = nil; r.reply("stats", 200)
  assert(r.state.status == "ready" and r.state.cacheWarning)
end)

test("history cache recovery is independent of any successful quota snapshot", function()
  local first = rig(); first.configure(); first.cache(nil); first.reply("stats", 503); first.reply("history", 200)
  assert(first.encoded.lastSuccess == 0 and first.encoded.historyLastSuccess == 1000)
  local second = rig(); second.configure(); second.documents.old = first.encoded; second.cache("old")
  assert(second.state.history.cached and second.state.history.summary.totalTokens == 10)
  assert(second.state.lastSuccess == 0 and #second.state.providers == 0)
end)

test("connection test waits for both fresh supported responses and treats empty data as reachable", function()
  local r = rig(); r.documents.stats = {limits = {providers = {}}}; r.documents.history = {daily = {}, monthly = {}, summary = {}}
  r.configure(); r.cache(nil)
  assert(r.state.connection.status == "checking" and r.state.connection.checkedAt == 0)
  r.reply("stats", 200)
  assert(r.state.status == "ready" and #r.state.providers == 0 and r.state.connection.status == "checking")
  assert(r.state.connection.stats == "ok" and r.state.connection.history == "checking")
  r.clock = 1001; r.reply("history", 200)
  assert(r.state.connection.status == "ready" and r.state.connection.checkedAt == 1001)
  assert(r.encoded.connection == nil)
end)

test("connection retry retains displayed cache without counting it as success", function()
  local r = rig(); r.configure(); r.documents.old = {schema = 1, scope = "http://localhost:17321\n", lastSuccess = 900, data = fixture()}
  r.cache("old"); r.reply("stats", 401); r.reply("history", 503)
  assert(r.state.cached and r.state.connection.status == "error" and r.state.connection.stats == "unauthorized")
  assert(r.engine.testConnection() and #r.requests == 4)
  assert(#r.state.providers == 1 and r.state.connection.status == "checking")
  assert(r.state.connection.stats == "checking" and r.state.connection.history == "checking")
  r.clock = 1100; r.reply("stats", 200)
  assert(r.state.connection.status == "checking" and r.state.connection.checkedAt == 1000)
  r.reply("history", 500)
  assert(r.state.connection.status == "partial" and r.state.connection.stats == "ok" and r.state.connection.history == "http")
  assert(r.state.connection.checkedAt == 1100)
  r.engine.testConnection(); r.reply("stats", 503); r.reply("history", 200)
  assert(r.state.connection.status == "partial" and r.state.connection.history == "ok")
end)

test("connection test supersedes in-flight requests, credential reads and late cache", function()
  local r = rig(true); r.configure(); local oldCache = r.reads[1].callback
  r.engine.testConnection(); local oldStats = r.requests[1].callback
  oldStats({ok = true, status = 200, body = "stats"})
  r.engine.testConnection(); oldCache("stats")
  r.requests[2].callback({ok = true, status = 200, body = "history"})
  r.drain()
  assert(r.state.lastSuccess == 0 and r.state.history.lastSuccess == 0 and r.state.connection.status == "checking")
  r.reply("stats", 401); r.reply("history", 401); r.drain()
  assert(r.state.connection.status == "error" and r.state.connection.stats == "unauthorized")
  local m = rig(); m.configure(nil, "/key"); m.cache(nil); local oldRead = m.reads[2].callback
  m.engine.testConnection(); oldRead("old-secret")
  assert(#m.requests == 0)
  m.reads[3].callback("new-secret")
  assert(#m.requests == 2 and m.requests[1].request.headers[2] == "Authorization: Bearer new-secret")
end)

test("automatic discovery retries newly created credentials and rotates every refresh", function()
  local r = rig(); r.variables.HOME = "/home/test"; local path = "/home/test/.config/Token Monitor/credentials.json"
  r.configure(nil, nil, true); r.cache(nil)
  assert(#r.requests == 2 and r.state.connection.discovery == "not_found" and #r.requests[1].request.headers == 1)
  r.reply("stats", 401); r.reply("history", 401)
  r.files[path] = true; r.documents.first = {credentials = {hub = {hostSecret = "first"}}}
  r.engine.testConnection(); assert(r.reads[2].path == path and #r.requests == 2)
  r.reads[2].callback("first"); assert(#r.requests == 4 and r.requests[3].request.headers[2] == "Authorization: Bearer first")
  assert(r.state.connection.credentialSource == "automatic" and r.state.connection.credentialPath == path)
  r.reply("stats", 200); r.reply("history", 200)
  r.documents.second = {credentials = {hub = {hostSecret = "second"}}}
  r.engine.refresh(); assert(r.reads[3].path == path); r.reads[3].callback("second")
  assert(r.requests[5].request.headers[2] == "Authorization: Bearer second")
  assert(r.encoded.scope == "http://localhost:17321\n\nautomatic" and r.encoded.credentials == nil)
  r.configure("http://remote:17321", nil, true); r.reads[4].callback(nil)
  assert(r.state.connection.discovery == "remote" and #r.requests[7].request.headers == 1 and #r.reads == 4)
end)

test("diagnostics keep queue rejection schema failures and network errors distinct", function()
  local r = rig(); r.configure(); r.cache(nil); r.reply("stats", 200, "invalid"); r.reply("history", 0, nil, false)
  assert(r.state.connection.status == "error" and r.state.connection.stats == "invalid_response" and r.state.connection.history == "network")
  r.reject = true; r.engine.testConnection()
  assert(r.state.connection.status == "error" and r.state.connection.stats == "request_rejected" and r.state.connection.history == "request_rejected")
  r.configure("http://bad/path"); r.reads[2].callback(nil)
  assert(r.state.connection.url == "" and r.state.connection.status == "error" and r.state.connection.stats == "invalid_url")
end)

test("processing diagnostics distinguish caught budget/runtime errors from malformed JSON", function()
  for _, item in ipairs({{"script callback 'update' exceeded its CPU budget", "budget"}, {"unexpected decode exception", "runtime"}}) do
    local r = rig(); r.configure(); r.cache(nil); r.decodeError = item[1]
    r.reply("stats", 200)
    assert(r.state.connection.stats == "processing_error" and r.state.error == "processing_error")
    assert(#r.diagnostics == 1 and r.diagnostics[1].kind == "stats" and r.diagnostics[1].phase == "decode")
    assert(r.diagnostics[1].category == item[2])
  end
  local malformed = rig(); malformed.configure(); malformed.cache(nil); malformed.reply("stats", 200, "invalid")
  assert(malformed.state.connection.stats == "invalid_response" and #malformed.diagnostics == 0)
end)

test("cache encoding exceptions warn without revoking validated endpoint success or blocking retry", function()
  local r = rig(); r.configure(); r.cache(nil); r.encodeError = "script callback 'update' exceeded its CPU budget"
  r.reply("stats", 200); r.reply("history", 200)
  assert(r.state.connection.status == "ready" and r.state.status == "ready" and r.state.history.status == "ready")
  assert(r.state.cacheWarning and #r.writes == 0 and #r.diagnostics == 2)
  assert(r.diagnostics[1].phase == "cache_encode" and r.diagnostics[1].category == "budget")
  r.encodeError = nil; assert(r.engine.refresh()); r.reply("stats", 200); r.reply("history", 200)
  assert(r.state.connection.status == "ready" and not r.state.cacheWarning and #r.writes > 0)
end)

test("large JSON partitioning yields through the protected decoder and keeps generation safety", function()
  local r = rig(true); r.configure(); r.cache(nil); r.drain()
  -- The native decoder is a fixture lookup here; whitespace forces the large-body
  -- branch while the small JSON leaf maps to an ordinary supported stats envelope.
  r.documents["{}"] = fixture()
  local body = string.rep(" ", 40000) .. "{}"
  r.reply("stats", 200, body)
  assert(r.drain() >= 3 and r.state.status == "ready" and r.state.connection.stats == "ok")
  r.engine.testConnection(); r.reply("stats", 200, body)
  table.remove(r.jobs, 1)()
  r.engine.testConnection(); r.drain()
  assert(r.state.connection.stats == "checking" and r.state.connection.status == "checking")
end)

print(tostring(total) .. " service cases passed")
