-- shortcut.luau
-- Control-center tile that opens/closes the contact-sounds panel where each
-- contact's sound can be tested.

--!nonstrict

local function tr(key)
  return noctalia.tr(key)
end

shortcut.setLabel(tr("shortcut.label"))
shortcut.setIcon("player-play", "player-play")
shortcut.setActive(false)

function onClick()
  noctalia.togglePanel("nilsonlinux/contact-sounds:Panel")
end

function onConfigChanged()
  shortcut.setLabel(tr("shortcut.label"))
end