local theme = require("../../utils/theme.luau")
local state = require("../state.luau")
local request = require("../actions.luau")
local common = require("../common.luau")
local playlist_comp = require("./playlist.luau")

local function build_discover()
	local data = state.data
	local view = {}
	local s = data.search

	table.insert(
		view,
		ui.row({ key = "discover-title", align = "center", justify = "space_between" }, {
			ui.column({ gap = 4 }, {
				ui.label({ text = "SEARCH RESULTS", fontSize = theme.fontHero, fontWeight = "bold", color = "on_surface" }),
				ui.label({
					text = s.query ~= "" and ('"' .. s.query .. '"') or "Search songs, albums, artists, or playlists",
					fontSize = theme.fontTitle,
					color = "on_surface_variant",
				}),
			}),
		})
	)
	table.insert(view, ui.row({ key = "spacer-disc-1", height = 8, borderWidth = 0 }))

	-- Search type filter chips (Top, Songs, Playlists, Albums, Artists)
	local chips = {
		{ id = "top", label = "Top" },
		{ id = "songs", label = "Songs" },
		{ id = "playlists", label = "Playlists" },
		{ id = "albums", label = "Albums" },
		{ id = "artists", label = "Artists" },
	}

	local chip_elems = {}
	for _, c in ipairs(chips) do
		local active = (s.type == c.id)
		local key = "search-chip-" .. c.id
		table.insert(
			chip_elems,
			ui.row({
				key = key,
				align = "center",
				justify = "center",
				paddingV = 6,
				paddingH = 16,
				borderWidth = 1,
				border = active and "primary" or "outline/0.4",
				fill = active and "primary" or "surface_variant/0.2",
				onClick = function()
					state.on_toggle_search_type(c.id)
				end,
			}, {
				ui.label({
					text = c.label,
					fontSize = theme.fontTitle,
					fontWeight = active and "bold" or "medium",
					color = active and "on_primary" or "on_surface",
				}),
			})
		)
	end
	table.insert(view, ui.row({ key = "search-chips-row", align = "center", gap = 8 }, chip_elems))
	table.insert(view, ui.row({ key = "spacer-disc-2", height = 14, borderWidth = 0 }))

	local rows = {}
	if s.pending then
		table.insert(
			rows,
			ui.label({
				text = "Searching...",
				fontSize = theme.fontTitle,
				color = "on_surface_variant",
			})
		)
	elseif #s.results == 0 then
		table.insert(
			rows,
			ui.label({
				text = "Type a query in the search bar above and press Enter.",
				fontSize = theme.fontTitle,
				color = "on_surface_variant",
			})
		)
	else
		for idx, t in ipairs(s.results) do
			if t.type == "playlist" or t.type == "album" or (t.id and tostring(t.id):sub(1, 5) == "MPREb") then
				table.insert(rows, playlist_comp.playlist_row(t, idx))
			elseif t.type == "artist" then
				local key = "artist-" .. tostring(t.id)
				local is_hovered = (state.view.hover_key.track == key)
				local is_hero = (t.is_hero == true)
				table.insert(
					rows,
					ui.row({
						key = key,
						gap = 14,
						align = "center",
						padding = 8,
						borderWidth = 0,
						fill = is_hovered and "primary/0.25" or "surface_variant/0.15",
						onClick = function()
							state.view.hover_key.track = nil
							state.open_artist(t)
						end,
						onHover = "onTrackHover",
					}, {
						common.thumb_or_placeholder(
							t.thumb_path,
							is_hero and 96 or 54,
							"user",
							is_hero and 28 or 20,
							is_hovered and "primary" or "on_surface_variant",
							is_hero and "primary/0.15" or nil
						),
						ui.column({ gap = 2, flexGrow = 1 }, {
							ui.label({
								text = t.title or "Artist",
								fontSize = is_hero and theme.fontHeading or theme.fontTitle,
								fontWeight = is_hero and "bold" or nil,
								color = "on_surface",
							}),
							ui.label({
								text = "Artist • view songs & albums",
								fontSize = theme.fontTitle,
								color = "on_surface_variant",
							}),
						}),
						ui.glyph({ name = "chevron-right", size = 18, color = "on_surface_variant" }),
					})
				)
			else
				table.insert(
					rows,
					common.media_row(t, idx, function()
						request("play_with_queue", { item = t, index = idx, queue = s.results })
					end, state.data.player.id == t.id)
				)
			end
		end
	end

	table.insert(view, ui.column({ key = "discover-track-list", gap = 0, borderWidth = 0 }, rows))

	return view
end

return { build = build_discover }
