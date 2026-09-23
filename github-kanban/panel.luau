--!nonstrict

local currentTab = noctalia.getConfig("default_dashboard") or "overview"
local workFilter = "prs"
local workStateFilter = "all"
local prScopeFilter = noctalia.getConfig("pr_default_filter") or "all"
local issueScopeFilter = noctalia.getConfig("issue_default_filter") or "all"
local feedFilter = "all"
local notificationFilter = "all"
local notificationReadFilter = noctalia.getConfig("notification_default_filter") or "unread"
local hovered = nil
local followingVisibleByGroup = {}
local selectedDate = nil
local selectedByKey = {}
local cachedCalendar = nil
local gridColumns = {}
local gridLevels = {}
local gridDetails = {}
local gridWeek = 1
local gridWeekCount = 0
local gridPreparingDay = 1
local gridReady = false
local panelOpen = false
local render

local CELL_SIZE = 13
local CELL_GAP = 1
local CELL_RADIUS = 2
local COLORS = {
  "surface_variant",
  "primary/0.25",
  "primary/0.45",
  "primary/0.70",
  "primary",
}

local function cfg(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil or value == "" then return fallback end
  return value
end

local function cfgInt(key, fallback, minimum, maximum)
  return math.clamp(tonumber(noctalia.getConfig(key)) or fallback, minimum, maximum)
end

local function font(size)
  return math.floor(size * cfgInt("appearance_font_scale", 100, 80, 130) / 100 + 0.5)
end

local function densityValue(compact, standard, comfortable)
  local density = cfg("appearance_density", "standard")
  if density == "compact" then return compact end
  if density == "comfortable" then return comfortable end
  return standard
end

local function cardRadius() return cfgInt("appearance_card_radius", 9, 0, 24) end
local function cardSpacing() return cfgInt("appearance_card_spacing", 8, 4, 20) end
local function cardFill()
  local mode = cfg("appearance_card_background", "tinted")
  if mode == "transparent" then return "transparent" end
  if mode == "solid" then return "surface/0.68" end
  return "surface_variant/0.38"
end

local function cardBorder(active, unread)
  local mode = cfg("appearance_card_border", "subtle")
  local hover = cfg("appearance_hover_effect", "background")
  if unread and noctalia.getConfig("notification_unread_border") ~= false then return "primary", 2 end
  if active and hover == "border" then return "primary", 2 end
  if mode == "none" then return "outline/0", 0 end
  if mode == "accent" then return "primary", 1 end
  return "outline", 1
end

local function hoverFill(active, unread)
  if active and cfg("appearance_hover_effect", "background") == "background" then return "tertiary/0.72" end
  if unread then return "primary/0.08" end
  return cardFill()
end

local function avatarGeometry(base)
  local mode = cfg("appearance_avatar_size", "medium")
  local size = mode == "small" and math.floor(base * 0.78) or (mode == "large" and math.floor(base * 1.25) or base)
  local radius = cfg("appearance_avatar_shape", "circle") == "circle" and math.ceil(size / 2) or math.max(4, math.floor(size / 4))
  return size, radius
end

local function iconColor(active)
  if active and cfg("appearance_hover_effect", "background") == "background" then return "on_tertiary" end
  local style = cfg("appearance_icon_style", "theme")
  if style == "muted" then return "on_surface_variant" end
  if style == "color" then return "tertiary" end
  return "primary"
end

local function validHex(value)
  value = tostring(value or "")
  return value:match("^#%x%x%x%x%x%x$") and value or nil
end

local function loadHeatmapAppearance()
  CELL_SIZE = cfgInt("heatmap_cell_size", 13, 8, 16)
  CELL_GAP = cfgInt("heatmap_cell_gap", 1, 1, 4)
  CELL_RADIUS = cfgInt("heatmap_cell_radius", 2, 0, 4)
  -- Clamp a full-year grid (~53 weeks) to the fixed 860px panel in both placements.
  local maxCell = math.floor((760 - 52 * CELL_GAP) / 53)
  CELL_SIZE = math.clamp(math.min(CELL_SIZE, maxCell), 8, 16)
  local mode = cfg("heatmap_color_mode", "noctalia")
  local themed = { "surface_variant", "primary/0.25", "primary/0.45", "primary/0.70", "primary" }
  if mode == "github" then
    COLORS = { "#ebedf0", "#9be9a8", "#40c463", "#30a14e", "#216e39" }
  elseif mode == "custom" then
    COLORS = {}
    for level = 0, 4 do COLORS[level + 1] = validHex(noctalia.getConfig("heatmap_custom_level_" .. tostring(level))) or themed[level + 1] end
  else COLORS = themed end
end

local function parseTimestamp(value)
  local y, m, d, h, minute, second, suffix = tostring(value or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$")
  if not y then return nil end
  y, m, d, h, minute, second = tonumber(y), tonumber(m), tonumber(d), tonumber(h), tonumber(minute), tonumber(second)
  if suffix == "" then
    return os.time({ year = y, month = m, day = d, hour = h, min = minute, sec = second })
  end

  local zone = suffix:match("^[%.%d]*([Zz])$")
  local sign, offsetHours, offsetMinutes = suffix:match("^[%.%d]*([+-])(%d%d):?(%d%d)$")
  if not zone and not sign then return nil end

  -- Convert the civil date to UTC without asking os.time to interpret it locally.
  local adjustedYear = y - (m <= 2 and 1 or 0)
  local era = math.floor(adjustedYear / 400)
  local yearOfEra = adjustedYear - era * 400
  local adjustedMonth = m + (m > 2 and -3 or 9)
  local dayOfYear = math.floor((153 * adjustedMonth + 2) / 5) + d - 1
  local dayOfEra = yearOfEra * 365 + math.floor(yearOfEra / 4) - math.floor(yearOfEra / 100) + dayOfYear
  local epoch = (era * 146097 + dayOfEra - 719468) * 86400 + h * 3600 + minute * 60 + second
  if sign then
    local offset = (tonumber(offsetHours) * 60 + tonumber(offsetMinutes)) * 60
    if sign == "-" then offset = -offset end
    epoch -= offset
  end
  return epoch
end

local function displayTime(value)
  if not value or value == "" then return "" end
  local mode = cfg("appearance_time_format", "relative")
  if mode == "iso" then return value end
  local timestamp = parseTimestamp(value)
  if not timestamp then return value end
  if mode == "local" then return noctalia.formatTime("%Y-%m-%d %H:%M", timestamp) end
  local seconds = math.max(0, os.time() - timestamp)
  if seconds < 60 then return noctalia.tr("time.just_now") end
  if seconds < 3600 then
    local count = math.floor(seconds / 60)
    return noctalia.trp("time.minutes_ago", count, { count = count })
  end
  if seconds < 86400 then
    local count = math.floor(seconds / 3600)
    return noctalia.trp("time.hours_ago", count, { count = count })
  end
  local count = math.floor(seconds / 86400)
  return noctalia.trp("time.days_ago", count, { count = count })
end

local state = {
  status = noctalia.state.get("status") or "loading",
  error = noctalia.state.get("error") or "",
  stale = noctalia.state.get("stale") == true,
  lastUpdate = noctalia.state.get("last_update") or "",
  profile = noctalia.state.get("profile") or {},
  contributions = noctalia.state.get("contributions") or {},
  notifications = noctalia.state.get("notifications") or {},
  followingEvents = noctalia.state.get("following_events") or {},
  followingRepoEvents = noctalia.state.get("following_repo_events") or {},
  prs = noctalia.state.get("my_prs") or {},
  reviews = noctalia.state.get("review_prs") or {},
  authoredIssues = noctalia.state.get("authored_issues") or {},
  issues = noctalia.state.get("issues") or {},
  repositories = noctalia.state.get("repositories") or {},
  actions = noctalia.state.get("actions") or {},
}

local function tr(key, args) return noctalia.tr(key, args) end

local function itemText(item, field)
  local key = item[field .. "Key"]
  if key and key ~= "" then return tr(key, item[field .. "Args"] or {}) end
  return item[field] or ""
end

local function translatedValue(group, value)
  if not value or value == "" then return "" end
  local key = group .. "." .. tostring(value):lower():gsub("[^a-z0-9_-]", "_")
  local translated = tr(key)
  return translated == key and tostring(value) or translated
end

local function splitTabs(value)
  local fields = {}
  for field in string.gmatch((value or "") .. "\t", "(.-)\t") do fields[#fields + 1] = field end
  return fields
end

local function rowLevels(row)
  local levels = {}
  local byCodepoint = { [0x00B7] = 0, [0x2591] = 1, [0x2592] = 2, [0x2593] = 3, [0x2588] = 4 }
  for _, codepoint in utf8.codes(row or "") do levels[#levels + 1] = byCodepoint[codepoint] or 0 end
  return levels
end

local function dateTimestamp(value)
  local year, month, day = string.match(value or "", "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not year then return nil end
  return os.time({ year = tonumber(year), month = tonumber(month), day = tonumber(day), hour = 12 })
end

local function resetGrid(source)
  selectedDate = nil
  selectedByKey = {}
  cachedCalendar = nil
  gridColumns = {}
  gridLevels = {}
  gridDetails = {}
  gridWeek = 1
  gridWeekCount = 0
  gridPreparingDay = 1
  gridReady = type(source) == "table" and type(source.rows) == "table"
end

local function detailDate(day, week)
  return string.match(((gridDetails[day] or {})[week] or ""), "^([^|]+)|")
end

local function representativeDateForWeek(week)
  for _, day in ipairs({ 4, 1, 2, 3, 5, 6, 7 }) do
    local date = detailDate(day, week)
    if date then return date end
  end
end

local function representativeDateForDay(day)
  for week = 1, gridWeekCount do
    local date = detailDate(day, week)
    if date then return date end
  end
end

local function monthHeader()
  local segments = {}
  local currentMonth, currentDate, weeks
  local function append()
    if not currentMonth or weeks == 0 then return end
    segments[#segments + 1] = ui.column({
      width = weeks * (CELL_SIZE + CELL_GAP) - CELL_GAP,
      height = 14, align = "start", justify = "center",
    }, {
      ui.label({
        text = weeks >= 2 and noctalia.formatTime("%b", dateTimestamp(currentDate)) or "",
        fontSize = font(10), color = "on_surface_variant",
      }),
    })
  end
  for week = 1, gridWeekCount do
    local date = representativeDateForWeek(week)
    local month = date and string.sub(date, 1, 7) or currentMonth
    if currentMonth and month ~= currentMonth then append(); weeks = 0 end
    currentMonth, currentDate, weeks = month, date or currentDate, (weeks or 0) + 1
  end
  append()
  return ui.row({ gap = CELL_GAP }, segments)
end

local function weekdayLabels()
  local labels = {}
  for day = 1, 7 do
    local date = (day == 2 or day == 4 or day == 6) and representativeDateForDay(day) or nil
    labels[#labels + 1] = ui.column({ width = 28, height = CELL_SIZE, align = "end", justify = "center" }, {
      ui.label({ text = date and noctalia.formatTime("%a", dateTimestamp(date)) or "", fontSize = font(9), color = "on_surface_variant" }),
    })
  end
  return ui.column({ gap = CELL_GAP, align = "end" }, labels)
end

local function prepareGrid()
  if not gridReady or cachedCalendar then return end
  if gridPreparingDay <= 7 then
    local day = gridPreparingDay
    gridLevels[day] = rowLevels(state.contributions.rows[day])
    gridDetails[day] = splitTabs((state.contributions.details or {})[day])
    gridWeekCount = math.max(gridWeekCount, #gridLevels[day])
    gridPreparingDay += 1
    return
  end
  if gridWeek <= gridWeekCount then
    local cells = {}
    for day = 1, 7 do
      local raw = gridDetails[day][gridWeek] or ""
      local date, count = string.match(raw, "^([^|]+)|(%d+)$")
      if date then
        local key = "contribution-" .. date
        local rawLevel = gridLevels[day][gridWeek] or 0
        local level = rawLevel
        if cfg("heatmap_levels", "5") == "4" and rawLevel > 0 then level = math.min(3, math.ceil(rawLevel * 3 / 4)) end
        local emptyOutline = level == 0 and cfg("heatmap_empty_style", "background") == "outline"
        selectedByKey[key] = { date = date, count = tonumber(count) or 0 }
        cells[#cells + 1] = ui.box({
          key = key, width = CELL_SIZE, height = CELL_SIZE, radius = CELL_RADIUS,
          fill = COLORS[level + 1], opacity = level == 0 and 0.32 or 1,
          border = emptyOutline and "primary/0.45" or "primary/0.24", borderWidth = 1,
          onHover = "onContributionHover",
        })
      else
        cells[#cells + 1] = ui.box({
          width = CELL_SIZE, height = CELL_SIZE, radius = CELL_RADIUS,
          fill = COLORS[1], opacity = 0.32,
          border = "primary/0.24", borderWidth = 1,
        })
      end
    end
    gridColumns[#gridColumns + 1] = ui.column({ key = "week-" .. tostring(gridWeek), gap = CELL_GAP }, cells)
    gridWeek += 1
    return
  end
  local calendarRows = {}
  if noctalia.getConfig("heatmap_show_months") ~= false then calendarRows[#calendarRows + 1] = monthHeader() end
  calendarRows[#calendarRows + 1] = ui.row({ gap = CELL_GAP, align = "start" }, gridColumns)
  local calendar = { ui.column({ gap = 5, align = "start" }, calendarRows) }
  if noctalia.getConfig("heatmap_show_weekdays") ~= false then table.insert(calendar, 1, weekdayLabels()) end
  cachedCalendar = ui.row({ gap = 10, align = "end", justify = "center" }, calendar)
  panel.setWantsSecondTicks(false)
  panel.setNeedsFrameTick(false)
  if panelOpen then render() end
end

loadHeatmapAppearance()
resetGrid(state.contributions)

local function openLink(url)
  if type(url) ~= "string" or url == "" then return end
  if not noctalia.commandExists("xdg-open") then
    noctalia.notifyError(tr("panel.title"), tr("status.missing_xdg_open"))
    return
  end
  noctalia.runAsync({ "xdg-open", url })
end

local function button(text, selected, callback)
  return ui.button({
    text = text,
    variant = selected and "primary" or "ghost",
    selected = selected,
    controlSize = "sm",
    onClick = callback,
  })
end

local function statusView()
  local message = tr("status.loading")
  if state.status == "missing_gh" then message = tr("status.missing_gh")
  elseif state.status == "auth_error" then message = tr("status.auth_error")
  elseif state.error ~= "" then message = state.error end
  return ui.column({ flexGrow = 1, gap = 12, align = "center", justify = "center" }, {
    ui.glyph({ name = state.status == "loading" and "loader" or "alert-triangle", size = 42, color = "on_surface_variant" }),
    ui.label({ text = message, color = "on_surface_variant", textAlign = "center", maxLines = 4 }),
  })
end

local function card(item, glyph, context)
  local url = item.url or item.htmlUrl or ""
  local key = item.id and item.id ~= "" and tostring(item.id)
    or (url ~= "" and url or tostring(item.title or item.name))
  local active = hovered == key
  local unread = item.unread == true
  local title = itemText(item, "title")
  if title == "" then title = item.sourceName or item.fullName or item.repository or item.name or item.login or item.type or tr("fallback.untitled") end
  local subtitle = itemText(item, "subtitle")
  if subtitle == "" then subtitle = item.ref or item.repo or item.repository or item.fullName or item.description or item.type or "" end
  local meta = item.state or item.meta or item.conclusion or item.status or item.reason or item.updatedAt or item.createdAt or ""
  if meta == item.updatedAt or meta == item.createdAt then meta = displayTime(meta) end
  if meta == item.state or meta == item.status or meta == item.conclusion then meta = translatedValue("github.status", meta) end
  if meta == item.reason then meta = translatedValue("github.reason", meta) end
  local avatarSize, avatarRadius = avatarGeometry(28)
  local leading
  if item.source == "user" and item.actor and item.actor ~= "" then
    if item.actorAvatarPath and item.actorAvatarPath ~= "" then
      leading = ui.image({ path = item.actorAvatarPath, width = avatarSize, height = avatarSize, radius = avatarRadius, fit = "cover" })
    else
      leading = ui.column({ width = avatarSize, height = avatarSize, radius = avatarRadius, fill = "primary/0.12", align = "center", justify = "center" }, {
        ui.glyph({ name = "user", size = font(16), color = iconColor(active) }),
      })
    end
  elseif item.source == "repository" then
    if item.repositoryOwnerAvatarPath and item.repositoryOwnerAvatarPath ~= "" then
      leading = ui.image({ path = item.repositoryOwnerAvatarPath, width = avatarSize, height = avatarSize, radius = avatarRadius, fit = "cover" })
    else
      leading = ui.column({ width = avatarSize, height = avatarSize, radius = avatarRadius, fill = "primary/0.12", align = "center", justify = "center" }, {
        ui.glyph({ name = "folder-code", size = font(16), color = iconColor(active) }),
      })
    end
  else
    leading = ui.glyph({ name = glyph or item.glyph or "brand-github", size = font(20), color = iconColor(active), visible = context ~= "activity" or noctalia.getConfig("activity_show_type_icons") ~= false })
  end
  local displayTitle = item.source == "user" and item.actor and item.actor ~= ""
    and (item.actor .. "  ·  " .. title) or title
  if context == "activity" and noctalia.getConfig("activity_repository_emphasis") ~= false and item.repository and item.repository ~= "" then
    displayTitle = item.repository .. " · " .. displayTitle
  end
  local border, borderWidth = cardBorder(active, unread)
  local secondaryMode = cfg("appearance_secondary_text", "truncate")
  local secondaryLines = secondaryMode == "full" and 4 or 1
  local readOpacity = unread and 1 or cfgInt("notification_read_opacity", 100, 40, 100) / 100
  return ui.row({
    key = key, gap = densityValue(7, 10, 13), padding = densityValue(7, 10, 13), radius = cardRadius(),
    border = border, borderWidth = borderWidth, fill = hoverFill(active, unread), opacity = context == "notifications" and readOpacity or 1,
    align = "center",
    onClick = function() openLink(url) end,
    onHover = function(value)
      if noctalia.getConfig("appearance_animations") == false then return end
      hovered = value == "true" and key or nil
      render()
    end,
  }, {
    ui.box({ width = 7, height = 7, radius = 4, fill = "primary", visible = unread and noctalia.getConfig("notification_unread_dot") ~= false }),
    leading,
    ui.column({ flexGrow = 1, gap = 3 }, {
      ui.label({ text = displayTitle, fontWeight = "bold", fontSize = font(13), color = active and cfg("appearance_hover_effect", "background") == "background" and "on_tertiary" or "on_surface", maxLines = 2 }),
      ui.label({ text = subtitle, fontSize = font(11), color = active and cfg("appearance_hover_effect", "background") == "background" and "on_tertiary" or "on_surface_variant", maxLines = secondaryLines, visible = subtitle ~= "" and secondaryMode ~= "hidden" }),
    }),
    ui.label({ text = meta, fontSize = font(10), color = active and cfg("appearance_hover_effect", "background") == "background" and "on_tertiary" or "on_surface_variant", maxLines = 1, visible = meta ~= "" and (context ~= "activity" or noctalia.getConfig("activity_show_status_badges") ~= false) }),
    ui.glyph({ name = "external-link", size = 15, color = active and "on_tertiary" or "on_surface_variant", visible = url ~= "" }),
  })
end

local function listView(items, glyph, context)
  if type(items) ~= "table" or #items == 0 then
    return ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 10 }, {
      ui.glyph({ name = "inbox", size = font(38), color = "on_surface_variant", visible = noctalia.getConfig("appearance_show_empty_illustration") ~= false }),
      ui.label({ text = tr("status.empty"), color = "on_surface_variant" }),
    })
  end
  local children = {}
  for _, item in ipairs(items) do children[#children + 1] = card(item, glyph, context) end
  return ui.scroll({ flexGrow = 1, gap = cardSpacing(), align = "stretch" }, children)
end

local function repositoryCard(item)
  local key = "repository-" .. tostring(item.fullName or item.url or item.name)
  local active = hovered == key
  local border, borderWidth = cardBorder(active, false)
  local details = {}
  if noctalia.getConfig("repositories_show_language") ~= false and item.language and item.language ~= "" then details[#details + 1] = item.language end
  if noctalia.getConfig("repositories_show_stats") ~= false then
    details[#details + 1] = tr("repository.stars", { count = item.stars or 0 })
    details[#details + 1] = tr("repository.forks", { count = item.forks or 0 })
  end
  if item.updatedAt and item.updatedAt ~= "" then details[#details + 1] = displayTime(item.updatedAt) end
  return ui.column({
    key = key, flexGrow = 1, gap = densityValue(4, 6, 8), padding = densityValue(8, 11, 14), radius = cardRadius(),
    fill = hoverFill(active, false), border = border, borderWidth = borderWidth,
    onClick = function() openLink(item.url) end,
    onHover = function(value)
      if noctalia.getConfig("appearance_animations") == false then return end
      hovered = value == "true" and key or nil
      render()
    end,
  }, {
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "folder-code", size = font(18), color = iconColor(active) }),
      ui.label({ text = item.fullName or item.name or tr("fallback.repository"), fontSize = font(13), fontWeight = "bold", flexGrow = 1, maxLines = 1 }),
      ui.glyph({ name = "external-link", size = font(14), color = "on_surface_variant" }),
    }),
    ui.label({ text = item.description or "", fontSize = font(11), color = "on_surface_variant", maxLines = cfg("appearance_secondary_text", "truncate") == "full" and 4 or 2, visible = item.description ~= "" and cfg("appearance_secondary_text", "truncate") ~= "hidden" }),
    ui.label({ text = table.concat(details, "  ·  "), fontSize = font(10), color = "on_surface_variant", maxLines = 1, visible = #details > 0 }),
  })
end

local function repositoriesView()
  if #state.repositories == 0 then return listView({}, "folder-code") end
  local children = {}
  if cfg("repositories_layout", "list") == "grid" then
    local index = 1
    while index <= #state.repositories do
      local row = { repositoryCard(state.repositories[index]) }
      if state.repositories[index + 1] then row[#row + 1] = repositoryCard(state.repositories[index + 1])
      else row[#row + 1] = ui.box({ flexGrow = 1 }) end
      children[#children + 1] = ui.row({ gap = cardSpacing(), align = "stretch" }, row)
      index += 2
    end
  else
    for _, item in ipairs(state.repositories) do children[#children + 1] = repositoryCard(item) end
  end
  return ui.scroll({ flexGrow = 1, gap = cardSpacing(), align = "stretch" }, children)
end

local function followingEventRow(item)
  local url = item.url or ""
  local key = "following-event-" .. tostring(item.id or url)
  local active = hovered == key
  local title = itemText(item, "title")
  if title == "" then title = item.type or tr("fallback.github_activity") end
  if item.source == "repository" then title = title:match(" %- (.+)$") or title end
  local subtitle = itemText(item, "subtitle")
  local border, borderWidth = cardBorder(active, false)
  local contentLines = cfgInt("following_content_lines", 2, 1, 5)
  return ui.row({
    key = key, gap = densityValue(6, 8, 10), padding = densityValue(6, 8, 10), radius = math.max(0, cardRadius() - 2),
    fill = hoverFill(active, false), border = border, borderWidth = borderWidth,
    align = "center",
    onClick = function() openLink(url) end,
    onHover = function(value)
      if noctalia.getConfig("appearance_animations") == false then return end
      hovered = value == "true" and key or nil
      render()
    end,
  }, {
    ui.column({ flexGrow = 1, gap = 2 }, {
      ui.label({ text = title, fontWeight = "bold", fontSize = font(13), color = active and cfg("appearance_hover_effect", "background") == "background" and "on_tertiary" or "on_surface", maxLines = 1 }),
      ui.label({ text = subtitle, fontSize = font(11), color = active and cfg("appearance_hover_effect", "background") == "background" and "on_tertiary" or "on_surface_variant", maxLines = contentLines, visible = subtitle ~= "" and cfg("appearance_secondary_text", "truncate") ~= "hidden" }),
    }),
    ui.label({ text = displayTime(item.createdAt), fontSize = font(9), color = active and cfg("appearance_hover_effect", "background") == "background" and "on_tertiary" or "on_surface_variant", maxLines = 1 }),
    ui.glyph({ name = "external-link", size = 14, color = active and "on_tertiary" or "on_surface_variant", visible = url ~= "" }),
  })
end

local function followingGroupCard(group)
  local first = group.items[1]
  local isUser = group.source == "user"
  local avatarPath = isUser and first.actorAvatarPath or first.repositoryOwnerAvatarPath
  local avatarSize, avatarRadius = avatarGeometry(32)
  local avatar
  if avatarPath and avatarPath ~= "" then
    avatar = ui.image({ path = avatarPath, width = avatarSize, height = avatarSize, radius = avatarRadius, fit = "cover" })
  else
    avatar = ui.column({ width = avatarSize, height = avatarSize, radius = avatarRadius, fill = "primary/0.12", align = "center", justify = "center" }, {
      ui.glyph({ name = isUser and "user" or "folder-code", size = font(17), color = iconColor(false) }),
    })
  end
  local maxHeight = math.clamp(tonumber(noctalia.getConfig("following_card_max_height")) or 260, 140, 500)
  local rowHeight = densityValue(50, 58, 68) + (cfgInt("following_content_lines", 2, 1, 5) - 2) * font(9)
  local headerHeight = densityValue(52, 59, 68)
  local hasOverflow = headerHeight + #group.items * rowHeight > maxHeight
  local footerHeight = hasOverflow and 30 or 0
  local initialVisible = math.max(1, math.min(#group.items, math.floor((maxHeight - headerHeight - footerHeight) / rowHeight)))
  local visibleCount = math.min(#group.items, math.max(initialVisible, followingVisibleByGroup[group.key] or initialVisible))
  local rows = {}
  for index = 1, visibleCount do rows[#rows + 1] = followingEventRow(group.items[index]) end
  local hiddenCount = #group.items - visibleCount
  local cardHeight = headerHeight + visibleCount * rowHeight + (hiddenCount > 0 and 30 or 0)
  local content = {}
  for _, row in ipairs(rows) do content[#content + 1] = row end
  if hiddenCount > 0 then
    local moreCount = math.min(3, hiddenCount)
    content[#content + 1] = ui.button({
      text = noctalia.trp("panel.show_more", moreCount, { count = moreCount, remaining = hiddenCount }),
      variant = "ghost", controlSize = "sm",
      onClick = function()
        followingVisibleByGroup[group.key] = visibleCount + 3
        render()
      end,
    })
  end
  return ui.column({
    key = "following-group-" .. group.key,
    gap = densityValue(5, 7, 10), padding = densityValue(7, 10, 13), radius = cardRadius(),
    border = cfg("appearance_card_border", "subtle") == "none" and "outline/0" or (cfg("appearance_card_border", "subtle") == "accent" and "primary" or "outline"),
    borderWidth = cfg("appearance_card_border", "subtle") == "none" and 0 or 1,
    fill = cardFill(), height = math.min(maxHeight, cardHeight),
  }, {
    ui.row({ gap = 9, align = "center" }, {
      avatar,
      ui.label({ text = group.name, fontWeight = "bold", fontSize = font(14), flexGrow = 1, maxLines = 1 }),
      ui.label({ text = tostring(#group.items), fontSize = font(10), color = "on_surface_variant" }),
    }),
    ui.column({ gap = cfgInt("following_event_spacing", 5, 2, 12), align = "stretch" }, content),
  })
end

local function groupedFollowingList(items)
  if #items == 0 then return listView(items, "rss") end
  local ordered = {}
  for _, item in ipairs(items) do ordered[#ordered + 1] = item end
  table.sort(ordered, function(a, b) return tostring(a.createdAt or "") > tostring(b.createdAt or "") end)
  local groups, groupByKey = {}, {}
  for _, item in ipairs(ordered) do
    local isUser = item.source == "user"
    local name = isUser and ((item.sourceName and item.sourceName ~= "" and item.sourceName) or item.actor or tr("fallback.github_user")) or (item.repository or tr("fallback.github_repository"))
    local identity = isUser and (item.actor or name) or name
    local key = (isUser and "user:" or "repository:") .. identity
    local group = groupByKey[key]
    if not group then
      group = { key = key, name = name, source = item.source, items = {} }
      groupByKey[key] = group
      groups[#groups + 1] = group
    end
    group.items[#group.items + 1] = item
  end
  local cards = {}
  for _, group in ipairs(groups) do cards[#cards + 1] = followingGroupCard(group) end
  return ui.scroll({ flexGrow = 1, gap = cardSpacing(), align = "stretch" }, cards)
end

local function metric(label, value, glyph)
  return ui.column({ flexGrow = 1, gap = densityValue(2, 4, 6), padding = densityValue(7, 10, 13), radius = cardRadius(), fill = cardFill(), align = "center" }, {
    ui.glyph({ name = glyph, size = font(19), color = iconColor(false) }),
    ui.label({ text = tostring(value or 0), fontSize = font(18), fontWeight = "bold", color = "on_surface" }),
    ui.label({ text = label, fontSize = font(10), color = "on_surface_variant" }),
  })
end

local function statsLayout(items)
  local mode = cfg("overview_stats_layout", "columns4")
  if mode == "grid" then
    return ui.column({ gap = cardSpacing() }, {
      ui.row({ gap = cardSpacing() }, { items[1], items[2] }),
      ui.row({ gap = cardSpacing() }, { items[3], items[4] }),
    })
  end
  return ui.row({ gap = mode == "compact" and 3 or cardSpacing() }, items)
end

local function profileHeader()
  local profile = state.profile
  local avatar
  local avatarSize, avatarRadius = avatarGeometry(58)
  if profile.avatarPath and profile.avatarPath ~= "" then
    avatar = ui.image({ path = profile.avatarPath, width = avatarSize, height = avatarSize, radius = avatarRadius, fit = "cover", border = "primary", borderWidth = 2 })
  else
    avatar = ui.column({ width = avatarSize, height = avatarSize, radius = avatarRadius, align = "center", justify = "center", border = "primary", borderWidth = 2 }, {
      ui.glyph({ name = "user", size = font(30), color = "on_surface_variant" }),
    })
  end
  local function profileMetric(label, value, glyph)
    return ui.column({ flexGrow = 1, gap = 2, align = "center", justify = "center" }, {
      ui.glyph({ name = glyph, size = font(16), color = iconColor(false) }),
      ui.label({ text = tostring(value or 0), fontSize = font(16), fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = label, fontSize = font(9), color = "on_surface_variant" }),
    })
  end
  local stats = statsLayout({
    profileMetric(tr("profile.followers"), profile.followers, "users"),
    profileMetric(tr("profile.following"), profile.following, "user-plus"),
    profileMetric(tr("profile.repositories"), profile.publicRepos, "folder-code"),
    profileMetric(tr("profile.contributions"), state.contributions.total, "chart-dots"),
  })
  return ui.row({ gap = densityValue(9, 12, 15), align = "center", padding = densityValue(9, 12, 15), radius = cardRadius(), fill = cardFill(), onClick = function() openLink(profile.url) end }, {
    avatar,
    ui.column({ width = 205, gap = 3 }, {
      ui.label({ text = profile.name or profile.login or tr("fallback.github"), fontSize = font(18), fontWeight = "bold" }),
      ui.label({ text = profile.login and ("@" .. profile.login) or "", color = "primary", fontSize = font(12) }),
      ui.label({ text = profile.bio or "", color = "on_surface_variant", fontSize = font(11), maxLines = cfg("appearance_secondary_text", "truncate") == "full" and 4 or 2, visible = cfg("appearance_secondary_text", "truncate") ~= "hidden" }),
    }),
    ui.column({ flexGrow = 1 }, { stats }),
    ui.glyph({ name = "external-link", size = 17, color = "on_surface_variant" }),
  })
end

local function heatmapPlaceholderHeight()
  -- Estimate the real card height so the placeholder swap doesn't jump layout.
  local gridH = 7 * CELL_SIZE + 6 * CELL_GAP
  local monthsH = noctalia.getConfig("heatmap_show_months") ~= false and 19 or 0
  return gridH + monthsH + 18 + densityValue(9, 12, 15) * 2 + cardSpacing()
end

local function heatmap()
  if not cachedCalendar then
    return ui.column({ flexGrow = 1, minHeight = heatmapPlaceholderHeight(), align = "center", justify = "center" }, {
      ui.label({ text = tr("status.preparing_contribution_calendar"), color = "on_surface_variant", fontSize = 11 }),
    })
  end
  local total = tonumber(state.contributions.total) or 0
  local detail = state.contributions.total and noctalia.trp("contributions.last_year", total, { count = total }) or ""
  if selectedDate then
    local selected = selectedByKey["contribution-" .. selectedDate]
    if selected then detail = noctalia.trp("contributions.selected_day", selected.count, { count = selected.count, date = selected.date }) end
  end
  local legend = { ui.label({ text = tr("heatmap.less"), fontSize = font(9), color = "on_surface_variant" }) }
  local levelCount = cfg("heatmap_levels", "5") == "4" and 4 or 5
  for level = 1, levelCount do
    legend[#legend + 1] = ui.box({
      width = 10, height = 10, radius = CELL_RADIUS,
      fill = COLORS[level], opacity = level == 1 and 0.32 or 1,
      border = "primary/0.24", borderWidth = 1,
    })
  end
  legend[#legend + 1] = ui.label({ text = tr("heatmap.more"), fontSize = font(9), color = "on_surface_variant" })
  local footer = {}
  -- Keyed on content so hover selections re-resolve width with flexGrow applied.
  if noctalia.getConfig("heatmap_show_total") ~= false then footer[#footer + 1] = ui.label({ key = "heatmap-footer-" .. (selectedDate or "total"), text = detail, flexGrow = 1, fontSize = font(10), color = "on_surface_variant", maxLines = 1 })
  else footer[#footer + 1] = ui.box({ flexGrow = 1 }) end
  if noctalia.getConfig("heatmap_show_legend") ~= false then footer[#footer + 1] = ui.row({ gap = 3, align = "center" }, legend) end
  -- Footer inset to the grid width (weeks * (CELL + GAP) - GAP), mirroring the
  -- calendar row's weekday gutter so items align with the grid edges.
  local gridWidth = math.max(gridWeekCount * (CELL_SIZE + CELL_GAP) - CELL_GAP, CELL_SIZE)
  local footerRow = ui.row({ width = gridWidth, align = "center", gap = 6 }, footer)
  local footerZone
  if noctalia.getConfig("heatmap_show_weekdays") ~= false then
    footerZone = ui.row({ gap = 10, align = "center", justify = "center" }, {
      ui.box({ width = 28 }),
      footerRow,
    })
  else
    footerZone = ui.row({ align = "center", justify = "center" }, { footerRow })
  end
  return ui.column({
    flexGrow = 1, justify = "center",
    gap = cardSpacing(), padding = densityValue(9, 12, 15), radius = cardRadius(),
    fill = "surface/0.20", border = "outline/0.45", borderWidth = 1,
  }, {
    cachedCalendar,
    footerZone,
  })
end

local function overview()
  local c = state.contributions
  -- Section stretches to fill the panel; air stays inside the heatmap card.
  return ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, {
    profileHeader(),
    ui.column({ flexGrow = 1, gap = 8, align = "stretch" }, {
      ui.label({ text = tr("panel.contributions"), fontSize = 15, fontWeight = "bold" }),
      heatmap(),
    }),
    statsLayout({
      metric(tr("contributions.today"), c.today, "calendar"),
      metric(tr("contributions.current_streak"), c.currentStreak, "flame"),
      metric(tr("contributions.best_streak"), c.bestStreak, "trophy"),
      metric(tr("contributions.this_year"), c.total, "chart-dots"),
    }),
  })
end

local function notificationGroup(reason)
  if reason == "assign" or reason == "author" then return "assigned" end
  if reason == "review_requested" or reason == "team_mention" or reason == "mention" then return "attention" end
  return "updates"
end

local function notifications()
  local readFilters = {
    { id = "all", label = tr("filter.all") }, { id = "unread", label = tr("filter.unread") }, { id = "read", label = tr("filter.read") },
  }
  local reasonFilters = {
    { id = "all", label = tr("filter.all") }, { id = "attention", label = tr("filter.attention") },
    { id = "assigned", label = tr("filter.assigned") }, { id = "updates", label = tr("filter.updates") },
  }
  local readStrip, reasonStrip = {}, {}
  for _, filter in ipairs(readFilters) do
    local id = filter.id
    readStrip[#readStrip + 1] = button(filter.label, notificationReadFilter == id, function() notificationReadFilter = id; render() end)
  end
  for _, filter in ipairs(reasonFilters) do
    local id = filter.id
    reasonStrip[#reasonStrip + 1] = button(filter.label, notificationFilter == id, function() notificationFilter = id; render() end)
  end
  local items = {}
  for _, item in ipairs(state.notifications) do
    local readMatches = notificationReadFilter == "all"
      or (notificationReadFilter == "unread" and item.unread == true)
      or (notificationReadFilter == "read" and item.unread ~= true)
    local reasonMatches = notificationFilter == "all" or notificationGroup(item.reason) == notificationFilter
    if readMatches and reasonMatches then items[#items + 1] = item end
  end
  return ui.column({ flexGrow = 1, gap = 8 }, {
    ui.row({ gap = 4 }, readStrip),
    ui.row({ gap = 4 }, reasonStrip),
    listView(items, "bell", "notifications"),
  })
end

local function work()
  local prItems, prByKey = {}, {}
  local function appendPrs(items, scope)
    for _, item in ipairs(items) do
      local key = item.url or (tostring(item.repository) .. "#" .. tostring(item.number))
      local existing = prByKey[key]
      if not existing then
        existing = {}
        for field, value in pairs(item) do existing[field] = value end
        prByKey[key] = existing
        prItems[#prItems + 1] = existing
      end
      if scope == "created" then existing.createdByMe = true else existing.reviewRequested = true end
    end
  end
  appendPrs(state.prs, "created")
  appendPrs(state.reviews, "review")
  local issueItems, issueByKey = {}, {}
  local function appendIssues(items, scope)
    for _, item in ipairs(items) do
      local key = item.url or (tostring(item.repository) .. "#" .. tostring(item.number))
      local existing = issueByKey[key]
      if not existing then
        existing = {}
        for field, value in pairs(item) do existing[field] = value end
        issueByKey[key] = existing
        issueItems[#issueItems + 1] = existing
      end
      if scope == "created" then existing.createdByMe = true else existing.assignedToMe = true end
    end
  end
  appendIssues(state.authoredIssues, "created")
  appendIssues(state.issues, "assigned")
  local filters = {
    { id = "prs", label = tr("panel.pull_requests"), items = prItems, glyph = "git-pull-request" },
    { id = "issues", label = tr("panel.issues"), items = issueItems, glyph = "circle-dot" },
    { id = "actions", label = tr("panel.actions"), items = state.actions, glyph = "player-play" },
  }
  local strip, selected = {}, filters[1]
  for _, filter in ipairs(filters) do
    local id = filter.id
    if id == workFilter then selected = filter end
    strip[#strip + 1] = button(filter.label, workFilter == id, function() workFilter = id; render() end)
  end
  local children = { ui.row({ gap = 4 }, strip) }
  local items = selected.items
  if selected.id == "prs" then
    local scopeStrip = {}
    for _, filter in ipairs({
      { id = "all", label = tr("filter.all") },
      { id = "created", label = tr("filter.created_by_me") },
      { id = "review", label = tr("filter.review_requested") },
    }) do
      local id = filter.id
      scopeStrip[#scopeStrip + 1] = button(filter.label, prScopeFilter == id, function() prScopeFilter = id; render() end)
    end
    children[#children + 1] = ui.row({ gap = 4 }, scopeStrip)
    if prScopeFilter ~= "all" then
      local scoped = {}
      for _, item in ipairs(items) do
        if (prScopeFilter == "created" and item.createdByMe) or (prScopeFilter == "review" and item.reviewRequested) then
          scoped[#scoped + 1] = item
        end
      end
      items = scoped
    end
  end
  if selected.id == "issues" then
    local scopeStrip = {}
    for _, filter in ipairs({
      { id = "all", label = tr("filter.all") },
      { id = "created", label = tr("filter.created_by_me") },
      { id = "assigned", label = tr("filter.assigned_to_me") },
    }) do
      local id = filter.id
      scopeStrip[#scopeStrip + 1] = button(filter.label, issueScopeFilter == id, function() issueScopeFilter = id; render() end)
    end
    children[#children + 1] = ui.row({ gap = 4 }, scopeStrip)
    if issueScopeFilter ~= "all" then
      local scoped = {}
      for _, item in ipairs(items) do
        if (issueScopeFilter == "created" and item.createdByMe) or (issueScopeFilter == "assigned" and item.assignedToMe) then
          scoped[#scoped + 1] = item
        end
      end
      items = scoped
    end
  end
  if selected.id == "prs" or selected.id == "issues" then
    local stateStrip = {}
    for _, filter in ipairs({
      { id = "all", label = tr("filter.all") }, { id = "open", label = tr("filter.open") }, { id = "closed", label = tr("filter.closed") },
    }) do
      local id = filter.id
      stateStrip[#stateStrip + 1] = button(filter.label, workStateFilter == id, function() workStateFilter = id; render() end)
    end
    children[#children + 1] = ui.row({ gap = 4 }, stateStrip)
    if workStateFilter ~= "all" then
      local filtered = {}
      for _, item in ipairs(items) do
        if item.state == workStateFilter then filtered[#filtered + 1] = item end
      end
      items = filtered
    end
  end
  children[#children + 1] = listView(items, selected.glyph, "activity")
  return ui.column({ flexGrow = 1, gap = 8 }, children)
end

local function following()
  local filters = {
    { id = "all", label = tr("filter.all") },
    { id = "users", label = tr("filter.users") },
    { id = "repositories", label = tr("filter.repositories") },
  }
  local strip = {}
  for _, filter in ipairs(filters) do
    local id = filter.id
    strip[#strip + 1] = button(filter.label, feedFilter == id, function() feedFilter = id; render() end)
  end
  local items = {}
  local seen = {}
  local function append(source)
    for _, item in ipairs(source) do
      local key = tostring(item.id or item.url or "")
      if key == "" or not seen[key] then
        if key ~= "" then seen[key] = true end
        items[#items + 1] = item
      end
    end
  end
  if feedFilter ~= "repositories" then append(state.followingEvents) end
  if feedFilter ~= "users" then append(state.followingRepoEvents) end
  return ui.column({ flexGrow = 1, gap = 8 }, { ui.row({ gap = 4 }, strip), groupedFollowingList(items) })
end

local TABS = {
  { id = "overview", label = "panel.overview", glyph = "layout-dashboard", setting = "show_overview" },
  { id = "notifications", label = "panel.notifications", glyph = "bell", setting = "show_notifications" },
  { id = "work", label = "panel.activity", glyph = "git-pull-request", setting = "show_activity" },
  { id = "following", label = "panel.feed", glyph = "rss", setting = "show_following" },
  { id = "repositories", label = "panel.repositories", glyph = "folder-code", setting = "show_repositories" },
}

local function enabledTabs()
  local tabs = {}
  for _, tab in ipairs(TABS) do
    if noctalia.getConfig(tab.setting) ~= false then tabs[#tabs + 1] = tab end
  end
  return tabs
end

local function body()
  if state.status == "loading" and next(state.profile) == nil then return statusView() end
  if (state.status == "missing_gh" or state.status == "auth_error") and not state.stale then return statusView() end
  if currentTab == "overview" then return overview() end
  if currentTab == "notifications" then return notifications() end
  if currentTab == "work" then return work() end
  if currentTab == "following" then return following() end
  return repositoriesView()
end

render = function()
  local tabs = {}
  local visibleTabs = enabledTabs()
  local currentVisible = false
  for _, tab in ipairs(visibleTabs) do if tab.id == currentTab then currentVisible = true end end
  if not currentVisible and visibleTabs[1] then currentTab = visibleTabs[1].id end
  for _, tab in ipairs(visibleTabs) do
    local id = tab.id
    tabs[#tabs + 1] = ui.button({
      text = tr(tab.label), glyph = tab.glyph, controlSize = "sm",
      variant = currentTab == id and "primary" or "ghost", selected = currentTab == id,
      onClick = function() currentTab = id; hovered = nil; render() end,
    })
  end
  local freshness = state.lastUpdate
  if type(freshness) == "number" then freshness = noctalia.formatTime("%H:%M", freshness) end
  if state.stale then freshness = tr("status.stale") end
  local content = #visibleTabs > 0 and body() or listView({}, "inbox")
  local contentChildren = {}
  if state.status == "partial" or state.status == "auth_error" then
    contentChildren[#contentChildren + 1] = ui.row({ gap = 7, align = "center", padding = 8, radius = cardRadius(), fill = "primary/0.12" }, {
      ui.glyph({ name = "alert-triangle", size = font(15), color = "primary" }),
      ui.label({ text = state.error ~= "" and state.error or tr("status.request_error"), color = "on_surface_variant", fontSize = font(11), maxLines = 2, flexGrow = 1 }),
    })
  end
  contentChildren[#contentChildren + 1] = content
  panel.render(ui.column({ flexGrow = 1, gap = 10 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "brand-github", size = 25, color = "primary" }),
      ui.label({ text = tr("panel.title"), fontSize = font(19), fontWeight = "bold", flexGrow = 1 }),
      ui.label({ text = freshness, fontSize = font(10), color = "on_surface_variant" }),
      ui.button({ glyph = "refresh", variant = "ghost", tooltip = tr("action.refresh"), onClick = function() noctalia.state.set("refresh_request", noctalia.nowMs()) end }),
      ui.button({ glyph = "close", variant = "ghost", tooltip = tr("action.close"), onClick = function() panel.close() end }),
    }),
    ui.row({ gap = 3, align = "center" }, tabs),
    ui.column({ flexGrow = 1, gap = 8 }, contentChildren),
  }))
end

local lastRenderMs = 0
local renderPending = false
local function requestRender()
  -- Space data-driven renders so measurement sees settled trees.
  local now = noctalia.nowMs()
  if now - lastRenderMs < 400 then
    renderPending = true
    panel.setWantsSecondTicks(true)
    return
  end
  lastRenderMs = now
  renderPending = false
  render()
end

local WATCHES = {
  status = "status", error = "error", stale = "stale", lastUpdate = "last_update",
  profile = "profile", contributions = "contributions", notifications = "notifications",
  followingEvents = "following_events", followingRepoEvents = "following_repo_events", prs = "my_prs",
  reviews = "review_prs", authoredIssues = "authored_issues", issues = "issues", repositories = "repositories", actions = "actions",
}
for field, key in pairs(WATCHES) do
  noctalia.state.watch(key, function(value)
    if field == "stale" then state[field] = value == true
    elseif field == "status" then state[field] = value or "loading"
    elseif field == "lastUpdate" or field == "error" then state[field] = value or ""
    else state[field] = value or {} end
    if field == "contributions" then
      resetGrid(state.contributions)
      if panelOpen and gridReady then
        panel.setWantsSecondTicks(true)
        panel.setNeedsFrameTick(true)
      end
    end
    requestRender()
  end)
end

function onContributionHover(value, key)
  if value == "true" and selectedByKey[key] then
    selectedDate = selectedByKey[key].date
  elseif selectedDate and key == "contribution-" .. selectedDate then
    selectedDate = nil
  end
  render()
end

function onOpen()
  panelOpen = true
  panel.setWantsSecondTicks(true)
  if gridReady and not cachedCalendar then
    panel.setNeedsFrameTick(true)
  end
  render()
end

function onClose()
  panelOpen = false
end

function onFrameTick(_deltaMs)
  prepareGrid()
end

function update()
  if renderPending then
    renderPending = false
    lastRenderMs = noctalia.nowMs()
    render()
  end
  prepareGrid()
end

function onConfigChanged()
  currentTab = noctalia.getConfig("default_dashboard") or "overview"
  notificationReadFilter = noctalia.getConfig("notification_default_filter") or "unread"
  prScopeFilter = noctalia.getConfig("pr_default_filter") or "all"
  issueScopeFilter = noctalia.getConfig("issue_default_filter") or "all"
  loadHeatmapAppearance()
  resetGrid(state.contributions)
  if panelOpen and gridReady then
    panel.setWantsSecondTicks(true)
    panel.setNeedsFrameTick(true)
  end
  hovered = nil
  render()
end

render()
