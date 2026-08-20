local theme = require("../../utils/theme.luau")
local state = require("../state.luau")
local request = require("../actions.luau")
local common = require("../common.luau")
local rerender = require("../rerender.luau")

local function build_home()
    local data = state.data
    local view = state.view
    local feed = {}

    local is_refreshing = (data.refreshing_quick_picks == true)
    table.insert(feed, ui.row({ key = "qp-header", align = "center", justify = "space_between" }, {
        ui.row({ align = "center", gap = 8 }, {
            ui.glyph({ name = "sparkles", size = 18, color = "primary" }),
            ui.column({ gap = 1 }, {
                ui.label({ text = "QUICK PICKS", fontSize = theme.fontHeading, fontWeight = "bold", color = "primary" }),
                ui.label({ text = "Start listening to tracks picked for you", fontSize = theme.fontTitle, color = "on_surface_variant" })
            })
        }),
        ui.button({
            key = "btn-sync-qp",
            glyph = is_refreshing and "loader" or "refresh",
            variant = "ghost",
            controlSize = "sm",
            tooltip = is_refreshing and "Refreshing Quick Picks..." or "Refresh Quick Picks",
            onClick = is_refreshing and nil or function() request("refresh_quick_picks") end
        })
    }))

    if type(data.quick_picks) == "table" and #data.quick_picks > 0 then
        local qp_cells = {}
        for idx, t in ipairs(data.quick_picks) do
            local cell_key = "qp-" .. idx
            local is_current = (data.player.id ~= "" and t.id ~= nil and data.player.id == t.id)
            local is_hovered = (view.hover_key.track == cell_key)

            local thumb = common.thumb_or_placeholder(t.thumb_path, 54, "music", 20, is_current and "primary" or "on_surface_variant", is_current and "primary/0.2" or "surface_variant/0.3")

            table.insert(qp_cells, ui.row({
                key = cell_key,
                gap = 8,
                align = "center",
                padding = 6,
                borderWidth = 0,
                fill = is_current and "primary/0.2" or (is_hovered and "primary/0.25" or "surface_variant/0.15"),
                flexGrow = 1,
                onClick = function()
                    view.hover_key.track = nil
                    request("play_with_queue", { item = t, index = idx, queue = data.quick_picks })
                end,
                onHover = function(hover_state)
                    if hover_state == "true" then
                        if view.hover_key.track ~= cell_key then
                            view.hover_key.track = cell_key
                            rerender.call()
                        end
                    else
                        if view.hover_key.track ~= nil then
                            view.hover_key.track = nil
                            rerender.call()
                        end
                    end
                end
            }, {
                thumb,
                ui.column({ gap = 1, flexGrow = 1 }, {
                    ui.label({ text = t.title or "Unknown Track", fontSize = theme.fontTitle, maxLines = 1, color = is_current and "primary" or "on_surface" }),
                    ui.label({ text = t.artist or "", fontSize = theme.fontTitle, maxLines = 1, color = "on_surface_variant" })
                }),
                ui.button({
                    key = cell_key .. "-playnext",
                    glyph = "playlist-add",
                    variant = "ghost",
                    controlSize = "sm",
                    tooltip = "Play next",
                    onClick = function()
                        view.hover_key.track = nil
                        if t and t.id then
                            request("play_next", { item = t })
                        end
                    end
                })
            }))
        end
        for _, row in ipairs(common.chunk_rows(qp_cells, 3, "qp-grid", 8)) do
            table.insert(feed, row)
        end
    else
        table.insert(feed, ui.label({
            text = state.logged_in() and "Loading Quick Picks recommendations..." or "Sign in to load recommendations.",
            fontSize = theme.fontBody,
            color = "on_surface_variant"
        }))
    end
    table.insert(feed, ui.row({ key = "spacer-above-sep-qp", height = 4, borderWidth = 0 }))
    table.insert(feed, ui.separator({ key = "sep-qp", color = "outline/0.3" }))

    local mixes_source = (type(data.home_mixes) == "table" and #data.home_mixes > 0) and data.home_mixes or nil

    if mixes_source then
        table.insert(feed, ui.row({ key = "spacer-mixes", height = 4, borderWidth = 0 }))
        table.insert(feed, ui.label({ text = "RECOMMENDED MIXES & RADIOS", fontSize = theme.fontHeading, fontWeight = "bold", color = "on_surface_variant" }))

        local mix_cards = {}
        for _, mix in ipairs(mixes_source) do
            local item_title = mix.title or "Mix"
            local item_sub = (mix.subtitle and mix.subtitle ~= "") and mix.subtitle or "YouTube Radio"
            local mix_key = "mix-" .. tostring(mix.id or item_title)
            local mix_hovered = (view.hover_key.card == mix_key)
            table.insert(mix_cards, ui.column({
                key = mix_key,
                gap = 10,
                padding = 10,
                borderWidth = 1,
                border = "primary/0.4",
                fill = mix_hovered and "primary/0.12" or "primary/0.04",
                flexGrow = 1,
                onClick = function()
                    view.hover_key.card = nil
                    state.open_playlist({ id = mix.id, title = item_title })
                end,
                onHover = "onCardHover"
            }, {
                common.thumb_or_placeholder(mix.thumb_path, 200, "disc", 38, "primary", mix_hovered and "primary/0.2" or "surface_variant/0.6"),
                ui.column({ gap = 2, flexGrow = 1 }, {
                    ui.label({ text = item_title, fontSize = theme.fontTitle, maxLines = 1, color = "on_surface" }),
                    ui.label({ text = item_sub, fontSize = theme.fontTitle, maxLines = 1, color = "on_surface_variant" })
                })
            }))
        end
        for _, row in ipairs(common.chunk_rows(mix_cards, 6, "mix-grid", 14)) do
            table.insert(feed, row)
        end
    end

    table.insert(feed, ui.row({ key = "spacer-above-sep-mixes", height = 4, borderWidth = 0 }))
    table.insert(feed, ui.separator({ key = "sep-mixes", color = "outline/0.3" }))
    table.insert(feed, ui.row({ key = "spacer-library", height = 4, borderWidth = 0 }))

    table.insert(feed, ui.label({ text = "YOUR LIBRARY", fontSize = theme.fontHeading, fontWeight = "bold", color = "on_surface_variant" }))

    if #data.library == 0 then
        table.insert(feed, ui.label({
            text = state.logged_in() and "Loading playlists..." or "Sign in to load your library.",
            fontSize = theme.fontBody,
            color = "on_surface_variant"
        }))
    else
        local cards = {}
        for _, pl in ipairs(data.library) do
            local card_key = "pl-card-" .. pl.id
            local card_hovered = (view.hover_key.card == card_key)

            local pl_id = tostring(pl.id or "")
            local is_pl_downloaded = (data.downloaded_playlist_ids and data.downloaded_playlist_ids[pl_id] == true)

            table.insert(cards, ui.column({
                key = card_key,
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
                onHover = "onCardHover"
            }, {
                common.thumb_or_placeholder(pl.thumb_path, 200, "playlist", 38, "primary", card_hovered and "primary/0.2" or "surface_variant/0.6"),
                ui.column({ gap = 2, flexGrow = 1 }, {
                    ui.row({ align = "center", justify = "space_between" }, {
                        ui.label({ text = pl.title, fontSize = theme.fontTitle, maxLines = 1, color = "on_surface", flexGrow = 1 }),
                        is_pl_downloaded and ui.glyph({ name = "check", size = 16, color = "primary" }) or nil
                    }),
                    ui.label({
                        text = (pl.count and pl.count > 0) and (pl.count .. " tracks") or "Playlist",
                        fontSize = theme.fontTitle,
                        color = "on_surface_variant"
                    })
                })
            }))
        end
        for _, row in ipairs(common.chunk_rows(cards, 6, "pl-grid", 14)) do
            table.insert(feed, row)
        end
    end

    return feed
end

return { build = build_home }