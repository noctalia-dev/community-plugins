--!nonstrict
-- Control Center tile. Click: open the dial panel.
-- Right click: start the timer with the chosen time, or cancel a running one.
-- The tile is highlighted and counts down while the timer runs.

local timer = require("./timer.luau")

local function render()
  local at = timer.scheduledAt()
  local value = at and timer.remainingMinutes(at) or timer.loadMinutes()
  shortcut.setLabel(timer.formatClock(value))
  shortcut.setIcon("moon")
  shortcut.setActive(at ~= nil)
  shortcut.setEnabled(true)
end

function update()
  timer.poll(render)
  render()
end

function onClick()
  noctalia.togglePanel(timer.PANEL_ID)
end

function onRightClick()
  if timer.scheduledAt() then
    timer.cancel(render)
  else
    timer.start(timer.loadMinutes(), render)
  end
end

noctalia.state.watch("minutes", render)
noctalia.state.watch("scheduled", render)

noctalia.setUpdateInterval(1000)
timer.verify(render)
render()
