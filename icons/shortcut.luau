--!nonstrict
-- Control centre tile that opens the icons panel.

shortcut.setLabel(noctalia.tr("title"))
shortcut.setIcon("icons")

function onClick()
  noctalia.togglePanel("vn1k/icons:manager")
end
