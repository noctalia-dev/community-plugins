--!nonstrict
-- Bangumi Progress bar widget: configurable collection or calendar counts.
-- Data requests go through the service; this widget never accesses the network.

local PANEL_ID = "mirei124/bangumi-progress:library"
local COUNT_TYPES = { wish = 1, completed = 2, watching = 3, on_hold = 4, dropped = 5 }
local snapshot = noctalia.state.get("bgm_snapshot") or {}
local open = false
local lastRequestKey = nil
local lastRequestAt = nil
local lastWaiting = snapshot.loading == true or snapshot.oauthBusy == true

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function tr(key, subst)
  return noctalia.tr("bar." .. key, subst)
end

local function countMode()
  local mode = noctalia.getConfig("count_mode") or "newly_unwatched"
  if COUNT_TYPES[mode] or mode == "none" or mode == "today_watching" or mode == "today_all" or mode == "newly_unwatched" then return mode end
  return "newly_unwatched"
end

local function collectionOf(collectionType)
  for _, collection in ipairs(snapshot.collections or {}) do
    if collection.type == collectionType then return collection end
  end
  return nil
end

local function fresh(fetchedAt)
  local at, now = tonumber(fetchedAt) or 0, os.time()
  local ttl = math.max(30000, (tonumber(noctalia.getConfig("refresh_minutes")) or 30) * 60000)
  return at > 0 and now >= at and (now - at) * 1000 < ttl
end

local function errorText(error)
  if error == "not_configured" then return tr("tooltip_not_configured") end
  if error == "unauthorized" then return tr(if snapshot.authSource == "oauth" then "tooltip_oauth_unauthorized" else "tooltip_unauthorized") end
  if error == "forbidden" then return tr("tooltip_forbidden") end
  if error == "network" then return tr("tooltip_network") end
  return error
end

local function collectionCount(collectionType)
  local collection = collectionOf(collectionType)
  local count = (snapshot.barCounts or {})[tostring(collectionType)]
  local total, fetchedAt
  local error = count and count.error
  if collection and collection.loaded and type(collection.total) == "number"
    and (not count or (collection.fetchedAt or 0) >= (count.fetchedAt or 0)) then
    total, fetchedAt = collection.total, collection.fetchedAt
    error = count and count.error
  elseif count and type(count.total) == "number" then
    total, fetchedAt, error = count.total, count.fetchedAt, count.error
  end
  if collectionType == 3 and snapshot.error and snapshot.error ~= "" then error = snapshot.error end
  return total, not fresh(fetchedAt), error
end

local function todayCount(mode)
  local calendar = snapshot.calendar
  local watching = collectionOf(3)
  if not calendar or not calendar.loaded or (mode == "today_watching" and (not watching or not watching.loaded)) then
    local error = calendar and calendar.error
    if mode == "today_watching" and (not watching or not watching.loaded)
      and snapshot.error and snapshot.error ~= "" then error = snapshot.error end
    return nil, true, error
  end
  local today = os.date("%Y-%m-%d")
  local weekday = tonumber(os.date("%w"))
  weekday = if weekday == 0 then 7 else weekday
  local watchingIds = {}
  if mode == "today_watching" then
    for _, row in ipairs(watching.rows or {}) do watchingIds[row.subjectId] = true end
  end
  local seen, total = {}, 0
  for _, day in ipairs(calendar.days or {}) do
    if day.weekday == weekday then
      for _, row in ipairs(day.rows or {}) do
        -- Reference weekday and subject premiere date do not confirm a new episode.
        local id = row.subjectId
        if id and not seen[id] and (row.airDate == nil or row.airDate <= today)
          and (mode == "today_all" or watchingIds[id]) then
          seen[id] = true
          total += 1
        end
      end
    end
  end
  local stale = not fresh(calendar.fetchedAt)
  local error = calendar.error
  if mode == "today_watching" then
    stale = stale or not fresh(watching.fetchedAt)
    if snapshot.error and snapshot.error ~= "" then error = snapshot.error end
  end
  return total, stale, error
end

local function render()
  barWidget.setGlyph(noctalia.getConfig("glyph") or "device-tv")
  barWidget.setGlyphColor(if open then "primary" else "on_surface")
  local mode = countMode()
  if mode == "none" then
    barWidget.setText("")
    barWidget.setTooltip(tr("tooltip_icon_only"))
    return
  end
  local total, stale, error, message
  if COUNT_TYPES[mode] then
    total, stale, error = collectionCount(COUNT_TYPES[mode])
  elseif mode == "today_watching" or mode == "today_all" then
    total, stale, error = todayCount(mode)
  else
    local watching = collectionOf(3)
    total = snapshot.unwatched
    stale = not watching or not fresh(watching.fetchedAt)
    error = snapshot.error
    if type(total) == "number" then
      local series = watching and watching.loaded and watching.total or 0
      message = tr(if total > 0 then "tooltip_unwatched" else "tooltip_all_caught_up", { count = total, series = series })
    elseif watching and watching.loaded and #(watching.rows or {}) == 0 and (not error or error == "") then
      barWidget.setText("")
      barWidget.setTooltip(tr("tooltip_empty"))
      return
    end
  end
  if type(total) ~= "number" then
    barWidget.setText("")
    local unknownError = if error and error ~= "" then error else snapshot.error
    if unknownError and unknownError ~= "" and mode ~= "today_all" then
      barWidget.setTooltip(errorText(unknownError))
    elseif mode == "today_all" and snapshot.calendar and snapshot.calendar.error ~= "" then
      barWidget.setTooltip(errorText(snapshot.calendar.error))
    else
      barWidget.setTooltip(tr("tooltip_loading"))
    end
    return
  end
  message = message or tr("tooltip_mode_" .. mode, { count = total })
  if error and error ~= "" then
    message = tr("tooltip_cached_error", { message = message, error = errorText(error) })
  elseif stale then
    message = tr("tooltip_cached", { message = message })
  end
  barWidget.setText(tostring(total))
  barWidget.setTooltip(message)
end

local function requestData(force)
  local mode = countMode()
  if mode == "none" then lastRequestKey = nil; return end
  local viewer = snapshot.viewer or {}
  local key = mode .. ":" .. tostring(snapshot.authSource) .. ":" .. tostring(viewer.id or viewer.username or "")
    .. ":" .. tostring(snapshot.oauthExpiresAt or "")
  local now = noctalia.nowMs()
  if not force and key == lastRequestKey and lastRequestAt and now >= lastRequestAt and now - lastRequestAt < 60000 then return end
  -- Remember before publishing: service callbacks can synchronously update state.
  lastRequestKey, lastRequestAt = key, now
  noctalia.state.set("bgm_command", { action = "load_bar_data", mode = mode })
end

noctalia.state.watch("bgm_open", function(value)
  open = value == true
  render()
end)

noctalia.state.watch("bgm_snapshot", function(value)
  if type(value) == "table" then
    local wasWaiting = lastWaiting
    snapshot = value
    lastWaiting = snapshot.loading == true or snapshot.oauthBusy == true
    render()
    requestData(wasWaiting and not lastWaiting)
  end
end)

function update()
  render() -- Local midnight changes the weekday even while the service cache is fresh.
  requestData(false)
end

function onConfigChanged()
  render()
  requestData(true)
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
  local username = snapshot.viewer and snapshot.viewer.username
  if username and username ~= "" then
    noctalia.runAsync("xdg-open " .. shellQuote("https://bgm.tv/user/" .. username) .. " >/dev/null 2>&1")
  else
    noctalia.openSettings()
  end
end

noctalia.setUpdateInterval(60000)
render()
requestData(false)

-- The host invokes entry points by name.
local _ = { update, onConfigChanged, onClick, onRightClick }
