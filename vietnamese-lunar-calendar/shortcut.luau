--!nonstrict

local function render()
    shortcut.setLabel(noctalia.tr("ui.shortcut_label"))
    shortcut.setIcon("moon-stars")
    shortcut.setActive(false)
    shortcut.setEnabled(true)
end

render()

function onClick()
    noctalia.togglePanel("notoxus/vietnamese-lunar-calendar:calendar")
end
