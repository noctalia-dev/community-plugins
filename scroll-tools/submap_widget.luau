-- submap_widget.luau — [[widget]] "submap"
--
-- Mirrors ScrollSubmap in gtkshell/scroll.cpp: own subscribe(["mode"]) stream,
-- direct label update on each event.

local scrollIpc = require("./scroll_ipc.luau")

-- Event-driven via runStream; stretch Noctalia's default 250ms noop timer.
noctalia.setUpdateInterval(3600000)

local showIcons = noctalia.getConfig("show_icons")
if showIcons == nil then
  showIcons = true
end

local function composeText(mode)
  if mode == nil or mode == "" or mode == "default" then
    return ""
  end
  local icon = showIcons and "⌨" or "MODE:"
  return icon .. " " .. mode
end

local lastText = nil

local function render(mode)
  local text = composeText(mode)
  if text == lastText then
    return
  end
  lastText = text
  barWidget.setVisible(text ~= "")
  barWidget.setText(text)
  barWidget.setTooltip("Scroll binding mode")
end

local function handleEnvelope(payload)
  if type(payload) ~= "table" then
    return
  end
  -- Live subscribe events use {"change": "<mode>"}; get_binding_state uses {"name": "..."}.
  local mode = payload.change or payload.name
  if mode == nil then
    return
  end
  render(mode)
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
  scrollIpc.fetch("get_binding_state", handleEnvelope)
  if not scrollIpc.subscribe('["mode"]', handleLine) then
    noctalia.log("scroll-tools: submap widget failed to start scrollmsg subscribe")
    barWidget.setVisible(false)
  end
end
