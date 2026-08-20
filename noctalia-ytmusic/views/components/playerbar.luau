local theme = require("../../utils/theme.luau")
local state = require("../state.luau")
local request = require("../actions.luau")
local common = require("../common.luau")

local function audio_spec_tooltip()
    local player = state.data.player or {}
    local codec_str = (player.codec and player.codec ~= "") and string.upper(player.codec) or "OPUS"
    local bitrate_str = (player.bitrate and tonumber(player.bitrate) > 0) and (math.floor(tonumber(player.bitrate) / 1000) .. " kbps") or "256 kbps"
    local rate_str = (player.samplerate and tonumber(player.samplerate) > 0) and string.format("%.1f kHz", tonumber(player.samplerate) / 1000) or "48.0 kHz"
    local title = (player.title ~= nil and player.title ~= "") and player.title or "Nothing playing"
    local artist = (player.artist ~= nil and player.artist ~= "") and player.artist or "—"
    return ("%s\n%s\n\nCodec: %s\nBitrate: %s\nSample rate: %s\nOutput driver: PipeWire\nVolume: %d%%")
        :format(title, artist, codec_str, bitrate_str, rate_str, tonumber(player.volume) or 70)
end

local function build_player_bar()
    local player = state.data.player
    local view = state.view
    local is_playing = (player.status == "playing")
    local track_label = player.title or ""
    if track_label == "" then
        track_label = "Nothing playing"
    end

    local track_meta = (player.artist ~= nil and player.artist ~= "") and player.artist or "Pick something to play"

    local duration = tonumber(player.duration) or 0
    local position = math.min(tonumber(player.position) or 0, duration)

    local player_thumb = common.thumb_or_placeholder(player.thumb_path, 64, "music", 24, is_playing and "primary" or "on_surface_variant")

    local now_playing = ui.row({ key = "pb-now", align = "center", gap = 10, width = 300 }, {
        player_thumb,
        ui.column({ gap = 1, flexGrow = 1 }, {
            ui.row({ key = "pb-title-row", align = "center", gap = 6 }, {
                ui.label({
                    text = track_label,
                    fontSize = theme.fontTitle,
                    maxLines = 1,
                    fontWeight = "bold",
                    color = "on_surface",
                    flexGrow = 1
                }),
                (function()
                    local is_liked = (state.data.liked_ids and player.id and state.data.liked_ids[player.id] == true)
                    return common.icon_btn("heart", function()
                        if player.id and player.id ~= "" then
                            request("toggle_like", { id = player.id })
                        end
                    end, is_liked)
                end)(),
                ui.button({
                    glyph = "activity",
                    variant = "ghost",
                    controlSize = "sm",
                    tooltip = audio_spec_tooltip(),
                    onHover = function() end
                })
            }),
            ui.column({ gap = 3 }, {
                ui.label({
                    text = track_meta,
                    fontSize = theme.fontTitle,
                    maxLines = 1,
                    color = is_playing and "primary" or "on_surface_variant"
                }),
                (function()
                    local stats_text = ""
                    local stats = {}
                    if player.views and player.views > 0 then
                        table.insert(stats, common.fmt_count(player.views) .. " views")
                    end
                    if player.likes and player.likes > 0 then
                        table.insert(stats, common.fmt_count(player.likes) .. " likes")
                    end
                    stats_text = table.concat(stats, " • ")
                    -- Always render the stats line so the column height is stable
                    -- and the artist label above it never shifts when stats arrive.
                    return ui.label({
                        text = (stats_text == "") and "\u{00A0}" or stats_text,
                        fontSize = theme.fontTitle,
                        maxLines = 1,
                        color = "on_surface_variant"
                    })
                end)()
            })
        })
    })

    if view.seek_drag_state and view.seek_drag_state.track_id ~= state.data.player.id then
        view.seek_drag_state = nil
    end
    local is_drag_active = view.seek_drag_state and view.seek_drag_state.track_id == state.data.player.id and view.seek_drag_state.dragging
    local slider_val = tonumber((is_drag_active and view.seek_drag_state.position) or position) or 0

    local is_loading = (state.data.player.status == "loading")
    local is_playing = (state.data.player.status == "playing")
    local play_glyph = is_loading and "loader" or (is_playing and "player-pause" or "player-play")
    local shuffle_active = (state.data.player.shuffle == true)
    local rep_mode = state.data.player.repeat_mode or "off"
    local rep_active = (rep_mode ~= "off")
    local rep_glyph = (rep_mode == "one") and "repeat-once" or "repeat"
    local rep_tooltip = (rep_mode == "one") and "Repeat Track (1)" or ((rep_mode == "all") and "Repeat Queue" or "Repeat Off")

    local controls = {
        common.icon_btn("arrows-shuffle", function() request("toggle_shuffle") end, shuffle_active),
        common.icon_btn("player-skip-back", function() request("prev") end),
        ui.button({
            glyph = play_glyph,
            variant = "primary",
            controlSize = "md",
            onClick = function() request("toggle") end
        }),
        common.icon_btn("player-skip-forward", function() request("next") end),
        ui.button({
            glyph = rep_glyph,
            variant = rep_active and "primary" or "ghost",
            controlSize = "sm",
            tooltip = rep_tooltip,
            onClick = function() request("cycle_repeat") end
        })
    }

    local transport = ui.column({
        key = "pb-center-col",
        align = "center",
        gap = 1,
        flexGrow = 1,
        justify = "center"
    }, {
        ui.row({ key = "pb-scrub", align = "center", gap = 10, width = 900 }, {
            ui.label({ key = "pb-pos-label", text = common.fmt_pos(slider_val), fontSize = theme.fontCaption, color = "on_surface_variant" }),
            ui.slider({
                key = "pb-seek",
                min = 0,
                max = math.max(1, duration),
                step = 1,
                value = math.floor(slider_val),
                flexGrow = 1,
                controlSize = "sm",
                onChange = function(v)
                    local num = tonumber(v)
                    -- Ignore programmatic onChange events (which echo back the current value)
                    if num and num ~= math.floor(position) then
                        view.seek_drag_state = { dragging = true, position = num, timestamp = os.time(), track_id = state.data.player.id }
                    end
                end,
                onDragEnd = function()
                    local target = (view.seek_drag_state and view.seek_drag_state.position) or position
                    view.seek_drag_state = nil
                    request("seek", { seconds = target, value = target })
                end
            }),
            ui.label({ key = "pb-dur-label", text = common.fmt_pos(duration), fontSize = theme.fontCaption, color = "on_surface_variant" })
        }),
        ui.row({ key = "pb-controls", align = "center", justify = "center", gap = 3 }, controls)
    })

    local vol = player.volume or 70
    local vol_icon = "volume"
    if vol == 0 then
        vol_icon = "volume-off"
    elseif vol < 50 then
        vol_icon = "volume-2"
    end

    local output_controls = ui.row({ key = "pb-right", align = "center", gap = 8, width = 170, justify = "end" }, {
        common.icon_btn(vol_icon, function() request("toggle_mute") end),
        ui.slider({
            key = "pb-volume",
            min = 0,
            max = 100,
            step = 5,
            value = vol,
            flexGrow = 1,
            onChange = function(v)
                local num = tonumber(v)
                if num and num ~= math.floor(vol) then
                    view.vol_drag_state = { dragging = true, value = num, timestamp = os.time() }
                end
            end,
            onDragEnd = function()
                local target = (view.vol_drag_state and view.vol_drag_state.value) or vol
                view.vol_drag_state = nil
                request("volume", { value = target })
            end
        }),
        ui.label({ text = tostring(vol) .. "%", fontSize = theme.fontCaption, color = "on_surface_variant" })
    })

    return ui.row({
        key = "player-bar",
        align = "center",
        gap = 12,
        paddingH = 12,
        paddingV = 10,
        borderWidth = 1,
        border = "primary/0.4",
        fill = "primary/0.04"
    }, {
        now_playing,
        transport,
        output_controls
    })
end

return { build = build_player_bar }