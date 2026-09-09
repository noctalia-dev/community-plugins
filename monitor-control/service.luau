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

local function hzText(refreshMhz)
  return config.hzText(refreshMhz)
end

local function currentMode(output)
  for _, mode in ipairs(output.modes or {}) do
    if mode.current == true then
      return mode
    end
  end
  return nil
end

-- Logical extent of an output in layout coordinates: the current mode size,
-- swapped for 90/270 transforms and divided by the scale.
local function logicalSize(output)
  local mode = currentMode(output)
  if mode == nil then
    return nil
  end
  local w, h = mode.width, mode.height
  local transform = output.transform or "normal"
  if transform == "90" or transform == "270" then
    w, h = h, w
  end
  local scale = (type(output.scale) == "number" and output.scale > 0) and output.scale or 1.0
  return math.floor(w / scale + 0.5), math.floor(h / scale + 0.5)
end

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
  local backup = dataFile("config.toml.monitor-control.bak")
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

-- side: "left" | "right" | "up" | "down" - place the named output at that end
-- of the arrangement, against the outer edge of the other enabled outputs,
-- keeping its cross-axis position. An output standing alone returns to origin.
local function arrangeFields(name, side)
  local target = nil
  local others = {}
  for _, output in ipairs(outputs) do
    if output.name == name then
      target = output
    elseif output.enabled == true then
      table.insert(others, output)
    end
  end
  if target == nil then
    return nil, "unknown output"
  end
  local w, h = logicalSize(target)
  if w == nil then
    return nil, name .. ": no active mode"
  end

  local x, y = target.position.x, target.position.y
  if #others == 0 then
    x, y = 0, 0
  else
    local minX, maxRight, minY, maxBottom = math.huge, -math.huge, math.huge, -math.huge
    for _, other in ipairs(others) do
      local ow, oh = logicalSize(other)
      ow = ow or other.width or 0
      oh = oh or other.height or 0
      local pos = other.position or { x = 0, y = 0 }
      minX = math.min(minX, pos.x)
      maxRight = math.max(maxRight, pos.x + ow)
      minY = math.min(minY, pos.y)
      maxBottom = math.max(maxBottom, pos.y + oh)
    end
    if side == "left" then
      x, y = minX - w, y
    elseif side == "right" then
      x, y = maxRight, y
    elseif side == "up" then
      x, y = x, minY - h
    elseif side == "down" then
      x, y = x, maxBottom
    else
      return nil, "unknown side"
    end
  end
  return { x = x, y = y }
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
    local backup = dataFile("config.toml.monitor-control.bak")
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
-- the panel:  noctalia msg plugin muhammadessam/monitor-control:service all request '<json>'
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
