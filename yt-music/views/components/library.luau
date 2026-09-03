local theme = require("../../utils/theme.luau")
local state = require("../state.luau")
local common = require("../common.luau")
local rerender = require("../rerender.luau")

local function build_library()
	local data = state.data
	local view = state.view
	local child = {}

	local filter = view.library_filter or "all"

	table.insert(
		child,
		ui.row({ key = "lib-head", align = "center", justify = "space_between" }, {
			ui.column({ gap = 4 }, {
				ui.label({ text = "LIBRARY", fontSize = theme.fontHero, fontWeight = "bold", color = "on_surface" }),
				ui.label({
					text = #data.library .. " items in your YouTube Music library",
					fontSize = theme.fontTitle,
					color = "on_surface_variant",
				}),
			}),
		})
	)

	table.insert(child, ui.row({ key = "spacer-lib-1", height = 8, borderWidth = 0 }))

	-- Filter chips
	local chips = {
		{ id = "all", label = "All" },
		{ id = "playlists", label = "Playlists" },
		{ id = "albums", label = "Albums" },
		{ id = "artists", label = "Artists" },
	}

	local chip_elems = {}
	for _, c in ipairs(chips) do
		local active = (filter == c.id)
		local key = "lib-chip-" .. c.id
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
					view.library_filter = c.id
					rerender.call()
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
	table.insert(child, ui.row({ key = "lib-chips-row", align = "center", gap = 8 }, chip_elems))
	table.insert(child, ui.row({ key = "spacer-lib-2", height = 14, borderWidth = 0 }))

	-- Filter items
	local items = {}
	local liked_item = nil
	for _, item in ipairs(data.library) do
		local iid = tostring(item.id or "")
		local sub_lower = (item.subtitle or ""):lower()
		local title_lower = (item.title or ""):lower()
		local is_artist = (iid:sub(1, 2) == "UC" or sub_lower:find("artist", 1, true))
		local is_album = (iid:sub(1, 5) == "MPREb" or sub_lower:find("album", 1, true))
		local is_playlist = not is_artist and not is_album

		local matches = false
		if filter == "all" then
			matches = true
		elseif filter == "playlists" and is_playlist then
			matches = true
		elseif filter == "albums" and is_album then
			matches = true
		elseif filter == "artists" and is_artist then
			matches = true
		end

		if matches then
			if iid == "VLLM" or title_lower:find("liked", 1, true) then
				liked_item = item
			else
				table.insert(items, item)
			end
		end
	end

	if liked_item then
		table.insert(items, 1, liked_item)
	end

	if #items == 0 then
		table.insert(
			child,
			ui.row({ key = "lib-empty", align = "center", justify = "center", padding = 40 }, {
				ui.label({
					text = state.logged_in() and "No items match your filter" or "Sign in to see your library",
					fontSize = theme.fontTitle,
					color = "on_surface_variant",
				}),
			})
		)
	else
		local cards = {}
		for idx, item in ipairs(items) do
			local iid = tostring(item.id or "")
			local key = "lib-card-" .. idx
			local is_hovered = (view.hover_key.card == key)

			local icon_name = "playlist"
			if iid:sub(1, 2) == "UC" then icon_name = "user" end
			if iid:sub(1, 5) == "MPREb" then icon_name = "disc" end
			if item.title:lower():find("liked", 1, true) then icon_name = "heart" end

			local thumb_path = item.thumb_path or item.thumbnail_url

			table.insert(
				cards,
				ui.column({
					key = key,
					gap = 10,
					padding = 10,
					borderWidth = 1,
					border = "primary/0.4",
					fill = is_hovered and "primary/0.12" or "primary/0.04",
					flexGrow = 1,
					onClick = function()
						view.hover_key.card = nil
						if iid:sub(1, 2) == "UC" then
							state.open_artist({ id = iid, title = item.title, name = item.title, thumbnail_url = item.thumbnail_url, thumb_path = item.thumb_path })
						else
							state.open_playlist(item)
						end
					end,
					onHover = "onCardHover",
				}, {
					common.thumb_or_placeholder(thumb_path, 200, icon_name, 38, "primary", is_hovered and "primary/0.2" or "surface_variant/0.6"),
					ui.column({ gap = 2, flexGrow = 1 }, {
						ui.label({
							text = item.title,
							fontSize = theme.fontTitle,
							fontWeight = "bold",
							maxLines = 1,
							color = is_hovered and "primary" or "on_surface",
						}),
						ui.label({
							text = item.subtitle or "Library item",
							fontSize = theme.fontTitle,
							maxLines = 1,
							color = "on_surface_variant",
						}),
					}),
				})
			)
		end

		for _, row in ipairs(common.chunk_rows(cards, 6, "lib-grid", 14)) do
			table.insert(child, row)
		end
	end

	return child
end

return { build = build_library }
