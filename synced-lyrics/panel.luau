--!nonstrict
-- Synced Lyrics Source Selection Panel
-- Modeled after github-kanban: lists available lyrics providers with karaoke badges,
-- checkmarks, and 2-3 preview lines per source for instant switching.

local panelOpen = false
local sourceTypeRank = { syllable = 1, word = 2, line = 3 }

local function renderEmpty()
  panel.render(ui.column({
    padding = 16,
    gap = 14,
    flexGrow = 1,
    align = "stretch",
  }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "music", size = 20, color = "primary" }),
      ui.label({
        text = noctalia.tr("panel.title") or "Lyrics Sources",
        fontSize = 15,
        fontWeight = "bold",
        color = "on_surface",
        flexGrow = 1,
      }),
      ui.button({
        glyph = "close",
        variant = "ghost",
        tooltip = noctalia.tr("panel.close") or "Close",
        onClick = function()
          panel.close()
        end,
      }),
    }),
    ui.column({
      flexGrow = 1,
      align = "center",
      justify = "center",
      gap = 8,
      padding = 24,
    }, {
      ui.glyph({ name = "music-off", size = 36, color = "on_surface_variant" }),
      ui.label({
        text = noctalia.tr("panel.no-sources") or "No lyrics available for this track",
        fontSize = 13,
        fontWeight = "bold",
        color = "on_surface_variant",
      }),
      ui.label({
        text = "Start playing music with a supported player to see available lyrics",
        fontSize = 11,
        color = "outline",
      }),
    }),
  }))
end

local function render()
  lyricsPayload = noctalia.state.get("lyrics_payload")
  currentTrack = noctalia.state.get("current_track") or {}
  activeSourceKey = noctalia.state.get("active_source_key") or ""

  local sources = lyricsPayload and lyricsPayload.sources or nil
  if not sources or type(sources) ~= "table" then
    renderEmpty()
    return
  end

  local trackTitle = currentTrack.title or "Unknown Track"
  local trackArtist = currentTrack.artist or "Unknown Artist"
  local trackAlbum = currentTrack.album or ""
  local subtitle = trackArtist
  if trackAlbum ~= "" and trackAlbum ~= trackTitle then
    subtitle = trackArtist .. " • " .. trackAlbum
  end

  -- Build sorted source list
  local sourceList = {}
  for key, src in pairs(sources) do
    if type(src) == "table" and src.lines and #src.lines > 0 then
      table.insert(sourceList, {
        key = key,
        name = src.name or key,
        srcType = src.type or "line",
        badge = src.badge or (src.type == "syllable" and "Karaoke (Syllable)" or (src.type == "word" and "Karaoke (Word)" or "Line-synced")),
        preview = src.preview or {},
        linesCount = #src.lines,
      })
    end
  end

  -- If no valid sources in dictionary, fallback to empty
  if #sourceList == 0 then
    renderEmpty()
    return
  end

  -- Sort so active is on top, then syllable sources, then line sources
  table.sort(sourceList, function(a, b)
    if a.key == activeSourceKey then return true end
    if b.key == activeSourceKey then return false end
    if (sourceTypeRank[a.srcType] or 4) ~= (sourceTypeRank[b.srcType] or 4) then
      return (sourceTypeRank[a.srcType] or 4) < (sourceTypeRank[b.srcType] or 4)
    end
    return a.name < b.name
  end)

  local cards = {}
  for _, item in ipairs(sourceList) do
    local isSelected = (item.key == activeSourceKey)
    local isKaraoke = (item.srcType == "syllable")

    -- First 2-3 preview lines
    local previewRows = {}
    if item.preview and #item.preview > 0 then
      for idx, previewText in ipairs(item.preview) do
        if idx <= 3 and previewText ~= "" then
          table.insert(previewRows, ui.label({
            text = "♪ " .. previewText,
            fontSize = 11,
            color = isSelected and "on_surface" or "on_surface_variant",
            maxLines = 1,
          }))
        end
      end
    else
      table.insert(previewRows, ui.label({
        text = "(" .. tostring(item.linesCount) .. " synced lines)",
        fontSize = 11,
        color = "outline",
      }))
    end

    local badgeWidget = ui.row({
      gap = 3,
      align = "center",
      padding = 4,
      radius = 4,
      fill = isKaraoke and "primary/0.18" or "secondary/0.18",
    }, {
      ui.glyph({
        name = isKaraoke and "sparkles" or "align-left",
        size = 11,
        color = isKaraoke and "primary" or "secondary",
      }),
      ui.label({
        text = item.badge,
        fontSize = 10,
        fontWeight = "bold",
        color = isKaraoke and "primary" or "secondary",
      }),
    })

    local cardItem = ui.column({
      padding = 10,
      radius = 8,
      gap = 6,
      fill = isSelected and "primary/0.12" or "surface_variant/0.38",
      border = isSelected and "primary" or "outline/0.2",
      borderWidth = isSelected and 2 or 1,
      align = "stretch",
      onClick = function()
        noctalia.state.set("user_selected_source", item.key)
        panel.close()
      end,
    }, {
      -- Header row inside card
      ui.row({ gap = 8, align = "center" }, {
        ui.glyph({
          name = isKaraoke and "microphone" or "music",
          size = 16,
          color = isSelected and "primary" or "on_surface_variant",
        }),
        ui.label({
          text = item.name,
          fontSize = 13,
          fontWeight = "bold",
          color = isSelected and "primary" or "on_surface",
          flexGrow = 1,
        }),
        badgeWidget,
        ui.glyph({
          name = "check",
          size = 16,
          color = "primary",
          visible = isSelected,
        }),
      }),
      -- Preview box with subtle contrast
      ui.column({
        padding = 6,
        radius = 6,
        gap = 2,
        fill = isSelected and "primary/0.08" or "surface_variant/0.2",
        align = "stretch",
      }, previewRows),
    })

    table.insert(cards, cardItem)
  end

  panel.render(ui.column({
    padding = 12,
    gap = 10,
    flexGrow = 1,
    align = "stretch",
  }, {
    -- Panel Header
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "music", size = 20, color = "primary" }),
      ui.column({ flexGrow = 1, gap = 1 }, {
        ui.label({
          text = trackTitle,
          fontSize = 14,
          fontWeight = "bold",
          color = "on_surface",
          maxLines = 1,
        }),
        ui.label({
          text = subtitle,
          fontSize = 11,
          color = "on_surface_variant",
          maxLines = 1,
        }),
      }),
      ui.button({
        glyph = "refresh",
        variant = "ghost",
        tooltip = noctalia.tr("panel.refresh") or "Refresh lyrics",
        onClick = function()
          noctalia.state.set("refresh_lyrics", noctalia.nowMs())
        end,
      }),
      ui.button({
        glyph = "close",
        variant = "ghost",
        tooltip = noctalia.tr("panel.close") or "Close",
        onClick = function()
          panel.close()
        end,
      }),
    }),

    -- Category indicator
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "list", size = 13, color = "primary" }),
      ui.label({
        text = noctalia.tr("panel.select-source") or "Select Lyric Provider",
        fontSize = 11,
        fontWeight = "bold",
        color = "primary",
        flexGrow = 1,
      }),
      ui.label({
        text = tostring(#sourceList) .. " available",
        fontSize = 10,
        color = "on_surface_variant",
      }),
    }),

    -- Scrollable Cards
    ui.scroll({
      flexGrow = 1,
      gap = 8,
      align = "stretch",
    }, cards),

    -- Bottom hint
    ui.label({
      text = noctalia.tr("panel.available-sources") or "Click any provider above to switch lyrics instantly",
      fontSize = 10,
      color = "on_surface_variant",
      align = "center",
    }),
  }))
end

noctalia.state.watch("lyrics_payload", function(_)
  if panelOpen then
    render()
  end
end)

noctalia.state.watch("active_source_key", function(_)
  if panelOpen then
    render()
  end
end)

noctalia.state.watch("current_track", function(_)
  if panelOpen then
    render()
  end
end)

function onOpen()
  panelOpen = true
  render()
end

function onClose()
  panelOpen = false
end

render()
