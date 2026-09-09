--!nonstrict
-- KWallet Secrets -- supervises the KWallet-backed NetworkManager secret agent.
--
-- The real work happens in scripts/kwallet-nm-agent.py, a long-lived process on
-- the system bus. This service only starts it, keeps it alive, restarts it when
-- the plugin settings change, and publishes a small status blob.

local SCRIPT = "/scripts/kwallet-nm-agent.py" -- resolved against the plugin dir
local STATE_KEY = "kwallet_secrets.status"    -- published status channel
local JOURNAL_TAG = "noctalia-kwallet-secrets" -- systemd-cat tag for helper logs
local CHECK_MS = 30000                        -- supervision interval
local RUN_TIMEOUT_MS = 5000                   -- timeout for the supervision shell

local IDENTIFIER = "io.github.grassyloki.kwalletSecrets" -- NM agent identifier

-- The helper takes an abstract unix socket as a single-instance lock, and that
-- lock is what "is it running?" asks about. Matching on the socket instead of a
-- command line keeps the check honest across argument changes, and a shell can
-- never be mistaken for the agent.
local LOCK = "@noctalia-kwallet-nm-agent-"

-- For stopping it there is no socket to signal, so this does match a command
-- line. Writing the pattern as `agent[.]py` means the shell running pkill --
-- whose own command line carries the brackets, not a literal dot -- cannot
-- match itself.
local KILL_PATTERN = "kwallet-nm-agent[.]py"

local status = {
  running = false,
  available = false,
  error = "",
  checkedAt = 0,
}

local starting = false

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function pluginDir()
  if type(noctalia.pluginDir) == "function" then
    return noctalia.pluginDir()
  end
  return noctalia.pluginDir
end

local function boolConfig(key, fallback)
  local v = noctalia.getConfig(key)
  if type(v) == "boolean" then
    return v
  end
  return fallback
end

local function stringConfig(key, fallback)
  local v = noctalia.getConfig(key)
  if type(v) == "string" and noctalia.string.trim(v) ~= "" then
    return noctalia.string.trim(v)
  end
  return fallback
end

-- Build the helper command line from the plugin settings.
local function agentCommand()
  local parts = {
    shellQuote(pluginDir() .. SCRIPT),
    "--identifier " .. shellQuote(IDENTIFIER),
    "--folder " .. shellQuote(stringConfig("folder_name", "Network Management")),
    "--app-id " .. shellQuote(stringConfig("app_id", "Noctalia KWallet Secrets")),
  }
  local wallet = stringConfig("wallet_name", "")
  if wallet ~= "" then
    table.insert(parts, "--wallet " .. shellQuote(wallet))
  end
  if boolConfig("handle_8021x", false) then
    table.insert(parts, "--with-8021x")
  end
  if not boolConfig("unlock_prompt", true) then
    table.insert(parts, "--no-unlock-prompt")
  end
  if boolConfig("debug_logging", false) then
    table.insert(parts, "--debug")
  end
  return table.concat(parts, " ")
end

local function publish()
  status.checkedAt = os.time()
  noctalia.state.set(STATE_KEY, status)
end

local function isRunning(callback)
  noctalia.runAsync(
    string.format("grep -q '%s'\"$(id -u)\"'$' /proc/net/unix && echo yes || echo no", LOCK),
    function(res)
      callback(noctalia.string.trim(res.stdout or "") == "yes")
    end,
    RUN_TIMEOUT_MS
  )
end

local function stopAgent(callback)
  noctalia.runAsync(
    string.format("pkill -u \"$(id -u)\" -f '%s' >/dev/null 2>&1; exit 0", KILL_PATTERN),
    function()
      status.running = false
      if callback then callback() end
    end,
    RUN_TIMEOUT_MS
  )
end

-- setsid detaches the helper from the shell noctalia spawns, so it outlives it;
-- systemd-cat routes its stdout/stderr into the journal under JOURNAL_TAG.
local function startAgent()
  if starting then return end
  starting = true
  local cmd = string.format(
    "(setsid systemd-cat -t %s %s </dev/null >/dev/null 2>&1 &) ; exit 0",
    JOURNAL_TAG, agentCommand()
  )
  noctalia.runAsync(cmd, function()
    starting = false
    status.running = true
    publish()
  end, RUN_TIMEOUT_MS)
end

local function preflight()
  if not noctalia.commandExists("python3") then
    status.error = noctalia.tr("errors.python_missing")
  elseif not noctalia.commandExists("pkill") then
    status.error = noctalia.tr("errors.procps_missing")
  elseif not noctalia.fileExists(pluginDir() .. SCRIPT) then
    status.error = noctalia.tr("errors.helper_missing")
  else
    status.error = ""
  end
  status.available = status.error == ""
  return status.available
end

function update()
  if not status.available then
    publish()
    return
  end
  isRunning(function(running)
    status.running = running
    if not running then
      noctalia.log("secret agent not running, starting it")
      startAgent()
    end
    publish()
  end)
end

function onConfigChanged()
  -- Settings become command-line flags, so the helper has to be replaced.
  if not preflight() then
    publish()
    return
  end
  stopAgent(function()
    startAgent()
  end)
end

if preflight() then
  noctalia.setUpdateInterval(CHECK_MS)
  update()
else
  noctalia.notifyError(noctalia.tr("title"), status.error)
  noctalia.log("disabled: " .. status.error)
  publish()
end
