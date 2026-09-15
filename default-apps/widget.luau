-- Bar widget: shows a static icon and opens the Default Apps panel on click.
-- No polling, no hover tooltip.
local PANEL_ID = "thaer99ob/default-apps:manager"

function update()
  barWidget.setGlyph("apps")
  barWidget.setText("")
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end
