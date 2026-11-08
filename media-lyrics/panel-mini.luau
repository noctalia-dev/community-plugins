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

-- ── padding ────────────────────────────────────────────────────────────────
-- The host already insets panel content by ~13 px on every side. Measured on a
-- live render: a root row with padding = 0 still leaves 13 px of panel
-- background at the left edge, and our padding adds 1:1 on top of that - so
-- padding = 8 produced a 21 px left margin. That base inset is already the
-- same order as the cover-to-text gap (12 px), which is the spacing the panel
-- should have everywhere, so the root row carries no padding of its own.
-- Adding our own only doubled the top/left margins (bug: top/left looked far
-- too airy while the bottom sat almost flush).
local PANEL_PAD = 0

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

-- Text column width in the 360 px mini panel: width minus root padding
-- (8*2), the cover and its gap (64+12) = 268 px.
--
-- The lyric label MUST carry maxWidth: without an explicit bound the host does
-- not wrap the label at all - it draws the line straight through the panel edge
-- and clips mid-word (bug: a long lyric line was cut at the right edge while
-- the two-line height budget sat unused).
--
-- The host's wrap test is a few px optimistic vs what it actually inks: measured
-- on this host, a line accepted at maxWidth=268 rendered its last glyph ~5 px
-- past the bound (and flush against the panel border). So the label gets a
-- small safety gutter - the wrap now lands a couple of px inside the edge
-- instead of kissing it. Measured live, not guessed.
local INFO_W = 268   -- 360 - host inset 13 - cover 64 - gap 12 - 3 slack (measured)
local TEXT_W = INFO_W - 12

-- Line height heuristic shared with the main panel: floor(fs * 1.35 + 0.5).
local function lineH(fs)
  return math.floor(fs * 1.35 + 0.5)
end

-- The lyric label holds at most two sub-lines. Its row gets a FIXED height
-- for that worst case: when the text wraps 1 <-> 2 sub-lines the label
-- changes height, and the root row's align="center" re-centers everything —
-- the cover visibly shifted down whenever a long line wrapped (bug 2026-09-09).
-- Reserving the full two-line height makes the info column height CONSTANT,
-- so the vertical centering never moves. Extra space sits under the lyric.
local LYRIC_ROW_H = 2 * lineH(T.fsLyric)

local function render()
  local s = snap
  if not s or not s.hasPlayer then
    panel.render(ui.column({ padding = PANEL_PAD, gap = T.gap, align = "center", justify = "center" }, {
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
    ui.label({ text = title, fontSize = T.fsTitle, fontWeight = "semibold", color = T.colTitle, maxLines = 1, maxWidth = TEXT_W }),
    ui.label({ text = artist, fontSize = T.fsMeta, color = T.colMeta, maxLines = 1, maxWidth = TEXT_W }),
    -- Fixed-height wrapper row: the label inside may render 1 or 2 sub-lines,
    -- but the row always occupies the same vertical budget.
    ui.row({ key = "lyricRow", height = LYRIC_ROW_H, align = "start" }, {
      ui.label({ text = line, fontSize = T.fsLyric, color = T.colLyric, maxLines = 2,
        maxWidth = TEXT_W, visible = line ~= "" }),
    }),
  })

  panel.render(ui.row({ padding = PANEL_PAD, gap = T.gap, align = "center" }, {
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
