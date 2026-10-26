--!nonstrict
-- Shared Chat Completions transport. No shell, redirects, automatic fallback or raw logs.
local M = {}
local MAX_ANSWER_BYTES = 262144
local sequence = 0

function M.newSession()
  sequence = sequence + 1
  return "ses_quickask_" .. tostring(noctalia.nowMs()) .. "_" .. tostring(sequence)
    .. "_" .. tostring(math.random(100000, 999999))
end

local function statusError(status)
  if status == 401 then
    return noctalia.tr("api.unauthorized")
  elseif status == 403 then
    return noctalia.tr("api.forbidden")
  elseif status == 429 then
    return noctalia.tr("api.rate-limited")
  elseif status >= 500 then
    return noctalia.tr("api.unavailable")
  end
  return noctalia.tr("api.http-error", { status = tostring(status) })
end

function M.start(question, key, session, connection, callbacks)
  local active = true
  local native = nil
  local done = false
  local serviceError = false
  local malformed = false
  local answerBytes = 0

  local function finish(message, discard)
    if not active then return end
    active = false
    if message then callbacks.onError(message, discard == true) else callbacks.onComplete() end
  end

  local handle = {}
  function handle.stop()
    if not active then return end
    active = false -- invalidate before stop, even if the native callback is synchronous
    if native then native.stop(); native = nil end
  end

  local payload = {
    model = connection.model,
    messages = {
      { role = "system", content = "Give clear, concise and accurate answers, preferably in the user's language. Use Markdown when useful." },
      { role = "user", content = question },
    },
    stream = true,
  }
  local headers = {
    "Authorization: Bearer " .. key,
    "Content-Type: application/json",
    "Accept: text/event-stream",
    "User-Agent: quickask/0.2.0",
  }
  if connection.provider == "opencode-go" then
    payload.thinking = { type = "disabled" }
    table.insert(headers, "x-opencode-session: " .. session)
  end
  local request = {
    url = connection.endpoint,
    method = "POST",
    follow_redirects = false,
    body = noctalia.json.encode(payload),
    headers = headers,
  }
  key = nil
  headers = nil

  local ok, stream = pcall(noctalia.httpStream, request, function(line)
    if not active then return end
    if callbacks.onActivity then callbacks.onActivity() end
    if done or type(line) ~= "string" then return end
    local data = line:match("^data:%s?(.*)$")
    if not data then return end -- comments, event fields and raw HTTP error bodies
    data = data:gsub("\r$", "")
    if data == "[DONE]" then done = true; return end
    if data == "" then return end
    local decodedOK, event = pcall(noctalia.json.decode, data)
    if not decodedOK or type(event) ~= "table" then malformed = true; return end
    if event.error ~= nil then serviceError = true; return end
    if serviceError then return end
    local choices = event.choices
    local first = type(choices) == "table" and choices[1] or nil
    local delta = type(first) == "table" and first.delta or nil
    local text = type(delta) == "table" and delta.content or nil
    if type(text) ~= "string" or text == "" then return end
    answerBytes = answerBytes + #text
    if answerBytes > MAX_ANSWER_BYTES then
      if native then native.stop(); native = nil end
      finish(noctalia.tr("api.too-long"))
      return
    end
    callbacks.onDelta(text)
  end, function(result)
    if not active then return end
    native = nil
    local status = tonumber(result.status) or 0
    -- ok indicates transport success only; HTTP errors can have ok=true.
    if status ~= 0 and (status < 200 or status >= 300) then
      finish(statusError(status), true)
    elseif not result.ok or status == 0 then
      finish(noctalia.tr("api.connection"))
    elseif serviceError then
      finish(noctalia.tr("api.service-error"))
    elseif not done then
      finish(noctalia.tr("api.incomplete"))
    elseif answerBytes == 0 then
      finish(malformed and noctalia.tr("api.unreadable") or noctalia.tr("api.empty"))
    else
      finish(nil)
    end
  end)
  request.headers = nil -- native client owns its copy; do not retain the credential
  request = nil
  if ok and stream then
    if active then native = stream else stream.stop() end
  else
    finish(noctalia.tr("api.startup"))
  end
  return handle
end

return M
