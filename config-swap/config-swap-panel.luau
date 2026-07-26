--!nonstrict
-- Config Swap

-- Local variable

local function render()
	panel.render(ui.column({ flexGrow = 1, gap = 16 }, {
		ui.row({ align = "center", justify = "space_between", gap = 8 }, {
			ui.label({ text = tr("panel.title"), align = "center", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
			ui.select({ options = {}, onChange = "" }),
			ui.button({ glyph = "close", onClick = "onCloseClicked" }),
		}),
		ui.scroll({ gap = 12, align = "stretch", flexGrow = 1 }, rows),
	}))
end

function onOpen(_context)
	render()
end

function onCloseClicked()
	panel.close()
end