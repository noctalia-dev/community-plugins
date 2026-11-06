--!nonstrict
-- Typing Stats - optional control-center reset tile.

shortcut.setLabel(noctalia.tr("shortcut.reset"))
shortcut.setIcon("refresh", "trash")
shortcut.setActive(false)
shortcut.setEnabled(true)

function onClick()
  noctalia.state.set("command", { action = "reset", seq = noctalia.nowMs() })
end
