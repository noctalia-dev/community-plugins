--!nonstrict

local candidateState = noctalia.state.get("lyrics_candidate_state") or {}
local track = noctalia.state.get("track")
local requestCounter = 0
local dirty = true

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

local function candidateLabel(candidate)
  local parts = {}
  local title = tostring(candidate.track_name or "")
  local artist = tostring(candidate.artist_name or "")
  if title ~= "" then parts[#parts + 1] = title end
  if artist ~= "" then parts[#parts + 1] = artist end
  if tonumber(candidate.duration) and tonumber(candidate.duration) > 0 then
    parts[#parts + 1] = durationLabel(candidate.duration)
  end
  parts[#parts + 1] = noctalia.tr(candidate.synced == true and "panel.synced" or "panel.unsynced")
  return table.concat(parts, "  ·  ")
end

local function selectedIndex()
  local state = stateForTrack()
  local candidates = type(state.candidates) == "table" and state.candidates or {}
  local selectedCandidateId = tostring(state.selected_id or "")
  for index, candidate in ipairs(candidates) do
    if tostring(candidate.id or "") == selectedCandidateId then return index - 1 end
  end
  return 0
end

local function render()
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
    local options = {}
    for _, candidate in ipairs(candidates) do options[#options + 1] = candidateLabel(candidate) end
    body[#body + 1] = ui.label({ text = noctalia.tr("panel.result"), color = "on_surface_variant", fontSize = 11 })
    body[#body + 1] = ui.select({
      key = "lyrics-candidate-" .. selectedCandidateId,
      options = options,
      selectedIndex = selectedIndex(),
      enabled = not loading,
      onChange = "onCandidateChange",
    })
  end

  if loading then
    body[#body + 1] = ui.label({ text = noctalia.tr("panel.loading"), color = "primary", fontSize = 11 })
  elseif selectionError ~= "" then
    body[#body + 1] = ui.label({ text = noctalia.tr("panel.selection_failed"), color = "error", fontSize = 11 })
  end

  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
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
      ui.button({ glyph = "close", variant = "ghost", tooltip = noctalia.tr("panel.close"), onClick = "onCloseClicked" }),
    }),
    ui.column({ flexGrow = 1, gap = 8, align = "stretch" }, body),
  }))
end

local function watch(key, transform)
  noctalia.state.watch(key, function(value)
    transform(value)
    dirty = true
  end)
end

watch("lyrics_candidate_state", function(value) candidateState = type(value) == "table" and value or {} end)
watch("track", function(value) track = value end)

function onOpen(_context)
  noctalia.state.set("lyrics_selector_open", true)
  dirty = true
  render()
end

function onClose()
  noctalia.state.set("lyrics_selector_open", false)
end

function update()
  if dirty then render() end
end

function onCloseClicked()
  panel.close()
end

function onCandidateChange(index, _label)
  local state = stateForTrack()
  local candidates = type(state.candidates) == "table" and state.candidates or {}
  local selectedCandidateId = tostring(state.selected_id or "")
  local candidate = candidates[(math.floor(tonumber(index) or 0)) + 1]
  if not candidate or tostring(candidate.id or "") == selectedCandidateId or not track then return end
  requestCounter = requestCounter + 1
  noctalia.state.set("lyrics_candidate_request", {
    request_id = tostring(os.clock()) .. "-" .. tostring(requestCounter),
    candidate_id = tostring(candidate.id or ""),
    track_key = trackKey(track),
  })
end

render()
