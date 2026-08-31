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
			ui.row({ gap = 8, align = "center" }, {
				ui.glyph({ name = "search", size = 18, color = "primary" }),
				ui.label({
					text = "SEARCH RESULTS",
					fontSize = theme.fontHeading,
					fontWeight = "bold",
					color = "on_surface_variant",
				}),
			}),
			ui.label({
				text = s.query ~= "" and ('"' .. s.query .. '"') or "",
				fontSize = theme.fontTitle,
				color = "on_surface_variant",
			}),
		})
	)

	table.insert(view, ui.separator({ key = "sep-discover", color = "outline" }))

	table.insert(
		view,
		ui.row({ key = "search-tabs", gap = 8, align = "center" }, {
			ui.button({
				key = "tab-top",
				text = "Top",
				variant = s.type == "top" and "primary" or "ghost",
				controlSize = "sm",
				onClick = function()
					state.on_toggle_search_type("top")
				end,
			}),
			ui.button({
				key = "tab-songs",
				text = "Songs",
				variant = s.type == "songs" and "primary" or "ghost",
				controlSize = "sm",
				onClick = function()
					state.on_toggle_search_type("songs")
				end,
			}),
			ui.button({
				key = "tab-playlists",
				text = "Playlists",
				variant = s.type == "playlists" and "primary" or "ghost",
				controlSize = "sm",
				onClick = function()
					state.on_toggle_search_type("playlists")
				end,
			}),
		})
	)

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
			if t.type == "playlist" then
				table.insert(rows, playlist_comp.playlist_row(t, idx))
			elseif t.type == "artist" then
				local key = "artist-" .. tostring(t.id)
				table.insert(
					rows,
					ui.row({
						key = key,
						gap = 14,
						align = "center",
						padding = 8,
						borderWidth = 1,
						border = "primary/0.4",
						fill = "primary/0.06",
						onClick = function()
							state.view.hover_key.track = nil
							state.open_artist(t)
						end,
					}, {
						common.thumb_or_placeholder(t.thumb_path, 96, "user", 28, "primary", "primary/0.15"),
						ui.column({ gap = 2, flexGrow = 1 }, {
							ui.label({
								text = t.title or "Artist",
								fontSize = theme.fontHeading,
								fontWeight = "bold",
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
