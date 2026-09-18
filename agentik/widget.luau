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
local function configured_bool(key, default)
    local value = noctalia.getConfig(key)
    if value == nil then return default end
    return value == true or value == "true"
end
local sessions = noctalia.state.get("sessions") or { active = 0, sessions = {} }
local frame = 0
local attention_initialized = false
local attention_by_session = {} -- id -> attention for sessions currently listed
local last_attention = {}       -- id -> last attention seen; survives drop-out
local last_seen_at = {}         -- id -> nowMs() of last sighting (TTL pruning)
local COOLDOWN_KEY = "agentik.notify_until"
local REAPPEAR_WINDOW_MS = 10 * 60 * 1000
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
local STATE_PERIOD_MS = STATE_HOLD_MS + 2 * STATE_FADE_MS

local PROGRESS_TRANSITION_MS = 300
local PROGRESS_FADE_MS = 200
local PROGRESS_FRAME_SUBSTEPS = 30
local progress_from = nil
local progress_to = nil
local progress_transition_at = 0
local progress_fade_in_at = nil
local progress_fade_out_at = nil

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
    if #agents == 0 then table.insert(agents, { state = "working", number = 1 }) end
    return agents
end

local function has_done_session()
    for _, item in ipairs(sessions.sessions or {}) do
        if item.exited ~= nil then return true end
    end
    return false
end

local function has_animated_session()
    if configured_bool("reduce_motion", false) then return false end
    return #(sessions.sessions or {}) > 0
end

local function quiet_session()
    for _, item in ipairs(sessions.sessions or {}) do
        if item.exited == nil and item.quiet == true then return item end
    end
    return nil
end

local function current_agent(agents)
    local choice_agents = {}
    for _, agent in ipairs(agents) do
        local item = agent.item
        local attention = item and item.attention
        if item
            and (attention == "blocked" or attention == "waiting")
            and type(item.propositions) == "table"
            and #item.propositions > 0
        then
            table.insert(choice_agents, agent)
        end
    end
    if #choice_agents > 0 then agents = choice_agents end
    if #agents == 1 then return agents[1], 1 end

    local now = noctalia.nowMs()
    local phase = now % STATE_PERIOD_MS
    local index = math.floor(now / STATE_PERIOD_MS) % #agents + 1
    if phase < STATE_HOLD_MS then return agents[index], 1 end
    if phase < STATE_HOLD_MS + STATE_FADE_MS then
        return agents[index], 1 - (phase - STATE_HOLD_MS) / STATE_FADE_MS
    end
    local next_index = index % #agents + 1
    return agents[next_index], (phase - STATE_HOLD_MS - STATE_FADE_MS) / STATE_FADE_MS
end

local function frame_index()
    if configured_bool("reduce_motion", false) then return 0 end
    return math.floor(noctalia.nowMs() * FRAME_RATE / 1000) % FRAME_COUNT
end

local function done_frame_index()
    if configured_bool("reduce_motion", false) then return 0 end
    return math.floor(noctalia.nowMs() * FRAME_RATE / 1000) % FRAME_COUNT
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

local function progress_path(value)
    local frame = math.floor(clamp(value, 0, 8) * PROGRESS_FRAME_SUBSTEPS + 0.5)
    return ORB_DIR .. "/progress-transition-" .. tostring(frame) .. ".svg"
end

local function orb_path(state, attention, index)
    if attention == "blocked" or attention == "waiting" then
        return ORB_DIR .. "/" .. state .. "-" .. attention .. "-20-" .. tostring(index) .. ".svg"
    end
    return ORB_DIR .. "/" .. state .. "-20-" .. tostring(index) .. ".svg"
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

local function choice_needed(item)
    return item ~= nil
        and attention_of(item) ~= "active"
        and type(item.propositions) == "table"
        and #item.propositions > 0
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
    for id, seen_at in pairs(last_seen_at) do
        if now - seen_at > REAPPEAR_WINDOW_MS then
            last_attention[id] = nil
            last_seen_at[id] = nil
        end
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
    local agents = active > 0 and active_agents() or nil
    local agent = nil
    local state_opacity = 1
    if agents ~= nil then agent, state_opacity = current_agent(agents) end
    local item = agent and agent.item or nil
    local choice = choice_needed(item)
    local state = agent and agent.state or nil
    local quiet = agents == nil and quiet_session() or nil
    local display_state = state or (quiet and (valid_states[quiet.state] and quiet.state or "working")) or nil
    local displayed_number = agent and agent.number or active
    local displayed_progress, progress_opacity = sync_progress(
        show_intent and progress_step(item or quiet) or nil
    )
    local children = {}
    if agents ~= nil and display_state ~= nil then
        local attention = configured_bool("show_attention", true) and attention_of(item) or "active"
        table.insert(children, orb_image({
            path = orb_path(display_state, attention, frame),
            width = 20,
            height = 20,
            opacity = state_opacity,
        }))
    elseif quiet ~= nil then
        table.insert(children, orb_image({
            path = orb_path(display_state, "active", frame),
            width = 20,
            height = 20,
            opacity = 0.55,
        }))
    elseif has_done_session() then
        local path = ORB_DIR .. "/done-20-" .. tostring(done_frame_index()) .. ".svg"
        table.insert(children, orb_image({ path = path, width = 20, height = 20 }))
    else
        table.insert(children, ui.glyph({ name = "sparkles", size = 18, color = "secondary" }))
    end
    if show_count and not compact and active > 0 then
        table.insert(children, ui.label({
            text = tostring(displayed_number),
            color = active > 0 and "primary" or "secondary",
            opacity = state_opacity,
            fontWeight = "bold",
        }))
    end
    if display_state ~= nil and show_intent then
        if not compact then
            local state_text = quiet ~= nil
                and noctalia.tr("ui.idle", { time = elapsed(quiet.idle) })
                or pill_state_label(item, display_state)
            table.insert(children, ui.label({
                key = "current-state",
                text = state_text,
                opacity = state_opacity,
                maxWidth = 96,
                maxLines = 1,
            }))
        end
    end
    if displayed_progress ~= nil then
        table.insert(children, orb_image({
            path = progress_path(displayed_progress),
            width = 20,
            height = 20,
            opacity = state_opacity * progress_opacity,
        }))
    end
    if choice then
        table.insert(children, ui.label({
            key = "choice-needed",
            text = noctalia.tr("ui.choice_needed"),
            color = attention_of(item) == "blocked" and "error" or "secondary",
            opacity = state_opacity,
            maxLines = 1,
        }))
    end

    local tooltip = quiet ~= nil
        and noctalia.tr("ui.idle", { time = elapsed(quiet.idle) })
        or noctalia.trp("ui.active_agents", active)
    local progress = progress_text(item or quiet)
    if progress ~= nil then tooltip = tooltip .. " · " .. progress end
    if choice then tooltip = tooltip .. " · " .. noctalia.tr("ui.choice_needed") end
    barWidget.setTooltip(tooltip)
    local container = compact and ui.column or ui.row
    barWidget.render(container({
        gap = compact and 3 or 5,
        align = "center",
    }, children))
end

local function set_update_interval()
    local animated = not configured_bool("reduce_motion", false)
        and ((tonumber(sessions.active) or 0) > 0 or has_animated_session() or progress_is_animating())
    noctalia.setUpdateInterval(animated and math.floor(1000 / FRAME_RATE) or 1000)
end

function update()
    if has_animated_session() then frame = frame_index() end
    render()
    set_update_interval()
end

noctalia.state.watch("sessions", function(value)
    sessions = value or { active = 0, sessions = {} }
    notify_attention_transitions(sessions)
    if has_animated_session() then frame = frame_index() end
    render()
    set_update_interval()
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
    render()
    set_update_interval()
end)

render()
set_update_interval()
notify_attention_transitions(sessions)

function onClick()
    noctalia.togglePanel("notfinaldev/agentik:session-panel")
end
