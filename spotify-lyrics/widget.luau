--!nonstrict
-- Spotify Lyrics desktop widget.
-- Reads current lyrics state written by the Python daemon.
-- Displays 3 lines: previous → current (highlighted) → next.

local function render(lyricsState)
  -- When idle or paused, show a minimal status indicator
  if not lyricsState or lyricsState.status == "Stopped" or lyricsState.status == "" then
    desktopWidget.render(ui.column({ gap = 8, align = "center" }, {
      ui.glyph({ name = "music", size = 28, color = "on_surface/0.3" }),
      ui.label({
        text = "No music playing",
        fontSize = 16,
        fontWeight = "medium",
        color = "on_surface/0.3",
      }),
    }))
    return
  end

  if lyricsState.status == "Paused" then
    desktopWidget.render(ui.column({ gap = 8, align = "center" }, {
      ui.glyph({ name = "player-pause", size = 22, color = "on_surface/0.4" }),
      ui.label({
        text = lyricsState.current or "Paused",
        fontSize = 22,
        fontWeight = "bold",
        color = "on_surface/0.5",
      }),
    }))
    return
  end

  -- ── Playing: render 3-line synced lyrics ──

  local rows = {}

  -- Track info: small, subtle line at the top
  if lyricsState.title and lyricsState.artist then
    table.insert(rows, ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "music", size = 12, color = "primary/0.7" }),
      ui.label({
        text = `{lyricsState.title} — {lyricsState.artist}`,
        fontSize = 11,
        fontWeight = "medium",
        color = "primary/0.6",
      }),
    }))
  end

  -- Thin separator
  table.insert(rows, ui.box({ height = 1, fill = "on_surface/0.08" }))

  -- Previous line (dimmed)
  local prevText = lyricsState.prev or ""
  if prevText ~= "" then
    table.insert(rows, ui.label({
      text = prevText,
      fontSize = 18,
      fontWeight = "normal",
      color = "on_surface/0.3",
    }))
  else
    table.insert(rows, ui.box({ height = 18 })) -- spacer to keep layout stable
  end

  -- Current line (bold, large, highlighted)
  local currentText = lyricsState.current or "..."
  table.insert(rows, ui.label({
    text = currentText,
    fontSize = 26,
    fontWeight = "bold",
    color = "on_surface",
  }))

  -- Next line (dimmed)
  local nextText = lyricsState.next or ""
  if nextText ~= "" then
    table.insert(rows, ui.label({
      text = nextText,
      fontSize = 18,
      fontWeight = "normal",
      color = "on_surface/0.3",
    }))
  else
    table.insert(rows, ui.box({ height = 18 })) -- spacer
  end

  desktopWidget.render(ui.column({ gap = 10, align = "center" }, rows))
end

function update()
  -- 100ms refresh for tight sync
  noctalia.setUpdateInterval(100)

  local path = "~/.cache/noctalia/lyrics/current.json"
  local content = noctalia.readFile(path)
  if content then
    local state, err = noctalia.json.decode(content)
    if state then
      render(state)
      return
    end
  end

  render(nil)
end
