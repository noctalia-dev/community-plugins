local STATE = "noctalia_ytmusic.state"
local theme = require("./utils/theme.luau")
local request = require("./views/actions.luau")

local state = {
    status = "idle",
    player = {
        status = "stopped",
        title = "",
        artist = "",
        id = "",
        position = 0,
        duration = 0,
        volume = 100,
        queue = {},
        index = 0
    }
}

local seek_drag_state = nil

local function fmt_time(sec)
    sec = tonumber(sec) or 0
    if sec <= 0 then return "0:00" end
    local m = math.floor(sec / 60)
    local s = math.floor(sec % 60)
    return string.format("%d:%02d", m, s)
end

local function icon_btn(glyph, cb, active)
    return ui.button({
        glyph = glyph,
        variant = active and "primary" or "ghost",
        controlSize = "md",
        onClick = cb
    })
end

local function audio_spec_tooltip()
    local player = state.player or {}
    local codec_str = (player.codec and player.codec ~= "") and string.upper(player.codec) or "OPUS"
    local bitrate_str = (player.bitrate and tonumber(player.bitrate) > 0) and (math.floor(tonumber(player.bitrate) / 1000) .. " kbps") or "256 kbps"
    local rate_str = (player.samplerate and tonumber(player.samplerate) > 0) and string.format("%.1f kHz", tonumber(player.samplerate) / 1000) or "48.0 kHz"
    local title = (player.title ~= nil and player.title ~= "") and player.title or "Nothing playing"
    local artist = (player.artist ~= nil and player.artist ~= "") and player.artist or "—"
    return ("%s\n%s\n\nCodec: %s\nBitrate: %s\nSample rate: %s\nOutput driver: PipeWire\nVolume: %d%%")
        :format(title, artist, codec_str, bitrate_str, rate_str, tonumber(player.volume) or 70)
end

local function is_logged_in()
    return state.status == "ready" or (state.cookie_count and state.cookie_count > 0)
end

local function render_mini()
    if not is_logged_in() then
        panel.render(ui.column({
            key = "mini-login",
            align = "center",
            justify = "center",
            gap = 16,
            padding = 24,
            flexGrow = 1
        }, {
            ui.glyph({ name = "user-x", size = 48, color = "on_surface_variant/0.5" }),
            ui.label({ text = "Not Logged In", fontSize = theme.fontHeading, fontWeight = "bold", color = "on_surface" }),
            ui.label({ text = "Sign in to YouTube Music to use the mini player.", fontSize = theme.fontBody, color = "on_surface_variant", textAlign = "center" }),
            ui.button({
                text = "Open Main Window",
                variant = "primary",
                controlSize = "md",
                onClick = function() noctalia.togglePanel("aabidk20/noctalia-ytmusic:panel") end
            })
        }))
        return
    end

    local player = state.player or {}
    local is_playing = (player.status == "playing")
    local duration = tonumber(player.duration) or 0
    local position = math.min(tonumber(player.position) or 0, duration)

    if seek_drag_state and seek_drag_state.track_id ~= player.id then
        seek_drag_state = nil
    end

    local is_drag_active = seek_drag_state and seek_drag_state.track_id == player.id and seek_drag_state.dragging
    local slider_val = tonumber((is_drag_active and seek_drag_state.position) or position) or 0

    local track_title = (player.title ~= nil and player.title ~= "") and player.title or "No Track Playing"
    local track_artist = (player.artist ~= nil and player.artist ~= "") and player.artist or "YouTube Music"

    -- Album Art Thumbnail
    local player_thumb
    if player.thumb_path and noctalia.fileExists(player.thumb_path) then
        player_thumb = ui.image({
            path = player.thumb_path,
            width = 170,
            height = 170,
            fit = "cover"
        })
    else
        player_thumb = ui.row({
            width = 170,
            height = 170,
            align = "center",
            justify = "center",
            fill = "surface_variant/0.25",
            borderWidth = 0
        }, {
            ui.glyph({ name = "music", size = 48, color = is_playing and "primary" or "on_surface_variant" })
        })
    end

    -- Header Cover Card
    local cover_card = ui.column({
        key = "mini-cover-card",
        align = "center",
        justify = "center",
        gap = 12,
        padding = 6,
        fill = "surface_variant/0.15",
        borderWidth = 0,
        width = "fill"
    }, {
        player_thumb,
        ui.column({ align = "center", gap = 4, width = "fill" }, {
            ui.label({
                key = "mini-title",
                text = track_title,
                fontSize = theme.fontTitle,
                fontWeight = "bold",
                maxLines = 1,
                color = "on_surface",
                width = "fill",
                textAlign = "center"
            }),
            ui.column({ key = "mini-artist-wrap", align = "center", gap = 8, width = "fill" }, {
                ui.label({
                    key = "mini-artist",
                    text = track_artist,
                    fontSize = theme.fontTitle,
                    maxLines = 1,
                    color = is_playing and "primary" or "on_surface_variant",
                    width = "fill",
                    textAlign = "center"
                }),
                ui.row({ key = "mini-title-actions", align = "center", justify = "center", gap = 4 }, {
                (function()
                    local is_liked = (state.liked_ids and player.id and state.liked_ids[player.id] == true)
                    return icon_btn("heart", function()
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
                }),
                ui.button({
                    key = "btn-expand-full",
                    glyph = "arrows-maximize",
                    variant = "ghost",
                    controlSize = "sm",
                    onClick = function()
                        noctalia.togglePanel("aabidk20/noctalia-ytmusic:panel")
                    end
                })
            })
        })
    })
    })

    -- Progress Scrub Bar
    local scrub_row = ui.column({ key = "mini-scrub-col", gap = 4, width = "fill" }, {
        ui.row({ key = "mini-scrub-labels", align = "center", justify = "space_between", width = "fill" }, {
            ui.label({ key = "mini-pos-label", text = fmt_time(slider_val), fontSize = theme.fontCaption, color = "on_surface_variant" }),
            ui.label({ key = "mini-dur-label", text = fmt_time(duration), fontSize = theme.fontCaption, color = "on_surface_variant" })
        }),
        ui.slider({
            key = "mini-seek-slider",
            min = 0,
            max = math.max(1, duration),
            step = 1,
            value = math.floor(slider_val),
            controlSize = "sm",
            onChange = function(v)
                local num = tonumber(v)
                -- Ignore programmatic onChange events
                if num and num ~= math.floor(position) then
                    seek_drag_state = { dragging = true, position = num, timestamp = os.time(), track_id = player.id }
                end
            end,
            onDragEnd = function()
                local target = (seek_drag_state and seek_drag_state.position) or position
                seek_drag_state = nil
                request("seek", { seconds = target, value = target })
            end
        })
    })

    -- Transport Controls
    local shuffle_active = (player.shuffle == true)
    local rep_mode = player.repeat_mode or "off"
    local rep_active = (rep_mode ~= "off")
    local rep_glyph = (rep_mode == "one") and "repeat-once" or "repeat"
    local rep_tooltip = (rep_mode == "one") and "Repeat Track (1)" or ((rep_mode == "all") and "Repeat Queue" or "Repeat Off")

    local is_loading = (player.status == "loading")
    local is_playing = (player.status == "playing")
    local play_glyph = is_loading and "loader" or (is_playing and "player-pause" or "player-play")

    local controls_row = ui.row({ key = "mini-controls", align = "center", justify = "center", gap = 12, width = "fill" }, {
        icon_btn("arrows-shuffle", function() request("toggle_shuffle") end, shuffle_active),
        icon_btn("player-skip-back", function() request("prev") end),
        ui.button({
            key = "mini-play-btn",
            glyph = play_glyph,
            variant = "primary",
            controlSize = "lg",
            onClick = function() request("toggle") end
        }),
        icon_btn("player-skip-forward", function() request("next") end),
        ui.button({
            key = "mini-repeat-btn",
            glyph = rep_glyph,
            variant = rep_active and "primary" or "ghost",
            controlSize = "md",
            tooltip = rep_tooltip,
            onClick = function() request("cycle_repeat") end
        })
    })

    -- Footer Links & Volume
    local footer_row = ui.row({ key = "mini-footer", align = "center", justify = "end", width = "fill", gap = 8 }, {
        ui.button({
            key = "btn-open-settings",
            glyph = "settings",
            variant = "ghost",
            controlSize = "sm",
            onClick = function()
                noctalia.openSettings("aabidk20/noctalia-ytmusic")
            end
        })
    })

    panel.render(ui.column({
        key = "mini-root",
        gap = 14,
        padding = 16,
        flexGrow = 1
    }, {
        cover_card,
        scrub_row,
        controls_row,
        ui.separator({ key = "mini-sep", color = "outline/0.3" }),
        footer_row
    }))
end

local function apply_state(s)
    if type(s) ~= "table" then return end
    if s.status ~= nil then
        state.status = s.status
    end
    if s.cookie_count ~= nil then
        state.cookie_count = s.cookie_count
    end
    if type(s.player) == "table" then
        for k, v in pairs(s.player) do state.player[k] = v end
    end
    if type(s.liked_ids) == "table" then
        state.liked_ids = s.liked_ids
    end
    render_mini()
end

function onOpen(_context)
    local curr = noctalia.state.get(STATE)
    if curr then apply_state(curr) end
end

if noctalia.state and noctalia.state.watch then
    noctalia.state.watch(STATE, apply_state)
    local curr = noctalia.state.get(STATE)
    if curr then apply_state(curr) end
end

render_mini()
