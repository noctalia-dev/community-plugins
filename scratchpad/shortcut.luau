--!nonstrict
-- Control-center quick tile: opens the scratchpad panel.

shortcut.setLabel(noctalia.tr("title"))
shortcut.setIcon("note")

function onClick()
  noctalia.togglePanel("xinghui/scratchpad:pad")
end
