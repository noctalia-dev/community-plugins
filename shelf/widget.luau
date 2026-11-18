--!nonstrict
-- Bar widget: shelf glyph plus a count. Left click opens the panel, right
-- click toggles the drop window.

local store = require("./lib/store.luau")

local function render(items)
  local count = #items
  local showCount = noctalia.getConfig("show_count") ~= false
  barWidget.setGlyph(noctalia.getConfig("glyph") or "stack-2")
  barWidget.setText((showCount and count > 0) and tostring(count) or "")
  barWidget.setGlyphColor(count > 0 and "primary" or "on_surface")
  barWidget.setVisible(count > 0 or not noctalia.getConfig("hide_when_empty"))
  if count == 0 then
    barWidget.setTooltip({
      { noctalia.tr("widget.tooltip.title"), noctalia.tr("widget.tooltip.empty") },
      { noctalia.tr("widget.tooltip.click"), noctalia.tr("widget.tooltip.open_panel") },
      { noctalia.tr("widget.tooltip.right_click"), noctalia.tr("widget.tooltip.drop_window") },
    })
  else
    barWidget.setTooltip({
      { noctalia.tr("widget.tooltip.title"), noctalia.trp("common.files", count) },
      { noctalia.tr("widget.tooltip.latest"), store.basename(items[1].path) },
      { noctalia.tr("widget.tooltip.click"), noctalia.tr("widget.tooltip.open_panel") },
      { noctalia.tr("widget.tooltip.right_click"), noctalia.tr("widget.tooltip.drop_window") },
    })
  end
end

noctalia.state.watch(store.ITEMS_KEY, function(items)
  if type(items) == "table" then
    render(items)
  end
end)

render(store.current())

function onClick()
  noctalia.togglePanel(store.PANEL_ID)
end

function onRightClick()
  store.request("toggle")
end
