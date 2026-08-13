--!nonstrict
-- KineticWE layout bridge service.
--
-- Watches the compositor's /Tiling DBus interface (plus virtual-desktop
-- switches, which implicitly change the "current" layout) and publishes a
-- single plain-data table on noctalia.state key "layout" for the widget and
-- panel entries:
--
--   { ok = true,  current = "Columns", enabled = { "MasterStack", ... },
--     qdbus = "qdbus-qt6" }
--   { ok = false, reason = "missing-qdbus" | "missing-monitor" | "missing-interface" }
--
-- "current" is the kind string for the active output's current desktop, or
-- "" when native tiling is disabled.

local KINDS = {
  MasterStack = true,
  Stacked = true,
  CenterTile = true,
  Monocle = true,
  AutoGrid = true,
  Columns = true,
}

local QDBUS = nil
local refreshing = false
local refreshQueued = false
local lastPublished = nil

local function findQdbus()
  for _, name in ipairs({ "qdbus-qt6", "qdbus6", "qdbus" }) do
    if noctalia.commandExists(name) then
      return name
    end
  end
  return nil
end

local function publish(state)
  noctalia.state.set("layout", state)
  lastPublished = state
end

-- qdbus prints a QStringList reply as { "MasterStack", "Stacked", ... }.
-- Some builds print bare words instead, so fall back to word splitting and
-- keep only tokens that are real layout kinds.
local function parseKindList(out)
  local items, seen = {}, {}
  local function add(s)
    if KINDS[s] and not seen[s] then
      seen[s] = true
      table.insert(items, s)
    end
  end
  for s in string.gmatch(out, '"([^"]+)"') do
    add(s)
  end
  if #items == 0 then
    for s in string.gmatch(out, "[%a]+") do
      add(s)
    end
  end
  return items
end

local function finishRefresh()
  refreshing = false
  if refreshQueued then
    refreshQueued = false
    refresh()
  end
end

function refresh()
  if refreshing then
    -- Coalesce signal bursts (e.g. one per desktop on a reconcile pass)
    -- into a single follow-up query.
    refreshQueued = true
    return
  end
  refreshing = true

  if QDBUS == nil then
    QDBUS = findQdbus()
    if QDBUS == nil then
      publish({ ok = false, reason = "missing-qdbus" })
      finishRefresh()
      return
    end
  end

  noctalia.runAsync(QDBUS .. " org.kde.KWin /Tiling org.kde.KWin.Tiling.currentLayout", function(res)
    if res.exitCode ~= 0 then
      publish({ ok = false, reason = "missing-interface" })
      finishRefresh()
      return
    end
    local current = noctalia.string.trim(res.stdout)
    noctalia.runAsync(QDBUS .. " org.kde.KWin /Tiling org.kde.KWin.Tiling.enabledLayouts", function(res2)
      if res2.exitCode ~= 0 then
        publish({ ok = false, reason = "missing-interface" })
        finishRefresh()
        return
      end
      local enabled = parseKindList(res2.stdout)
      local unchanged = lastPublished
        and lastPublished.ok
        and lastPublished.current == current
        and table.concat(lastPublished.enabled, ",") == table.concat(enabled, ",")
      if not unchanged then
        publish({ ok = true, current = current, enabled = enabled, qdbus = QDBUS })
      end
      finishRefresh()
    end)
  end)
end

local function onMonitorLine(line)
  -- Any of: member=layoutChanged, member=enabledLayoutsChanged,
  -- member=currentChanged (desktop switch). Re-query rather than parse
  -- arguments: it is cheap and always yields a consistent snapshot.
  if string.find(line, "member=") then
    refresh()
  end
end

local function startMonitor()
  if not noctalia.commandExists("dbus-monitor") then
    noctalia.log("dbus-monitor not found; falling back to polling only")
    return
  end
  noctalia.runStream(
    "dbus-monitor --session"
      .. " \"type='signal',interface='org.kde.KWin.Tiling'\""
      .. " \"type='signal',interface='org.kde.KWin.VirtualDesktopManager',member='currentChanged'\"",
    onMonitorLine
  )
end

-- Startup: query immediately, then keep a slow poll as a self-healing net
-- (recovers when the monitor dies or the compositor gains /Tiling after a
-- rebuild). Signal-driven refreshes make updates feel instant.
refresh()
startMonitor()
noctalia.setUpdateInterval(5000)

function update()
  refresh()
end
