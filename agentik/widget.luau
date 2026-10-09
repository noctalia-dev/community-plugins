local Orb = require("./orb.luau")
local FRAME_RATE = 60
local function configured_bool(key, default)
    local value = noctalia.getConfig(key)
    if value == nil then return default end
    return value == true or value == "true"
end
local sessions = noctalia.state.get("sessions") or { active = 0, sessions = {} }
local pinned_session = noctalia.state.get("agentik.pinned_session")
local pinned_item = nil
local blocked_count, waiting_count = 0, 0
local monitor_health = noctalia.state.get("agentik.monitor_health") or { status = "pending" }
local attention_initialized = false
local attention_by_session = {} -- id -> attention for sessions currently listed
local last_attention = {}       -- id -> last attention seen; survives drop-out
local last_seen_at = {}         -- id -> nowMs() of last sighting (TTL pruning)
local COOLDOWN_KEY = "agentik.notify_until"
local REAPPEAR_WINDOW_MS = 10 * 60 * 1000
local ATTENTION_EXPANSION_MS = 8000
local attention_expansion_item = nil
local attention_expansion_until = 0
local ATTENTION_TRANSITION_MS = 180
local expansion_from, expansion_to = 0, 0
local expansion_started_at = 0
local expansion_display_item = nil
local COMPLETION_MOMENT_MS = 3000
local completion_initialized = false
local completion_by_session = {}
local completion_until = 0
local function cooldown_until()
    return tonumber(noctalia.state.get(COOLDOWN_KEY)) or 0
end
local valid_states = {
    working = true, searching = true, solving = true, listening = true, connecting = true,
    weaving = true, composing = true, breathing = true, shaping = true, done = true,
}

local function state_label(state)
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

local STATE_HOLD_MS = 2000
local STATE_FADE_MS = 250
local rotating_id = nil
local rotation_started_at = nil

local PROGRESS_TRANSITION_MS = 300
local PROGRESS_FADE_MS = 200
local progress_from = nil
local progress_to = nil
local progress_transition_at = 0
local progress_fade_in_at = nil
local progress_fade_out_at = nil

local function agent_identity(item)
    return tostring(item.id or item.cwd or item.project or "")
end

local function active_agents()
    local agents = {}
    for _, item in ipairs(sessions.sessions or {}) do
        if item.exited == nil and item.quiet ~= true then
            table.insert(agents, {
                item = item,
                state = valid_states[item.state] and item.state or "working",
                number = #agents + 1,
            })
        end
    end
    table.sort(agents, function(a, b)
        return agent_identity(a.item) < agent_identity(b.item)
    end)
    for index, agent in ipairs(agents) do agent.number = index end
    if #agents == 0 then table.insert(agents, { state = "working", number = 1 }) end
    return agents
end

local function has_animated_session()
    if configured_bool("reduce_motion", false) then return false end
    if noctalia.nowMs() < completion_until then return true end
    for _, item in ipairs(sessions.sessions or {}) do
        if item.exited == nil then return true end
    end
    return false
end

local function quiet_session()
    for _, item in ipairs(sessions.sessions or {}) do
        if item.exited == nil and item.quiet == true then return item end
    end
    return nil
end

local function current_agent(agents)
    if pinned_item ~= nil then
        for _, agent in ipairs(agents) do
            if agent.item and agent.item.id == pinned_session then return agent, 1 end
        end
        return {
            item = pinned_item,
            state = valid_states[pinned_item.state] and pinned_item.state or "working",
            number = 0,
        }, 1
    end
    local choice_agents = {}
    for _, agent in ipairs(agents) do
        local item = agent.item
        if item and (item.attention == "blocked" or item.attention == "waiting") then
            table.insert(choice_agents, agent)
        end
    end
    if #choice_agents > 0 then agents = choice_agents end
    local now = noctalia.nowMs()
    local index = 1
    local found = false
    for candidate, agent in ipairs(agents) do
        if agent.item and agent_identity(agent.item) == rotating_id then
            index = candidate
            found = true
            break
        end
    end
    if not found or rotation_started_at == nil then
        rotating_id = agents[index].item and agent_identity(agents[index].item) or nil
        rotation_started_at = now
    end
    if #agents == 1 then
        rotation_started_at = now
        return agents[index], 1
    end
    local hold = configured_bool("presentation_mode", false) and 5000 or STATE_HOLD_MS
    if configured_bool("reduce_motion", false) then return agents[index], 1 end
    local fade = STATE_FADE_MS
    local phase = now - rotation_started_at
    if phase >= hold + 2 * fade then
        index = index % #agents + 1
        rotating_id = agents[index].item and agent_identity(agents[index].item) or nil
        rotation_started_at = now
        return agents[index], 1
    end
    if phase < hold then return agents[index], 1 end
    if phase < hold + fade then
        return agents[index], 1 - (phase - hold) / fade
    end
    return agents[index % #agents + 1], (phase - hold - fade) / fade
end

local function animation_time()
    if configured_bool("reduce_motion", false) then return 0 end
    return noctalia.nowMs() / 1000 * (configured_bool("presentation_mode", false) and 0.5 or 1)
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

local function progress_step(item)
    local completed = tonumber(item and item.todo_completed)
    local total = tonumber(item and item.todo_total)
    if item == nil or item.todo_active ~= true or completed == nil or total == nil or total <= 0 then return nil end
    return math.max(0, math.min(8, math.floor(completed / total * 8 + 0.5)))
end

local function progress_text(item)
    local completed = tonumber(item and item.todo_completed)
    local total = tonumber(item and item.todo_total)
    if item == nil or item.todo_active ~= true or completed == nil or total == nil or total <= 0 then return nil end
    return noctalia.tr("ui.todo_progress", { completed = completed, total = total })
end

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function smoothstep(value)
    value = clamp(value, 0, 1)
    return value * value * (3 - 2 * value)
end

local function displayed_progress(now)
    if progress_from == nil or progress_to == nil then return nil end
    local elapsed = now - progress_transition_at
    if elapsed >= PROGRESS_TRANSITION_MS then return progress_to end
    return progress_from + (progress_to - progress_from) * smoothstep(elapsed / PROGRESS_TRANSITION_MS)
end

local function sync_progress(requested)
    local now = noctalia.nowMs()
    if configured_bool("reduce_motion", false) then
        progress_from = requested
        progress_to = requested
        progress_transition_at = now - PROGRESS_TRANSITION_MS
        progress_fade_in_at = now - PROGRESS_FADE_MS
        progress_fade_out_at = nil
        return requested, requested ~= nil and 1 or 0
    end
    if requested ~= nil then
        if progress_to == nil or progress_fade_out_at ~= nil then
            progress_from = requested
            progress_to = requested
            progress_transition_at = now
            progress_fade_in_at = now
            progress_fade_out_at = nil
        elseif requested ~= progress_to then
            progress_from = displayed_progress(now)
            progress_to = requested
            progress_transition_at = now
        end
    elseif progress_to ~= nil then
        if progress_fade_out_at == nil then
            local current = displayed_progress(now)
            progress_from = current
            progress_to = current
            progress_transition_at = now
            progress_fade_out_at = now
        elseif now - progress_fade_out_at >= PROGRESS_FADE_MS then
            progress_from = nil
            progress_to = nil
            progress_fade_in_at = nil
            progress_fade_out_at = nil
            return nil, 0
        end
    end

    local opacity
    if progress_to == nil then
        opacity = 0
    elseif progress_fade_out_at ~= nil then
        opacity = 1 - clamp((now - progress_fade_out_at) / PROGRESS_FADE_MS, 0, 1)
    else
        opacity = clamp((now - progress_fade_in_at) / PROGRESS_FADE_MS, 0, 1)
    end
    return displayed_progress(now), opacity
end

local function progress_is_animating()
    if configured_bool("reduce_motion", false) then return false end
    if progress_to == nil then return false end
    local now = noctalia.nowMs()
    return now - progress_transition_at < PROGRESS_TRANSITION_MS
        or (progress_fade_in_at ~= nil and now - progress_fade_in_at < PROGRESS_FADE_MS)
        or (progress_fade_out_at ~= nil and now - progress_fade_out_at < PROGRESS_FADE_MS)
end


local function attention_of(item)
    local attention = item and item.attention
    if attention == "waiting" or attention == "blocked" then return attention end
    return "active"
end

local function pill_state_label(item, state)
    local attention = attention_of(item)
    if attention == "blocked" then return noctalia.tr("ui.attention_blocked") end
    if attention == "waiting" then return noctalia.tr("ui.attention_waiting") end
    return state_label(state)
end

local function pill_tone(item, state)
    local attention = attention_of(item)
    if attention == "blocked" then return "error" end
    if attention == "waiting" then return "secondary" end
    if state == "searching" or state == "connecting" then return "secondary" end
    if state == "breathing" then return "on_surface_variant" end
    return "primary"
end

local function choice_needed(item)
    return item ~= nil
        and attention_of(item) ~= "active"
        and type(item.propositions) == "table"
        and #item.propositions > 0
end

local function attention_expansion_active()
    return attention_expansion_item ~= nil and noctalia.nowMs() < attention_expansion_until
end

local function monitor_status()
    if monitor_health.status == "error" then return "error" end
    local last_success = tonumber(monitor_health.last_success_ms)
    if last_success ~= nil
        and noctalia.nowMs() - last_success > (tonumber(monitor_health.stale_after_ms) or 15000)
    then
        return "stale"
    end
    return last_success ~= nil and "ok" or "pending"
end

local function refresh_session_summary()
    blocked_count, waiting_count = 0, 0
    pinned_item = nil
    for _, item in ipairs(sessions.sessions or {}) do
        if item.exited == nil then
            if item.id == pinned_session then pinned_item = item end
            local attention = attention_of(item)
            if attention == "blocked" then blocked_count = blocked_count + 1 end
            if attention == "waiting" then waiting_count = waiting_count + 1 end
        end
    end
    if pinned_session ~= nil and pinned_item == nil and monitor_status() == "ok" then
        pinned_session = nil
        noctalia.state.set("agentik.pinned_session", nil)
    end
end

local function expansion_value(now)
    local fraction = smoothstep((now - expansion_started_at) / ATTENTION_TRANSITION_MS)
    return expansion_from + (expansion_to - expansion_from) * fraction
end

local function sync_expansion(requested)
    local now = noctalia.nowMs()
    local target = requested and 1 or 0
    if requested then expansion_display_item = attention_expansion_item end
    if configured_bool("reduce_motion", false) then
        expansion_from, expansion_to = target, target
        expansion_started_at = now - ATTENTION_TRANSITION_MS
    elseif target ~= expansion_to then
        expansion_from = expansion_value(now)
        expansion_to = target
        expansion_started_at = now
    end
    local value = expansion_value(now)
    if target == 0 and value <= 0 then expansion_display_item = nil end
    return value
end

local function expansion_is_animating()
    return not configured_bool("reduce_motion", false)
        and expansion_from ~= expansion_to
        and noctalia.nowMs() - expansion_started_at < ATTENTION_TRANSITION_MS
end

local function completion_moment_active()
    return noctalia.nowMs() < completion_until
end

local function observe_completions(value)
    local current = {}
    local now = noctalia.nowMs()
    for _, item in ipairs(value.sessions or {}) do
        local id = tostring(item.id or "")
        if id ~= "" then
            local completed = item.status == "completed"
                or (item.exited ~= nil and item.status ~= "failed" and item.status ~= "cancelled")
            current[id] = completed
            if completion_initialized and completed and completion_by_session[id] == false then
                completion_until = now + COMPLETION_MOMENT_MS
            end
        end
    end
    completion_by_session = current
    completion_initialized = true
end

local function notify_attention_transitions(value)
    local current = {}
    local transitions = {}
    local now = noctalia.nowMs()
    for _, item in ipairs(value.sessions or {}) do
        local id = tostring(item.id or "")
        if id ~= "" and item.exited == nil then
            local attention = attention_of(item)
            local previous = attention_by_session[id]
            local last = last_attention[id]
            current[id] = attention
            last_attention[id] = attention
            last_seen_at[id] = now
            if attention_initialized and attention ~= "active" then
                if (previous ~= nil and previous ~= attention) or (previous == nil and last ~= nil) then
                    -- ordinary transition, or a session that dropped out and
                    -- reappeared still needing attention
                    table.insert(transitions, item)
                end
            end
        end
    end
    attention_by_session = current
    if attention_expansion_item ~= nil then
        local expanded_id = tostring(attention_expansion_item.id or "")
        if current[expanded_id] == nil or current[expanded_id] == "active" then
            attention_expansion_item = nil
        else
            for _, item in ipairs(value.sessions or {}) do
                if tostring(item.id or "") == expanded_id then
                    attention_expansion_item = item
                    break
                end
            end
        end
    end
    for id, seen_at in pairs(last_seen_at) do
        if now - seen_at > REAPPEAR_WINDOW_MS then
            last_attention[id] = nil
            last_seen_at[id] = nil
        end
    end

    if #transitions > 0 then
        attention_expansion_item = transitions[1]
        attention_expansion_until = now + ATTENTION_EXPANSION_MS
    end

    local cooldown_seconds = tonumber(noctalia.getConfig("notification_cooldown_seconds")) or 300
    if attention_initialized
        and configured_bool("notify_attention", false)
        and now >= cooldown_until()
        and #transitions > 0
    then
        local count = #transitions
        local title
        if count == 1 then
            title = attention_of(transitions[1]) == "blocked"
                and noctalia.tr("ui.toast_blocked")
                or noctalia.tr("ui.toast_waiting")
        else
            title = noctalia.trp("ui.toast_attention", count)
        end
        local body
        if configured_bool("notification_privacy", false) then
            local blocked = 0
            local waiting = 0
            for _, item in ipairs(transitions) do
                if attention_of(item) == "blocked" then
                    blocked = blocked + 1
                else
                    waiting = waiting + 1
                end
            end
            local parts = {}
            if blocked > 0 then table.insert(parts, noctalia.trp("ui.blocked_count", blocked)) end
            if waiting > 0 then table.insert(parts, noctalia.trp("ui.waiting_count", waiting)) end
            body = table.concat(parts, ", ")
        else
            local parts = {}
            for i = 1, math.min(count, 3) do
                local item = transitions[i]
                table.insert(parts, tostring(item.project or "terminal")
                    .. ": " .. tostring(item.task or item.activity or noctalia.tr("ui.attention_required")))
            end
            body = table.concat(parts, ", ")
            if count > 3 then body = body .. noctalia.trp("ui.more", count - 3) end
        end
        noctalia.notify(title, body)
        local cooldown_ms = math.max(30, math.min(3600, cooldown_seconds)) * 1000
        noctalia.state.set(COOLDOWN_KEY, now + cooldown_ms)
    end
    attention_initialized = true
end

local function render()
    local active = tonumber(sessions.active) or 0
    local show_count = configured_bool("show_count", true)
    local show_intent = configured_bool("show_intent", true)
    local compact = barWidget.isVertical()
    local expansion_requested = not compact and configured_bool("show_attention", true)
        and attention_expansion_active()
        and (pinned_item == nil or attention_expansion_item.id == pinned_item.id)
    local expansion_progress = sync_expansion(expansion_requested)
    local expanded_attention = expansion_progress > 0 and expansion_display_item ~= nil
    local health_status = monitor_status()
    local orb_time = health_status == "ok" and animation_time() or 0
    local agents = (active > 0 or pinned_item ~= nil) and active_agents() or nil
    local agent = nil
    local state_opacity = 1
    if agents ~= nil then agent, state_opacity = current_agent(agents) end
    if expanded_attention and pinned_item == nil and agents ~= nil then
        for _, candidate in ipairs(agents) do
            if candidate.item and candidate.item.id == expansion_display_item.id then
                agent, state_opacity = candidate, 1
                break
            end
        end
    end
    local item = agent and agent.item or nil
    local choice = choice_needed(item)
    local state = agent and agent.state or nil
    local quiet = item ~= nil and item.quiet == true and item
        or (agents == nil and quiet_session() or nil)
    local display_state = state or (quiet and (valid_states[quiet.state] and quiet.state or "working")) or nil
    local displayed_number = agent and agent.number or active
    local displayed_progress, progress_opacity = sync_progress(
        show_intent and progress_step(item or quiet) or nil
    )
    local tone = pill_tone(item or quiet, display_state)
    local completion_moment = not compact and completion_moment_active()
    local children = {}
    if agents ~= nil and display_state ~= nil then
        local attention = configured_bool("show_attention", true) and attention_of(item) or "active"
        local orb_size = math.floor(16 + 4 * state_opacity + 0.5)
        table.insert(children, ui.column({ width = 20, height = 20, align = "center", justify = "center" }, {
            Orb.render({
                state = display_state, attention = attention,
                size = orb_size, time = orb_time, opacity = state_opacity,
            }),
        }))
    elseif quiet ~= nil then
        table.insert(children, Orb.render({
            state = display_state, size = 20, time = orb_time, opacity = 0.55,
        }))
    elseif completion_moment then
        table.insert(children, Orb.render({ state = "done", size = 20, time = orb_time }))
    else
        table.insert(children, ui.glyph({ name = "sparkles", size = 18, color = "secondary" }))
    end
    if display_state ~= nil and not compact then
        table.insert(children, ui.label({
            key = "state-marker",
            text = "•",
            color = (item or quiet) and (item or quiet).accent or tone,
            opacity = 1,
            fontWeight = "bold",
        }))
    end
    if pinned_item ~= nil then
        table.insert(children, ui.glyph({ key = "pinned-session", name = "pin", size = 12,
            color = pinned_item.accent or "primary" }))
        if not compact then
            table.insert(children, ui.label({ key = "pinned-identity",
                text = configured_bool("notification_privacy", false)
                    and noctalia.tr("ui.pinned_session") or tostring(pinned_item.project or "terminal"),
                maxWidth = 96, maxLines = 1, color = pinned_item.accent or "primary" }))
        end
    end
    if show_count and not compact and active > 0 and pinned_item == nil then
        table.insert(children, ui.label({
            text = tostring(displayed_number),
            color = tone,
            opacity = state_opacity,
            fontWeight = "bold",
        }))
    end
    if display_state ~= nil and show_intent and not expanded_attention then
        if not compact then
            local state_text = quiet ~= nil
                and noctalia.tr("ui.idle", { time = elapsed(quiet.idle) })
                or pill_state_label(item, display_state)
            table.insert(children, ui.label({
                key = "current-state",
                text = state_text,
                color = tone,
                opacity = state_opacity,
                maxWidth = configured_bool("presentation_mode", false) and 160 or 96,
                maxLines = 1,
            }))
        end
    end
    if displayed_progress ~= nil and not expanded_attention then
        table.insert(children, Orb.progress({
            value = displayed_progress / 8, size = 20,
            opacity = state_opacity * progress_opacity,
        }))
    end
    if choice and not expanded_attention then
        table.insert(children, ui.label({
            key = "choice-needed",
            text = noctalia.tr("ui.choice_needed"),
            color = attention_of(item) == "blocked" and "error" or "secondary",
            opacity = state_opacity,
            maxLines = 1,
        }))
    end
    if expanded_attention then
        local attention_item = expansion_display_item
        local private = configured_bool("notification_privacy", false)
        table.insert(children, ui.label({
            key = "attention-project",
            text = private and pill_state_label(attention_item, display_state)
                or tostring(attention_item.project or "terminal"),
            color = pill_tone(attention_item, display_state),
            fontWeight = "bold",
            maxWidth = math.max(1, math.floor((configured_bool("presentation_mode", false) and 120 or 72) * expansion_progress)),
            opacity = expansion_progress,
            maxLines = 1,
        }))
        if not private and configured_bool("show_task", true) then table.insert(children, ui.label({
            key = "attention-task",
            text = tostring(attention_item.task or attention_item.activity or noctalia.tr("ui.attention_required")),
            maxWidth = math.max(1, math.floor((configured_bool("presentation_mode", false) and 180 or 100) * expansion_progress)),
            opacity = expansion_progress,
            maxLines = 1,
        })) end
        table.insert(children, ui.label({
            key = "attention-open",
            text = noctalia.tr("ui.open_agentik"),
            color = "primary",
            opacity = expansion_progress,
            maxWidth = math.max(1, math.floor(110 * expansion_progress)),
            fontWeight = "bold",
            maxLines = 1,
        }))
    elseif completion_moment then
        table.insert(children, ui.label({
            key = "completion-moment",
            text = "✓ " .. noctalia.tr("ui.done"),
            color = "primary",
            opacity = configured_bool("reduce_motion", false) and 1
                or (0.75 + 0.25 * math.sin(noctalia.nowMs() / 160)),
            fontWeight = "bold",
            maxLines = 1,
        }))
    end
    if configured_bool("show_attention", true) then
        if blocked_count > 0 then
            table.insert(children, ui.row({ key = "blocked-count", gap = 2, align = "center" }, {
                ui.glyph({ name = "alert-triangle", size = 12, color = "error" }),
                ui.label({ text = tostring(blocked_count), color = "error", maxLines = 1 }),
            }))
        end
        if waiting_count > 0 then
            table.insert(children, ui.row({ key = "waiting-count", gap = 2, align = "center" }, {
                ui.glyph({ name = "clock", size = 12, color = "secondary" }),
                ui.label({ text = tostring(waiting_count), color = "secondary", maxLines = 1 }),
            }))
        end
    end
    if health_status ~= "ok" then
        table.insert(children, ui.glyph({ key = "monitor-warning",
            name = health_status == "pending" and "clock" or "alert-triangle",
            size = 14, color = health_status == "pending" and "on_surface_variant" or "error" }))
    end

    local tooltip = quiet ~= nil
        and noctalia.tr("ui.idle", { time = elapsed(quiet.idle) })
        or noctalia.trp("ui.active_agents", active)
    local progress = progress_text(item or quiet)
    if progress ~= nil then tooltip = tooltip .. " · " .. progress end
    if choice then tooltip = tooltip .. " · " .. noctalia.tr("ui.choice_needed") end
    if pinned_item ~= nil then tooltip = tooltip .. " · " .. noctalia.tr("ui.pinned_session") end
    if configured_bool("show_attention", true) then
        if blocked_count > 0 then tooltip = tooltip .. " · " .. noctalia.trp("ui.blocked_count", blocked_count) end
        if waiting_count > 0 then tooltip = tooltip .. " · " .. noctalia.trp("ui.waiting_count", waiting_count) end
    end
    if health_status ~= "ok" then
        tooltip = noctalia.tr("ui.monitor_" .. health_status)
        local last_success = tonumber(monitor_health.last_success_ms)
        if last_success ~= nil then
            tooltip = tooltip .. " · " .. noctalia.tr("ui.monitor_last_success", {
                time = elapsed((noctalia.nowMs() - last_success) / 1000),
            })
        end
        if type(monitor_health.error) == "string" then
            tooltip = tooltip .. " · " .. monitor_health.error
        end
    end
    barWidget.setTooltip(tooltip)
    local container = compact and ui.column or ui.row
    barWidget.render(container({
        key = "agentik-pill",
        gap = compact and 3 or 5,
        paddingH = compact and 2 or 5,
        paddingV = 2,
        radius = 10,
        fill = display_state ~= nil
            and (tone .. (configured_bool("presentation_mode", false) and "/0.24" or "/0.10"))
            or "surface_variant/0.10",
        align = "center",
    }, children))
end

local function set_update_interval()
    local animated = not configured_bool("reduce_motion", false)
        and ((tonumber(sessions.active) or 0) > 0 or has_animated_session()
            or progress_is_animating() or expansion_is_animating())
    noctalia.setUpdateInterval(animated and math.floor(1000 / FRAME_RATE) or 1000)
end

function update()
    render()
    set_update_interval()
end

noctalia.state.watch("sessions", function(value)
    sessions = value or { active = 0, sessions = {} }
    notify_attention_transitions(sessions)
    observe_completions(sessions)
    refresh_session_summary()
    render()
    set_update_interval()
end)


noctalia.state.watch("agentik.pinned_session", function(value)
    pinned_session = type(value) == "string" and value ~= "" and value or nil
    refresh_session_summary()
    render()
    set_update_interval()
end)

noctalia.state.watch("agentik.monitor_health", function(value)
    monitor_health = type(value) == "table" and value or { status = "pending" }
    render()
    set_update_interval()
end)

refresh_session_summary()
render()
set_update_interval()
notify_attention_transitions(sessions)
observe_completions(sessions)

function onClick()
    local attention_item = configured_bool("show_attention", true)
        and attention_expansion_active()
        and (pinned_item == nil or attention_expansion_item.id == pinned_item.id)
        and attention_expansion_item or nil
    noctalia.state.set("agentik.attention_target", attention_item and attention_item.id or nil)
    noctalia.state.set("agentik.open_attention", attention_item ~= nil)
    attention_expansion_item = nil
    render()
    set_update_interval()
    noctalia.togglePanel("notfinaldev/agentik:session-panel")
end
