--!nonstrict
-- Screen Control panel, in two views. Brightness: a brightness slider for each monitor, and
-- an extra dim slider once it is at its lowest brightness, then night light and caffeine.
-- Layout: the screens to scale, as they are arranged, and the settings of the chosen screen.
-- A screen dragged onto an edge of another goes there: left, right, above or below, lined up
-- at the start, the middle or the end of that edge. Renders "screen-control.model" and
-- "screen-control.layout", and sends actions on "screen-control.command" and
-- "screen-control.layout-command".

local Layout = require("./lib/layout.luau")
local Level = require("./lib/level.luau")

local NIGHT_MODES = { "off", "scheduled", "on" }
local VIEWS = { "brightness", "layout" }
local CANVAS_WIDTH = 428
local CANVAS_HEIGHT = 180
local TILE_GAP = 2
local CONTROL_WIDTH = 220
local DRAG_TYPE = "omerfuyar/screen-control:screen"
local SDR_BRIGHTNESS = { 1, 1.2, 1.4, 1.6, 1.8, 2 }

local model = nil
local layoutModel = nil
local view = "brightness"
local chosen = nil -- id of the screen whose settings show

local render

local function send(command)
  command.n = noctalia.nowMs()
  noctalia.state.set("screen-control.command", command)
end

local function sendLayout(command)
  command.n = noctalia.nowMs()
  noctalia.state.set("screen-control.layout-command", command)
end

local function monitorBlock(monitor)
  local dimmed = monitor.dim > 0
  local hasBrightness = monitor.brightness ~= nil
  local title = { ui.label({ text = monitor.label, maxLines = 1 }) }
  if monitor.workspace then
    table.insert(title, ui.label({
      text = noctalia.tr("monitor.workspace", { name = monitor.workspace }),
      color = "on_surface_variant",
      maxLines = 1,
    }))
  end
  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = monitor.internal and "device-laptop" or "device-desktop", size = 18,
        color = "on_surface_variant" }),
      ui.column({ gap = 2, flexGrow = 1 }, title),
      ui.label({ text = Level.text(monitor.brightness, monitor.dim), color = dimmed and "primary" or "on_surface" }),
    }),
  }
  if hasBrightness then
    table.insert(children, ui.slider({
      min = 0,
      max = 1,
      step = 0.01,
      value = Level.share(monitor.brightness),
      onChange = function(value)
        send({ action = "brightness", output = monitor.name, value = tonumber(value) })
      end,
    }))
  end
  -- Dimming below the lowest brightness has a slider of its own, shown once the
  -- brightness is at its lowest, so the brightness slider never starts it by accident.
  if not hasBrightness or dimmed or Level.share(monitor.brightness) <= 0.001 then
    table.insert(children, ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "moon-stars", size = 16, color = dimmed and "primary" or "on_surface_variant" }),
      ui.label({ text = noctalia.tr("monitor.dim"), color = "on_surface_variant" }),
      ui.slider({
        min = 0,
        max = 1,
        step = 0.01,
        flexGrow = 1,
        value = 1 - math.clamp(monitor.dim / Level.maxDim(), 0, 1),
        onChange = function(value)
          send({ action = "dim", output = monitor.name, value = tonumber(value) })
        end,
      }),
    }))
  end
  return ui.column({ key = monitor.name, gap = 6 }, children)
end

local function modeButton(mode)
  local selected = model.night.mode == mode
  return ui.button({
    text = noctalia.tr("night." .. mode),
    variant = selected and "secondary" or "ghost",
    selected = selected,
    controlSize = "sm",
    flexGrow = 1,
    onClick = function() send({ action = "night", mode = mode }) end,
  })
end

local function timeInput(key, value, placeholder)
  return ui.input({
    key = "time-" .. key,
    value = value,
    placeholder = placeholder,
    width = 80,
    onChange = function(text)
      send({ action = "schedule", key = key, value = noctalia.string.trim(text) })
    end,
  })
end

-- Sunset to sunrise where Noctalia's location is, or times the user sets.
local function scheduleBlock()
  local night = model.night
  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = noctalia.tr("night.custom"), color = "on_surface_variant", flexGrow = 1 }),
      ui.toggle({
        checked = night.custom,
        onChange = function(value) send({ action = "schedule", custom = value == "true" }) end,
      }),
    }),
  }
  if night.custom then
    table.insert(children, ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = noctalia.tr("night.from"), color = "on_surface_variant" }),
      timeInput("sunset", night.start, "20:30"),
      ui.label({ text = noctalia.tr("night.until"), color = "on_surface_variant" }),
      timeInput("sunrise", night.finish, "07:30"),
    }))
    table.insert(children, ui.label({ text = noctalia.tr("night.dark_mode_note"), color = "on_surface_variant" }))
  elseif night.place and night.place ~= "" then
    table.insert(children, ui.label({
      text = noctalia.tr("night.sunset_to_sunrise", { place = night.place }),
      color = "on_surface_variant",
      maxLines = 2,
    }))
  else
    table.insert(children, ui.label({ text = noctalia.tr("night.no_place"), color = "on_surface_variant" }))
  end
  return ui.column({ gap = 8 }, children)
end

local function nightBlock()
  local buttons = {}
  for _, mode in ipairs(NIGHT_MODES) do
    table.insert(buttons, modeButton(mode))
  end
  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "moon", size = 18, color = "on_surface_variant" }),
      ui.label({ text = noctalia.tr("night.title"), flexGrow = 1 }),
    }),
    ui.row({ gap = 6 }, buttons),
  }
  if model.night.mode == "scheduled" then
    table.insert(children, scheduleBlock())
  end
  if model.night.mode ~= "off" then
    table.insert(children, ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = noctalia.tr("night.warmth"), color = "on_surface_variant", flexGrow = 1 }),
      ui.label({ text = `{model.night.temperature} K` }),
    }))
    -- Reversed, so that right is warmer, like the brightness slider's right is brighter.
    table.insert(children, ui.slider({
      min = 0,
      max = 5000,
      step = 100,
      value = 6500 - model.night.temperature,
      onChange = function(value)
        send({ action = "temperature", value = 6500 - (tonumber(value) or 2500) })
      end,
    }))
  end
  return ui.column({ gap = 8 }, children)
end

-- Noctalia's caffeine: the screen stays on and does not lock while it is on.
local function caffeineRow()
  return ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "coffee", size = 18, color = model.caffeine and "primary" or "on_surface_variant" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = noctalia.tr("caffeine.title") }),
      ui.label({ text = noctalia.tr("caffeine.hint"), color = "on_surface_variant" }),
    }),
    ui.toggle({
      checked = model.caffeine == true,
      onChange = function(value) send({ action = "caffeine", on = value == "true" }) end,
    }),
  })
end

local function setField(screen, field, value)
  sendLayout({ action = "set", id = screen.id, field = field, value = value })
end

local function screenName(screen)
  return `{screen.model} ({screen.name})`
end

-- A drop zone on <screen>'s edge, named "<edge>/<align>".
local function zone(screen, edge, align, width, height)
  return ui.dropZone({
    key = `{screen.id}-{edge}-{align}`,
    accepts = { DRAG_TYPE },
    value = `{edge}/{align}`,
    width = width,
    height = height,
    radius = 3,
    hitSlop = 2,
    onDrop = function(id, value)
      local where, along = value:match("^(%a+)/(%a+)$")
      if id ~= screen.id then
        sendLayout({ action = "move", id = id, target = screen.id, edge = where, align = along })
      end
    end,
  }, {})
end

-- Three zones along one edge of <screen>, which is <length> long and <depth> deep.
local function edgeZones(screen, edge, length, depth, across)
  local part = math.floor(length / 3)
  local sizes = { part, length - 2 * part, part }
  local zones = {}
  for index, align in ipairs({ "start", "middle", "end" }) do
    table.insert(zones, across and zone(screen, edge, align, sizes[index], depth)
      or zone(screen, edge, align, depth, sizes[index]))
  end
  if across then
    return ui.row({ width = length, height = depth }, zones)
  end
  return ui.column({ width = depth, height = length }, zones)
end

local function tile(screen, width, height)
  local band = math.max(8, math.floor(math.min(width, height) / 4))
  local middle = height - 2 * band
  local inner = width - 2 * band
  local active = screen.id == chosen
  local labels = {
    ui.label({ text = screen.model, fontSize = 11, maxLines = 1, maxWidth = math.max(20, inner),
      color = active and "primary" or "on_surface" }),
  }
  if middle >= 34 then
    table.insert(labels, ui.label({ text = screen.name, fontSize = 10, color = "on_surface_variant", maxLines = 1 }))
  end
  local edges = {
    edgeZones(screen, "above", width, band, true),
    ui.row({ width = width, height = middle }, {
      edgeZones(screen, "left", middle, band, false),
      ui.column({ width = inner, height = middle, align = "center", justify = "center" }, labels),
      edgeZones(screen, "right", middle, band, false),
    }),
    edgeZones(screen, "below", width, band, true),
  }
  return ui.dragSource({
    key = "tile-" .. screen.id,
    dragType = DRAG_TYPE,
    payload = screen.id,
    grabCursor = false,
    width = width,
    height = height,
    radius = 6,
    fill = active and "primary/0.18" or "surface_container_high",
    border = active and "primary" or "outline_variant",
    borderWidth = active and 2 or 1,
    tooltip = screenName(screen),
    onClick = function()
      chosen = screen.id
      render()
    end,
  }, { ui.column({ width = width, height = height }, edges) })
end

local function spacer(width, height)
  return ui.spacer({ width = math.max(0, width), height = math.max(0, height) })
end

-- Draws <items> inside the box x, y, width, height: cut into columns, or rows, wherever a
-- line crosses no screen, so each piece is placed by its neighbours and spacers.
local function draw(items, x, y, width, height)
  if #items == 1 then
    local item = items[1]
    return ui.column({ width = width, height = height }, {
      spacer(0, item.y - y),
      ui.row({ height = item.h }, {
        spacer(item.x - x, 0),
        tile(item.screen, math.max(16, item.w - TILE_GAP), math.max(16, item.h - TILE_GAP)),
      }),
    })
  end
  for _, across in ipairs({ "x", "y" }) do
    local size = across == "x" and "w" or "h"
    table.sort(items, function(a, b) return a[across] < b[across] end)
    local groups, last = {}, -math.huge
    for _, item in ipairs(items) do
      if item[across] >= last - 0.5 then
        table.insert(groups, {})
      end
      table.insert(groups[#groups], item)
      last = math.max(last, item[across] + item[size])
    end
    if #groups > 1 then
      local children, cursor = {}, across == "x" and x or y
      for _, group in ipairs(groups) do
        local from, to = math.huge, -math.huge
        for _, item in ipairs(group) do
          from, to = math.min(from, item[across]), math.max(to, item[across] + item[size])
        end
        if across == "x" then
          table.insert(children, spacer(from - cursor, 0))
          table.insert(children, draw(group, from, y, to - from, height))
        else
          table.insert(children, spacer(0, from - cursor))
          table.insert(children, draw(group, x, from, width, to - from))
        end
        cursor = to
      end
      if across == "x" then
        return ui.row({ width = width, height = height }, children)
      end
      return ui.column({ width = width, height = height }, children)
    end
  end
  -- Screens that overlap: side by side, in order.
  local children = {}
  for _, item in ipairs(items) do
    table.insert(children, tile(item.screen, math.max(16, math.floor(width / #items) - TILE_GAP), math.max(16, item.h)))
  end
  return ui.row({ width = width, height = height, gap = TILE_GAP }, children)
end

local function canvas(screens)
  local placed, aside = {}, {}
  local maxX, maxY = 0, 0
  for _, screen in ipairs(screens) do
    if Layout.placed(screen) then
      local width, height = Layout.size(screen)
      table.insert(placed, { screen = screen, x = screen.x, y = screen.y, w = width, h = height })
      maxX, maxY = math.max(maxX, screen.x + width), math.max(maxY, screen.y + height)
    else
      table.insert(aside, screen)
    end
  end
  local factor = math.min(CANVAS_WIDTH / math.max(1, maxX), CANVAS_HEIGHT / math.max(1, maxY))
  for _, item in ipairs(placed) do
    item.x, item.y = math.floor(item.x * factor), math.floor(item.y * factor)
    item.w, item.h = math.floor(item.w * factor), math.floor(item.h * factor)
  end
  local width, height = math.floor(maxX * factor), math.floor(maxY * factor)
  local children = {
    ui.row({ justify = "center" }, { draw(placed, 0, 0, width, height) }),
  }
  -- Screens that are off or show another screen's picture take no place of their own.
  if #aside > 0 then
    local chips = {}
    for _, screen in ipairs(aside) do
      local source = screen.mirror ~= "" and Layout.find(screens, screen.mirror)
      table.insert(chips, ui.button({
        key = "aside-" .. screen.id,
        text = source and noctalia.tr("screen.mirrors", { name = screen.model, source = source.model })
          or noctalia.tr("screen.off", { name = screen.model }),
        glyph = source and "copy" or "device-desktop-off",
        variant = screen.id == chosen and "default" or "ghost",
        controlSize = "sm",
        onClick = function()
          chosen = screen.id
          render()
        end,
      }))
    end
    table.insert(children, ui.row({ gap = 6, justify = "center" }, chips))
  end
  return ui.column({ gap = 8 }, children)
end

local function selectControl(key, labels, selected, onPick)
  return ui.select({
    key = key,
    width = CONTROL_WIDTH,
    controlSize = "sm",
    options = labels,
    selectedIndex = selected,
    onChange = function(index)
      onPick((tonumber(index) or -1) + 1)
    end,
  })
end

local function controlRow(label, control)
  return ui.row({ gap = 8, align = "center", height = 36 }, {
    ui.label({ text = label, flexGrow = 1, maxLines = 1 }),
    control,
  })
end

local function modeLabel(mode)
  local width, height = Layout.pixels(mode)
  local rate = tonumber(mode:match("@([%d.]+)")) or 0
  return string.format("%d × %d · %s Hz", width, height, rate % 1 < 0.005 and tostring(math.floor(rate)) or string.format("%.2f", rate))
end

local function scaleLabel(scale)
  return string.format("%d%%", math.floor(scale * 100 + 0.5))
end

local function screenSettings(screen, screens)
  local rows = {}
  local version = `{screen.id}-{screen.mode}-{screen.scale}-{screen.transform}-{screen.vrr}-{tostring(screen.hdr)}-{screen.mirror}`
  local on = Layout.enabledCount(screens)
  table.insert(rows, controlRow(noctalia.tr("screen.on"), ui.toggle({
    checked = screen.enabled,
    enabled = not screen.enabled or on > 1,
    onChange = function(value) setField(screen, "enabled", value == "true") end,
  })))
  if screen.enabled then
    local modes = table.clone(screen.modes)
    local labels, selected = {}, -1
    for index, mode in ipairs(modes) do
      table.insert(labels, modeLabel(mode))
      if mode == screen.mode then
        selected = index - 1
      end
    end
    if selected < 0 then
      table.insert(labels, 1, modeLabel(screen.mode))
      table.insert(modes, 1, screen.mode)
      selected = 0
    end
    table.insert(rows, controlRow(noctalia.tr("screen.mode"), selectControl("mode-" .. version, labels, selected,
      function(index) if modes[index] then setField(screen, "mode", modes[index]) end end)))

    local scales = Layout.scales(screen)
    labels, selected = {}, 0
    for index, scale in ipairs(scales) do
      table.insert(labels, scaleLabel(scale))
      if math.abs(scale - screen.scale) < 0.001 then
        selected = index - 1
      end
    end
    table.insert(rows, controlRow(noctalia.tr("screen.scale"), selectControl("scale-" .. version, labels, selected,
      function(index) if scales[index] then setField(screen, "scale", scales[index]) end end)))

    labels = {}
    for turn = 0, 3 do
      table.insert(labels, noctalia.tr("screen.rotation_" .. turn))
    end
    table.insert(rows, controlRow(noctalia.tr("screen.rotation"), selectControl("rotation-" .. version, labels,
      screen.transform, function(index) setField(screen, "transform", index - 1) end)))

    if screen.vrrCapable then
      labels = { noctalia.tr("screen.vrr_0"), noctalia.tr("screen.vrr_1"), noctalia.tr("screen.vrr_2") }
      table.insert(rows, controlRow(noctalia.tr("screen.vrr"), selectControl("vrr-" .. version, labels,
        math.clamp(screen.vrr, 0, 2), function(index) setField(screen, "vrr", index - 1) end)))
    end

    if screen.hdrCapable then
      table.insert(rows, controlRow(noctalia.tr("screen.hdr"), ui.toggle({
        checked = screen.hdr,
        onChange = function(value) setField(screen, "hdr", value == "true") end,
      })))
      if screen.hdr then
        labels, selected = {}, 0
        for index, level in ipairs(SDR_BRIGHTNESS) do
          table.insert(labels, scaleLabel(level))
          if math.abs(level - screen.sdrBrightness) < 0.05 then
            selected = index - 1
          end
        end
        table.insert(rows, controlRow(noctalia.tr("screen.sdr_brightness"), selectControl("sdr-" .. version, labels,
          selected, function(index) setField(screen, "sdrBrightness", SDR_BRIGHTNESS[index]) end)))
      end
    end

    if #screens > 1 then
      local sources = {}
      labels, selected = { noctalia.tr("screen.mirror_none") }, 0
      for _, other in ipairs(screens) do
        if other.id ~= screen.id and other.enabled and other.mirror == "" then
          table.insert(sources, other.id)
          table.insert(labels, screenName(other))
          if other.id == screen.mirror then
            selected = #labels - 1
          end
        end
      end
      table.insert(rows, controlRow(noctalia.tr("screen.mirror"), selectControl("mirror-" .. version, labels, selected,
        function(index) setField(screen, "mirror", sources[index - 1] or "") end)))
    end

    table.insert(rows, controlRow(noctalia.tr("screen.workspaces"), ui.input({
      key = `workspaces-{screen.id}-{screen.workspaces}`,
      width = CONTROL_WIDTH,
      controlSize = "sm",
      value = screen.workspaces,
      placeholder = noctalia.tr("screen.workspaces_placeholder"),
      onSubmit = function(value) setField(screen, "workspaces", value) end,
    })))
    local problem = layoutModel.errors and layoutModel.errors[screen.id]
    if problem then
      table.insert(rows, ui.label({ text = problem, color = "error", fontSize = 11, maxLines = 2 }))
    end
  end
  return ui.column({ gap = 4 }, {
    ui.label({ text = screenName(screen), fontWeight = "semibold", color = "primary", maxLines = 1 }),
    ui.column({ gap = 0 }, rows),
  })
end

local function keepCard()
  return ui.row({ gap = 8, align = "center", padding = 10, radius = 10, fill = "primary/0.12", border = "primary" }, {
    ui.glyph({ name = "clock-hour-4", size = 18, color = "primary" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = noctalia.tr("layout.keep_question"), fontWeight = "semibold" }),
      ui.label({ text = noctalia.trp("layout.keep_countdown", layoutModel.pending), color = "on_surface_variant", fontSize = 11 }),
    }),
    ui.button({ text = noctalia.tr("layout.undo"), variant = "ghost", controlSize = "sm",
      onClick = function() sendLayout({ action = "undo" }) end }),
    ui.button({ text = noctalia.tr("layout.keep"), variant = "primary", controlSize = "sm",
      onClick = function() sendLayout({ action = "keep" }) end }),
  })
end

local function brightnessView()
  local children = {}
  for _, monitor in ipairs(model.monitors) do
    table.insert(children, monitorBlock(monitor))
  end
  if model.sharedDim and #model.monitors > 1 then
    table.insert(children, ui.label({ text = noctalia.tr("panel.shared_dim"), color = "on_surface_variant" }))
  end
  table.insert(children, ui.separator({}))
  table.insert(children, nightBlock())
  table.insert(children, ui.separator({}))
  table.insert(children, caffeineRow())
  return children
end

local function layoutView()
  if layoutModel == nil or not layoutModel.ready then
    return {
      ui.label({ text = layoutModel and layoutModel.error or noctalia.tr("panel.loading"), color = "on_surface_variant",
        maxLines = 4 }),
    }
  end
  local screens = layoutModel.screens
  if not chosen or not Layout.find(screens, chosen) then
    chosen = screens[1] and screens[1].id
  end
  local children = {}
  if layoutModel.pending then
    table.insert(children, keepCard())
  end
  if layoutModel.error then
    table.insert(children, ui.label({ text = layoutModel.error, color = "error", fontSize = 11, maxLines = 3 }))
  end
  table.insert(children, canvas(screens))
  if #screens > 1 then
    table.insert(children, ui.label({ text = noctalia.tr("layout.hint"), color = "on_surface_variant", fontSize = 11,
      maxLines = 2, textAlign = "center" }))
  end
  local screen = Layout.find(screens, chosen)
  if screen then
    table.insert(children, ui.separator({}))
    table.insert(children, screenSettings(screen, screens))
  end
  if layoutModel.remembered then
    table.insert(children, ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = noctalia.tr("layout.remembered"), color = "on_surface_variant", fontSize = 11, flexGrow = 1,
        maxLines = 2 }),
      ui.button({
        text = noctalia.tr("layout.reset"),
        glyph = "restore",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("layout.reset_tooltip"),
        onClick = function() sendLayout({ action = "reset" }) end,
      }),
    }))
  end
  return children
end

local function viewButton(name)
  local selected = view == name
  return ui.button({
    text = noctalia.tr("panel." .. name),
    variant = selected and "secondary" or "ghost",
    selected = selected,
    controlSize = "sm",
    onClick = function()
      view = name
      render()
    end,
  })
end

render = function()
  if model == nil then
    panel.render(ui.column({ padding = 16 }, {
      ui.label({ text = noctalia.tr("panel.loading"), color = "on_surface_variant" }),
    }))
    return
  end
  local header = {
    ui.glyph({ name = "sun", size = 20, color = "primary" }),
    ui.label({ text = noctalia.tr("panel.title"), fontWeight = "semibold", flexGrow = 1 }),
  }
  for _, name in ipairs(VIEWS) do
    table.insert(header, viewButton(name))
  end
  local children = { ui.row({ gap = 6, align = "center" }, header) }
  for _, child in ipairs(view == "layout" and layoutView() or brightnessView()) do
    table.insert(children, child)
  end
  panel.render(ui.column({ gap = 14, padding = 16 }, children))
end

noctalia.state.watch("screen-control.model", function(value)
  model = value
  render()
end)

noctalia.state.watch("screen-control.layout", function(value)
  -- A change that waits to be kept shows its question.
  if value and value.pending and not (layoutModel and layoutModel.pending) then
    view = "layout"
  end
  layoutModel = value
  render()
end)

function onOpen(_context)
  send({ action = "refresh" })
  model = noctalia.state.get("screen-control.model") or model
  layoutModel = noctalia.state.get("screen-control.layout") or layoutModel
  if layoutModel and layoutModel.pending then
    view = "layout"
  end
  render()
end
