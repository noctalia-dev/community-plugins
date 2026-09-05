local transport = "UNKNOWN"
local controllable = false
local state = "STOPPED"
local phase = "IDLE"
local paused = false
local time = "--:--"

local function isLive() return state == "WORKING" or state == "RESTING" end
local function render()
  local label
  if transport == "ABSENT" then
    label = noctalia.tr("err.absent_title")
  elseif isLive() then
    label = paused and (time .. " · " .. noctalia.tr("ui.paused")) or time
  elseif state == "WAITING_FOR_REST" or state == "WAITING_FOR_WORK" then
    label = noctalia.tr("phase.waiting")
  else
    label = noctalia.tr("ui.pomodoro")
  end

  shortcut.setLabel(label)
  shortcut.setIcon(phase == "REST" and "moon" or "brain", "hourglass")
  shortcut.setActive(isLive() and not paused)
  shortcut.setEnabled(controllable)
end

noctalia.state.watch("hm.transport", function(v) transport = v or "UNKNOWN"; render() end)
noctalia.state.watch("hm.controllable", function(v) controllable = v == true; render() end)
noctalia.state.watch("hm.state", function(v) state = v or "STOPPED"; render() end)
noctalia.state.watch("hm.phase", function(v) phase = v or "IDLE"; render() end)
noctalia.state.watch("hm.paused", function(v) paused = v == true; render() end)
noctalia.state.watch("hm.time", function(v) time = v or "--:--"; render() end)

function onClick()
  noctalia.state.set("hm.cmd", state == "STOPPED" and "START" or "PAUSE")
end

function onRightClick()
  noctalia.state.set("hm.cmd", "STOP")
end

transport = noctalia.state.get("hm.transport") or "UNKNOWN"
controllable = noctalia.state.get("hm.controllable") == true
state = noctalia.state.get("hm.state") or "STOPPED"
phase = noctalia.state.get("hm.phase") or "IDLE"
paused = noctalia.state.get("hm.paused") == true
time = noctalia.state.get("hm.time") or "--:--"
render()
