function tr(key)
	return noctalia.tr(key)
end

local function render()
  local monitors = noctalia.state.get("monitors") or {}
  local focusedMonitor = noctalia.state.get("focusedMonitor")
  local sourceMonitor = noctalia.state.get("sourceMonitor")
  local targetMonitor = noctalia.state.get("targetMonitor")
  local isMirroring = noctalia.state.get("isMirroring")

  local buttonColor = isMirroring and "destructive" or "primary"
  local buttonGlyph = isMirroring and "player-stop" or "player-play"
  local buttonText = isMirroring and tr("panel.stop_mirroring") or tr("panel.start_mirroring")

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
      ui.select({ options = monitors, onChange = "onSourceChange", selectedIndex = sourceMonitor, enabled = not isMirroring  }),
    }),
    ui.column({ gap = 4 }, {
      ui.label({ text = tr("panel.target_monitor"), fontSize = 14, color = "on_surface_variant" }),
      ui.select({ options = monitors, onChange = "onTargetChange", selectedIndex = targetMonitor, enabled = not isMirroring }),
    }),
    ui.row({ align = "center", justify = "space-between", gap = 8 }, {
      ui.button({ text = tr("panel.refresh"), glyph = "refresh", onClick = "onRefreshClicked", flexGrow = 1 }),
      ui.button({ text = buttonText, glyph = buttonGlyph, onClick = "onStartMirroringClicked", flexGrow = 1, variant = buttonColor, enabled = sourceMonitor ~= nil and targetMonitor ~= nil and sourceMonitor ~= targetMonitor  }),
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
  noctalia.state.set("sourceMonitor", tonumber(selected))
  render()
end

function onTargetChange(selected)
  noctalia.state.set("targetMonitor", tonumber(selected))
  render()
end

function onRefreshClicked()
  noctalia.state.set("monitor_refresh", os.clock())
end

function onStartMirroringClicked()
  noctalia.state.set("mirrorRequest", {
    enabled = not noctalia.state.get("isMirroring"),
    sourceMonitor = noctalia.state.get("sourceMonitor"),
    targetMonitor = noctalia.state.get("targetMonitor"),
  })
end

noctalia.state.watch("monitors", function()
  render()
end)

noctalia.state.watch("focusedMonitor", function()
  render()
end)

noctalia.state.watch("sourceMonitor", function()
  render()
end)

noctalia.state.watch("targetMonitor", function()
  render()
end)

noctalia.state.watch("isMirroring", function()
  render()
end)
