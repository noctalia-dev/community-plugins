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
-- Mechanism: subscribe to `niri msg -j event-stream`; on structural changes
-- fetch windows/workspaces/outputs via three concurrent runAsync queries;
-- once all callbacks arrive, compute ratioStart/ratioWidth and render the
-- ribbon overview with a row + 3 boxes (left gap / viewport highlight /
-- right gap).
--
-- Key design notes:
--   * runStream is killed automatically by Noctalia when the widget unmounts;
--     no manual lifecycle management needed.
--   * fetchAll debounces via an inFlight + dirty flag: when events arrive
--     while a query round is in flight, one more round runs right after it
--     completes, so the final state is never missed.
--
-- ── Viewport estimation (the hard part) ───────────────────────────────────
-- The niri IPC (26.04 through current HEAD) exposes neither the live viewport
-- offset (view_pos) nor any "viewport scrolled" event. The WorkspaceViewChanged
-- event assumed by the original ews implementation has never existed upstream,
-- so this plugin estimates the resting viewport position from the focused
-- window plus geometry.
--
-- Estimation models (selected via `viewport_model`; should match niri
-- `center-focused-column`):
--   * "fit"    — matches niri `center-focused-column: never` (niri default).
--                niri behavior: focusing an off-screen column snaps it near a
--                viewport edge (left or right, whichever moves less); columns
--                already visible stay put. We approximate the steady state of
--                the common interaction (focusing columns left to right) as
--                "focused column right-aligned to the viewport":
--                  view_pos = clamp(col_x + col_w + padding - view_w, 0, canvas)
--                This simplified formula deviates from a per-column simulation
--                (focusing from the leftmost column up to the focused one) by
--                at most one gaps value (usually <= 8px) — imperceptible on a
--                ribbon ~80px wide.
--   * "center" — matches niri `center-focused-column: always`.
--                niri behavior: the focused column is always centered.
--                Formula:
--                  view_pos = col_x + col_w/2 - view_w/2
--
-- Known limitations (inherent without live viewport data; exact rendering
-- would need niri to expose view_pos upstream):
--   (1) When focusing columns right-to-left, niri's actual steady state tends
--       toward "focused column left-aligned", while the "fit" model still
--       assumes right-alignment — a visible deviation.
--   (2) When the newly focused column is already inside the viewport (niri
--       keeps the view unchanged for visible columns), the "fit" model still
--       recomputes as right-aligned, which does not match niri's "keep it".
--       Root cause: the IPC does not expose the current view_pos, so "already
--       visible" cannot be detected. Typical trigger: clicking a non-adjacent
--       column inside the viewport.
--
-- Upstream progress: niri PR#4147 (https://github.com/niri-wm/niri/pull/4147,
-- 2026-06) proposes Workspace.scrolling_view_pos + Event::WorkspaceViewPosChanged
-- — exactly what this plugin needs (per-workspace view_pos with a resting
-- target to avoid animation-interpolated IPC spam). The maintainer (YaLTeR)
-- acknowledged the problem in #2381 but opposed a per-tile approach, and has
-- not commented on that PR yet. Once it lands in a stable release, this plugin
-- can consume the real view_pos and drop the estimation, removing both
-- limitations above.

-- ── Configuration ─────────────────────────────────────────────────────────
local BAR_COLOR = noctalia.getConfig("bar_color") or "outline"
local VIEWPORT_COLOR = noctalia.getConfig("viewport_color") or "primary"
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

-- ── Rendering ─────────────────────────────────────────────────────────────
local function render()
  local leftFlex = ratioStart
  local vpFlex = ratioWidth
  local rightFlex = math.max(0.0, 1.0 - ratioStart - ratioWidth)
  -- 3 boxes: flexGrow distributes the row's fixed width proportionally.
  -- Note: the row needs an explicit width; otherwise the bar plugin_widget
  -- sizes it with uiHost.width() (= 0) and the whole widget stays invisible
  -- (flexGrow has no effect inside a zero-width parent).
  barWidget.render(ui.row({ width = 80, height = THICKNESS, gap = 0, padding = 0 }, {
    ui.box({ flexGrow = leftFlex, fill = BAR_COLOR }),
    ui.box({ flexGrow = vpFlex, fill = VIEWPORT_COLOR, radius = RADIUS }),
    ui.box({ flexGrow = rightFlex, fill = BAR_COLOR }),
  }))
end

-- ── Algorithm ─────────────────────────────────────────────────────────────
-- Returns (ratioStart, ratioWidth), both clamped to [0, 1] with sum <= 1.
-- ratioStart/ratioWidth describe the viewport highlight as the
-- [start, start+width] fraction of the ribbon.
local function computeRatios(windows, workspaces, outputs)
  if not windows or not workspaces or not outputs then
    return 0.0, 1.0
  end

  -- Find the focused workspace, fall back to the first active one
  local focusedWs = nil
  for _, ws in ipairs(workspaces) do
    if ws.is_focused then
      focusedWs = ws
      break
    end
  end
  if not focusedWs then
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

  -- Single column or none: viewport fills the whole ribbon
  if #colIndices <= 1 then
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

  -- Locate the focused column (prefer workspace.active_window_id, fall back
  -- to the globally focused window)
  local targetWinId = activeWinId
  if targetWinId == nil then
    for _, w in ipairs(windows) do
      if w.is_focused and w.workspace_id == wsId then
        targetWinId = w.id
        break
      end
    end
  end
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

  -- Estimate the viewport's left edge in canvas coordinates (view_pos)
  local viewPos
  if VIEWPORT_MODEL == "center" then
    -- Focused column always centered: viewport center = column center
    viewPos = colX + fWidth / 2 - viewWidth / 2
  else
    -- "fit" model (steady-state approximation of niri `never`): focused
    -- column right-aligned to the viewport, left edge clamped to 0.
    -- Right-alignment puts the focused column at the right viewport edge and
    -- reveals previously focused columns to the left — the typical steady
    -- state of focusing columns left to right. If the focused column is wider
    -- than the viewport, fall back to left alignment (matches niri).
    if fWidth >= viewWidth then
      viewPos = colX
    else
      -- padding = min((view_w - col_w)/2, gaps), matching niri's
      -- compute_new_view_offset
      local padding = math.min((viewWidth - fWidth) / 2, GAPS)
      viewPos = colX + fWidth + padding - viewWidth
    end
    -- Clamp to [0, inf): niri actually allows view_pos < 0 (viewport left
    -- edge beyond the canvas, background visible on the left), but ribbon
    -- rendering requires rStart in [0, 1], so negatives clamp to 0 (the
    -- highlight starts at the ribbon's left end). This is a rendering
    -- constraint of the plugin, not upstream behavior.
    if viewPos < 0 then
      viewPos = 0
    end
  end

  local rStart = viewPos / canvasWidth
  local rWidth = viewWidth / canvasWidth

  -- Clamp to [0, 1] and keep rStart + rWidth <= 1
  rStart = math.max(0.0, math.min(1.0, rStart))
  rWidth = math.max(0.01, math.min(1.0, rWidth))
  if rStart + rWidth > 1.0 then
    rStart = 1.0 - rWidth
  end

  return rStart, rWidth
end

-- ── Data fetching (concurrent + debounced) ────────────────────────────────
local inFlight = false
local dirty = false
local snapshot = { windows = nil, workspaces = nil, outputs = nil }

local function fetchAll()
  if inFlight then
    dirty = true
    return
  end
  inFlight = true
  dirty = false
  snapshot = { windows = nil, workspaces = nil, outputs = nil }

  local remaining = 3

  local function onPart(key, result)
    if result.exitCode == 0 and result.stdout ~= "" then
      local ok, data = pcall(noctalia.json.decode, result.stdout)
      if ok then
        snapshot[key] = data
      end
    end
    remaining = remaining - 1
    if remaining == 0 then
      inFlight = false
      ratioStart, ratioWidth = computeRatios(snapshot.windows, snapshot.workspaces, snapshot.outputs)
      render()
      if dirty then
        -- More events arrived during the query round; run one more round to
        -- capture the final state
        fetchAll()
      end
    end
  end

  noctalia.runAsync("niri msg -j windows", function(r)
    onPart("windows", r)
  end)
  noctalia.runAsync("niri msg -j workspaces", function(r)
    onPart("workspaces", r)
  end)
  noctalia.runAsync("niri msg -j outputs", function(r)
    onPart("outputs", r)
  end)
end

-- ── Event stream ──────────────────────────────────────────────────────────
-- The niri event-stream emits no "viewport scrolled" event (no such event
-- type exists in the upstream niri IPC), so every structural change triggers
-- a full recomputation. The viewport position can only come from the
-- geometric estimation inside computeRatios.
-- Structural event types that trigger recomputation (tagged-union keys of
-- the niri event-stream)
local STRUCTURAL_EVENTS = {
  WorkspaceActivated = true,
  WindowOpenedOrChanged = true,
  WindowClosed = true,
  WorkspaceActiveWindowChanged = true,
  WindowFocusChanged = true,
  WindowsChanged = true,
  WorkspacesChanged = true,
  WindowLayoutsChanged = true,
}
local function onEventLine(line)
  if not line or line == "" then
    return
  end
  local ok, event = pcall(noctalia.json.decode, line)
  if not ok or type(event) ~= "table" then
    return
  end
  -- The event is a tagged union; hitting any structural key triggers a
  -- recompute (pairs only iterates keys with non-nil values, equivalent to
  -- the original `event.X ~= nil` checks)
  for key in pairs(event) do
    if STRUCTURAL_EVENTS[key] then
      fetchAll()
      return
    end
  end
end

-- ── Startup ───────────────────────────────────────────────────────────────
local function start()
  if not noctalia.commandExists("niri") then
    noctalia.notifyError("Niri Ribbon", "niri command not found in PATH")
    render()
    return
  end

  -- Initial computation + event-stream subscription (Noctalia kills the
  -- stream automatically when the widget unmounts)
  fetchAll()
  if not noctalia.runStream("niri msg -j event-stream", onEventLine) then
    noctalia.notifyError("Niri Ribbon", "Unable to subscribe to niri event-stream")
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
-- (In niri scrollable-tiling the focused column auto-centers, so "moving the
-- focused column" is equivalent to "scrolling the viewport sideways".)
function onScroll(_axis, steps, _startsGesture)
  -- Noctalia guarantees steps is non-zero (continuous sources only fire the
  -- callback once a full detent accrues); this check is purely defensive
  if steps == 0 then
    return
  end
  local action = (steps < 0) and "focus-column-left" or "focus-column-right"
  noctalia.runAsync("niri msg action " .. action)
end

start()
