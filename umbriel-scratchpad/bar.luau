--!nonstrict
-- Scratchpad bar widget - one pill per scratchpad, drawn like a native taskbar
-- workspace group: a round name badge followed by the scratchpad's windows.
--
-- Badge click toggles the scratchpad; icon click reveals and focuses that window,
-- or hides the scratchpad again when the window is already focused. A collapsed
-- app icon cycles through that app's windows.
--
-- The plugin UI has no overlay, so everything the native taskbar draws on top of
-- something else (the active dot, the count badge) is pulled into place with a
-- negative flex gap. The corner label sits flush in the pill's top-left corner
-- instead of straddling the border.

local BADGE_SIZE = 13
local MIN_PILL_HEIGHT = 20
local DOT_SIZE = 5
local COUNT_BADGE_SIZE = 9
local CONTENT_DOT_SIZE = 5
local MAX_CONTENT_DOTS = 5
-- Icons are drawn without mipmapping, so a much larger source (a 256 px icon
-- shrunk to 16 px) comes out fuzzy. Look icons up at the size actually drawn:
-- icon_size times the output's scale.
local MIN_ICON_LOOKUP_SIZE = 16

local snapshot = { available = false, windows = {} }
local iconCache = {}
-- appIconPath searches the icon theme and is slow; resolving every icon in one
-- render can exceed the script CPU budget right after startup. Resolve at most
-- this many new icons per render; the rest show a placeholder until a later
-- update() tick fills them in.
local MAX_ICON_LOOKUPS_PER_RENDER = 1
local lookupsLeft = MAX_ICON_LOOKUPS_PER_RENDER
-- Set when a render left icons unresolved; update() renders again to fill them.
local iconsPending = false
-- Output, orientation and scale the last render used; update() re-renders only
-- when one of them changes.
local lastHost = nil
local requestSeq = 0

-- `action` is Umbriel's typed request, e.g. { action = "scratchpad-toggle", scratchpad = "M" }.
local function request(action)
  -- The sequence number makes repeated identical requests still count as a change.
  requestSeq += 1
  noctalia.state.set("scratchpad.request", { request = action, seq = `{os.clock()}:{requestSeq}` })
end

local function toggle(name)
  request({ action = "scratchpad-toggle", scratchpad = name })
end

local function outputScale()
  local name = barWidget.outputName()
  for _, output in ipairs(noctalia.outputs() or {}) do
    if output.name == name and tonumber(output.scale) then
      return tonumber(output.scale)
    end
  end
  return 1
end

local function appIcon(appId, px)
  local key = `{appId}@{px}`
  local cached = iconCache[key]
  if cached == nil then
    if lookupsLeft <= 0 then
      iconsPending = true
      return nil
    end
    lookupsLeft -= 1
    cached = noctalia.appIconPath(appId, px)
      or noctalia.appIconPath(string.lower(appId), px)
      or false
    iconCache[key] = cached
  end
  return cached or nil
end

-- Opacity settings were integer percents before 0.3.0; accept either form.
local function opacitySetting(key, fallback)
  local value = tonumber(noctalia.getConfig(key)) or fallback
  if value > 1 then
    value /= 100
  end
  return math.clamp(value, 0, 1)
end

local function listSetting(key)
  local value = noctalia.getConfig(key)
  local list = {}
  if type(value) == "table" then
    for _, item in ipairs(value) do
      local name = noctalia.string.trim(tostring(item))
      if name ~= "" then
        table.insert(list, name)
      end
    end
  end
  return list
end

local function readSettings(scale)
  local iconSize = math.floor((tonumber(noctalia.getConfig("icon_size")) or 16) + 0.5)
  local function enabled(key)
    return noctalia.getConfig(key) ~= false
  end
  local function on(key)
    return noctalia.getConfig(key) == true
  end
  return {
    -- Windows
    showAllMonitors = enabled("show_all_monitors"),
    indicator = enabled("active_indicator"),
    indicatorColor = noctalia.getConfig("indicator_color") or "primary",
    activeOpacity = opacitySetting("active_opacity", 1),
    unfocusedOpacity = enabled("dim_unfocused") and opacitySetting("unfocused_opacity", 0.5) or nil,
    hiddenOpacity = opacitySetting("hidden_opacity", 0.5),
    iconSize = iconSize,
    iconLookupSize = math.max(MIN_ICON_LOOKUP_SIZE, math.ceil(iconSize * scale)),
    pillHeight = math.max(MIN_PILL_HEIGHT, iconSize + 4),
    -- Grouping
    onlyShown = on("only_shown"),
    grouped = enabled("group_by_scratchpad"),
    hideEmpty = enabled("hide_empty"),
    known = listSetting("known_scratchpads"),
    hiddenNames = listSetting("hidden_scratchpads"),
    content = noctalia.getConfig("group_content") or "icons",
    singleIconPerApp = on("single_icon_per_app"),
    capsule = enabled("group_capsule"),
    -- Labels
    showLabel = enabled("show_label"),
    placement = noctalia.getConfig("label_placement") or "corner",
    minimal = on("minimal_style"),
    focusedMonitorOnly = on("highlight_focused_monitor_only"),
    shownColor = noctalia.getConfig("shown_color") or "primary",
    hiddenColor = noctalia.getConfig("hidden_color") or "secondary",
    emptyColor = noctalia.getConfig("empty_color") or "secondary",
    urgentColor = noctalia.getConfig("urgent_color") or "error",
    urgentOutline = on("urgent_outline"),
  }
end

-- Text color for a badge fill: the matching on_* role, or the surface color for
-- custom hex or alpha-suffixed fills.
local function onColor(fill)
  if string.find(fill, "^[%a_]+$") and not string.find(fill, "^on_") then
    return `on_{fill}`
  end
  return "surface"
end

local function contains(list, value)
  for _, item in ipairs(list) do
    if item == value then
      return true
    end
  end
  return false
end

-- Scratchpads to draw, known names first in their configured order, then the rest
-- by name. Each group carries the state its label and capsule are colored by.
local function groups(cfg)
  local output = barWidget.outputName()

  local byName = {}
  local names = {}
  local function ensure(name)
    if byName[name] == nil then
      byName[name] = {}
      table.insert(names, name)
    end
  end

  for _, window in ipairs(snapshot.windows or {}) do
    if cfg.showAllMonitors or output == nil or window.output == output then
      ensure(window.scratchpad)
      table.insert(byName[window.scratchpad], window)
    end
  end

  local rank = {}
  for i, name in ipairs(cfg.known) do
    rank[name] = i
    if cfg.grouped and not cfg.hideEmpty then
      ensure(name)
    end
  end
  table.sort(names, function(a, b)
    local ra, rb = rank[a], rank[b]
    if ra ~= nil and rb ~= nil then
      return ra < rb
    end
    if ra ~= nil or rb ~= nil then
      return ra ~= nil
    end
    return a < b
  end)

  local list = {}
  for _, name in ipairs(names) do
    local windows = byName[name]
    local shown, shownHere, hasFocus, urgent = false, false, false, false
    for _, window in ipairs(windows) do
      if window.visible == true then
        shown = true
        if snapshot.focused_output == nil or window.output == snapshot.focused_output then
          shownHere = true
        end
      end
      if window.active == true then
        hasFocus = true
      end
      if window.urgent == true then
        urgent = true
      end
    end

    local include = true
    if contains(cfg.hiddenNames, name) and not shown then
      include = false
    end
    if cfg.onlyShown and not shown then
      include = false
    end
    if include then
      local highlighted = shown and (shownHere or not cfg.focusedMonitorOnly)
      local color
      if urgent then
        color = cfg.urgentColor
      elseif highlighted then
        color = cfg.shownColor
      elseif #windows == 0 then
        color = cfg.emptyColor
      else
        color = cfg.hiddenColor
      end
      table.insert(list, {
        name = name,
        windows = windows,
        shown = shown,
        highlighted = highlighted,
        hasFocus = hasFocus,
        color = color,
      })
    end
  end
  return list
end

-- One icon slot per window, or per app when collapsing. A slot's state is the union
-- of its windows' states; its representative is the focused window if any.
local function entries(group, cfg)
  local list = {}
  if not cfg.singleIconPerApp then
    for _, window in ipairs(group.windows) do
      table.insert(list, { window = window, windows = { window }, visible = window.visible == true, active = window.active == true, urgent = window.urgent == true })
    end
    return list
  end

  local byApp = {}
  for _, window in ipairs(group.windows) do
    local appId = window.app_id or ""
    local entry = byApp[appId]
    if entry == nil then
      entry = { window = window, windows = {}, visible = false, active = false, urgent = false }
      byApp[appId] = entry
      table.insert(list, entry)
    end
    table.insert(entry.windows, window)
    entry.visible = entry.visible or window.visible == true
    entry.urgent = entry.urgent or window.urgent == true
    if window.active == true then
      entry.active = true
      entry.window = window
    end
  end
  return list
end

local function entryOpacity(group, entry, cfg)
  if not entry.visible then
    return cfg.hiddenOpacity
  end
  if entry.active then
    return cfg.activeOpacity
  end
  if cfg.unfocusedOpacity ~= nil and group.hasFocus then
    return cfg.unfocusedOpacity
  end
  return 1
end

-- Focused single window: hide the scratchpad. Otherwise focus the window after the
-- focused one among the slot's windows, or its first window.
local function entryClick(group, entry)
  local windows = entry.windows
  if entry.active and #windows == 1 then
    toggle(group.name)
    return
  end
  local target = windows[1]
  for i, window in ipairs(windows) do
    if window.active == true then
      target = windows[(i % #windows) + 1]
      break
    end
  end
  request({ action = "window-focus", window = target.id })
end

local function entryTooltip(group, entry)
  local scratchpad = noctalia.tr("tooltip.scratchpad", { name = group.name })
  if #entry.windows == 1 then
    local window = entry.window
    return `{window.title}\n{window.app_id} · {scratchpad}`
  end
  local lines = {}
  for _, window in ipairs(entry.windows) do
    table.insert(lines, window.title)
  end
  table.insert(lines, `{entry.window.app_id} · {noctalia.tr("tooltip.windows", { count = #entry.windows })} · {scratchpad}`)
  return table.concat(lines, "\n")
end

local function iconNode(group, entry, cfg)
  -- The click target is the icon itself: a clickable row wrapper draws its own
  -- background tile, which the native taskbar does not have.
  local props = {
    key = `icon:{entry.window.id}`,
    width = cfg.iconSize,
    height = cfg.iconSize,
    opacity = entryOpacity(group, entry, cfg),
    tooltip = entryTooltip(group, entry),
    onClick = function()
      entryClick(group, entry)
    end,
  }
  if entry.urgent and cfg.urgentOutline then
    props.border = cfg.urgentColor
    props.borderWidth = 1
  end

  local path = appIcon(entry.window.app_id or "", cfg.iconLookupSize)
  if path ~= nil then
    props.path = path
    props.fit = "contain"
    return ui.image(props)
  end
  -- Glyphs take no click handler, so a missing icon is wrapped in a row (no fill).
  props.radius = cfg.iconSize / 2
  return ui.row(props, { ui.glyph({ name = "app-window", size = cfg.iconSize }) })
end

local function countBadge(count)
  return ui.row({
    height = COUNT_BADGE_SIZE,
    minWidth = COUNT_BADGE_SIZE,
    paddingH = 2,
    radius = COUNT_BADGE_SIZE / 2,
    fill = "surface_container",
    align = "center",
    justify = "center",
  }, {
    ui.label({ text = tostring(count), fontSize = 7, fontWeight = "bold", color = "on_surface", maxLines = 1 }),
  })
end

-- The icon, with the count badge over its top-right corner when collapsed and the
-- active dot centered over its bottom edge. Negative gaps keep the slot exactly
-- icon-sized, so icons do not shift when focus moves.
local function entryNode(group, entry, cfg)
  local node = iconNode(group, entry, cfg)
  if #entry.windows > 1 then
    node = ui.row({ gap = -COUNT_BADGE_SIZE, align = "start" }, { node, countBadge(#entry.windows) })
  end
  if not cfg.indicator then
    return node
  end
  local dot
  if entry.active then
    dot = ui.box({ width = DOT_SIZE, height = DOT_SIZE, radius = DOT_SIZE / 2, fill = cfg.indicatorColor })
  else
    dot = ui.spacer({ width = DOT_SIZE, height = DOT_SIZE })
  end
  return ui.column({ key = `entry:{entry.window.id}`, gap = -DOT_SIZE, align = "center" }, { node, dot })
end

local function badge(group, cfg)
  local props = {
    key = `badge:{group.name}`,
    align = "center",
    justify = "center",
    tooltip = noctalia.tr("tooltip.toggle", { name = group.name }),
    onClick = function()
      toggle(group.name)
    end,
  }
  if cfg.minimal then
    props.minWidth = BADGE_SIZE
    props.height = BADGE_SIZE
    return ui.row(props, {
      ui.label({ text = group.name, fontSize = 10, fontWeight = "bold", maxLines = 1, color = group.color }),
    })
  end
  props.width = BADGE_SIZE
  props.height = BADGE_SIZE
  props.radius = BADGE_SIZE / 2
  props.fill = group.color
  return ui.row(props, {
    ui.label({ text = group.name, fontSize = 9, fontWeight = "medium", maxLines = 1, color = onColor(group.color) }),
  })
end

-- Corner pins the badge to the pill's start corner (top on a horizontal bar);
-- edge and inside leave it centered on the cross axis.
local function placedBadge(group, vertical, cfg)
  if cfg.placement ~= "corner" then
    return badge(group, cfg)
  end
  if vertical then
    return ui.row({ width = cfg.pillHeight, justify = "start", align = "start" }, { badge(group, cfg) })
  end
  return ui.column({ height = cfg.pillHeight, justify = "start", align = "start" }, { badge(group, cfg) })
end

local function contentDots(group, cfg)
  local children = {}
  for i, window in ipairs(group.windows) do
    if i > MAX_CONTENT_DOTS then
      break
    end
    local fill = "on_surface_variant/0.5"
    if window.active == true then
      fill = cfg.indicatorColor
    elseif window.visible == true then
      fill = "on_surface"
    end
    table.insert(children, ui.box({ width = CONTENT_DOT_SIZE, height = CONTENT_DOT_SIZE, radius = CONTENT_DOT_SIZE / 2, fill = fill }))
  end
  if #group.windows > MAX_CONTENT_DOTS then
    table.insert(children, ui.label({ text = `+{#group.windows - MAX_CONTENT_DOTS}`, fontSize = 9, color = "on_surface_variant" }))
  end
  return children
end

-- Count and dots modes: one clickable cluster that toggles the scratchpad.
local function summaryNode(group, cfg)
  local children
  if cfg.content == "count" then
    children = { ui.label({ text = tostring(#group.windows), fontSize = 11, fontWeight = "bold", color = group.shown and "on_surface" or "on_surface_variant" }) }
  else
    children = contentDots(group, cfg)
  end
  return ui.row({
    key = `summary:{group.name}`,
    gap = 3,
    align = "center",
    height = cfg.iconSize,
    tooltip = noctalia.tr("tooltip.toggle", { name = group.name }),
    onClick = function()
      toggle(group.name)
    end,
  }, children)
end

local function pill(group, vertical, cfg)
  local children = {}
  local label = cfg.showLabel
  if label then
    if cfg.placement == "inside" then
      table.insert(children, ui.spacer({ width = 3, height = 3 }))
    end
    table.insert(children, placedBadge(group, vertical, cfg))
  else
    table.insert(children, ui.spacer({ width = 3, height = 3 }))
  end

  if #group.windows > 0 then
    if cfg.content == "icons" then
      for _, entry in ipairs(entries(group, cfg)) do
        table.insert(children, entryNode(group, entry, cfg))
      end
    else
      table.insert(children, summaryNode(group, cfg))
    end
  end
  -- Trailing room; the leading side has none so a corner or edge badge touches
  -- the border.
  table.insert(children, ui.spacer({ width = 2, height = 2 }))

  local props = {
    key = `scratchpad:{group.name}`,
    gap = 4,
    align = "center",
    width = vertical and cfg.pillHeight or nil,
    height = if vertical then nil else cfg.pillHeight,
    radius = cfg.pillHeight / 2,
  }
  if cfg.capsule then
    props.border = group.highlighted and cfg.shownColor or "outline_variant"
    props.borderWidth = 1
  end
  if vertical then
    return ui.column(props, children)
  end
  return ui.row(props, children)
end

-- Ungrouped: every scratchpad window in one flat run of icons, no labels.
local function flatItems(list, cfg)
  local items = {}
  for _, group in ipairs(list) do
    for _, entry in ipairs(entries(group, cfg)) do
      table.insert(items, entryNode(group, entry, cfg))
    end
  end
  return items
end

local function hostKey(scale)
  return `{barWidget.outputName() or ""}|{barWidget.isVertical()}|{scale}`
end

local function render()
  lookupsLeft = MAX_ICON_LOOKUPS_PER_RENDER
  iconsPending = false
  local scale = outputScale()
  lastHost = hostKey(scale)
  if snapshot.available ~= true then
    barWidget.setVisible(false)
    return
  end

  local cfg = readSettings(scale)
  local list = groups(cfg)
  local vertical = barWidget.isVertical()

  local items
  if cfg.grouped then
    items = {}
    for _, group in ipairs(list) do
      table.insert(items, pill(group, vertical, cfg))
    end
  else
    items = flatItems(list, cfg)
  end

  if #items == 0 then
    if noctalia.getConfig("hide_when_empty") ~= false then
      barWidget.setVisible(false)
      return
    end
    barWidget.setVisible(true)
    barWidget.setTooltip(snapshot.error or noctalia.tr("tooltip.empty"))
    barWidget.render(ui.glyph({ name = "box-multiple", color = "on_surface_variant" }))
    return
  end

  barWidget.setVisible(true)
  barWidget.clearTooltip()
  local gap = cfg.grouped and 4 or 6
  if vertical then
    barWidget.render(ui.column({ gap = gap, align = "center" }, items))
  else
    barWidget.render(ui.row({ gap = gap, align = "center" }, items))
  end
end

-- Snapshots and settings changes render straight away; the tick only finishes
-- icons a render had to defer and follows output, orientation or scale changes.
function update()
  if iconsPending or hostKey(outputScale()) ~= lastHost then
    render()
  end
end

function onConfigChanged()
  render()
end

noctalia.state.watch("scratchpad.state", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

snapshot = noctalia.state.get("scratchpad.state") or snapshot
render()
