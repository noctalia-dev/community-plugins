--!nonstrict
-- Typing Stats - control-center tile that opens the heatmap calendar.

shortcut.setLabel(noctalia.tr("shortcut.heatmap"))
shortcut.setIcon("chart-bar", "calendar")
shortcut.setActive(false)
shortcut.setEnabled(true)

function onClick()
  noctalia.togglePanel("goldesquemoon/typing-stats:calendar")
end
