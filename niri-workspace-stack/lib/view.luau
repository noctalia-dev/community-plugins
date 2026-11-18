--!nonstrict
-- Derived data for one output. Pure: no noctalia.* / ui.* calls, so every display mode's
-- data can be unit-tested. The UI builders in lib/render.luau only map these states to
-- props; they never look at the model directly.
--
-- Highlight vocabulary, shared by all modes (one meaning per state):
--   workspace.state  "active_focused" active on the focused output (there is only one)
--                    "active"         active on another output (muted)
--                    "occupied" | "empty"
--   window.state     "focused"  global keyboard focus (at most one in the whole session)
--                    "current"  the workspace's own active window, shown where no window of
--                               this workspace holds keyboard focus (muted outline)
--                    "normal"

local Model = require("./model.luau")

local V = {}

local function windowState(model, ws, window, wsHasFocus)
  if model:isWindowFocused(window.id) then
    return "focused"
  end
  if not wsHasFocus and window.id == ws.activeWindowId then
    return "current"
  end
  return "normal"
end

local function workspaceState(ws, count, isFocusedOutput)
  if ws.isActive then
    return (isFocusedOutput and ws.isFocused) and "active_focused" or "active"
  end
  return count > 0 and "occupied" or "empty"
end

-- Shortens an app id for text: "org.telegram.desktop" -> "telegram", "firefox" -> "firefox".
function V.appName(appId)
  if appId == nil or appId == "" then
    return "?"
  end
  local parts = {}
  for part in string.gmatch(appId, "[^%.]+") do
    parts[#parts + 1] = part
  end
  local name = parts[#parts] or appId
  if (name == "desktop" or name == "app") and #parts > 1 then
    name = parts[#parts - 1]
  end
  return name
end

-- Label length limits (in characters, UTF-8 aware). The renderer also caps the width in
-- pixels, so a wide-glyph name cannot overflow either way.
V.BADGE_MAX_CHARS = 10
V.PANEL_MAX_CHARS = 16

-- `text` cut to `maxChars` characters with a trailing ellipsis; nil/"" stay as they are.
function V.shorten(text, maxChars)
  if text == nil or maxChars == nil or maxChars < 1 then
    return text
  end
  local count = utf8.len(text)
  if count == nil then
    -- Invalid UTF-8 (niri only sends valid strings): fall back to bytes.
    count = #text
    if count <= maxChars then
      return text
    end
    return string.sub(text, 1, math.max(1, maxChars - 1)) .. "…"
  end
  if count <= maxChars then
    return text
  end
  local cut = utf8.offset(text, maxChars) -- byte offset of the character the ellipsis replaces
  return string.sub(text, 1, cut - 1) .. "…"
end

local function hasName(ws)
  return ws.name ~= nil and ws.name ~= ""
end

-- Every workspace of `output` with derived fields, in niri order. Honors showEmpty: an
-- empty workspace is dropped unless it is active (so the active slot never disappears).
function V.workspaceList(model, output, opts)
  local focusedOutput = model:focusedOutput()
  local isFocusedOutput = output ~= nil and output == focusedOutput
  local out = {}
  for _, ws in ipairs(model:workspacesOn(output)) do
    local windows = model:windowsOf(ws.id)
    local count = #windows
    if opts.showEmpty ~= false or count > 0 or ws.isActive then
      local wsHasFocus = false
      for _, w in ipairs(windows) do
        if model:isWindowFocused(w.id) then
          wsHasFocus = true
        end
      end
      local items, apps = {}, {}
      for _, w in ipairs(windows) do
        items[#items + 1] = {
          id = w.id,
          appId = w.appId,
          title = w.title,
          state = windowState(model, ws, w, wsHasFocus),
          urgent = w.isUrgent,
          floating = w.isFloating,
        }
        apps[#apps + 1] = V.appName(w.appId)
      end
      out[#out + 1] = {
        id = ws.id,
        idx = ws.idx,
        name = hasName(ws) and ws.name or nil,
        named = hasName(ws),
        label = hasName(ws) and ws.name or tostring(ws.idx), -- full; shorten() for display
        state = workspaceState(ws, count, isFocusedOutput),
        active = ws.isActive,
        urgent = ws.isUrgent,
        windowCount = count,
        windows = items,
        apps = apps,
      }
    end
  end
  return out, isFocusedOutput, focusedOutput
end

-- opts: { visibleWorkspaces, maxWindows (0 = all), showEmpty }
function V.build(model, output, opts)
  local list, isFocusedOutput, focusedOutput = V.workspaceList(model, output, opts)
  local view = {
    output = output,
    focusedOutput = focusedOutput,
    isFocusedOutput = isFocusedOutput,
    all = list, -- every listed workspace (navigator panel)
    workspaces = {}, -- the visible slice (rail, mini map)
    hiddenAbove = 0,
    hiddenBelow = 0,
    position = 0, -- 1-based position of the active workspace within `all`
    activeWorkspace = nil,
    windows = {},
    overflow = 0,
  }
  for i, ws in ipairs(list) do
    if ws.active then
      view.position = i
      view.activeWorkspace = ws
      break
    end
  end

  local first, last = Model.visibleRange(#list, view.position > 0 and view.position or 1, opts.visibleWorkspaces or 3)
  view.hiddenAbove = math.max(0, first - 1)
  view.hiddenBelow = math.max(0, #list - last)
  for i = first, last do
    view.workspaces[#view.workspaces + 1] = list[i]
  end

  local active = view.activeWorkspace
  if active ~= nil then
    local limit = #active.windows
    if (opts.maxWindows or 0) > 0 then
      limit = math.min(limit, opts.maxWindows)
    end
    for i = 1, limit do
      view.windows[#view.windows + 1] = active.windows[i]
    end
    view.overflow = #active.windows - limit
  end
  return view
end

-- Mini map rows: per visible workspace, up to `maxDots` window dots (+ overflow flag).
function V.miniMap(view, maxDots)
  local rows = {}
  for _, ws in ipairs(view.workspaces) do
    local dots = {}
    for i = 1, math.min(#ws.windows, maxDots) do
      dots[i] = { id = ws.windows[i].id, state = ws.windows[i].state, urgent = ws.windows[i].urgent }
    end
    rows[#rows + 1] = { workspace = ws, dots = dots, more = #ws.windows > maxDots }
  end
  return rows
end

-- Navigator badge: the active workspace (name if it has one, else its number, shortened to
-- BADGE_MAX_CHARS) and whether niri has workspaces above/below it.
function V.navigator(view)
  local total = #view.all
  local active = view.activeWorkspace
  return {
    label = active and V.shorten(active.label, V.BADGE_MAX_CHARS) or "–",
    fullLabel = active and active.label or nil,
    named = active ~= nil and active.named,
    truncated = active ~= nil and V.shorten(active.label, V.BADGE_MAX_CHARS) ~= active.label,
    position = view.position,
    total = total,
    hasAbove = view.position > 1,
    hasBelow = view.position > 0 and view.position < total,
    focused = view.isFocusedOutput,
  }
end

-- The workspace `delta` positions away from the active one on this output (wheel and
-- navigator), clamped to the list; nil when there is nowhere to go.
function V.neighbor(view, delta)
  if view.position == 0 then
    return nil
  end
  local target = math.max(1, math.min(#view.all, view.position + delta))
  if target == view.position then
    return nil
  end
  return view.all[target]
end

return V
