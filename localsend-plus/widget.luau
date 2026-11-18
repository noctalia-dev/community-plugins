--!nonstrict
-- Bar widget: send glyph with a counter of pending requests and active
-- transfers; click toggles the panel.

local lib = require("./lib.luau")

local function tr(key, args)
  return noctalia.tr(key, args)
end

local function refresh(ls)
  ls = ls or noctalia.state.get("ls") or {}
  local pending = ls.incoming ~= nil and 1 or 0
  local active = 0
  for _, t in ipairs(ls.transfers or {}) do
    if lib.ACTIVE[t.state] then active = active + 1 end
  end

  if pending + active > 0 then
    barWidget.setText(tostring(pending + active))
    barWidget.setGlyphColor("primary", "script")
  else
    barWidget.setText("")
    barWidget.setGlyphColor("on_surface")
  end
  barWidget.setGlyph(ls.up and "send" or "send-off")

  local tip = { tr("widget.tooltip") }
  if not ls.up then
    table.insert(tip, ls.startError or tr("panel.starting"))
  else
    if pending > 0 then table.insert(tip, tr("widget.request")) end
    if active > 0 then table.insert(tip, tr("widget.active", { count = tostring(active) })) end
  end
  local vis = ls.vis
  if vis ~= nil then
    local mode = (vis.tempUntil or 0) > 0
        and tr(
          "visibility.temp_left",
          { minutes = tostring(lib.minutesLeft(vis.tempUntil)), mode = tr("visibility." .. vis.base) }
        )
      or tr("visibility." .. vis.mode)
    table.insert(tip, tr("widget.visibility", { mode = mode }))
  end
  barWidget.setTooltip(table.concat(tip, "\n"))
end

function onClick()
  noctalia.togglePanel(lib.PANEL)
end

function onRightClick()
  noctalia.openSettings()
end

function onIpc(event)
  if event == "toggle" then noctalia.togglePanel(lib.PANEL) end
end

noctalia.state.watch("ls", refresh)
refresh()
