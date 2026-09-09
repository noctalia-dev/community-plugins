--!nonstrict
-- media-lyrics compact mini panel: cover + current lyric line only.
-- A lightweight always-on karaoke line (pinnable to the desktop) without the
-- full transport/header chrome of the main panel. Reads the same "media"
-- snapshot the service publishes; commands go back over "panel_cmd".
--
-- Layout (single band, 360x120):
--   [cover 64]  title / artist
--               current lyric line (karaoke, primary color)
--
-- The panel is a thin client: state comes from noctalia.state("media"),
-- commands go back over noctalia.state("panel_cmd").

local T = {
  pad = 8,
  gap = 12,
  cover = 64,
  coverRadius = 12,
  fsTitle = 15,
  fsMeta = 12,
  fsLyric = 16,
  colTitle = "on_surface",
  colMeta = "on_surface_variant",
  colLyric = "primary",
  colEmpty = "on_surface_variant",
}

local snap = nil
local lastSnapMs = 0

local function nowMs()
  local ok, v = pcall(function() return noctalia.nowMs() end)
  if ok and type(v) == "number" then return v end
  return os.time() * 1000
end

local function interpPos(s)
  if not s then return 0 end
  if not s.playing then return s.posSec or 0 end
  local elapsed = (lastSnapMs > 0) and ((nowMs() - lastSnapMs) / 1000) or 0
  local p = (s.posSec or 0) + elapsed
  if s.lengthSec and s.lengthSec > 0 and p > s.lengthSec then p = s.lengthSec end
  return p
end

-- 1-based index of the active lyric line at the interpolated position.
local function activeIndex(s)
  local pos = interpPos(s)
  local active = -1
  local n = #(s.lyrics or {})
  for i = 1, n do
    if (s.lyrics[i].time >= 0) and (s.lyrics[i].time <= pos) then active = i end
    if (s.lyrics[i].time >= 0) and (s.lyrics[i].time > pos) then break end
  end
  return active
end

local function buildCover(s)
  local art = s.artUrl or ""
  if art ~= "" then
    return ui.image({ key = "cover", path = art, width = T.cover, height = T.cover,
      fit = "cover", radius = T.coverRadius })
  end
  return ui.box({ key = "coverbox", width = T.cover, height = T.cover,
    fill = "surface_variant/0.6", radius = T.coverRadius }, {
      ui.glyph({ name = "disc", size = 40, color = "on_surface_variant" }),
    })
end

local function render()
  local s = snap
  if not s or not s.hasPlayer then
    panel.render(ui.column({ padding = T.pad, gap = T.gap, align = "center", justify = "center" }, {
      ui.label({ text = noctalia.tr("panel.no-media-player"), fontSize = T.fsMeta, color = T.colEmpty }),
    }))
    return
  end

  local title = (s.title or "") ~= "" and s.title or noctalia.tr("common.no-title")
  local artist = (s.artist or "") ~= "" and s.artist or noctalia.tr("common.unknown-artist")
  local line = ""
  local idx = activeIndex(s)
  if idx >= 1 and s.lyrics and s.lyrics[idx] then
    line = s.lyrics[idx].text or ""
  end

  local info = ui.column({ key = "info", gap = 2, flexGrow = 1 }, {
    ui.label({ text = title, fontSize = T.fsTitle, fontWeight = "semibold", color = T.colTitle, maxLines = 1 }),
    ui.label({ text = artist, fontSize = T.fsMeta, color = T.colMeta, maxLines = 1 }),
    ui.label({ text = line, fontSize = T.fsLyric, color = T.colLyric, maxLines = 2, visible = line ~= "" }),
  })

  panel.render(ui.row({ padding = T.pad, gap = T.gap, align = "center" }, {
    buildCover(s),
    info,
  }))
end

noctalia.state.watch("media", function(value)
  snap = value
  lastSnapMs = nowMs()
  render()
end)

function update()
end
