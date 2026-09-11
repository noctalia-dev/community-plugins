--!nonstrict
-- Monitor Control service - the only entry that talks to the compositor or the
-- Umbriel config file.
--
-- Reads the display inventory with `umbriel outputs --json`, and applies a
-- change by patching the matching [output.*] section in the config file, then
-- `umbriel validate` against the patched copy and `umbriel msg config-reload`
-- on success. A failed validate restores the previous file, so a bad edit can
-- never take the session's config down. Because the change lands in the
-- config file itself, it survives reboots by definition.
--
--   noctalia.state.set("monitor.state", snapshot)    UI entries render this
--   noctalia.state.watch("monitor.request", handler)  actions from bar/panel
--
-- Both halves of availability matter: the socket variable proves this is an
-- Umbriel session, the binary is what the service actually runs.

local config = require("./config.luau")
local layout = require("./layout.luau")

local VALIDATE_TIMEOUT_MS = 5000
local SETTLE_MS = 800

local available = noctalia.getenv("UMBRIEL_SOCKET") ~= nil and noctalia.commandExists("umbriel")

local configPath = noctalia.getConfig("config_path")
if type(configPath) ~= "string" or configPath == "" then
  configPath = "~/.config/umbriel/config.toml"
end
configPath = noctalia.expandPath(configPath)

local outputs = {}
local busy = false
local lastError = nil

local function publish()
  noctalia.state.set("monitor.state", {
    available = available,
    outputs = outputs,
    busy = busy,
    error = lastError,
    config_path = configPath,
    focused = noctalia.focusedOutputName(),
    now = os.time(),
  })
end

-- ── inventory ────────────────────────────────────────────────────────────────

local function afterReload(result)
  if result.exitCode ~= 0 then
    noctalia.notifyError(noctalia.tr("notify.reload_failed"), noctalia.string.trim(result.stderr))
  end
  -- The compositor re-modes asynchronously after reload; give it a beat so the
  -- refreshed snapshot reports the new current mode, not the old one.
  noctalia.runAsync({ "sh", "-c", string.format("sleep %.1f; umbriel outputs --json", SETTLE_MS / 1000) }, function(inv)
    local decoded = inv.exitCode == 0 and noctalia.json.decode(inv.stdout) or nil
    if type(decoded) == "table" then
      outputs = decoded
    end
    busy = false
    lastError = nil
    publish()
  end, VALIDATE_TIMEOUT_MS + 2000)
end

local function refresh()
  if not available then
    return
  end
  noctalia.runAsync({ "umbriel", "outputs", "--json" }, function(result)
    if result.exitCode ~= 0 or result.timedOut then
      lastError = noctalia.string.trim(result.stderr)
      publish()
      return
    end
    local decoded = noctalia.json.decode(result.stdout)
    if type(decoded) ~= "table" then
      lastError = noctalia.tr("error.parse_failed")
      publish()
      return
    end
    outputs = decoded
    lastError = nil
    publish()
  end, VALIDATE_TIMEOUT_MS)
end

-- ── config writes ────────────────────────────────────────────────────────────

local function dataFile(name)
  local dir = noctalia.pluginDataDir()
  return dir ~= nil and (dir .. "/" .. name) or nil
end

-- Patch [output.<name>] in the config, gate on `umbriel validate`, reload.
-- A validate failure restores the previous file byte-for-byte.
local function applyConfig(name, fields)
  local text = noctalia.readFile(configPath)
  if text == nil then
    return false, "cannot read " .. configPath
  end

  local patched, reason = config.patchConfig(text, name, fields)
  if patched == nil then
    return false, reason or "could not patch config"
  end

  -- Best-effort rolling backup for the revert action; the restore path on a
  -- rejected validate uses the in-memory copy instead, so a nil data dir or a
  -- failed backup write can never strand an invalid config on disk.
  local backup = dataFile("config.toml.bak")
  if backup ~= nil then
    noctalia.writeFile(backup, text)
  end

  local written, writeErr = noctalia.writeFile(configPath, patched)
  if not written then
    return false, writeErr or "cannot write config"
  end

  noctalia.runAsync({ "umbriel", "validate", "-c", configPath }, function(result)
    if result.exitCode ~= 0 or result.timedOut then
      -- Restore byte-for-byte from memory: no backup-file dependency at all.
      local restored, restoreErr = noctalia.writeFile(configPath, text)
      busy = false
      refresh()
      local detail = noctalia.string.trim(result.stderr)
      if detail == "" then
        detail = noctalia.string.trim(result.stdout)
      end
      if restored == false and restoreErr ~= nil then
        detail = (detail ~= "" and detail .. " — " or "") .. "restore failed: " .. restoreErr
      end
      noctalia.notifyError(noctalia.tr("notify.validate_failed"), detail ~= "" and detail or nil)
      return
    end

    if noctalia.getConfig("auto_reload") == false then
      busy = false
      publish()
      noctalia.notify(noctalia.tr("notify.saved_no_reload"))
      return
    end

    noctalia.runAsync({ "umbriel", "msg", "config-reload" }, afterReload, VALIDATE_TIMEOUT_MS)
  end, VALIDATE_TIMEOUT_MS)

  return true
end

-- ── placement geometry ───────────────────────────────────────────────────────

-- side: "left" | "right" | "up" | "down" - dock the named output on that side of
-- the other enabled outputs: it lands just outside their edge, level with them
-- on the other axis (see layout.dock, which holds the maths and its tests).
local function arrangeFields(name, side)
  local target = nil
  local neighbours = {}
  for _, output in ipairs(outputs) do
    if output.name == name then
      target = output
    elseif output.enabled == true then
      table.insert(neighbours, output)
    end
  end
  if target == nil then
    return nil, "unknown output"
  end
  local w, h = layout.logicalSize(target)
  if w == nil then
    return nil, name .. ": no active mode"
  end

  local position = target.position or {}
  return layout.dock({
    x = position.x or 0,
    y = position.y or 0,
    w = w,
    h = h,
  }, layout.rects(neighbours), side)
end

-- ── request handling ─────────────────────────────────────────────────────────

local function handleRequest(value)
  if type(value) ~= "table" or not available then
    return
  end
  if value.action == "refresh" then
    refresh()
    return
  end
  if busy then
    return
  end

  local fields, action = nil, value.action
  if action == "set-mode" and type(value.mode) == "string" then
    fields = { mode = value.mode }
  elseif action == "place" and type(value.name) == "string" then
    -- Exact position typed in the panel. Validated here as well as there, since
    -- the same request can arrive over IPC without the panel involved.
    local x, xReason = layout.coordinate(value.x)
    local y, yReason = layout.coordinate(value.y)
    if x == nil or y == nil then
      noctalia.notifyError(noctalia.tr("notify.apply_failed"), tostring(xReason or yReason))
      return
    end
    fields = { x = x, y = y }
  elseif action == "arrange" then
    local placed, reason = arrangeFields(value.name, value.side)
    if placed == nil then
      noctalia.notifyError(noctalia.tr("notify.apply_failed"), tostring(reason))
      return
    end
    fields = placed
  elseif action == "reload" then
    noctalia.runAsync({ "umbriel", "msg", "config-reload" }, function(result)
      if result.exitCode ~= 0 then
        noctalia.notifyError(noctalia.tr("notify.reload_failed"), noctalia.string.trim(result.stderr))
      end
      refresh()
    end, VALIDATE_TIMEOUT_MS)
    return
  elseif action == "revert" then
    local backup = dataFile("config.toml.bak")
    local original = backup ~= nil and noctalia.readFile(backup) or nil
    if original == nil then
      noctalia.notifyError(noctalia.tr("notify.revert_failed"))
      return
    end
    busy = true
    publish()
    noctalia.runAsync({ "umbriel", "validate", "-c", backup }, function(check)
      if check.exitCode ~= 0 then
        busy = false
        refresh()
        noctalia.notifyError(noctalia.tr("notify.validate_failed"))
        return
      end
      noctalia.writeFile(configPath, original)
      noctalia.runAsync({ "umbriel", "msg", "config-reload" }, afterReload, VALIDATE_TIMEOUT_MS)
    end, VALIDATE_TIMEOUT_MS)
    return
  else
    return
  end

  busy = true
  publish()
  local ok, reason = applyConfig(value.name, fields)
  if not ok then
    busy = false
    lastError = reason
    publish()
    noctalia.notifyError(noctalia.tr("notify.apply_failed"), tostring(reason))
  end
end

noctalia.state.watch("monitor.request", handleRequest)

-- CLI surface, mirroring the state channel so a request is testable without
-- the panel:  noctalia msg plugin muhammadessam/umbriel-monitor-control:service all request '<json>'
function onIpc(event, payload)
  if event ~= "request" or type(payload) ~= "string" then
    return
  end
  local value = noctalia.json.decode(payload)
  if type(value) == "table" then
    handleRequest(value)
  end
end

-- Geometry and inventory changes (hotplug, another tool over the
-- wlr-output-management protocol) all land here, so the panel never shows a
-- stale layout the user might edit against.
function onOutputsChanged()
  refresh()
end

-- state.watch does not replay an old value to a late-attaching entry, so a
-- bar widget that loads after the last publish would stay hidden. Re-hand
-- the snapshot on a slow tick: an in-memory republish, no subprocess.
noctalia.setUpdateInterval(3000)

function update()
  publish()
end

publish()
refresh()
