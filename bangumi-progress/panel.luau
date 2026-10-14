--!nonstrict
-- Bangumi Progress panel: collection filters, episode controls, completion, and subject links.

local snapshot = noctalia.state.get("bgm_snapshot") or {}

local function configChoice(key, fallback, allowed)
  local value = noctalia.getConfig(key)
  return if allowed[value] then value else fallback
end

local function readAppearance()
  return {
    density = configChoice("appearance_density", "standard", { compact = true, standard = true, comfortable = true }),
    rowStyle = configChoice("collection_row_style", "plain", { plain = true, cards = true }),
    layout = configChoice("collection_layout", "remember", { remember = true, list = true, grid = true }),
    timelineLayout = configChoice("timeline_layout", "remember", { remember = true, list = true, grid = true }),
    timelineDensity = configChoice("timeline_density", "inherit", { inherit = true, compact = true, standard = true, comfortable = true }),
    timelineCovers = noctalia.getConfig("timeline_show_covers") ~= false,
    pageSize = math.clamp(math.floor(tonumber(noctalia.getConfig("collection_page_size")) or 24), 12, 60),
    avatar = noctalia.getConfig("show_profile_avatar") == true,
    identity = noctalia.getConfig("show_profile_identity") == true,
    bio = noctalia.getConfig("show_profile_bio") == true,
    covers = noctalia.getConfig("show_collection_covers") ~= false,
    metadata = noctalia.getConfig("show_collection_metadata") ~= false,
    progressBar = noctalia.getConfig("show_progress_bar") == true,
    emptyDays = noctalia.getConfig("timeline_show_empty_days") == true,
    timelineDetails = noctalia.getConfig("timeline_show_details") == true,
    defaultRange = configChoice("timeline_default_range", "today", { today = true, week = true }),
    defaultFilter = configChoice("timeline_default_filter", "watching", { watching = true, all = true }),
    defaultView = configChoice("panel_default_view", "collections", { collections = true, timeline = true }),
  }
end

local DENSITIES = {
  compact = { columns = 5, cardWidth = 132, coverWidth = 120, coverHeight = 168, cardPadding = 6,
    gap = 6, rowGap = 8, rowPadding = 8, listCoverWidth = 36, listCoverHeight = 50, fontSize = 12, detailSize = 10, actionSize = 26 },
  standard = { columns = 4, cardWidth = 166, coverWidth = 150, coverHeight = 210, cardPadding = 8,
    gap = 8, rowGap = 12, rowPadding = 10, listCoverWidth = 44, listCoverHeight = 62, fontSize = 13, detailSize = 11, actionSize = 32 },
  comfortable = { columns = 3, cardWidth = 224, coverWidth = 208, coverHeight = 291, cardPadding = 8,
    gap = 10, rowGap = 14, rowPadding = 12, listCoverWidth = 52, listCoverHeight = 73, fontSize = 14, detailSize = 12, actionSize = 32 },
}
local appearance = readAppearance()
local density = DENSITIES[appearance.density]
local timelineDensity = DENSITIES[if appearance.timelineDensity == "inherit" then appearance.density else appearance.timelineDensity]
local gridPage = 1
local LAYOUT_FILE = "collection-layout.txt"
local TIMELINE_LAYOUT_FILE = "timeline-layout.txt"

-- The host has no settings writer. Keep this local UI preference separately
-- from service caches and credentials, using the existing file API.
local layoutDir = noctalia.pluginDataDir()
local savedLayout
if layoutDir then
  local ok, value = pcall(noctalia.readFile, layoutDir .. "/" .. LAYOUT_FILE)
  if ok then savedLayout = value end
end
local rememberedLayout = if savedLayout == "grid" then "grid" else "list"
local collectionLayout = if appearance.layout == "remember" then rememberedLayout else appearance.layout
local savedTimelineLayout
if layoutDir then
  local ok, value = pcall(noctalia.readFile, layoutDir .. "/" .. TIMELINE_LAYOUT_FILE)
  if ok then savedTimelineLayout = value end
end
local rememberedTimelineLayout = if savedTimelineLayout == "grid" then "grid" else "list"
local timelineLayout = if appearance.timelineLayout == "remember" then rememberedTimelineLayout else appearance.timelineLayout
local coverRequestSignature = nil
local timelineCoverRequestSignature = nil
local profileRequestSignature = nil

local FILTERS = {
  { type = 3, key = "filter_watching" },
  { type = 1, key = "filter_wish" },
  { type = 2, key = "filter_done" },
  { type = 4, key = "filter_on_hold" },
  { type = 5, key = "filter_dropped" },
}

local activeType = 3
local activeView = appearance.defaultView
local timelineRange = appearance.defaultRange
local timelineFilter = appearance.defaultFilter
local lastLocalDate = os.date("%Y-%m-%d")
local dirty = true
local confirmDisconnect = false
local disconnectEpoch = 0
local accountExpanded = false
local render -- Forward declaration for functions such as setFilter and onOpen.
local ensureSelectedCollection
local pendingCategoryCheck = false
local categoryRequestKey = nil

local function tr(key, subst)
  return noctalia.tr("panel." .. key, subst)
end

local function sendCommand(action, values)
  local command = { action = action }
  if type(values) == "table" then
    for k, v in pairs(values) do
      command[k] = v
    end
  end
  noctalia.state.set("bgm_command", command)
end

local function clearDisconnect()
  confirmDisconnect = false
  disconnectEpoch += 1
end

local function accountIdentity(value)
  local viewer = value.viewer or {}
  return tostring(value.authSource) .. ":" .. tostring(value.authMode) .. ":" .. tostring(viewer.id or viewer.username or "")
end

local function loadProfile()
  if not snapshot.viewer or snapshot.oauthBusy or not noctalia.state.get("bgm_open") then return end
  if not appearance.avatar and not appearance.identity and not appearance.bio then return end
  local signature = accountIdentity(snapshot) .. ":" .. tostring(appearance.avatar) .. ":" .. tostring(appearance.identity) .. ":" .. tostring(appearance.bio)
  if signature == profileRequestSignature then return end
  profileRequestSignature = signature
  sendCommand("load_profile")
end

local function syncAppearance()
  local nextAppearance = readAppearance()
  local changed = false
  for key, value in pairs(nextAppearance) do
    if appearance[key] ~= value then changed = true end
  end
  if not changed then return false end
  if nextAppearance.layout ~= appearance.layout then
    collectionLayout = if nextAppearance.layout == "remember" then rememberedLayout else nextAppearance.layout
    gridPage = 1
  end
  if nextAppearance.timelineLayout ~= appearance.timelineLayout then
    timelineLayout = if nextAppearance.timelineLayout == "remember" then rememberedTimelineLayout else nextAppearance.timelineLayout
  end
  if nextAppearance.pageSize ~= appearance.pageSize then gridPage = 1 end
  if nextAppearance.defaultView ~= appearance.defaultView then activeView = nextAppearance.defaultView end
  if nextAppearance.defaultRange ~= appearance.defaultRange then timelineRange = nextAppearance.defaultRange end
  if nextAppearance.defaultFilter ~= appearance.defaultFilter then timelineFilter = nextAppearance.defaultFilter end
  if nextAppearance.covers ~= appearance.covers then coverRequestSignature = nil end
  if nextAppearance.timelineCovers ~= appearance.timelineCovers then timelineCoverRequestSignature = nil end
  appearance = nextAppearance
  density = DENSITIES[appearance.density]
  timelineDensity = DENSITIES[if appearance.timelineDensity == "inherit" then appearance.density else appearance.timelineDensity]
  return true
end

local function loadCalendar(force)
  local calendar = snapshot.calendar or {}
  if snapshot.oauthBusy or calendar.loading then return end
  -- The service owns cache freshness; loaded data may still need a TTL check.
  sendCommand("load_calendar", { force = force == true })
end

local function setView(view)
  activeView = view
  if view == "timeline" then loadCalendar(false) end
  if view == "collections" then ensureSelectedCollection() end
  dirty = true
  render()
end

-- Calendar reports a reference weekday and premiere date, not an episode time.
-- Use local dates and calendar arithmetic so daylight-saving changes cannot
-- shift the dates shown in the Monday-to-Sunday week.
local function monthLength(year, month)
  if month == 2 then
    return if year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0) then 29 else 28
  end
  return if month == 4 or month == 6 or month == 9 or month == 11 then 30 else 31
end

local function dateParts(value)
  if type(value) ~= "string" then return nil end
  local y, m, d = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  if not y or not m or not d or m < 1 or m > 12 or d < 1 or d > monthLength(y, m) then return nil end
  return y, m, d
end

local function shiftedDate(value, offset)
  local y, m, d = dateParts(value)
  if not y then return value end
  d += offset
  while d < 1 do
    m -= 1
    if m < 1 then y -= 1; m = 12 end
    d += monthLength(y, m)
  end
  while d > monthLength(y, m) do
    d -= monthLength(y, m)
    m += 1
    if m > 12 then y += 1; m = 1 end
  end
  return string.format("%04d-%02d-%02d", y, m, d)
end

local function weekdayOf(value)
  local y, m, d = dateParts(value)
  if not y then return 1 end
  local offsets = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }
  if m < 3 then y -= 1 end
  local sundayZero = (y + math.floor(y / 4) - math.floor(y / 100) + math.floor(y / 400) + offsets[m] + d) % 7
  return if sundayZero == 0 then 7 else sundayZero
end

local function collectionOf(type)
  for _, c in ipairs(snapshot.collections or {}) do
    if c.type == type then
      return c
    end
  end
  return nil
end

-- Selection can change while another read/write or login is in progress.
-- Retain that intent and issue it once the service is ready. A failed request
-- stays visible as an error instead of being retried on every snapshot.
ensureSelectedCollection = function()
  if activeView ~= "collections" or not snapshot.viewer
    or not snapshot.authMode or snapshot.authMode == "none"
    or snapshot.oauthReadOnly == true
    or snapshot.loading or snapshot.refreshing or snapshot.oauthBusy or snapshot.busy then return end
  local collection = collectionOf(activeType)
  local requestKey = accountIdentity(snapshot) .. ":" .. tostring(activeType)
  local hasError = snapshot.error and snapshot.error ~= "" and snapshot.error ~= "empty"
  if not pendingCategoryCheck and (collection and collection.loaded or hasError
    or categoryRequestKey == requestKey) then return end
  -- Set these before sending: the host may immediately publish a snapshot.
  pendingCategoryCheck = false
  categoryRequestKey = requestKey
  sendCommand("load_type", { type = activeType })
end

local function requestVisibleCovers(rows, first, last)
  if not appearance.covers then return end
  local collection = collectionOf(activeType)
  local ids, signatureParts = {}, {accountIdentity(snapshot), collectionLayout, tostring(activeType), tostring(gridPage),
    tostring(collection and collection.fetchedAt)}
  for index = first, last do
    local id = rows[index].subjectId
    table.insert(ids, id)
    table.insert(signatureParts, tostring(id))
  end
  local signature = table.concat(signatureParts, ":")
  if signature == coverRequestSignature then return end
  coverRequestSignature = signature
  -- The service caps each explicit request at 64 and deduplicates local files.
  for start = 1, #ids, 64 do
    local batch = {}
    for index = start, math.min(start + 63, #ids) do table.insert(batch, ids[index]) end
    sendCommand("load_covers", { type = activeType, subjectIds = batch })
  end
end

local function requestTimelineCovers(ids)
  if not appearance.timelineCovers or not noctalia.state.get("bgm_open") or #ids == 0 then return end
  local parts = { accountIdentity(snapshot), tostring((snapshot.calendar or {}).fetchedAt),
    timelineRange, timelineFilter, lastLocalDate }
  for _, id in ipairs(ids) do table.insert(parts, tostring(id)) end
  local signature = table.concat(parts, ":")
  if signature == timelineCoverRequestSignature then return end
  timelineCoverRequestSignature = signature
  for start = 1, #ids, 64 do
    local batch = {}
    for index = start, math.min(start + 63, #ids) do table.insert(batch, ids[index]) end
    sendCommand("load_calendar_covers", { subjectIds = batch })
  end
end

local function errorText(code)
  if code == "not_configured" then
    return tr("not_configured")
  elseif code == "unauthorized" then
    return tr(if snapshot.authSource == "oauth" then "oauth_unauthorized" else "unauthorized")
  elseif code == "forbidden" then
    return tr(if snapshot.authSource == "oauth" then "oauth_forbidden" else "forbidden")
  elseif code == "network" then
    return tr("network_error")
  elseif code == "parse" then
    return tr("parse_error")
  elseif code == "busy" then
    return tr("busy")
  elseif code == "episodes_unavailable" then
    return tr("episodes_unavailable")
  elseif code == "no_next_episode" then
    return tr("no_next_episode")
  elseif code == "no_prev_episode" then
    return tr("no_prev_episode")
  elseif code and code:sub(1, 4) == "http" then
    return tr("http_error", { status = code:gsub("http_", "") })
  end
  return tr("unknown_error")
end

local function setFilter(type)
  activeType = type
  gridPage = 1
  -- Loaded categories can expire too; the service owns their TTL.
  pendingCategoryCheck = true
  categoryRequestKey = nil
  ensureSelectedCollection()
  dirty = true
  render()
end

local function progressText(row)
  local current = row.epStatus or 0
  local total = row.eps or 0
  local aired = row.airedEp
  if aired == nil and total > 0 and current >= total then
    aired = total
  end
  if aired ~= nil and total > 0 then
    return tr("progress_aired", { current = current, aired = aired, total = total })
  end
  if total > 0 then
    return tr("progress", { current = current, total = total })
  end
  return tr("progress_unknown", { current = current })
end

local function subtitleText(row)
  local parts = { progressText(row) }
  if appearance.metadata and row.rate and row.rate > 0 then
    table.insert(parts, tr("score", { score = row.rate }))
  end
  if appearance.metadata and row.date and row.date ~= "" then
    table.insert(parts, row.date)
  end
  return table.concat(parts, " · ")
end

-- Keep optional nodes in a dense array: a nil first child must not hide the
-- text and controls when users turn off covers or the avatar.
local function childrenWithOptions(...)
  local children = {}
  for index = 1, select("#", ...) do
    local child = select(index, ...)
    if child then table.insert(children, child) end
  end
  return children
end

local function renderCover(row, width, height)
  height = height or density.listCoverHeight
  if row.coverPath then
    return ui.image({
      key = "cover-" .. tostring(row.subjectId),
      path = row.coverPath,
      width = width,
      height = height,
      radius = 6,
      fit = "cover",
    })
  end
  return ui.column({
    width = width,
    minWidth = if type(width) == "number" then width else 0,
    height = height,
    radius = 6,
    fill = "surface_variant",
    align = "center",
    justify = "center",
  }, {
    ui.glyph({ name = "device-tv", size = 14, color = "on_surface_variant" }),
  })
end

local function canUpdateProgress()
  return snapshot.authMode == "token" and snapshot.canWrite ~= false
    and not snapshot.oauthBusy and not snapshot.busy
    and not snapshot.loading and not snapshot.refreshing
    and (snapshot.authSource ~= "oauth" or not snapshot.oauthExpiresAt
      or os.time() < snapshot.oauthExpiresAt)
end

-- Use one scroll viewport for all panel sections. Its built-in inset and
-- scrollbar gutter must affect navigation and cards together.
local function panelFrame(children)
  return ui.column({ key = "panel-frame", padding = 16, flexGrow = 1, align = "stretch" }, {
    ui.scroll({ key = "panel-scroll", flexGrow = 1, paddingH = 0, paddingV = 0, align = "stretch" }, {
      ui.column({ key = "panel-content", gap = 12, align = "stretch" }, children),
    }),
  })
end

local function markerSlot(marker, size)
  return ui.column({ width = size, height = size, align = "center", justify = "center" }, childrenWithOptions(marker))
end

local function renderRow(row)
  local canWrite = canUpdateProgress()
  local plain = appearance.rowStyle == "plain"
  local originalSize = plain and appearance.density == "standard"
  local subjectId = row.subjectId
  local current, total = row.epStatus or 0, row.eps or 0
  local isDone = total > 0 and current >= total
  local hasNew = (row.newlyUnwatched or 0) > 0
  local marker = if hasNew then ui.box({ width = 7, height = 7, radius = 4, fill = "error" })
    elseif isDone then ui.glyph({ name = "check", size = 13, color = "primary" }) else nil
  local titleChildren = {}
  table.insert(titleChildren, ui.label({ text = row.title or "?", fontSize = density.fontSize,
    fontWeight = "medium", maxLines = 1, flexGrow = 1,
    color = if isDone then "primary" else "on_surface" }))
  table.insert(titleChildren, markerSlot(marker, 14))
  local subtitle = subtitleText(row)
  if hasNew then subtitle = subtitle .. " · " .. tr("newly_unwatched", { count = row.newlyUnwatched }) end
  local details = {
    ui.row({ gap = 6, align = "center" }, titleChildren),
    ui.label({ text = subtitle, fontSize = density.detailSize, color = if hasNew then "primary" else "on_surface_variant", maxLines = 1 }),
  }
  if appearance.progressBar and total > 0 then
    table.insert(details, ui.progress({ progress = math.clamp(current / total, 0, 1), height = 4, radius = 2 }))
  end
  return ui.row({ key = "entry-" .. tostring(subjectId), gap = 12, align = "center",
    paddingH = if plain then 0 else density.rowPadding, paddingV = if plain then 6 else density.rowPadding,
    radius = if plain then 0 else 8, fill = if plain then "#00000000" else "surface_variant" }, childrenWithOptions(
    if appearance.covers then renderCover(row, if originalSize then 40 else density.listCoverWidth,
      if originalSize then 56 else density.listCoverHeight) else nil,
    ui.column({ key = "entry-details-" .. tostring(subjectId), gap = density.gap - 3, width = 0, flexGrow = 1, minWidth = 0, align = "stretch", justify = "center" }, details),
    ui.row({ key = "entry-actions-" .. tostring(subjectId), width = 140, height = 32, gap = 4, align = "center" }, {
      ui.button({ glyph = "minus", width = 32, height = 32, variant = "ghost", tooltip = tr("ep_decrement"), enabled = canWrite and current > 0,
        onClick = (current > 0 and canWrite) and function() sendCommand("decrement", { subjectId = subjectId }) end or "onNoop" }),
      ui.button({ glyph = "plus", width = 32, height = 32, variant = "ghost", tooltip = tr("ep_increment"), enabled = canWrite,
        onClick = canWrite and function() sendCommand("increment", { subjectId = subjectId }) end or "onNoop" }),
      ui.button({ glyph = if isDone then "check" else "circle-check", width = 32, height = 32,
        variant = if isDone then "primary" else "ghost", tooltip = tr("mark_done"), enabled = canWrite,
        onClick = not canWrite and "onNoop" or function() sendCommand("complete", { subjectId = subjectId }) end }),
      ui.button({ glyph = "external-link", width = 32, height = 32, variant = "ghost", tooltip = tr("open"),
        onClick = function() sendCommand("open_subject", { subjectId = subjectId }) end }),
    })
  ))
end

local function renderGridCard(row)
  local canWrite = canUpdateProgress()
  local subjectId = row.subjectId
  local current, total = row.epStatus or 0, row.eps or 0
  local isDone = total > 0 and current >= total
  local hasNew = (row.newlyUnwatched or 0) > 0
  local detail = if total > 0 then tr("grid_progress", { current = current, total = total })
    else tr("grid_progress_unknown", { current = current })
  local marker = if hasNew then ui.box({ width = 6, height = 6, radius = 3, fill = "error" })
    elseif isDone then ui.glyph({ name = "check", size = 12, color = "primary" }) else nil
  local progressChildren = {}
  table.insert(progressChildren, ui.label({ text = detail, fontSize = density.detailSize, maxLines = 1, flexGrow = 1,
    color = if hasNew then "primary" else "on_surface_variant" }))
  table.insert(progressChildren, markerSlot(marker, 12))
  local children = childrenWithOptions(
    if appearance.covers then renderCover(row, nil, density.coverHeight) else nil,
    ui.column({ key = "grid-title-slot-" .. tostring(subjectId), height = 48, minHeight = 48,
      align = "stretch", justify = "start" }, {
      ui.label({ key = "grid-title-" .. tostring(subjectId), text = row.title or "?", fontSize = density.fontSize - 1,
        fontWeight = "medium", maxLines = 2,
        color = if isDone then "primary" else "on_surface" }),
    }),
    ui.row({ gap = 4, align = "center", height = 24 }, progressChildren),
    ui.column({ height = 4, minHeight = 4, align = "stretch" }, childrenWithOptions(
      if appearance.progressBar then ui.progress({ progress = if total > 0 then math.clamp(current / total, 0, 1) else 0, height = 4, radius = 2 }) else nil
    )),
    ui.row({ key = "grid-actions-" .. tostring(subjectId), gap = 2, align = "center", justify = "center" }, {
      ui.button({ glyph = "minus", width = 0, flexGrow = 1, height = 32, variant = "ghost", tooltip = tr("ep_decrement"), enabled = canWrite and current > 0,
        onClick = (current > 0 and canWrite) and function() sendCommand("decrement", { subjectId = subjectId }) end or "onNoop" }),
      ui.button({ glyph = "plus", width = 0, flexGrow = 1, height = 32, variant = "ghost", tooltip = tr("ep_increment"), enabled = canWrite,
        onClick = canWrite and function() sendCommand("increment", { subjectId = subjectId }) end or "onNoop" }),
      ui.button({ glyph = if isDone then "check" else "circle-check", width = 0, flexGrow = 1, height = 32,
        variant = if isDone then "primary" else "ghost", tooltip = tr("mark_done"), enabled = canWrite,
        onClick = not canWrite and "onNoop" or function() sendCommand("complete", { subjectId = subjectId }) end }),
      ui.button({ glyph = "external-link", width = 0, flexGrow = 1, height = 32, variant = "ghost", tooltip = tr("open"),
        onClick = function() sendCommand("open_subject", { subjectId = subjectId }) end }),
    })
  )
  return ui.column({ key = "grid-entry-" .. tostring(subjectId), width = 0, flexGrow = 1, minWidth = 0,
    gap = density.gap - 2, padding = density.cardPadding, radius = 8, fill = "surface_variant", align = "stretch" }, children)
end

local function setCollectionLayout(layout)
  if layout == collectionLayout then return end
  collectionLayout = layout
  rememberedLayout = layout
  gridPage = 1
  if layoutDir then
    pcall(function()
      noctalia.mkdirAll(layoutDir)
      noctalia.writeFile(layoutDir .. "/" .. LAYOUT_FILE, layout)
    end)
  end
  dirty = true
  render()
end

local function setTimelineLayout(layout)
  if layout == timelineLayout then return end
  timelineLayout = layout
  rememberedTimelineLayout = layout
  if layoutDir then
    pcall(function()
      noctalia.mkdirAll(layoutDir)
      noctalia.writeFile(layoutDir .. "/" .. TIMELINE_LAYOUT_FILE, layout)
    end)
  end
  dirty = true
  render()
end

local function timelineDetailText(row, watching)
  local detail = if watching then progressText(watching) else ""
  if appearance.timelineDetails then
    local premiere = if dateParts(row.airDate) then tr("timeline_premiere", { date = row.airDate }) else tr("timeline_premiere_unknown")
    detail = if detail ~= "" then detail .. " · " .. premiere else premiere
  end
  return detail
end

local function renderTimelineGridCard(row, watching)
  local density = timelineDensity
  local cover = if watching and watching.coverPath then watching else row
  local detail = timelineDetailText(row, watching)
  return ui.column({ key = "timeline-grid-entry-" .. tostring(row.subjectId), width = 0, flexGrow = 1,
    minWidth = 0, gap = density.gap - 2, padding = density.cardPadding,
    radius = 8, fill = "surface", align = "stretch" }, childrenWithOptions(
    if appearance.timelineCovers then renderCover(cover, nil, density.coverHeight) else nil,
    ui.column({ key = "timeline-grid-title-slot-" .. tostring(row.subjectId), height = 48, minHeight = 48,
      align = "stretch", justify = "start" }, {
      ui.label({ text = row.title or row.nameCn or row.name or "?", fontSize = density.fontSize - 1,
        fontWeight = "medium", maxLines = 2 }),
    }),
    ui.column({ key = "timeline-grid-detail-slot-" .. tostring(row.subjectId),
      height = 40, minHeight = 40,
      align = "stretch", justify = "start" }, childrenWithOptions(
      if detail ~= "" then ui.label({ text = detail, fontSize = density.detailSize,
        color = "on_surface_variant", maxLines = 2 }) else nil
    )),
    ui.row({ align = "center", justify = "center" }, {
      ui.button({ glyph = "external-link", width = 32, height = 32,
        variant = "ghost", tooltip = tr("open"),
        onClick = function() sendCommand("open_subject", { subjectId = row.subjectId }) end }),
    })
  ))
end

local function renderTimelineRow(row, watching)
  local density = timelineDensity
  local cover = if watching and watching.coverPath then watching else row
  local details = { ui.label({ text = row.title or row.nameCn or row.name or "?", fontSize = density.fontSize,
    fontWeight = "medium", maxLines = 1 }) }
  local detail = timelineDetailText(row, watching)
  if detail ~= "" then table.insert(details, ui.label({ text = detail, fontSize = density.detailSize,
    color = "on_surface_variant", maxLines = 1 })) end
  return ui.row({ key = "timeline-entry-" .. tostring(row.subjectId), gap = density.rowGap, align = "center",
    padding = density.rowPadding, radius = 8, fill = "surface" }, childrenWithOptions(
    if appearance.timelineCovers then renderCover(cover, density.listCoverWidth, density.listCoverHeight) else nil,
    ui.column({ key = "timeline-entry-details-" .. tostring(row.subjectId), gap = density.gap - 3, width = 0, flexGrow = 1, minWidth = 0, align = "stretch", justify = "center" }, details),
    ui.button({ glyph = "external-link", width = 32, height = 32, variant = "ghost", tooltip = tr("open"),
      onClick = function() sendCommand("open_subject", { subjectId = row.subjectId }) end })
  ))
end

local function selectedOption(index, values)
  if type(index) ~= "string" and type(index) ~= "number" then return nil end
  local parsed = tonumber(index)
  if not parsed or parsed ~= math.floor(parsed) or parsed < 0 or parsed >= #values then return nil end
  return values[parsed + 1]
end

local function renderTimeline()
  local density = timelineDensity
  local children = { ui.row({ key = "timeline-controls", gap = 12, align = "center" }, {
    ui.column({ gap = 4, flexGrow = 1, minWidth = 0, align = "stretch" }, {
      ui.label({ text = tr("timeline_dates"), fontSize = 11, color = "on_surface_variant" }),
      ui.select({ key = "timeline-range", height = 32, controlSize = "sm",
        options = { tr("timeline_today"), tr("timeline_week") }, selectedIndex = if timelineRange == "today" then 0 else 1,
        onChange = function(index)
          local range = selectedOption(index, { "today", "week" })
          if range and range ~= timelineRange then timelineRange = range; dirty = true; render() end
        end }),
    }),
    ui.column({ gap = 4, flexGrow = 1, minWidth = 0, align = "stretch" }, {
      ui.label({ text = tr("timeline_titles"), fontSize = 11, color = "on_surface_variant" }),
      ui.select({ key = "timeline-filter", height = 32, controlSize = "sm",
        options = { tr("timeline_watching"), tr("timeline_all") }, selectedIndex = if timelineFilter == "watching" then 0 else 1,
        onChange = function(index)
          local filter = selectedOption(index, { "watching", "all" })
          if filter and filter ~= timelineFilter then timelineFilter = filter; dirty = true; render() end
        end }),
    }),
    ui.row({ width = 68, height = 52, gap = 4, align = "end" }, {
      ui.button({ key = "timeline-layout-list", glyph = "list", width = 32, height = 32,
        tooltip = tr("layout_list"), selected = timelineLayout == "list",
        variant = if timelineLayout == "list" then "primary" else "ghost",
        onClick = function() setTimelineLayout("list") end }),
      ui.button({ key = "timeline-layout-grid", glyph = "layout-grid", width = 32, height = 32,
        tooltip = tr("layout_grid"), selected = timelineLayout == "grid",
        variant = if timelineLayout == "grid" then "primary" else "ghost",
        onClick = function() setTimelineLayout("grid") end }),
    }),
  }) }
  local content = {}
  local coverIds = {}
  local calendar = snapshot.calendar or {}
  if calendar.loading then
    table.insert(content, ui.label({ text = tr("timeline_loading"), color = "on_surface_variant" }))
  end
  if calendar.error and calendar.error ~= "" then
    table.insert(content, ui.row({ gap = 6, align = "center" }, {
      ui.label({ text = tr("timeline_error", { error = errorText(calendar.error) }),
        color = "error", flexGrow = 1, maxLines = 2 }),
      ui.button({ height = 32, contentAlign = "center", text = tr("timeline_retry"), variant = "ghost",
        onClick = function() loadCalendar(true) end }),
    }))
  end
  if calendar.loaded and (appearance.timelineDetails or (calendar.error and calendar.error ~= "")) then
    local fetchedAt = tonumber(calendar.fetchedAt)
    local updated = if fetchedAt and fetchedAt > 0 then os.date("%Y-%m-%d %H:%M", fetchedAt) else tr("timeline_update_unknown")
    table.insert(content, ui.label({ text = tr(if calendar.error and calendar.error ~= "" then "timeline_cached" else "timeline_updated",
      { date = updated }), fontSize = 11, color = "on_surface_variant" }))
  end

  local watching = collectionOf(3)
  local watchingReady = watching and watching.loaded == true
  local watchingById = {}
  for _, row in ipairs(if watchingReady then watching.rows or {} else {}) do
    watchingById[tostring(row.subjectId)] = row
  end
  if timelineFilter == "watching" and not watchingReady then
    local collectionError = snapshot.error and snapshot.error ~= "" and snapshot.error ~= "empty"
    table.insert(content, ui.label({
      text = if collectionError then tr("timeline_watching_error", { error = errorText(snapshot.error) })
        elseif snapshot.loading then tr("timeline_watching_loading") else tr("timeline_watching_unloaded"),
      color = if collectionError then "error" else "on_surface_variant", maxLines = 3,
    }))
  end

  if calendar.loaded then
    local today = os.date("%Y-%m-%d")
    local todayWeekday = weekdayOf(today)
    local monday = shiftedDate(today, 1 - todayWeekday)
    local daysByWeekday, scheduled = {}, {}
    for _, day in ipairs(calendar.days or {}) do
      daysByWeekday[day.weekday] = day.rows or {}
      for _, row in ipairs(day.rows or {}) do scheduled[tostring(row.subjectId)] = true end
    end
    if appearance.timelineDetails and watchingReady and timelineFilter == "watching" then
      local unlisted = 0
      for id in pairs(watchingById) do if not scheduled[id] then unlisted += 1 end end
      if unlisted > 0 then
        table.insert(content, ui.label({ text = tr("timeline_unlisted", { count = unlisted }),
          fontSize = 10, color = "on_surface_variant", maxLines = 2 }))
      end
    end
    local total = 0
    if timelineFilter == "all" or watchingReady then
      local first = if timelineRange == "today" then todayWeekday else 1
      local last = if timelineRange == "today" then todayWeekday else 7
      for weekday = first, last do
        local date = shiftedDate(monday, weekday - 1)
        local rows = {}
        for _, row in ipairs(daysByWeekday[weekday] or {}) do
          local accountRow = watchingById[tostring(row.subjectId)]
          if (timelineFilter == "all" or accountRow) and (not dateParts(row.airDate) or row.airDate <= date) then
            table.insert(rows, { row = row, watching = accountRow })
            table.insert(coverIds, row.subjectId)
          end
        end
        total += #rows
        if #rows > 0 or appearance.emptyDays then
          local heading = tr("timeline_day", { day = tr("timeline_weekday_" .. tostring(weekday)), date = date, count = #rows })
          local dayChildren = { ui.row({ key = "timeline-day-heading-" .. tostring(weekday), gap = 8,
            align = "center", tooltip = heading }, childrenWithOptions(
            ui.column({ key = "timeline-day-identity-" .. tostring(weekday), flexGrow = 1,
              minWidth = 0, gap = 2, align = "stretch" }, {
              ui.label({ key = "timeline-day-label-" .. tostring(weekday), text = tr("timeline_weekday_" .. tostring(weekday)),
                fontSize = density.fontSize + 1, maxLines = 1, fontWeight = "bold",
                color = if date == today then "primary" else "on_surface" }),
              ui.label({ key = "timeline-day-date-" .. tostring(weekday), text = date,
                fontSize = density.detailSize, color = "on_surface_variant", maxLines = 1 }),
            }),
            ui.column({ key = "timeline-day-count-" .. tostring(weekday), paddingH = 8, paddingV = 4,
              radius = 6, fill = "surface_variant", align = "center", justify = "center" }, {
              ui.label({ text = tr(if #rows == 1 then "timeline_day_count_one" else "timeline_day_count_many", { count = #rows }),
                fontSize = density.detailSize, color = "on_surface_variant", maxLines = 1 }),
            }),
            if date == today then ui.column({ paddingH = 8, paddingV = 4, radius = 6,
              fill = "primary/0.12", align = "center", justify = "center" }, {
              ui.label({ key = "timeline-today-marker", text = tr("timeline_today"),
                fontSize = density.detailSize, fontWeight = "bold", color = "primary", maxLines = 1 }),
            }) else nil
          )) }
          if #rows > 0 then
            local entries = {}
            if timelineLayout == "grid" then
              for start = 1, #rows, density.columns do
                local cards = {}
                for index = start, math.min(start + density.columns - 1, #rows) do
                  table.insert(cards, renderTimelineGridCard(rows[index].row, rows[index].watching))
                end
                for _ = #cards + 1, density.columns do
                  table.insert(cards, ui.spacer({ width = 0, flexGrow = 1 }))
                end
                table.insert(entries, ui.row({ key = "timeline-grid-row-" .. tostring(weekday) .. "-" .. tostring(start),
                  gap = density.gap, align = "start" }, cards))
              end
            else
              for _, entry in ipairs(rows) do table.insert(entries, renderTimelineRow(entry.row, entry.watching)) end
            end
            table.insert(dayChildren, ui.column({ gap = density.gap - 2, align = "stretch" }, entries))
          end
          -- Every date is a single card; header and nested entries share its
          -- numeric inset in both layouts, including optional empty dates.
          table.insert(content, ui.column({ key = "timeline-day-" .. tostring(weekday), gap = 12,
            padding = 12, radius = 12, fill = "surface_variant/0.35",
            border = if date == today then "primary/0.45" else "on_surface_variant/0.18",
            borderWidth = 1, align = "stretch" }, dayChildren))
        end
      end
      if total == 0 then
        table.insert(content, ui.label({ text = tr(if timelineFilter == "watching" then "timeline_empty_watching" else "timeline_empty_calendar"),
          color = "on_surface_variant", maxLines = 3 }))
      end
    end
  elseif not calendar.loading and (not calendar.error or calendar.error == "") then
    table.insert(content, ui.label({ text = tr("timeline_unloaded"), color = "on_surface_variant" }))
  end
  requestTimelineCovers(coverIds)
  table.insert(children, ui.column({ key = "timeline-scroll", gap = density.gap, align = "stretch" }, content))
  return ui.column({ key = "timeline-content", gap = 12, align = "stretch" }, children)
end

local OAUTH_ERRORS = {
  oauth_not_configured = true,
  oauth_unavailable = true,
  browser_open_failed = true,
  callback_port_in_use = true,
  oauth_timeout = true,
  oauth_cancelled = true,
  oauth_exchange_failed = true,
  oauth_invalid_grant = true,
  oauth_profile_failed = true,
  oauth_storage_error = true,
  oauth_client_changed = true,
  oauth_busy = true,
  oauth_unknown_error = true,
  oauth_network = true,
  oauth_internal_error = true,
  oauth_invalid_attempt = true,
  oauth_access_denied = true,
  oauth_network_error = true,
  oauth_not_authenticated = true,
}

local function renderAuthControls(initial)
  local controls, actions = {}, {}
  if snapshot.oauthBusy or snapshot.busy then clearDisconnect() end
  if snapshot.oauthBusy then
    local waitingForBrowser = snapshot.oauthOperation == "login"
    table.insert(controls, ui.row({ key = "auth-waiting", gap = 8, align = "center" }, {
      ui.label({ key = "auth-waiting-text", text = tr(if waitingForBrowser then "oauth_waiting" else "oauth_working"),
        fontSize = 12, color = "on_surface_variant", flexGrow = 1, maxLines = 3 }),
      if waitingForBrowser then ui.button({ height = 32, contentAlign = "center", text = tr("oauth_cancel"), variant = "ghost",
        onClick = function() sendCommand("oauth_cancel") end }) else nil,
    }))
  else
    table.insert(actions, ui.button({
      flexGrow = if initial then 0 else 1, height = 32, contentAlign = "center",
      text = tr(if snapshot.authSource == "oauth" then "oauth_sign_in_again" else "oauth_sign_in"),
      variant = if snapshot.authSource == "oauth" then "ghost" else "primary",
      onClick = function() clearDisconnect(); sendCommand("oauth_login") end,
    }))
    if snapshot.authSource == "oauth" then
      if snapshot.oauthError and snapshot.oauthError ~= "" and snapshot.oauthCanRetry then
        table.insert(actions, ui.button({ height = 32, contentAlign = "center", text = tr("oauth_retry_refresh"), variant = "ghost",
          onClick = function() clearDisconnect(); sendCommand("oauth_refresh") end }))
      end
      table.insert(actions, ui.button({ height = 32, contentAlign = "center", text = tr("oauth_disconnect"), variant = "ghost",
        onClick = snapshot.busy and "onNoop" or function()
          if snapshot.authSource == "oauth" and not snapshot.oauthBusy and not snapshot.busy then
            clearDisconnect()
            confirmDisconnect = true
            render()
          end
        end,
      }))
    end
    table.insert(actions, ui.button({ height = 32, contentAlign = "center", text = tr("oauth_manual_settings"), variant = "ghost", onClick = "onSettings" }))
    table.insert(controls, ui.row({ key = "auth-actions", gap = 6, align = "center", justify = if initial then "center" else "start" }, actions))
  end
  if confirmDisconnect and snapshot.authSource == "oauth" then
    local confirmationEpoch = disconnectEpoch
    table.insert(controls, ui.label({ key = "auth-disconnect-hint", text = tr("oauth_disconnect_hint"), fontSize = 11,
      color = "on_surface_variant", maxLines = 3 }))
    table.insert(controls, ui.row({ key = "auth-confirmation", gap = 8, align = "center" }, {
      ui.button({ height = 32, contentAlign = "center", text = tr("oauth_keep_signed_in"), variant = "ghost",
        onClick = function() clearDisconnect(); render() end }),
      ui.button({ height = 32, contentAlign = "center", text = tr("oauth_confirm_disconnect"), variant = "ghost",
        onClick = function()
          if confirmationEpoch ~= disconnectEpoch then return end
          local canDisconnect = confirmDisconnect and snapshot.authSource == "oauth"
            and not snapshot.oauthBusy and not snapshot.busy
          clearDisconnect()
          if canDisconnect then sendCommand("oauth_logout") end
          render()
        end }),
    }))
  end
  if snapshot.oauthReadOnly then
    table.insert(controls, ui.label({ key = "auth-read-only", text = tr("oauth_cached_read_only"),
      fontSize = 12, color = "on_surface_variant", maxLines = 3 }))
  end
  if snapshot.oauthError and snapshot.oauthError ~= "" then
    local key = if OAUTH_ERRORS[snapshot.oauthError] then snapshot.oauthError else "oauth_unknown_error"
    table.insert(controls, ui.label({ key = "auth-error", text = tr(key), fontSize = 12, color = "error", maxLines = 3 }))
  end
  return ui.column({ key = "account-controls", flexGrow = 0, gap = 8, padding = if initial then 0 else 10, radius = 8,
    fill = if initial then nil else "surface_variant" }, controls)
end

local function renderNotConfigured()
  return ui.column({ key = "welcome", gap = 16, padding = 32, flexGrow = 1, align = "center", justify = "center" }, {
    ui.glyph({ name = "device-tv", size = 36, color = "primary" }),
    ui.label({ text = tr("title"), fontSize = 20, fontWeight = "bold", textAlign = "center" }),
    ui.label({ text = tr("not_configured_hint"), fontSize = 13, color = "on_surface_variant", textAlign = "center", maxLines = 4 }),
    renderAuthControls(true),
  })
end

local function renderContent()
  local children = {}
  local refreshBusy = snapshot.oauthBusy or (if activeView == "timeline" then (snapshot.calendar or {}).loading else snapshot.busy)

  local viewer = snapshot.viewer or {}
  local username = if type(viewer.username) == "string" then viewer.username else ""
  local nickname = if type(viewer.nickname) == "string" and viewer.nickname ~= "" then viewer.nickname
    elseif username ~= "" then username else tr("title")
  local showProfile = appearance.avatar or appearance.identity or appearance.bio
  local heading = { ui.label({ key = "plugin-title", text = tr("title"), fontSize = 18, fontWeight = "bold", maxLines = 1 }) }
  if not showProfile and snapshot.viewer then
    table.insert(heading, ui.label({ key = "account-summary", fontSize = 12, color = "on_surface_variant", maxLines = 1,
      text = if snapshot.authMode == "token" then tr("logged_in_as", { name = nickname, username = username })
        else tr("public_view", { username = username }) }))
  end
  table.insert(children, ui.row({ key = "panel-header", align = "center", gap = 8 }, {
    markerSlot(ui.glyph({ name = "device-tv", size = 22, color = "primary" }), 32),
    ui.column({ key = "plugin-heading", gap = 2, width = 0, flexGrow = 1, minWidth = 0 }, heading),
    ui.button({ text = tr("account"), height = 32, contentAlign = "center", variant = if accountExpanded then "primary" else "ghost",
      onClick = function() accountExpanded = not accountExpanded; clearDisconnect(); render() end }),
    ui.button({ key = "panel-settings", glyph = "settings", width = 32, height = 32,
      variant = "ghost", tooltip = tr("settings"), onClick = "onSettings" }),
    ui.button({ glyph = "refresh", width = 32, height = 32,
      variant = if refreshBusy then "primary" else "ghost",
      tooltip = if refreshBusy then tr("updating") else tr("refresh"),
      onClick = refreshBusy and "onNoop" or "onRefresh" }),
  }))

  if showProfile then
    local profileChildren = { ui.label({ key = "profile-nickname", text = nickname, fontSize = density.fontSize + 3,
      fontWeight = "bold", maxLines = 1 }) }
    if appearance.identity then
      local identity = {}
      if username ~= "" then table.insert(identity, "@" .. username) end
      if viewer.id then table.insert(identity, "#" .. tostring(viewer.id)) end
      if #identity > 0 then table.insert(profileChildren, ui.label({ key = "profile-identity", text = table.concat(identity, " · "),
        fontSize = density.detailSize, color = "on_surface_variant", maxLines = 1 })) end
    end
    if appearance.bio and type(viewer.bio) == "string" and viewer.bio ~= "" then
      table.insert(profileChildren, ui.label({ key = "profile-bio", text = viewer.bio,
        fontSize = density.detailSize, color = "on_surface_variant", maxLines = 2 }))
    end
    local avatarSize = 56
    local avatar
    if appearance.avatar and snapshot.viewer then
      avatar = if type(viewer.avatarPath) == "string" and viewer.avatarPath:sub(1, 1) == "/" then
        ui.image({ key = "profile-avatar", path = viewer.avatarPath, width = avatarSize, height = avatarSize, radius = avatarSize / 2, fit = "cover" })
        else ui.column({ key = "profile-avatar-fallback", width = avatarSize, minWidth = avatarSize, height = avatarSize,
          radius = avatarSize / 2, fill = "surface_variant", align = "center", justify = "center" }, {
          ui.glyph({ name = "user", size = density.fontSize + 6, color = "on_surface_variant" }),
        })
    end
    table.insert(children, ui.row({ key = "profile-header", align = "center", gap = 12 }, childrenWithOptions(
      avatar,
      ui.column({ key = "profile-details", gap = 3, width = 0, flexGrow = 1, minWidth = 0 }, profileChildren)
    )))
  end
  if accountExpanded or snapshot.oauthBusy or (snapshot.oauthError and snapshot.oauthError ~= "") then
    table.insert(children, renderAuthControls(false))
  end

  table.insert(children, ui.row({ key = "main-navigation", gap = 0, padding = 0, radius = 8, fill = "surface_variant" }, {
    ui.button({ key = "main-navigation-collections", width = 0, flexGrow = 1, height = 38, contentAlign = "center", text = tr("view_collections"), variant = if activeView == "collections" then "primary" else "ghost",
      onClick = function() setView("collections") end }),
    ui.button({ key = "main-navigation-timeline", width = 0, flexGrow = 1, height = 38, contentAlign = "center", text = tr("view_timeline"), variant = if activeView == "timeline" then "primary" else "ghost",
      onClick = function() setView("timeline") end }),
  }))
  if activeView == "timeline" then
    table.insert(children, renderTimeline())
    return panelFrame(children)
  end

  -- Collection status is secondary to the main Collections / Timeline navigation.
  local filterButtons = {}
  for _, filter in ipairs(FILTERS) do
    local collection = collectionOf(filter.type)
    local label = tr(filter.key)
    if collection and collection.total and collection.total > 0 then label = label .. " " .. tostring(collection.total) end
    local selected = filter.type == activeType
    table.insert(filterButtons, ui.button({ key = "collection-status-" .. tostring(filter.type),
      width = 0, flexGrow = 1, height = 32, fontSize = 12, contentAlign = "center", text = label, variant = if selected then "primary" else "ghost", selected = selected,
      controlSize = "sm", onClick = function()
        local current = collectionOf(filter.type)
        local failedUnloaded = (not current or not current.loaded)
          and snapshot.error and snapshot.error ~= "" and snapshot.error ~= "empty"
        if filter.type ~= activeType or failedUnloaded then setFilter(filter.type) end
      end }))
  end
  -- Give status labels their own width; layout controls share the page toolbar.
  table.insert(children, ui.row({ key = "collection-controls", gap = 4, height = 32, align = "center" }, filterButtons))
  local layoutControls = ui.row({ width = 68, height = 32, gap = 4, align = "center" }, {
    ui.button({ key = "collection-layout-list", glyph = "list", width = 32, height = 32,
      tooltip = tr("layout_list"), selected = collectionLayout == "list",
      variant = if collectionLayout == "list" then "primary" else "ghost",
      onClick = function() setCollectionLayout("list") end }),
    ui.button({ key = "collection-layout-grid", glyph = "layout-grid", width = 32, height = 32,
      tooltip = tr("layout_grid"), selected = collectionLayout == "grid",
      variant = if collectionLayout == "grid" then "primary" else "ghost",
      onClick = function() setCollectionLayout("grid") end }),
  })

  -- Status message
  if snapshot.loading then
    table.insert(children, ui.label({ text = tr("loading"), color = "on_surface_variant" }))
  elseif snapshot.error and snapshot.error ~= "" and snapshot.error ~= "empty" then
    table.insert(children, ui.label({ text = errorText(snapshot.error), color = "error" }))
  end

  -- Entry list
  local collection = collectionOf(activeType)
  local rows = collection and collection.rows or {}
  if #rows == 0 then
    table.insert(children, ui.row({ key = "collection-toolbar", gap = 4, height = 32, align = "center" }, {
      ui.spacer({ flexGrow = 1 }), layoutControls,
    }))
    if not snapshot.loading and (not snapshot.error or snapshot.error == "" or snapshot.error == "empty") then
      table.insert(children, ui.label({ text = tr(if collection and collection.loaded then "empty" else "loading"), color = "on_surface_variant" }))
    end
  else
    local displayRows = {}
    local originalIndex = {}
    for index, row in ipairs(rows) do
      table.insert(displayRows, row)
      originalIndex[row] = index
    end
    table.sort(displayRows, function(a, b)
      local aNew = (a.newlyUnwatched or 0) > 0
      local bNew = (b.newlyUnwatched or 0) > 0
      if aNew ~= bNew then
        return aNew
      end
      return originalIndex[a] < originalIndex[b]
    end)
    local listChildren = {}
    -- Bound both layouts to one page: the host caps container children, and
    -- only this page needs covers downloaded or large images decoded.
    local pageCount = math.ceil(#displayRows / appearance.pageSize)
    gridPage = math.clamp(gridPage, 1, pageCount)
    local first = (gridPage - 1) * appearance.pageSize + 1
    local last = math.min(gridPage * appearance.pageSize, #displayRows)
    table.insert(children, ui.row({ key = "grid-pagination", gap = 4, height = 32, align = "center" }, {
      ui.label({ text = tr("grid_page", { page = gridPage, pages = pageCount, total = #displayRows }),
        fontSize = 11, color = "on_surface_variant", flexGrow = 1, maxLines = 1 }),
      layoutControls,
      ui.button({ key = "grid-previous", glyph = "chevron-left", width = 32, height = 32, variant = "ghost",
        tooltip = tr("grid_previous"), onClick = if gridPage > 1 then function() gridPage -= 1; render() end else "onNoop" }),
      ui.button({ key = "grid-next", glyph = "chevron-right", width = 32, height = 32, variant = "ghost",
        tooltip = tr("grid_next"), onClick = if gridPage < pageCount then function() gridPage += 1; render() end else "onNoop" }),
    }))
    requestVisibleCovers(displayRows, first, last)
    if collectionLayout == "grid" then
      for start = first, last, density.columns do
        local cards = {}
        for index = start, math.min(start + density.columns - 1, last) do
          table.insert(cards, renderGridCard(displayRows[index]))
        end
        for _ = #cards + 1, density.columns do
          table.insert(cards, ui.spacer({ width = 0, flexGrow = 1 }))
        end
        table.insert(listChildren, ui.row({ key = "grid-row-" .. tostring(start), gap = density.gap, align = "start" }, cards))
      end
    else
      for index = first, last do
        table.insert(listChildren, renderRow(displayRows[index]))
      end
    end
    -- All rows share the same parent width inside the panel-wide viewport.
    table.insert(children, ui.column({ key = "collection-scroll", gap = density.gap, align = "stretch" }, listChildren))
  end

  return panelFrame(children)
end

render = function()
  if not snapshot.viewer and snapshot.authMode == "none" and not snapshot.loading then
    panel.render(renderNotConfigured())
    dirty = false
    return
  end
  panel.render(renderContent())
  dirty = false
end

noctalia.state.watch("bgm_snapshot", function(value)
  if type(value) == "table" then
    if accountIdentity(snapshot) ~= accountIdentity(value) then
      clearDisconnect()
      accountExpanded = false
      categoryRequestKey = nil
      pendingCategoryCheck = false
      gridPage = 1
    elseif value.oauthBusy or value.busy then
      clearDisconnect()
    end
    snapshot = value
    loadProfile()
    if noctalia.state.get("bgm_open") then ensureSelectedCollection() end
    dirty = true
    render()
  end
end)

panel.setWantsSecondTicks(true)

function onOpen(_context)
  syncAppearance()
  if appearance.layout ~= "remember" then collectionLayout = appearance.layout; gridPage = 1 end
  if appearance.timelineLayout ~= "remember" then timelineLayout = appearance.timelineLayout end
  coverRequestSignature = nil
  timelineCoverRequestSignature = nil
  profileRequestSignature = nil
  clearDisconnect()
  accountExpanded = false
  -- Hidden panels can miss watcher callbacks; use the service's latest state.
  local current = noctalia.state.get("bgm_snapshot")
  if type(current) == "table" then
    if accountIdentity(snapshot) ~= accountIdentity(current) then
      categoryRequestKey = nil
      pendingCategoryCheck = false
      gridPage = 1
    end
    snapshot = current
  end
  noctalia.state.set("bgm_open", true)
  loadProfile()
  if _context == "timeline" then activeView = "timeline" end
  if activeView == "timeline" then
    loadCalendar(false)
  elseif snapshot.authMode and snapshot.authMode ~= "none" and not snapshot.oauthBusy and not snapshot.loading and not snapshot.busy then
    pendingCategoryCheck = activeType ~= 3
    sendCommand("refresh", { silent = true })
    -- Refresh already checks Watching; other selected categories have their
    -- own TTL and must be checked even when their cached rows are loaded.
    if activeType ~= 3 then
      ensureSelectedCollection()
    end
  else
    pendingCategoryCheck = true
  end
  dirty = true
  render()
end

function onClose()
  clearDisconnect()
  accountExpanded = false
  noctalia.state.set("bgm_open", false)
end

function update()
  if syncAppearance() then
    dirty = true
    loadProfile()
    if activeView == "timeline" and noctalia.state.get("bgm_open") then loadCalendar(false) end
  end
  local localDate = os.date("%Y-%m-%d")
  if lastLocalDate ~= localDate then
    lastLocalDate = localDate
    if activeView == "timeline" then dirty = true; loadCalendar(false) end
  end
  if dirty then
    render()
  end
  if noctalia.state.get("bgm_open") then ensureSelectedCollection() end
end

function onNoop() end

function onRefresh()
  if activeView == "timeline" then timelineCoverRequestSignature = nil; loadCalendar(true)
  elseif not snapshot.oauthBusy and not snapshot.busy then sendCommand("refresh", {}) end
end

function onSettings()
  clearDisconnect()
  noctalia.openSettings()
end

render()

-- The host invokes entry points by name; this reference suppresses static-analysis unused warnings.
local _ = { update, onOpen, onClose, onNoop, onRefresh, onSettings }
