--!nonstrict
-- Declarative bar widget: renders a ui.* tree with barWidget.render() instead
-- of the imperative setText/setGlyph patches (hello.luau). The tree replaces
-- the built-in glyph/text row. Pointer controls (ui.button, ui.toggle, …) work
-- inline and consume their own clicks; the widget-level onClick still fires on
-- the rest of the capsule. Keyboard controls (ui.input/ui.select/ui.scroll)
-- are not available in the bar. The capsule clips to bar thickness, so keep
-- the tree one control tall.

local clicks = 0
local tick = noctalia.state.get("tick") or 0

local function render()
  -- Stack along the bar: a row in a horizontal bar, a column in a side bar.
  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 6, align = "center" }, {
    ui.glyph({ name = "sparkles", size = 14, color = "secondary" }),
    -- A filled rounded badge - something the imperative setText/setGlyph API
    -- cannot draw. "secondary/0.25" is the secondary role at 25% alpha, so the
    -- pill stays theme-aware while the text on it remains fully opaque.
    ui.row({ fill = "secondary/0.25", radius = 8, paddingH = 6, align = "center" }, {
      ui.label({ text = tostring(tick), color = "secondary", fontWeight = "bold" }),
    }),
    -- Function-valued callbacks (plugin_api >= 9) are render-scoped closures.
    -- They can capture local state directly without defining a plugin global.
    ui.button({
      glyph = "plus",
      glyphSize = 12,
      variant = "ghost",
      onClick = function()
        clicks += 1
        noctalia.notify(noctalia.tr("title"), noctalia.trp("clicks", clicks))
      end,
    }),
  }))
end

-- Live updates from the plugin's background service (ticker.luau).
noctalia.state.watch("tick", function(value)
  tick = value
  render()
end)

function update()
  noctalia.setUpdateInterval(1000)
  render()
end
