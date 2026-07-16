--!nonstrict

shortcut.setLabel("HA Panel")
shortcut.setIcon("layout-list")
shortcut.setActive(false)
shortcut.setEnabled(true)

function onClick()
    noctalia.togglePanel("pozzoo/hassio:entity_manager")
end
