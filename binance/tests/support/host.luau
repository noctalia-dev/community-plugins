--!nonstrict
-- A fake Noctalia host for the service spec: in-memory files, recorded HTTP
-- requests and processes answered by the test, a state store with watchers,
-- and a settable clock.

local json = require("./json")

local M = {}

M.T0 = 1792411200000 -- 2026-10-19 12:00 UTC, a Monday

function M.new()
  local host = {
    clock = M.T0,
    files = {} :: { [string]: string },
    requests = {} :: { any },
    processes = {} :: { any },
    state = {} :: { [string]: any },
    watchers = {} :: { [string]: { (any) -> () } },
    config = { display_currency = "USDT", day_boundary = "utc" },
    clipboard = nil :: string?,
    notifications = {} :: { any },
    logs = {} :: { string },
    env = { HOME = "/home/u" } :: { [string]: string },
    tzdata = true, -- America/New_York resolves
  }

  local function copy(value)
    return json.decode(json.encode(value))
  end

  local noctalia = {
    json = { encode = json.encode, decode = json.decode },
    string = {
      trim = function(s)
        return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
      end,
      urlEncode = function(s)
        return (string.gsub(s, "[^%w%-_%.~]", function(c)
          return string.format("%%%02X", string.byte(c))
        end))
      end,
    },
    nowMs = function()
      return host.clock
    end,
    pluginDataDir = function()
      return "/data"
    end,
    pluginDir = function()
      return "/plugin"
    end,
    fileExists = function(p)
      return host.files[p] ~= nil
    end,
    readFile = function(p)
      return host.files[p]
    end,
    writeFile = function(p, content)
      host.files[p] = content
      return true
    end,
    renameFile = function(a, b)
      host.files[b] = host.files[a]
      host.files[a] = nil
      return true
    end,
    removeFile = function(p)
      host.files[p] = nil
      return true
    end,
    -- America/New_York (EDT holds for the specs' October dates) or, without
    -- a zone, "local" time, which the fake host keeps at UTC.
    formatTime = function(pattern, seconds, zone)
      assert(zone == nil or zone == "America/New_York", "unexpected zone")
      -- Like Noctalia, an unresolvable zone silently falls back to local time.
      local ny = zone ~= nil and host.tzdata
      return os.date("!" .. pattern, seconds - (if ny then 4 * 3600 else 0))
    end,
    isValidTimezone = function(name)
      return name == "" or (name == "America/New_York" and host.tzdata)
    end,
    getenv = function(name)
      return host.env[name]
    end,
    mkdirAll = function(_path)
      return true
    end,
    getConfig = function(key)
      return host.config[key]
    end,
    setUpdateInterval = function() end,
    log = function(msg)
      table.insert(host.logs, msg)
    end,
    tr = function(key, subst)
      return key .. (if subst then " " .. json.encode(subst) else "")
    end,
    notify = function(title, body)
      table.insert(host.notifications, { title = title, body = body })
    end,
    copyToClipboard = function(text, _mime)
      host.clipboard = text
      return true
    end,
    http = function(request, cb)
      table.insert(host.requests, { url = request.url, cb = cb })
      return true
    end,
    runAsync = function(argv, cb, timeout)
      table.insert(host.processes, { argv = argv, command = argv[4], cb = cb, timeout = timeout })
      return true
    end,
    state = {
      set = function(key, value)
        host.state[key] = copy(value)
        for _, fn in host.watchers[key] or {} do
          fn(copy(value))
        end
      end,
      get = function(key)
        return host.state[key]
      end,
      watch = function(key, fn)
        host.watchers[key] = host.watchers[key] or {}
        table.insert(host.watchers[key], fn)
      end,
    },
  }
  host.globals = { noctalia = noctalia }

  function host.writeJson(name: string, value)
    host.files[`/data/{name}`] = json.encode(value)
  end

  function host.readJson(name: string)
    local raw = host.files[`/data/{name}`]
    return if raw ~= nil then json.decode(raw) else nil
  end

  -- Answers (and removes) the oldest pending request whose URL contains
  -- `needle`. Returns false if none is pending.
  function host.respond(needle: string, status: number, body: any): boolean
    for i, request in host.requests do
      if string.find(request.url, needle, 1, true) then
        table.remove(host.requests, i)
        request.cb({ ok = true, status = status, body = if type(body) == "string" then body else json.encode(body) })
        return true
      end
    end
    return false
  end

  -- Answers every pending request with `answer(url) -> (status, body)` until
  -- none are left (answers may queue more).
  function host.drainRequests(answer)
    local guard = 0
    while #host.requests > 0 do
      guard += 1
      assert(guard < 500, "request loop")
      local request = table.remove(host.requests, 1)
      local status, body = answer(request.url)
      request.cb({ ok = true, status = status, body = if type(body) == "string" then body else json.encode(body) })
    end
  end

  -- Answers the oldest pending helper run with `result` (a table, encoded as
  -- its stdout). `sideEffect` runs first, like the helper writing its files.
  function host.finishProcess(command: string, result, sideEffect: (() -> ())?)
    local process = table.remove(host.processes, 1)
    assert(process ~= nil, `no helper run pending (wanted {command})`)
    assert(process.command == command, `expected helper {command}, got {process.command}`)
    if sideEffect then
      sideEffect()
    end
    process.cb({ exitCode = 0, stdout = json.encode(result) .. "\n", stderr = "", timedOut = false })
  end

  function host.report()
    return host.state.report
  end

  function host.command(command)
    command.at = host.clock
    noctalia.state.set("command", command)
  end

  return host
end

return M
