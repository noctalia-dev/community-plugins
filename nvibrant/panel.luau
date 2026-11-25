--!nonstrict
-- NVibrant panel: on/off toggle and a saturation slider (0..1023) with live preview. The toggle shows what is
-- actually applied, not what was last requested.
local core = require("./core.luau")

local state = core.load()

local function draw()
  local on = core.appliedOn()
  panel.render(ui.column({ gap = 12, padding = 16 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "contrast", color = on and "primary" or "on_surface" }),
      ui.label({ text = noctalia.tr("panel.title"), fontWeight = "bold", flexGrow = 1 }),
      ui.toggle({
        checked = on,
        onChange = function(v)
          core.setEnabled(v == true or v == "true", function() draw() end)
        end,
      }),
    }),
    ui.row({ gap = 12, align = "center" }, {
      ui.slider({
        min = 0, max = core.MAX, step = 1, value = state.level, flexGrow = 1,
        onChange = function(v)
          state.level = math.floor(tonumber(v) or 0)
          if core.appliedOn() then core.apply(state.level) end
        end,
        onDragEnd = function()
          -- the level is a preference: keep it even while off, so switching on uses it
          local saved = core.load()
          saved.level = state.level
          core.save(saved)
          draw()
        end,
      }),
      ui.label({ text = tostring(state.level), width = 48 }),
    }),
  }))
end

noctalia.state.watch("applied", function() draw() end)

function onOpen()
  state = core.load()
  draw()
end
