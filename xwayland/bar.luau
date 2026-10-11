--!nonstrict
-- Umbriel Companion bar widget - the focused layout or active submap, at a glance.
--
-- Click opens the panel; a scroll flick cycles scrolling → dwindle → master.
-- Every compositor call goes through the service, so several bars on several
-- outputs still share one poller.

local snapshot = { available = false, focused_window = nil }

local function render()
  -- The plugin only means anything on an Umbriel session: take no bar space
  -- anywhere else instead of showing a dead icon.
  if snapshot.available ~= true then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)

  local focused_window = snapshot.focused_window
  if focused_window == nil then
    barWidget.setVisible(false)
    return
  end
  if focused_window.xwayland == true then
    barWidget.setVisible(true)
    barWidget.setGlyph(noctalia.getConfig("xwayland_glyph"))
    return
  end
  if noctalia.getConfig("hide_on_wayland") then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)
  barWidget.setGlyph(noctalia.getConfig("wayland_glyph"))
end

function update()
  render()
end

noctalia.state.watch("umbriel.state", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

snapshot = noctalia.state.get("umbriel.state") or snapshot
render()
