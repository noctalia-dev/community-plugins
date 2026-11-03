--!nonstrict
-- Scroll indicator: on a workspace using Hyprland's scrolling layout, shows one dot per
-- column (● = focused column, ○ = others). Hidden on every other layout.
-- Idea from jtams/waybar-hyprland-scroll-indicator (Go/Waybar); independent Luau implementation.

-- One shell call returns [activeworkspace, activewindow, clients] as a JSON array.
local QUERY = { "sh", "-c",
  "printf '['; hyprctl -j activeworkspace; printf ','; hyprctl -j activewindow; printf ','; hyprctl -j clients; printf ']'" }

-- Hyprland event socket, so the dots update the moment focus changes.
local EVENTS = "socat -U - UNIX-CONNECT:\"$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock\""

local busy = false
local pending = false
local streaming = false

local function hide()
  barWidget.setVisible(false)
end

local function show(ws, active, clients)
  if not ws or ws.tiledLayout ~= "scrolling" then
    hide()
    return
  end

  -- Tiled, visible windows on this workspace; windows stacked in one column share an x.
  local xs, seen = {}, {}
  local activeX = nil
  for _, c in ipairs(clients or {}) do
    -- Hyprland 0.56 identifies workspaces by address/name (no numeric id in clients JSON)
    if c.workspace and c.workspace.name == ws.name and not c.floating and c.mapped and not c.hidden then
      local x = c.at and c.at[1] or 0
      if not seen[x] then
        seen[x] = true
        table.insert(xs, x)
      end
      if active and c.address == active.address then
        activeX = x
      end
    end
  end
  table.sort(xs)

  if #xs == 0 then
    hide()
    return
  end

  local dots, idx = {}, nil
  for i, x in ipairs(xs) do
    if x == activeX then
      idx = i
      table.insert(dots, "●")
    else
      table.insert(dots, "○")
    end
  end

  barWidget.setText(table.concat(dots, " "))
  barWidget.setTooltip(string.format("Scrolling: column %s of %d", idx and tostring(idx) or "?", #xs))
  barWidget.setVisible(true)
end

local function refresh()
  if busy then
    pending = true
    return
  end
  busy = true
  noctalia.runAsync(QUERY, function(result)
    busy = false
    if result.exitCode == 0 then
      local d = noctalia.json.decode(result.stdout)
      if d then
        show(d[1], d[2], d[3])
      end
    end
    if pending then
      pending = false
      refresh()
    end
  end)
end

-- Event names from socket2 that can change which column is focused or how many there are.
local RELEVANT = {
  activewindowv2 = true, workspacev2 = true, openwindow = true, closewindow = true,
  movewindowv2 = true, changefloatingmode = true, focusedmonv2 = true, fullscreen = true,
}

local function startEvents()
  if not noctalia.commandExists("socat") then
    noctalia.log("scroll-indicator: socat not found, polling only")
    return
  end
  local ok, err = pcall(function()
    noctalia.runStream(EVENTS, function(data)
      -- Callback may receive a line string or a table; handle both, and multi-line chunks.
      local text = type(data) == "string" and data
        or (type(data) == "table" and (data.line or data.stdout or data.data)) or ""
      for ev in text:gmatch("(%w+)>>") do
        if RELEVANT[ev] then
          refresh()
          return
        end
      end
    end)
  end)
  streaming = ok
  if not ok then
    noctalia.log("scroll-indicator: event stream unavailable (" .. tostring(err) .. "), polling only")
  end
end

hide()
startEvents()

function update()
  -- Events drive updates; polling is a slow safety net (fast if events failed to start).
  noctalia.setUpdateInterval(streaming and 2000 or 400)
  refresh()
end
