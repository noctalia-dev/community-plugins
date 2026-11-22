--!nonstrict
-- Control-center tile mirroring the bar indicator: active while passwordless
-- sudo is on. Click revokes an active grant or opens the duration picker;
-- right click opens the panel.

local common = require("./lib/common.luau")
local tr = noctalia.tr

local function render(s)
  s = s or common.status()
  if s.active and s.mode == "timed" then
    shortcut.setLabel(tr("shortcut.left", { span = common.formatShort(s.deadline - common.nowSec()) }))
  elseif s.active then
    shortcut.setLabel(tr("shortcut.on"))
  else
    shortcut.setLabel(tr("shortcut.label"))
  end
  shortcut.setIcon("shield-lock", "shield-lock")
  shortcut.setActive(s.active == true)
  shortcut.setEnabled(not s.busy)
end

noctalia.state.watch("status", render)

function onClick()
  local s = common.status()
  if s.active then
    common.send("disable")
  else
    noctalia.togglePanel(common.PANEL)
  end
end

function onRightClick()
  noctalia.togglePanel(common.PANEL)
end

render()
