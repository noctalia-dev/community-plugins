--!nonstrict
-- rbw-enhanced poller — the headless [[service]] entry.
--
-- Runs `rbw status --json` every poll_interval seconds and publishes a small
-- snapshot under "rbw.snapshot". `rbw status` never starts the agent, never
-- prompts and decrypts nothing, so polling it is cheap and silent. Commands
-- from the widget and the panel arrive through "rbw.cmd": refresh, unlock,
-- lock, sync, tui, settings, login.

local pending = false
local lastCmd = 0

local function trim(s)
  return noctalia.string.trim(s or "")
end

local function rbwBin()
  local configured = trim(noctalia.getConfig("rbw_bin"))
  return configured ~= "" and noctalia.expandPath(configured) or "rbw"
end

-- runInTerminal only takes a command line, so the binary is shell-quoted
local function shq(value)
  local quoted = tostring(value or ""):gsub("'", "'\\''")
  return `'{quoted}'`
end

-- unlocked | locked | stopped (agent not running) | expired | logged-out |
-- not-installed | error
local function stateOf(status)
  if not status.logged_in then
    return "logged-out"
  elseif status.login_expired then
    return "expired"
  elseif not status.agent then
    return "stopped"
  elseif status.locked then
    return "locked"
  end
  return "unlocked"
end

local function publish(snapshot)
  snapshot.checkedAt = noctalia.formatTime("%H:%M:%S")
  local encoded = noctalia.json.encode(snapshot)
  if encoded then
    noctalia.state.set("rbw.snapshot", encoded)
  end
end

local function poll()
  if pending then
    return
  end
  local bin = rbwBin()
  if bin == "rbw" and not noctalia.commandExists("rbw") then
    publish({ state = "not-installed" })
    return
  end
  pending = true
  local accepted = noctalia.runAsync({ bin, "status", "--json" }, function(result)
    pending = false
    if result.exitCode ~= 0 then
      publish({ state = "error", detail = trim(result.stderr) })
      return
    end
    local status = noctalia.json.decode(result.stdout)
    if type(status) ~= "table" then
      -- the upstream rbw has no `status --json` and prints usage instead
      publish({ state = "error", detail = noctalia.tr("panel.not-enhanced") })
      return
    end
    publish({
      state = stateOf(status),
      quick = status.keys_in_memory == true,
      pin = status.pin == true,
      systemAuth = status.system_auth == true,
      lastSync = status.last_sync,
      email = status.email,
      server = status.server,
      autoUnlock = status.auto_unlock == true,
      tuiAuth = status.tui_auth == true,
    })
  end)
  if not accepted then
    pending = false
    publish({ state = "error", detail = "could not start rbw" })
  end
end

-- run an rbw command, report a failure, and poll again right after
local function run(args, okMessage)
  local argv = { rbwBin() }
  for _, a in args do
    table.insert(argv, a)
  end
  noctalia.runAsync(argv, function(result)
    if result.exitCode ~= 0 then
      local detail = trim(result.stderr)
      noctalia.notifyError(noctalia.tr("notify.failed", { command = `rbw {table.concat(args, " ")}` }),
        detail ~= "" and detail or nil)
    elseif okMessage then
      noctalia.notify("rbw-enhanced", noctalia.tr(okMessage))
    end
    poll()
  end)
end

local function terminal(args)
  noctalia.runInTerminal(`{shq(rbwBin())} {args}`)
end

local COMMANDS = {
  refresh = poll,
  -- the agent shows the dialog itself: system authentication (polkit), the
  -- pin or the master password, through the configured pinentry
  unlock = function()
    run({ "unlock" })
  end,
  lock = function()
    run({ "lock" })
  end,
  sync = function()
    run({ "sync" }, "notify.synced")
  end,
  tui = function()
    terminal("tui")
  end,
  settings = function()
    terminal("tui --settings")
  end,
  -- a new login needs the two factor code, so it gets a terminal
  login = function()
    terminal("login")
  end,
}

noctalia.state.watch("rbw.cmd", function(encoded)
  local cmd = encoded and noctalia.json.decode(encoded)
  if type(cmd) ~= "table" or cmd.n == lastCmd then
    return
  end
  lastCmd = cmd.n
  local handler = COMMANDS[cmd.action]
  if handler then
    handler()
  end
end)

function update()
  noctalia.setUpdateInterval(math.max(1, noctalia.getConfig("poll_interval") or 3) * 1000)
  poll()
end

function onIpc(event)
  local handler = COMMANDS[event]
  if handler then
    handler()
  end
end
