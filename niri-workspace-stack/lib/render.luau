--!nonstrict
-- ui.* builders for the three display modes and the navigator panel. They only map the
-- derived states from lib/view.luau to props.
--
-- Two host rules apply to everything here:
--   * every style prop (fill, border, borderWidth, opacity) is passed on every render,
--     because the reconciler keeps a retained row/column's fill/border when it is omitted;
--   * a slot's size never depends on focus, so focus changes never change the widget width.

local View = require("./view.luau")

local R = {}

R.TRANSPARENT = "#00000000"
local T = R.TRANSPARENT

-- Palette role with alpha ("primary/0.45"); theme-aware, resolved live by the host.
local function a(role, alpha)
  return string.format("%s/%.2f", role, alpha)
end
R.alpha = a

-- ── Tooltips: explain the state, not just the number ────────────────────────

function R.workspaceTooltip(ctx, ws, view)
  local lines = {}
  local title = noctalia.tr("tooltip.workspace_title", { idx = tostring(ws.idx) })
  if ws.name ~= nil and ws.name ~= "" then
    title = title .. " · " .. ws.name
  end
  lines[#lines + 1] = title
  if ws.state == "active_focused" then
    lines[#lines + 1] = noctalia.tr("tooltip.active_focused", { output = view.output })
  elseif ws.state == "active" then
    lines[#lines + 1] = noctalia.tr("tooltip.active_unfocused", { output = view.output })
  end
  if ws.windowCount == 0 then
    lines[#lines + 1] = noctalia.tr("tooltip.empty")
  else
    lines[#lines + 1] = noctalia.trp("tooltip.windows", ws.windowCount, { apps = table.concat(ws.apps, ", ") })
  end
  if ws.urgent then
    lines[#lines + 1] = noctalia.tr("tooltip.urgent")
  end
  if ws.state ~= "active_focused" then
    lines[#lines + 1] = noctalia.tr("tooltip.click_switch")
  end
  return table.concat(lines, "\n")
end

-- Full title (never shortened here), then the app (short name and app id), floating, and
-- what a click does.
function R.windowTooltip(window)
  local appId = window.appId ~= nil and window.appId ~= "" and window.appId or nil
  local title = window.title ~= nil and window.title ~= "" and window.title or nil
  local lines = { title or appId or "?" }
  local app = View.appName(appId)
  if appId ~= nil and app ~= appId then
    app = app .. " (" .. appId .. ")"
  end
  if lines[1] ~= app then
    lines[#lines + 1] = app
  end
  if window.floating then
    lines[#lines + 1] = noctalia.tr("tooltip.window_floating")
  end
  if window.urgent then
    lines[#lines + 1] = noctalia.tr("tooltip.urgent")
  end
  local stateKey = window.state == "focused" and "tooltip.window_focused"
    or (window.state == "current" and "tooltip.window_current" or "tooltip.window_normal")
  lines[#lines + 1] = noctalia.tr(stateKey)
  return table.concat(lines, "\n")
end

-- ── Shared pieces ───────────────────────────────────────────────────────────

-- Bar label width: fixed for numbers (1-2 digits), grows with a name's length up to
-- LABEL_MAX_WIDTH, beyond which the host ellipsizes. Always explicit (stale width otherwise).
local LABEL_MAX_WIDTH = 72
local function labelWidth(text, s)
  local chars = utf8.len(text) or #text
  if chars <= 2 then
    return 16 * s
  end
  return math.min(LABEL_MAX_WIDTH, 7 * chars + 4) * s
end
R.labelWidth = labelWidth

-- Active workspace number with the focused-monitor marker underneath. Fixed width for
-- numbers, so switching 9 -> 10 or changing focus does not move the icons.
function R.numberBlock(ctx, view)
  local s = ctx.size
  local ws = view.activeWorkspace
  local label = ws and View.shorten(ws.label, View.BADGE_MAX_CHARS) or "–"
  return ui.column({ key = "number", gap = 1, align = "center", justify = "center" }, {
    ui.label({
      key = "label",
      text = label,
      fontSize = 13 * s,
      fontWeight = "bold",
      color = view.isFocusedOutput and "primary" or a("on_surface", 0.6),
      width = labelWidth(label, s),
      maxWidth = LABEL_MAX_WIDTH * s,
      maxLines = 1,
      textAlign = "center",
    }),
    ui.box({
      key = "focus-marker",
      width = 10 * s,
      height = 2,
      radius = 1,
      fill = view.isFocusedOutput and "primary" or T,
    }),
  })
end

-- Tiny "more workspaces above/below" marker; always laid out so the stack never jumps.
local function edgeMarker(key, visible, s)
  return ui.box({
    key = key,
    width = 3 * s,
    height = 2 * s,
    radius = 1,
    fill = visible and a("on_surface", 0.5) or T,
  })
end

local function windowItem(ctx, window)
  local s = ctx.size
  local path = ctx.iconFor(window.appId)
  local icon = path and ui.image({ key = "icon", path = path, width = ctx.iconSize, height = ctx.iconSize, fit = "contain" })
    or ui.glyph({ key = "glyph", name = "app-window", size = ctx.iconSize * 0.85 })
  local fill, border, opacity = T, T, 0.7
  if window.state == "focused" then
    fill, border, opacity = a("primary", 0.22), "primary", 1
  elseif window.state == "current" then
    border, opacity = a("on_surface", 0.45), 0.9
  end
  if window.urgent then
    border = "error"
  end
  local id = window.id
  return ui.row({
    key = "win-" .. tostring(id),
    padding = 2 * s,
    radius = 5 * s,
    align = "center",
    justify = "center",
    fill = fill,
    border = border,
    borderWidth = 1,
    opacity = opacity,
    onClick = function()
      ctx.onWindow(id)
    end,
    tooltip = R.windowTooltip(window),
  }, { icon })
end

function R.windowStrip(ctx, view, vertical)
  if not ctx.showWindows or #view.windows == 0 then
    return nil
  end
  local items = {}
  for _, window in ipairs(view.windows) do
    items[#items + 1] = windowItem(ctx, window)
  end
  if view.overflow > 0 then
    items[#items + 1] = ui.label({
      key = "overflow",
      text = "+" .. tostring(view.overflow),
      fontSize = ctx.iconSize * 0.6,
      color = a("on_surface", 0.7),
    })
  end
  local container = vertical and ui.column or ui.row
  return container({ key = "windows", gap = ctx.gap, align = "center" }, items)
end

-- ── A. Numbered Rail ────────────────────────────────────────────────────────

local function railStyle(ws)
  if ws.urgent then
    return "error", T
  end
  if ws.state == "active_focused" then
    return "primary", T
  elseif ws.state == "active" then
    return a("primary", 0.45), T
  elseif ws.state == "occupied" then
    return a("on_surface", 0.55), T
  end
  return T, a("on_surface", 0.4) -- empty: outline only
end

function R.rail(ctx, view)
  local s = ctx.size
  local thick, gap = 4 * s, ctx.compact and 2 * s or 3 * s
  local long, short = 18 * s, 10 * s
  local children = { edgeMarker("above", view.hiddenAbove > 0, s) }
  for _, ws in ipairs(view.workspaces) do
    local fill, border = railStyle(ws)
    local id = ws.id
    children[#children + 1] = ui.row({
      key = "ws-" .. tostring(id),
      width = long,
      height = thick + gap,
      align = "center",
      justify = "center",
      fill = T,
      border = T,
      borderWidth = 0,
      opacity = 1,
      onClick = function()
        ctx.onWorkspace(id)
      end,
      tooltip = R.workspaceTooltip(ctx, ws, view),
    }, {
      ui.box({
        key = "pill",
        width = ws.active and long or short,
        height = thick,
        radius = thick / 2,
        fill = fill,
        border = border,
        borderWidth = 1,
      }),
    })
  end
  children[#children + 1] = edgeMarker("below", view.hiddenBelow > 0, s)
  return ui.column({ key = "rail", gap = 0, align = "center", justify = "center" }, children)
end

-- ── B. Mini Map ─────────────────────────────────────────────────────────────

local MAX_DOTS = 4

local function rowFill(ws)
  if ws.state == "active_focused" then
    return a("primary", 0.22), "primary"
  elseif ws.state == "active" then
    return a("on_surface", 0.10), a("on_surface", 0.35)
  end
  return T, T
end

local function dotFill(dot)
  if dot.urgent then
    return "error"
  elseif dot.state == "focused" then
    return "primary"
  elseif dot.state == "current" then
    return "on_surface"
  end
  return a("on_surface", 0.5)
end

function R.miniMap(ctx, view)
  local s = ctx.size
  local d = 4 * s
  local padH, padV = 3 * s, ctx.compact and 1 * s or 1.5 * s
  local rowWidth = MAX_DOTS * d + (MAX_DOTS - 1) * s + d * 1.5 + padH * 2
  local children = { edgeMarker("above", view.hiddenAbove > 0, s) }
  for _, row in ipairs(View.miniMap(view, MAX_DOTS)) do
    local ws = row.workspace
    local fill, border = rowFill(ws)
    local dots = {}
    if #row.dots == 0 then
      dots[1] = ui.box({ key = "empty", width = d, height = d, radius = d / 2, fill = T, border = a("on_surface", 0.4), borderWidth = 1 })
    end
    for i, dot in ipairs(row.dots) do
      dots[#dots + 1] = ui.box({ key = "dot-" .. tostring(i), width = d, height = d, radius = d / 2, fill = dotFill(dot), border = T, borderWidth = 0 })
    end
    if row.more then
      dots[#dots + 1] = ui.box({ key = "more", width = d * 1.5, height = d * 0.6, radius = d * 0.3, fill = a("on_surface", 0.5) })
    end
    local id = ws.id
    children[#children + 1] = ui.row({
      key = "ws-" .. tostring(id),
      width = rowWidth,
      height = d + padV * 2,
      gap = 1 * s,
      paddingH = padH,
      paddingV = padV,
      radius = (d + padV * 2) / 2,
      align = "center",
      justify = "start",
      fill = fill,
      border = border,
      borderWidth = ws.active and 1 or 0,
      opacity = 1,
      onClick = function()
        ctx.onWorkspace(id)
      end,
      tooltip = R.workspaceTooltip(ctx, ws, view),
    }, dots)
  end
  children[#children + 1] = edgeMarker("below", view.hiddenBelow > 0, s)
  return ui.column({ key = "map", gap = 0, align = "center", justify = "center" }, children)
end

-- ── C. Navigator badge (the list lives in panel.luau) ───────────────────────

-- No onClick on purpose: a left click falls through to the widget's gesture binding
-- `panel-toggle …:navigator`, the only public way to open a panel anchored at this
-- widget on this bar's output.
function R.navigatorBadge(ctx, view)
  local s = ctx.size
  local nav = View.navigator(view)
  local chevron = function(key, name, on)
    return ui.glyph({ key = key, name = name, size = 9 * s, color = on and "on_surface" or a("on_surface", 0.2) })
  end
  local tip = nav.label
  if view.activeWorkspace ~= nil then
    tip = R.workspaceTooltip(ctx, view.activeWorkspace, view)
  end
  tip = tip .. "\n" .. noctalia.tr("tooltip.navigator", { position = tostring(nav.position), total = tostring(nav.total) })
  return ui.row({
    key = "badge",
    gap = 2 * s,
    paddingH = 5 * s,
    paddingV = 2 * s,
    radius = 7 * s,
    align = "center",
    fill = a("surface_variant", 0.6),
    border = nav.focused and "primary" or T,
    borderWidth = 1,
    opacity = 1,
    tooltip = tip,
  }, {
    ui.label({
      key = "label",
      text = nav.label,
      fontSize = 13 * s,
      fontWeight = "bold",
      color = nav.focused and "primary" or a("on_surface", 0.65),
      width = labelWidth(nav.label, s),
      maxWidth = LABEL_MAX_WIDTH * s,
      maxLines = 1,
      textAlign = "center",
    }),
    ui.column({ key = "chevrons", gap = 0, align = "center" }, {
      chevron("up", "chevron-up", nav.hasAbove),
      chevron("down", "chevron-down", nav.hasBelow),
    }),
  })
end

-- ── Navigator panel list ────────────────────────────────────────────────────

function R.panelList(ctx, view, onClose)
  local rows = {}
  for _, ws in ipairs(view.all) do
    local id = ws.id
    local fill, border = T, T
    if ws.state == "active_focused" then
      fill, border = a("primary", 0.16), "primary"
    elseif ws.state == "active" then
      fill, border = a("on_surface", 0.08), a("on_surface", 0.3)
    end
    local icons = {}
    for i, window in ipairs(ws.windows) do
      if i > 8 then
        icons[#icons + 1] = ui.label({ key = "more", text = "+" .. tostring(#ws.windows - 8), fontSize = 11, color = a("on_surface", 0.7) })
        break
      end
      icons[#icons + 1] = windowItem(ctx, window)
    end
    if #icons == 0 then
      icons[1] = ui.label({ key = "empty", text = noctalia.tr("panel.empty"), fontSize = 11, color = a("on_surface", 0.5) })
    end
    rows[#rows + 1] = ui.row({
      key = "row-" .. tostring(id),
      gap = 8,
      paddingH = 8,
      paddingV = 4,
      radius = 8,
      align = "center",
      fill = fill,
      border = border,
      borderWidth = 1,
      opacity = 1,
      onClick = function()
        ctx.onWorkspace(id)
        onClose()
      end,
      tooltip = R.workspaceTooltip(ctx, ws, view),
    }, {
      ui.label({ key = "idx", text = tostring(ws.idx), fontSize = 14, fontWeight = "bold", width = 22, textAlign = "center",
        color = ws.state == "active_focused" and "primary" or "on_surface" }),
      ui.label({ key = "name", text = View.shorten(ws.name, View.PANEL_MAX_CHARS) or "", fontSize = 12, width = 96,
        maxWidth = 96, maxLines = 1, color = a("on_surface", 0.8) }),
      ui.row({ key = "icons", gap = 3, align = "center", flexGrow = 1 }, icons),
    })
  end
  local header = noctalia.tr("panel.title", { output = tostring(view.output) })
  if view.isFocusedOutput then
    header = header .. " · " .. noctalia.tr("panel.focused")
  end
  return ui.column({ key = "panel", gap = 8, padding = 12 }, {
    ui.label({ key = "title", text = header, fontSize = 14, fontWeight = "semibold", color = "primary" }),
    ui.scroll({ key = "list", gap = 4, flexGrow = 1 }, rows),
  })
end

return R
