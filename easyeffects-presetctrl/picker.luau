local enabled = true
local presetIndex = 0
local presets = {}
local title = "Easy Effects Preset Picker"

local function section(title, control)
  return ui.column({ gap = 8 }, {
    ui.label({ text = title, fontWeight = "medium", color = "on_surface_variant" }),
    control,
  })
end

local function render()
  panel.render(ui.column({ flexGrow = 1, gap = 16 }, {
    
    -- Header
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({ text = title, fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
      ui.button({ glyph = "close", onClick = "onCloseClicked" }),
    }),

    -- Body
    ui.scroll({ flexGrow = 1, gap = 16 }, {
      section("Preset", ui.select({ options = presets, selectedIndex = presetIndex, onChange = "onPreset" })),

      section("Enable EasyEffects?", ui.row({ gap = 12, align = "center" }, {
        ui.toggle({ checked = enabled, onChange = "onToggle" }),
        ui.label({ text = enabled and "Enabled" or "Disabled", flexGrow = 1 }),
      })),

    }),
  }))
end

function onOpen(_context)
  local inOutputPresets = false
  presets = {}

  noctalia.runStream(
    "easyeffects -p",
    function(line)
      if line == "Output presets:" then
        inOutputPresets = true
        return
      end

      if line == "Input presets:" or line == "No input presets." then
        inOutputPresets = false
        return
      end

      if inOutputPresets then
        -- Match: "^<index><TAB><preset>$"
        local preset = line:match("^%d+\t(.+)$")

        if preset then
          table.insert(presets, preset)
          render()
        end
      end
    end
  )
end

function onToggle(value)
  enabled = value == "true"
  render()
end

function onPreset(index, _text)
  presetIndex = tonumber(index) or 0
  noctalia.notify("EasyEffects PresetCTRL", table.concat({"Setting preset: ", presets[presetIndex +1]}))
  if not noctalia.commandExists("easyeffects") then
  noctalia.notify("EasyEffects PresetCTRL", table.concat({"Can't set preset: ", presets[presetIndex +1]}))
  end

  noctalia.runStream(
    table.concat({"easyeffects -l", '"' .. presets[presetIndex + 1] .. '"'}),
    function(line)
      noctalia.notify("EasyEffects PresetCTRL", line)
    end)
    
  render()
end

function onCloseClicked()
  panel.close()
end
