local theme = require("../../utils/theme.luau")
local state = require("../state.luau")
local request = require("../actions.luau")
local auth_comp = require("./auth.luau")

local function build_settings()
	local items = {}
	table.insert(
		items,
		ui.row({ key = "set-head", paddingV = 16, borderWidth = 0 }, {
			ui.label({ text = "Settings", fontSize = theme.fontHero, fontWeight = "bold" }),
		})
	)

	local caches = {
		{
			id = "downloads",
			name = "Downloaded songs",
			desc = "Explicitly saved tracks and fully downloaded playlists.",
		},
		{ id = "cached_audio", name = "Cached audio", desc = "Songs auto-cached during playback." },
		{ id = "streams", name = "Stream URLs", desc = "Cached streaming URLs to speed up playback." },
		{ id = "thumbnails", name = "Thumbnails", desc = "Cached album and video thumbnail images." },
		{ id = "playlists", name = "Playlists", desc = "Cached library playlists and metadata." },
	}

	local cache_rows = {}
	for _, c in ipairs(caches) do
		local size = state.data.cache_stats and state.data.cache_stats[c.id] or "0"
		table.insert(
			cache_rows,
			ui.row({ key = "cache-" .. c.id, align = "center", justify = "space_between", paddingV = 12 }, {
				ui.column({ gap = 2 }, {
					ui.label({ text = c.name, fontSize = theme.fontTitle, fontWeight = "bold" }),
					ui.label({ text = c.desc, fontSize = theme.fontTitle, color = "on_surface_variant" }),
				}),
				ui.row({ gap = 16, align = "center" }, {
					ui.label({ text = size, fontSize = theme.fontTitle, fontWeight = "bold", color = "primary" }),
					ui.button({
						text = "Clear",
						variant = "outline",
						controlSize = "sm",
						onClick = function()
							request("clear_cache", { target = c.id })
						end,
					}),
				}),
			})
		)
		table.insert(cache_rows, ui.separator({ key = "sep-" .. c.id, color = "outline" }))
	end

	table.insert(
		items,
		ui.column({
			key = "set-card",
			padding = 16,
			gap = 8,
			borderWidth = 1,
			border = "outline",
			fill = "surface_variant/0.2",
			radius = 12,
		}, {
			ui.label({ text = "Storage & Cache", fontSize = theme.fontTitle, fontWeight = "bold" }),
			ui.label({
				text = "Manage downloads and local cache sizes to free up disk space.",
				fontSize = theme.fontTitle,
				color = "on_surface_variant",
			}),
			ui.column({ gap = 0, paddingV = 12 }, cache_rows),
		})
	)

	table.insert(items, ui.row({ key = "set-spacer-1", height = 24, borderWidth = 0 }))

	for _, item in ipairs(auth_comp.build_cookies_page()) do
		table.insert(items, item)
	end

	return items
end

return { build = build_settings }
