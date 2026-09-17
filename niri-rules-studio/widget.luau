--!nonstrict

local PANEL_ID = "setyvii/niri-rules-studio:panel"

function onClick()
    noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
    noctalia.togglePanel(PANEL_ID)
end

function onMiddleClick()
    noctalia.openSettings()
end

function update()
    barWidget.setGlyph("adjustments-horizontal")
    barWidget.setText(noctalia.tr("widget_text"))
    barWidget.setTooltip(noctalia.tr("widget_tooltip"))
end

update()
