--!nonstrict
-- Bar [[widget]] entry: glyph + open-PR count, fed entirely by the fetch
-- service through shared state. The glyph tints error-red when fetching
-- itself failed; details remain available in the panel.
-- Clicking anywhere on the capsule toggles the panel —
-- which is why the tree deliberately contains no inline ui.button (inline
-- controls would consume their own clicks).

local PANEL_ID = "raycursive/github-prs:panel"

local counts = noctalia.state.get("counts")
local fetchStatus = noctalia.state.get("fetch_status") or "loading"

local function countText()
  if counts ~= nil then
    return tostring(counts.total)
  end
  if fetchStatus == "error" then
    return "!"
  end
  return "…"
end

local function render()
  local hideWhenZero = noctalia.getConfig("hide_when_zero") == true
  if hideWhenZero and fetchStatus == "ok" and counts ~= nil and counts.total == 0 then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)

  local glyph = noctalia.getConfig("glyph")
  if type(glyph) ~= "string" or glyph == "" then
    glyph = "git-pull-request"
  end
  local isVertical = barWidget.isVertical()
  local container = isVertical and ui.column or ui.row
  local layout = { gap = 4, align = "center" }
  if isVertical then
    layout.paddingV = 4
  else
    layout.paddingH = 4
  end
  barWidget.render(container(layout, {
    ui.glyph({
      name = glyph,
      size = 16,
      color = fetchStatus == "error" and "error" or "on_surface",
    }),
    ui.label({
      text = countText(),
      color = "on_surface",
    }),
  }))
end

-- fetch_status is published last by the service, so one watcher on it sees a
-- consistent prs/counts snapshot; the counts watcher covers same-status updates.
noctalia.state.watch("counts", function(value)
  counts = value
  render()
end)

noctalia.state.watch("fetch_status", function(value)
  fetchStatus = value
  render()
end)

render()

function update()
  noctalia.setUpdateInterval(5000)
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onConfigChanged()
  render()
end
