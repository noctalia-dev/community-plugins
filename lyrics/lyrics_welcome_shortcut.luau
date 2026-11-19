--!nonstrict

shortcut.setLabel(noctalia.tr("open_welcome.label"))
shortcut.setIcon("layout-grid")
shortcut.setEnabled(true)

function onClick()
  noctalia.togglePanel("h465855hgg/lyrics:welcome")
end

function onActivate()
  onClick()
end
