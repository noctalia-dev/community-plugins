--!nonstrict
-- Navigator panel: every workspace of one output with its windows. Same core as the bar
-- widget (stream / model / view / render / actions).
--
-- Which output: a panel's snapshot carries no output, and noctalia.focusedOutputName()
-- reports niri's focused monitor rather than the clicked bar. So, in order:
--   1. an explicit context ("panel-toggle johnnyp0t/niri-workspace-stack:navigator DP-3"),
--   2. the output published by the hovered bar widget (onHover in widget.luau),
--   3. niri's focused output.
--
-- The runtime lives from the first open until reload/disable, so its stream does too:
-- one extra `niri msg --json event-stream`, independent of display mode and bar count.

local Model = require("./lib/model.luau")
local View = require("./lib/view.luau")
local Render = require("./lib/render.luau")
local Actions = require("./lib/actions.luau")
local Stream = require("./lib/stream.luau")

local model = Model.new()
local isOpen = false
local output = nil
local iconCache = {}

local function iconFor(appId)
  if appId == nil or appId == "" then
    return nil
  end
  local cached = iconCache[appId]
  if cached == nil then
    cached = noctalia.appIconPath(appId, 32) or false
    iconCache[appId] = cached
  end
  return cached or nil
end

local ctx = {
  size = 1,
  iconSize = 18,
  gap = 3,
  compact = false,
  showWindows = true,
  iconFor = iconFor,
  onWorkspace = function(id)
    Actions.focusWorkspace(model, id)
  end,
  onWindow = function(id)
    if Actions.focusWindow(model, id) then
      panel.close()
    end
  end,
}

local function isKnownOutput(name)
  if type(name) ~= "string" or name == "" then
    return false
  end
  for _, ws in pairs(model.workspaces) do
    if ws.output == name then
      return true
    end
  end
  -- Before the first state arrives, trust a connector-looking name.
  return not model:ready()
end

local function render()
  if not isOpen then
    return
  end
  if not model:ready() then
    panel.render(ui.column({ key = "panel", padding = 16, align = "center", justify = "center" }, {
      ui.glyph({ key = "status", name = "loader", size = 18, color = Render.alpha("on_surface", 0.6) }),
    }))
    return
  end
  local target = output
  if not isKnownOutput(target) then
    target = model:focusedOutput()
  end
  local view = View.build(model, target, { visibleWorkspaces = 99, maxWindows = 0, showEmpty = true })
  panel.render(Render.panelList(ctx, view, function()
    panel.close()
  end))
end

local sub = Stream.start(model, render)

function onOpen(context)
  isOpen = true
  if isKnownOutput(context) then
    output = context
  else
    output = noctalia.state.get("navigator_output")
  end
  render()
end

function onClose()
  isOpen = false
end

function onIpc(event)
  if event == "resync" then
    sub.resync()
  end
end
