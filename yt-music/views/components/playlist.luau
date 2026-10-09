local theme = require("../../utils/theme.luau")
local state = require("../state.luau")
local request = require("../actions.luau")
local common = require("../common.luau")
local rerender = require("../rerender.luau")

local function playlist_row(item, idx)
	local row_key = "plrow-" .. idx
	local is_hovered = (state.view.hover_key.track == row_key)

	local thumb = common.thumb_or_placeholder(
		item.thumb_path,
		54,
		"playlist",
		20,
		is_hovered and "primary" or "on_surface_variant"
	)

	return ui.row({
		key = row_key,
		gap = 14,
		align = "center",
		padding = 8,
		borderWidth = 0,
		fill = is_hovered and "primary/0.25" or "surface_variant/0.15",
		onClick = function()
			state.view.hover_key.track = nil
			state.open_playlist(item)
		end,
		onHover = "onTrackHover",
		radius = theme.radius,
	}, {
		thumb,
		ui.column({ gap = 2, flexGrow = 1, radius = theme.radius }, {
			ui.label({
				text = item.title or "Unknown Playlist",
				fontSize = theme.fontTitle,
				maxLines = 1,
				color = "on_surface",
			}),
			ui.label({ text = item.artist or "", fontSize = theme.fontTitle, color = "on_surface_variant" }),
		}),
	})
end

local function build_playlist_view()
	local pl = state.data.playlist
	local view = state.view
	local child = {}
	local PAGE_SIZE = 50

	local downloaded_count = 0
	if #pl.tracks > 0 then
		for _, tr in ipairs(pl.tracks) do
			if tr.id and state.data.cached_audio_ids and state.data.cached_audio_ids[tr.id] == true then
				downloaded_count = downloaded_count + 1
			end
		end
	end
	local all_cached = (#pl.tracks > 0 and downloaded_count == #pl.tracks)

	local is_downloading = (
		state.data.downloading_playlist_ids and state.data.downloading_playlist_ids[state.data.playlist.id] == true
	)

	local download_btn
	if is_downloading then
		download_btn = ui.button({
			key = "btn-download-pl",
			glyph = "loader",
			variant = "secondary",
			controlSize = "md",
			tooltip = "Downloading playlist tracks...",
		})
	elseif all_cached then
		download_btn = ui.button({
			key = "btn-download-pl",
			glyph = "check",
			variant = "secondary",
			controlSize = "md",
			tooltip = "All tracks downloaded for offline playback",
		})
	else
		download_btn = ui.button({
			key = "btn-download-pl",
			glyph = "download",
			variant = "secondary",
			controlSize = "md",
			tooltip = "Download all tracks in playlist for offline",
			onClick = function()
				request("download_playlist")
			end,
		})
	end

	-- Which rows are on screen: the filter decides, and the pagination below
	-- walks this list. Filter first, then paginate, exactly like the queue page.
	local query = view.playlist_text_filter or ""
	local filtering = query ~= ""
	local order = {}
	if filtering then
		for idx, item in ipairs(pl.tracks) do
			if common.fuzzy_match(query, (item.title or "") .. " " .. (item.artist or "")) then
				table.insert(order, idx)
			end
		end
	else
		for idx = 1, #pl.tracks do
			order[idx] = idx
		end
	end

	-- What a click queues: the matches when filtering, otherwise the playlist
	-- itself (shared, not copied). Rows and Play all both use this, so the queue
	-- always matches what is on screen.
	local queue_items = pl.tracks
	if filtering then
		queue_items = {}
		for _, idx in ipairs(order) do
			table.insert(queue_items, pl.tracks[idx])
		end
	end

	-- Subtitle mirrors the queue/offline headers: one muted line under the title.
	local declared_total = state.data.playlist.count
	local playlist_total_text
	if declared_total and declared_total > #pl.tracks then
		playlist_total_text = #pl.tracks .. " of " .. declared_total .. " total"
	else
		playlist_total_text = #pl.tracks .. " total"
	end

	-- Filter sits with the actions, ahead of the buttons, and only appears when
	-- there is something to filter — same rule as the queue and offline headers.
	local header_right = {}
	if #pl.tracks > 0 then
		table.insert(
			header_right,
			ui.input({
				key = "playlist-filter-input",
				placeholder = "Filter...",
				value = view.playlist_text_filter or "",
				width = 270,
				onChange = function(val)
					view.playlist_text_filter = val or ""
					view.playlist_view_page = 0
					rerender.call()
				end,
			})
		)
	end
	table.insert(header_right, download_btn)
	table.insert(
		header_right,
		ui.button({
			key = "btn-sync-pl",
			glyph = "refresh",
			variant = "secondary",
			controlSize = "md",
			tooltip = "Refresh playlist",
			onClick = function()
				request("refresh_playlist", { playlist_id = pl.id })
			end,
		})
	)
	table.insert(
		header_right,
		ui.button({
			key = "btn-play-all",
			text = "Play all",
			glyph = "player-play",
			variant = "primary",
			controlSize = "md",
			onClick = function()
				-- Filtered: queue what is on screen. Otherwise stay on the existing
				-- path, which also covers the window where a refresh has cleared the
				-- list and only the cache is available to play.
				if filtering and #queue_items > 0 then
					request(
						"replace_queue_and_play",
						{ index = 1, queue = queue_items, source_playlist = pl.id, filtered = true }
					)
				else
					state.play_playlist(pl)
				end
			end,
		})
	)

	table.insert(
		child,
		ui.row({ key = "pl-header", align = "center", justify = "space_between", radius = theme.radius }, {
			ui.column({ key = "pl-title-col", gap = 4, radius = theme.radius }, {
				ui.label({
					text = pl.title or "Playlist",
					fontSize = theme.fontHero,
					fontWeight = "bold",
					color = "on_surface",
				}),
				ui.label({
					key = "pl-subtitle-label",
					text = downloaded_count .. " downloaded • " .. playlist_total_text,
					fontSize = theme.fontTitle,
					color = "on_surface_variant",
				}),
			}),
			ui.row({ gap = 8, align = "center", radius = theme.radius }, header_right),
		})
	)

	table.insert(child, ui.row({ key = "spacer-pl-1", height = 8, borderWidth = 0, radius = theme.radius }))

	local total = #order

	local total_pages = math.max(1, math.ceil(total / PAGE_SIZE))
	if view.playlist_view_page >= total_pages then
		view.playlist_view_page = math.max(0, total_pages - 1)
	end
	local page_start = view.playlist_view_page * PAGE_SIZE + 1
	local page_end = math.min(page_start + PAGE_SIZE - 1, total)

	local tracks = {}
	if total == 0 then
		local empty_text
		if pl.fetching then
			empty_text = "Loading tracks..."
		elseif filtering then
			empty_text = 'No tracks match "' .. query .. '".'
		elseif state.data.online == false then
			empty_text = "You're offline — this playlist isn't downloaded."
		else
			empty_text = "No tracks found in playlist."
		end
		table.insert(
			tracks,
			ui.label({
				text = empty_text,
				fontSize = theme.fontTitle,
				color = "on_surface_variant",
			})
		)
	else
		for pos = page_start, page_end do
			local abs_idx = order[pos]
			local t = abs_idx and pl.tracks[abs_idx]
			-- Position within the queued list: the matches when filtering, the
			-- playlist otherwise (identical to abs_idx without a filter).
			local queue_pos = pos
			if t then
				table.insert(
					tracks,
					common.media_row(t, abs_idx, function()
						request("replace_queue_and_play", {
							item = t,
							index = queue_pos,
							queue = queue_items,
							source_playlist = pl.id,
							filtered = filtering,
						})
					end, state.data.player.id == t.id)
				)
			end
		end

		local has_prev = (view.playlist_view_page > 0)
		local has_next_page = (view.playlist_view_page < total_pages - 1)
		-- While filtering, Next only walks the matches: reaching for another
		-- continuation mid-filter would stream in rows the user never asked for.
		local can_fetch_more = not filtering
			and (pl.next_token ~= nil and pl.next_token ~= "")
			-- YT hands out continuations even for fully-loaded lists; once the
			-- declared count is on screen there is nothing real left to fetch
			and not ((pl.count or 0) > 0 and #pl.tracks >= pl.count)
		local has_next = has_next_page or can_fetch_more

		local page_controls = {}
		if has_prev then
			table.insert(
				page_controls,
				ui.button({
					key = "pl-prev-page",
					text = "← Previous",
					variant = "outline",
					controlSize = "sm",
					onClick = function()
						view.playlist_view_page = view.playlist_view_page - 1
						rerender.call()
					end,
				})
			)
		end

		local label_total
		if filtering then
			label_total = total
		elseif state.data.playlist.count and state.data.playlist.count > total then
			label_total = state.data.playlist.count
		else
			label_total = total
		end

		table.insert(
			page_controls,
			ui.label({
				text = page_start .. "–" .. page_end .. " of " .. label_total,
				fontSize = theme.fontBody,
				fontWeight = "medium",
				color = "on_surface_variant",
			})
		)

		if has_next then
			table.insert(
				page_controls,
				ui.button({
					key = "pl-next-page",
					text = pl.fetching and "Loading..." or "Next →",
					variant = "outline",
					controlSize = "sm",
					onClick = function()
						local cur_total = #state.data.playlist.tracks
						local cur_pages = math.max(1, math.ceil(cur_total / PAGE_SIZE))
						if view.playlist_view_page < cur_pages - 1 then
							view.playlist_view_page = view.playlist_view_page + 1
							rerender.call()
						elseif state.data.playlist.next_token and state.data.playlist.next_token ~= "" then
							view.playlist_pending_advance = true
							request(
								"fetch_next_page",
								{ playlist_id = state.data.playlist.id, token = state.data.playlist.next_token }
							)
							rerender.call()
						end
					end,
				})
			)
		end

		table.insert(
			tracks,
			ui.row({
				key = "pl-pagination",
				align = "center",
				justify = "center",
				gap = 12,
				padding = 10,
				borderWidth = 0,
				radius = theme.radius,
			}, page_controls)
		)
	end

	-- YT's suggestion shelf for this playlist: rendered outside pagination,
	-- clicking a row plays it now while the rest of the queue continues.
	local sugg = pl.suggestions or {}
	-- The shelf is filtered by the same query, and its heading is dropped
	-- entirely when nothing matches rather than sitting over an empty list.
	local shown_sugg = {}
	for si, s in ipairs(sugg) do
		if common.fuzzy_match(query, (s.title or "") .. " " .. (s.artist or "")) then
			table.insert(shown_sugg, { si = si, item = s })
		end
	end
	if #shown_sugg > 0 then
		table.insert(tracks, ui.row({ key = "spacer-suggestions", height = 6, borderWidth = 0, radius = theme.radius }))
		table.insert(tracks, ui.separator({ key = "sep-suggestions", color = "outline/0.3" }))
		table.insert(
			tracks,
			ui.label({
				text = "SUGGESTED TRACKS",
				fontSize = theme.fontHeading,
				fontWeight = "bold",
				color = "on_surface_variant",
			})
		)
		for _, entry in ipairs(shown_sugg) do
			table.insert(
				tracks,
				common.media_row(entry.item, "sug-" .. entry.si, function()
					request("play_suggestion", { item = entry.item })
				end)
			)
		end
	end

	table.insert(child, ui.column({ key = "pl-track-list", gap = 0, borderWidth = 0, radius = theme.radius }, tracks))

	return child
end

return {
	build = build_playlist_view,
	playlist_row = playlist_row,
}
