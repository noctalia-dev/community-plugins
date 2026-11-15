--!nonstrict
-- Flatpak Background Apps bar widget - the glyph and the number of background
-- Flatpak apps. Clicking it toggles the panel. By default it is hidden while no
-- app runs in the background; with always_show on it stays in the bar, and the
-- count is left out while it is 0. When a scan fails it shows "!" and says so in
-- the tooltip.
--
-- State (read): flatpak_bg.apps, flatpak_bg.error (published by the service)
-- Settings (widget): glyph, always_show, show_count

local PANEL_ID = "naijnus/flatpak-bg:panel"
local BULLET = "• "

local function render()
  local apps = noctalia.state.get("flatpak_bg.apps") or {}
  local scanError = noctalia.state.get("flatpak_bg.error") == true
  local count = #apps
  -- Read on every render, so a settings change shows on the next one
  local alwaysShow = noctalia.getConfig("always_show") == true
  local showCount = noctalia.getConfig("show_count") ~= false

  local visible = count > 0 or scanError or alwaysShow
  barWidget.setVisible(visible)
  if not visible then
    barWidget.clearTooltip()
    return
  end

  barWidget.setGlyph(noctalia.getConfig("glyph"))
  local text = ""
  if scanError and count == 0 then
    text = "!"
  elseif showCount and count > 0 then
    text = tostring(count)
  end
  barWidget.setText(text)

  local lines = {}
  if scanError then table.insert(lines, noctalia.tr("widget.scan_error")) end
  if count > 0 then
    table.insert(lines, noctalia.trp("widget.tooltip", count))
    for _, app in ipairs(apps) do table.insert(lines, BULLET .. app.name) end
  elseif not scanError then
    table.insert(lines, noctalia.tr("widget.empty"))
  end
  barWidget.setTooltip(table.concat(lines, "\n"))
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onConfigChanged()
  render()
end

noctalia.state.watch("flatpak_bg.apps", render)
noctalia.state.watch("flatpak_bg.error", render)
render()
