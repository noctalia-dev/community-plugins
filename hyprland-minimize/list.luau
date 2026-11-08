--!nonstrict
-- Panel: list of minimized windows (the "menu" for short bars, or the "+N" of long ones).
-- Clicking a window restores it. The data comes from the service through the shared state.

local windows = {}
local isOpen = false

local function decode(value)
  if type(value) ~= "string" or value == "" then return {} end
  local data = noctalia.json.decode(value)
  if type(data) == "table" then return data end
  return {}
end

local function send(action, address)
  local text = noctalia.json.encode({ action = action, address = address, n = noctalia.nowMs() })
  if text then noctalia.state.set("cmd", text) end
end

local function iconFor(cls)
  local path = cls ~= "" and noctalia.appIconPath(cls, 28) or nil
  if path then
    return ui.image({ path = path, width = 26, height = 26, fit = "contain" })
  end
  return ui.glyph({ name = "app-window", size = 22, color = "on_surface_variant" })
end

local function render()
  local header = {
    ui.label({
      text = noctalia.tr("panel.title"),
      fontSize = 16,
      fontWeight = "bold",
      color = "on_surface",
      flexGrow = 1,
    }),
  }
  if #windows > 1 then
    table.insert(header, ui.button({
      text = noctalia.tr("panel.restore_all"),
      variant = "outline",
      controlSize = "sm",
      onClick = function()
        send("restore-all")
        panel.close()
      end,
    }))
  end
  table.insert(header, ui.button({
    glyph = "x",
    variant = "ghost",
    tooltip = noctalia.tr("panel.close"),
    onClick = function() panel.close() end,
  }))

  local body
  if #windows == 0 then
    body = ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 8 }, {
      ui.glyph({ name = "arrows-diagonal-minimize-2", size = 28, color = "on_surface_variant" }),
      ui.label({ text = noctalia.tr("panel.empty"), color = "on_surface_variant" }),
    })
  else
    local rows = {}
    for _, w in ipairs(windows) do
      local addr = w.address
      local title = w.title ~= "" and w.title or w.class
      table.insert(rows, ui.row({
        key = addr,
        gap = 12,
        align = "center",
        paddingH = 12,
        paddingV = 9,
        radius = 12,
        fill = "on_surface/0.09",
        onClick = function()
          send("restore", addr)
          panel.close()
        end,
      }, {
        iconFor(w.class),
        ui.column({ flexGrow = 1, gap = 2, align = "start" }, {
          ui.label({ text = title, color = "on_surface", fontWeight = "medium", maxLines = 1 }),
          ui.label({ text = w.class, color = "on_surface_variant", fontSize = 11, maxLines = 1 }),
        }),
        ui.glyph({ name = "arrow-back-up", size = 18, color = "primary" }),
      }))
    end
    body = ui.scroll({ flexGrow = 1, gap = 8 }, rows)
  end

  panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, header),
    body,
    ui.label({ text = noctalia.tr("panel.hint"), color = "on_surface_variant", fontSize = 11 }),
  }))
end

function onOpen(_context)
  isOpen = true
  windows = decode(noctalia.state.get("windows"))
  render()
end

function onClose()
  isOpen = false
end

noctalia.state.watch("windows", function(value)
  windows = decode(value)
  if isOpen then render() end
end)
