function tr(key)
	return noctalia.tr(key)
end

local function render()
  local monitors = noctalia.state.get("monitors") or {}
  local focusedMonitor = noctalia.state.get("focusedMonitor")
  local sourceMonitor = tonumber(noctalia.state.get("sourceMonitor"))
  local targetMonitor = tonumber(noctalia.state.get("targetMonitor"))
  local isMirroring = noctalia.state.get("isMirroring")

  local buttonColor = isMirroring and "destructive" or "primary"
  local buttonGlyph = isMirroring and "player-stop" or "player-play"

  panel.render(ui.column({ flexGrow = 1, gap = 8 }, {
    ui.row({ align = "center", justify = "space-between", gap = 8 }, {
      ui.label({ text = tr("panel.title"), fontSize = 14, fontWeight = "bold", color = "primary", flexGrow = 1 }),
      ui.button({ glyph = "close", onClick = "onCloseClicked" }),
    }),
    ui.row({ align = "center", justify = "space-between", gap = 8 }, {
      ui.label({ text = tr("panel.focused_monitor") .. ":" , fontSize = 14, color = "on_surface_variant", flexGrow = 1 }),
      ui.label({ text = focusedMonitor, fontSize = 14, color = "on_surface" }),
    }),
    ui.column({ gap = 4 }, {
      ui.label({ text = tr("panel.source_monitor"), fontSize = 14, color = "on_surface_variant" }),
      ui.select({ options = monitors, onChange = "onSourceChange", selectedIndex = sourceMonitor }),
    }),
    ui.column({ gap = 4 }, {
      ui.label({ text = tr("panel.target_monitor"), fontSize = 14, color = "on_surface_variant" }),
      ui.select({ options = monitors, onChange = "onTargetChange", selectedIndex = targetMonitor }),
    }),
    ui.row({ align = "center", justify = "space-between", gap = 8 }, {
      ui.button({ text = tr("panel.refresh"), glyph = "refresh", onClick = "onRefreshClicked", flexGrow = 1 }),
      ui.button({ text = tr("panel.start_mirroring"), glyph = buttonGlyph, onClick = "onStartMirroringClicked", flexGrow = 1, variant = buttonColor  }),
    }),
  }))
end

function onOpen(_context)
  render()
end

function onCloseClicked()
  panel.close()
end

function onSourceChange(selected)
  noctalia.state.set("sourceMonitor", selected)
  render()
end

function onTargetChange(selected)
  noctalia.state.set("targetMonitor", selected)
  render()
end

noctalia.state.watch("monitors", function()
  render()
end)

noctalia.state.watch("focusedMonitor", function()
  render()
end)
