local theme = require("../../utils/theme.luau")
local state = require("../state.luau")
local request = require("../actions.luau")
local common = require("../common.luau")

-- Artist detail: header profile + top-ish tracks + albums/singles rows.
-- Everything here needs the network; offline shows a clear message instead
-- of stale guesses.
local function build_artist()
	local data = state.data
	local artist = data.artist or { id = "", title = "" }
	local view = state.view
	local child = {}

	table.insert(
		child,
		ui.row({ key = "ar-head", gap = 16, align = "center", paddingV = 12 }, {
			common.thumb_or_placeholder(artist.thumb_path, 120, "user", 44, "primary"),
			ui.column({ gap = 4, flexGrow = 1 }, {
				ui.label({
					text = "ARTIST",
					fontSize = theme.fontTitle,
					fontWeight = "bold",
					color = "on_surface_variant",
				}),
				ui.label({
					text = artist.title or "Artist",
					fontSize = theme.fontHero,
					fontWeight = "bold",
					color = "on_surface",
				}),
			}),
		})
	)

	table.insert(child, ui.row({ key = "spacer-artist-1", height = 8, borderWidth = 0 }))

	if #data.artist_tracks == 0 then
		table.insert(
			child,
			ui.label({
				text = (data.online == false) and "You're offline — artist details need internet."
					or "Loading artist...",
				fontSize = theme.fontTitle,
				color = "on_surface_variant",
			})
		)
		return child
	end

	table.insert(
		child,
		ui.label({
			text = "SONGS",
			fontSize = theme.fontHeading,
			fontWeight = "bold",
			color = "on_surface_variant",
		})
	)
	local song_rows = {}
	for i, t in ipairs(data.artist_tracks) do
		table.insert(
			song_rows,
			common.media_row(t, "ar-" .. i, function()
				request("play_with_queue", { item = t, index = i, queue = data.artist_tracks })
			end, state.data.player.id == t.id)
		)
	end
	table.insert(child, ui.column({ key = "ar-songs-col", gap = 0 }, song_rows))

	if #(data.artist_related or {}) > 0 then
		table.insert(child, ui.separator({ key = "sep-ar-rel", color = "outline/0.3" }))
		table.insert(
			child,
			ui.label({
				text = "ALBUMS & SINGLES",
				fontSize = theme.fontHeading,
				fontWeight = "bold",
				color = "on_surface_variant",
			})
		)

		-- Home-style cards: one per album/single, sharing the cover file when
		-- several singles point at the same artwork resource.
		local cards = {}
		for _, pl in ipairs(data.artist_related) do
			local key = "ar-rel-" .. tostring(pl.id or "")
			local card_hovered = (view.hover_key.card == key)
			table.insert(
				cards,
				ui.column({
					key = key,
					gap = 10,
					padding = 10,
					borderWidth = 1,
					border = "primary/0.4",
					fill = card_hovered and "primary/0.12" or "primary/0.04",
					flexGrow = 1,
					onClick = function()
						view.hover_key.card = nil
						state.open_playlist({
							id = pl.id,
							title = pl.title,
							thumbnail_url = pl.thumbnail_url,
							thumb_path = pl.thumb_path,
						})
					end,
					onHover = "onCardHover",
				}, {
					common.thumb_or_placeholder(
						pl.thumb_path,
						200,
						"playlist",
						38,
						"primary",
						card_hovered and "primary/0.2" or "surface_variant/0.6"
					),
					ui.column({ gap = 2, flexGrow = 1 }, {
						ui.label({
							text = pl.title or "Album",
							fontSize = theme.fontTitle,
							maxLines = 1,
							color = "on_surface",
							flexGrow = 1,
						}),
						ui.label({
							text = (pl.artist and pl.artist ~= "") and pl.artist or "Single",
							fontSize = theme.fontTitle,
							color = "on_surface_variant",
						}),
					}),
				})
			)
		end
		for _, row in ipairs(common.chunk_rows(cards, 6, "ar-rel-grid", 14)) do
			table.insert(child, row)
		end
	end

	return child
end

return { build = build_artist }
