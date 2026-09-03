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
            fontSize = theme.fontTitle,
            color = "on_surface_variant"
        }))
    end
    table.insert(feed, ui.row({ key = "spacer-above-sep-qp", height = 4, borderWidth = 0 }))
    table.insert(feed, ui.separator({ key = "sep-qp", color = "outline/0.3" }))

    local lib_ids = {}
    if type(data.library) == "table" then
        for _, pl in ipairs(data.library) do
            if pl.id and pl.id ~= "" then
                local id_str = tostring(pl.id)
                lib_ids[id_str] = true
                if id_str:sub(1, 2) == "VL" then
                    lib_ids[id_str:sub(3)] = true
                else
                    lib_ids["VL" .. id_str] = true
                end
            end
        end
    end

    local mixes_source = nil
    if type(data.home_mixes) == "table" and #data.home_mixes > 0 then
        local filtered = {}
        for _, mix in ipairs(data.home_mixes) do
            local mid = tostring(mix.id or "")
            if mid ~= "" and not lib_ids[mid] then
                table.insert(filtered, mix)
                if #filtered >= 6 then
                    break
                end
            end
        end
        if #filtered > 0 then
            mixes_source = filtered
        end
    end

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

    -- Temporarily hidden YOUR LIBRARY section for speed test
    -- table.insert(feed, ui.label({ text = "YOUR LIBRARY", fontSize = theme.fontHeading, fontWeight = "bold", color = "on_surface_variant" }))

    return feed
end

return { build = build_home }