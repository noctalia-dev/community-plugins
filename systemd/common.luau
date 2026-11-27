--!nonstrict
-- Shared systemctl helpers for the launcher provider, the bar widget, its controls
-- panel and the action service, so every entry runs and reports actions the same way.

local M = {}

M.PANEL_ID = "srounce/systemd:controls"

M.VERB_GLYPH = {
  start = "player-play",
  stop = "player-stop",
  restart = "refresh",
}

local tr = noctalia.tr
local trim = noctalia.string.trim

M.tr = tr
M.trim = trim

-- argv for an action on a unit; system units get the configured wrapper (e.g. "sudo -n").
function M.systemctlArgv(scope, ...)
  local argv = {}
  if scope == "system" then
    local wrapper = noctalia.getConfig("system_wrapper")
    if type(wrapper) == "string" then
      for word in string.gmatch(wrapper, "%S+") do
        table.insert(argv, word)
      end
    end
  end
  table.insert(argv, "systemctl")
  if scope == "user" then
    table.insert(argv, "--user")
  end
  for _, arg in { ... } do
    table.insert(argv, arg)
  end
  return argv
end

function M.scopeLabel(scope)
  return tr("launcher.scope." .. scope)
end

-- Whether a unit in this ActiveState offers Stop/Restart rather than Start.
function M.isRunning(active)
  return active == "active" or active == "activating" or active == "reloading"
end

local function reportState(verb, scope, name)
  noctalia.runAsync(M.systemctlArgv(scope, "is-active", name), function(result)
    local state = trim(result.stdout)
    if state == "" then
      state = "unknown"
    end
    noctalia.notify(
      tr("launcher.action." .. verb, { unit = name }),
      tr("notify.state", { scope = M.scopeLabel(scope), state = state })
    )
  end)
end

-- Runs `systemctl <verb> <name>` and notifies with the unit's new state, or the error.
-- onDone(ok) fires once the action has finished (or failed to launch).
function M.runAction(verb, scope, name, onDone)
  local ok = noctalia.runAsync(M.systemctlArgv(scope, verb, name), function(result)
    local success = result.exitCode == 0
    if success then
      reportState(verb, scope, name)
    else
      noctalia.notifyError(tr("notify.failed", { verb = verb, unit = name }), trim(result.stderr))
    end
    if onDone then
      onDone(success)
    end
  end)
  if not ok then
    noctalia.notifyError(tr("notify.launch-failed"))
    if onDone then
      onDone(false)
    end
  end
end

-- Reads a unit's state. Read-only, so it never goes through the system wrapper.
-- onResult receives { load, active, sub, description }, or nil when systemctl failed.
function M.queryUnit(scope, name, onResult)
  local argv = { "systemctl" }
  if scope == "user" then
    table.insert(argv, "--user")
  end
  for _, arg in { "show", "--property=LoadState,ActiveState,SubState,Description", "--", name } do
    table.insert(argv, arg)
  end
  return noctalia.runAsync(argv, function(result)
    if result.exitCode ~= 0 then
      onResult(nil)
      return
    end
    local props = {}
    for line in string.gmatch(result.stdout, "[^\n]+") do
      local key, value = string.match(line, "^(%w+)=(.*)$")
      if key ~= nil then
        props[key] = value
      end
    end
    onResult({
      load = props.LoadState or "",
      active = props.ActiveState or "",
      sub = props.SubState or "",
      description = props.Description or "",
    })
  end, 5000)
end

-- Glyph and color role for a queried state: filled circle when active, empty when not.
function M.stateIcon(status)
  if status == nil then
    return "circle-dashed", "on_surface_variant"
  elseif status.load == "not-found" then
    return "circle-dashed", "error"
  elseif status.active == "active" then
    return "circle-filled", "primary"
  elseif status.active == "failed" then
    return "circle-x", "error"
  elseif status.active == "activating" or status.active == "deactivating" or status.active == "reloading" then
    return "circle-dot", "tertiary"
  end
  return "circle", "on_surface_variant"
end

function M.stateText(status)
  if status == nil then
    return tr("state.unknown")
  elseif status.load == "not-found" then
    return tr("state.not-found")
  elseif status.sub ~= "" and status.sub ~= status.active then
    return `{status.active} ({status.sub})`
  end
  return status.active
end

return M
