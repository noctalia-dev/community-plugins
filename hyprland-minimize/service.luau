--!nonstrict
-- Minimized-windows service (Hyprland).
--
-- Minimizing = moving the window to the special workspace "special:minimized". This service:
--   * keeps the list of windows that are there (most recently minimized first)
--     and publishes it to the shared state ("windows", as JSON) for the widget and the panel;
--   * runs the actions: minimize, restore, restore-last, restore-all.
--
-- Actions, from a Hyprland keybind (IPC):
--   noctalia msg plugin fr4j4/hyprland-minimize:service all minimize        (active window)
--   noctalia msg plugin fr4j4/hyprland-minimize:service all restore-last
--   noctalia msg plugin fr4j4/hyprland-minimize:service all restore <address>
--   noctalia msg plugin fr4j4/hyprland-minimize:service all restore-all
-- and from the widget or the panel, through the shared state "cmd".

local MIN_WS = "special:minimized"
local POLL_SAFETY_MS = 8000          -- safety re-read in case an event is missed

local windows = {}                   -- { { address, class, title }, ... } most recent first
local origins = {}                   -- address -> { id, name } of the workspace it came from
local refreshing = false
local dirty = false
local pendingAt = nil
local lastPoll = 0
local streamOk = false

-- ───────── helpers ─────────

local function hypr(args, cb)
  local argv = { "hyprctl" }
  for _, a in ipairs(args) do table.insert(argv, a) end
  return noctalia.runAsync(argv, cb, 4000)
end

local function dispatch(lua, cb)
  return hypr({ "dispatch", lua }, cb)
end

local function decode(text)
  if type(text) ~= "string" or text == "" then return nil end
  local value = noctalia.json.decode(text)
  return value
end

-- ───────── origins (persisted) ─────────

local originsFile = nil
do
  local dir = noctalia.pluginDataDir()
  if dir then originsFile = dir .. "/origins.json" end
end

local function loadOrigins()
  if not originsFile or not noctalia.fileExists(originsFile) then return end
  local text = noctalia.readFile(originsFile)
  local value = decode(text)
  if type(value) == "table" then origins = value end
end

local function saveOrigins()
  if not originsFile then return end
  local text = noctalia.json.encode(origins)
  if text then noctalia.writeFile(originsFile, text) end
end

-- ───────── minimized list ─────────

local lastPublished = nil

local function publish()
  local text = noctalia.json.encode(windows) or "[]"
  -- only when the list actually changed: every state change makes the widgets redraw
  if text ~= lastPublished then
    lastPublished = text
    noctalia.state.set("windows", text)
  end
end

local function entryOf(c)
  local cls = c["class"]
  if cls == nil or cls == "" then cls = c.initialClass or "" end
  return { address = c.address, class = cls, title = c.title or "" }
end

local function refresh()
  if refreshing then
    dirty = true
    return
  end
  refreshing = true
  hypr({ "clients", "-j" }, function(res)
    refreshing = false
    if res.exitCode == 0 then
      local data = decode(res.stdout)
      if type(data) == "table" then
        local present = {}
        for _, c in ipairs(data) do
          local ws = c.workspace
          if ws and ws.name == MIN_WS and c.mapped ~= false and c.address then
            present[c.address] = c
          end
        end

        local known = {}
        for _, w in ipairs(windows) do known[w.address] = true end

        local list = {}
        -- windows that just arrived go first
        for addr, c in pairs(present) do
          if not known[addr] then table.insert(list, entryOf(c)) end
        end
        -- windows that were already there keep their order
        for _, w in ipairs(windows) do
          local c = present[w.address]
          if c then table.insert(list, entryOf(c)) end
        end

        -- forget the origins of windows that no longer exist
        local alive = {}
        for _, c in ipairs(data) do if c.address then alive[c.address] = true end end
        local changed = false
        for addr in pairs(origins) do
          if not alive[addr] then
            origins[addr] = nil
            changed = true
          end
        end
        if changed then saveOrigins() end

        windows = list
        publish()
      end
    end
    if dirty then
      dirty = false
      refresh()
    end
  end)
end

local function requestRefresh(delayMs)
  pendingAt = noctalia.nowMs() + (delayMs or 80)
end

-- ───────── actions ─────────

local function minimizeWindow(win)
  local addr = win and win.address
  if type(addr) ~= "string" or addr == "" then return end
  local ws = win.workspace
  if ws and type(ws.name) == "string" and string.sub(ws.name, 1, 8) == "special:" then return end
  origins[addr] = { id = ws and ws.id or nil, name = ws and ws.name or nil }
  saveOrigins()
  dispatch(
    'hl.dsp.window.move({ workspace = "' .. MIN_WS .. '", follow = false, window = "address:' .. addr .. '" })',
    function() requestRefresh(60) end
  )
end

local function minimize()
  hypr({ "activewindow", "-j" }, function(res)
    if res.exitCode ~= 0 then return end
    local win = decode(res.stdout)
    if type(win) == "table" then minimizeWindow(win) end
  end)
end

local function moveAndFocus(addr, wsExpr)
  dispatch(
    'hl.dsp.window.move({ workspace = ' .. wsExpr .. ', follow = false, window = "address:' .. addr .. '" })',
    function()
      dispatch('hl.dsp.focus({ window = "address:' .. addr .. '" })', function() requestRefresh(60) end)
    end
  )
end

local function restore(addr)
  if type(addr) ~= "string" or addr == "" then return end
  local mode = noctalia.getConfig("restore_to") or "current"
  local o = origins[addr]
  if mode == "origin" and o and type(o.id) == "number" and o.id > 0 then
    origins[addr] = nil
    saveOrigins()
    moveAndFocus(addr, tostring(o.id))
    return
  end
  hypr({ "activeworkspace", "-j" }, function(res)
    if res.exitCode ~= 0 then return end
    local ws = decode(res.stdout)
    if type(ws) == "table" and ws.id then
      origins[addr] = nil
      saveOrigins()
      moveAndFocus(addr, tostring(ws.id))
    end
  end)
end

local function restoreLast()
  local w = windows[1]
  if w then restore(w.address) end
end

local function restoreAll()
  -- copy: the list changes while windows are being restored
  local addrs = {}
  for _, w in ipairs(windows) do table.insert(addrs, w.address) end
  for _, a in ipairs(addrs) do restore(a) end
end

local function handle(action, payload)
  if action == "minimize" then
    minimize()
  elseif action == "restore" then
    restore(payload)
  elseif action == "restore-last" then
    restoreLast()
  elseif action == "restore-all" then
    restoreAll()
  elseif action == "panel" then
    noctalia.togglePanel("fr4j4/hyprland-minimize:list")
  end
end

-- via IPC (Hyprland keybinds)
function onIpc(event, payload)
  handle(event, payload)
end

-- via the shared state (widget and panel); each command carries a number so the value always changes
noctalia.state.watch("cmd", function(value)
  local c = decode(value)
  if type(c) == "table" and c.action then handle(c.action, c.address) end
end)

-- ───────── Hyprland events ─────────

local function startStream()
  local runtime = noctalia.getenv("XDG_RUNTIME_DIR")
  local sig = noctalia.getenv("HYPRLAND_INSTANCE_SIGNATURE")
  if not runtime or not sig then return false end
  local sock = runtime .. "/hypr/" .. sig .. "/.socket2.sock"
  return noctalia.runStream("socat -u UNIX-CONNECT:" .. sock .. " - 2>/dev/null", function(line)
    -- only window changes matter
    if string.find(line, "^movewindowv2>>", 1) or string.find(line, "^openwindow>>", 1) or string.find(line, "^closewindow>>", 1) then
      requestRefresh(80)
    end
  end)
end

-- ───────── startup ─────────

loadOrigins()
streamOk = startStream() and true or false
refresh()

noctalia.setUpdateInterval(150)
function update()
  local now = noctalia.nowMs()
  if pendingAt and now >= pendingAt then
    pendingAt = nil
    lastPoll = now
    refresh()
    return
  end
  -- no event stream, or as a safety net: periodic re-read
  local every = streamOk and POLL_SAFETY_MS or 2000
  if now - lastPoll >= every then
    lastPoll = now
    refresh()
  end
end
