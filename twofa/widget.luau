--!nonstrict
-- Bar widget: a glyph that opens the codes panel; the tooltip says how many accounts are
-- stored, or that the keyring could not be read.

local store = require("./store.luau")

local tr = noctalia.tr

local function render()
  local glyph = noctalia.getConfig("glyph")
  barWidget.setGlyph((type(glyph) == "string" and glyph ~= "") and glyph or "shield-lock")
  local s = store.current()
  if s.status == "error" then
    barWidget.setGlyphColor("error")
    barWidget.setTooltip(tr("widget.error"))
  else
    barWidget.setGlyphColor("on_surface")
    barWidget.setTooltip(tr("widget.tooltip", { count = #s.accounts }))
  end
end

noctalia.state.watch(store.STATE_KEY, function()
  render()
end)

function onClick()
  noctalia.togglePanel(store.PANEL_ID)
end

function onConfigChanged()
  render()
end

render()
