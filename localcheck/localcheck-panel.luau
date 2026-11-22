--!nonstrict
local closeButton = true
local tr = noctalia.tr
local commande = "ss -tlnp"
local tableau = {}
local render

local function getLocalhost()
	noctalia.runAsync(commande, function(result)
		if result.exitCode == 0 then
			tableau = string.split(result.stdout or "", "\n")
		else
			tableau = { "Erreur lors de l'exécution de ss" }
		end
		render()
	end)
end

local function buildLocalHostView(tableau)
	local localView = {}
	table.insert(localView, ui.label({
		text = tr("panel.tcp_listeners"),
		fontSize = 13,
		fontWeight = "bold",
		color = "on_surface"
	}))
	if #tableau == 0 then
		table.insert(localView, ui.label({
			text = tr("panel.no_services"),
			fontSize = 12,
			color = "on_surface_variant"
		}))
		return localView
	end
	for index, line in ipairs(tableau) do
		if index > 1 and line ~= "" then
			table.insert(localView, ui.row({ align = "center", gap = 8 }, {
				ui.label({
					text = line,
					fontSize = 12,
					color = "on_surface_variant",
					flexGrow = 1
				}),
				ui.button({
					text = tr("panel.kill"),
					fontSize = 12,
					onClick = function()
						local local_address = string.match(line, "^%S+%s+%S+%s+%S+%s+(%S+)")
						if not local_address then
							noctalia.notify(tr("title"), tr("panel.ip_not_found"))
							return
						end
						local kill_commande =
							"ss -tulpn | grep -F '" .. local_address ..
							"' | grep -o 'pid=[0-9]*' | cut -d= -f2 | xargs -r kill -9"
						noctalia.runAsync(kill_commande, function(result)
							if result.exitCode == 0 then
								noctalia.notify(tr("title"), tr("panel.kill_success"))
								getLocalhost()
							else
								noctalia.notify(tr("title"), tr("panel.kill_failed"))
							end
						end)
					end
				})
			}))
		end
	end
	return localView
end

render = function()
  	local headerContent = {
    	ui.label({ text = "LocalCheck", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 })
  	}
  	if closeButton then
    	table.insert(headerContent, ui.button({ glyph = "close", onClick = "onCloseClicked" }))
  	end
	local buildView = buildLocalHostView(tableau)
  	panel.render(ui.column({ flexGrow = 1, gap = 16 }, {
    	ui.row({ align = "center", justify = "space_between", gap = 8 }, headerContent),
	    ui.scroll({ flexGrow = 1, gap = 8, align = "stretch" },
			buildView
		),
  	}))
end

function onOpen(_context)
	getLocalhost()
  render()
end

function onCloseClicked()
  	panel.close()
end