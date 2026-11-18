local schema = require("../utils/schema.luau")
local request = require("./actions.luau")
local rerender = require("./rerender.luau")
local const = require("../api/constants.luau")

local data = schema.new()

local view = {
	content_page = "home",
	search_query = "",
	last_searched_query = "",
	search_timer_nonce = 0,
	playlist_view_page = 0,
	playlist_pending_advance = false,
	queue_view_page = 0,
	queue_filter = "",
	library_text_filter = "",
	offline_view_page = 0,
	offline_track_filter = "",
	offline_filter = "all",
	playlist_text_filter = "",
	settings_tab = "cache",
	loading_track_id = nil,
	expanded_track_id = nil,
	expanded_row_key = nil,
	hover_key = { sidebar = nil, track = nil, card = nil },
	seek_drag_state = nil,
	vol_drag_state = nil,
	home_library_ready = false,
}

local function collapse_track()
	view.expanded_track_id = nil
	view.expanded_row_key = nil
end

local function logged_in()
	return data.status == "ready"
		or (data.cookie_count and data.cookie_count > 0)
		or (noctalia.fileExists and noctalia.fileExists(const.COOKIE_PATH))
end

local function loading_track_id_ok(d)
	if not view.loading_track_id then
		return true
	end
	local p = d.player or {}
	return p.status ~= "loading" or (p.id ~= "" and p.id ~= view.loading_track_id)
end

local function apply(snapshot)
	if type(snapshot) ~= "table" then
		return
	end
	if data and data.nonce and snapshot.nonce and data.nonce == snapshot.nonce then
		return
	end

	local old_playlist_count = type(data.playlist) == "table" and #data.playlist.tracks or 0
	local old_player_index = type(data.player) == "table" and data.player.index or nil

	local fresh = schema.new()
	for k, v in pairs(snapshot) do
		fresh[k] = v
	end
	for k in pairs(data) do
		data[k] = nil
	end
	for k, v in pairs(fresh) do
		data[k] = v
	end

	if loading_track_id_ok(data) then
		view.loading_track_id = nil
	end

	if
		view.playlist_pending_advance
		and type(data.playlist) == "table"
		and #data.playlist.tracks > old_playlist_count
	then
		view.playlist_pending_advance = false
		view.playlist_view_page = view.playlist_view_page + 1
	end

	if
		type(data.player) == "table"
		and data.player.index
		and old_player_index
		and data.player.index ~= old_player_index
	then
		view.queue_view_page = math.max(0, math.floor((data.player.index - 1) / 50))
	end

	rerender.call()
end

local function on_nav(id)
	collapse_track()
	view.content_page = id
	if id ~= "playlist" then
		data.playlist.id = ""
	end
	if id == "home" then
		view.home_library_ready = false
	end
	if id == "settings" then
		request("fetch_cache_stats")
	end
	if id == "offline" then
		view.offline_view_page = 0
		request("fetch_offline")
	end
	rerender.call()
end

local function do_search(query)
	query = tostring(query or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if query == "" then
		return
	end
	collapse_track()
	view.last_searched_query = query
	view.content_page = "discover"
	view.search_query = query
	data.search.pending = true
	data.search.query = query
	data.search.results = {}
	request("search", { query = query, type = data.search.type })
	rerender.call()
end

local function on_search_type(val)
	view.search_query = val or ""
	view.search_timer_nonce = view.search_timer_nonce + 1
	local current_nonce = view.search_timer_nonce
	local target_q = (val or ""):gsub("^%s+", ""):gsub("%s+$", "")

	if target_q == "" or #target_q < 2 then
		view.last_searched_query = ""
		data.search.query = target_q
		data.search.results = {}
		rerender.call()
		return
	end

	noctalia.runAsync("sleep 0.4", function()
		if view.search_timer_nonce == current_nonce then
			do_search(target_q)
		end
	end)
end

local function on_toggle_search_type(stype)
	if data.search.type == stype then
		return
	end
	data.search.type = stype
	if view.last_searched_query ~= "" and view.content_page == "discover" then
		do_search(view.last_searched_query)
	else
		data.search.results = {}
		rerender.call()
	end
end

local function open_playlist(pl)
	collapse_track()
	view.content_page = "playlist"
	view.playlist_view_page = 0
	view.playlist_text_filter = ""
	data.playlist.id = tostring(pl.id or "")
	data.playlist.title = tostring(pl.title or "Playlist")
	data.playlist.count = tonumber(pl.count) or 0
	data.playlist.tracks = {}
	request("open_playlist", { id = pl.id, title = pl.title, count = pl.count })
	rerender.call()
end

local function play_item(item)
	collapse_track()
	if item and item.id then
		view.loading_track_id = item.id
		data.player.id = item.id
		data.player.title = item.title or "Loading..."
		data.player.artist = item.artist or ""
		data.player.status = "loading"
		if item.thumb_path then
			data.player.thumb_path = item.thumb_path
		end
	end
	request("play", { item = item })
	rerender.call()
end

local function play_playlist(pl)
	request("play_playlist", { id = pl.id, title = pl.title })
end

local function open_artist(a)
	collapse_track()
	local artist_name = tostring(a.title or a.name or "Artist")
	data.artist = {
		id = tostring(a.id or ""),
		title = artist_name,
		name = artist_name,
		thumbnail_url = a.thumbnail_url or "",
		thumb_path = a.thumb_path or nil,
	}
	data.artist_tracks = {}
	data.artist_related = {}
	view.content_page = "artist"
	request("fetch_artist", {
		browse_id = data.artist.id,
		title = data.artist.title,
		thumbnail_url = data.artist.thumbnail_url,
		thumb_path = data.artist.thumb_path,
	})
	rerender.call()
end

local hover_render_nonce = 0
local last_hover_render_at = 0
local HOVER_COALESCE_MS = 30

local track_leave_timer_nonce = 0
local hover_intent_nonce = 0
local collapse_timer_nonce = 0

-- Leading-edge + trailing-edge debounce: render immediately when the previous
-- hover render was >30ms ago (slow, deliberate moves stay instant), otherwise
-- coalesce rapid sweeps into the window and render once at the end.
local function hover_render()
	local now = noctalia.nowMs()
	if now - last_hover_render_at >= HOVER_COALESCE_MS then
		last_hover_render_at = now
		rerender.call()
		return
	end
	hover_render_nonce = hover_render_nonce + 1
	local n = hover_render_nonce
	noctalia.runAsync("sleep 0.03", function()
		if hover_render_nonce == n then
			last_hover_render_at = noctalia.nowMs()
			rerender.call()
		end
	end)
end

local function hover_update(slot, hover_state, key)
	if (slot == "sidebar" or slot == "card") and hover_state == "true" then
		if view.expanded_row_key then
			collapse_track()
		end
	end

	local current = view.hover_key[slot]
	if hover_state == "true" then
		if current ~= key then
			view.hover_key[slot] = key
			hover_render()
		end
	elseif current == key then
		if slot == "track" then
			if view.expanded_row_key == key then
				return
			end
			local n = track_leave_timer_nonce + 1
			track_leave_timer_nonce = n
			noctalia.runAsync("sleep 0.06", function()
				if track_leave_timer_nonce == n and view.hover_key.track == key then
					if view.expanded_row_key ~= key then
						view.hover_key.track = nil
						last_hover_render_at = noctalia.nowMs()
						rerender.call()
					end
				end
			end)
			return
		end
		view.hover_key[slot] = nil
		hover_render()
	end
end

local function track_hover(hover_state, row_key, sub, item)
	if not row_key then
		return
	end

	if hover_state == "true" then
		track_leave_timer_nonce = track_leave_timer_nonce + 1
		collapse_timer_nonce = collapse_timer_nonce + 1

		if view.expanded_row_key and view.expanded_row_key ~= row_key then
			collapse_track()
		end

		if view.hover_key.track ~= row_key then
			view.hover_key.track = row_key
			hover_render()
		end

		if sub == "menu" and item and item.id then
			if view.expanded_row_key ~= row_key then
				local n = hover_intent_nonce + 1
				hover_intent_nonce = n
				noctalia.runAsync("sleep 0.12", function()
					if hover_intent_nonce == n and view.hover_key.track == row_key then
						view.expanded_track_id = item.id
						view.expanded_row_key = row_key
						rerender.call()
					end
				end)
			end
		end
	else
		-- hover_state == "false"
		if sub == "menu" then
			hover_intent_nonce = hover_intent_nonce + 1
		end

		if view.expanded_row_key == row_key then
			local n = collapse_timer_nonce + 1
			collapse_timer_nonce = n
			noctalia.runAsync("sleep 0.25", function()
				if collapse_timer_nonce == n and view.expanded_row_key == row_key then
					collapse_track()
					if view.hover_key.track == row_key then
						view.hover_key.track = nil
					end
					rerender.call()
				end
			end)
		else
			local n = track_leave_timer_nonce + 1
			track_leave_timer_nonce = n
			noctalia.runAsync("sleep 0.06", function()
				if track_leave_timer_nonce == n and view.hover_key.track == row_key then
					if view.expanded_row_key ~= row_key then
						view.hover_key.track = nil
						last_hover_render_at = noctalia.nowMs()
						rerender.call()
					end
				end
			end)
		end
	end
end

local function expand_track(item, row_key)
	if not item or not item.id or item.id == "" then
		return
	end
	if view.expanded_track_id == item.id and view.expanded_row_key == row_key then
		return
	end
	view.expanded_track_id = item.id
	view.expanded_row_key = row_key
	view.hover_key.track = row_key
	rerender.call()
end

local context_menu_track = nil

local function open_track_context_menu(item)
	if not item or not item.id or item.id == "" then
		return
	end
	context_menu_track = item

	local id_on_disk = (data.cached_audio_ids and data.cached_audio_ids[item.id] == true)
	local is_explicit = (id_on_disk and data.offline_meta and data.offline_meta[item.id] ~= nil)
	local is_liked = (data.liked_ids and data.liked_ids[item.id] == true)
	local raw_title = tostring(item.title or "Track")
	local header_label = (#raw_title > 25) and (raw_title:sub(1, 24) .. "…") or raw_title
	local items = {
		{ kind = "header", label = header_label },
		{ id = "play", label = "Play now" },
		{ id = "play_next", label = "Play next" },
		{ id = "add_queue", label = "Add to queue" },
		{ kind = "separator" },
		{ id = "toggle_like", label = is_liked and "Remove from Liked" or "Add to Liked" },
		{
			id = "download",
			label = is_explicit and "Remove from downloads"
				or (id_on_disk and "Save to offline" or "Download for offline"),
		},
		{ kind = "separator" },
		{ id = "copy_link", label = "Copy link" },
	}

	if panel and panel.openContextMenu then
		local ok = panel.openContextMenu({
			items = items,
			onActivate = "onTrackContextMenu",
			context = item.id,
			maxVisible = 12,
		})
		print("[ytm/menu] openContextMenu returned:", tostring(ok))
	end
end

local function execute_track_action(action_id, track)
	if not track or not track.id or track.id == "" then
		return
	end

	if action_id == "play" then
		play_item(track)
	elseif action_id == "play_next" then
		request("play_next", { item = track })
	elseif action_id == "add_queue" then
		request("add_to_queue", { item = track })
	elseif action_id == "toggle_like" then
		request("toggle_like", { id = track.id, item = track })
	elseif action_id == "download" then
		local id_on_disk = (data.cached_audio_ids and data.cached_audio_ids[track.id] == true)
		local is_explicit = (id_on_disk and data.offline_meta and data.offline_meta[track.id] ~= nil)
		if is_explicit then
			request("remove_download", { id = track.id, item = track })
		else
			request("download_track", { id = track.id, item = track })
		end
	elseif action_id == "copy_link" then
		if noctalia and noctalia.copyToClipboard then
			noctalia.copyToClipboard("https://music.youtube.com/watch?v=" .. track.id, "text/plain")
		end
	end
end

local function handle_track_context_menu(action_id, track_id)
	local track = context_menu_track
	if not track or track.id ~= track_id then
		return
	end
	execute_track_action(action_id, track)
end

return {
	data = data,
	view = view,
	apply = apply,
	logged_in = logged_in,
	on_nav = on_nav,
	do_search = do_search,
	on_search_type = on_search_type,
	on_toggle_search_type = on_toggle_search_type,
	open_playlist = open_playlist,
	open_artist = open_artist,
	play_item = play_item,
	play_playlist = play_playlist,
	hover_update = hover_update,
	track_hover = track_hover,
	open_track_context_menu = open_track_context_menu,
	handle_track_context_menu = handle_track_context_menu,
	execute_track_action = execute_track_action,
	collapse_track = collapse_track,
	expand_track = expand_track,
}
