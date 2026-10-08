-- Desktop widget: live OMP monitoring with an optional full-session client.
-- Monitoring reads the shared collector state; session chat runs through the
-- same local bridge as the main Agentik panel.
local Orb = require("./orb.luau")
local FRAME_RATE = 60
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
local chat_attachments = {}
local attachment_busy = false
local chat_capabilities = {}
local capabilities_negotiated = false
local pending_requests = {}
local request_history = {}
local request_states = {}
local activity_open = false
local activity_session_id = nil
local activity_events = {}
local activity_expanded = {}
local activity_loading = false
local activity_error = nil
local activity_last_poll = -3000
local focus_busy = {}
local focus_error = nil
local chat_session_id = nil


-- Bridge output is emitted only after the journal is processed; a large
-- session can take several seconds, past runAsync's 5 s default timeout.

local function configured_bool(key, default)
    local value = noctalia.getConfig(key)
    if value == nil then return default end
    return value == true or value == "true"
end
local function chat_writable()
    return configured_bool("chat_enabled", true) and chat_selected and not attachment_busy
        and not chat_busy and not chat_terminal_owns_session
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
    return (configured_bool("high_contrast", false) or configured_bool("presentation_mode", false))
        and "on_surface" or "on_surface_variant"
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
        key = "desktop-focus-" .. item.id, glyph = "terminal", glyphSize = 14,
        variant = "ghost", controlSize = "sm", enabled = focus_busy[item.id] ~= true,
        tooltip = noctalia.tr("ui.focus_session"),
        onClick = function()
            if focus_busy[item.id] then return end
            focus_busy[item.id] = true
            focus_error = nil
            update()
            noctalia.runAsync({"python3", chat_bridge, "focus-session", hex_encode(item.id)}, function(result)
                focus_busy[item.id] = nil
                local payload = noctalia.json.decode(result.stdout or "")
                if type(payload) ~= "table" or payload.ok ~= true then
                    focus_error = type(payload) == "table" and tostring(payload.error or noctalia.tr("ui.chat_error"))
                        or noctalia.tr("ui.chat_error")
                end
                update()
            end, chat_bridge_timeout_ms)
        end,
    })
end

local function poll_activity(force)
    if not activity_open or activity_loading or activity_session_id == nil then return end
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
        update()
    end, chat_bridge_timeout_ms)
end

local function open_activity(item)
    activity_open = true
    chat_open = false
    if item ~= nil and activity_session_id ~= item.id then
        activity_session_id = item.id
        activity_events = {}
        activity_expanded = {}
        activity_error = nil
    end
    poll_activity(true)
    update()
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
            key = "desktop-activity-session", width = 320, options = choices,
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
            key = "desktop-activity-" .. key, gap = 3, paddingH = 10, paddingV = 7,
            radius = 8, fill = event.status == "failed" and "error/0.10" or "surface_variant/0.24",
        }, {
            ui.row({ gap = 4, align = "center" }, {
                ui.label({ text = tostring(event.tool or event.kind or "") .. " · " .. tostring(event.status or ""),
                    color = event.status == "failed" and "error" or "secondary", fontWeight = "bold", flexGrow = 1 }),
                ui.button({ glyph = expanded and "chevron-up" or "chevron-down", variant = "ghost", controlSize = "sm",
                    tooltip = noctalia.tr(expanded and "ui.chat_collapse_output" or "ui.chat_expand_output"),
                    onClick = function() activity_expanded[key] = not expanded; update() end }),
            }),
            ui.label({ text = tostring(event.text or ""), maxLines = 2, maxWidth = 520 }),
            expanded and ui.label({ text = detail, color = "on_surface_variant",
                maxLines = math.max(4, lines + 1), maxWidth = 520 }) or ui.label({ text = "" }),
        }))
    end
    return ui.scroll({ key = "desktop-activity", flexGrow = 1, gap = 6 }, rows)
end

local function attachments_supported()
    return not capabilities_negotiated or chat_capabilities.attachments == true
end

local function add_attachments(action)
    if not chat_writable() or not attachments_supported() or attachment_busy then return end
    attachment_busy = true
    chat_error = nil
    update()
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
        update()
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
                onClick = function() table.remove(chat_attachments, index); update() end }),
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
            color = "on_surface_variant", fontSize = 11, maxLines = 2, maxWidth = 400,
        })
    end
    return labels
end

local function requests_writable()
    return configured_bool("chat_enabled", true) and chat_selected
        and not chat_terminal_owns_session
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
        update()
        return
    end
    state.submitting = true
    state.error = nil
    update()
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
        update()
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
                                    update()
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
                            key = "desktop-request-" .. key .. "-" .. name, options = labels, selectedIndex = selected,
                            width = 320, enabled = not state.submitting,
                            onChange = function(index, text)
                                local choice = select_option(labels, index, text)
                                if choice > 1 then state.values[name] = options[choice - 1].value
                                else state.values[name] = nil end
                                update()
                            end,
                        }))
                    else
                        table.insert(rows, ui.input({
                            key = "desktop-request-" .. key .. "-" .. name, width = 320,
                            value = tostring(state.values[name] or ""), enabled = not state.submitting,
                            onChange = function(value) state.values[name] = tostring(value or "") end,
                        }))
                    end
                end
                table.insert(rows, ui.row({ gap = 4 }, {
                    ui.button({ text = noctalia.tr("ui.request_submit"), variant = "primary", enabled = not state.submitting,
                        onClick = function()
                            local content, error = question_content(request, state)
                            if error ~= nil then state.error = error; update(); return end
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
            table.insert(cards, ui.column({ key = "desktop-request-" .. key, gap = 4,
                paddingH = 10, paddingV = 8, radius = 8, fill = "secondary/0.10" }, rows))
        end
    end
    local acknowledged = request_history[#request_history]
    if type(acknowledged) == "table" and acknowledged.status == "responded" then
        table.insert(cards, ui.column({ key = "desktop-request-ack", gap = 2,
            paddingH = 10, paddingV = 6, radius = 8, fill = "primary/0.10" }, {
            ui.label({ text = noctalia.tr("ui.request_acknowledged"), color = "secondary", maxLines = 2 }),
            ui.label({ text = tostring(acknowledged.title or ""), color = "on_surface_variant",
                fontSize = 11, maxLines = 1 }),
        }))
    end
    return cards
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
                    update()
                end }),
            ui.label({ text = available and tostring(harness.auth_status or noctalia.tr("ui.harness_auth_local"))
                    or tostring(harness.install_hint or noctalia.tr("ui.harness_unavailable")),
                color = "on_surface_variant", fontSize = 11, maxLines = 3 }),
        })
    end
    return ui.column({ width = 340, height = 140 }, {
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
                key = "desktop-chat-model-" .. tostring(chat_new_harness) .. "-" .. tostring(chat_model_input_revision),
                width = 304,
                value = chat_new_model or "",
                placeholder = noctalia.tr("ui.chat_model_placeholder"),
                enabled = not chat_busy and selected_harness() ~= nil and selected_harness().available ~= false,
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
                enabled = not chat_busy and selected_harness() ~= nil and selected_harness().available ~= false and #options > 0,
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
    desktopWidget.setNeedsFrameTick(needs_orb_animation())
    update()
end

local function load_chat()
    if not configured_bool("chat_enabled", true) or chat_busy then return end
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
    if not chat_writable() or attachment_busy or (message == "" and #chat_attachments == 0) then return end
    if #chat_attachments > 0 and not attachments_supported() then return end
    local command = {"python3", chat_bridge, "send", hex_encode(message)}
    if #chat_attachments > 0 then
        local paths = {}
        for _, attachment in ipairs(chat_attachments) do paths[#paths + 1] = attachment.path end
        local encoded, error = noctalia.json.encode(paths)
        if encoded == nil then chat_error = tostring(error or noctalia.tr("ui.chat_error")); update(); return end
        command[#command + 1] = hex_encode(encoded)
    end
    chat_busy = true
    chat_error = nil
    update()
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
    if not configured_bool("chat_enabled", true) or selected_harness() == nil or selected_harness().available == false then return end
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
    if not configured_bool("chat_enabled", true) or chat_busy then return end
    chat_busy = true
    chat_error = nil
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
    if not configured_bool("chat_enabled", true) or chat_busy then return end
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
        update()
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
        local available = target.available ~= false and (target.resumable == true or target.forkable == true)
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
            harness_picker(),
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
        ui.column({ gap = 2 }, attachment_labels(event.attachments)),
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
                ui.column({ gap = 2 }, attachment_labels(message.attachments)),
            }))
        end
    end
    for _, card in ipairs(request_cards()) do table.insert(transcript, card) end
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
    local monitored_item = nil
    local monitored_id = chat_session_harness == "hermes" and "hermes:" .. tostring(chat_session_id) or chat_session_id
    for _, item in ipairs(sessions.sessions or {}) do
        if item.id == monitored_id then monitored_item = item; break end
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
            focus_button(monitored_item) or ui.label({ text = "" }),
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
        attachment_controls(),
        ui.row({ gap = 6, align = "center" }, {
            ui.input({
                key = "chat-input-" .. tostring(chat_input_revision),
                width = 340,
                value = chat_draft,
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
                enabled = chat_writable() and (chat_draft:match("%S") ~= nil
                    or (#chat_attachments > 0 and attachments_supported())),
                onClick = function() submit_chat(chat_draft) end,
            }),
        }),
    })
end


local function session_row(item, show_task)
    local presentation = configured_bool("presentation_mode", false)
    local details = {
        ui.label({
            text = display_label(item),
            fontWeight = "bold",
            color = presentation and "on_surface" or nil,
            maxLines = presentation and 3 or 1,
        }),
    }
    if show_task and item.task and item.task ~= "" then
        table.insert(details, ui.label({
            text = tostring(item.task),
            color = "primary",
            maxLines = presentation and 3 or 1,
        }))
    end
    table.insert(details, ui.label({
        text = state_description(item),
        color = presentation and "on_surface" or "on_surface_variant",
        maxLines = presentation and 2 or 1,
    }))
    local row = {
        Orb.render({ state = state_of(item), size = 20, time = animation_time() }),
        ui.column({ gap = 2, flexGrow = 1 }, details),
        ui.label({
            text = attention_label(item),
            color = attention_color(item),
        }),
    }
    local actions = proposal_actions(item)
    if actions then table.insert(row, actions) end
    local focus = focus_button(item)
    if focus ~= nil then table.insert(row, focus) end
    table.insert(row, ui.button({ glyph = "activity", glyphSize = 14, variant = "ghost", controlSize = "sm",
        tooltip = noctalia.tr("ui.activity_title"), onClick = function() open_activity(item) end }))
    return ui.row({
        gap = 8,
        align = "center",
        paddingV = presentation and 6 or 2,
        paddingH = presentation and 6 or nil,
        radius = presentation and 8 or nil,
        fill = presentation and "surface" or nil,
    }, row)
end

local function render()
    local active = tonumber(sessions.active) or 0
    local show_task = configured_bool("show_task", true)
    local presentation = configured_bool("presentation_mode", false)
    local children = {}
    local items = sessions.sessions or {}
    local header_icon
    if #items > 0 then
        header_icon = Orb.render({ state = state_of(items[1]), size = 20, time = animation_time() })
    else
        header_icon = ui.glyph({ name = "sparkles", size = 18, color = "secondary" })
    end
    local header = {
        header_icon,
        ui.label({
            text = noctalia.trp("ui.active_agents", active),
            fontWeight = "bold",
            color = presentation and "on_surface" or nil,
            flexGrow = 1,
            maxLines = presentation and 2 or 1,
        }),
    }
    table.insert(header, ui.button({ text = noctalia.tr("ui.activity_title"), variant = "ghost",
        controlSize = "sm", selected = activity_open,
        onClick = function()
            activity_open = not activity_open
            if activity_open then chat_open = false; poll_activity(true) end
            update()
        end }))
    if configured_bool("chat_enabled", true) then
        table.insert(header, ui.button({
            text = chat_open and noctalia.tr("ui.chat_close") or noctalia.tr("ui.chat_open"),
            variant = chat_open and "secondary" or (presentation and "primary" or "ghost"),
            controlSize = "sm",
            onClick = function()
                chat_open = not chat_open
                if chat_open then activity_open = false end
                if chat_open then load_chat() end
                update()
            end,
        }))
    end
    table.insert(children, ui.row({ gap = 8, align = "center", paddingV = 4 }, header))
    if #items == 0 then
        table.insert(children, ui.label({
            text = noctalia.tr("ui.no_sessions"),
            color = presentation and "on_surface" or "on_surface_variant",
        }))
    else
        for i = 1, #items do
            table.insert(children, session_row(items[i], show_task))
        end
    end
    if chat_open and configured_bool("chat_enabled", true) then
        table.insert(children, chat_view())
    end
    if activity_open then table.insert(children, activity_view()) end
    if focus_error ~= nil then
        table.insert(children, ui.label({ text = focus_error, color = "error", maxLines = 3 }))
    end
    desktopWidget.render(ui.column({ gap = 2, padding = 6 }, children))
end
function update()
    if activity_open then poll_activity(false) end
    frame = frame_index()
    local active = tonumber(sessions.active) or 0
    noctalia.setUpdateInterval((activity_open or chat_busy or (chat_open and chat_selected) or active > 0) and 1000 or 5000)
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
    noctalia.setUpdateInterval((activity_open or chat_busy or active > 0) and 1000 or 5000)
    desktopWidget.setNeedsFrameTick(needs_orb_animation())
    frame = frame_index()
    render()
end)


noctalia.state.watch("agentik_chat_status", function(result)
    if type(result) == "table" then apply_chat_status(result) end
end)

if needs_orb_animation() then frame = frame_index() end
desktopWidget.setNeedsFrameTick(needs_orb_animation())
render()
