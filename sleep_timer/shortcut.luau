--!nonstrict
-- Control Center tile. Click: open the dial panel.
-- Right click: start the timer with the chosen time, or cancel a running one. While the
-- timer state is unknown (systemd could not be asked yet) right click cancels, so a timer
-- the plugin lost track of can always be stopped from here.
-- The tile is highlighted and counts down while the timer runs.

local timer = require("./timer.luau")

local function render()
  local status, at = timer.status()
  local value = at and timer.remainingMinutes(at) or timer.loadMinutes()
  shortcut.setLabel(status == "unknown" and "?" or timer.formatClock(value))
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
  if timer.status() ~= "idle" then
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
