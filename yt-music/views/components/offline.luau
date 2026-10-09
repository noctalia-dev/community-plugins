local theme = require("../../utils/theme.luau")
local state = require("../state.luau")
local request = require("../actions.luau")
local common = require("../common.luau")
local rerender = require("../rerender.luau")

local PAGE_SIZE = 50

-- Everything the user can reach without a network:
--   PLAYLISTS    fully-downloaded playlists (library + recently played)
--   DOWNLOADED     explicitly saved audio that is not a member of any of those
local function build_offline()
	local data = state.data
	local view = state.view
	local child = {}

	local downloaded_pls, seen_pid = {}, {}
	local function add_source(list)
		if type(list) ~= "table" then
			return
		end
		for _, pl in ipairs(list) do
			local pid = tostring(pl.id or "")
			if
				pid ~= ""
				and not seen_pid[pid]
				and data.downloaded_playlist_ids
				and data.downloaded_playlist_ids[pid]
			then
				seen_pid[pid] = true
				table.insert(downloaded_pls, pl)
			end
		end
	end
	add_source(data.library)
	add_source(data.recent_playlists)

	local tracks = data.offline_tracks or {}
	local cached_tracks = data.cached_tracks or {}
	local n_pls, n_tr, n_cached = #downloaded_pls, #tracks, #cached_tracks

	local head_children = {
		ui.column({ gap = 4, radius = theme.radius }, {
			ui.label({ text = "OFFLINE", fontSize = theme.fontHero, fontWeight = "bold", color = "on_surface" }),
			ui.label({
				text = n_pls
					.. (n_pls == 1 and " playlist" or " playlists")
					.. " • "
					.. n_tr
					.. (n_tr == 1 and " downloaded track" or " downloaded tracks")
					.. " • "
					.. n_cached
					.. (n_cached == 1 and " cached track" or " cached tracks"),
				fontSize = theme.fontTitle,
				color = "on_surface_variant",
			}),
		}),
	}
	if (n_tr + n_cached) > 0 then
		table.insert(
			head_children,
			ui.input({
				key = "offline-track-filter-input",
				placeholder = "Filter...",
				value = view.offline_track_filter or "",
				width = 270,
				onChange = function(val)
					view.offline_track_filter = val or ""
					view.offline_view_page = 0
					rerender.call()
				end,
			})
		)
	end
	table.insert(
		child,
		ui.row({ key = "off-head", align = "center", justify = "space_between", radius = theme.radius }, head_children)
	)

	table.insert(child, ui.row({ key = "spacer-off-1", height = 8, borderWidth = 0, radius = theme.radius }))

	-- Filter chips
	local filter = view.offline_filter or "all"
	local track_entries = {} -- { item, cached }
	local track_title = "TRACKS"
	if filter == "cached" then
		for _, t in ipairs(cached_tracks) do
			table.insert(track_entries, { item = t, cached = true })
		end
		track_title = "CACHED TRACKS"
	elseif filter == "tracks" then
		for _, t in ipairs(tracks) do
			table.insert(track_entries, { item = t, cached = false })
		end
		track_title = "DOWNLOADED"
	elseif filter == "all" then
		for _, t in ipairs(tracks) do
			table.insert(track_entries, { item = t, cached = false })
		end
		for _, t in ipairs(cached_tracks) do
			table.insert(track_entries, { item = t, cached = true })
		end
	end
	local query = view.offline_track_filter or ""
	local visible = {} -- positions into track_entries, in source order
	for pos, entry in ipairs(track_entries) do
		local t = entry.item
		if common.fuzzy_match(query, (t.title or "") .. " " .. (t.artist or "")) then
			table.insert(visible, pos)
		end
	end
	local show_track_section = #visible > 0
	local chips = {
		{ id = "all", label = "All" },
		{ id = "tracks", label = "Downloaded" },
		{ id = "cached", label = "Cached" },
	}

	local chip_elems = {}
	for _, c in ipairs(chips) do
		local active = (filter == c.id)
		local key = "off-chip-" .. c.id
		table.insert(
			chip_elems,
			ui.button({
				key = key,
				text = c.label,
				variant = active and "primary" or "outline",
				controlSize = "sm",
				onClick = function()
					view.offline_filter = c.id
					view.offline_view_page = 0
					rerender.call()
				end,
			})
		)
	end
	table.insert(child, ui.row({ key = "off-chips-row", align = "center", gap = 8, radius = theme.radius }, chip_elems))
	table.insert(child, ui.row({ key = "spacer-off-2", height = 14, borderWidth = 0, radius = theme.radius }))

	if n_pls == 0 and n_tr == 0 and n_cached == 0 then
		table.insert(
			child,
			ui.label({
				text = "Nothing downloaded or cached yet. Use the download buttons on any playlist or track.",
				fontSize = theme.fontTitle,
				color = "on_surface_variant",
			})
		)
		return child
	end

	local visible_pls = {}
	for _, pl in ipairs(downloaded_pls) do
		if common.fuzzy_match(query, pl.title or "") then
			table.insert(visible_pls, pl)
		end
	end
	local show_playlists = (filter == "all" or filter == "tracks") and #visible_pls > 0

	-- One track list for every tab: Downloaded shows saved, Cached shows cached,
	-- All shows saved ++ cached with a single pager.

	if not show_playlists and not show_track_section then
		table.insert(
			child,
			ui.row(
				{ key = "off-empty-filter", align = "center", justify = "center", padding = 40, radius = theme.radius },
				{
					ui.label({
						text = "No offline items match your filter",
						fontSize = theme.fontTitle,
						color = "on_surface_variant",
					}),
				}
			)
		)
		return child
	end

	if show_playlists then
		table.insert(
			child,
			ui.label({
				text = "PLAYLISTS",
				fontSize = theme.fontHeading,
				fontWeight = "bold",
				color = "on_surface_variant",
			})
		)

		local cards = {}
		for _, pl in ipairs(visible_pls) do
			local key = "off-pl-" .. tostring(pl.id or "")
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
					radius = theme.radius,
					onClick = function()
						view.hover_key.card = nil
						state.open_playlist(pl)
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
					ui.column({ gap = 2, flexGrow = 1, radius = theme.radius }, {
						ui.label({
							text = (pl.title or "Playlist"),
							fontSize = theme.fontTitle,
							maxLines = 1,
							color = "on_surface",
							flexGrow = 1,
						}),
						ui.label({
							text = (pl.count and pl.count > 0) and (pl.count .. " tracks") or "Playlist",
							fontSize = theme.fontTitle,
							color = "on_surface_variant",
						}),
					}),
				})
			)
		end
		for _, row in ipairs(common.chunk_rows(cards, 6, "off-pl-grid", 14)) do
			table.insert(child, row)
		end

		if show_track_section then
			table.insert(child, ui.separator({ key = "sep-off-tracks", color = "outline/0.3" }))
		end
	end

	if #track_entries > 0 then
		table.insert(
			child,
			ui.row({ key = "off-tracks-head", justify = "space_between", align = "center", radius = theme.radius }, {
				ui.label({
					text = track_title,
					fontSize = theme.fontHeading,
					fontWeight = "bold",
					color = "on_surface_variant",
				}),
			})
		)
	end

	if show_track_section then
		local n_total = #visible
		local total_pages = math.max(1, math.ceil(n_total / PAGE_SIZE))
		if view.offline_view_page >= total_pages then
			view.offline_view_page = math.max(0, total_pages - 1)
		end
		if view.offline_view_page < 0 then
			view.offline_view_page = 0
		end
		local page_start = view.offline_view_page * PAGE_SIZE + 1
		local page_end = math.min(page_start + PAGE_SIZE - 1, n_total)

		-- Clicking a row queues this visible page starting at the clicked
		-- position; resolve_stream prefers the local file so playback works
		-- with no network.
		local page_tracks = {}
		for p = page_start, page_end do
			local entry = track_entries[visible[p]]
			table.insert(page_tracks, entry.item)
		end
		local track_rows = {}
		for i, t in ipairs(page_tracks) do
			local orig = visible[page_start + i - 1]
			local entry = track_entries[orig]
			table.insert(
				track_rows,
				common.media_row(t, orig, function()
					request("replace_queue_and_play", { item = t, index = i, queue = page_tracks })
				end, data.player.id == t.id, nil, entry.cached and "off-cached" or nil)
			)
		end
		table.insert(child, ui.column({ key = "off-tracks-col", gap = 0, radius = theme.radius }, track_rows))

		local has_prev = (view.offline_view_page > 0)
		local has_next = (view.offline_view_page < total_pages - 1)
		local controls = {}
		if has_prev then
			table.insert(
				controls,
				ui.button({
					key = "off-prev-page",
					text = "← Previous",
					variant = "outline",
					controlSize = "sm",
					onClick = function()
						view.offline_view_page = view.offline_view_page - 1
						rerender.call()
					end,
				})
			)
		end
		table.insert(
			controls,
			ui.label({
				text = page_start .. "–" .. page_end .. " of " .. n_total,
				fontSize = theme.fontBody,
				fontWeight = "medium",
				color = "on_surface_variant",
			})
		)
		if has_next then
			table.insert(
				controls,
				ui.button({
					key = "off-next-page",
					text = "Next →",
					variant = "outline",
					controlSize = "sm",
					onClick = function()
						view.offline_view_page = view.offline_view_page + 1
						rerender.call()
					end,
				})
			)
		end
		table.insert(
			child,
			ui.row({
				key = "off-pagination",
				align = "center",
				justify = "center",
				gap = 12,
				padding = 10,
				borderWidth = 0,
				radius = theme.radius,
			}, controls)
		)
	end

	return child
end

return { build = build_offline }
