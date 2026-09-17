--!nonstrict
-- The panel vocabulary both display panels are built from.
--
-- Pure functions taking their state as arguments, since every entry script runs
-- in its own Luau state and the two panels would otherwise each carry a copy.

local M = {}

M.PADDING = 16
M.RADIUS = 14

-- A handful of choices reads better as a row of buttons than as a list behind a
-- dropdown. Long labels fit three to a row, short ones four; past the limit the
-- wrapping costs more height than the select it replaces.
M.CHIP_LIMIT = 8

function M.card(children)
  return ui.column({ gap = 14, padding = M.PADDING, radius = M.RADIUS, fill = "surface_variant" }, children)
end

function M.heading(text, trailing)
  local children = { ui.label({ text = text, fontSize = 15, fontWeight = "bold", flexGrow = 1 }) }
  if trailing ~= nil then
    table.insert(children, trailing)
  end
  return ui.row({ align = "center", gap = 8 }, children)
end

-- Caption above the control, not a label column: a fixed gutter leaves every
-- select stranded in the middle of the panel.
function M.control(caption, node, reading)
  local head = { ui.label({ text = caption, fontSize = 13, fontWeight = "bold", flexGrow = 1 }) }
  if reading ~= nil then
    table.insert(head, ui.label({ text = reading, fontSize = 13, fontWeight = "bold", color = "primary" }))
  end
  return ui.column({ gap = 6 }, {
    ui.row({ align = "center", gap = 8 }, head),
    node,
  })
end

-- A range wide enough that stepping through it is not an option. The host emits
-- onChange while dragging and again when it applies a controlled value, so the
-- caller has to feed its own preview back in as `value`: passing the stored
-- number instead resets the handle under the pointer.
function M.slider(value, low, high, step, onPreview, onSet)
  return ui.slider({
    key = "slider",
    min = low,
    max = high,
    step = step,
    value = value,
    controlSize = "sm",
    onChange = function(next)
      onPreview(tonumber(next) or value)
    end,
    onDragEnd = function(next)
      onSet(tonumber(next) or value)
    end,
  })
end

function M.chips(labels, current, onPick)
  local widest = 0
  for _, label in ipairs(labels) do
    widest = math.max(widest, #label)
  end
  local perRow = widest > 6 and 3 or 4

  local rows, row = {}, {}
  for _, label in ipairs(labels) do
    if #row == perRow then
      table.insert(rows, ui.row({ gap = 8 }, row))
      row = {}
    end
    local picked = label == current
    table.insert(row, ui.button({
      key = "chip-" .. label,
      text = label,
      controlSize = "sm",
      flexGrow = 1,
      variant = picked and "primary" or "outline",
      selected = picked,
      onClick = function()
        onPick(label)
      end,
    }))
  end
  if #row > 0 then
    -- The last row keeps the others' button width instead of stretching.
    for _ = #row + 1, perRow do
      table.insert(row, ui.spacer({ flexGrow = 1 }))
    end
    table.insert(rows, ui.row({ gap = 8 }, row))
  end
  return ui.column({ gap = 8 }, rows)
end

-- Three equal segments on the chip grid's rhythm, with the count wearing the
-- same tint a picked chip does.
function M.stepper(value, low, high, step, onSet)
  local function arrow(label, to, enabled)
    return ui.button({
      text = label,
      controlSize = "sm",
      variant = "outline",
      flexGrow = 1,
      enabled = enabled,
      onClick = function()
        onSet(to)
      end,
    })
  end

  return ui.row({ gap = 8, align = "center" }, {
    arrow("-", math.max(value - step, low), value > low),
    ui.row({ justify = "center", align = "center", flexGrow = 1, paddingV = 8, radius = 8, fill = "primary" }, {
      ui.label({ text = tostring(value), fontSize = 13, fontWeight = "bold", color = "on_primary" }),
    }),
    arrow("+", math.min(value + step, high), value < high),
  })
end

function M.toggleRow(caption, checked, onSet, key)
  return ui.row({ align = "center", gap = 10 }, {
    ui.label({ text = caption, fontSize = 13, fontWeight = "bold", flexGrow = 1 }),
    ui.toggle({
      key = key,
      checked = checked,
      onChange = function(value)
        onSet(value == "true")
      end,
    }),
  })
end

-- One tile per display, the active one tinted, the way the control center marks
-- a live toggle.
function M.tiles(outputs, selectedName, onPick)
  local tiles = {}
  for _, entry in ipairs(outputs) do
    local active = entry.name == selectedName
    local name = entry.name
    table.insert(tiles, ui.row({
      key = "pick-" .. name,
      gap = 6,
      align = "center",
      justify = "center",
      paddingV = 9,
      radius = M.RADIUS,
      flexGrow = 1,
      fill = active and "primary" or "surface_variant",
      onClick = function()
        onPick(name)
      end,
    }, {
      ui.glyph({
        name = entry.enabled and "device-desktop" or "device-desktop-off",
        size = 15,
        color = active and "on_primary" or "on_surface_variant",
      }),
      ui.label({
        text = name,
        fontSize = 12,
        fontWeight = "medium",
        color = active and "on_primary" or "on_surface",
      }),
    }))
  end
  return ui.row({ gap = 8 }, tiles)
end

function M.hero(text, glyph, handler)
  return ui.button({
    text = text,
    glyph = glyph,
    variant = "primary",
    controlSize = "lg",
    onClick = handler,
  })
end

function M.message(text)
  return ui.column({ flexGrow = 1, gap = 10, align = "center", justify = "center" }, {
    ui.glyph({ name = "device-desktop-off", size = 26, color = "on_surface_variant" }),
    ui.label({ text = text, fontSize = 13, color = "on_surface_variant", textAlign = "center" }),
  })
end

function M.header(title, buttons)
  local children = { ui.label({ text = title, fontSize = 15, fontWeight = "semibold", color = "primary", flexGrow = 1 }) }
  for _, button in ipairs(buttons) do
    table.insert(children, button)
  end
  return ui.row({ align = "center", gap = 6 }, children)
end

return M
