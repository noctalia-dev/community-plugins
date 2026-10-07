--!nonstrict
-- undershell panel: what is on the desktop, and the few things worth
-- changing without opening the editor (depth plane, tilt, depth on/off).
-- Talks to the daemon through `undershell msg`; `msg json` is its state.

local state = nil        -- decoded `undershell msg json`, or nil when not running
local saves = {}         -- decoded `undershell msg saves`
local pending = {}       -- slider values being dragged, by "id:key"
local busy = false
local newName = ""       -- the name typed for the next saved profile
local armedDelete = nil  -- save id waiting for its confirming click
local target = nil       -- the monitor saved profiles are loaded onto (several monitors only)

local function tr(key, params)
  return noctalia.tr(key, params)
end

local function binary()
  local local_bin = noctalia.expandPath("~/.local/bin/undershell")
  if noctalia.fileExists ~= nil and noctalia.fileExists(local_bin) then
    return local_bin
  end
  if noctalia.commandExists("undershell") then
    return "undershell"
  end
  return local_bin
end

local render

local function refresh()
  noctalia.runAsync({ binary(), "msg", "json" }, function(result)
    busy = false
    local decoded = nil
    if result.exitCode == 0 and result.stdout ~= nil then
      decoded = noctalia.json.decode(result.stdout)
    end
    state = type(decoded) == "table" and decoded or nil
    render()
  end)
  noctalia.runAsync({ binary(), "msg", "saves" }, function(result)
    local decoded = nil
    if result.exitCode == 0 and result.stdout ~= nil then
      decoded = noctalia.json.decode(result.stdout)
    end
    saves = type(decoded) == "table" and decoded or {}
    render()
  end)
end

-- runs `undershell msg <args...>`, then reloads the state
local function send(args, keepOpen)
  local argv = { binary(), "msg" }
  for _, a in ipairs(args) do
    table.insert(argv, a)
  end
  busy = true
  noctalia.runAsync(argv, function(_result)
    if keepOpen ~= false then
      refresh()
    end
  end)
end

local function typeGlyph(t)
  if t == "clock" then
    return "clock"
  elseif t == "now_playing" then
    return "music"
  end
  return "chart-bar"
end

local function typeName(t)
  return tr("type." .. t)
end

local function header()
  return ui.row({ align = "center", gap = 8 }, {
    ui.glyph({ name = "layout-dashboard", size = 20, color = "primary" }),
    ui.label({ text = "undershell", fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
    ui.button({ glyph = "refresh", variant = "ghost", tooltip = tr("panel.refresh"), onClick = function()
      refresh()
    end }),
    ui.button({ glyph = "x", variant = "ghost", onClick = function()
      panel.close()
    end }),
  })
end

local function notRunning()
  return ui.column({ gap = 10, padding = 12, radius = 8, fill = "surface_variant/0.35" }, {
    ui.row({ gap = 10, align = "center" }, {
      ui.glyph({ name = "alert-triangle", size = 20, color = "error" }),
      ui.label({ text = tr("panel.not_running"), fontWeight = "bold", fontSize = 13, flexGrow = 1 }),
    }),
    ui.label({ text = tr("panel.not_running_hint"), color = "on_surface_variant", fontSize = 11 }),
    ui.button({ text = tr("panel.start"), glyph = "player-play", variant = "primary", onClick = function()
      noctalia.runAsync({ "systemctl", "--user", "start", "undershell.service" }, function(_r)
        refresh()
      end)
    end }),
  })
end

local function profileCard()
  local p = state.profile or {}
  local line
  if state.profiles ~= true then
    line = tr("panel.profiles_off")
  elseif p.wallpaper == nil or p.wallpaper == "" then
    line = tr("panel.profile_waiting")
  else
    line = tr("panel.profile_line", { wallpaper = p.wallpaper, count = tostring(p.saved or 0) })
  end
  local depth = state.depth or {}
  local depthLine
  if state.motion == true then
    depthLine = tr("panel.depth_motion")
  elseif depth.field == true then
    depthLine = tr("panel.depth_field", { level = tostring(depth.plugin_threshold or 0) })
  elseif depth.mask == true then
    depthLine = tr("panel.depth_mask")
  else
    depthLine = tr("panel.depth_none")
  end
  return ui.column({ gap = 6, padding = 10, radius = 8, fill = "surface_variant/0.35" }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "photo", size = 16, color = "primary" }),
      ui.label({ text = line, fontSize = 12, flexGrow = 1 }),
    }),
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "layers-subtract", size = 16, color = depth.field == true and "primary" or "on_surface_variant" }),
      ui.label({ text = depthLine, fontSize = 12, color = "on_surface_variant", flexGrow = 1 }),
    }),
  })
end

local function actions()
  return ui.row({ gap = 8 }, {
    ui.button({
      text = state.edit == true and tr("panel.edit_done") or tr("panel.edit"),
      glyph = "pencil",
      variant = "primary",
      flexGrow = 1,
      onClick = function()
        send({ state.edit == true and "edit-off" or "edit-on" })
        if state.edit ~= true then
          panel.close()
        end
      end,
    }),
    ui.button({
      text = tr("panel.demo"),
      glyph = "wave-sine",
      variant = state.demo == true and "secondary" or "outline",
      selected = state.demo == true,
      tooltip = tr("panel.demo_hint"),
      onClick = function()
        send({ state.demo == true and "demo-off" or "demo-on" })
      end,
    }),
  })
end

-- a labelled slider that commits when the drag ends (one config write, one
-- undo-free change) and shows the value while dragging
local function slider(w, key, label, min, max, step, value, format)
  local slot = w.id .. ":" .. key
  local shown = pending[slot] or value
  return ui.column({ gap = 2 }, {
    ui.row({ align = "center" }, {
      ui.label({ text = label, fontSize = 11, color = "on_surface_variant", flexGrow = 1 }),
      ui.label({ text = format(shown), fontSize = 11, fontWeight = "bold" }),
    }),
    ui.slider({
      key = slot,
      min = min,
      max = max,
      step = step,
      value = value,
      controlSize = "sm",
      onChange = function(v)
        pending[slot] = tonumber(v)
        render()
      end,
      onDragEnd = function(v)
        local final = tonumber(v) or pending[slot]
        pending[slot] = nil
        if final ~= nil then
          send({ "set", w.id, key, tostring(final) })
        end
      end,
    }),
  })
end

local function widgetCard(w)
  local level = w.depth_level or 0
  local locked = state.motion == true  -- a video or scene: no depth to pass behind
  return ui.column({ key = w.id, gap = 8, padding = 10, radius = 8, fill = "surface_variant/0.35" }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = typeGlyph(w.type), size = 18, color = "primary" }),
      ui.column({ gap = 0, flexGrow = 1 }, {
        ui.label({ text = w.id, fontWeight = "bold", fontSize = 13 }),
        ui.label({ text = typeName(w.type) .. " · " .. (w.look or ""), fontSize = 11, color = "on_surface_variant" }),
      }),
      ui.button({
        glyph = "pencil",
        variant = "ghost",
        tooltip = tr("panel.edit_this"),
        onClick = function()
          send({ "select", w.id }, false)  -- opens the editor on it
          panel.close()
        end,
      }),
    }),
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = tr("panel.depth"), fontSize = 12, flexGrow = 1, color = locked and "on_surface_variant" or nil }),
      ui.label({ text = tr("panel.locked"), fontSize = 11, color = "on_surface_variant", visible = locked }),
      ui.toggle({ checked = w.depth == true and not locked, enabled = not locked, onChange = function(v)
        send({ "set", w.id, "depth", v == "true" and "true" or "false" })
      end }),
    }),
    locked and ui.label({ text = tr("panel.locked_hint"), fontSize = 11, color = "on_surface_variant" })
      or slider(w, "depth_level", tr("panel.plane"), 0, 100, 1, level, function(v)
        if (v or 0) <= 0 then
          return tr("panel.plane_auto")
        end
        return tostring(math.floor(v + 0.5))
      end),
    slider(w, "rotation", tr("panel.tilt"), -45, 45, 0.5, w.rotation or 0, function(v)
      return string.format("%.1f°", v or 0)
    end),
  })
end

-- saved profiles: named copies of the layout, loaded back on demand
local function savesSection()
  local rows = {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "device-floppy", size = 16, color = "primary" }),
      ui.label({ text = tr("saves.title"), fontWeight = "bold", fontSize = 13, flexGrow = 1 }),
    }),
    ui.label({ text = tr("saves.hint"), color = "on_surface_variant", fontSize = 11 }),
    ui.row({ gap = 8, align = "center" }, {
      ui.input({ value = "", placeholder = tr("saves.placeholder"), controlSize = "sm", flexGrow = 1,
        submitOnEnter = true,
        onChange = function(v)
          newName = v or ""
        end,
        onSubmit = function(v)
          send({ "save", (v ~= nil and v ~= "") and v or "" })
        end,
      }),
      ui.button({ text = tr("saves.save"), glyph = "device-floppy", variant = "primary", controlSize = "sm", onClick = function()
        if newName ~= "" then
          send({ "save", newName })
        else
          send({ "save" })
        end
      end }),
    }),
  }
  -- several monitors: choose which one a profile is loaded onto (it is fitted
  -- to that screen's size through the wallpaper; the others keep their widgets)
  local outputs = (state ~= nil and type(state.outputs) == "table") and state.outputs or {}
  if #outputs > 1 then
    local known = target == "all"
    for _, o in ipairs(outputs) do
      if o.name == target then known = true end
    end
    if not known then
      target = outputs[1].name
      for _, o in ipairs(outputs) do  -- default: where the widgets are
        if (o.widgets or 0) > 0 then target = o.name break end
      end
    end
    local chips = { ui.label({ text = tr("saves.target"), fontSize = 11, color = "on_surface_variant" }) }
    for _, o in ipairs(outputs) do
      table.insert(chips, ui.button({ text = o.name, controlSize = "sm",
        variant = o.name == target and "primary" or "ghost",
        tooltip = string.format("%d × %d", o.width or 0, o.height or 0),
        onClick = function()
          target = o.name
          render()
        end }))
    end
    -- every monitor: a copy of the profile on each
    table.insert(chips, ui.button({ text = tr("saves.all"), controlSize = "sm",
      variant = target == "all" and "primary" or "ghost",
      onClick = function()
        target = "all"
        render()
      end }))
    table.insert(rows, ui.row({ gap = 6, align = "center" }, chips))
  else
    target = nil
  end
  if #saves == 0 then
    table.insert(rows, ui.label({ text = tr("saves.empty"), color = "on_surface_variant", fontSize = 11 }))
  end
  for _, sv in ipairs(saves) do
    local meta = (sv.created or "") .. " · " .. tostring(sv.widgets or 0) .. " widgets"
    if sv.wallpaper ~= nil and sv.wallpaper ~= "" then
      meta = meta .. " · " .. sv.wallpaper
    end
    if sv.current == true then
      meta = tr("saves.on_screen") .. " · " .. meta
    end
    local armed = armedDelete == sv.id
    table.insert(rows, ui.row({ key = "save:" .. sv.id, gap = 8, align = "center", padding = 8, radius = 8,
      fill = sv.current == true and "primary/0.12" or "surface_variant/0.35" }, {
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = sv.name or sv.id, fontWeight = "bold", fontSize = 12 }),
        ui.label({ text = meta, fontSize = 10, color = sv.current == true and "primary" or "on_surface_variant" }),
      }),
      ui.button({ text = tr("saves.load"), variant = "primary", controlSize = "sm", onClick = function()
        armedDelete = nil
        if target ~= nil then
          send({ "save-load", sv.id, target })
        else
          send({ "save-load", sv.id })
        end
      end }),
      ui.button({ glyph = "device-floppy", variant = "ghost", controlSize = "sm", tooltip = tr("saves.overwrite"), onClick = function()
        armedDelete = nil
        send({ "save-overwrite", sv.id })
      end }),
      ui.button({ glyph = "trash", variant = armed and "destructive" or "ghost", controlSize = "sm",
        tooltip = armed and tr("saves.confirm") or tr("saves.delete"), onClick = function()
        if armedDelete == sv.id then
          armedDelete = nil
          send({ "save-delete", sv.id })
        else
          armedDelete = sv.id
          render()
        end
      end }),
    }))
  end
  return ui.column({ gap = 6 }, rows)
end

render = function()
  local children = { header() }
  if state == nil then
    table.insert(children, notRunning())
  else
    table.insert(children, profileCard())
    table.insert(children, actions())
    table.insert(children, ui.separator({}))
    local cards = { savesSection(), ui.separator({}) }
    for _, w in ipairs(state.widgets or {}) do
      table.insert(cards, widgetCard(w))
    end
    if #cards == 0 then
      table.insert(cards, ui.label({ text = tr("panel.no_widgets"), color = "on_surface_variant", fontSize = 12 }))
    end
    table.insert(children, ui.scroll({ flexGrow = 1, gap = 8 }, cards))
  end
  panel.render(ui.column({ flexGrow = 1, gap = 10, padding = 10 }, children))
end

function onOpen(_context)
  render()
  refresh()
end
