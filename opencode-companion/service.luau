    -- OpenCode Companion service — the headless backend and single source of truth.
--
-- Responsibilities:
--   • Manage the OpenCode server lifecycle (auto or external mode)
--   • Maintain the SSE event stream connection
--   • Track active session, messages, and connection state
--   • Handle permission requests
--   • Publish shared state for widget and panel subscribers
--   • Persist boot-scoped session state
--
-- The widget and panel are pure subscribers of `opencode.*` state keys.

-- ── helpers ─────────────────────────────────────────────────────────────────

-- Translation with an optional per-plugin language override (mirrors panel.luau).
-- noctalia.tr() follows the global shell locale, so a specific `language` choice
-- loads the plugin's own translations/<lang>.json (merged over en.json) and
-- resolves keys locally. "auto" delegates to noctalia.tr.
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

local function tr(key, args)
    local lang = noctalia.getConfig and noctalia.getConfig("language")
    if type(lang) ~= "string" or lang == "" or lang == "auto" then
        return noctalia.tr(key, args)
    end
    local node = load_lang_table(lang)
    for part in string.gmatch(key, "[^%.]+") do
        if type(node) ~= "table" then node = nil break end
        node = node[part]
    end
    if type(node) ~= "string" then
        return noctalia.tr(key, args)
    end
    if type(args) == "table" then
        node = string.gsub(node, "{(%w+)}", function(name)
            local v = args[name]
            if v == nil then return "{" .. name .. "}" end
            return tostring(v)
        end)
    end
    return node
end

local function debug_log(msg)
    if noctalia.getConfig and noctalia.getConfig("debug_logging") then
        print("[opencode-companion] " .. tostring(msg))
    end
end

-- Shell-quote for safe command composition
local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Safe id validation for IPC / URL composition
local function safe_id(id)
    return type(id) == "string" and id ~= "" and id:match("^[%w%._%-]+$") ~= nil
end

-- ── config ───────────────────────────────────────────────────────────────────

local function get_server_mode()
    local v = noctalia.getConfig and noctalia.getConfig("server_mode")
    return (type(v) == "string" and v ~= "") and v or "auto"
end

local function get_server_host()
    local v = noctalia.getConfig and noctalia.getConfig("server_host")
    return (type(v) == "string" and v ~= "") and v or "127.0.0.1"
end

local function get_server_port()
    local v = noctalia.getConfig and noctalia.getConfig("server_port")
    return (type(v) == "number" and v > 0) and v or 4096
end

local function get_server_url()
    local v = noctalia.getConfig and noctalia.getConfig("server_url")
    return (type(v) == "string") and v or ""
end

local function get_auto_start()
    local v = noctalia.getConfig and noctalia.getConfig("auto_start")
    return v ~= false
end

local function get_default_workspace()
    local v = noctalia.getConfig and noctalia.getConfig("default_workspace")
    return (type(v) == "string") and v or ""
end

local function get_default_model()
    local v = noctalia.getConfig and noctalia.getConfig("default_model")
    return (type(v) == "string") and v or ""
end

local function get_default_agent()
    local v = noctalia.getConfig and noctalia.getConfig("default_agent")
    return (type(v) == "string" and v ~= "") and v or "build"
end

local function get_max_messages()
    local v = noctalia.getConfig and noctalia.getConfig("max_messages_load")
    local n = (type(v) == "number" and v > 0) and math.floor(v) or 50
    -- The slider tops out at 101 which we treat as "unlimited": ask the server
    -- for an effectively unbounded window so the whole session loads. The
    -- server's /message?limit=N returns the N NEWEST messages (oldest-first
    -- within that window), so a large N yields the full history.
    if n >= 101 then
        return 100000
    end
    return n
end

-- ── state ────────────────────────────────────────────────────────────────────

-- Connection state
local connection = {
    status = "offline",
    error = nil,
    server_version = nil,
}

-- Server process info (managed mode only)
local managed_pid = nil
local managed_port = nil

-- Active session tracking
local active_session = nil
local sessions = {}
local messages = {}
local session_status = {}
local pending_permissions = {}
local pending_questions = {}  -- [{ requestID, sessionID, questions, tool }]
local mcp_status = {}
local providers = {}
local agents = {}
local model_options = {}  -- [{ value, label }] for the model picker
local agent_options = {}  -- [{ value, label }] for the agent picker
local unread_count = 0
local last_error = nil

-- Optimistic user message appended on send, replaced once the server echoes it.
local optimistic_msg = nil

-- When the active session went busy (os.time seconds). Used to auto-recover a
-- stale busy status if the server never emits idle/error (dropped SSE event),
-- which otherwise locks the composer ("can only send once").
local busy_since = nil
local BUSY_STALE_S = 180

-- Cheap guard: skip re-decoding an identical messages payload. SSE fires many
-- part-updated events per reply; without this each one re-decodes the full
-- (often large) JSON and can blow the callback CPU budget.
local last_messages_body = nil

-- Runtime-selected model / agent (override the configured defaults for this
-- session without editing settings). Set via IPC from the panel selectors.
-- `selected_model` is ONLY set when the user explicitly picks one; when nil we
-- send no model override so the server uses the session's own working default.
-- Auto-seeding this from /config/providers `default` was the cause of the
-- "session encountered an error" bug: `default` can list several providers and
-- pairs() picked an arbitrary (possibly unauthenticated) one, forcing every
-- turn onto a model the server couldn't run.
local selected_model = nil  -- "providerID/modelID" or nil = no override
local selected_agent = nil  -- agent name or nil = no override
-- Model to preselect in the picker for display only (never auto-sent).
local default_model_display = nil

-- SSE connection state
local sse_stream = nil
local sse_reconnect_attempts = 0
local sse_max_reconnect = 10

-- Boot-scoped state
local boot_id = nil
local state_file = nil

-- Restore the previously-active session only once per boot. load_sessions()
-- runs after every delete/create/refresh, and without this guard it would
-- re-select the persisted session on every reload — making deleting a session
-- from the chooser "jump" into whatever session was last active.
local restore_done = false

-- Forward declarations: these functions are defined later in the file but are
-- referenced by earlier callbacks (health checks, session loading). Declaring
-- them up front keeps the references in scope so the async callbacks don't hit
-- a nil global when they fire.
local load_initial_data
local restore_active_session
local select_session

-- ── boot id persistence ──────────────────────────────────────────────────────

local function read_boot_id()
    local ok, content = pcall(noctalia.readFile, "/proc/sys/kernel/random/boot_id")
    if not ok or type(content) ~= "string" or content == "" then return nil end
    local id = content:match("^[^\n\r]*")
    if id then id = id:gsub("^%s+", ""):gsub("%s+$", "") end
    return (id and id ~= "") and id or nil
end

local function load_boot_state()
    if not state_file then return nil end
    local ok, content = pcall(noctalia.readFile, state_file)
    if not ok or type(content) ~= "string" or content == "" then return nil end
    local ok2, data = pcall(noctalia.json.decode, content)
    if not ok2 or type(data) ~= "table" then return nil end
    return data
end

local function save_boot_state(state)
    if not state_file then return end
    local ok, encoded = pcall(noctalia.json.encode, state)
    if not ok then return end
    pcall(noctalia.writeFile, state_file, encoded)
end

local function clear_boot_state()
    if not state_file then return end
    pcall(noctalia.writeFile, state_file, "{}")
end

local function persist_active_session()
    if not boot_id then return end
    local data = load_boot_state() or {}
    data.boot_id = boot_id
    data.active_session_id = active_session and active_session.id or nil
    data.workspace = get_default_workspace()
    data.draft = nil  -- panel handles draft persistence separately
    save_boot_state(data)
end

local function restore_session_if_same_boot()
    local data = load_boot_state()
    if not data or type(data) ~= "table" then return false end
    if data.boot_id ~= boot_id then
        -- Different boot: clear stale session reference
        clear_boot_state()
        return false
    end
    if data.active_session_id and safe_id(data.active_session_id) then
        -- Try to validate the session still exists
        return data.active_session_id
    end
    return false
end

-- ── http client ──────────────────────────────────────────────────────────────

local API = {}

function API.request(method, path, body, callback)
    local mode = get_server_mode()
    local base_url
    if mode == "external" then
        base_url = get_server_url()
        if base_url == "" then
            callback({ ok = false, status = 0, body = "external server URL not configured" })
            return
        end
    else
        base_url = "http://" .. get_server_host() .. ":" .. tostring(get_server_port())
    end

    local url = base_url .. path
    local headers = { "Accept: application/json" }
    local body_str = nil

    if body then
        body_str = noctalia.json.encode(body)
        table.insert(headers, "Content-Type: application/json")
    end

    local request = {
        url = url,
        method = method,
        headers = headers,
        body = body_str,
        follow_redirects = false,
    }

    noctalia.http(request, callback)
end

function API.get(path, callback)
    API.request("GET", path, nil, callback)
end

function API.post(path, body, callback)
    API.request("POST", path, body, callback)
end

function API.patch(path, body, callback)
    API.request("PATCH", path, body, callback)
end

function API.delete(path, callback)
    API.request("DELETE", path, nil, callback)
end

function API.health(callback)
    API.get("/global/health", callback)
end

-- ── server lifecycle ─────────────────────────────────────────────────────────

-- Dirty tracking: publish() only writes state keys that changed since the last
-- call. Publishing every key on every change is expensive (large tables like
-- sessions/messages get re-serialized each time) and blows the per-callback CPU
-- budget, which silently kills IPC/SSE handlers — the cause of "can only send
-- one message".
local dirty = {}

local function mark_dirty(key)
    dirty[key] = true
end

local function publish()
    if dirty.connection or dirty.all then
        noctalia.state.set("opencode.connection", connection)
        noctalia.state.set("opencode.server_version", connection.server_version)
    end
    if dirty.active_session or dirty.all then
        noctalia.state.set("opencode.active_session", active_session)
    end
    if dirty.sessions or dirty.all then
        noctalia.state.set("opencode.sessions", sessions)
    end
    if dirty.messages or dirty.all then
        noctalia.state.set("opencode.messages", messages)
    end
    if dirty.session_status or dirty.all then
        noctalia.state.set("opencode.session_status", session_status)
    end
    if dirty.mcp_status or dirty.all then
        noctalia.state.set("opencode.mcp_status", mcp_status)
    end
    if dirty.pending_permissions or dirty.all then
        noctalia.state.set("opencode.pending_permissions", pending_permissions)
    end
    if dirty.pending_questions or dirty.all then
        noctalia.state.set("opencode.pending_questions", pending_questions)
    end
    if dirty.unread_count or dirty.all then
        noctalia.state.set("opencode.unread_count", unread_count)
    end
    if dirty.last_error or dirty.all then
        noctalia.state.set("opencode.last_error", last_error)
    end
    if dirty.selection or dirty.all then
        -- Display value: show the server default until the user overrides it.
        noctalia.state.set("opencode.selected_model", selected_model or default_model_display)
        noctalia.state.set("opencode.selected_agent", selected_agent)
        noctalia.state.set("opencode.model_options", model_options)
        noctalia.state.set("opencode.agent_options", agent_options)
    end
    dirty = {}
end

local function set_connection_status(status, err)
    connection.status = status
    connection.error = err
    if status == "busy" then
        busy_since = os.time()
    else
        busy_since = nil
    end
    mark_dirty("connection")
    publish()
end

local function set_last_error(message, detail)
    last_error = { message = message, detail = detail }
    mark_dirty("last_error")
    publish()
end

local function clear_last_error()
    last_error = nil
    mark_dirty("last_error")
    publish()
end

local function find_opencode_on_path()
    if noctalia.commandExists("opencode") then
        return "opencode"
    end
    return nil
end

local function start_managed_server()
    local host = get_server_host()
    local port = get_server_port()

    -- Check health first — server may already be running
    API.health(function(resp)
        if resp.ok and resp.status == 200 then
            local ok, data = pcall(noctalia.json.decode, resp.body)
            if ok and data.healthy then
                connection.server_version = data.version
                managed_port = port
                set_connection_status("online")
                debug_log("Connected to existing server at " .. host .. ":" .. port)
                load_initial_data()
                return
            end
        end

        -- No healthy server — start one
        local exe = find_opencode_on_path()
        if not exe then
            set_connection_status("offline", tr("error.exe_not_found"))
            set_last_error(tr("error.exe_not_found_detail"))
            return
        end

        local workspace = get_default_workspace()
        local cmd = "opencode serve --hostname " .. shq(host) .. " --port " .. tostring(port)
        if workspace ~= "" then
            cmd = "cd " .. shq(workspace) .. " && " .. cmd
        end

        debug_log("Starting managed server: " .. cmd)
        set_connection_status("starting")

        noctalia.runAsync(cmd, function(result)
            -- Server should not exit immediately; if it did, there's an error
            if result.exitCode ~= 0 then
                local err = (result.stderr ~= "" and result.stderr or result.stdout or "unknown")
                err = err:gsub("[\r\n]", " "):gsub("^%s+", ""):gsub("%s+$", "")
                set_connection_status("offline", err)
                set_last_error(tr("error.server_failed"), err)
            end
        end)

        -- Retry health check with backoff
        local attempts = 0
        local function retry_health()
            attempts = attempts + 1
            if attempts > 10 then
                set_connection_status("offline", tr("error.server_timeout"))
                set_last_error(tr("error.server_timeout_detail"))
                return
            end
            local delay = math.min(1000 * (2 ^ attempts), 16000)
            -- Use a simple timer pattern: schedule next check
            -- Since we don't have real timers in service, poll via state change
            -- For now, try health immediately with increasing waits
            API.health(function(resp2)
                if resp2.ok and resp2.status == 200 then
                    local ok2, data2 = pcall(noctalia.json.decode, resp2.body)
                    if ok2 and data2.healthy then
                        connection.server_version = data2.version
                        managed_port = port
                        managed_pid = true  -- we spawned it
                        set_connection_status("online")
                        debug_log("Server started successfully")
                        load_initial_data()
                        return
                    end
                end
                -- Schedule retry
                local cmd2 = "sleep " .. tostring(delay / 1000) .. " && echo done"
                noctalia.runAsync(cmd2, function(_)
                    retry_health()
                end)
            end)
        end

        -- Start retry chain after a short initial delay
        noctalia.runAsync("sleep 1 && echo done", function(_)
            retry_health()
        end)
    end)
end

local function connect_external()
    local url = get_server_url()
    if url == "" then
        set_connection_status("offline", tr("error.external_not_configured"))
        return
    end

    set_connection_status("starting")
    debug_log("Connecting to external server: " .. url)

    API.health(function(resp)
        if resp.ok and resp.status == 200 then
            local ok, data = pcall(noctalia.json.decode, resp.body)
            if ok and data.healthy then
                connection.server_version = data.version
                set_connection_status("online")
                debug_log("Connected to external server")
                load_initial_data()
                return
            end
        end
        local err = tr("error.connection_failed") .. " (HTTP " .. tostring(resp.status) .. ")"
        set_connection_status("offline", err)
        set_last_error(tr("error.connection_failed_detail"), resp.body)
    end)
end

local function connect()
    clear_last_error()
    sse_reconnect_attempts = 0
    local mode = get_server_mode()
    if mode == "external" then
        connect_external()
    else
        start_managed_server()
    end
end

-- ── data loading ─────────────────────────────────────────────────────────────

local function load_sessions()
    -- Cap the session list: decoding the full history (can be 90+ sessions /
    -- tens of KB) in one async callback blows the CPU budget. The chooser only
    -- needs the most recent sessions.
    API.get("/session?limit=40", function(resp)
        if not (resp.ok and resp.status == 200) then
            debug_log("Failed to load sessions: " .. tostring(resp.status))
            return
        end
        local ok, data = pcall(noctalia.json.decode, resp.body)
        if not ok or type(data) ~= "table" then
            debug_log("Failed to parse sessions response")
            return
        end
        -- Sort by updated time descending
        table.sort(data, function(a, b)
            local ta = (a.time and a.time.updated) or 0
            local tb = (b.time and b.time.updated) or 0
            return ta > tb
        end)
        -- Defensive dedup by id (a session must never appear twice).
        local seen = {}
        local deduped = {}
        for _, s in ipairs(data) do
            if type(s) == "table" and s.id and not seen[s.id] then
                seen[s.id] = true
                deduped[#deduped + 1] = s
            end
        end
        sessions = deduped
        mark_dirty("sessions")
        publish()
        -- Try to restore active session
        restore_active_session()
    end)
end

-- Restore the previously active session if it belongs to the same boot.
restore_active_session = function()
    if restore_done then return end
    restore_done = true
    local id = restore_session_if_same_boot()
    if id then
        select_session(id)
    end
end

local function load_messages(session_id, limit)
    if not safe_id(session_id) then return end
    local lim = limit or get_max_messages()
    local path = "/session/" .. session_id .. "/message?limit=" .. tostring(lim)
    API.get(path, function(resp)
        if not (resp.ok and resp.status == 200) then
            debug_log("Failed to load messages: " .. tostring(resp.status))
            return
        end
        -- Nothing changed since last load: skip the decode + reconcile entirely.
        if resp.body == last_messages_body and not optimistic_msg then
            return
        end
        last_messages_body = resp.body
        local ok, data = pcall(noctalia.json.decode, resp.body)
        if not ok or type(data) ~= "table" then
            debug_log("Failed to parse messages response")
            return
        end
        messages = data
        -- Re-append the optimistic user message if the server hasn't echoed it
        -- yet, so the just-sent message doesn't flicker out before confirmation.
        --
        -- The server injects extra parts (e.g. a <memory_context> block) into the
        -- real user message, so the sent text is usually parts[2..], not parts[1].
        -- Match by scanning ALL text parts of every user message for our text.
        if optimistic_msg then
            local want = optimistic_msg.parts[1].text
            local echoed = false
            for _, m in ipairs(messages) do
                if type(m) == "table" and type(m.info) == "table" and m.info.role == "user"
                   and type(m.parts) == "table" then
                    for _, p in ipairs(m.parts) do
                        if type(p) == "table" and type(p.text) == "string"
                           and (p.text == want or p.text:find(want, 1, true)) then
                            echoed = true
                            break
                        end
                    end
                end
                if echoed then break end
            end
            if not echoed then
                messages[#messages + 1] = optimistic_msg
            else
                optimistic_msg = nil
            end
        end
        -- Defensive dedup by message id (a message must never render twice).
        local seen = {}
        local deduped = {}
        for _, m in ipairs(messages) do
            local mid = (type(m) == "table" and type(m.info) == "table" and m.info.id) or nil
            if not mid or not seen[mid] then
                if mid then seen[mid] = true end
                deduped[#deduped + 1] = m
            end
        end
        messages = deduped
        mark_dirty("messages")
        publish()
    end)
end

local function load_mcp_status()
    API.get("/mcp", function(resp)
        if not (resp.ok and resp.status == 200) then
            debug_log("Failed to load MCP status")
            return
        end
        local ok, data = pcall(noctalia.json.decode, resp.body)
        if not ok or type(data) ~= "table" then
            debug_log("Failed to parse MCP response")
            return
        end
        mcp_status = data
        mark_dirty("mcp_status")
        publish()
    end)
end

local function load_providers()
    API.get("/config/providers", function(resp)
        if not (resp.ok and resp.status == 200) then
            debug_log("Failed to load providers")
            return
        end
        local ok, data = pcall(noctalia.json.decode, resp.body)
        if not ok or type(data) ~= "table" then
            debug_log("Failed to parse providers response")
            return
        end
        -- Flatten providers into a simple list, and build a flat model-option
        -- list the panel's select can consume: { value = "prov/model", label }.
        -- NOTE: /config/providers returns a LIST of provider objects, each with
        -- its own .id. Iterate with ipairs and use the object's real id (not the
        -- array index) — using the index produced values like "1/Code" that the
        -- server can't resolve ("Model not found: Code").
        local list = {}
        local opts = {}
        if type(data.providers) == "table" then
            for _, p in ipairs(data.providers) do
                if type(p) == "table" and type(p.id) == "string" and p.id ~= "" then
                    local pid = p.id
                    table.insert(list, p)
                    if type(p.models) == "table" then
                        for model_id, _ in pairs(p.models) do
                            opts[#opts + 1] = {
                                value = pid .. "/" .. model_id,
                                label = model_id .. "  (" .. pid .. ")",
                            }
                        end
                    end
                end
            end
        end
        table.sort(opts, function(a, b) return a.label < b.label end)
        providers = list
        model_options = opts
        -- Seed a DISPLAY-ONLY default for the picker (never auto-sent). Prefer
        -- the configured default_model, else the first server default entry.
        if not default_model_display then
            local cfg = get_default_model()
            if cfg ~= "" then
                default_model_display = cfg
            elseif type(data.default) == "table" then
                for prov_id, model_id in pairs(data.default) do
                    default_model_display = prov_id .. "/" .. model_id
                    break
                end
            end
        end
        mark_dirty("providers")
        mark_dirty("selection")
        publish()
    end)
end

local function load_agents()
    API.get("/agent", function(resp)
        if not (resp.ok and resp.status == 200) then
            debug_log("Failed to load agents")
            return
        end
        local ok, data = pcall(noctalia.json.decode, resp.body)
        if not ok or type(data) ~= "table" then
            debug_log("Failed to parse agents response")
            return
        end
        agents = data
        -- Build flat agent-option list; only primary agents are user-selectable.
        local opts = {}
        if type(data) == "table" then
            for _, a in ipairs(data) do
                if type(a) == "table" and type(a.name) == "string" then
                    if a.mode == "primary" or a.mode == nil then
                        opts[#opts + 1] = { value = a.name, label = a.name }
                    end
                end
            end
        end
        table.sort(opts, function(x, y) return x.label < y.label end)
        agent_options = opts
        mark_dirty("agents")
        publish()
    end)
end

load_initial_data = function()
    load_sessions()
    load_mcp_status()
    load_providers()
    load_agents()
    start_sse()
end

-- ── session management ───────────────────────────────────────────────────────

local function set_active_session(session)
    active_session = session
    messages = {}
    last_messages_body = nil  -- force a fresh decode for the new session
    if not session then
        optimistic_msg = nil
    end
    mark_dirty("active_session")
    mark_dirty("messages")
    if session and session.id then
        load_messages(session.id)
        persist_active_session()
    end
    publish()
end

select_session = function(session_id)
    if not safe_id(session_id) then return end
    -- Find session in list
    for _, s in ipairs(sessions) do
        if s.id == session_id then
            set_active_session(s)
            return
        end
    end
    -- Not in list — fetch it
    API.get("/session/" .. session_id, function(resp)
        if resp.ok and resp.status == 200 then
            local ok, data = pcall(noctalia.json.decode, resp.body)
            if ok and type(data) == "table" then
                set_active_session(data)
                return
            end
        end
        -- Session no longer exists
        set_last_error(tr("error.session_not_found"), session_id)
        active_session = nil
        mark_dirty("active_session")
        publish()
    end)
end

local function create_session(title)
    local body = {}
    if type(title) == "string" and title ~= "" then
        body.title = title
    end
    API.post("/session", body, function(resp)
        if resp.ok and resp.status == 200 then
            local ok, data = pcall(noctalia.json.decode, resp.body)
            if ok and type(data) == "table" then
                set_active_session(data)
                load_sessions()  -- refresh list
                clear_last_error()
                return
            end
        end
        set_last_error(tr("error.create_session_failed"), resp.body)
    end)
end

local function delete_session(session_id)
    if not safe_id(session_id) then return end
    API.delete("/session/" .. session_id, function(resp)
        if resp.ok then
            if active_session and active_session.id == session_id then
                active_session = nil
                messages = {}
                mark_dirty("active_session")
                mark_dirty("messages")
                persist_active_session()
            end
            load_sessions()
        else
            set_last_error(tr("error.delete_session_failed"), "HTTP " .. tostring(resp.status))
        end
    end)
end

local function abort_session(session_id)
    if not safe_id(session_id) then return end
    API.post("/session/" .. session_id .. "/abort", {}, function(resp)
        if not resp.ok then
            set_last_error(tr("error.abort_failed"), "HTTP " .. tostring(resp.status))
        end
    end)
end

local function rename_session(session_id, title)
    if not safe_id(session_id) then return end
    API.patch("/session/" .. session_id, { title = title }, function(resp)
        if resp.ok and resp.status == 200 then
            load_sessions()
            -- Update active session if it's the one renamed
            if active_session and active_session.id == session_id then
                local ok, data = pcall(noctalia.json.decode, resp.body)
                if ok then
                    active_session = data
                    mark_dirty("active_session")
                    publish()
                end
            end
        end
    end)
end

-- ── messaging ────────────────────────────────────────────────────────────────

-- Only send a model override when the model actually exists in the provider
-- list the server reported. A stale/unknown override (e.g. a configured
-- `default_model` pointing at a provider/model the server can't run) otherwise
-- gets sent on every turn, failing the session repeatedly — while the CLI, which
-- sends no override, works fine. When unknown, fall back to no override so the
-- server uses the session's own default.
local function model_is_known(model)
    if type(model) ~= "string" or model == "" then return false end
    for _, o in ipairs(model_options) do
        if o.value == model then return true end
    end
    return false
end

local function send_prompt(session_id, text, model, agent)
    if not safe_id(session_id) then return end
    if type(text) ~= "string" or text == "" then return end

    -- Optimistically append the user message so it appears immediately on the
    -- right. It is replaced by the server's copy once echoed (see load_messages).
    local now_ms = os.time() * 1000
    optimistic_msg = {
        info = {
            id = "local-" .. tostring(now_ms),
            role = "user",
            sessionID = session_id,
            time = { created = now_ms },
        },
        parts = { { type = "text", text = text } },
    }
    messages[#messages + 1] = optimistic_msg
    mark_dirty("messages")
    publish()

    -- Mark busy immediately so the thinking indicator shows right away.
    set_connection_status("busy")

    -- Build parts
    local parts = { { type = "text", text = text } }
    local body = { parts = parts }

    if type(model) == "string" and model ~= "" then
        -- Parse "provider/model" format
        local provider_id, model_id = model:match("([^/]+)/(.+)")
        if provider_id and model_id then
            body.model = { providerID = provider_id, modelID = model_id }
        end
    end
    if type(agent) == "string" and agent ~= "" then
        body.agent = agent
    end

    -- Use prompt_async to not block
    API.post("/session/" .. session_id .. "/prompt_async", body, function(resp)
        if resp.ok then
            clear_last_error()
        else
            -- The turn was rejected (busy session, bad model, server error…).
            -- Recover: drop the optimistic bubble and re-enable the composer.
            optimistic_msg = nil
            mark_dirty("messages")
            set_connection_status("online")
            set_last_error(tr("error.prompt_failed"),
                "HTTP " .. tostring(resp.status) .. (resp.body and (": " .. tostring(resp.body)) or ""))
            publish()
        end
    end)
end

-- ── permissions ──────────────────────────────────────────────────────────────

local function respond_to_permission(session_id, permission_id, response, remember)
    -- The panel sends response = "allow" | "allow:true" | "deny". Map those to
    -- the server's reply enum: once / always / reject.
    if not safe_id(permission_id) then return end
    local reply = "reject"
    if response == "allow" then
        reply = remember and "always" or "once"
    end
    local body = { reply = reply }
    API.post("/permission/" .. permission_id .. "/reply", body, function(resp)
        if resp.ok then
            -- Remove from pending
            for i, p in ipairs(pending_permissions) do
                if p.permissionID == permission_id then
                    table.remove(pending_permissions, i)
                    break
                end
            end
            mark_dirty("pending_permissions")
            set_connection_status("online")
            publish()
        else
            set_last_error(tr("error.permission_failed"), "HTTP " .. tostring(resp.status))
        end
    end)
end

local function respond_to_question(request_id, answers)
    -- answers: array of arrays of selected option labels (one inner array per
    -- question, in order). The request body must be a JSON array of arrays.
    if not safe_id(request_id) then return end
    if type(answers) ~= "table" then return end
    local body = { answers = answers }
    API.post("/question/" .. request_id .. "/reply", body, function(resp)
        if resp.ok then
            for i, q in ipairs(pending_questions) do
                if q.requestID == request_id then
                    table.remove(pending_questions, i)
                    break
                end
            end
            mark_dirty("pending_questions")
            set_connection_status("online")
            publish()
        else
            set_last_error(tr("error.question_failed"), "HTTP " .. tostring(resp.status))
        end
    end)
end

local function reject_question(request_id)
    if not safe_id(request_id) then return end
    API.post("/question/" .. request_id .. "/reject", {}, function(resp)
        if resp.ok then
            for i, q in ipairs(pending_questions) do
                if q.requestID == request_id then
                    table.remove(pending_questions, i)
                    break
                end
            end
            mark_dirty("pending_questions")
            set_connection_status("online")
            publish()
        else
            set_last_error(tr("error.question_failed"), "HTTP " .. tostring(resp.status))
        end
    end)
end

-- ── SSE event stream ────────────────────────────────────────────────────────

local SSE = {}

-- Throttle for message reloads during streaming (os.clock gives fractional seconds)
last_messages_reload = 0
RELOAD_THROTTLE_S = 0.3

-- Dedup set for unread counting (prevents inflating count on every part update)
local counted_messages = {}
local COUNTED_MAX = 100

-- Parse SSE event data
local function parse_sse_line(line)
    if line == nil then return nil, nil end
    if line == "" then return nil, nil end
    if line:sub(1, 6) == "data: " then
        local json_str = line:sub(7)
        local ok, data = pcall(noctalia.json.decode, json_str)
        if ok and type(data) == "table" then
            return data.type, data
        end
    end
    return nil, nil
end

function SSE.start()
    if sse_stream then return end  -- already connected
    local mode = get_server_mode()
    local base_url
    if mode == "external" then
        base_url = get_server_url()
        if base_url == "" then return end
    else
        base_url = "http://" .. get_server_host() .. ":" .. tostring(get_server_port())
    end

    local url = base_url .. "/event"
    local request = {
        url = url,
        method = "GET",
        headers = { "Accept: text/event-stream" },
    }

    local buffer = ""

    sse_stream = noctalia.httpStream(request,
        -- onProgress: each line
        function(line)
            buffer = buffer .. line .. "\n"
            -- Process complete events (double newline)
            while true do
                local event_end = buffer:find("\n\n")
                if not event_end then break end
                local event_data = buffer:sub(1, event_end)
                buffer = buffer:sub(event_end + 2)

                -- Extract data lines
                for data_line in event_data:gmatch("([^\r\n]+)") do
                    local event_type, event = parse_sse_line(data_line)
                    if event_type then
                        SSE.handle_event(event_type, event)
                    end
                end
            end
        end,
        -- onFinish
        function(result)
            sse_stream = nil
            sse_reconnect_attempts = sse_reconnect_attempts + 1
            if sse_reconnect_attempts <= sse_max_reconnect then
                -- Reconnect with backoff
                local delay = math.min(1000 * (2 ^ sse_reconnect_attempts), 30000)
                -- Schedule reconnect via a sleep command
                noctalia.runAsync("sleep " .. tostring(delay / 1000) .. " && echo done", function(_)
                    SSE.start()
                end)
            else
                set_last_error(tr("error.sse_disconnected"))
            end
        end
    )
end

function SSE.stop()
    -- The stream will close when the server closes it; we just clear our ref
    sse_stream = nil
end

function SSE.handle_event(event_type, event)
    debug_log("SSE event: " .. tostring(event_type))

    if event_type == "server.connected" or event_type == "server.heartbeat" then
        -- Connection lifecycle event; heartbeat is a keepalive ping — no-op.
        return
    end

    if event_type == "message.part.updated" or event_type == "message.updated" then
        local session_id = event.sessionID or (event.properties and event.properties.sessionID)
        local props = event.properties or event
        -- Throttle message reloads during streaming
        if active_session and session_id == active_session.id then
            local now = os.clock()
            if now - last_messages_reload > RELOAD_THROTTLE_S then
                last_messages_reload = now
                load_messages(active_session.id)
            end
        end
        -- Track unread once per message (dedup by message ID)
        if props and props.role == "assistant" then
            local msg_id = props.messageID or props.id
            if msg_id and not counted_messages[msg_id] then
                counted_messages[msg_id] = true
                unread_count = unread_count + 1
                mark_dirty("unread_count")
                publish()
                -- Prevent unbounded growth
                local n = 0
                for _ in pairs(counted_messages) do n = n + 1 end
                if n > COUNTED_MAX then
                    counted_messages = {}
                end
            end
        end
        return
    end

    if event_type == "session.status" then
        local session_id = event.sessionID or (event.properties and event.properties.sessionID)
        local status = event.status or (event.properties and event.properties.status)
        -- status arrives as a table like { type = "busy" }; normalize to the string.
        local st = type(status) == "table" and status.type or status
        if session_id and st then
            session_status[session_id] = st
            mark_dirty("session_status")
            -- Update connection status based on session activity
            if active_session and active_session.id == session_id then
                if st == "processing" then
                    set_connection_status("busy")
                elseif st == "idle" then
                    set_connection_status("online")
                    unread_count = 0
                    mark_dirty("unread_count")
                elseif st == "error" then
                    set_connection_status("online")
                end
            end
            publish()
        end
        return
    end

    if event_type == "session.idle" then
        local session_id = event.sessionID or (event.properties and event.properties.sessionID)
        if session_id then
            session_status[session_id] = "idle"
            mark_dirty("session_status")
            if active_session and active_session.id == session_id then
                set_connection_status("online")
                unread_count = 0
                mark_dirty("unread_count")
                counted_messages = {}
                load_messages(session_id)
            end
            publish()
        end
        return
    end

    -- Session-level error: the server aborts the turn. Recover the UI so the
    -- composer is usable again, surface the real error, and drop the optimistic
    -- user bubble (the server did not accept the turn).
    if event_type == "session.error" then
        local props = event.properties or event.data or event
        local session_id = props and props.sessionID
        local err = props and props.error
        local name = (type(err) == "table" and err.name) or "UnknownError"
        local detail = (type(err) == "table" and type(err.data) == "table" and err.data.message)
            or tr("error.session_error_detail")
        session_status[session_id or ""] = "error"
        mark_dirty("session_status")
        if not active_session or not session_id or active_session.id == session_id then
            -- MessageAbortedError is expected when the user hits Stop; don't shout.
            if name ~= "MessageAbortedError" then
                set_last_error(tr("error.session_error"), tostring(detail))
            end
            optimistic_msg = nil
            set_connection_status("online")
            unread_count = 0
            mark_dirty("unread_count")
            if session_id then load_messages(session_id) end
        end
        publish()
        return
    end

    -- Permission events: the agent asks the user to approve a tool action.
    -- Both `permission.asked` (v1) and `permission.v2.asked` (v2) carry the
    -- request id in `properties.id` (^per) — NOT `permissionID`. Normalize that
    -- into `permissionID` for the panel's permission card.
    if event_type == "permission.asked" or event_type == "permission.v2.asked" then
        local props = event.properties or event
        if props and props.id and props.sessionID then
            local perm = {
                permissionID = props.id,
                sessionID = props.sessionID,
                permission = props.permission,
                patterns = props.patterns,
                action = props.action,
                resources = props.resources,
                save = props.save,
                metadata = props.metadata,
                tool = props.tool,
            }
            -- Reuse an existing pending card for the same id instead of duplicating.
            local found = false
            for _, p in ipairs(pending_permissions) do
                if p.permissionID == props.id then
                    found = true
                    break
                end
            end
            if not found then
                table.insert(pending_permissions, perm)
            end
            mark_dirty("pending_permissions")
            set_connection_status("waiting_permission")
            publish()
            noctalia.notify(tr("notify.permission_title"), tr("notify.permission_body"))
        end
        return
    end

    -- The permission was answered (here or on another surface); drop the card.
    if event_type == "permission.replied" or event_type == "permission.v2.replied" then
        local props = event.properties or event
        local rid = props and props.requestID
        if rid then
            for i, p in ipairs(pending_permissions) do
                if p.permissionID == rid then
                    table.remove(pending_permissions, i)
                    break
                end
            end
            mark_dirty("pending_permissions")
            set_connection_status("online")
            publish()
        end
        return
    end

    -- Question/choice events: the agent asks the user to pick among options.
    if event_type == "question.asked" then
        local props = event.properties or event
        if props and props.sessionID and type(props.questions) == "table" and #props.questions > 0 then
            local req = {
                requestID = props.id or props.requestID,
                sessionID = props.sessionID,
                questions = props.questions,
                tool = props.tool,
            }
            -- Reuse an existing pending request for the same id instead of duplicating.
            local found = false
            for _, q in ipairs(pending_questions) do
                if q.requestID == req.requestID then
                    q.questions = req.questions
                    found = true
                    break
                end
            end
            if not found then
                table.insert(pending_questions, req)
            end
            mark_dirty("pending_questions")
            set_connection_status("waiting_permission")
            publish()
        end
        return
    end

    -- The agent already got an answer (from another surface); drop the prompt.
    if event_type == "question.replied" or event_type == "question.rejected" then
        local props = event.properties or event
        local rid = props and props.requestID
        if rid then
            for i, q in ipairs(pending_questions) do
                if q.requestID == rid then
                    table.remove(pending_questions, i)
                    break
                end
            end
            mark_dirty("pending_questions")
            set_connection_status("online")
            publish()
        end
        return
    end

    -- Unknown event — log if debug
    debug_log("Unknown event: " .. tostring(event_type))
end

function start_sse()
    SSE.start()
end

function stop_sse()
    SSE.stop()
end

-- ── ipc handling ─────────────────────────────────────────────────────────────

function onIpc(event, payload)
    debug_log("IPC: " .. tostring(event))

    -- Self-heal a stale busy status: if we've been "busy" longer than the
    -- threshold with no idle/error event, the SSE update was likely dropped.
    -- Clear it so the composer unlocks and sending works again.
    if connection.status == "busy" and busy_since and (os.time() - busy_since) > BUSY_STALE_S then
        optimistic_msg = nil
        mark_dirty("messages")
        set_connection_status("online")
        if active_session then load_messages(active_session.id) end
    end

    if event == "select_session" then
        select_session(payload)
    elseif event == "deselect_session" then
        set_active_session(nil)
    elseif event == "create_session" then
        create_session(payload)
    elseif event == "delete_session" then
        if type(payload) == "string" then
            delete_session(payload)
        end
    elseif event == "abort_session" then
        if active_session then
            abort_session(active_session.id)
        end
    elseif event == "send_prompt" then
        if active_session then
            local model = ""
            if selected_model and selected_model ~= "" then
                -- An explicit pick comes from the picker (always known); guard anyway.
                if model_is_known(selected_model) then
                    model = selected_model
                end
            else
                -- Config default only if the server actually reports that model.
                -- Warn when the configured default is bogus so the user knows to
                -- fix the setting instead of silently running a different model.
                local dm = get_default_model()
                if model_is_known(dm) then
                    model = dm
                elseif dm ~= "" then
                    noctalia.log("opencode-companion: default_model " .. tostring(dm) .. " not available; sending without an override")
                end
            end
            local agent = (selected_agent and selected_agent ~= "") and selected_agent or get_default_agent()
            send_prompt(active_session.id, payload, model, agent)
        end
    elseif event == "set_model" then
        if type(payload) == "string" and payload ~= "" then
            selected_model = payload
            mark_dirty("selection")
            publish()
        end
    elseif event == "set_agent" then
        if type(payload) == "string" and payload ~= "" then
            selected_agent = payload
            mark_dirty("selection")
            publish()
        end
    elseif event == "permission_response" then
        -- payload: "permission_id:response[:remember]"
        if type(payload) == "string" and active_session then
            local perm_id, response, remember = payload:match("^([^:]+):([^:]+):?(%w*)")
            if perm_id and response then
                local rem = (remember == "true")
                respond_to_permission(active_session.id, perm_id, response, rem)
            end
        end
    elseif event == "question_reply" then
        -- payload: "requestID\2answers" where answers is a JSON string of the
        -- outer array; the panel encodes it as JSON for safe transport.
        if type(payload) == "string" and active_session then
            local rid, answers_json = payload:match("^([^\2]+)\2(.+)")
            if rid and answers_json then
                local ok, answers = pcall(noctalia.json.decode, answers_json)
                if ok and type(answers) == "table" then
                    respond_to_question(rid, answers)
                end
            end
        end
    elseif event == "question_reject" then
        if type(payload) == "string" and active_session then
            reject_question(payload)
        end
    elseif event == "refresh" then
        load_initial_data()
    elseif event == "reconnect" then
        connect()
    elseif event == "clear_unread" then
        unread_count = 0
        mark_dirty("unread_count")
        publish()
    elseif event == "clear_error" then
        last_error = nil
        mark_dirty("last_error")
        publish()
    elseif event == "rename_session" then
        if type(payload) == "string" then
            local id, title = payload:match("^([^:]+):(.+)")
            if id and title then
                rename_session(id, title)
            end
        end
    end
end

-- ── init ─────────────────────────────────────────────────────────────────────

function onOpen()
    boot_id = read_boot_id()
    -- Build state file path in plugin data dir
    local plugin_dir = noctalia.pluginDataDir and noctalia.pluginDataDir()
    if plugin_dir then
        state_file = plugin_dir .. "/opencode_state.json"
    end

    -- Initialize state
    mark_dirty("all")
    publish()

    -- Attempt connection (skip if the user disabled auto_start; they can
    -- still reconnect manually via the panel's refresh/reconnect action).
    if get_auto_start() then
        connect()
    end
end

function onExit()
    SSE.stop()
    managed_pid = nil
    sse_stream = nil
end

-- Start on load
onOpen()
