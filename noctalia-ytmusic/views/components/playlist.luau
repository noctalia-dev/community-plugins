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
	}, {
		thumb,
		ui.column({ gap = 2, flexGrow = 1 }, {
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

	table.insert(
		child,
		ui.row({ key = "pl-header", align = "center", justify = "space_between" }, {
			ui.row({ key = "pl-title-row", align = "center", gap = 10 }, {
				ui.label({
					text = pl.title or "Playlist",
					fontSize = theme.fontHero,
					fontWeight = "bold",
					color = "on_surface",
				}),
			}),
			ui.row({ gap = 8, align = "center" }, {
				ui.column({ key = "pl-count-col", gap = 1, align = "end" }, {
					ui.label({
						key = "pl-downloaded-label",
						text = downloaded_count .. " downloaded",
						fontSize = theme.fontTitle,
						fontWeight = "medium",
						color = "on_surface",
					}),
					ui.label({
						key = "pl-total-label",
						text = (state.data.playlist.count and state.data.playlist.count > #pl.tracks)
								and (#pl.tracks .. " of " .. state.data.playlist.count .. " total")
							or (#pl.tracks .. " total"),
						fontSize = theme.fontTitle,
						color = "on_surface_variant",
					}),
				}),
				download_btn,
				ui.button({
					key = "btn-sync-pl",
					glyph = "refresh",
					variant = "secondary",
					controlSize = "md",
					tooltip = "Refresh playlist",
					onClick = function()
						request("refresh_playlist", { playlist_id = pl.id })
					end,
				}),
				ui.button({
					key = "btn-play-all",
					text = "Play all",
					glyph = "player-play",
					variant = "primary",
					controlSize = "md",
					onClick = function()
						state.play_playlist(pl)
					end,
				}),
			}),
		})
	)

	table.insert(child, ui.separator({ key = "sep-pl", color = "outline" }))

	local total = #pl.tracks
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
		for abs_idx = page_start, page_end do
			local t = pl.tracks[abs_idx]
			if t then
				table.insert(
					tracks,
					common.media_row(t, abs_idx, function()
						request(
							"play_with_queue",
							{ item = t, index = abs_idx, queue = pl.tracks, source_playlist = pl.id }
						)
					end, state.data.player.id == t.id)
				)
			end
		end

		local has_prev = (view.playlist_view_page > 0)
		local has_next_page = (view.playlist_view_page < total_pages - 1)
		local can_fetch_more = (pl.next_token and pl.next_token ~= "")
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

		table.insert(
			page_controls,
			ui.label({
				text = page_start
					.. "–"
					.. page_end
					.. " of "
					.. (
						(state.data.playlist.count and state.data.playlist.count > total)
							and state.data.playlist.count
						or total
					),
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
			}, page_controls)
		)
	end

	-- YT's suggestion shelf for this playlist: rendered outside pagination,
	-- clicking a row plays it now while the rest of the queue continues.
	local sugg = pl.suggestions or {}
	if #sugg > 0 then
		table.insert(tracks, ui.row({ key = "spacer-suggestions", height = 6, borderWidth = 0 }))
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
		for si, s in ipairs(sugg) do
			table.insert(
				tracks,
				common.media_row(s, "sug-" .. si, function()
					request("play_suggestion", { item = s })
				end)
			)
		end
	end

	table.insert(child, ui.column({ key = "pl-track-list", gap = 0, borderWidth = 0 }, tracks))

	return child
end

return {
	build = build_playlist_view,
	playlist_row = playlist_row,
}
