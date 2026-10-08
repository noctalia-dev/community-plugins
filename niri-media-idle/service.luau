--!nonstrict

local STATUS_KEY = "niri_media_idle_status"
local COMMAND_KEY = "niri_media_idle_command"
local CONTROL_TIMEOUT_MS = 65000
local UNIT_STATES = { active = true, inactive = true, failed = true }
local PROTECTION_STATES = {
  unknown = true,
  normal = true,
  music_sleep = true,
  music_sleep_incomplete = true,
  protected = true,
  incomplete = true,
  loading = true,
}
local pluginDir = noctalia.pluginDir()
local controlPath = type(pluginDir) == "string" and pluginDir ~= ""
  and (pluginDir .. "/bridge-control.py") or nil

local status = {
  unitState = "unknown",
  protectionState = "unknown",
  busy = false,
  error = "",
  revision = 0,
}
local autoStartReconcilePending = false
local applyAutoStartPreference

local function reconcilePendingAutoStartPreference()
  if not autoStartReconcilePending or status.busy then return end
  autoStartReconcilePending = false
  applyAutoStartPreference(true)
end

local function publish()
  status.revision += 1
  noctalia.state.set(STATUS_KEY, {
    unitState = status.unitState,
    protectionState = status.protectionState,
    busy = status.busy,
    error = status.error,
    revision = status.revision,
  })
end

local function detailFrom(result)
  if type(result) == "table" then
    local detail = noctalia.string.trim(result.stderr or "")
    if detail ~= "" then return detail end
  end
  return noctalia.tr("error.command_failed")
end

local function fail(message, notifyUser, callback)
  status.unitState = "unknown"
  status.protectionState = "unknown"
  status.busy = false
  status.error = message
  publish()
  if notifyUser then
    noctalia.notifyError(noctalia.tr("title"), message)
  end
  if callback then callback(false) end
  reconcilePendingAutoStartPreference()
end

local function parseStatus(result)
  if type(result) ~= "table" or type(result.stdout) ~= "string" then
    return nil, nil
  end

  local output = noctalia.string.trim(result.stdout)
  local unitState, protectionState = output:match("^([%a]+)[ \t]+([%a_]+)$")
  if not unitState or not protectionState then
    return nil, nil
  end
  if not UNIT_STATES[unitState] or not PROTECTION_STATES[protectionState] then
    return nil, nil
  end
  if unitState ~= "active" and protectionState ~= "unknown" then
    return nil, nil
  end
  return unitState, protectionState
end

local function runControl(action, notifySuccess, notifyFailure, callback)
  if status.busy then
    if callback then callback(false) end
    return
  end
  if not controlPath then
    fail(noctalia.tr("error.plugin_directory"), notifyFailure, callback)
    return
  end

  status.busy = true
  status.error = ""
  publish()

  local started = noctalia.runAsync(
    { "python3", controlPath, action },
    function(result)
      if type(result) ~= "table" or result.exitCode ~= 0 then
        fail(detailFrom(result), notifyFailure, callback)
        return
      end

      local nextState, nextProtectionState = parseStatus(result)
      if not nextState then
        fail(noctalia.tr("error.unexpected_state"), notifyFailure, callback)
        return
      end

      status.unitState = nextState
      status.protectionState = nextProtectionState
      status.busy = false
      status.error = ""
      publish()

      if notifySuccess and action ~= "status" then
        local key = nextState == "active" and "started"
          or nextState == "failed" and "failed"
          or "stopped"
        noctalia.notify(
          noctalia.tr(`notification.{key}.title`),
          noctalia.tr(`notification.{key}.body`)
        )
      end
      if callback then callback(true) end
      reconcilePendingAutoStartPreference()
    end,
    CONTROL_TIMEOUT_MS
  )

  if not started then
    fail(noctalia.tr("error.command_not_started"), notifyFailure, callback)
  end
end

local function refresh()
  runControl("status", false, false)
end

applyAutoStartPreference = function(configChanged)
  if configChanged and status.busy then
    autoStartReconcilePending = true
    return
  end
  if configChanged then
    autoStartReconcilePending = false
  end

  if noctalia.getConfig("auto_start") ~= false then
    runControl("start", false, true)
  elseif configChanged then
    runControl("stop", false, true)
  else
    refresh()
  end
end

local function toggle()
  if status.busy then return end
  if status.unitState == "active" then
    runControl("stop", true, true)
  elseif status.unitState == "inactive" then
    runControl("start", true, true)
  else
    runControl("status", false, true, function(ok)
      if not ok then return end
      if status.unitState == "active" then
        runControl("stop", true, true)
      else
        runControl("start", true, true)
      end
    end)
  end
end

noctalia.state.watch(COMMAND_KEY, function(command)
  if type(command) ~= "table" then return end
  if command.action == "toggle" then
    toggle()
  elseif command.action == "start" then
    runControl("start", true, true)
  elseif command.action == "stop" then
    runControl("stop", true, true)
  elseif command.action == "refresh" or command.action == "status" then
    refresh()
  end
end)

noctalia.setUpdateInterval(5000)
applyAutoStartPreference(false)

function update()
  if not status.busy then refresh() end
end

function onConfigChanged()
  applyAutoStartPreference(true)
end

function onIpc(event, _payload)
  if event == "toggle" then
    toggle()
  elseif event == "start" then
    runControl("start", true, true)
  elseif event == "stop" then
    runControl("stop", true, true)
  elseif event == "refresh" or event == "status" then
    refresh()
  end
end

function onExit(_signal, reason)
  if reason == "reload" then return end
  if not controlPath then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("error.plugin_directory"))
    return
  end

  local started = noctalia.runAsync(
    { "python3", controlPath, "stop" },
    function(result)
      if type(result) ~= "table" or result.exitCode ~= 0 then
        noctalia.notifyError(noctalia.tr("title"), detailFrom(result))
      end
    end,
    CONTROL_TIMEOUT_MS
  )
  if not started then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("error.command_not_started"))
  end
end
