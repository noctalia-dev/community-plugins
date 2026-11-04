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

-- Everything that ends up inside a Hyprland Lua expression or a shell command is validated first: window
-- addresses arrive from IPC (any local process can send them) and titles/classes are chosen by the apps.
local function validAddr(a)
  return type(a) == "string" and #a <= 20 and string.match(a, "^0x%x+$") ~= nil
end

-- Workspace id as a plain decimal integer, or nil.
local function wsId(n)
  if type(n) ~= "number" or n ~= n or n < 1 or n > 2147483647 or n ~= math.floor(n) then return nil end
  return string.format("%d", n)
end

-- Text from an app (title, class): no control characters, bounded length.
local function clean(text, max)
  if type(text) ~= "string" then return "" end
  text = string.gsub(text, "%c", " ")
  if #text > max then
    local cut = utf8.offset(text, max + 1) or (max + 1)
    text = string.sub(text, 1, cut - 1)
  end
  return text
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
  if type(value) ~= "table" then return end
  -- the file is only trusted for well-formed entries
  for addr, o in pairs(value) do
    if validAddr(addr) and type(o) == "table" then
      origins[addr] = { id = wsId(o.id) and o.id or nil, name = type(o.name) == "string" and clean(o.name, 100) or nil }
    end
  end
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
  -- the class is used to look up an icon: keep it from being a path
  cls = string.gsub(clean(cls, 100), "[/\\]", "")
  return { address = c.address, class = cls, title = clean(c.title, 200) }
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
          if ws and ws.name == MIN_WS and c.mapped ~= false and validAddr(c.address) then
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
  if not validAddr(addr) then return end
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
  if not validAddr(addr) or not wsId(tonumber(wsExpr)) then return end
  dispatch(
    'hl.dsp.window.move({ workspace = ' .. wsExpr .. ', follow = false, window = "address:' .. addr .. '" })',
    function()
      dispatch('hl.dsp.focus({ window = "address:' .. addr .. '" })', function() requestRefresh(60) end)
    end
  )
end

local closeOverlayAt = nil

local function isMinimized(addr)
  for _, w in ipairs(windows) do
    if w.address == addr then return true end
  end
  return false
end

local function restore(addr)
  -- only well-formed addresses of windows that are really minimized (not any window of the session)
  if not validAddr(addr) or not isMinimized(addr) then return end
  local mode = noctalia.getConfig("restore_to") or "current"
  local o = origins[addr]
  if mode == "origin" and o and wsId(o.id) then
    origins[addr] = nil
    saveOrigins()
    moveAndFocus(addr, wsId(o.id))
    return
  end
  hypr({ "activeworkspace", "-j" }, function(res)
    if res.exitCode ~= 0 then return end
    local ws = decode(res.stdout)
    if type(ws) == "table" and wsId(ws.id) then
      origins[addr] = nil
      saveOrigins()
      moveAndFocus(addr, wsId(ws.id))
    end
  end)
end

-- Hyprland shows the special workspace as an overlay whenever one of its windows is focused. After the
-- window has been moved out, close the overlay if it is still open (other windows may remain in it).
local function closeOverlay()
  hypr({ "monitors", "-j" }, function(res)
    if res.exitCode ~= 0 then return end
    local list = decode(res.stdout)
    if type(list) ~= "table" then return end
    for _, m in ipairs(list) do
      local sp = m.specialWorkspace
      if type(sp) == "table" and sp.name == MIN_WS then
        dispatch('hl.dsp.workspace.toggle_special("minimized")')
        return
      end
    end
  end)
end

-- A minimized window got focus from outside (window switcher, launcher, a click on a notification...):
-- treat it as a restore, so the user does not end up looking at the special workspace.
local lastFocusRestore = nil

local function onFocused(addr)
  if noctalia.getConfig("restore_on_focus") == false then return end
  if not validAddr(addr) or not isMinimized(addr) then return end
  local now = noctalia.nowMs()
  -- once the focused window has left the overlay, Hyprland focuses the next one inside it: that is not a
  -- request from the user, so a burst of focus events restores only the first window
  if lastFocusRestore and now - lastFocusRestore < 1200 then return end
  lastFocusRestore = now
  restore(addr)
  -- give restore() time to move the window before checking the overlay
  closeOverlayAt = now + 400
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
  -- the path goes into a shell command and into a socat address (where "," and ":" are separators):
  -- anything unusual is refused and the service falls back to polling
  if not string.match(sock, "^[%w%._/%-]+$") then return false end
  return noctalia.runStream("socat -u UNIX-CONNECT:" .. sock .. " - 2>/dev/null", function(line)
    -- only window changes matter
    local focused = string.match(line, "^activewindowv2>>(%x+)$")
    if focused then onFocused("0x" .. focused) end
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
  if closeOverlayAt and now >= closeOverlayAt then
    closeOverlayAt = nil
    closeOverlay()
  end
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
