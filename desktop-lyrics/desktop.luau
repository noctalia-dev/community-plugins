--!nonstrict
-- Desktop widget: the lyric overlay itself. Renders with ui.* only, so it is
-- drawn by the shell on the desktop layer and needs no external renderer.

local function cfg(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil then
    return fallback
  end
  return value
end

local function align()
  local value = cfg("text_align", "center")
  if value == "start" or value == "end" then
    return value
  end
  return "center"
end

local function isHidden()
  if not cfg("enabled", true) then
    return true
  end
  if noctalia.state.get("lyrics_hidden") == true then
    return true
  end
  local status = noctalia.state.get("status") or "idle"
  if status == "idle" or status == "off" or status == "filtered" or status == "hidden" then
    return true
  end
  if status == "notfound" or status == "instrumental" or status == "plain" or status == "error" then
    return true
  end
  -- A short pause must not blink the overlay away: wait 1.5 s first.
  local pausedSince = noctalia.state.get("paused_since") or 0
  if cfg("hide_on_pause", true) and noctalia.state.get("playing") ~= true
      and pausedSince > 0 and noctalia.nowMs() - pausedSince >= 1500 then
    return true
  end
  return false
end

local function widthFor(size)
  return math.floor(size * 12)
end

function update()
  noctalia.setUpdateInterval(200)

  if isHidden() then
    desktopWidget.setVisible(false)
    return
  end
  desktopWidget.setVisible(true)

  local size = cfg("font_size", 44)
  local maxLines = cfg("max_lines", 3)
  local mode = cfg("display_mode", "karaoke")
  local alignment = align()
  local current = noctalia.state.get("current") or ""
  local nextLine = noctalia.state.get("next") or ""
  local previous = noctalia.state.get("previous") or ""
  local title = noctalia.state.get("title") or ""
  local artist = noctalia.state.get("artist") or ""
  local progress = noctalia.state.get("progress") or 0
  local wordRanges = noctalia.state.get("word_ranges")
  local wordProgress = noctalia.state.get("word_progress") or 0
  local trackProgress = noctalia.state.get("track_progress") or 0
  local status = noctalia.state.get("status") or ""

  local rows = {}

  if status == "loading" then
    table.insert(rows, ui.label({
      text = noctalia.tr("desktop.loading"),
      fontSize = math.max(14, math.floor(size * 0.4)),
      color = "on_surface/0.5",
      textAlign = alignment,
      maxLines = 1,
    }))
  end

  if cfg("show_title", false) and title ~= "" then
    local header = title
    if artist ~= "" then
      header = title .. " — " .. artist
    end
    table.insert(rows, ui.label({
      text = header,
      fontSize = math.max(12, math.floor(size * 0.32)),
      fontWeight = "medium",
      color = "primary/0.75",
      textAlign = alignment,
      maxLines = 1,
      maxWidth = widthFor(size),
      shadow = true,
    }))
  end

  if mode == "focus" then
    table.insert(rows, ui.label({
      text = current,
      fontSize = size,
      fontWeight = "bold",
      color = "on_surface",
      textAlign = alignment,
      maxLines = 2,
      maxWidth = widthFor(size),
      shadow = true,
    }))
  else
    if mode == "line" and cfg("show_next_line", true) and previous ~= "" and maxLines > 1 then
      table.insert(rows, ui.label({
        text = previous,
        fontSize = math.max(12, math.floor(size * 0.42)),
        color = "on_surface/0.3",
        textAlign = alignment,
        maxLines = 1,
        maxWidth = widthFor(size),
        shadow = true,
      }))
    end

    if mode == "karaoke" and cfg("show_progress", true) then
      local fill = {
        text = current,
        fontSize = size,
        fontWeight = "bold",
        color = "on_surface/0.45",
        fillColor = "primary",
        fillProgress = progress,
        textAlign = alignment,
        maxWidth = widthFor(size),
        shadow = true,
      }
      -- Enhanced LRC: one segment per timed word, so the fill moves when the
      -- word does instead of sweeping the whole line at a constant rate.
      if type(wordRanges) == "table" and #wordRanges > 0 then
        fill.fillRanges = wordRanges
        fill.fillProgress = wordProgress
      end
      table.insert(rows, ui.fillLabel(fill))
    else
      table.insert(rows, ui.label({
        text = current,
        fontSize = size,
        fontWeight = "bold",
        color = "on_surface",
        textAlign = alignment,
        maxLines = 2,
        maxWidth = widthFor(size),
        shadow = true,
      }))
    end

    if cfg("show_next_line", true) and nextLine ~= "" and maxLines > 1 then
      table.insert(rows, ui.label({
        text = nextLine,
        fontSize = math.max(12, math.floor(size * 0.42)),
        color = "on_surface/0.35",
        textAlign = alignment,
        maxLines = 1,
        maxWidth = widthFor(size),
        shadow = true,
      }))
    end
  end

  if cfg("show_progress", true) and mode ~= "karaoke" then
    table.insert(rows, ui.progress({
      progress = trackProgress,
      width = math.floor(size * 6),
      height = 2,
      fill = "primary/0.8",
      track = "on_surface/0.2",
      radius = 1,
    }))
  end

  desktopWidget.render(ui.column({
    gap = 6,
    align = alignment,
    justify = "center",
  }, rows))
end
