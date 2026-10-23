--!nonstrict
-- Screen Toolkit — recording save card [[panel]].
--
-- A separate panel the [[service]] opens when a recording stops and the
-- "record-skip-confirmation" setting is off. It previews the raw capture and
-- offers save / play / discard for both formats: GIF saves as-is, a video can
-- still be finalized as MP4 or MOV. The manifest sets
-- "dismiss_on_outside_click = false" on this panel: a pending recording is a
-- destructive choice, so a stray click outside must never dismiss the card and
-- look like it threw the recording away. Closing is explicit — the header
-- Clear (discard) and close buttons — or automatic when the service leaves the
-- "ready" state (save / discard / superseding capture). It is a thin client:
-- it reads the published state and dispatches actions through the "command"
-- channel.

local panelOpen = false

local recordState = noctalia.state.get("recordState") or "idle"
local recordFormat = noctalia.state.get("recordFormat") or "mp4"
local recordInfo = noctalia.state.get("recordInfo")
local saveContainerIndex = 0
local render -- forward for the state watches below

-- ── Helpers ────────────────────────────────────────────────────────────────

local function tr(key, subst)
  if subst then return noctalia.tr(key, subst) end
  return noctalia.tr(key)
end

local function send(action, payload)
  noctalia.state.set("command", { action = action, payload = payload })
end

local function actionButton(glyph, text, onClick, variant)
  return ui.button({
    glyph = glyph,
    text = text,
    controlSize = "sm",
    variant = variant or "default",
    onClick = onClick,
  })
end

local function fmtBytes(bytes)
  if bytes >= 1048576 then
    return string.format("%.1f MB", bytes / 1048576)
  end
  return string.format("%.0f KB", bytes / 1024)
end

local function fmtDuration(seconds)
  seconds = math.floor(seconds + 0.5)
  local h = math.floor(seconds / 3600)
  local m = math.floor((seconds % 3600) / 60)
  local s = seconds % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
  return string.format("%d:%02d", m, s)
end

local function fmtRatio(w, h)
  if not w or not h or w <= 0 or h <= 0 then return "—" end
  local a, b = w, h
  while b ~= 0 do a, b = b, a % b end
  return string.format("%d:%d", w / a, h / a)
end

local function infoTile(label, value)
  return ui.column({ flexGrow = 1, gap = 2, align = "center", paddingH = 6, paddingV = 8, radius = 10, fill = "surface_variant/0.25" }, {
    ui.label({ text = label, fontSize = 10, color = "on_surface_variant" }),
    ui.label({ text = value or "—", fontSize = 13, fontWeight = "bold" }),
  })
end

-- ── Header ─────────────────────────────────────────────────────────────────

local function header()
  -- Clear sits top-right like every other result dialog. Here it discards:
  -- a finished-but-unsaved recording has a raw file to drop (recordDiscard).
  return ui.row({ align = "center", gap = 10 }, {
    ui.column({ width = 36, height = 36, radius = 10, fill = "primary/0.15", align = "center", justify = "center" }, {
      ui.glyph({ name = "video", size = 18, color = "primary" }),
    }),
    ui.label({ text = tr("panel.ready"), flexGrow = 1, fontSize = 16, fontWeight = "bold", color = "on_surface" }),
    ui.button({
      glyph = "trash",
      text = tr("panel.clear"),
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("panel.clear"),
      onClick = function()
        send("recordDiscard")
        panel.close()
      end,
    }),
    ui.button({
      glyph = "close", variant = "ghost", controlSize = "sm", onClick = function() panel.close() end,
    }),
  })
end

-- Recording finished: preview the thumbnail, recording info, then save or
-- play.
local RECORD_THUMB_PATH = "/tmp/screen-toolkit-record-thumb.png"

local function recordSaveCard()
  local isGif = recordFormat == "gif"
  local info = recordInfo or {}
  local actions = {}
  -- Format control on the left, actions flush right — the same shape every
  -- other result dialog uses, and the one the GIF recording already had.
  if isGif then
    table.insert(actions, ui.label({
      text = tr("tools.record_gif"),
      fontSize = 12,
      color = "on_surface_variant",
    }))
  else
    table.insert(actions, ui.select({
      options = { "MP4", "MOV" },
      selectedIndex = saveContainerIndex,
      controlSize = "sm",
      width = 96,
      onChange = function(value)
        saveContainerIndex = tonumber(value) or 0
      end,
    }))
  end
  table.insert(actions, ui.spacer({ flexGrow = 1 }))
  table.insert(actions, actionButton("download", tr("panel.save"), function()
    if isGif then
      send("recordSave")
    else
      send("recordSave", { format = saveContainerIndex == 0 and "mp4" or "mov" })
    end
  end, "primary"))
  -- The preview plays the unsaved raw file, not the finalized destination,
  -- because finalize has not run yet at this point. `onClick` on the thumbnail
  -- is the whole-image hit target (no overlay primitive exists to draw a badge
  -- on top of it), and the button is the discoverable equivalent.
  table.insert(actions, actionButton("player-play", tr("panel.play"), function()
    send("recordPreview")
  end, "secondary"))
  return ui.column({ flexGrow = 1, gap = 10, paddingV = 22 }, {
    -- The panel height is fixed in the manifest and this column packs from
    -- the top, so the image is the one node whose height decides where the
    -- action row lands. Its value is what the 16:9 picture needs at the
    -- content width, so the border hugs the picture rather than boxing a
    -- letterbox; the margin above the header and below the action row comes
    -- from paddingV above, not from inflating this frame. `fit = "contain"`
    -- still matters for other aspect ratios, and `flexGrow` is not a
    -- substitute — an image with no explicit height has no intrinsic size to
    -- rasterize at and drops out of the tree entirely.
    ui.image({
      path = RECORD_THUMB_PATH,
      height = 299,
      fit = "contain",
      radius = 12,
      borderWidth = 1,
      border = "outline",
      onClick = function() send("recordPreview") end,
    }),
    ui.row({ gap = 8 }, {
      infoTile(tr("panel.record_size"), fmtBytes(info.size or 0)),
      infoTile(tr("panel.record_duration"), fmtDuration(info.duration or 0)),
      infoTile(tr("panel.record_ratio"), fmtRatio(info.width, info.height)),
    }),
    ui.row({ gap = 6, align = "center" }, actions),
  })
end

local function emptyState(glyph, text)
  return ui.column({ flexGrow = 1, gap = 10, align = "center", justify = "center" }, {
    ui.glyph({ name = glyph, size = 30, color = "outline" }),
    ui.label({ text = text, fontSize = 12, color = "on_surface_variant" }),
  })
end

-- ── Render ─────────────────────────────────────────────────────────────────

render = function()
  panel.render(ui.column({ flexGrow = 1, gap = 10 }, {
    header(),
    if recordState == "ready" then recordSaveCard() else emptyState("video", tr("panel.ready")),
  }))
end

-- ── Lifecycle ──────────────────────────────────────────────────────────────

function onOpen(_context)
  panelOpen = true
  saveContainerIndex = 0
  recordState = noctalia.state.get("recordState") or "idle"
  recordFormat = noctalia.state.get("recordFormat") or "mp4"
  recordInfo = noctalia.state.get("recordInfo")
  render()
end

function onClose()
  panelOpen = false
end

noctalia.state.watch("recordState", function(v)
  if recordState == "ready" and v ~= "ready" then
    panel.close()
    return
  end
  recordState = v or "idle"
  if panelOpen then render() end
end)
noctalia.state.watch("recordFormat", function(v) recordFormat = v or "mp4"; if panelOpen then render() end end)
noctalia.state.watch("recordInfo", function(v) recordInfo = v; if panelOpen then render() end end)
