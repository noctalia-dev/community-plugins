--!nonstrict
-- Owns the systemd inhibitor. Widgets and shortcuts communicate with this
-- singleton through noctalia.state.

local UNIT = "noctalia-lid-guard.service"
local CHECK_COMMAND = `systemctl --user is-active --quiet {UNIT}`
local START_COMMAND = `systemctl --user reset-failed {UNIT} >/dev/null 2>&1 || true; ` .. table.concat({
  `systemd-run --user --quiet --collect --unit={UNIT}`,
  `--description='Noctalia Lid Guard'`,
  `systemd-inhibit --what=handle-lid-switch`,
  `--who='Noctalia Lid Guard'`,
  `--why='Keep background jobs running while the laptop lid is closed'`,
  `--mode=block sleep infinity`,
}, " ")
local STOP_COMMAND = `systemctl --user stop {UNIT}`

local active = false
local busy = false
local available = noctalia.commandExists("systemctl")
  and noctalia.commandExists("systemd-run")
  and noctalia.commandExists("systemd-inhibit")
  and noctalia.commandExists("sleep")
local revision = 0

local function publish(errorMessage)
  revision += 1
  noctalia.state.set("lid_guard_status", {
    active = active,
    busy = busy,
    available = available,
    error = errorMessage or "",
    revision = revision,
  })
end

local function refresh(callback)
  if not available then
    active = false
    publish(noctalia.tr("error.missing_dependencies"))
    if callback then callback(false) end
    return
  end

  noctalia.runAsync(CHECK_COMMAND, function(result)
    active = result.exitCode == 0
    publish()
    if callback then callback(active) end
  end)
end

local function finishToggle(expectedActive, result)
  if result.exitCode ~= 0 then
    busy = false
    local detail = noctalia.string.trim(result.stderr or "")
    if detail == "" then detail = noctalia.tr("error.command_failed") end
    publish(detail)
    noctalia.notifyError(noctalia.tr("title"), detail)
    return
  end

  refresh(function(currentActive)
    busy = false
    active = currentActive
    publish()

    if currentActive ~= expectedActive then
      noctalia.notifyError(noctalia.tr("title"), noctalia.tr("error.state_mismatch"))
    elseif currentActive then
      noctalia.notify(noctalia.tr("notification.enabled.title"), noctalia.tr("notification.enabled.body"))
    else
      noctalia.notify(noctalia.tr("notification.disabled.title"), noctalia.tr("notification.disabled.body"))
    end
  end)
end

local function setActive(nextActive)
  if busy or not available then return end
  busy = true
  publish()

  if nextActive then
    noctalia.runAsync(START_COMMAND, function(result)
      finishToggle(true, result)
    end)
  else
    noctalia.runAsync(STOP_COMMAND, function(result)
      finishToggle(false, result)
    end)
  end
end

noctalia.state.watch("lid_guard_command", function(command)
  if type(command) ~= "table" then return end

  if command.action == "toggle" then
    refresh(function(currentActive)
      setActive(not currentActive)
    end)
  elseif command.action == "enable" then
    setActive(true)
  elseif command.action == "disable" then
    setActive(false)
  elseif command.action == "refresh" then
    refresh()
  end
end)

noctalia.setUpdateInterval(5000)
refresh()

function update()
  if not busy then refresh() end
end

function onIpc(event, _payload)
  if event == "toggle" then
    refresh(function(currentActive)
      setActive(not currentActive)
    end)
  elseif event == "enable" then
    setActive(true)
  elseif event == "disable" then
    setActive(false)
  elseif event == "refresh" or event == "status" then
    refresh()
  end
end
