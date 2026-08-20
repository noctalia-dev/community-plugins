--!nonstrict
-- Flex Taskbar for Noctalia v5 + Niri.
-- Niri is queried asynchronously so compositor IPC never blocks the shell UI.

local groups = {}
local hoveredApp = nil
local refreshInFlight = false
local workspaceOutputs = {}
local iconCache = {}
local lastCycle = {}
local warned = false
local previewRequestedApp = nil
local previewShowAt = nil
local previewCloseAt = nil
local previewOpening = false
local previewGeneration = 0

noctalia.state.watch("preview_open", function(value)
  previewOpening = value == true
end)

local function cfg(key)
  return noctalia.getConfig(key)
end

local function lower(value)
  return string.lower(tostring(value or ""))
end

local function shellQuote(value)
  local text = tostring(value or "")
  return "'" .. string.gsub(text, "'", "'\\''") .. "'"
end

local function tableValue(map, key)
  if type(map) ~= "table" then return nil end
  if map[key] ~= nil then return map[key] end
  local wanted = lower(key)
  for candidate, value in pairs(map) do
    if lower(candidate) == wanted then return value end
  end
  return nil
end

local function containsPinned(pins, appId)
  local wanted = lower(appId)
  for index, pinned in ipairs(pins) do
    if lower(pinned) == wanted then return index, pinned end
  end
  return nil, nil
end

local function canonicalAppId(appId, pins, aliases)
  local alias = tableValue(aliases, appId)
  if alias ~= nil and tostring(alias) ~= "" then return tostring(alias) end
  local _, pinned = containsPinned(pins, appId)
  return pinned or tostring(appId)
end

local function appLabel(appId)
  local override = tableValue(cfg("label_overrides"), appId)
  if override ~= nil and tostring(override) ~= "" then return tostring(override) end
  local label = tostring(appId)
  label = string.gsub(label, "%.desktop$", "")
  label = string.gsub(label, "^org%.gnome%.", "")
  label = string.gsub(label, "^com%.[^%.]+%.", "")
  label = string.gsub(label, "[-_%.]+", " ")
  return label
end

local function resolveIcon(appId)
  local size = tonumber(cfg("icon_size")) or 24
  local override = tableValue(cfg("icon_overrides"), appId)
  local source = (override ~= nil and tostring(override) ~= "") and tostring(override) or appId
  local cacheKey = tostring(source) .. "|" .. tostring(size)
  if iconCache[cacheKey] ~= nil then
    return iconCache[cacheKey] ~= false and iconCache[cacheKey] or nil
  end
  local path = noctalia.appIconPath(source, size)
  iconCache[cacheKey] = path or false
  return path
end

local function findGroup(appId)
  for _, group in ipairs(groups) do
    if group.id == appId then return group end
  end
  return nil
end

local function focusWindow(windowId)
  local id = tonumber(windowId)
  if id == nil then return end
  noctalia.runAsync("niri msg action focus-window --id " .. tostring(math.floor(id)))
end

local function launchApp(appId)
  local command = tableValue(cfg("launch_commands"), appId)
  if command ~= nil and tostring(command) ~= "" then
    noctalia.runAsync(tostring(command))
  else
    noctalia.runAsync("gtk-launch " .. shellQuote(appId))
  end
end

local function activateApp(appId)
  local group = findGroup(appId)
  if group == nil or #group.windows == 0 then
    launchApp(appId)
    return
  end

  local focusedIndex = nil
  for index, window in ipairs(group.windows) do
    if window.is_focused == true then focusedIndex = index break end
  end

  local nextIndex = 1
  if focusedIndex ~= nil then
    nextIndex = (focusedIndex % #group.windows) + 1
  elseif lastCycle[appId] ~= nil then
    nextIndex = (lastCycle[appId] % #group.windows) + 1
  end
  lastCycle[appId] = nextIndex
  focusWindow(group.windows[nextIndex].id)
end

local function windowFocusTime(window)
  local timestamp = window.focus_timestamp
  if type(timestamp) ~= "table" then return 0 end
  return (tonumber(timestamp.secs) or 0) * 1000000000 + (tonumber(timestamp.nanos) or 0)
end

local function previewWindows(group)
  local windows = {}
  for _, window in ipairs(group.windows) do table.insert(windows, window) end
  table.sort(windows, function(a, b)
    if a.is_focused ~= b.is_focused then return a.is_focused == true end
    return windowFocusTime(a) > windowFocusTime(b)
  end)
  return windows
end

local function thumbnailIsFresh(path)
  local info = noctalia.fileInfo(path)
  if info == nil or info.isDir == true then return false end
  local age = (noctalia.nowMs() / 1000) - (tonumber(info.mtime) or 0)
  return age <= (tonumber(cfg("preview_refresh_seconds")) or 12)
end

local function ensurePreviewPanel()
  if noctalia.state.get("preview_open") == true or previewOpening then return end
  previewOpening = true
  noctalia.togglePanel("sudiptacmd/flex-taskbar:previews")
end

local function closePreviewPanel()
  previewRequestedApp = nil
  previewShowAt = nil
  previewCloseAt = nil
  if noctalia.state.get("preview_open") == true or previewOpening then
    noctalia.togglePanel("sudiptacmd/flex-taskbar:previews")
  end
  previewOpening = false
end

local function publishPreview(appId, entries)
  noctalia.state.set("preview_app", appId)
  noctalia.state.set("preview_data", entries)
  ensurePreviewPanel()
end

local function capturePreviews(appId, entries, stale)
  if #stale == 0 then return end
  previewGeneration = previewGeneration + 1
  local generation = previewGeneration
  local backup = "/tmp/noctalia-flex-taskbar-clipboard-" .. tostring(math.floor(noctalia.nowMs()))
  local commands = {
    "mime=$(wl-paste --list-types 2>/dev/null | head -n 1)",
    "if [ -n \"$mime\" ]; then wl-paste --type \"$mime\" > " .. shellQuote(backup) .. " 2>/dev/null; fi",
  }
  for _, entry in ipairs(stale) do
    table.insert(commands,
      "niri msg action screenshot-window --id " .. tostring(entry.id)
      .. " --write-to-disk true --show-pointer false --path " .. shellQuote(entry.path) .. " >/dev/null 2>&1"
    )
  end
  table.insert(commands,
    "if [ -n \"$mime\" ] && [ -e " .. shellQuote(backup)
    .. " ]; then wl-copy --type \"$mime\" < " .. shellQuote(backup)
    .. "; else wl-copy --clear; fi"
  )

  noctalia.runAsync(table.concat(commands, "; "), function(_result)
    noctalia.removeFile(backup)
    if generation ~= previewGeneration or noctalia.state.get("preview_app") ~= appId then return end
    for _, entry in ipairs(entries) do
      entry.ready = noctalia.fileExists(entry.path)
    end
    noctalia.state.set("preview_data", entries)
  end)
end

local function showPreview(appId)
  local group = findGroup(appId)
  if cfg("preview_enabled") ~= true or group == nil or #group.windows == 0 then
    closePreviewPanel()
    return
  end

  local dataDir = noctalia.pluginDataDir()
  if dataDir == nil then return end
  local previewDir = dataDir .. "/previews"
  noctalia.mkdirAll(previewDir)

  local entries = {}
  local stale = {}
  local windows = previewWindows(group)
  local limit = math.min(#windows, tonumber(cfg("preview_max_windows")) or 3)
  for index = 1, limit do
    local window = windows[index]
    local id = math.floor(tonumber(window.id) or 0)
    local path = previewDir .. "/window-" .. tostring(id) .. ".png"
    local entry = {
      id = id,
      app_id = appId,
      title = tostring(window.title or appLabel(appId)),
      path = path,
      focused = window.is_focused == true,
      ready = thumbnailIsFresh(path),
    }
    table.insert(entries, entry)
    if not entry.ready then table.insert(stale, entry) end
  end

  publishPreview(appId, entries)
  capturePreviews(appId, entries, stale)
end

local function requestPreview(appId)
  if cfg("preview_enabled") ~= true then return end
  local group = findGroup(appId)
  if group == nil or #group.windows == 0 then return end
  previewRequestedApp = appId
  previewShowAt = noctalia.nowMs() + (tonumber(cfg("preview_hover_delay")) or 220)
  previewCloseAt = nil
end

local function updatePreviewLifecycle()
  if cfg("preview_enabled") ~= true then
    if noctalia.state.get("preview_open") == true then closePreviewPanel() end
    return
  end

  local now = noctalia.nowMs()
  if previewRequestedApp ~= nil and hoveredApp == previewRequestedApp and previewShowAt ~= nil and now >= previewShowAt then
    local appId = previewRequestedApp
    previewRequestedApp = nil
    previewShowAt = nil
    showPreview(appId)
  end

  local panelHovered = noctalia.state.get("preview_panel_hovered") == true
  if panelHovered or hoveredApp ~= nil then
    previewCloseAt = nil
  elseif noctalia.state.get("preview_open") == true or previewOpening then
    if previewCloseAt == nil then
      previewCloseAt = now + (tonumber(cfg("preview_hide_delay")) or 450)
    elseif now >= previewCloseAt then
      closePreviewPanel()
    end
  end
end

local function backgroundFor(group)
  if hoveredApp == group.id then return cfg("hover_background_color") end
  local style = tostring(cfg("background_style") or "active")
  if style == "always" then
    return group.focused and cfg("active_background_color") or cfg("running_background_color")
  elseif style == "running" and #group.windows > 0 then
    return group.focused and cfg("active_background_color") or cfg("running_background_color")
  elseif style == "active" and group.focused then
    return cfg("active_background_color")
  end
  return "#00000000"
end

local function iconOpacity(group)
  if group.focused then return tonumber(cfg("active_opacity")) or 1.0 end
  if #group.windows > 0 then return tonumber(cfg("inactive_opacity")) or 1.0 end
  return tonumber(cfg("stopped_opacity")) or 1.0
end

local function makeDots(group)
  local dotSize = tonumber(cfg("dot_size")) or 3
  local children = {}
  if cfg("show_window_dots") == true then
    local limit = math.min(#group.windows, tonumber(cfg("max_dots")) or 8)
    for index = 1, limit do
      local window = group.windows[index]
      table.insert(children, ui.box({
        key = "dot-" .. tostring(window.id),
        width = dotSize,
        height = dotSize,
        radius = dotSize / 2,
        fill = window.is_focused == true and cfg("focused_dot_color") or cfg("dot_color"),
      }))
    end
  end
  if #children == 0 then
    table.insert(children, ui.box({ width = 1, height = dotSize, fill = "#00000000" }))
  end
  return ui.row({
    key = "dots-" .. group.id,
    height = dotSize,
    gap = tonumber(cfg("dot_gap")) or 2,
    align = "center",
    justify = "center",
    visible = cfg("show_window_dots") == true,
  }, children)
end

local function makeUnderline(group)
  local shown = cfg("show_active_underline") == true
  return ui.box({
    key = "underline-" .. group.id,
    width = tonumber(cfg("underline_width")) or 18,
    height = tonumber(cfg("underline_thickness")) or 2,
    radius = tonumber(cfg("underline_radius")) or 2,
    fill = cfg("underline_color"),
    opacity = group.focused and 1.0 or 0.0,
    visible = shown,
  })
end

local function makeAppTile(group)
  local appId = group.id
  local iconSize = tonumber(cfg("icon_size")) or 24
  local content = {}
  local iconPath = resolveIcon(appId)
  if iconPath ~= nil then
    table.insert(content, ui.image({
      key = "icon-" .. appId,
      path = iconPath,
      width = iconSize,
      height = iconSize,
      radius = tonumber(cfg("icon_radius")) or 5,
      fit = "contain",
      opacity = iconOpacity(group),
    }))
  else
    table.insert(content, ui.glyph({
      key = "glyph-" .. appId,
      name = tostring(cfg("fallback_glyph") or "app-window"),
      size = iconSize,
      opacity = iconOpacity(group),
    }))
  end

  if cfg("show_labels") == true then
    table.insert(content, ui.label({
      key = "label-" .. appId,
      text = appLabel(appId),
      fontSize = tonumber(cfg("label_size")) or 12,
      maxWidth = tonumber(cfg("label_max_width")) or 90,
      maxLines = 1,
      opacity = iconOpacity(group),
    }))
  end

  local itemWidth = math.max(
    tonumber(cfg("item_width")) or 34,
    iconSize + (tonumber(cfg("item_padding")) or 3) * 2,
    (tonumber(cfg("underline_width")) or 18) + 4
  )

  return ui.column({
    key = "app-" .. appId,
    minWidth = itemWidth,
    paddingH = tonumber(cfg("item_padding")) or 3,
    paddingV = 1,
    gap = tonumber(cfg("indicator_gap")) or 1,
    align = "center",
    justify = "center",
    fill = backgroundFor(group),
    radius = tonumber(cfg("item_radius")) or 8,
    border = cfg("item_border_color"),
    borderWidth = tonumber(cfg("item_border_width")) or 0,
    onClick = function() activateApp(appId) end,
    onHover = function(state)
      if state == "true" then
        hoveredApp = appId
        requestPreview(appId)
      elseif hoveredApp == appId then
        hoveredApp = nil
        previewRequestedApp = nil
        previewShowAt = nil
        previewCloseAt = noctalia.nowMs() + (tonumber(cfg("preview_hide_delay")) or 450)
      end
      if #groups > 0 then renderTaskbar() end
    end,
  }, {
    ui.row({ gap = 6, align = "center", justify = "center" }, content),
    makeDots(group),
    makeUnderline(group),
  })
end

function renderTaskbar()
  local items = {}
  for _, group in ipairs(groups) do
    table.insert(items, makeAppTile(group))
  end

  if #items == 0 then
    table.insert(items, ui.glyph({ name = "apps", size = tonumber(cfg("icon_size")) or 24, opacity = 0.35 }))
  end

  local root = ui.row({
    gap = tonumber(cfg("item_gap")) or 3,
    align = "center",
    justify = "center",
  }, items)
  barWidget.render(root)
end

local function groupWindows(windows)
  local pins = cfg("pinned_apps") or {}
  local aliases = cfg("app_aliases") or {}
  local byId = {}
  local result = {}

  for index, appId in ipairs(pins) do
    if tostring(appId) ~= "" then
      local group = { id = tostring(appId), windows = {}, focused = false, pinnedIndex = index, firstWindowId = math.huge }
      byId[lower(appId)] = group
      table.insert(result, group)
    end
  end

  local outputName = barWidget.outputName()
  local onlyThisOutput = cfg("current_output_only") == true and outputName ~= nil
  for _, window in ipairs(windows) do
    local appId = tostring(window.app_id or "")
    local allowed = appId ~= ""
    if allowed and onlyThisOutput then
      allowed = workspaceOutputs[tonumber(window.workspace_id)] == outputName
    end
    if allowed then
      local canonical = canonicalAppId(appId, pins, aliases)
      local key = lower(canonical)
      local group = byId[key]
      if group == nil and cfg("show_unpinned_running") == true then
        group = { id = canonical, windows = {}, focused = false, pinnedIndex = nil, firstWindowId = math.huge }
        byId[key] = group
        table.insert(result, group)
      end
      if group ~= nil then
        table.insert(group.windows, window)
        group.focused = group.focused or window.is_focused == true
        group.firstWindowId = math.min(group.firstWindowId, tonumber(window.id) or math.huge)
      end
    end
  end

  if cfg("hide_stopped_pins") == true then
    local running = {}
    for _, group in ipairs(result) do
      if #group.windows > 0 then table.insert(running, group) end
    end
    result = running
  end

  local order = tostring(cfg("order") or "pinned_first")
  table.sort(result, function(a, b)
    if order == "alphabetical" then return lower(appLabel(a.id)) < lower(appLabel(b.id)) end
    if order == "running_first" then
      local ar, br = #a.windows > 0, #b.windows > 0
      if ar ~= br then return ar end
    end
    if a.pinnedIndex ~= nil and b.pinnedIndex ~= nil then return a.pinnedIndex < b.pinnedIndex end
    if a.pinnedIndex ~= nil then return true end
    if b.pinnedIndex ~= nil then return false end
    return a.firstWindowId < b.firstWindowId
  end)
  return result
end

local function acceptWindows(result)
  refreshInFlight = false
  if result.exitCode ~= 0 then
    if not warned then
      noctalia.log("Could not query Niri windows: " .. tostring(result.stderr or "unknown error"))
      warned = true
    end
    if #groups == 0 then
      groups = groupWindows({})
      renderTaskbar()
    end
    return
  end
  local windows, err = noctalia.json.decode(result.stdout or "[]")
  if windows == nil or type(windows) ~= "table" then
    noctalia.log("Invalid JSON from 'niri msg -j windows': " .. tostring(err))
    return
  end
  warned = false
  groups = groupWindows(windows)
  renderTaskbar()
end

local function queryWindows()
  noctalia.runAsync("niri msg -j windows", acceptWindows)
end

local function acceptWorkspaces(result)
  workspaceOutputs = {}
  if result.exitCode == 0 then
    local workspaces = noctalia.json.decode(result.stdout or "[]")
    if type(workspaces) == "table" then
      for _, workspace in ipairs(workspaces) do
        workspaceOutputs[tonumber(workspace.id)] = tostring(workspace.output or "")
      end
    end
  end
  queryWindows()
end

local function refresh()
  if refreshInFlight then return end
  refreshInFlight = true
  if cfg("current_output_only") == true then
    if not noctalia.runAsync("niri msg -j workspaces", acceptWorkspaces) then
      workspaceOutputs = {}
      queryWindows()
    end
  elseif not noctalia.runAsync("niri msg -j windows", acceptWindows) then
    refreshInFlight = false
  end
end

function update()
  noctalia.setUpdateInterval(tonumber(cfg("poll_interval")) or 350)
  updatePreviewLifecycle()
  refresh()
end

function onRightClick()
  noctalia.openSettings()
end

function onScroll(axis, steps, startsGesture)
  if axis ~= "vertical" or not startsGesture or #groups == 0 then return end
  local focusedIndex = nil
  for index, group in ipairs(groups) do
    if group.focused and #group.windows > 0 then focusedIndex = index break end
  end
  local direction = steps > 0 and 1 or -1
  local index = focusedIndex or (direction > 0 and 0 or 1)
  for _ = 1, #groups do
    index = ((index - 1 + direction) % #groups) + 1
    if #groups[index].windows > 0 then
      focusWindow(groups[index].windows[1].id)
      return
    end
  end
end

function onIpc(event, payload)
  if event == "refresh" then
    refresh()
  elseif event == "settings" then
    noctalia.openSettings()
  elseif event == "close-previews" then
    closePreviewPanel()
  elseif event == "preview" and payload ~= nil and tostring(payload) ~= "" then
    showPreview(tostring(payload))
  else
    noctalia.log("Unknown IPC event: " .. tostring(event))
  end
end
