--!nonstrict

local layouts = { "dwindle", "master", "monocle", "scrolling" }

noctalia.setUpdateInterval(1000)

local lastLayout = nil

local function setLayoutCmd(layout)
  local lua = string.format(
    "local w = hl.get_active_special_workspace() or hl.get_active_workspace(); "
      .. "if w then if w.special then hl.workspace_rule({workspace = tostring(w.name), layout = %q}) "
      .. "else hl.workspace_rule({workspace = tostring(w.id), layout = %q}) end end",
    layout, layout
  )
  return "hyprctl eval '" .. lua:gsub("'", "'\\''") .. "'"
end

local function poll()
  if not noctalia.commandExists("hyprctl") then
    return
  end
  noctalia.runAsync("hyprctl activeworkspace -j", function(result)
    if result.exitCode ~= 0 then
      return
    end
    local data = noctalia.json.decode(result.stdout)
    if data == nil then
      return
    end
    local layout = data.tiledLayout
    if layout and layout ~= lastLayout then
      lastLayout = layout
      noctalia.state.set("layout", layout)
    end
  end)
end

local function cycle()
  local idx = 1
  for i, l in ipairs(layouts) do
    if l == lastLayout then
      idx = (i % #layouts) + 1
      break
    end
  end
  local nextLayout = layouts[idx]
  noctalia.runAsync(setLayoutCmd(nextLayout))
  lastLayout = nextLayout
  noctalia.state.set("layout", nextLayout)
end

function onIpc(event)
  if event == "cycle" then
    cycle()
  end
end

function update()
  poll()
end

poll()

