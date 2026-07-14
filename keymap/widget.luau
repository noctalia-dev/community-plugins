--!nonstrict

local PANEL_ID = "blackbartblues/keymap:panel"

local glyph = "keyboard"
local showLabel = false

local function readConfig()
  glyph = noctalia.getConfig("glyph") or "keyboard"
  showLabel = noctalia.getConfig("show_label") == true
end

local function render()
  barWidget.setGlyph(glyph)
  barWidget.setText(showLabel and noctalia.tr("title") or "")
  barWidget.setTooltip(noctalia.tr("widget.tooltip"))
end

function update()
  noctalia.setUpdateInterval(60000)
  readConfig()
  render()
end

function onConfigChanged()
  readConfig()
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end
