--!nonstrict
-- Control centre tile that opens the cursor panel.

local function render()
  shortcut.setLabel(noctalia.tr("title"))
  shortcut.setIcon("pointer")
end

render()

function onClick()
  noctalia.togglePanel("vn1k/cursor:manager")
end
