--!nonstrict
-- Reference [[panel]] entry - a settings-style panel of interactive controls.
--
-- Panels describe their UI declaratively, exactly like desktop widgets: build a
-- tree with the ui.* constructors and hand it to panel.render(). The host diffs
-- the tree against the previous one and updates retained native controls, so
-- rendering an unchanged tree is free.
--
--   panel.render(tree)              replace the panel's UI tree
--   panel.close()                   ask the host to close this panel
--   noctalia.getConfig(key)         settings (seeded from the manifest)
--   noctalia.openColorPicker(...)   open the native color picker asynchronously
--   button/toggle/slider/...        onClick / onChange accept a closure or the
--                                   name of a plugin global; values arrive as
--                                   string args
--
-- Layout notes:
--   * a Flex (column/row/scroll) centers its children on the cross axis by
--     default - pass align = "stretch" so controls fill the panel width.
--   * panel size is host-owned: declare width/height on the [[panel]] manifest
--     entry, so the surface is the same size on every open.
--
-- Stateful controls follow a controlled/uncontrolled split:
--   * toggle / slider / select are value-driven - pass the current value each
--     render; the callback reports the user's new value.
--   * input is uncontrolled - `value` seeds the field once; the host owns the
--     text buffer afterward, so re-rendering never clobbers what the user typed.
--     Observe edits via onChange (live) / onSubmit (Enter).

local enabled = true
local volume = 50
local greeting = ""
local themeIndex = 0
local themes = { "Dark", "Light", "System" }
local selectedColor = "#FFF59B"
local colorPickerStatus = "Choose a color to test the dialog callback."

-- A labelled section: a heading above a control. ui.column stretches children to
-- the panel width by default, so the control fills the row.
local function section(title, control)
  return ui.column({ gap = 8 }, {
    ui.label({ text = title, fontWeight = "medium", color = "on_surface_variant" }),
    control,
  })
end

local function render()
  -- The panel surface already insets its content (Style::panelPadding), so this
  -- adds gaps between rows, not its own outer padding.
  panel.render(ui.column({ flexGrow = 1, gap = 16 }, {
    -- Header: title on the left, close button pinned to the top right -
    -- matching the built-in panels (no divider rule).
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({ text = "Example Panel", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
      ui.button({ glyph = "close", onClick = "onCloseClicked" }),
    }),

    -- Body: a scrollable stack of settings.
    ui.scroll({ flexGrow = 1, gap = 16 }, {
      section("Notifications", ui.row({ gap = 12, align = "center" }, {
        ui.toggle({ checked = enabled, onChange = "onToggle" }),
        ui.label({ text = enabled and "Enabled" or "Disabled", flexGrow = 1 }),
      })),

      section(`Volume - {volume}%`, ui.slider({
        min = 0, max = 100, step = 1, value = volume, onChange = "onVolume",
      })),

      section("Your name (press Enter to greet)", ui.column({ gap = 8 }, {
        ui.input({ key = "name", placeholder = "Type a name…", onSubmit = "onNameSubmit" }),
        ui.label({ text = greeting, color = "primary" }),
      })),

      section("Theme", ui.select({ options = themes, selectedIndex = themeIndex, onChange = "onTheme" })),

      section("Color picker", ui.column({ gap = 8 }, {
        ui.row({ gap = 12, align = "center" }, {
          ui.button({ text = "Choose color", onClick = "onColorPickerClicked" }),
          ui.box({ width = 32, height = 32, radius = 8, fill = selectedColor, border = "outline", borderWidth = 1 }),
          ui.label({ text = selectedColor, color = "on_surface", flexGrow = 1 }),
        }),
        ui.label({ text = colorPickerStatus, color = "on_surface_variant" }),
      })),
    }),
  }))
end

function onOpen(_context)
  render()
end

function onToggle(value)
  enabled = value == "true"
  render()
end

function onVolume(value)
  volume = math.floor(tonumber(value) or 0)
  render()
end

function onNameSubmit(value)
  greeting = value ~= "" and `Hello, {value}!` or ""
  noctalia.notify("Example Panel", greeting)
  render()
end

function onTheme(index, _text)
  themeIndex = tonumber(index) or 0
  render()
end

function onColorPickerClicked()
  local accepted = noctalia.openColorPicker(selectedColor, function(color)
    if color == nil then
      colorPickerStatus = "Color selection cancelled."
    else
      selectedColor = color
      colorPickerStatus = `Callback returned {color}.`
    end
    render()
  end)

  if not accepted then
    colorPickerStatus = "A color picker callback is already pending."
    render()
  end
end

function onCloseClicked()
  panel.close()
end
