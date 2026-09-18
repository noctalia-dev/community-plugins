--!nonstrict
-- Monitor Control control-center tile - the display glyph, one click from the
-- panel.
--
-- A thin client like the bar widget: it watches the service's "monitor.state"
-- snapshot for availability and opens the panel on click, so every compositor
-- call stays in the service. Add it in
-- Settings -> Control Center -> Shortcuts.

local snapshot = { available = false }

local function render()
  shortcut.setIcon("device-desktop")

  if snapshot.available ~= true then
    shortcut.setLabel(noctalia.tr("shortcut.unavailable"))
    shortcut.setActive(false)
    shortcut.setEnabled(false)
    return
  end

  -- The tile is the glyph alone, with no caption: the shell substitutes the
  -- entry id for an *empty* label, so a single space keeps this tile text-free
  -- while its neighbours keep their labels. The focused output's mode is the
  -- bar widget's and the panel's job, and a mode string more than about ten
  -- characters is elided here anyway.
  shortcut.setLabel(" ")

  -- A way into the panel, not a state of its own - and the shell renders every
  -- plugin shortcut as a toggle tile, so this one never lights up.
  shortcut.setActive(false)
  shortcut.setEnabled(true)
end

function onClick()
  noctalia.togglePanel("muhammadessam/umbriel-monitor-control:panel")
end

noctalia.state.watch("monitor.state", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

render()

-- watch does not replay an old value to a freshly loaded entry, and the service
-- may have last published before this tile was added: ask for a snapshot,
-- exactly as the bar widget does.
noctalia.state.set("monitor.request", { action = "refresh" })
