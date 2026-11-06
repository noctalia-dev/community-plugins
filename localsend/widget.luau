--!nonstrict
-- Bar widget: icon with a badge-ish label; click opens the panel.

local PANEL = "mera/localsend:panel"

local function refresh(ls)
  ls = ls or noctalia.state.get("ls") or {}
  local pending, active = 0, 0
  for _, s in ipairs(ls.sessions or {}) do
    if s.direction == "in" and s.status == "pending" then
      pending = pending + 1
    elseif s.status == "sending" or s.status == "receiving" or s.status == "waiting" then
      active = active + 1
    end
  end

  if pending + active > 0 then
    barWidget.setText(tostring(pending + active))
    barWidget.setGlyphColor("primary", "script")
  else
    barWidget.setText("")
    barWidget.setGlyphColor("on_surface", "script")
  end
  barWidget.setGlyph(ls.up == false and "wifi-off" or "send")

  local tip = { noctalia.tr("widget.tooltip") }
  if pending > 0 then table.insert(tip, noctalia.tr("widget.requests", { count = pending })) end
  if active > 0 then table.insert(tip, noctalia.tr("widget.active", { count = active })) end
  barWidget.setTooltip(tip)
end

function onClick() noctalia.togglePanel(PANEL) end

function onRightClick() noctalia.openSettings() end

function onIpc(event, payload)
  if event == "toggle" then noctalia.togglePanel(PANEL) end
end

noctalia.state.watch("ls", refresh)
refresh()
