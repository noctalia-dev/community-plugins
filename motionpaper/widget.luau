--!nonstrict

local PANEL_ID = "lawnninja/motionpaper:picker"

local function render()
  barWidget.setGlyph(noctalia.getConfig("glyph") or "wallpaper-selector")
  barWidget.setTooltip(noctalia.tr("widget.tooltip"))
end

local nonce = 0
local function sendCommand(action)
  nonce = nonce + 1
  noctalia.state.set("command", {
    nonce = math.floor(noctalia.nowMs() * 1000 + nonce),
    action = action,
    target = "*",
  })
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
  sendCommand("toggle-pause")
end

function onMiddleClick()
  sendCommand("toggle-stop")
end

function onConfigChanged()
  render()
end

render()
