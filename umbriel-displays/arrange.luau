--!nonstrict
local displays = require("./outputs.luau")
local controls = require("./controls.luau")

local CANVAS_W = 830
local CANVAS_H = 400
-- Wide hit areas keep narrow slots reachable without consuming canvas space.
local SLOT = 22
local END_SLOT = 44
local ROW_SLOT = 20
local HIT = 90
-- Limit vertical reach to avoid competing with side slots along the entire row.
local ROW_HIT = 24
local LINE = 10
local MARK = 6
local END_MARK = 22
local MARK_FILL = "surface_container"
local MARK_RADIUS = 4
local MIN_BOX_W = 96
local MIN_BOX_H = 58

local opened = false
local outputs = {}
local rows = {}
local status = ""
local statusIsError = false

local render

local tr = noctalia.tr

-- ── Model ──────────────────────────────────────────────────────────────────

local function outputNamed(name)
  for _, output in ipairs(outputs) do
    if output.name == name then
      return output
    end
  end
  return nil
end

local function offline()
  local list = {}
  for _, output in ipairs(outputs) do
    if not output.enabled or output.currentMode == nil then
      table.insert(list, output)
    end
  end
  return list
end

local function load()
  displays.query(function(result)
    if result == nil then
      outputs, rows = {}, {}
      status, statusIsError = tr("status.query_failed"), true
    else
      outputs = result
      rows = displays.rows(outputs)
    end
    if opened then
      render()
    end
  end)
end

-- A display dragged to the tray keeps its section, so its mode and scale come
-- back with it.
local function commit()
  local sections, changed = displays.apply(outputs, rows)
  if not changed then
    render()
    return
  end

  displays.write(sections, function(ok, err, unsupported)
    if ok then
      status, statusIsError = tr("status.applied"), false
    else
      status, statusIsError = unsupported ~= nil and tr("status.unsupported", { key = unsupported })
        or tr("status.write_failed", { error = tostring(err) }), true
      load()
    end
    render()
  end)
end

-- ── View ───────────────────────────────────────────────────────────────────

-- Use one scale factor to preserve relative geometry; shrink minimum sizes
-- when necessary to keep crowded rows within the canvas.
local function metrics()
  local totalW, totalH, widest = 0, 0, 1
  for _, row in ipairs(rows) do
    local rowW, rowH = 0, 0
    for _, output in ipairs(row) do
      local w, h = displays.logicalSize(output)
      rowW = rowW + w
      rowH = math.max(rowH, h)
    end
    totalW = math.max(totalW, rowW)
    totalH = totalH + rowH
    widest = math.max(widest, #row)
  end

  local availW = CANVAS_W - (END_SLOT * 2 + SLOT * (widest - 1))
  local availH = CANVAS_H - ROW_SLOT * (#rows + 1)
  if totalW == 0 or totalH == 0 then
    return { k = 0.1, minW = MIN_BOX_W, minH = MIN_BOX_H }
  end
  return {
    k = math.min(availW / totalW, availH / totalH, 0.5),
    minW = math.min(MIN_BOX_W, availW / widest),
    minH = math.min(MIN_BOX_H, availH / #rows),
  }
end

local function rowHeight(row, m)
  local tallest = 0
  for _, output in ipairs(row) do
    local _, h = displays.logicalSize(output)
    tallest = math.max(tallest, h)
  end
  return math.floor(math.max(tallest * m.k, m.minH))
end

local function screen(output, m)
  local w, h = displays.logicalSize(output)
  -- Floored, so a row of rounded-up boxes can never total past the canvas.
  local width = math.floor(math.max(w * m.k, m.minW))
  local height = math.floor(math.max(h * m.k, m.minH))
  local mode = output.currentMode
  local children = {
    ui.label({ text = output.name, fontSize = 13, fontWeight = "bold", textAlign = "center" }),
  }
  -- A crowded canvas leaves room for the name and nothing else.
  if mode ~= nil and width >= 130 and height >= 52 then
    table.insert(children, ui.label({
      text = string.format("%s · %s", displays.resolutionOf(mode), displays.hzLabel(mode)),
      fontSize = 11,
      color = "on_surface_variant",
      textAlign = "center",
    }))
  end
  if math.abs(output.scale - 1.0) > 0.001 and height >= 70 then
    table.insert(children, ui.label({
      text = string.format("%gx", output.scale),
      fontSize = 10,
      color = "primary",
      textAlign = "center",
    }))
  end

  local box = ui.dragSource({
    key = "screen-" .. output.name,
    dragType = "display",
    payload = output.name,
    tooltip = output.description,
    width = width,
    height = height,
    align = "center",
    justify = "center",
    gap = 2,
    fill = "surface",
    border = "primary",
    borderWidth = 1,
    radius = 8,
  }, children)

  -- The nested drag source is not a drop zone, so its parent receives the drop.
  return ui.dropZone({
    key = "swap-" .. output.name,
    accepts = { "display" },
    value = "swap|" .. output.name,
    onDrop = "onDrop",
    align = "center",
    justify = "center",
  }, { box })
end

-- Grow outer slots so drops at the canvas edge still reach a target.
local function slot(value, width, height, reach, grow, mark)
  local vertical = height > width
  local thickness = mark or MARK
  return ui.dropZone({
    key = "slot-" .. value,
    accepts = { "display" },
    value = value,
    onDrop = "onDrop",
    hitSlop = reach,
    flexGrow = grow,
    align = "center",
    justify = "center",
    width = width,
    height = height,
    radius = 4,
  }, {
    ui.box({
      width = vertical and thickness or math.max(width - 12, LINE),
      height = vertical and height or thickness,
      fill = MARK_FILL,
      radius = MARK_RADIUS,
    }),
  })
end

local function canvas()
  local m = metrics()
  local nodes = {}

  for r, row in ipairs(rows) do
    local height = rowHeight(row, m)
    table.insert(nodes, slot("above|" .. row[1].name, CANVAS_W, ROW_SLOT, ROW_HIT,
      r == 1 and 1 or nil, LINE))

    local cells = {}
    for i, output in ipairs(row) do
      local first = i == 1
      table.insert(cells, slot("left|" .. output.name, first and END_SLOT or SLOT, height, HIT,
        first and 1 or nil, first and END_MARK or MARK))
      table.insert(cells, screen(output, m))
    end
    table.insert(cells, slot("right|" .. row[#row].name, END_SLOT, height, HIT, 1, END_MARK))
    table.insert(nodes, ui.row({ align = "center", justify = "center", gap = 0 }, cells))

    if r == #rows then
      table.insert(nodes, slot("below|" .. row[1].name, CANVAS_W, ROW_SLOT, ROW_HIT, 1, LINE))
    end
  end

  return ui.column({
    gap = 0,
    align = "center",
    justify = "center",
    flexGrow = 1,
    padding = 12,
    radius = controls.RADIUS,
    fill = "surface_container/0.35",
  }, nodes)
end

local function tray()
  local children = {}
  local list = offline()
  local hint = tr("tray.hint")

  if #list > 0 then
    hint = tr("tray.restore")
    local chips = {}
    for _, output in ipairs(list) do
      table.insert(chips, ui.dragSource({
        key = "off-" .. output.name,
        dragType = "display",
        payload = output.name,
        tooltip = tr("tray.restore"),
        gap = 6,
        align = "center",
        paddingH = 12,
        paddingV = 8,
        fill = "surface_container",
        border = "outline_variant",
        borderWidth = 1,
        radius = 10,
      }, {
        ui.glyph({ name = "grip-vertical", size = 13, color = "on_surface_variant" }),
        ui.glyph({ name = "device-desktop-off", size = 14, color = "on_surface_variant" }),
        ui.label({ text = output.name, fontSize = 12, fontWeight = "medium" }),
      }))
    end
    table.insert(children, ui.row({ gap = 8, justify = "center" }, chips))
  else
    table.insert(children, ui.glyph({ name = "device-desktop-off", size = 20, color = "on_surface_variant" }))
  end

  table.insert(children, ui.label({
    text = hint,
    fontSize = 12,
    color = "on_surface_variant",
    textAlign = "center",
  }))

  return ui.dropZone({
    key = "tray",
    accepts = { "display" },
    value = "off",
    onDrop = "onDrop",
    hitSlop = 40,
    direction = "column",
    align = "center",
    justify = "center",
    gap = 8,
    padding = 16,
    radius = controls.RADIUS,
    border = "outline_variant",
    borderWidth = 1,
  }, children)
end

render = function()
  local nodes = {
    controls.header(tr("arrange.title"), {
      ui.button({ glyph = "arrow-left", variant = "ghost", controlSize = "sm", tooltip = tr("action.back"), onClick = "onBack" }),
      ui.label({ text = tr("arrange.hint"), fontSize = 11, color = "on_surface_variant" }),
      ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm", tooltip = tr("action.refresh"), onClick = "onRefresh" }),
      ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", onClick = "onCloseClick" }),
    }),
  }

  if #rows == 0 and #offline() == 0 then
    table.insert(nodes, controls.message(status ~= "" and status or tr("status.no_outputs")))
  else
    table.insert(nodes, ui.scroll({ flexGrow = 1 }, { canvas() }))
    table.insert(nodes, tray())
    if status ~= "" then
      table.insert(nodes, ui.label({
        text = status,
        fontSize = 12,
        color = statusIsError and "error" or "on_surface_variant",
      }))
    end
  end

  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, nodes))
end

-- ── Callbacks ──────────────────────────────────────────────────────────────

function onOpen(_context)
  opened = true
  status = ""
  statusIsError = false
  render()
  load()
end

function onClose()
  opened = false
end

function onRefresh()
  status = ""
  statusIsError = false
  load()
end

function onCloseClick()
  panel.close()
end

function onDrop(payload, value)
  local output = outputNamed(payload)
  if output == nil then
    return
  end

  if value == "off" then
    -- The last screen has nowhere to hand its windows to, and Umbriel would
    -- keep them without a workspace until one comes back.
    if #rows == 1 and #rows[1] == 1 and rows[1][1].name == payload then
      status, statusIsError = tr("status.last_output"), true
      render()
      return
    end
    output.enabled = false
    rows = displays.move(rows, output, "off")
  else
    if output.currentMode == nil then
      status, statusIsError = tr("status.no_mode", { name = payload }), true
      render()
      return
    end
    output.enabled = true
    local anchor = string.match(value, "^swap|(.+)$")
    if anchor ~= nil then
      if anchor == payload then
        return
      end
      rows = displays.swap(rows, output, anchor)
    else
      rows = displays.move(rows, output, value)
    end
  end

  commit()
end

function onBack()
  panel.close()
  noctalia.togglePanel("prponkshe/umbriel-displays:panel")
end

-- Escape walks back to the panel this window was opened from, rather than
-- leaving the user on the desktop.
function onKey(chord, pressed)
  if pressed and chord == "escape" then
    onBack()
  end
end
