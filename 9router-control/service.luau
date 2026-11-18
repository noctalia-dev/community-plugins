-- 9Router Control service — the headless backend and single source of truth.
--
-- Responsibilities:
--   • Talk to the 9Router REST API (GET/POST/PUT/DELETE /api/combos)
--   • Authenticate: plain requests work when the dashboard has login disabled
--     (the default local setup); on a 401 we compute the CLI token from the
--     machine-id + cli-secret files and retry with the x-9r-cli-token header.
--   • Track connection state, the combo list, and the selected combo
--   • Publish shared state for the widget and panel subscribers
--
-- The widget and panel are pure subscribers of `9router.*` state keys.

-- ── helpers ─────────────────────────────────────────────────────────────────

-- Translation with an optional per-plugin language override (mirrors panel.luau).
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
        noctalia.log("9router-control: " .. tostring(msg))
    end
end

-- Single-quote a value so it is treated as a literal argument by the shell,
-- neutralising any metacharacters in user-provided strings (data_dir, host).
local function shell_quote(value)
    return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function get_server_host()
    local v = noctalia.getConfig and noctalia.getConfig("server_host")
    if type(v) == "string" and v ~= "" then return v end
    return "127.0.0.1"
end

local function get_server_port()
    local v = noctalia.getConfig and noctalia.getConfig("server_port")
    if type(v) == "number" and v > 0 then return v end
    return 20128
end

local function get_data_dir()
    local v = noctalia.getConfig and noctalia.getConfig("data_dir")
    if type(v) == "string" and v ~= "" then return v end
    return "~/.9router"
end

-- ── state ────────────────────────────────────────────────────────────────────

local connection = { status = "offline", error = "" }
local combos = {}
local models = {}
local selected_combo_id = nil
local last_error = nil
local auth_token = nil -- JWT cookie captured from a successful login

local function publish()
    noctalia.state.set("9router.connection", connection)
    noctalia.state.set("9router.combos", combos)
    noctalia.state.set("9router.models", models)
    noctalia.state.set("9router.selected_combo", selected_combo_id)
    noctalia.state.set("9router.last_error", last_error)
end

local function set_connection(status, err)
    connection = { status = status, error = err or "" }
    publish()
end

local function set_last_error(message, detail)
    last_error = { message = message, detail = detail }
    publish()
end

local function clear_last_error()
    last_error = nil
    publish()
end

-- ── HTTP ─────────────────────────────────────────────────────────────────────

local base_url = nil
local cli_token = nil
local token_loading = false

local function build_base_url()
    return "http://" .. get_server_host() .. ":" .. tostring(get_server_port())
end

-- Compute the 9Router CLI token: sha256(rawMachineId + "9r-cli-auth" +
-- cliSecret).substring(0,16). Noctalia has no sha256 binding, so we shell out.
-- The command reads the machine-id and cli-secret files from the data dir.
local function compute_cli_token(callback)
    if cli_token then
        callback(cli_token)
        return
    end
    if token_loading then
        -- Wait for the in-flight computation to finish.
        local tries = 0
        local function poll()
            tries = tries + 1
            if cli_token then
                callback(cli_token)
            elseif tries > 50 then
                callback(nil)
            else
                noctalia.runAsync("sleep 0.1 && echo done", function()
                    poll()
                end)
            end
        end
        poll()
        return
    end
    token_loading = true
    local dir = get_data_dir()
    -- Expand a leading "~/" to the user's home directory here (not in the
    -- shell) so the path is an absolute path with no shell variable expansion
    -- and can be safely single-quoted.
    if dir:sub(1, 2) == "~/" then
        dir = (noctalia.getenv and noctalia.getenv("HOME") or "") .. dir:sub(2)
    end
    local cmd = "printf '%s' \"$(cat " .. shell_quote(dir .. "/machine-id") .. " 2>/dev/null)9r-cli-auth$(cat " .. shell_quote(dir .. "/auth/cli-secret") .. " 2>/dev/null)\" | sha256sum | cut -c1-16"
    noctalia.runAsync(cmd, function(result)
        token_loading = false
        local token = ""
        if result and result.exitCode == 0 and type(result.stdout) == "string" then
            token = noctalia.string and noctalia.string.trim and noctalia.string.trim(result.stdout) or result.stdout
        end
        if token ~= "" then
            cli_token = token
            debug_log("computed CLI token")
        end
        callback(token ~= "" and token or nil)
    end)
end

-- Perform a request with auth fallback. `with_token` is true on the retry pass.
-- Once a CLI token or login cookie is known it is attached to every request, so
-- the retry only fires when a 401 arrives before we have any auth material.
local function request(method, path, body, callback, with_token)
    local url = (base_url or build_base_url()) .. path
    local headers = { "Accept: application/json" }
    local body_str = nil
    if body then
        body_str = noctalia.json.encode(body)
        table.insert(headers, "Content-Type: application/json")
    end
    -- Attach the CLI token on every request once it is known.
    if cli_token then
        table.insert(headers, "x-9r-cli-token: " .. cli_token)
    end
    -- Attach the login cookie on every request once it is known.
    if auth_token then
        table.insert(headers, "Cookie: auth_token=" .. auth_token)
    end
    noctalia.http({
        url = url,
        method = method,
        headers = headers,
        body = body_str,
        follow_redirects = false,
    }, function(response)
        if not response then
            callback({ ok = false, status = 0, body = "" })
            return
        end
        local status = response.status or 0
        -- On 401: if we have not tried with auth yet, compute the CLI token (if
        -- needed) and retry once. If we already have auth material but still got
        -- a 401, the token/cookie is stale — surface it so the UI can re-login.
        if status == 401 and not with_token then
            if cli_token or auth_token then
                request(method, path, body, callback, true)
            else
                compute_cli_token(function(token)
                    if token then
                        request(method, path, body, callback, true)
                    else
                        callback({ ok = false, status = status, body = response.body })
                    end
                end)
            end
            return
        end
        callback({ ok = status >= 200 and status < 300, status = status, body = response.body })
    end)
end

local function decode_body(body)
    if type(body) ~= "string" or body == "" then return nil end
    local ok, data = pcall(noctalia.json.decode, body)
    if not ok or type(data) ~= "table" then return nil end
    return data
end

-- ── combo operations ─────────────────────────────────────────────────────────

local function load_combos()
    request("GET", "/api/combos", nil, function(resp)
        if not resp.ok then
            if resp.status == 0 then
                set_connection("offline", tr("error.connection_failed"))
            elseif resp.status == 401 then
                set_connection("auth_required", tr("error.auth_required"))
            else
                set_connection("offline", tr("error.http_status", { status = tostring(resp.status) }))
            end
            return
        end
        local data = decode_body(resp.body)
        if not data or type(data.combos) ~= "table" then
            set_connection("offline", tr("error.bad_response"))
            return
        end
        combos = data.combos
        set_connection("online", "")
        clear_last_error()
        publish()
    end)
end

local function refresh_combos()
    load_combos()
end

local function load_models()
    request("GET", "/api/models", nil, function(resp)
        if not resp.ok then return end
        local data = decode_body(resp.body)
        if not data or type(data.models) ~= "table" then return end
        models = data.models
        publish()
    end)
end

local function select_combo(id)
    selected_combo_id = id
    publish()
end

local function back_to_list()
    selected_combo_id = nil
    publish()
end

local function find_combo(id)
    for _, c in ipairs(combos) do
        if type(c) == "table" and c.id == id then return c end
    end
    return nil
end

local function reorder_model(payload)
    -- payload: "combo_id:index:direction"
    local id, idx_str, direction = payload:match("^([^:]+):(%d+):(%w+)$")
    if not id or not idx_str or not direction then return end
    local combo = find_combo(id)
    if not combo or type(combo.models) ~= "table" then return end
    local idx = tonumber(idx_str)
    local models = {}
    for _, m in ipairs(combo.models) do models[#models + 1] = m end
    local n = #models
    if idx < 1 or idx > n then return end
    local target = direction == "up" and idx - 1 or idx + 1
    if target < 1 or target > n then return end
    models[idx], models[target] = models[target], models[idx]
    request("PUT", "/api/combos/" .. id, { models = models }, function(resp)
        if resp.ok then
            refresh_combos()
        else
            set_last_error(tr("error.reorder_failed"), tr("error.http_status", { status = tostring(resp.status) }))
        end
    end)
end

local function move_model(payload)
    -- payload: "combo_id:from_index:to_index" (1-based)
    local id, from_str, to_str = payload:match("^([^:]+):(%d+):(%d+)$")
    if not id or not from_str or not to_str then return end
    local combo = find_combo(id)
    if not combo or type(combo.models) ~= "table" then return end
    local from = tonumber(from_str)
    local to = tonumber(to_str)
    local models = {}
    for _, m in ipairs(combo.models) do models[#models + 1] = m end
    local n = #models
    if from < 1 or from > n or to < 1 or to > n or from == to then return end
    local moved = table.remove(models, from)
    table.insert(models, to, moved)
    request("PUT", "/api/combos/" .. id, { models = models }, function(resp)
        if resp.ok then
            refresh_combos()
        else
            set_last_error(tr("error.reorder_failed"), tr("error.http_status", { status = tostring(resp.status) }))
        end
    end)
end

local function add_model(payload)
    -- payload: "combo_id:model_fullModel" (provider/model)
    local id, model = payload:match("^([^:]+):(.+)$")
    if not id or not model or model == "" then return end
    local combo = find_combo(id)
    if not combo or type(combo.models) ~= "table" then return end
    local models = {}
    for _, m in ipairs(combo.models) do models[#models + 1] = m end
    for _, m in ipairs(models) do
        if m == model then return end -- already present
    end
    models[#models + 1] = model
    request("PUT", "/api/combos/" .. id, { models = models }, function(resp)
        if resp.ok then
            refresh_combos()
        else
            set_last_error(tr("error.add_model_failed"), tr("error.http_status", { status = tostring(resp.status) }))
        end
    end)
end

local function remove_model(payload)
    -- payload: "combo_id:index" (1-based)
    local id, idx_str = payload:match("^([^:]+):(%d+)$")
    if not id or not idx_str then return end
    local combo = find_combo(id)
    if not combo or type(combo.models) ~= "table" then return end
    local idx = tonumber(idx_str)
    local models = {}
    for _, m in ipairs(combo.models) do models[#models + 1] = m end
    if idx < 1 or idx > #models then return end
    table.remove(models, idx)
    request("PUT", "/api/combos/" .. id, { models = models }, function(resp)
        if resp.ok then
            refresh_combos()
        else
            set_last_error(tr("error.remove_model_failed"), tr("error.http_status", { status = tostring(resp.status) }))
        end
    end)
end

local function create_combo(payload)
    -- payload: JSON string { name, models, kind }
    local ok, data = pcall(noctalia.json.decode, payload)
    if not ok or type(data) ~= "table" then return end
    local name = type(data.name) == "string" and data.name or ""
    local models = type(data.models) == "table" and data.models or {}
    local kind = type(data.kind) == "string" and data.kind or nil
    if name == "" or #models == 0 then
        set_last_error(tr("error.create_failed"), tr("error.need_name_models"))
        return
    end
    request("POST", "/api/combos", { name = name, models = models, kind = kind }, function(resp)
        if resp.ok then
            refresh_combos()
        else
            local data2 = decode_body(resp.body)
            local detail = (type(data2) == "table" and type(data2.error) == "string" and data2.error)
                or tr("error.http_status", { status = tostring(resp.status) })
            set_last_error(tr("error.create_failed"), detail)
        end
    end)
end

local function delete_combo(id)
    request("DELETE", "/api/combos/" .. id, nil, function(resp)
        if resp.ok then
            if selected_combo_id == id then selected_combo_id = nil end
            refresh_combos()
        else
            set_last_error(tr("error.delete_failed"), tr("error.http_status", { status = tostring(resp.status) }))
        end
    end)
end

local function rename_combo(payload)
    -- payload: "combo_id:new_name"
    local id, name = payload:match("^([^:]+):(.+)$")
    if not id or not name or name == "" then return end
    request("PUT", "/api/combos/" .. id, { name = name }, function(resp)
        if resp.ok then
            refresh_combos()
        else
            local data = decode_body(resp.body)
            local detail = (type(data) == "table" and type(data.error) == "string" and data.error)
                or tr("error.http_status", { status = tostring(resp.status) })
            set_last_error(tr("error.rename_failed"), detail)
        end
    end)
end

local function set_kind(payload)
    -- payload: "combo_id:kind"
    local id, kind = payload:match("^([^:]+):(.+)$")
    if not id or not kind then return end
    local value = (kind == "none" or kind == "") and nil or kind
    request("PUT", "/api/combos/" .. id, { kind = value }, function(resp)
        if resp.ok then
            refresh_combos()
        else
            set_last_error(tr("error.kind_failed"), tr("error.http_status", { status = tostring(resp.status) }))
        end
    end)
end

-- ── auth (login / logout) ────────────────────────────────────────────────────

-- Log in against the dashboard and capture the auth_token cookie. Noctalia's
-- http binding does not expose response headers, so we shell out to curl with
-- `-i` to read the Set-Cookie header, then reuse the cookie on later requests.
local function login(payload)
    if type(payload) ~= "string" or payload == "" then
        set_last_error(tr("error.login_failed"), tr("error.need_password"))
        return
    end
    local url = (base_url or build_base_url()) .. "/api/auth/login"
    -- Escape the password for the JSON body, then for the shell single-quote.
    local json_password = payload:gsub("\\", "\\\\"):gsub('"', '\\"')
    local body = '{"password":"' .. json_password .. '"}'
    local cmd = "curl -s -i -X POST " .. shell_quote(url) .. " -H 'Content-Type: application/json' -d " .. shell_quote(body)
    debug_log("login: posting to /api/auth/login")
    noctalia.runAsync(cmd, function(result)
        if not result or result.exitCode ~= 0 then
            set_last_error(tr("error.login_failed"), tr("error.connection_failed"))
            return
        end
        local stdout = result.stdout or ""
        local cookie = stdout:match("auth_token=([^;%s]+)")
        if not cookie then
            -- No cookie set — likely a bad password. Surface the server error.
            local body_part = stdout:match("\r?\n\r?\n(.*)$") or stdout
            local ok, data = pcall(noctalia.json.decode, body_part)
            local detail = (ok and type(data) == "table" and type(data.error) == "string" and data.error)
                or tr("error.login_failed")
            set_last_error(tr("error.login_failed"), detail)
            return
        end
        auth_token = cookie
        debug_log("login: authenticated")
        clear_last_error()
        set_connection("online", "")
        load_combos()
    end)
end

local function logout()
    auth_token = nil
    cli_token = nil
    set_connection("auth_required", tr("error.auth_required"))
end

-- ── ipc handling ─────────────────────────────────────────────────────────────

function onIpc(event, payload)
    debug_log("IPC: " .. tostring(event))
    if event == "refresh" then
        refresh_combos()
    elseif event == "select_combo" then
        if type(payload) == "string" then select_combo(payload) end
    elseif event == "back_to_list" then
        back_to_list()
    elseif event == "reorder_model" then
        if type(payload) == "string" then reorder_model(payload) end
    elseif event == "move_model" then
        if type(payload) == "string" then move_model(payload) end
    elseif event == "add_model" then
        if type(payload) == "string" then add_model(payload) end
    elseif event == "remove_model" then
        if type(payload) == "string" then remove_model(payload) end
    elseif event == "create_combo" then
        if type(payload) == "string" then create_combo(payload) end
    elseif event == "delete_combo" then
        if type(payload) == "string" then delete_combo(payload) end
    elseif event == "rename_combo" then
        if type(payload) == "string" then rename_combo(payload) end
    elseif event == "set_kind" then
        if type(payload) == "string" then set_kind(payload) end
    elseif event == "login" then
        if type(payload) == "string" then login(payload) end
    elseif event == "logout" then
        logout()
    elseif event == "clear_error" then
        clear_last_error()
    end
end

-- ── init ─────────────────────────────────────────────────────────────────────

function onOpen()
    base_url = build_base_url()
    publish()
    load_combos()
    load_models()
end

function onExit()
end

-- Start on load
onOpen()
