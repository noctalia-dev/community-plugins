--!nonstrict
-- Lyrics panel: 3-line synced view (prev / current / next).
-- Anchored to the bar widget so it feels like part of the media controls.

local function readState()
  local content = noctalia.readFile("~/.cache/noctalia/lyrics/current.json")
  if not content then return nil end
  local state, _ = noctalia.json.decode(content)
  return state
end

local function render()
  local state = readState()

  -- No music
  if not state or state.status == "Stopped" or state.status == "" then
    panel.render(ui.column({ flexGrow = 1, gap = 8, align = "stretch", justify = "center", padding = 16 }, {
      ui.row({ justify = "center" }, { ui.glyph({ name = "music", size = 28, color = "on_surface/0.2" }) }),
      ui.label({ text = "No music playing", fontSize = 14, fontWeight = "medium", color = "on_surface/0.25", textAlign = "center" }),
    }))
    return
  end

  -- Paused
  if state.status == "Paused" then
    panel.render(ui.column({ flexGrow = 1, gap = 6, align = "stretch", justify = "center", padding = 16 }, {
      ui.row({ gap = 6, justify = "center", align = "center" }, {
        ui.glyph({ name = "player-pause", size = 16, color = "on_surface/0.3" }),
        ui.label({
          text = `{state.title or "Paused"} — {state.artist or ""}`,
          fontSize = 12,
          fontWeight = "medium",
          color = "on_surface/0.4",
          textAlign = "center",
          wrap = true,
        }),
      }),
      ui.label({
        text = state.current or "Paused",
        fontSize = 18,
        fontWeight = "bold",
        color = "on_surface/0.6",
        textAlign = "center",
        wrap = true,
      }),
    }))
    return
  end

  -- ── Playing ──

  local rows = {}

  -- Track header
  if state.title and state.artist then
    table.insert(rows, ui.column({ gap = 4, align = "stretch" }, {
      ui.row({ justify = "center" }, { ui.glyph({ name = "music", size = 14, color = "primary/0.7" }) }),
      ui.label({
        text = `{state.title} • {state.artist}`,
        fontSize = 12,
        fontWeight = "medium",
        color = "primary/0.7",
        textAlign = "center",
        wrap = true,
      }),
    }))
    table.insert(rows, ui.box({ height = 1, fill = "on_surface/0.06" }))
  end

  -- Previous line (faded)
  local prevText = state.prev or ""
  if prevText ~= "" then
    table.insert(rows, ui.label({
      text = prevText,
      fontSize = 14,
      fontWeight = "medium",
      color = "on_surface/0.4",
      wrap = true,
      textAlign = "center",
    }))
  else
    table.insert(rows, ui.box({ height = 16 }))
  end

  -- Current line (bold, prominent)
  table.insert(rows, ui.label({
    text = state.current or "...",
    fontSize = 18,
    fontWeight = "bold",
    color = "on_surface/0.95",
    wrap = true,
    textAlign = "center",
  }))

  -- Next line (faded)
  local nextText = state.next or ""
  if nextText ~= "" then
    table.insert(rows, ui.label({
      text = nextText,
      fontSize = 14,
      fontWeight = "medium",
      color = "on_surface/0.4",
      wrap = true,
      textAlign = "center",
    }))
  else
    table.insert(rows, ui.box({ height = 16 }))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 8, align = "stretch", justify = "center", padding = 16 }, rows))
end

noctalia.state.watch("lyricsTick", function(_value)
  render()
end)

function onOpen(_context)
  render()
end
