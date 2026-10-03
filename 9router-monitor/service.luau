--!nonstrict
-- 9Router Monitor — Pure Native Luau background service.
-- Owns native SSE live stream, async HTTP polling, quota aggregation, and busy-state detection.
-- Zero external Python dependencies.

noctalia.setUpdateInterval(1000)

local sha256 = require("./sha256.luau")

local data_dir = noctalia.pluginDataDir()
local state_file = data_dir .. "/last.json"
local cookie_file = data_dir .. "/cookie.txt"

local KEYRING_SERVICE = "9router-monitor"
local KEYRING_ACCOUNT = "dashboard"

-- ── Configuration helpers ───────────────────────────────────────────────────

local function cfg_host()
    local h = noctalia.getConfig("dashboard_host")
    if type(h) == "string" and h:match("%S") then
        return h:match("^%s*(.-)%s*$")
    end
    return "localhost"
end

local function cfg_port()
    local p = noctalia.getConfig("dashboard_port")
    if type(p) == "number" and p > 0 and p <= 65535 then
        return math.floor(p)
    end
    return 20128
end

local function cfg_refresh_seconds()
    local s = noctalia.getConfig("refresh_seconds")
    if type(s) == "number" and s >= 2 and s <= 120 then
        return math.floor(s)
    end
    return 5
end

local function cfg_busy_hold_seconds()
    local b = noctalia.getConfig("busy_hold_seconds")
    if type(b) == "number" and b >= 3 and b <= 60 then
        return math.floor(b)
    end
    return 12
end

local function cfg_remember_password()
    local r = noctalia.getConfig("remember_password")
    if r == false then return false end
    return true
end

local function cfg_show_model_label()
    local s = noctalia.getConfig("show_model_label")
    if s == false then return false end
    return true
end

local function cfg_auth_mode()
    local m = noctalia.getConfig("auth_mode")
    if type(m) == "string" and m ~= "" then
        return m
    end
    return "cli_token"
end

local function cfg_cli_token_path()
    local p = noctalia.getConfig("cli_token_path")
    if type(p) == "string" and p ~= "" then
        return p
    end
    return "~/.9router"
end

local function cfg_dashboard_password()
    local p = noctalia.getConfig("dashboard_password")
    if type(p) == "string" and p ~= "" then
        return p
    end
    return ""
end

local function get_resolved_url()
    local host = cfg_host()
    local port = cfg_port()
    if host ~= "" and port > 0 then
        local scheme = "http"
        if host:match("^https://") then
            scheme = "https"
            host = host:gsub("^https://", "")
        elseif host:match("^http://") then
            host = host:gsub("^http://", "")
        end
        return string.format("%s://%s:%d", scheme, host, port)
    end
    local base = noctalia.getConfig("base_url")
    if type(base) == "string" and base ~= "" then
        return base:gsub("/+$", "")
    end
    return "http://localhost:20128"
end

-- ── Service State ───────────────────────────────────────────────────────────

local auth = "unknown" -- "unknown" | "ok" | "expired" | "offline"
local error_text = ""
local login_error = ""
local logging_in = false

local active_requests = {}
local recent_requests = {}
local quotas = {}
local models_usage = { ["today"] = {}, ["24h"] = {}, ["7d"] = {}, ["30d"] = {}, ["60d"] = {} }
local period_totals = { ["today"] = {}, ["24h"] = {}, ["7d"] = {}, ["30d"] = {}, ["60d"] = {} }

local last_model = ""
local last_provider = ""
local last_timestamp = ""
local last_fetch_text = ""

local last_arrival_ms = 0
local seen_primed = false
local last_seen_key = ""

local stream_active = false
local current_stream_handle = nil
local next_stream_reconnect_ms = 0
local ticks_since_poll = 0
local session_cookie = ""

-- ── State Persistence ───────────────────────────────────────────────────────

local function load_saved_last()
    local raw = noctalia.readFile(state_file)
    if type(raw) == "string" and raw ~= "" then
        local data = noctalia.json.decode(raw)
        if type(data) == "table" then
            if data.last_model then last_model = tostring(data.last_model) end
            if data.last_provider then last_provider = tostring(data.last_provider) end
            if data.last_timestamp then last_timestamp = tostring(data.last_timestamp) end
        end
    end
end

local function save_last()
    local data = {
        last_model = last_model,
        last_provider = last_provider,
        last_timestamp = last_timestamp,
    }
    pcall(noctalia.writeFile, state_file, noctalia.json.encode(data))
end

local function load_saved_cookie()
    local raw = noctalia.readFile(cookie_file)
    if type(raw) == "string" and raw ~= "" then
        session_cookie = raw:match("^%s*(.-)%s*$")
    end
end

local function save_cookie(cookie)
    session_cookie = cookie
    if cookie and cookie ~= "" then
        pcall(noctalia.writeFile, cookie_file, cookie)
    else
        pcall(noctalia.removeFile, cookie_file)
    end
end

-- ── Authentication Token & Headers ──────────────────────────────────────────

local function get_cli_token()
    local base_dir = cfg_cli_token_path()
    local expanded = noctalia.expandPath(base_dir)
    local mid_raw = noctalia.readFile(expanded .. "/machine-id")
    local sec_raw = noctalia.readFile(expanded .. "/auth/cli-secret")
    if type(mid_raw) ~= "string" or type(sec_raw) ~= "string" then
        return nil
    end

    local mid = mid_raw:match("^%s*(.-)%s*$")
    local sec = sec_raw:match("^%s*(.-)%s*$")
    if not mid or mid == "" or not sec or sec == "" then
        return nil
    end

    local raw = mid .. "9r-cli-auth" .. sec
    return sha256.hex(raw):sub(1, 16)
end

local function get_auth_headers()
    local mode = cfg_auth_mode()
    local headers = {}
    if mode == "cli_token" then
        local token = get_cli_token()
        if token then
            table.insert(headers, "x-9r-cli-token: " .. token)
        end
    elseif mode == "password" then
        if session_cookie and session_cookie ~= "" then
            table.insert(headers, "Cookie: " .. session_cookie)
        end
    end
    return headers
end

-- ── Busy & State Publishing ────────────────────────────────────────────────

local function is_busy()
    if #active_requests > 0 then return true end
    if last_arrival_ms > 0 then
        local elapsed = (noctalia.nowMs() - last_arrival_ms) / 1000
        return elapsed < cfg_busy_hold_seconds()
    end
    return false
end

local function current_display_model()
    if #active_requests > 0 and type(active_requests[1]) == "table" and active_requests[1].model then
        return tostring(active_requests[1].model)
    end
    if is_busy() and last_model ~= "" then
        return last_model
    end
    return last_model
end

local function publish_state()
    noctalia.state.set("9router.status", {
        auth = auth,
        busy = is_busy(),
        server_active = (#active_requests > 0),
        display_model = current_display_model(),
        last_model = last_model,
        last_provider = last_provider,
        last_timestamp = last_timestamp,
        last_fetch_text = last_fetch_text,
        base_url = get_resolved_url(),
        error_text = error_text,
        login_error = login_error,
        logging_in = logging_in,
        active_requests = active_requests,
        recent_requests = recent_requests,
        quotas = quotas,
        models_usage = models_usage,
        period_totals = period_totals,
        show_model_label = cfg_show_model_label(),
    })
end

-- ── Normalization Helpers ───────────────────────────────────────────────────

local function round1(num)
    return math.floor((num or 0) * 10 + 0.5) / 10
end

local function round2(num)
    return math.floor((num or 0) * 100 + 0.5) / 100
end

local function round4(num)
    return math.floor((num or 0) * 10000 + 0.5) / 10000
end

local function calc_rem_pct(q)
    if q.remainingPercentage ~= nil then
        local p = tonumber(q.remainingPercentage)
        if p ~= nil then return p end
    end
    local tot = tonumber(q.total) or 1000
    local used = tonumber(q.used) or 0
    if tot > 0 then
        return math.max(0.0, 100.0 - (used / tot * 100.0))
    end
    return 100.0
end

local function summarize_antigravity(quotas_dict)
    local weekly_set = { gemini_weekly = true, claude_gpt_weekly = true }
    local gemini_pool = {}
    local claude_pool = {}
    local other_pool = {}
    local image_pool = {}

    for k, q in pairs(quotas_dict) do
        if type(q) == "table" then
            local is_gemini = (k:find("^gemini%-") ~= nil or k == "gemini-pro-agent") and k:find("image") == nil
            local is_claude = k:find("^claude%-") ~= nil
            local is_image = k:find("image") ~= nil

            if is_gemini then
                table.insert(gemini_pool, { k = k, q = q })
            elseif is_claude then
                table.insert(claude_pool, { k = k, q = q })
            elseif is_image then
                table.insert(image_pool, { k = k, q = q })
            elseif not weekly_set[k] and k ~= "gemini-pro-agent" then
                table.insert(other_pool, { k = k, q = q })
            end
        end
    end

    local res = {}

    -- 1. Gemini (Flash / Pro)
    if #gemini_pool > 0 then
        local min_item = gemini_pool[1]
        local min_pct = calc_rem_pct(min_item.q)
        for i = 2, #gemini_pool do
            local p = calc_rem_pct(gemini_pool[i].q)
            if p < min_pct then
                min_item = gemini_pool[i]
                min_pct = p
            end
        end
        local q = min_item.q
        table.insert(res, {
            id = "gemini_flash_pro",
            display_name = "Gemini (Flash / Pro)",
            used = round2(tonumber(q.used) or 0),
            total = round2(tonumber(q.total) or 1000),
            remaining_percentage = round1(min_pct),
            reset_at = tostring(q.resetAt or ""),
            unlimited = (q.unlimited == true),
        })
    end

    -- 2. Claude (Sonnet / Opus)
    if #claude_pool > 0 then
        local min_item = claude_pool[1]
        local min_pct = calc_rem_pct(min_item.q)
        for i = 2, #claude_pool do
            local p = calc_rem_pct(claude_pool[i].q)
            if p < min_pct then
                min_item = claude_pool[i]
                min_pct = p
            end
        end
        local q = min_item.q
        table.insert(res, {
            id = "claude_sonnet_opus",
            display_name = "Claude (Sonnet / Opus)",
            used = round2(tonumber(q.used) or 0),
            total = round2(tonumber(q.total) or 1000),
            remaining_percentage = round1(min_pct),
            reset_at = tostring(q.resetAt or ""),
            unlimited = (q.unlimited == true),
        })
    end

    -- 3. Non-gemini / non-claude / non-image (e.g. GPT-OSS 120B)
    for _, item in ipairs(other_pool) do
        local q = item.q
        table.insert(res, {
            id = tostring(item.k),
            display_name = tostring(q.displayName or item.k),
            used = round2(tonumber(q.used) or 0),
            total = round2(tonumber(q.total) or 1000),
            remaining_percentage = round1(calc_rem_pct(q)),
            reset_at = tostring(q.resetAt or ""),
            unlimited = (q.unlimited == true),
        })
    end

    -- 4. Image models (e.g. Gemini 3.1 Flash Image)
    for _, item in ipairs(image_pool) do
        local q = item.q
        table.insert(res, {
            id = tostring(item.k),
            display_name = tostring(q.displayName or item.k),
            used = round2(tonumber(q.used) or 0),
            total = round2(tonumber(q.total) or 1000),
            remaining_percentage = round1(calc_rem_pct(q)),
            reset_at = tostring(q.resetAt or ""),
            unlimited = (q.unlimited == true),
        })
    end

    -- 5. Weekly pools (Gemini Weekly, Claude & GPT Weekly)
    for _, k in ipairs({ "gemini_weekly", "claude_gpt_weekly" }) do
        if quotas_dict[k] and type(quotas_dict[k]) == "table" then
            local q = quotas_dict[k]
            table.insert(res, {
                id = k,
                display_name = tostring(q.displayName or k),
                used = round2(tonumber(q.used) or 0),
                total = round2(tonumber(q.total) or 1000),
                remaining_percentage = round1(calc_rem_pct(q)),
                reset_at = tostring(q.resetAt or ""),
                unlimited = (q.unlimited == true),
            })
        end
    end

    return res
end

local function norm_active(items)
    local out = {}
    if type(items) ~= "table" then return out end
    local max_items = 10
    local count = #items
    if count > max_items then count = max_items end
    for i = 1, count do
        local entry = items[i]
        if type(entry) == "table" and entry.model then
            table.insert(out, {
                id = tostring(entry.id or entry.requestId or ""),
                model = tostring(entry.model or ""),
                provider = tostring(entry.provider or ""),
                duration_ms = tonumber(entry.durationMs or entry.duration_ms) or 0,
                started_at = tostring(entry.startedAt or entry.started_at or ""),
            })
        end
    end
    return out
end

local function norm_recent(items)
    local out = {}
    if type(items) ~= "table" then return out end
    local max_items = 15
    local count = #items
    if count > max_items then count = max_items end
    for i = 1, count do
        local entry = items[i]
        if type(entry) == "table" and entry.model then
            table.insert(out, {
                model = tostring(entry.model or ""),
                provider = tostring(entry.provider or ""),
                timestamp = tostring(entry.timestamp or ""),
                status = tostring(entry.status or "ok"),
                prompt_tokens = tonumber(entry.promptTokens or entry.prompt_tokens) or 0,
                completion_tokens = tonumber(entry.completionTokens or entry.completion_tokens) or 0,
                cached_tokens = tonumber(entry.cachedTokens or entry.cached_tokens) or 0,
                cost = tonumber(entry.cost) or 0.0,
            })
        end
    end
    return out
end

-- ── Polling: Quotas & Model Stats ───────────────────────────────────────────

local function fetch_quotas()
    local base = get_resolved_url()
    local headers = get_auth_headers()
    table.insert(headers, "Accept: application/json")

    noctalia.http({
        url = base .. "/api/providers",
        method = "GET",
        headers = headers,
    }, function(res)
        if not res or not res.ok or res.status ~= 200 or not res.body then
            return
        end
        local pdata = noctalia.json.decode(res.body)
        if type(pdata) ~= "table" then return end
        local connections = pdata.connections
        if type(connections) ~= "table" then return end

        local new_quotas = {}
        local pending = #connections

        if pending == 0 then
            quotas = new_quotas
            publish_state()
            return
        end

        for _, conn in ipairs(connections) do
            if type(conn) == "table" and conn.id then
                local cid = conn.id
                local provider = tostring(conn.provider or "")
                local name = tostring(conn.name or conn.email or conn.displayName or provider)
                local is_active = (conn.isActive ~= false)
                local priority = tonumber(conn.priority) or 1

                local q_headers = get_auth_headers()
                table.insert(q_headers, "Accept: application/json")

                noctalia.http({
                    url = base .. "/api/usage/" .. cid,
                    method = "GET",
                    headers = q_headers,
                }, function(qres)
                    pending -= 1
                    local quotas_list = {}
                    local plan = ""
                    if qres and qres.ok and qres.status == 200 and qres.body then
                        local qdata = noctalia.json.decode(qres.body)
                        if type(qdata) == "table" then
                            plan = tostring(qdata.plan or "")
                            local raw_quotas = qdata.quotas
                            if type(raw_quotas) == "table" then
                                if provider:lower() == "antigravity" then
                                    quotas_list = summarize_antigravity(raw_quotas)
                                else
                                    for qk, q in pairs(raw_quotas) do
                                        if type(q) == "table" then
                                            local disp = tostring(q.displayName or qk)
                                            local used = tonumber(q.used) or 0
                                            local total = tonumber(q.total) or 1000
                                            table.insert(quotas_list, {
                                                id = tostring(qk),
                                                display_name = disp,
                                                used = round2(used),
                                                total = round2(total),
                                                remaining_percentage = round1(calc_rem_pct(q)),
                                                reset_at = tostring(q.resetAt or ""),
                                                unlimited = (q.unlimited == true),
                                            })
                                        end
                                    end
                                    table.sort(quotas_list, function(a, b) return tostring(a.id):lower() < tostring(b.id):lower() end)
                                end
                            end
                        end
                    end

                    table.insert(new_quotas, {
                        id = cid,
                        provider = provider,
                        name = name,
                        is_active = is_active,
                        priority = priority,
                        plan = plan,
                        quotas = quotas_list,
                    })

                    if pending <= 0 then
                        table.sort(new_quotas, function(a, b) return (a.priority or 1) < (b.priority or 1) end)
                        quotas = new_quotas
                        publish_state()
                    end
                end)
            else
                pending -= 1
            end
        end
    end)
end

local function fetch_models_usage_all()
    local base = get_resolved_url()
    local periods = { "today", "24h", "7d", "30d", "60d" }

    for _, period in ipairs(periods) do
        local headers = get_auth_headers()
        table.insert(headers, "Accept: application/json")

        noctalia.http({
            url = base .. "/api/usage/stats?period=" .. period,
            method = "GET",
            headers = headers,
        }, function(res)
            if not res or not res.ok or res.status ~= 200 or not res.body then
                return
            end
            local data = noctalia.json.decode(res.body)
            if type(data) ~= "table" then return end

            if (period == "today" or period == "24h") and type(data.recentRequests) == "table" and #data.recentRequests > 0 then
                if #recent_requests == 0 then
                    recent_requests = norm_recent(data.recentRequests)
                end
                if last_model == "" and #recent_requests > 0 then
                    local top = recent_requests[1]
                    last_model = tostring(top.model or "")
                    last_provider = tostring(top.provider or "")
                    last_timestamp = tostring(top.timestamp or "")
                    save_last()
                end
            end

            period_totals[period] = {
                requests = tonumber(data.totalRequests) or 0,
                cost = round4(tonumber(data.totalCost) or 0.0),
                prompt_tokens = tonumber(data.totalPromptTokens) or 0,
                completion_tokens = tonumber(data.totalCompletionTokens) or 0,
                cached_tokens = tonumber(data.totalCachedTokens) or 0,
            }

            local by_model = data.byModel
            local mlist = {}
            if type(by_model) == "table" then
                for k, v in pairs(by_model) do
                    if type(v) == "table" then
                        table.insert(mlist, {
                            key = tostring(k),
                            model = tostring(v.rawModel or k),
                            provider = tostring(v.provider or ""),
                            requests = tonumber(v.requests) or 0,
                            prompt_tokens = tonumber(v.promptTokens) or 0,
                            completion_tokens = tonumber(v.completionTokens) or 0,
                            cached_tokens = tonumber(v.cachedTokens) or 0,
                            cost = round4(tonumber(v.cost) or 0.0),
                            last_used = tostring(v.lastUsed or ""),
                        })
                    end
                end
                table.sort(mlist, function(a, b)
                    if a.cost ~= b.cost then return a.cost > b.cost end
                    if a.requests ~= b.requests then return a.requests > b.requests end
                    return a.prompt_tokens > b.prompt_tokens
                end)
            end
            models_usage[period] = mlist
            publish_state()
        end)
    end
end

-- ── Live Event Stream (Native noctalia.httpStream) ──────────────────────────

local function apply_stream_payload(data)
    if type(data) ~= "table" then return end

    auth = "ok"
    error_text = ""
    login_error = ""

    local active = norm_active(data.activeRequests)
    local recent = norm_recent(data.recentRequests)
    active_requests = active
    recent_requests = recent

    if #recent > 0 and type(recent[1]) == "table" then
        local top = recent[1]
        local top_key = tostring(top.timestamp or "") .. "|" .. tostring(top.model or "")
        if top.model and tostring(top.model) ~= "" then
            last_model = tostring(top.model)
        end
        if top.provider and tostring(top.provider) ~= "" then
            last_provider = tostring(top.provider)
        end
        if top.timestamp and tostring(top.timestamp) ~= "" then
            last_timestamp = tostring(top.timestamp)
        end

        if top_key ~= "" and top_key ~= last_seen_key then
            last_seen_key = top_key
            if seen_primed then
                last_arrival_ms = noctalia.nowMs()
            end
        end

        if not seen_primed then
            seen_primed = true
            last_arrival_ms = 0
        end

        save_last()
    end

    last_fetch_text = noctalia.formatTime("%H:%M:%S")
    publish_state()
end

local function stop_stream()
    if current_stream_handle then
        pcall(current_stream_handle.stop)
        current_stream_handle = nil
    end
    stream_active = false
end

local function start_stream()
    if stream_active then return end

    local base = get_resolved_url()
    local headers = get_auth_headers()
    table.insert(headers, "Accept: text/event-stream")

    stream_active = true
    current_stream_handle = noctalia.httpStream({
        url = base .. "/api/usage/stream",
        method = "GET",
        headers = headers,
    }, function(line)
        if line:sub(1, 5) == "data:" then
            local json_str = line:sub(6)
            if json_str:sub(1, 1) == " " then
                json_str = json_str:sub(2)
            end
            local parsed = noctalia.json.decode(json_str)
            if parsed then
                apply_stream_payload(parsed)
            end
        end
    end, function(result)
        current_stream_handle = nil
        stream_active = false
        if result and result.status == 401 then
            auth = "expired"
            error_text = "Session expired (401)"
            publish_state()
            if cfg_auth_mode() == "password" and cfg_remember_password() and not logging_in then
                noctalia.state.set("9router.command", { action = "stored_login" })
            end
        else
            next_stream_reconnect_ms = noctalia.nowMs() + 3000
        end
    end)

    if not current_stream_handle then
        stream_active = false
        next_stream_reconnect_ms = noctalia.nowMs() + 4000
    end
end

-- ── Password Login & Keyring (Subprocess curl Workaround) ───────────────────

local function remember_secret(secret)
    if not cfg_remember_password() or not secret or secret == "" then return end
    noctalia.runAsync({
        "sh", "-c",
        string.format("printf '%%s\\n' %q | secret-tool store --label='9Router dashboard password' service %q account %q", secret, KEYRING_SERVICE, KEYRING_ACCOUNT)
    })
end

local function forget_secret()
    noctalia.runAsync({
        "secret-tool", "clear",
        "service", KEYRING_SERVICE,
        "account", KEYRING_ACCOUNT
    })
end

local function do_password_login(password, on_complete)
    local secret = tostring(password or "")
    if secret == "" or logging_in then return end
    logging_in = true
    login_error = ""
    publish_state()

    local base = get_resolved_url()
    local payload = noctalia.json.encode({ password = secret })

    noctalia.runAsync({
        "curl", "-s", "-i", "-X", "POST",
        base .. "/api/auth/login",
        "-H", "Content-Type: application/json",
        "-d", payload
    }, function(result)
        logging_in = false
        if not result or result.exitCode ~= 0 then
            login_error = "curl failed to contact 9Router"
            publish_state()
            if on_complete then on_complete(false) end
            return
        end

        local stdout = result.stdout or ""
        local cookie = stdout:match("[Ss]et%-[Cc]ookie:%s*(session=[^;\r\n]+)")
        if not cookie then
            cookie = stdout:match("[Ss]et%-[Cc]ookie:%s*([^;\r\n]+)")
        end

        if cookie and cookie ~= "" then
            save_cookie(cookie)
            remember_secret(secret)
            auth = "ok"
            login_error = ""
            publish_state()

            fetch_quotas()
            fetch_models_usage_all()
            stop_stream()
            start_stream()
            if on_complete then on_complete(true) end
        else
            local status_code = tonumber(stdout:match("HTTP/[%d%.]+%s+(%d+)")) or 0
            if status_code == 401 then
                login_error = "Invalid password"
            else
                login_error = "Login failed (HTTP " .. tostring(status_code) .. ")"
            end
            auth = "expired"
            publish_state()
            if on_complete then on_complete(false) end
        end
    end)
end

local function try_stored_login()
    if not cfg_remember_password() or logging_in then return end
    noctalia.runAsync({
        "secret-tool", "lookup",
        "service", KEYRING_SERVICE,
        "account", KEYRING_ACCOUNT
    }, function(result)
        if result and result.exitCode == 0 and type(result.stdout) == "string" then
            local stored = result.stdout:match("^[^\r\n]+")
            if stored and stored ~= "" then
                do_password_login(stored)
            end
        end
    end)
end

local function do_logout()
    auth = "expired"
    active_requests = {}
    login_error = ""
    save_cookie("")
    forget_secret()
    stop_stream()
    publish_state()
end

-- ── Command Handling ────────────────────────────────────────────────────────

local function refresh_all()
    fetch_quotas()
    fetch_models_usage_all()
    if not stream_active and auth == "ok" then
        start_stream()
    end
end

local function handle_action(action, payload)
    if action == "refresh" then
        refresh_all()
    elseif action == "refresh_quotas" then
        fetch_quotas()
    elseif action == "login" then
        if type(payload) == "table" and payload.password then
            do_password_login(payload.password)
        elseif type(payload) == "string" then
            do_password_login(payload)
        end
    elseif action == "stored_login" then
        try_stored_login()
    elseif action == "set-tab" or action == "tab" then
        local t = tostring(payload or ""):lower():match("^%s*(.-)%s*$")
        if t == "activity" or t == "models" or t == "quotas" then
            noctalia.state.set("9router.active_tab", t)
        end
    elseif action == "next-tab" or action == "cycle-tab" then
        local cur = noctalia.state.get("9router.active_tab") or "activity"
        local nxt = if cur == "activity" then "models" elseif cur == "models" then "quotas" else "activity"
        noctalia.state.set("9router.active_tab", nxt)
    elseif action == "prev-tab" then
        local cur = noctalia.state.get("9router.active_tab") or "activity"
        local prv = if cur == "activity" then "quotas" elseif cur == "quotas" then "models" else "activity"
        noctalia.state.set("9router.active_tab", prv)
    elseif action == "activity" or action == "models" or action == "quotas" then
        noctalia.state.set("9router.active_tab", action)
    elseif action == "open-dashboard" then
        local base = base_url or "http://localhost:20128"
        noctalia.runAsync({ "xdg-open", base .. "/dashboard/usage" })
    elseif action == "logout" then
        do_logout()
    elseif action == "reconnect" then
        stop_stream()
        seen_primed = false
        last_seen_key = ""
        last_arrival_ms = 0
        auth = "unknown"
        error_text = ""
        login_error = ""
        refresh_all()
        start_stream()
    end
end

noctalia.state.watch("9router.command", function(cmd)
    if type(cmd) == "table" and cmd.action then
        handle_action(cmd.action, cmd)
    elseif type(cmd) == "string" then
        handle_action(cmd, nil)
    end
end)

function onIpc(event, payload)
    handle_action(event, payload)
end

function onConfigChanged()
    handle_action("reconnect", nil)
end

function onExit()
    stop_stream()
end

-- ── Startup ─────────────────────────────────────────────────────────────────

load_saved_last()
load_saved_cookie()
publish_state()

-- Initial data pull and stream connect
refresh_all()
start_stream()

-- If password mode configured with password, perform initial login
if cfg_auth_mode() == "password" and cfg_dashboard_password() ~= "" and session_cookie == "" then
    do_password_login(cfg_dashboard_password())
end

-- ── Periodic Heartbeat Loop ─────────────────────────────────────────────────

function update()
    ticks_since_poll += 1

    -- Update busy state in real-time
    publish_state()

    -- Reconnect stream if it dropped
    if not stream_active and auth == "ok" and noctalia.nowMs() >= next_stream_reconnect_ms then
        start_stream()
    end

    -- Periodic poll for quotas and period model statistics (every 30 seconds)
    local interval = math.max(6, cfg_refresh_seconds() * 6)
    if ticks_since_poll >= interval then
        ticks_since_poll = 0
        fetch_quotas()
        fetch_models_usage_all()
    end
end
