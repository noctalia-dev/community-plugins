--!nonstrict
-- Niri Workspace Stack bar widget. Three display modes over one shared core:
--   lib/stream.luau  subscription lifecycle   lib/model.luau  normalized niri state
--   lib/view.luau    per-output derived data   lib/render.luau per-mode ui builders
--   lib/actions.luau clicks / wheel / focus
--
-- Host behaviour this file depends on (verified in Noctalia 5.2.0 / 5.2.1 sources):
--   * stream and runAsync callbacks run without the bar snapshot: barWidget.outputName()
--     and isVertical() are nil/false there, so both are cached from load/update/UI/IPC calls;
--   * a settings change rebuilds the widget runtime, which kills the old event-stream
--     process group before the new one starts (no leaked or duplicated subscriptions).

local Model = require("./lib/model.luau")
local View = require("./lib/view.luau")
local Render = require("./lib/render.luau")
local Actions = require("./lib/actions.luau")
local Stream = require("./lib/stream.luau")

local MODES = { numbered_rail = true, mini_map = true, navigator = true }
local NAVIGATOR_OUTPUT_KEY = "navigator_output"

local function cfgNumber(key, fallback)
  return tonumber(noctalia.getConfig(key)) or fallback
end

local function cfgBool(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil then
    return fallback
  end
  return value == true
end

local configuredMode = noctalia.getConfig("displayMode")
local cfg = {
  mode = MODES[configuredMode] and configuredMode or "navigator", -- keep in sync with plugin.toml
  visibleWorkspaces = math.floor(cfgNumber("visible_workspaces", 3)),
  showNumbers = cfgBool("show_numbers", true),
  showWindows = cfgBool("show_windows", true),
  showEmpty = cfgBool("show_empty", true),
  maxWindows = math.floor(cfgNumber("max_windows", 8)),
  size = cfgNumber("indicator_size", 1.0),
  iconSize = cfgNumber("icon_size", 18),
  compact = cfgBool("compact", false),
}

local model = Model.new()
local modeOverride = nil -- runtime-only, set over IPC for quick comparison
local debugOverlay = false
local iconCache = {}

-- Snapshot-only values, cached (see header).
local barOutput = barWidget.outputName()
local vertical = barWidget.isVertical()

local function refreshSnapshot()
  local output = barWidget.outputName()
  if output ~= nil then
    barOutput = output
  end
  vertical = barWidget.isVertical()
end

local function iconFor(appId)
  if appId == nil or appId == "" then
    return nil
  end
  local cached = iconCache[appId]
  if cached == nil then
    cached = noctalia.appIconPath(appId, math.floor(cfg.iconSize * 2)) or false
    iconCache[appId] = cached
  end
  return cached or nil
end

-- The bar clips the tree to its thickness (34 px by default, no capsule). Rail and mini map
-- rows are (4 + gap) * size tall plus two 2 px edge markers; cap the row count so the stack
-- fits a 30 px budget instead of being cut off at larger sizes.
local function fittedVisible()
  local rowHeight = (4 + (cfg.compact and 2 or 3)) * cfg.size
  local fit = math.floor((30 - 4 * cfg.size) / rowHeight)
  return math.max(1, math.min(cfg.visibleWorkspaces, fit))
end

local function currentView()
  return View.build(model, barOutput, {
    visibleWorkspaces = fittedVisible(),
    maxWindows = cfg.maxWindows,
    showEmpty = cfg.showEmpty,
  })
end

local ctx = {
  size = cfg.size,
  iconSize = cfg.iconSize,
  gap = cfg.compact and 2 or 3,
  compact = cfg.compact,
  showWindows = cfg.showWindows,
  iconFor = iconFor,
  onWorkspace = function(id)
    Actions.focusWorkspace(model, id)
  end,
  onWindow = function(id)
    Actions.focusWindow(model, id)
  end,
}

local sub -- set by Stream.start below

-- ── Diagnostics (on demand only) ────────────────────────────────────────────

local function diagnosticLines()
  local lines = {}
  local function add(fmt, ...)
    lines[#lines + 1] = string.format(fmt, ...)
  end
  add("widget output=%s mode=%s vertical=%s connected=%s ready=%s", tostring(barOutput), modeOverride or cfg.mode,
    tostring(vertical), tostring(sub and sub.connected), tostring(model:ready()))
  add("focused output=%s focused window=%s events=%d last=%s", tostring(model:focusedOutput()),
    tostring(model.focusedWindowId), model.eventCount, tostring(model.lastEvent))
  local outputs, names = {}, {}
  for _, ws in pairs(model.workspaces) do
    if ws.output ~= nil and not outputs[ws.output] then
      outputs[ws.output] = true
      names[#names + 1] = ws.output
    end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local parts = {}
    for _, ws in ipairs(model:workspacesOn(name)) do
      parts[#parts + 1] = string.format("%s%sidx%d=id%d(%dw)", ws.isFocused and "F" or "", ws.isActive and "*" or "",
        ws.idx or -1, ws.id, model:windowCount(ws.id))
    end
    add("  %s: %s", name, table.concat(parts, " "))
  end
  local violations = model:violations()
  add("invariants: %s", #violations == 0 and "ok" or table.concat(violations, "; "))
  return lines
end

-- ── Rendering ───────────────────────────────────────────────────────────────

local function render()
  local container = vertical and ui.column or ui.row

  if barOutput == nil or not model:ready() then
    local glyph = "loader"
    if barOutput == nil then
      glyph = "device-desktop-off"
    elseif sub ~= nil and not sub.connected then
      glyph = "plug-connected-x"
    end
    barWidget.render(container({ key = "root", align = "center" }, {
      ui.glyph({ key = "status", name = glyph, size = 14, color = Render.alpha("on_surface", 0.6) }),
    }))
    return
  end

  local view = currentView()
  local mode = modeOverride or cfg.mode
  local children = {}
  if mode == "navigator" then
    children[#children + 1] = Render.navigatorBadge(ctx, view)
  else
    if cfg.showNumbers then
      children[#children + 1] = Render.numberBlock(ctx, view)
    end
    children[#children + 1] = mode == "mini_map" and Render.miniMap(ctx, view) or Render.rail(ctx, view)
  end
  local strip = Render.windowStrip(ctx, view, vertical)
  if strip ~= nil then
    children[#children + 1] = strip
  end
  if debugOverlay then
    local active = view.activeWorkspace
    children[#children + 1] = ui.label({
      key = "debug",
      text = string.format("%s%s ws%s#%s fw%s", barOutput, view.isFocusedOutput and "*" or "",
        active and tostring(active.id) or "-", active and tostring(active.idx) or "-", tostring(model.focusedWindowId)),
      fontSize = 9,
      color = "error",
    })
  end
  barWidget.render(container({
    key = "root",
    gap = cfg.compact and 4 or 6,
    align = "center",
    opacity = (sub ~= nil and sub.connected) and 1 or 0.5,
    tooltip = debugOverlay and table.concat(diagnosticLines(), "\n") or nil,
  }, children))
end

-- ── Subscription ────────────────────────────────────────────────────────────

sub = Stream.start(model, render)
if not sub.available then
  barWidget.setVisible(false)
end
if barOutput == nil then
  noctalia.log("niri-workspace-stack: bar output unknown at load; waiting for update()")
end
render()

-- ── Host callbacks (all of these carry the bar snapshot) ────────────────────

function update()
  -- Event-driven; the tick only refreshes snapshot-only values (output, orientation).
  noctalia.setUpdateInterval(60000)
  refreshSnapshot()
  render()
end

-- The navigator panel cannot see which bar opened it, so the hovered widget publishes its
-- output; a click always follows a hover on the same widget.
function onHover(entered)
  if entered then
    refreshSnapshot()
    if barOutput ~= nil then
      noctalia.state.set(NAVIGATOR_OUTPUT_KEY, barOutput)
    end
  end
end

-- One workspace up/down on this bar's monitor through `niri msg`, so niri's
-- warp-mouse-to-focus applies (see README, Known limitations). The manifest leaves the
-- wheel unbound; a user scroll binding in the widget's actions would replace this handler.
function onScroll(axis, steps, startsGesture)
  if axis ~= "vertical" or not startsGesture or not model:ready() then
    return
  end
  refreshSnapshot()
  Actions.step(model, currentView(), steps > 0 and 1 or -1)
end

function onIpc(event, payload)
  refreshSnapshot()
  if event == "resync" then
    sub.resync()
  elseif event == "diag" then
    for _, line in ipairs(diagnosticLines()) do
      noctalia.log("niri-workspace-stack[" .. tostring(barOutput) .. "]: " .. line)
    end
  elseif event == "debug" then
    debugOverlay = payload == "on" or (payload ~= "off" and not debugOverlay)
    render()
  elseif event == "mode" then
    modeOverride = MODES[payload] and payload or nil
    render()
  end
end
