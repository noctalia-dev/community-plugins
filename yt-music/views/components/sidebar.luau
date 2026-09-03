local theme = require("../../utils/theme.luau")
local state = require("../state.luau")
local common = require("../common.luau")
local rerender = require("../rerender.luau")

local NAV_ITEMS = {
    { id = "home", label = "For you", icon = "home" },
    { id = "discover", label = "Search", icon = "search" },
    { id = "queue", label = "Queue", icon = "music" },
    { id = "offline", label = "Offline", icon = "download" },
    { id = "library", label = "Library", icon = "library" },
    { id = "settings", label = "Settings", icon = "settings" }
}

local function sidebar_row(key, icon, label, subtext, active, onClick, thumb_path, bold_active, text_color)
    local is_hovered = (state.view.hover_key.sidebar == key)
    local fill_color = active and "primary/0.2" or (is_hovered and "primary/0.25" or "surface_variant/0.15")
    local glyph_color = (active or is_hovered) and "primary" or "on_surface_variant"

    local icon_elem
    if thumb_path and common.file_exists_cached(thumb_path) then
        icon_elem = ui.image({ path = thumb_path, width = 26, height = 26, fit = "cover" })
    else
        icon_elem = ui.glyph({ name = icon, size = 17, color = glyph_color })
    end

    return ui.row({
        key = key,
        gap = 10,
        align = "center",
        padding = 8,
        borderWidth = 0,
        fill = fill_color,
        onClick = function()
            state.view.hover_key.sidebar = nil
            onClick()
        end,
        onHover = "onSidebarHover"
    }, {
        icon_elem,
        ui.column({ gap = 1, flexGrow = 1 }, {
            ui.label({
                text = label,
                fontSize = theme.fontTitle,
                maxLines = 1,
                fontWeight = (active and bold_active ~= false) and "bold" or "medium",
                color = text_color or (active and "primary" or "on_surface"),
                flexGrow = 1
            }),
            subtext and ui.label({
                text = subtext,
                fontSize = theme.fontBody,
                color = "on_surface_variant"
            }) or nil
        })
    })
end

local function build_topbar()
    return ui.row({ key = "topbar", align = "center", gap = 12, paddingH = 16, paddingV = 10, borderWidth = 0 }, {
        ui.input({
            key = "search-input",
            placeholder = "Search songs, artists, albums",
            value = state.view.search_query,
            flexGrow = 1,
            onChange = function(val) state.on_search_type(val) end,
            onSubmit = function() state.do_search(state.view.search_query) end
        })
    })
end

local function build_sidebar()
    local data = state.data
    local view = state.view
    local sidebar_items = {}

    table.insert(sidebar_items, ui.row({ key = "side-brand", align = "center", gap = 9, padding = 6, borderWidth = 0 }, {
        ui.glyph({ name = "brand-youtube-filled", size = 30, color = "primary" }),
        ui.column({ gap = 1, flexGrow = 1 }, {
            ui.label({ text = "Music", fontSize = theme.fontHeading, fontWeight = "bold", color = "on_surface" }),
            ui.label({ text = "for YouTube Music", fontSize = theme.fontTitle, color = "on_surface_variant" })
        })
    }))

    table.insert(sidebar_items, ui.separator({ key = "sep-brand", color = "outline", spacing = 8 }))

    for idx, item in ipairs(NAV_ITEMS) do
        local key = "nav-" .. idx
        local active = (view.content_page == item.id)
        table.insert(sidebar_items, sidebar_row(key, item.icon, item.label, nil, active, function()
            state.on_nav(item.id)
        end))
    end

    -- Always-visible connectivity cue, independent of which page is open.
    if data.online == false then
        table.insert(sidebar_items, ui.row({
            key = "offline-indicator",
            gap = 8,
            align = "center",
            padding = 6,
            borderWidth = 0
        }, {
            ui.glyph({ name = "wifi-off", size = 15, color = "error" }),
            ui.label({ text = "Offline mode", fontSize = theme.fontTitle, color = "error" })
        }))
    end

    table.insert(sidebar_items, ui.separator({ key = "sep-side", color = "outline", spacing = 8 }))

    -- Hide stale cached history while signed out; reappears reactively once
    -- cookies land and status flips to ready.
    if state.logged_in()
        and type(data.recent_playlists) == "table" and #data.recent_playlists > 0 then
        table.insert(sidebar_items, ui.row({ key = "label-recent", gap = 0, padding = 6, borderWidth = 0 }, {
            ui.label({
                text = "RECENTLY PLAYED",
                fontSize = theme.fontBody,
                fontWeight = "bold",
                color = "on_surface_variant"
            })
        }))

        for idx, pl in ipairs(data.recent_playlists) do
            local pl_id = tostring(pl.id or "")
            local key = "recent-" .. idx
            local active = (view.content_page == "playlist" and pl_id ~= "" and data.playlist.id == pl_id)
            local is_source = (data.player and data.player.source_playlist ~= nil and tostring(data.player.source_playlist) == pl_id)
            table.insert(sidebar_items, sidebar_row(key, "clock", pl.title, nil, active, function()
                state.open_playlist(pl)
            end, nil, false, is_source and "primary" or nil))
        end

        table.insert(sidebar_items, ui.separator({ key = "sep-recent", color = "outline", spacing = 8 }))
    end

    table.insert(sidebar_items, ui.row({ key = "label-library", gap = 0, padding = 6, borderWidth = 0 }, {
        ui.label({
            text = "YOUR LIBRARY",
            fontSize = theme.fontBody,
            fontWeight = "bold",
            color = "on_surface_variant"
        })
    }))

    local library_list = {}
    if #data.library == 0 then
        table.insert(library_list, ui.label({
            text = state.logged_in() and "Loading your playlists..." or "Sign in to see your playlists",
            fontSize = theme.fontBody,
            color = "on_surface_variant"
        }))
    else
        for idx, pl in ipairs(data.library) do
            local pl_id = tostring(pl.id or "")
            local key = "pl-" .. idx
            local active = (
                (view.content_page == "playlist" and pl_id ~= "" and data.playlist and data.playlist.id == pl_id) or
                (view.content_page == "artist" and pl_id ~= "" and data.artist and data.artist.id == pl_id)
            )
            local is_source = (data.player and data.player.source_playlist ~= nil and tostring(data.player.source_playlist) == pl_id)
            local title_lower = (pl.title or ""):lower()
            local sub_lower = (pl.subtitle or ""):lower()
            local row_icon = "playlist"
            if title_lower:find("liked", 1, true) or pl_id == "VLLM" then
                row_icon = "heart"
            elseif pl_id:sub(1, 2) == "UC" or sub_lower:find("artist", 1, true) then
                row_icon = "user"
            elseif pl_id:sub(1, 5) == "MPREb" or sub_lower:find("album", 1, true) then
                row_icon = "disc"
            end
            table.insert(library_list, sidebar_row(key, row_icon, pl.title, nil, active, function()
                if pl_id:sub(1, 2) == "UC" then
                    state.open_artist({ id = pl_id, title = pl.title, name = pl.title, thumbnail_url = pl.thumbnail_url, thumb_path = pl.thumb_path })
                else
                    state.open_playlist(pl)
                end
            end, pl.thumb_path, false, is_source and "primary" or nil))
        end
    end

    table.insert(sidebar_items, ui.scroll({ key = "library-scroll", flexGrow = 1, gap = 0 }, library_list))

    return ui.column({ key = "sidebar", width = 256, gap = 2, paddingH = 12, paddingV = 12, borderWidth = 1, border = "primary/0.4", fill = "primary/0.04" }, sidebar_items)
end

return {
    build_topbar = build_topbar,
    build_sidebar = build_sidebar
}