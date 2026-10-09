local theme = require("../utils/theme.luau")
local state = require("./state.luau")
local rerender = require("./rerender.luau")

-- fileExists is a synchronous host call; on hover every row re-renders, so
-- memoize existence with a short TTL. Newly-downloaded thumbs and deleted
-- files self-correct within EXISTS_TTL seconds.
local exists_cache = {}
local EXISTS_TTL = 5

local function file_exists_cached(path)
	local e = exists_cache[path]
	local now = os.time()
	if e and (now - e.at) < EXISTS_TTL then
		return e.ok
	end
	local ok = noctalia.fileExists(path)
	exists_cache[path] = { ok = ok, at = now }
	return ok
end

local function fmt_pos(seconds)
	seconds = tonumber(seconds) or 0
	local m = math.floor(seconds / 60)
	local s = math.floor(seconds % 60)
	return string.format("%d:%02d", m, s)
end

local function fmt_count(n)
	n = tonumber(n) or 0
	if n >= 1000000000 then
		return string.format("%.1fB", n / 1000000000)
	elseif n >= 1000000 then
		return string.format("%.1fM", n / 1000000)
	elseif n >= 1000 then
		return string.format("%.1fK", n / 1000)
	end
	return tostring(n)
end

-- Local text filter using the host's native matcher. Empty query matches
-- everything; otherwise true when the pattern fuzzy-matches. Falls back to
-- a plain substring search when the host matcher is unavailable.
local function fuzzy_match(query, text)
	if not query or query == "" then
		return true
	end
	text = tostring(text or "")
	if text == "" then
		return false
	end
	if noctalia.fuzzyScore then
		return noctalia.fuzzyScore(query, text) ~= nil
	end
	return text:lower():find(query:lower(), 1, true) ~= nil
end

local function thumb_or_placeholder(path, size, glyph, glyph_size, color, fill)
	if path and file_exists_cached(path) then
		return ui.image({ path = path, width = size, height = size, fit = "cover", radius = theme.radius })
	end
	return ui.row({
		width = size,
		height = size,
		align = "center",
		justify = "center",
		fill = fill or "surface_variant/0.3",
		borderWidth = 0,
		radius = theme.radius,
	}, {
		ui.glyph({ name = glyph or "music", size = glyph_size or 20, color = color or "on_surface_variant" }),
	})
end

local function icon_btn(glyph, onClick, variant)
	local v = "ghost"
	if type(variant) == "boolean" then
		v = variant and "primary" or "ghost"
	elseif type(variant) == "string" and variant ~= "" then
		v = variant
	end
	return ui.button({
		glyph = glyph,
		variant = v,
		controlSize = "sm",
		onClick = onClick or function() end,
	})
end

local function chunk_rows(cells, per_row, key_prefix, gap)
	-- Pad the final row with invisible stretch cells so short rows keep the
	-- same card width as full ones instead of growing to fill the panel.
	while #cells % per_row ~= 0 do
		table.insert(
			cells,
			ui.column({
				key = key_prefix .. "-pad-" .. (#cells + 1),
				flexGrow = 1,
				borderWidth = 0,
				radius = theme.radius,
			})
		)
	end

	local rows = {}
	for i = 1, #cells, per_row do
		local row_children = { cells[i] }
		for j = i + 1, math.min(i + per_row - 1, #cells) do
			table.insert(row_children, cells[j])
		end
		table.insert(
			rows,
			ui.row({
				key = key_prefix .. "-row-" .. i,
				gap = gap or 10,
				align = "stretch",
				radius = theme.radius,
			}, row_children)
		)
	end
	return rows
end

-- spec = { drag_type, payload, enabled? }
local function drag_grip(row_key, spec, highlighted)
	return ui.dragSource({
		key = row_key .. "-grip",
		dragType = spec.drag_type,
		payload = tostring(spec.payload),
		enabled = spec.enabled ~= false,
		previewAncestor = 2, -- 2 = the onClick wrapper around the row; 1 leaves a hole
		liftFromLayout = true,
		width = 20,
		height = 32,
		align = "center",
		justify = "center",
		tooltip = spec.tooltip or "Drag to reorder",
	}, {
		ui.glyph({
			key = row_key .. "-grip-glyph",
			name = "grip-vertical",
			size = 16,
			color = highlighted and "primary" or "on_surface_variant",
		}),
	})
end

local function track_actions(item, row_key, trailing)
	local is_expanded = (
		state.view.expanded_track_id ~= nil
		and item.id ~= nil
		and state.view.expanded_track_id == item.id
		and state.view.expanded_row_key == row_key
	)
	local is_liked = (state.data.liked_ids and item.id and state.data.liked_ids[item.id] == true)
	local id_on_disk = (state.data.cached_audio_ids and item.id and state.data.cached_audio_ids[item.id] == true)
	local is_explicit = (id_on_disk and state.data.offline_meta and item.id and state.data.offline_meta[item.id] ~= nil)

	local trailing_row = ui.row({
		key = row_key .. "-trailing-row",
		gap = 10,
		paddingH = 8,
		align = "center",
		visible = (not is_expanded) and (trailing ~= nil and #trailing > 0),
	}, trailing or {})

	local addqueue_button = ui.button({
		key = row_key .. "-addqueue",
		glyph = "plus",
		variant = "ghost",
		controlSize = "sm",
		tooltip = "Add to queue",
		visible = is_expanded,
		onClick = function()
			state.execute_track_action("add_queue", item)
			state.collapse_track()
			rerender.call()
		end,
		onHover = function(h)
			state.track_hover(h, row_key, "addqueue", item)
		end,
	})

	local playnext_button = ui.button({
		key = row_key .. "-playnext",
		glyph = "playlist-add",
		variant = "ghost",
		controlSize = "sm",
		tooltip = "Play next",
		visible = is_expanded,
		onClick = function()
			state.execute_track_action("play_next", item)
			state.collapse_track()
			rerender.call()
		end,
		onHover = function(h)
			state.track_hover(h, row_key, "playnext", item)
		end,
	})

	local like_button = ui.button({
		key = row_key .. "-like",
		glyph = "heart",
		variant = is_liked and "primary" or "ghost",
		controlSize = "sm",
		tooltip = is_liked and "Remove from Liked" or "Add to Liked",
		visible = is_expanded,
		onClick = function()
			state.execute_track_action("toggle_like", item)
			rerender.call()
		end,
		onHover = function(h)
			state.track_hover(h, row_key, "like", item)
		end,
	})

	local dl_button = ui.button({
		key = row_key .. "-dl",
		glyph = is_explicit and "trash" or "download",
		variant = "ghost",
		controlSize = "sm",
		tooltip = is_explicit and "Remove from downloads"
			or (id_on_disk and "Save to offline" or "Download for offline"),
		visible = is_expanded,
		onClick = function()
			state.execute_track_action("download", item)
			rerender.call()
		end,
		onHover = function(h)
			state.track_hover(h, row_key, "dl", item)
		end,
	})

	local copy_button = ui.button({
		key = row_key .. "-copy",
		glyph = "copy",
		variant = "ghost",
		controlSize = "sm",
		tooltip = "Copy YouTube Music link",
		visible = is_expanded,
		onClick = function()
			state.execute_track_action("copy_link", item)
			state.collapse_track()
			rerender.call()
		end,
		onHover = function(h)
			state.track_hover(h, row_key, "copy", item)
		end,
	})

	local menu_button = ui.button({
		key = row_key .. "-menu",
		glyph = "dots-vertical",
		variant = "ghost",
		controlSize = "sm",
		tooltip = "Right click for menu",
		visible = true,
		-- Left click is a deliberate no-op so the button swallows the row's
		-- play onClick; the flyout opens on hover, the menu on right click.
		onClick = function() end,
		onRightClick = function()
			state.open_track_context_menu(item)
		end,
		onHover = function(h)
			state.track_hover(h, row_key, "menu", item)
		end,
	})

	return ui.row({
		key = row_key .. "-actions-row",
		gap = 2,
		align = "center",
		borderWidth = 0,
	}, {
		trailing_row,
		addqueue_button,
		playnext_button,
		like_button,
		dl_button,
		copy_button,
		menu_button,
	})
end

local function media_row(item, idx, custom_click, is_active, drag, key_prefix)
	local handler = custom_click or function()
		state.play_item(item)
	end
	local row_key = (key_prefix and (key_prefix .. "-") or "track-") .. idx
	local is_expanded = (
		state.view.expanded_track_id ~= nil
		and item.id ~= nil
		and state.view.expanded_track_id == item.id
		and state.view.expanded_row_key == row_key
	)
	local is_hovered = (state.view.hover_key.track == row_key or is_expanded)
	local is_playing = (
		state.data.player.id ~= ""
		and item.id ~= nil
		and state.data.player.id == item.id
		and state.data.player.status == "playing"
	)
	local is_loading = (
		state.view.loading_track_id ~= nil
		and item.id ~= nil
		and state.view.loading_track_id == item.id
	)
		or (
			state.data.player.id ~= ""
			and item.id ~= nil
			and state.data.player.id == item.id
			and state.data.player.status == "loading"
		)
	local is_current = is_active or is_playing or is_loading
	local id_on_disk = (state.data.cached_audio_ids and item.id and state.data.cached_audio_ids[item.id] == true)
	local is_explicit = (id_on_disk and state.data.offline_meta and item.id and state.data.offline_meta[item.id] ~= nil)

	local track_thumb = thumb_or_placeholder(
		item.thumb_path,
		54,
		"music",
		20,
		(is_current or is_hovered) and "primary" or "on_surface_variant",
		is_current and "primary/0.2" or "surface_variant/0.3"
	)

	-- Trailing cluster: [✓ | ⚡?] [duration]
	--   ✓  explicit download (listed in Saved Tracks)
	--   ⚡  cached by playback — plays offline, not yet saved
	local trailing = {}
	if is_explicit then
		table.insert(
			trailing,
			ui.button({
				key = row_key .. "-status-check",
				glyph = "check",
				variant = "ghost",
				controlSize = "sm",
				tooltip = "Downloaded for offline playback",
				onHover = function(h)
					state.track_hover(h, row_key, "check", item)
				end,
			})
		)
	elseif id_on_disk then
		table.insert(
			trailing,
			ui.button({
				key = row_key .. "-status-bolt",
				glyph = "bolt",
				variant = "ghost",
				controlSize = "sm",
				tooltip = "Song cached for faster playback",
				onHover = function(h)
					state.track_hover(h, row_key, "bolt", item)
				end,
			})
		)
	end
	table.insert(
		trailing,
		ui.label({
			key = row_key .. "-dur",
			text = item.duration_text or "",
			fontSize = theme.fontBody,
			color = "on_surface_variant",
		})
	)

	local actions_row = track_actions(item, row_key, trailing)

	local row_children = {
		track_thumb,
		ui.column({ gap = 2, flexGrow = 1, radius = theme.radius }, {
			ui.label({
				text = item.title or "Unknown Track",
				fontSize = theme.fontTitle,
				maxLines = 1,
				color = (is_loading or is_current) and "primary" or "on_surface",
			}),
			ui.label({ text = item.artist or "", fontSize = theme.fontTitle, color = "on_surface_variant" }),
		}),
		actions_row,
	}
	if drag then
		table.insert(row_children, 1, drag_grip(row_key, drag, is_hovered or is_current))
	end

	return ui.row({
		key = row_key,
		gap = 14,
		align = "center",
		padding = 8,
		borderWidth = 0,
		fill = (is_loading or is_current) and "primary/0.2"
			or (is_hovered and "primary/0.25" or "surface_variant/0.15"),
		onClick = function()
			state.view.hover_key.track = nil
			state.collapse_track()
			if item and item.id then
				state.view.loading_track_id = item.id
			end
			handler()
			rerender.call()
		end,
		onHover = function(h)
			state.track_hover(h, row_key, nil, item)
		end,
		radius = theme.radius,
	}, row_children)
end

return {
	file_exists_cached = file_exists_cached,
	fmt_pos = fmt_pos,
	fmt_count = fmt_count,
	thumb_or_placeholder = thumb_or_placeholder,
	fuzzy_match = fuzzy_match,
	icon_btn = icon_btn,
	chunk_rows = chunk_rows,
	track_actions = track_actions,
	media_row = media_row,
}
