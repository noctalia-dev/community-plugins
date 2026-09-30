--!nonstrict
-- settings.luau: Declarative UI panel for Saved Desktop Widgets

local saveWidgets = noctalia.getConfig("saveWidgets")
local loadWidgets = noctalia.getConfig("loadWidgets")
local monitorWidgets = noctalia.state.get("monitorWidgets") or {}

local function render()
  local widgetRows = {}

  -- Dynamically build a row for each saved wallpaper layout
  for wallpaper, layoutData in pairs(monitorWidgets) do
    -- Extract just the filename for a cleaner display
    local fileName = wallpaper:match("([^/]+)%.%w+$") or wallpaper

    table.insert(widgetRows, ui.row({
      align = "center", justify = "space_between", padding = 8, fill = "surface_variant/0.2", radius = 8
    }, {
      ui.label({ text = fileName, flexGrow = 1 }),
      ui.button({
        glyph = "trash",
        variant = "ghost",
        tooltip = noctalia.tr("settings.remove_widget"),
        onClick = function()
          monitorWidgets[wallpaper] = nil
          noctalia.state.set("monitorWidgets", monitorWidgets)
          render()
        end
      })
    }))
  end

  if #widgetRows == 0 then
    table.insert(widgetRows, ui.label({
      text = noctalia.tr("settings.no_widgets_saved"), color = "on_surface_variant", align = "center", padding = 16
    }))
  end

  -- Render the entire UI tree to the panel
  panel.render(ui.column({ flexGrow = 1, gap = 16, padding = 16 }, {
    -- Header
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({ text = noctalia.tr("settings.title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
      ui.button({ glyph = "close", onClick = "onCloseClicked" }),
    }),

    -- Scrollable settings body
    ui.scroll({ flexGrow = 1, gap = 24 }, {

      -- Toggles section
      ui.column({ gap = 8 }, {
        ui.label({ text = noctalia.tr("settings.general"), fontWeight = "medium", color = "on_surface_variant" }),
        ui.row({ gap = 12, align = "center" }, {
          ui.toggle({ checked = saveWidgets, onChange = "onSaveToggled" }),
          ui.label({ text = noctalia.tr("settings.save_widgets_auto"), flexGrow = 1 }),
        }),
        ui.row({ gap = 12, align = "center" }, {
          ui.toggle({ checked = loadWidgets, onChange = "onLoadToggled" }),
          ui.label({ text = noctalia.tr("settings.load_widgets_auto"), flexGrow = 1 }),
        }),
      }),

      -- Saved Layouts list section
      ui.column({ gap = 8 }, {
        ui.row({ align = "center", justify = "space_between" }, {
          ui.label({ text = noctalia.tr("settings.saved_layouts"), fontWeight = "medium", color = "on_surface_variant" }),
          ui.button({
            text = noctalia.tr("settings.nuke_all"),
            glyph = "trash",
            onClick = function()
              monitorWidgets = {}
              noctalia.state.set("monitorWidgets", monitorWidgets)
              noctalia.notify(noctalia.tr("settings.title"), noctalia.tr("settings.nuke_all_notification"))
              render()
            end
          }),
        }),
        ui.column({ gap = 8 }, widgetRows),
      }),
    }),
  }))
end

function onOpen(_context)
  -- Fetch the freshest state from the background service whenever the panel opens
  monitorWidgets = noctalia.state.get("monitorWidgets") or {}
  saveWidgets = noctalia.state.get("saveWidgets") or noctalia.getConfig("saveWidgets")
  loadWidgets = noctalia.state.get("loadWidgets") or noctalia.getConfig("loadWidgets")
  render()
end

function onCloseClicked()
  panel.close()
end

function onSaveToggled(value)
  saveWidgets = value == "true"
  noctalia.state.set("saveWidgets", saveWidgets)
  render()
end

function onLoadToggled(value)
  loadWidgets = value == "true"
  noctalia.state.set("loadWidgets", loadWidgets)
  render()
end
