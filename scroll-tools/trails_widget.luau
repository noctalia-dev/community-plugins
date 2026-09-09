-- trails_widget.luau — [[widget]] "trails"
--
-- Mirrors ScrollTrails in gtkshell/scroll.cpp: own subscribe(["trails"]) stream,
-- direct label update on each event.

local scrollIpc = require("./scroll_ipc.luau")

-- Event-driven via runStream; stretch Noctalia's default 250ms noop timer.
noctalia.setUpdateInterval(3600000)

local function composeText(trails)
  if trails == nil then
    return ""
  end
  local active = trails.active or 0
  local length = trails.length or 0
  local marks = trails.trail_length or 0
  return string.format("%d/%d (%d)", active, length, marks)
end

local lastText = nil

local function render(trails)
  local text = composeText(trails)
  if text == lastText then
    return
  end
  lastText = text
  barWidget.setText(text)
  barWidget.setTooltip("Scroll trails: position / length (marks)")
end

local function handleEnvelope(payload)
  if type(payload) ~= "table" or payload.trails == nil then
    return
  end
  render(payload.trails)
end

local function handleLine(line)
  if line == nil or line == "" then
    return
  end
  handleEnvelope(noctalia.json.decode(line))
end

if not scrollIpc.isAvailable() then
  barWidget.setVisible(false)
else
  barWidget.setVisible(true)
  scrollIpc.fetch("get_trails", handleEnvelope)
  if not scrollIpc.subscribe('["trails"]', handleLine) then
    noctalia.log("scroll-tools: trails widget failed to start scrollmsg subscribe")
    barWidget.setVisible(false)
  end
end
