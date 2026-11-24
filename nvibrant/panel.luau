--!nonstrict
-- NVibrant panel: on/off toggle and a saturation slider (0..1023) with live preview.
local core = require("./core.luau")

local state = core.load()

local function draw()
  panel.render(ui.column({ gap = 12, padding = 16 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "contrast", color = state.enabled and "primary" or "on_surface" }),
      ui.label({ text = noctalia.tr("panel.title"), fontWeight = "bold", flexGrow = 1 }),
      ui.toggle({
        checked = state.enabled,
        onChange = function(on)
          state.enabled = on == true
          core.save(state)
          core.apply(state.enabled and state.level or 0)
          draw()
        end,
      }),
    }),
    ui.row({ gap = 12, align = "center" }, {
      ui.slider({
        min = 0, max = core.MAX, step = 1, value = state.level, flexGrow = 1,
        onChange = function(v)
          state.level = math.floor(tonumber(v) or 0)
          if state.enabled then core.apply(state.level) end
        end,
        onDragEnd = function()
          core.save(state)
          draw()
        end,
      }),
      ui.label({ text = tostring(state.level), width = 48 }),
    }),
  }))
end

function onOpen()
  state = core.load()
  draw()
end
