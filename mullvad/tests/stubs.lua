-- Fake `noctalia` global and ui node builders for specs.
--
--   local fake = stubs.newNoctalia()
--   fake.install()              -- sets the global `noctalia` (fake.uninstall() restores)
--   fake.queue({"mullvad","status"}, {exitCode=0, stdout="..."})
--   fake.calls                  -- every runAsync: { argv=..., timeoutMs=... }
--   fake.unmatched              -- calls that matched no queued result (they got exitCode 127)
--   fake.state / fake.files / fake.logs / fake.notifications / fake.runStreams
--   fake.config                 -- getConfig(key) values
--   fake.advance(ms)            -- moves nowMs() forward
--   fake.queue(prefix, {defer=true, ...}) holds that call's callback in fake.deferred;
--   fake.flush() then delivers every held result (in order), to model in-flight work
--   fake.updateInterval         -- last setUpdateInterval(ms)
--   fake.processes              -- running command lines for processMatches; runStream adds its cmd
--   fake.fileReads              -- readFileAsync paths; fake.refuseFileReads = true makes it return false
-- Uses the global `json` that run.lua installs (tests/json.lua).

local stubs = {}

local function startsWith(argv, prefix)
  for i, part in ipairs(prefix) do
    if argv[i] ~= part then
      return false
    end
  end
  return true
end

function stubs.newNoctalia()
  local fake = {
    calls = {},
    unmatched = {},
    logs = {},
    notifications = {},
    runStreams = {},
    terminalCalls = {},
    deferred = {},
    processes = {},
    fileReads = {},
    refuseFileReads = false,
    state = {},
    files = {},
    now = 1700000000000,
  }
  local queued = {}
  local watchers = {}
  local dataDir = "/fake/plugin-data"

  -- Results are consumed in order; the first queued entry whose prefix matches wins.
  function fake.queue(argvPrefix, result)
    local full = {
      exitCode = 0, stdout = "", stderr = "",
      timedOut = false, stdoutTruncated = false, stderrTruncated = false,
    }
    for k, v in pairs(result or {}) do
      full[k] = v
    end
    queued[#queued + 1] = { prefix = argvPrefix, result = full }
  end

  function fake.advance(ms)
    fake.now = fake.now + ms
  end

  local n = {}
  fake.noctalia = n

  function n.log(msg)
    fake.logs[#fake.logs + 1] = tostring(msg)
  end

  function n.runAsync(cmdOrArgv, onResult, timeoutMs)
    if type(cmdOrArgv) ~= "table" then
      error("stub runAsync: argv table required, got " .. type(cmdOrArgv) .. " (shell strings are forbidden)", 2)
    end
    local argv = cmdOrArgv
    fake.calls[#fake.calls + 1] = { argv = argv, timeoutMs = timeoutMs, hasCallback = onResult ~= nil }
    local result
    for i, entry in ipairs(queued) do
      if startsWith(argv, entry.prefix) then
        result = entry.result
        table.remove(queued, i)
        break
      end
    end
    if not result then
      fake.unmatched[#fake.unmatched + 1] = { argv = argv }
      result = {
        exitCode = 127, stdout = "", stderr = "stub: no queued result",
        timedOut = false, stdoutTruncated = false, stderrTruncated = false,
      }
    end
    if onResult then
      if result.defer then
        fake.deferred[#fake.deferred + 1] = { onResult = onResult, result = result }
      else
        onResult(result)
      end
    end
    return true
  end

  function fake.flush()
    local held = fake.deferred
    fake.deferred = {}
    for _, entry in ipairs(held) do
      entry.onResult(entry.result)
    end
  end

  function n.setUpdateInterval(ms)
    fake.updateInterval = ms
  end

  function n.runInTerminal(cmd)
    fake.terminalCalls[#fake.terminalCalls + 1] = cmd
    return not fake.terminalFails
  end

  function n.runStream(cmd, onLine)
    fake.runStreams[#fake.runStreams + 1] = { cmd = cmd, onLine = onLine }
    fake.processes[#fake.processes + 1] = cmd
    return true
  end

  -- Like the host: true iff one command line contains every needle as a substring.
  function n.processMatches(onResult, ...)
    local needles = { ... }
    local matched = false
    for _, line in ipairs(fake.processes) do
      local all = #needles > 0
      for _, needle in ipairs(needles) do
        if needle == "" or string.find(line, needle, 1, true) == nil then
          all = false
        end
      end
      if all then
        matched = true
      end
    end
    onResult(matched)
    return true
  end

  function fake.kill(cmd)
    for i = #fake.processes, 1, -1 do
      if fake.processes[i] == cmd then
        table.remove(fake.processes, i)
      end
    end
  end

  function n.notify(title, body)
    fake.notifications[#fake.notifications + 1] = { title = title, body = body, error = false }
  end

  function n.notifyError(title, body)
    fake.notifications[#fake.notifications + 1] = { title = title, body = body, error = true }
  end

  function n.nowMs()
    return fake.now
  end

  -- fake.config = { show_flags = false } sets plugin settings; unset reads as nil.
  fake.config = {}
  function n.getConfig(key)
    return fake.config[key]
  end

  function n.pluginDataDir()
    return dataDir
  end

  function n.fileExists(path)
    return fake.files[path] ~= nil
  end

  function n.readFile(path)
    local contents = fake.files[path]
    if contents == nil then
      return nil, "no such file: " .. tostring(path)
    end
    return contents
  end

  function n.readFileAsync(path, onResult)
    if fake.refuseFileReads then
      return false
    end
    fake.fileReads[#fake.fileReads + 1] = path
    onResult(fake.files[path], fake.files[path] == nil and ("no such file: " .. tostring(path)) or nil)
    return true
  end

  function n.pluginDir()
    return "/fake/plugin"
  end

  function n.writeFile(path, contents)
    fake.files[path] = contents
    return true
  end

  function n.tr(key)
    return key
  end

  n.json = { decode = _G.json.decode, encode = _G.json.encode }

  n.state = {
    set = function(key, value)
      fake.state[key] = value
      for _, cb in ipairs(watchers[key] or {}) do
        cb(value)
      end
    end,
    get = function(key)
      return fake.state[key]
    end,
    watch = function(key, callback)
      watchers[key] = watchers[key] or {}
      table.insert(watchers[key], callback)
    end,
  }

  local previous
  function fake.install()
    previous = _G.noctalia
    _G.noctalia = n
  end
  function fake.uninstall()
    _G.noctalia = previous
  end

  return fake
end

-- stubs.ui.<name>(props, children) -> { type = name, props = props or {}, children = children or {} }
stubs.ui = setmetatable({}, {
  __index = function(_, name)
    return function(props, children)
      return { type = name, props = props or {}, children = children or {} }
    end
  end,
})

return stubs
