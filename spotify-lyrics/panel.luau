--!nonstrict
-- Spotify Lyrics Panel – 3-line synced lyrics view with album art.
--
-- Reads state from noctalia.state (published by service.luau) or directly
-- from disk fallback, and renders album art + prev / current / next lyric lines.

local STATE_PATH = noctalia.expandPath("~/.cache/noctalia/lyrics/current.json")

--------------------------------------------------------------------------------
-- Layout constants
--------------------------------------------------------------------------------
local PANEL_WIDTH   = 460
local PANEL_PADDING = 16
local INNER_WIDTH   = PANEL_WIDTH - PANEL_PADDING * 2  -- 428px usable
local PANEL_HEIGHT  = 280  -- matches plugin.toml height exactly
local ART_SIZE      = 80   -- album art thumbnail size

--------------------------------------------------------------------------------
-- Dynamic font sizing
--------------------------------------------------------------------------------

local function fitFontSize(text, defaultSize)
  if not text or text == "" then return defaultSize end
  local len = #text
  if len <= 40 then return defaultSize end
  local reduction = math.floor((len - 40) / 15) * 2
  return math.max(10, defaultSize - reduction)
end

--------------------------------------------------------------------------------
-- Text truncation
--------------------------------------------------------------------------------

local function clampText(text, fontSize, maxLines)
  if not text or text == "" then return text end
  local charsPerLine = math.max(1, math.floor(INNER_WIDTH / (fontSize * 0.60)))
  local maxChars = charsPerLine * maxLines
  if #text > maxChars then
    return string.sub(text, 1, maxChars - 1) .. "…"
  end
  return text
end

--------------------------------------------------------------------------------
-- State Reader
--------------------------------------------------------------------------------

local function readStateFromFile()
  local content = noctalia.readFile(STATE_PATH)
  if not content or content == "" then return nil end
  local ok, state = pcall(function() return noctalia.json.decode(content) end)
  if ok and type(state) == "table" then return state end
  return nil
end

local function getState()
  local status = noctalia.state.get("lyricsStatus")
  if status and status ~= "" then
    return {
      status   = status,
      title    = noctalia.state.get("lyricsTitle")    or "",
      artist   = noctalia.state.get("lyricsArtist")   or "",
      prev     = noctalia.state.get("lyricsPrev")     or "",
      current  = noctalia.state.get("lyricsCurrent")  or "",
      next     = noctalia.state.get("lyricsNext")     or "",
      art_path = noctalia.state.get("lyricsArtPath")  or "",
    }
  end

  local fileState = readStateFromFile()
  if fileState then
    return {
      status   = fileState.status   or "",
      title    = fileState.title    or "",
      artist   = fileState.artist   or "",
      prev     = fileState.prev     or "",
      current  = fileState.current  or "",
      next     = fileState.next     or "",
      art_path = fileState.art_path or "",
    }
  end

  return {
    status = "", title = "", artist = "",
    prev = "", current = "", next = "", art_path = ""
  }
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

local function renderEmpty()
  panel.render(ui.column({
    flexGrow = 1, gap = 8, align = "stretch", justify = "center",
    padding = PANEL_PADDING,
    minWidth = PANEL_WIDTH, height = PANEL_HEIGHT,
  }, {
    ui.row({ justify = "center" }, {
      ui.glyph({ name = "music", size = 28, color = "on_surface/0.2" }),
    }),
    ui.label({
      text = "No music playing",
      fontSize = 14, fontWeight = "medium",
      color = "on_surface/0.25", textAlign = "center",
    }),
  }))
end

local function renderPaused(title, artist, current, artPath)
  local headerChildren = {}

  -- Album art (if available)
  if artPath ~= "" then
    table.insert(headerChildren, ui.image({
      path = artPath,
      width = 60, height = 60,
      cornerRadius = 8,
    }))
  else
    table.insert(headerChildren, ui.glyph({ name = "player-pause", size = 22, color = "on_surface/0.3" }))
  end

  -- Title + artist beside the art
  table.insert(headerChildren, ui.column({ gap = 2, flexGrow = 1, flexShrink = 1 }, {
    ui.label({
      text = title or "Paused",
      fontSize = 13, fontWeight = "bold",
      color = "on_surface/0.5", wrap = true, maxLines = 1,
    }),
    ui.label({
      text = artist or "",
      fontSize = 11, fontWeight = "medium",
      color = "on_surface/0.35", wrap = true, maxLines = 1,
    }),
  }))

  panel.render(ui.column({
    flexGrow = 1, gap = 8, align = "stretch", justify = "center",
    padding = PANEL_PADDING,
    minWidth = PANEL_WIDTH, height = PANEL_HEIGHT,
  }, {
    ui.row({ gap = 12, align = "center", justify = "center" }, headerChildren),
    ui.label({
      text = current or "Paused",
      fontSize = 18, fontWeight = "bold",
      color = "on_surface/0.6", textAlign = "center", wrap = true,
    }),
  }))
end

local function renderPlaying(title, artist, prev, current, nextLine, artPath)
  local rows = {}

  -- ── Track header: album art + song info ──
  if title ~= "" and artist ~= "" then
    local headerChildren = {}

    -- Album art
    if artPath ~= "" then
      table.insert(headerChildren, ui.image({
        path = artPath,
        width = ART_SIZE, height = ART_SIZE,
        cornerRadius = 8,
      }))
    end

    -- Title + artist stacked vertically, beside the art
    table.insert(headerChildren, ui.column({ gap = 2, flexGrow = 1, flexShrink = 1 }, {
      ui.label({
        text = title,
        fontSize = 13, fontWeight = "bold",
        color = "on_surface/0.9", wrap = true, maxLines = 2,
      }),
      ui.label({
        text = artist,
        fontSize = 11, fontWeight = "medium",
        color = "primary/0.7", wrap = true, maxLines = 1,
      }),
    }))

    table.insert(rows, ui.row({ gap = 12, align = "center" }, headerChildren))
    table.insert(rows, ui.box({ height = 1, fill = "on_surface/0.06" }))
  end

  -- ── Previous lyric ──
  if prev ~= "" then
    local prevSize = fitFontSize(prev, 14)
    table.insert(rows, ui.label({
      text = clampText(prev, prevSize, 2),
      fontSize = prevSize, fontWeight = "medium",
      color = "on_surface/0.4", textAlign = "center", wrap = true,
      maxLines = 2,
    }))
  else
    table.insert(rows, ui.box({ height = 16 }))
  end

  -- ── Current lyric ──
  local currentText = current
  if currentText == "" then currentText = "..." end
  local currentSize = fitFontSize(currentText, 18)
  table.insert(rows, ui.label({
    text = clampText(currentText, currentSize, 3),
    fontSize = currentSize, fontWeight = "bold",
    color = "on_surface/0.95", textAlign = "center", wrap = true,
    maxLines = 3,
  }))

  -- ── Next lyric ──
  if nextLine ~= "" then
    local nextSize = fitFontSize(nextLine, 14)
    table.insert(rows, ui.label({
      text = clampText(nextLine, nextSize, 2),
      fontSize = nextSize, fontWeight = "medium",
      color = "on_surface/0.4", textAlign = "center", wrap = true,
      maxLines = 2,
    }))
  else
    table.insert(rows, ui.box({ height = 16 }))
  end

  panel.render(ui.column({
    flexGrow = 1, gap = 8, align = "stretch", justify = "center",
    padding = PANEL_PADDING,
    minWidth = PANEL_WIDTH, height = PANEL_HEIGHT,
  }, rows))
end

--------------------------------------------------------------------------------
-- Full re-render
--------------------------------------------------------------------------------

local function renderFromState()
  local state = getState()

  if state.status == "" or state.status == "Stopped" then
    renderEmpty()
  elseif state.status == "Paused" then
    renderPaused(state.title, state.artist, state.current, state.art_path)
  else
    renderPlaying(state.title, state.artist, state.prev, state.current, state.next, state.art_path)
  end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function onOpen()
  renderFromState()

  noctalia.state.watch("lyricsTick", function(_tick)
    renderFromState()
  end)
end
