--!nonstrict
-- Owns the drop window. Noctalia panels cannot take part in Wayland drag and
-- drop, so the service starts helper/shelf-window.py (GTK4), reads the JSON
-- events it prints, and applies them to the store. Panel and widget ask for
-- the window through the shelf.request state key.
--
-- The helper stays resident once started: closing the window only hides it,
-- and the service shows, hides, and reconfigures it over D-Bus (gdbus), which
-- is far quicker than starting Python and GTK again. The helper quits on its
-- own when this service goes away (its stdout closes) or after sitting hidden
-- for a while, and the service notices and launches a fresh one next time.

local store = require("./lib/store.luau")

local HELPER = "helper/shelf-window.py"
local APP_ID = "dev.noctalia.Shelf"
local APP_PATH = "/dev/noctalia/Shelf"
local PALETTE_ROLES = {
  "primary", "on_primary", "surface", "surface_variant",
  "on_surface", "on_surface_variant", "outline", "error",
}
local IDLE_POLL_MS = 60000
local LIVENESS_POLL_MS = 10000
local LAUNCH_POLL_MS = 1000
local LAUNCH_TIMEOUT_MS = 8000

local running = false   -- a helper process is up and attached to our stream
local launching = false -- launched, waiting for its "ready"
local launchedAt = 0
local generation = 0    -- bumped per launch, so stale gdbus replies are ignored
local wantVisible = false -- the window is shown, or about to be
local pending = nil     -- "hide" when the window should hide once it is up
local depsOk = false
local depsChecking = false
local depsWaiting = {}

local lastRequest = noctalia.state.get(store.REQUEST_KEY)
local lastRequestId = type(lastRequest) == "table" and lastRequest.id or nil

noctalia.state.set(store.ITEMS_KEY, store.load())
noctalia.state.set(store.HELPER_KEY, false)

local function shellQuote(value)
  return "'" .. string.gsub(value, "'", "'\\''") .. "'"
end

-- GVariant text-format string literal.
local function gvariantString(value)
  return "'" .. string.gsub(string.gsub(value, "\\", "\\\\"), "'", "\\'") .. "'"
end

local function python()
  local configured = noctalia.string.trim(noctalia.getConfig("python") or "")
  if configured ~= "" then
    return noctalia.expandPath(configured)
  end
  -- The GTK bindings ship with the system interpreter; a python3 from
  -- Homebrew, pyenv, or a venv earlier on PATH usually lacks them.
  if noctalia.fileExists("/usr/bin/python3") then
    return "/usr/bin/python3"
  end
  return "python3"
end

local function palette()
  if noctalia.getColor == nil then
    return nil
  end
  local colors = {}
  local any = false
  for _, role in ipairs(PALETTE_ROLES) do
    local ok, value = pcall(noctalia.getColor, role)
    if ok and type(value) == "string" then
      colors[role] = value
      any = true
    end
  end
  return any and colors or nil
end

-- Settings the window follows. Sent on every show so changes apply without a
-- restart.
local function windowOptions()
  return {
    position = noctalia.getConfig("window_position") or "last",
    remove_after_drag = noctalia.getConfig("remove_after_drag") == true,
    close_after_drag = noctalia.getConfig("close_after_drag") == true,
    colors = palette(),
  }
end

local function setVisible(visible)
  if noctalia.state.get(store.HELPER_KEY) ~= visible then
    noctalia.state.set(store.HELPER_KEY, visible)
  end
end

local function setRunning(value)
  running = value
  if not value then
    wantVisible = false
    setVisible(false)
  end
  noctalia.setUpdateInterval(launching and LAUNCH_POLL_MS or (value and LIVENESS_POLL_MS or IDLE_POLL_MS))
end

local launch -- forward declaration

-- Sends an action to the resident window. Falls back to a fresh launch when
-- the helper turns out to be gone.
local function activate(action)
  local gen = generation
  if action == "show" then
    wantVisible = true
  elseif action == "hide" then
    wantVisible = false
  elseif action == "toggle" then
    wantVisible = not wantVisible
  end
  local args = "[]"
  if action ~= "hide" and action ~= "quit" then
    args = "[<" .. gvariantString(noctalia.json.encode(windowOptions())) .. ">]"
  end
  noctalia.runAsync({
    "gdbus", "call", "--session", "--dest", APP_ID, "--object-path", APP_PATH,
    "--method", "org.gtk.Actions.Activate", action, args, "{}",
  }, function(result)
    if result.exitCode == 0 or gen ~= generation then
      return
    end
    noctalia.log("shelf: window did not answer " .. action .. ": " .. tostring(result.stderr))
    -- Only a failed show means the window is gone and must be started again;
    -- other failures leave state alone and the liveness check settles it.
    if action == "show" or (action == "toggle" and wantVisible) then
      setRunning(false)
      launch()
    end
  end)
end

local function onHelperLine(line)
  local event = noctalia.json.decode(line)
  if type(event) ~= "table" then
    noctalia.log("shelf window: " .. line)
    return
  end
  if event.op == "add" and type(event.paths) == "table" then
    store.add(event.paths)
  elseif event.op == "remove" and type(event.paths) == "table" then
    store.remove(event.paths)
  elseif event.op == "clear" then
    store.clear()
  elseif event.op == "ready" then
    launching = false
    setRunning(true)
    if pending ~= nil then
      local action = pending
      pending = nil
      activate(action)
    end
  elseif event.op == "shown" then
    running = true
    wantVisible = true
    setVisible(true)
  elseif event.op == "hidden" then
    running = true
    wantVisible = false
    setVisible(false)
  elseif event.op == "bye" then
    launching = false
    setRunning(false)
  end
end

local function helperCommand()
  local opts = windowOptions()
  local parts = {
    shellQuote(python()),
    shellQuote(noctalia.pluginDir() .. "/" .. HELPER),
    "--store", shellQuote(store.path()),
    "--options", shellQuote(noctalia.json.encode(opts)),
  }
  -- stderr joins stdout, so GTK warnings and tracebacks land in the Noctalia log.
  return table.concat(parts, " ") .. " 2>&1"
end

launch = function()
  if launching then
    return
  end
  if store.path() == nil then
    noctalia.notifyError(noctalia.tr("notify.no_data_dir"))
    return
  end
  launching = true
  launchedAt = noctalia.nowMs()
  generation = generation + 1
  wantVisible = true
  noctalia.setUpdateInterval(LAUNCH_POLL_MS)
  if not noctalia.runStream(helperCommand(), onHelperLine) then
    launching = false
    setRunning(false)
    noctalia.notifyError(noctalia.tr("notify.launch_failed"))
  end
end

-- Checks that the interpreter has the GTK 4 bindings, so a missing package
-- produces a clear notification instead of a window that never shows. Only
-- success is cached: after installing the package the next try works.
local function withDeps(fn)
  if depsOk then
    fn()
    return
  end
  table.insert(depsWaiting, fn)
  if depsChecking then
    return
  end
  depsChecking = true
  local check = "import gi; gi.require_version('Gtk', '4.0'); from gi.repository import Gtk"
  noctalia.runAsync({ python(), "-c", check }, function(result)
    depsChecking = false
    depsOk = result.exitCode == 0
    local waiting = depsWaiting
    depsWaiting = {}
    if not depsOk then
      noctalia.log("shelf: GTK 4 check failed: " .. tostring(result.stderr))
      noctalia.notifyError(noctalia.tr("notify.missing_deps.title"), noctalia.tr("notify.missing_deps.body"))
      return
    end
    for _, waiter in ipairs(waiting) do
      waiter()
    end
  end)
end

local function handle(action)
  if action ~= "open" and action ~= "toggle" and action ~= "close" then
    return
  end
  if launching or depsChecking then
    -- The new window shows itself; remember whether it should hide again.
    if action == "close" then
      pending = "hide"
    elseif action == "open" then
      pending = nil
    else
      pending = (pending == nil) and "hide" or nil
    end
    return
  end
  if running then
    if action == "open" then
      activate("show")
    elseif action == "toggle" then
      activate("toggle")
    else
      activate("hide")
    end
    return
  end
  if action ~= "close" then
    pending = nil
    withDeps(launch)
  end
end

noctalia.state.watch(store.REQUEST_KEY, function(request)
  if type(request) ~= "table" or request.id == lastRequestId then
    return
  end
  lastRequestId = request.id
  handle(request.action)
end)

noctalia.setUpdateInterval(IDLE_POLL_MS)

-- The stream gives no exit callback, so check now and then that the helper is
-- still alive; a crash would otherwise leave the window marked open.
function update()
  if launching then
    -- A helper that dies before "ready" (or hands off to another copy and
    -- exits) never reports back. Give up waiting after a while.
    if noctalia.nowMs() - launchedAt > LAUNCH_TIMEOUT_MS then
      noctalia.log("shelf: drop window did not start")
      launching = false
      pending = nil
      setRunning(false)
    end
    return
  end
  if not running then
    return
  end
  local gen = generation
  noctalia.processMatches(function(matched)
    if not matched and running and not launching and gen == generation then
      noctalia.log("shelf: drop window process is gone")
      setRunning(false)
    end
  end, HELPER)
end

-- A setting changed. Keep the store, and pass the new settings to a running
-- window right away.
function onConfigChanged()
  depsOk = false
  if running then
    activate("configure")
  end
end

-- The runtime ends our stream on reload or disable, and the helper quits when
-- its stdout closes. Ask it directly too, in case it is between writes.
function onExit()
  if running or launching then
    noctalia.runAsync({
      "gdbus", "call", "--session", "--dest", APP_ID, "--object-path", APP_PATH,
      "--method", "org.gtk.Actions.Activate", "quit", "[]", "{}",
    })
  end
end

-- noctalia msg plugin alok-debnath/shelf:service all <event> [payload]
function onIpc(event, payload)
  if event == "toggle" or event == "open" or event == "close" then
    handle(event)
  elseif event == "add" then
    local paths = store.pathsFromText(payload)
    if #paths > 0 then
      store.add(paths)
    else
      noctalia.log("shelf: add ignored, no existing path in: " .. tostring(payload))
    end
  elseif event == "clear" then
    store.clear()
  elseif event == "panel" then
    noctalia.togglePanel(store.PANEL_ID)
  elseif event == "shortcut" then
    -- Open the panel at its keyboard shortcut section.
    noctalia.state.set(store.PANEL_VIEW_KEY, { id = tostring(noctalia.nowMs()), view = "shortcut" })
    if noctalia.state.get(store.PANEL_OPEN_KEY) ~= true then
      noctalia.togglePanel(store.PANEL_ID)
    end
  else
    noctalia.log("shelf: unknown IPC event " .. tostring(event))
  end
end
