-- OpenCode Companion — the chat panel surface.
--
-- Two views:
--   • Session chooser — when no active session is selected
--   — Session chat — when a session is active
--
-- Pure subscriber of opencode.* state. User actions are dispatched as IPC
-- events to the service.

local STATE = {
    connection = "opencode.connection",
    active = "opencode.active_session",
    sessions = "opencode.sessions",
    messages = "opencode.messages",
    permissions = "opencode.pending_permissions",
    questions = "opencode.pending_questions",
    mcp = "opencode.mcp_status",
    providers = "opencode.providers",
    agents = "opencode.agents",
    model_options = "opencode.model_options",
    agent_options = "opencode.agent_options",
    selected_model = "opencode.selected_model",
    selected_agent = "opencode.selected_agent",
    unread = "opencode.unread_count",
    last_error = "opencode.last_error",
}

-- Confirmation state for destructive actions (delete session).
local pending_delete = nil

-- The session the user most recently opened/selected. Kept so the chooser can
-- highlight it (single accent-colored row) even after the user backs out to the
-- session list. Synced from the active session on every render.
local last_opened_id = nil

-- Live filter text for the chooser's session search box (in-memory only).
local session_query = ""

-- Pending answer selections for multi-question agent requests. Keyed by
-- requestID -> { [question_index] = chosen_label }. A request with N questions
-- is only replied once every question has a selection, so a single-question
-- click never fires the reply before the others are answered.
local question_choices = {}

local SVC = "weinguyen/opencode-companion:service"
local PANEL_ID = "weinguyen/opencode-companion:panel"

-- Layout constants (recomputed from the ui_mode setting on every render).
local compact = false
local PAD = 14
local WRAP = 432  -- 560 - 2*PAD - scrollbar room
local GAP = 8
local GAP_SM = 4
local FONT_TITLE = 18
local FONT_BODY = 13
local FONT_SUB = 12
local CARD_PAD = 10
local CARD_RADIUS = 10
local BUBBLE_GAP = 4

-- Recompute layout metrics from the ui_mode setting. Called at the top of
-- render() so a settings change reflows the whole panel on the next frame.
local function apply_layout()
    compact = (noctalia.getConfig and noctalia.getConfig("ui_mode")) == "compact"
    if compact then
        PAD = 8
        GAP = 4
        GAP_SM = 2
        FONT_TITLE = 15
        FONT_BODY = 12
        FONT_SUB = 11
        CARD_PAD = 6
        CARD_RADIUS = 8
        BUBBLE_GAP = 2
    else
        PAD = 14
        GAP = 8
        GAP_SM = 4
        FONT_TITLE = 18
        FONT_BODY = 13
        FONT_SUB = 12
        CARD_PAD = 10
        CARD_RADIUS = 10
        BUBBLE_GAP = 4
    end
    WRAP = 560 - 2 * PAD - 100
end

-- Draft persistence key (in-memory only; survives panel close/open within same boot)
local draft = ""
-- Bumped after each successful send. The composer input is uncontrolled and only
-- seeds its text once per node instance, so clearing `draft` alone won't wipe the
-- on-screen text. Changing the input's key forces the reconciler to build a fresh
-- (empty) input, which is how we clear the field after sending.
local composer_seq = 0

local view = "session_chooser"
local snap_cache = {}  -- last rendered fingerprint
-- Forward declaration so chooser/chat closures can call render() to refresh
-- local-only UI state (e.g. delete confirmation) not held in shared state.
local render

-- Thinking indicator animation: cycle loader glyphs on each second tick while
-- the agent is processing (beta.7 has no animated spinner, so we rotate icons).
local thinking_frame = 0
local THINKING_GLYPHS = { "loader", "loader-2", "loader-3", "loader-quarter" }

-- Translation with an optional per-plugin language override.
--
-- noctalia.tr() always follows the global shell locale, so the plugin's
-- `language` setting cannot re-point it. When the user picks a specific
-- language we load the plugin's own bundled translations/<lang>.json (merged
-- over en.json) via noctalia.readFile — relative paths resolve against the
-- plugin dir — and resolve keys ourselves. "auto" delegates to noctalia.tr.
local i18n_cache = { lang = nil, table = nil }

local function load_lang_table(lang)
    if i18n_cache.lang == lang and i18n_cache.table then
        return i18n_cache.table
    end
    local merged = {}
    local function merge_file(path)
        local ok, content = pcall(noctalia.readFile, path)
        if not ok or type(content) ~= "string" or content == "" then return end
        local ok2, data = pcall(noctalia.json.decode, content)
        if not ok2 or type(data) ~= "table" then return end
        -- Deep-merge nested tables so <lang> overrides en per leaf key.
        local function deep(dst, src)
            for k, v in pairs(src) do
                if type(v) == "table" and type(dst[k]) == "table" then
                    deep(dst[k], v)
                else
                    dst[k] = v
                end
            end
        end
        deep(merged, data)
    end
    merge_file("translations/en.json")
    if lang ~= "en" then
        merge_file("translations/" .. lang .. ".json")
    end
    i18n_cache.lang = lang
    i18n_cache.table = merged
    return merged
end

local function lookup_path(tbl, key)
    local node = tbl
    for part in string.gmatch(key, "[^%.]+") do
        if type(node) ~= "table" then return nil end
        node = node[part]
    end
    if type(node) == "string" then return node end
    return nil
end

local function tr(key, args)
    local lang = noctalia.getConfig and noctalia.getConfig("language")
    if type(lang) ~= "string" or lang == "" or lang == "auto" then
        return noctalia.tr(key, args)
    end
    local tbl = load_lang_table(lang)
    local str = lookup_path(tbl, key)
    if not str then
        -- Missing override key: fall back to the shell translator.
        return noctalia.tr(key, args)
    end
    if type(args) == "table" then
        str = string.gsub(str, "{(%w+)}", function(name)
            local v = args[name]
            if v == nil then return "{" .. name .. "}" end
            return tostring(v)
        end)
    end
    return str
end

-- Fingerprint a value to detect real changes (avoid re-render storms)
local function fp(v)
    if type(v) ~= "table" then return tostring(v) end
    local parts = {}
    for k, val in pairs(v) do
        parts[#parts + 1] = tostring(k) .. "=" .. tostring(val)
    end
    table.sort(parts)
    return table.concat(parts, "\1")
end

local function fp_list(list, fields)
    if type(list) ~= "table" then return "" end
    local parts = {}
    for i, item in ipairs(list) do
        if type(item) == "table" then
            local item_parts = {}
            for _, f in ipairs(fields) do
                item_parts[#item_parts + 1] = tostring(item[f] or "")
            end
            parts[i] = table.concat(item_parts, "\2")
        end
    end
    return table.concat(parts, "\1")
end

-- Fingerprint the MCP server map (name-keyed) by sorted name + status, so the
-- footer re-renders when a server's status changes.
local function fp_mcp(servers)
    if type(servers) ~= "table" then return "" end
    local parts = {}
    for name, srv in pairs(servers) do
        local st = (type(srv) == "table" and srv.status) or "disabled"
        parts[#parts + 1] = tostring(name) .. "=" .. tostring(st)
    end
    table.sort(parts)
    return table.concat(parts, "\1")
end

-- Fingerprint a message list by message id + concatenated part text, so the
-- panel re-renders when message content actually changes (ids alone are stable
-- while a response streams in).
local function fp_messages(list)
    if type(list) ~= "table" then return "" end
    local parts = {}
    for i, msg in ipairs(list) do
        if type(msg) == "table" then
            local info = msg.info
            local id = (type(info) == "table" and info.id) or msg.id or ""
            local text = ""
            if type(msg.parts) == "table" then
                local tparts = {}
                for _, p in ipairs(msg.parts) do
                    if type(p) == "table" and type(p.text) == "string" then
                        tparts[#tparts + 1] = p.text
                    end
                end
                text = table.concat(tparts, "\2")
            end
            parts[i] = id .. "\2" .. text
        end
    end
    return table.concat(parts, "\1")
end

-- ── helpers ─────────────────────────────────────────────────────────────────

local function is_connected()
    local conn = noctalia.state.get(STATE.connection)
    return type(conn) == "table" and conn.status ~= "offline"
end

local function is_processing()
    local conn = noctalia.state.get(STATE.connection)
    return type(conn) == "table" and conn.status == "busy"
end

local function is_waiting_permission()
    local conn = noctalia.state.get(STATE.connection)
    return type(conn) == "table" and conn.status == "waiting_permission"
end

local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function dispatch_ipc(event, payload)
    local cmd = "noctalia msg plugin '" .. SVC .. "' all " .. event
    if payload then
        -- Shell-escape the payload
        payload = payload:gsub("'", "'\\''")
        cmd = cmd .. " '" .. payload .. "'"
    end
    noctalia.runAsync(cmd)
end

-- MCP status footer: colored server names, one per line. Returns nil when
-- there's nothing meaningful to show. Kept intentionally minimal — the
-- MCP status footer: a single collapsible toggle row (chevron + title +
-- connected/total count). Clicking expands it to show one pill per server.
-- Collapsed by default so it never crowds the message list.
local MCP_META = {
    connected = { fill = "primary/0.12", color = "primary", dot = "primary", key = "connected" },
    failed    = { fill = "error/0.10",   color = "error",   dot = "error",   key = "failed" },
    disabled  = { fill = "surface_variant/0.45", color = "on_surface_variant", dot = "on_surface/0.35", key = "disabled" },
}
local mcp_expanded = false
local function render_mcp_status()
    local servers = noctalia.state.get(STATE.mcp)
    if type(servers) ~= "table" then return nil end
    local names = {}
    for name in pairs(servers) do names[#names + 1] = name end
    if #names == 0 then return nil end
    table.sort(names)

    local connected, failed = 0, 0
    for _, name in ipairs(names) do
        local st = (type(servers[name]) == "table" and servers[name].status) or "disabled"
        if st == "connected" then connected = connected + 1
        elseif st == "failed" then failed = failed + 1 end
    end

    local header = ui.button({
        text = tr("mcp.title") .. " (" .. tostring(connected) .. "/" .. tostring(#names) .. ")",
        glyph = mcp_expanded and "chevron-up" or "chevron-right",
        variant = "ghost",
        tooltip = tr("mcp.title"),
        onClick = function()
            mcp_expanded = not mcp_expanded
            render()
        end,
    })

    if not mcp_expanded then
        return ui.column({ gap = GAP_SM, key = "mcp_status" }, { header })
    end

    local rows = {}
    for _, name in ipairs(names) do
        local st = (type(servers[name]) == "table" and servers[name].status) or "disabled"
        local meta = MCP_META[st] or MCP_META.disabled
        rows[#rows + 1] = ui.row({ gap = GAP, align = "center", fill = meta.fill, radius = 8, paddingH = 9, paddingV = 6 }, {
            ui.box({ width = 8, height = 8, radius = 4, fill = meta.dot }),
            ui.label({ text = name, color = "on_surface", fontSize = FONT_SUB, flexGrow = 1, maxWidth = WRAP - 140, maxLines = 1 }),
            ui.label({ text = tr("mcp." .. meta.key), color = meta.color, fontSize = 10, maxLines = 1 }),
        })
    end

    return ui.column({ gap = GAP_SM, key = "mcp_status", padding = 10, radius = 10, fill = "surface/0.45" }, {
        header,
        unpack(rows),
    })
end

-- ── session chooser view ────────────────────────────────────────────────────

local function render_session_chooser(sessions, conn)
    local rows = {}

    -- Header
    rows[#rows + 1] = ui.row({ justify = "space_between", align = "center" }, {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = "code-circle", color = "primary", size = compact and 18 or 24 }),
            ui.label({ text = tr("chooser.title"), fontSize = FONT_TITLE, fontWeight = "bold", color = "on_surface" }),
        }),
        ui.row({ gap = 8 }, {
            ui.button({ glyph = "refresh", onClick = function()
                dispatch_ipc("refresh")
            end, tooltip = tr("chooser.refresh") }),
        }),
    })

    rows[#rows + 1] = ui.separator({})

    -- New session button
    rows[#rows + 1] = ui.button({
        text = tr("chooser.new_session"),
        glyph = "plus",
        onClick = function()
            dispatch_ipc("create_session")
        end,
    })

    -- Search box (live filter over the session list). A stable `key` keeps the
    -- input node alive across render() calls so typed text/cursor survive the
    -- re-render triggered by onChange.
    rows[#rows + 1] = ui.input({
        key = "session_search",
        value = session_query,
        placeholder = tr("chooser.search"),
        onChange = function(text)
            session_query = text or ""
            render()
        end,
    })

    -- Filter sessions by the search query (case-insensitive substring over
    -- title/slug/id/directory). Empty query shows everything.
    local visible = sessions
    if type(sessions) == "table" and session_query ~= "" then
        local needle = string.lower(session_query)
        visible = {}
        for _, s in ipairs(sessions) do
            if type(s) == "table" then
                local hay = string.lower(
                    tostring(s.title or "") .. " " ..
                    tostring(s.slug or "") .. " " ..
                    tostring(s.id or "") .. " " ..
                    tostring(s.directory or "")
                )
                if string.find(hay, needle, 1, true) then
                    visible[#visible + 1] = s
                end
            end
        end
    end

    -- Session list
    local list_items = {}
    if type(visible) ~= "table" or #visible == 0 then
        list_items[#list_items + 1] = ui.label({
            text = session_query ~= "" and tr("chooser.no_match") or tr("chooser.empty"),
            maxWidth = WRAP,
            opacity = 0.7,
        })
    else
        for _, s in ipairs(visible) do
            if type(s) == "table" and s.id then
                local title = s.title or s.slug or s.id
                local model_str = ""
                if type(s.model) == "table" and s.model.id then
                    model_str = " · " .. (s.model.providerID or "?") .. "/" .. s.model.id
                end
                local time_str = ""
                if type(s.time) == "table" and s.time.updated then
                    -- Simple relative time display
                    local now = os.time() * 1000
                    local diff = now - s.time.updated
                    if diff < 60000 then
                        time_str = " · " .. tr("time.just_now")
                    elseif diff < 3600000 then
                        time_str = " · " .. tr("time.minutes_ago", { n = math.floor(diff / 60000) })
                    elseif diff < 86400000 then
                        time_str = " · " .. tr("time.hours_ago", { n = math.floor(diff / 3600000) })
                    else
                        time_str = " · " .. tr("time.days_ago", { n = math.floor(diff / 86400000) })
                    end
                end

                local row_id = s.id  -- capture for closure
                local is_active = (row_id == last_opened_id)
                -- Record the opened session so the chooser can keep the row
                -- highlighted after the user backs out to the list.
                local function open_this()
                    last_opened_id = row_id
                    dispatch_ipc("select_session", row_id)
                end
                local actions
                if pending_delete == row_id then
                    -- Inline confirmation for the destructive delete.
                    actions = ui.row({ gap = 6 }, {
                        ui.button({
                            glyph = "check",
                            variant = "primary",
                            tooltip = tr("chooser.delete_confirm"),
                            onClick = function()
                                dispatch_ipc("delete_session", row_id)
                                pending_delete = nil
                                render()
                            end,
                        }),
                        ui.button({
                            glyph = "x",
                            variant = "secondary",
                            tooltip = tr("chooser.delete_cancel"),
                            onClick = function()
                                pending_delete = nil
                                render()
                            end,
                        }),
                    })
                else
                    actions = ui.row({ gap = 6 }, {
                        ui.button({
                            glyph = "trash",
                            variant = "secondary",
                            tooltip = tr("chooser.delete"),
                            onClick = function()
                                pending_delete = row_id
                                render()
                            end,
                        }),
                        ui.button({
                            glyph = "arrow-right",
                            variant = is_active and "primary" or "secondary",
                            tooltip = tr("chooser.open"),
                            onClick = open_this,
                        }),
                    })
                end
                -- Each session is a card. The most recently opened one is
                -- highlighted with the accent (only ever one at a time). The
                -- whole label area is clickable to open; action buttons on the
                -- right stay separately clickable.
                list_items[#list_items + 1] = ui.row({
                    key = row_id,
                    justify = "space_between",
                    align = "center",
                    padding = CARD_PAD,
                    radius = CARD_RADIUS,
                    fill = is_active and "primary/0.15" or "surface",
                    border = is_active and "primary" or "surface",
                    borderWidth = is_active and 2 or 1,
                }, {
                    ui.column({
                        gap = GAP_SM, flexGrow = 1,
                        onClick = open_this,
                    }, {
                        ui.label({
                            text = title,
                            maxWidth = WRAP - 140,
                            fontWeight = is_active and "bold" or "medium",
                            color = is_active and "primary" or "on_surface",
                            fontSize = compact and 12 or nil,
                        }),
                        (not compact)
                            and ui.label({
                                text = (s.directory or "") .. model_str .. time_str,
                                maxWidth = WRAP - 140,
                                opacity = 0.6,
                                fontSize = FONT_SUB,
                            })
                            or nil,
                    }),
                    actions,
                })
            end
        end
    end

    rows[#rows + 1] = ui.scroll({ flexGrow = 1, gap = GAP, align = "stretch", justify = "start" }, list_items)

    panel.render(ui.column({ padding = PAD, gap = GAP, flexGrow = 1, align = "stretch", justify = "start" }, rows))
end

-- ── chat view ───────────────────────────────────────────────────────────────

local function render_message(msg_data)
    if type(msg_data) ~= "table" then return nil end
    local info = msg_data.info
    local parts = msg_data.parts
    if type(info) ~= "table" then return nil end

    local role = info.role or "unknown"
    local cells = {}

    -- Render each part
    if type(parts) == "table" then
        for _, part in ipairs(parts) do
            if type(part) == "table" then
            local ptype = part.type

            if ptype == "text" and type(part.text) == "string" and part.text ~= "" then
                -- The server prepends an injected context block (e.g. a
                -- <memory_context>…</memory_context> section) to user messages.
                -- Hide those synthetic parts so the bubble shows only what the
                -- user actually typed.
                local txt = part.text
                local is_injected = (role == "user") and (
                    txt:sub(1, 16) == "<memory_context>"
                    or txt:sub(1, 1) == "<" and txt:find("_context>", 1, true) ~= nil
                )
                if not is_injected then
                    cells[#cells + 1] = ui.label({
                        text = txt,
                        maxWidth = WRAP,
                        flexGrow = 1,
                    })
                end
            elseif ptype == "reasoning" and type(part.text) == "string" and part.text ~= "" then
                -- Only show reasoning if enabled (checked at render time via config)
                local show_reasoning = noctalia.getConfig and noctalia.getConfig("show_reasoning")
                if show_reasoning then
                    cells[#cells + 1] = ui.label({
                        text = "> " .. part.text:gsub("\n", "\n> "),
                        maxWidth = WRAP,
                        opacity = 0.6,
                        fontSize = 12,
                    })
                end
            elseif ptype == "tool" then
                local show_tools = noctalia.getConfig and noctalia.getConfig("show_tool_calls")
                if show_tools then
                    local tool_name = part.tool or "?"
                    local status = "unknown"
                    local detail = ""
                    if type(part.state) == "table" then
                        status = part.state.status or "?"
                        if type(part.state.title) == "string" then
                            detail = part.state.title
                        end
                    end
                    local status_icon = "circle"
                    if status == "completed" then status_icon = "circle-check"
                    elseif status == "error" then status_icon = "alert-circle"
                    elseif status == "pending" then status_icon = "loader"
                    end
                    cells[#cells + 1] = ui.row({ gap = 6, align = "center" }, {
                        ui.glyph({ name = status_icon, size = 14, color = status == "error" and "error" or "secondary" }),
                        ui.label({ text = tool_name .. (detail ~= "" and (" → " .. detail) or ""), fontSize = 12, opacity = 0.8 }),
                    })
                end
            elseif ptype == "step-start" or ptype == "step-finish" then
                -- Skip structural parts
            end
            end
        end
    end

    if #cells == 0 then return nil end

    local is_user = (role == "user")
    local header_text = is_user and tr("chat.you") or tr("chat.assistant")
    local header_color = is_user and "secondary" or "primary"

    local all_cells = {
        ui.label({ text = header_text, fontWeight = "bold", color = header_color, fontSize = compact and 11 or 12 }),
    }
    for _, c in ipairs(cells) do
        all_cells[#all_cells + 1] = c
    end

    -- User messages hug the right edge, agent messages the left.
    -- `align` on the column right/left-aligns the bubble content (maxWidth on
    -- column is unsupported in beta.7, so we rely on align + label maxWidth).
    -- A stable `key` (the message id) keeps each bubble's node identity across
    -- re-renders so the scroll offset isn't reset while a reply streams in.
    local msg_id = (type(info.id) == "string" and info.id) or ""
    return ui.row({ key = "msg_" .. msg_id, justify = is_user and "end" or "start", align = "start" }, {
        ui.column({ gap = BUBBLE_GAP, align = is_user and "end" or "start" }, all_cells),
    })
end

-- Animated "thinking" bubble shown on the left while the agent is processing.
local function render_thinking()
    local glyph_name = THINKING_GLYPHS[(thinking_frame % #THINKING_GLYPHS) + 1]
    return ui.row({ justify = "start", align = "start" }, {
        ui.column({ gap = BUBBLE_GAP, align = "start" }, {
            ui.label({ text = tr("chat.assistant"), fontWeight = "bold", color = "primary", fontSize = compact and 11 or 12 }),
            ui.row({ gap = 6, align = "center" }, {
                ui.glyph({ name = glyph_name, color = "primary" }),
                ui.label({ text = tr("chat.thinking"), opacity = 0.7, fontSize = compact and 12 or nil }),
            }),
        }),
    })
end

local function render_permission_card(perm)
    if type(perm) ~= "table" then return nil end
    local perm_id = perm.permissionID or "?"
    local session_id = perm.sessionID or "?"

    -- Compose a readable description from the v1 (`permission`/`patterns`) or
    -- v2 (`action`/`resources`) fields the SSE event carries.
    local message = ""
    if type(perm.action) == "string" and perm.action ~= "" then
        message = perm.action
    elseif type(perm.permission) == "string" and perm.permission ~= "" then
        message = perm.permission
    end
    if message == "" then
        message = tr("permission.default_message")
    end
    local src = perm.resources
    if type(src) ~= "table" then src = perm.patterns end
    local detail_items = {}
    if type(src) == "table" then
        for _, s in ipairs(src) do
            if type(s) == "string" and s ~= "" then
                detail_items[#detail_items + 1] = s
            end
        end
    end
    local details = table.concat(detail_items, ", ")

    local cards = {}

    cards[#cards + 1] = ui.column({ gap = 6 }, {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = "shield-exclamation", color = "error", size = 20 }),
            ui.label({ text = tr("permission.title"), fontWeight = "bold", color = "error" }),
        }),
        ui.label({ text = message, maxWidth = WRAP }),
    })

    if details ~= "" then
        cards[#cards + 1] = ui.label({ text = details, fontSize = 12, fontFamily = "monospace", maxWidth = WRAP })
    end

    -- Action buttons
    cards[#cards + 1] = ui.row({ gap = 8 }, {
        ui.button({
            text = tr("permission.allow"),
            glyph = "check",
            variant = "primary",
            onClick = function()
                dispatch_ipc("permission_response", perm_id .. ":allow")
            end,
        }),
        ui.button({
            text = tr("permission.allow_remember"),
            glyph = "checks",
            variant = "secondary",
            onClick = function()
                dispatch_ipc("permission_response", perm_id .. ":allow:true")
            end,
        }),
        ui.button({
            text = tr("permission.deny"),
            glyph = "x",
            variant = "secondary",
            onClick = function()
                dispatch_ipc("permission_response", perm_id .. ":deny")
            end,
        }),
    })

    return ui.column({ gap = 8, padding = 8 }, cards)
end

local function render_question_card(q)
    if type(q) ~= "table" then return nil end
    local rid = q.requestID or q.id
    local questions = q.questions
    if not rid or type(questions) ~= "table" or #questions == 0 then return nil end

    -- Per-request selection store: choices[i] = chosen label for question i.
    local choices = question_choices[rid]
    if type(choices) ~= "table" then
        choices = {}
        question_choices[rid] = choices
    end

    local cards = {}
    cards[#cards + 1] = ui.column({ gap = 6 }, {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = "message-circle-question", color = "primary", size = 20 }),
            ui.label({ text = tr("question.title"), fontWeight = "bold", color = "primary" }),
        }),
    })

    for qi, qinfo in ipairs(questions) do
        if type(qinfo) == "table" then
            cards[#cards + 1] = ui.label({ text = qinfo.question or "", maxWidth = WRAP })
            local opts = qinfo.options
            if type(opts) == "table" then
                local opt_row = {}
                for _, o in ipairs(opts) do
                    if type(o) == "table" and type(o.label) == "string" and o.label ~= "" then
                        local label = o.label
                        opt_row[#opt_row + 1] = ui.button({
                            text = label,
                            -- Highlight the chosen option; only record the
                            -- selection locally, never reply until every
                            -- question has an answer.
                            variant = (choices[qi] == label) and "primary" or "secondary",
                            selected = (choices[qi] == label),
                            onClick = function()
                                choices[qi] = label
                                render()
                            end,
                        })
                    end
                end
                if #opt_row > 0 then
                    -- Stack option buttons vertically: avoids horizontal overflow
                    -- (no wrap support in beta.7) and reads like choice buttons.
                    cards[#cards + 1] = ui.column({ gap = 6 }, opt_row)
                end
            end
            if qinfo.custom then
                cards[#cards + 1] = ui.button({
                    text = tr("question.custom"),
                    variant = (choices[qi] == "") and "primary" or "secondary",
                    selected = (choices[qi] == ""),
                    onClick = function()
                        -- Custom answer is encoded as an empty selection for
                        -- this question; still requires the others to be set.
                        choices[qi] = ""
                        render()
                    end,
                })
            end
        end
    end

    -- Every question must have a selection before the reply can be sent.
    local all_answered = true
    for qi = 1, #questions do
        if choices[qi] == nil then
            all_answered = false
            break
        end
    end

    cards[#cards + 1] = ui.row({ gap = 6 }, {
        ui.button({
            text = tr("question.submit"),
            glyph = "check",
            variant = "primary",
            enabled = all_answered,
            flexGrow = 1,
            onClick = function()
                if not all_answered then return end
                -- Build the outer array: one inner array per question, in order.
                local inner = {}
                for qi = 1, #questions do
                    local ok, enc = pcall(noctalia.json.encode, { choices[qi] })
                    inner[#inner + 1] = ok and enc or "[\"\"]"
                end
                local payload = "[" .. table.concat(inner, ",") .. "]"
                question_choices[rid] = nil
                dispatch_ipc("question_reply", rid .. "\2" .. payload)
            end,
        }),
        ui.button({
            text = tr("question.cancel"),
            variant = "secondary",
            glyph = "x",
            onClick = function()
                question_choices[rid] = nil
                dispatch_ipc("question_reject", rid)
            end,
        }),
    })

    return ui.column({ gap = 8, padding = 8, fill = "surface" }, cards)
end

local function render_chat(active, messages, permissions, questions, conn)
    local rows = {}

    -- Header
    local title = (type(active) == "table" and active.title) or tr("chat.title")
    local model_str = ""
    if type(active) == "table" and type(active.model) == "table" then
        model_str = (active.model.providerID or "?") .. "/" .. (active.model.id or "?")
    end
    local agent_str = (type(active) == "table" and active.agent) or "?"

    rows[#rows + 1] = ui.row({ justify = "space_between", align = "center" }, {
        ui.row({ gap = 8, align = "center", flexGrow = 1 }, {
            ui.button({
                glyph = "arrow-left",
                variant = "secondary",
                tooltip = tr("chat.back"),
                onClick = function()
                    dispatch_ipc("deselect_session")
                end,
            }),
            ui.glyph({ name = "code-circle", color = "primary", size = compact and 18 or 20 }),
            ui.column({ gap = 0 }, {
                ui.label({ text = title, fontWeight = "bold", maxWidth = WRAP - 200, fontSize = compact and 13 or 14 }),
                (not compact)
                    and ui.label({
                        text = agent_str .. (model_str ~= "" and (" · " .. model_str) or ""),
                        fontSize = FONT_SUB,
                        opacity = 0.6,
                    })
                    or nil,
            }),
        }),
        ui.row({ gap = 6 }, {
            ui.button({
                glyph = "plus",
                variant = "secondary",
                tooltip = tr("chooser.new_session"),
                onClick = function()
                    dispatch_ipc("create_session")
                end,
            }),
            ui.button({
                glyph = "terminal",
                tooltip = tr("chat.open_terminal"),
                onClick = function()
                    local host = noctalia.getConfig and noctalia.getConfig("server_host") or "127.0.0.1"
                    local port = noctalia.getConfig and noctalia.getConfig("server_port") or 4096
                    local url = "http://" .. host .. ":" .. tostring(port)
                    local sess = (type(active) == "table" and type(active.id) == "string") and active.id or nil
                    local cmd = "opencode attach " .. shq(url)
                    if sess and sess ~= "" then
                        cmd = cmd .. " --session " .. shq(sess)
                    end
                    noctalia.runInTerminal(cmd)
                end,
            }),
            ui.button({
                glyph = "refresh",
                variant = "secondary",
                tooltip = tr("chat.refresh"),
                onClick = function()
                    dispatch_ipc("refresh")
                end,
            }),
        }),
    })

    -- Model + agent selectors. The service publishes option lists as arrays of
    -- { value, label }; ui.select takes a flat label array + selectedIndex, and
    -- its onChange fires with (indexString, labelText). We map the chosen index
    -- back to the option's `value` and dispatch it to the service.
    local model_options = noctalia.state.get(STATE.model_options) or {}
    local agent_options = noctalia.state.get(STATE.agent_options) or {}
    local sel_model = noctalia.state.get(STATE.selected_model)
    local sel_agent = noctalia.state.get(STATE.selected_agent)

    local function build_select(key, opts, selected_value, placeholder_key, event)
        local labels = {}
        local values = {}
        local sel_index = nil
        for i, o in ipairs(opts) do
            labels[i] = (type(o) == "table" and o.label) or tostring(o)
            values[i] = (type(o) == "table" and o.value) or tostring(o)
            if selected_value and values[i] == selected_value then
                sel_index = i - 1  -- host uses 0-based indices
            end
        end
        local props = {
            key = key,
            options = labels,
            placeholder = tr(placeholder_key),
            flexGrow = 1,
            onChange = function(idx)
                -- idx arrives as a 0-based index (string or number).
                local n = tonumber(idx)
                if n ~= nil then
                    local chosen = values[math.floor(n) + 1]
                    if type(chosen) == "string" and chosen ~= "" then
                        dispatch_ipc(event, chosen)
                    end
                end
            end,
        }
        if sel_index ~= nil then props.selectedIndex = sel_index end
        return ui.select(props)
    end

    if (type(model_options) == "table" and #model_options > 0)
       or (type(agent_options) == "table" and #agent_options > 0) then
        local selectors = {}
        if type(model_options) == "table" and #model_options > 0 then
            selectors[#selectors + 1] = build_select("model_select", model_options, sel_model, "chat.select_model", "set_model")
        end
        if type(agent_options) == "table" and #agent_options > 0 then
            selectors[#selectors + 1] = build_select("agent_select", agent_options, sel_agent, "chat.select_agent", "set_agent")
        end
        rows[#rows + 1] = ui.row({ gap = 8, align = "center" }, selectors)
    end

    rows[#rows + 1] = ui.separator({})

    -- Error banner: surface the last error (e.g. session.error from the server)
    -- so failures are visible instead of a silently-stuck composer.
    local err = noctalia.state.get(STATE.last_error)
    if type(err) == "table" and type(err.message) == "string" and err.message ~= "" then
        local banner = {
            ui.glyph({ name = "alert-circle", color = "error", size = 16 }),
            ui.column({ gap = 2, flexGrow = 1 }, {
                ui.label({ text = err.message, color = "error", fontSize = 13, fontWeight = "bold", maxWidth = WRAP - 40 }),
                (type(err.detail) == "string" and err.detail ~= "")
                    and ui.label({ text = err.detail, fontSize = 11, opacity = 0.75, maxWidth = WRAP - 40 })
                    or nil,
            }),
            ui.button({
                glyph = "x",
                variant = "secondary",
                tooltip = tr("chat.dismiss_error"),
                onClick = function()
                    dispatch_ipc("clear_error")
                end,
            }),
        }
        rows[#rows + 1] = ui.row({
            gap = 8, align = "start", padding = 8, radius = 8,
            fill = "surface", border = "error", borderWidth = 1,
        }, banner)
    end

    -- Permission cards (if any)
    if type(permissions) == "table" and #permissions > 0 then
        for _, perm in ipairs(permissions) do
            local card = render_permission_card(perm)
            if card then
                rows[#rows + 1] = card
                rows[#rows + 1] = ui.separator({})
            end
        end
    end

    -- Question/choice cards (if any) — the agent asked the user to pick.
    if type(questions) == "table" and #questions > 0 then
        for _, q in ipairs(questions) do
            local card = render_question_card(q)
            if card then
                rows[#rows + 1] = card
                rows[#rows + 1] = ui.separator({})
            end
        end
    end

    -- Message list, newest-first. Newest at the top so the panel always opens on
    -- the latest message without needing a scroll API (shell < API 21 resets a
    -- re-mounted scroll to offset 0 = top). Scrolling down reveals older
    -- messages. The scroll node carries a stable `key` so its offset survives
    -- re-renders even when siblings above it appear/disappear. Children are
    -- passed directly to the scroll (not wrapped in a column).
    local msg_items = {}
    if type(messages) ~= "table" or #messages == 0 then
        msg_items[#msg_items + 1] = ui.label({ text = tr("chat.empty"), maxWidth = WRAP, opacity = 0.7 })
    else
        -- "Waiting" (show thinking bubble) whenever the agent is processing and
        -- the newest message is the user's optimistic bubble, or an assistant
        -- bubble that has no text yet. The server creates the assistant message
        -- (role="assistant") as soon as streaming starts, before any text part
        -- exists, so we key off "assistant + has no text" not just the role.
        local newest = messages[#messages]
        local newest_is_assistant = type(newest) == "table"
            and type(newest.info) == "table" and newest.info.role == "assistant"
        local newest_has_text = false
        if type(newest) == "table" and type(newest.parts) == "table" then
            for _, p in ipairs(newest.parts) do
                if type(p) == "table" and p.type == "text"
                   and type(p.text) == "string" and p.text ~= "" then
                    newest_has_text = true
                    break
                end
            end
        end
        -- Thinking shows after the user sends (newest = user bubble) and while
        -- the agent is reasoning (newest = assistant bubble, no text yet). It
        -- disappears once the assistant's first text part streams in.
        local waiting = is_processing()
            and (not newest_is_assistant or not newest_has_text)
        -- Newest-first: build the list from the end so bubble order is latest
        -- first, oldest last.
        for i = #messages, 1, -1 do
            local rendered = render_message(messages[i])
            if rendered then
                msg_items[#msg_items + 1] = rendered
            end
        end
        -- Thinking bubble sits right ABOVE the newest message (top of the
        -- newest-first list), like a spinner over the reply in progress.
        if waiting then
            table.insert(msg_items, 1, render_thinking())
        end
    end

    rows[#rows + 1] = ui.scroll({ key = "chat_messages", flexGrow = 1, gap = GAP }, msg_items)

    -- MCP status footer
    local mcp_footer = render_mcp_status()
    if mcp_footer then
        rows[#rows + 1] = mcp_footer
    end

    -- Composer: input always visible; sending is disabled while processing and a
    -- stop button appears. The thinking indicator lives in the message list.
    local processing = is_processing()
    rows[#rows + 1] = ui.separator({})

    -- Send the current draft, then clear the composer. Clearing requires bumping
    -- the input's key so the reconciler rebuilds a fresh, empty input.
    local function send_draft(text)
        if processing then return end
        text = text or draft
        if type(text) ~= "string" or text == "" then return end
        dispatch_ipc("send_prompt", text)
        draft = ""
        composer_seq = composer_seq + 1
        render()
    end

    local composer_elems = {
        ui.input({
            -- Key changes on each send to force a fresh (cleared) input.
            key = "composer_" .. composer_seq,
            value = draft,
            placeholder = tr("chat.placeholder"),
            multiline = true,
            flexGrow = 1,
            onChange = function(text)
                draft = text
            end,
            -- Multiline: Enter inserts a newline; Ctrl+Enter submits (send). This
            -- is the input control's built-in mapping and cannot distinguish
            -- Shift+Enter, so Ctrl+Enter is the send chord.
            onSubmit = function(text)
                send_draft(text)
            end,
        }),
        ui.button({
            glyph = "send",
            variant = "primary",
            tooltip = tr("chat.send"),
            onClick = function()
                send_draft(draft)
            end,
        }),
    }
    if processing then
        composer_elems[#composer_elems + 1] = ui.button({
            glyph = "player-stop",
            variant = "secondary",
            tooltip = tr("chat.stop"),
            onClick = function()
                dispatch_ipc("abort_session")
            end,
        })
    end
    rows[#rows + 1] = ui.row({ gap = 8, align = "end" }, composer_elems)

    panel.render(ui.column({ padding = PAD, gap = GAP, flexGrow = 1 }, rows))
end

-- ── main render ─────────────────────────────────────────────────────────────

render = function()
    apply_layout()
    local active = noctalia.state.get(STATE.active)
    local sessions = noctalia.state.get(STATE.sessions) or {}
    local messages = noctalia.state.get(STATE.messages) or {}
    local permissions = noctalia.state.get(STATE.permissions) or {}
    local questions = noctalia.state.get(STATE.questions) or {}
    local conn = noctalia.state.get(STATE.connection)

    -- Keep the chooser highlight in sync with whatever session is actually
    -- open (covers restore-on-boot and IPC-driven selection).
    if type(active) == "table" and active.id then
        last_opened_id = active.id
    end

    -- Determine view
    if type(active) ~= "table" or not active.id then
        view = "session_chooser"
        render_session_chooser(sessions, conn)
    else
        view = "chat"
        render_chat(active, messages, permissions, questions, conn)
    end
end

local function fingerprint_state()
    local active = noctalia.state.get(STATE.active)
    local sessions = noctalia.state.get(STATE.sessions)
    local messages = noctalia.state.get(STATE.messages)
    local permissions = noctalia.state.get(STATE.permissions)
    local questions = noctalia.state.get(STATE.questions)
    local conn = noctalia.state.get(STATE.connection)
    local err = noctalia.state.get(STATE.last_error)
    local sel_model = noctalia.state.get(STATE.selected_model)
    local sel_agent = noctalia.state.get(STATE.selected_agent)
    local mcp = noctalia.state.get(STATE.mcp)

    return table.concat({
        (type(active) == "table" and active.id or "none"),
        fp_list(sessions or {}, { "id", "title" }),
        fp_messages(messages or {}),
        fp_list(permissions or {}, { "permissionID", "sessionID" }),
        fp_list(questions or {}, { "requestID", "sessionID" }),
        (type(conn) == "table" and conn.status or "offline"),
        (type(err) == "table" and tostring(err.message) or "none"),
        -- Selection changes must re-render so the selectors reflect the pick.
        tostring(sel_model or "") .. "\1" .. tostring(sel_agent or ""),
        fp_mcp((type(mcp) == "table" and mcp or {})),
        -- Animation frame drives the thinking spinner re-render while busy.
        tostring(thinking_frame),
    }, "\1")
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function onOpen(_context)
    panel.setWantsSecondTicks(true)
    -- Subscribe to all relevant state changes
    for _, key in pairs(STATE) do
        noctalia.state.watch(key, function()
            -- Debounce: only re-render if fingerprint changed
            local fp = fingerprint_state()
            if fp ~= snap_cache.fingerprint then
                snap_cache.fingerprint = fp
                render()
            end
        end)
    end
    render()
end

function onClose()
    -- Keep draft in memory — it persists for this panel instance
end

function update()
    -- Second tick: advance the thinking animation while processing, then
    -- re-render only if state changed.
    if is_processing() then
        thinking_frame = thinking_frame + 1
    end
    local fp = fingerprint_state()
    if fp ~= snap_cache.fingerprint then
        snap_cache.fingerprint = fp
        render()
    end
end
