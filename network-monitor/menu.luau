--!nonstrict

function onOpen()
  panel.render(ui.column({ gap = 4 }, {
    ui.button({ text = noctalia.tr("context.refresh"), glyph = "refresh", variant = "ghost", contentAlign = "start", onClick = "onRefresh" }),
    ui.button({ text = noctalia.tr("context.settings"), glyph = "settings", variant = "ghost", contentAlign = "start", onClick = "onSettings" }),
  }))
end

function onRefresh()
  noctalia.state.set("scan", 0)
  panel.close()
end

function onSettings()
  noctalia.openSettings()
end
