--!nonstrict
-- Compact Cider now-playing bar widget.
-- Only re-render on identity/playing changes — position ticks must not flash opacity.
-- Hide entirely when nothing is active (no title/artist).
-- Clicks: [widget.actions] in plugin.toml (left = lyrics HUD, right = show OSD).

local showCover = noctalia.getConfig("show_cover")
if showCover == nil then showCover = true end
local coverSize = tonumber(noctalia.getConfig("cover_size")) or 18
local glyphName = noctalia.getConfig("glyph")
if type(glyphName) ~= "string" or glyphName == "" then
  glyphName = "music"
end

local title = ""
local artist = ""
local artwork = ""
local playing = false
local lastRenderKey = ""
local visible = true

local function hasTrack()
  return title ~= "" or artist ~= ""
end

local function setChipVisible(want)
  want = want == true
  if want == visible then
    return
  end
  visible = want
  barWidget.setVisible(want)
end

local function renderKey()
  return table.concat({
    title,
    artist,
    artwork,
    playing and "1" or "0",
    showCover and "1" or "0",
    tostring(coverSize),
    glyphName,
    hasTrack() and "1" or "0",
  }, "|")
end

local function render(force)
  local key = renderKey()
  if not force and key == lastRenderKey then
    return
  end
  lastRenderKey = key

  if not hasTrack() then
    setChipVisible(false)
    return
  end
  setChipVisible(true)

  local children = {}
  if showCover and artwork ~= "" and noctalia.fileExists(artwork) then
    children[#children + 1] = ui.image({
      path = artwork,
      width = coverSize,
      height = coverSize,
      radius = math.floor(coverSize / 4),
      fit = "cover",
    })
  else
    children[#children + 1] = ui.glyph({
      name = glyphName,
      size = coverSize - 2,
      color = "on_surface",
    })
  end
  local label = title
  if artist ~= "" then
    label = title ~= "" and (title .. " · " .. artist) or artist
  end
  -- Stable color — never opacity-pulse on playback_state flicker.
  local color = playing and "on_surface" or "on_surface/0.7"
  children[#children + 1] = ui.label({
    text = label,
    maxLines = 1,
    color = color,
  })
  barWidget.render(ui.row({ gap = 6, align = "center" }, children))
end

local function applyNowPlaying(np)
  local nextTitle = ""
  local nextArtist = ""
  local nextArtwork = ""
  local nextPlaying = false
  if type(np) == "table" then
    nextTitle = tostring(np.title or "")
    nextArtist = tostring(np.artist or "")
    nextArtwork = tostring(np.artwork_path or ""):gsub("^file://", "")
    nextPlaying = np.playback_state == "playing"
  end
  if nextTitle == title and nextArtist == artist and nextArtwork == artwork and nextPlaying == playing then
    -- Still force-hide if we somehow rendered while empty.
    if not hasTrack() then
      setChipVisible(false)
    end
    return
  end
  title, artist, artwork, playing = nextTitle, nextArtist, nextArtwork, nextPlaying
  render(false)
end

noctalia.state.watch("now_playing", applyNowPlaying)

noctalia.state.watch("playing", function(v)
  local nextPlaying = v == true
  if nextPlaying == playing then
    return
  end
  playing = nextPlaying
  render(false)
end)

function onConfigChanged()
  showCover = noctalia.getConfig("show_cover")
  if showCover == nil then showCover = true end
  coverSize = tonumber(noctalia.getConfig("cover_size")) or 18
  glyphName = noctalia.getConfig("glyph")
  if type(glyphName) ~= "string" or glyphName == "" then
    glyphName = "music"
  end
  lastRenderKey = ""
  render(true)
end

-- Seed once from cache; no periodic update() — that was flashing grey/white.
applyNowPlaying(noctalia.state.get("now_playing"))
