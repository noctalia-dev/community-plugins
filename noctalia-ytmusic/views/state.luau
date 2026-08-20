local schema = require("../utils/schema.luau")
local request = require("./actions.luau")
local rerender = require("./rerender.luau")

local data = schema.new()

local view = {
    content_page = "home",
    search_query = "",
    last_searched_query = "",
    search_timer_nonce = 0,
    playlist_view_page = 0,
    playlist_pending_advance = false,
    queue_view_page = 0,
    loading_track_id = nil,
    hover_key = { sidebar = nil, track = nil, card = nil },
    seek_drag_state = nil,
    vol_drag_state = nil
}

local function logged_in()
    return data.status == "ready"
end

local function loading_track_id_ok(d)
    if not view.loading_track_id then return true end
    local p = d.player or {}
    return p.status ~= "loading" or (p.id ~= "" and p.id ~= view.loading_track_id)
end

local function apply(snapshot)
    if type(snapshot) ~= "table" then return end

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

    if view.playlist_pending_advance and type(data.playlist) == "table"
        and #data.playlist.tracks > old_playlist_count then
        view.playlist_pending_advance = false
        view.playlist_view_page = view.playlist_view_page + 1
    end

    if type(data.player) == "table" and data.player.index and old_player_index
        and data.player.index ~= old_player_index then
        view.queue_view_page = math.max(0, math.floor((data.player.index - 1) / 50))
    end

    rerender.call()
end

local function on_nav(id)
    view.content_page = id
    if id ~= "playlist" then
        data.playlist.id = ""
    end
    if id == "settings" then
        request("fetch_cache_stats")
    end
    rerender.call()
end

local function do_search(query)
    query = tostring(query or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if query == "" then return end
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
    if data.search.type == stype then return end
    data.search.type = stype
    if view.last_searched_query ~= "" and view.content_page == "discover" then
        do_search(view.last_searched_query)
    else
        data.search.results = {}
        rerender.call()
    end
end

local function open_playlist(pl)
    view.content_page = "playlist"
    view.playlist_view_page = 0
    data.playlist.id = tostring(pl.id or "")
    data.playlist.title = tostring(pl.title or "Playlist")
    data.playlist.count = tonumber(pl.count) or 0
    data.playlist.tracks = {}
    request("open_playlist", { id = pl.id, title = pl.title, count = pl.count })
    rerender.call()
end

local function play_item(item)
    if item and item.id then
        view.loading_track_id = item.id
        data.player.id = item.id
        data.player.title = item.title or "Loading..."
        data.player.artist = item.artist or ""
        data.player.status = "loading"
        if item.thumb_path then data.player.thumb_path = item.thumb_path end
    end
    request("play", { item = item })
    rerender.call()
end

local function play_playlist(pl)
    request("play_playlist", { id = pl.id, title = pl.title })
end

local hover_render_nonce = 0
local last_hover_render_at = 0
local HOVER_COALESCE_MS = 30

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
    local current = view.hover_key[slot]
    if hover_state == "true" then
        if current ~= key then
            view.hover_key[slot] = key
            hover_render()
        end
    elseif current == key then
        view.hover_key[slot] = nil
        hover_render()
    end
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
    play_item = play_item,
    play_playlist = play_playlist,
    hover_update = hover_update
}