--!nonstrict
-- AniList library panel: login, filters, scrollable list, episode/chapter controls.

local COVER_WIDTH = 44
local COVER_HEIGHT = 62
local PREVIEW_WIDTH = 280
local PREVIEW_HEIGHT = math.floor(PREVIEW_WIDTH * COVER_HEIGHT / COVER_WIDTH)
local INITIAL_VISIBLE_ROWS = 12
local ROW_BATCH_SIZE = 10
local MAX_VISIBLE_ROWS = 200
local LIST_LOAD_INTERVAL_MS = 80
local LIST_IDLE_INTERVAL_MS = 1000
local lastCoverPriorityKey = ""
local visibleRowLimit = INITIAL_VISIBLE_ROWS

local snapshot = noctalia.state.get("anilist_snapshot") or {
  revision = 0,
  loading = false,
  refreshing = false,
  busy = false,
  error = "",
  viewer = nil,
  anime = {},
  manga = {},
}

local mediaTab = "ANIME"
local statusFilter = "CURRENT"
local dirty = true
local render
local coverPreview = nil
local coverDownloadBusy = false

local function coverLoadingSet()
  local set = {}
  for _, id in ipairs(noctalia.state.get("anilist_cover_loading") or {}) do
    local mediaId = tonumber(id)
    if mediaId then
      set[mediaId] = true
    end
  end
  return set
end

local env = getfenv()

local function tr(key, subst)
  return noctalia.tr("panel." .. key, subst)
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function sendCommand(action, values)
  local command = { action = action }
  if type(values) == "table" then
    for k, v in pairs(values) do
      command[k] = v
    end
  end
  noctalia.state.set("anilist_command", command)
end

local function rowCallback(prefix, mediaId, fn)
  local name = prefix .. "_" .. tostring(mediaId)
  env[name] = fn
  return name
end

local function resetListView()
  visibleRowLimit = INITIAL_VISIBLE_ROWS
  lastCoverPriorityKey = ""
end

local function listRowCap(rows)
  return math.min(#rows, MAX_VISIBLE_ROWS)
end

local function syncListLoadInterval(rows)
  if visibleRowLimit < listRowCap(rows) then
    noctalia.setUpdateInterval(LIST_LOAD_INTERVAL_MS)
  else
    noctalia.setUpdateInterval(LIST_IDLE_INTERVAL_MS)
  end
end

local function growVisibleRows(rows)
  local cap = listRowCap(rows)
  if visibleRowLimit >= cap then
    return false
  end
  visibleRowLimit = math.min(visibleRowLimit + ROW_BATCH_SIZE, cap)
  return true
end

local function titleCompare(a, b)
  return (a.title or ""):lower() < (b.title or ""):lower()
end

local function sortEntries(entries, filter)
  local sorted = {}
  for _, entry in ipairs(entries) do
    table.insert(sorted, entry)
  end

  if filter == "CURRENT" then
    table.sort(sorted, function(a, b)
      local progressA = a.progress or 0
      local progressB = b.progress or 0
      if progressA ~= progressB then
        return progressA > progressB
      end
      return titleCompare(a, b)
    end)
  else
    table.sort(sorted, titleCompare)
  end

  return sorted
end

local function entriesForView()
  local source = if mediaTab == "MANGA" then snapshot.manga else snapshot.anime
  if statusFilter == "ALL" then
    return sortEntries(source, statusFilter)
  end

  local filtered = {}
  for _, entry in ipairs(source) do
    if entry.status == statusFilter then
      table.insert(filtered, entry)
    end
  end
  return sortEntries(filtered, statusFilter)
end

local function progressLabel(entry)
  local current = entry.progress or 0
  local total = entry.total
  if entry.mediaType == "MANGA" then
    if total then
      return tr("progress_manga", { current = current, total = total })
    end
    return tr("progress_manga_unknown", { current = current })
  end
  if total then
    return tr("progress_anime", { current = current, total = total })
  end
  return tr("progress_anime_unknown", { current = current })
end

local STAR_GLYPH_SIZE = 15

local function renderScoreStars(score)
  local value = tonumber(score)
  if not value or value <= 0 then
    return nil
  end
  local filled = math.max(1, math.min(5, math.floor(value / 20 + 0.5)))
  local stars = {}
  for index = 1, 5 do
    table.insert(stars, ui.glyph({
      name = if index <= filled then "star-filled" else "star",
      size = STAR_GLYPH_SIZE,
      color = "on_surface_variant",
    }))
  end
  return ui.row({ gap = 1, align = "center" }, stars)
end

local function subtitleTextFor(entry)
  local parts = { progressLabel(entry) }
  if entry.nextEpisode and entry.mediaType == "ANIME" then
    table.insert(parts, tr("next_episode", { episode = entry.nextEpisode }))
  end
  return table.concat(parts, " · ")
end

local function renderTitle(entry)
  return ui.label({
    text = entry.title or "?",
    fontWeight = "medium",
    maxLines = 2,
  })
end

local function renderSubtitle(entry)
  return ui.label({
    text = subtitleTextFor(entry),
    fontSize = 12,
    color = "on_surface_variant",
    maxLines = 2,
  })
end

local function syncVisibleCoverPriority(rows)
  local ids = {}
  local cap = math.min(listRowCap(rows), visibleRowLimit)
  for index = 1, cap do
    local entry = rows[index]
    if entry and entry.mediaId then
      table.insert(ids, entry.mediaId)
    end
  end

  local key = table.concat(ids, ",")
  if key == lastCoverPriorityKey then
    return
  end
  lastCoverPriorityKey = key
  sendCommand("prioritize_covers", { mediaIds = ids })
end

local function filterButton(key, label, filter)
  local active = statusFilter == filter
  return ui.button({
    key = "filter-" .. key,
    text = label,
    variant = if active then "primary" else "ghost",
    onClick = rowCallback("onFilter", key, function()
      statusFilter = filter
      resetListView()
      dirty = true
      render()
    end),
  })
end

local function renderLogin()
  local children = {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({ text = tr("login_title"), fontSize = 18, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "settings", variant = "ghost", tooltip = tr("settings"), onClick = "onOpenSettings" }),
      ui.button({ glyph = "close", variant = "ghost", tooltip = tr("close"), onClick = "onClosePanel" }),
    }),
    ui.label({ text = tr("login_help"), fontSize = 12, color = "on_surface_variant", maxLines = 8 }),
  }

  if snapshot.loading then
    table.insert(children, ui.label({ text = tr("login_waiting"), color = "primary", fontSize = 13 }))
  else
    table.insert(children, ui.button({
      text = tr("connect"),
      variant = "primary",
      onClick = "onConnect",
      flexGrow = 1,
    }))
  end

  if snapshot.error ~= "" then
    table.insert(children, ui.label({ text = tr("error", { message = snapshot.error }), color = "error", fontSize = 12 }))
  end

  panel.render(ui.column({ gap = 12, padding = 16 }, children))
end

local function coverFilename(title)
  local name = (title or "cover"):gsub("[^%w%-%._ ]", ""):gsub("%s+", " ")
  name = noctalia.string.trim(name)
  if name == "" then
    name = "cover"
  end
  if not name:lower():match("%.jpe?g$") then
    name = name .. ".jpg"
  end
  return name
end

local function ensureJpegExtension(path)
  path = noctalia.string.trim(path or "")
  if path == "" then
    return path
  end
  if not path:lower():match("%.jpe?g$") then
    return path .. ".jpg"
  end
  return path
end

local function pickCoverSavePath(defaultName, callback)
  local suggested = noctalia.expandPath("~/Downloads/" .. defaultName)
  local cmd
  if noctalia.commandExists("zenity") then
    cmd = "zenity --file-selection --save --confirm-overwrite --filename="
      .. shellQuote(suggested)
  elseif noctalia.commandExists("kdialog") then
    cmd = "kdialog --getsavefilename " .. shellQuote(suggested) .. " 'Images (*.jpg)'"
  else
    callback(nil, tr("download_cover_unavailable"))
    return
  end

  noctalia.runAsync(cmd, function(result)
    local path = (result.stdout or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if result.exitCode ~= 0 or path == "" then
      callback(nil, nil)
      return
    end
    callback(ensureJpegExtension(path), nil)
  end)
end

local function writeCoverToPath(coverPath, coverUrl, destPath, callback)
  if coverPath and noctalia.fileExists(coverPath) then
    local data = noctalia.readFile(coverPath)
    if type(data) == "string" and data ~= "" then
      local ok = noctalia.writeFile(destPath, data)
      callback(ok, ok and nil or tr("download_cover_failed"))
      return
    end
  end

  if type(coverUrl) == "string" and coverUrl ~= "" then
    local started = noctalia.download(coverUrl, destPath, function(ok)
      callback(ok == true, ok and nil or tr("download_cover_failed"))
    end)
    if not started then
      callback(false, tr("download_cover_failed"))
    end
    return
  end

  callback(false, tr("download_cover_failed"))
end

local function startCoverDownload(preview)
  if coverDownloadBusy or type(preview) ~= "table" then
    return
  end

  coverDownloadBusy = true
  dirty = true
  render()

  pickCoverSavePath(coverFilename(preview.title), function(destPath, pickError)
    if pickError then
      coverDownloadBusy = false
      noctalia.notifyError(tr("title"), pickError)
      dirty = true
      render()
      return
    end
    if not destPath then
      coverDownloadBusy = false
      dirty = true
      render()
      return
    end

    writeCoverToPath(preview.coverPath, preview.coverUrl, destPath, function(ok, saveError)
      coverDownloadBusy = false
      if ok then
        noctalia.notify(tr("title"), tr("download_cover_success", { path = destPath }))
      elseif saveError then
        noctalia.notifyError(tr("title"), saveError)
      end
      dirty = true
      render()
    end)
  end)
end

local function openCoverPreview(entry)
  if not entry.coverPath then
    return
  end
  coverPreview = {
    mediaId = entry.mediaId,
    title = entry.title or "?",
    coverPath = entry.coverPath,
    coverUrl = entry.coverUrl,
  }
  dirty = true
  render()
end

local function renderCoverPreview()
  return ui.column({ gap = 12, padding = 16, flexGrow = 1 }, {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({
        text = coverPreview.title or "?",
        fontSize = 16,
        fontWeight = "bold",
        flexGrow = 1,
        maxLines = 2,
      }),
      ui.row({ gap = 4, align = "center" }, {
        ui.button({
          glyph = "download",
          variant = "ghost",
          tooltip = tr("download_cover"),
          disabled = coverDownloadBusy,
          onClick = coverDownloadBusy and "onNoop" or "onDownloadCoverPreview",
        }),
        ui.button({ glyph = "close", variant = "ghost", tooltip = tr("close_preview"), onClick = "onCloseCoverPreview" }),
      }),
    }),
    ui.column({ flexGrow = 1, align = "center", justify = "center" }, {
      ui.image({
        path = coverPreview.coverPath,
        width = PREVIEW_WIDTH,
        height = PREVIEW_HEIGHT,
        radius = 10,
        fit = "cover",
      }),
    }),
  })
end

local function renderCover(entry, loadingSet)
  local mediaId = entry.mediaId
  local coverPath = entry.coverPath

  if coverPath then
    return ui.image({
      key = "cover-" .. tostring(mediaId),
      path = coverPath,
      width = COVER_WIDTH,
      height = COVER_HEIGHT,
      radius = 6,
      fit = "cover",
      tooltip = tr("cover_preview"),
      onClick = rowCallback("onCover", mediaId, function()
        openCoverPreview(entry)
      end),
    })
  end

  local children = {}
  if loadingSet[entry.mediaId] then
    table.insert(children, ui.glyph({
      name = "loader",
      size = 18,
      color = "on_surface",
    }))
  end

  return ui.column({
    width = COVER_WIDTH,
    height = COVER_HEIGHT,
    radius = 6,
    fill = entry.coverColor or "#334155",
    align = "center",
    justify = "center",
  }, children)
end

local function renderEntryRow(entry, index, loadingSet)
  if index > visibleRowLimit then
    return nil
  end

  local mediaId = entry.mediaId
  local canDecrement = (entry.progress or 0) > 0 and not snapshot.busy
  local canIncrement = not snapshot.busy
  local isComplete = entry.status == "COMPLETED"

  local textChildren = {
    renderTitle(entry),
    renderSubtitle(entry),
  }
  local stars = renderScoreStars(entry.score)
  local mainChildren = {
    ui.column({ gap = 2, flexGrow = 1, justify = "center" }, textChildren),
  }
  if stars then
    table.insert(mainChildren, stars)
  end

  local rowChildren = {
    renderCover(entry, loadingSet),
    ui.row({
      height = COVER_HEIGHT,
      gap = 8,
      flexGrow = 1,
      align = "center",
    }, mainChildren),
  }

  table.insert(rowChildren, ui.button({
    glyph = "minus",
    variant = "ghost",
    tooltip = tr("decrement"),
    onClick = canDecrement and rowCallback("onDec", mediaId, function()
      sendCommand("decrement", { mediaId = mediaId })
    end) or "onNoop",
  }))
  table.insert(rowChildren, ui.button({
    glyph = "plus",
    variant = "ghost",
    tooltip = tr("increment"),
    onClick = canIncrement and rowCallback("onInc", mediaId, function()
      sendCommand("increment", { mediaId = mediaId })
    end) or "onNoop",
  }))
  table.insert(rowChildren, ui.button({
    glyph = if isComplete then "check" else "circle-check",
    variant = if isComplete then "primary" else "ghost",
    tooltip = tr("mark_complete"),
    onClick = snapshot.busy and "onNoop" or rowCallback("onDone", mediaId, function()
      sendCommand("complete", { mediaId = mediaId })
    end),
  }))
  table.insert(rowChildren, ui.button({
    glyph = "external-link",
    variant = "ghost",
    tooltip = tr("open_anilist"),
    onClick = rowCallback("onOpen", mediaId, function()
      sendCommand("open_media", { mediaId = mediaId, mediaType = entry.mediaType })
    end),
  }))

  return ui.row({
    key = "entry-" .. tostring(mediaId),
    gap = 10,
    align = "center",
    padding = { top = 8, bottom = 8 },
  }, rowChildren)
end

local function renderLibrary()
  local rows = entriesForView()
  local loadingSet = coverLoadingSet()
  local children = {}

  local headerChildren = {
    ui.label({ text = tr("title"), fontSize = 18, fontWeight = "bold" }),
  }
  if snapshot.viewer and snapshot.viewer.name then
    table.insert(headerChildren, ui.label({
      text = tr("logged_in_as", { name = snapshot.viewer.name }),
      fontSize = 12,
      color = "on_surface_variant",
    }))
  end

  table.insert(children, ui.row({ align = "center", justify = "space_between", gap = 8 }, {
    ui.column({ gap = 2, flexGrow = 1 }, headerChildren),
    ui.button({ glyph = "settings", variant = "ghost", tooltip = tr("settings"), onClick = "onOpenSettings" }),
    ui.button({ glyph = "refresh", variant = "ghost", tooltip = tr("refresh"), onClick = "onRefresh" }),
    ui.button({ glyph = "logout", variant = "ghost", tooltip = tr("logout"), onClick = "onLogout" }),
    ui.button({ glyph = "close", variant = "ghost", tooltip = tr("close"), onClick = "onClosePanel" }),
  }))

  table.insert(children, ui.row({ gap = 6 }, {
    ui.button({
      text = tr("tab_anime"),
      variant = if mediaTab == "ANIME" then "primary" else "ghost",
      onClick = "onTabAnime",
    }),
    ui.button({
      text = tr("tab_manga"),
      variant = if mediaTab == "MANGA" then "primary" else "ghost",
      onClick = "onTabManga",
    }),
  }))

  table.insert(children, ui.scroll({ horizontal = true }, {
    ui.row({ gap = 6 }, {
      filterButton(
        "current",
        if mediaTab == "MANGA" then tr("filter_reading") else tr("filter_current"),
        "CURRENT"
      ),
      filterButton(
        "planning",
        if mediaTab == "MANGA" then tr("filter_planning_manga") else tr("filter_planning"),
        "PLANNING"
      ),
      filterButton("completed", tr("filter_completed"), "COMPLETED"),
      filterButton("paused", tr("filter_paused"), "PAUSED"),
      filterButton("dropped", tr("filter_dropped"), "DROPPED"),
      filterButton("repeating", tr("filter_repeating"), "REPEATING"),
      filterButton("all", tr("filter_all"), "ALL"),
    }),
  }))

  if snapshot.loading and not snapshot.viewer then
    table.insert(children, ui.label({ text = tr("loading"), color = "on_surface_variant", padding = { top = 12 } }))
  elseif snapshot.error ~= "" then
    table.insert(children, ui.label({ text = tr("error", { message = snapshot.error }), color = "error", padding = { top = 12 } }))
  elseif snapshot.refreshing then
    table.insert(children, ui.label({ text = tr("refreshing"), color = "on_surface_variant", padding = { top = 8 } }))
  elseif snapshot.busy then
    table.insert(children, ui.label({ text = tr("updating"), color = "on_surface_variant", padding = { top = 8 } }))
  end

  if (not snapshot.loading or snapshot.viewer) and #rows == 0 then
    table.insert(children, ui.label({ text = tr("empty"), color = "on_surface_variant", padding = { top = 12 } }))
  else
    local listChildren = {}
    local rowCap = listRowCap(rows)
    for index = 1, rowCap do
      local entry = rows[index]
      local row = renderEntryRow(entry, index, loadingSet)
      if row then
        table.insert(listChildren, row)
      end
    end
    if visibleRowLimit < rowCap then
      table.insert(listChildren, ui.row({ gap = 8, align = "center", justify = "center", padding = { top = 4, bottom = 4 } }, {
        ui.glyph({ name = "loader", size = 16, color = "on_surface_variant" }),
        ui.label({ text = tr("loading_more"), fontSize = 12, color = "on_surface_variant" }),
      }))
    end
    table.insert(children, ui.scroll({ flexGrow = 1, gap = 8 }, listChildren))
    syncVisibleCoverPriority(rows)
    syncListLoadInterval(rows)
  end

  panel.render(ui.column({ gap = 10, padding = 16, flexGrow = 1 }, children))
end

render = function()
  if coverPreview then
    panel.render(renderCoverPreview())
    dirty = false
    return
  end
  if snapshot.viewer and snapshot.viewer.id then
    renderLibrary()
  else
    renderLogin()
  end
  dirty = false
end

noctalia.state.watch("anilist_snapshot", function(value)
  if type(value) == "table" then
    snapshot = value
    dirty = true
    render()
  end
end)

noctalia.state.watch("anilist_cover_loading", function()
  dirty = true
  render()
end)

panel.setWantsSecondTicks(true)

function onOpen(_context)
  noctalia.state.set("anilist_open", true)
  resetListView()
  if snapshot.viewer and snapshot.viewer.id then
    sendCommand("refresh", { mediaType = mediaTab })
  end
  dirty = true
  render()
end

function onClose()
  coverPreview = nil
  noctalia.state.set("anilist_open", false)
  noctalia.setUpdateInterval(LIST_IDLE_INTERVAL_MS)
end

function update()
  if snapshot.viewer and snapshot.viewer.id then
    local rows = entriesForView()
    if growVisibleRows(rows) then
      dirty = true
    end
    syncListLoadInterval(rows)
  end
  if dirty then
    render()
  end
end

function onClosePanel()
  coverPreview = nil
  panel.close()
end

function onCloseCoverPreview()
  coverPreview = nil
  coverDownloadBusy = false
  dirty = true
  render()
end

function onDownloadCoverPreview()
  if coverPreview then
    startCoverDownload(coverPreview)
  end
end

function onNoop() end

function onOpenSettings()
  noctalia.runAsync("noctalia msg settings-open plugins")
end

function onConnect()
  sendCommand("start_oauth")
  dirty = true
  render()
end

function onLogout()
  sendCommand("logout")
end

function onRefresh()
  sendCommand("refresh", { mediaType = mediaTab })
end

function onTabAnime()
  mediaTab = "ANIME"
  resetListView()
  dirty = true
  render()
end

function onTabManga()
  mediaTab = "MANGA"
  resetListView()
  dirty = true
  render()
end

render()
