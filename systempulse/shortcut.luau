--!nonstrict
-- Control-center [[shortcut]] entry for SystemPulse.

-- Sets up the control-center tile: label, icon and enabled state.
local function render()
  shortcut.setLabel("SystemPulse")
  shortcut.setIcon("cpu")
  shortcut.setActive(false)
  shortcut.setEnabled(true)
end

render()

-- Opens (or closes) the SystemPulse panel.
function onClick()
  noctalia.togglePanel("arrifat346afs/systempulse:panel")
end

