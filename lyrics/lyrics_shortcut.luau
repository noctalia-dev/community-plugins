--!nonstrict

shortcut.setLabel(noctalia.tr("shortcut.label"))
shortcut.setIcon("list-search")
shortcut.setEnabled(true)

function onClick()
  noctalia.togglePanel("h465855hgg/lyrics:selector")
end

function onActivate()
  onClick()
end
