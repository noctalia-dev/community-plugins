-- Mocked service tests: no real processes, compositor or Herdr server are used.
local file = assert(io.open(arg[1] or "herdr/service.luau", "r"))
local source = file:read("a")
file:close()

local function fixture(options)
  options = options or {}
  local calls, opened, errors, watches, notifications = {}, {}, {}, {}, {}
  local loaded = false
  local windows = options.windows or { { pid = 100, id = 42 } }
  local parents = options.parents or { [102] = 101, [101] = 100 }
  local context = {
    string = { trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end },
    state = { get = function() return false end, set = function() end,
      watch = function(key, callback) watches[key] = callback end },
    commandExists = function(command) return command ~= "herdr" or loaded end,
    getenv = function(name) return name == "NIRI_SOCKET" and (options.hyprland and "" or "/mock/niri.sock") or "" end,
    readFile = function(path)
      if path == "/proc/sys/kernel/hostname" then return options.hostname end
      local pid = tonumber(path:match("/proc/(%d+)/stat"))
      if parents[pid] then return pid .. " (mock) S " .. parents[pid] .. " 0 0" end
    end,
    json = { decode = options.decode or function(value)
      if value == "windows" then return options.windows or windows end
      if value == "picked" then return options.picked end
    end },
    getConfig = function() return false end,
    setUpdateInterval = function() end,
    tr = options.tr or function(key) return key end,
    log = function() end,
    notifyError = function(_, message) table.insert(errors, message) end,
    notify = function(title, body)
      table.insert(notifications, { title = title, body = body, callCount = #calls })
    end,
    runInTerminal = function(command) table.insert(opened, command); return true end,
  }
  context.runAsync = function(argv, callback)
    local command = table.concat(argv, " ")
    table.insert(calls, command)
    if options.spawnFail == command then return false end
    if command == "niri msg --json windows" then
      callback({ exitCode = options.listExit or 0, timedOut = options.listTimeout, stdout = options.windowsRaw or "windows" })
    elseif command == "ps -C herdr -o pid=,args=" then
      callback({ exitCode = options.psExit or 0, stdout = options.processes or "102 /home/me/.local/bin/herdr\n" })
    elseif command == "niri msg --json pick-window" then
      if options.deferPick then
        options.resolvePick = callback
      else
        callback({ exitCode = options.pickExit or 0, timedOut = options.pickTimeout,
          stdout = options.pickRaw or (options.picked and "picked" or "null") })
      end
    elseif command:match("^niri msg action focus%-window") or command:match("^hyprctl dispatch ") then
      callback({ exitCode = options.focusExit or 0, stdout = "" })
    elseif command:match("^herdr .*agent focus ") or command:match("^herdr agent focus ") then
      if options.deferAgent then options.resolveAgent = callback
      else callback({ exitCode = options.agentExit or 0, stdout = "" }) end
    elseif command:match("^herdr session stop ") or command:match("^herdr session delete ") then
      if options.deferLifecycle then options.resolveLifecycle = callback
      else callback({ exitCode = options.lifecycleExit or 0, stdout = "" }) end
    else
      callback({ exitCode = 1, stdout = "" }) -- No polling fixture needed for action tests.
    end
    return true
  end
  local env = setmetatable({ noctalia = context }, { __index = _G })
  local exported = assert(load(source .. [[
return { detect = detectSessionWindows, focus = focusWindowOrOpen,
  focusAgent = focusAgent, parse = sessionFromArgs, state = state }
]], "service.luau", "t", env))()
  loaded = true
  exported.command = watches["herdr.command"]
  return exported, calls, opened, errors, notifications
end

local count = 0
local function test(name, fn)
  fn()
  count = count + 1
  print("ok " .. count .. " - " .. name)
end
local function includes(values, needle)
  for _, value in ipairs(values) do if value == needle then return true end end
  return false
end

local function readFixture(name)
  local fixtureFile = assert(io.open("herdr/tests/fixtures/" .. name, "r"))
  local value = fixtureFile:read("a")
  fixtureFile:close()
  return value
end

local function decodeJson(value)
  -- Parse JSON text instead of substituting a canned table at the host boundary.
  local quoted = "'" .. value:gsub("'", "'\\''") .. "'"
  local process = assert(io.popen("python3 herdr/tests/decode_json.py " .. quoted .. " 2>/dev/null", "r"))
  local literal = process:read("a")
  local ok = process:close()
  if not ok then return nil end
  return assert(load("return " .. literal, "decoded JSON", "t", {}))()
end

test("JSON window array and picker object reach the existing focus path", function()
  local svc, calls, opened, errors = fixture({
    windowsRaw = readFixture("niri-windows.json"),
    pickRaw = readFixture("niri-picked-window.json"), decode = decodeJson,
  })
  svc.focus("default")
  svc.focus("default")
  local picks = 0
  for _, command in ipairs(calls) do if command == "niri msg --json pick-window" then picks = picks + 1 end end
  assert(picks == 1 and includes(calls, "niri msg action focus-window --id 43"))
  assert(not includes(calls, "niri msg action focus-window --id 44")) -- null PID is not a client.
  assert(#opened == 0 and #errors == 0)
end)

test("malformed window JSON cannot open another terminal", function()
  for _, raw in ipairs({ "[", "null", "false" }) do
    local svc, _, opened, errors = fixture({ windowsRaw = raw, decode = decodeJson })
    svc.focus("default")
    assert(#opened == 0 and #errors == 1)
  end
end)

test("malformed picker JSON reports an error while JSON null cancels silently", function()
  for _, raw in ipairs({ "{", "null" }) do
    local svc, _, opened, errors = fixture({
      windowsRaw = readFixture("niri-windows.json"), pickRaw = raw, decode = decodeJson,
    })
    svc.focus("default")
    assert(#opened == 0)
    assert(#errors == (raw == "null" and 0 or 1))
    assert(svc.state.action.status == (raw == "null" and "cancelled" or "error"))
  end
end)

test("default session maps through shell ancestry, with Niri preferred over installed hyprctl", function()
  local svc, calls = fixture()
  svc.detect(function(windows, err)
    assert(not err and windows.default.id == "42")
    assert(windows.default.compositor == "niri")
  end)
  assert(not includes(calls, "hyprctl clients -j"))
end)

test("named attachment syntax and non-client exclusions", function()
  local svc = fixture()
  assert(svc.parse("herdr") == "default")
  assert(svc.parse("herdr attach") == "default")
  assert(svc.parse("herdr --session project") == "project")
  assert(svc.parse("herdr --session=project") == "project")
  assert(svc.parse("herdr session attach project") == "project")
  assert(svc.parse("herdr --handoff --session project") == "project")
  for _, command in ipairs({ "herdr server", "herdr api snapshot", "herdr agent focus p:q", "herdr --remote host", "herdr --session project status" }) do
    assert(svc.parse(command) == nil, command)
  end
end)

test("one Herdr-titled window among shared-PID terminals needs no picker", function()
  for _, title in ipairs({ "herdr", "HerdR", "Herdr: project", "herdr - project" }) do
    local svc, calls, opened, errors, notifications = fixture({ windows = {
      { pid = 100, id = 42, title = "shell" }, { pid = 100, id = 43, title = title },
    } })
    svc.focus("default")
    assert(includes(calls, "niri msg action focus-window --id 43"), title)
    assert(not includes(calls, "niri msg --json pick-window"))
    assert(#notifications == 0)
    assert(#opened == 0 and #errors == 0)
  end
end)

test("picker notification names the session and explains cancellation before selection", function()
  local translationFile = assert(io.open("herdr/translations/en.json", "r"))
  local english = assert(decodeJson(translationFile:read("a")))
  translationFile:close()
  for _, sessionName in ipairs({ "default", "project" }) do
    local options = {
      windows = { { pid = 100, id = 42 }, { pid = 100, id = 43 } }, deferPick = true,
      processes = "102 herdr --session " .. sessionName,
      tr = function(key, values)
        if key == "notify.pick_window" then return english.notify.pick_window end
        if key == "action.pick_window" then
          assert(values.session == sessionName)
          return (english.action.pick_window:gsub("{session}", values.session))
        end
        return key
      end,
    }
    local svc, calls, opened, errors, notifications = fixture(options)
    svc.focus(sessionName)
    assert(options.resolvePick and #notifications == 1)
    local notification = notifications[1]
    assert(notification.title == english.notify.pick_window)
    assert(notification.body:find('"' .. sessionName .. '"', 1, true))
    assert(notification.body:find("Esc", 1, true))
    assert(calls[notification.callCount + 1] == "niri msg --json pick-window")
    options.resolvePick({ exitCode = 0, stdout = "null" })
    assert(#notifications == 1 and #opened == 0 and #errors == 0)
  end
end)

test("default and Herdr-prefixed workspace titles take precedence over a generic title", function()
  for _, title in ipairs({ "test-host: project", "Herdr: test-host: project", "herdr - test-host: project" }) do
    local svc, calls = fixture({ hostname = "test-host\n", windows = {
      { pid = 100, id = 42, title = "herdr" }, { pid = 100, id = 43, title = title },
    } })
    svc.state.sessions = { { name = "default", projects = { "project" } } }
    svc.focus("default")
    assert(includes(calls, "niri msg action focus-window --id 43"), title)
    assert(not includes(calls, "niri msg --json pick-window"))
  end
end)

test("default titles distinguish two named sessions sharing a terminal process", function()
  local svc, calls = fixture({ hostname = "test-host", windows = {
    { pid = 100, id = 42, title = "test-host: alpha" },
    { pid = 100, id = 43, title = "test-host: beta" },
  }, processes = "102 herdr --session project\n202 herdr --session project2\n",
    parents = { [102] = 100, [202] = 100 } })
  svc.state.sessions = {
    { name = "project", projects = { "alpha" } }, { name = "project2", projects = { "beta" } },
  }
  svc.focus("project")
  svc.focus("project2")
  assert(includes(calls, "niri msg action focus-window --id 42"))
  assert(includes(calls, "niri msg action focus-window --id 43"))
  assert(not includes(calls, "niri msg --json pick-window"))
end)

test("Herdr session labels respect name boundaries, punctuation and case", function()
  for _, names in ipairs({ { "project", "project2" }, { "app.v2", "appXv2" }, { "Prod", "prod" } }) do
    local svc, calls = fixture({ windows = {
      { pid = 100, id = 42, title = "herdr [" .. names[1] .. "]" },
      { pid = 100, id = 43, title = "herdr [" .. names[2] .. "]" },
    }, processes = "102 herdr --session " .. names[1] .. "\n202 herdr --session " .. names[2] .. "\n",
      parents = { [102] = 100, [202] = 100 } })
    svc.focus(names[1])
    assert(includes(calls, "niri msg action focus-window --id 42"))
    assert(not includes(calls, "niri msg action focus-window --id 43"))
    svc.focus(names[2])
    assert(includes(calls, "niri msg action focus-window --id 43"))
    assert(not includes(calls, "niri msg --json pick-window"))
  end
end)

test("generic titles do not guess between sessions sharing one terminal process", function()
  local svc, calls = fixture({ windows = {
    { pid = 100, id = 42, title = "herdr" }, { pid = 100, id = 43, title = "shell" },
  }, processes = "102 herdr\n202 herdr --session project\n", parents = { [102] = 100, [202] = 100 },
    picked = { id = 43 } })
  svc.focus("project")
  assert(includes(calls, "niri msg --json pick-window"))
  assert(includes(calls, "niri msg action focus-window --id 43"))
  assert(not includes(calls, "niri msg action focus-window --id 42"))
end)

test("overlapping workspace labels stay ambiguous for shared-process sessions", function()
  local svc, calls = fixture({ hostname = "test-host", windows = {
    { pid = 100, id = 42, title = "test-host: common" }, { pid = 100, id = 43, title = "shell" },
  }, processes = "102 herdr\n202 herdr --session project\n", parents = { [102] = 100, [202] = 100 },
    picked = { id = 42 } })
  svc.state.sessions = {
    { name = "default", projects = { "common" } }, { name = "project", projects = { "common" } },
  }
  svc.focus("default")
  assert(includes(calls, "niri msg --json pick-window"))
end)

test("another session in a separate terminal process does not prevent title matching", function()
  local svc, calls = fixture({ windows = {
    { pid = 100, id = 42, title = "shell" }, { pid = 100, id = 43, title = "herdr" },
    { pid = 200, id = 44, title = "herdr" },
  }, processes = "102 herdr\n202 herdr --session project\n", parents = { [102] = 100, [202] = 200 } })
  svc.focus("default")
  assert(includes(calls, "niri msg action focus-window --id 43"))
  assert(not includes(calls, "niri msg --json pick-window"))
end)

test("matching titles outside the session's PID candidates are ignored", function()
  local svc, calls = fixture({ windows = {
    { pid = 100, id = 42, title = "shell" }, { pid = 100, id = 43, title = "shell" },
    { pid = 200, id = 44, title = "herdr" },
  }, picked = { id = 42 } })
  svc.focus("default")
  assert(includes(calls, "niri msg --json pick-window"))
  assert(not includes(calls, "niri msg action focus-window --id 44"))
end)

test("identical Herdr titles still use the picker", function()
  local svc, calls = fixture({ windows = {
    { pid = 100, id = 42, title = "herdr" }, { pid = 100, id = 43, title = "herdr" },
  }, picked = { id = 43 } })
  svc.focus("default")
  assert(includes(calls, "niri msg --json pick-window"))
  assert(includes(calls, "niri msg action focus-window --id 43"))
end)

test("mentions of Herdr in editor titles and paths do not select a window", function()
  for _, title in ipairs({ "vim /repo/herdr/service.luau", "herdr.md", "myherdr" }) do
    local svc, calls = fixture({ windows = {
      { pid = 100, id = 42, title = title }, { pid = 100, id = 43, title = "shell" },
    }, picked = { id = 43 } })
    svc.focus("default")
    assert(includes(calls, "niri msg --json pick-window"), title)
  end
end)

test("remembered user choices take precedence over a newly recognizable title", function()
  local options = { windows = {
    { pid = 100, id = 42, title = "shell" }, { pid = 100, id = 43, title = "shell" },
  }, picked = { id = 42 } }
  local svc, calls = fixture(options)
  svc.focus("default")
  options.windows[2].title = "herdr"
  svc.focus("default")
  assert(not includes(calls, "niri msg action focus-window --id 43"))
end)

test("automatic title matches are re-evaluated at every click", function()
  local options = { windows = {
    { pid = 100, id = 42, title = "shell" }, { pid = 100, id = 43, title = "herdr" },
  } }
  local svc, calls = fixture(options)
  svc.focus("default")
  options.windows[1].title, options.windows[2].title = "herdr", "shell"
  svc.focus("default")
  assert(includes(calls, "niri msg action focus-window --id 43"))
  assert(includes(calls, "niri msg action focus-window --id 42"))
  assert(not includes(calls, "niri msg --json pick-window"))
end)

test("title matching uses the decoded Niri JSON field", function()
  local svc, calls = fixture({ decode = decodeJson,
    windowsRaw = ' [{"id":42,"pid":100,"title":"shell"},{"id":43,"pid":100,"title":"Herdr"}] ',
  })
  svc.focus("default")
  assert(includes(calls, "niri msg action focus-window --id 43"))
  assert(not includes(calls, "niri msg --json pick-window"))
end)

test("command watcher allows stop/delete/refresh while serializing focus during a picker", function()
  for _, action in ipairs({ "stop_session", "delete_session" }) do
    local sessionName = action == "stop_session" and "default" or "stopped"
    local command = action == "stop_session" and "herdr session stop default --json"
      or "herdr session delete stopped --json"
    for _, outcome in ipairs({ "success", "error", "spawn failure" }) do
      local options = {
        windows = { { pid = 100, id = 42 }, { pid = 100, id = 43 } },
        picked = { id = 43 }, deferPick = true,
        lifecycleExit = outcome == "error" and 1 or 0,
        spawnFail = outcome == "spawn failure" and command or nil,
      }
      local svc, calls, opened = fixture(options)
      svc.state.sessions = { { name = "default", running = true }, { name = "stopped", running = false } }
      svc.command({ action = "focus_agent", session = "default", pane = "pane:1" })
      assert(options.resolvePick, "focus must reach the picker")
      svc.command({ action = action, session = sessionName })
      assert(includes(calls, command), action .. " was dropped during the picker")
      local before = #calls
      svc.command({ action = "focus_agent", session = "default", pane = "pane:2" })
      svc.command({ action = "open_session", session = "default" })
      assert(#calls == before, outcome .. " released another operation's focus lock")
      svc.command({ action = "refresh" })
      assert(#calls > before and includes(calls, "herdr session list --json"))
      options.resolvePick({ exitCode = 0, stdout = "picked" })
      svc.command({ action = "focus_agent", session = "default", pane = "pane:2" })
      assert(includes(calls, "herdr agent focus pane:2"), "picker completion must release the lock")
      assert(#opened == 0)
    end
  end
end)

test("a late lifecycle completion cannot release a newer focus operation", function()
  local options = {
    windows = { { pid = 100, id = 42 }, { pid = 100, id = 43 } },
    picked = { id = 43 }, deferPick = true, deferLifecycle = true, deferAgent = true,
  }
  local svc, calls = fixture(options)
  svc.state.sessions = { { name = "default", running = true } }
  svc.command({ action = "open_session", session = "default" })
  svc.command({ action = "stop_session", session = "default" })
  assert(options.resolvePick and options.resolveLifecycle)
  options.resolvePick({ exitCode = 0, stdout = "picked" })
  svc.command({ action = "focus_agent", session = "default", pane = "pane:1" })
  assert(options.resolveAgent)
  options.resolveLifecycle({ exitCode = 0, stdout = "" })
  local before = #calls
  svc.command({ action = "focus_agent", session = "default", pane = "pane:2" })
  assert(#calls == before)
  options.resolveAgent({ exitCode = 0, stdout = "" })
end)

test("invalid lifecycle requests do not release the picker lock", function()
  local options = { windows = { { pid = 100, id = 42 }, { pid = 100, id = 43 } }, deferPick = true }
  local svc, calls = fixture(options)
  svc.state.sessions = { { name = "default", running = true } }
  svc.command({ action = "open_session", session = "default" })
  svc.command({ action = "stop_session", session = "bad/name" })
  svc.command({ action = "delete_session", session = "missing" })
  local before = #calls
  svc.command({ action = "focus_agent", session = "default", pane = "pane:1" })
  assert(#calls == before)
  options.resolvePick({ exitCode = 0, stdout = "null" })
end)

test("incomplete window and process polls preserve the remembered choice", function()
  for _, incomplete in ipairs({ "windows", "processes" }) do
    local options = {
      windows = { { pid = 100, id = 42 }, { pid = 200, id = 43 } }, picked = { id = 43 },
      processes = "102 herdr\n202 herdr\n", parents = { [102] = 100, [202] = 200 },
    }
    local svc, calls = fixture(options)
    svc.focus("default")
    local originalWindows, originalProcesses = options.windows, options.processes
    if incomplete == "windows" then options.windows = { { pid = 100, id = 42 } }
    else options.processes = "102 herdr\n" end
    svc.detect(function(windows, err)
      assert(not err and windows.default.id == "42")
    end)
    options.windows, options.processes = originalWindows, originalProcesses
    svc.focus("default")
    local picks = 0
    for _, command in ipairs(calls) do if command == "niri msg --json pick-window" then picks = picks + 1 end end
    assert(picks == 1, incomplete .. " poll discarded the remembered choice")
    assert(includes(calls, "niri msg action focus-window --id 43"))
  end
end)

test("a click invalidates a genuinely missing remembered window", function()
  local options = { windows = { { pid = 100, id = 42 }, { pid = 100, id = 43 } }, picked = { id = 43 } }
  local svc, calls = fixture(options)
  svc.focus("default")
  options.windows = { { pid = 100, id = 42 } }
  svc.focus("default")
  assert(includes(calls, "niri msg action focus-window --id 42"))
  options.windows = { { pid = 100, id = 42 }, { pid = 100, id = 43 } }
  svc.focus("default")
  local picks = 0
  for _, command in ipairs(calls) do if command == "niri msg --json pick-window" then picks = picks + 1 end end
  assert(picks == 2, "click-time validation must forget the missing window")
end)

test("failed click-time discovery keeps the remembered choice for retry", function()
  local options = { windows = { { pid = 100, id = 42 }, { pid = 100, id = 43 } }, picked = { id = 43 } }
  local svc, calls, opened = fixture(options)
  svc.focus("default")
  options.listExit = 1
  svc.focus("default")
  options.listExit = 0
  svc.focus("default")
  local picks = 0
  for _, command in ipairs(calls) do if command == "niri msg --json pick-window" then picks = picks + 1 end end
  assert(picks == 1 and #opened == 0)
end)

test("agent click focuses pane then existing Niri window without opening a terminal", function()
  local svc, calls, opened = fixture()
  svc.focusAgent("default", "pane:1")
  assert(calls[1] == "herdr agent focus pane:1")
  assert(includes(calls, "niri msg action focus-window --id 42"))
  assert(#opened == 0)
end)

test("named session focuses its existing terminal", function()
  local svc, calls, opened = fixture({ processes = "102 herdr --session project" })
  svc.focusAgent("project", "pane:2")
  assert(calls[1] == "herdr --session project agent focus pane:2")
  assert(includes(calls, "niri msg action focus-window --id 42"))
  assert(#opened == 0)
end)

test("absent client opens requested named session", function()
  local svc, _, opened = fixture({ processes = "", psExit = 1 })
  svc.focus("project")
  assert(#opened == 1 and opened[1] == "herdr --session project")
end)

test("no windows opens default session", function()
  local svc, _, opened = fixture({ windows = {} })
  svc.focus("default")
  assert(#opened == 1 and opened[1] == "herdr")
end)

test("cancelled window selection stays quiet and permits a later retry", function()
  local svc, calls, opened, errors = fixture({ windows = { { pid = 100, id = 42 }, { pid = 100, id = 43 } } })
  svc.focus("default")
  assert(#opened == 0 and #errors == 0 and svc.state.action.status == "cancelled")
  assert(not includes(calls, "niri msg action focus-window --id 42"))
  svc.focus("default")
  local picks = 0
  for _, command in ipairs(calls) do if command == "niri msg --json pick-window" then picks = picks + 1 end end
  assert(picks == 2)
end)

test("shared PID prompts once and remembers the selected window", function()
  local svc, calls, opened, errors, notifications = fixture({ windows = { { pid = 100, id = 42 }, { pid = 100, id = 43 } }, picked = { id = 43 } })
  svc.focus("default")
  svc.focus("default")
  local picks = 0
  for _, command in ipairs(calls) do if command == "niri msg --json pick-window" then picks = picks + 1 end end
  assert(picks == 1 and includes(calls, "niri msg action focus-window --id 43"))
  assert(#notifications == 1 and notifications[1].title == "notify.pick_window")
  assert(#opened == 0 and #errors == 0)
end)

test("selecting an unrelated window never focuses it", function()
  local svc, calls, opened, errors = fixture({ windows = { { pid = 100, id = 42 }, { pid = 100, id = 43 } }, picked = { id = 99 } })
  svc.focus("default")
  assert(not includes(calls, "niri msg action focus-window --id 99"))
  assert(#opened == 0 and #errors == 0 and svc.state.action.status == "cancelled")
end)

test("real picker failures still report an error", function()
  for _, extra in ipairs({ { pickExit = 1 }, { pickTimeout = true }, { pickRaw = "garbled" }, { spawnFail = "niri msg --json pick-window" } }) do
    extra.windows = { { pid = 100, id = 42 }, { pid = 100, id = 43 } }
    local svc, _, opened, errors = fixture(extra)
    svc.focus("default")
    assert(#opened == 0 and errors[1] == "error.niri_picker_failed")
  end
end)

test("multiple attached clients retain a valid selection when process order changes", function()
  local options = { windows = { { pid = 100, id = 42 }, { pid = 200, id = 43 } }, picked = { id = 43 },
    processes = "102 herdr\n202 herdr\n", parents = { [102] = 100, [202] = 200 } }
  local svc, calls, opened, errors = fixture(options)
  svc.focus("default")
  options.processes = "202 herdr\n102 herdr\n"
  svc.focus("default")
  local picks, focuses = 0, 0
  for _, command in ipairs(calls) do
    if command == "niri msg --json pick-window" then picks = picks + 1 end
    if command == "niri msg action focus-window --id 43" then focuses = focuses + 1 end
  end
  assert(picks == 1 and focuses == 2 and #opened == 0 and #errors == 0)
end)

test("rapid clicks start only one picker and do not send another agent focus", function()
  local options = { windows = { { pid = 100, id = 42 }, { pid = 100, id = 43 } }, picked = { id = 43 }, deferPick = true }
  local svc, calls, opened, errors, notifications = fixture(options)
  svc.focusAgent("default", "pane:1")
  svc.focusAgent("default", "pane:2")
  svc.focus("default")
  local picks = 0
  for _, command in ipairs(calls) do if command == "niri msg --json pick-window" then picks = picks + 1 end end
  assert(picks == 1 and not includes(calls, "herdr agent focus pane:2"))
  assert(#notifications == 1 and notifications[1].title == "notify.pick_window")
  options.resolvePick({ exitCode = 0, stdout = "picked" })
  assert(includes(calls, "niri msg action focus-window --id 43"))
  assert(#opened == 0 and #errors == 0)
end)

test("focus is serialized even while the initial Herdr command is pending", function()
  local options = { deferAgent = true }
  local svc, calls, opened, errors = fixture(options)
  svc.focusAgent("default", "pane:1")
  svc.focusAgent("default", "pane:2")
  svc.focus("default")
  assert(#calls == 1)
  options.resolveAgent({ exitCode = 0, stdout = "" })
  assert(includes(calls, "niri msg action focus-window --id 42"))
  assert(#opened == 0 and #errors == 0)
end)

test("new candidates opened during selection are accepted after revalidation", function()
  local options = { windows = { { pid = 100, id = 42 }, { pid = 100, id = 43 } }, picked = { id = 44 }, deferPick = true }
  local svc, calls, opened, errors = fixture(options)
  svc.focus("default")
  table.insert(options.windows, { pid = 100, id = 44 })
  options.resolvePick({ exitCode = 0, stdout = "picked" })
  assert(includes(calls, "niri msg action focus-window --id 44"))
  assert(#opened == 0 and #errors == 0)
end)

test("closed selected window is rejected on revalidation without a new terminal", function()
  local options = { windows = { { pid = 100, id = 42 }, { pid = 100, id = 43 } }, picked = { id = 43 }, deferPick = true }
  local svc, calls, opened, errors = fixture(options)
  svc.focus("default")
  options.windows = { { pid = 100, id = 42 } }
  options.resolvePick({ exitCode = 0, stdout = "picked" })
  assert(not includes(calls, "niri msg action focus-window --id 43"))
  assert(#opened == 0 and #errors == 0)
end)

test("panel closes before publishing a focus command, but not for refresh", function()
  local events, callbacks = {}, nil
  local env = setmetatable({
    require = function() return { build = function(_, options) callbacks = options; return {} end } end,
    noctalia = { state = { get = function() return {} end, watch = function() end,
      set = function(key) if key == "herdr.command" then table.insert(events, "command") end end } },
    panel = { render = function() end, close = function() table.insert(events, "close") end },
  }, { __index = _G })
  assert(loadfile("herdr/panel.luau", "t", env))()
  callbacks.request("focus_agent", "default", "pane:1")
  assert(events[1] == "close" and events[2] == "command")
  events = {}
  callbacks.request("refresh")
  assert(#events == 1 and events[1] == "command")
end)

test("cancelled picker status renders silently while errors retain their message", function()
  local ui = setmetatable({}, { __index = function(_, kind)
    return function(props, children) return { props = props, children = children or {} } end
  end })
  local env = setmetatable({ ui = ui, noctalia = {
    tr = function(key) return key end,
    state = { get = function() return nil end },
  } }, { __index = _G })
  local view = assert(loadfile("herdr/panel_view.luau", "t", env))()
  local function contains(node, message)
    if node.props.text == message then return true end
    for _, child in ipairs(node.children) do if contains(child, message) then return true end end
    return false
  end
  for _, status in ipairs({ "cancelled", "error" }) do
    local message = "action.selection_cancelled"
    local tree = view.build({ available = true, sessions = {}, action = { status = status, message = message } })
    assert(contains(tree, message) == (status == "error"))
  end
end)

test("failed or timed-out window listing does not create duplicate terminals", function()
  for _, options in ipairs({ { listExit = 1 }, { listTimeout = true }, { spawnFail = "niri msg --json windows" } }) do
    local svc, _, opened, errors = fixture(options)
    svc.focus("default")
    assert(#opened == 0 and #errors == 1)
  end
end)

test("process-list errors do not create duplicate terminals", function()
  local svc, _, opened, errors = fixture({ psExit = 2 })
  svc.focus("default")
  assert(#opened == 0 and #errors == 1)
end)

test("failed focus reports an error without creating duplicate terminals", function()
  for _, options in ipairs({ { focusExit = 1 }, { spawnFail = "niri msg action focus-window --id 42" } }) do
    local svc, _, opened, errors = fixture(options)
    svc.focus("default")
    assert(#opened == 0 and errors[1] == "error.niri_focus_failed")
  end
end)

test("window ID zero is accepted and invalid window records are ignored", function()
  local svc, calls = fixture({ windows = { { id = "bad", pid = 100 }, { id = 0, pid = 100 }, { id = 10 } } })
  svc.focus("default")
  assert(includes(calls, "niri msg action focus-window --id 0"))
end)

test("Hyprland focus behavior remains available outside Niri", function()
  local svc, calls, opened = fixture({ hyprland = true })
  svc.state.sessions = { { name = "default", window = { address = "0x123", workspace = "2" } } }
  svc.focus("default")
  assert(includes(calls, 'hyprctl dispatch hl.dsp.focus({ window = "address:0x123" })'))
  assert(#opened == 0)
end)

print(count .. " tests passed")
