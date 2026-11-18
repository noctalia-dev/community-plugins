--!nonstrict
-- This entry observes the backend; it never owns or stops SSH processes.
local cli = noctalia.expandPath("~/.local/bin/portforward")
local reading = false
local busy = false
local lastRequest = nil
local preparing = true
local setupError = nil
local backendWarning = nil
local prepare
noctalia.setUpdateInterval(2000)

local function publishError(message)
  noctalia.state.set("snapshot", { profiles = {}, error = message })
end

local function refresh()
  if reading or busy or preparing then return end
  if not noctalia.fileExists(cli) then
    publishError(noctalia.tr("backend.missing"))
    return
  end
  reading = true
  local accepted = noctalia.runAsync({ cli, "status" }, function(result)
    reading = false
    if result.exitCode ~= 0 then
      publishError(result.stderr ~= "" and result.stderr or noctalia.tr("backend.failed"))
      return
    end
    local value, err = noctalia.json.decode(result.stdout)
    if value == nil or type(value.profiles) ~= "table" then
      publishError(err or noctalia.tr("backend.invalid"))
      return
    end
    value.error = setupError or backendWarning
    noctalia.state.set("snapshot", value)
  end)
  if not accepted then
    reading = false
    publishError(noctalia.tr("backend.failed"))
  end
end

noctalia.state.watch("request", function(request)
  if request == nil or request.token == lastRequest or busy then return end
  lastRequest = request.token
  if preparing or setupError then
    noctalia.state.set("result", { token = request.token, ok = false,
      error = setupError or noctalia.tr("backend.preparing") })
    return
  end
  busy = true
  noctalia.state.set("busy", true)
  local argv = { cli }
  for _, arg in ipairs(request.args) do table.insert(argv, arg) end
  local function finished(ok, error)
    busy = false
    noctalia.state.set("busy", false)
    noctalia.state.set("result", { token = request.token, ok = ok, error = error })
    if backendWarning and request.args[1] == "disconnect" then prepare() else refresh() end
  end
  local accepted = noctalia.runAsync(argv, function(result)
    finished(result.exitCode == 0, result.stderr or "")
  end)
  if not accepted then finished(false, noctalia.tr("backend.failed")) end
end)

noctalia.state.watch("refresh", function() refresh() end)
function update() refresh() end

-- Normal startup and source reload both check setup; onEnable alone misses them.
prepare = function()
  preparing = true
  noctalia.state.set("snapshot", { profiles = {}, error = noctalia.tr("backend.preparing") })
  local accepted = noctalia.runAsync({ "python3", noctalia.pluginDir() .. "/backend/bootstrap.py" }, function(result)
    preparing = false
    if result.exitCode ~= 0 then
      setupError = result.stderr ~= "" and result.stderr or noctalia.tr("backend.failed")
      publishError(setupError)
      return
    end
    local value = noctalia.json.decode(result.stdout)
    if value == nil or type(value.cli) ~= "string" then
      setupError = noctalia.tr("backend.invalid")
      publishError(setupError)
      return
    end
    cli = value.cli
    setupError = nil
    backendWarning = value.warning
    refresh()
  end)
  if not accepted then
    preparing = false
    setupError = noctalia.tr("backend.failed")
    publishError(setupError)
  end
end

prepare()
