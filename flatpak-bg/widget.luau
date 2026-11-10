--!nonstrict
-- Bar widget: hidden when nothing runs in the background,
-- otherwise shows the glyph and the number of background apps.
-- When a scan fails it stays visible and says so in the tooltip.

local PANEL_ID = "naijnus/flatpak-bg:panel"

local function render()
  local apps = noctalia.state.get("bg_apps") or {}
  local scanError = noctalia.state.get("bg_error") == true
  local count = #apps

  barWidget.setVisible(count > 0 or scanError)
  if count == 0 and not scanError then
    barWidget.clearTooltip()
    return
  end

  barWidget.setGlyph(noctalia.getConfig("glyph"))
  barWidget.setText(count > 0 and tostring(count) or "!")

  local lines = {}
  if scanError then table.insert(lines, noctalia.tr("widget.scan_error")) end
  if count > 0 then
    table.insert(lines, noctalia.trp("widget.tooltip", count))
    for _, app in ipairs(apps) do table.insert(lines, app.name) end
  end
  barWidget.setTooltip(table.concat(lines, "\n"))
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onConfigChanged()
  render()
end

noctalia.state.watch("bg_apps", render)
noctalia.state.watch("bg_error", render)
render()
