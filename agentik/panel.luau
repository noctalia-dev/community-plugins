local Orb = require("./orb.luau")
local FRAME_RATE = 60
local function panel_redraw_interval_ms()
    return 1000 / FRAME_RATE
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
local attention_target = nil
local pinned_session = noctalia.state.get("agentik.pinned_session")
local monitor_health = noctalia.state.get("agentik.monitor_health") or { status = "pending" }
local surface_transition_started = nil
local SURFACE_TRANSITION_MS = 200
local transcript_return_mode = "sessions"
local transcript_return_attention = false
local transcript_item = nil
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
local quota_usage = { reports = {} }
local quota_loading = false
local quota_return_mode = "sessions"
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
local chat_read_only_view = false
local chat_session_accent = nil
local chat_stream_target = ""
local chat_stream_revealed = 0
local chat_stream_credit = 0
local CHAT_STREAM_CHARS_PER_SECOND = 40
local CHAT_STREAM_MAX_FRAME_MS = 50
local chat_attachments = {}
local attachment_busy = false
local chat_capabilities = {}
local capabilities_negotiated = false
local pending_requests = {}
local request_history = {}
local request_states = {}
local activity_session_id = nil
local activity_events = {}
local activity_expanded = {}
local activity_loading = false
local activity_error = nil
local activity_last_poll = -3000
local focus_busy = {}
local focus_error = nil



local function configured_bool(key, default)
    local value = noctalia.getConfig(key)
    if value == nil then return default end
    return value == true or value == "true"
end

local function chat_writable()
    return configured_bool("chat_enabled", true)
        and chat_selected and not attachment_busy
        and not chat_busy and not chat_terminal_owns_session and not chat_read_only_view
end

local function surface_transition_progress()
    if surface_transition_started == nil then return 1 end
    if configured_bool("reduce_motion", false) then
        surface_transition_started = nil
        return 1
    end
    local progress = math.min(1, math.max(0, (noctalia.nowMs() - surface_transition_started) / SURFACE_TRANSITION_MS))
    if progress == 1 then surface_transition_started = nil end
    return progress
end

local function set_panel_mode(mode)
    if panel_mode == mode then return end
    local previous = panel_mode
    panel_mode = mode
    if (previous == "chat" or mode == "chat") and not configured_bool("reduce_motion", false) then
        surface_transition_started = noctalia.nowMs()
    else
        surface_transition_started = nil
    end
end

local function pin_button(item)
    if item == nil or item.exited ~= nil or type(item.id) ~= "string" then return nil end
    local selected = pinned_session == item.id
    return ui.button({
        key = "panel-pin-" .. item.id,
        glyph = "pin",
        glyphSize = 14,
        variant = "ghost",
        controlSize = "sm",
        selected = selected,
        tooltip = noctalia.tr(selected and "ui.unpin_session" or "ui.pin_session"),
        onClick = function()
            if pinned_session == item.id then
                noctalia.state.set("agentik.pinned_session", nil)
            else
                noctalia.state.set("agentik.pinned_session", item.id)
            end
        end,
    })
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
    local contrast = configured_bool("high_contrast", false) or configured_bool("presentation_mode", false)
    if item.exited ~= nil or item.quiet == true then
        return contrast and "surface_variant/0.30" or "surface_variant/0.12"
    end
    local attention = attention_of(item)
    if attention == "blocked" then return contrast and "error/0.24" or "error/0.10" end
    if attention == "waiting" then return contrast and "secondary/0.24" or "secondary/0.10" end
    return contrast and "surface_variant/0.36" or "surface_variant/0.18"
end

local function identity_marker(item)
    return ui.glyph({ name = "circle", size = 10, color = item and item.accent or "primary" })
end

local function label_lines()
    return configured_bool("presentation_mode", false) and 3 or 1
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
    return math.floor(noctalia.nowMs() * FRAME_RATE / 1000)
end

local function animation_time()
    if configured_bool("reduce_motion", false) then return 0 end
    return noctalia.nowMs() / 1000 * (configured_bool("presentation_mode", false) and 0.5 or 1)
end

local function chat_stream_animating()
    if configured_bool("reduce_motion", false) then return false end
    return chat_stream_revealed < (utf8.len(chat_stream_target) or 0)
end

local function monitored_chat_session()
    if type(chat_session_id) ~= "string" or chat_session_id == "" then return nil end
    local id = chat_session_harness == "hermes" and "hermes:" .. chat_session_id or chat_session_id
    for _, item in ipairs(sessions.sessions or {}) do
        if item.id == id then return item end
    end
    return nil
end

local function needs_panel_frame_tick()
    if not open or configured_bool("reduce_motion", false) then return false end
    local count = #(sessions.sessions or {})
    return surface_transition_started ~= nil
        or count == 1
        or (panel_mode == "chat" and (chat_loading or chat_stream_animating()
            or chat_selected))
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

local function monitoring_status()
    if monitor_health.status == "error" then return "error" end
    local success = tonumber(monitor_health.last_success_ms)
    if success == nil then return "pending" end
    if noctalia.nowMs() - success > (tonumber(monitor_health.stale_after_ms) or 15000) then return "stale" end
    return "ok"
end

local function monitoring_banner()
    local status = monitoring_status()
    if status == "ok" then return nil end
    local details = { ui.label({
        text = noctalia.tr("ui.monitor_" .. status),
        fontWeight = "bold", color = status == "error" and "error" or "secondary", maxLines = 2,
    }) }
    if tonumber(monitor_health.last_success_ms) ~= nil then
        table.insert(details, ui.label({
            text = noctalia.tr("ui.monitor_last_success", {
                time = elapsed((noctalia.nowMs() - monitor_health.last_success_ms) / 1000),
            }),
            color = "on_surface_variant", fontSize = 11, maxLines = 1,
        }))
    end
    if status == "error" and type(monitor_health.error) == "string" then
        table.insert(details, ui.label({
            text = monitor_health.error:sub(1, 240),
            color = "on_surface_variant", fontSize = 11, maxLines = 2,
        }))
    end
    return ui.column({ key = "panel-monitor-health", gap = 3, paddingH = 10, paddingV = 6,
        radius = 10, fill = status == "error" and "error/0.10" or "secondary/0.10" }, details)
end

local function resolved_attention_target()
    if attention_target == nil then return nil end
    for _, item in ipairs(sessions.sessions or {}) do
        if item.id == attention_target and item.exited == nil and attention_of(item) ~= "active" then return item end
    end
    attention_target = nil
    return nil
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

local function request_key(request)
    return noctalia.json.encode({ request.run_id, request.request_id })
end

local function sync_requests(payload)
    local changed = false
    if type(payload.capabilities) == "table" then
        changed = noctalia.json.encode(chat_capabilities) ~= noctalia.json.encode(payload.capabilities)
        chat_capabilities = payload.capabilities
    end
    if type(payload.capabilities_negotiated) == "boolean" then
        changed = changed or capabilities_negotiated ~= payload.capabilities_negotiated
        capabilities_negotiated = payload.capabilities_negotiated
    end
    if type(payload.request_history) == "table" then
        changed = changed or noctalia.json.encode(request_history) ~= noctalia.json.encode(payload.request_history)
        request_history = payload.request_history
    end
    if type(payload.pending_requests) ~= "table" then return changed end
    changed = changed or noctalia.json.encode(pending_requests) ~= noctalia.json.encode(payload.pending_requests)
    pending_requests = payload.pending_requests
    local active = {}
    for _, request in ipairs(pending_requests) do
        local key = request_key(request)
        active[key] = true
        if request.submitted == true then
            local state = request_states[key] or { values = {} }
            state.submitting = true
            state.queued = true
            request_states[key] = state
        end
    end
    for key in pairs(request_states) do
        if not active[key] then request_states[key] = nil end
    end
    return changed
end

local function focus_button(item)
    if item == nil or item.exited ~= nil or type(item.id) ~= "string" then return nil end
    return ui.button({
        key = "panel-focus-" .. item.id, glyph = "terminal", glyphSize = 14,
        variant = "ghost", controlSize = "sm", enabled = focus_busy[item.id] ~= true,
        tooltip = noctalia.tr("ui.focus_session"),
        onClick = function()
            if focus_busy[item.id] then return end
            focus_busy[item.id] = true
            focus_error = nil
            render()
            noctalia.runAsync({"python3", chat_bridge, "focus-session", hex_encode(item.id)}, function(result)
                focus_busy[item.id] = nil
                local payload = noctalia.json.decode(result.stdout or "")
                if type(payload) ~= "table" or payload.ok ~= true then
                    focus_error = type(payload) == "table" and tostring(payload.error or noctalia.tr("ui.chat_error"))
                        or noctalia.tr("ui.chat_error")
                end
                if open then render() end
            end, chat_bridge_timeout_ms)
        end,
    })
end

local function poll_activity(force)
    if not open or panel_mode ~= "activity" or activity_loading or activity_session_id == nil then return end
    if not force and noctalia.nowMs() - activity_last_poll < 3000 then return end
    local selected = activity_session_id
    activity_loading = true
    activity_last_poll = noctalia.nowMs()
    noctalia.runAsync({"python3", chat_bridge, "activity", hex_encode(selected)}, function(result)
        activity_loading = false
        if activity_session_id ~= selected then
            poll_activity(true)
            return
        end
        local payload = noctalia.json.decode(result.stdout or "")
        if type(payload) == "table" and payload.ok == true and payload.session_id == selected then
            activity_events = type(payload.events) == "table" and payload.events or {}
            activity_error = nil
        else
            activity_error = type(payload) == "table" and tostring(payload.error or noctalia.tr("ui.chat_error"))
                or noctalia.tr("ui.chat_error")
        end
        if open then render() end
    end, chat_bridge_timeout_ms)
end

local function open_activity(item)
    set_panel_mode("activity")
    if item ~= nil and activity_session_id ~= item.id then
        activity_session_id = item.id
        activity_events = {}
        activity_expanded = {}
        activity_error = nil
    end
    poll_activity(true)
    render()
end

local function activity_view()
    local rows = {}
    local choices, items, selected_index = {}, {}, 0
    for _, collection in ipairs({ sessions.sessions or {}, sessions.recent_outcomes or {} }) do
        for _, item in ipairs(collection) do
            choices[#choices + 1] = display_label(item) .. " · " .. tostring(item.id)
            items[#items + 1] = item
            if item.id == activity_session_id then selected_index = #items - 1 end
        end
    end
    if activity_session_id == nil and items[1] ~= nil then
        activity_session_id = items[1].id
        poll_activity(true)
    end
    local item = items[selected_index + 1]
    if item ~= nil and item.id ~= activity_session_id then item = nil end
    table.insert(rows, ui.row({ gap = 6, align = "center" }, {
        ui.select({
            key = "panel-activity-session", width = 320, options = choices,
            selectedIndex = selected_index, enabled = #items > 0,
            onChange = function(index, text)
                local choice = items[select_option(choices, index, text)]
                if choice ~= nil then open_activity(choice) end
            end,
        }),
        focus_button(item) or ui.label({ text = "" }),
    }))
    if activity_error ~= nil then
        table.insert(rows, ui.label({ text = activity_error, color = "error", maxLines = 3 }))
    end
    if #activity_events == 0 then
        table.insert(rows, ui.label({
            text = noctalia.tr(activity_loading and "ui.chat_loading" or "ui.activity_empty"),
            color = "on_surface_variant", maxLines = 2,
        }))
    end
    for index, event in ipairs(activity_events) do
        local key = tostring(activity_session_id) .. ":" .. tostring(event.id or index)
        local expanded = activity_expanded[key] == true
        local detail = tostring(event.detail or event.text or "")
        local _, lines = detail:gsub("\n", "\n")
        table.insert(rows, ui.column({
            key = "panel-activity-" .. key, gap = 3, paddingH = 10, paddingV = 7,
            radius = 8, fill = event.status == "failed" and "error/0.10" or "surface_variant/0.24",
        }, {
            ui.row({ gap = 4, align = "center" }, {
                ui.label({ text = tostring(event.tool or event.kind or "") .. " · " .. tostring(event.status or ""),
                    color = event.status == "failed" and "error" or "secondary", fontWeight = "bold", flexGrow = 1 }),
                ui.button({ glyph = expanded and "chevron-up" or "chevron-down", variant = "ghost", controlSize = "sm",
                    tooltip = noctalia.tr(expanded and "ui.chat_collapse_output" or "ui.chat_expand_output"),
                    onClick = function() activity_expanded[key] = not expanded; render() end }),
            }),
            ui.label({ text = tostring(event.text or ""), maxLines = 2, maxWidth = 520 }),
            expanded and ui.label({ text = detail, color = "on_surface_variant",
                maxLines = math.max(4, lines + 1), maxWidth = 520 }) or ui.label({ text = "" }),
        }))
    end
    return ui.scroll({ key = "panel-activity", flexGrow = 1, gap = 6 }, rows)
end

local function attachments_supported()
    return not capabilities_negotiated or chat_capabilities.attachments == true
end

local function add_attachments(action)
    if not chat_writable() or not attachments_supported() or attachment_busy then return end
    attachment_busy = true
    chat_error = nil
    render()
    noctalia.runAsync({"python3", chat_bridge, action}, function(result)
        attachment_busy = false
        local payload = noctalia.json.decode(result.stdout or "")
        if type(payload) == "table" and payload.ok == true then
            for _, attachment in ipairs(payload.attachments or {}) do
                local duplicate = false
                for _, existing in ipairs(chat_attachments) do
                    if existing.path == attachment.path then duplicate = true end
                end
                if type(attachment.path) == "string" and not duplicate then
                    chat_attachments[#chat_attachments + 1] = attachment
                end
            end
        else
            chat_error = type(payload) == "table" and tostring(payload.error or noctalia.tr("ui.chat_error"))
                or noctalia.tr("ui.chat_error")
        end
        if open then render() end
    end, chat_bridge_timeout_ms)
end

local function attachment_controls()
    local rows = {
        ui.row({ gap = 4, align = "center" }, {
            ui.button({ text = noctalia.tr("ui.attach_files"), variant = "ghost", controlSize = "sm",
                enabled = chat_writable() and not attachment_busy and attachments_supported(),
                onClick = function() add_attachments("pick-attachments") end }),
            ui.button({ text = noctalia.tr("ui.attach_screenshot"), variant = "ghost", controlSize = "sm",
                enabled = chat_writable() and not attachment_busy and attachments_supported(),
                onClick = function() add_attachments("capture-attachment") end }),
            not attachments_supported() and ui.label({
                text = noctalia.tr("ui.attachments_unavailable"), color = "on_surface_variant", fontSize = 11,
            }) or ui.label({ text = "" }),
        }),
    }
    for index, attachment in ipairs(chat_attachments) do
        table.insert(rows, ui.row({ gap = 4, align = "center" }, {
            ui.label({ text = tostring(attachment.name or attachment.path) .. " · " .. tostring(attachment.mime or "")
                .. " · " .. tostring(attachment.size or 0) .. " B", flexGrow = 1, maxLines = 2, fontSize = 11 }),
            ui.button({ glyph = "close", variant = "ghost", controlSize = "sm",
                tooltip = noctalia.tr("ui.remove_attachment"), enabled = chat_writable() and not attachment_busy,
                onClick = function() table.remove(chat_attachments, index); render() end }),
        }))
    end
    return ui.column({ gap = 2 }, rows)
end

local function attachment_labels(attachments)
    local labels = {}
    for _, attachment in ipairs(type(attachments) == "table" and attachments or {}) do
        labels[#labels + 1] = ui.label({
            text = tostring(attachment.name or attachment.path or "") .. " · " .. tostring(attachment.mime or "")
                .. " · " .. tostring(attachment.size or 0) .. " B",
            color = "on_surface_variant", fontSize = 11, maxLines = 2, maxWidth = 520,
        })
    end
    return labels
end

local function requests_writable()
    return configured_bool("chat_enabled", true) and chat_selected
        and not chat_read_only_view and not chat_terminal_owns_session
end

local function respond_request(request, action, content, option_id)
    local key = request_key(request)
    local state = request_states[key] or { values = {} }
    request_states[key] = state
    if not requests_writable() or state.submitting then return end
    local active = false
    for _, pending in ipairs(pending_requests) do
        if request_key(pending) == key and pending.submitted ~= true then active = true; break end
    end
    if not active then return end
    local response = { run_id = request.run_id, request_id = request.request_id,
        action = action, option_id = option_id }
    local encoded, error = noctalia.json.encode(response)
    if encoded ~= nil and content ~= nil then
        local fields = {}
        for name, value in pairs(content) do
            local serialized, value_error = noctalia.json.encode(value)
            if type(value) == "table" and #value == 0 then serialized = "[]" end
            if serialized == nil then encoded = nil; error = value_error; break end
            fields[#fields + 1] = noctalia.json.encode(name) .. ":" .. serialized
        end
        if encoded ~= nil then
            encoded = encoded:sub(1, -2) .. ',"content":{' .. table.concat(fields, ",") .. "}}"
        end
    end
    if encoded == nil then
        state.error = tostring(error or noctalia.tr("ui.chat_error"))
        render()
        return
    end
    state.submitting = true
    state.error = nil
    render()
    noctalia.runAsync({"python3", chat_bridge, "respond", hex_encode(encoded)}, function(result)
        local payload = noctalia.json.decode(result.stdout or "")
        if type(payload) == "table" and payload.ok == true then
            -- Keep the lock until the runtime removes this exact run/request.
            state.queued = true
            sync_requests(payload)
        else
            state.submitting = false
            state.error = type(payload) == "table" and tostring(payload.error or noctalia.tr("ui.chat_error"))
                or noctalia.tr("ui.chat_error")
        end
        if open then render() end
    end, chat_bridge_timeout_ms)
end

local function question_content(request, state)
    local schema = request.schema or {}
    local required, content = {}, {}
    for _, name in ipairs(schema.required or {}) do required[name] = true end
    for name, property in pairs(schema.properties or {}) do
        local value = state.values[name]
        if value == nil or (type(value) == "string" and value == "" and property.type ~= "string") then
            if required[name] then return nil, noctalia.tr("ui.request_required", { field = property.title or name }) end
        else
            if property.type == "number" or property.type == "integer" then
                value = tonumber(value)
                if value == nil or (property.type == "integer" and value % 1 ~= 0) then
                    return nil, noctalia.tr("ui.request_invalid", { field = property.title or name })
                end
                if (property.minimum ~= nil and value < property.minimum)
                    or (property.maximum ~= nil and value > property.maximum) then
                    return nil, noctalia.tr("ui.request_invalid", { field = property.title or name })
                end
            end
            if type(value) == "string" and required[name] and value == "" then
                return nil, noctalia.tr("ui.request_required", { field = property.title or name })
            end
            if property.type == "array" then
                if (property.minItems ~= nil and #value < property.minItems)
                    or (property.maxItems ~= nil and #value > property.maxItems) then
                    return nil, noctalia.tr("ui.request_invalid", { field = property.title or name })
                end
            elseif type(value) == "string" then
                local length = utf8.len(value) or #value
                if (property.minLength ~= nil and length < property.minLength)
                    or (property.maxLength ~= nil and length > property.maxLength) then
                    return nil, noctalia.tr("ui.request_invalid", { field = property.title or name })
                end
            end
            content[name] = value
        end
    end
    return content
end

local function schema_options(property)
    local options = {}
    for _, value in ipairs(property.enum or {}) do
        options[#options + 1] = { value = value, label = tostring(value) }
    end
    for _, option in ipairs(property.oneOf or property.anyOf or {}) do
        if option.const ~= nil then
            options[#options + 1] = { value = option.const, label = tostring(option.title or option.const) }
        end
    end
    if property.type == "boolean" and #options == 0 then
        options = { { value = true, label = noctalia.tr("ui.request_yes") },
            { value = false, label = noctalia.tr("ui.request_no") } }
    end
    return options
end

local function request_cards()
    local cards = {}
    if not requests_writable() then return cards end
    for _, request in ipairs(pending_requests) do
        local permission = request.kind == "permission" and chat_capabilities.approvals == true
        local question = request.kind == "question" and chat_capabilities.questions == true
        if permission or question then
            local key = request_key(request)
            local state = request_states[key] or { values = {} }
            request_states[key] = state
            local rows = { ui.label({ text = tostring(request.title or ""), fontWeight = "bold", maxLines = 3 }) }
            if request.tool ~= nil then
                table.insert(rows, ui.label({ text = type(request.tool) == "string" and request.tool
                    or noctalia.json.encode(request.tool), color = "on_surface_variant", maxLines = 3 }))
            end
            if permission then
                for _, option in ipairs(request.options or {}) do
                    table.insert(rows, ui.button({
                        text = tostring(option.label or option.id), variant = "ghost", controlSize = "sm",
                        enabled = not state.submitting,
                        onClick = function() respond_request(request, "permission", nil, option.id) end,
                    }))
                end
            else
                local names = {}
                for name in pairs((request.schema or {}).properties or {}) do names[#names + 1] = name end
                table.sort(names)
                for _, name in ipairs(names) do
                    local property = request.schema.properties[name]
                    table.insert(rows, ui.label({ text = tostring(property.title or name), maxLines = 2, fontSize = 11 }))
                    local options = schema_options(property)
                    local array_options = type(property.items) == "table" and schema_options(property.items) or {}
                    if property.type == "array" and #array_options > 0 then
                        if state.values[name] == nil then state.values[name] = {} end
                        local selected = state.values[name] or {}
                        for _, choice in ipairs(array_options) do
                            local option = choice.value
                            local found = false
                            for _, value in ipairs(selected) do if value == option then found = true end end
                            table.insert(rows, ui.button({
                                text = choice.label, variant = "ghost", selected = found, enabled = not state.submitting,
                                onClick = function()
                                    local values, removed = {}, false
                                    for _, value in ipairs(state.values[name] or {}) do
                                        if value == option then removed = true else values[#values + 1] = value end
                                    end
                                    if not removed then values[#values + 1] = option end
                                    state.values[name] = values
                                    render()
                                end,
                            }))
                        end
                    elseif #options > 0 then
                        local labels, selected = { noctalia.tr("ui.request_choose") }, 0
                        for index, option in ipairs(options) do
                            labels[#labels + 1] = option.label
                            if state.values[name] == option.value then selected = index end
                        end
                        table.insert(rows, ui.select({
                            key = "panel-request-" .. key .. "-" .. name, options = labels, selectedIndex = selected,
                            width = 320, enabled = not state.submitting,
                            onChange = function(index, text)
                                local choice = select_option(labels, index, text)
                                if choice > 1 then state.values[name] = options[choice - 1].value
                                else state.values[name] = nil end
                                render()
                            end,
                        }))
                    else
                        table.insert(rows, ui.input({
                            key = "panel-request-" .. key .. "-" .. name, width = 320,
                            value = tostring(state.values[name] or ""), enabled = not state.submitting,
                            onChange = function(value) state.values[name] = tostring(value or "") end,
                        }))
                    end
                end
                table.insert(rows, ui.row({ gap = 4 }, {
                    ui.button({ text = noctalia.tr("ui.request_submit"), variant = "primary", enabled = not state.submitting,
                        onClick = function()
                            local content, error = question_content(request, state)
                            if error ~= nil then state.error = error; render(); return end
                            respond_request(request, "accept", content)
                        end }),
                    ui.button({ text = noctalia.tr("ui.request_decline"), variant = "ghost", enabled = not state.submitting,
                        onClick = function() respond_request(request, "decline") end }),
                    ui.button({ text = noctalia.tr("ui.request_cancel"), variant = "ghost", enabled = not state.submitting,
                        onClick = function() respond_request(request, "cancel") end }),
                }))
            end
            if state.error ~= nil then table.insert(rows, ui.label({ text = state.error, color = "error", maxLines = 3 })) end
            if state.submitting then table.insert(rows, ui.label({
                text = noctalia.tr(state.queued and "ui.request_waiting_ack" or "ui.request_submitting"),
                color = "secondary", maxLines = 2,
            })) end
            table.insert(cards, ui.column({ key = "panel-request-" .. key, gap = 4,
                paddingH = 10, paddingV = 8, radius = 8, fill = "secondary/0.10" }, rows))
        end
    end
    local acknowledged = request_history[#request_history]
    if type(acknowledged) == "table" and acknowledged.status == "responded" then
        table.insert(cards, ui.column({ key = "panel-request-ack", gap = 2,
            paddingH = 10, paddingV = 6, radius = 8, fill = "primary/0.10" }, {
            ui.label({ text = noctalia.tr("ui.request_acknowledged"), color = "secondary", maxLines = 2 }),
            ui.label({ text = tostring(acknowledged.title or ""), color = "on_surface_variant",
                fontSize = 11, maxLines = 1 }),
        }))
    end
    return cards
end

local function selected_harness()
    for _, harness in ipairs(chat_harnesses) do
        if harness.id == chat_new_harness then return harness end
    end
    return chat_harnesses[1]
end


local function harness_picker()
    local rows = {}
    for _, harness in ipairs(chat_harnesses) do
        local available = harness.available ~= false
        rows[#rows + 1] = ui.column({ gap = 2 }, {
            ui.button({ text = tostring(harness.name or harness.id), variant = "ghost", controlSize = "sm",
                selected = harness.id == chat_new_harness, enabled = available and not chat_busy,
                onClick = function()
                    if not available or chat_busy then return end
                    chat_new_harness = harness.id
                    chat_new_model = harness.default_model
                    chat_model_filter = ""
                    chat_model_menu_open = false
                    chat_model_input_revision = chat_model_input_revision + 1
                    render()
                end }),
            ui.label({ text = available and tostring(harness.auth_status or noctalia.tr("ui.harness_auth_local"))
                    or tostring(harness.install_hint or noctalia.tr("ui.harness_unavailable")),
                color = "on_surface_variant", fontSize = 11, maxLines = 3 }),
        })
    end
    return ui.column({ width = 280, height = 140 }, {
        ui.scroll({ flexGrow = 1, gap = 3 }, rows),
    })
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
                enabled = not chat_busy and selected_harness() ~= nil and selected_harness().available ~= false,
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
                enabled = not chat_busy and selected_harness() ~= nil and selected_harness().available ~= false and #options > 0,
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
            local value = type(option) == "table" and option.id or option
            local label = type(option) == "table" and tostring(option.label or option.id) or tostring(option)
            if fuzzy_matches(chat_model_filter, label .. " " .. tostring(value)) then
                table.insert(choices, ui.button({
                    text = label,
                    variant = value == chat_new_model and "primary" or "ghost",
                    enabled = not chat_busy and selected_harness().available ~= false,
                    onClick = function()
                        chat_new_model = value
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
        sync_requests(payload)
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
        if type(payload.usage) == "table" then quota_usage = payload.usage end
        chat_selected = payload.selected == true
        chat_session_id = payload.session_id
        chat_session_title = payload.title
        chat_session_cwd = payload.cwd
        chat_session_model = payload.model
        chat_session_harness = payload.harness
        chat_terminal_owns_session = payload.active == true and payload.mode == "resume"
        if chat_new_harness == nil then
            for _, harness in ipairs(chat_harnesses) do
                if harness.available ~= false then chat_new_harness = harness.id; break end
            end
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
    panel.setNeedsFrameTick(needs_panel_frame_tick())
    noctalia.runAsync(
        {"python3", chat_bridge, "load"},
        apply_chat_result,
        chat_bridge_timeout_ms
    )
end

local function refresh_usage()
    if quota_loading or chat_busy then return end
    quota_loading = true
    render()
    noctalia.runAsync(
        {"python3", chat_bridge, "refresh-usage"},
        function(result)
            quota_loading = false
            apply_chat_result(result)
        end,
        chat_bridge_timeout_ms
    )
end

local function submit_chat(value)
    local message = tostring(value or ""):match("^%s*(.-)%s*$")
    if not chat_writable() or attachment_busy or (message == "" and #chat_attachments == 0) then return end
    if #chat_attachments > 0 and not attachments_supported() then return end
    local command = {"python3", chat_bridge, "send", hex_encode(message)}
    if #chat_attachments > 0 then
        local paths = {}
        for _, attachment in ipairs(chat_attachments) do paths[#paths + 1] = attachment.path end
        local encoded, error = noctalia.json.encode(paths)
        if encoded == nil then chat_error = tostring(error or noctalia.tr("ui.chat_error")); render(); return end
        command[#command + 1] = hex_encode(encoded)
    end
    chat_busy = true
    chat_error = nil
    render()
    noctalia.runAsync(command, function(result)
        local payload = noctalia.json.decode(result.stdout or "")
        if type(payload) == "table" and payload.ok == true then
            chat_draft = ""
            chat_attachments = {}
            chat_input_revision = chat_input_revision + 1
            chat_scroll_revision = chat_scroll_revision + 1
        end
        apply_chat_result(result)
    end, chat_bridge_timeout_ms)
end
local function select_chat_session(path)
    if not configured_bool("chat_enabled", true) or chat_busy or type(path) ~= "string" then return end
    chat_read_only_view = false
    chat_session_accent = nil
    chat_scroll_to_bottom_on_load = true
    chat_loading = true
    chat_busy = true
    panel.setNeedsFrameTick(needs_panel_frame_tick())
    render()
    noctalia.runAsync(
        {"python3", chat_bridge, "select", hex_encode(path)},
        apply_chat_result,
        chat_bridge_timeout_ms
    )
end

local function open_session_chat(session_id, read_only)
    if chat_busy or type(session_id) ~= "string" or session_id == "" then return end
    if read_only ~= true and not configured_bool("chat_enabled", true) then return end
    if panel_mode ~= "chat" then
        transcript_return_mode = panel_mode
        transcript_return_attention = attention_inbox
    end
    set_panel_mode("chat")
    attention_inbox = false
    transcript_item = nil
    for _, collection in ipairs({ sessions.sessions or {}, sessions.recent_outcomes or {} }) do
        for _, item in ipairs(collection) do
            if item.id == session_id then transcript_item = item; break end
        end
        if transcript_item ~= nil then break end
    end
    chat_session_accent = transcript_item and transcript_item.accent or nil
    chat_read_only_view = read_only == true
    chat_selected = false
    chat_events = {}
    chat_messages = {}
    chat_feed_revision = nil
    chat_event_limit = CHAT_RENDERED_EVENTS
    chat_loading = true
    panel.setNeedsFrameTick(needs_panel_frame_tick())
    chat_busy = true
    chat_error = nil
    chat_scroll_to_bottom_on_load = true
    render()
    noctalia.runAsync(
        {"python3", chat_bridge, "select-id", hex_encode(session_id)},
        apply_chat_result,
        chat_bridge_timeout_ms
    )
end

local function start_chat_session(cwd)
    local path = tostring(cwd or ""):match("^%s*(.-)%s*$")
    if not configured_bool("chat_enabled", true) or chat_read_only_view
        or chat_busy or path == "" or chat_new_harness == nil or chat_new_model == nil then return end
    if selected_harness() == nil or selected_harness().available == false then return end
    chat_read_only_view = false
    chat_session_accent = nil
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
    if not configured_bool("chat_enabled", true) or chat_read_only_view or chat_busy then return end
    chat_read_only_view = false
    chat_session_accent = nil
    chat_busy = true
    chat_error = nil
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
    if not configured_bool("chat_enabled", true) or not chat_busy
        or chat_read_only_view or chat_terminal_owns_session then return end
    noctalia.runAsync(
        {"python3", chat_bridge, "cancel"},
        apply_chat_result,
        chat_bridge_timeout_ms
    )
end

local function open_chat_terminal()
    if not configured_bool("chat_enabled", true) or chat_read_only_view or chat_busy then return end
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
            or message.text ~= candidate.text
            or noctalia.json.encode(message.attachments or {}) ~= noctalia.json.encode(candidate.attachments or {}) then
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
            or event.text ~= candidate.text
            or noctalia.json.encode(event.attachments or {}) ~= noctalia.json.encode(candidate.attachments or {}) then
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
    local changed = sync_requests(payload) or chat_busy ~= (payload.busy == true)
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
        local available = target.available ~= false and (target.resumable == true or target.forkable == true)
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
            harness_picker(),
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
                enabled = not chat_busy and selected_harness() ~= nil and selected_harness().available ~= false
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

local function chat_context(item)
    local parts = {}
    if type(chat_session_harness) == "string" then table.insert(parts, chat_session_harness) end
    if type(chat_session_model) == "string" then table.insert(parts, model_name(chat_session_model)) end
    if configured_bool("show_task", true) and item ~= nil and type(item.activity) == "string" and item.activity ~= "" then
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
        ui.column({ gap = 2 }, attachment_labels(message.attachments)),
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

local function transcript_back_button()
    return ui.button({
        key = "panel-transcript-back",
        glyph = "arrow-left", variant = "ghost", controlSize = "sm",
        tooltip = noctalia.tr("ui.transcript_back"),
        onClick = function()
            set_panel_mode(transcript_return_mode)
            attention_inbox = transcript_return_attention
            panel.setNeedsFrameTick(needs_panel_frame_tick())
            render()
        end,
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
        Orb.render({ state = "working", size = 64, time = animation_time() }),
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
        return chat_message_card({ role = kind, text = text, attachments = event.attachments }, index)
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
    if chat_loading then
        return ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, {
            ui.row({ align = "center" }, { transcript_back_button() }),
            chat_loading_view(),
        })
    end
    if not chat_selected then
        if chat_read_only_view or not configured_bool("chat_enabled", true) then
            return ui.column({ flexGrow = 1, gap = 8 }, {
                ui.row({ align = "center" }, { transcript_back_button() }),
                identity_marker(transcript_item),
                ui.label({ text = transcript_item and display_label(transcript_item) or noctalia.tr("ui.chat_session"),
                    fontWeight = "bold", maxLines = label_lines() }),
                ui.label({ text = noctalia.tr("ui.recent_activity_read_only"), color = "secondary" }),
                chat_error_label() or ui.label({ text = noctalia.tr("ui.chat_empty"), color = "on_surface_variant" }),
            })
        end
        return ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, {
            ui.row({ align = "center" }, { transcript_back_button() }),
            chat_picker(),
        })
    end
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
    for _, card in ipairs(request_cards()) do table.insert(transcript, card) end
    local item = monitored_chat_session() or transcript_item
    if item and item.accent then chat_session_accent = item.accent end
    if chat_busy then
        table.insert(transcript, ui.row({
            gap = 6,
            align = "center",
            paddingH = 10,
            paddingV = 8,
            radius = 10,
            fill = "secondary/0.10",
        }, {
            Orb.render({ state = state_of(item), size = 16, time = animation_time() }),
            ui.label({ text = noctalia.tr("ui.chat_thinking"), color = "secondary" }),
        }))
    end
    if chat_terminal_owns_session or chat_read_only_view then
        table.insert(transcript, ui.label({
            text = noctalia.tr(chat_terminal_owns_session and "ui.chat_terminal_active" or "ui.recent_activity_read_only"),
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
            identity_marker(item or { accent = chat_session_accent }),
            Orb.render({
                state = item ~= nil and state_of(item) or (chat_busy and "working" or "breathing"),
                size = 24, time = animation_time(),
            }),
            ui.column({ gap = 2, flexGrow = 1 }, {
                ui.label({ text = title, fontWeight = "bold", maxLines = label_lines() }),
                ui.label({ text = context, color = "on_surface_variant", fontSize = 11, maxLines = label_lines() }),
            }),
            pin_button(item) or ui.label({ text = "" }),
            focus_button(item) or ui.label({ text = "" }),
            transcript_back_button(),
            configured_bool("chat_enabled", true) and not chat_read_only_view and ui.button({
                text = noctalia.tr("ui.chat_cancel"),
                variant = "ghost",
                controlSize = "sm",
                enabled = chat_busy and not chat_read_only_view and not chat_terminal_owns_session,
                onClick = cancel_chat,
            }) or ui.label({ text = "" }),
            configured_bool("chat_enabled", true) and not chat_read_only_view and ui.button({
                text = noctalia.tr("ui.chat_open_terminal"),
                variant = "ghost",
                controlSize = "sm",
                enabled = not chat_busy,
                onClick = open_chat_terminal,
            }) or ui.label({ text = "" }),
            configured_bool("chat_enabled", true) and not chat_read_only_view and ui.button({
                text = noctalia.tr("ui.chat_switch"),
                variant = "ghost",
                controlSize = "sm",
                enabled = not chat_busy,
                onClick = reset_chat,
            }) or ui.label({ text = "" }),
        }),
        ui.scroll({
            align = "stretch",
            flexGrow = 1,
            gap = 8,
            padding = 4,
            stickToBottom = true,
            scrollToBottomRev = chat_scroll_revision,
        }, transcript),
        configured_bool("chat_enabled", true) and not chat_read_only_view
            and attachment_controls() or ui.label({ text = "" }),
        configured_bool("chat_enabled", true) and not chat_read_only_view and ui.row({ gap = 8, align = "center" }, {
            ui.input({
                key = "panel-chat-input-" .. tostring(chat_input_revision),
                width = 500,
                value = chat_draft,
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
                enabled = chat_writable() and (chat_draft:match("%S") ~= nil
                    or (#chat_attachments > 0 and attachments_supported())),
                onClick = function() submit_chat(chat_draft) end,
            }),
        }) or ui.label({ text = "" }),
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
                    text = noctalia.tr("ui.copy_proposal", { choice = response }),
                    controlSize = "sm",
                    variant = "ghost",
                    tooltip = noctalia.tr("ui.copy_proposal_help", { choice = label }),
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
        text = noctalia.tr("ui.copy_custom_response"),
        controlSize = "sm",
        variant = "ghost",
        tooltip = noctalia.tr("ui.copy_custom_response"),
        onClick = function() copy_response("Custom: ") end,
    }))
    return ui.column({ gap = 2 }, rows)
end

local function session_row(item, show_task, show_attention)
    local details = {
        ui.label({ text = display_label(item), fontWeight = "bold", maxLines = label_lines() }),
    }
    if show_task and item.task and item.task ~= "" then
        table.insert(details, ui.label({
            text = tostring(item.task),
            color = "primary",
            maxLines = label_lines(),
        }))
    end
    table.insert(details, ui.label({
        text = show_task and state_description(item) or state_label(item),
        color = "on_surface_variant",
        maxLines = 1,
    }))
    if item.last_activity_time ~= nil then
        table.insert(details, ui.label({
            text = noctalia.tr("ui.attention_last_activity", { time = item.last_activity_time }),
            color = "on_surface_variant",
            fontSize = 11,
            maxLines = 1,
        }))
    end
    local controls = show_task and proposal_controls(item) or nil
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
        status = {}
        if show_attention then
            table.insert(status, 1, ui.label({
                text = attention_label(item),
                color = attention_color(item),
            }))
        end
    end

    local row = {
        identity_marker(item),
        Orb.render({ state = state_of(item), size = 20, time = animation_time() }),
        ui.column({ gap = 2, flexGrow = 1 }, details),
        ui.column({ gap = 2 }, status),
    }
    local pin = pin_button(item)
    if pin ~= nil then table.insert(row, pin) end
    local focus = focus_button(item)
    if focus ~= nil then table.insert(row, focus) end
    table.insert(row, ui.button({ glyph = "activity", glyphSize = 14, variant = "ghost", controlSize = "sm",
        tooltip = noctalia.tr("ui.activity_title"), onClick = function() open_activity(item) end }))
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
    return ui.row({ key = "session-" .. tostring(item.id), gap = 10, align = "center", paddingH = 8, paddingV = 7,
        radius = 10, fill = pinned_session == item.id and "primary/0.12" or session_fill(item) }, row)
end

local function attention_row(item, show_task)
    local details = {
        ui.label({ text = display_label(item), fontWeight = "bold", maxLines = label_lines() }),
        ui.label({
            text = item.last_activity_time ~= nil
                and noctalia.tr("ui.attention_last_activity", { time = item.last_activity_time }) or "",
            color = "on_surface_variant", fontSize = 11, maxLines = 1,
        }),
    }
    if show_task and type(item.task) == "string" and item.task ~= "" then
        table.insert(details, ui.label({ text = item.task, maxLines = label_lines() }))
    end
    local actions = {}
    local pin = pin_button(item)
    if pin ~= nil then table.insert(actions, pin) end
    local focus = focus_button(item)
    if focus ~= nil then table.insert(actions, focus) end
    if attention_target == item.id then
        table.insert(details, 1, ui.label({
            text = noctalia.tr("ui.attention_target"), color = "primary", fontSize = 11, fontWeight = "bold",
        }))
    end
    if configured_bool("chat_enabled", true) then
        table.insert(actions, ui.button({
            text = noctalia.tr("ui.attention_open_session"), variant = "ghost", controlSize = "sm",
            enabled = not chat_busy,
            tooltip = noctalia.tr("ui.attention_open_session_help"),
            onClick = function() open_session_chat(item.id) end,
        }))
    end
        table.insert(actions, ui.button({
            text = noctalia.tr("ui.activity_title"), variant = "ghost", controlSize = "sm",
            tooltip = noctalia.tr("ui.activity_title"),
            onClick = function() open_activity(item) end,
        }))
    if show_task and type(item.task) == "string" and item.task ~= "" then
        table.insert(actions, ui.button({
            text = noctalia.tr("ui.attention_copy_task"), variant = "ghost", controlSize = "sm",
            onClick = function() copy_response(item.task) end,
        }))
    end
    table.insert(actions, ui.button({
        glyph = "folder-open", glyphSize = 14, variant = "ghost", controlSize = "sm",
        enabled = type(item.cwd) == "string" and item.cwd ~= "",
        tooltip = noctalia.tr("ui.open_project"),
        onClick = function()
            if type(item.cwd) == "string" and item.cwd ~= "" then noctalia.runAsync({"xdg-open", item.cwd}) end
        end,
    }))
    table.insert(details, ui.row({ gap = 4, align = "center" }, actions))
    local controls = show_task and proposal_controls(item) or nil
    if controls then table.insert(details, controls) end
    return ui.row({
        key = "attention-" .. tostring(item.id), gap = 8, align = "center",
        paddingH = 8, paddingV = 6, radius = 10,
        fill = attention_target == item.id and "primary/0.18" or session_fill(item),
    }, {
        identity_marker(item),
        Orb.render({ state = state_of(item), size = 20, time = animation_time() }),
        ui.glyph({ name = attention_of(item) == "blocked" and "alert-triangle" or "clock", size = 16, color = attention_color(item) }),
        ui.column({ gap = 3, flexGrow = 1 }, details),
    })
end

local function outcomes_view()
    local rows = {}
    for _, item in ipairs(sessions.recent_outcomes or {}) do
        table.insert(rows, ui.row({
            key = "outcome-" .. tostring(item.id), gap = 8, align = "center",
            paddingH = 8, paddingV = 6, radius = 10, fill = session_fill(item),
        }, {
            identity_marker(item),
            ui.column({ flexGrow = 1, gap = 2 }, {
                ui.label({ text = tostring(item.project or "terminal"), fontWeight = "bold", maxLines = label_lines() }),
                ui.label({ text = tostring(item.task or ""), color = "on_surface_variant", maxLines = label_lines() }),
            }),
            ui.column({ gap = 2 }, {
                ui.label({ text = attention_label(item), color = attention_color(item) }),
                ui.label({ text = noctalia.tr("ui.exited_ago", { time = elapsed(item.exited) }),
                    color = "on_surface_variant", fontSize = 11 }),
            }),
            ui.button({
                glyph = "message-circle", glyphSize = 14, variant = "ghost", controlSize = "sm",
                enabled = not chat_busy, tooltip = noctalia.tr("ui.recent_activity_read_only"),
                onClick = function() open_session_chat(item.id, true) end,
            }),
        }))
    end
    if #rows == 0 then
        table.insert(rows, ui.label({ text = noctalia.tr("ui.recent_outcomes_empty"),
            color = "on_surface_variant", maxLines = 3 }))
    else
        table.insert(rows, 1, ui.label({ text = noctalia.tr("ui.recent_outcomes_retention"),
            color = "on_surface_variant", fontSize = 11, maxLines = 2 }))
    end
    return ui.scroll({ key = "panel-outcomes", flexGrow = 1, gap = 6 }, rows)
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

local function quota_remaining(limit)
    local fraction = limit.remaining_fraction
    if type(fraction) == "number" then
        return string.format("%.0f%%", math.min(1, math.max(0, fraction)) * 100)
    end
    local remaining = limit.remaining
    if type(remaining) == "number" then
        local unit = type(limit.unit) == "string" and limit.unit or ""
        return tostring(remaining) .. (unit ~= "" and " " .. unit or "")
    end
    return noctalia.tr("ui.quota_unknown")
end

local function quota_reset(limit)
    if type(limit.resets_at) ~= "number" then return nil end
    return os.date("%Y-%m-%d %H:%M", math.floor(limit.resets_at / 1000))
end

local function quota_view()
    local content = {
        ui.row({ gap = 8, align = "center" }, {
            ui.label({ text = noctalia.tr("ui.quota_title"), fontWeight = "bold", flexGrow = 1 }),
            ui.button({
                glyph = "refresh",
                glyphSize = 15,
                variant = "ghost",
                controlSize = "sm",
                tooltip = noctalia.tr("ui.quota_refresh"),
                enabled = not quota_loading and not chat_busy,
                onClick = refresh_usage,
            }),
        }),
    }
    if quota_loading then
        table.insert(content, ui.label({
            text = noctalia.tr("ui.quota_loading"),
            color = "on_surface_variant",
        }))
    end
    if type(quota_usage.error) == "string" and quota_usage.error ~= "" then
        table.insert(content, ui.label({
            text = quota_usage.error,
            color = "error",
            maxLines = 3,
        }))
    end
    local reports = type(quota_usage.reports) == "table" and quota_usage.reports or {}
    if #reports == 0 and not quota_loading and quota_usage.error == nil then
        table.insert(content, ui.label({
            text = noctalia.tr("ui.quota_empty"),
            color = "on_surface_variant",
        }))
    end
    for report_index, report in ipairs(reports) do
        if type(report) == "table" then
            local lines = {
                ui.row({ gap = 6, align = "center" }, {
                    ui.label({
                        text = tostring(report.provider or noctalia.tr("ui.quota_provider")),
                        fontWeight = "bold",
                        flexGrow = 1,
                    }),
                    type(report.plan) == "string" and ui.label({
                        text = report.plan,
                        color = "on_surface_variant",
                        fontSize = 11,
                    }) or ui.label({ text = "" }),
                }),
            }
            local limits = type(report.limits) == "table" and report.limits or {}
            for limit_index, limit in ipairs(limits) do
                if type(limit) == "table" then
                    local reset = quota_reset(limit)
                    table.insert(lines, ui.row({
                        key = "quota-limit-" .. tostring(report_index) .. "-" .. tostring(limit_index),
                        gap = 8,
                        align = "center",
                    }, {
                        ui.label({ text = tostring(limit.label or noctalia.tr("ui.quota_usage")), flexGrow = 1 }),
                        ui.label({
                            text = noctalia.tr("ui.quota_remaining", { remaining = quota_remaining(limit) }),
                            color = limit.status == "ok" and "primary" or "on_surface_variant",
                            fontWeight = "bold",
                        }),
                        reset ~= nil and ui.label({
                            text = noctalia.tr("ui.quota_resets", { time = reset }),
                            color = "on_surface_variant",
                            fontSize = 11,
                        }) or ui.label({ text = "" }),
                    }))
                end
            end
            for _, note in ipairs(type(report.notes) == "table" and report.notes or {}) do
                table.insert(lines, ui.label({
                    text = tostring(note),
                    color = "on_surface_variant",
                    fontSize = 11,
                    maxLines = 3,
                }))
            end
            table.insert(content, ui.column({
                key = "quota-report-" .. tostring(report_index),
                gap = 6,
                paddingH = 10,
                paddingV = 8,
                radius = 10,
                fill = "surface_variant/0.30",
            }, lines))
        end
    end
    return ui.scroll({ flexGrow = 1, gap = 8, padding = 4 }, content)
end

render = function()
    local active = tonumber(sessions.active) or 0
    local body = {}
    local items = sessions.sessions or {}
    local show_task = configured_bool("show_task", true)
    local show_attention = configured_bool("show_attention", true)
    local filter_attention = configured_bool("filter_attention", false)
    local sort_mode = noctalia.getConfig("sort_mode") or "duration"
    local target = resolved_attention_target()
    local blocked, waiting = 0, 0
    for _, item in ipairs(items) do
        if item.exited == nil then
            if attention_of(item) == "blocked" then blocked = blocked + 1 end
            if attention_of(item) == "waiting" then waiting = waiting + 1 end
        end
    end
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
    elseif attention_inbox then
        for _, attention in ipairs({ "blocked", "waiting" }) do
            local queue = {}
            for _, item in ipairs(rows) do
                if attention_of(item) == attention then table.insert(queue, item) end
            end
            table.sort(queue, function(a, b)
                if target ~= nil then
                    if a.id == target.id then return true end
                    if b.id == target.id then return false end
                end
                local ai, bi = tonumber(a.idle) or 0, tonumber(b.idle) or 0
                if ai ~= bi then return ai > bi end
                return tostring(a.id) < tostring(b.id)
            end)
            if #queue > 0 then
                table.insert(body, ui.label({
                    text = noctalia.tr(attention == "blocked" and "ui.attention_blocked_group" or "ui.attention_waiting_group", { count = #queue }),
                    color = attention == "blocked" and "error" or "secondary", fontWeight = "bold",
                }))
                for _, item in ipairs(queue) do table.insert(body, attention_row(item, show_task)) end
            end
        end
    else
        local groups = group_items(rows)
        for _, group in ipairs(groups) do
            local is_collapsed = not configured_bool("presentation_mode", false) and collapsed[group.project] == true
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
        header_icon = Orb.render({ state = state_of(rows[1]), size = 42, time = animation_time() })
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
                    or (panel_mode == "usage"
                        and noctalia.tr("ui.quota_title")
                        or noctalia.trp("ui.active_agents", active)),
                color = (panel_mode == "chat" or panel_mode == "usage" or active > 0)
                    and "primary" or "on_surface_variant",
            }),
        }),
    }
    table.insert(header, ui.button({
        key = "panel-tab-outcomes", glyph = "history", glyphSize = 16, variant = "ghost",
        tooltip = noctalia.tr("ui.recent_outcomes"), selected = panel_mode == "outcomes",
        onClick = function()
            set_panel_mode("outcomes")
            panel.setNeedsFrameTick(needs_panel_frame_tick())
            render()
        end,
    }))
    table.insert(header, ui.button({
        key = "panel-tab-activity", glyph = "activity", glyphSize = 16, variant = "ghost",
        tooltip = noctalia.tr("ui.activity_title"), selected = panel_mode == "activity",
        onClick = function() open_activity(nil) end,
    }))
    if pinned_session ~= nil then
        table.insert(header, ui.button({
            key = "panel-unpin", glyph = "pin", variant = "ghost", selected = true,
            tooltip = noctalia.tr("ui.unpin_session"),
            onClick = function() noctalia.state.set("agentik.pinned_session", nil) end,
        }))
    end
        table.insert(header, ui.button({
            key = "panel-tab-sessions",
            glyph = "list",
            glyphSize = 16,
            variant = "ghost",
            tooltip = noctalia.tr("ui.sessions"),
            selected = panel_mode == "sessions",
            onClick = function()
                set_panel_mode("sessions")
                attention_inbox = false
                attention_target = nil
                panel.setNeedsFrameTick(needs_panel_frame_tick())
                render()
            end,
        }))
    if configured_bool("chat_enabled", true) then
        table.insert(header, ui.button({
            key = "panel-tab-chat",
            glyph = "message-circle",
            glyphSize = 16,
            variant = "ghost",
            tooltip = noctalia.tr("ui.chat_open"),
            selected = panel_mode == "chat",
            onClick = function()
                if panel_mode ~= "chat" then
                    transcript_return_mode = panel_mode
                    transcript_return_attention = attention_inbox
                    set_panel_mode("chat")
                    panel.setNeedsFrameTick(needs_panel_frame_tick())
                    load_chat(true)
                end
                render()
            end,
        }))
    end
    table.insert(header, ui.button({
        key = "panel-tab-usage",
        glyph = "gauge",
        glyphSize = 16,
        variant = "ghost",
        tooltip = noctalia.tr("ui.quota_title"),
        selected = panel_mode == "usage",
        onClick = function()
            if panel_mode == "usage" then
                set_panel_mode(quota_return_mode)
            else
                quota_return_mode = panel_mode
                set_panel_mode("usage")
                refresh_usage()
            end
            render()
        end,
    }))
    table.insert(header, ui.button({
        key = "panel-attention-inbox",
        glyph = "alert-circle",
        text = tostring(blocked) .. " / " .. tostring(waiting),
        glyphSize = 16,
        variant = "ghost",
        tooltip = noctalia.tr("ui.attention_counts", { blocked = blocked, waiting = waiting }),
        selected = attention_inbox,
        onClick = function()
            attention_inbox = not attention_inbox
            set_panel_mode("sessions")
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

    local content
    if panel_mode == "chat" then
        content = chat_view()
    elseif panel_mode == "activity" then
        content = activity_view()
    elseif panel_mode == "usage" then
        content = quota_view()
    elseif panel_mode == "outcomes" then
        content = outcomes_view()
    else
        content = ui.scroll({ flexGrow = 1, gap = 6 }, body)
    end
    local progress = surface_transition_progress()
    content = ui.column({ key = "panel-surface", flexGrow = 1,
        opacity = 0.65 + 0.35 * progress, paddingH = 6 * (1 - progress) }, { content })
    local children = {}
    local banner = monitoring_banner()
    if banner ~= nil then table.insert(children, banner) end
    if focus_error ~= nil then
        table.insert(children, ui.label({ text = focus_error, color = "error", maxLines = 3 }))
    end
    table.insert(children, content)
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
        ui.column({ flexGrow = 1, gap = 6 }, children),
    }))
    panel.setNeedsFrameTick(open and needs_panel_frame_tick())
end

function update()
    if not open then return end
    if panel_mode == "activity" then poll_activity(false) end
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
    local animated = panel_stream_dirty or surface_transition_started ~= nil
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
    if context == "chat" then set_panel_mode("chat") end
    if context == "attention" or noctalia.state.get("agentik.open_attention") == true then
        noctalia.state.set("agentik.open_attention", false)
        set_panel_mode("sessions")
        attention_inbox = true
        attention_target = noctalia.state.get("agentik.attention_target")
        noctalia.state.set("agentik.attention_target", nil)
    end
    panel.setNeedsFrameTick(needs_panel_frame_tick())
    panel.setWantsSecondTicks(true)
    if panel_mode == "chat" then load_chat(true) end
    if panel_mode == "activity" then poll_activity(true) end
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

noctalia.state.watch("agentik.pinned_session", function(value)
    pinned_session = type(value) == "string" and value or nil
    if open then render() end
end)
noctalia.state.watch("agentik.monitor_health", function(value)
    monitor_health = type(value) == "table" and value or { status = "pending" }
    if open then render() end
end)


noctalia.state.watch("agentik_chat_status", function(result)
    if type(result) == "table" then apply_chat_status(result) end
end)
