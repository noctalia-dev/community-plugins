--!nonstrict
-- VS Code bar widget - a thin client: the editor's icon (or the brand glyph), the editor's
-- name when show_label is on, and a click that toggles the panel. No status, no counts.

local PANEL_ID = "3dprogramin/vscode:panel"

local snapshot = nil
local applied = nil -- what was last pushed to barWidget, so ticks don't re-set the image

local function render()
  local flavor = type(snapshot) == "table" and snapshot.flavor or nil
  local icon = flavor and flavor.iconPath or nil
  if type(icon) ~= "string" or icon == "" then
    icon = nil
  end
  local text = ""
  if noctalia.getConfig("show_label") == true then
    text = flavor and flavor.name or noctalia.tr("plugin.name")
  end
  local tooltip = noctalia.tr("bar.tooltip")
  local sig = tostring(icon) .. "\n" .. text .. "\n" .. tooltip
  if sig == applied then
    return
  end
  applied = sig
  if icon then
    barWidget.setImage(icon)
  else
    barWidget.setGlyph("brand-vscode")
  end
  barWidget.setText(text)
  barWidget.setTooltip(tooltip)
end

-- Re-applies each tick; this is how a show_label change takes effect.
function update()
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

noctalia.state.watch("vscode.state", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

render()

-- state.watch does not replay an old value, so ask the service for a snapshot.
noctalia.state.set("vscode.request", { action = "refresh", requestId = "bar-" .. tostring(noctalia.nowMs()) })
