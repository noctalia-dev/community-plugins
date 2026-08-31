local theme = require("../../utils/theme.luau")
local state = require("../state.luau")
local request = require("../actions.luau")
local common = require("../common.luau")
local rerender = require("../rerender.luau")

local PAGE_SIZE = 50

-- Everything the user can reach without a network:
--   PLAYLISTS    fully-downloaded playlists (library + recently played)
--   SAVED TRACKS locally cached audio that is not a member of any of those
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
	local n_pls, n_tr = #downloaded_pls, #tracks

	table.insert(
		child,
		ui.row({ key = "off-head", align = "center", justify = "space_between" }, {
			ui.label({ text = "OFFLINE", fontSize = theme.fontHero, fontWeight = "bold", color = "on_surface" }),
			ui.label({
				text = n_pls
					.. (n_pls == 1 and " playlist" or " playlists")
					.. " • "
					.. n_tr
					.. (n_tr == 1 and " saved track" or " saved tracks"),
				fontSize = theme.fontTitle,
				color = "on_surface_variant",
			}),
		})
	)

	table.insert(child, ui.separator({ key = "sep-off", color = "outline" }))

	if n_pls == 0 and n_tr == 0 then
		table.insert(
			child,
			ui.label({
				text = "Nothing downloaded yet. Use the download buttons on any playlist or track.",
				fontSize = theme.fontTitle,
				color = "on_surface_variant",
			})
		)
		return child
	end

	if n_pls > 0 then
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
		for _, pl in ipairs(downloaded_pls) do
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
					ui.column({ gap = 2, flexGrow = 1 }, {
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

		table.insert(child, ui.separator({ key = "sep-off-tracks", color = "outline/0.3" }))
	end

	if n_tr > 0 then
		table.insert(
			child,
			ui.row({ key = "off-tracks-head", justify = "space_between", align = "center" }, {
				ui.label({
					text = "SAVED TRACKS",
					fontSize = theme.fontHeading,
					fontWeight = "bold",
					color = "on_surface_variant",
				}),
				ui.label({
					text = "playable without internet",
					fontSize = theme.fontBody,
					color = "on_surface_variant",
				}),
			})
		)

		local total_pages = math.max(1, math.ceil(n_tr / PAGE_SIZE))
		if view.offline_view_page >= total_pages then
			view.offline_view_page = math.max(0, total_pages - 1)
		end
		if view.offline_view_page < 0 then
			view.offline_view_page = 0
		end
		local page_start = view.offline_view_page * PAGE_SIZE + 1
		local page_end = math.min(page_start + PAGE_SIZE - 1, n_tr)

		-- Clicking a row queues this visible page starting at the clicked
		-- position; resolve_stream prefers the local file so playback works
		-- with no network.
		local page_tracks = {}
		for abs_idx = page_start, page_end do
			table.insert(page_tracks, tracks[abs_idx])
		end
		for i, t in ipairs(page_tracks) do
			table.insert(
				child,
				common.media_row(t, page_start + i - 1, function()
					request("play_with_queue", { item = t, index = i, queue = page_tracks })
				end, data.player.id == t.id)
			)
		end

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
				text = page_start .. "–" .. page_end .. " of " .. n_tr,
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
			}, controls)
		)
	end

	return child
end

return { build = build_offline }
