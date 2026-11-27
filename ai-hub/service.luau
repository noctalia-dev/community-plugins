--!nonstrict
--[[
  service.luau - the brain: one conversation, one in-flight request.

  The service owns every network call and every message in the transcript. The
  panel and the widget only render what it publishes and send commands back
  through the shared state channel, so there is exactly one place that knows how
  a request is built and what a response meant.

  Published keys (`hub.*`), all plain data:

    hub.messages    the transcript, oldest first
    hub.stream      the assistant message currently being written
    hub.status      "idle" | "thinking" | "streaming" | "waiting"
    hub.model       the selected model id
    hub.models      the fetched model list (ids, free set, tool set)
    hub.pending     a tool call waiting for the user's decision
    hub.info        provider/endpoint/key status for the panel header
    hub.test        the result of the last "Probar conexión"
    hub.cmd         commands from the panel (the panel bumps `seq`)

  Accepted commands: send, stop, clear, models, test, set_model, retry,
  approve, deny.

  Internal helpers are plain globals, which is how a plugin entry script
  already exposes `update`/`onIpc`/`onExit` to the host; none of the names below
  collide with a host callback.
]]

local providers = require("./lib/providers.luau")
local openai = require("./lib/openai.luau")
local config = require("./lib/config.luau")
local text = require("./lib/text.luau")
local tools = require("./lib/tools.luau")

local KEY_MESSAGES = "hub.messages"
local KEY_STREAM = "hub.stream"
local KEY_STATUS = "hub.status"
local KEY_MODEL = "hub.model"
local KEY_MODELS = "hub.models"
local KEY_PENDING = "hub.pending"
local KEY_INFO = "hub.info"
local KEY_TEST = "hub.test"
local KEY_COMMAND = "hub.cmd"

local MAX_STORED_MESSAGES = 200
local STREAM_PUBLISH_MS = 120
local IDLE_TIMEOUT_MS = 120000
local MAX_TOOL_ROUNDS = 8
local WATCHDOG_MS = 5000

local cfg = nil
local state = {}
local messages = {}
local status = "idle"
local pending = nil
local turn = nil
local stream_retry_notified = false
local last_command_seq = 0

local function now()
  return noctalia.nowMs()
end

local function trim(s)
  if type(s) ~= "string" then
    return ""
  end
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function publish(key, value)
  noctalia.state.set(key, value)
end

local function set_status(value)
  status = value
  publish(KEY_STATUS, value)
end

local function publish_messages()
  publish(KEY_MESSAGES, messages)
end

local function append_message(message)
  message.ts = message.ts or now()
  table.insert(messages, message)
  while #messages > MAX_STORED_MESSAGES do
    table.remove(messages, 1)
  end
  publish_messages()
  return message
end

local function publish_stream(active)
  if active == true and turn ~= nil then
    publish(KEY_STREAM, {
      active = true,
      content = turn.content,
      reasoning = turn.reasoning,
      model = turn.model or cfg.model,
    })
  else
    publish(KEY_STREAM, { active = false })
  end
end

local function publish_info()
  publish(KEY_INFO, config.fingerprint(cfg))
end

local function fail_turn(message)
  turn = nil
  pending = nil
  publish(KEY_PENDING, nil)
  publish(KEY_STREAM, { active = false })
  append_message({ role = "error", content = message })
  set_status("idle")
  noctalia.notifyError(noctalia.tr("notify.error_title"), message)
end

local function finish_turn()
  turn = nil
  publish(KEY_STREAM, { active = false })
  set_status("idle")
end

-- ---------------------------------------------------------------------------
-- Conversation to request
-- ---------------------------------------------------------------------------

local function request_messages()
  local out = {}
  if cfg.system_prompt ~= "" then
    table.insert(out, { role = "system", content = cfg.system_prompt })
  end

  local first = 1
  if #messages > cfg.max_history then
    first = #messages - cfg.max_history + 1
  end
  -- never start the window on a tool result (its assistant tool_calls would be
  -- gone, and the API rejects an orphaned `tool` message)
  while first < #messages do
    local message = messages[first]
    if message.role == "tool" or (message.role == "assistant" and message.tool_calls ~= nil) then
      first = first + 1
    else
      break
    end
  end

  for index = first, #messages do
    local message = messages[index]
    if message.role == "user" or message.role == "assistant" or message.role == "tool" then
      local entry = { role = message.role }
      if message.content ~= nil and message.content ~= "" then
        entry.content = message.content
      end
      if message.tool_calls ~= nil then
        entry.tool_calls = message.tool_calls
      end
      if message.tool_call_id ~= nil then
        entry.tool_call_id = message.tool_call_id
        entry.name = message.name
      end
      table.insert(out, entry)
    end
  end
  return out
end

local function tool_definitions()
  if cfg.tool_permission == "off" then
    return nil
  end
  return tools.definitions({ web_search = cfg.web_search })
end

local function api_tool_calls(calls, global_thought_signature)
  local out = {}
  for _, call in ipairs(calls) do
    local arguments = call.arguments
    if type(arguments) ~= "string" then
      arguments = noctalia.json.encode(arguments) or "{}"
    end
    local fn_entry = { name = call.name, arguments = arguments }
    local sig = call.thought_signature
    if (sig == nil or sig == "") and global_thought_signature ~= nil then
      sig = global_thought_signature
    end
    if sig ~= nil and sig ~= "" then
      fn_entry["thought_signature"] = sig
    end
    table.insert(out, {
      id = call.id,
      type = "function",
      ["function"] = fn_entry,
    })
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Requests
-- ---------------------------------------------------------------------------

local function describe_http_failure(status_code, raw_lines, stream_error)
  local detail = nil
  if type(raw_lines) == "table" and #raw_lines > 0 then
    local decoded = noctalia.json.decode(table.concat(raw_lines, "\n"))
    if type(decoded) == "table" then
      detail = openai.error_message(decoded)
    elseif #raw_lines == 1 then
      detail = text.one_line(text.html_to_text(raw_lines[1]), 200)
    end
  end
  if detail == nil or trim(detail) == "" then
    detail = stream_error
  end

  local head
  if status_code == 401 or status_code == 403 then
    head = noctalia.tr("error.unauthorized")
  elseif status_code == 404 then
    head = noctalia.tr("error.not_found")
  elseif status_code == 429 then
    head = noctalia.tr("error.rate_limited")
  elseif status_code == 0 then
    head = noctalia.tr("error.unreachable", { endpoint = cfg.endpoint })
  elseif status_code >= 500 then
    head = noctalia.tr("error.server", { status = tostring(status_code) })
  else
    head = noctalia.tr("error.http", { status = tostring(status_code) })
  end
  if detail ~= nil and trim(detail) ~= "" then
    head = head .. " — " .. text.one_line(detail, 400)
  end
  return head
end

local function finalize_round(result)
  if result == nil then
    fail_turn(noctalia.tr("error.empty_response"))
    return
  end
  if result.error ~= nil then
    fail_turn(result.error)
    return
  end

  local calls = result.tool_calls or {}
  if #calls > 0 and cfg.tool_permission ~= "off" then
    append_message({
      role = "assistant",
      content = result.content or "",
      tool_calls = api_tool_calls(calls, turn and turn.thought_signature),
      summary = noctalia.tr("panel.tool_calls", { count = tostring(#calls) }),
      model = result.model or cfg.model,
    })
    publish(KEY_STREAM, { active = false })
    turn.calls = calls
    turn.call_index = 0
    next_tool_call()
    return
  end

  local content = result.content or ""
  local message = append_message({
    role = "assistant",
    content = content,
    reasoning = result.reasoning,
    model = result.model or cfg.model,
    usage = result.usage,
    finish_reason = result.finish_reason,
  })
  if trim(content) == "" and result.finish_reason == "length" then
    message.notice = noctalia.tr("notice.length_empty")
    publish_messages()
  elseif trim(content) == "" and #(result.reasoning or "") > 0 then
    message.notice = noctalia.tr("notice.reasoning_only")
    publish_messages()
  elseif trim(content) == "" and #calls > 0 then
    -- the model asked for tools while they are switched off; say so instead of
    -- leaving an empty bubble behind
    message.notice = noctalia.tr("notice.tools_disabled")
    publish_messages()
  elseif trim(content) == "" and result.finish_reason ~= nil then
    -- the server closed the answer cleanly and never wrote anything
    message.notice = noctalia.tr("notice.stopped_empty")
    publish_messages()
  end
  finish_turn()
end

function next_tool_call()
  if turn == nil then
    return
  end
  local calls = turn.calls or {}
  local index = (turn.call_index or 0) + 1
  if index > #calls then
    turn.calls = nil
    turn.call_index = 0
    publish(KEY_PENDING, nil)
    pending = nil
    -- hand the tool results back to the model and let it continue
    send_request()
    return
  end
  turn.call_index = index
  local call = calls[index]
  local arguments, parse_error = tools.parse_arguments(call.arguments)
  if arguments == nil then
    append_tool_result(call, noctalia.tr("tool.bad_arguments", { error = tostring(parse_error) }))
    next_tool_call()
    return
  end
  call.parsed = arguments

  if cfg.tool_permission == "allow" then
    execute_tool_call(call)
    return
  end

  local title, body = tools.summary(call.name, arguments)
  pending = {
    id = call.id,
    name = call.name,
    position = index,
    total = #calls,
    title = title,
    body = body,
    blocked = tools.blocked(arguments.command, cfg.tool_blocklist),
  }
  publish(KEY_PENDING, pending)
  set_status("waiting")
end

function append_tool_result(call, content)
  append_message({
    role = "tool",
    tool_call_id = call.id,
    name = call.name,
    content = content,
    summary = noctalia.tr("tool.result", { name = tostring(call.name or "?") }),
  })
end

function execute_tool_call(call)
  pending = nil
  publish(KEY_PENDING, nil)
  set_status("thinking")
  tools.execute(call.name, call.parsed, { blocklist = cfg.tool_blocklist }, function(result)
    local body = result.text or ""
    if result.ok ~= true then
      body = noctalia.tr("tool.failed") .. " " .. body
    end
    append_tool_result(call, body)
    next_tool_call()
  end)
end

function perform_request()
  local body = openai.request_body({
    model = providers.request_model(cfg.model, cfg.resolved.strip_model_prefix),
    messages = request_messages(),
    stream = turn.stream,
    max_tokens = cfg.max_tokens,
    tools = tool_definitions(),
  })
  local encoded, encode_error = noctalia.json.encode(body)
  if encoded == nil then
    fail_turn("No se pudo codificar la petición: " .. tostring(encode_error))
    return
  end

  local request = {
    url = providers.chat_url(cfg.endpoint),
    method = "POST",
    headers = openai.headers(cfg.resolved, cfg.key, {
      stream = turn.stream,
      session_id = cfg.session_id,
    }),
    body = encoded,
  }

  if turn.rounds > 1 then
    noctalia.log("ai-hub: request body (tool round) " .. tostring((encoded or ""):sub(1, 1000)))
  end
  turn.content = ""
  turn.reasoning = ""
  turn.tool_calls = {}
  turn.thought_signature = nil
  turn.raw_lines = {}
  turn.error = nil
  turn.usage = nil
  turn.finish_reason = nil
  turn.started_at = now()
  turn.last_data_at = now()
  turn.published_at = 0
  set_status("thinking")
  publish_stream(true)

  if turn.stream then
    local handle = noctalia.httpStream(request, on_stream_line, on_stream_close)
    if handle == nil then
      -- a provider or a proxy that cannot stream: retry the same turn buffered
      turn.stream = false
      noctalia.log("ai-hub: streaming no disponible, se reintenta sin SSE")
      perform_request()
      return
    end
    turn.handle = handle
    return
  end

  local accepted = noctalia.http(request, on_response)
  if accepted ~= true then
    fail_turn(noctalia.tr("error.request_failed"))
  end
end

function send_request()
  if turn == nil then
    return
  end
  turn.rounds = (turn.rounds or 0) + 1
  if turn.rounds > MAX_TOOL_ROUNDS then
    append_message({ role = "notice", content = noctalia.tr("notice.tool_limit") })
    finish_turn()
    return
  end
  perform_request()
end

-- ---------------------------------------------------------------------------
-- Responses
-- ---------------------------------------------------------------------------

function on_stream_line(line)
  if turn == nil then
    return
  end
  turn.last_data_at = now()

  local payload = openai.sse_payload(line)
  if payload == nil then
    -- not an SSE line: a server that ignored stream=true may be sending one
    -- whole JSON body, which `recover_body` picks up when the transfer ends
    if type(line) == "string" and trim(line) ~= "" then
      table.insert(turn.raw_lines, line)
    end
    return
  end
  if payload.done then
    return
  end

  local decoded = noctalia.json.decode(payload.payload)
  if decoded == nil then
    table.insert(turn.raw_lines, payload.payload)
    return
  end

  local chunk = openai.stream_chunk(decoded)
  if chunk == nil then
    return
  end
  -- Debug: log SSE chunks that might carry thought_signature
  if chunk.tool_calls ~= nil or chunk.thought_signature ~= nil then
    noctalia.log("ai-hub: SSE chunk tool_calls=" .. tostring(#(chunk.tool_calls or {}))
      .. " thought=" .. tostring(chunk.thought_signature))
  end
  -- Also log the raw decoded payload when the delta carries extra fields
  if decoded ~= nil and type(decoded) == "table" then
    local choice = type(decoded.choices) == "table" and decoded.choices[1] or nil
    local piece = choice ~= nil and (choice.delta or choice.message) or nil
    if type(piece) == "table" and (piece.thought_signature ~= nil or piece.tool_calls ~= nil) then
      noctalia.log("ai-hub: SSE raw piece thought=" .. tostring(piece.thought_signature)
        .. " tools=" .. tostring(piece.tool_calls and #piece.tool_calls or 0))
    end
  end
  if chunk.error ~= nil then
    turn.error = chunk.error
    return
  end
  if chunk.content ~= nil and chunk.content ~= "" then
    turn.content = turn.content .. chunk.content
  end
  if chunk.reasoning ~= nil and chunk.reasoning ~= "" then
    turn.reasoning = turn.reasoning .. chunk.reasoning
  end
  if chunk.tool_calls ~= nil then
    openai.accumulate_tool_calls(turn.tool_calls, chunk.tool_calls)
  end
  if chunk.thought_signature ~= nil then
    turn.thought_signature = chunk.thought_signature
  end
  if chunk.finish_reason ~= nil then
    turn.finish_reason = chunk.finish_reason
  end
  if chunk.usage ~= nil then
    turn.usage = chunk.usage
  end
  if chunk.model ~= nil then
    turn.model = chunk.model
  end

  if (now() - turn.published_at) >= STREAM_PUBLISH_MS then
    turn.published_at = now()
    set_status("streaming")
    publish_stream(true)
  end
end

-- A server that answered a "streaming" request with a single JSON object.
function recover_body()
  if turn == nil or #turn.raw_lines == 0 then
    return nil
  end
  if turn.content ~= "" or #turn.tool_calls > 0 then
    return nil
  end
  local decoded = noctalia.json.decode(table.concat(turn.raw_lines, "\n"))
  if type(decoded) ~= "table" then
    return nil
  end
  -- hand it back even when it carries an API error: finalize_round turns that
  -- into a visible message instead of a silent empty bubble
  return openai.parse_completion(decoded)
end

function on_stream_close(result)
  if turn == nil then
    return
  end
  turn.handle = nil

  local ok = result ~= nil and result.ok == true
  local status_code = (result ~= nil and tonumber(result.status)) or 0
  if not ok or status_code < 200 or status_code >= 300 then
    local recovered = recover_body()
    if recovered ~= nil then
      finalize_round(recovered)
      return
    end
    noctalia.log(string.format("ai-hub: on_stream_close error status=%d raw_lines=%d err=%s body=%s",
      status_code, #turn.raw_lines, tostring(turn.error),
      tostring(table.concat(turn.raw_lines, "\n"))))
    fail_turn(describe_http_failure(status_code, turn.raw_lines, turn.error))
    return
  end

  local recovered = recover_body()
  if recovered ~= nil then
    finalize_round(recovered)
    return
  end

  -- Some servers ignore stream=true and answer with one plain JSON body, which
  -- the streaming client never hands over as lines: nothing at all arrives.
  -- Repeat the same turn once, buffered, instead of leaving an empty bubble.
  if #turn.raw_lines == 0 and #turn.tool_calls == 0 and trim(turn.content) == ""
    and trim(turn.reasoning) == "" and turn.error == nil and turn.finish_reason == nil
    and not turn.stream_retried then
    turn.stream_retried = true
    turn.stream = false
    noctalia.log("ai-hub: el servidor ignoró stream=true; se repite sin SSE")
    if not stream_retry_notified then
      stream_retry_notified = true
      noctalia.notifyError(noctalia.tr("notify.error_title"), noctalia.tr("notify.stream_ignored"))
    end
    perform_request()
    return
  end

  -- A 200 that is neither SSE nor JSON is what a wrong base URL answers with:
  -- a proxy page, a login wall, a captive portal. Say that instead of leaving an
  -- empty bubble behind.
  if trim(turn.content) == "" and #turn.tool_calls == 0 and #turn.raw_lines > 0 then
    if text.looks_like_html(table.concat(turn.raw_lines, "\n")) then
      fail_turn(noctalia.tr("error.html_body"))
      return
    end
  end

  finalize_round({
    content = turn.content,
    reasoning = turn.reasoning,
    tool_calls = openai.finalize_tool_calls(turn.tool_calls),
    finish_reason = turn.finish_reason,
    model = turn.model,
    usage = turn.usage,
  })
end

function on_response(response)
  if turn == nil then
    return
  end
  if response == nil then
    noctalia.log("ai-hub: on_response response=nil")
    fail_turn(noctalia.tr("error.request_failed"))
    return
  end
  local status_code = tonumber(response.status) or 0
  local decoded = noctalia.json.decode(response.body or "")
  if response.ok ~= true or status_code < 200 or status_code >= 300 then
    noctalia.log(string.format("ai-hub: on_response status=%d body=%s", status_code, tostring(response.body or "")))
    fail_turn(describe_http_failure(status_code, { response.body or "" }, nil))
    return
  end
  if type(decoded) ~= "table" then
    if text.looks_like_html(response.body or "") then
      noctalia.log("ai-hub: on_response HTML body: " .. tostring((response.body or ""):sub(1, 500)))
      fail_turn(noctalia.tr("error.html_body"))
      return
    end
    noctalia.log("ai-hub: on_response bad JSON: " .. tostring((response.body or ""):sub(1, 500)))
    fail_turn(noctalia.tr("error.bad_json"))
    return
  end
  finalize_round(openai.parse_completion(decoded))
end

-- ---------------------------------------------------------------------------
-- Model list
-- ---------------------------------------------------------------------------

-- Free models first, then alphabetical. Sorting with the built-in comparator and
-- partitioning afterwards keeps the comparisons in native code: a comparator
-- written here costs one host-language call per comparison, and a catalogue of a
-- few thousand models overruns the per-call CPU budget that way.
local function sort_models(ids)
  table.sort(ids)
  local ordered, paid = {}, {}
  for index = 1, #ids do
    local id = ids[index]
    if providers.looks_free(id) then
      table.insert(ordered, id)
    else
      table.insert(paid, id)
    end
  end
  for index = 1, #paid do
    table.insert(ordered, paid[index])
  end
  for index = 1, #ids do
    ids[index] = ordered[index]
  end
  return ids
end

-- A catalogue this size or smaller is folded in one pass: it is a couple of
-- hundred models at most, far inside the per-call CPU budget. A bigger one is
-- walked a slice at a time (see run_models_job).
local INLINE_MODELS_BYTES = 65536
-- Slice settings: how many objects and characters one call may chew, how long
-- that call may spend doing it, and how often the update() tick runs while a
-- catalogue is still being walked. The 25 ms per-call budget the runtime grants
-- is never approached.
local MODELS_SLICE_OBJECTS = 24
local MODELS_SLICE_CHARS = 32768
local MODELS_SLICE_MS = 6
local MODELS_SLICE_TICK_MS = 40

local models_job = nil

-- Everything the published model list needs, filled one entry at a time so that
-- a big catalogue can be spread over several calls.
local function new_model_set(provider, endpoint)
  return {
    seen = {},
    ids = {},
    free = {},
    tools = {},
    tools_known = false,
    provider = provider,
    endpoint = endpoint,
  }
end

-- One entry in: its display id (deduplicated), and the capabilities the panel
-- can filter by when the provider reports them.
local function collect_model(set, entry)
  for _, id in ipairs(openai.parse_models({ data = { entry } })) do
    local display = providers.display_model(id, cfg.resolved.strip_model_prefix)
    if display ~= "" and set.seen[display] == nil then
      set.seen[display] = true
      table.insert(set.ids, display)
    end
  end

  local metadata = openai.model_entry_metadata(entry)
  if metadata ~= nil and metadata.tools_known and type(entry) == "table" then
    local id = entry.id or entry.name or entry.model
    if type(id) == "string" then
      local display = providers.display_model(id, cfg.resolved.strip_model_prefix)
      if display ~= "" then
        set.tools_known = true
        if metadata.tools then
          set.tools[display] = true
        end
        if metadata.free then
          set.free[display] = true
        end
      end
    end
  end
end

local function publish_model_set(set, error_message)
  if error_message ~= nil then
    publish(KEY_MODELS, { ids = {}, error = error_message, provider = set.provider, endpoint = set.endpoint })
    noctalia.notifyError(noctalia.tr("notify.models_failed"), error_message)
    return
  end
  sort_models(set.ids)
  publish(KEY_MODELS, {
    ids = set.ids,
    free = set.free,
    tools = set.tools,
    tools_known = set.tools_known,
    provider = set.provider,
    endpoint = set.endpoint,
    fetched_at = now(),
    count = #set.ids,
    error = nil,
    loading = false,
  })
  noctalia.notify(noctalia.tr("notify.models_ok"), string.format("%d modelos", #set.ids))
end

-- Walk part of a catalogue that is too big to fold in one pass. Returns true
-- when there is nothing left to do; false means the update() tick should call
-- again. Each call stays inside its own CPU budget.
local function run_models_job()
  local job = models_job
  if job == nil then
    return true
  end
  local started = noctalia.nowMs()
  if job.cursor == nil then
    local start = openai.json_list_start(job.text)
    if start == nil then
      job.failed = true
      return true
    end
    job.cursor = start
  end
  while true do
    local objects, next_pos, done = openai.slice_json_objects(
      job.text, job.cursor, MODELS_SLICE_OBJECTS, MODELS_SLICE_CHARS)
    if #objects == 0 and not done then
      return true
    end
    for _, raw in ipairs(objects) do
      local entry = noctalia.json.decode(raw)
      if entry ~= nil then
        collect_model(job.set, entry)
      end
    end
    job.cursor = next_pos
    if done then
      return true
    end
    if noctalia.nowMs() - started >= MODELS_SLICE_MS then
      return false
    end
  end
end

local function finish_models_job()
  local job = models_job
  models_job = nil
  noctalia.setUpdateInterval(WATCHDOG_MS)
  if job == nil then
    return
  end
  if job.failed or #job.set.ids == 0 then
    publish_model_set(job.set, noctalia.tr("error.bad_json"))
    return
  end
  publish_model_set(job.set, nil)
end

function fetch_models()
  local problem = config.blocking_problem(cfg)
  if problem ~= nil then
    noctalia.notifyError(noctalia.tr("notify.models_failed"), problem)
    publish(KEY_MODELS, { ids = {}, error = problem, provider = cfg.provider, endpoint = cfg.endpoint })
    return
  end
  local previous = noctalia.state.get(KEY_MODELS)
  publish(KEY_MODELS, {
    ids = (type(previous) == "table" and previous.ids) or {},
    loading = true,
    provider = cfg.provider,
    endpoint = cfg.endpoint,
  })

  local request = {
    url = providers.models_url(cfg.endpoint),
    method = "GET",
    headers = openai.headers(cfg.resolved, cfg.key, { stream = false }),
  }
  local accepted = noctalia.http(request, function(response)
    if response == nil or response.ok ~= true then
      local status_code = response ~= nil and response.status or 0
      local message = describe_http_failure(status_code, { response ~= nil and response.body or "" }, nil)
      publish(KEY_MODELS, { ids = {}, error = message, provider = cfg.provider, endpoint = cfg.endpoint })
      noctalia.notifyError(noctalia.tr("notify.models_failed"), message)
      return
    end

    local body = response.body or ""
    local provider, endpoint = cfg.provider, cfg.endpoint
    if #body <= INLINE_MODELS_BYTES then
      local decoded = noctalia.json.decode(body)
      if type(decoded) ~= "table" then
        publish_model_set(new_model_set(provider, endpoint), noctalia.tr("error.bad_json"))
        return
      end
      local raw_list = type(decoded.data) == "table" and decoded.data or decoded.models
      local set = new_model_set(provider, endpoint)
      if type(raw_list) == "table" then
        for _, entry in ipairs(raw_list) do
          collect_model(set, entry)
        end
      end
      if #set.ids == 0 then
        -- nothing usable: the payload may carry the endpoint's own error text
        local _, parse_error = openai.parse_models(decoded)
        if parse_error ~= nil then
          publish_model_set(set, parse_error)
          return
        end
      end
      publish_model_set(set, nil)
      return
    end

    -- A catalogue this big cannot be decoded and folded inside one call without
    -- overrunning the CPU budget, which would eventually get the plugin
    -- auto-disabled. Start a job instead and let update() finish it.
    noctalia.log(string.format("ai-hub: catálogo de %d bytes; se recorre por partes", #body))
    models_job = {
      text = body,
      cursor = nil,
      set = new_model_set(provider, endpoint),
    }
    if run_models_job() then
      finish_models_job()
    else
      noctalia.setUpdateInterval(MODELS_SLICE_TICK_MS)
    end
  end)
  if accepted ~= true then
    publish(KEY_MODELS, {
      ids = {},
      error = noctalia.tr("error.request_failed"),
      provider = cfg.provider,
      endpoint = cfg.endpoint,
    })
    noctalia.notifyError(noctalia.tr("notify.models_failed"), noctalia.tr("error.request_failed"))
  end
end

-- ---------------------------------------------------------------------------
-- Connection test
-- ---------------------------------------------------------------------------

local function publish_test(ok, lines)
  publish(KEY_TEST, { ok = ok, lines = lines, at = now(), provider = cfg.provider })
end

function test_connection()
  local problem = config.blocking_problem(cfg)
  if problem ~= nil then
    publish_test(false, { problem })
    noctalia.notifyError(noctalia.tr("notify.test_failed"), problem)
    return
  end

  local results = {}
  local finished = false
  local expected = 1
  if cfg.provider == "openrouter" then
    expected = expected + 2
  end

  local function step(line, ok)
    table.insert(results, line)
    if #results >= expected and not finished then
      finished = true
      local all_ok = ok
      for _, entry in ipairs(results) do
        if entry:sub(1, 1) == "!" then
          all_ok = false
        end
      end
      publish_test(all_ok, results)
      if all_ok then
        noctalia.notify(noctalia.tr("notify.test_ok"), cfg.endpoint)
      else
        noctalia.notifyError(noctalia.tr("notify.test_failed"), results[#results])
      end
    end
  end

  local function request(path, describe)
    local accepted = noctalia.http({
      url = providers.normalize_endpoint(cfg.endpoint) .. path,
      method = "GET",
      headers = openai.headers(cfg.resolved, cfg.key, { stream = false }),
    }, function(response)
      if response == nil or response.ok ~= true then
        local status_code = response ~= nil and response.status or 0
        step("! " .. path .. ": " .. describe_http_failure(status_code, { response ~= nil and response.body or "" }, nil), false)
        return
      end
      local decoded = noctalia.json.decode(response.body or "")
      step(describe(decoded), true)
    end)
    if accepted ~= true then
      step("! " .. path .. ": " .. noctalia.tr("error.request_failed"), false)
    end
  end

  request("/models", function(decoded)
    local ids = openai.parse_models(decoded)
    return noctalia.tr("test.models", { count = tostring(#ids) })
  end)

  if cfg.provider == "openrouter" then
    request("/key", function(decoded)
      local data = type(decoded) == "table" and (decoded.data or decoded) or {}
      local label = tostring(data.label or data.name or "clave")
      local notice = ""
      if data.is_management_key == true or data.is_provisioning_key == true then
        notice = " ! " .. noctalia.tr("test.management_key")
      end
      return noctalia.tr("test.key", { label = label, limit = tostring(data.limit or "-") }) .. notice
    end)
    request("/credits", function(decoded)
      local data = type(decoded) == "table" and (decoded.data or decoded) or {}
      return noctalia.tr("test.credits", {
        credits = tostring(data.total_credits or "0"),
        usage = tostring(data.total_usage or "0"),
      })
    end)
  end
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

local function select_model(model)
  local clean = trim(model)
  noctalia.log("select_model called with: " .. tostring(model) .. " clean=" .. tostring(clean) .. " current cfg.model=" .. tostring(cfg.model))
  if clean == "" then
    return
  end
  cfg.model = providers.display_model(clean, cfg.resolved.strip_model_prefix)
  noctalia.log("select_model: after display_model cfg.model=" .. tostring(cfg.model))
  state = config.persist_model(cfg.state, cfg.model, cfg.model_setting)
  cfg.state = state
  publish(KEY_MODEL, cfg.model)
  publish_info()
end

function start_turn(prompt)
  local body = trim(prompt)
  if body == "" then
    return
  end
  if turn ~= nil then
    noctalia.notifyError(noctalia.tr("notify.error_title"), noctalia.tr("error.busy"))
    return
  end
  if cfg.model == "" then
    noctalia.notifyError(noctalia.tr("notify.error_title"), noctalia.tr("error.no_model"))
    return
  end
  local problem = config.blocking_problem(cfg)
  if problem ~= nil then
    fail_turn(problem)
    return
  end
  append_message({ role = "user", content = body })
  turn = { rounds = 0, stream = false }
  send_request()
end

function stop_turn()
  if turn == nil then
    return
  end
  if turn.handle ~= nil then
    -- stop() suppresses onClose, so the partial answer is finalized here
    turn.handle:stop()
  end
  local partial = turn.content
  local reasoning = turn.reasoning
  local model = turn.model
  finish_turn()
  if trim(partial) ~= "" then
    append_message({
      role = "assistant",
      content = partial,
      reasoning = reasoning,
      model = model or cfg.model,
      stopped = true,
    })
  else
    append_message({ role = "notice", content = noctalia.tr("notice.stopped_empty") })
  end
end

function retry_last()
  if turn ~= nil then
    return
  end
  -- drop the trailing error/notice noise so the transcript reads as if the
  -- failed attempt never happened, then ask again from the same history
  while #messages > 0 do
    local last = messages[#messages]
    if last.role == "error" or last.role == "notice" then
      table.remove(messages)
    else
      break
    end
  end
  publish_messages()
  local last_user = nil
  for index = #messages, 1, -1 do
    if messages[index].role == "user" then
      last_user = messages[index]
      break
    end
  end
  if last_user == nil then
    noctalia.notifyError(noctalia.tr("notify.error_title"), noctalia.tr("error.nothing_to_retry"))
    return
  end
  turn = { rounds = 0, stream = false }
  send_request()
end

function clear_conversation()
  if turn ~= nil then
    stop_turn()
  end
  messages = {}
  publish_messages()
  publish(KEY_PENDING, nil)
  pending = nil
  set_status("idle")
end

function handle_command(command)
  local kind = command.kind
  if kind == "send" then
    start_turn(command.text)
  elseif kind == "stop" then
    stop_turn()
  elseif kind == "clear" then
    clear_conversation()
  elseif kind == "retry" then
    retry_last()
  elseif kind == "models" then
    fetch_models()
  elseif kind == "test" then
    test_connection()
  elseif kind == "set_model" then
    select_model(command.model)
  elseif kind == "approve" then
    if turn ~= nil and pending ~= nil and pending.id == command.id then
      local call = turn.calls ~= nil and turn.calls[turn.call_index] or nil
      if call ~= nil then
        execute_tool_call(call)
      end
    end
  elseif kind == "deny" then
    if turn ~= nil and pending ~= nil and pending.id == command.id then
      local call = turn.calls ~= nil and turn.calls[turn.call_index] or nil
      if call ~= nil then
        append_tool_result(call, noctalia.tr("tool.denied"))
      end
      next_tool_call()
    end
  end
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function reload_config()
  cfg = config.read()
  state = cfg.state or {}
  publish_info()
  publish(KEY_MODEL, cfg.model)
end

reload_config()
publish(KEY_MESSAGES, messages)
publish(KEY_STREAM, { active = false })
publish(KEY_PENDING, nil)
publish(KEY_MODELS, { ids = {}, provider = cfg.provider, endpoint = cfg.endpoint })
publish(KEY_STATUS, status)
noctalia.setUpdateInterval(WATCHDOG_MS)

noctalia.state.watch(KEY_COMMAND, function(command)
  if type(command) ~= "table" then
    return
  end
  noctalia.log("service received command: " .. tostring(command.kind) .. " model=" .. tostring(command.model))
  handle_command(command)
end)

function onConfigChanged()
  local previous = cfg
  reload_config()
  -- Persist keys per provider:
  --   * provider changed and old key was manually typed → save it
  --   * same provider but key changed and is non-empty → save the new key
  if previous ~= nil then
    local old_provider = previous.provider
    local new_provider = cfg.provider
    local old_key = previous.key
    local new_key = cfg.key
    if old_provider ~= new_provider then
      -- Provider changed: save the old provider's key (only if manual and non-empty)
      if old_key ~= "" and previous.key_source == "manual" then
        local old_stored = config.load_credential(state, old_provider)
        if old_stored == nil or old_stored.key ~= old_key then
          config.save_credential(state, old_provider, old_key, "")
        end
      end
    elseif old_key ~= new_key and new_key ~= "" and previous.key_source == "manual" then
      -- Same provider, key changed: save the new key
      config.save_credential(state, new_provider, new_key, "")
    end
  end
  if models_job ~= nil then
    models_job = nil
    noctalia.setUpdateInterval(WATCHDOG_MS)
  end
  if previous == nil or previous.provider ~= cfg.provider or previous.endpoint ~= cfg.endpoint
    or previous.key ~= cfg.key then
    publish(KEY_MODELS, { ids = {}, provider = cfg.provider, endpoint = cfg.endpoint })
    publish(KEY_TEST, nil)
  end
end

function update()
  -- a catalogue too big to fold in one call is finished here, a slice per tick
  if models_job ~= nil and run_models_job() then
    finish_models_job()
  end

  -- a stream that stops producing data is cancelled here: httpStream has no
  -- overall timeout, so a wedged connection would otherwise hang the turn
  if turn ~= nil and turn.stream and turn.last_data_at ~= nil
    and (now() - turn.last_data_at) > IDLE_TIMEOUT_MS then
    local handle = turn.handle
    turn = nil
    if handle ~= nil then
      pcall(function()
        handle:stop()
      end)
    end
    pending = nil
    publish(KEY_PENDING, nil)
    publish(KEY_STREAM, { active = false })
    append_message({ role = "error", content = noctalia.tr("error.timeout") })
    set_status("idle")
    noctalia.notifyError(noctalia.tr("notify.error_title"), noctalia.tr("error.timeout"))
  end
end

function onIpc(event, payload)
  if event == "send" or event == "ask" then
    start_turn(payload)
  elseif event == "clear" then
    clear_conversation()
  elseif event == "stop" then
    stop_turn()
  elseif event == "models" then
    fetch_models()
  elseif event == "test" then
    test_connection()
  elseif event == "model" then
    select_model(payload)
  elseif event == "dump" then
    -- Bug-report aid: one JSON file the user can attach, plus a line in the log.
    -- The key is never included - only whether one was found and where it came
    -- from - and the model catalogue is reported by size, never in full.
    local listed = noctalia.state.get(KEY_MODELS)
    local model_count = 0
    if type(listed) == "table" and type(listed.ids) == "table" then
      model_count = #listed.ids
    end
    local function count_keys(value)
      local total = 0
      if type(value) == "table" then
        for _ in pairs(value) do
          total = total + 1
        end
      end
      return total
    end
    local snapshot = {
      plugin = "robpidev/ai-hub",
      generated_at = now(),
      info = config.fingerprint(cfg),
      status = status,
      stream = noctalia.state.get(KEY_STREAM),
      messages = messages,
      models = {
        count = model_count,
        error = type(listed) == "table" and listed.error or nil,
        provider = type(listed) == "table" and listed.provider or nil,
        endpoint = type(listed) == "table" and listed.endpoint or nil,
        free = type(listed) == "table" and count_keys(listed.free) or nil,
        tools = type(listed) == "table" and count_keys(listed.tools) or nil,
        tools_known = type(listed) == "table" and listed.tools_known or nil,
        fetched_at = type(listed) == "table" and listed.fetched_at or nil,
      },
      test = noctalia.state.get(KEY_TEST),
    }
    local directory = noctalia.pluginDataDir()
    local target = nil
    if type(directory) == "string" and directory ~= "" then
      target = directory .. "/dump.json"
    end
    local written, write_error = false, "sin directorio de datos"
    if target ~= nil then
      written, write_error = noctalia.writeFile(target, noctalia.json.encode(snapshot, true) or "")
    end
    if written == true then
      noctalia.log("ai-hub dump: escrito en " .. target)
      noctalia.notify(noctalia.tr("dump.title"), noctalia.tr("dump.written", { path = target }))
    else
      -- fall back to the log so the command still returns something
      noctalia.log("ai-hub dump: no se pudo escribir (" .. tostring(write_error) .. "); al log")
      noctalia.log("ai-hub dump: info=" .. tostring(noctalia.json.encode(snapshot.info)))
      noctalia.log("ai-hub dump: messages=" .. tostring(noctalia.json.encode(messages)))
      noctalia.notifyError(noctalia.tr("dump.title"), tostring(write_error))
    end
  elseif event == "ping" then
    noctalia.notify("AI Hub", "vivo")
  end
end

function onExit(_signal, reason)
  if turn ~= nil and turn.handle ~= nil then
    pcall(function()
      turn.handle:stop()
    end)
  end
  if reason == "disable" or reason == "uninstall" then
    noctalia.log("ai-hub: parando (" .. tostring(reason) .. ")")
  end
end
