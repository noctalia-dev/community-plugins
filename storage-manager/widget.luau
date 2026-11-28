--!nonstrict
-- Storage Manager bar widget: a drive glyph and the free space on one
-- filesystem. Click opens the panel; the tooltip lists every filesystem.

local common = require("./lib/common.luau")

local function render(data)
  barWidget.setGlyph("database")
  local vols = data and data.volumes or nil
  if vols == nil then
    barWidget.setText("")
    barWidget.setTooltip(noctalia.tr("widget.title"))
    return
  end
  local want = noctalia.getConfig("mount") or "/"
  local shown = nil
  for _, v in ipairs(vols) do
    if v.mount == want then
      shown = v
    end
  end
  shown = shown or vols[1]

  local limit = tonumber(noctalia.getConfig("low_space_percent")) or 10
  local low = shown ~= nil and common.freePercent(shown) < limit
  if noctalia.getConfig("show_free") and shown then
    barWidget.setText(common.size(shown.avail))
  else
    barWidget.setText("")
  end
  barWidget.setGlyphColor(low and "error" or "on_surface")

  local rows = {}
  for _, v in ipairs(vols) do
    table.insert(rows, {
      key = v.name,
      value = noctalia.tr("widget.free_of", { free = common.size(v.avail), size = common.size(v.size) }),
    })
  end
  barWidget.setTooltip(rows)
end

noctalia.state.watch("volumes", render)
render(noctalia.state.get("volumes"))

function onClick()
  noctalia.togglePanel(common.PANEL)
end

function onRightClick()
  noctalia.state.set("refresh_request", noctalia.nowMs())
end
