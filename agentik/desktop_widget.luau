-- Desktop widget: live OMP monitoring with an optional full-session client.
-- Monitoring reads the shared collector state; session chat runs through the
-- same local bridge as the main Agentik panel.
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
local chat_open = false
local chat_busy = false
local expanded_chat_output = {}
local chat_messages = {}
local chat_events = {}
local chat_feed_revision = nil
local chat_error = nil
local chat_draft = ""
local chat_input_revision = 0
local chat_targets = {}
local chat_selected = false
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
local chat_bridge_timeout_ms = 60000
local chat_bridge = noctalia.pluginDir() .. "/chat_bridge.py"
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

-- Bridge output is emitted only after the journal is processed; a large
-- session can take several seconds, past runAsync's 5 s default timeout.

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


local function elapsed(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    if seconds < 60 then return tostring(seconds) .. "s" end
    local minutes = math.floor(seconds / 60)
    if minutes < 60 then
        return tostring(minutes) .. "m" .. (seconds % 60 > 0 and " " .. tostring(seconds % 60) .. "s" or "")
    end
    return tostring(math.floor(minutes / 60)) .. "h" .. (minutes % 60 > 0 and " " .. tostring(minutes % 60) .. "m" or "")
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
    if item.quiet == true then return noctalia.tr("ui.idle", { time = elapsed(item.idle) }) end
    local attention = attention_of(item)
    if attention == "blocked" then return noctalia.tr("ui.attention_blocked") end
    if attention == "waiting" then return noctalia.tr("ui.attention_waiting") end
    return noctalia.tr("ui.status_running")
end

local function attention_color(item)
    local status = item and item.status
    if status == "failed" then return "error" end
    if status == "cancelled" or status == "completed" then return "secondary" end
    if item.quiet == true then return "on_surface_variant" end
    local attention = attention_of(item)
    if attention == "blocked" then return "error" end
    if attention == "waiting" then return "secondary" end
    return configured_bool("high_contrast", false) and "on_surface" or "on_surface_variant"
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

local function needs_orb_animation()
    if configured_bool("reduce_motion", false) then return false end
    return chat_stream_animating() or #(sessions.sessions or {}) > 0
end
local function copy_response(response)
    noctalia.runAsync({"wl-copy", response})
end

local function proposal_actions(item)
    if attention_of(item) == "active" or type(item.propositions) ~= "table" then
        return nil
    end
    local buttons = {}
    for index, proposition in ipairs(item.propositions) do
        if type(proposition) == "table" and type(proposition.value) == "string" then
            local response = proposition.value
            local label = type(proposition.label) == "string" and proposition.label or response
            table.insert(buttons, ui.button({
                text = response,
                controlSize = "sm",
                variant = "ghost",
                tooltip = noctalia.tr("ui.copy_choice", { choice = label }),
                onClick = function() copy_response(response) end,
            }))
        end
    end
    if #buttons == 0 then return nil end
    table.insert(buttons, ui.button({
        text = noctalia.tr("ui.custom_response"),
        controlSize = "sm",
        variant = "ghost",
        tooltip = noctalia.tr("ui.copy_custom_response"),
        onClick = function() copy_response("Custom: ") end,
    }))
    return ui.row({ gap = 2 }, buttons)
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
                key = "desktop-chat-model-" .. tostring(chat_new_harness) .. "-" .. tostring(chat_model_input_revision),
                width = 304,
                value = chat_new_model or "",
                placeholder = noctalia.tr("ui.chat_model_placeholder"),
                enabled = not chat_busy,
                onChange = function(value)
                    chat_new_model = tostring(value or "")
                    chat_model_filter = chat_new_model
                    chat_model_menu_open = #options > 0
                    update()
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
                    update()
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
                        update()
                    end,
                }))
            end
        end
        if #choices > 0 then
            table.insert(children, ui.scroll({ width = 340, height = 144, gap = 2 }, choices))
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
    local payload = noctalia.json.decode(result.stdout or "")
    chat_busy = type(payload) == "table" and payload.busy == true
    if type(payload) ~= "table" then
        chat_error = noctalia.tr("ui.chat_error")
        update()
        return
    end
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
    desktopWidget.setNeedsFrameTick(needs_orb_animation())
    update()
end

local function load_chat()
    if chat_busy then return end
    chat_scroll_to_bottom_on_load = true
    chat_busy = true
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
    update()
    noctalia.runAsync(
        {"python3", chat_bridge, "send", hex_encode(message)},
        apply_chat_result,
        chat_bridge_timeout_ms
    )
end
local function select_chat_session(path)
    if chat_busy or type(path) ~= "string" then return end
    chat_scroll_to_bottom_on_load = true
    chat_busy = true
    chat_error = nil
    update()
    noctalia.runAsync(
        {"python3", chat_bridge, "select", hex_encode(path)},
        apply_chat_result,
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
    update()
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
    update()
    noctalia.runAsync(
        {"python3", chat_bridge, "reset"},
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
            update()
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
        update()
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
    if changed then update() end
end


local function chat_error_label()
    if chat_error == nil then return nil end
    return ui.label({
        text = noctalia.tr("ui.chat_error_detail", { error = chat_error }),
        color = "error",
        maxWidth = 400,
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
            key = "desktop-chat-target-" .. tostring(target.id or index),
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
            maxWidth = 400,
            maxLines = 3,
        }),
        ui.row({ gap = 6, align = "center" }, {
            ui.label({ text = noctalia.tr("ui.chat_harness"), width = 80, color = "on_surface_variant" }),
            ui.select({
                key = "desktop-chat-harness",
                options = harness_options(),
                selectedIndex = harness_index(),
                width = 340,
                enabled = not chat_busy and #chat_harnesses > 0,
                onChange = function(index, text)
                    local selected = chat_harnesses[select_option(harness_options(), index, text)]
                    if type(selected) == "table" then
                        chat_new_harness = selected.id
                        chat_new_model = selected.default_model
                        chat_model_filter = ""
                        chat_model_menu_open = false
                        update()
                    end
                end,
            }),
        }),
        ui.row({ gap = 6, align = "center" }, {
            ui.label({ text = noctalia.tr("ui.chat_model"), width = 80, color = "on_surface_variant" }),
            model_picker(),
        }),
        ui.row({ gap = 6, align = "center" }, {
            ui.input({
                width = 345,
                value = chat_new_cwd,
                placeholder = noctalia.tr("ui.chat_project_placeholder"),
                enabled = not chat_busy,
                onChange = function(value)
                    chat_new_cwd = value
                    update()
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
            key = "desktop-chat-target-filter",
            width = 420,
            value = chat_target_filter,
            placeholder = noctalia.tr("ui.chat_find_sessions_placeholder"),
            enabled = not chat_busy,
            onChange = function(value)
                chat_target_filter = tostring(value or "")
                update()
            end,
        }),
        ui.scroll({ width = 420, height = 360, gap = 2 }, target_rows),
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
    return ui.column({ key = "chat-picker", gap = 6, paddingV = 4 }, children)
end

-- Lightweight markdown rendering for the discussion feed. The installed
-- runtime has no ui.markdown control, so messages are split into blocks
-- (code fences, headings, lists, paragraphs) rendered with plain labels;
-- inline emphasis markers are stripped so the text stays readable.
local function chat_inline_text(value)
    local out = tostring(value or "")
    out = out:gsub("`([^`]*)`", "%1")
    out = out:gsub("%*%*([^*]*)%*%*", "%1")
    out = out:gsub("%*([^*]*)%*", "%1")
    out = out:gsub("%~%~([^~]*)%~%~", "%1")
    out = out:gsub("%[([^]]*)%][(]([^)]*)[)]", "%1")
    return out
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
        if line:match("^%s*`+%s*$") then
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
                        blocks[#blocks + 1] = { kind = "text", text = chat_inline_text(line) }
                    end
                end
            end
            index = index + 1
        end
    end
    return blocks
end

local function chat_body_labels(text)
    local labels = {}
    for _, block in ipairs(chat_message_blocks(text)) do
        if block.kind == "code" then
            for _, code_line in ipairs(block.lines) do
                labels[#labels + 1] = ui.label({
                    text = code_line,
                    maxWidth = 400,
                    maxLines = 6,
                    color = "on_surface_variant",
                })
            end
        elseif block.kind == "heading" then
            labels[#labels + 1] = ui.label({
                text = block.text,
                maxWidth = 400,
                maxLines = 3,
                fontWeight = "bold",
                fontSize = block.level <= 2 and 13 or 12,
            })
        elseif block.kind == "list" then
            labels[#labels + 1] = ui.label({
                text = (block.ordered and (block.number .. ". ") or "• ") .. block.text,
                maxWidth = 400,
                maxLines = 6,
            })
        else
            local display, bold = block.text:match("^%*%*(.-)%*%*$")
            labels[#labels + 1] = ui.label({
                text = bold ~= nil and display or block.text,
                maxWidth = 400,
                maxLines = 12,
                fontWeight = bold ~= nil and "bold" or nil,
            })
        end
    end
    if #labels == 0 then
        labels[#labels + 1] = ui.label({ text = "", maxWidth = 400, maxLines = 12 })
    end
    return labels
end

local function chat_choice_event(event, index)
    local rows = {
        ui.label({ text = noctalia.tr("ui.choice_needed"), color = "secondary", fontWeight = "bold" }),
        ui.label({ text = tostring(event.text or ""), maxWidth = 400, maxLines = 6 }),
    }
    if type(event.choices) == "table" then
        for _, choice in ipairs(event.choices) do
            if type(choice) == "table" and type(choice.value) == "string" then
                local response = choice.value
                local label = type(choice.label) == "string" and choice.label or response
                table.insert(rows, ui.row({ gap = 4, align = "center" }, {
                    ui.button({
                        text = response,
                        variant = "ghost",
                        controlSize = "sm",
                        tooltip = noctalia.tr("ui.copy_choice", { choice = label }),
                        onClick = function() copy_response(response) end,
                    }),
                    ui.label({ text = label, color = "on_surface_variant", maxWidth = 320, maxLines = 3 }),
                }))
            end
        end
    end
    return ui.column({
        key = "chat-choice-" .. tostring(event.sequence or event.id or index),
        gap = 3,
        paddingV = 3,
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

local function chat_tool_output_event(event, index)
    local key = chat_event_key(event, index)
    local expanded = expanded_chat_output[key] == true
    local text = tostring(event.text or "")
    local _, lines = text:gsub("\n", "\n")
    return ui.column({
        key = "chat-output-" .. key,
        gap = 3,
        paddingV = 3,
    }, {
        ui.row({ gap = 3, align = "center" }, {
            ui.label({
                text = chat_event_label("tool_output", event.tool),
                color = event.error == true and "error" or "secondary",
                fontWeight = "bold",
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
                    update()
                end,
            }),
        }),
        ui.label({
            text = text,
            color = "on_surface_variant",
            maxWidth = 400,
            maxLines = expanded and math.max(4, lines + 1) or 4,
        }),
    })
end

local function chat_todo_update_event(event, index)
    local rows = {
        ui.label({
            text = event.complete == true and noctalia.tr("ui.done") or noctalia.tr("ui.chat_event_todo_update"),
            color = "secondary",
            fontWeight = "bold",
        }),
    }
    if type(event.completed) == "number" and type(event.total) == "number" then
        table.insert(rows, ui.label({
            text = noctalia.tr("ui.todo_progress", { completed = event.completed, total = event.total }),
            color = "on_surface_variant",
        }))
    end
    if tostring(event.text or "") ~= "" then
        table.insert(rows, ui.label({ text = tostring(event.text), maxWidth = 400, maxLines = 3 }))
    end
    return ui.column({
        key = "chat-todo-" .. chat_event_key(event, index),
        gap = 2,
        paddingV = 3,
    }, rows)
end


local function chat_session_exit_event(event, index)
    return ui.column({
        key = "chat-exit-" .. chat_event_key(event, index),
        gap = 2,
        paddingV = 3,
    }, {
        ui.label({ text = noctalia.tr("ui.done"), color = "primary", fontWeight = "bold" }),
        ui.label({ text = noctalia.tr("ui.chat_event_session_exit"), maxWidth = 400, maxLines = 2 }),
    })
end


local function chat_feed_event(event, index)
    local kind = tostring(event.kind or "event")
    local text = tostring(event.text or "")
    if kind == "choice" then return chat_choice_event(event, index) end
    if kind == "tool_output" then return chat_tool_output_event(event, index) end
    if kind == "todo_update" then return chat_todo_update_event(event, index) end
    if kind == "session_exit" then return chat_session_exit_event(event, index) end
    local tool = type(event.tool) == "string" and event.tool or nil
    local title
    if kind == "user" then
        title = noctalia.tr("ui.chat_you")
    elseif kind == "assistant" then
        title = noctalia.tr("ui.chat_assistant")
    else
        title = chat_event_label(kind, tool)
    end
    return ui.column({
        key = "chat-event-" .. tostring(event.sequence or event.id or index),
        gap = 2,
        paddingV = 3,
    }, {
        ui.label({
            text = title,
            color = kind == "user" and "primary" or "secondary",
            fontWeight = "bold",
        }),
        ui.label({
            text = text,
            color = kind == "thinking" and "on_surface_variant" or nil,
            maxWidth = 400,
            maxLines = 3,
        }),
    })
end

local function chat_view()
    if not chat_selected then return chat_picker() end
    local transcript = {}
    if #chat_events == 0 and #chat_messages == 0 then
        table.insert(transcript, ui.label({
            text = noctalia.tr("ui.chat_empty"),
            color = "on_surface_variant",
            maxWidth = 400,
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
                    update()
                end,
            }))
        end
        for index = first, #chat_events do
            table.insert(transcript, chat_feed_event(chat_events[index], index))
        end
    else
        for index, message in ipairs(chat_messages) do
            local role = message.role == "user" and noctalia.tr("ui.chat_you") or noctalia.tr("ui.chat_assistant")
            table.insert(transcript, ui.column({
                key = "chat-message-" .. tostring(index),
                gap = 2,
                paddingV = 3,
            }, {
                ui.label({
                    text = role,
                    color = message.role == "user" and "primary" or "secondary",
                    fontWeight = "bold",
                }),
                ui.column({ gap = 1 }, chat_body_labels(animated_chat_text(message, index))),
            }))
        end
    end
    if chat_busy then
        table.insert(transcript, ui.label({
            text = noctalia.tr("ui.chat_thinking"),
            color = "secondary",
        }))
    end
    if chat_terminal_owns_session then
        table.insert(transcript, ui.label({
            text = noctalia.tr("ui.chat_terminal_active"),
            color = "secondary",
            maxWidth = 400,
            maxLines = 2,
        }))
    end
    local error_label = chat_error_label()
    if error_label ~= nil then table.insert(transcript, error_label) end
    local detail = tostring(chat_session_cwd or "")
    if type(chat_session_model) == "string" then
        detail = detail .. " · " .. model_name(chat_session_model)
    end
    if type(chat_session_harness) == "string" then
        detail = chat_session_harness .. " · " .. detail
    end
    return ui.column({ key = "chat", gap = 6, paddingV = 4 }, {
        ui.row({ gap = 6, align = "center" }, {
            ui.column({ gap = 1, flexGrow = 1 }, {
                ui.label({
                    text = tostring(chat_session_title or noctalia.tr("ui.chat_session")),
                    fontWeight = "bold",
                    maxLines = 1,
                }),
                ui.label({ text = detail, color = "on_surface_variant", fontSize = 11, maxLines = 1 }),
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
            width = 420,
            height = 220,
            padding = 4,
            stickToBottom = true,
            scrollToBottomRev = chat_scroll_revision,
        }, transcript),
        ui.row({ gap = 6, align = "center" }, {
            ui.input({
                key = "chat-input-" .. tostring(chat_input_revision),
                width = 340,
                value = "",
                placeholder = noctalia.tr("ui.chat_placeholder"),
                enabled = chat_writable(),
                focus = true,
                onChange = function(value)
                    chat_draft = value
                    update()
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


local function session_row(item, show_task)
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
    local orb_frame = frame
    local row = {
        orb_image({
            path = ORB_DIR .. "/" .. state_of(item) .. "-20-" .. tostring(orb_frame) .. ".svg",
            width = 20,
            height = 20,
        }),
        ui.column({ gap = 2, flexGrow = 1 }, details),
        ui.label({
            text = attention_label(item),
            color = attention_color(item),
        }),
    }
    local actions = proposal_actions(item)
    if actions then table.insert(row, actions) end
    return ui.row({ gap = 8, align = "center", paddingV = 2 }, row)
end

local function render()
    local active = tonumber(sessions.active) or 0
    local show_task = configured_bool("show_task", true)
    local children = {}
    local items = sessions.sessions or {}
    local header_icon
    if #items > 0 then
        local header_frame = frame
        header_icon = orb_image({
            path = ORB_DIR .. "/" .. state_of(items[1]) .. "-20-" .. tostring(header_frame) .. ".svg",
            width = 20,
            height = 20,
        })
    else
        header_icon = ui.glyph({ name = "sparkles", size = 18, color = "secondary" })
    end
    local header = {
        header_icon,
        ui.label({
            text = noctalia.trp("ui.active_agents", active),
            fontWeight = "bold",
            flexGrow = 1,
            maxLines = 1,
        }),
    }
    if configured_bool("chat_enabled", true) then
        table.insert(header, ui.button({
            text = chat_open and noctalia.tr("ui.chat_close") or noctalia.tr("ui.chat_open"),
            variant = chat_open and "secondary" or "ghost",
            controlSize = "sm",
            onClick = function()
                chat_open = not chat_open
                if chat_open then load_chat() end
                update()
            end,
        }))
    end
    table.insert(children, ui.row({ gap = 8, align = "center", paddingV = 4 }, header))
    if #items == 0 then
        table.insert(children, ui.label({
            text = noctalia.tr("ui.no_sessions"),
            color = "on_surface_variant",
        }))
    else
        for i = 1, #items do
            table.insert(children, session_row(items[i], show_task))
        end
    end
    if chat_open and configured_bool("chat_enabled", true) then
        table.insert(children, chat_view())
    end
    desktopWidget.render(ui.column({ gap = 2, padding = 6 }, children))
end
function update()
    local active = tonumber(sessions.active) or 0
    noctalia.setUpdateInterval((chat_busy or (chat_open and chat_selected) or active > 0) and 1000 or 5000)
    desktopWidget.setNeedsFrameTick(needs_orb_animation())
    render()
end


function onFrameTick(delta_ms)
    if not needs_orb_animation() then
        desktopWidget.setNeedsFrameTick(false)
        return
    end
    local next_frame = frame_index()
    local animated = chat_open and advance_chat_stream_animation(delta_ms)
    if next_frame == frame and not animated then return end
    frame = next_frame
    render()
end

noctalia.state.watch("sessions", function(value)
    sessions = value or { active = 0, sessions = {} }
    local active = tonumber(sessions.active) or 0
    noctalia.setUpdateInterval((chat_busy or active > 0) and 1000 or 5000)
    desktopWidget.setNeedsFrameTick(needs_orb_animation())
    if needs_orb_animation() then frame = frame_index() end
    render()
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
    desktopWidget.setNeedsFrameTick(needs_orb_animation())
    render()
end)

noctalia.state.watch("agentik_chat_status", function(result)
    if type(result) == "table" then apply_chat_status(result) end
end)

if needs_orb_animation() then frame = frame_index() end
desktopWidget.setNeedsFrameTick(needs_orb_animation())
render()
