--!nonstrict
-- Layout picker panel: lists the layouts enabled in kwinrc and switches
-- the active output's current desktop on click.

local KIND_INFO = {
  MasterStack = { display = "MasterStack",   glyph = "layout-sidebar-right" },
  Stacked     = { display = "Stacked",        glyph = "layout-rows" },
  CenterTile  = { display = "Center Tile",    glyph = "layout-columns" },
  Monocle     = { display = "Monocle",        glyph = "rectangle" },
  AutoGrid    = { display = "Auto Grid",      glyph = "layout-grid" },
  Columns     = { display = "Columns",        glyph = "columns-3" },
}

local isOpen = false

local function selectLayout(kind)
  local state = noctalia.state.get("layout")
  local qdbus = (state and state.qdbus) or "qdbus-qt6"
  noctalia.runAsync(qdbus .. " org.kde.KWin /Tiling org.kde.KWin.Tiling.setLayout " .. kind)
  panel.close()
end

local function render()
  local state = noctalia.state.get("layout")

  local children = {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = "Layouts", fontSize = 16, fontWeight = "bold", color = "primary", flexGrow = 1 }),
      ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
    }),
    ui.separator({}),
  }

  if state == nil or not state.ok then
    table.insert(children, ui.label({
      text = "KineticWE /Tiling DBus interface not found. Rebuild KineticWE and log back in.",
      maxLines = 3,
    }))
  elseif #state.enabled == 0 then
    table.insert(children, ui.label({ text = "No layouts enabled in kwinrc ([Tiling] EnabledLayouts)." }))
  else
    for _, kind in ipairs(state.enabled) do
      local info = KIND_INFO[kind] or { display = kind, glyph = "layout-grid" }
      table.insert(children, ui.button({
        key = "layout-" .. kind,
        text = info.display,
        glyph = info.glyph,
        variant = (kind == state.current) and "primary" or "default",
        contentAlign = "start",
        onClick = function()
          selectLayout(kind)
        end,
      }))
    end
  end

  panel.render(ui.column({ gap = 6, padding = 10 }, children))
end

function onOpen(_context)
  isOpen = true
  render()
end

function onClose()
  isOpen = false
end

function onCloseClicked()
  panel.close()
end

-- Keep the highlight in sync if the layout changes while the panel is open
-- (e.g. a keybind cycle).
noctalia.state.watch("layout", function()
  if isOpen then
    render()
  end
end)
