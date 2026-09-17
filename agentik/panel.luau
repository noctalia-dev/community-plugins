local home = noctalia.getenv("HOME") or ""
local cache_home = noctalia.getenv("XDG_CACHE_HOME")
if cache_home == nil or cache_home == "" then cache_home = home .. "/.cache" end
local ORB_DIR = cache_home .. "/agentik/orbs"
local FRAME_RATE = 30
local FRAME_COUNT = 60
local ORBS_READY = false
local orb_config = noctalia.state.get("agentik_orbs")
if type(orb_config) == "table" then
    ORB_DIR = tostring(orb_config.directory or ORB_DIR)
    FRAME_RATE = tonumber(orb_config.fps) or FRAME_RATE
    FRAME_COUNT = tonumber(orb_config.frame_count) or FRAME_COUNT
    ORBS_READY = orb_config.ready == true
end
local function panel_redraw_interval_ms()
    return 1000 / FRAME_RATE
end

local function orb_image(props)
    if ORBS_READY then return ui.image(props) end
    return ui.glyph({
        name = "sparkles",
        size = props.width or 20,
        color = "primary",
    })
end
local CHAT_RENDERED_EVENTS = 12
local chat_event_limit = CHAT_RENDERED_EVENTS
local sessions = noctalia.state.get("sessions") or { active = 0, sessions = {} }
local frame = 0
local panel_redraw_credit_ms = 0
local panel_stream_dirty = false
local open = false
local collapsed = {}
local render
local panel_mode = "sessions"
local attention_inbox = false
local chat_busy = false
local chat_loading = false
local expanded_chat_output = {}
local chat_messages = {}
local chat_events = {}
local chat_feed_revision = nil
local chat_error = nil
local chat_draft = ""
local chat_input_revision = 0
local chat_targets = {}
local chat_selected = false
local chat_session_id = nil
local chat_session_title = nil
local chat_session_cwd = nil
local chat_session_model = nil
local chat_session_harness = nil
local chat_new_cwd = ""
local chat_harnesses = {}
local chat_health = nil
local chat_new_harness = nil
local chat_new_model = nil
local chat_model_menu_open = false
local chat_model_input_revision = 0
local chat_model_filter = ""
local chat_target_filter = ""
local chat_bridge = noctalia.pluginDir() .. "/chat_bridge.py"
-- Bridge output is emitted only after the journal is processed; a large
-- session can take several seconds, past runAsync's 5 s default timeout.
local chat_bridge_timeout_ms = 60000
local chat_scroll_revision = 0
local chat_scroll_to_bottom_on_load = false
local chat_terminal_owns_session = false
local chat_stream_target = ""
local chat_stream_revealed = 0
local chat_stream_credit = 0
local CHAT_STREAM_CHARS_PER_SECOND = 40
local CHAT_STREAM_MAX_FRAME_MS = 50

local function chat_writable()
    return not chat_busy and not chat_terminal_owns_session
end


local function configured_bool(key, default)
    local value = noctalia.getConfig(key)
    if value == nil then return default end
    return value == true or value == "true"
end
local valid_states = {
    working = true, searching = true, solving = true, listening = true, connecting = true,
    weaving = true, composing = true, breathing = true, shaping = true, done = true,
}

local function state_of(item)
    local state = item and item.state
    return valid_states[state] and state or "working"
end

local function state_label(item)
    local state = state_of(item)
    if state == "searching" then return noctalia.tr("ui.state_searching") end
    if state == "solving" then return noctalia.tr("ui.state_solving") end
    if state == "listening" then return noctalia.tr("ui.state_listening") end
    if state == "connecting" then return noctalia.tr("ui.state_connecting") end
    if state == "weaving" then return noctalia.tr("ui.state_weaving") end
    if state == "composing" then return noctalia.tr("ui.state_composing") end
    if state == "breathing" then return noctalia.tr("ui.state_breathing") end
    if state == "shaping" then return noctalia.tr("ui.state_shaping") end
    if state == "done" then return noctalia.tr("ui.state_done") end
    return noctalia.tr("ui.state_working")
end

local function state_description(item)
    return noctalia.tr("ui.state_description", {
        harness = string.upper(tostring(item.harness or "omp")),
        state = state_label(item),
        activity = tostring(item.activity or noctalia.tr("ui.state_working")),
    })
end

local function attention_of(item)
    local attention = item and item.attention
    if attention == "blocked" or attention == "waiting" then return attention end
    return "active"
end


local function attention_label(item)
    local status = item and item.status
    if status == "failed" then return noctalia.tr("ui.status_failed") end
    if status == "cancelled" then return noctalia.tr("ui.status_cancelled") end
    if status == "completed" then return noctalia.tr("ui.status_completed") end
    if item and item.exited ~= nil then return noctalia.tr("ui.status_completed") end
    local attention = attention_of(item)
    if attention == "blocked" then return noctalia.tr("ui.attention_blocked") end
    if attention == "waiting" then return noctalia.tr("ui.attention_waiting") end
    return noctalia.tr("ui.status_running")
end

local function attention_color(item)
    local status = item and item.status
    if status == "failed" then return "error" end
    if status == "cancelled" or status == "completed" then return "secondary" end
    local attention = attention_of(item)
    if attention == "blocked" then return "error" end
    if attention == "waiting" then return "secondary" end
    return "on_surface_variant"
end

local function session_fill(item)
    local contrast = configured_bool("high_contrast", false)
    if item.exited ~= nil or item.quiet == true then
        return contrast and "surface_variant/0.30" or "surface_variant/0.12"
    end
    local attention = attention_of(item)
    if attention == "blocked" then return contrast and "error/0.24" or "error/0.10" end
    if attention == "waiting" then return contrast and "secondary/0.24" or "secondary/0.10" end
    return contrast and "surface_variant/0.36" or "surface_variant/0.18"
end

local function model_name(model)
    if model == nil or model == "" then return nil end
    local slash = string.find(model, "/", 1, true)
    if slash then
        local name = string.sub(model, slash + 1)
        if name ~= "" then return name end
    end
    return model
end

local function display_label(item)
    local choice = noctalia.getConfig("display_label")
    local fallback = item.project or "terminal"
    if choice == "agent" then
        return item.agent or fallback
    end
    if choice == "model" then
        return model_name(item.model) or fallback
    end
    return fallback
end

local function frame_index()
    if configured_bool("reduce_motion", false) then return 0 end
    return math.floor(noctalia.nowMs() * FRAME_RATE / 1000) % FRAME_COUNT
end

local function chat_stream_animating()
    if configured_bool("reduce_motion", false) then return false end
    return chat_stream_revealed < (utf8.len(chat_stream_target) or 0)
end

local function needs_panel_frame_tick()
    if configured_bool("reduce_motion", false) then return false end
    local count = #(sessions.sessions or {})
    return chat_loading
        or chat_stream_animating()
        or (panel_mode == "sessions" and count > 0)

end

local function elapsed(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    if seconds < 60 then return tostring(seconds) .. "s" end
    local minutes = math.floor(seconds / 60)
    if minutes < 60 then
        return tostring(minutes) .. "m" .. (seconds % 60 > 0 and " " .. tostring(seconds % 60) .. "s" or "")
    end
    return tostring(math.floor(minutes / 60)) .. "h" .. (minutes % 60 > 0 and " " .. tostring(minutes % 60) .. "m" or "")
end

local function copy_response(response)
    noctalia.runAsync({"wl-copy", response})
end

local function hex_encode(value)
    local encoded = {}
    for index = 1, #value do
        encoded[#encoded + 1] = string.format("%02x", string.byte(value, index))
    end
    return table.concat(encoded)
end

local function selected_harness()
    for _, harness in ipairs(chat_harnesses) do
        if harness.id == chat_new_harness then return harness end
    end
    return chat_harnesses[1]
end

local function select_option(options, index_value, text_value)
    if type(text_value) == "string" and text_value ~= "" then
        for index, option in ipairs(options) do
            if option == text_value then return index end
        end
    end
    local index = tonumber(index_value)
    if index ~= nil and options[index + 1] ~= nil then return index + 1 end
    return 1
end

local function harness_options()
    local labels = {}
    for _, harness in ipairs(chat_harnesses) do
        labels[#labels + 1] = tostring(harness.name or harness.id)
    end
    return labels
end


local function harness_index()
    for index, harness in ipairs(chat_harnesses) do
        if harness.id == chat_new_harness then return index - 1 end
    end
    return 0
end
local function model_options()
    local harness = selected_harness()
    return type(harness) == "table" and type(harness.models) == "table" and harness.models or {}
end
local function fuzzy_matches(needle, haystack)
    local query = string.lower(needle)
    if query == "" then return true end
    local value = string.lower(tostring(haystack or ""))
    local offset = 1
    for index = 1, #query do
        local found = string.find(value, string.sub(query, index, index), offset, true)
        if found == nil then return false end
        offset = found + 1
    end
    return true
end

local function model_picker()
    local options = model_options()
    local children = {
        ui.row({ gap = 2, align = "center" }, {
            ui.input({
                key = "panel-chat-model-" .. tostring(chat_new_harness) .. "-" .. tostring(chat_model_input_revision),
                width = 244,
                value = chat_new_model or "",
                placeholder = noctalia.tr("ui.chat_model_placeholder"),
                enabled = not chat_busy,
                onChange = function(value)
                    chat_new_model = tostring(value or "")
                    chat_model_filter = chat_new_model
                    chat_model_menu_open = #options > 0
                    render()
                end,
            }),
            ui.button({
                text = "⌄",
                variant = "ghost",
                controlSize = "sm",
                tooltip = noctalia.tr("ui.chat_model_suggestions"),
                enabled = not chat_busy and #options > 0,
                onClick = function()
                    chat_model_filter = ""
                    chat_model_menu_open = not chat_model_menu_open
                    render()
                end,
            }),
        }),
    }
    if chat_model_menu_open and #options > 0 then
        local choices = {}
        for _, option in ipairs(options) do
            if fuzzy_matches(chat_model_filter, option) then
                table.insert(choices, ui.button({
                    text = option,
                    variant = option == chat_new_model and "primary" or "ghost",
                    enabled = not chat_busy,
                    onClick = function()
                        chat_new_model = option
                        chat_model_filter = ""
                        chat_model_menu_open = false
                        chat_model_input_revision = chat_model_input_revision + 1
                        render()
                    end,
                }))
            end
        end
        if #choices > 0 then
            table.insert(children, ui.scroll({ width = 280, height = 144, gap = 2 }, choices))
        end
    end
    return ui.column({ gap = 2 }, children)
end

local function sync_chat_stream_animation()
    local message = chat_messages[#chat_messages]
    local target = chat_busy and type(message) == "table" and message.role == "assistant"
        and tostring(message.text or "") or ""
    if configured_bool("reduce_motion", false) then
        chat_stream_target = target
        chat_stream_revealed = utf8.len(target) or 0
        chat_stream_credit = 0
        return
    end
    if chat_stream_target ~= "" and target:sub(1, #chat_stream_target) == chat_stream_target then
        chat_stream_target = target
        return
    end
    chat_stream_target = target
    chat_stream_revealed = target == "" and 0 or 1
    chat_stream_credit = 0
end

local function animated_chat_text(message, index)
    if chat_busy and index == #chat_messages and message.role == "assistant" then
        local offset = utf8.offset(chat_stream_target, chat_stream_revealed + 1)
        return offset == nil and chat_stream_target or chat_stream_target:sub(1, offset - 1)
    end
    return message.text
end

local function advance_chat_stream_animation(delta_ms)
    if not chat_stream_animating() then return false end
    chat_stream_credit = chat_stream_credit
        + math.min(delta_ms, CHAT_STREAM_MAX_FRAME_MS) * CHAT_STREAM_CHARS_PER_SECOND / 1000
    local advance = math.floor(chat_stream_credit)
    if advance == 0 then return false end
    chat_stream_credit = chat_stream_credit - advance
    chat_stream_revealed = math.min(chat_stream_revealed + advance, utf8.len(chat_stream_target) or 0)
    return true
end

local function apply_chat_result(result)
    chat_loading = false
    local payload = noctalia.json.decode(result.stdout or "")
    chat_busy = type(payload) == "table" and payload.busy == true
    if type(payload) ~= "table" then
        chat_error = noctalia.tr("ui.chat_error")
    else
        local feed = payload.feed
        if type(feed) == "table" then
            if feed.reset == true and type(feed.events) == "table" then
                chat_events = feed.events
            elseif type(feed.events) == "table" then
                for _, event in ipairs(feed.events) do table.insert(chat_events, event) end
            end
            if type(feed.revision) == "string" then chat_feed_revision = feed.revision end
        end
        if type(payload.messages) == "table" then
            chat_messages = payload.messages
            sync_chat_stream_animation()
            if chat_scroll_to_bottom_on_load then
                chat_scroll_revision = chat_scroll_revision + 1
                chat_scroll_to_bottom_on_load = false
            end
        end
        if type(payload.targets) == "table" then chat_targets = payload.targets end
        if type(payload.harnesses) == "table" then chat_harnesses = payload.harnesses end
        if type(payload.health) == "table" then chat_health = payload.health end
        chat_selected = payload.selected == true
        chat_session_id = payload.session_id
        chat_session_title = payload.title
        chat_session_cwd = payload.cwd
        chat_session_model = payload.model
        chat_session_harness = payload.harness
        chat_terminal_owns_session = payload.active == true and payload.mode == "resume"
        if chat_new_harness == nil and type(chat_harnesses[1]) == "table" then
            chat_new_harness = chat_harnesses[1].id
        end
        local harness = selected_harness()
        if chat_new_model == nil and type(harness) == "table" then
            chat_new_model = harness.default_model
        end
        if chat_new_cwd == "" then
            if type(payload.cwd) == "string" then
                chat_new_cwd = payload.cwd
            elseif type(chat_targets[1]) == "table" and type(chat_targets[1].cwd) == "string" then
                chat_new_cwd = chat_targets[1].cwd
            end
        end
        if payload.ok == true then
            chat_error = nil
        else
            chat_error = tostring(payload.error or noctalia.tr("ui.chat_error"))
        end
    end
    panel.setNeedsFrameTick(needs_panel_frame_tick())
    if open then render() end
end

local function load_chat(scroll_to_bottom)
    if scroll_to_bottom then chat_scroll_to_bottom_on_load = true end
    if chat_busy then return end
    chat_loading = true
    chat_busy = true
    panel.setNeedsFrameTick(true)
    noctalia.runAsync(
        {"python3", chat_bridge, "load"},
        apply_chat_result,
        chat_bridge_timeout_ms
    )
end

local function submit_chat(value)
    local message = tostring(value or ""):match("^%s*(.-)%s*$")
    if not chat_writable() or message == "" then return end
    chat_busy = true
    chat_error = nil
    chat_draft = ""
    chat_events = {}
    chat_feed_revision = nil
    chat_input_revision = chat_input_revision + 1
    table.insert(chat_messages, { role = "user", text = message })
    chat_scroll_revision = chat_scroll_revision + 1
    render()
    noctalia.runAsync(
        {"python3", chat_bridge, "send", hex_encode(message)},
        apply_chat_result,
        chat_bridge_timeout_ms
    )
end
local function select_chat_session(path)
    if chat_busy or type(path) ~= "string" then return end
    chat_scroll_to_bottom_on_load = true
    chat_loading = true
    chat_busy = true
    panel.setNeedsFrameTick(true)
    render()
    noctalia.runAsync(
        {"python3", chat_bridge, "select", hex_encode(path)},
        apply_chat_result,
        chat_bridge_timeout_ms
    )
end

local function open_session_chat(session_id)
    if chat_busy or type(session_id) ~= "string" or session_id == "" then return end
    panel_mode = "chat"
    attention_inbox = false
    chat_loading = true
    panel.setNeedsFrameTick(true)
    chat_busy = true
    chat_error = nil
    chat_scroll_to_bottom_on_load = true
    noctalia.runAsync(
        {"python3", chat_bridge, "select-id", hex_encode(session_id)},
        function(result)
            apply_chat_result(result)
            if chat_selected then render() end
        end,
        chat_bridge_timeout_ms
    )
end

local function start_chat_session(cwd)
    local path = tostring(cwd or ""):match("^%s*(.-)%s*$")
    if chat_busy or path == "" or chat_new_harness == nil or chat_new_model == nil then return end
    chat_scroll_to_bottom_on_load = true
    chat_busy = true
    chat_error = nil
    chat_events = {}
    chat_feed_revision = nil
    render()
    noctalia.runAsync(
        {
            "python3",
            chat_bridge,
            "new",
            hex_encode(path),
            hex_encode(chat_new_harness),
            hex_encode(chat_new_model),
        },
        apply_chat_result,
        chat_bridge_timeout_ms
    )
end

local function reset_chat()
    if chat_busy then return end
    chat_busy = true
    chat_error = nil
    chat_draft = ""
    chat_events = {}
    chat_feed_revision = nil
    chat_input_revision = chat_input_revision + 1
    render()
    noctalia.runAsync(
        {"python3", chat_bridge, "reset"},
        apply_chat_result,
        chat_bridge_timeout_ms
    )
end

local function cancel_chat()
    if not chat_busy then return end
    noctalia.runAsync(
        {"python3", chat_bridge, "cancel"},
        apply_chat_result,
        chat_bridge_timeout_ms
    )
end

local function open_chat_terminal()
    if chat_busy then return end
    chat_busy = true
    chat_error = nil
    noctalia.runAsync(
        {"python3", chat_bridge, "open"},
        function(result)
            local payload = noctalia.json.decode(result.stdout or "")
            chat_busy = false
            if type(payload) ~= "table" then
                chat_error = noctalia.tr("ui.chat_error")
            elseif payload.ok ~= true then
                chat_error = tostring(payload.error or noctalia.tr("ui.chat_error"))
            end
            render()
        end,
        chat_bridge_timeout_ms
    )
end

local function same_chat_messages(left, right)
    if #left ~= #right then return false end
    for index, message in ipairs(left) do
        local candidate = right[index]
        if type(candidate) ~= "table"
            or message.role ~= candidate.role
            or message.text ~= candidate.text then
            return false
        end
    end
    return true
end

local function same_chat_events(left, right)
    if #left ~= #right then return false end
    for index, event in ipairs(left) do
        local candidate = right[index]
        if type(candidate) ~= "table"
            or event.sequence ~= candidate.sequence
            or event.id ~= candidate.id
            or event.kind ~= candidate.kind
            or event.text ~= candidate.text then
            return false
        end
    end
    return true
end

local function apply_chat_status(result)
    local payload = noctalia.json.decode(result.stdout or "")
    if type(payload) ~= "table" then
        chat_error = noctalia.tr("ui.chat_error")
        if open then render() end
        return
    end
    local changed = chat_busy ~= (payload.busy == true)
    chat_busy = payload.busy == true
    local feed = payload.feed
    if type(feed) == "table" then
        if feed.reset == true and type(feed.events) == "table" and not same_chat_events(chat_events, feed.events) then
            chat_events = feed.events
            changed = true
        elseif type(feed.events) == "table" and #feed.events > 0 then
            for _, event in ipairs(feed.events) do table.insert(chat_events, event) end
            changed = true
        end
        if type(feed.revision) == "string" and chat_feed_revision ~= feed.revision then
            chat_feed_revision = feed.revision
            changed = true
        end
    end
    if type(payload.messages) == "table"
        and (chat_busy or type(feed) ~= "table")
        and not same_chat_messages(chat_messages, payload.messages) then
        chat_messages = payload.messages
        sync_chat_stream_animation()
        changed = true
        if chat_scroll_to_bottom_on_load then
            chat_scroll_revision = chat_scroll_revision + 1
            chat_scroll_to_bottom_on_load = false
        end
    end
    local terminal_owns_session = payload.active == true and payload.mode == "resume"
    if chat_terminal_owns_session ~= terminal_owns_session then changed = true end
    chat_terminal_owns_session = terminal_owns_session
    local error = nil
    if payload.ok ~= true then error = tostring(payload.error or noctalia.tr("ui.chat_error")) end
    if chat_error ~= error then changed = true end
    chat_error = error
    if not changed then return end
    panel.setNeedsFrameTick(needs_panel_frame_tick())
    if open then render() end
end



local function chat_error_label()
    if chat_error == nil then return nil end
    return ui.label({
        text = noctalia.tr("ui.chat_error_detail", { error = chat_error }),
        color = "error",
        maxWidth = 360,
        maxLines = 3,
    })
end


local function target_matches(target)
    if chat_target_filter:match("%S") == nil then return true end
    return fuzzy_matches(chat_target_filter, target.title)
        or fuzzy_matches(chat_target_filter, target.project)
        or fuzzy_matches(chat_target_filter, target.cwd)
        or fuzzy_matches(chat_target_filter, target.model)
end

local function chat_picker()
    local target_rows = {}
    local shown = 0
    for index, target in ipairs(chat_targets) do
        if target_matches(target) then
            shown = shown + 1
            if shown > 12 then break end
        local available = target.resumable == true or target.forkable == true
        local status = target.resumable == true
            and noctalia.tr("ui.chat_ready")
            or (target.active == true and noctalia.tr("ui.chat_fork_active")
                or noctalia.tr("ui.chat_fork_snapshot"))
        local detail = tostring(target.project or target.cwd or "")
        if type(target.model) == "string" then detail = detail .. " · " .. model_name(target.model) end
        table.insert(target_rows, ui.column({
            key = "panel-chat-target-" .. tostring(target.id or index),
            gap = 1,
            paddingV = 2,
        }, {
            ui.button({
                text = tostring(target.title or target.id or noctalia.tr("ui.chat_session")),
                variant = "ghost",
                enabled = available and not chat_busy,
                onClick = function() select_chat_session(target.path) end,
            }),
            ui.label({
                text = detail .. " · " .. status,
                color = available and "on_surface_variant" or "secondary",
                fontSize = 11,
                maxLines = 1,
            }),
        }))
        end
    end
    if #target_rows == 0 then
        table.insert(target_rows, ui.label({
            text = noctalia.tr("ui.chat_no_sessions"),
            color = "on_surface_variant",
        }))
    end
    local children = {
        ui.label({
            text = noctalia.tr("ui.chat_picker_help"),
            color = "on_surface_variant",
            maxWidth = 360,
            maxLines = 3,
        }),
        ui.row({ gap = 6, align = "center" }, {
            ui.label({ text = noctalia.tr("ui.chat_harness"), width = 70, color = "on_surface_variant" }),
            ui.select({
                key = "panel-chat-harness",
                options = harness_options(),
                selectedIndex = harness_index(),
                width = 280,
                enabled = not chat_busy and #chat_harnesses > 0,
                onChange = function(index, text)
                    local selected = chat_harnesses[select_option(harness_options(), index, text)]
                    if type(selected) == "table" then
                        chat_new_harness = selected.id
                        chat_new_model = selected.default_model
                        chat_model_filter = ""
                        chat_model_menu_open = false
                        render()
                    end
                end,
            }),
        }),
        ui.row({ gap = 6, align = "center" }, {
            ui.label({ text = noctalia.tr("ui.chat_model"), width = 70, color = "on_surface_variant" }),
            model_picker(),
        }),
        ui.row({ gap = 6, align = "center" }, {
            ui.input({
                width = 285,
                value = chat_new_cwd,
                placeholder = noctalia.tr("ui.chat_project_placeholder"),
                enabled = not chat_busy,
                onChange = function(value)
                    chat_new_cwd = value
                    render()
                end,
                onSubmit = start_chat_session,
            }),
            ui.button({
                text = noctalia.tr("ui.chat_start"),
                variant = "primary",
                controlSize = "sm",
                enabled = not chat_busy
                    and chat_new_cwd:match("%S") ~= nil
                    and chat_new_harness ~= nil
                    and type(chat_new_model) == "string"
                    and chat_new_model:match("%S") ~= nil,
                onClick = function() start_chat_session(chat_new_cwd) end,
            }),
        }),
        ui.label({ text = noctalia.tr("ui.chat_recent"), fontWeight = "bold" }),
        ui.input({
            key = "panel-chat-target-filter",
            width = 360,
            value = chat_target_filter,
            placeholder = noctalia.tr("ui.chat_find_sessions_placeholder"),
            enabled = not chat_busy,
            onChange = function(value)
                chat_target_filter = tostring(value or "")
                render()
            end,
        }),
        ui.scroll({ flexGrow = 1, gap = 2 }, target_rows),
    }
    if type(chat_health) == "table" then
        local detail = chat_health.ready == true
            and noctalia.tr("ui.health_ready", { harnesses = table.concat(chat_health.harnesses or {}, ", ") })
            or tostring((chat_health.issues or {})[1] or noctalia.tr("ui.health_not_ready"))
        table.insert(children, 1, ui.column({
            paddingH = 8,
            paddingV = 6,
            radius = 8,
            fill = chat_health.ready == true and "primary/0.10" or "error/0.10",
        }, {
            ui.label({
                text = chat_health.ready == true and noctalia.tr("ui.health_title_ready")
                    or noctalia.tr("ui.health_title_action"),
                color = chat_health.ready == true and "primary" or "error",
                fontWeight = "bold",
            }),
            ui.label({ text = detail, color = "on_surface_variant", maxLines = 2 }),
        }))
    end
    local error_label = chat_error_label()
    if error_label ~= nil then table.insert(children, error_label) end
    if chat_busy then
        table.insert(children, ui.label({ text = noctalia.tr("ui.chat_loading"), color = "secondary" }))
    end
    return ui.column({ flexGrow = 1, gap = 6 }, children)
end

-- Lightweight markdown rendering for the discussion feed. The installed
-- runtime has no ui.markdown control, so messages are split into blocks
-- (code fences, headings, lists, paragraphs) rendered with plain labels;
-- inline emphasis markers are stripped so the text stays readable.
local function chat_inline_text(value)
    local out = tostring(value or "")
    if out:find("`", 1, true) then out = out:gsub("`([^`]*)`", "%1") end
    if out:find("*", 1, true) then
        out = out:gsub("%*%*([^*]*)%*%*", "%1")
        out = out:gsub("%*([^*]*)%*", "%1")
    end
    if out:find("~~", 1, true) then out = out:gsub("%~%~([^~]*)%~%~", "%1") end
    if out:find("[", 1, true) and out:find("](", 1, true) then
        out = out:gsub("%[([^]]*)%][(]([^)]*)[)]", "%1")
    end
    return out
end

local function append_chat_text_block(blocks, text)
    local previous = blocks[#blocks]
    if previous ~= nil and previous.kind == "text" and previous.line_count < 4 then
        previous.text = previous.text .. "\n" .. text
        previous.line_count = previous.line_count + 1
    else
        blocks[#blocks + 1] = { kind = "text", text = text, line_count = 1 }
    end
end

local function chat_message_blocks(value)
    local blocks = {}
    local lines = {}
    for line in tostring(value or ""):gmatch("[^\r\n]+") do
        lines[#lines + 1] = line
    end
    local index = 1
    while index <= #lines do
        local line = lines[index]
        if line:match("^%s*`+") then
            local code = {}
            index = index + 1
            while index <= #lines and not lines[index]:match("^%s*`+%s*$") do
                code[#code + 1] = lines[index]
                index = index + 1
            end
            index = index + 1
            blocks[#blocks + 1] = { kind = "code", lines = code }
        else
            local level, heading = line:match("^%s*(#+)%s+(.+)$")
            if level ~= nil then
                blocks[#blocks + 1] = { kind = "heading", level = #level, text = chat_inline_text(heading) }
            else
                local number, item = line:match("^%s*(%d+)[.)]%s+(.+)$")
                if number ~= nil then
                    blocks[#blocks + 1] = {
                        kind = "list", ordered = true, number = number, text = chat_inline_text(item),
                    }
                else
                    local item = line:match("^%s*[-*+]%s+(.+)$")
                    if item ~= nil then
                        blocks[#blocks + 1] = { kind = "list", text = chat_inline_text(item) }
                    elseif not line:match("^%s*$") then
                        append_chat_text_block(blocks, chat_inline_text(line))
                    end
                end
            end
            index = index + 1
        end
    end
    return blocks
end

local function chat_code_block(lines)
    local source = table.concat(lines, "\n")
    local code = {}
    for _, line in ipairs(lines) do
        table.insert(code, ui.label({
            text = line,
            maxWidth = 520,
            maxLines = 1,
            color = "on_surface_variant",
        }))
    end
    if #code == 0 then table.insert(code, ui.label({ text = "", maxWidth = 520, maxLines = 1 })) end
    return ui.column({
        gap = 3,
        paddingH = 8,
        paddingV = 6,
        radius = 8,
        fill = "surface_variant/0.35",
    }, {
        ui.row({ align = "center", gap = 6 }, {
            ui.label({ text = noctalia.tr("ui.chat_code"), color = "on_surface_variant", fontSize = 11, flexGrow = 1 }),
            ui.button({
                glyph = "copy",
                glyphSize = 13,
                variant = "ghost",
                controlSize = "sm",
                tooltip = noctalia.tr("ui.chat_copy_code"),
                onClick = function() copy_response(source) end,
            }),
        }),
        ui.column({ gap = 1 }, code),
    })
end

local function chat_body_labels(text)
    local labels = {}
    for _, block in ipairs(chat_message_blocks(text)) do
        if block.kind == "code" then
            labels[#labels + 1] = chat_code_block(block.lines)
        elseif block.kind == "heading" then
            labels[#labels + 1] = ui.label({
                text = block.text,
                maxWidth = 520,
                maxLines = 3,
                fontWeight = "bold",
                fontSize = block.level <= 2 and 14 or 13,
            })
        elseif block.kind == "list" then
            labels[#labels + 1] = ui.label({
                text = (block.ordered and (block.number .. ". ") or "• ") .. block.text,
                maxWidth = 520,
                maxLines = 6,
            })
        else
            local display, bold = block.text:match("^%*%*(.-)%*%*$")
            labels[#labels + 1] = ui.label({
                text = bold ~= nil and display or block.text,
                maxWidth = 520,
                maxLines = 12,
                fontWeight = bold ~= nil and "bold" or nil,
            })
        end
    end
    if #labels == 0 then
        labels[#labels + 1] = ui.label({ text = "", maxWidth = 520, maxLines = 12 })
    end
    return labels
end

local function monitored_chat_session()
    if type(chat_session_id) ~= "string" or chat_session_id == "" then return nil end
    local id = chat_session_harness == "hermes" and "hermes:" .. chat_session_id or chat_session_id
    for _, item in ipairs(sessions.sessions or {}) do
        if item.id == id then return item end
    end
    return nil
end

local function chat_context(item)
    local parts = {}
    if type(chat_session_harness) == "string" then table.insert(parts, chat_session_harness) end
    if type(chat_session_model) == "string" then table.insert(parts, model_name(chat_session_model)) end
    if item ~= nil and type(item.activity) == "string" and item.activity ~= "" then
        table.insert(parts, item.activity)
    end
    return table.concat(parts, " · ")
end

local function chat_message_card(message, index)
    local user = message.role == "user"
    local role = user and noctalia.tr("ui.chat_you") or noctalia.tr("ui.chat_assistant")
    return ui.column({
        key = "panel-chat-message-" .. tostring(index),
        gap = 4,
        paddingH = 10,
        paddingV = 8,
        radius = 10,
        fill = user and "primary/0.10" or "surface_variant/0.24",
    }, {
        ui.label({
            text = role,
            color = user and "primary" or "secondary",
            fontWeight = "bold",
            fontSize = 11,
        }),
        ui.column({ gap = 3 }, chat_body_labels(animated_chat_text(message, index))),
    })
end

local function chat_choice_event_card(event, index)
    local rows = {
        ui.label({
            text = noctalia.tr("ui.choice_needed"),
            color = "secondary",
            fontWeight = "bold",
            fontSize = 11,
        }),
        ui.label({ text = tostring(event.text or ""), maxWidth = 520, maxLines = 6 }),
    }
    if type(event.choices) == "table" then
        for _, choice in ipairs(event.choices) do
            if type(choice) == "table" and type(choice.value) == "string" then
                local response = choice.value
                local label = type(choice.label) == "string" and choice.label or response
                table.insert(rows, ui.row({ gap = 6, align = "center" }, {
                    ui.button({
                        text = response,
                        variant = "ghost",
                        controlSize = "sm",
                        tooltip = noctalia.tr("ui.copy_choice", { choice = label }),
                        onClick = function() copy_response(response) end,
                    }),
                    ui.label({ text = label, color = "on_surface_variant", maxWidth = 430, maxLines = 3 }),
                }))
            end
        end
    end
    return ui.column({
        key = "panel-chat-choice-" .. tostring(event.sequence or event.id or index),
        gap = 4,
        paddingH = 10,
        paddingV = 8,
        radius = 8,
        fill = "secondary/0.10",
    }, rows)
end

local function chat_event_label(kind, tool)
    if kind == "thinking" then return noctalia.tr("ui.chat_event_thinking") end
    if kind == "todo" then return noctalia.tr("ui.chat_event_todo") end
    if kind == "session_exit" then return noctalia.tr("ui.chat_event_session_exit") end
    if kind == "tool_call" then return noctalia.tr("ui.chat_event_tool_call", { tool = tool or "" }) end
    if kind == "tool_start" then return noctalia.tr("ui.chat_event_tool_start", { tool = tool or "" }) end
    if kind == "tool_output" then return noctalia.tr("ui.chat_event_tool_output", { tool = tool or "" }) end
    return noctalia.tr("ui.chat_event")
end

local function chat_event_key(event, index)
    return tostring(event.id or event.sequence or index)
end

local function chat_tool_output_card(event, index)
    local key = chat_event_key(event, index)
    local expanded = expanded_chat_output[key] == true
    local text = tostring(event.text or "")
    local _, lines = text:gsub("\n", "\n")
    return ui.column({
        key = "panel-chat-output-" .. key,
        gap = 4,
        paddingH = 10,
        paddingV = 8,
        radius = 8,
        fill = event.error == true and "error/0.10" or "surface_variant/0.35",
    }, {
        ui.row({ gap = 4, align = "center" }, {
            ui.label({
                text = chat_event_label("tool_output", event.tool),
                color = event.error == true and "error" or "secondary",
                fontWeight = "bold",
                fontSize = 11,
                flexGrow = 1,
            }),
            ui.button({
                glyph = "copy",
                glyphSize = 13,
                variant = "ghost",
                controlSize = "sm",
                tooltip = noctalia.tr("ui.chat_copy_output"),
                onClick = function() copy_response(text) end,
            }),
            ui.button({
                glyph = expanded and "chevron-up" or "chevron-down",
                glyphSize = 13,
                variant = "ghost",
                controlSize = "sm",
                tooltip = noctalia.tr(expanded and "ui.chat_collapse_output" or "ui.chat_expand_output"),
                onClick = function()
                    expanded_chat_output[key] = not expanded
                    render()
                end,
            }),
        }),
        ui.label({
            text = text,
            color = "on_surface_variant",
            maxWidth = 520,
            maxLines = expanded and math.max(4, lines + 1) or 4,
        }),
    })
end

local function chat_todo_update_card(event, index)
    local details = {}
    if type(event.completed) == "number" and type(event.total) == "number" then
        table.insert(details, ui.label({
            text = noctalia.tr("ui.todo_progress", { completed = event.completed, total = event.total }),
            color = "secondary",
            fontWeight = "bold",
        }))
    end
    if tostring(event.text or "") ~= "" then
        table.insert(details, ui.label({ text = tostring(event.text), maxWidth = 520, maxLines = 3 }))
    end
    if #details == 0 then table.insert(details, ui.label({ text = noctalia.tr("ui.done") })) end
    return ui.column({
        key = "panel-chat-todo-" .. chat_event_key(event, index),
        gap = 3,
        paddingH = 10,
        paddingV = 8,
        radius = 8,
        fill = event.complete == true and "primary/0.10" or "secondary/0.10",
    }, {
        ui.label({
            text = event.complete == true and noctalia.tr("ui.done") or noctalia.tr("ui.chat_event_todo_update"),
            color = "secondary",
            fontWeight = "bold",
            fontSize = 11,
        }),
        ui.column({ gap = 2 }, details),
    })
end

local function chat_session_exit_card(event, index)
    return ui.column({
        key = "panel-chat-exit-" .. chat_event_key(event, index),
        gap = 3,
        paddingH = 10,
        paddingV = 8,
        radius = 8,
        fill = "primary/0.10",
    }, {
        ui.label({ text = noctalia.tr("ui.done"), color = "primary", fontWeight = "bold", fontSize = 11 }),
        ui.label({ text = noctalia.tr("ui.chat_event_session_exit"), maxWidth = 520, maxLines = 2 }),
    })
end

local function chat_loading_view()
    return ui.column({
        flexGrow = 1,
        align = "center",
        justify = "center",
        gap = 12,
        padding = 24,
    }, {
        orb_image({
            path = ORB_DIR .. "/working-64-" .. tostring(frame) .. ".svg",
            width = 64,
            height = 64,
        }),
        ui.label({
            text = noctalia.tr("ui.chat_loading_conversation"),
            color = "secondary",
            fontWeight = "bold",
        }),
    })
end



local function chat_feed_event_card(event, index)
    local kind = tostring(event.kind or "event")
    local text = tostring(event.text or "")
    if kind == "user" or kind == "assistant" then
        return chat_message_card({ role = kind, text = text }, index)
    end
    if kind == "choice" then return chat_choice_event_card(event, index) end
    if kind == "tool_output" then return chat_tool_output_card(event, index) end
    if kind == "todo_update" then return chat_todo_update_card(event, index) end
    if kind == "session_exit" then return chat_session_exit_card(event, index) end
    local tool = type(event.tool) == "string" and event.tool or nil
    local label = chat_event_label(kind, tool)
    return ui.column({
        key = "panel-chat-event-" .. tostring(event.sequence or event.id or index),
        gap = 3,
        paddingH = 10,
        paddingV = 7,
        radius = 8,
        fill = kind == "tool_output" and "surface_variant/0.35" or "secondary/0.10",
    }, {
        ui.label({ text = label, color = "secondary", fontWeight = "bold", fontSize = 11 }),
        ui.label({
            text = text,
            color = kind == "thinking" and "on_surface_variant" or nil,
            maxWidth = 520,
            maxLines = 3,
        }),
    })
end

local function chat_view()
    if chat_loading then return chat_loading_view() end
    if not chat_selected then return chat_picker() end
    local transcript = {}
    if #chat_events == 0 and #chat_messages == 0 then
        table.insert(transcript, ui.label({
            text = noctalia.tr("ui.chat_empty"),
            color = "on_surface_variant",
            maxWidth = 520,
            maxLines = 3,
        }))
    elseif #chat_events > 0 then
        local first = math.max(1, #chat_events - chat_event_limit + 1)
        if first > 1 then
            table.insert(transcript, ui.button({
                text = noctalia.tr("ui.chat_show_earlier", { count = first - 1 }),
                variant = "ghost",
                onClick = function()
                    chat_event_limit = chat_event_limit + CHAT_RENDERED_EVENTS
                    render()
                end,
            }))
        end
        for index = first, #chat_events do
            table.insert(transcript, chat_feed_event_card(chat_events[index], index))
        end
    else
        for index, message in ipairs(chat_messages) do
            table.insert(transcript, chat_message_card(message, index))
        end
    end
    local item = monitored_chat_session()
    if chat_busy then
        table.insert(transcript, ui.row({
            gap = 6,
            align = "center",
            paddingH = 10,
            paddingV = 8,
            radius = 10,
            fill = "secondary/0.10",
        }, {
            orb_image({
                path = ORB_DIR .. "/" .. state_of(item) .. "-20-" .. tostring(frame) .. ".svg",
                width = 16,
                height = 16,
            }),
            ui.label({ text = noctalia.tr("ui.chat_thinking"), color = "secondary" }),
        }))
    end
    if chat_terminal_owns_session then
        table.insert(transcript, ui.label({
            text = noctalia.tr("ui.chat_terminal_active"),
            color = "secondary",
            maxWidth = 520,
        }))
    end
    local error_label = chat_error_label()
    if error_label ~= nil then table.insert(transcript, error_label) end
    local context = chat_context(item)
    local title = tostring(chat_session_title or noctalia.tr("ui.chat_session"))
    return ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, {
        ui.row({
            align = "center",
            gap = 8,
            paddingH = 10,
            paddingV = 8,
            radius = 10,
            fill = "surface_variant/0.32",
        }, {
            item ~= nil and orb_image({
                path = ORB_DIR .. "/" .. state_of(item) .. "-20-" .. tostring(frame) .. ".svg",
                width = 24,
                height = 24,
            }) or ui.glyph({ name = "message-circle", size = 20, color = "secondary" }),
            ui.column({ gap = 2, flexGrow = 1 }, {
                ui.label({ text = title, fontWeight = "bold", maxLines = 1 }),
                ui.label({ text = context, color = "on_surface_variant", fontSize = 11, maxLines = 1 }),
            }),
            item ~= nil and ui.label({ text = elapsed(item.duration), color = "on_surface_variant", fontSize = 11 })
                or ui.label({ text = "" }),
            ui.button({
                text = noctalia.tr("ui.chat_cancel"),
                variant = "ghost",
                controlSize = "sm",
                enabled = chat_busy,
                onClick = cancel_chat,
            }),
            ui.button({
                text = noctalia.tr("ui.chat_open_terminal"),
                variant = "ghost",
                controlSize = "sm",
                enabled = not chat_busy,
                onClick = open_chat_terminal,
            }),
            ui.button({
                text = noctalia.tr("ui.chat_switch"),
                variant = "ghost",
                controlSize = "sm",
                enabled = not chat_busy,
                onClick = reset_chat,
            }),
        }),
        ui.scroll({
            align = "stretch",
            flexGrow = 1,
            gap = 8,
            padding = 4,
            stickToBottom = true,
            scrollToBottomRev = chat_scroll_revision,
        }, transcript),
        ui.row({ gap = 8, align = "center" }, {
            ui.input({
                key = "panel-chat-input-" .. tostring(chat_input_revision),
                width = 500,
                value = "",
                placeholder = noctalia.tr("ui.chat_placeholder"),
                enabled = chat_writable(),
                focus = true,
                onChange = function(value)
                    chat_draft = value
                    render()
                end,
                onSubmit = submit_chat,
            }),
            ui.button({
                text = noctalia.tr("ui.chat_send"),
                variant = "primary",
                controlSize = "md",
                enabled = chat_writable() and chat_draft:match("%S") ~= nil,
                onClick = function() submit_chat(chat_draft) end,
            }),
        }),
    })
end

local function proposal_controls(item)
    if attention_of(item) == "active" or type(item.propositions) ~= "table" then
        return nil
    end
    local rows = {}
    for _, proposition in ipairs(item.propositions) do
        if type(proposition) == "table" and type(proposition.value) == "string" then
            local response = proposition.value
            local label = type(proposition.label) == "string" and proposition.label or response
            table.insert(rows, ui.row({ gap = 4, align = "center" }, {
                ui.button({
                    text = response,
                    controlSize = "sm",
                    variant = "ghost",
                    tooltip = noctalia.tr("ui.copy_choice", { choice = label }),
                    onClick = function() copy_response(response) end,
                }),
                ui.label({
                    text = label,
                    color = "on_surface_variant",
                    maxLines = 2,
                }),
            }))
        end
    end
    if #rows == 0 then return nil end
    table.insert(rows, ui.button({
        text = noctalia.tr("ui.custom_response"),
        controlSize = "sm",
        variant = "ghost",
        tooltip = noctalia.tr("ui.copy_custom_response"),
        onClick = function() copy_response("Custom: ") end,
    }))
    return ui.column({ gap = 2 }, rows)
end

local function session_row(item, show_task, show_attention)
    local details = {
        ui.label({ text = display_label(item), fontWeight = "bold", maxLines = 1 }),
    }
    if show_task and item.task and item.task ~= "" then
        table.insert(details, ui.label({
            text = tostring(item.task),
            color = "primary",
            maxLines = 1,
        }))
    end
    table.insert(details, ui.label({
        text = state_description(item),
        color = "on_surface_variant",
        maxLines = 1,
    }))
    if item.started_at ~= nil and item.last_activity_at ~= nil then
        table.insert(details, ui.label({
            text = noctalia.tr("ui.session_timeline", {
                started = elapsed(item.duration),
                activity = elapsed(item.idle),
            }),
            color = "on_surface_variant",
            fontSize = 11,
            maxLines = 1,
        }))
    end
    local controls = proposal_controls(item)
    if controls then table.insert(details, controls) end

    local status
    if item.exited ~= nil then
        status = {
            ui.label({ text = attention_label(item), color = attention_color(item) }),
            ui.label({
                text = noctalia.tr("ui.exited_ago", { time = elapsed(item.exited) }),
                color = "on_surface_variant",
            }),
        }
    elseif item.quiet == true then
        status = {
            ui.label({
                text = noctalia.tr("ui.idle", { time = elapsed(item.idle) }),
                color = "on_surface_variant",
            }),
        }
    else
        status = {
            ui.label({
                text = elapsed(item.duration),
                color = "on_surface_variant",
            }),
        }
        if show_attention then
            table.insert(status, 1, ui.label({
                text = attention_label(item),
                color = attention_color(item),
            }))
        end
    end

    local row = {
        orb_image({
            path = ORB_DIR .. "/" .. state_of(item) .. "-20-" .. tostring(frame) .. ".svg",
            width = 20,
            height = 20,
        }),
        ui.column({ gap = 2, flexGrow = 1 }, details),
        ui.column({ gap = 2 }, status),
    }
    if configured_bool("chat_enabled", true) then
        table.insert(row, ui.button({
            glyph = "message-circle",
            glyphSize = 14,
            variant = "ghost",
            enabled = not chat_busy,
            tooltip = noctalia.tr("ui.chat_open"),
            onClick = function() open_session_chat(item.id) end,
        }))
    end
    table.insert(row, ui.button({
        glyph = "folder-open",
        glyphSize = 14,
        variant = "ghost",
        enabled = item.cwd ~= nil,
        tooltip = noctalia.tr("ui.open_project"),
        onClick = function()
            if item.cwd then
                noctalia.runAsync({"xdg-open", item.cwd})
            end
        end,
    }))
    return ui.row({ gap = 10, align = "center", paddingH = 8, paddingV = 7, radius = 10, fill = session_fill(item) }, row)
end

local function group_items(items)
    local groups = {}
    local order = {}
    for _, item in ipairs(items) do
        local project = item.project or "terminal"
        local group = groups[project]
        if group == nil then
            group = { project = project, count = 0, rows = {} }
            groups[project] = group
            table.insert(order, group)
        end
        group.count = group.count + 1
        table.insert(group.rows, item)
    end
    return order
end

local function group_header(group, is_collapsed)
    return ui.row({
        gap = 6,
        align = "center",
        paddingH = 8,
        paddingV = 5,
        radius = 8,
        fill = "surface_variant/0.30",
    }, {
        ui.button({
            glyph = is_collapsed and "chevron-right" or "chevron-down",
            glyphSize = 14,
            variant = "ghost",
            tooltip = noctalia.tr(
                is_collapsed and "ui.expand_group" or "ui.collapse_group",
                { project = group.project }
            ),
            onClick = function()
                collapsed[group.project] = not is_collapsed
                render()
            end,
        }),
        ui.label({ text = group.project, fontWeight = "bold", flexGrow = 1, maxLines = 1 }),
        ui.label({ text = tostring(group.count), color = "on_surface_variant", fontSize = 12 }),
    })
end

render = function()
    local active = tonumber(sessions.active) or 0
    local body = {}
    local items = sessions.sessions or {}
    local show_task = configured_bool("show_task", true)
    local show_attention = configured_bool("show_attention", true)
    local filter_attention = configured_bool("filter_attention", false)
    local sort_mode = noctalia.getConfig("sort_mode") or "duration"
    local rows = items
    if filter_attention or attention_inbox then
        local filtered = {}
        for _, item in ipairs(items) do
            local attention = attention_of(item)
            if item.exited == nil and (attention == "blocked" or attention == "waiting") then
                table.insert(filtered, item)
            end
        end
        rows = filtered
    end
    if sort_mode == "attention" then
        local priority = { blocked = 0, waiting = 1, active = 2 }
        local function rank(item)
            if item.exited ~= nil then return 3 end
            return priority[attention_of(item)]
        end
        local decorated = {}
        for index, item in ipairs(rows) do
            table.insert(decorated, { item = item, index = index })
        end
        table.sort(decorated, function(a, b)
            local pa = rank(a.item)
            local pb = rank(b.item)
            if pa ~= pb then return pa < pb end
            return a.index < b.index
        end)
        rows = {}
        for _, entry in ipairs(decorated) do
            table.insert(rows, entry.item)
        end
    end
    if #items == 0 then
        table.insert(body, ui.label({
            text = noctalia.tr("ui.no_sessions"),
            color = "on_surface_variant",
        }))
    elseif #rows == 0 then
        table.insert(body, ui.label({
            text = noctalia.tr("ui.no_attention_sessions"),
            color = "on_surface_variant",
        }))
    else
        local groups = group_items(rows)
        for _, group in ipairs(groups) do
            local is_collapsed = collapsed[group.project] == true
            table.insert(body, group_header(group, is_collapsed))
            if not is_collapsed then
                for _, item in ipairs(group.rows) do
                    table.insert(body, session_row(item, show_task, show_attention))
                end
            end
        end
    end

    local header_icon
    if #rows == 1 then
        local header_frame = frame
        header_icon = orb_image({
            path = ORB_DIR .. "/" .. state_of(rows[1]) .. "-64-" .. tostring(header_frame) .. ".svg",
            width = 42,
            height = 42,
        })
    else
        header_icon = ui.glyph({ name = "sparkles", size = 28, color = "secondary" })
    end
    local header = {
        header_icon,
        ui.column({ gap = 2, flexGrow = 1 }, {
            ui.label({ text = "Agentik", fontSize = 16, fontWeight = "bold" }),
            ui.label({
                text = panel_mode == "chat"
                    and noctalia.tr("ui.chat_title")
                    or noctalia.trp("ui.active_agents", active),
                color = (panel_mode == "chat" or active > 0) and "primary" or "on_surface_variant",
            }),
        }),
    }
    if configured_bool("chat_enabled", true) then
        table.insert(header, ui.button({
            key = "panel-tab-sessions",
            glyph = "list",
            glyphSize = 16,
            variant = "ghost",
            tooltip = noctalia.tr("ui.sessions"),
            selected = panel_mode == "sessions",
            onClick = function()
                panel_mode = "sessions"
                panel.setNeedsFrameTick(needs_panel_frame_tick())
                render()
            end,
        }))
        table.insert(header, ui.button({
            key = "panel-tab-chat",
            glyph = "message-circle",
            glyphSize = 16,
            variant = "ghost",
            tooltip = noctalia.tr("ui.chat_open"),
            selected = panel_mode == "chat",
            onClick = function()
                if panel_mode ~= "chat" then
                    panel_mode = "chat"
                    panel.setNeedsFrameTick(needs_panel_frame_tick())
                    load_chat(true)
                end
                render()
            end,
        }))
    end
    table.insert(header, ui.button({
        key = "panel-attention-inbox",
        glyph = "alert-circle",
        glyphSize = 16,
        variant = "ghost",
        tooltip = noctalia.tr("ui.attention_inbox"),
        selected = attention_inbox,
        onClick = function()
            attention_inbox = not attention_inbox
            panel_mode = "sessions"
            panel.setNeedsFrameTick(needs_panel_frame_tick())
            render()
        end,
    }))
    table.insert(header, ui.button({
        key = "panel-settings",
        glyph = "settings",
        variant = "ghost",
        tooltip = "Agentik settings",
        onClick = "onSettingsClicked",
    }))
    table.insert(header, ui.button({ key = "panel-close", glyph = "close", onClick = "onCloseClicked" }))

    local content = panel_mode == "chat"
        and chat_view()
        or ui.scroll({ flexGrow = 1, gap = 6 }, body)
    panel.render(ui.column({
        key = "panel-root",
        flexGrow = 1,
        gap = 10,
    }, {
        ui.row({
            key = "panel-header",
            align = "center",
            gap = 8,
            paddingH = 8,
            paddingV = 6,
            radius = 12,
            fill = "surface_variant/0.30",
        }, header),
        content,
    }))
end

function update()
    if not open then return end
    if panel_mode ~= "chat" then render() end
end
function onFrameTick(delta_ms)
    if not open or (not needs_panel_frame_tick() and not panel_stream_dirty) then
        panel_redraw_credit_ms = 0
        panel_stream_dirty = false
        panel.setNeedsFrameTick(false)
        return
    end
    local elapsed_ms = math.max(0, tonumber(delta_ms) or 0)
    if panel_mode == "chat" and advance_chat_stream_animation(elapsed_ms) then
        panel_stream_dirty = true
    end
    local redraw_interval_ms = panel_redraw_interval_ms()
    if panel_stream_dirty and not chat_stream_animating() then
        panel_redraw_credit_ms = redraw_interval_ms
    end
    panel_redraw_credit_ms = panel_redraw_credit_ms + elapsed_ms
    if panel_redraw_credit_ms < redraw_interval_ms then return end
    panel_redraw_credit_ms = panel_redraw_credit_ms - redraw_interval_ms
    local next_frame = frame_index()
    local animated = panel_stream_dirty
    panel_stream_dirty = false
    if next_frame == frame and not animated then return end
    frame = next_frame
    render()
end

function onOpen(context)
    open = true
    panel_stream_dirty = false
    panel_redraw_credit_ms = 0
    frame = frame_index()
    if context == "chat" then panel_mode = "chat" end
    panel.setNeedsFrameTick(needs_panel_frame_tick())
    panel.setWantsSecondTicks(true)
    if panel_mode == "chat" then load_chat(true) end
    render()
end


function onClose()
    panel_redraw_credit_ms = 0
    open = false
    panel.setWantsSecondTicks(false)
    panel.setNeedsFrameTick(false)
    panel_stream_dirty = false
end

function onCloseClicked()
    panel.close()
end

function onSettingsClicked()
    noctalia.openSettings()
end

noctalia.state.watch("sessions", function(value)
    sessions = value or { active = 0, sessions = {} }
    if open then
        frame = frame_index()
        panel.setNeedsFrameTick(needs_panel_frame_tick())
        if panel_mode ~= "chat" then render() end
    end
end)


noctalia.state.watch("agentik_orbs", function(value)
    if type(value) ~= "table" then return end
    local fps = tonumber(value.fps)
    local frame_count = tonumber(value.frame_count)
    if value.ready ~= true
        or type(value.directory) ~= "string"
        or (fps ~= 30 and fps ~= 60)
        or frame_count ~= fps * 2
    then
        return
    end
    ORB_DIR = value.directory
    FRAME_RATE = fps
    FRAME_COUNT = frame_count
    ORBS_READY = true
    frame = frame_index()
    if open then render() end
end)
noctalia.state.watch("agentik_chat_status", function(result)
    if type(result) == "table" then apply_chat_status(result) end
end)
