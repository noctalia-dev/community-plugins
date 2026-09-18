-- scroller_widget.luau — [[widget]] "scroller"
--
-- Mirrors ScrollScroller in gtkshell/scroll.cpp: owns its own scrollmsg
-- subscribe(["scroller"]) stream and updates the bar label directly on each
-- event — no timers, no central bridge. Also publishes scroll.scroller for the
-- control panel.

local scrollIpc = require("./scroll_ipc.luau")
local scrollState = require("./scroll_state.luau")

-- Event-driven via runStream; stretch Noctalia's default 250ms noop timer.
noctalia.setUpdateInterval(3600000)

local showIcons = noctalia.getConfig("show_icons")
if showIcons == nil then
  showIcons = true
end

local function symbol(icon, plain)
  if showIcons then
    return icon
  end
  return plain
end

local function composeText(scroller)
  if scroller == nil then
    return ""
  end

  local mode = scroller.mode == "horizontal" and symbol("-", "H") or symbol("|", "V")

  local pos = ""
  local insert = scroller.insert
  if insert == "after" then
    pos = symbol("→", ">")
  elseif insert == "before" then
    pos = symbol("←", "<")
  elseif insert == "end" then
    pos = symbol("⇥", "E")
  elseif insert == "beginning" then
    pos = symbol("⇤", "B")
  end

  local focus = scroller.focus and symbol("◉", "f") or symbol("◎", "-")
  local reorder = scroller.reorder == "auto" and symbol("A", "a") or symbol("M", "-")

  local fit = ""
  if scroller.fit == "nofit" then
    fit = symbol("·", "-")
  elseif scroller.fit == "fitsplit" then
    fit = symbol("S", "S")
  elseif scroller.fit == "fitfraction" then
    fit = symbol("F", "F")
  end

  local centerH = scroller.center_horizontal and symbol("⇔", "h") or ""
  local centerV = scroller.center_vertical and symbol("⇕", "v") or ""

  local overview = scroller.overview and symbol(" 󰆾", " *") or ""
  local scale = ""
  if scroller.scaled then
    scale = string.format(" %.2fx", scroller.scale or 1.0)
  end

  return string.format("%s %s %s %s %s%s%s%s", mode, pos, focus, reorder, fit, centerH, centerV, overview) .. scale
end

local function tooltipRows(scroller)
  if scroller == nil then
    return "Waiting for Scroll…"
  end
  local rows = {}
  table.insert(rows, { key = "Mode", value = scroller.mode })
  table.insert(rows, { key = "Insert", value = scroller.insert })
  table.insert(rows, { key = "Focus", value = scroller.focus and "focus" or "nofocus" })
  table.insert(rows, { key = "Reorder", value = scroller.reorder })
  table.insert(rows, { key = "Fit", value = scroller.fit })
  table.insert(rows, { key = "Center H", value = scroller.center_horizontal and "on" or "off" })
  table.insert(rows, { key = "Center V", value = scroller.center_vertical and "on" or "off" })
  return rows
end

local lastText = nil

local function render(scroller)
  local text = composeText(scroller)
  if text == lastText then
    return
  end
  lastText = text
  barWidget.setText(text)
  barWidget.setTooltip(tooltipRows(scroller))
end

local function applyScroller(scroller)
  scrollState.publishIfChanged(
    "scroll.scroller",
    scroller,
    scrollState.scrollerFingerprint(scroller)
  )
  render(scroller)
end

local function handleEnvelope(payload)
  if type(payload) ~= "table" or payload.scroller == nil then
    return
  end
  applyScroller(payload.scroller)
end

local function handleLine(line)
  if line == nil or line == "" then
    return
  end
  handleEnvelope(noctalia.json.decode(line))
end

if not scrollIpc.isAvailable() then
  barWidget.setVisible(false)
  noctalia.state.set("scroll.available", false)
else
  barWidget.setVisible(true)
  noctalia.state.set("scroll.available", true)
  scrollIpc.fetch("get_scroller", handleEnvelope)
  if not scrollIpc.subscribe('["scroller"]', handleLine) then
    noctalia.log("scroll-tools: scroller widget failed to start scrollmsg subscribe")
    barWidget.setVisible(false)
    noctalia.state.set("scroll.available", false)
  end
end

function onClick()
  noctalia.togglePanel("n3ptune-plan3t/scroll-tools:scroller-controls")
end
