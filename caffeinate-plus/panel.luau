--!nonstrict
-- Presets panel: the Spoon's right-click menu. On/off, remaining time, one
-- button per preset, cancel timer, and the lid option.

local C = require("./common.luau")

local status = C.status()
local isOpen = false

local function presetGrid()
  local rows, row = {}, {}
  for i, minutes in C.presets() do
    table.insert(
      row,
      ui.button({
        key = `preset-{i}`,
        text = C.presetLabel(minutes),
        variant = "outline",
        flexGrow = 1,
        onClick = function()
          C.send("for", tostring(minutes))
          panel.close()
        end,
      })
    )
    if #row == 3 then
      table.insert(rows, ui.row({ gap = 8 }, row))
      row = {}
    end
  end
  if #row > 0 then
    -- Pad the last row so its buttons keep the same width.
    while #row < 3 do
      table.insert(row, ui.spacer({ flexGrow = 1 }))
    end
    table.insert(rows, ui.row({ gap = 8 }, row))
  end
  return rows
end

local function render()
  if not isOpen then
    return
  end
  local on = status.active == true
  local stateText
  if status.remaining then
    stateText = noctalia.tr("panel.remaining", { time = C.short(status.remaining) })
  elseif on and not status.owned and not status.session then
    stateText = noctalia.tr("tooltip.external")
  elseif on then
    stateText = noctalia.tr("panel.until_off")
  else
    stateText = noctalia.tr("panel.off")
  end

  local body = {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = if on then "coffee" else "coffee-off", color = if on then "tertiary" else "on_surface_variant" }),
      ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.toggle({
        checked = on,
        enabled = not status.busy,
        onChange = function(value)
          C.send(if value == "true" then "enable" else "disable")
        end,
      }),
    }),
    ui.label({ text = stateText, color = if status.remaining then "primary" else "on_surface_variant" }),
    ui.separator({}),
    ui.label({ text = noctalia.tr("panel.enable_for"), fontWeight = "semibold" }),
  }
  for _, row in presetGrid() do
    table.insert(body, row)
  end
  table.insert(
    body,
    ui.button({
      text = noctalia.tr("panel.cancel_timer"),
      variant = "ghost",
      enabled = status.remaining ~= nil,
      onClick = function()
        C.send("cancel-timer")
      end,
    })
  )
  table.insert(body, ui.separator({}))
  table.insert(
    body,
    ui.row({ align = "center", gap = 8 }, {
      ui.column({ flexGrow = 1, gap = 2 }, {
        ui.label({ text = noctalia.tr("panel.lid") }),
        ui.label({ text = noctalia.tr("panel.lid_hint"), fontSize = 11, color = "on_surface_variant" }),
      }),
      ui.toggle({
        checked = status.lidEnabled == true,
        onChange = function(value)
          C.send("lid", if value == "true" then "on" else "off")
        end,
      }),
    })
  )

  panel.render(ui.scroll({ gap = 10, padding = 14 }, body))
end

noctalia.state.watch(C.STATUS, function(value)
  if type(value) == "table" then
    status = value
    render()
  end
end)

function onOpen(_context)
  isOpen = true
  status = C.status()
  render()
end

function onClose()
  isOpen = false
end
