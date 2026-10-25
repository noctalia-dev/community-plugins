local Model = require("./model.luau")
local Analytics = require("./analytics.luau")
local Credentials = require("./credentials.luau")
local Json = require("./json_decode.luau")
local Service = {}
local RESPONSE_LIMIT, CACHE_LIMIT = 4 * 1024 * 1024, 2 * 1024 * 1024

function Service.new(env)
  local function initial()
    return { status = "loading", error = "", providers = {}, lastSuccess = 0, cached = false, cacheWarning = false,
      connection = { status = "checking", url = "", credentialSource = "none", credentialPath = "",
        discovery = "disabled", stats = "waiting", history = "waiting", checkedAt = 0 },
      analytics = { status = "loading", error = "", periods = {} },
      history = { status = "loading", error = "", daily = {}, monthly = {}, summary = {}, lastSuccess = 0, cached = false } }
  end
  local state = initial()
  local generation, requestId, revision = 0, 0, 0
  local busy, tickets = { stats = false, history = false }, { stats = 0, history = 0 }
  local config, scope, cachePath
  local engine = {}
  local function publish() env.publish(state) end
  local function category(error)
    return type(error) == "string" and error:find("exceeded its CPU budget", 1, true) and "budget" or "runtime"
  end
  local function report(kind, phase, failure)
    if env.reportProcessingError then pcall(env.reportProcessingError, kind, phase, failure) end
  end
  local function decode(contents)
    local ok, result, error = pcall(Json.decode, contents, env.decode, function() coroutine.yield() end)
    if not ok then return nil, "processing_error", category(result) end
    if error then return nil, error end
    return type(result) == "table" and result or nil
  end
  local function settled(kind, result)
    local connection = state.connection
    connection[kind] = result
    if connection.stats == "checking" or connection.history == "checking"
        or connection.stats == "waiting" or connection.history == "waiting" then
      connection.status = "checking"
    else
      local count = (connection.stats == "ok" and 1 or 0) + (connection.history == "ok" and 1 or 0)
      connection.status = count == 2 and "ready" or (count == 1 and "partial" or "error")
      connection.checkedAt = env.now()
    end
  end
  local function fail(kind, code)
    settled(kind, code)
    busy[kind] = false
    if kind == "stats" then
      state.status, state.error, state.cached = "error", code, state.lastSuccess > 0
      state.analytics.status, state.analytics.error = "error", code
    else
      state.history.status, state.history.error = "error", code
      state.history.cached = state.history.lastSuccess > 0
    end
    publish()
  end
  -- Native adapters schedule one resume per frame. Pure tests may run synchronously.
  local function work(current, fn, onError)
    local thread = coroutine.create(fn)
    local function resume()
      if not current() then return end
      local ok, error = coroutine.resume(thread)
      if not ok then onError(category(error)); return end
      if coroutine.status(thread) ~= "dead" then
        if env.defer then env.defer(resume) else
          while current() and coroutine.status(thread) ~= "dead" do
            local resumed, error = coroutine.resume(thread)
            if not resumed then onError(category(error)); return end
          end
        end
      end
    end
    if env.defer then env.defer(resume) else resume() end
  end
  local function step() coroutine.yield() end
  local function persist(kind)
    if not cachePath then state.cacheWarning = true; return end
    local snapshotRevision = revision
    local snapshot = { schema = 2, scope = scope, lastSuccess = state.lastSuccess,
      data = Model.cachePayload(state.providers, step), analytics = Analytics.cacheUsage(state.analytics, step) }
    if state.history.lastSuccess > 0 then
      snapshot.history = Analytics.cacheHistory(state.history, step)
      snapshot.historyLastSuccess = state.history.lastSuccess
    end
    step()
    if snapshotRevision ~= revision then return end
    local ok, encoded = pcall(env.encode, snapshot)
    if not ok or type(encoded) ~= "string" then
      state.cacheWarning = true
      report(kind, "cache_encode", not ok and category(encoded) or "runtime")
      return
    end
    if #encoded > CACHE_LIMIT then
      -- Quota recovery remains available if history/detail exceeds the bounded cache budget.
      snapshot.analytics, snapshot.history, snapshot.historyLastSuccess = nil, nil, nil
      ok, encoded = pcall(env.encode, snapshot)
      if not ok or type(encoded) ~= "string" then report(kind, "cache_encode", not ok and category(encoded) or "runtime") end
      state.cacheWarning = true
    end
    step()
    if snapshotRevision ~= revision then return end
    local writeOk, written = false, false
    if ok and type(encoded) == "string" and #encoded <= CACHE_LIMIT then writeOk, written = pcall(env.write, cachePath, encoded) end
    if not writeOk or written ~= true then
      state.cacheWarning = true
      if not writeOk then report(kind, "cache_write", category(written)) end
    end
  end

  function engine.refresh()
    if busy.stats and busy.history then return false end
    if not config or not config.url then fail("stats", "invalid_url"); fail("history", "invalid_url"); return false end
    requestId += 1
    local epoch, targets = generation, {}
    for _, kind in ipairs({ "stats", "history" }) do
      if not busy[kind] then
        busy[kind] = true
        tickets[kind] += 1
        targets[kind] = tickets[kind]
        state.connection[kind] = "checking"
        if kind == "stats" then
          state.status, state.error = "loading", ""
          state.analytics.status, state.analytics.error = "loading", ""
        else state.history.status, state.history.error = "loading", "" end
      end
    end
    state.connection.status = "checking"
    state.connection.discovery = config.credentialFile ~= "" and "manual"
      or (config.autoDiscover and (Credentials.loopback(config.url) and "searching" or "remote") or "disabled")
    publish()
    local function current(kind) return epoch == generation and targets[kind] == tickets[kind] end
    local function failedTargets(code)
      for kind in pairs(targets) do if current(kind) then fail(kind, code) end end
    end
    local function fetch(secret)
      if epoch ~= generation then return end
      for _, kind in ipairs({ "stats", "history" }) do
        if targets[kind] and current(kind) then
          local headers = { "Accept: application/json" }
          if secret then headers[#headers + 1] = "Authorization: Bearer " .. secret end
          local accepted = env.http({ url = config.url .. "/api/" .. kind, method = "GET",
            headers = headers, follow_redirects = false }, function(response)
            if not current(kind) then return end
            local code
            if type(response) ~= "table" then code = "invalid_response"
            elseif not response.ok then code = "network"
            elseif response.status == 401 or response.status == 403 then code = "unauthorized"
            elseif response.status ~= 200 then code = "http"
            elseif type(response.body) ~= "string" then code = "invalid_response"
            elseif #response.body > RESPONSE_LIMIT then code = "too_large" end
            if code then fail(kind, code); return end
            local phase = "decode"
            work(function() return current(kind) end, function()
              local data, decodeFailure, decodeCategory = decode(response.body)
              if decodeFailure then
                if decodeFailure == "processing_error" then report(kind, phase, decodeCategory) end
                fail(kind, decodeFailure); return
              end
              step()
              if kind == "stats" then
                phase = "normalize_stats"
                local providers, error = Model.normalize(data, false, step)
                if not providers then fail(kind, error); return end
                phase = "normalize_usage"
                local analytics = Analytics.normalize(data, step)
                step()
                state.providers, state.analytics, state.lastSuccess = providers, analytics, env.now()
                state.status, state.error, state.cached, state.cacheWarning = "ready", "", false, false
              else
                phase = "normalize_history"
                local history, error = Analytics.history(data, step)
                if not history then fail(kind, error); return end
                history.lastSuccess, history.cached = env.now(), false
                state.history = history
              end
              settled(kind, "ok")
              revision += 1
              step()
              phase = "publish"
              publish()
              step()
              phase = "cache"
              persist(kind)
              busy[kind] = false
              step()
              phase = "publish"
              publish()
            end, function(failure)
              report(kind, phase, failure)
              if phase == "cache" then
                state.cacheWarning, busy[kind] = true, false
                -- The fresh endpoint already validated successfully. Cache failures
                -- are local persistence problems, not invalid server responses.
                publish()
              else fail(kind, "processing_error") end
            end)
          end)
          if not accepted and current(kind) then fail(kind, "request_rejected") end
        end
      end
    end
    Credentials.resolve(env, config, function() return epoch == generation end, function(secret, info, error)
      if epoch ~= generation then return end
      for key, value in pairs(info) do state.connection[key] = value end
      publish()
      if error then failedTargets(error) else fetch(secret) end
    end)
    return true
  end

  function engine.testConnection()
    generation += 1
    revision += 1
    busy, tickets = { stats = false, history = false }, { stats = 0, history = 0 }
    state.connection.stats, state.connection.history = "waiting", "waiting"
    state.connection.credentialSource = config and config.credentialFile ~= "" and "manual" or "none"
    state.connection.credentialPath = ""
    return engine.refresh()
  end

  function engine.configure(options)
    local url = Model.origin(options.url)
    local path = type(options.credentialFile) == "string" and options.credentialFile or ""
    local autoDiscover = options.autoDiscover ~= false
    local nextScope = Credentials.scope(url, path, autoDiscover)
    if config and nextScope == scope then return end
    config, scope = { url = url, credentialFile = path, autoDiscover = autoDiscover }, nextScope
    generation += 1
    revision = 0
    busy, tickets = { stats = false, history = false }, { stats = 0, history = 0 }
    state = initial()
    state.connection.url = url or ""
    state.connection.credentialSource = path ~= "" and "manual" or "none"
    state.connection.credentialPath = path ~= "" and Credentials.path(env, path) or ""
    state.connection.discovery = path ~= "" and "manual" or (autoDiscover and (Credentials.loopback(url) and "searching" or "remote") or "disabled")
    publish()
    cachePath = env.cachePath()
    local epoch, cacheRequestId = generation, requestId
    local function current() return epoch == generation and cacheRequestId == requestId end
    local function resume(contents)
      if not current() then return end
      work(current, function()
        local cache = type(contents) == "string" and #contents <= CACHE_LIMIT and decode(contents) or nil
        step()
        if cache and (cache.schema == 1 or cache.schema == 2) and cache.scope == scope then
          local restored = false
          if type(cache.lastSuccess) == "number" and cache.lastSuccess > 0 and cache.lastSuccess <= env.now() then
            local providers = Model.normalize(cache.data, true, step)
            if providers then
              state.providers, state.lastSuccess, state.cached = providers, cache.lastSuccess, true
              restored = true
              if cache.schema == 2 then state.analytics = Analytics.restoreUsage(cache.analytics, step) end
            end
          end
          if cache.schema == 2 and type(cache.historyLastSuccess) == "number"
              and cache.historyLastSuccess > 0 and cache.historyLastSuccess <= env.now() then
            local history = Analytics.restoreHistory(cache.history, step)
            if history then
              history.lastSuccess, history.cached = cache.historyLastSuccess, true
              state.history, restored = history, true
            end
          end
          if restored then step(); publish() end
        end
        engine.refresh()
      end, function() engine.refresh() end)
    end
    if cachePath then
      if not env.read(cachePath, resume) then resume(nil) end
    else resume(nil) end
  end
  return engine
end
return Service
