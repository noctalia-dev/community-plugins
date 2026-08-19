--!nonstrict
-- Floating now-playing OSD for Cider. Theme colors only — Noctalia styles the shell.
-- Card size matches other floating OSDs (OpenRazer / Bitwarden): 400×148, 16px inset.

local ART = 64
local title = ""
local artist = ""
local album = ""
local artwork = ""
local progress = 0
local elapsed = "0:00"
local remaining = "0:00"
local panelOpen = false

local function subtitle()
  if album ~= "" and artist ~= "" then
    return artist .. " — " .. album
  end
  return album ~= "" and album or artist
end

local function fmt(ms)
  ms = math.max(0, math.floor((tonumber(ms) or 0) / 1000))
  return string.format("%d:%02d", math.floor(ms / 60), ms % 60)
end

local function render()
  local artBlock
  if artwork ~= "" and noctalia.fileExists(artwork) then
    artBlock = ui.image({
      path = artwork,
      width = ART,
      height = ART,
      radius = 14,
      fit = "cover",
    })
  else
    artBlock = ui.column({
      width = ART,
      height = ART,
      radius = 14,
      fill = "surface_variant",
      align = "center",
      justify = "center",
    }, {
      ui.glyph({ name = "music", size = 26, color = "on_surface_variant" }),
    })
  end

  panel.render(ui.column({
    gap = 12,
    align = "stretch",
    padding = 16,
  }, {
    ui.row({ gap = 14, align = "center" }, {
      artBlock,
      ui.column({ flexGrow = 1, gap = 4, align = "stretch" }, {
        ui.label({
          text = title ~= "" and title or noctalia.tr("osd.not_playing"),
          fontSize = 14,
          fontWeight = "bold",
          color = "on_surface",
          maxLines = 1,
        }),
        ui.label({
          text = subtitle(),
          fontSize = 12,
          color = "on_surface_variant",
          maxLines = 1,
        }),
      }),
    }),
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = elapsed, fontSize = 11, color = "on_surface_variant", width = 34 }),
      ui.progress({
        progress = progress,
        height = 4,
        radius = 2,
        flexGrow = 1,
        fill = "primary",
        track = "surface_variant",
      }),
      ui.label({
        text = remaining,
        fontSize = 11,
        color = "on_surface_variant",
        width = 34,
        textAlign = "end",
      }),
    }),
  }))
end

local function apply(np)
  if type(np) ~= "table" then
    title, artist, album, artwork = "", "", "", ""
    progress, elapsed, remaining = 0, "0:00", "0:00"
    if panelOpen then
      render()
    end
    return
  end
  title = tostring(np.title or "")
  artist = tostring(np.artist or "")
  album = tostring(np.album or "")
  artwork = tostring(np.artwork_path or ""):gsub("^file://", "")
  local dur = tonumber(np.duration_ms) or 0
  local pos = tonumber(np.position_ms) or 0
  progress = dur > 0 and math.min(1, pos / dur) or 0
  elapsed = fmt(pos)
  remaining = fmt(math.max(0, dur - pos))
  if panelOpen then
    render()
  end
end

noctalia.state.watch("now_playing", apply)

function onOpen(_context)
  panelOpen = true
  local cached = noctalia.state.get("now_playing")
  if type(cached) == "table" then
    apply(cached)
  else
    render()
  end
end

function onClose()
  panelOpen = false
end
