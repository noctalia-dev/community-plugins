--[[
  openai.luau - everything that is pure data transformation between the
  OpenAI-compatible wire format and the plugin's own tables.

  Pure module: no `noctalia.*` calls, no I/O. The caller encodes JSON and owns
  the socket, which keeps every parsing rule below unit-testable with the
  standalone `luau` CLI.
]]

local M = {}

local WHITESPACE = { [9] = true, [10] = true, [11] = true, [12] = true, [13] = true, [32] = true }

-- Most strings (model ids above all) have nothing to trim, so the pattern engine
-- is only reached when the first or last byte really is whitespace. The callback
-- that folds a model list runs inside the host's CPU budget, and paying for a
-- `gsub` per id was most of that budget.
local function trim(s: string): string
  local length = #s
  if length == 0 or (not WHITESPACE[s:byte(1)] and not WHITESPACE[s:byte(length)]) then
    return s
  end
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

--[[
  Request headers as the array of "Name: value" strings `noctalia.http` wants.

  A blank key adds no Authorization header at all: local gateways and Ollama
  reject a stray `Bearer `, and some clouds read an empty one as a real
  credential attempt.
]]
function M.headers(resolved, key: string?, opts)
  local headers = {
    "Content-Type: application/json",
    "Accept: " .. ((opts and opts.stream) and "text/event-stream" or "application/json"),
  }
  if key ~= nil and key ~= "" then
    if resolved.auth then
      table.insert(headers, "Authorization: Bearer " .. key)
    end
  end
  if resolved.send_session and opts and opts.session_id and opts.session_id ~= "" then
    table.insert(headers, "x-opencode-session: " .. opts.session_id)
  end
  if resolved.user_agent and resolved.user_agent ~= "" then
    table.insert(headers, "User-Agent: " .. resolved.user_agent)
  end
  return headers
end

--[[
  Chat request body. Deliberately minimal:

    * `max_tokens` is omitted unless the user set one, so a provider keeps its
      own ceiling (a small ceiling plus a reasoning model yields empty content
      and `finish_reason = "length"`);
    * `tools` are only attached when the caller decided they are on.
]]
function M.request_body(opts)
  local body = {
    model = opts.model,
    messages = opts.messages,
    stream = opts.stream == true,
  }
  local max_tokens = tonumber(opts.max_tokens)
  if max_tokens ~= nil and max_tokens > 0 then
    body.max_tokens = max_tokens
  end
  if opts.tools ~= nil and #opts.tools > 0 then
    body.tools = opts.tools
  end
  return body
end

--[[
  A message's `content` is a string in the spec, but compatible servers also
  send an array of parts (`{ { type = "text", text = "..." } }`). Flatten both.
]]
function M.text_of(content): string
  if type(content) == "string" then
    return content
  end
  if type(content) == "table" then
    local parts = {}
    for _, part in ipairs(content) do
      if type(part) == "string" then
        table.insert(parts, part)
      elseif type(part) == "table" and type(part.text) == "string" then
        table.insert(parts, part.text)
      elseif type(part) == "table" and type(part.content) == "string" then
        table.insert(parts, part.content)
      end
    end
    return table.concat(parts, "")
  end
  return ""
end

--[[
  Turn any error shape into one readable sentence. Compatible servers answer
  with `{ error = "..." }`, `{ error = { message =, type = } }`, and once in a
  while with a plain HTML page instead of JSON; the caller handles the last one.
]]
function M.error_message(decoded): string?
  if type(decoded) ~= "table" then
    return nil
  end
  local err = decoded.error
  if type(err) == "string" and err ~= "" then
    return err
  end
  if type(err) == "table" then
    local message = err.message or err.msg or err.detail or err.error
    local code = err.code or err.type or err.status
    if type(message) ~= "string" then
      message = nil
    end
    if message and code ~= nil then
      return message .. " (" .. tostring(code) .. ")"
    end
    if message then
      return message
    end
  end
  if type(decoded.message) == "string" and decoded.message ~= "" and decoded.choices == nil then
    return decoded.message
  end
  return nil
end

function M.usage_of(usage)
  if type(usage) ~= "table" then
    return nil
  end
  local prompt = tonumber(usage.prompt_tokens) or tonumber(usage.input_tokens)
  local completion = tonumber(usage.completion_tokens) or tonumber(usage.output_tokens)
  local total = tonumber(usage.total_tokens)
  if total == nil and prompt ~= nil and completion ~= nil then
    total = prompt + completion
  end
  local cost = tonumber(usage.cost)
  if cost == nil and type(usage.cost_details) == "table" then
    cost = tonumber(usage.cost_details.upstream_inference_cost)
  end
  if prompt == nil and completion == nil and total == nil and cost == nil then
    return nil
  end
  return { prompt = prompt, completion = completion, total = total, cost = cost }
end

--[[
  Normalise `tool_calls` into `{ id, name, arguments }`. `arguments` stays the
  raw JSON string the model produced (some models stream it in pieces, and a
  few send an object); the executor parses it before use.
]]
function M.normalize_tool_calls(raw, opts)
  local calls = {}
  local invent_ids = not (opts ~= nil and opts.invent_ids == false)
  if type(raw) ~= "table" then
    return calls
  end
  for index, call in ipairs(raw) do
    if type(call) == "table" then
      local fn = type(call["function"]) == "table" and call["function"] or call
      local args = fn.arguments
      if args == nil then
        args = call.arguments
      end
      local id = type(call.id) == "string" and call.id ~= "" and call.id or nil
      if id == nil and invent_ids then
        id = "call_" .. tostring(index)
      end
      local thought_signature = call.thought_signature or fn.thought_signature
      table.insert(calls, {
        id = id,
        name = fn.name or call.name,
        arguments = args,
        -- streaming deltas carry the slot number; a complete response does not
        index = call.index,
        thought_signature = thought_signature,
      })
    end
  end
  return calls
end

--[[
  Read a complete (non-streaming) completion body. Returns a table with either
  `error` or the parsed result:

    { content, reasoning, tool_calls, finish_reason, model, usage }
]]
function M.parse_completion(decoded)
  if type(decoded) ~= "table" then
    return { error = "La respuesta no es un objeto JSON." }
  end
  local api_error = M.error_message(decoded)
  if api_error then
    return { error = api_error }
  end
  local choice = type(decoded.choices) == "table" and decoded.choices[1] or nil
  if type(choice) ~= "table" then
    return { error = "La respuesta no trae 'choices'." }
  end
  local message = type(choice.message) == "table" and choice.message or {}
  return {
    content = M.text_of(message.content),
    reasoning = M.text_of(message.reasoning_content or message.reasoning),
    tool_calls = M.normalize_tool_calls(message.tool_calls),
    finish_reason = choice.finish_reason,
    model = decoded.model,
    usage = M.usage_of(decoded.usage),
  }
end

--[[
  Model listing. Three shapes are in the wild and all three are accepted:

    { data = { { id = "..." }, ... } }   OpenAI, Ollama, Gemini, OmniRoute
    { models = { { name = "..." }, ... } }  Ollama's native endpoint
    { data = { "id", ... } }             hand-rolled gateways
]]
--[[
  Model catalogues can be a megabyte or more, and the runtime gives every host
  callback a 25 ms CPU budget: decoding a catalogue that size in one go overruns
  it, and three overruns in a row get the plugin auto-disabled. So a big
  catalogue is walked a slice at a time instead. These two functions find the
  array and hand back a bounded number of *raw* object substrings, which the
  caller decodes one by one.

  `json_list_start` returns the position just after the '[' that opens the
  `data` (or `models`) array, or after a bare top-level '['. nil means the
  payload is not a listing.
]]
function M.json_list_start(text: string): number?
  local _, stop = text:find('"data"%s*:%s*%[')
  if stop == nil then
    _, stop = text:find('"models"%s*:%s*%[')
  end
  if stop == nil then
    _, stop = text:find("^%s*%[")
  end
  if stop == nil then
    return nil
  end
  return stop + 1
end

-- Position just after the closing quote of the string that opens at `quote`, so
-- braces and brackets inside strings never count as structure.
local function end_of_string(text: string, quote: number, length: number): number
  local index = quote + 1
  while index <= length do
    local at = text:find('"', index, true)
    if at == nil then
      return length + 1
    end
    local backslashes = 0
    local back = at - 1
    while back > quote and text:sub(back, back) == "\\" do
      backslashes = backslashes + 1
      back = back - 1
    end
    if backslashes % 2 == 0 then
      return at + 1
    end
    index = at + 1
  end
  return length + 1
end

--[[
  Slice the objects of a JSON array out of `text`, starting at `pos` (the value
  `json_list_start` returned, or the one a previous call returned). Stops after
  `max_objects` objects or `max_chars` characters, whichever comes first, and
  reports where to continue and whether the array ended. The scan jumps between
  the few characters that carry structure instead of looking at every byte, so a
  slice costs a fraction of the CPU budget.
]]
function M.slice_json_objects(text: string, pos: number, max_objects: number, max_chars: number)
  local entries = {}
  local length = #text
  local cursor = pos
  local scanned = 0

  while #entries < max_objects and scanned < max_chars do
    local open = text:find("{", cursor, true)
    if open == nil then
      return entries, cursor, true
    end
    local array_end = text:find("]", cursor, true)
    if array_end ~= nil and array_end < open then
      return entries, cursor, true
    end

    local depth = 0
    local index = open
    local entry_end = nil
    while index <= length do
      local at = text:find('[{}"]', index)
      if at == nil then
        break
      end
      local ch = text:sub(at, at)
      if ch == '"' then
        index = end_of_string(text, at, length)
      else
        if ch == "{" then
          depth = depth + 1
        else
          depth = depth - 1
        end
        if depth == 0 then
          entry_end = at
          break
        end
        index = at + 1
      end
    end
    if entry_end == nil then
      return entries, cursor, true
    end

    table.insert(entries, text:sub(open, entry_end))
    scanned = scanned + (entry_end - open + 1)
    cursor = entry_end + 1
  end

  return entries, cursor, false
end

function M.parse_models(decoded)
  local ids = {}
  if type(decoded) ~= "table" then
    return ids, "La respuesta no es un objeto JSON."
  end
  local api_error = M.error_message(decoded)
  if api_error and decoded.data == nil and decoded.models == nil then
    return ids, api_error
  end
  local list = decoded.data or decoded.models
  if type(list) ~= "table" then
    return ids, "La respuesta no trae una lista 'data'."
  end
  for _, entry in ipairs(list) do
    local id
    if type(entry) == "string" then
      id = entry
    elseif type(entry) == "table" then
      id = entry.id or entry.name or entry.model
    end
    if type(id) == "string" then
      local trimmed = trim(id)
      if trimmed ~= "" then
        table.insert(ids, trimmed)
      end
    end
  end
  return ids
end

--[[
  Pick the useful metadata out of a model entry. OmniRoute (and OpenRouter)
  report capabilities; most others do not, which is why the caller tracks
  `tools_known` separately instead of assuming "no metadata = no tools".
]]
function M.model_entry_metadata(entry)
  if type(entry) ~= "table" then
    return nil
  end
  local capabilities = type(entry.capabilities) == "table" and entry.capabilities or {}
  local supports_tools = capabilities.tool_calling
  if supports_tools == nil and type(entry.supported_parameters) == "table" then
    for _, name in ipairs(entry.supported_parameters) do
      if name == "tools" then
        supports_tools = true
      end
    end
  end
  local context = tonumber(entry.context_length) or tonumber(entry.context_window)
  local free = capabilities.free == true
  if free == false and (entry.pricing == nil) then
    free = nil
  end
  return {
    tools = supports_tools == true,
    tools_known = supports_tools ~= nil,
    context = context,
    free = free,
  }
end

--[[
  SSE parsing. A line is either an event (`data: {...}`), the terminator
  (`data: [DONE]`), a comment/keepalive (`: ping`, `event: ...`), or a blank
  separator. Returns `{ payload = "..." }`, `{ done = true }`, or nil.
]]
function M.sse_payload(line: string?)
  if type(line) ~= "string" then
    return nil
  end
  local trimmed = trim(line)
  if trimmed == "" or trimmed:sub(1, 1) == ":" then
    return nil
  end
  local payload = trimmed
  if payload:sub(1, 5) == "data:" then
    payload = trim(payload:sub(6))
  elseif payload:sub(1, 6) == "event:" or payload:sub(1, 7) == "id: " then
    return nil
  end
  if payload == "[DONE]" then
    return { done = true }
  end
  if payload == "" then
    return nil
  end
  return { payload = payload }
end

--[[
  Read one decoded stream chunk. Handles both `delta` (streaming) and `message`
  (a server that answered a streaming request with one whole completion), plus
  providers that put the reasoning trace in `reasoning_content` or `reasoning`.
]]
function M.stream_chunk(decoded)
  if type(decoded) ~= "table" then
    return nil
  end
  local api_error = M.error_message(decoded)
  if api_error then
    return { error = api_error }
  end
  local choice = type(decoded.choices) == "table" and decoded.choices[1] or nil
  if type(choice) ~= "table" then
    if decoded.usage ~= nil and decoded.choices == nil then
      return { usage = M.usage_of(decoded.usage) }
    end
    return nil
  end
  local piece = type(choice.delta) == "table" and choice.delta or choice.message or {}
  return {
    content = M.text_of(piece.content),
    reasoning = M.text_of(piece.reasoning_content or piece.reasoning),
    tool_calls = M.normalize_tool_calls(piece.tool_calls, { invent_ids = false }),
    thought_signature = piece.thought_signature,
    finish_reason = choice.finish_reason,
    model = decoded.model,
    usage = M.usage_of(decoded.usage),
  }
end

--[[
  Streaming tool calls arrive spread over many chunks, keyed by `index`, with
  `arguments` concatenated as JSON fragments. This accumulator rejoins them.

  The name is taken from the first chunk that carries one: compatible servers
  send it once and in full (some repeat the whole name in every chunk, which
  then simply overwrites nothing), while only `arguments` is genuinely
  fragmented. Ids are never invented here, so a chunk without one cannot
  overwrite the real id seen earlier.
]]
function M.accumulate_tool_calls(accumulator, calls)
  if type(accumulator) ~= "table" or type(calls) ~= "table" then
    return accumulator
  end
  -- accept raw OpenAI deltas as well as already-normalised ones, so the caller
  -- never has to remember which shape a given code path produces
  calls = M.normalize_tool_calls(calls, { invent_ids = false })
  for position, call in ipairs(calls) do
    local index = tonumber(call.index)
    if index == nil then
      index = position - 1
    end
    local slot = accumulator[index + 1]
    if slot == nil then
      slot = { arguments = "" }
      accumulator[index + 1] = slot
    end
    if type(call.id) == "string" and call.id ~= "" then
      slot.id = call.id
    end
    if type(call.name) == "string" and call.name ~= "" and slot.name == nil then
      slot.name = call.name
    end
    if type(call.thought_signature) == "string" and call.thought_signature ~= "" then
      slot.thought_signature = call.thought_signature
    end
    local args = call.arguments
    if type(args) == "string" and args ~= "" then
      slot.arguments = slot.arguments .. args
    elseif type(args) == "table" then
      slot.arguments_table = args
    end
  end
  return accumulator
end

function M.finalize_tool_calls(accumulator)
  local calls = {}
  if type(accumulator) ~= "table" then
    return calls
  end
  for index, slot in ipairs(accumulator) do
    if type(slot) == "table" and (slot.name ~= nil or slot.arguments ~= "") then
      table.insert(calls, {
        id = slot.id or ("call_" .. tostring(index)),
        name = slot.name,
        arguments = slot.arguments_table or slot.arguments or "{}",
        thought_signature = slot.thought_signature,
      })
    end
  end
  return calls
end

function M.trim(s: string?): string
  return trim(s or "")
end

return M
