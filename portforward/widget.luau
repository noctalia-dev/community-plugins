--!nonstrict
local layout = require("./layout.luau")

local function apply(snapshot)
  local connected, errors, retrying = 0, 0, 0
  for _, profile in ipairs(snapshot.profiles or {}) do
    if profile.state == "connected" then connected += 1 end
    if profile.state == "error" then errors += 1 end
    if profile.state == "connecting" or profile.state == "reconnecting" then retrying += 1 end
  end
  if snapshot.error then errors += 1 end
  barWidget.setGlyph(errors > 0 and "alert-circle" or "arrows-left-right")
  barWidget.setText(tostring(connected) .. (retrying > 0 and " …" or ""))
end

noctalia.state.watch("snapshot", function(snapshot) apply(snapshot or {}) end)
apply(noctalia.state.get("snapshot") or {})
function onClick()
  -- Close the active size even when status/count changed since it opened.
  local target = layout.panelId(noctalia.state.get("snapshot") or {})
  if noctalia.state.get("visible_panel") then
    target = noctalia.state.get("visible_panel")
  end
  noctalia.togglePanel(target)
end
