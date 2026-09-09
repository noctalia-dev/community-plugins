-- scroller_panel.luau — [[panel]] "scroller-controls"
--
-- Interactive control panel for the focused workspace's scroller modifiers.
-- Mirrors the popover in ScrollScroller (gtkshell/scroll.cpp).

local scrollIpc = require("./scroll_ipc.luau")
local scrollState = require("./scroll_state.luau")

local function send(command)
  noctalia.runAsync(scrollIpc.scrollmsgBase() .. " -- " .. command, function(result)
    if result.exitCode ~= 0 then
      noctalia.notifyError("Scroll", "Command failed: " .. command)
    end
  end)
end

local MODE_OPTIONS = { "Horizontal", "Vertical" }
local INSERT_OPTIONS = { "After", "Before", "Beginning", "End" }
local INSERT_COMMANDS = { "after", "before", "beginning", "end" }
local FIT_OPTIONS = { "No fit", "Split", "Fraction" }
local FIT_COMMANDS = { "nofit", "fitsplit", "fitfraction" }

local panelOpen = false
local lastRenderedFingerprint = nil

local function indexOf(list, value)
  for i, v in ipairs(list) do
    if v == value then
      return i - 1
    end
  end
  return 0
end

local function labeledRow(labelText, control)
  return {
    type = "row",
    props = { gap = 8, align = "center", justify = "space_between" },
    children = {
      { type = "label", props = { text = labelText } },
      control,
    },
  }
end

local function buildTree()
  if not scrollIpc.isAvailable() then
    return {
      type = "column",
      props = { gap = 8, padding = 12 },
      children = {
        { type = "label", props = { text = "Scroll not detected." } },
        { type = "label", props = { text = "This panel only applies under the Scroll compositor." } },
      },
    }
  end

  local scroller = noctalia.state.get("scroll.scroller") or {}

  return {
    type = "column",
    props = { gap = 10, padding = 12 },
    children = {
      labeledRow("Direction", {
        type = "select",
        props = {
          width = 140,
          options = MODE_OPTIONS,
          selectedIndex = scroller.mode == "vertical" and 1 or 0,
          onChange = "onModeChange",
        },
      }),
      labeledRow("Insert position", {
        type = "select",
        props = {
          width = 140,
          options = INSERT_OPTIONS,
          selectedIndex = indexOf(INSERT_COMMANDS, scroller.insert),
          onChange = "onInsertChange",
        },
      }),
      labeledRow("Focus new window", {
        type = "toggle",
        props = { checked = scroller.focus == true, onChange = "onFocusChange" },
      }),
      labeledRow("Auto reorder", {
        type = "toggle",
        props = { checked = scroller.reorder == "auto", onChange = "onReorderChange" },
      }),
      labeledRow("Fit", {
        type = "select",
        props = {
          width = 140,
          options = FIT_OPTIONS,
          selectedIndex = indexOf(FIT_COMMANDS, scroller.fit),
          onChange = "onFitChange",
        },
      }),
      labeledRow("Center column", {
        type = "toggle",
        props = { checked = scroller.center_horizontal == true, onChange = "onCenterHChange" },
      }),
      labeledRow("Center window", {
        type = "toggle",
        props = { checked = scroller.center_vertical == true, onChange = "onCenterVChange" },
      }),
      { type = "separator", props = {} },
      { type = "button", props = { text = "Refresh", onClick = "onRefresh" } },
    },
  }
end

local function refreshFingerprint()
  local scroller = noctalia.state.get("scroll.scroller")
  return scrollState.panelScrollerFingerprint(scroller)
end

local function refresh()
  if not panelOpen then
    return
  end
  local fingerprint = refreshFingerprint()
  if fingerprint == lastRenderedFingerprint then
    return
  end
  lastRenderedFingerprint = fingerprint
  panel.render(buildTree())
end

noctalia.state.watch("scroll.scroller", refresh)

function onOpen()
  panelOpen = true
  lastRenderedFingerprint = nil
  refresh()
end

function onClose()
  panelOpen = false
end

function onModeChange(idxStr)
  send(tonumber(idxStr) == 1 and "set_mode v" or "set_mode h")
end

function onInsertChange(idxStr)
  local command = INSERT_COMMANDS[(tonumber(idxStr) or 0) + 1]
  if command ~= nil then
    send("set_mode " .. command)
  end
end

function onFocusChange(checkedStr)
  send(checkedStr == "true" and "set_mode focus" or "set_mode nofocus")
end

function onReorderChange(checkedStr)
  send(checkedStr == "true" and "set_mode reorder_auto" or "set_mode noreorder_auto")
end

function onFitChange(idxStr)
  local command = FIT_COMMANDS[(tonumber(idxStr) or 0) + 1]
  if command ~= nil then
    send("set_mode " .. command)
  end
end

function onCenterHChange(checkedStr)
  send(checkedStr == "true" and "set_mode center_horiz" or "set_mode nocenter_horiz")
end

function onCenterVChange(checkedStr)
  send(checkedStr == "true" and "set_mode center_vert" or "set_mode nocenter_vert")
end

function onRefresh()
  scrollIpc.fetch("get_scroller", function(payload)
    if type(payload) == "table" and payload.scroller ~= nil then
      scrollState.publishIfChanged(
        "scroll.scroller",
        payload.scroller,
        scrollState.scrollerFingerprint(payload.scroller)
      )
    end
  end)
end
