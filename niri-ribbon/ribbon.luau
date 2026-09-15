--!nonstrict
-- Niri Ribbon - viewport position indicator for niri scrollable-tiling layout.
--
-- Acknowledgement: the core idea originates from ews/noctalia-niri-ribbon by
-- J Pablo Puerta <ews@folksonomy.com>
-- (https://github.com/ews/noctalia-niri-ribbon). That project targeted the
-- legacy quickshell-era QML+manifest.json plugin API (since removed upstream);
-- this file is a ground-up rewrite against the Noctalia v5 plugin spec
-- (plugin.toml + Luau).
--
-- The shared service publishes compact per-output snapshots. This widget only
-- estimates viewport geometry and renders; it never polls the compositor.
--
-- Viewport estimation: niri does not expose the live scrolling offset on
-- standard releases. The "fit" model remembers an offset per workspace and
-- moves it only enough to reveal the focused column, in either direction.
-- "center" always centers the focused column. These remain estimates when
-- attaching mid-session, scrolling without changing focus, or using struts.

-- ── Configuration ─────────────────────────────────────────────────────────
local BAR_COLOR = noctalia.getConfig("bar_color") or "outline"
local VIEWPORT_COLOR = noctalia.getConfig("viewport_color") or "primary"
local SHOW_ACTIVE_WINDOW = noctalia.getConfig("show_active_window") == true
local ACTIVE_WINDOW_COLOR = noctalia.getConfig("active_window_color") or "secondary"
local ANIMATION_SPEED = math.max(0, noctalia.getConfig("animation_speed") or 1.0)
local THICKNESS = noctalia.getConfig("thickness") or 4.0
local RADIUS = noctalia.getConfig("radius") or 2.0
-- Viewport estimation model: "fit" (niri default `never`) | "center" (`always`)
local VIEWPORT_MODEL = noctalia.getConfig("viewport_model") or "fit"
-- The niri `layout.gaps` value (logical pixels), used to estimate the total
-- canvas width and padding. Defaults to 0.0 (the niri upstream default).
local GAPS = noctalia.getConfig("gaps") or 0.0

-- ── Viewport state ────────────────────────────────────────────────────────
local ratioStart = 0.0
local ratioWidth = 1.0
local windowStart, windowWidth = 0, 0
local targetWindowStart, targetWindowWidth = 0, 0
local fromWindowStart, fromWindowWidth = 0, 0
local targetStart = ratioStart
local targetWidth = ratioWidth
local fromStart = ratioStart
local fromWidth = ratioWidth
local animationStartedMs = nil
local initialized = false
local workspaceViews = {}
local ANIMATION_DURATION_MS = 200 / math.max(0.01, ANIMATION_SPEED)
local FRAME_INTERVAL_MS = 16
-- The host requires a positive interval. State watches deliver actual updates.
local IDLE_INTERVAL_MS = 60000

-- ── Rendering ─────────────────────────────────────────────────────────────
local function render()
  -- Explicit widths also collapse a gap to zero. A flexGrow of zero instead
  -- lets the host measure the box using its previous laid-out width.
  local width = 80
  local viewport
  if SHOW_ACTIVE_WINDOW then
    local left = math.max(ratioStart, math.min(ratioStart + ratioWidth, windowStart))
    local right = math.max(left, math.min(ratioStart + ratioWidth, windowStart + windowWidth))
    local children = {
      ui.box({ width = width * (left - ratioStart), height = THICKNESS, opacity = 0 }),
    }
    children[#children + 1] = ui.box({
      width = width * (right - left), height = THICKNESS,
      fill = ACTIVE_WINDOW_COLOR, radius = RADIUS,
    })
    children[#children + 1] = ui.box({
      width = width * (ratioStart + ratioWidth - right), height = THICKNESS, opacity = 0,
    })
    viewport = ui.row({ width = width * ratioWidth, height = THICKNESS,
      gap = 0, padding = 0, fill = VIEWPORT_COLOR, radius = RADIUS }, children)
  else
    viewport = ui.box({ width = width * ratioWidth, height = THICKNESS, fill = VIEWPORT_COLOR, radius = RADIUS })
  end
  barWidget.render(ui.row({ width = width, height = THICKNESS, gap = 0, padding = 0 }, {
    ui.box({ width = width * ratioStart, height = THICKNESS, fill = BAR_COLOR }),
    viewport,
    ui.box({ width = width * math.max(0, 1 - ratioStart - ratioWidth), height = THICKNESS, fill = BAR_COLOR }),
  }))
end

-- ── Transitions ───────────────────────────────────────────────────────────
local function animateTo(nextStart, nextWidth, nextWindowStart, nextWindowWidth)
  nextWindowStart = SHOW_ACTIVE_WINDOW and nextWindowStart or 0
  nextWindowWidth = SHOW_ACTIVE_WINDOW and nextWindowWidth or 0
  nextWindowStart, nextWindowWidth = nextWindowStart or 0, nextWindowWidth or 0
  if initialized and nextStart == targetStart and nextWidth == targetWidth
    and nextWindowStart == targetWindowStart and nextWindowWidth == targetWindowWidth then
    return
  end
  -- Initial state and speed zero are immediate, with no animation ticks.
  if not initialized or ANIMATION_SPEED == 0 then
    initialized = true
    windowStart, windowWidth = nextWindowStart, nextWindowWidth
    targetWindowStart, targetWindowWidth = nextWindowStart, nextWindowWidth
    ratioStart, ratioWidth = nextStart, nextWidth
    targetStart, targetWidth = nextStart, nextWidth
    animationStartedMs = nil
    render()
    return
  end
  -- Retarget from the last rendered frame so rapid focus changes stay smooth.
  fromWindowStart, fromWindowWidth = windowStart, windowWidth
  targetWindowStart, targetWindowWidth = nextWindowStart, nextWindowWidth
  fromStart, fromWidth = ratioStart, ratioWidth
  targetStart, targetWidth = nextStart, nextWidth
  local wasAnimating = animationStartedMs ~= nil
  animationStartedMs = noctalia.nowMs()
  if not wasAnimating then
    noctalia.setUpdateInterval(FRAME_INTERVAL_MS)
  end
end

function update()
  if animationStartedMs == nil then
    return
  end
  local progress = math.max(0, math.min(1,
    (noctalia.nowMs() - animationStartedMs) / ANIMATION_DURATION_MS))
  local eased = 1 - (1 - progress) ^ 3 -- cubic ease-out
  -- Interpolating both ratios with the same weight keeps the highlight in bounds.
  ratioStart = fromStart + (targetStart - fromStart) * eased
  ratioWidth = fromWidth + (targetWidth - fromWidth) * eased
  windowStart = fromWindowStart + (targetWindowStart - fromWindowStart) * eased
  windowWidth = fromWindowWidth + (targetWindowWidth - fromWindowWidth) * eased
  if progress >= 1 then
    windowStart, windowWidth = targetWindowStart, targetWindowWidth
    ratioStart, ratioWidth = targetStart, targetWidth
    animationStartedMs = nil
    noctalia.setUpdateInterval(IDLE_INTERVAL_MS)
  end
  render()
end

local function widgetOutputName()
  if barWidget.outputName then
    local ok, name = pcall(barWidget.outputName)
    if ok and type(name) == "string" and name ~= "" then
      return name
    end
  end
  return nil
end

-- ── Algorithm ─────────────────────────────────────────────────────────────
-- Returns (ratioStart, ratioWidth), both clamped to [0, 1] with sum <= 1.
-- ratioStart/ratioWidth describe the viewport highlight as the
-- [start, start+width] fraction of the ribbon.
local function computeRatios(windows, workspaces, outputs)
  if not windows or not workspaces or not outputs then
    return 0.0, 1.0
  end

  -- Workspace IDs are stable; workspace indices repeat across monitors.
  local liveIds = {}
  for _, ws in ipairs(workspaces) do
    liveIds[ws.id] = true
  end
  for id in pairs(workspaceViews) do
    if not liveIds[id] then
      workspaceViews[id] = nil
    end
  end

  local connector = widgetOutputName()
  local focusedWs = nil
  for _, ws in ipairs(workspaces) do
    if (connector and ws.output == connector and ws.is_active)
      or (not connector and ws.is_focused) then
      focusedWs = ws
      break
    end
  end
  if not focusedWs and not connector then
    for _, ws in ipairs(workspaces) do
      if ws.is_active then
        focusedWs = ws
        break
      end
    end
  end
  if not focusedWs then
    return 0.0, 1.0
  end

  local wsId = focusedWs.id
  local outputName = focusedWs.output
  local activeWinId = focusedWs.active_window_id

  local output = outputs[outputName]
  if not output or not output.logical then
    return 0.0, 1.0
  end
  -- Note: strictly the view width should be working_area.size.w (minus
  -- struts), but the niri IPC does not expose working_area, so
  -- output.logical.width is an approximation. Non-empty struts (external
  -- panels on the sides) introduce a deviation; most configurations have
  -- empty struts, where it is negligible.
  local viewWidth = (output.logical.width or 1920)
  if viewWidth <= 0 then
    return 0.0, 1.0
  end

  -- Collect the workspace's non-floating windows
  local wsWindows = {}
  for _, w in ipairs(windows) do
    if w.workspace_id == wsId and not w.is_floating then
      table.insert(wsWindows, w)
    end
  end
  if #wsWindows == 0 then
    workspaceViews[wsId] = nil
    return 0.0, 1.0
  end

  -- Collect column widths: pos_in_scrolling_layout[1] is the column index
  -- (niri positions are 1-indexed)
  local columns = {} -- { [col_idx] = width }
  for _, w in ipairs(wsWindows) do
    local layout = w.layout or {}
    local pos = layout.pos_in_scrolling_layout
    if type(pos) == "table" and #pos >= 1 then
      local colIdx = pos[1]
      local tileSize = layout.tile_size or {}
      local width = (#tileSize >= 1) and tileSize[1] or 0
      if columns[colIdx] == nil then
        columns[colIdx] = width
      end
    end
  end

  -- Sort column indices
  local colIndices = {}
  for k in pairs(columns) do
    table.insert(colIndices, k)
  end
  table.sort(colIndices)

  -- No scrolling geometry available.
  if #colIndices == 0 then
    workspaceViews[wsId] = nil
    return 0.0, 1.0
  end

  -- Total canvas width = sum(column widths) + (columns-1)*gaps
  -- (niri inserts one gaps between every two adjacent columns)
  local sumWidths = 0
  for _, idx in ipairs(colIndices) do
    sumWidths = sumWidths + columns[idx]
  end
  local gapsTotal = (#colIndices - 1) * GAPS
  local canvasWidth = math.max(sumWidths + gapsTotal, viewWidth)

  -- The service supplies the workspace's active window ID; published windows
  -- contain geometry only, with no global focus flag.
  local targetWinId = activeWinId
  local targetWin = nil
  for _, w in ipairs(wsWindows) do
    if w.id == targetWinId then
      targetWin = w
      break
    end
  end
  -- wsWindows[1] always exists: #wsWindows == 0 returned early above
  targetWin = targetWin or wsWindows[1]

  -- Left x of the focused column on the canvas (preceding widths + gaps)
  local fLayout = targetWin.layout or {}
  local fPos = fLayout.pos_in_scrolling_layout or {1}
  local fIdx = fPos[1] or 1
  local fWidth = columns[fIdx] or 0
  local colX = 0
  for _, idx in ipairs(colIndices) do
    if idx == fIdx then
      break
    end
    colX = colX + (columns[idx] or 0) + GAPS
  end

  -- Keep each workspace's resting estimate independent of the animation.
  local previous = workspaceViews[wsId]
  if previous and previous.output ~= outputName then
    previous = nil
  end
  local viewPos
  if targetWinId == nil or targetWin.id ~= targetWinId then
    -- Floating focus should not move the scrolling ribbon to an arbitrary tile.
    viewPos = previous and previous.position or 0
  elseif VIEWPORT_MODEL == "center" then
    viewPos = colX + fWidth / 2 - viewWidth / 2
  else
    local padding = math.min(math.max(0, (viewWidth - fWidth) / 2), GAPS)
    local leftAligned = colX - padding
    local rightAligned = colX + fWidth + padding - viewWidth
    viewPos = previous and previous.position or math.max(0, rightAligned)
    if fWidth >= viewWidth then
      viewPos = colX
    elseif leftAligned < viewPos then
      viewPos = leftAligned
    elseif rightAligned > viewPos then
      viewPos = rightAligned
    end
  end
  viewPos = math.max(0, math.min(canvasWidth - viewWidth, viewPos))
  workspaceViews[wsId] = { position = viewPos, output = outputName }

  local rStart = viewPos / canvasWidth
  local rWidth = viewWidth / canvasWidth

  -- Clamp to [0, 1] and keep rStart + rWidth <= 1
  rStart = math.max(0.0, math.min(1.0, rStart))
  rWidth = math.max(0.01, math.min(1.0, rWidth))
  if rStart + rWidth > 1.0 then
    rStart = 1.0 - rWidth
  end

  local activeStart, activeWidth = 0, 0
  if targetWinId ~= nil and targetWin.id == targetWinId then
    activeStart = math.max(rStart, colX / canvasWidth)
    local activeEnd = math.min(rStart + rWidth, (colX + fWidth) / canvasWidth)
    activeWidth = math.max(0, activeEnd - activeStart)
  end
  return rStart, rWidth, activeStart, activeWidth
end

-- ── Shared compositor state ──────────────────────────────────────────────
local function applySnapshot(value)
  if type(value) ~= "table" then return end
  if value.windows and value.workspaces and value.outputs then
    animateTo(computeRatios(value.windows, value.workspaces, value.outputs))
  else
    animateTo(0, 1)
  end
end

-- ── Scroll interaction ────────────────────────────────────────────────────
-- Noctalia native API (PR#3428, merged 2026-07): fires once per wheel detent
-- (axis = "vertical"|"horizontal", steps is the step count (negative =
-- up/left), startsGesture is true on the first step after the scroll stream
-- goes quiet or reverses direction — not limited to touchpad flicks). Users
-- can override or disable this callback via gesture bindings (scroll_up/...)
-- or enable_scroll = false.
-- niri-ribbon is a horizontal ribbon: both axes map to focus-column changes:
--   steps < 0 (scroll up / left)    -> focus-column-left
--   steps > 0 (scroll down / right) -> focus-column-right
-- Niri scrolls the viewport as needed to reveal the newly focused column.
-- Keep this focus-relative: focus-monitor warps the pointer even when the
-- requested output is already focused.
function onScroll(_axis, steps, _startsGesture)
  -- Noctalia guarantees steps is non-zero (continuous sources only fire the
  -- callback once a full detent accrues); this check is purely defensive
  if steps == 0 then
    return
  end
  local action = (steps < 0) and "focus-column-left" or "focus-column-right"
  noctalia.runAsync("niri msg action " .. action)
end

noctalia.setUpdateInterval(IDLE_INTERVAL_MS)
render()
local connector = widgetOutputName()
local stateKey = connector and ("output:" .. connector) or "focused"
noctalia.state.watch(stateKey, applySnapshot)
local initial = noctalia.state.get(stateKey)
if initial then applySnapshot(initial) end
