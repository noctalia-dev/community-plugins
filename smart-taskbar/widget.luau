--!nonstrict
local Model = require("./lib/model.luau")
local Compositor = require("./lib/compositor.luau")
local Transport = require("./lib/transport.luau")
local transport = Transport.new(noctalia)
local state = Model.new()
local backend = Compositor.new(transport.name)
local config, groups, ranks, icons, cursors = {}, {}, nil, {}, {}
local expanded, hovered, hoveredKey = false, false, nil
local deadline, pendingExpand, transitionStart = nil, false, nil
local offset, lastFocus, subscription = 0, nil, nil
local initialized, dirty = false, true
local subscriptionGeneration = 0
local scheduledInterval,reportedProblem = nil,nil
local cachedLayout, layoutConfig, layoutGroups, layoutOffset, layoutVertical
local render, refresh, subscribe, handleHover
local zoomFrom, zoomStart = {}, nil

local function sameValue(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for key, value in pairs(a) do if not sameValue(value, b[key]) then return false end end
  for key in pairs(b) do if a[key] == nil then return false end end
  return true
end
local function readConfig()
  -- All keys are manifest declared. The host validates types; clamp cross-field constraints here.
  local keys = { "expand_mode", "hover_delay", "collapse_delay", "animation_duration", "animations",
    "min_width", "max_width", "collapsed_width", "icon_size", "icon_spacing", "overflow_behavior",
    "scroll_step", "auto_reveal_focused", "show_scroll_indicators", "display_mode", "workspace_filter",
    "output_filter", "show_minimized", "grouping", "duplicate_indicator", "sorting", "exclusions",
    "pinned_apps", "app_aliases", "collapsed_label", "capsule_radius", "hover_enlarge", "hover_scale",
    "opacity", "border", "active_indicator", "minimized_indicator", "urgent_indicator", "badge_placement", "badge_style", "inline_count_style",
    "click_behavior", "middle_click", "refresh_fallback", "diagnostic_logging", "compositor_compatibility" }
  local nextConfig = {}
  for _, key in ipairs(keys) do nextConfig[key] = noctalia.getConfig(key) end
  nextConfig.min_width = math.min(nextConfig.min_width, nextConfig.max_width)
  nextConfig.collapsed_width = math.min(nextConfig.collapsed_width, nextConfig.max_width)
  local changed = not sameValue(config, nextConfig)
  config = nextConfig
  return changed
end
local function getLayout()
  local vertical=barWidget.isVertical()
  if not cachedLayout or layoutConfig~=config or layoutGroups~=groups or layoutOffset~=offset or layoutVertical~=vertical then
    cachedLayout=Model.layout(config,#groups,groups,offset,vertical)
    layoutConfig,layoutGroups,layoutOffset,layoutVertical=config,groups,offset,vertical
  end
  return cachedLayout
end
local function log(message)
  if config.diagnostic_logging then noctalia.log(message) end
end
local function schedule()
  -- No hover polling: ticks only implement a pending delay / short fade. Idle ticks do no rendering.
  local interval = config.refresh_fallback * 1000
  if deadline then interval = math.max(16, math.min(interval, deadline - noctalia.nowMs())) end
  if transitionStart or zoomStart then interval = 33 end
  if scheduledInterval~=interval then
    scheduledInterval=interval; noctalia.setUpdateInterval(interval)
  end
end
local function setExpanded(value)
  value = config.expand_mode == "always" or value
  deadline = nil
  if expanded ~= value then
    expanded = value
    transitionStart = config.animations and config.animation_duration > 0 and noctalia.nowMs() or nil
    dirty = true
  end
  schedule()
end
local function reportFailure(ok, err)
  if not ok then
    log("Window action failed: " .. tostring(err))
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("action_failed"))
  end
end
local function act(action, window)
  local accepted = Compositor.action(backend, noctalia, action, window, reportFailure)
  if not accepted then
    noctalia.notify(noctalia.tr("title"), noctalia.tr("unsupported_action"))
  end
end
local function activate(group)
  if #group.windows == 0 then
    if not noctalia.commandExists("gtk-launch") then
      noctalia.notifyError(noctalia.tr("title"), noctalia.tr("launcher_missing")); return
    end
    -- Desktop IDs only, passed as a single argument. Never execute a configured shell string.
    -- Detached launch: disabling/reloading the dock must not own the application's lifetime.
    if not noctalia.runAsync({ "gtk-launch", "--", group.launchId or group.iconId }) then
      reportFailure(false,"launch rejected")
    end
    return
  end
  local window, cursor = Model.cycle(group, cursors[group.key])
  cursors[group.key] = cursor
  if config.click_behavior == "minimize" and group.focused and #group.windows == 1 and window.minimizable then
    act("minimize", window)
  else act("focus", window) end
end
local function focusedGroup()
  for _, group in ipairs(groups) do if group.focused then return group end end
  return nil
end
local function targetGroup()
  for _, group in ipairs(groups) do if group.key == hoveredKey then return group end end
  return focusedGroup()
end
local function hoverLevel(key)
  local target = config.hover_enlarge and key == hoveredKey and 1 or 0
  if not zoomStart then return target end
  local t = math.clamp((noctalia.nowMs() - zoomStart) / math.max(1, config.animation_duration), 0, 1)
  local eased = t * t * (3 - 2 * t)
  return (zoomFrom[key] or 0) + (target - (zoomFrom[key] or 0)) * eased
end
local function setHoverTarget(key)
  if key == hoveredKey then return end
  local from = {}
  local animate=config.hover_enlarge and config.animations and config.animation_duration>0
  if animate then
    -- Only previously animated icons can have a nonzero starting scale.
    for previous in pairs(zoomFrom) do
      local level=hoverLevel(previous)
      if level>0 then from[previous]=level end
    end
    if hoveredKey then from[hoveredKey]=hoverLevel(hoveredKey) end
  end
  hoveredKey=key; zoomFrom=from
  zoomStart=animate and noctalia.nowMs() or nil
  dirty=true -- hover feedback is also available without magnification
end
local function icon(group, size, scale)
  local app = group.iconId or ""
  -- Resolve once for the maximum intended size, not on each magnification frame.
  local targetSize = Model.peakIconSize(config)
  local cacheKey = app .. ":" .. targetSize
  if icons[cacheKey] == nil then icons[cacheKey] = app ~= "" and (noctalia.appIconPath(app, targetSize * 3) or false) or false end
  if icons[cacheKey] then
    return ui.image({ key = "icon:" .. group.key, path = icons[cacheKey], width = size, height = size,
      fit = "contain", scale = scale or 1 })
  end
  return ui.glyph({ key = "icon:" .. group.key, name = "app-window", size = size,
    scale = scale or 1, color = "on_surface_variant" })
end
local function countNode(group, peak, inline)
  local n = #group.windows
  if n <= 1 or config.duplicate_indicator == "none" then return nil end
  local badge = Model.badgeMetrics(config,n)
  local width = inline and badge.width or math.min(peak+8,badge.width)
  local props = { key="badge:"..group.key, width=width, height=badge.height,
    justify="center", align="center", clip=true }
  local bubble = not inline or config.inline_count_style=="bubble"
  if bubble then
    props.radius=badge.height/2
    props.fill=group.focused and "primary" or "secondary_container"
  end
  if not inline then
    props.translateX = config.badge_placement=="before" and -(peak+2) or 2-width
    props.translateY = -(peak+8-badge.height)/2
    props.border = "surface_container"
  end
  return ui.row(props, { ui.label({text=tostring(n),fontSize=badge.font,
    maxWidth=width-4,maxLines=1,fontWeight="bold",
    color=not bubble and (group.focused and config.active_indicator and "on_primary_container" or "on_surface")
      or (group.focused and "on_primary" or "on_secondary_container")}) })
end
local function cell(group, extent)
  local peak = Model.peakIconSize(config)
  local vertical = barWidget.isVertical()
  local inline = Model.inlineBadge(config,group)
  local scale = 1 + ((config.hover_enlarge and config.hover_scale or 1) - 1) * hoverLevel(group.key)
  local children = { ui.row({width=peak,height=peak,justify="center",align="center"}, {
    icon(group,config.icon_size,scale),
  }) }
  local badge = countNode(group,peak,inline)
  if badge then
    if inline and not vertical and config.badge_placement=="before" then table.insert(children,1,badge)
    else table.insert(children,badge) end
  end
  local fill = group.focused and config.active_indicator and "primary_container"
    or (hoveredKey==group.key and "surface_container_highest" or (inline and "surface_container_high" or "surface_container/0"))
  local props = {key=group.key,width=vertical and peak+8 or extent,
    height=vertical and extent or peak+8,paddingH=4,paddingV=inline and vertical and 4 or 0,
    gap=inline and 4 or 0,align="center",justify="start",radius=math.min(12,(peak+8)/2),fill=fill,
    border=group.urgent and config.urgent_indicator and "error" or nil,
    opacity=group.minimized and config.minimized_indicator and 0.65 or 1,clip=true,
    tooltip=(group.title or group.appId)..(#group.windows>1 and (" ("..tostring(#group.windows)..")") or ""),
    onClick=function() activate(group) end,
    onHover=function(entered)
      if entered=="true" then setHoverTarget(group.key)
      elseif hoveredKey==group.key then setHoverTarget(nil) end
      handleHover(entered=="true")
    end }
  if config.sorting == "manual" then props.onClick = nil end
  local content = (inline and vertical and ui.column or ui.row)(props, children)
  if config.sorting == "manual" then
    local dragProps = { key = "drag:" .. group.key, dragType = "smart-taskbar/app", payload = group.key,
      grabCursor = true, onClick = function() activate(group) end }
    local source = ui.dragSource(dragProps, { content })
    return ui.dropZone({ key = "drop:" .. group.key, accepts = { "smart-taskbar/app" }, value = group.key,
      onDrop = function(payload, target)
        Model.move(state, groups, payload, target)
        ranks = nil; dirty = true; refresh(false); render()
      end }, { source })
  end
  return content
end
refresh = function(reveal)
  local previousKey = groups[offset + 1] and groups[offset + 1].key
  Model.reconcile(state, Compositor.snapshot(backend))
  groups = Model.groups(state, config, barWidget.outputName(), backend.workspaces, hovered and ranks or nil)
  local nextRanks = {}
  for i, group in ipairs(groups) do nextRanks[i] = group.key end
  ranks = nextRanks
  local retainedIcons={}
  local size=Model.peakIconSize(config)
  for _,group in ipairs(groups) do retainedIcons[(group.iconId or "")..":"..size]=true end
  for key in pairs(icons) do if not retainedIcons[key] then icons[key]=nil end end
  -- Preserve the leading identity through membership changes before applying focus reveal.
  if previousKey then
    for i, group in ipairs(groups) do if group.key == previousKey then offset = i - 1; break end end
  end
  local focusIndex
  for i, group in ipairs(groups) do if group.focused then focusIndex = i; break end end
  local layout = getLayout()
  local focusChanged = state.lastFocus ~= lastFocus
  if focusChanged then cursors = {} end
  offset = math.clamp(offset,0,math.max(0,#groups-1))
  if config.auto_reveal_focused and (reveal or focusChanged) and focusIndex then
    if focusIndex<=offset then offset=focusIndex-1 end
    layout=getLayout()
    if focusIndex>offset+layout.capacity then
      -- Fit backwards from the target in one pass, even for thousands of apps.
      local available=config.max_width-16-(layout.indicators and 32 or 0)
      offset=focusIndex-1
      local used=Model.cellExtent(config,groups[focusIndex],barWidget.isVertical())
      while offset>0 do
        local extra=config.icon_spacing+Model.cellExtent(config,groups[offset],barWidget.isVertical())
        if used+extra>available then break end
        used+=extra; offset-=1
      end
    end
  end
  lastFocus = state.lastFocus
  dirty = true
end
local function navigate(delta)
  local layout = getLayout()
  local amount = config.overflow_behavior == "pages" and layout.capacity or config.scroll_step
  local nextOffset=Model.reveal(offset+delta*amount,layout.capacity,#groups,nil)
  if nextOffset~=offset then offset=nextOffset; dirty=true end
  render()
end
render = function()
  if not dirty and not transitionStart and not zoomStart then return end
  local vertical = barWidget.isVertical()
  local container = vertical and ui.column or ui.row
  local hasWindows = false
  for _, group in ipairs(groups) do if #group.windows > 0 then hasWindows = true; break end end
  barWidget.setVisible(hasWindows)
  if not hasWindows then
    -- Keep subscriptions alive so the first matching window can restore the widget.
    hovered, hoveredKey, deadline, transitionStart, zoomStart = false, nil, nil, nil, nil
    zoomFrom = {}; cachedLayout,layoutGroups=nil,nil
    expanded = config.expand_mode == "always"
    barWidget.render(container({ key = "smart-taskbar", visible = false }, {}))
    barWidget.setTooltip("")
    dirty = false; schedule(); return
  end
  local layout = getLayout()
  local children, width = {}, expanded and layout.width or layout.collapsed
  if expanded then
    if layout.indicators then
      table.insert(children, ui.glyph({ name = vertical and "chevron-up" or "chevron-left", size = 14,
        width = vertical and nil or 16, height = vertical and 16 or nil,
        color = offset > 0 and "primary" or "on_surface_variant/0.25" }))
    end
    local strip = {}
    -- Virtualization: render only the visible cells. The fixed viewport clips small budgets and all paint.
    for i = offset + 1, math.min(#groups, offset + layout.capacity) do
      local group = groups[i]
      local extent = Model.cellExtent(config,group,vertical)
      local item = cell(group, extent)
      if vertical then
        item = ui.column({ height = extent, justify = "center", align = "center" }, { item })
      end
      table.insert(strip, item)
    end
    local viewportProps = { key = "viewport", gap = config.icon_spacing, align = "center", clip = true }
    if vertical then viewportProps.height = layout.viewport else viewportProps.width = layout.viewport end
    local alpha = 1
    if transitionStart then
      alpha = math.clamp((noctalia.nowMs() - transitionStart) / math.max(1, config.animation_duration), 0, 1)
      if alpha >= 1 then transitionStart = nil end
    end
    viewportProps.opacity = 0.65 + 0.35 * alpha
    table.insert(children, container(viewportProps, strip))
    if layout.indicators then
      table.insert(children, ui.glyph({ name = vertical and "chevron-down" or "chevron-right", size = 14,
        width = vertical and nil or 16, height = vertical and 16 or nil,
        color = offset + layout.capacity < #groups and "primary" or "on_surface_variant/0.25" }))
    end
  else
    transitionStart = nil
    local group = focusedGroup()
    if not group then
      for _, candidate in ipairs(groups) do if #candidate.windows > 0 then group = candidate; break end end
    end
    table.insert(children, icon(group, math.min(config.icon_size, width - 16)))
    local text = ""
    if group then
      if config.collapsed_label == "title" then text = group.title or group.appId
      elseif config.collapsed_label == "name" then text = group.appId
      elseif config.collapsed_label == "count" and #group.windows > 1 then text = tostring(#group.windows) end
    end
    if text ~= "" and not vertical then
      table.insert(children, ui.label({ text = text, fontSize = 11, maxLines = 1,
        maxWidth = math.max(0, width - config.icon_size - 20), color = "on_surface" }))
    end
  end
  local props = { key = "smart-taskbar", gap = 0, align = "center", justify = "center", paddingH = 8, paddingV = 0,
    radius = config.capsule_radius, fill = "surface_container/" .. tostring(config.opacity),
    border = config.border and "outline_variant" or nil, clip = true,
    onHover = function(entered) handleHover(entered == "true") end }
  if vertical then props.paddingH = 0; props.paddingV = 8; props.height = width; props.width = layout.peak + 8
  else props.width = width; props.height = layout.peak + 8 end
  barWidget.render(container(props, children))
  barWidget.setTooltip(backend.connected and noctalia.tr("hint") or noctalia.tr("disconnected"))
  if zoomStart and noctalia.nowMs() - zoomStart >= config.animation_duration then zoomStart = nil; zoomFrom = {} end
  dirty = false; schedule()
end
handleHover = function(entered)
  hovered = entered
  if entered then
    if config.expand_mode == "hover" and not expanded then
      pendingExpand = true; deadline = noctalia.nowMs() + config.hover_delay
    else deadline = nil end
  else
    setHoverTarget(nil)
    if config.expand_mode == "hover" and expanded and config.sorting ~= "manual" then
      pendingExpand = false; deadline = noctalia.nowMs() + config.collapse_delay
    else deadline = nil end
  end
  schedule()
  render()
end
function onHover(entered)
  handleHover(entered)
end
function onClick()
  if config.expand_mode ~= "always" then setExpanded(not expanded); refresh(true); render() end
end
function onRightClick()
  noctalia.openSettings()
end
function onMiddleClick()
  -- The host's built-in settings gesture wins unless the user explicitly sets middle = "none".
  if config.middle_click == "none" then return end
  if config.middle_click == "settings" then noctalia.openSettings(); return end
  local group = targetGroup()
  if not group or #group.windows == 0 then return end
  local window = group.windows[1]
  for _, w in ipairs(group.windows) do if w.focused then window = w; break end end
  act(config.middle_click == "close" and "close" or (window.minimized and "focus" or "minimize"), window)
end
function onScroll(axis, steps, startsGesture)
  if axis ~= "vertical" and axis ~= "horizontal" then return end
  if not startsGesture or steps == 0 then return end
  if not expanded then setExpanded(true); refresh(true) end
  navigate(steps > 0 and 1 or -1)
end
function onConfigChanged()
  local previousCompatibility = config.compositor_compatibility
  local previousMode = config.expand_mode
  -- Ignore unrelated host/editor configuration changes without resetting the widget.
  if not readConfig() then return end
  zoomStart = nil; zoomFrom = {}; hoveredKey = nil
  if previousCompatibility ~= config.compositor_compatibility then
    subscriptionGeneration += 1
    if subscription then transport.unsubscribe(subscription); subscription = nil end
    Compositor.event(backend, "reset", nil)
    state = Model.new()
  end
  subscribe(); cursors = {}; ranks = nil; offset = 0
  if previousMode~=config.expand_mode then setExpanded(config.expand_mode=="always")
  else deadline=nil; schedule() end
  refresh(true); render()
end
function onIpc(event)
  if event == "expand" then setExpanded(true)
  elseif event == "collapse" then setExpanded(false)
  elseif event == "next" then navigate(1); return
  elseif event == "previous" then navigate(-1); return
  else return end
  refresh(true); render()
end
subscribe = function()
  if subscription then return end
  if config.compositor_compatibility ~= "auto" and config.compositor_compatibility ~= backend.name then return end
  local generation = subscriptionGeneration
  subscription = transport.subscribe({ events = { "windows", "workspaces" } }, function(event, data)
    if generation ~= subscriptionGeneration then return end
    if event == "error" then log("Compositor subscription: " .. tostring(data)) end
    if event == "reset" then icons = {}; cursors = {}; state = Model.new(); ranks = nil; offset = 0 end
    if Compositor.event(backend, event, data) then refresh(false); render() end
  end)
  if not subscription and transport.problem and transport.problem~=reportedProblem then
    reportedProblem=transport.problem
    log("Compositor unavailable: "..reportedProblem)
    if reportedProblem~="unsupported compositor" then
      noctalia.notify(noctalia.tr("title"),noctalia.tr("dependency_missing",{dependency=reportedProblem}))
    end
  end
end
function update()
  if not initialized then
    readConfig(); expanded = config.expand_mode == "always"; initialized = true
    subscribe()
    refresh(true); render()
  end
  if deadline and noctalia.nowMs() >= deadline then
    setExpanded(pendingExpand); refresh(pendingExpand); render()
  elseif transitionStart or zoomStart then render()
  else subscribe(); schedule() end
end
function onExit()
  subscriptionGeneration += 1
  if subscription then transport.unsubscribe(subscription) end
end
