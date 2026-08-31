local theme = require("../utils/theme.luau")
local state = require("./state.luau")
local request = require("./actions.luau")
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

local function thumb_or_placeholder(path, size, glyph, glyph_size, color, fill)
	if path and file_exists_cached(path) then
		return ui.image({ path = path, width = size, height = size, fit = "cover" })
	end
	return ui.row({
		width = size,
		height = size,
		align = "center",
		justify = "center",
		fill = fill or "surface_variant/0.3",
		borderWidth = 0,
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
			}, row_children)
		)
	end
	return rows
end

local function media_row(item, idx, custom_click, is_active)
	local handler = custom_click or function()
		state.play_item(item)
	end
	local row_key = "track-" .. idx
	local is_hovered = (state.view.hover_key.track == row_key)
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

	-- Trailing cluster, built conditionally (never leave nil holes):
	--   [⚡?] [duration] [✓ | ⬇]
	--   ✓  explicit download (listed in Saved Tracks)
	--   ⚡  cached by playback — plays offline, not yet saved
	local trailing = {}
	if id_on_disk and not is_explicit then
		table.insert(
			trailing,
			ui.button({
				key = row_key .. "-bolt",
				glyph = "bolt",
				variant = "ghost",
				controlSize = "sm",
				tooltip = "Song cached for faster playback",
				onHover = function() end,
			})
		)
	end
	table.insert(
		trailing,
		ui.label({
			text = item.duration_text or "",
			fontSize = theme.fontBody,
			color = "on_surface_variant",
		})
	)
	if is_explicit then
		table.insert(trailing, ui.glyph({ name = "check", size = 16, color = "primary" }))
	else
		table.insert(
			trailing,
			ui.button({
				glyph = "download",
				variant = "ghost",
				controlSize = "sm",
				tooltip = id_on_disk and "Add to offline downloads" or "Download for offline",
				onClick = function()
					if item.id and item.id ~= "" then
						-- Full item rides along so standalone downloads can
						-- keep their title/artist in the Offline view.
						request("download_track", { id = item.id, item = item })
					end
				end,
			})
		)
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
			if item and item.id then
				state.view.loading_track_id = item.id
			end
			handler()
			rerender.call()
		end,
		onHover = "onTrackHover",
	}, {
		track_thumb,
		ui.column({ gap = 2, flexGrow = 1 }, {
			ui.label({
				text = item.title or "Unknown Track",
				fontSize = theme.fontTitle,
				maxLines = 1,
				color = (is_loading or is_current) and "primary" or "on_surface",
			}),
			ui.label({ text = item.artist or "", fontSize = theme.fontTitle, color = "on_surface_variant" }),
		}),
		ui.row({ gap = 6, align = "center" }, trailing),
		ui.button({
			key = row_key .. "-playnext",
			glyph = "playlist-add",
			variant = "ghost",
			controlSize = "sm",
			tooltip = "Play next",
			onClick = function()
				state.view.hover_key.track = nil
				if item and item.id then
					request("play_next", { item = item })
				end
			end,
		}),
	})
end

return {
	fmt_pos = fmt_pos,
	fmt_count = fmt_count,
	thumb_or_placeholder = thumb_or_placeholder,
	icon_btn = icon_btn,
	chunk_rows = chunk_rows,
	media_row = media_row,
}
