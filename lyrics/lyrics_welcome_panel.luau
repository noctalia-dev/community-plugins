--!nonstrict

local welcome = require("./lyrics_welcome.luau")
local isOpen = false

local function render()
  panel.render(ui.column({ flexGrow = 1, gap = 12, padding = 8, align = "stretch" }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "layout-grid", size = 20, color = "primary" }),
      ui.label({ text = noctalia.tr("welcome.title"), fontWeight = "semibold", flexGrow = 1 }),
      ui.label({ text = noctalia.tr("welcome.overview_hint"), fontSize = 11,
        color = "on_surface_variant", maxLines = 1 }),
      ui.button({ glyph = "close", variant = "ghost", tooltip = noctalia.tr("panel.close"), onClick = "onCloseClicked" }),
    }),
    welcome.view(render),
    ui.row({ gap = 8, justify = "end" }, {
      ui.button({ text = noctalia.tr("welcome.recheck"), onClick = "onRecheck" }),
      ui.button({ text = noctalia.tr("panel.title"), onClick = "onOpenSelector" }),
    }),
  }))
end

function onRecheck()
  welcome.check(function()
    if isOpen then render() end
  end)
  render()
end

function onOpen(_context)
  isOpen = true
  onRecheck()
end

function onClose()
  isOpen = false
end

function onCloseClicked()
  panel.close()
end

function onOpenSelector()
  noctalia.togglePanel("h465855hgg/lyrics:selector")
end
