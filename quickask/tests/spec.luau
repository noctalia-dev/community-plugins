local passed, failed = 0, 0
local function equal(actual, expected)
  assert(actual == expected, "Values differ") -- never print credentials or request bodies
end
local function find(kind, text, node)
  node = node or mock.tree
  if node.kind == kind and (text == nil or node.props.text == text) then return node end
  for _, child in ipairs(node.children) do
    local result = find(kind, text, child)
    if result then return result end
  end
  return nil
end
local function hasText(fragment, node)
  node = node or mock.tree
  if type(node.props.text) == "string" and node.props.text:find(fragment, 1, true) then return true end
  for _, child in ipairs(node.children) do if hasText(fragment, child) then return true end end
  return false
end
local function fresh(settings)
  onClose()
  resetMock()
  for key, value in pairs(settings or {}) do mock.settings[key] = value end
  onOpen({})
end
local function credential(index, overrides)
  local result = { exitCode = 0, stdout = "synthetic-test-credential\n", stderr = "" }
  for k, v in pairs(overrides or {}) do result[k] = v end
  mock.lookups[index or #mock.lookups](result)
  equal(result.stdout, nil)
  equal(result.stderr, nil)
end
local function request() return mock.requests[#mock.requests] end
local function emit(text, record)
  (record or request()).onLine("data: " .. json.encode({ choices = { { delta = { content = text } } } }))
end
local function flush(ms)
  mock.now = mock.now + (ms or 40)
  onFrameTick("40")
end
local function closeHTTP(status, ok, record)
  local r = record or request()
  r.active = false
  r.onClose({ status = status or 200, ok = ok ~= false })
end
local function begin(questionText)
  onSubmit(questionText or "Soru")
  credential()
  assert(request())
end
local function complete(text)
  emit(text or "Yanıt")
  request().onLine("data: [DONE]")
  closeHTTP()
end
local function test(name, fn)
  local ok = pcall(fn)
  if ok then passed = passed + 1; print("PASS " .. name)
  else failed = failed + 1; print("FAIL " .. name) end
end

test("opening paints before lookup; closing/reopening creates a fresh focused input", function()
  fresh()
  equal(#mock.lookups, 0); equal(#mock.requests, 0)
  local input = find("input")
  equal(input.props.focus, true); equal(input.props.multiline, true)
  equal(input.props.submitOnEnter, true); equal(input.props.placeholder, "Ask something…")
  local key = input.props.key
  input.props.onChange("Taslak")
  equal(find("input").props.key, key)
  onClose(); onOpen({}); assert(find("input").props.key ~= key)
  equal(find("input").props.value, "")
end)
test("empty and whitespace submits do not look up credentials or open HTTP", function()
  fresh(); onSubmit(""); onSubmit(" \n\t\r ")
  equal(#mock.lookups, 0); equal(#mock.requests, 0)
  equal(find("button", "Send").props.enabled, false)
end)
test("Unicode-only whitespace is disabled and cannot submit", function()
  fresh()
  local spaces = " \n\t"
  for _, cp in ipairs({ 0x85, 0xA0, 0x1680, 0x2000, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 }) do
    spaces = spaces .. utf8.char(cp)
  end
  find("input").props.onChange(spaces)
  equal(find("button", "Send").props.enabled, false)
  onSubmit(spaces); equal(#mock.lookups, 0); equal(#mock.requests, 0)
  find("input").props.onChange(spaces .. "İ")
  equal(find("button", "Send").props.enabled, true)
end)
test("input text and button callback submit exactly once", function()
  fresh(); find("input").props.onChange("  Soru  ")
  equal(find("button", "Send").props.enabled, true)
  find("button", "Send").props.onClick(); onSubmit("ikinci")
  equal(#mock.lookups, 1); credential(); equal(#mock.requests, 1)
  assert(hasText("Soru")); assert(not find("input"))
end)
test("JSON roundtrip preserves Turkish, quotes, backslashes, newlines and emoji", function()
  fresh()
  local q = 'Türkçe "alıntı" \\ yol\nyeni satır 🧠'
  begin(q)
  local payload = json.decode(request().request.body)
  equal(payload.messages[2].content, q)
  equal(#payload.messages, 2); equal(payload.messages[1].role, "system")
  equal(payload.model, "deepseek-v4.1-flash"); equal(payload.stream, true)
  equal(payload.thinking.type, "disabled")
end)
test("fixed HTTPS endpoint and complete header array with redirects disabled", function()
  fresh(); begin()
  local r = request().request
  equal(r.url, "https://opencode.ai/inference/go/openai/v1/chat/completions")
  equal(r.method, "POST"); equal(r.follow_redirects, false)
  assert(not r.allow_insecure_tls)
  equal(r.headers[1], "Authorization: Bearer synthetic-test-credential")
  equal(r.headers[2], "Content-Type: application/json")
  equal(r.headers[3], "Accept: text/event-stream")
  equal(r.headers[4], "User-Agent: quickask/0.2.0")
  assert(r.headers[5]:match("^x%-opencode%-session: ses_"))
end)
test("rapid duplicate Enter/retry opens at most one stream", function()
  fresh(); begin(); onSubmit("x"); onRetry(); onSubmit("y")
  equal(#mock.lookups, 1); equal(#mock.requests, 1); equal(mock.maxActive, 1)
end)
test("SSE metadata, malformed JSON, empty/role/reasoning deltas are safe", function()
  fresh(); begin()
  for _, line in ipairs({ "", ": ping", "event: message", "id: 1", "data:", "data: oops", "data: null", "data: {}", 'data: {"choices":[]}', 'data: {"choices":[{"delta":{"role":"assistant","reasoning_content":"hidden"}}]}' }) do request().onLine(line) end
  emit("İlk "); flush(); equal(find("markdown").props.text, "İlk ")
  emit("parça 🧠"); flush(); equal(find("markdown").props.text, "İlk parça 🧠")
  request().onLine("data: [DONE]\r"); closeHTTP()
  equal(find("button", "Copy response").props.enabled, true)
  assert(not hasText("hidden"))
end)
test("render coalescing displays chunks without rendering every token", function()
  fresh(); begin(); local before = mock.renders
  emit("A"); emit("B"); emit("C"); equal(mock.renders, before)
  flush(); equal(mock.renders, before + 1); equal(find("markdown").props.text, "ABC")
  equal(find("scroll").props.stickToBottom, true)
end)
test("Markdown/code response is copied without the user's question", function()
  fresh(); begin("Gizli soru")
  onCopy(); equal(mock.clipboard, nil)
  local text = "# Başlık\n```lua\nprint(1)\n```"
  emit(text); onCopy(); equal(mock.clipboard, nil)
  request().onLine("data: [DONE]"); closeHTTP(); onCopy()
  equal(mock.clipboard, text); assert(find("button", "Copied")); equal(mock.ticks, false)
end)
test("[DONE] alone does not hide a later HTTP 401", function()
  fresh(); begin(); emit("Yanlış veri"); request().onLine("data: [DONE]")
  equal(find("button", "Copy response").props.enabled, false)
  closeHTTP(401, true); assert(hasText("401")); assert(not find("markdown"))
end)
for _, status in ipairs({ 401, 403, 429, 500, 503, 302, 400 }) do
  test("HTTP " .. tostring(status) .. " with ok=true is an error without automatic retry", function()
    fresh(); begin(); request().onLine('{"error":{"message":"synthetic-private-body"}}')
    closeHTTP(status, true)
    assert(find("button", "Retry")); equal(#mock.requests, 1)
    assert(not hasText("synthetic-private-body")); assert(not find("markdown"))
  end)
end
test("raw HTTP error object cannot become an answer", function()
  fresh(); begin(); request().onLine('{"error":{"message":"private"}}'); closeHTTP()
  assert(find("button", "Retry")); assert(not find("markdown"))
end)
test("SSE error object and incomplete stream preserve partial text", function()
  fresh(); begin(); emit("Kısmi"); request().onLine('data: {"error":{"message":"private"}}')
  request().onLine("data: [DONE]"); closeHTTP()
  equal(find("markdown").props.text, "Kısmi"); assert(find("button", "Retry"))
  assert(not hasText("private"))
end)
test("EOF without DONE is incomplete, even with useful partial text", function()
  fresh(); begin(); emit("Kısmi"); closeHTTP()
  assert(hasText("before completion")); equal(find("markdown").props.text, "Kısmi")
end)
test("transport failure retains question and partial response", function()
  fresh(); begin("Asıl soru"); emit("Kısmi"); closeHTTP(0, false)
  assert(hasText("Internet")); assert(hasText("Asıl soru")); equal(find("markdown").props.text, "Kısmi")
end)
test("success transport without HTTP status is not accepted", function()
  fresh(); begin(); emit("x"); request().onLine("data: [DONE]"); closeHTTP(0, true)
  assert(find("button", "Retry"))
end)
test("empty completed answer is a recoverable error", function()
  fresh(); begin(); request().onLine("data: [DONE]"); closeHTTP()
  assert(hasText("empty response"))
end)
test("stop cancels once, preserves partial answer, ignores all late callbacks", function()
  fresh(); begin(); local old = request(); emit("Kısmi"); flush()
  onStop(); equal(old.stopped, 1); equal(mock.ticks, false)
  emit("geç", old); old.onClose({ ok = true, status = 200 }); flush()
  equal(find("markdown").props.text, "Kısmi"); assert(hasText("Stopped"))
  onStop(); equal(old.stopped, 1)
end)
test("close/reopen isolates old streams and creates a new session", function()
  fresh(); begin(); local old = request(); local oldSession = old.request.headers[5]
  onClose(); equal(old.stopped, 1); onOpen({}); begin("Yeni")
  assert(request().request.headers[5] ~= oldSession)
  emit("eski", old); old.onClose({ ok = false, status = 0 })
  complete("Yeni yanıt"); equal(find("markdown").props.text, "Yeni yanıt")
end)
test("close and stop invalidate pending credential callbacks", function()
  fresh(); onSubmit("Eski"); onClose(); onOpen({}); credential(1); equal(#mock.requests, 0)
  onSubmit("Yeni"); onStop(); credential(2); equal(#mock.requests, 0)
end)
test("retry preserves the question and session and ignores the previous stream", function()
  fresh(); begin("Asıl soru"); local old = request(); emit("Kısmi"); closeHTTP(503)
  onRetry(); onRetry(); equal(#mock.lookups, 2); credential(2)
  equal(request().request.headers[5], old.request.headers[5])
  equal(json.decode(request().request.body).messages[2].content, "Asıl soru")
  emit("geç", old); complete("Başarılı"); equal(find("markdown").props.text, "Başarılı")
  equal(mock.maxActive, 1)
end)
test("missing secret-tool never starts lookup or HTTP", function()
  fresh(); mock.commandExists = false; onSubmit("Soru")
  equal(#mock.lookups, 0); equal(#mock.requests, 0); assert(hasText("libsecret"))
end)
for _, scenario in ipairs({
  { name = "missing key", value = { stdout = "\n" } },
  { name = "locked keyring", value = { exitCode = 1, stderr = "private" } },
  { name = "lookup timeout", value = { timedOut = true } },
  { name = "truncated secret", value = { stdoutTruncated = true } },
  { name = "header injection", value = { stdout = "bad\r\nX-Header: value" } },
}) do
  test(scenario.name .. " yields safe guidance without HTTP", function()
    fresh(); onSubmit("Soru"); credential(1, scenario.value)
    equal(#mock.requests, 0); assert(find("button", "Retry"))
    assert(not hasText("private")); assert(not hasText("X-Header"))
  end)
end
test("subprocess startup failure is recoverable", function()
  fresh(); mock.processStarted = false; onSubmit("Soru")
  assert(hasText("Could not start")); equal(#mock.requests, 0)
end)
for _, mode in ipairs({ "nil", "throw", "syncError" }) do
  test("native HTTP " .. mode .. " startup is handled", function()
    fresh(); mock.httpMode = mode; onSubmit("Soru"); credential()
    assert(find("button", "Retry")); equal(mock.ticks, false)
  end)
end
test("credential timeout rejects a late key, even after manual retry", function()
  fresh(); onSubmit("Soru"); flush(45001); assert(hasText("timed out"))
  onRetry(); credential(1); equal(#mock.requests, 0)
  credential(2); equal(#mock.requests, 1); complete()
end)
test("idle HTTP timeout stops the stream and preserves partial output", function()
  fresh(); begin(); emit("Kısmi"); local old = request(); flush(45001)
  equal(old.stopped, 1); equal(find("markdown").props.text, "Kısmi")
  emit("geç", old); equal(find("markdown").props.text, "Kısmi")
end)
test("total timeout applies even with periodic keepalives", function()
  fresh(); begin()
  for _ = 1, 5 do request().onLine(": ping"); flush(40000) end
  assert(hasText("timed out")); equal(request().stopped, 1)
end)
test("oversized answers stop at bounded memory without losing prior output", function()
  fresh(); begin(); emit("Kısmi"); emit(string.rep("x", 262144))
  equal(request().stopped, 1); equal(find("markdown").props.text, "Kısmi")
  assert(hasText("display limit"))
end)
test("clipboard failure is visible and can be retried without a request", function()
  fresh(); begin(); complete(); mock.clipboardOK = false; onCopy()
  assert(hasText("clipboard")); assert(not find("button", "Retry"))
  onRetry(); equal(#mock.lookups, 1); equal(find("markdown").props.text, "Yanıt")
  mock.clipboardOK = true; onCopy()
  assert(not hasText("clipboard")); assert(not find("button", "Retry"))
  equal(mock.clipboard, "Yanıt"); equal(#mock.requests, 1)
end)
test("close button cancels stream and exit clears the session", function()
  fresh(); begin(); local old = request(); onCloseClicked()
  equal(mock.closed, 1); equal(old.stopped, 1)
  onOpen({}); equal(find("input").props.value, ""); onExit("", "reload")
  onSubmit("Geç"); equal(#mock.lookups, 1)
end)

local compatible = { provider = "openai-compatible", endpoint = "https://api.example.org/v1/chat/completions", model = "test-model" }

test("compatible mode streams text with standard JSON and no Go-only headers or parameters", function()
  fresh(compatible)
  assert(hasText("api.example.org · test-model"))
  equal(#mock.lookups, 0); equal(#mock.requests, 0)
  begin('Question "one"\nUnicode İ 🧠')
  local r = request().request
  local payload = json.decode(r.body)
  equal(r.url, compatible.endpoint); equal(r.method, "POST"); equal(r.follow_redirects, false)
  assert(not r.allow_insecure_tls)
  equal(payload.model, compatible.model); equal(payload.stream, true)
  equal(payload.thinking, nil); equal(#payload.messages, 2)
  local fieldCount = 0
  for _ in pairs(payload) do fieldCount = fieldCount + 1 end
  equal(fieldCount, 3)
  equal(#r.headers, 4); equal(r.headers[1], "Authorization: Bearer synthetic-test-credential")
  equal(r.headers[4], "User-Agent: quickask/0.2.0")
  equal(table.concat(mock.lookupArgs[1], "|"), "secret-tool|lookup|application|quickask|provider|openai-compatible|endpoint|" .. compatible.endpoint)
  emit("# Answer\n"); flush(); equal(find("markdown").props.text, "# Answer\n")
  complete("```lua\nprint(1)\n```"); onCopy()
  equal(mock.clipboard, "# Answer\n```lua\nprint(1)\n```")
end)

test("Go preset ignores compatible endpoint/model settings and retains the original key attributes", function()
  fresh({ endpoint = "https://other.example/v1/chat/completions", model = "other-model" }); begin()
  equal(json.decode(request().request.body).model, "deepseek-v4.1-flash")
  equal(table.concat(mock.lookupArgs[1], "|"), "secret-tool|lookup|application|quickask|provider|opencode-go")
end)

test("unknown provider never falls back to Go or looks up credentials", function()
  fresh({ provider = "typo" }); onSubmit("Soru")
  equal(find("button", "Send").props.enabled, false)
  equal(#mock.lookups, 0); equal(#mock.requests, 0); assert(hasText("Unknown API provider"))
end)

for index, endpoint in ipairs({
  "", "http://api.example.org/v1/chat/completions", "https://api.example.org/v1/responses",
  "https://api.example.org", "https://api.example.org/v1/chat/completions?key=private",
  "https://api.example.org/v1/chat/completions#private", "https://user:private@api.example.org/v1/chat/completions",
  "https://api.example.org\\@evil.example/v1/chat/completions", "https://api.example.org\n/v1/chat/completions",
  "https://api.example.org:0/v1/chat/completions", "https://api.example.org:65536/v1/chat/completions",
  "https://api.example.org:abc/v1/chat/completions", "https://-bad.example/v1/chat/completions",
  "https://api..example.org/v1/chat/completions", "https://api.example.org./v1/chat/completions",
  "https://api%2eexample.org/v1/chat/completions", "https://api.example.org/v1/chat/completions/",
}) do
  test("invalid compatible endpoint " .. tostring(index) .. " is blocked before credentials or network", function()
    fresh({ provider = compatible.provider, endpoint = endpoint, model = compatible.model })
    onSubmit("Soru"); equal(#mock.lookups, 0); equal(#mock.requests, 0)
    equal(find("button", "Send").props.enabled, false); assert(hasText("full HTTPS URL"))
    assert(not hasText("private"))
  end)
end

for _, model in ipairs({ "", "   ", "bad\nmodel", string.rep("m", 257) }) do
  test("invalid compatible model is blocked before credentials or network", function()
    fresh({ provider = compatible.provider, endpoint = compatible.endpoint, model = model })
    onSubmit("Soru"); equal(#mock.lookups, 0); equal(#mock.requests, 0)
    assert(hasText("valid model ID"))
  end)
end

for _, endpoint in ipairs({ "https://host.example:8443/api/v1/chat/completions", "https://[::1]:8443/v1/chat/completions" }) do
  test("compatible HTTPS endpoints with explicit ports bind credentials to the complete URL", function()
    fresh({ provider = compatible.provider, endpoint = endpoint, model = "  vendor/model  " }); begin()
    equal(request().request.url, endpoint); equal(mock.lookupArgs[1][8], endpoint)
    equal(json.decode(request().request.body).model, "vendor/model")
  end)
end

test("a compatible missing key never falls back to the Go credential or sends a request", function()
  fresh(compatible); onSubmit("Soru"); credential(nil, { stdout = "" })
  equal(#mock.lookups, 1); equal(#mock.requests, 0)
  assert(hasText("selected provider and endpoint"))
end)

test("compatible retry keeps its connection snapshot during delayed credential lookup", function()
  fresh(compatible); onSubmit("Soru")
  mock.settings.endpoint = "https://different.example/v1/chat/completions"
  mock.settings.model = "different-model"
  mock.settings.provider = "opencode-go"
  credential(); equal(request().request.url, compatible.endpoint)
  equal(json.decode(request().request.body).model, compatible.model)
  closeHTTP(503); onRetry(); credential()
  equal(mock.lookupArgs[2][8], compatible.endpoint); equal(request().request.url, compatible.endpoint)
  complete(); onClose(); onOpen({}); begin()
  equal(request().request.url, "https://opencode.ai/inference/go/openai/v1/chat/completions")
end)

test("submission uses the destination displayed at opening even if settings change before Enter", function()
  fresh(compatible)
  mock.settings.provider = "opencode-go"
  mock.settings.endpoint = "https://different.example/v1/chat/completions"
  mock.settings.model = "different-model"
  begin()
  equal(request().request.url, compatible.endpoint)
  equal(json.decode(request().request.body).model, compatible.model)
  equal(mock.lookupArgs[1][8], compatible.endpoint)
end)

test("changing compatible endpoint requires a separately scoped lookup on reopening", function()
  fresh(compatible); begin(); complete(); onClose()
  local endpoint = "https://different.example/v1/chat/completions"
  mock.settings.endpoint = endpoint; onOpen({}); onSubmit("Yeni")
  equal(mock.lookupArgs[2][8], endpoint); credential(nil, { stdout = "" })
  equal(#mock.requests, 1); assert(hasText("No key was found"))
end)

test("opening settings cancels the stream before handing control to Noctalia", function()
  fresh(compatible); begin(); local old = request(); emit("partial")
  onSettingsClicked(); equal(old.stopped, 1); equal(mock.settingsOpened, 1)
  emit("late", old); old.onClose({ ok = true, status = 200 }); onSubmit("late")
  equal(#mock.requests, 1); equal(mock.ticks, false)
  onOpen({}); equal(find("input").props.value, "")
end)

test("opening settings while key lookup is pending prevents the delayed request", function()
  fresh(compatible); onSubmit("Soru"); onSettingsClicked(); credential()
  equal(#mock.requests, 0); equal(mock.settingsOpened, 1)
end)

for _, status in ipairs({ 401, 403, 429, 500 }) do
  test("compatible HTTP " .. tostring(status) .. " preserves provider choice and never falls back", function()
    fresh(compatible); begin(); closeHTTP(status)
    equal(#mock.requests, 1); equal(#mock.lookups, 1); assert(find("button", "Retry"))
    onRetry(); credential(); equal(request().request.url, compatible.endpoint)
  end)
end

test("compatible timeout cancels the stream and ignores late callbacks", function()
  fresh(compatible); begin(); local old = request(); emit("partial"); flush(45001)
  equal(old.stopped, 1); assert(hasText("timed out")); emit("late", old)
  equal(find("markdown").props.text, "partial")
end)

onClose()
print(tostring(passed) .. " passed; " .. tostring(failed) .. " failed")
assert(failed == 0, "QuickAsk test failures (payloads and secrets intentionally omitted)")
