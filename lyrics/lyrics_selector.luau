--!nonstrict

-- Alternate-lyrics picker. It can be opened from the control-center shortcut,
-- from the widget's IPC, or by hovering the widget when the current track has
-- more than one match from any lyric source (see `selector_enabled` in the widget settings).

local candidateState = noctalia.state.get("lyrics_candidate_state") or {}
local track = noctalia.state.get("track")
local requestCounter = 0
local dirty = true

local pendingId = ""
local pendingSource = ""
local panelOpen = false
local idleMs = 0
local openedTrackKey = ""
local autoClose = false
local panelHovered = false
local hoveredIndex = 0

-- A hover-opened picker closes itself when it is ignored, so it never lingers
-- over the user's content without interaction.
local AUTO_CLOSE_SECONDS = 8

local function trackKey(value)
  if type(value) ~= "table" then return "" end
  local durationSeconds = math.floor((tonumber(value.duration) or 0) / 1000000)
  return (value.playerInstance or "") .. "|" .. (value.trackId or "") .. "|"
    .. (value.title or "") .. "|" .. (value.artist or "") .. "|" .. (value.album or "")
    .. "|" .. tostring(durationSeconds)
end

local function stateForTrack()
  if type(candidateState) ~= "table" or candidateState.track_key ~= trackKey(track) then return {} end
  return candidateState
end

local function durationLabel(value)
  local seconds = math.max(0, math.floor(tonumber(value) or 0))
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function candidateTitle(candidate)
  local title = tostring(candidate.track_name or "")
  if title == "" then title = noctalia.tr("panel.untitled") end
  return title
end

local SOURCE_NAMES = {
  lrclib = "LRCLIB",
  netease = "NetEase",
  netease_public = "NetEase",
  qqmusic = "QQ Music",
  qq = "QQ Music",
  kugou = "Kugou",
  splayer = "SPlayer",
  splayer_next = "SPlayer Next",
  qishui = "Qishui",
  apple_music = "Apple Music",
  spotify = "Spotify",
  musixmatch = "Musixmatch",
}

local function sourceLabel(candidate)
  local source = tostring(candidate.source or "lrclib")
  return SOURCE_NAMES[source] or source
end

local function trackDurationSeconds()
  if type(track) ~= "table" then return 0 end
  return math.floor((tonumber(track.duration) or 0) / 1000000)
end

local function durationDifference(candidate)
  local wanted = trackDurationSeconds()
  local actual = tonumber(candidate.duration)
  if wanted <= 0 or not actual or actual <= 0 then return 0 end
  return math.floor(actual) - wanted
end

local function candidateMeta(candidate)
  local parts = { sourceLabel(candidate) }
  local artist = tostring(candidate.artist_name or "")
  if artist ~= "" then parts[#parts + 1] = artist end
  if tonumber(candidate.duration) and tonumber(candidate.duration) > 0 then
    parts[#parts + 1] = durationLabel(candidate.duration)
    local delta = durationDifference(candidate)
    if math.abs(delta) > 2 then
      parts[#parts + 1] = string.format(noctalia.tr("panel.duration_delta"), delta)
    end
  end
  if candidate.synced ~= nil then
    local syncLabel = noctalia.tr(candidate.synced == true and "panel.synced" or "panel.unsynced")
    if candidate.format ~= nil and tostring(candidate.format) ~= "" then
      syncLabel = tostring(candidate.format):upper() .. " · " .. syncLabel
    end
    parts[#parts + 1] = syncLabel
  end
  return table.concat(parts, "  ·  ")
end

local render

local function appliedFormatLabel(state)
  local formatName = tostring(state.applied_format or "")
  if formatName == "" then return "" end
  local sync = tostring(state.applied_sync or "")
  local syncKey = { word = "panel.sync_word", line = "panel.sync_line", plain = "panel.sync_plain" }[sync]
  local label = formatName:upper()
  if syncKey then label = label .. " · " .. noctalia.tr(syncKey) end
  return string.format(noctalia.tr("panel.applied_format"), label)
end

local function applyCandidate(index)
  local state = stateForTrack()
  local candidates = type(state.candidates) == "table" and state.candidates or {}
  local candidate = candidates[index]
  if not candidate or not track or pendingId ~= "" or state.loading == true then return end
  local candidateId = tostring(candidate.id or "")
  local candidateSource = tostring(candidate.source or "lrclib")
  if candidateId == "" then return end
  if candidateId == tostring(state.selected_id or "")
    and candidateSource == tostring(state.selected_source or "lrclib") then
    return
  end
  pendingId = candidateId
  pendingSource = candidateSource
  requestCounter = requestCounter + 1
  noctalia.state.set("lyrics_candidate_request", {
    request_id = tostring(os.clock()) .. "-" .. tostring(requestCounter),
    candidate_id = candidateId,
    source = candidateSource,
    track_key = trackKey(track),
  })
  render()
end

local function onRowHover(index, value)
  if value == "true" then
    hoveredIndex = index
    render()
  elseif hoveredIndex == index then
    hoveredIndex = 0
    render()
  end
end

local function candidateRow(candidate, index, selected)
  local candidateId = tostring(candidate.id or index)
  local candidateSource = tostring(candidate.source or "lrclib")
  local pending = pendingId ~= "" and candidateId == pendingId
    and candidateSource == pendingSource
  local active = selected or pending
  local mismatch = math.abs(durationDifference(candidate)) > 2
  local fill = active and "primary_container" or (hoveredIndex == index and "surface_container_high" or "surface_container")
  local titleColor = active and "on_primary_container" or "on_surface"
  local metaColor = active and "on_primary_container" or (mismatch and "error" or "on_surface_variant")
  return ui.row({
    key = "candidate-" .. candidateSource .. "-" .. candidateId,
    fill = fill,
    radius = 8,
    padding = 8,
    gap = 10,
    align = "center",
    opacity = pending and 0.62 or 1,
    onClick = function() applyCandidate(index) end,
    onHover = function(value) onRowHover(index, value) end,
  }, {
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({
        text = candidateTitle(candidate),
        fontSize = 13,
        fontWeight = active and "bold" or "normal",
        color = titleColor,
        maxLines = 1,
      }),
      ui.label({ text = candidateMeta(candidate), fontSize = 11, color = metaColor, maxLines = 1 }),
    }),
    ui.label({
      text = selected and "✓" or (pending and "…" or ""),
      fontSize = 13,
      fontWeight = "bold",
      color = titleColor,
    }),
  })
end

function render()
  dirty = false
  local state = stateForTrack()
  local candidates = type(state.candidates) == "table" and state.candidates or {}
  local selectedCandidateId = tostring(state.selected_id or "")
  local loading = state.loading == true
  local selectionError = tostring(state.error or "")
  local body = {}
  if not track then
    body[#body + 1] = ui.column({ align = "center", justify = "center", gap = 8, flexGrow = 1 }, {
      ui.glyph({ name = "music-off", size = 28, color = "on_surface_variant" }),
      ui.label({ text = noctalia.tr("panel.no_track"), color = "on_surface_variant" }),
    })
  elseif #candidates == 0 then
    body[#body + 1] = ui.column({ align = "center", justify = "center", gap = 8, flexGrow = 1 }, {
      ui.glyph({ name = "list-search", size = 28, color = "on_surface_variant" }),
      ui.label({ text = noctalia.tr("panel.no_candidates"), color = "on_surface_variant" }),
    })
  else
    body[#body + 1] = ui.row({ align = "center", gap = 8 }, {
      ui.label({
        text = string.format(noctalia.tr("panel.candidates_count"), #candidates),
        fontSize = 11,
        fontWeight = "semibold",
        color = "on_surface",
        flexGrow = 1,
      }),
      ui.label({ text = noctalia.tr("panel.apply_hint"), fontSize = 10, color = "on_surface_variant" }),
    })
    local rows = {}
    for index, candidate in ipairs(candidates) do
      local selected = tostring(candidate.id or "") == selectedCandidateId
        and tostring(candidate.source or "lrclib") == tostring(state.selected_source or "lrclib")
      rows[#rows + 1] = candidateRow(candidate, index, selected)
    end
    body[#body + 1] = ui.scroll({
      key = "candidate-list",
      flexGrow = 1,
      gap = 6,
      align = "stretch",
      opacity = loading and not pendingId ~= "" and 0.6 or 1,
    }, rows)
  end

  if pendingId ~= "" then
    body[#body + 1] = ui.label({ text = noctalia.tr("panel.applying"), color = "primary", fontSize = 11 })
  elseif loading then
    body[#body + 1] = ui.label({ text = noctalia.tr("panel.loading"), color = "primary", fontSize = 11 })
  elseif selectionError ~= "" then
    body[#body + 1] = ui.label({ text = noctalia.tr("panel.selection_failed"), color = "error", fontSize = 11 })
  end
  local applied = appliedFormatLabel(state)
  if applied ~= "" then
    body[#body + 1] = ui.label({ text = applied, color = "on_surface_variant", fontSize = 10 })
  end

  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch", onHover = "onPanelHover" }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "list-search", size = 22, color = "primary" }),
      ui.column({ flexGrow = 1, gap = 2 }, {
        ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold" }),
        ui.label({
          text = track and ((track.artist and track.artist ~= "" and track.artist .. " - " or "") .. tostring(track.title or "")) or "",
          color = "on_surface_variant",
          fontSize = 11,
          maxLines = 1,
        }),
      }),
      ui.button({
        text = noctalia.tr("panel.use_best"),
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.use_best_tooltip"),
        onClick = "onUseBest",
      }),
      ui.button({ glyph = "close", variant = "ghost", tooltip = noctalia.tr("panel.close"), onClick = "onCloseClicked" }),
    }),
    ui.column({ flexGrow = 1, gap = 8, align = "stretch" }, body),
  }))
end

local function handleCandidateState(value)
  candidateState = type(value) == "table" and value or {}
  if pendingId == "" then return end
  local state = stateForTrack()
  if tostring(state.selected_id or "") == pendingId
    and tostring(state.selected_source or "lrclib") == pendingSource then
    pendingId = ""
    pendingSource = ""
  elseif tostring(state.error or "") ~= "" then
    pendingId = ""
    pendingSource = ""
  end
end

local function watch(key, transform)
  noctalia.state.watch(key, function(value)
    transform(value)
    if panelOpen then render() end
  end)
end

watch("lyrics_candidate_state", function(value) handleCandidateState(value) end)
watch("track", function(value)
  local previousKey = trackKey(track)
  track = value
  if openedTrackKey ~= "" and trackKey(track) ~= openedTrackKey then
    panel.close()
    return
  end
  if trackKey(track) ~= previousKey and panelOpen then render() end
end)

function onPanelHover(value, _key)
  panelHovered = value == "true"
  idleMs = 0
end

function onOpen(_context)
  if noctalia.getConfig("candidate_mode") == "best" then
    panel.close()
    return
  end
  noctalia.state.set("lyrics_selector_open", true)
  local origin = tostring(noctalia.state.get("lyrics_selector_origin") or "")
  noctalia.state.set("lyrics_selector_origin", "")
  autoClose = origin == "hover"
  openedTrackKey = trackKey(track)
  pendingId = ""
  pendingSource = ""
  hoveredIndex = 0
  panelHovered = false
  idleMs = 0
  panelOpen = true
  panel.setNeedsFrameTick(autoClose)
  render()
end

function onClose()
  noctalia.state.set("lyrics_selector_open", false)
  autoClose = false
  panelOpen = false
  panel.setNeedsFrameTick(false)
end

function onFrameTick(deltaMs)
  if not autoClose then return end
  if panelHovered then
    idleMs = 0
    return
  end
  idleMs = idleMs + (tonumber(deltaMs) or 0)
  if idleMs >= AUTO_CLOSE_SECONDS * 1000 then
    panel.close()
  end
end

function onCloseClicked()
  panel.close()
end

function onUseBest()
  if not track then return end
  -- Empty candidate id asks the service to discard the manual pick and fall
  -- back to the source's best-ranked result.
  pendingId = ""
  pendingSource = ""
  requestCounter = requestCounter + 1
  noctalia.state.set("lyrics_candidate_request", {
    request_id = tostring(os.clock()) .. "-best-" .. tostring(requestCounter),
    candidate_id = "",
    track_key = trackKey(track),
  })
  render()
end

render()
