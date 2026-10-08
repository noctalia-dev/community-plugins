--!nonstrict
-- Draws a compact, proportional map of every active Niri workspace. This is a
-- schematic made only from IPC metadata; it never captures window contents.

local STATE_KEY = "workspace_preview_snapshot"
local VIEWPORT_STATE_KEY = "workspace_preview_viewports"
local RENDER_TICK_MS = 50
local EVENT_SETTLE_MS = 120
local snapshot = noctalia.state.get(STATE_KEY)
local renderDueAt = nil
local render
local iconCache = {}
local iconDataCache = {}

local SIZE_MODE = noctalia.getConfig("size_mode") or "auto"
local PREVIEW_SIZE = math.max(12, tonumber(noctalia.getConfig("preview_size")) or 24)
local MAX_OUTPUT_LENGTH = math.max(24, tonumber(noctalia.getConfig("max_output_length")) or 160)
local FIXED_WIDTH = math.max(24, tonumber(noctalia.getConfig("fixed_width")) or 96)
local FIXED_HEIGHT = math.max(12, tonumber(noctalia.getConfig("fixed_height")) or 24)
local OUTPUT_GAP = math.max(0, tonumber(noctalia.getConfig("output_gap")) or 3)
local WINDOW_GAP = math.max(0, tonumber(noctalia.getConfig("window_gap")) or 1)
local VIEWPORT_MODE = noctalia.getConfig("viewport_mode") or "off"
local SHOW_VIEWPORT_MAP = VIEWPORT_MODE == "separate" or VIEWPORT_MODE == "both"
local HIGHLIGHT_VIEWPORT = VIEWPORT_MODE == "highlight" or VIEWPORT_MODE == "both"
local VIEWPORT_COLOR = noctalia.getConfig("viewport_color") or "tertiary"
local VIEWPORT_BORDER_WIDTH = math.max(1, tonumber(noctalia.getConfig("viewport_border_width")) or 2)
local SHOW_ICONS = noctalia.getConfig("show_icons") ~= false
local SHOW_FLOATING = noctalia.getConfig("show_floating") ~= false
local FLOATING_MODE = noctalia.getConfig("floating_mode") or "strip"
local FLOATING_COLOR = noctalia.getConfig("floating_color") or "#ffb74d"
local HIGHLIGHT_FOCUSED = noctalia.getConfig("highlight_focused") ~= false
local NORMAL_COLOR = noctalia.getConfig("normal_color") or "outline"
local ACTIVE_COLOR = noctalia.getConfig("active_color") or "secondary"
local FOCUSED_COLOR = noctalia.getConfig("focused_color") or "primary"
local URGENT_COLOR = noctalia.getConfig("urgent_color") or "error"
local INVERT_SCROLL = noctalia.getConfig("invert_scroll") == true
local HIGHLIGHT_HOVERED = noctalia.getConfig("highlight_hovered") ~= false
local HOVER_COLOR = noctalia.getConfig("hover_color") or "secondary"
local OUTPUT_SCOPE = noctalia.getConfig("output_scope") or "all"
local OUTPUT_NAMES = tostring(noctalia.getConfig("output_names") or "")
local generatedFiles = {}
local generatedByOutput = {}
local exactCache = {}
local themeColors = nil
local exactFocusCursor = {}
local windowClickTargets = {}
local windowClickSlots = {}
local nextWindowClickSlot = 1
local MAX_WINDOW_CLICK_SLOTS = 32
local stackClickTargets = {}
local stackClickSlots = {}
local stackClickCursors = {}
local nextStackClickSlot = 1
local MAX_STACK_CLICK_SLOTS = 16
local viewportStarts = noctalia.state.get(VIEWPORT_STATE_KEY)
if type(viewportStarts) ~= "table" then viewportStarts = {} end
local hoveredWindowIds = {}
local hoveredStackSlot = nil

local function trim(value)
  return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

local function widgetOutputName()
  if barWidget.outputName == nil then return nil end
  local ok, name = pcall(barWidget.outputName)
  if ok and type(name) == "string" and name ~= "" then return name end
  return nil
end

local function customOutputNames()
  local names = {}
  for rawName in OUTPUT_NAMES:gmatch("[^,;\n]+") do
    local name = trim(rawName)
    if name ~= "" then names[name] = true end
  end
  return names
end

local function selectedOutputs()
  local outputs = (snapshot and snapshot.outputs) or {}
  if OUTPUT_SCOPE == "all" then return outputs end

  local selected = {}
  if OUTPUT_SCOPE == "custom" then
    local names = customOutputNames()
    for _, output in ipairs(outputs) do
      if names[tostring(output.name or "")] then selected[#selected + 1] = output end
    end
    return selected
  end

  local connector = widgetOutputName()
  if connector ~= nil then
    for _, output in ipairs(outputs) do
      if output.name == connector then selected[#selected + 1] = output end
    end
    if #selected > 0 then return selected end
  end

  -- Older hosts may not expose the bar connector. Prefer the compositor's
  -- focused output, then the first physical output, instead of blanking.
  for _, output in ipairs(outputs) do
    if output.focused == true then return { output } end
  end
  if outputs[1] ~= nil then return { outputs[1] } end
  return selected
end

local function number(value, fallback)
  local converted = tonumber(value)
  if converted == nil then return fallback end
  return converted
end

local function colorWithAlpha(color, roleAlpha, hexAlpha)
  local value = tostring(color or "")
  if value:match("^#%x%x%x%x%x%x$") then return value .. hexAlpha end
  if value:match("^#%x%x%x%x%x%x%x%x$") then return value:sub(1, 7) .. hexAlpha end
  return value .. "/" .. roleAlpha
end

local function focusWindow(windowId)
  local id = tonumber(windowId)
  if id == nil then return end
  noctalia.runAsync("niri msg action focus-window --id " .. tostring(math.floor(id)))
end

local function focusWindowSlot(slot) focusWindow(windowClickTargets[slot]) end

function onWindowClick1() focusWindowSlot(1) end
function onWindowClick2() focusWindowSlot(2) end
function onWindowClick3() focusWindowSlot(3) end
function onWindowClick4() focusWindowSlot(4) end
function onWindowClick5() focusWindowSlot(5) end
function onWindowClick6() focusWindowSlot(6) end
function onWindowClick7() focusWindowSlot(7) end
function onWindowClick8() focusWindowSlot(8) end
function onWindowClick9() focusWindowSlot(9) end
function onWindowClick10() focusWindowSlot(10) end
function onWindowClick11() focusWindowSlot(11) end
function onWindowClick12() focusWindowSlot(12) end
function onWindowClick13() focusWindowSlot(13) end
function onWindowClick14() focusWindowSlot(14) end
function onWindowClick15() focusWindowSlot(15) end
function onWindowClick16() focusWindowSlot(16) end
function onWindowClick17() focusWindowSlot(17) end
function onWindowClick18() focusWindowSlot(18) end
function onWindowClick19() focusWindowSlot(19) end
function onWindowClick20() focusWindowSlot(20) end
function onWindowClick21() focusWindowSlot(21) end
function onWindowClick22() focusWindowSlot(22) end
function onWindowClick23() focusWindowSlot(23) end
function onWindowClick24() focusWindowSlot(24) end
function onWindowClick25() focusWindowSlot(25) end
function onWindowClick26() focusWindowSlot(26) end
function onWindowClick27() focusWindowSlot(27) end
function onWindowClick28() focusWindowSlot(28) end
function onWindowClick29() focusWindowSlot(29) end
function onWindowClick30() focusWindowSlot(30) end
function onWindowClick31() focusWindowSlot(31) end
function onWindowClick32() focusWindowSlot(32) end

local function focusStackSlot(slot)
  local targets = stackClickTargets[slot] or {}
  if #targets == 0 then return end
  local cursor = (stackClickCursors[slot] or 0) % #targets + 1
  stackClickCursors[slot] = cursor
  focusWindow(targets[cursor])
end

function onStackClick1() focusStackSlot(1) end
function onStackClick2() focusStackSlot(2) end
function onStackClick3() focusStackSlot(3) end
function onStackClick4() focusStackSlot(4) end
function onStackClick5() focusStackSlot(5) end
function onStackClick6() focusStackSlot(6) end
function onStackClick7() focusStackSlot(7) end
function onStackClick8() focusStackSlot(8) end
function onStackClick9() focusStackSlot(9) end
function onStackClick10() focusStackSlot(10) end
function onStackClick11() focusStackSlot(11) end
function onStackClick12() focusStackSlot(12) end
function onStackClick13() focusStackSlot(13) end
function onStackClick14() focusStackSlot(14) end
function onStackClick15() focusStackSlot(15) end
function onStackClick16() focusStackSlot(16) end

local function hoverStackSlot(slot, state)
  if state == "true" then
    hoveredStackSlot = slot
    hoveredWindowIds = {}
    for _, id in ipairs(stackClickTargets[slot] or {}) do hoveredWindowIds[id] = true end
    render()
  elseif hoveredStackSlot == slot then
    hoveredStackSlot = nil
    hoveredWindowIds = {}
    render()
  end
end

function onStackHover1(state) hoverStackSlot(1, state) end
function onStackHover2(state) hoverStackSlot(2, state) end
function onStackHover3(state) hoverStackSlot(3, state) end
function onStackHover4(state) hoverStackSlot(4, state) end
function onStackHover5(state) hoverStackSlot(5, state) end
function onStackHover6(state) hoverStackSlot(6, state) end
function onStackHover7(state) hoverStackSlot(7, state) end
function onStackHover8(state) hoverStackSlot(8, state) end
function onStackHover9(state) hoverStackSlot(9, state) end
function onStackHover10(state) hoverStackSlot(10, state) end
function onStackHover11(state) hoverStackSlot(11, state) end
function onStackHover12(state) hoverStackSlot(12, state) end
function onStackHover13(state) hoverStackSlot(13, state) end
function onStackHover14(state) hoverStackSlot(14, state) end
function onStackHover15(state) hoverStackSlot(15, state) end
function onStackHover16(state) hoverStackSlot(16, state) end

function onWindowHover(state, key)
  local text = tostring(key or "")
  local id = tonumber(text:match("^window%-icon%-(%d+)$") or text:match("^window%-(%d+)%-"))
  if id == nil then return end
  if state == "true" then
    hoveredStackSlot = nil
    hoveredWindowIds = { [id] = true }
    render()
  elseif hoveredWindowIds[id] then
    hoveredWindowIds = {}
    render()
  end
end

function onScroll(_axis, steps, _startsGesture)
  local amount = tonumber(steps) or 0
  if amount == 0 then return end
  local moveRight = amount > 0
  if INVERT_SCROLL then moveRight = not moveRight end
  local action = moveRight and "focus-column-right" or "focus-column-left"
  noctalia.runAsync("niri msg action " .. action)
end

local function clickHandlerFor(windowId)
  local key = tostring(windowId)
  local slot = windowClickSlots[key]
  if slot == nil and nextWindowClickSlot <= MAX_WINDOW_CLICK_SLOTS then
    slot = nextWindowClickSlot
    nextWindowClickSlot = nextWindowClickSlot + 1
    windowClickSlots[key] = slot
  end
  if slot == nil then return nil end
  windowClickTargets[slot] = windowId
  return "onWindowClick" .. tostring(slot)
end

local function clickHandlerForStack(key, windows)
  local slot = stackClickSlots[key]
  if slot == nil and nextStackClickSlot <= MAX_STACK_CLICK_SLOTS then
    slot = nextStackClickSlot
    nextStackClickSlot = nextStackClickSlot + 1
    stackClickSlots[key] = slot
  end
  if slot == nil then return nil end
  local targets = {}
  for _, window in ipairs(windows) do targets[#targets + 1] = window.id end
  stackClickTargets[slot] = targets
  return "onStackClick" .. tostring(slot)
end

local function activeWorkspaceFor(outputName)
  for _, workspace in ipairs((snapshot and snapshot.workspaces) or {}) do
    if workspace.output == outputName and workspace.is_active == true then return workspace end
  end
  return nil
end

local function workspaceWindows(workspaceId)
  local tiled, floating = {}, {}
  for _, window in ipairs((snapshot and snapshot.windows) or {}) do
    if window.workspace_id == workspaceId then
      if window.is_floating == true or window.layout == nil
        or window.layout.pos_in_scrolling_layout == nil then
        floating[#floating + 1] = window
      else
        tiled[#tiled + 1] = window
      end
    end
  end
  table.sort(tiled, function(a, b)
    local ap = a.layout.pos_in_scrolling_layout
    local bp = b.layout.pos_in_scrolling_layout
    if ap[1] ~= bp[1] then return ap[1] < bp[1] end
    return ap[2] < bp[2]
  end)
  table.sort(floating, function(a, b) return number(a.id, 0) < number(b.id, 0) end)
  return tiled, floating
end

local function iconPathFor(appId)
  if not SHOW_ICONS or appId == nil or appId == "" then return nil end
  if iconCache[appId] == nil then iconCache[appId] = noctalia.appIconPath(appId, 24) or false end
  local path = iconCache[appId]
  if path == false then return nil end
  return path
end

local function iconFor(appId, size, onClick, onHover, key)
  if size < 8 then return nil end
  local path = iconPathFor(appId)
  if path == nil then return nil end
  return ui.image({ key = key, path = path, width = size, height = size, fit = "contain", onClick = onClick, onHover = onHover })
end

local function windowNode(window, width, height, floating, clickable, borderOverride, isActive)
  local focused = HIGHLIGHT_FOCUSED and window.is_focused == true
  local hovered = HIGHLIGHT_HOVERED and hoveredWindowIds[window.id] == true
  local hoverActive = hovered and not focused and window.is_urgent ~= true
  local fill = focused and colorWithAlpha(FOCUSED_COLOR, "0.32", "52")
    or (floating and colorWithAlpha(FLOATING_COLOR, "0.22", "38") or "surface_variant")
  local border = focused and FOCUSED_COLOR
    or (window.is_urgent and URGENT_COLOR
    or (hovered and HOVER_COLOR
    or (isActive and ACTIVE_COLOR
    or (floating and FLOATING_COLOR
    or (borderOverride or NORMAL_COLOR)))))
  local iconSize = math.floor(math.min(width - 2, height - 2, 14))
  local children = {}
  local click = nil
  if clickable ~= false then click = clickHandlerFor(window.id) end
  local hover = HIGHLIGHT_HOVERED and clickable ~= false and "onWindowHover" or nil
  local icon = iconFor(window.app_id, iconSize, click, hover, "window-icon-" .. tostring(window.id))
  local props = {
    key = "window-" .. tostring(window.id) .. (clickable == false and "-stacked" or "-direct"),
    width = math.max(1, width),
    height = math.max(1, height),
    fill = fill,
    border = border,
    borderWidth = hoverActive and 2 or (borderOverride and VIEWPORT_BORDER_WIDTH or 1),
    radius = math.min(3, math.max(0, math.min(width, height) / 4)),
    align = "center",
    justify = "center",
    onClick = click,
    onHover = hover,
  }
  if icon == nil then
    -- Flex containers are not reliable independent hit targets when several
    -- tiny siblings share one column. A leaf box keeps each stacked window's
    -- click region separate even when there is no room for an icon.
    props.align = nil
    props.justify = nil
    return ui.box(props)
  end
  children[1] = icon
  return ui.column(props, children)
end

local function xmlEscape(value)
  return tostring(value):gsub("&", "&amp;"):gsub('"', "&quot;"):gsub("<", "&lt;"):gsub(">", "&gt;")
end

local THEME_COLOR_KEYS = {
  primary = "mPrimary",
  on_primary = "mOnPrimary",
  secondary = "mSecondary",
  on_secondary = "mOnSecondary",
  tertiary = "mTertiary",
  on_tertiary = "mOnTertiary",
  error = "mError",
  on_error = "mOnError",
  surface = "mSurface",
  on_surface = "mOnSurface",
  surface_variant = "mSurfaceVariant",
  on_surface_variant = "mOnSurfaceVariant",
  outline = "mOutline",
  shadow = "mShadow",
  hover = "mHover",
  on_hover = "mOnHover",
}

local function loadThemeColors()
  if themeColors ~= nil then return themeColors end
  themeColors = {}
  local configHome = noctalia.getenv("XDG_CONFIG_HOME")
  if configHome == nil or configHome == "" then
    configHome = (noctalia.getenv("HOME") or "") .. "/.config"
  end
  local contents = noctalia.readFile(configHome .. "/noctalia/config.toml")
  if contents ~= nil then
    for role, key in pairs(THEME_COLOR_KEYS) do
      local color = contents:match(key .. '%s*=%s*"(#[%x]+)"')
      if color ~= nil then themeColors[role] = color end
    end
  end
  return themeColors
end

local function svgColor(value)
  local color = tostring(value or "")
  if color:match("^#%x%x%x%x%x%x$") or color:match("^#%x%x%x%x%x%x%x%x$") then return color end
  local resolved = loadThemeColors()[color]
  if type(resolved) == "string" then return resolved end
  return "#ffb74d"
end

local function safeName(value)
  return tostring(value or "output"):gsub("[^%w_.-]", "_")
end

local function contentHash(value)
  local hash = 5381
  for index = 1, #value do
    hash = (hash * 33 + string.byte(value, index)) % 2147483647
  end
  return tostring(hash)
end

local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64Encode(data)
  local result = {}
  for index = 1, #data, 3 do
    local first = string.byte(data, index) or 0
    local second = string.byte(data, index + 1)
    local third = string.byte(data, index + 2)
    local combined = first * 65536 + (second or 0) * 256 + (third or 0)
    local a = math.floor(combined / 262144) % 64
    local b = math.floor(combined / 4096) % 64
    local c = math.floor(combined / 64) % 64
    local d = combined % 64
    result[#result + 1] = BASE64_ALPHABET:sub(a + 1, a + 1)
    result[#result + 1] = BASE64_ALPHABET:sub(b + 1, b + 1)
    result[#result + 1] = second and BASE64_ALPHABET:sub(c + 1, c + 1) or "="
    result[#result + 1] = third and BASE64_ALPHABET:sub(d + 1, d + 1) or "="
  end
  return table.concat(result)
end

local function iconDataUri(path)
  if iconDataCache[path] ~= nil then
    local cached = iconDataCache[path]
    return cached == false and nil or cached
  end
  local contents = noctalia.readFile(path)
  if contents == nil then
    iconDataCache[path] = false
    return nil
  end
  local lower = tostring(path):lower()
  local mime = "image/png"
  if lower:match("%.svg$") then mime = "image/svg+xml"
  elseif lower:match("%.webp$") then mime = "image/webp"
  elseif lower:match("%.jpe?g$") then mime = "image/jpeg" end
  local uri = "data:" .. mime .. ";base64," .. base64Encode(contents)
  iconDataCache[path] = uri
  return uri
end

local function embeddedIcon(path, x, y, size)
  local lower = tostring(path):lower()
  if lower:match("%.svg$") then
    local contents = noctalia.readFile(path)
    if contents ~= nil then
      local attributes, body = contents:match("<svg%s*([^>]*)>(.*)</svg>%s*$")
      if body ~= nil then
        local viewBox = attributes:match('viewBox%s*=%s*"([^"]+)"')
          or attributes:match("viewBox%s*=%s*'([^']+)'")
          or "0 0 24 24"
        local namespaces = {}
        for declaration in attributes:gmatch('xmlns:[%w_%-]+%s*=%s*"[^"]+"') do
          namespaces[#namespaces + 1] = declaration
        end
        for declaration in attributes:gmatch("xmlns:[%w_%-]+%s*=%s*'[^']+'") do
          namespaces[#namespaces + 1] = declaration
        end
        return string.format(
          '<svg x="%s" y="%s" width="%s" height="%s" viewBox="%s" preserveAspectRatio="xMidYMid meet" %s>%s</svg>',
          x, y, size, size, xmlEscape(viewBox), table.concat(namespaces, " "), body
        )
      end
    end
  end
  local uri = iconDataUri(path)
  if uri == nil then return nil end
  return string.format(
    '<image href="%s" x="%s" y="%s" width="%s" height="%s" preserveAspectRatio="xMidYMid meet"/>',
    xmlEscape(uri), x, y, size, size
  )
end

local function exactFloatingNode(output, windows, width, height, activeWindowId)
  local outputWidth = math.max(1, number(output.width, 1))
  local outputHeight = math.max(1, number(output.height, 1))
  local color = svgColor(FLOATING_COLOR)
  local parts = {
    string.format('<svg xmlns="http://www.w3.org/2000/svg" width="%s" height="%s" viewBox="0 0 %s %s">', width, height, outputWidth, outputHeight),
    string.format('<rect x="1" y="1" width="%s" height="%s" rx="24" fill="#00000018" stroke="%s" stroke-width="24"/>', math.max(1, outputWidth - 2), math.max(1, outputHeight - 2), color),
  }
  local fallback = {}
  local focusableIds = {}
  for _, window in ipairs(windows) do
    local layout = window.layout
    local pos = layout and layout.tile_pos_in_workspace_view
    local size = layout and layout.tile_size
    if pos ~= nil and size ~= nil then
      focusableIds[#focusableIds + 1] = window.id
      local x = number(pos[1], 0)
      local y = number(pos[2], 0)
      local windowWidth = math.max(1, number(size[1], 1))
      local windowHeight = math.max(1, number(size[2], 1))
      local focused = HIGHLIGHT_FOCUSED and window.is_focused == true
      local windowColor = focused and FOCUSED_COLOR
        or (window.is_urgent and URGENT_COLOR
        or (window.id == activeWindowId and ACTIVE_COLOR or FLOATING_COLOR))
      windowColor = svgColor(windowColor)
      local opacity = focused and "0.72" or "0.42"
      local strokeWidth = focused and "34" or "22"
      parts[#parts + 1] = string.format(
        '<rect x="%s" y="%s" width="%s" height="%s" rx="36" fill="%s" fill-opacity="%s" stroke="%s" stroke-width="%s"/>',
        x, y, windowWidth, windowHeight, windowColor, opacity, windowColor, strokeWidth
      )
      local iconPath = iconPathFor(window.app_id)
      local iconSize = math.min(windowWidth * 0.45, windowHeight * 0.45, outputHeight * 14 / math.max(1, height))
      local minimumIconSize = outputHeight * 6 / math.max(1, height)
      if iconPath ~= nil and iconSize >= minimumIconSize then
        local markup = embeddedIcon(
          iconPath,
          x + (windowWidth - iconSize) / 2,
          y + (windowHeight - iconSize) / 2,
          iconSize
        )
        if markup ~= nil then parts[#parts + 1] = markup end
      end
    else
      fallback[#fallback + 1] = window
    end
  end
  parts[#parts + 1] = "</svg>"
  local svg = table.concat(parts)
  local cacheKey = tostring(output.name) .. "\0" .. tostring(width) .. "\0" .. tostring(height) .. "\0" .. svg
  local path = exactCache[cacheKey]
  if path == nil then
    local runtimeDir = noctalia.getenv("XDG_RUNTIME_DIR") or "/tmp"
    local outputKey = tostring(output.name)
    path = runtimeDir .. "/noctalia-niri-workspace-preview-" .. safeName(output.name) .. "-" .. contentHash(svg) .. ".svg"
    if noctalia.writeFile(path, svg) then
      local history = generatedByOutput[outputKey] or {}
      if history[#history] ~= path then history[#history + 1] = path end
      generatedByOutput[outputKey] = history
      while #history > 32 do
        local expired = table.remove(history, 1)
        if expired ~= path then
          noctalia.removeFile(expired)
          generatedFiles[expired] = nil
        end
      end
      generatedFiles[path] = true
      exactCache = { [cacheKey] = path }
    else
      path = nil
    end
  end
  local node
  if path ~= nil then
    local outputKey = tostring(output.name)
    node = ui.image({
      key = "floating-exact-" .. tostring(output.name),
      path = path,
      width = width,
      height = height,
      fit = "contain",
      onClick = function()
        if #focusableIds == 0 then return end
        local cursor = (exactFocusCursor[outputKey] or 0) % #focusableIds + 1
        exactFocusCursor[outputKey] = cursor
        -- Later windows are normally newer and visually above earlier ones.
        focusWindow(focusableIds[#focusableIds - cursor + 1])
      end,
    })
  end
  return node, fallback
end

local function groupedColumns(windows)
  local columns, order = {}, {}
  for _, window in ipairs(windows) do
    local columnIndex = window.layout.pos_in_scrolling_layout[1]
    if columns[columnIndex] == nil then
      columns[columnIndex] = {}
      order[#order + 1] = columnIndex
    end
    columns[columnIndex][#columns[columnIndex] + 1] = window
  end
  table.sort(order)
  return columns, order
end

local function layoutExtent(windows)
  local columns, order = groupedColumns(windows)
  local rawWidth, rawHeight, maxRows = 0, 1, 1
  for _, columnIndex in ipairs(order) do
    local columnWidth, columnHeight = 1, 0
    for _, window in ipairs(columns[columnIndex]) do
      columnWidth = math.max(columnWidth, number(window.layout.tile_size and window.layout.tile_size[1], 1))
      columnHeight = columnHeight + number(window.layout.tile_size and window.layout.tile_size[2], 1)
    end
    rawWidth = rawWidth + columnWidth
    rawHeight = math.max(rawHeight, columnHeight)
    maxRows = math.max(maxRows, #columns[columnIndex])
  end
  return columns, order, math.max(1, rawWidth), math.max(1, rawHeight), maxRows
end

local function visibleViewportWindows(windows, outputWidth, activeWindowId, stateKey)
  local columns, order = groupedColumns(windows)
  if #order == 0 then return {} end
  local focusedOrder = 1
  for orderIndex, columnIndex in ipairs(order) do
    for _, window in ipairs(columns[columnIndex]) do
      if window.id == activeWindowId or window.is_focused == true then
        focusedOrder = orderIndex
      end
    end
  end
  local widths = {}
  for _, columnIndex in ipairs(order) do
    local width = 1
    for _, window in ipairs(columns[columnIndex]) do
      width = math.max(width, number(window.layout.tile_size and window.layout.tile_size[1], 1))
    end
    widths[columnIndex] = width
  end
  local edgeTolerance = math.max(24, outputWidth * 0.02)

  local function rangeEnd(startOrder)
    local used = 0
    local last = startOrder
    while last <= #order and (used == 0 or outputWidth - used > edgeTolerance) do
      used = used + widths[order[last]]
      last = last + 1
    end
    return last - 1
  end

  local startOrder = focusedOrder
  local previousStartWindows = viewportStarts[stateKey]
  if type(previousStartWindows) == "table" then
    local previousIds = {}
    for _, id in ipairs(previousStartWindows) do previousIds[tonumber(id) or id] = true end
    for orderIndex, columnIndex in ipairs(order) do
      for _, window in ipairs(columns[columnIndex]) do
        if previousIds[window.id] then startOrder = orderIndex end
      end
    end
  end

  local endOrder = rangeEnd(startOrder)
  if focusedOrder < startOrder then
    -- Match Niri's minimal scrolling when focus crosses the left edge.
    startOrder = focusedOrder
  elseif focusedOrder > endOrder then
    -- Keep the focused column at the right side while retaining as many
    -- preceding columns as fit, rather than rebuilding from the left.
    startOrder = focusedOrder
    local used = widths[order[focusedOrder]]
    while startOrder > 1 and outputWidth - used > edgeTolerance do
      startOrder = startOrder - 1
      used = used + widths[order[startOrder]]
    end
  end

  local startWindows = {}
  for _, window in ipairs(columns[order[startOrder]]) do startWindows[#startWindows + 1] = window.id end
  local changed = type(previousStartWindows) ~= "table" or #previousStartWindows ~= #startWindows
  if not changed then
    for index, id in ipairs(startWindows) do
      if tonumber(previousStartWindows[index]) ~= tonumber(id) then changed = true end
    end
  end
  if changed then
    local persisted = noctalia.state.get(VIEWPORT_STATE_KEY)
    if type(persisted) ~= "table" then persisted = {} end
    persisted[stateKey] = startWindows
    viewportStarts = persisted
    noctalia.state.set(VIEWPORT_STATE_KEY, persisted)
  else
    viewportStarts[stateKey] = startWindows
  end
  endOrder = rangeEnd(startOrder)
  local result = {}
  for orderIndex, columnIndex in ipairs(order) do
    if orderIndex >= startOrder and orderIndex <= endOrder then
      for _, window in ipairs(columns[columnIndex]) do result[#result + 1] = window end
    end
  end
  return result
end

local function tiledNode(windows, width, height, scale, visibleIds, keyPrefix, activeWindowId)
  if #windows == 0 then
    return ui.column({ width = width, height = height, align = "center", justify = "center" }, {
      ui.glyph({ name = "layout-dashboard", size = math.max(6, math.min(width, height) - 4), color = "outline" }),
    })
  end
  local columns, order = groupedColumns(windows)
  local columnNodes = {}
  local totalWidth = 0
  for _, columnIndex in ipairs(order) do
    local column = columns[columnIndex]
    local rawWidth = 1
    for _, window in ipairs(column) do
      rawWidth = math.max(rawWidth, number(window.layout.tile_size and window.layout.tile_size[1], 1))
    end
    local columnWidth = math.max(1, rawWidth * scale)
    local nodes = {}
    for index, window in ipairs(column) do
      local rawHeight = number(window.layout.tile_size and window.layout.tile_size[2], 1)
      local viewportBorder = visibleIds and visibleIds[window.id] and VIEWPORT_COLOR or nil
      nodes[#nodes + 1] = windowNode(
        window,
        columnWidth,
        math.max(1, rawHeight * scale),
        false,
        #column == 1,
        viewportBorder,
        window.id == activeWindowId
      )
    end
    local stackClick = nil
    local stackHover = nil
    if #column > 1 then
      stackClick = clickHandlerForStack(keyPrefix .. ":" .. tostring(columnIndex), column)
      if HIGHLIGHT_HOVERED and stackClick ~= nil then
        stackHover = string.gsub(stackClick, "^onStackClick", "onStackHover")
      end
    end
    columnNodes[#columnNodes + 1] = ui.column({
      key = "column-" .. tostring(columnIndex),
      width = columnWidth,
      height = height,
      gap = WINDOW_GAP,
      justify = "center",
      onClick = stackClick,
      onHover = stackHover,
    }, nodes)
    totalWidth = totalWidth + columnWidth
  end
  totalWidth = math.min(width, totalWidth + WINDOW_GAP * math.max(0, #columnNodes - 1))
  return ui.row({ width = totalWidth, height = height, gap = WINDOW_GAP, justify = "center" }, columnNodes)
end

local function workspaceNode(output, width, height, viewportOnly)
  local workspace = activeWorkspaceFor(output.name)
  local innerWidth, innerHeight = math.max(1, width - 2), math.max(1, height - 2)
  local screenChildren = {}
  local floating = {}
  local visibleIds = nil
  if workspace == nil then
    screenChildren[1] = ui.glyph({ name = "plug-off", size = math.max(6, math.min(innerWidth, innerHeight) - 4), color = "outline" })
  else
    local tiled
    tiled, floating = workspaceWindows(workspace.id)
    local viewportStateKey = tostring(output.name) .. ":" .. tostring(workspace.id)
    if not viewportOnly and HIGHLIGHT_VIEWPORT then
      visibleIds = {}
      local visible = visibleViewportWindows(tiled, math.max(1, number(output.width, 1)), workspace.active_window_id, viewportStateKey)
      for _, window in ipairs(visible) do visibleIds[window.id] = true end
    end
    if viewportOnly then
      tiled = visibleViewportWindows(tiled, math.max(1, number(output.width, 1)), workspace.active_window_id, viewportStateKey)
      floating = {}
    end
    local _, order, rawWidth, rawHeight, maxRows = layoutExtent(tiled)
    local gapWidth = WINDOW_GAP * math.max(0, #order - 1)
    local gapHeight = WINDOW_GAP * math.max(0, maxRows - 1)
    local scale = math.min(
      math.max(1, innerWidth - gapWidth) / rawWidth,
      math.max(1, innerHeight - gapHeight) / rawHeight
    )
    local mapKey = viewportStateKey .. (viewportOnly and ":viewport" or ":full")
    screenChildren[1] = tiledNode(tiled, innerWidth, innerHeight, scale, visibleIds, mapKey, workspace.active_window_id)
  end
  local screen = ui.row({
    key = (viewportOnly and "viewport-" or "output-") .. tostring(output.name),
    width = width,
    height = height,
    padding = 1,
    fill = "surface/0.72",
    border = viewportOnly and VIEWPORT_COLOR or (output.focused and "primary" or "outline"),
    borderWidth = viewportOnly and VIEWPORT_BORDER_WIDTH or 1,
    radius = 3,
    align = "center",
    justify = "center",
  }, screenChildren)

  if not SHOW_FLOATING or #floating == 0 then return screen end
  local resultChildren = { screen }
  if FLOATING_MODE == "exact" then
    local aspect = math.max(0.1, number(output.width, 1) / math.max(1, number(output.height, 1)))
    local exactHeight = math.max(8, height)
    local exactWidth = exactHeight * aspect
    if barWidget.isVertical() then
      exactWidth = math.max(8, width)
      exactHeight = exactWidth / aspect
    end
    local exactNode, fallback = exactFloatingNode(output, floating, exactWidth, exactHeight, workspace and workspace.active_window_id)
    if exactNode ~= nil then resultChildren[#resultChildren + 1] = exactNode end
    floating = fallback
    if #floating == 0 then
      return ui.row({ gap = WINDOW_GAP, align = "center" }, resultChildren)
    end
  end
  local floatingNodes = {}
  for _, window in ipairs(floating) do
    local rawWidth = number(window.layout and window.layout.tile_size and window.layout.tile_size[1], 1)
    local rawHeight = number(window.layout and window.layout.tile_size and window.layout.tile_size[2], 1)
    local scale = math.min(14 / rawWidth, height / rawHeight)
    floatingNodes[#floatingNodes + 1] = windowNode(
      window,
      rawWidth * scale,
      rawHeight * scale,
      true,
      true,
      nil,
      workspace ~= nil and window.id == workspace.active_window_id
    )
  end
  resultChildren[#resultChildren + 1] = ui.column({ gap = WINDOW_GAP, align = "center" }, floatingNodes)
  return ui.row({ gap = WINDOW_GAP, align = "center" }, resultChildren)
end

local function dimensionsFor(output, vertical)
  if SIZE_MODE == "fixed" then
    return FIXED_WIDTH, FIXED_HEIGHT
  end
  local workspace = activeWorkspaceFor(output.name)
  if workspace == nil then
    if vertical then return PREVIEW_SIZE, PREVIEW_SIZE * 9 / 16 end
    return PREVIEW_SIZE * 16 / 9, PREVIEW_SIZE
  end
  local tiled = workspaceWindows(workspace.id)
  if #tiled == 0 then
    if vertical then return PREVIEW_SIZE, PREVIEW_SIZE * 9 / 16 end
    return PREVIEW_SIZE * 16 / 9, PREVIEW_SIZE
  end
  local _, order, rawWidth, rawHeight, maxRows = layoutExtent(tiled)
  local gapWidth = WINDOW_GAP * math.max(0, #order - 1)
  local gapHeight = WINDOW_GAP * math.max(0, maxRows - 1)
  local maxInnerWidth = (vertical and PREVIEW_SIZE or MAX_OUTPUT_LENGTH) - 2
  local maxInnerHeight = (vertical and MAX_OUTPUT_LENGTH or PREVIEW_SIZE) - 2
  local scale = math.min(
    math.max(1, maxInnerWidth - gapWidth) / rawWidth,
    math.max(1, maxInnerHeight - gapHeight) / rawHeight
  )
  return rawWidth * scale + gapWidth + 2, rawHeight * scale + gapHeight + 2
end

local function viewportDimensions(output, vertical)
  local aspect = math.max(0.1, number(output.width, 1) / math.max(1, number(output.height, 1)))
  if SIZE_MODE == "fixed" then return FIXED_WIDTH, FIXED_HEIGHT end
  if vertical then return PREVIEW_SIZE, math.max(8, PREVIEW_SIZE / aspect) end
  return math.max(8, PREVIEW_SIZE * aspect), PREVIEW_SIZE
end

local function updateTooltip(outputs)
  if snapshot == nil then
    barWidget.setTooltip("Niri workspace preview: waiting for state")
    return
  end
  local rows = {}
  for _, output in ipairs(outputs or {}) do
    local workspace = activeWorkspaceFor(output.name)
    local count = 0
    if workspace ~= nil then
      for _, window in ipairs(snapshot.windows or {}) do
        if window.workspace_id == workspace.id then count = count + 1 end
      end
    end
    rows[#rows + 1] = {
      key = tostring(output.name),
      value = workspace and (tostring(workspace.name or workspace.idx) .. " · " .. tostring(count) .. " windows") or "no active workspace",
    }
  end
  if #rows == 0 then
    local message = snapshot.message ~= "" and snapshot.message or "No outputs match this widget's output scope"
    barWidget.setTooltip(message)
  else
    barWidget.setTooltip(rows)
  end
end

render = function()
  local vertical = barWidget.isVertical()
  local container = vertical and ui.column or ui.row
  local outputs = selectedOutputs()
  local children = {}
  for _, output in ipairs(outputs) do
    local width, height = dimensionsFor(output, vertical)
    children[#children + 1] = workspaceNode(output, width, height, false)
    if SHOW_VIEWPORT_MAP then
      local viewportWidth, viewportHeight = viewportDimensions(output, vertical)
      children[#children + 1] = workspaceNode(output, viewportWidth, viewportHeight, true)
    end
  end
  if #children == 0 then
    children[1] = ui.glyph({ name = snapshot and "alert-circle" or "loader", size = math.min(PREVIEW_SIZE, 16), color = "outline" })
  end
  barWidget.render(container({ gap = OUTPUT_GAP, align = "center", justify = "center" }, children))
  updateTooltip(outputs)
end

noctalia.setUpdateInterval(RENDER_TICK_MS)

noctalia.state.watch(STATE_KEY, function(value)
  snapshot = value
  -- Niri emits layout updates at pointer frequency while moving/resizing a
  -- floating window. Keep the last valid tree visible and render only the
  -- newest snapshot after the burst settles; replacing SVG paths on every
  -- event makes the host briefly display an unloaded image.
  renderDueAt = noctalia.nowMs() + EVENT_SETTLE_MS
end)

render()

function update()
  if renderDueAt ~= nil and noctalia.nowMs() >= renderDueAt then
    renderDueAt = nil
    render()
  end
end

function onClick()
  noctalia.runAsync("niri msg action toggle-overview")
end

function onIpc(event)
  if event == "refresh" then
    renderDueAt = nil
    render()
  end
end

function onExit()
  for path, _ in pairs(generatedFiles) do noctalia.removeFile(path) end
end
